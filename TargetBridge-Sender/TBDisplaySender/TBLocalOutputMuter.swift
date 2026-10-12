import CoreAudio
import Foundation

/// Keeps this Mac's default output device muted while a session relays audio,
/// and puts it back the way it was afterwards.
///
/// Relayed audio is captured ahead of the output device (see docs/audio.md),
/// so muting here silences the sender's speakers without touching what the
/// receiver plays. Only the mute flag is changed — never the volume — so the
/// user's level survives the session untouched.
///
/// If the default output device changes mid-session (headphones plugged in,
/// an AirPlay target picked), the previous device is restored and the new one
/// muted, so exactly one device is ever held muted by this class.
@MainActor
final class TBLocalOutputMuter {
    private struct HeldDevice {
        let id: AudioDeviceID
        /// Only elements successfully changed from unmuted to muted.
        let elements: [AudioObjectPropertyElement]
    }

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var held: HeldDevice?
    private var listener: AudioObjectPropertyListenerBlock?
    private(set) var isActive = false

    func activate() {
        guard !isActive else { return }
        isActive = true
        muteDefaultOutputDevice()
        installDefaultDeviceListener()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        removeDefaultDeviceListener()
        restoreHeldDevice()
    }

    // MARK: - Default device tracking

    private func installDefaultDeviceListener() {
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.defaultOutputDeviceChanged()
            }
        }
        var address = Self.defaultOutputAddress
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        if status == noErr {
            listener = block
        } else {
            TBLog.audio.warning("local output muter: default-device listener failed (\(status))")
        }
    }

    private func removeDefaultDeviceListener() {
        guard let listener else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        self.listener = nil
    }

    private func defaultOutputDeviceChanged() {
        guard isActive else { return }
        let current = Self.defaultOutputDevice()
        guard current != held?.id else { return }
        restoreHeldDevice()
        muteDefaultOutputDevice()
    }

    // MARK: - Mute / restore

    private func muteDefaultOutputDevice() {
        guard held == nil else { return }
        guard let device = Self.defaultOutputDevice() else {
            TBLog.audio.warning("local output muter: no default output device")
            return
        }
        let elements = Self.settableMuteElements(of: device)
        guard !elements.isEmpty else {
            TBLog.audio.warning("local output muter: device \(device) has no mute control")
            return
        }
        let changed = TBOutputMuteRestoration.mute(
            elements: elements,
            read: { Self.muteState(device, element: $0) },
            write: { Self.setMuted($1, device, element: $0) }
        )
        held = HeldDevice(id: device, elements: changed)
        TBLog.audio.info("local output muter: muted device \(device) (changed elements: \(changed.count))")
    }

    private func restoreHeldDevice() {
        guard let held else { return }
        self.held = nil
        TBOutputMuteRestoration.restore(
            changedElements: held.elements,
            read: { Self.muteState(held.id, element: $0) },
            write: { Self.setMuted($1, held.id, element: $0) }
        )
        TBLog.audio.info("local output muter: restored device \(held.id)")
    }

    // MARK: - CoreAudio helpers

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = defaultOutputAddress
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func muteAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
    }

    /// The main mute element when the device has one, otherwise the left and
    /// right channel elements — the same fallback the receiver uses for volume.
    private static func settableMuteElements(of device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        if isMuteSettable(device, element: kAudioObjectPropertyElementMain) {
            return [kAudioObjectPropertyElementMain]
        }
        return [1, 2].filter { isMuteSettable(device, element: $0) }
    }

    private static func isMuteSettable(_ device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        var address = muteAddress(element)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private static func muteState(_ device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool? {
        var address = muteAddress(element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func setMuted(_ muted: Bool, _ device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        var address = muteAddress(element)
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        if status != noErr {
            TBLog.audio.warning("local output muter: set mute=\(muted) on \(device)/\(element) failed (\(status))")
        }
        return status == noErr
    }
}
