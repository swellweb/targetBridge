import CoreAudio
import Foundation

/// Stops the Mac being left pointed at a silent device.
///
/// Once the user selects TargetBridge as their output it stays selected after
/// the session ends — the device is still there, so macOS has no reason to
/// switch away and sound simply disappears until someone works out why. This
/// watches which device is default, remembers the last one that wasn't ours,
/// and puts it back when streaming stops.
///
/// A lock-guarded singleton rather than statics: the CoreAudio listener fires
/// on an arbitrary thread, so the remembered device is genuinely shared state.
final class TBDefaultOutputGuard: @unchecked Sendable {

    static let shared = TBDefaultOutputGuard()

    private let lock = NSLock()
    private var previousDeviceID: AudioDeviceID?
    private var listening = false

    private init() {}

    /// Fresh each time: the CoreAudio calls take it `inout`, so a shared
    /// instance would be mutable state for no benefit.
    private func defaultOutputAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func currentDefaultOutput() -> AudioDeviceID? {
        var addr = defaultOutputAddress()
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private func uid(of device: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cf: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &cf) == noErr else { return nil }
        return cf as String?
    }

    private func isOurs(_ device: AudioDeviceID) -> Bool {
        uid(of: device) == TBAudioDriverReceiver.deviceUID
    }

    private func noteCurrentDefault() {
        guard let device = currentDefaultOutput(), !isOurs(device) else { return }
        lock.lock()
        previousDeviceID = device
        lock.unlock()
    }

    /// Begin tracking. Safe to call repeatedly.
    func begin() {
        noteCurrentDefault()

        lock.lock()
        let alreadyListening = listening
        listening = true
        lock.unlock()
        guard !alreadyListening else { return }

        var addr = defaultOutputAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.noteCurrentDefault()
        }
        _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                &addr, nil, block)
    }

    /// Any output device that isn't ours, preferring the built-in speakers.
    ///
    /// Needed because the common case has no history to fall back on: if
    /// TargetBridge was already the default when the app launched — which it
    /// will be for anyone using this daily — we never observed a different
    /// device, so there is nothing "previous" to restore. Without this the
    /// guard silently did nothing precisely when it was most needed.
    private func fallbackDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &ids) == noErr else { return nil }

        var firstUsable: AudioDeviceID?
        for id in ids where !isOurs(id) {
            // Must actually have output channels — input-only devices and other
            // virtual endpoints would be a pointless place to send audio.
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { continue }

            if let uid = uid(of: id), uid.contains("BuiltInSpeakerDevice") {
                return id   // the sensible default
            }
            if firstUsable == nil { firstUsable = id }
        }
        return firstUsable
    }

    /// If the Mac is currently pointed at our device, point it back at whatever
    /// it was using before. No-op when the user is on some other device, so a
    /// deliberate choice is never overridden.
    func restoreIfSelected() {
        guard let current = currentDefaultOutput(), isOurs(current) else { return }

        lock.lock()
        let remembered = previousDeviceID
        lock.unlock()

        guard var target = remembered ?? fallbackDevice(), target != current else {
            TBLog.connection.info("audio: TargetBridge selected but no other output device to fall back to")
            return
        }

        var addr = defaultOutputAddress()
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &addr, 0, nil, size, &target)
        if status == noErr {
            TBLog.connection.info("audio: output restored to device \(target, privacy: .public) so sound is not left silent")
        } else {
            TBLog.connection.error("audio: failed to restore output device (\(status, privacy: .public))")
        }
    }
}
