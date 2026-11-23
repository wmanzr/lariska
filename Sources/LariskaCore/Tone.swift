import Foundation

/// One sine component of an actuation.
public struct Tone: Sendable, Equatable {
    public var hz: Double
    public var amp: Double
    public init(hz: Double, amp: Double = 1) { self.hz = hz; self.amp = amp }
}

/// Segment arithmetic. The motor plays short segments back to back; a segment that ends mid-cycle clicks.
public enum Segment {
    /// Duration close to `target` that holds a whole number of cycles of `hz`.
    public static func whole(_ hz: Double, near target: Double) -> Double {
        max(1, (target * hz).rounded()) / hz
    }

    /// Several tones in one segment: each frequency moves to the nearest multiple of 1/length,
    /// so every tone completes whole cycles.
    public static func aligned(_ tones: [Tone], length: Double) -> [Tone] {
        tones.map { Tone(hz: max(1, ($0.hz * length).rounded()) / length, amp: $0.amp) }
    }
}

/// Logarithmic frequency axis, used both for sounds (sweeps) and for drawing.
public struct LogScale: Sendable {
    public let low: Double, high: Double
    public init(_ low: Double, _ high: Double) { self.low = low; self.high = high }
    public func position(of hz: Double) -> Double { log(min(high, max(low, hz)) / low) / log(high / low) }
    public func frequency(at position: Double) -> Double { low * pow(high / low, min(1, max(0, position))) }

    /// The motor's usable range.
    public static let motor = LogScale(100, 4000)
}
