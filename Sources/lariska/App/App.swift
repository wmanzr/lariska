import Foundation
import LariskaCore

/// Owns the session: terminal, renderer, keyboard, motor and the menu loop. Runs on the main thread;
/// every mode plays sound on this thread, so the motor is never shared.
final class App {
    let motor: HapticMotor
    let control: Control
    let stage = Stage()
    let telemetry: Telemetry
    let terminal: Terminal
    private let renderer: Renderer
    private let keyboard: Keyboard
    private let speakerPoll = DispatchSource.makeTimerSource(queue: .global(qos: .utility))

    /// Effective settings (file + command line) and the subset that goes back to disk.
    var settings: Settings
    var savedSettings: Settings
    var saveProblem: String?

    let analyzer = SpeechAnalyzer()
    lazy var voices = VoiceLibrary(analyzer: analyzer)

    lazy var voice = VoicePlayer(motor: motor, control: control, telemetry: telemetry, hop: analyzer.hop)
    lazy var music = MusicPlayer(motor: motor, control: control, voice: voice)
    lazy var touch = TouchInstruments(motor: motor, control: control, stage: stage, music: music, voice: voice)

    init(motor: HapticMotor, telemetry: Telemetry, control: Control, terminal: Terminal, settings: Settings, saved: Settings) {
        self.motor = motor
        self.telemetry = telemetry
        self.control = control
        self.terminal = terminal
        self.settings = settings
        self.savedSettings = saved
        renderer = Renderer(terminal: terminal, stage: stage, telemetry: telemetry)
        keyboard = Keyboard(control: control)
        motor.strength = settings.strength
    }

    func run() {
        terminal.activate()
        keyboard.start()
        renderer.start()
        voices.warmUp(phrases: [Script.greeting, Script.yourTurn, Script.sample], rap: Script.rap,
                      pattern: .night, voice: settings.voice, rate: settings.rate)
        speakerPoll.schedule(deadline: .now(), repeating: 0.5)
        speakerPoll.setEventHandler { [stage] in stage.setSpeakers(SpeakerStatus.isSilent()) }
        speakerPoll.resume()
        defer {
            speakerPoll.cancel()
            renderer.stop()
            terminal.restore()
        }
        opening()
        menu()
    }

    private func opening() {
        let start = Clock.now()
        control.anyKeySkips.store(true, ordering: .relaxed)
        stage.show(.splash(start: start))
        music.introSound(from: start)
        while !control.interrupted && Clock.now() - start < Opening.end { Clock.sleep(until: Clock.now() + 0.01) }
        control.anyKeySkips.store(false, ordering: .relaxed)
        control.reset()
    }

    private func menu() {
        var selected = 0
        let count = Act.allCases.count
        while !control.isQuitting {
            stage.show(.menu(selected: selected), title: "")
            guard let event = control.nextEvent() else { Clock.sleep(until: Clock.now() + 0.02); continue }
            switch event {
            case .up: selected = (selected + count - 1) % count
            case .down: selected = (selected + 1) % count
            case .escape: control.quit()
            case .enter: launch(Act.allCases[selected])
            case .char(let c):
                if let digit = c.wholeNumberValue {
                    let index = digit == 0 ? 9 : digit - 1
                    if index < count { selected = index; launch(Act.allCases[index]) }
                }
            default: break
            }
        }
    }

    /// Runs a mode; any error is shown on screen and the menu comes back.
    private func launch(_ act: Act) {
        control.reset()
        stage.setCaption(nil)
        do { try perform(act) } catch is CancellationError {
            // the user left while a phrase was being prepared
        } catch {
            stage.show(.message(String(describing: error)))
            control.reset()
            control.pause(2.5)
        }
        stage.setCaption(nil)
        stage.setDemoPart(nil)
        control.reset()
    }

    // MARK: Voice

    var voiceSettings: VoicePlayer.Voice { VoicePlayer.Voice(pitch: settings.pitch) }

    func isReady(_ text: String) -> Bool { voices.isReady(text, voice: settings.voice, rate: settings.rate) }

    func frames(_ text: String) throws -> [SpeechFrame] {
        try voices.frames(text, voice: settings.voice, rate: settings.rate, cancelled: { control.interrupted })
    }

    /// Shows the speech scene with the caption and speaks; the spinner appears only if the phrase isn't ready yet.
    func speak(_ text: String, title: String) throws {
        if !isReady(text) { stage.show(.preparing, title: title) }
        let f = try frames(text)
        stage.show(.speech, title: title)
        speak(f, caption: text)
    }

    /// Speaks prepared frames while `caption` types itself out on the current screen.
    func speak(_ frames: [SpeechFrame], caption text: String) {
        stage.setCaption(Caption(text: text, start: Clock.now(), duration: Double(frames.count) * analyzer.hop))
        voice.speak(frames, voice: voiceSettings)
        stage.setCaption(nil)
    }

    func rapLinesReady(_ texts: [String], pattern: BeatPattern) -> Bool {
        voices.isReady(rap: texts, voice: settings.voice, pattern: pattern)
    }

    func rapLines(_ texts: [String], pattern: BeatPattern) throws -> [RapLine] {
        try texts.map { try voices.rapLine($0, voice: settings.voice, pattern: pattern, cancelled: { control.interrupted }) }
    }

    func applySetting(_ key: Setting, by steps: Double) {
        settings[key] = settings[key] + steps * key.step
        savedSettings[key] = settings[key]
        motor.strength = settings.strength
    }

    func persistSettings() {
        do { try SettingsFile.save(savedSettings) } catch { saveProblem = "настройки не сохранены: \(error.localizedDescription)" }
    }
}
