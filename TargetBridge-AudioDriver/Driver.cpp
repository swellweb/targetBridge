// TargetBridge audio driver — a virtual output device that forwards whatever
// macOS routes to it, so the receiver Mac's speakers can be chosen from the
// system's own Sound UI (and per app) rather than from a toggle in our app.
//
// Two deliberate differences from an off-the-shelf loopback device such as
// BlackHole:
//
//  1. The volume control reports its level but does NOT scale the samples.
//     A loopback device attenuates digitally before we ever capture the audio,
//     which throws away dynamic range *and* leaves the receiver's amplifier at
//     whatever it was — turning its slider down made the sound quieter twice
//     over. Here the level is published for the sender to read and apply as the
//     receiver's hardware volume, while the audio itself passes at unity.
//
//  2. Output audio is pushed straight to the sender over loopback UDP rather
//     than being looped back to an input, so selecting this device as *output*
//     never triggers a microphone permission prompt.
//
// The device also exposes an input stream carrying the receiver Mac's
// microphone, so that mic can be selected here like any local one. Audio for it
// arrives on a second UDP port and is buffered through a lock-free ring, since
// the realtime read callback cannot block.
//
// Built on libASPL (MIT, vendored under vendor/libASPL).

#include <aspl/Driver.hpp>

// VolumeCurve lives in libASPL's src/, not its public headers, but
// VolumeControl holds a unique_ptr to it — so subclassing VolumeControl needs
// the complete type for the implicit destructor. Hence src/ on the include path.
#include "VolumeCurve.hpp"

#include <CoreAudio/AudioServerPlugIn.h>
#include <os/log.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <ctime>
#include <memory>
#include <thread>
#include <vector>

namespace {

// ---- Wire format -------------------------------------------------------
//
// 48 kHz, stereo, 32-bit float, interleaved, native endian. This is CoreAudio's
// canonical format (kAudioFormatFlagsNativeFloatPacked), which is why it is
// used end to end: the audio server hands over the mix untouched, and the
// receiver's output device is float as well, so nothing quantises anywhere.
//
// Every size below is derived from these three numbers. Byte counts written out
// by hand silently change meaning when the sample size does — that is exactly
// how a "0.5 second" buffer became a quarter of a second when this moved from
// Int16 to Float32.
constexpr UInt32 kSampleRate     = 48000;
constexpr UInt32 kChannelCount   = 2;
constexpr UInt32 kBytesPerSample = sizeof(Float32);

constexpr size_t kBytesPerFrame  = kChannelCount * kBytesPerSample;
constexpr size_t kBytesPerSecond = kSampleRate * kBytesPerFrame;
constexpr size_t BytesForMs(size_t ms) { return kBytesPerSecond * ms / 1000; }

// ---- Loopback endpoints ------------------------------------------------
//
// Both ports are in IANA's dynamic/private range (49152-65535), which is the
// range reserved for exactly this: no registration, no collision with a
// registered service. Traffic never leaves the loopback interface.
constexpr const char* kSinkAddr = "127.0.0.1";

// Output audio, driver -> sender. The sender binds it; if nothing is listening
// the datagrams are dropped, so audio routed here while TargetBridge is closed
// is harmless rather than an error.
constexpr unsigned short kSinkPort = 51710;

// Microphone audio, sender -> driver, presented as this device's input stream
// so the receiver Mac's mic can be selected here like any local one.
constexpr unsigned short kMicPort = 51711;

// One datagram carries at most this much audio. Sized to stay well inside the
// loopback MTU so the kernel never fragments a packet: fragmentation would make
// a single lost fragment cost the whole datagram.
constexpr UInt32 kMaxDatagram = 1024;

// ---- Liveness ----------------------------------------------------------
//
// A virtual device that is still present but no longer carries audio is
// silently broken — sound just stops with no explanation — so when the sender
// disappears the device must go too.
//
// Detection is by probing kSinkPort, not by listening on a port of our own. The
// plug-in is hosted in a process we do not control, and a leftover host from a
// previous load can sit on a fixed port for minutes; bind() then fails with
// EADDRINUSE and a listener never recovers. Sending has no such failure mode,
// and a connected UDP socket surfaces ICMP port-unreachable as ECONNREFUSED
// (RFC 1122 s4.1.3.3) — so an unanswered probe *is* the "sender is gone" signal.
constexpr int kProbeIntervalUs = 1000 * 1000;   // 1 s between probes

// The ICMP reply is asynchronous: send() returns fine and the error is queued
// for the next call on the socket. Pause before looking for it.
constexpr int kProbeReplyWaitUs = 200 * 1000;   // 0.2 s

// Consecutive unanswered probes before the device is withdrawn. Three, so a
// single dropped probe cannot yank the user's output device away; at the
// interval above that is a ~3 s worst case, which is below the point where a
// listener starts wondering why the sound stopped.
constexpr int kProbeStrikes = 3;

// ---- Microphone buffering ----------------------------------------------
//
// The two ends run on independent 48 kHz clocks — the receiver's mic ADC and
// this Mac's audio device — with no shared reference, so drift accumulates one
// way forever and a ring that is merely large eventually runs full and stays
// full.
//
// Every tier of standard practice above the crudest (PulseAudio and PipeWire
// resample toward a target latency; WebRTC's NetEq tracks a target delay and
// time-stretches with WSOLA) shares one idea: pick a target and correct toward
// it. This does the cheap version — discard whole frames once the backlog
// passes the ceiling — which bounds delay and self-corrects drift in both
// directions, at the cost of one skip per drift period (minutes apart at
// typical tens of ppm). Resampling would remove even that, and is worth adding
// only if measurement shows the skips matter.
//
// 30 ms target: comfortably above the ~21 ms the receiver's own output buffer
// needs, so normal jitter does not starve us, and low enough to stay under the
// ~100 ms where conversational delay becomes noticeable.
constexpr size_t kMicTargetBytes = BytesForMs(30);
constexpr size_t kMicMaxBytes    = BytesForMs(60);   // 2x target: correct late, not constantly

// Capacity, not latency — headroom for a scheduling stall. The ceiling above is
// what actually governs delay.
constexpr size_t kMicRingBytes = BytesForMs(500);

// The plug-in is hosted by audiomxd, so stderr goes nowhere useful; os_log is
// the only way to see what it is doing. Read with:
//   log stream --predicate 'subsystem == "com.targetbridge.audiodriver"'
static os_log_t TBLog()
{
    static os_log_t log = os_log_create("com.targetbridge.audiodriver", "driver");
    return log;
}

static double MonotonicSeconds()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return double(ts.tv_sec) + double(ts.tv_nsec) / 1e9;
}


constexpr const char* kDeviceName = "TargetBridge";
constexpr const char* kDeviceUID = "TargetBridgeAudioDevice_UID";
constexpr const char* kManufacturer = "TargetBridge";

// Volume control that publishes a level without touching the audio. See (1) above.
class ReportingOnlyVolumeControl : public aspl::VolumeControl
{
public:
    using aspl::VolumeControl::VolumeControl;

    // Deliberately empty: the level is metadata for the sender, not gain to
    // apply here. Overriding this is the entire reason for a custom control.
    void ApplyProcessing(Float32*, UInt32, UInt32) const override
    {
    }
};


// Single-producer / single-consumer ring. The producer is a plain socket
// thread; the consumer is the realtime I/O callback, which must never block or
// allocate — hence atomics and a fixed buffer rather than a mutex.
class MicRing
{
public:
    MicRing() : buffer_(kMicRingBytes, 0) {}

    void Write(const UInt8* data, size_t size)
    {
        // Whole frames only. A partial frame would shift every following sample
        // by one channel, swapping left and right for the rest of the stream —
        // and it would never resynchronise.
        size -= size % kBytesPerFrame;
        if (size == 0) {
            return;
        }

        const size_t writePos = write_.load(std::memory_order_relaxed);
        const size_t readPos = read_.load(std::memory_order_acquire);
        const size_t used = writePos - readPos;
        const size_t free = kMicRingBytes - used;
        if (size > free) {
            // Producer outran the consumer: drop this packet rather than
            // overwrite audio the RT thread has not read yet.
            return;
        }
        for (size_t i = 0; i < size; ++i) {
            buffer_[(writePos + i) % kMicRingBytes] = data[i];
        }
        write_.store(writePos + size, std::memory_order_release);
    }

    // Fills `size` bytes, padding with silence when starved. Never blocks.
    void Read(UInt8* out, size_t size)
    {
        size_t readPos = read_.load(std::memory_order_relaxed);
        const size_t writePos = write_.load(std::memory_order_acquire);
        size_t available = writePos - readPos;

        // Enforce the latency ceiling here, in the consumer, rather than in
        // Write: only this thread may move read_, and reaching across from the
        // producer would break the single-reader/single-writer contract that
        // makes the lock-free access safe.
        //
        // Skipping the OLDEST audio is the whole point. Refusing the newest —
        // the obvious-looking choice — keeps a full buffer full, so delay pins
        // at the ring depth permanently and never recovers.
        if (available > kMicMaxBytes) {
            size_t drop = available - kMicTargetBytes;
            drop -= drop % kBytesPerFrame;
            readPos += drop;
            available -= drop;
        }

        const size_t take = std::min(size, available);
        for (size_t i = 0; i < take; ++i) {
            out[i] = buffer_[(readPos + i) % kMicRingBytes];
        }
        if (take < size) {
            // Underrun: silence is the right filler — it is inaudible, whereas
            // repeating the last buffer would sound like a stutter.
            memset(out + take, 0, size - take);
        }
        read_.store(readPos + take, std::memory_order_release);
    }

private:
    std::vector<UInt8> buffer_;
    std::atomic<size_t> write_ { 0 };
    std::atomic<size_t> read_ { 0 };
};


// Marks the device not-alive when the sender stops heartbeating, and alive
// again when it returns. Runs for the driver's whole lifetime, independent of
// I/O — the interesting case (sender quits while music is playing) is precisely
// when we must react without being driven by the audio callback.
class LivenessWatcher
{
public:
    void Start(std::shared_ptr<aspl::Plugin> plugin, std::shared_ptr<aspl::Device> device)
    {
        os_log_error(TBLog(), "liveness: starting watcher");
        plugin_ = std::move(plugin);
        device_ = std::move(device);
        stop_.store(false);
        thread_ = std::thread([this] { Run(); });
    }

    void Stop()
    {
        stop_.store(true);
        const int fd = socket_.exchange(-1);
        if (fd != -1) {
            close(fd);
        }
        if (thread_.joinable()) {
            thread_.join();
        }
    }

private:
    void Run()
    {
        const int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (fd == -1) {
            os_log_error(TBLog(), "liveness: socket() failed errno=%{public}d", errno);
            return;
        }

        // connect() on a datagram socket only fixes the peer; nothing is sent
        // and no port is claimed. It is what makes the kernel report the peer's
        // ICMP unreachable to us instead of discarding it.
        sockaddr_in addr = {};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(kSinkPort);
        inet_pton(AF_INET, kSinkAddr, &addr.sin_addr);
        if (connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == -1) {
            os_log_error(TBLog(), "liveness: connect failed errno=%{public}d", errno);
            close(fd);
            return;
        }
        socket_.store(fd);
        os_log_error(TBLog(), "liveness: probing %{public}u", kSinkPort);

        // Start alive: the device is usable until proven otherwise, so a driver
        // installed before the sender ever runs still behaves normally.
        bool alive = true;
        int strikes = 0;

        while (!stop_.load()) {
            // One byte, because the sender's reader discards anything shorter
            // than a sample frame — so the probe costs it nothing to ignore.
            const UInt8 probe = 0;
            bool refused = false;
            if (send(fd, &probe, sizeof(probe), 0) == -1 && errno == ECONNREFUSED) {
                refused = true;   // error queued from the previous round
            }
            Nap(kProbeReplyWaitUs);
            UInt8 sink[64];   // probe replies are never read for content
            if (recv(fd, sink, sizeof(sink), MSG_DONTWAIT) == -1 && errno == ECONNREFUSED) {
                refused = true;
            }

            // Require several in a row: one lost probe should not yank the
            // user's output device out from under them.
            strikes = refused ? strikes + 1 : 0;
            const bool shouldBeAlive = strikes < kProbeStrikes;

            if (shouldBeAlive != alive) {
                alive = shouldBeAlive;
                os_log_error(TBLog(), "liveness: sender %{public}s -> device %{public}s",
                             alive ? "returned" : "gone",
                             alive ? "published" : "withdrawn");
                // Remove the device outright rather than only marking it
                // not-alive. Real hardware *disappears* when unplugged, and that
                // is the event macOS reliably reacts to by moving the user to
                // another output; a device that merely reports not-alive can be
                // left selected and silent.
                if (auto plugin = plugin_) {
                    if (auto device = device_) {
                        if (alive) {
                            plugin->AddDevice(device);
                        } else {
                            plugin->RemoveDevice(device);
                        }
                    }
                }
            }

            Nap(kProbeIntervalUs - kProbeReplyWaitUs);
        }

        const int held = socket_.exchange(-1);
        if (held != -1) {
            close(held);
        }
    }

    /// Sleep in slices so Stop() is not left waiting a whole probe interval.
    void Nap(int microseconds)
    {
        // Sleep in slices so Stop() waits at most this long rather than a whole
        // probe interval.
        constexpr int kSlice = 100 * 1000;   // 0.1 s
        while (microseconds > 0 && !stop_.load()) {
            const int chunk = microseconds < kSlice ? microseconds : kSlice;
            usleep(static_cast<useconds_t>(chunk));
            microseconds -= chunk;
        }
    }

    std::shared_ptr<aspl::Plugin> plugin_;
    std::shared_ptr<aspl::Device> device_;
    std::thread thread_;
    std::atomic<int> socket_ { -1 };
    std::atomic<bool> stop_ { false };
};

class TargetBridgeHandler : public aspl::ControlRequestHandler,
                            public aspl::IORequestHandler
{
public:
    // Control thread, before the first I/O request.
    OSStatus OnStartIO() override
    {
        StartMicReceiver();

        const int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (fd == -1) {
            return kAudioHardwareUnspecifiedError;
        }

        sockaddr_in addr = {};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(kSinkPort);
        inet_pton(AF_INET, kSinkAddr, &addr.sin_addr);

        // connect() on a datagram socket just fixes the peer, so the realtime
        // path can send() without carrying an address around.
        if (connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == -1) {
            close(fd);
            return kAudioHardwareUnspecifiedError;
        }

        socket_.store(fd);
        return kAudioHardwareNoError;
    }

    // Control thread, after the last I/O request.
    void OnStopIO() override
    {
        StopMicReceiver();
        const int fd = socket_.exchange(-1);
        if (fd != -1) {
            close(fd);
        }
    }

    // Realtime I/O thread: hand the client whatever mic audio has arrived.
    void OnReadClientInput(const std::shared_ptr<aspl::Client>& client,
        const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        void* bytes,
        UInt32 bytesCount) override
    {
        micRing_.Read(reinterpret_cast<UInt8*>(bytes), bytesCount);
    }

    // Realtime I/O thread. Must not block, allocate, or lock — hence
    // MSG_DONTWAIT and no error handling beyond ignoring the result: a full or
    // absent receiver must never stall the audio thread.
    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        const void* buff,
        UInt32 buffBytesSize) override
    {
        const int fd = socket_.load();
        if (fd == -1) {
            return;
        }

        auto* bytes = reinterpret_cast<const UInt8*>(buff);
        while (buffBytesSize != 0) {
            const UInt32 chunk = std::min(buffBytesSize, kMaxDatagram);
            (void)send(fd, bytes, chunk, MSG_DONTWAIT);
            bytes += chunk;
            buffBytesSize -= chunk;
        }
    }

private:
    void StartMicReceiver()
    {
        if (micThread_.joinable()) {
            return;
        }
        micStop_.store(false);
        micThread_ = std::thread([this] { MicReceiveLoop(); });
    }

    void StopMicReceiver()
    {
        micStop_.store(true);
        const int fd = micSocket_.exchange(-1);
        if (fd != -1) {
            // Closing the socket unblocks the recv() in the loop.
            close(fd);
        }
        if (micThread_.joinable()) {
            micThread_.join();
        }
    }

    void MicReceiveLoop()
    {
        const int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (fd == -1) {
            return;
        }
        int yes = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

        sockaddr_in addr = {};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(kMicPort);
        inet_pton(AF_INET, kSinkAddr, &addr.sin_addr);
        // A leftover plug-in host from a previous load can hold this port for
        // minutes. Retry rather than giving up for the lifetime of the process,
        // which is how the mic silently never worked.
        bool bound = false;
        // One attempt per second for a minute: long enough to outlast a
        // leftover host holding the port, short enough to give up rather than
        // spin for the life of the process.
        constexpr int kBindAttempts = 60;
        for (int attempt = 0; attempt < kBindAttempts && !micStop_.load(); ++attempt) {
            if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0) {
                bound = true;
                break;
            }
            if (attempt == 0) {
                os_log_error(TBLog(), "mic: bind(%{public}u) failed errno=%{public}d, retrying",
                             kMicPort, errno);
            }
            sleep(1);
        }
        if (!bound) {
            os_log_error(TBLog(), "mic: gave up binding %{public}u", kMicPort);
            close(fd);
            return;
        }
        micSocket_.store(fd);
        os_log_error(TBLog(), "mic: listening on %{public}u", kMicPort);

        UInt8 buf[2 * kMaxDatagram];   // one datagram, with slack
        while (!micStop_.load()) {
            const ssize_t n = recv(fd, buf, sizeof(buf), 0);
            if (n <= 0) {
                break;   // socket closed by StopMicReceiver, or a fatal error
            }
            micRing_.Write(buf, static_cast<size_t>(n));
        }

        const int held = micSocket_.exchange(-1);
        if (held != -1) {
            close(held);
        }
    }

    std::atomic<int> socket_ { -1 };
    MicRing micRing_;
    std::thread micThread_;
    std::atomic<int> micSocket_ { -1 };
    std::atomic<bool> micStop_ { false };
};

std::shared_ptr<aspl::Driver> CreateTargetBridgeDriver()
{
    os_log_error(TBLog(), "driver: creating device");
    auto context = std::make_shared<aspl::Context>();

    aspl::DeviceParameters deviceParams;
    deviceParams.Name = kDeviceName;
    deviceParams.DeviceUID = kDeviceUID;
    deviceParams.Manufacturer = kManufacturer;
    deviceParams.SampleRate = kSampleRate;
    deviceParams.ChannelCount = kChannelCount;
    // Mix all clients together: this is a normal output device, so several apps
    // may be playing to it at once.
    deviceParams.EnableMixing = true;

    auto device = std::make_shared<aspl::Device>(context, deviceParams);

    // Output only — no input stream, so no microphone permission. See (2) above.
    // AddStreamAsync (rather than AddStreamWithControlsAsync) so no default
    // volume control is created; we attach our own reporting-only one instead.
    //
    // Pin the stream format explicitly. libASPL defaults to 44100 Hz Int16, and
    // OnWriteMixedOutput hands over the *stream's native format* — so leaving
    // OnWriteMixedOutput hands over the stream's *native* format — so leaving
    // the default while treating the bytes as 48 kHz Float32 produced noise.
    // Matching the receiver's wire format here means no conversion at all.
    aspl::StreamParameters streamParams;
    streamParams.Direction = aspl::Direction::Output;
    streamParams.Format.mSampleRate = kSampleRate;
    streamParams.Format.mFormatID = kAudioFormatLinearPCM;
    streamParams.Format.mFormatFlags = kAudioFormatFlagIsFloat
                                     | kAudioFormatFlagsNativeEndian
                                     | kAudioFormatFlagIsPacked;
    streamParams.Format.mBitsPerChannel = 32;
    streamParams.Format.mChannelsPerFrame = kChannelCount;
    streamParams.Format.mBytesPerFrame = kChannelCount * kBytesPerSample;
    streamParams.Format.mFramesPerPacket = 1;
    streamParams.Format.mBytesPerPacket = kChannelCount * kBytesPerSample;
    auto stream = device->AddStreamAsync(streamParams);

    aspl::VolumeControlParameters volumeParams;
    volumeParams.Scope = kAudioObjectPropertyScopeOutput;
    auto volume = std::make_shared<ReportingOnlyVolumeControl>(context, volumeParams);
    // Both calls are required and do different things: AddVolumeControlAsync
    // *publishes* the control as an audio object, which is what makes macOS
    // draw a volume slider for the device; AttachVolumeControl wires it into
    // the stream so ApplyProcessing runs (ours deliberately does nothing).
    // Attaching without publishing leaves the slider greyed out.
    device->AddVolumeControlAsync(volume);
    stream->AttachVolumeControl(volume);

    // Publish a mute control too, so the mute key and the muted state work.
    auto mute = device->AddMuteControlAsync(kAudioObjectPropertyScopeOutput);
    stream->AttachMuteControl(mute);

    // Input stream carrying the receiver Mac's microphone. Same format as the
    // output side, so nothing converts anywhere.
    aspl::StreamParameters micParams = streamParams;
    micParams.Direction = aspl::Direction::Input;
    device->AddStreamAsync(micParams);

    auto handler = std::make_shared<TargetBridgeHandler>();
    device->SetControlHandler(handler);
    device->SetIOHandler(handler);

    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(device);

    // Lives as long as the driver; the audio server keeps the plug-in loaded.
    static LivenessWatcher watcher;
    watcher.Start(plugin, device);

    return std::make_shared<aspl::Driver>(context, plugin);
}

} // namespace

extern "C" void* TargetBridgeAudioDriverFactory(CFAllocatorRef, CFUUIDRef typeUUID)
{
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }

    // Held for the lifetime of the process: coreaudiod keeps the driver loaded.
    static std::shared_ptr<aspl::Driver> driver = CreateTargetBridgeDriver();

    return driver->GetReference();
}
