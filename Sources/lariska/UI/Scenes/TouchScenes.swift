import Foundation
import LariskaCore

extension SceneDrawer {
    private var fingers: [Finger] { TouchInput.shared.current }

    private func position(_ x: Double, _ y: Double, in f: Frame) -> (Int, Int) {
        (f.x + 1 + Int(min(1, max(0, x)) * Double(f.width - 3)), f.y + 1 + Int((1 - min(1, max(0, y))) * Double(f.height - 3)))
    }

    /// Current fingers as @, the first finger's recent path as a fading trail.
    private func drawFingers(in f: Frame) {
        memory.remember(finger: fingers.first)
        for (k, p) in memory.trail.enumerated() {
            let (x, y) = position(p.x, p.y, in: f)
            canvas.put(x, y, "·", shimmer(k * 2), bold: true)
        }
        for finger in fingers {
            let (x, y) = position(finger.x, finger.y, in: f)
            canvas.put(x, y, "@", Palette.foam, bold: true)
        }
    }

    func playScene(smooth: Bool, endsAt: Double?) {
        let pad = Frame(x: 3, y: 9, width: 44, height: 11)
        box(pad, fingers.isEmpty ? Palette.muted : Palette.amber)
        if !smooth {
            let notes = TouchInstruments.scale
            for i in 1..<notes.count {
                let x = pad.x + 1 + i * (pad.width - 2) / notes.count
                for y in (pad.y + 1)..<(pad.y + pad.height - 1) { canvas.put(x, y, "┊", Palette.ghost) }
            }
            for (i, note) in notes.enumerated() {
                canvas.text(pad.x + 2 + i * (pad.width - 2) / notes.count, pad.y + pad.height - 2, note.name, Palette.ghost)
            }
        }
        drawFingers(in: pad)
        let sounding = !fingers.isEmpty && time - motor.lastTime < 0.1
        if fingers.isEmpty && time - motor.lastTime > 1 {
            canvas.put(pad.x + pad.width / 2 - 1, pad.y + pad.height / 2, "◉", Palette.ghost.mixed(Palette.gold, 0.5 + 0.5 * sin(time * 4)), bold: true)
        }
        let side = 52
        canvas.text(side, 10, smooth ? "плавно" : "ноты", Palette.gold, bold: true)
        if sounding {
            canvas.text(side, 12, Note(nearest: motor.lastHz).name, Palette.bright, bold: true)
            canvas.text(side, 13, String(format: "%4.0f Гц", motor.lastHz), Palette.soft)
        }
        canvas.text(side, 15, Self.levelBar(sounding ? motor.lastLevel : 0, width: 24), Palette.amber)
        if let endsAt { canvas.text(side, 17, Self.levelBar((endsAt - time) / 15, width: 24), Palette.gold) }
    }

    /// Three tall pads; a hit lights the frame and sends rings rolling out from the pad's centre.
    mutating func padScene(_ hits: [Drum: Double]) {
        let names: [(Drum, String)] = [(.kick, "бочка"), (.snare, "малый"), (.hat, "хэт")]
        let top = Layout.content.lowerBound, height = 9
        for (i, (drum, name)) in names.enumerated() {
            let x0 = 4 + i * 25, width = 22
            let age = hits[drum].map { time - $0 } ?? .infinity
            let glow = max(0, 1 - age / 0.3)
            let frame = Palette.ghost.mixed(Palette.gold, glow)
            for y in top..<(top + height) {
                for x in x0..<(x0 + width) {
                    let edgeY = y == top || y == top + height - 1, edgeX = x == x0 || x == x0 + width - 1
                    if edgeY || edgeX { canvas.put(x, y, edgeY && edgeX ? "+" : edgeY ? "-" : "|", frame) }
                }
            }
            canvas.text(x0 + (width - name.count) / 2, top + height / 2, name, Palette.text.mixed(Palette.foam, glow), bold: true)
            ripples(since: age, inside: Frame(x: x0, y: top, width: width, height: height))
        }
        for finger in fingers {
            canvas.put(4 + Int(finger.x * 71), top + 1 + Int((1 - finger.y) * Double(height - 3)), "@", Palette.foam, bold: true)
        }
    }

    private enum Ripple {
        static let life = 0.5, speed = 70.0, rings = 3, spacing = 0.07   // seconds; dots per second
    }

    /// Rings spreading from the centre of `tile`, clipped to its inside: near-white at first, then gold, then gone.
    private mutating func ripples(since age: Double, inside tile: Frame) {
        let clip = (x: (tile.x + 1) * 2, y: (tile.y + 1) * 4, maxX: (tile.x + tile.width - 1) * 2 - 1, maxY: (tile.y + tile.height - 1) * 4 - 1)
        let centre = (x: Double(tile.x * 2 + tile.width), y: Double(tile.y * 4 + tile.height * 2))
        for ring in 0..<Ripple.rings {
            let ringAge = age - Double(ring) * Ripple.spacing
            guard ringAge > 0, ringAge < Ripple.life else { continue }
            let fade = ringAge / Ripple.life
            let colour = fade < 0.3 ? Palette.foam.mixed(Palette.gold, fade / 0.3) : Palette.gold.mixed(Palette.ghost, (fade - 0.3) / 0.7)
            dots.circle(centre.x, centre.y, radius: 2 + ringAge * Ripple.speed, colour, clip: clip)
        }
    }

    func vowelsScene() {
        let pad = Frame(x: 3, y: 9, width: 48, height: 11)
        box(pad, fingers.isEmpty ? Palette.muted : Palette.amber)
        let nearest = fingers.first.map { VowelSpace.nearest(x: $0.x, y: $0.y).letter }
        for v in VowelSpace.vowels {
            let p = VowelSpace.position(f1: v.f1, f2: v.f2)
            let (x, y) = position(p.x, p.y, in: pad)
            canvas.put(x, y, v.letter, v.letter == nearest ? Palette.gold : Palette.muted, bold: v.letter == nearest)
        }
        drawFingers(in: pad)
        let v = motor.voice, live = nearest != nil && time - v.time < 0.1
        let side = 56
        if let nearest, live { canvas.text(side, 10, String(nearest).uppercased(), Palette.gold, bold: true) }
        for (i, (label, value)) in [("F1", v.f1), ("F2", v.f2), ("F0", v.f0)].enumerated() {
            canvas.text(side, 13 + i, label, Palette.muted)
            if live { canvas.text(side + 4, 13 + i, String(format: "%4.0f", value), Palette.bright) }
        }
    }
}
