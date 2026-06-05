import Foundation
import CoreAudio
import AudioToolbox

/// Captures the system-wide audio mix via a Core Audio process tap (macOS 14.4+)
/// and delivers it as float frames, so EffeTune can treat "everything the Mac is
/// playing" as an input source — no third-party virtual device (e.g. BlackHole)
/// or driver install required, and nothing system-wide is left behind.
///
/// A process tap is not itself an IO device, so it is wrapped in a *private*
/// aggregate device on which we run an IOProc; the captured AudioBufferList is
/// handed to `onAudio`. The tap is a global stereo mixdown with `.muted` mute
/// behavior: the OS mutes the original system output while EffeTune re-outputs the
/// processed signal (EffeTune is inserted into the output path), avoiding hearing
/// the dry and processed signals at once.
///
/// Requires the `NSAudioCaptureUsageDescription` Info.plist key; the first tap
/// creation triggers the system's audio-recording permission prompt.
@available(macOS 14.4, *)
public final class SystemAudioTap {
    public private(set) var sampleRate: Double = 0
    public private(set) var channelCount: Int = 2

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    /// CoreAudio process-object ID for our own pid, or unknown. A global tap must
    /// EXCLUDE us: otherwise it taps (and, when muted, silences) EffeTune's own
    /// output, which both mutes the processed signal and feeds it back into itself.
    private static func ownProcessObject() -> AudioObjectID {
        var pid = getpid()
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        if st != noErr { nlog("tap: translate pid->process failed (status \(st))") }
        return obj
    }

    public init() throws {
        // Exclude our own audio process so EffeTune's processed output is neither
        // tapped nor muted (prevents a silence/feedback loop).
        var exclude: [AudioObjectID] = []
        let own = SystemAudioTap.ownProcessObject()
        if own != kAudioObjectUnknown { exclude.append(own) }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        desc.name = "EffeTune System Tap"
        desc.isPrivate = true
        desc.muteBehavior = .muted
        nlog("tap: excluding own process object \(own)")

        var tap = AudioObjectID(kAudioObjectUnknown)
        let st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr, tap != kAudioObjectUnknown else {
            throw NSError(domain: "EffeTuneEngine", code: Int(st), userInfo: [NSLocalizedDescriptionKey:
                "Could not capture system audio (status \(st)). Allow audio recording for EffeTune in System Settings › Privacy & Security."])
        }
        tapID = tap

        // Tap stream format → engine sample rate + channel count.
        var fmt = AudioStreamBasicDescription()
        var fsize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var faddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tapID, &faddr, 0, nil, &fsize, &fmt) == noErr, fmt.mSampleRate > 0 {
            sampleRate = fmt.mSampleRate
            channelCount = max(1, Int(fmt.mChannelsPerFrame))
        }

        // Private aggregate device wrapping just the tap (never exposed system-wide).
        let aggUID = "com.frieve.effetune.tap." + desc.uuid.uuidString
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "EffeTune Tap",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        let ast = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &agg)
        guard ast == noErr, agg != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown
            throw NSError(domain: "EffeTuneEngine", code: Int(ast), userInfo: [NSLocalizedDescriptionKey:
                "Could not create the tap aggregate device (status \(ast))."])
        }
        aggID = agg

        // Fall back to the aggregate's nominal rate if the tap format was unavailable.
        if sampleRate <= 0, let sr = AudioDevices.nominalSampleRate(aggID) { sampleRate = sr }
        if sampleRate <= 0 { sampleRate = 48000 }
        nlog("system tap ready: sr=\(sampleRate) ch=\(channelCount) tapID=\(tapID) aggID=\(aggID)")
    }

    /// Install the IOProc and start capturing. `onAudio` is called on a CoreAudio
    /// realtime thread with the captured input buffer list and its frame count.
    public func start(onAudio cb: @escaping (UnsafePointer<AudioBufferList>, UInt32) -> Void) throws {
        let st = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggID, nil) { _, inInputData, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard list.count > 0 else { return }
            let ch = max(1, Int(list[0].mNumberChannels))
            let frames = Int(list[0].mDataByteSize) / (4 * ch)
            if frames > 0 { cb(inInputData, UInt32(frames)) }
        }
        guard st == noErr, ioProcID != nil else {
            throw NSError(domain: "EffeTuneEngine", code: Int(st), userInfo: [NSLocalizedDescriptionKey:
                "Could not install the tap IOProc (status \(st))."])
        }
        let started = AudioDeviceStart(aggID, ioProcID)
        guard started == noErr else {
            throw NSError(domain: "EffeTuneEngine", code: Int(started), userInfo: [NSLocalizedDescriptionKey:
                "Could not start the tap device (status \(started))."])
        }
    }

    public func stop() {
        if let p = ioProcID {
            AudioDeviceStop(aggID, p)
            AudioDeviceDestroyIOProcID(aggID, p)
            ioProcID = nil
        }
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = kAudioObjectUnknown }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown }
    }

    deinit { stop() }
}
