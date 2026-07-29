import Foundation

/// The one description of how audio is represented between the virtual audio
/// driver, the sender and the receiver.
///
/// 48 kHz, stereo, 32-bit float, interleaved, native endian — CoreAudio's
/// canonical format (`kAudioFormatFlagsNativeFloatPacked`). Chosen so the audio
/// server hands the mix over untouched and the receiver's output device takes it
/// untouched, with no quantisation at either end.
///
/// Everything here is derived rather than written out. A byte count spelled as a
/// literal silently changes meaning when the sample size does, which is how a
/// "half second" buffer quietly became a quarter of a second when this path
/// moved from Int16 to Float32.
///
/// The C side of these values lives in `TargetBridge-AudioDriver/Driver.cpp`
/// and `TargetBridge-Receiver/TBReceiverC/src/proto.h`; the three must agree.
enum TBAudioWireFormat {

    static let sampleRate = 48000
    static let channelCount = 2
    static let bytesPerSample = MemoryLayout<Float32>.size

    static let bytesPerFrame = channelCount * bytesPerSample
    static let bytesPerSecond = sampleRate * bytesPerFrame

    static func bytes(forMilliseconds ms: Int) -> Int { bytesPerSecond * ms / 1000 }

    /// Loopback ports, both inside IANA's dynamic/private range (49152–65535) —
    /// the range meant for exactly this: no registration, no clash with a
    /// registered service. Traffic never leaves the loopback interface.
    enum Port {
        /// Output audio, driver → sender.
        static let output: UInt16 = 51710
        /// Microphone audio, sender → driver.
        static let microphone: UInt16 = 51711
    }

    static let loopbackAddress = "127.0.0.1"

    /// Largest datagram written to the loopback sockets. Comfortably inside the
    /// loopback MTU so the kernel never fragments one, and a whole number of
    /// frames so a datagram boundary is never a frame boundary — a split frame
    /// would swap left and right for everything after it.
    static let maxDatagram = 1024

    /// Read buffer for a single datagram, with slack.
    static let receiveBufferBytes = maxDatagram * 4

    /// Scale factors for the Int16 fallback used with peers too old for float.
    ///
    /// The asymmetry is deliberate and conventional: two's-complement Int16 runs
    /// −32768…+32767, so widening divides by 32768 to map the full negative rail
    /// to −1.0, while narrowing multiplies by 32767 and clamps, so +1.0 cannot
    /// wrap to the negative rail.
    enum Int16Scale {
        static let toFloat: Float32 = 32768.0
        static let fromFloat: Float32 = 32767.0
    }
}
