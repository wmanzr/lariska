import Foundation
import LariskaCore
import Synchronization

/// Rendered and analysed speech, shared by the playback thread and a background warm-up.
/// Each phrase is rendered once per voice and rate. A request for a phrase that is already being
/// rendered waits for that work instead of starting it again.
final class VoiceLibrary: Sendable {
    let analyzer: SpeechAnalyzer
    private struct Store {
        var frames: [String: [SpeechFrame]] = [:]
        var lines: [String: RapLine] = [:]
        var rendering: Set<String> = []
    }
    private let store = Mutex(Store())
    private let background = DispatchQueue(label: "lariska.voice", qos: .utility)

    init(analyzer: SpeechAnalyzer) { self.analyzer = analyzer }

    private static func key(_ text: String, voice: String, rate: Int) -> String { "\(voice)|\(rate)|\(text)" }
    private static func lineKey(_ text: String, voice: String, pattern: BeatPattern) -> String { "\(voice)|\(pattern.bpm)|\(text)" }

    func isReady(_ text: String, voice: String, rate: Int) -> Bool {
        store.withLock { $0.frames[Self.key(text, voice: voice, rate: rate)] != nil }
    }

    func isReady(rap texts: [String], voice: String, pattern: BeatPattern) -> Bool {
        store.withLock { s in texts.allSatisfy { s.lines[Self.lineKey($0, voice: voice, pattern: pattern)] != nil } }
    }

    /// Rendering stops early with `CancellationError` when `cancelled` turns true.
    func frames(_ text: String, voice: String, rate: Int, cancelled: () -> Bool = { false }) throws -> [SpeechFrame] {
        let key = Self.key(text, voice: voice, rate: rate)
        enum Next { case ready([SpeechFrame]), wait, render }
        while true {
            let next: Next = store.withLock { s in
                if let f = s.frames[key] { return .ready(f) }
                if s.rendering.contains(key) { return .wait }
                s.rendering.insert(key)
                return .render
            }
            switch next {
            case .ready(let f): return f
            case .wait:
                if cancelled() { throw CancellationError() }
                Thread.sleep(forTimeInterval: 0.02)
            case .render:
                do {
                    let samples = try SpeechSynth.render(text, voice: voice, rate: rate, sampleRate: analyzer.config.sampleRate,
                                                         cancelled: cancelled)
                    let f = analyzer.analyze(samples)
                    store.withLock { $0.frames[key] = f; $0.rendering.remove(key) }
                    return f
                } catch {
                    store.withLock { _ = $0.rendering.remove(key) }
                    throw error
                }
            }
        }
    }

    /// A rap line fitted to `pattern`: spoken at the rate that brings it closest to 1.5 bars, then snapped to
    /// the 16th grid. `say` duration is not proportional to rate, so a few rates are probed.
    func rapLine(_ text: String, voice: String, pattern: BeatPattern, cancelled: () -> Bool = { false }) throws -> RapLine {
        let key = Self.lineKey(text, voice: voice, pattern: pattern)
        if let line = store.withLock({ $0.lines[key] }) { return line }
        let slot = pattern.bar * 1.5 * 0.92
        var best: [SpeechFrame] = [], rate = 140.0
        for _ in 0..<3 {
            let f = try frames(text, voice: voice, rate: Int(rate), cancelled: cancelled)
            let length = Double(f.count) * analyzer.hop
            if best.isEmpty || abs(length - slot) < abs(Double(best.count) * analyzer.hop - slot) { best = f }
            rate = min(220, max(100, rate * length / slot))
        }
        let line = RapLine(frames: best, text: text, hop: analyzer.hop, slot: slot, grid: pattern.sixteenth)
        store.withLock { $0.lines[key] = line }
        return line
    }

    /// Prepares everything known in advance while the opening and the menu are on screen,
    /// so the scripted modes start at once. Failures are left for the mode itself to report.
    func warmUp(phrases: [String], rap: [String], pattern: BeatPattern, voice: String, rate: Int) {
        background.async { [self] in
            for text in phrases { _ = try? frames(text, voice: voice, rate: rate) }
            for text in rap { _ = try? rapLine(text, voice: voice, pattern: pattern) }
        }
    }
}
