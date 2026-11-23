import Foundation

public enum Morse {
    /// Russian Morse code.
    public static let table: [(letter: Character, code: String)] = [
        ("А", ".-"), ("Б", "-..."), ("В", ".--"), ("Г", "--."), ("Д", "-.."), ("Е", "."), ("Ж", "...-"), ("З", "--.."),
        ("И", ".."), ("Й", ".---"), ("К", "-.-"), ("Л", ".-.."), ("М", "--"), ("Н", "-."), ("О", "---"), ("П", ".--."),
        ("Р", ".-."), ("С", "..."), ("Т", "-"), ("У", "..-"), ("Ф", "..-."), ("Х", "...."), ("Ц", "-.-."), ("Ч", "---."),
        ("Ш", "----"), ("Щ", "--.-"), ("Ъ", "--.--"), ("Ы", "-.--"), ("Ь", "-..-"), ("Э", "..-.."), ("Ю", "..--"), ("Я", ".-.-"),
    ]
    static let decode = Dictionary(uniqueKeysWithValues: table.map { ($0.code, $0.letter) })
}

/// Key presses → text. Timings in seconds, tuned for a finger on glass.
public struct MorseDecoder: Sendable {
    public struct Timing: Sendable {
        public var dash = 0.22, letterGap = 0.55, wordGap = 1.4, speakAfter = 2.8
        public init() {}
    }

    public let timing: Timing
    public private(set) var symbol = ""
    public private(set) var text = ""

    public init(timing: Timing = Timing()) { self.timing = timing }

    public mutating func release(after duration: Double) {
        symbol += duration < timing.dash ? "." : "-"
    }

    /// Call while the key is up. Returns true once the pause is long enough to speak the text.
    public mutating func idle(for gap: Double) -> Bool {
        if !symbol.isEmpty, gap >= timing.letterGap {
            text.append(Morse.decode[symbol] ?? "?")
            symbol = ""
        }
        if symbol.isEmpty, !text.isEmpty, text.last != " ", gap >= timing.wordGap { text.append(" ") }
        return symbol.isEmpty && !text.trimmingCharacters(in: .whitespaces).isEmpty && gap >= timing.speakAfter
    }

    public mutating func reset() { symbol = ""; text = "" }
}
