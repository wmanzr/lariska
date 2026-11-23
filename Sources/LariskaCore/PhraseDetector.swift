import Foundation

/// Splits a microphone stream into phrases with an adaptive noise floor.
public struct PhraseDetector: Sendable {
    public struct Config: Sendable {
        public var sampleRate = 16_000.0
        public var chunk = 0.02            // analysis step, seconds
        public var preRoll = 0.2           // audio kept from before the start
        public var hangover = 0.6          // quiet time that ends a phrase
        public var maxLength = 8.0
        public var minLength = 0.9
        public var floorRatio = 3.5        // start threshold above the noise floor
        public var minThreshold = 0.012
        public init() {}
    }

    public let config: Config
    private var pending: [Float] = []
    private var preroll: [[Float]] = []
    private var recording: [Float] = []
    private var quiet = 0.0
    public private(set) var noiseFloor = 0.005
    public private(set) var level = 0.0
    public var isRecording: Bool { !recording.isEmpty }

    public init(config: Config = Config()) { self.config = config }

    /// Feeds samples; returns a finished phrase if one ended inside them.
    public mutating func feed(_ samples: [Float]) -> [Float]? {
        let size = Int(config.chunk * config.sampleRate)
        pending += samples
        var finished: [Float]?
        while pending.count >= size {
            let chunk = Array(pending.prefix(size))
            pending.removeFirst(size)
            let rms = sqrt(chunk.reduce(0) { $0 + Double($1) * Double($1) } / Double(size))
            level = rms
            let threshold = max(config.minThreshold, noiseFloor * config.floorRatio)
            if recording.isEmpty {
                noiseFloor += (min(rms, 0.05) - noiseFloor) * 0.03
                preroll.append(chunk)
                if Double(preroll.count) * config.chunk > config.preRoll { preroll.removeFirst() }
                if rms > threshold { recording = preroll.flatMap { $0 }; quiet = 0 }
            } else {
                recording += chunk
                quiet = rms < threshold * 0.6 ? quiet + config.chunk : 0
                let length = Double(recording.count) / config.sampleRate
                if quiet > config.hangover || length > config.maxLength {
                    if length > config.minLength { finished = recording }
                    recording = []; preroll = []
                }
            }
        }
        return finished
    }

    public mutating func reset() { pending = []; preroll = []; recording = []; quiet = 0 }
}
