import Foundation
import LariskaCore

// lariska — the MacBook trackpad as a voice and an instrument, through its haptic motor.

func exitWithError(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("lariska: \(message)\n".utf8))
    exit(code)
}

struct Options {
    var settingsOverride: [Setting: Double] = [:]
    var voice: String?
    var test = false, sweep = false, help = false
    var phrase: [String] = []

    init(_ arguments: [String]) {
        var args = arguments[...]
        while let arg = args.popFirst() {
            switch arg {
            case "-h", "--help": help = true
            case "--test": test = true
            case "--sweep": sweep = true
            case "--voice":
                guard let v = args.popFirst() else { exitWithError("после --voice нужно имя голоса", code: 64) }
                voice = v
            default:
                if let key = Setting.allCases.first(where: { $0.flag == arg }) {
                    guard let text = args.popFirst(), let v = Double(text), key.range.contains(v) else {
                        exitWithError("\(arg): число от \(key.format(key.range.lowerBound)) до \(key.format(key.range.upperBound))", code: 64)
                    }
                    settingsOverride[key] = v
                } else if arg.hasPrefix("-") {
                    exitWithError("нет такой опции: \(arg) (справка: lariska --help)", code: 64)
                } else {
                    phrase.append(arg)
                }
            }
        }
    }

    static var usage: String {
        let options = Setting.allCases.map { "  \($0.flag) \($0.format($0.range.lowerBound))…\($0.format($0.range.upperBound))".padding(toLength: 30, withPad: " ", startingAt: 0) + $0.title }
        return (["lariska — трекпад, который говорит", "",
                 "  lariska                     меню", "  lariska \"привет\"            сказать фразу",
                 "  lariska --test              три тихих сигнала", "  lariska --sweep             весь диапазон мотора", ""]
                + options + ["  --voice Milena              голос из say -v '?'", "", "  esc — назад, ctrl-c — выход"]).joined(separator: "\n")
    }
}

let options = Options(Array(CommandLine.arguments.dropFirst()))
if options.help { print(Options.usage); exit(0) }

let loaded = SettingsFile.load()
var settings = loaded.settings
for (key, value) in options.settingsOverride { settings[key] = value }
if let voice = options.voice { settings.voice = voice }
guard SpeechSynth.hasVoice(settings.voice) else { exitWithError(SpeechSynth.Failure.noVoice(settings.voice).description) }

let control = Control()
let terminal = Terminal()
let telemetry = Telemetry()

// ctrl-c, kill or a closed window ask to quit; a second one restores the terminal and exits at once.
// The motor stops by itself: no actuation lasts longer than 100 ms.
signal(SIGPIPE, SIG_IGN)   // a dying `say` must surface as an error on write, not kill the app
let signalQueue = DispatchQueue(label: "lariska.signals")
let signalSources = [SIGINT, SIGTERM, SIGHUP].map { sig -> DispatchSourceSignal in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
    source.setEventHandler {
        if control.isQuitting { terminal.restore(); _exit(130) }
        control.quit()
    }
    source.resume()
    return source
}

let motor: HapticMotor
do { motor = try HapticMotor(telemetry: telemetry) } catch { exitWithError(String(describing: error)) }
defer { motor.close() }
motor.strength = settings.strength
pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)

let analyzer = SpeechAnalyzer()
let voice = VoicePlayer(motor: motor, control: control, telemetry: telemetry, hop: analyzer.hop)
let music = MusicPlayer(motor: motor, control: control, voice: voice)

if options.test {
    music.testBeeps()
} else if options.sweep {
    music.sweep(seconds: 5)
} else if !options.phrase.isEmpty {
    let text = options.phrase.joined(separator: " ")
    do {
        let samples = try SpeechSynth.render(text, voice: settings.voice, rate: settings.rate, sampleRate: analyzer.config.sampleRate)
        print("«\(text)»")
        voice.speak(analyzer.analyze(samples), voice: VoicePlayer.Voice(pitch: settings.pitch))
    } catch { exitWithError(String(describing: error)) }
} else {
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else { exitWithError("меню работает только в терминале; для фразы: lariska \"привет\"") }
    if terminal.size.columns < Canvas.width || terminal.size.rows < Canvas.height {
        print("окно должно быть не меньше \(Canvas.width) × \(Canvas.height)")
        while (terminal.size.columns < Canvas.width || terminal.size.rows < Canvas.height) && !control.isQuitting { usleep(200_000) }
    }
    if !control.isQuitting {
        let app = App(motor: motor, telemetry: telemetry, control: control, terminal: terminal,
                      settings: settings, saved: loaded.settings)
        app.run()
        if let problem = app.saveProblem ?? loaded.problem { FileHandle.standardError.write(Data("lariska: \(problem)\n".utf8)) }
    }
}

let stats = telemetry.snapshot
print(String(format: "%.1f с мотора · %@ импульсов · 0 динамиков", stats.motorSeconds, SceneDrawer.grouped(stats.actuations)))
_ = signalSources
