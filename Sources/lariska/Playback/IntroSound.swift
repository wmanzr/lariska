import Foundation
import LariskaCore

extension MusicPlayer {
    /// The opening on the motor, in step with the picture: a rising hum while the outline draws, the tap as a
    /// real click, ringing glass, a whoosh while the wordmark assembles, a ping, a tick for each mute blink.
    func introSound(from start: Double) {
        func wait(until t: Double) -> Bool {
            while Clock.now() - start < t { if control.interrupted { return false }; Clock.sleep(until: Clock.now() + 0.001) }
            return true
        }
        func glide(until end: Double, _ tone: (Double) -> (hz: Double, level: Double)) {
            var schedule = Schedule()
            let length = end - (Clock.now() - start)
            while schedule.elapsed < length && !control.interrupted {
                let (hz, level) = tone(schedule.elapsed / length)
                let seg = Segment.whole(hz, near: 0.02)
                motor.play([Tone(hz: hz)], duration: seg, level: level)
                schedule.advance(seg)
            }
        }
        glide(until: Opening.trace) { p in (300 + 600 * p, 0.08 + 0.17 * p) }
        guard wait(until: Opening.tap) else { return }
        knock(0.9)
        var schedule = Schedule()
        let ringing = Opening.morph - (Clock.now() - start)
        while schedule.elapsed < ringing && !control.interrupted {
            motor.play(Segment.aligned([Tone(hz: 1320), Tone(hz: 1980, amp: 0.6)], length: 0.04), duration: 0.04,
                       level: 0.6 * exp(-schedule.elapsed / 0.25))
            schedule.advance(0.04)
        }
        glide(until: Opening.formed - 0.05) { p in (500 * pow(3.5, p), 0.12 + 0.35 * p) }
        guard wait(until: Opening.formed) else { return }
        schedule = Schedule()
        while schedule.elapsed < 0.2 && !control.interrupted {
            let seg = Segment.whole(1760, near: 0.02)
            motor.play([Tone(hz: 1760)], duration: seg, level: 0.85 * exp(-schedule.elapsed / 0.08))
            schedule.advance(seg)
        }
        for blink in [0.0, 0.45] {
            guard wait(until: Opening.mute + blink) else { return }
            tick(level: 0.35, hz: 2600)
        }
    }
}
