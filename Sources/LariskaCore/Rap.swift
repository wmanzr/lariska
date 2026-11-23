import Foundation

/// A spoken line fitted to a beat: syllable onsets land on grid steps and the audio between them is
/// time-stretched piecewise. Only the reading speed changes, so the pitch (F0) is untouched.
public struct RapLine: Sendable {
    public let frames: [SpeechFrame]
    public let text: String
    public let hop: Double
    /// Matching anchors: `source` in the original line, `target` relative to the downbeat.
    /// target[0] may be negative: a pickup consonant before the first stressed vowel.
    public private(set) var source: [Double] = []
    public private(set) var target: [Double] = []

    public var start: Double { target.first ?? 0 }
    public var end: Double { target.last ?? 0 }

    public init(frames: [SpeechFrame], text: String, hop: Double, slot: Double, grid: Double) {
        self.frames = frames
        self.text = text
        self.hop = hop
        let natural = Double(frames.count) * hop
        guard natural > 0 else { return }
        let scale = slot / natural
        let onsets = syllableOnsets(frames).map { Double($0) * hop }
        guard let first = onsets.first else { source = [0, natural]; target = [0, slot]; return }

        source = [0]; target = [-first * scale]
        let slots = assignSlots(onsets.map { ($0 - first) * scale / grid })
        for (onset, slotIndex) in zip(onsets, slots) {
            let placed = Double(slotIndex) * grid
            let stretch = (placed - target.last!) / max(onset - source.last!, 1e-6)
            if onset > source.last!, stretch > 0.3, stretch < 3.5 { source.append(onset); target.append(placed) }
        }
        source.append(natural)
        target.append(target.last! + (natural - source[source.count - 2]) * scale)
    }

    /// Frame to play `t` seconds after the downbeat, or nil outside the line.
    public func frame(at t: Double) -> SpeechFrame? {
        guard target.count >= 2, t >= start, t < end else { return nil }
        var k = 0
        while k + 2 < target.count, target[k + 1] <= t { k += 1 }
        let s = source[k] + (t - target[k]) * (source[k + 1] - source[k]) / max(target[k + 1] - target[k], 1e-6)
        return frames[min(frames.count - 1, max(0, Int(s / hop)))]
    }
}

/// Gives each syllable its own grid slot (strictly increasing, first at 0) with the least total shift.
/// Plain rounding fails when two syllables are closer than one slot; this dynamic programme doesn't.
public func assignSlots(_ positions: [Double]) -> [Int] {
    guard !positions.isEmpty else { return [] }
    let width = Int((positions.last ?? 0).rounded(.up)) + positions.count + 2
    var cost = [[Double]](repeating: [Double](repeating: .infinity, count: width), count: positions.count)
    var from = [[Int]](repeating: [Int](repeating: -1, count: width), count: positions.count)
    cost[0][0] = 0
    for k in 1..<positions.count {
        var bestPrevious = Double.infinity, bestIndex = -1
        for j in 1..<width {
            if cost[k - 1][j - 1] < bestPrevious { bestPrevious = cost[k - 1][j - 1]; bestIndex = j - 1 }
            guard bestIndex >= 0 else { continue }
            cost[k][j] = bestPrevious + abs(Double(j) - positions[k])
            from[k][j] = bestIndex
        }
    }
    let last = positions.count - 1
    var j = cost[last].indices.min { cost[last][$0] < cost[last][$1] }!
    var slots = [Int](repeating: 0, count: positions.count)
    for k in stride(from: last, through: 0, by: -1) {
        slots[k] = j
        if k > 0 { j = from[k][j] }
    }
    return slots
}

/// Syllable onsets as frame indices: each voiced loudness peak, walked back to where it rose above half its height.
public func syllableOnsets(_ frames: [SpeechFrame]) -> [Int] {
    let count = frames.count
    guard count > 2 else { return [] }
    var level = [Double](repeating: 0, count: count)
    for i in 0..<count {
        level[i] = (frames[max(0, i - 1)].level + frames[i].level + frames[min(count - 1, i + 1)].level) / 3
    }
    let reach = 8, minGap = 8
    var onsets: [Int] = []
    var i = 0
    while i < count {
        var localMax = 0.0
        for k in max(0, i - reach)...min(count - 1, i + reach) { localMax = max(localMax, level[k]) }
        if level[i] > 0.35, frames[i].voiced, level[i] >= localMax {
            var j = i
            while j > 0, level[j - 1] > level[i] * 0.5, i - j < 15 { j -= 1 }
            if onsets.isEmpty || j - onsets.last! >= minGap { onsets.append(j) }
            i += reach
        } else {
            i += 1
        }
    }
    return onsets
}
