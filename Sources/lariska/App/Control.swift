import Darwin
import Synchronization

enum KeyEvent: Equatable, Sendable {
    case char(Character), enter, backspace, tab, escape, up, down, left, right
}

/// Communication from the keyboard thread and signal handlers to the playback loop:
/// flags that stop sound within one segment, and a queue of key events for the current mode.
final class Control: Sendable {
    private let stopFlag = Atomic(false), skipFlag = Atomic(false), quitFlag = Atomic(false)
    private let events = Mutex([KeyEvent]())
    /// While true, letters are text (q is not "stop").
    let textEntry = Atomic(false)
    /// While true, space skips the current demo part.
    let skippable = Atomic(false)
    /// While true, any key skips (the opening sequence).
    let anyKeySkips = Atomic(false)

    var isStopped: Bool { stopFlag.load(ordering: .relaxed) }
    var isQuitting: Bool { quitFlag.load(ordering: .relaxed) }
    var interrupted: Bool { isStopped || skipFlag.load(ordering: .relaxed) }

    func stop() { stopFlag.store(true, ordering: .relaxed) }
    func skip() { skipFlag.store(true, ordering: .relaxed) }
    func clearSkip() { skipFlag.store(false, ordering: .relaxed) }
    func quit() { quitFlag.store(true, ordering: .relaxed); stop() }

    /// Clears per-mode state before the next mode starts.
    func reset() {
        if !isQuitting { stopFlag.store(false, ordering: .relaxed) }
        if isQuitting { stop() }          // a quit that arrived while we were clearing must win
        clearSkip()
        textEntry.store(false, ordering: .relaxed)
        skippable.store(false, ordering: .relaxed)
        events.withLock { $0.removeAll() }
    }

    func post(_ event: KeyEvent) { events.withLock { $0.append(event) } }
    func nextEvent() -> KeyEvent? { events.withLock { $0.isEmpty ? nil : $0.removeFirst() } }
}

/// Monotonic time and precise waits.
enum Clock {
    private static let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()
    private static let origin = mach_absolute_time()

    static func now() -> Double {
        let start = origin   // read before the current time: the lazy global must not be initialised after it
        return Double(mach_absolute_time() - start) / ticksPerSecond
    }

    /// Kernel-timed sleep to an absolute moment; no busy waiting.
    static func sleep(until t: Double) {
        let deadline = origin + UInt64(max(0, t) * ticksPerSecond)
        if deadline > mach_absolute_time() { mach_wait_until(deadline) }
    }
}

/// Back-to-back segments scheduled against an absolute start, so timing errors never accumulate.
struct Schedule {
    let start = Clock.now()
    private(set) var elapsed = 0.0
    mutating func advance(_ dt: Double) {
        elapsed += dt
        Clock.sleep(until: start + elapsed)
    }
}

extension Control {
    /// Waits up to `seconds`, returning early when interrupted.
    func pause(_ seconds: Double) {
        let end = Clock.now() + seconds
        while Clock.now() < end && !interrupted { Clock.sleep(until: min(end, Clock.now() + 0.01)) }
    }
}
