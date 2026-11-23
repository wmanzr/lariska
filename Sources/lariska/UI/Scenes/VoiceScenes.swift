import Foundation
import LariskaCore

extension SceneDrawer {
    /// The phrase types itself above the voice meters.
    func speechScene() {
        typedCaption(row: 10)
        voiceMeters(row: 13)
    }

    func sayScene(input: String, typing: Bool) {
        let field = Frame(x: 6, y: 10, width: 68, height: 3)
        box(field, typing ? Palette.amber : Palette.ghost)
        if typing {
            let cursor = blink(period: 0.4) ? "█" : " "
            canvas.text(field.x + 2, field.y + 1, "›", Palette.amber, bold: true)
            canvas.text(field.x + 4, field.y + 1, String(input.suffix(field.width - 7)) + cursor, Palette.bright, bold: true)
        }
        if state.caption != nil {
            typedCaption(row: 14)
            spectrum(row: 17, live: time - motor.voice.time < Telemetry.liveWindow)
        }
    }

    /// A mark in the middle (filled while recording) over a level meter that grows from the centre.
    func parrotScene(_ status: ParrotStatus, level: Double) {
        switch status {
        case .waitingForAccess:
            canvas.centred(12, "разреши доступ к микрофону", Palette.soft)
        case .speaking:
            voiceMeters(row: 11)
        case .listening, .recording:
            let recording = status == .recording
            canvas.put(39, 10, recording ? "●" : "◉",
                       recording ? Palette.red : Palette.ghost.mixed(Palette.gold, 0.5 + 0.5 * sin(time * 3)), bold: true)
            let half = 34, lit = min(1, sqrt(level * 12))
            for i in 0..<half {
                let on = Double(i) / Double(half) < lit
                let colour = on ? Palette.amber.mixed(Palette.red, Double(i) / Double(half)) : Palette.ghost
                canvas.put(39 - i, 13, on ? "█" : "·", colour)
                canvas.put(40 + i, 13, on ? "█" : "·", colour)
            }
        }
    }

    /// Key mark, the symbol being keyed and the decoded text on the left; the alphabet on the right,
    /// with letters that still fit the symbol lit and the exact match filled.
    func morseScene(symbol: String, text: String) {
        let keyDown = time - motor.lastTime < Telemetry.liveWindow
        canvas.put(5, 10, "◉", keyDown ? Palette.gold : Palette.ghost, bold: true)
        canvas.text(8, 10, symbol.map { $0 == "." ? "●" : "━━" }.joined(separator: " "), Palette.gold, bold: true)
        let cursor = blink(period: 0.4) ? "█" : " "
        canvas.text(5, 13, String((text + cursor).suffix(28)), Palette.bright, bold: true)
        typedCaption(row: 17)
        for (i, entry) in Morse.table.enumerated() {
            let x = 36 + (i / 8) * 11, y = 9 + i % 8
            let fits = !symbol.isEmpty && entry.code.hasPrefix(symbol), exact = entry.code == symbol
            canvas.text(x, y, String(entry.letter), exact ? Palette.night : fits ? Palette.gold : Palette.muted,
                        bg: exact ? Palette.amber : nil, bold: fits)
            canvas.text(x + 2, y, entry.code.map { $0 == "." ? "·" : "−" }.joined(), fits ? Palette.text : Palette.ghost)
        }
    }
}
