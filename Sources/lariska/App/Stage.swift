import LariskaCore
import Synchronization

/// What the motor is doing, written by playback, read by the renderer.
final class Telemetry: Sendable {
    struct Sample: Sendable { var time: Double; var hz: Double; var level: Double }
    struct State: Sendable {
        var lastHz = 0.0, lastLevel = 0.0, lastTime = -9.0
        var actuations = 0, motorSeconds = 0.0
        var voice = (f0: 0.0, f1: 0.0, f2: 0.0, level: 0.0, time: -9.0)
        var trace: [Sample] = []        // recent activity for the seismograph
    }
    static let traceSpan = 3.0
    /// A reading younger than this counts as "sounding now".
    static let liveWindow = 0.1

    private let state = Mutex(State())
    var snapshot: State { state.withLock { $0 } }

    func recordActuation(hz: Double, level: Double, duration: Double) {
        let t = Clock.now()
        state.withLock { s in
            s.lastHz = hz; s.lastLevel = level; s.lastTime = t
            s.actuations += 1; s.motorSeconds += duration
            if let last = s.trace.last, t - last.time < 1.0 / 90 { return }
            s.trace.append(Sample(time: t, hz: hz, level: level))
            if let first = s.trace.first, t - first.time > Self.traceSpan { s.trace.removeFirst() }
        }
    }

    func recordVoice(f0: Double, f1: Double, f2: Double, level: Double) {
        let t = Clock.now()
        state.withLock { $0.voice = (f0, f1, f2, level, t) }
    }
}

/// A phrase shown karaoke-style: the whole line is visible, words light up as they are spoken.
struct Caption: Sendable {
    var text: String
    var start: Double
    var duration: Double
}

/// The screen model. Modes publish whole values; the renderer draws the latest one.
enum Screen: Sendable {
    case splash(start: Double)
    case menu(selected: Int)
    case preparing                          // speech is being rendered
    case speech
    case melody(Melody, start: Double)
    case beat(BeatPattern, start: Double, bars: Int)
    case range
    case play(smooth: Bool, endsAt: Double?)
    case pad(hits: [Drum: Double])          // last hit time per drum
    case vowels
    case parrot(ParrotStatus, levels: [Double])
    case morse(symbol: String, text: String)
    case say(input: String, typing: Bool)
    case settings(Settings, selected: Int)
    case outro
    case message(String)
}

enum ParrotStatus: Sendable { case waitingForAccess, listening, recording, speaking }

struct StageState: Sendable {
    var screen = Screen.splash(start: 0)
    var title = ""
    var demoPart: (index: Int, count: Int)?
    var caption: Caption?
    var speakersSilent: Bool?
}

final class Stage: Sendable {
    private let state = Mutex(StageState())
    var snapshot: StageState { state.withLock { $0 } }

    func show(_ screen: Screen, title: String? = nil) {
        state.withLock { s in s.screen = screen; if let title { s.title = title } }
    }
    func setDemoPart(_ part: (Int, Int)?) { state.withLock { $0.demoPart = part } }
    func setCaption(_ caption: Caption?) { state.withLock { $0.caption = caption } }
    func setSpeakers(_ silent: Bool?) { state.withLock { $0.speakersSilent = silent } }
}
