import CoreAudio
import Foundation

/// Mutes the local default output while audio streams to a receiver.
///
/// ScreenCaptureKit captures system audio upstream of the output device, so a
/// stream plays on the local speakers and the receiver at once unless the Mac
/// is muted. Sessions claim the mute when their capture starts and release it
/// when they stop; the device is muted on the first claim and the original
/// state restored when the last claim goes away. A device the app muted itself
/// is the only thing it will unmute — if the user had already muted, or
/// unmutes by hand mid-stream, their choice stands.
final class TBLocalAudioMuteCoordinator: @unchecked Sendable {
    static let shared = TBLocalAudioMuteCoordinator()

    private let lock = NSLock()
    private var activeClaims = 0
    private var deviceToRestore: AudioDeviceID?

    func claim() {
        lock.lock()
        defer { lock.unlock() }
        activeClaims += 1
        guard activeClaims == 1 else { return }

        guard let device = Self.defaultOutputDevice(),
              Self.isMuted(device) == false,
              Self.setMuted(device, true)
        else {
            deviceToRestore = nil
            return
        }
        deviceToRestore = device
        NSLog("TargetBridge: muted local output while streaming audio")
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard activeClaims > 0 else { return }
        activeClaims -= 1
        guard activeClaims == 0, let device = deviceToRestore else { return }
        deviceToRestore = nil
        // Restore only if still muted: respects a manual unmute mid-stream.
        if Self.isMuted(device) == true, Self.setMuted(device, false) {
            NSLog("TargetBridge: restored local output after streaming")
        }
    }

    // MARK: - CoreAudio plumbing

    private static func mutePropertyAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func isMuted(_ device: AudioDeviceID) -> Bool? {
        var address = mutePropertyAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else {
            return nil
        }
        return muted != 0
    }

    private static func setMuted(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        var address = mutePropertyAddress()
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue
        else {
            return false
        }
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }
}
