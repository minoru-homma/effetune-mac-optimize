import Foundation
import CoreAudio
import AudioToolbox
import os.lock

/// Duplex low-latency engine for SEPARATE input and output devices.
///
/// A single AUHAL is bound to one device, so different in/out devices need two
/// HALOutput units bridged by a ring buffer:
///   - input unit  : captures the chosen input device -> writes the ring
///   - output unit : reads the ring -> runs the effect chain -> output device
/// The two devices have independent clocks; the ring's slack absorbs jitter and
/// small drift (residual drift is tolerated via under/overrun handling — good
/// enough for v1; adaptive resampling is a future refinement).
///
/// Buffers are non-interleaved float32 (planar), matching the Rust DSP layout
/// (channel-major, stride = frames).
public final class CoreAudioEngine {
    public private(set) var sampleRate: Double = 48000
    public private(set) var channels: Int = 2
    public private(set) var bufferFrames: UInt32 = 128
    private var inputUID: String?
    private var outputUID: String?

    public var chain: EffectChain?

    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?

    // Per-channel SPSC ring (indices in frames, shared; guarded by a tiny lock
    // used only for index publish/consume — never around the bulk copies).
    private var ring: [UnsafeMutablePointer<Float>] = []
    private var ringFrames = 8192
    private var writeIdx: Int = 0
    private var readIdx: Int = 0
    private var idxLock = os_unfair_lock()

    // Diagnostics (RT-incremented, logged periodically off the hot path).
    private var inCount = 0, outCount = 0, underruns = 0, inErrors = 0
    private var lastInErr: OSStatus = 0

    // Input-capture scratch + buffer list (planar).
    private var capture: UnsafeMutableBufferPointer<Float>?
    private var captureList: UnsafeMutableAudioBufferListPointer?
    // Output processing scratch (planar, chain works in place here).
    private var outScratch: UnsafeMutableBufferPointer<Float>?

    public init() {}

    public func configure(sampleRate: Double, channels: Int, bufferFrames: UInt32,
                          inputUID: String?, outputUID: String?) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        self.bufferFrames = bufferFrames
        self.inputUID = inputUID
        self.outputUID = outputUID
    }

    // MARK: lifecycle

    public func start() throws {
        stop()
        // Match the engine sample rate to the OUTPUT device's nominal rate. Forcing
        // a rate the device can't run (e.g. 96k on a display) lets init/start
        // succeed yet the IO thread never fires its callbacks. The input AUHAL
        // resamples its device to this rate via its client format.
        let outDev = AudioDevices.deviceID(forUID: outputUID ?? "")
            ?? AudioDevices.defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice)
        if let devSR = AudioDevices.nominalSampleRate(outDev), devSR != sampleRate {
            nlog("override sampleRate \(sampleRate) -> output device \(devSR)")
            sampleRate = devSR
        }
        // Ring sized to comfortably hold several device buffers of slack.
        ringFrames = max(8192, Int(bufferFrames) * 16)
        ring = (0..<channels).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: ringFrames)
            p.initialize(repeating: 0, count: ringFrames)
            return p
        }
        writeIdx = 0; readIdx = ringFrames / 2 // prime with half-buffer of latency

        let cap = UnsafeMutableBufferPointer<Float>.allocate(capacity: channels * Int(bufferFrames))
        cap.initialize(repeating: 0); capture = cap
        captureList = AudioBufferList.allocate(maximumBuffers: channels)
        let os = UnsafeMutableBufferPointer<Float>.allocate(capacity: channels * Int(bufferFrames))
        os.initialize(repeating: 0); outScratch = os

        nlog("engine start: sr=\(sampleRate) ch=\(channels) buf=\(bufferFrames) inUID=\(inputUID ?? "default") outUID=\(outputUID ?? "default")")
        try buildInputUnit()
        try buildOutputUnit()
        if let u = inputUnit { try check(AudioOutputUnitStart(u), "start input") }
        if let u = outputUnit { try check(AudioOutputUnitStart(u), "start output") }
        nlog("engine started OK (sr=\(sampleRate))")
        // 1.5s later, report whether the IO threads actually ran.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            func running(_ u: AudioUnit?) -> UInt32 {
                guard let u = u else { return 99 }
                var r: UInt32 = 0; var sz = UInt32(MemoryLayout<UInt32>.size)
                AudioUnitGetProperty(u, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &r, &sz)
                return r
            }
            nlog("post-start 1.5s: inRunning=\(running(self.inputUnit)) outRunning=\(running(self.outputUnit)) inCb=\(self.inCount) outCb=\(self.outCount) inErr=\(self.inErrors) lastInErr=\(self.lastInErr) underruns=\(self.underruns)")
        }
    }

    public func stop() {
        for u in [inputUnit, outputUnit].compactMap({ $0 }) {
            AudioOutputUnitStop(u); AudioUnitUninitialize(u); AudioComponentInstanceDispose(u)
        }
        inputUnit = nil; outputUnit = nil
        if let cl = captureList { free(cl.unsafeMutablePointer); captureList = nil }
        capture?.deallocate(); capture = nil
        outScratch?.deallocate(); outScratch = nil
        ring.forEach { $0.deallocate() }; ring = []
    }

    private func asbd() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }

    private func makeHAL() throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw err("no HALOutput") }
        var au: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &au), "instantiate HAL")
        guard let u = au else { throw err("null AU") }
        return u
    }

    private func setDevice(_ u: AudioUnit, uid: String?, fallbackDefault sel: AudioObjectPropertySelector) throws {
        var devID: AudioDeviceID = 0
        if let uid = uid, let id = AudioDevices.deviceID(forUID: uid) { devID = id }
        else {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &devID)
        }
        nlog("setDevice uid=\(uid ?? "default") -> AudioDeviceID \(devID)")
        var d = devID
        try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &d, UInt32(MemoryLayout<AudioDeviceID>.size)), "set device")
    }

    private func buildInputUnit() throws {
        let u = try makeHAL()
        inputUnit = u
        var enableIn: UInt32 = 1, disableOut: UInt32 = 0
        try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableIn, 4), "enable in")
        try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableOut, 4), "disable out")
        try setDevice(u, uid: inputUID, fallbackDefault: kAudioHardwarePropertyDefaultInputDevice)
        var fmt = asbd()
        // Format we read FROM the input bus (scope output of element 1).
        try check(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "input fmt")
        var cb = AURenderCallbackStruct(inputProc: inputProc, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "input cb")
        try check(AudioUnitInitialize(u), "init input unit")
    }

    private func buildOutputUnit() throws {
        let u = try makeHAL()
        outputUnit = u
        var enableOut: UInt32 = 1, disableIn: UInt32 = 0
        try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableOut, 4), "enable out")
        try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disableIn, 4), "disable in(out unit)")
        try setDevice(u, uid: outputUID, fallbackDefault: kAudioHardwarePropertyDefaultOutputDevice)
        var fmt = asbd()
        // Format we provide TO the output bus (scope input of element 0).
        try check(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "output fmt")
        var frames = bufferFrames
        _ = AudioUnitSetProperty(u, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, 4)
        var cb = AURenderCallbackStruct(inputProc: outputProc, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "output cb")
        try check(AudioUnitInitialize(u), "init output unit")
    }

    // MARK: realtime callbacks

    fileprivate func captureInput(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                  _ ts: UnsafePointer<AudioTimeStamp>, _ frames: UInt32) -> OSStatus {
        guard let u = inputUnit, let cap = capture?.baseAddress, let list = captureList else { return noErr }
        let n = Int(frames), stride = Int(bufferFrames)
        if n > stride { return noErr }
        for c in 0..<channels {
            list[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4),
                                  mData: UnsafeMutableRawPointer(cap + c * stride))
        }
        let st = AudioUnitRender(u, flags, ts, 1, frames, list.unsafeMutablePointer)
        inCount += 1
        if st != noErr {
            inErrors += 1; lastInErr = st
            if inErrors <= 3 || inErrors % 200 == 0 { nlog("input render err=\(st) (count \(inErrors))") }
            return noErr
        }
        if inCount <= 2 { nlog("input callback firing (frames \(n))") }

        // Write into the ring; on overrun drop this input block (don't touch readIdx).
        os_unfair_lock_lock(&idxLock)
        let w = writeIdx, r = readIdx
        os_unfair_lock_unlock(&idxLock)
        let avail = (w - r + ringFrames) % ringFrames
        let free = ringFrames - 1 - avail
        if free < n { return noErr } // overrun: drop
        for i in 0..<n {
            let pos = (w + i) % ringFrames
            for c in 0..<channels { ring[c][pos] = cap[c * stride + i] }
        }
        os_unfair_lock_lock(&idxLock)
        writeIdx = (writeIdx + n) % ringFrames
        os_unfair_lock_unlock(&idxLock)
        return noErr
    }

    fileprivate func renderOutput(_ frames: UInt32, _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let outList = ioData, let scratch = outScratch?.baseAddress else { return noErr }
        let n = Int(frames), stride = Int(bufferFrames)
        let nn = min(n, stride)

        os_unfair_lock_lock(&idxLock)
        let w = writeIdx, r = readIdx
        os_unfair_lock_unlock(&idxLock)
        let avail = (w - r + ringFrames) % ringFrames

        if avail >= nn {
            for i in 0..<nn {
                let pos = (r + i) % ringFrames
                for c in 0..<channels { scratch[c * stride + i] = ring[c][pos] }
            }
            os_unfair_lock_lock(&idxLock)
            readIdx = (readIdx + nn) % ringFrames
            os_unfair_lock_unlock(&idxLock)
        } else {
            // Underrun: emit silence this cycle (don't advance readIdx).
            underruns += 1
            for c in 0..<channels { (scratch + c * stride).update(repeating: 0, count: nn) }
        }

        outCount += 1
        if outCount <= 2 || outCount % 500 == 0 {
            nlog("output cb #\(outCount): avail=\(avail) underruns=\(underruns) inCb=\(inCount) inErr=\(inErrors) lastInErr=\(lastInErr)")
        }

        chain?.process(scratch, frames: nn)

        let out = UnsafeMutableAudioBufferListPointer(outList)
        for c in 0..<min(channels, out.count) {
            if let dst = out[c].mData { dst.copyMemory(from: scratch + c * stride, byteCount: nn * 4) }
        }
        return noErr
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw err("\(what): OSStatus \(status)") }
    }
    private func err(_ m: String) -> NSError { NSError(domain: "EffeTuneEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: m]) }
}

// MARK: C trampolines

private func inputProc(refCon: UnsafeMutableRawPointer, flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                       ts: UnsafePointer<AudioTimeStamp>, bus: UInt32, frames: UInt32,
                       ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<CoreAudioEngine>.fromOpaque(refCon).takeUnretainedValue().captureInput(flags, ts, frames)
}

private func outputProc(refCon: UnsafeMutableRawPointer, flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                        ts: UnsafePointer<AudioTimeStamp>, bus: UInt32, frames: UInt32,
                        ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<CoreAudioEngine>.fromOpaque(refCon).takeUnretainedValue().renderOutput(frames, ioData)
}
