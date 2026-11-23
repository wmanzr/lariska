import Foundation
import LariskaCore
import Synchronization

extension App {
    func perform(_ act: Act) throws {
        let title = act.title
        switch act {
        case .demo: try demo()
        case .greeting:
            try speak(Script.greeting, title: title)
            music.chime()
        case .play:
            stage.show(.play(smooth: false, endsAt: nil), title: title)
            touch.play()
        case .pad:
            stage.show(.pad(hits: [:]), title: title)
            touch.drumPad()
        case .vowels:
            stage.show(.vowels, title: title)
            touch.vowels(pitch: settings.pitch)
        case .parrot: try parrot(title: title)
        case .morse: try morse(title: title)
        case .katyusha:
            stage.show(.melody(.katyusha, start: Clock.now()), title: title)
            music.sing(.katyusha, loop: true)
        case .beat: try beat(title: title, lines: Script.rap, bars: 3 + 2 * Script.rap.count)
        case .say: try say(title: title)
        case .range:
            stage.show(.range, title: title)
            music.sweep(seconds: 6)
        case .settings: try settingsScreen(title: title)
        }
    }

    func beat(title: String, lines texts: [String], bars: Int) throws {
        let pattern = BeatPattern.night
        if !rapLinesReady(texts, pattern: pattern) { stage.show(.preparing, title: title) }
        let lines = try rapLines(texts, pattern: pattern)
        guard !control.isStopped else { return }
        let start = Clock.now()
        stage.show(.beat(pattern, start: start, bars: bars), title: title)
        music.groove(pattern, bars: bars, rapFrom: 2, lines: lines, voiceSettings: voiceSettings) { [stage] line in
            stage.setCaption(Caption(text: line.text, start: Clock.now(), duration: line.end - line.start))
        }
        stage.setCaption(nil)
    }

    /// Mic → phrase detection → the same analysis as `say` → the motor repeats you.
    func parrot(title: String) throws {
        stage.show(.parrot(.waitingForAccess, levels: []), title: title)
        let answer = Atomic(0)   // 0 waiting, 1 granted, 2 denied
        Task { answer.store(await Microphone.requestAccess() ? 1 : 2, ordering: .relaxed) }
        while answer.load(ordering: .relaxed) == 0 && !control.isStopped { Clock.sleep(until: Clock.now() + 0.05) }
        guard !control.isStopped else { return }
        guard answer.load(ordering: .relaxed) == 1 else { throw Microphone.Failure.denied }

        let mic = Microphone()
        try mic.start(sampleRate: analyzer.config.sampleRate)
        defer { mic.stop() }
        var detector = PhraseDetector(config: { var c = PhraseDetector.Config(); c.sampleRate = analyzer.config.sampleRate; return c }())
        var levels: [Double] = [], lastSample = 0.0
        let historyLength = 40, sampleInterval = 0.05
        while !control.isStopped {
            Clock.sleep(until: Clock.now() + 0.02)
            if let phrase = detector.feed(mic.drain()) {
                stage.show(.parrot(.speaking, levels: []))
                voice.speak(analyzer.analyze(phrase), voice: voiceSettings)
                control.clearSkip()
                control.pause(0.25)
                _ = mic.drain()      // what the mic heard while the motor played
                detector.reset()
            }
            if Clock.now() - lastSample >= sampleInterval {
                lastSample = Clock.now()
                levels = Array((levels + [detector.level]).suffix(historyLength))
            }
            stage.show(.parrot(detector.isRecording ? .recording : .listening, levels: levels))
        }
    }

    /// The trackpad as a telegraph key: letters decode live, the word is spoken after a pause.
    func morse(title: String) throws {
        stage.show(.morse(symbol: "", text: ""), title: title)
        guard TouchInput.shared.start(on: motor) else { throw MotorError.noTrackpad }
        defer { TouchInput.shared.stop(on: motor) }
        var decoder = MorseDecoder()
        var pressedAt: Double?, releasedAt = Clock.now()
        while !control.isStopped {
            if !TouchInput.shared.current.isEmpty {
                if pressedAt == nil { pressedAt = Clock.now() }
                var schedule = Schedule()
                let seg = Segment.whole(700, near: 0.02)
                motor.play([Tone(hz: 700)], duration: seg, level: 0.7)
                schedule.advance(seg)
            } else {
                if let p = pressedAt { decoder.release(after: Clock.now() - p); pressedAt = nil; releasedAt = Clock.now() }
                if decoder.idle(for: Clock.now() - releasedAt) {
                    let text = decoder.text.trimmingCharacters(in: .whitespaces)
                    decoder.reset()
                    stage.show(.morse(symbol: "", text: ""))
                    let f = try frames(text.lowercased())
                    speak(f, caption: text)
                    control.clearSkip()
                    releasedAt = Clock.now()
                }
                Clock.sleep(until: Clock.now() + 0.005)
            }
            stage.show(.morse(symbol: decoder.symbol, text: decoder.text))
        }
    }

    /// Type a phrase, Enter speaks it, ↑ brings back the previous one, Esc or an empty Enter leaves.
    func say(title: String) throws {
        var input = "", previous = ""
        control.textEntry.store(true, ordering: .relaxed)
        defer { control.textEntry.store(false, ordering: .relaxed) }
        stage.show(.say(input: input, typing: true), title: title)
        while !control.isStopped {
            guard let event = control.nextEvent() else { Clock.sleep(until: Clock.now() + 0.02); continue }
            switch event {
            case .char(let c) where input.count < 60: input.append(c)
            case .backspace: if !input.isEmpty { input.removeLast() }
            case .up: input = previous
            case .escape: return
            case .enter:
                let text = input.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return }
                previous = text; input = ""
                stage.show(.say(input: "", typing: false))
                let f = try frames(text)
                speak(f, caption: text)
            default: break
            }
            stage.show(.say(input: input, typing: true))
        }
    }

    /// ↑↓ choose, ←→ adjust, Enter plays a sample; saved on exit.
    func settingsScreen(title: String) throws {
        var selected = 0
        let keys = Setting.allCases
        defer { persistSettings() }
        while !control.isStopped {
            stage.show(.settings(settings, selected: selected), title: title)
            guard let event = control.nextEvent() else { Clock.sleep(until: Clock.now() + 0.02); continue }
            switch event {
            case .up: selected = max(0, selected - 1)
            case .down: selected = min(keys.count - 1, selected + 1)
            case .left: applySetting(keys[selected], by: -1)
            case .right: applySetting(keys[selected], by: 1)
            case .enter, .char(" "):
                let f = try frames(Script.sample)
                speak(f, caption: Script.sample)
            default: break
            }
        }
    }

    // MARK: Demo

    /// Seven parts; space skips one, Esc ends the demo.
    func demo() throws {
        let parts = 7
        func part(_ index: Int, _ title: String, _ body: () throws -> Void) rethrows {
            guard !control.isStopped else { return }
            control.clearSkip()
            stage.setDemoPart((index, parts))
            stage.show(.preparing, title: title)
            try body()
        }

        let verse = Array(Script.rap.prefix(2))
        if !(isReady(Script.greeting) && isReady(Script.yourTurn) && rapLinesReady(verse, pattern: .night)) {
            stage.show(.preparing, title: "демо-версия")
        }
        _ = try frames(Script.greeting)
        _ = try frames(Script.yourTurn)
        let rap = try rapLines(verse, pattern: .night)
        control.skippable.store(true, ordering: .relaxed)

        try part(1, "привет") { try speak(Script.greeting, title: "привет") }
        part(2, "диапазон") { stage.show(.range); music.sweep(seconds: 5) }
        part(3, "катюша") { stage.show(.melody(.katyusha, start: Clock.now())); music.sing(.katyusha, loop: false) }
        part(4, "бит") {
            let start = Clock.now()
            stage.show(.beat(.night, start: start, bars: 7))
            music.groove(.night, bars: 7, rapFrom: 2, lines: rap, voiceSettings: voiceSettings) { [stage] line in
                stage.setCaption(Caption(text: line.text, start: Clock.now(), duration: line.end - line.start))
            }
            stage.setCaption(nil)
        }
        try part(5, "твой ход") {
            try speak(Script.yourTurn, title: "твой ход")
            guard !control.interrupted else { return }    // one space skips the whole part
            stage.show(.play(smooth: false, endsAt: nil))
            touch.play(seconds: 15, waitForTouch: 10)
        }
        part(6, "дрэм-пад") { stage.show(.pad(hits: [:])); touch.drumPad(seconds: 15) }
        part(7, "финал") {
            stage.show(.outro)
            music.chime()
            control.pause(6)
        }
    }
}
