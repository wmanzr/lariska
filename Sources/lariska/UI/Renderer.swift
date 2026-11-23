import Foundation
import LariskaCore
import Synchronization

/// Draws the latest stage and telemetry at a steady frame rate on its own thread.
final class Renderer {
    static let frameRate = 30.0

    private let terminal: Terminal
    private let stage: Stage
    private let telemetry: Telemetry
    private let running = Atomic(false)
    private let finished = DispatchSemaphore(value: 0)

    init(terminal: Terminal, stage: Stage, telemetry: Telemetry) {
        self.terminal = terminal
        self.stage = stage
        self.telemetry = telemetry
    }

    func start() {
        running.store(true, ordering: .relaxed)
        let thread = Thread { [self] in
            let canvas = Canvas()
            let memory = SceneMemory()
            var lastSize = (columns: 0, rows: 0)
            var next = Clock.now()
            while running.load(ordering: .acquiring) {
                let size = terminal.size
                if size != lastSize {
                    lastSize = size
                    canvas.invalidate()
                    terminal.write(Array("\u{1B}[0m\u{1B}[2J".utf8))
                    if size.columns < Canvas.width || size.rows < Canvas.height {
                        terminal.write(Array("\u{1B}[1;1Hокно мало: нужно \(Canvas.width) × \(Canvas.height)".utf8))
                    }
                }
                guard size.columns >= Canvas.width, size.rows >= Canvas.height else {
                    Clock.sleep(until: Clock.now() + 0.1)    // too small to draw: wait for a resize
                    next = Clock.now()
                    continue
                }
                canvas.clear()
                var frame = SceneDrawer(canvas: canvas, memory: memory, state: stage.snapshot, motor: telemetry.snapshot, time: Clock.now())
                frame.draw()
                let bytes = canvas.render(originX: max(0, (size.columns - Canvas.width) / 2),
                                          originY: max(0, (size.rows - Canvas.height) / 2))
                if !bytes.isEmpty { terminal.write(bytes) }
                next += 1 / Self.frameRate
                if next > Clock.now() { Clock.sleep(until: next) } else { next = Clock.now() }
            }
            finished.signal()
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Returns after the last frame is written, so nothing reaches a restored terminal.
    func stop() {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        finished.wait()
    }
}

/// What the screen remembers between frames. Touched only by the render thread.
final class SceneMemory {
    static let rollLength = 60, trailLength = 14
    var roll: [Int?] = Array(repeating: nil, count: rollLength)     // melody row per frame, newest last
    var trail: [Finger] = []                                          // recent positions of the first finger

    func remember(row: Int?) { roll.removeFirst(); roll.append(row) }

    func remember(finger: Finger?) {
        if let finger { trail.append(finger); if trail.count > Self.trailLength { trail.removeFirst() } }
        else if !trail.isEmpty { trail.removeFirst() }
    }
}

/// One frame: wordmark on top, the current scene, status and hints below, the activity track at the bottom.
struct SceneDrawer {
    let canvas: Canvas
    let memory: SceneMemory
    let state: StageState
    let motor: Telemetry.State
    let time: Double
    var px = Pixels()
    var dots = Dots()

    enum Layout {
        static let logo = 1, content = 9..<20, status = 21, hints = 22, track = 23..<24
        static let readoutColumn = 30
    }

    init(canvas: Canvas, memory: SceneMemory, state: StageState, motor: Telemetry.State, time: Double) {
        self.canvas = canvas; self.memory = memory; self.state = state; self.motor = motor; self.time = time
    }

    mutating func draw() {
        if case let .splash(start) = state.screen {
            Opening.draw(canvas, elapsed: time - start)
            return
        }
        Logo.draw(canvas, time: time)
        Opening.rule(canvas, 1)
        scene()
        status()
        hints()
        activityTrack(rows: Layout.track)
        dots.render(into: canvas)
        px.render(into: canvas)
    }

    private mutating func scene() {
        switch state.screen {
        case let .menu(selected): menu(selected)
        case .preparing: preparingScene()
        case .speech: speechScene()
        case let .melody(melody, start): melodyScene(melody, start: start)
        case let .beat(pattern, start, bars): beatScene(pattern, start: start, bars: bars)
        case .range: rangeScene()
        case let .play(smooth, endsAt): playScene(smooth: smooth, endsAt: endsAt)
        case let .pad(hits): padScene(hits)
        case .vowels: vowelsScene()
        case let .parrot(status, levels): parrotScene(status, level: levels.last ?? 0)
        case let .morse(symbol, text): morseScene(symbol: symbol, text: text)
        case let .say(input, typing): sayScene(input: input, typing: typing)
        case let .settings(settings, selected): settingsScene(settings, selected)
        case .outro: outroScene()
        case let .message(text): canvas.centred(13, text, Palette.red, bold: true)
        case .splash: break
        }
    }

    /// Mode badge and name, what the motor is playing, and the speaker warning.
    private func status() {
        let row = Layout.status
        if case .menu = state.screen {} else {
            let badge = state.demoPart.map { " \($0.index)/\($0.count) " } ?? " ▸ "
            canvas.text(2, row, badge, Palette.night, bg: Palette.amber, bold: true)
            canvas.text(badge.count + 4, row, String(state.title.uppercased().prefix(20)), Palette.bright, bold: true)
            let active = time - motor.lastTime < Telemetry.liveWindow
            canvas.text(Layout.readoutColumn, row, active ? String(format: "%4.0f Гц", motor.lastHz) : "   ·   ",
                        active ? Palette.bright : Palette.ghost, bold: active)
            canvas.text(Layout.readoutColumn + 9, row, Self.levelBar(active ? motor.lastLevel : 0, width: 10), Palette.amber)
        }
        if state.speakersSilent == false {
            let on = blink(period: 0.5)
            canvas.text(Canvas.width - 13, row, " звук вкл ", on ? Palette.foam : Palette.night, bg: on ? Palette.red : Palette.ghost, bold: true)
        }
    }

    private func hints() {
        let text: String
        switch state.screen {
        case .menu: text = "↑↓  ⏎  esc"
        case .play: text = "tab  esc"
        case .settings: text = "↑↓  ←→  ⏎  esc"
        case .say(_, typing: true): text = "⏎  ↑  esc"
        default: text = state.demoPart == nil ? "esc" : "space  esc"
        }
        canvas.text(2, Layout.hints, text, Palette.muted)
    }
}
