/* Production address discovery with synthetic interfaces only: no sockets,
 * actual interface queries, SDL or receiver process. */
#include <arpa/inet.h>
#include <assert.h>
#include <ifaddrs.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <SystemConfiguration/SystemConfiguration.h>
#endif

enum { MAX_ADDRESSES = 32 };
static struct ifaddrs fake_addresses[MAX_ADDRESSES];
static struct sockaddr_in fake_sockaddrs[MAX_ADDRESSES];
static int address_count, get_calls, free_calls, get_failure;
static const struct sockaddr *name_failure;
static int checks;

static int fake_getifaddrs(struct ifaddrs **output) {
    ++get_calls;
    *output = NULL;
    if (get_failure) return -1;
    if (address_count) *output = fake_addresses;
    return 0;
}

static void fake_freeifaddrs(struct ifaddrs *addresses) {
    assert(addresses == (address_count ? fake_addresses : NULL));
    ++free_calls;
}

static int fake_getnameinfo(const struct sockaddr *address, socklen_t address_len,
                          char *host, socklen_t host_len, char *service,
                          socklen_t service_len, int flags) {
    assert(flags & NI_NUMERICHOST);
    if (address == name_failure) return EAI_FAIL;
    return getnameinfo(address, address_len, host, host_len, service, service_len, flags);
}

#if defined(__APPLE__)
struct fake_role { CFStringRef name; CFStringRef kind; };
static struct fake_role roles[MAX_ADDRESSES];
static int role_count, copy_calls, copy_failure, role_queries;

static CFArrayRef fake_SCNetworkInterfaceCopyAll(void) {
    ++copy_calls;
    if (copy_failure) return NULL;
    const void *values[MAX_ADDRESSES];
    for (int i = 0; i < role_count; ++i) values[i] = &roles[i];
    return CFArrayCreate(NULL, values, role_count, NULL);
}

static CFStringRef fake_SCNetworkInterfaceGetBSDName(SCNetworkInterfaceRef interface) {
    ++role_queries;
    return ((const struct fake_role *)interface)->name;
}

static CFStringRef fake_SCNetworkInterfaceGetInterfaceType(SCNetworkInterfaceRef interface) {
    return ((const struct fake_role *)interface)->kind;
}
#define SCNetworkInterfaceCopyAll fake_SCNetworkInterfaceCopyAll
#define SCNetworkInterfaceGetBSDName fake_SCNetworkInterfaceGetBSDName
#define SCNetworkInterfaceGetInterfaceType fake_SCNetworkInterfaceGetInterfaceType
#endif
#define getifaddrs fake_getifaddrs
#define freeifaddrs fake_freeifaddrs
#define getnameinfo fake_getnameinfo
#include "../src/net.c"
#undef getifaddrs
#undef freeifaddrs
#undef getnameinfo

#define CHECK(condition) do { ++checks; assert(condition); } while (0)

static void reset_fixture(void) {
    memset(fake_addresses, 0, sizeof(fake_addresses));
    memset(fake_sockaddrs, 0, sizeof(fake_sockaddrs));
    address_count = get_calls = free_calls = get_failure = 0;
    name_failure = NULL;
#if defined(__APPLE__)
    memset(roles, 0, sizeof(roles));
    role_count = copy_calls = copy_failure = role_queries = 0;
#endif
}

static void add_address(const char *name, const char *ip) {
    assert(address_count < MAX_ADDRESSES);
    const int index = address_count++;
    struct ifaddrs *address = &fake_addresses[index];
    address->ifa_name = (char *)name;
    if (index) fake_addresses[index - 1].ifa_next = address;
    if (ip) {
        fake_sockaddrs[index].sin_family = AF_INET;
        assert(inet_pton(AF_INET, ip, &fake_sockaddrs[index].sin_addr) == 1);
        address->ifa_addr = (struct sockaddr *)&fake_sockaddrs[index];
    }
}

#if defined(__APPLE__)
static void add_role(CFStringRef name, CFStringRef kind) {
    assert(role_count < MAX_ADDRESSES);
    roles[role_count++] = (struct fake_role){name, kind};
}
#endif

static void expect_empty(const struct tb_net_addresses *addresses) {
    CHECK(!addresses->tb_ip[0]);
    CHECK(!addresses->link_local_ip[0]);
    CHECK(!addresses->lan_ip[0]);
    CHECK(!addresses->ethernet_ip[0]);
    CHECK(!addresses->wifi_ip[0]);
}

static void test_selection_and_legacy_getters(void) {
    reset_fixture();
    add_address("missing", NULL);
    add_address("lo0", "127.0.0.1");
    add_address("utun0", "169.254.1.1");
    add_address("bridge0", "8.8.8.8");
    add_address("bridge0", "169.254.2.1");
    add_address("bridge1", "169.254.2.2");
    add_address("en7", "169.254.3.1");
    add_address("eth4", "169.254.3.2");
#if defined(__APPLE__)
    const char *wifi = "en0";
    add_role(CFSTR("en0"), kSCNetworkInterfaceTypeIEEE80211);
    add_role(CFSTR("en8"), kSCNetworkInterfaceTypeEthernet);
    add_role(CFSTR("utun8"), kSCNetworkInterfaceTypePPP);
#else
    const char *wifi = "wlan0";
#endif
    add_address(wifi, "192.168.7.2");
    add_address(wifi, "192.168.7.3");
    add_address("utun8", "10.0.0.9");
    add_address("en8", "1.1.1.1");
    add_address("en8", "172.15.1.1");
    add_address("en8", "172.16.1.2");
    add_address("en8", "10.1.1.3");
    struct tb_net_addresses addresses;
    memset(&addresses, 0x7f, sizeof(addresses));
    CHECK(tb_net_get_addresses(&addresses) == 0);
    CHECK(!strcmp(addresses.tb_ip, "169.254.2.1"));
    CHECK(!strcmp(addresses.link_local_ip, "169.254.3.1"));
    CHECK(!strcmp(addresses.lan_ip, "172.16.1.2"));
    CHECK(!strcmp(addresses.ethernet_ip, "172.16.1.2"));
    CHECK(!strcmp(addresses.wifi_ip, "192.168.7.2"));
    CHECK(get_calls == 1 && free_calls == 1);
#if defined(__APPLE__)
    CHECK(copy_calls == 1);
#endif
    int (*getters[])(char *, size_t) = {tb_net_get_tb_ip, tb_net_get_link_local_ip,
        tb_net_get_lan_ip, tb_net_get_ethernet_ip, tb_net_get_wifi_ip};
    const char *expected[] = {addresses.tb_ip, addresses.link_local_ip,
        addresses.lan_ip, addresses.ethernet_ip, addresses.wifi_ip};
    for (size_t i = 0; i < sizeof(getters) / sizeof(getters[0]); ++i) {
        char output[64] = "previous";
        CHECK(getters[i](output, sizeof(output)) == 0);
        CHECK(!strcmp(output, expected[i]));
    }
    char tiny[4];
    CHECK(tb_net_get_lan_ip(tiny, sizeof(tiny)) == 0);
    CHECK(!strcmp(tiny, "172"));
}

static void test_wifi_fallback_and_refresh(void) {
    reset_fixture();
#if defined(__APPLE__)
    add_role(CFSTR("en2"), kSCNetworkInterfaceTypeIEEE80211);
    add_address("en2", "192.168.1.5");
#else
    add_address("wifi0", "192.168.1.5");
#endif
    struct tb_net_addresses addresses;
    CHECK(tb_net_get_addresses(&addresses) == 0);
    CHECK(!addresses.ethernet_ip[0]);
    CHECK(!strcmp(addresses.lan_ip, "192.168.1.5"));
    CHECK(!strcmp(addresses.wifi_ip, "192.168.1.5"));
    reset_fixture();
    CHECK(tb_net_get_addresses(&addresses) == 0);
    expect_empty(&addresses);
    CHECK(get_calls == 1 && free_calls == 1);
#if defined(__APPLE__)
    CHECK(copy_calls == 0);
#endif
    char output[64] = "previous";
    CHECK(tb_net_get_lan_ip(output, sizeof(output)) == -1);
    CHECK(!output[0]);
}

static void test_no_private_candidates(void) {
    reset_fixture();
    add_address("lo0", "127.0.0.1");
    add_address("bridge0", "169.254.3.1");
    add_address("en7", "169.254.3.2");
    add_address("en0", "8.8.8.8");
    add_address("en1", "172.32.0.1");
    add_address("awdl0", "169.254.4.1");
    add_address("llw0", "169.254.4.2");
    add_address("en9", "10.1.1.1");
    fake_sockaddrs[address_count - 1].sin_family = AF_INET6;
    struct tb_net_addresses addresses;
    CHECK(tb_net_get_addresses(&addresses) == 0);
    CHECK(!strcmp(addresses.tb_ip, "169.254.3.1"));
    CHECK(!strcmp(addresses.link_local_ip, "169.254.3.2"));
    CHECK(!addresses.lan_ip[0] && !addresses.ethernet_ip[0] && !addresses.wifi_ip[0]);
    CHECK(get_calls == 1 && free_calls == 1);
#if defined(__APPLE__)
    CHECK(copy_calls == 0 && role_queries == 0);
#endif
}

static void test_failures(void) {
    reset_fixture();
    CHECK(tb_net_get_addresses(NULL) == -1);
    CHECK(get_calls == 0);
    struct tb_net_addresses addresses;
    memset(&addresses, 0x7f, sizeof(addresses));
    get_failure = 1;
    CHECK(tb_net_get_addresses(&addresses) == -1);
    expect_empty(&addresses);
    CHECK(get_calls == 1 && free_calls == 0);
    reset_fixture();
    add_address("en0", "10.1.1.1");
    name_failure = fake_addresses[0].ifa_addr;
    CHECK(tb_net_get_addresses(&addresses) == 0);
    expect_empty(&addresses);
#if defined(__APPLE__)
    CHECK(copy_calls == 0);
    reset_fixture();
    copy_failure = 1;
    add_address("bridge0", "169.254.5.1");
    add_address("en7", "169.254.5.2");
    add_address("en0", "10.1.1.1");
    add_address("en1", "192.168.1.1");
    CHECK(tb_net_get_addresses(&addresses) == 0);
    CHECK(!strcmp(addresses.tb_ip, "169.254.5.1"));
    CHECK(!strcmp(addresses.link_local_ip, "169.254.5.2"));
    CHECK(!addresses.lan_ip[0] && !addresses.ethernet_ip[0] && !addresses.wifi_ip[0]);
    CHECK(copy_calls == 1 && role_queries == 0);
    CHECK(get_calls == 1 && free_calls == 1);
#endif
}

int main(void) {
    test_selection_and_legacy_getters();
    test_wifi_fallback_and_refresh();
    test_no_private_candidates();
    test_failures();
    printf("address discovery: %d checks passed (synthetic interfaces only)\n", checks);
    return 0;
}
