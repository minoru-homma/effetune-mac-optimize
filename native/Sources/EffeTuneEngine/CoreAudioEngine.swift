import Foundation
import CoreAudio
import AudioToolbox

/// Low-latency duplex audio engine built on a single AUHAL (HALOutput) unit:
/// input element (1) captures the default input device, output element (0)
/// renders to the default output device. The render callback pulls input, runs
/// the effect chain in place, and writes the result — all on CoreAudio's
/// realtime thread, so latency is bounded by the configured hardware buffer
/// (e.g. 64/128 frames) with no Web Audio 128-quantum / Chromium buffering.
public final class CoreAudioEngine {
    public private(set) var sampleRate: Double = 48000
    public private(set) var channels: Int = 2
    public private(set) var bufferFrames: UInt32 = 128

    private var unit: AudioUnit?
    private var planar: UnsafeMutableBufferPointer<Float>?   // stable channel-major scratch [ch * bufferFrames]
    private var captureList: UnsafeMutableAudioBufferListPointer?

    /// The live chain read by the RT callback. Swapped wholesale on reconfigure.
    /// (A production build should make this swap lock-free / RCU; see EffectChain.)
    public var chain: EffectChain?

    public init() {}

    public func configure(sampleRate: Double, channels: Int, bufferFrames: UInt32) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bufferFrames = bufferFrames
    }

    public func start() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw err("no HALOutput component") }
        var au: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &au), "AudioComponentInstanceNew")
        guard let unit = au else { throw err("null AudioUnit") }
        self.unit = unit

        // Enable input (bus 1) and output (bus 0).
        var enable: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size)), "enable input")
        var enableOut: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableOut, UInt32(MemoryLayout<UInt32>.size)), "enable output")

        // Non-interleaved float32 stream maps 1 AudioBuffer per channel == planar.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "input stream format")
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "output stream format")

        // Request the hardware buffer size (low latency).
        var frames = bufferFrames
        _ = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, UInt32(MemoryLayout<UInt32>.size))

        let scratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: channels * Int(bufferFrames))
        scratch.initialize(repeating: 0)
        planar = scratch
        captureList = AudioBufferList.allocate(maximumBuffers: channels)

        var cb = AURenderCallbackStruct(inputProc: renderProc, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set render callback")

        try check(AudioUnitInitialize(unit), "AudioUnitInitialize")
        try check(AudioOutputUnitStart(unit), "AudioOutputUnitStart")
    }

    public func stop() {
        if let unit = unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        if let cl = captureList { free(cl.unsafeMutablePointer) }
        captureList = nil
        planar?.deallocate()
        planar = nil
    }

    // Called on the realtime thread. Allocation-free.
    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ ts: UnsafePointer<AudioTimeStamp>,
                            _ frames: UInt32,
                            _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let unit = unit, let outList = ioData, let scratch = planar, let base = scratch.baseAddress else { return noErr }
        let n = Int(frames)
        let ch = channels
        let stride = Int(bufferFrames)

        // 1. Pull input into our planar scratch via the capture buffer list.
        if let cap = captureList {
            for i in 0..<ch {
                cap[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4),
                                     mData: UnsafeMutableRawPointer(base + i * stride))
            }
            let st = AudioUnitRender(unit, flags, ts, 1, frames, cap.unsafeMutablePointer)
            if st != noErr { // input not ready: emit silence
                for i in 0..<ch { (base + i * stride).update(repeating: 0, count: n) }
            }
        }

        // 2. Run the effect chain in place over the planar buffer.
        chain?.process(base, frames: n)

        // 3. Copy planar scratch into the non-interleaved output buffers.
        let out = UnsafeMutableAudioBufferListPointer(outList)
        for i in 0..<min(ch, out.count) {
            if let dst = out[i].mData {
                dst.copyMemory(from: base + i * stride, byteCount: n * 4)
            }
        }
        return noErr
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw err("\(what) failed: OSStatus \(status)") }
    }
    private func err(_ msg: String) -> NSError {
        NSError(domain: "EffeTuneEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

// C render callback trampoline -> instance method.
private func renderProc(refCon: UnsafeMutableRawPointer,
                        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                        ts: UnsafePointer<AudioTimeStamp>,
                        bus: UInt32, frames: UInt32,
                        ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let engine = Unmanaged<CoreAudioEngine>.fromOpaque(refCon).takeUnretainedValue()
    return engine.render(flags, ts, frames, ioData)
}
