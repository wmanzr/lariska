import Foundation
import LariskaCore

/// Melodies, the beat with rap, the frequency sweep and short effects.
struct MusicPlayer {
    let motor: Haptics
    let control: Control
    let voice: VoicePlayer

    // MARK: Melody

    private enum Singing {
        static let envelope = ADSR(attack: 0.012, decay: 0.25, sustain: 0.75, release: 0.04)
        static let vibrato = Vibrato(delay: 0.18, fadeIn: 0.2, depthCents: 18, rate: 5.4)
        static let glide = 2400.0                       // cents per second between notes of a phrase
        static let segment = 0.025
        static let breath = 0.12                        // share of a phrase's last note left silent
    }

    /// Plays the melody once, or until stopped when `loop` is set.
    func sing(_ melody: Melody, loop: Bool) {
        repeat {
            var schedule = Schedule()
            var previous: Double?
            for (step, onset) in zip(melody.steps, melody.onsets) where !control.interrupted {
                let length = step.beats * melody.beat
                let gate = length * (step.endsPhrase ? 1 - Singing.breath : 0.96)
                let from = previous
                while schedule.elapsed < onset + length && !control.interrupted {
                    let age = schedule.elapsed - onset
                    var hz = from.map { Portamento.frequency(from: $0, to: step.note.hz, after: age, centsPerSecond: Singing.glide) } ?? step.note.hz
                    hz *= Singing.vibrato.factor(at: age)
                    let level = Singing.envelope.level(at: age, gate: gate)
                    let seg = Segment.whole(hz, near: Singing.segment)
                    if level > 0.01 { motor.play([Tone(hz: hz)], duration: seg, level: level) }
                    schedule.advance(seg)
                }
                previous = step.endsPhrase ? nil : step.note.hz
            }
            if loop { control.pause(melody.beat) }
        } while loop && !control.interrupted
    }

    // MARK: Beat

    private enum Mix {
        static let maxTones = 6
        static let duckDepth = 0.7               // how far drums dip under the voice
        static let duckAttack = 0.01, duckRelease = 0.12
        static let bassTarget = (low: 1050.0, high: 1400.0)
        static let bassEnvelope = ADSR(attack: 0.008, decay: 0.12, sustain: 0.35, release: 0.05)
        static let bassLevel = 0.5
    }

    /// Plays the whole arrangement as one stream of short actuations. Rap line `i` begins on the downbeat of
    /// bar `rapFrom + 2i`. Each actuation lasts one period of the "carrier": the bass root normally, the
    /// speaker's pitch while a line is sounding. The motor is weak at bass frequencies, so the bass is carried
    /// by harmonics near 1 kHz and the repetition rate supplies the missing fundamental.
    func groove(_ pattern: BeatPattern, bars: Int, rapFrom: Int, lines: [RapLine], voiceSettings: VoicePlayer.Voice,
                onLine: (RapLine) -> Void = { _ in }) {
        let hits = pattern.hits(bars: bars)
        let end = Double(bars) * pattern.bar
        var next = 0, ringing: [DrumHit] = [], duck = 0.0, announced = -1
        var schedule = Schedule()
        while schedule.elapsed < end && !control.interrupted {
            let t = schedule.elapsed
            while next < hits.count, hits[next].time <= t + 0.0005 { ringing.append(hits[next]); next += 1 }
            ringing.removeAll { t - $0.time > DrumKit.length($0.drum) }

            var frame: SpeechFrame?
            for (i, line) in lines.enumerated() {
                let downbeat = Double(rapFrom + 2 * i) * pattern.bar
                if i > announced, t >= downbeat + line.start { announced = i; onLine(line) }
                if let f = line.frame(at: t - downbeat), f.level > 0 { frame = f }
            }
            let (root, age) = pattern.bass(at: t)
            var step = 1 / root.hz
            var tones: [Tone] = []     // voice tones always come first and are never dropped
            if let frame {
                if frame.voiced {
                    step = 1 / (frame.f0 * voiceSettings.pitch)
                    tones += voice.formantTones(frame, voice: voiceSettings).map { Tone(hz: $0.hz, amp: $0.amp * frame.level) }
                } else {
                    step = 0.004
                    tones += (0..<2).map { _ in Tone(hz: frame.noiseHz * .random(in: 0.85...1.15), amp: frame.level * 0.4) }
                }
            } else {
                let env = Mix.bassEnvelope.level(at: age, gate: pattern.sixteenth * 2) * Mix.bassLevel
                tones.append(Tone(hz: (Mix.bassTarget.low / root.hz).rounded() * root.hz, amp: env * 0.6))
                tones.append(Tone(hz: (Mix.bassTarget.high / root.hz).rounded() * root.hz, amp: env * 0.4))
            }
            // Envelope follower on the voice: drums dip smoothly while it speaks.
            let target = frame.map { $0.level } ?? 0
            duck += (target - duck) * min(1, step / (target > duck ? Mix.duckAttack : Mix.duckRelease))
            let drumGain = 1 - Mix.duckDepth * duck
            for hit in ringing { tones += DrumKit.tones(hit, at: t).map { Tone(hz: $0.hz, amp: $0.amp * drumGain) } }

            if next < hits.count { let dt = hits[next].time - t; if dt > 0.003, dt < step { step = dt } }
            // Voice first, then the loudest of the rest; the total is soft-limited instead of clipped.
            let voiceCount = frame == nil ? 0 : 2
            let chosen = Array((tones.prefix(voiceCount) + tones.dropFirst(voiceCount).sorted { $0.amp > $1.amp }).prefix(Mix.maxTones))
            let total = chosen.reduce(0) { $0 + $1.amp }
            if total > 0.01 { motor.play(chosen, duration: step, level: tanh(total * 1.2)) }
            schedule.advance(step)
        }
    }

    // MARK: Sweep and effects

    /// Stepped chromatic run across the motor's range, two steps per semitone.
    func sweep(seconds: Double) {
        let scale = LogScale.motor
        var schedule = Schedule()
        while schedule.elapsed < seconds && !control.interrupted {
            let position = (schedule.elapsed / seconds * 2 * 12 * log2(scale.high / scale.low)).rounded(.down) / (2 * 12 * log2(scale.high / scale.low))
            let hz = scale.frequency(at: position)
            let seg = Segment.whole(hz, near: 0.02)
            motor.play([Tone(hz: hz)], duration: seg, level: 0.95)
            schedule.advance(seg)
        }
    }

    /// Bell-like rising fifths.
    func chime() {
        let envelope = ADSR(attack: 0.004, decay: 0.18, sustain: 0.0, release: 0.01)
        for (i, note) in [n("E6"), n("B6"), n("E7")].enumerated() where !control.interrupted {
            var schedule = Schedule()
            let length = i == 2 ? 0.45 : 0.11
            while schedule.elapsed < length && !control.interrupted {
                let seg = Segment.whole(note.hz, near: 0.02)
                motor.play([Tone(hz: note.hz), Tone(hz: note.hz * 2, amp: 0.25)], duration: seg,
                           level: envelope.level(at: schedule.elapsed, gate: length) + 0.05)
                schedule.advance(seg)
            }
        }
    }

    /// A short knock with a falling pitch, felt as much as heard.
    func knock(_ strength: Double) {
        var schedule = Schedule()
        while schedule.elapsed < 0.09 && !control.isStopped {
            let hz = 140 + 700 * pow(1 - schedule.elapsed / 0.09, 3)
            motor.play([Tone(hz: hz)], duration: 1 / hz, level: strength * (1 - schedule.elapsed / 0.09))
            schedule.advance(1 / hz)
        }
    }

    func tick(level: Double, hz: Double = 2400) { motor.play([Tone(hz: hz)], duration: 0.008, level: level) }

    func testBeeps() {
        for hz in [880.0, 1320, 1760] where !control.isStopped {
            var schedule = Schedule()
            while schedule.elapsed < 0.25 && !control.isStopped {
                let seg = Segment.whole(hz, near: 0.02)
                motor.play([Tone(hz: hz)], duration: seg, level: 0.4)
                schedule.advance(seg)
            }
            control.pause(0.15)
        }
    }
}
