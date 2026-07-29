import Foundation

/// Forwards the receiver Mac's microphone into the TargetBridge audio driver.
///
/// The driver exposes an input stream and listens on a loopback UDP port; this
/// just relays the PCM that arrives over the wire. Keeping the relay here rather
/// than having the driver talk to the network means the driver stays a dumb,
/// realtime-safe endpoint that knows nothing about sessions or reconnects.
final class TBMicForwarder {

    /// Must match `kMicPort` in TargetBridge-AudioDriver/Driver.cpp.
    private static let port = TBAudioWireFormat.Port.microphone

    private var fd: Int32 = -1

    init?() {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.port.bigEndian
        addr.sin_addr.s_addr = inet_addr(TBAudioWireFormat.loopbackAddress)
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else { close(s); return nil }
        fd = s
    }

    deinit { stop() }

    func stop() {
        if fd >= 0 { close(fd); fd = -1 }
    }

    /// Datagrams are capped so a large frame cannot exceed the UDP limit, and
    /// sent non-blocking: if the driver is not running the packets are simply
    /// discarded, which is the correct behaviour for live audio.
    func forward(_ pcm: Data) {
        guard fd >= 0, !pcm.isEmpty else { return }
        pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            // Whole frames per datagram: the driver discards a trailing
            // partial frame, so a chunk that split one would desynchronise the
            // channels for the rest of the stream.
            let chunk = TBAudioWireFormat.maxDatagram
                      - (TBAudioWireFormat.maxDatagram % TBAudioWireFormat.bytesPerFrame)
            while offset < raw.count {
                let n = min(chunk, raw.count - offset)
                _ = send(fd, base.advanced(by: offset), n, MSG_DONTWAIT)
                offset += n
            }
        }
    }
}
