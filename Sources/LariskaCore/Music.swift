import Foundation

/// Equal-tempered pitch, stored as a MIDI number (A4 = 69 = 440 Hz).
public struct Note: Sendable, Hashable, Comparable {
    public let midi: Int

    public init(midi: Int) { self.midi = midi }

    private static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// Scientific pitch notation: "A5", "G#5", "C7".
    public init?(_ text: String) {
        guard let octaveDigit = text.last, let octave = Int(String(octaveDigit)),
              let pc = Self.names.firstIndex(of: String(text.dropLast())) else { return nil }
        midi = (octave + 1) * 12 + pc
    }

    public init(nearest hz: Double) { midi = Int((69 + 12 * log2(max(hz, 1) / 440)).rounded()) }

    public var hz: Double { 440 * pow(2, Double(midi - 69) / 12) }
    public var name: String { Self.names[((midi % 12) + 12) % 12] + String(midi / 12 - 1) }
    public static func < (a: Note, b: Note) -> Bool { a.midi < b.midi }
}

/// Note literal for tables of music; a typo is a programmer error, caught at first use.
public func n(_ text: String) -> Note {
    guard let note = Note(text) else { preconditionFailure("bad note \(text)") }
    return note
}

public struct Melody: Sendable {
    public struct Step: Sendable {
        public let note: Note
        public let beats: Double
        public let endsPhrase: Bool
    }

    public let title: String
    public let bpm: Double
    public let steps: [Step]

    public var beat: Double { 60 / bpm }
    public var length: Double { steps.reduce(0) { $0 + $1.beats } * beat }
    /// Distinct notes, low to high.
    public var range: [Note] { Array(Set(steps.map(\.note))).sorted() }

    public init(title: String, bpm: Double, phrases: [[(String, Double)]]) {
        self.title = title
        self.bpm = bpm
        steps = phrases.flatMap { phrase in
            phrase.enumerated().map { i, item in Step(note: n(item.0), beats: item.1, endsPhrase: i == phrase.count - 1) }
        }
    }

    /// Start time of every step, in seconds from the beginning.
    public var onsets: [Double] {
        var t = 0.0
        return steps.map { step in defer { t += step.beats * beat }; return t }
    }
}

extension Melody {
    /// «Катюша» (М. Блантер), A minor, lifted an octave into the motor's loudest band.
    public static let katyusha: Melody = {
        let verse: [(String, Double)] = [("A5", 1.5), ("B5", 0.5), ("C6", 1.5), ("A5", 0.5),
                                         ("C6", 0.5), ("C6", 0.5), ("B5", 0.5), ("A5", 0.5), ("B5", 1), ("E5", 1)]
        let answer: [(String, Double)] = [("B5", 1.5), ("C6", 0.5), ("D6", 1.5), ("B5", 0.5),
                                          ("D6", 0.5), ("D6", 0.5), ("C6", 0.5), ("B5", 0.5), ("A5", 2)]
        let rise: [(String, Double)] = [("E6", 1), ("A6", 1), ("G6", 0.75), ("A6", 0.25),
                                        ("G6", 0.5), ("F6", 0.5), ("F6", 0.5), ("E6", 0.5), ("D6", 0.5), ("E6", 1.5)]
        let close: [(String, Double)] = [("F6", 1.5), ("D6", 0.5), ("E6", 1.5), ("C6", 0.5),
                                         ("B5", 0.5), ("E5", 0.5), ("C6", 0.5), ("B5", 0.5), ("A5", 2)]
        return Melody(title: "Катюша", bpm: 132, phrases: [verse, answer, rise, close, rise, close])
    }()
}

/// Attack-decay-sustain-release envelope, in seconds.
public struct ADSR: Sendable {
    public var attack, decay, sustain, release: Double
    public init(attack: Double, decay: Double, sustain: Double, release: Double) {
        self.attack = attack; self.decay = decay; self.sustain = sustain; self.release = release
    }

    /// Level `t` seconds after note-on for a note held `gate` seconds.
    public func level(at t: Double, gate: Double) -> Double {
        func held(_ t: Double) -> Double {
            if t < attack { return t / attack }
            return sustain + (1 - sustain) * exp(-(t - attack) / max(decay, 1e-6))
        }
        guard t >= 0 else { return 0 }
        if t < gate { return held(t) }
        return held(gate) * max(0, 1 - (t - gate) / max(release, 1e-6))
    }
}

/// Delayed vibrato whose rate drifts slowly, like a singer's.
public struct Vibrato: Sendable {
    public var delay: Double, fadeIn: Double, depthCents: Double, rate: Double
    public init(delay: Double, fadeIn: Double, depthCents: Double, rate: Double) {
        self.delay = delay; self.fadeIn = fadeIn; self.depthCents = depthCents; self.rate = rate
    }

    /// Pitch factor `t` seconds into a note.
    public func factor(at t: Double) -> Double {
        guard t > delay else { return 1 }
        let depth = depthCents * min(1, (t - delay) / fadeIn)
        let phase = 2 * .pi * (rate * t + 0.15 * sin(0.7 * t))
        return pow(2, depth * sin(phase) / 1200)
    }
}

/// Constant-speed glide between pitches.
public enum Portamento {
    /// Frequency `t` seconds into a glide from `from` to `to` at `centsPerSecond`.
    public static func frequency(from: Double, to: Double, after t: Double, centsPerSecond: Double) -> Double {
        let total = 1200 * log2(to / from)
        let moved = min(abs(total), centsPerSecond * t)
        return from * pow(2, (total < 0 ? -moved : moved) / 1200)
    }
}
