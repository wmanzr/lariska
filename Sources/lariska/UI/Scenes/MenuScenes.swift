import Foundation
import LariskaCore

extension SceneDrawer {
    /// Modes in one column; the selected one sits on an amber bar with a blinking pointer.
    func menu(_ selected: Int) {
        let column = 30, width = 24
        for (i, act) in Act.allCases.enumerated() {
            let y = Layout.content.lowerBound + i
            let key = i < 9 ? "\(i + 1)" : i == 9 ? "0" : " "
            if i == selected {
                let label = " \(key)  \(act.title)"
                canvas.text(column - 2, y, label.padding(toLength: width, withPad: " ", startingAt: 0), Palette.night, bg: Palette.amber, bold: true)
                if blink(period: 0.33) { canvas.put(column - 4, y, "▸", Palette.amber, bold: true) }
            } else {
                canvas.text(column - 1, y, key, Palette.ghost)
                canvas.text(column + 2, y, act.title, Palette.text)
            }
        }
    }

    /// A thin ring of dots with a bright head running round it and a fading tail.
    mutating func preparingScene() {
        let centre = (x: 79.5, y: 14.0 * 4 + 1.5), radius = 10.0, count = 40, tail = 26
        let head = Int(time * 1.1 * Double(count)) % count
        for k in 0..<tail {
            let i = (head - k + count) % count
            let angle = 2 * Double.pi * Double(i) / Double(count) - .pi / 2
            let fade = 1 - Double(k) / Double(tail)
            let colour = k < 2 ? Palette.foam : Palette.muted.mixed(Palette.gold, fade)
            for r in k < 6 ? [radius - 1, radius] : [radius] {       // the head is two dots thick
                dots.plot(centre.x + cos(angle) * r, centre.y + sin(angle) * r, colour, weight: fade)
            }
        }
    }

    func settingsScene(_ settings: Settings, _ selected: Int) {
        for (i, key) in Setting.allCases.enumerated() {
            let y = 10 + i * 2, on = i == selected, value = settings[key]
            if on && blink(period: 0.33) { canvas.put(7, y, "▸", Palette.amber, bold: true) }
            canvas.text(10, y, key.title, on ? Palette.gold : Palette.muted, bold: on)
            let width = 36, knob = Int(min(1, max(0, key.fraction(value))) * Double(width - 1))
            for x in 0..<width {
                if x == knob { canvas.put(22 + x, y, "●", on ? Palette.foam : Palette.text, bold: true) }
                else { canvas.put(22 + x, y, "─", x < knob ? Palette.amber : Palette.ghost) }
            }
            canvas.text(61, y, key.format(value), on ? Palette.bright : Palette.muted, bold: on)
        }
        typedCaption(row: 17)
    }

    /// A small trackpad with rings rolling out from its centre, and the session's numbers.
    func outroScene() {
        let pad = Frame(x: 5, y: 9, width: 22, height: 9)
        box(pad, Palette.soft)
        let density: [Character] = [".", ":", "-", "=", "+", "*", "#"]
        let cx = Double(pad.width - 2) / 2, cy = Double(pad.height - 2) / 2
        for y in 0..<(pad.height - 2) {
            for x in 0..<(pad.width - 2) {
                let d = hypot((Double(x) - cx) / 2, Double(y) - cy)
                let wave = max(0, sin(d * 1.3 - time * 5)) * max(0, 1 - d / 7)
                guard wave > 0.1 else { continue }
                canvas.put(pad.x + 1 + x, pad.y + 1 + y, density[min(density.count - 1, Int(wave * Double(density.count)))],
                           Palette.ghost.mixed(Palette.gold, wave))
            }
        }
        let rows: [(String, String)] = [
            ("динамики", "0"),
            ("импульсы", Self.grouped(motor.actuations)),
            ("мотор", String(format: "%.1f с", motor.motorSeconds)),
        ]
        for (i, row) in rows.enumerated() { leader(row.0, row.1, x: 32, y: 11 + i, width: 42) }
    }

    static func grouped(_ n: Int) -> String {
        let digits = Array(String(n))
        return String(digits.enumerated().flatMap { i, d in (digits.count - i) % 3 == 0 && i > 0 ? [" ", d] : [d] })
    }
}
