import Foundation
import LariskaCore

/// Plays analysed speech on the motor: voiced frames as their two formants, restarted once per pitch period
/// (the restart rate is heard as the voice); unvoiced frames as hiss around the frame's own centre frequency.
struct VoicePlayer {
    let motor: Haptics
    let control: Control
    let telemetry: Telemetry
    let hop: Double

    struct Voice {
        var pitch: Double
        /// Formants move with pitch at a quarter of the ratio: a lighter voice with vowels intact.
        var formantShift: Double { 1 + (pitch - 1) * 0.25 }
        var f2Emphasis = 2.0     // F2 separates «и» from «ы»; the motor renders it weaker than F1
    }

    private enum Hiss {
        static let step = 0.005, spread = 0.15, voices = 3, level = 0.75
    }

    func speak(_ frames: [SpeechFrame], voice: Voice) {
        guard frames.count > 1 else { return }
        let length = Double(frames.count) * hop
        var schedule = Schedule()
        while schedule.elapsed < length && !control.interrupted {
            let frame = interpolated(frames, at: schedule.elapsed / hop)
            schedule.advance(play(frame, voice: voice))
        }
        telemetry.recordVoice(f0: 0, f1: 0, f2: 0, level: 0)
    }

    /// Plays one segment of `frame` and returns its length.
    @discardableResult
    func play(_ frame: SpeechFrame, voice: Voice, gain: Double = 1) -> Double {
        guard frame.level > 0 else { return Hiss.step }
        if frame.voiced {
            let period = 1 / (frame.f0 * voice.pitch)
            let tones = formantTones(frame, voice: voice)
            motor.play(tones, duration: period, level: frame.level * gain)
            telemetry.recordVoice(f0: 1 / period, f1: tones[0].hz, f2: tones[1].hz, level: frame.level)
            return period
        }
        let hiss = (0..<Hiss.voices).map { _ in
            Tone(hz: frame.noiseHz * Double.random(in: (1 - Hiss.spread)...(1 + Hiss.spread)))
        }
        motor.play(hiss, duration: Hiss.step, level: frame.level * Hiss.level * gain)
        return Hiss.step
    }

    func formantTones(_ frame: SpeechFrame, voice: Voice) -> [Tone] {
        let w1 = frame.a1, w2 = frame.a2 * voice.f2Emphasis
        return [Tone(hz: frame.f1 * voice.formantShift, amp: w1 / (w1 + w2)),
                Tone(hz: frame.f2 * voice.formantShift, amp: w2 / (w1 + w2))]
    }

    /// Linear blend between neighbouring frames, so formants glide instead of stepping every 10 ms.
    private func interpolated(_ frames: [SpeechFrame], at position: Double) -> SpeechFrame {
        let i = min(frames.count - 2, max(0, Int(position)))
        let u = min(1, max(0, position - Double(i)))
        let a = frames[i], b = frames[i + 1]
        var f = u < 0.5 ? a : b
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * u }
        f.level = mix(a.level, b.level)
        f.f1 = mix(a.f1, b.f1); f.f2 = mix(a.f2, b.f2)
        f.a1 = mix(a.a1, b.a1); f.a2 = mix(a.a2, b.a2)
        if a.voiced && b.voiced { f.f0 = mix(a.f0, b.f0) }
        return f
    }
}
