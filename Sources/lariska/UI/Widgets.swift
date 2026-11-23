import Foundation
import LariskaCore

/// Building blocks shared by the scenes.
extension SceneDrawer {
    struct Frame { var x: Int, y: Int, width: Int, height: Int }

    /// Rounded box of line characters.
    func box(_ f: Frame, _ colour: RGB) {
        let edge = String(repeating: "─", count: f.width - 2)
        canvas.text(f.x, f.y, "╭" + edge + "╮", colour)
        canvas.text(f.x, f.y + f.height - 1, "╰" + edge + "╯", colour)
        for y in (f.y + 1)..<(f.y + f.height - 1) { canvas.put(f.x, y, "│", colour); canvas.put(f.x + f.width - 1, y, "│", colour) }
    }

    /// A level from 0 to 1 as a row of `width` slanted cells, filled ones first.
    static func levelBar(_ value: Double, width: Int) -> String {
        let filled = Int((min(1, max(0, value)) * Double(width)).rounded())
        return String(repeating: "▰", count: filled) + String(repeating: "▱", count: width - filled)
    }

    /// Label on the left, value on the right, a dotted rule between; the value is drawn bold.
    func leader(_ label: String, _ value: String, x: Int, y: Int, width: Int) {
        let rule = (label + " ").padding(toLength: max(label.count + 1, width - value.count - 1), withPad: "·", startingAt: 0)
        canvas.text(x, y, rule + " ", Palette.ghost)
        canvas.text(x + rule.count + 1, y, value, Palette.bright, bold: true)
    }

    /// True for half of each period; a steady on/off pulse for blinking marks.
    func blink(period: Double = 0.5) -> Bool { Int(time / period) % 2 == 0 }

    /// The phrase types itself out as it is spoken, behind an opening quote; a closing quote when done.
    func typedCaption(row: Int, width: Int = 62) {
        guard let c = state.caption else { return }
        let progress = min(1, max(0, (time - c.start) / max(0.2, c.duration)))
        let visible = String(c.text.prefix(Int((Double(c.text.count) * progress).rounded(.up))))
        var lines: [String] = [""]
        for word in visible.split(separator: " ", omittingEmptySubsequences: false) {
            if lines[lines.count - 1].count + word.count + 1 > width { lines.append(String(word)) }
            else { lines[lines.count - 1] += (lines[lines.count - 1].isEmpty ? "" : " ") + word }
        }
        let tail = progress >= 1 ? "»" : (blink(period: 0.33) ? "▌" : " ")
        lines[lines.count - 1] += tail
        let shown = lines.suffix(2)
        if lines.count <= 2 { canvas.text(7, row, "«", Palette.amber, bold: true) }
        for (i, line) in shown.enumerated() { canvas.text(8, row + i, line, Palette.bright, bold: true) }
    }

    /// Pitch and the two strongest resonances as level bars, then their shape on a log frequency strip.
    func voiceMeters(row: Int) {
        let v = motor.voice, live = time - v.time < Telemetry.liveWindow && v.level > 0
        let meters: [(String, Double, ClosedRange<Double>)] = [
            ("F0", v.f0, 80...450), ("F1", v.f1, 150...1100), ("F2", v.f2, 600...3000),
        ]
        for (i, (label, value, range)) in meters.enumerated() {
            let y = row + i
            canvas.text(6, y, label, Palette.gold, bold: true)
            let fraction = live ? (value - range.lowerBound) / (range.upperBound - range.lowerBound) : 0
            canvas.text(10, y, Self.levelBar(fraction, width: 46), Palette.amber)
            if live { canvas.text(57, y, String(format: "%5.0f Гц", value), Palette.bright) }
        }
        spectrum(row: row + 4, live: live)
    }

    /// Envelope of the two resonances on a 100 Hz…4 kHz log axis, in density characters.
    func spectrum(row: Int, live: Bool) {
        let v = motor.voice
        let density: [Character] = [".", ":", "-", "=", "+", "*", "#", "%", "@"]
        let left = 3, right = 76
        for x in left...right {
            let hz = LogScale.motor.frequency(at: Double(x - left) / Double(right - left))
            var energy = 0.0
            if live {
                for (centre, weight) in [(v.f1, 1.0), (v.f2, 0.8)] where centre > 0 {
                    energy += weight * exp(-pow(log(hz / centre) / 0.12, 2))
                }
                energy *= v.level
            }
            let index = Int((min(1, energy) * Double(density.count - 1)).rounded())
            canvas.put(x, row, density[index], index == 0 ? Palette.ghost : Palette.ghost.mixed(Palette.gold, 0.4 + energy))
        }
        for (hz, label) in [(100.0, "100"), (1000, "1k"), (4000, "4k")] {
            let x = left + Int(LogScale.motor.position(of: hz) * Double(right - left))
            canvas.text(min(right - label.count + 1, max(left, x - label.count / 2)), row + 1, label, Palette.ghost)
        }
    }

    /// The last seconds of motor activity as a waveform of thin vertical strokes, older ones fainter.
    mutating func activityTrack(rows: Range<Int>) {
        let top = Double(rows.lowerBound * 4), height = Double(rows.count * 4)
        let centre = top + height / 2 - 0.5
        var index = 0
        for x in stride(from: 1, to: Dots.width, by: 3) {
            let t = time - Telemetry.traceSpan * Double(Dots.width - 1 - x) / Double(Dots.width - 1)
            while index + 1 < motor.trace.count, motor.trace[index + 1].time <= t { index += 1 }
            let recency = 0.3 + 0.7 * Double(x) / Double(Dots.width)
            guard index < motor.trace.count, abs(motor.trace[index].time - t) < 0.05 else {
                if x % 6 == 1 { dots.plot(Double(x), centre, Palette.ghost, weight: 0.1) }
                continue
            }
            let sample = motor.trace[index]
            let colour = Palette.amber.mixed(Palette.foam, LogScale.motor.position(of: sample.hz) * 0.6).mixed(Palette.ghost, 1 - recency)
            let reach = max(0.5, sample.level * (height / 2 - 0.5))
            dots.line(Double(x), centre - reach, Double(x), centre + reach, colour, weight: recency)
        }
    }

    /// Large block digits, 3×5 glyphs at two columns per glyph pixel, with a unit after them.
    func bigNumber(_ text: String, row: Int, suffix: String) {
        let glyphs: [Character: [String]] = [
            "0": ["###", "#.#", "#.#", "#.#", "###"], "1": [".#.", "##.", ".#.", ".#.", "###"],
            "2": ["###", "..#", "###", "#..", "###"], "3": ["###", "..#", "###", "..#", "###"],
            "4": ["#.#", "#.#", "###", "..#", "..#"], "5": ["###", "#..", "###", "..#", "###"],
            "6": ["###", "#..", "###", "#.#", "###"], "7": ["###", "..#", "..#", ".#.", ".#."],
            "8": ["###", "#.#", "###", "#.#", "###"], "9": ["###", "#.#", "###", "..#", "###"],
        ]
        let advance = 7, width = text.count * advance - 1 + suffix.count + 2
        var x = (Canvas.width - width) / 2
        for ch in text {
            if let g = glyphs[ch] {
                for (r, line) in g.enumerated() {
                    for (i, p) in line.enumerated() where p == "#" { canvas.text(x + i * 2, row + r, "██", Palette.gold) }
                }
            }
            x += advance
        }
        canvas.text(x + 1, row + 4, suffix, Palette.bright, bold: true)
    }

    /// A slow travelling highlight along a row, for decorative strokes.
    func shimmer(_ i: Int) -> RGB {
        let phase = Double(((i % 24) + 24) % 24) / 24
        return RGB(200, 110, 10).mixed(Palette.foam, 0.5 - 0.5 * cos(2 * .pi * phase))
    }
}
