import Foundation
import LariskaCore

/// Instruments played with fingers on the trackpad.
struct TouchInstruments {
    let motor: HapticMotor
    let control: Control
    let stage: Stage
    let music: MusicPlayer
    let voice: VoicePlayer

    static let scale = ["A5", "C6", "D6", "E6", "G6", "A6", "C7"].map(n)   // A minor pentatonic
    static let smoothRange = (low: n("C5").hz, high: n("C7").hz)

    private enum Feel {
        static let glideTime = 0.03                  // one-pole pitch smoothing, seconds
        static let vibrato = (rate: 5.5, maxCents: 55.0)
        static let level = 0.55...1.0
        static let chordSegment = 0.04
        static let soloSegment = 0.02
        static let maxFingers = 3
    }

    private func withTouch(_ body: () -> Void) {
        guard TouchInput.shared.start(on: motor) else { stage.show(.message("трекпад не отдаёт касания")); control.pause(2); return }
        defer { TouchInput.shared.stop(on: motor) }
        body()
    }

    /// One note per finger (up to three). x: pitch, y: vibrato depth, contact size: level.
    /// Tab switches between the pentatonic scale and continuous pitch.
    func play(seconds: Double? = nil, waitForTouch: Double? = nil) {
        withTouch {
            var smooth = false
            var pitch = [Double](repeating: Self.scale[3].hz, count: Feel.maxFingers)
            var touchedAt: Double?, endsAt: Double?
            let giveUp = waitForTouch.map { Clock.now() + $0 }
            stage.show(.play(smooth: smooth, endsAt: nil))
            while !control.interrupted {
                while let event = control.nextEvent() {
                    if event == .tab { smooth.toggle(); stage.show(.play(smooth: smooth, endsAt: endsAt)) }
                }
                if let endsAt, Clock.now() >= endsAt { break }
                if touchedAt == nil, let giveUp, Clock.now() >= giveUp { break }
                let fingers = Array(TouchInput.shared.current.prefix(Feel.maxFingers))
                guard !fingers.isEmpty else { Clock.sleep(until: Clock.now() + 0.003); continue }
                if touchedAt == nil {
                    touchedAt = Clock.now()
                    endsAt = seconds.map { Clock.now() + $0 }
                    stage.show(.play(smooth: smooth, endsAt: endsAt))
                }
                let age = Clock.now() - (touchedAt ?? 0)
                var tones: [Tone] = []
                for (i, finger) in fingers.enumerated() {
                    let target = smooth
                        ? LogScale(Self.smoothRange.low, Self.smoothRange.high).frequency(at: finger.x)
                        : Self.scale[min(Self.scale.count - 1, max(0, Int(finger.x * Double(Self.scale.count))))].hz
                    let segment = fingers.count == 1 ? Feel.soloSegment : Feel.chordSegment
                    pitch[i] *= pow(target / pitch[i], 1 - exp(-segment / Feel.glideTime))
                    let cents = Feel.vibrato.maxCents * min(1, max(0, finger.y)) * sin(2 * .pi * Feel.vibrato.rate * age)
                    tones.append(Tone(hz: pitch[i] * pow(2, cents / 1200)))
                }
                let size = fingers.map(\.size).max() ?? 0
                let level = Feel.level.lowerBound + (Feel.level.upperBound - Feel.level.lowerBound) * min(1, size)
                let segment: Double
                if tones.count == 1 { segment = Segment.whole(tones[0].hz, near: Feel.soloSegment) }
                else { segment = Feel.chordSegment; tones = Segment.aligned(tones, length: segment) }
                var schedule = Schedule()
                motor.play(tones, duration: segment, level: level)
                schedule.advance(segment)
            }
        }
    }

    /// Left, middle and right thirds are kick, snare and hat. A tap is a new finger, no click needed.
    func drumPad(seconds: Double? = nil) {
        withTouch {
            let end = seconds.map { Clock.now() + $0 }
            var previous: [Finger] = [], ringing: [DrumHit] = []
            var flashes: [Drum: Double] = [:]
            stage.show(.pad(hits: flashes))
            var schedule = Schedule()
            let step = 0.005
            while !control.interrupted {
                if let end, Clock.now() >= end { break }
                let t = schedule.elapsed
                let fingers = TouchInput.shared.current
                for finger in fingers where !previous.contains(where: { abs($0.x - finger.x) < 0.08 && abs($0.y - finger.y) < 0.08 }) {
                    let drum: Drum = finger.x < 1.0 / 3 ? .kick : finger.x < 2.0 / 3 ? .snare : .hat
                    ringing.append(DrumHit(time: t, drum: drum, velocity: min(1, 0.7 + finger.size * 0.5)))
                    flashes[drum] = Clock.now()
                    stage.show(.pad(hits: flashes))
                }
                previous = fingers
                ringing.removeAll { t - $0.time > DrumKit.length($0.drum) }
                let tones = Array(ringing.flatMap { DrumKit.tones($0, at: t) }.sorted { $0.amp > $1.amp }.prefix(6))
                let total = tones.reduce(0) { $0 + $1.amp }
                if total > 0.01 { motor.play(tones, duration: step, level: tanh(total * 1.2)) }
                schedule.advance(step)
            }
        }
    }

    /// The trackpad as a mouth: the finger places F1/F2 on the vowel chart, a second finger bends the pitch.
    func vowels(pitch: Double) {
        withTouch {
            stage.show(.vowels)
            var f1 = 500.0, f2 = 1500.0, touchedAt: Double?
            let voiceSettings = VoicePlayer.Voice(pitch: pitch)
            while !control.interrupted {
                let fingers = TouchInput.shared.current
                guard let finger = fingers.first else { touchedAt = nil; Clock.sleep(until: Clock.now() + 0.003); continue }
                let target = VowelSpace.formants(x: finger.x, y: finger.y)
                if touchedAt == nil { touchedAt = Clock.now(); f1 = target.f1; f2 = target.f2 }
                f1 += (target.f1 - f1) * 0.25
                f2 += (target.f2 - f2) * 0.25
                var f0 = 210 * Vibrato(delay: 0.25, fadeIn: 0.3, depthCents: 20, rate: 5.5).factor(at: Clock.now() - touchedAt!)
                if fingers.count > 1 { f0 *= pow(2, fingers[1].x - 0.5) }
                var frame = SpeechFrame()
                frame.voiced = true; frame.f0 = f0
                frame.f1 = f1; frame.f2 = f2; frame.a1 = 1; frame.a2 = 0.55
                frame.level = min(1, 0.65 + finger.size * 0.6) * min(1, (Clock.now() - touchedAt!) / 0.04)
                var schedule = Schedule()
                schedule.advance(voice.play(frame, voice: voiceSettings))
            }
        }
    }
}
