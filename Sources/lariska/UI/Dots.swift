import Foundation

/// Fine line graphics in Braille dots: 2 × 4 dots per cell, 160 × 96 on the canvas, one colour per cell
/// (the strongest one plotted into it). Dots are about square on screen, so circles stay round.
struct Dots {
    static let width = Canvas.width * 2, height = Canvas.height * 4
    private var bits = [UInt8](repeating: 0, count: Canvas.width * Canvas.height)
    private var colours = [RGB?](repeating: nil, count: Canvas.width * Canvas.height)
    private var weights = [Double](repeating: 0, count: Canvas.width * Canvas.height)

    // Braille dot numbering: left column 1, 2, 3, 7; right column 4, 5, 6, 8.
    private static let bit: [[UInt8]] = [[0x01, 0x08], [0x02, 0x10], [0x04, 0x20], [0x40, 0x80]]

    mutating func plot(_ x: Int, _ y: Int, _ colour: RGB, weight: Double = 1) {
        guard x >= 0, y >= 0, x < Self.width, y < Self.height else { return }
        let cell = (y / 4) * Canvas.width + x / 2
        bits[cell] |= Self.bit[y % 4][x % 2]
        if weight >= weights[cell] { weights[cell] = weight; colours[cell] = colour }
    }

    mutating func plot(_ x: Double, _ y: Double, _ colour: RGB, weight: Double = 1) {
        guard x.isFinite, y.isFinite, abs(x) < 1e6, abs(y) < 1e6 else { return }
        plot(Int(x.rounded()), Int(y.rounded()), colour, weight: weight)
    }

    /// Connected line between two points (Bresenham), so curves never break into dots.
    mutating func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ colour: RGB, weight: Double = 1) {
        guard [x0, y0, x1, y1].allSatisfy({ $0.isFinite && abs($0) < 1e6 }) else { return }
        var x = Int(x0.rounded()), y = Int(y0.rounded())
        let tx = Int(x1.rounded()), ty = Int(y1.rounded())
        let dx = abs(tx - x), dy = -abs(ty - y), sx = x < tx ? 1 : -1, sy = y < ty ? 1 : -1
        var err = dx + dy
        while true {
            plot(x, y, colour, weight: weight)
            if x == tx && y == ty { return }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
        }
    }

    /// Circle outline, only inside `clip` (dot bounds, inclusive).
    mutating func circle(_ cx: Double, _ cy: Double, radius: Double, _ colour: RGB,
                         clip: (x: Int, y: Int, maxX: Int, maxY: Int)) {
        let steps = max(16, Int(radius * 6))
        for k in 0..<steps {
            let a = 2 * Double.pi * Double(k) / Double(steps)
            let x = Int((cx + cos(a) * radius).rounded()), y = Int((cy + sin(a) * radius).rounded())
            if x >= clip.x, x <= clip.maxX, y >= clip.y, y <= clip.maxY { plot(x, y, colour) }
        }
    }

    /// Draws into cells without text, keeping their background, so text stays on top and fills show through.
    func render(into canvas: Canvas) {
        for cell in bits.indices where bits[cell] != 0 {
            guard let colour = colours[cell], let scalar = Unicode.Scalar(0x2800 + UInt32(bits[cell])) else { continue }
            canvas.overlay(cell % Canvas.width, cell / Canvas.width, Character(scalar), colour)
        }
    }
}
