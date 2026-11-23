import Foundation

struct RGB: Hashable, Sendable {
    var r: UInt8, g: UInt8, b: UInt8
    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    init(_ c: Light) {
        func ch(_ v: Double) -> UInt8 { UInt8(min(1, max(0, v)) * 255) }
        self.init(ch(c.r), ch(c.g), ch(c.b))
    }
    func mixed(_ other: RGB, _ u: Double) -> RGB {
        let u = min(1, max(0, u))
        func m(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8(Double(a) + (Double(b) - Double(a)) * u) }
        return RGB(m(r, other.r), m(g, other.g), m(b, other.b))
    }
}

enum Palette {
    static let bright = RGB(255, 240, 214), text = RGB(226, 205, 172), soft = RGB(170, 145, 110)
    static let muted = RGB(115, 96, 72), ghost = RGB(62, 52, 40)
    static let amber = RGB(255, 170, 30), gold = RGB(255, 210, 90), foam = RGB(255, 250, 238), red = RGB(235, 70, 60)
    static let night = RGB(18, 14, 10)     // tile fill for text on amber
}

struct Cell: Equatable {
    var ch: Character = " "
    var fg = Palette.text
    var bg: RGB?                            // nil: the terminal's own background
    var bold = false
}

/// 80×24 frame buffer. Each frame sends one cursor move per changed row span and wraps the whole
/// update in synchronized-output markers, so terminals that support them never show a half-drawn frame.
final class Canvas {
    static let width = 80, height = 24
    private(set) var cells = [Cell](repeating: Cell(), count: width * height)
    private var shown: [Cell]?
    private let colors = ColorEncoder()

    func clear() { cells = [Cell](repeating: Cell(), count: Self.width * Self.height) }
    func invalidate() { shown = nil }

    func put(_ x: Int, _ y: Int, _ ch: Character, _ fg: RGB, bg: RGB? = nil, bold: Bool = false) {
        guard x >= 0, y >= 0, x < Self.width, y < Self.height else { return }
        cells[y * Self.width + x] = Cell(ch: ch, fg: fg, bg: bg, bold: bold)
    }

    func text(_ x: Int, _ y: Int, _ s: String, _ fg: RGB, bg: RGB? = nil, bold: Bool = false) {
        for (i, c) in s.enumerated() { put(x + i, y, c, fg, bg: bg, bold: bold) }
    }

    func centred(_ y: Int, _ s: String, _ fg: RGB, bg: RGB? = nil, bold: Bool = false) {
        text((Self.width - s.count) / 2, y, s, fg, bg: bg, bold: bold)
    }

    func isBlank(_ x: Int, _ y: Int) -> Bool { cells[y * Self.width + x] == Cell() }

    /// Puts a glyph into a cell that holds no text yet, keeping whatever background it already has.
    func overlay(_ x: Int, _ y: Int, _ ch: Character, _ fg: RGB) {
        guard x >= 0, y >= 0, x < Self.width, y < Self.height, cells[y * Self.width + x].ch == " " else { return }
        cells[y * Self.width + x].ch = ch
        cells[y * Self.width + x].fg = fg
    }

    private struct Style: Equatable { var fg: RGB, bg: RGB?, bold: Bool }

    /// Escape sequences that bring the terminal to `canvas` from the previous frame. Per row, only the span
    /// that changed is sent: one cursor move, then runs of cells sharing a style, each run led by its style codes.
    /// The update is wrapped in synchronized-output markers so supporting terminals never show a half frame.
    func render(originX: Int, originY: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(16_384)
        for row in 0..<Self.height {
            let base = row * Self.width
            let changed = (0..<Self.width).filter { shown?[base + $0] != cells[base + $0] }
            guard let first = changed.first, let last = changed.last else { continue }
            out += Array("\u{1B}[\(originY + row + 1);\(originX + first + 1)H".utf8)

            var runStyle: Style?, run = ""
            func flush() {
                guard let style = runStyle else { return }
                out += Array((style.bold ? "\u{1B}[1m" : "\u{1B}[22m").utf8)
                out += colors.foreground(style.fg) + colors.background(style.bg) + Array(run.utf8)
                run = ""
            }
            for col in first...last {
                let c = cells[base + col], style = Style(fg: c.fg, bg: c.bg, bold: c.bold)
                if style != runStyle { flush(); runStyle = style }
                run.append(c.ch)
            }
            flush()
        }
        shown = cells
        guard !out.isEmpty else { return [] }
        return Array("\u{1B}[?2026h".utf8) + out + Array("\u{1B}[0m\u{1B}[?2026l".utf8)
    }
}

/// Colour escape codes. 24-bit where the terminal advertises it (COLORTERM); otherwise the closest of the
/// 240 xterm colours by "redmean" distance, which follows perceived difference. Owned by one renderer: no locks.
final class ColorEncoder {
    let truecolor: Bool = {
        let v = (ProcessInfo.processInfo.environment["COLORTERM"] ?? "").lowercased()
        return v == "truecolor" || v == "24bit"
    }()
    private var cache: [RGB: Int] = [:]
    private static let palette: [(Int, Int, Int)] = (16..<256).map { n in
        if n >= 232 { let g = 8 + (n - 232) * 10; return (g, g, g) }
        let levels = [0, 95, 135, 175, 215, 255], k = n - 16
        return (levels[k / 36], levels[(k / 6) % 6], levels[k % 6])
    }

    func foreground(_ c: RGB) -> [UInt8] { Array((truecolor ? "\u{1B}[38;2;\(c.r);\(c.g);\(c.b)m" : "\u{1B}[38;5;\(index(c))m").utf8) }

    func background(_ c: RGB?) -> [UInt8] {
        guard let c else { return Array("\u{1B}[49m".utf8) }
        return Array((truecolor ? "\u{1B}[48;2;\(c.r);\(c.g);\(c.b)m" : "\u{1B}[48;5;\(index(c))m").utf8)
    }

    func index(_ c: RGB) -> Int {
        if let hit = cache[c] { return hit }
        var best = 16, bestDistance = Double.infinity
        for (i, p) in Self.palette.enumerated() {
            let rm = (Double(c.r) + Double(p.0)) / 2
            let dr = Double(Int(c.r) - p.0), dg = Double(Int(c.g) - p.1), db = Double(Int(c.b) - p.2)
            let d = (2 + rm / 256) * dr * dr + 4 * dg * dg + (2 + (255 - rm) / 256) * db * db
            if d < bestDistance { bestDistance = d; best = 16 + i }
        }
        cache[c] = best
        return best
    }
}

typealias Light = (r: Double, g: Double, b: Double)

/// Additive light in half-block pixels: 80 × 48, two per cell. Dark pixels stay transparent.
struct Pixels {
    static let width = Canvas.width, height = Canvas.height * 2
    private var px = [Light](repeating: (0, 0, 0), count: width * height)

    static let amber: Light = (1.0, 0.62, 0.10), gold: Light = (1.0, 0.80, 0.33)
    static let white: Light = (1.0, 0.97, 0.90), glass: Light = (0.17, 0.13, 0.09)

    mutating func add(_ x: Int, _ y: Int, _ c: Light, _ a: Double) {
        guard a > 0.001, x >= 0, y >= 0, x < Self.width, y < Self.height else { return }
        let i = y * Self.width + x
        px[i] = (px[i].r + c.r * a, px[i].g + c.g * a, px[i].b + c.b * a)
    }

    /// Sub-pixel position spread over four pixels, so moving points glide.
    mutating func splat(_ x: Double, _ y: Double, _ c: Light, _ a: Double) {
        let x0 = Int(floor(x)), y0 = Int(floor(y)), fx = x - floor(x), fy = y - floor(y)
        add(x0, y0, c, a * (1 - fx) * (1 - fy)); add(x0 + 1, y0, c, a * fx * (1 - fy))
        add(x0, y0 + 1, c, a * (1 - fx) * fy); add(x0 + 1, y0 + 1, c, a * fx * fy)
    }

    static func roundedBox(_ x: Double, _ y: Double, halfWidth: Double, halfHeight: Double, radius: Double) -> Double {
        let qx = abs(x) - halfWidth + radius, qy = abs(y) - halfHeight + radius
        return hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius
    }

    /// Draws into the canvas: lit pixels become ▀ ▄ █ cells. Dark pixels, and cells that already hold text,
    /// are left untouched, so text drawn earlier in the frame stays on top.
    func render(into canvas: Canvas) {
        func color(_ c: Light) -> RGB? { 0.3 * c.r + 0.59 * c.g + 0.11 * c.b > 0.045 ? RGB(c) : nil }
        for cy in 0..<Canvas.height {
            for cx in 0..<Canvas.width where canvas.isBlank(cx, cy) {
                let top = color(px[cy * 2 * Self.width + cx]), bottom = color(px[(cy * 2 + 1) * Self.width + cx])
                switch (top, bottom) {
                case let (t?, b?) where t == b: canvas.put(cx, cy, "█", t)
                case let (t?, b?): canvas.put(cx, cy, "▀", t, bg: b)
                case let (t?, nil): canvas.put(cx, cy, "▀", t)
                case let (nil, b?): canvas.put(cx, cy, "▄", b)
                default: break
                }
            }
        }
    }
}
