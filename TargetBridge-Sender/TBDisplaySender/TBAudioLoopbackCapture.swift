import AVFoundation
import CoreAudio
import Foundation

/// Where a session takes the audio it relays to the receiver.
enum TBAudioSource: String, CaseIterable, Identifiable, Sendable {
    /// ScreenCaptureKit system audio, the original pipeline.
    case systemCapture = "system"
    /// Only what macOS sends to the TargetBridge Audio output.
    case outputDevice = "device"

    var id: String { rawValue }

    func title(_ language: TBDisplaySenderLanguage) -> String {
        switch self {
        case .systemCapture:
            return TBDisplaySenderL10n.text("sender.audio_source.system", language)
        case .outputDevice:
            return TBDisplaySenderL10n.text("sender.audio_source.device", language)
        }
    }
}

/// Reads the input side of the "TargetBridge Audio" device, which carries
/// whatever macOS sends to that output, as S16 interleaved 48 kHz stereo.
final class TBAudioLoopbackCapture: @unchecked Sendable {
    typealias Handler = @Sendable (Data) -> Void

    static let shared = TBAudioLoopbackCapture()
    static let deviceUID = "com.targetbridge.audio.device"

    private static let preferredBufferFrames: UInt32 = 1024

    // AudioDeviceStop can wait for the running I/O cycle, so the I/O block only
    // ever takes handlerLock, never lifecycleLock.
    private let lifecycleLock = NSLock()
    private let handlerLock = NSLock()
    private var handlers: [UUID: Handler] = [:]
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    private init() {}

    static var isDriverInstalled: Bool {
        findDevice() != nil
    }

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    func subscribe(_ handler: @escaping Handler) -> UUID? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        let id = UUID()
        handlerLock.lock()
        handlers[id] = handler
        handlerLock.unlock()

        if ioProcID == nil, !startIO() {
            removeHandler(id)
            return nil
        }
        return id
    }

    func unsubscribe(_ id: UUID) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        if removeHandler(id) == 0 {
            stopIO()
        }
    }

    @discardableResult
    private func removeHandler(_ id: UUID) -> Int {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        handlers[id] = nil
        return handlers.count
    }

    private func startIO() -> Bool {
        guard let device = Self.findDevice() else { return false }

        var bufferFrames = Self.preferredBufferFrames
        var bufferAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectSetPropertyData(
            device,
            &bufferAddress,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &bufferFrames
        )

        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) {
            [weak self] _, inputData, _, _, _ in
            self?.handleInput(inputData)
        }
        guard createStatus == noErr, let procID else {
            NSLog("TargetBridge: could not create audio IO proc: %d", createStatus)
            return false
        }

        let startStatus = AudioDeviceStart(device, procID)
        guard startStatus == noErr else {
            NSLog("TargetBridge: could not start audio device: %d", startStatus)
            AudioDeviceDestroyIOProcID(device, procID)
            return false
        }

        deviceID = device
        ioProcID = procID
        return true
    }

    private func stopIO() {
        guard let procID = ioProcID else { return }
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)
        ioProcID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    private func handleInput(_ inputData: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let buffer = buffers.first,
              buffer.mNumberChannels == 2,
              let source = buffer.mData?.assumingMemoryBound(to: Float32.self) else { return }

        let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
        guard sampleCount > 0 else { return }

        var isSilent = true
        var data = Data(count: sampleCount * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { rawBytes in
            let target = rawBytes.bindMemory(to: Int16.self)
            for index in 0..<sampleCount {
                let sample = source[index]
                if sample != 0 { isSilent = false }
                target[index] = Int16(max(-1, min(1, sample)) * 32767).littleEndian
            }
        }
        guard !isSilent else { return }

        handlerLock.lock()
        let currentHandlers = Array(handlers.values)
        handlerLock.unlock()

        for handler in currentHandlers {
            handler(data)
        }
    }

    private static func findDevice() -> AudioObjectID? {
        let uid = deviceUID as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafePointer(to: uid) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPointer,
                &size,
                &device
            )
        }
        guard status == noErr, device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device
    }
}
