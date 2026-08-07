import CoreAudio
import Foundation

/// Watches a CoreAudio device's volume and mute, and reports changes.
///
/// Point the Mac's output at the loopback device we capture, and this makes the
/// system's own volume control — the Sound slider, and the F11/F12 keys, which
/// always act on the *default output device* — drive the receiver's hardware
/// volume. That is a better answer than the loopback device's own gain, which
/// only attenuates the samples digitally before we ever see them: it throws away
/// dynamic range and leaves the iMac's amplifier at whatever it was.
final class TBAudioDeviceVolumeObserver {

    private let lock = NSLock()
    private var deviceID: AudioDeviceID = kAudioObjectUnknown
    private var listener: AudioObjectPropertyListenerBlock?
    private var wantedUID: String?
    private var watchingDeviceList = false
    private let onChange: @Sendable (Double) -> Void

    init(onChange: @escaping @Sendable (Double) -> Void) {
        self.onChange = onChange
    }

    /// Resolve a device UID to its CoreAudio ID. Returns nil when the device has
    /// gone away (unplugged, driver uninstalled).
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                            &addr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &ids) == noErr else { return nil }

        for id in ids {
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var cf: CFString? = nil
            var sz = UInt32(MemoryLayout<CFString?>.size)
            guard AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &sz, &cf) == noErr,
                  let got = cf as String? else { continue }
            if got == uid { return id }
        }
        return nil
    }

    /// Current output volume 0...1, or nil if the device exposes no volume control.
    static func volume(of device: AudioDeviceID) -> Double? {
        // Try the main element first, then channels 1/2 — virtual devices often
        // implement per-channel volume only.
        for element in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element)
            guard AudioObjectHasProperty(device, &addr) else { continue }
            var value: Float32 = 0
            var sz = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &sz, &value) == noErr {
                return Double(value)
            }
        }
        return nil
    }

    private static func muted(_ device: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var value: UInt32 = 0
        var sz = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &sz, &value) == noErr else { return false }
        return value != 0
    }

    /// Begin mirroring `deviceUID`'s volume, now or as soon as it appears.
    ///
    /// The device may legitimately not exist yet: our own driver withdraws it
    /// whenever the sender is not carrying audio, and republishes it about a
    /// second after we open the socket — which is *after* this is called. It
    /// also gets a fresh CoreAudio ID each time it is republished, so an ID
    /// resolved once is not good for the life of the app. Hence: watch the
    /// device list and (re)attach whenever the UID shows up.
    @discardableResult
    func start(deviceUID: String) -> Bool {
        lock.lock()
        wantedUID = deviceUID
        lock.unlock()
        watchDeviceList()
        return attach()
    }

    /// Re-run attachment whenever devices come or go.
    private func watchDeviceList() {
        lock.lock()
        let already = watchingDeviceList
        watchingDeviceList = true
        lock.unlock()
        guard !already else { return }

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.attachIfNeeded()
        }
        _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                &addr, nil, block)
    }

    private func attachIfNeeded() {
        lock.lock()
        let uid = wantedUID
        let current = deviceID
        lock.unlock()
        guard let uid else { return }

        let resolved = Self.deviceID(forUID: uid)
        if resolved == current { return }   // nothing changed

        // Either it went away, or it came back under a new ID. Drop the old
        // registration before taking a new one so listeners cannot accumulate.
        detach()
        if resolved != nil { _ = attach() }
    }

    private func attach() -> Bool {
        lock.lock()
        let uid = wantedUID
        lock.unlock()
        guard let deviceUID = uid, let id = Self.deviceID(forUID: deviceUID) else { return false }

        lock.lock()
        deviceID = id
        lock.unlock()

        let cb = onChange
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            // Mute reports as level 0 so the receiver actually goes silent,
            // rather than staying at its last level with muted audio arriving.
            let level = Self.muted(id) ? 0 : (Self.volume(of: id) ?? 1)
            DispatchQueue.main.async { cb(level) }
        }
        lock.lock()
        listener = block
        lock.unlock()

        var ok = false
        for element in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element)
            if AudioObjectHasProperty(id, &addr),
               AudioObjectAddPropertyListenerBlock(id, &addr, nil, block) == noErr {
                ok = true
            }
        }
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(id, &muteAddr) {
            _ = AudioObjectAddPropertyListenerBlock(id, &muteAddr, nil, block)
        }

        TBLog.connection.notice("audio volume: observer start uid=\(deviceUID, privacy: .public) id=\(id, privacy: .public) registered=\(ok, privacy: .public)")
        if ok {
            // Adopt the device's current level immediately, so the receiver is not
            // left at a stale value until the user first touches the slider.
            let level = Self.muted(id) ? 0 : (Self.volume(of: id) ?? 1)
            DispatchQueue.main.async { cb(level) }
        } else {
            TBLog.connection.info("audio volume: \(deviceUID, privacy: .public) exposes no volume control")
        }
        return ok
    }

    func stop() {
        lock.lock()
        wantedUID = nil
        lock.unlock()
        detach()
    }

    private func detach() {
        lock.lock()
        let deviceID = self.deviceID
        let held = listener
        lock.unlock()
        guard deviceID != kAudioObjectUnknown, let block = held else { return }
        for element in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element)
            _ = AudioObjectRemovePropertyListenerBlock(deviceID, &addr, nil, block)
        }
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectRemovePropertyListenerBlock(deviceID, &muteAddr, nil, block)

        lock.lock()
        listener = nil
        self.deviceID = kAudioObjectUnknown
        lock.unlock()
    }
}
