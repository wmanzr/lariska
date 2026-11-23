import Foundation

/// User-adjustable values. Each one's range, step and default live in `Setting`, the single source
/// for the settings screen, the command line and decoding.
public struct Settings: Sendable, Equatable {
    public var voice = "Milena"
    /// Only values the user has chosen; anything absent follows the current default, so a new default
    /// reaches everyone who never touched that setting.
    public var values: [Setting: Double] = [:]

    public init() {}

    public subscript(_ key: Setting) -> Double {
        get { values[key] ?? key.defaultValue }
        set { values[key] = key.clamp(newValue) }
    }

    public var pitch: Double { self[.pitch] }
    public var rate: Int { Int(self[.rate].rounded()) }
    public var strength: Double { self[.volume] }
}

public enum Setting: String, CaseIterable, Sendable, Codable {
    case pitch, rate, volume

    public var title: String {
        switch self {
        case .pitch: "высота"
        case .rate: "скорость"
        case .volume: "громкость"
        }
    }
    public var range: ClosedRange<Double> {
        switch self {
        case .pitch: 0.8...1.6
        case .rate: 90...200
        case .volume: 0.3...1.0          // 1.0 is the motor's nominal maximum
        }
    }
    public var step: Double {
        switch self {
        case .pitch: 0.05
        case .rate: 5
        case .volume: 0.05
        }
    }
    public var defaultValue: Double {
        switch self {
        case .pitch: 1.2
        case .rate: 145
        case .volume: 0.8
        }
    }
    public var flag: String { "--" + rawValue }

    /// Snaps to the step grid and the range; the final rounding drops binary noise like 1.2000000000000002.
    public func clamp(_ v: Double) -> Double {
        let snapped = ((v / step).rounded() * step * 1e6).rounded() / 1e6
        return min(range.upperBound, max(range.lowerBound, snapped))
    }
    public func fraction(_ v: Double) -> Double { (v - range.lowerBound) / (range.upperBound - range.lowerBound) }
    public func format(_ v: Double) -> String {
        switch self {
        case .pitch: String(format: "×%.2f", v)
        case .rate: "\(Int(v))"
        case .volume: String(format: "%.0f%%", v * 100)
        }
    }
}

extension Settings: Codable {
    public init(json: String) throws { self = try JSONDecoder().decode(Settings.self, from: Data(json.utf8)) }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    private enum Keys: String, CodingKey { case voice, values }

    /// Missing or unknown keys fall back to defaults, so files from older versions keep loading.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: Keys.self)
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? voice
        let stored = try c.decodeIfPresent([String: Double].self, forKey: .values) ?? [:]
        for (name, value) in stored { if let key = Setting(rawValue: name) { self[key] = value } }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(voice, forKey: .voice)
        try c.encode(Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }), forKey: .values)
    }
}

/// Russian vowels on the F1/F2 plane, and the mapping between that plane and a finger on the glass.
public enum VowelSpace {
    public struct Vowel: Sendable { public let letter: Character; public let f1: Double; public let f2: Double }

    public static let vowels = [
        Vowel(letter: "и", f1: 300, f2: 2300), Vowel(letter: "ы", f1: 330, f2: 1600), Vowel(letter: "у", f1: 320, f2: 800),
        Vowel(letter: "э", f1: 500, f2: 2000), Vowel(letter: "о", f1: 520, f2: 950), Vowel(letter: "а", f1: 800, f2: 1350),
    ]
    public static let f1Range = 250.0...850.0, f2Range = 650.0...2450.0

    /// Front vowels (high F2) on the left, open vowels (high F1) at the bottom, as in a phonetics chart.
    public static func position(f1: Double, f2: Double) -> (x: Double, y: Double) {
        (1 - (f2 - f2Range.lowerBound) / (f2Range.upperBound - f2Range.lowerBound),
         1 - (f1 - f1Range.lowerBound) / (f1Range.upperBound - f1Range.lowerBound))
    }

    public static func formants(x: Double, y: Double) -> (f1: Double, f2: Double) {
        let cx = min(1, max(0, x)), cy = min(1, max(0, y))
        return (f1Range.lowerBound + (1 - cy) * (f1Range.upperBound - f1Range.lowerBound),
                f2Range.lowerBound + (1 - cx) * (f2Range.upperBound - f2Range.lowerBound))
    }

    public static func nearest(x: Double, y: Double) -> Vowel {
        vowels.min { a, b in
            let pa = position(f1: a.f1, f2: a.f2), pb = position(f1: b.f1, f2: b.f2)
            return hypot(pa.x - x, pa.y - y) < hypot(pb.x - x, pb.y - y)
        }!
    }
}
