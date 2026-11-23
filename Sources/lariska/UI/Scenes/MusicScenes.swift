import Foundation
import LariskaCore

extension SceneDrawer {
    /// Piano roll: one row per note of the tune (high to low); the notes just played trail to the left.
    func melodyScene(_ melody: Melody, start: Double) {
        let rows = Array(melody.range.reversed().prefix(Layout.content.count - 1))
        let top = Layout.content.lowerBound, left = 6, length = SceneMemory.rollLength
        let elapsed = (time - start).truncatingRemainder(dividingBy: melody.length + melody.beat)
        let sounding = time - motor.lastTime < 0.1
            ? zip(melody.steps, melody.onsets).first { elapsed >= $1 && elapsed < $1 + $0.beats * melody.beat * 0.97 }?.0.note
            : nil
        memory.remember(row: sounding.flatMap { rows.firstIndex(of: $0) })

        for (i, note) in rows.enumerated() {
            let on = note == sounding
            canvas.text(2, top + i, note.name, on ? Palette.gold : Palette.ghost, bold: on)
            for x in left..<(left + length) { canvas.put(x, top + i, "·", Palette.ghost) }
        }
        for (k, row) in memory.roll.enumerated() {
            guard let row else { continue }
            let newest = k == memory.roll.count - 1
            canvas.put(left + k, top + row, newest ? "●" : "=", newest ? Palette.foam : shimmer(k / 2), bold: true)
        }
        canvas.text(69, top + 1, "♪", Palette.amber, bold: true)
        if let sounding {
            canvas.text(71, top + 1, sounding.name, Palette.bright, bold: true)
            canvas.text(69, top + 2, String(format: "%4.0f Гц", motor.lastHz), Palette.soft)
        }
    }

    /// Chord and bar on top; one lane per drum with a label that flashes on its hit, the 16 steps as dots,
    /// and a thin envelope on the right that shoots out on each hit and shrinks as it decays.
    func beatScene(_ pattern: BeatPattern, start: Double, bars: Int) {
        let t = max(0, time - start)
        let bar = Int(t / pattern.bar), playing = bar < bars
        let step = Int(t / pattern.sixteenth) % 16
        let top = Layout.content.lowerBound

        if playing {
            let chord = pattern.chord(at: t), info = String(format: "   такт %d/%d · %.0f bpm", bar + 1, bars, pattern.bpm)
            let x = (Canvas.width - chord.count - info.count) / 2
            canvas.text(x, top + 1, chord, Palette.gold, bold: true)
            canvas.text(x + chord.count, top + 1, info, Palette.muted)
        }

        let lanes: [(Drum, String)] = [(.kick, "бочка"), (.snare, "малый"), (.hat, "хэт")]
        let labelWidth = 6, spacing = 3, envelopeWidth = 8
        let gridWidth = 16 * spacing + 3
        let left = (Canvas.width - labelWidth - 2 - gridWidth - 2 - envelopeWidth) / 2 + labelWidth + 2
        func column(_ k: Int) -> Int { left + k * spacing + k / 4 }
        for (row, (drum, name)) in lanes.enumerated() {
            let y = top + 3 + row * 2
            let since = playing ? Self.sinceLastHit(drum, in: pattern, at: t) : .infinity
            let flash = max(0, 1 - since / 0.15)
            canvas.text(left - 2 - name.count, y, name, Palette.muted.mixed(Palette.gold, flash), bold: flash > 0.3)
            if let lane = pattern.lanes[drum] {
                for (k, mark) in Array(lane).enumerated() {
                    let hit = mark != ".", current = playing && k == step
                    let colour = current ? (hit ? Palette.foam : Palette.amber) : hit ? Palette.text : Palette.ghost
                    canvas.put(column(k), y, hit ? (mark == "X" ? "●" : "•") : "·", colour, bold: current && hit)
                }
            }
            let envelope = Int((Double(envelopeWidth) * exp(-since / 0.12)).rounded())
            canvas.text(column(15) + 3, y, String(repeating: "━", count: envelope), Palette.amber.mixed(Palette.foam, flash))
        }
        if playing { canvas.put(column(step), top + 8, "▴", Palette.gold) }
        if state.caption != nil { typedCaption(row: top + 9) }
    }

    /// Seconds since `drum` last struck, looking back up to one bar.
    private static func sinceLastHit(_ drum: Drum, in pattern: BeatPattern, at t: Double) -> Double {
        guard let lane = pattern.lanes.first(where: { $0.key == drum })?.value.map({ $0 }) else { return .infinity }
        let now = Int(t / pattern.sixteenth)
        for back in 0..<16 where now - back >= 0 {
            if lane[(now - back) % 16] != "." { return t - Double(now - back) * pattern.sixteenth }
        }
        return .infinity
    }

    /// Big readout of the motor's frequency, a wave that tightens as it rises, and a ruler with a marker.
    func rangeScene() {
        let active = time - motor.lastTime < 0.1
        let hz = active ? motor.lastHz : LogScale.motor.low
        let position = LogScale.motor.position(of: hz)
        bigNumber(String(Int(hz)), row: 9, suffix: "Гц")

        let wave: [Character] = ["_", ".", "-", "~", "^"]
        let cycles = 1 + 22 * position
        for i in 0..<76 {
            let v = sin(2 * .pi * cycles * Double(i) / 76 - time * 12)
            canvas.put(2 + i, 15, wave[min(wave.count - 1, Int((v + 1) / 2 * Double(wave.count)))], shimmer(i / 3 + Int(time * 10)), bold: true)
        }
        let left = 3, right = 76
        func x(_ f: Double) -> Int { left + Int(LogScale.motor.position(of: f) * Double(right - left)) }
        for i in left...right { canvas.put(i, 17, "-", Palette.ghost) }
        for (mark, label) in [(100.0, "100"), (250, "250"), (500, "500"), (1000, "1k"), (2000, "2k"), (4000, "4k")] {
            canvas.put(x(mark), 17, "+", Palette.muted)
            canvas.text(min(right - label.count + 1, max(2, x(mark) - label.count / 2)), 18, label, Palette.soft)
        }
        canvas.put(x(hz), 16, "v", Palette.amber, bold: true)
    }
}
