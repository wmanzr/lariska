import Foundation

/// The ЛАРИСА wordmark: 5×5 glyphs on a pixel grid, drawn with half-blocks at 2 px per glyph pixel.
enum Logo {
    private static let glyphs: [[String]] = [
        [".####", ".#..#", ".#..#", ".#..#", "##..#"],   // Л
        [".###.", "#...#", "#####", "#...#", "#...#"],   // А
        ["####.", "#...#", "####.", "#....", "#...."],   // Р
        ["#...#", "#..##", "#.#.#", "##..#", "#...#"],   // И
        [".####", "#....", "#....", "#....", ".####"],   // С
        [".###.", "#...#", "#####", "#...#", "#...#"],   // А
    ]
    static let scale = 2
    static let rows: [String] = (0..<5).map { r in glyphs.map { $0[r] }.joined(separator: ".") }
    static let width = rows[0].count * scale
    static let topPixel = 2
    static let originX = (Pixels.width - width) / 2
    /// Row colours, gold at the top to deep amber at the bottom.
    static let rowColours = [Palette.gold, Palette.gold, Palette.amber, Palette.amber, RGB(210, 120, 15)]
    static let tint: [Light] = rowColours.map { (Double($0.r) / 255, Double($0.g) / 255, Double($0.b) / 255) }

    /// Every lit pixel with its glyph row (for the colour gradient).
    static let pixels: [(x: Int, y: Int, row: Int)] = rows.enumerated().flatMap { r, line in
        line.enumerated().flatMap { i, ch -> [(Int, Int, Int)] in
            guard ch == "#" else { return [] }
            return (0..<scale).flatMap { dx in (0..<scale).map { dy in (originX + i * scale + dx, topPixel + r * scale + dy, r) } }
        }
    }

    /// The steady wordmark in cells, with a diagonal band of light sweeping across it.
    static func draw(_ canvas: Canvas, time t: Double) {
        let left = originX, top = topPixel / 2
        let sweep = Int(t * 30) % (width + 40) - 20
        for (r, line) in rows.enumerated() {
            for (i, ch) in line.enumerated() where ch == "#" {
                for k in 0..<scale {
                    let x = left + i * scale + k
                    let shine = max(0, 1 - Double(abs(x - left - sweep - r)) / 6)
                    canvas.put(x, top + r, "█", rowColours[r].mixed(Palette.foam, shine * 0.8))
                }
            }
        }
    }
}

/// Opening sequence: a glowing trackpad outline traces itself, a tap sends vibration rings across the
/// glass, the rings break into particles that assemble the wordmark, then a muted-speaker badge blinks twice.
enum Opening {
    static let trace = 0.4, tap = 0.55, morph = 1.15, morphLength = 0.45, formed = 1.85, mute = 2.05, end = 2.95

    private static let centre = (x: 39.5, y: 23.5)
    private static let pad = (halfWidth: 26.0, halfHeight: 15.0, radius: 5.0)
    private static let ringSpeed = 46.0, ringSpacing = 7.0

    private static func clamp01(_ x: Double) -> Double { max(0, min(1, x)) }
    private static func smooth(_ x: Double) -> Double { let p = clamp01(x); return p * p * (3 - 2 * p) }
    private static func easeInOut(_ x: Double) -> Double { let p = clamp01(x); return p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2 }
    private static func mix(_ a: Light, _ b: Light, _ u: Double) -> Light { (a.r + (b.r - a.r) * u, a.g + (b.g - a.g) * u, a.b + (b.b - a.b) * u) }
    private static func hash(_ n: Int) -> Double { let v = sin(Double(n) * 12.9898) * 43758.5453; return v - floor(v) }

    static func draw(_ canvas: Canvas, elapsed t: Double) {
        var px = Pixels()
        let fade = 1 - smooth((t - morph) / 0.5)
        if fade > 0 { trackpad(&px, t, fade) }
        particles(&px, t)
        if t >= mute { badge(&px, t - mute) }
        px.render(into: canvas)
        rule(canvas, smooth((t - formed) / 0.3))
    }

    private static func trackpad(_ px: inout Pixels, _ t: Double, _ alpha: Double) {
        let traced = easeInOut(t / trace), fill = smooth((t - 0.25) / 0.35), tau = t - tap
        for y in 0..<Pixels.height {
            for x in 0..<Pixels.width {
                let dx = Double(x) - centre.x, dy = Double(y) - centre.y
                let d = Pixels.roundedBox(dx, dy, halfWidth: pad.halfWidth, halfHeight: pad.halfHeight, radius: pad.radius)
                guard d < 6 else { continue }
                let r = hypot(dx, dy)
                // Outline drawn from the bottom centre up both sides.
                let along = acos(max(-1, min(1, dy / max(r, 1e-6)))) / .pi
                if along <= traced {
                    let core = exp(-abs(d) / 0.55), halo = 0.28 * exp(-abs(d) / 2.6)
                    let head = t < trace + 0.12 ? exp(-pow((along - traced) * 11, 2)) * 1.4 : 0
                    let hit = tau > 0 ? exp(-pow((ringSpeed * tau - r) / 3, 2)) * exp(-tau / 0.8) : 0
                    px.add(x, y, mix(Pixels.amber, Pixels.white, min(1, head * 0.7 + hit)), (core * 1.25 + halo) * (0.9 + head + hit) * alpha)
                }
                guard d < 0 else { continue }
                let inner = clamp01(-d / 1.6)
                px.add(x, y, Pixels.glass, fill * (0.75 + 0.5 * (0.5 - dy / 30)) * inner * alpha)
                let sheen = (t - 0.3) / 0.7 * 120 - 60
                px.add(x, y, Pixels.white, exp(-pow((dx * 0.7 + dy - sheen) / 5, 2)) * 0.16 * clamp01(1 - abs(t - 0.65) / 0.4) * inner * alpha)
                guard tau > 0 else { continue }
                px.add(x, y, Pixels.white, exp(-r * r / (2 * pow(1.2 + 10 * tau, 2))) * max(0, 1 - tau / 0.3) * 1.3 * alpha)
                let front = ringSpeed * tau
                if r < front {
                    let wave = pow(max(0, cos((front - r) / ringSpacing * 2 * .pi)), 4) * exp(-(front - r) / 20) * exp(-tau / 0.75)
                    px.add(x, y, Pixels.gold, wave * 1.1 * inner * alpha)
                }
            }
        }
    }

    /// Each wordmark pixel starts on the rings and arcs to its place.
    private static func particles(_ px: inout Pixels, _ t: Double) {
        let glint = -10 + (t - formed) / 0.35 * 100
        for (i, p) in Logo.pixels.enumerated() {
            let progress = (t - morph - hash(i) * 0.22) / morphLength
            guard progress > 0 else { continue }
            let tint = Logo.tint[p.row]
            if progress >= 1 {
                let arrival = max(0, 1 - (progress - 1) * morphLength / 0.2)
                let shine = t > formed ? exp(-pow((Double(p.x) - glint) / 4, 2)) * 0.8 : 0
                px.add(p.x, p.y, mix(tint, Pixels.white, min(1, arrival * 0.8 + shine)), 1)
                continue
            }
            let angle = atan2(Double(p.y) - centre.y, Double(p.x) - centre.x) + (hash(i + 999) - 0.5) * 1.6
            let r0 = 6 + hash(i + 77) * 16
            let sx = centre.x + cos(angle) * r0, sy = centre.y + sin(angle) * r0
            var nx = -(Double(p.y) - sy), ny = Double(p.x) - sx
            let norm = max(hypot(nx, ny), 1e-6); nx /= norm; ny /= norm
            let swirl = (hash(i + 5) - 0.5) * 18
            func position(_ u: Double) -> (Double, Double) {
                let s = sin(u * .pi) * swirl
                return (sx + (Double(p.x) - sx) * u + nx * s, sy + (Double(p.y) - sy) * u + ny * s)
            }
            let u = easeInOut(progress)
            let (x, y) = position(u), (tx, ty) = position(max(0, u - 0.06))
            px.splat(x, y, mix(Pixels.white, tint, u), 1)
            px.splat(tx, ty, mix(Pixels.white, tint, u), 0.35)
        }
    }

    private static let speaker = [
        ".......##.........", "......###.........", ".....####..##...##", "#########...##.##.", "#########....###..",
        "#########....###..", "#########...##.##.", ".....####..##...##", "......###.........", ".......##.........",
    ]

    /// macOS-style volume badge with a crossed-out speaker, blinking twice, centred below the wordmark.
    private static func badge(_ px: inout Pixels, _ m: Double) {
        func pulse(_ a: Double, _ b: Double) -> Double { smooth((m - a) / 0.05) * (1 - smooth((m - b + 0.05) / 0.05)) }
        let alpha = max(pulse(0, 0.25), pulse(0.45, 0.7))
        guard alpha > 0 else { return }
        let cy = 31.5, half = (w: 13.0, h: 8.0)
        for y in Int(cy - half.h - 2)...Int(cy + half.h + 2) {
            for x in Int(centre.x - half.w - 2)...Int(centre.x + half.w + 2) {
                let d = Pixels.roundedBox(Double(x) - centre.x, Double(y) - cy, halfWidth: half.w, halfHeight: half.h, radius: 4)
                if d < 0 { px.add(x, y, (0.2, 0.17, 0.14), alpha * clamp01(-d / 1.2)) }
                px.add(x, y, Pixels.amber, exp(-abs(d) / 0.6) * 0.25 * alpha)
            }
        }
        for (r, row) in speaker.enumerated() {
            for (c, ch) in row.enumerated() where ch == "#" { px.add(Int(centre.x) - 8 + c, Int(cy) - 4 + r, Pixels.white, alpha) }
        }
    }

    /// The rule under the wordmark, drawn outwards from the centre, with the tagline once complete.
    static func rule(_ canvas: Canvas, _ grow: Double) {
        guard grow > 0 else { return }
        let row = Logo.topPixel / 2 + 6, half = Double(Logo.width) / 2 * grow
        for x in Logo.originX..<(Logo.originX + Logo.width) where abs(Double(x) - 39.5) <= half { canvas.put(x, row, "─", Palette.ghost) }
        guard grow >= 1 else { return }
        let tag = "  говорит трекпад  "
        canvas.text(Logo.originX + Logo.width - tag.count - 1, row, tag, Palette.soft)
    }
}
