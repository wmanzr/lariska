import Foundation

public enum Drum: Int, Sendable, CaseIterable { case kick, snare, hat }

public struct DrumHit: Sendable {
    public let time: Double
    public let drum: Drum
    public let velocity: Double
    public init(time: Double, drum: Drum, velocity: Double) { self.time = time; self.drum = drum; self.velocity = velocity }
}

/// Drum voices built from the few sine tones the motor can play at once.
public enum DrumKit {
    /// How long each drum rings, seconds.
    public static func length(_ drum: Drum) -> Double {
        switch drum {
        case .kick: 0.16
        case .snare: 0.18
        case .hat: 0.05
        }
    }

    public static func tones(_ hit: DrumHit, at t: Double) -> [Tone] {
        let age = t - hit.time
        guard age >= 0, age < length(hit.drum) else { return [] }
        let v = hit.velocity
        switch hit.drum {
        case .kick:
            // 5 ms beater click, then a body whose pitch falls 400 → 110 Hz along a log curve.
            if age < 0.005 { return [Tone(hz: 1200, amp: v)] }
            let fall = max(0, 1 - (age - 0.005) / 0.06)
            let body = 110 * pow(400.0 / 110, fall)
            return [Tone(hz: body, amp: v * min(1, age / 0.002) * exp(-age / 0.07))]
        case .snare:
            // A tuned shell plus three inharmonic partials, each detuned per hit so no two hits match.
            let decay = exp(-age / 0.05)
            var tones = [Tone(hz: 330, amp: v * 0.6 * exp(-age / 0.03))]
            for (i, (ratio, weight)) in [(1.0, 0.5), (1.62, 0.35), (2.31, 0.25)].enumerated() {
                let jitter = 1 + 0.05 * (unitHash(hit.time * 1000 + Double(i)) - 0.5) * 2
                tones.append(Tone(hz: 1700 * ratio * jitter, amp: v * weight * decay))
            }
            return tones
        case .hat:
            // Metallic pair with an inharmonic 1.47 ratio.
            let decay = exp(-age / 0.015)
            return [Tone(hz: 3100, amp: v * 0.5 * decay), Tone(hz: 3100 * 1.47, amp: v * 0.35 * decay)]
        }
    }

    private static func unitHash(_ x: Double) -> Double { let v = sin(x * 91.345) * 47453.5453; return v - floor(v) }
}

/// A one-bar loop on a 16th-note grid plus a bass line, one root per bar.
public struct BeatPattern: Sendable {
    public let bpm: Double
    public let lanes: [Drum: String]       // "x" hit, "X" accent, "." rest
    public let bassRoots: [Note]
    public let bassRhythm: String
    public let chords: [String]            // display name of each bar's harmony

    public var sixteenth: Double { 15 / bpm }
    public var bar: Double { 16 * sixteenth }

    /// Hits for `bars` bars, sorted by time.
    public func hits(bars: Int) -> [DrumHit] {
        var out: [DrumHit] = []
        for step in 0..<(bars * 16) {
            for drum in Drum.allCases {
                guard let lane = lanes[drum] else { continue }
                let mark = Array(lane)[step % 16]
                if mark != "." { out.append(DrumHit(time: Double(step) * sixteenth, drum: drum, velocity: mark == "X" ? 1 : 0.6)) }
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    /// Bass note sounding at `t` and how long ago it was struck.
    public func bass(at time: Double) -> (root: Note, age: Double) {
        let t = max(0, time)
        let step = Int(t / sixteenth), barIndex = step / 16
        let rhythm = Array(bassRhythm)
        let lastStrike = (0...(step % 16)).last { rhythm[$0] != "." } ?? 0
        return (bassRoots[barIndex % bassRoots.count], t - Double(barIndex * 16 + lastStrike) * sixteenth)
    }

    public func chord(at t: Double) -> String { chords[Int(max(0, t) / bar) % chords.count] }

    /// Am – G – F – E, the Andalusian cadence.
    public static let night = BeatPattern(
        bpm: 90,
        lanes: [.kick: "X.....x.X.......", .snare: "....X.......X..x", .hat: "x.x.x.x.x.x.x.X."],
        bassRoots: [n("A2"), n("G2"), n("F2"), n("E2")],
        bassRhythm: "x..x..x.x.......",
        chords: ["Am", "G", "F", "E"])
}
