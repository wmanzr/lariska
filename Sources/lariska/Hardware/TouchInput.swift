import Foundation
import Synchronization

/// One finger on the glass: position normalised to 0…1 (y up) and contact size.
struct Finger: Sendable, Equatable { var x = 0.0, y = 0.0, size = 0.0 }

/// Fingers on the motor's trackpad, delivered by MultitouchSupport on its own thread.
final class TouchInput: Sendable {
    static let shared = TouchInput()

    // Contact record layout of the frame callback (96 bytes per finger).
    private enum Record {
        static let stride = 96, state = 20, x = 32, y = 36, size = 48
        static let touching: ClosedRange<Int32> = 3...5
        static let maxFingers = 10
    }

    private let fingers = Mutex([Finger]())
    private init() {}

    /// Fingers sorted left to right.
    var current: [Finger] { fingers.withLock { $0 } }

    private static let callback: MultitouchAPI.FrameCallback = { _, data, count, _, _ in
        var found: [Finger] = []
        if let data, count > 0 {
            for i in 0..<min(Int(count), Record.maxFingers) {
                let record = data.advanced(by: i * Record.stride)
                guard Record.touching.contains(record.load(fromByteOffset: Record.state, as: Int32.self)) else { continue }
                // The record layout is private and may change; anything non-finite is dropped and the rest clamped.
                let x = Double(record.load(fromByteOffset: Record.x, as: Float.self))
                let y = Double(record.load(fromByteOffset: Record.y, as: Float.self))
                let size = Double(record.load(fromByteOffset: Record.size, as: Float.self))
                guard x.isFinite, y.isFinite, size.isFinite else { continue }
                found.append(Finger(x: min(1, max(0, x)), y: min(1, max(0, y)), size: min(1, max(0, size))))
            }
        }
        found.sort { $0.x < $1.x }
        TouchInput.shared.fingers.withLock { $0 = found }
        return 0
    }

    private func devices(of motor: HapticMotor, _ api: MultitouchAPI) -> [UnsafeMutableRawPointer] {
        (0..<CFArrayGetCount(motor.devices)).compactMap { i in
            guard let raw = CFArrayGetValueAtIndex(motor.devices, i) else { return nil }
            let device = UnsafeMutableRawPointer(mutating: raw)
            var id: UInt64 = 0
            return api.deviceID(device, &id) == 0 && id == motor.deviceID ? device : nil
        }
    }

    func start(on motor: HapticMotor) -> Bool {
        guard let api = MultitouchAPI.shared, let register = api.registerCallback, let start = api.deviceStart else { return false }
        let found = devices(of: motor, api)
        for device in found { register(device, Self.callback); start(device, 0) }
        return !found.isEmpty
    }

    func stop(on motor: HapticMotor) {
        guard let api = MultitouchAPI.shared else { return }
        for device in devices(of: motor, api) {
            api.unregisterCallback?(device, Self.callback)
            api.deviceStop?(device)
        }
        fingers.withLock { $0 = [] }
    }
}
