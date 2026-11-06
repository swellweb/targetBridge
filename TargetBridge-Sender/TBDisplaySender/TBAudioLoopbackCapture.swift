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
    typealias AudioHandler = @Sendable (Data) -> Void
    typealias VolumeHandler = @Sendable (Double) -> Void

    private struct Subscriber {
        let audio: AudioHandler
        let volume: VolumeHandler
    }

    static let shared = TBAudioLoopbackCapture()
    static let deviceUID = "com.targetbridge.audio.device"

    private static let preferredBufferFrames: UInt32 = 1024
    private static let volumeSelectors = [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute]

    // AudioDeviceStop can wait for the running I/O cycle, so the I/O block only
    // ever takes handlerLock, never lifecycleLock.
    private let lifecycleLock = NSLock()
    private let handlerLock = NSLock()
    private var subscribers: [UUID: Subscriber] = [:]
    private let volumeQueue = DispatchQueue(label: "targetbridge.audio.volume")
    private var volumeListener: AudioObjectPropertyListenerBlock?
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

    func subscribe(audio: @escaping AudioHandler, volume: @escaping VolumeHandler) -> UUID? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        let id = UUID()
        handlerLock.lock()
        subscribers[id] = Subscriber(audio: audio, volume: volume)
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
        subscribers[id] = nil
        return subscribers.count
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

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.publishVolume(of: device)
        }
        for selector in Self.volumeSelectors {
            var address = Self.outputAddress(selector)
            AudioObjectAddPropertyListenerBlock(device, &address, volumeQueue, listener)
        }
        volumeListener = listener
        return true
    }

    private func stopIO() {
        guard let procID = ioProcID else { return }
        if let listener = volumeListener {
            for selector in Self.volumeSelectors {
                var address = Self.outputAddress(selector)
                AudioObjectRemovePropertyListenerBlock(deviceID, &address, volumeQueue, listener)
            }
            volumeListener = nil
        }
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
        let currentSubscribers = Array(subscribers.values)
        handlerLock.unlock()

        for subscriber in currentSubscribers {
            subscriber.audio(data)
        }
    }

    private func publishVolume(of device: AudioObjectID) {
        guard let level = Self.outputLevel(of: device) else { return }

        handlerLock.lock()
        let currentSubscribers = Array(subscribers.values)
        handlerLock.unlock()

        for subscriber in currentSubscribers {
            subscriber.volume(level)
        }
    }

    /// The device's volume as set on this Mac, or 0 while muted.
    static func currentOutputLevel() -> Double? {
        findDevice().flatMap(outputLevel(of:))
    }

    private static func outputLevel(of device: AudioObjectID) -> Double? {
        var volumeAddress = outputAddress(kAudioDevicePropertyVolumeScalar)
        var volume: Float32 = 0
        var volumeSize = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &volumeSize, &volume) == noErr else {
            return nil
        }

        var muteAddress = outputAddress(kAudioDevicePropertyMute)
        var muted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &muteSize, &muted) == noErr, muted != 0 {
            return 0
        }
        return Double(volume)
    }

    private static func outputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
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
