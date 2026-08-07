import Foundation

struct TBDiscoveredReceiver: Identifiable, Equatable {
    let serviceName: String
    let receiverName: String
    let preferredIP: String
    let thunderboltIP: String
    let usbIP: String
    let networkIP: String
    let ethernetIP: String
    let wifiIP: String
    let resolvedIPv4Addresses: [String]
    let panelSummary: String
    let version: String
    let supportsHEVCDecode: Bool
    let hostName: String?

    init(
        serviceName: String,
        receiverName: String,
        preferredIP: String,
        thunderboltIP: String,
        usbIP: String = "",
        networkIP: String,
        ethernetIP: String = "",
        wifiIP: String = "",
        resolvedIPv4Addresses: [String] = [],
        panelSummary: String,
        version: String,
        supportsHEVCDecode: Bool,
        hostName: String?
    ) {
        self.serviceName = serviceName
        self.receiverName = receiverName
        self.preferredIP = preferredIP
        self.thunderboltIP = thunderboltIP
        self.usbIP = usbIP
        self.networkIP = networkIP
        self.ethernetIP = ethernetIP
        self.wifiIP = wifiIP
        self.resolvedIPv4Addresses = resolvedIPv4Addresses
        self.panelSummary = panelSummary
        self.version = version
        self.supportsHEVCDecode = supportsHEVCDecode
        self.hostName = hostName
    }

    var id: String { "\(serviceName)|\(preferredIP)" }

    /// Bonjour service names survive link-local IP address changes after wake.
    /// Use this only for persisted receiver preferences, not Picker selection.
    var stableIdentity: String { "service:\(serviceName)" }

    var shortHostName: String? {
        guard let host = hostName, !host.isEmpty else { return nil }
        let stripped = host.hasSuffix(".") ? String(host.dropLast()) : host
        let components = stripped.split(separator: ".")
        guard let first = components.first, !first.isEmpty else { return nil }
        return String(first)
    }

    func ip(for transportKind: TBTransportKind, localInterfaceIP: String = "") -> String {
        switch transportKind {
        case .thunderboltBridge:
            return !thunderboltIP.isEmpty ? thunderboltIP : preferredIP
        case .networkLink:
            if localInterfaceIP.hasPrefix("169.254."), !usbIP.isEmpty {
                return usbIP
            }
            return !networkIP.isEmpty ? networkIP : preferredIP
        }
    }

    var displayText: String {
        var addresses: [(label: String, ip: String)] = []
        var seenIPs = Set<String>()
        func appendAddress(_ label: String, _ ip: String) {
            guard !ip.isEmpty, seenIPs.insert(ip).inserted else { return }
            addresses.append((label, ip))
        }
        appendAddress("TB", thunderboltIP)
        appendAddress("USB", usbIP)
        appendAddress("ETH", ethernetIP)
        appendAddress("Wi-Fi", wifiIP)
        appendAddress("NET", networkIP)

        let addressSummary: String
        if addresses.isEmpty {
            addressSummary = preferredIP
        } else if addresses.count == 1 {
            addressSummary = addresses[0].ip
        } else {
            addressSummary = addresses
                .map { "\($0.label) \($0.ip)" }
                .joined(separator: " · ")
        }

        let name: String
        if let host = shortHostName {
            name = "\(host) (\(addressSummary))"
        } else {
            name = addressSummary
        }

        if panelSummary.isEmpty {
            return name
        }
        return "\(name) · \(panelSummary)"
    }
}

final class TBReceiverDiscovery: NSObject, ObservableObject {
    @Published private(set) var receivers: [TBDiscoveredReceiver] = []

    private let browser = NetServiceBrowser()
    private var services: [String: NetService] = [:]

    override init() {
        super.init()
        browser.delegate = self
        start()
    }

    func refresh() {
        stop()
        start()
    }

    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private func start() {
        browser.searchForServices(ofType: "_targetbridge._tcp.", inDomain: "local.")
    }

    private func stop() {
        browser.stop()
        services.values.forEach { service in
            service.stop()
            service.delegate = nil
        }
        services.removeAll()
        receivers = []
    }

    private func upsertReceiver(from service: NetService) {
        guard let txtData = service.txtRecordData() else { return }
        let txt = NetService.dictionary(fromTXTRecord: txtData)

        func stringValue(_ key: String) -> String {
            guard let data = txt[key], !data.isEmpty else { return "" }
            return String(decoding: data, as: UTF8.self)
        }

        let receiverName = stringValue("name").isEmpty ? service.name : stringValue("name")
        let receiverIP = stringValue("ip")
        let thunderboltIP = stringValue("tbIP")
        let usbIP = stringValue("usbIP")
        let networkIP = stringValue("netIP")
        let ethernetIP = stringValue("ethernetIP")
        let wifiIP = stringValue("wifiIP")
        let resolvedIPv4Addresses = resolvedIPv4Addresses(from: service)
        let preferredIP = !receiverIP.isEmpty
            ? receiverIP
            : (!thunderboltIP.isEmpty
                ? thunderboltIP
                : (!usbIP.isEmpty
                    ? usbIP
                    : (!networkIP.isEmpty ? networkIP : (resolvedIPv4Addresses.first ?? ""))))
        guard !preferredIP.isEmpty else { return }

        let panelName = stringValue("panel")
        let panelWidth = stringValue("panelWidth")
        let panelHeight = stringValue("panelHeight")
        let version = stringValue("version")
        let supportsHEVCDecode = stringValue("supportsHEVCDecode") == "1"

        let panelSummary: String
        if !panelWidth.isEmpty, !panelHeight.isEmpty, !panelName.isEmpty {
            panelSummary = "\(panelName) (\(panelWidth)x\(panelHeight))"
        } else if !panelName.isEmpty {
            panelSummary = panelName
        } else if !panelWidth.isEmpty, !panelHeight.isEmpty {
            panelSummary = "\(panelWidth)x\(panelHeight)"
        } else {
            panelSummary = ""
        }

        let receiver = TBDiscoveredReceiver(
            serviceName: service.name,
            receiverName: receiverName,
            preferredIP: preferredIP,
            thunderboltIP: thunderboltIP,
            usbIP: usbIP,
            networkIP: networkIP,
            ethernetIP: ethernetIP,
            wifiIP: wifiIP,
            resolvedIPv4Addresses: resolvedIPv4Addresses,
            panelSummary: panelSummary,
            version: version,
            supportsHEVCDecode: supportsHEVCDecode,
            hostName: service.hostName
        )

        if let index = receivers.firstIndex(where: { $0.serviceName == receiver.serviceName }) {
            receivers[index] = receiver
        } else {
            receivers.append(receiver)
        }
        receivers.sort { lhs, rhs in
            if lhs.receiverName == rhs.receiverName {
                return lhs.preferredIP < rhs.preferredIP
            }
            return lhs.receiverName.localizedCaseInsensitiveCompare(rhs.receiverName) == .orderedAscending
        }
    }

    private func resolvedIPv4Addresses(from service: NetService) -> [String] {
        guard let addresses = service.addresses else { return [] }
        var result: [String] = []
        var seen = Set<String>()

        for addressData in addresses {
            let address: String? = addressData.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress,
                      rawBuffer.count >= MemoryLayout<sockaddr>.size
                else { return nil }
                let socketAddress = baseAddress.assumingMemoryBound(to: sockaddr.self)
                guard socketAddress.pointee.sa_family == UInt8(AF_INET) else { return nil }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let length = socklen_t(min(rawBuffer.count, Int(socketAddress.pointee.sa_len)))
                guard getnameinfo(
                    socketAddress,
                    length,
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 else { return nil }
                return String(cString: host)
            }
            if let address, seen.insert(address).inserted {
                result.append(address)
            }
        }

        return result.sorted()
    }

    private func removeService(_ service: NetService) {
        services.removeValue(forKey: service.name)
        receivers.removeAll { $0.serviceName == service.name }
    }

    deinit {
        stop()
    }
}

extension TBReceiverDiscovery: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        runOnMain { [weak self] in
            guard let self else { return }
            service.delegate = self
            services[service.name] = service
            service.resolve(withTimeout: 5)
            if !moreComing {
                objectWillChange.send()
            }
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        runOnMain { [weak self] in
            guard let self else { return }
            removeService(service)
            if !moreComing {
                objectWillChange.send()
            }
        }
    }
}

extension TBReceiverDiscovery: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        runOnMain { [weak self] in
            self?.upsertReceiver(from: sender)
        }
    }

    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        runOnMain { [weak self] in
            self?.upsertReceiver(from: sender)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        runOnMain { [weak self] in
            guard sender.txtRecordData() != nil else { return }
            self?.upsertReceiver(from: sender)
        }
    }
}
