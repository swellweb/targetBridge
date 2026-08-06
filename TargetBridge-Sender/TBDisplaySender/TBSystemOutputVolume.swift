import CoreAudio
import Foundation

/// Reads and controls the volume of the Mac running the sender. This stays
/// deliberately separate from `TBDisplaySenderSession.volume`, which is sent
/// over the wire and controls the receiver Mac's default output volume.
enum TBSystemOutputVolume {
    struct State {
        let level: Double
        let isControllable: Bool
    }

    static func readState() -> State? {
        guard let device = defaultOutputDevice(),
              let level = readVolume(from: device)
        else {
            return nil
        }

        let muted = readMute(from: device) ?? false
        return State(
            level: muted ? 0 : min(max(Double(level), 0), 1),
            isControllable: hasSettableVolume(on: device)
        )
    }

    @discardableResult
    static func setLevel(_ rawLevel: Double) -> Bool {
        guard let device = defaultOutputDevice() else { return false }

        var level = Float32(min(max(rawLevel, 0), 1))
        var changed = false

        var masterAddress = volumeAddress(element: kAudioObjectPropertyElementMain)
        if isSettable(device: device, address: &masterAddress),
           AudioObjectSetPropertyData(
               device,
               &masterAddress,
               0,
               nil,
               UInt32(MemoryLayout<Float32>.size),
               &level
           ) == noErr {
            changed = true
        } else {
            for channel in UInt32(1)...UInt32(2) {
                var channelAddress = volumeAddress(element: channel)
                guard isSettable(device: device, address: &channelAddress) else { continue }
                if AudioObjectSetPropertyData(
                    device,
                    &channelAddress,
                    0,
                    nil,
                    UInt32(MemoryLayout<Float32>.size),
                    &level
                ) == noErr {
                    changed = true
                }
            }
        }

        if changed {
            setMute(rawLevel <= 0.0001, on: device)
        }
        return changed
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func readVolume(from device: AudioDeviceID) -> Float32? {
        var masterAddress = volumeAddress(element: kAudioObjectPropertyElementMain)
        if let value = readFloat32(device: device, address: &masterAddress) {
            return value
        }

        var channelValues: [Float32] = []
        for channel in UInt32(1)...UInt32(2) {
            var channelAddress = volumeAddress(element: channel)
            if let value = readFloat32(device: device, address: &channelAddress) {
                channelValues.append(value)
            }
        }
        guard !channelValues.isEmpty else { return nil }
        return channelValues.reduce(0, +) / Float32(channelValues.count)
    }

    private static func readMute(from device: AudioDeviceID) -> Bool? {
        var masterAddress = muteAddress(element: kAudioObjectPropertyElementMain)
        if let value = readUInt32(device: device, address: &masterAddress) {
            return value != 0
        }

        var values: [UInt32] = []
        for channel in UInt32(1)...UInt32(2) {
            var channelAddress = muteAddress(element: channel)
            if let value = readUInt32(device: device, address: &channelAddress) {
                values.append(value)
            }
        }
        guard !values.isEmpty else { return nil }
        return values.allSatisfy { $0 != 0 }
    }

    private static func hasSettableVolume(on device: AudioDeviceID) -> Bool {
        var masterAddress = volumeAddress(element: kAudioObjectPropertyElementMain)
        if isSettable(device: device, address: &masterAddress) {
            return true
        }
        for channel in UInt32(1)...UInt32(2) {
            var channelAddress = volumeAddress(element: channel)
            if isSettable(device: device, address: &channelAddress) {
                return true
            }
        }
        return false
    }

    private static func setMute(_ muted: Bool, on device: AudioDeviceID) {
        var value: UInt32 = muted ? 1 : 0
        var masterAddress = muteAddress(element: kAudioObjectPropertyElementMain)
        if isSettable(device: device, address: &masterAddress),
           AudioObjectSetPropertyData(
               device,
               &masterAddress,
               0,
               nil,
               UInt32(MemoryLayout<UInt32>.size),
               &value
           ) == noErr {
            return
        }

        for channel in UInt32(1)...UInt32(2) {
            var channelAddress = muteAddress(element: channel)
            guard isSettable(device: device, address: &channelAddress) else { continue }
            AudioObjectSetPropertyData(
                device,
                &channelAddress,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &value
            )
        }
    }

    private static func readFloat32(
        device: AudioDeviceID,
        address: inout AudioObjectPropertyAddress
    ) -> Float32? {
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func readUInt32(
        device: AudioDeviceID,
        address: inout AudioObjectPropertyAddress
    ) -> UInt32? {
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func isSettable(
        device: AudioDeviceID,
        address: inout AudioObjectPropertyAddress
    ) -> Bool {
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func volumeAddress(element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private static func muteAddress(element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }
}
