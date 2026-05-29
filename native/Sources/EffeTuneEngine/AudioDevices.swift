import Foundation
import CoreAudio

/// A CoreAudio device, identified by its stable UID (used as the JS deviceId so
/// selections survive device-id renumbering across reconnects).
public struct AudioDeviceInfo: Codable {
    public let uid: String
    public let name: String
    public let hasInput: Bool
    public let hasOutput: Bool
    public let isDefaultInput: Bool
    public let isDefaultOutput: Bool
}

public enum AudioDevices {
    private static func addr(_ sel: AudioObjectPropertySelector,
                            _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var a = addr(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func defaultDevice(_ sel: AudioObjectPropertySelector) -> AudioDeviceID {
        var a = addr(sel)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev)
        return dev
    }

    private static func stringProp(_ dev: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = addr(sel)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: CFString? = nil
        let st = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(dev, &a, 0, nil, &size, $0)
        }
        guard st == noErr, let s = cf else { return nil }
        return s as String
    }

    /// Channel count available on a device for the given scope (input/output).
    private static func channels(_ dev: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var a = addr(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let listPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { listPtr.deallocate() }
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, listPtr) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(listPtr.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public static func deviceUID(_ dev: AudioDeviceID) -> String? {
        stringProp(dev, kAudioDevicePropertyDeviceUID)
    }

    /// Resolve a stable UID back to the current runtime AudioDeviceID.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        for id in deviceIDs() where deviceUID(id) == uid { return id }
        return nil
    }

    public static func list() -> [AudioDeviceInfo] {
        let defIn = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let defOut = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        var out: [AudioDeviceInfo] = []
        for id in deviceIDs() {
            guard let uid = deviceUID(id) else { continue }
            let name = stringProp(id, kAudioObjectPropertyName) ?? stringProp(id, kAudioDevicePropertyDeviceNameCFString) ?? uid
            let inCh = channels(id, scope: kAudioObjectPropertyScopeInput)
            let outCh = channels(id, scope: kAudioObjectPropertyScopeOutput)
            if inCh == 0 && outCh == 0 { continue }
            out.append(AudioDeviceInfo(uid: uid, name: name,
                                       hasInput: inCh > 0, hasOutput: outCh > 0,
                                       isDefaultInput: id == defIn, isDefaultOutput: id == defOut))
        }
        return out
    }

    public static var defaultInputUID: String? { deviceUID(defaultDevice(kAudioHardwarePropertyDefaultInputDevice)) }
    public static var defaultOutputUID: String? { deviceUID(defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)) }
}
