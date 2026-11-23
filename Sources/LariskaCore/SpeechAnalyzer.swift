import Foundation

/// What the motor needs to imitate 10 ms of speech.
public struct SpeechFrame: Sendable, Equatable {
    public var level = 0.0          // 0…1, from loudness in dB
    public var voiced = false
    public var f0 = 0.0             // pitch, Hz
    public var f1 = 500.0, f2 = 1500.0
    public var a1 = 1.0, a2 = 0.5   // formant strengths from the spectral envelope
    public var noiseHz = 3500.0     // centre of hiss for unvoiced frames ("ш" low, "с" high)
    public init() {}
}

/// Speech → frames. Pitch by YIN, spectral envelope by Burg LPC, formants by envelope peak picking,
/// formant tracks chosen by dynamic programming over the whole phrase.
public struct SpeechAnalyzer: Sendable {
    public struct Config: Sendable {
        public var sampleRate = 16_000.0
        public var hop = 0.010
        public var window = 0.030
        public var pitchRange = 70.0...420.0
        public var yinThreshold = 0.15
        public var voicedAperiodicity = 0.35
        public var lpcOrder = 16
        public var preEmphasis = 0.95
        public var dynamicRange = 45.0           // dB below the phrase peak that maps to level 0
        public var absoluteFloor = -60.0         // dBFS; quieter frames are silence whatever the peak
        public var silence = 0.03
        public var f1Band = 220.0...1000.0, f2Band = 750.0...2700.0
        public var f1Typical = 550.0, f2Typical = 1500.0
        public init() {}
    }

    public let config: Config
    public init(config: Config = Config()) { self.config = config }

    public var hop: Double { config.hop }

    public func analyze(_ samples: [Float]) -> [SpeechFrame] {
        let c = config
        let win = Int(c.window * c.sampleRate), step = Int(c.hop * c.sampleRate)
        guard samples.count >= win else { return [] }
        let hann = (0..<win).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(win - 1)) }

        var frames: [SpeechFrame] = []
        var energyDB: [Double] = []
        var f1Candidates: [[Peak]] = [], f2Candidates: [[Peak]] = []
        var start = 0
        while start + win <= samples.count {
            let x = (0..<win).map { Double(samples[start + $0]) }
            var frame = SpeechFrame()
            let rms = sqrt(x.reduce(0) { $0 + $1 * $1 } / Double(win))
            energyDB.append(20 * log10(max(rms, 1e-9)))

            if let (lag, aperiodicity) = yin(x) {
                frame.voiced = aperiodicity < c.voicedAperiodicity
                frame.f0 = c.sampleRate / lag
            }

            var shaped = [Double](repeating: 0, count: win)
            for i in 0..<win { shaped[i] = (x[i] - c.preEmphasis * (i > 0 ? x[i - 1] : 0)) * hann[i] }
            let a = burg(shaped, order: c.lpcOrder)
            let peaks = envelopePeaks(a)
            f1Candidates.append(peaks.filter { c.f1Band.contains($0.hz) })
            f2Candidates.append(peaks.filter { c.f2Band.contains($0.hz) })
            frame.noiseHz = hissCentre(a)
            frames.append(frame)
            start += step
        }

        // Loudness relative to the loudest frame, linear in dB.
        let peakDB = energyDB.max() ?? 0
        for i in frames.indices {
            frames[i].level = min(1, max(0, (energyDB[i] - (peakDB - c.dynamicRange)) / c.dynamicRange))
            if frames[i].level < c.silence || energyDB[i] < c.absoluteFloor { frames[i].level = 0; frames[i].voiced = false }
        }

        let f1 = track(f1Candidates, typical: c.f1Typical, below: nil)
        let f2 = track(f2Candidates, typical: c.f2Typical, below: f1)
        for i in frames.indices {
            frames[i].f1 = f1[i].hz; frames[i].a1 = f1[i].strength
            frames[i].f2 = f2[i].hz; frames[i].a2 = f2[i].strength
        }
        smoothPitch(&frames)

        let first = frames.firstIndex { $0.level > 0 } ?? 0
        let last = frames.lastIndex { $0.level > 0 } ?? -1
        return last >= first ? Array(frames[first...last]) : []
    }

    // MARK: Pitch (YIN)

    /// Lag in samples (parabolically refined) and its aperiodicity, or nil if nothing periodic was found.
    private func yin(_ x: [Double]) -> (Double, Double)? {
        let c = config
        let minLag = Int(c.sampleRate / c.pitchRange.upperBound), maxLag = Int(c.sampleRate / c.pitchRange.lowerBound)
        let span = x.count - maxLag - 1   // lags run up to maxLag + 1
        guard span > 0 else { return nil }
        var d = [Double](repeating: 0, count: maxLag + 2)
        for lag in 1...(maxLag + 1) {
            var s = 0.0
            for i in 0..<span { let diff = x[i] - x[i + lag]; s += diff * diff }
            d[lag] = s
        }
        // Cumulative mean normalised difference: removes the bias towards long lags.
        var cmnd = [Double](repeating: 1, count: maxLag + 2)
        var running = 0.0
        for lag in 1...(maxLag + 1) {
            running += d[lag]
            cmnd[lag] = running > 0 ? d[lag] * Double(lag) / running : 1
        }
        var best = -1
        for lag in minLag...maxLag where cmnd[lag] < c.yinThreshold {
            var l = lag
            while l + 1 <= maxLag, cmnd[l + 1] < cmnd[l] { l += 1 }
            best = l
            break
        }
        if best < 0 { best = (minLag...maxLag).min { cmnd[$0] < cmnd[$1] }! }
        let (y0, y1, y2) = (cmnd[best - 1], cmnd[best], cmnd[best + 1])
        let denom = y0 - 2 * y1 + y2
        let shift = abs(denom) > 1e-12 ? 0.5 * (y0 - y2) / denom : 0
        return (Double(best) + max(-1, min(1, shift)), y1)
    }

    private func smoothPitch(_ frames: inout [SpeechFrame]) {
        let raw = frames.map(\.f0)
        for i in frames.indices where frames[i].voiced {
            let around = (max(0, i - 1)...min(frames.count - 1, i + 1)).filter { frames[$0].voiced }.map { raw[$0] }.sorted()
            frames[i].f0 = around[around.count / 2]
        }
    }

    // MARK: Spectral envelope (Burg LPC)

    /// Prediction polynomial a[0…order], a[0] = 1, estimated by Burg's method
    /// (minimises forward and backward error together; stable on short windows).
    private func burg(_ x: [Double], order: Int) -> [Double] {
        var a = [Double](repeating: 0, count: order + 1); a[0] = 1
        var f = x, b = x
        for m in 1...order {
            var num = 0.0, den = 0.0
            for i in m..<x.count { num += f[i] * b[i - 1]; den += f[i] * f[i] + b[i - 1] * b[i - 1] }
            guard den > 1e-12 else { break }
            let k = -2 * num / den
            let previous = a
            for j in 1...m { a[j] = previous[j] + k * previous[m - j] }
            for i in stride(from: x.count - 1, through: m, by: -1) {
                let fi = f[i], bi = b[i - 1]
                f[i] = fi + k * bi
                b[i] = bi + k * fi
            }
        }
        return a
    }

    private func envelope(_ a: [Double], at hz: Double) -> Double {
        let w = 2 * Double.pi * hz / config.sampleRate
        var re = 0.0, im = 0.0
        for (k, ak) in a.enumerated() { re += ak * cos(w * Double(k)); im -= ak * sin(w * Double(k)) }
        return 1 / max(re * re + im * im, 1e-12)
    }

    struct Peak: Sendable { var hz: Double; var strength: Double }

    /// Local maxima of the envelope on a 15 Hz grid, refined by a parabola in dB, narrower than 600 Hz at −3 dB.
    private func envelopePeaks(_ a: [Double]) -> [Peak] {
        let stepHz = 15.0, grid = stride(from: 150.0, through: 4200, by: stepHz).map { $0 }
        let db = grid.map { 10 * log10(envelope(a, at: $0)) }
        var peaks: [Peak] = []
        for i in 1..<(grid.count - 1) where db[i] > db[i - 1] && db[i] >= db[i + 1] {
            var lo = i, hi = i
            while lo > 0, db[lo] > db[i] - 3 { lo -= 1 }
            while hi < grid.count - 1, db[hi] > db[i] - 3 { hi += 1 }
            guard Double(hi - lo) * stepHz < 600 else { continue }
            let denom = db[i - 1] - 2 * db[i] + db[i + 1]
            let shift = abs(denom) > 1e-9 ? 0.5 * (db[i - 1] - db[i + 1]) / denom : 0
            peaks.append(Peak(hz: grid[i] + shift * stepHz, strength: pow(10, db[i] / 20)))
        }
        return peaks
    }

    /// Envelope-weighted mean frequency of the hiss band.
    private func hissCentre(_ a: [Double]) -> Double {
        var weighted = 0.0, total = 0.0
        for hz in stride(from: 2000.0, through: 5000, by: 100) { let e = envelope(a, at: hz); weighted += hz * e; total += e }
        return total > 0 ? weighted / total : 3500
    }

    // MARK: Formant tracking

    /// Viterbi over each frame's candidate peaks. Cost = distance from the typical value plus jump size,
    /// with a "no peak" state that holds the previous value. Picks the smoothest plausible track.
    private func track(_ candidates: [[Peak]], typical: Double, below: [Peak]?) -> [Peak] {
        let hold = Peak(hz: typical, strength: 0.3)
        let states: [[Peak]] = candidates.enumerated().map { i, peaks in
            let allowed = below.map { lower in peaks.filter { $0.hz > lower[i].hz + 150 } } ?? peaks
            return allowed + [hold]
        }
        guard !states.isEmpty else { return [] }
        func prior(_ p: Peak, _ isHold: Bool) -> Double { isHold ? 1.5 : abs(log2(p.hz / typical)) }
        var cost = states[0].enumerated().map { prior($1, $0 == states[0].count - 1) }
        var back: [[Int]] = [Array(repeating: 0, count: states[0].count)]
        for t in 1..<states.count {
            var next: [Double] = [], from: [Int] = []
            for (j, p) in states[t].enumerated() {
                let isHold = j == states[t].count - 1
                var best = Double.infinity, arg = 0
                for (i, q) in states[t - 1].enumerated() {
                    let jump = isHold || i == states[t - 1].count - 1 ? 0.3 : abs(log2(p.hz / q.hz)) * 4
                    if cost[i] + jump < best { best = cost[i] + jump; arg = i }
                }
                next.append(best + prior(p, isHold)); from.append(arg)
            }
            cost = next; back.append(from)
        }
        var j = cost.indices.min { cost[$0] < cost[$1] }!
        var path = [Peak](repeating: hold, count: states.count)
        var held = [Bool](repeating: false, count: states.count)
        for t in stride(from: states.count - 1, through: 0, by: -1) {
            path[t] = states[t][j]
            held[t] = j == states[t].count - 1
            j = back[t][j]
        }
        // A held frame repeats the last real value.
        var lastReal: Peak?
        for t in path.indices {
            if held[t] { if let r = lastReal { path[t] = r } } else { lastReal = path[t] }
        }
        return path
    }
}
