import Foundation

/// An ordered chain of native effects processing a fixed channel count / block size.
///
/// The RT audio callback owns one immutable chain at a time. To reconfigure
/// (add/remove/reorder), build a new chain off-thread and atomically swap the
/// reference the callback reads — never mutate a live chain from the audio thread.
public final class EffectChain {
    public let channels: Int
    public let maxBlock: Int
    private(set) public var effects: [EffectModule]

    public init(channels: Int, maxBlock: Int, effects: [EffectModule] = []) {
        self.channels = channels
        self.maxBlock = maxBlock
        self.effects = effects
    }

    public func append(_ e: EffectModule) { effects.append(e) }

    /// Process `frames` of planar audio (channel-major, stride = frames) in place
    /// through every effect in order. Allocation-free; safe on the audio thread.
    public func process(_ buf: UnsafeMutablePointer<Float>, frames: Int) {
        for e in effects where e.enabled { e.process(buf, frames: frames) }
    }
}
