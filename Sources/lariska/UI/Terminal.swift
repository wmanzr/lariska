import Foundation
import Synchronization

/// Owns the terminal: raw input, alternate screen, output. Thread-safe: the renderer writes frames,
/// the main thread takes and restores, the signal queue may restore in an emergency.
final class Terminal: Sendable {
    private struct State {
        var active = false
        var output = STDOUT_FILENO
        var savedOut: Int32 = -1, savedErr: Int32 = -1
        var savedMode = termios()
    }
    private let state = Mutex(State())

    private enum Sequence {
        // Alternate screen, hidden cursor, mouse reporting on (so touches don't select text), screen cleared.
        static let enter = "\u{1B}[?1049h\u{1B}[?25l\u{1B}[?1000h\u{1B}[?1006h\u{1B}[0m\u{1B}[2J"
        static let leave = "\u{1B}[?1006l\u{1B}[?1000l\u{1B}[0m\u{1B}[2J\u{1B}[?25h\u{1B}[?1049l"
    }

    var size: (columns: Int, rows: Int) {
        state.withLock { s in
            var w = winsize()
            return ioctl(s.output, TIOCGWINSZ, &w) == 0 && w.ws_col > 0 ? (Int(w.ws_col), Int(w.ws_row)) : (Canvas.width, Canvas.height)
        }
    }

    /// stdout/stderr are parked on /dev/null while the UI runs: MultitouchSupport logs to them when touch starts.
    func activate() {
        state.withLock { s in
            guard !s.active else { return }
            s.active = true
            fflush(stdout); fflush(stderr)
            s.savedOut = dup(STDOUT_FILENO); s.savedErr = dup(STDERR_FILENO)
            s.output = s.savedOut
            let null = open("/dev/null", O_WRONLY)
            dup2(null, STDOUT_FILENO); dup2(null, STDERR_FILENO); close(null)
            tcgetattr(STDIN_FILENO, &s.savedMode)
            var raw = s.savedMode
            raw.c_lflag &= ~tcflag_t(ICANON | ECHO | IEXTEN)   // ISIG stays on: ctrl-c still arrives as a signal
            raw.c_iflag &= ~tcflag_t(IXON)                      // ctrl-s must not freeze output
            withUnsafeMutableBytes(of: &raw.c_cc) { cc in       // ctrl-z and ctrl-\ would leave the screen half-drawn
                cc[Int(VSUSP)] = 0xFF; cc[Int(VQUIT)] = 0xFF
            }
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
            Self.writeAll(s.output, Array(Sequence.enter.utf8))
        }
    }

    func restore() {
        state.withLock { s in
            guard s.active else { return }
            s.active = false
            Self.writeAll(s.output, Array(Sequence.leave.utf8))
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &s.savedMode)   // flush: queued mouse reports must not reach the shell
            dup2(s.savedOut, STDOUT_FILENO); dup2(s.savedErr, STDERR_FILENO)
            close(s.savedOut); close(s.savedErr)
            s.output = STDOUT_FILENO
        }
    }

    /// Writes only while the UI is active, so a late frame can never land in a restored terminal.
    func write(_ bytes: [UInt8]) {
        state.withLock { s in if s.active { Self.writeAll(s.output, bytes) } }
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, bytes.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }
}

/// Turns raw stdin bytes into key events on a background thread.
final class Keyboard {
    private let control: Control

    init(control: Control) { self.control = control }

    func start() {
        let thread = Thread { [control] in
            var pending: [UInt8] = []
            while !control.isQuitting {
                guard Self.ready(50) else { continue }
                guard let byte = Self.read() else {
                    if errno == EINTR { continue }
                    control.quit(); break          // stdin closed: nothing left to read
                }
                if control.anyKeySkips.load(ordering: .relaxed) {
                    if byte == 0x1B { _ = Self.sequence() }
                    control.skip()
                    continue
                }
                if let event = Self.decode(byte, pending: &pending) { Self.dispatch(event, control) }
            }
        }
        thread.start()
    }

    private static func dispatch(_ event: KeyEvent, _ control: Control) {
        let typing = control.textEntry.load(ordering: .relaxed)
        switch event {
        case .escape:
            control.stop(); control.post(.escape)
        case .char(let c) where !typing && (c == "q" || c == "Q" || c == "й" || c == "Й"):
            control.stop(); control.post(.escape)
        case .char(" ") where !typing && control.skippable.load(ordering: .relaxed):
            control.skip()
        default:
            control.post(event)
        }
    }

    private static func decode(_ byte: UInt8, pending: inout [UInt8]) -> KeyEvent? {
        switch byte {
        case 0x1B:
            pending.removeAll()
            guard ready(30) else { return .escape }
            switch sequence() {
            case UInt8(ascii: "A"): return .up
            case UInt8(ascii: "B"): return .down
            case UInt8(ascii: "C"): return .right
            case UInt8(ascii: "D"): return .left
            default: return nil   // mouse reports, function keys
            }
        case 0x0D, 0x0A: return .enter
        case 0x7F, 0x08: return .backspace
        case 0x09: return .tab
        default:
            if byte & 0xC0 != 0x80 { pending.removeAll() }   // a new character starts: drop any stale partial one
            pending.append(byte)                              // UTF-8: Cyrillic letters arrive as two bytes
            guard let text = String(bytes: pending, encoding: .utf8), let c = text.first else { return nil }
            pending.removeAll()
            // Printable, single-width text only: no controls (incl. C1) and nothing from wide scripts or emoji.
            let printable = c.unicodeScalars.allSatisfy { $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value) && $0.value < 0x1100 }
            return printable ? .char(c) : nil
        }
    }

    /// Reads an escape sequence (ECMA-48 CSI or SS3) to its final byte.
    private static func sequence() -> UInt8? {
        var first = true
        while ready(30), let b = read() {
            if first { first = false; if b == UInt8(ascii: "[") || b == UInt8(ascii: "O") { continue } }
            if (0x40...0x7E).contains(b) { return b }
        }
        return nil
    }

    private static func ready(_ ms: Int32) -> Bool {
        var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        return poll(&fds, 1, ms) > 0
    }

    private static func read() -> UInt8? {
        var b: UInt8 = 0
        return Darwin.read(STDIN_FILENO, &b, 1) == 1 ? b : nil
    }
}
