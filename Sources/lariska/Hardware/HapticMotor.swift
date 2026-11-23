import Foundation
import LariskaCore

/// Anything that can play a short chord of sine tones. Lets playback code run against a fake in tests.
protocol Haptics: AnyObject {
    func play(_ tones: [Tone], duration: Double, level: Double)
}

enum MotorError: Error, CustomStringConvertible {
    case unavailable, noTrackpad, noActuator
    var description: String {
        switch self {
        case .unavailable: "MultitouchSupport недоступен в этой версии macOS"
        case .noTrackpad: "трекпад не найден"
        case .noActuator: "у трекпада нет Force Touch"
        }
    }
}

/// The trackpad's actuator. Not thread-safe: only the playback thread may call `play`.
final class HapticMotor: Haptics {
    enum Limits {
        static let duration = 0.0005...0.1      // seconds per actuation
        static let frequency = 40.0...5000.0
    }

    let deviceID: UInt64
    let devices: CFArray                       // kept alive for touch input on the same device
    /// User cap on strength, 0…1, where 1 is the motor's nominal maximum.
    var strength = 1.0
    private let api: MultitouchAPI
    private let actuator: CFTypeRef
    private let telemetry: Telemetry
    private var closed = false

    init(telemetry: Telemetry) throws {
        guard let api = MultitouchAPI.shared else { throw MotorError.unavailable }
        guard let found = api.devices(), !found.entries.isEmpty else { throw MotorError.noTrackpad }
        for entry in found.entries {
            if let ref = api.actuatorCreate(entry.id)?.takeRetainedValue(), api.actuatorOpen(ref) == 0 {
                self.api = api
                self.actuator = ref
                self.deviceID = entry.id
                self.devices = found.list
                self.telemetry = telemetry
                return
            }
        }
        throw MotorError.noActuator
    }

    /// Plays `tones` together. Weights are normalised to sum 1 and the level is scaled by `strength`
    /// (itself ≤ 1), so nothing upstream can drive the motor past its nominal maximum.
    func play(_ tones: [Tone], duration: Double, level: Double) {
        guard !closed, !tones.isEmpty else { return }
        let ms = min(Limits.duration.upperBound, max(Limits.duration.lowerBound, duration)) * 1000
        let total = max(tones.reduce(0) { $0 + max(0, $1.amp) }, 1e-6)
        let components: [[String: Any]] = tones.map {
            ["Type": "Sine", "Amplitude": max(0, $0.amp) / total, "DurationMS": ms, "DelayMS": 0.0,
             "FrequencykHz": min(Limits.frequency.upperBound, max(Limits.frequency.lowerBound, $0.hz)) / 1000]
        }
        let description: [String: Any] = ["BaseWaveform": ["Type": "Gaussian", "Amplitude": 0.0, "DurationMS": ms],
                                          "Tones": components]
        guard let actuation = api.actuationCreate(description as CFDictionary, 0) else { return }
        let applied = min(1, max(0, level)) * min(1, max(0, strength))
        _ = api.actuate(actuation, Unmanaged.passUnretained(actuator as AnyObject).toOpaque(), 0, Float(applied), 0)
        Unmanaged<AnyObject>.fromOpaque(actuation).release()   // created with +1, we own it
        telemetry.recordActuation(hz: tones[0].hz, level: applied, duration: ms / 1000)
    }

    func close() {
        guard !closed else { return }
        closed = true
        _ = api.actuatorClose?(actuator)
    }
}
