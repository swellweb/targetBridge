import Foundation

/// Receives audio from the TargetBridge virtual output device.
///
/// The driver pushes whatever macOS routes to it as interleaved **Float32** stereo
/// at 48 kHz over loopback UDP — deliberately the receiver's exact wire format,
/// so these bytes are forwarded untouched. No resampling, no sample conversion,
/// and no capture session, which is why this path needs no microphone
/// permission.
final class TBAudioDriverReceiver {

    static let port = TBAudioWireFormat.Port.output
    /// The device UID the driver publishes; used to read its volume.
    static let deviceUID = "TargetBridgeAudioDevice_UID"

    private var socketFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.targetbridge.audiodriver.rx", qos: .userInitiated)
    private let onPCM: (Data) -> Void
    private(set) var isRunning = false

    init(onPCM: @escaping (Data) -> Void) {
        self.onPCM = onPCM
    }

    func start() -> Bool {
        guard !isRunning else { return true }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            TBLog.connection.error("audio driver rx: socket failed")
            return false
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        // Generous receive buffer: audio arrives in small datagrams and a brief
        // stall in our own processing must not drop the stream.
        var rcv: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.port.bigEndian
        addr.sin_addr.s_addr = inet_addr(TBAudioWireFormat.loopbackAddress)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            TBLog.connection.error("audio driver rx: bind \(Self.port, privacy: .public) failed (already running?)")
            close(fd)
            return false
        }

        socketFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.drain() }
        src.setCancelHandler { [fd] in close(fd) }
        source = src
        src.resume()
        isRunning = true
        TBLog.connection.info("audio driver rx: listening on \(Self.port, privacy: .public)")
        return true
    }

    func stop() {
        guard isRunning else { return }
        source?.cancel()
        source = nil
        socketFD = -1
        isRunning = false
        TBLog.connection.info("audio driver rx: stopped")
    }

    private func drain() {
        var buf = [UInt8](repeating: 0, count: TBAudioWireFormat.receiveBufferBytes)
        while true {
            let n = recv(socketFD, &buf, buf.count, 0)
            if n <= 0 { return }   // EAGAIN once the socket is empty
            // Already the wire format — forward verbatim. Trim any partial
            // trailing frame: a split frame would swap left and right for
            // everything after it, permanently.
            let usable = n - (n % TBAudioWireFormat.bytesPerFrame)
            guard usable > 0 else { continue }
            onPCM(Data(buf[0..<usable]))
        }
    }
}
