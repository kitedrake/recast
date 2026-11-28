import AVFoundation
import Foundation

/// One step of the processing chain. A block holds one array of samples per channel; a step may change how many
/// frames pass through (trimming, padding, the limiter's look-ahead).
protocol AudioEffect: AnyObject {
    func process(_ block: inout [[Float]])
    /// Called once after the last block with whatever the steps before it released at the end: processes that,
    /// then appends anything this step still holds.
    func finish(_ block: inout [[Float]])
}

extension AudioEffect {
    func finish(_ block: inout [[Float]]) { process(&block) }
}

private func frameCount(_ block: [[Float]]) -> Int { block.first?.count ?? 0 }

/// Swaps left and right, and/or turns the waveform upside down.
final class ChannelFlip: AudioEffect {
    let swap: Bool
    let invert: Bool

    init(swap: Bool, invert: Bool) {
        self.swap = swap
        self.invert = invert
    }

    func process(_ block: inout [[Float]]) {
        if swap, block.count == 2 { block.swapAt(0, 1) }
        if invert {
            for channel in block.indices { block[channel] = block[channel].map { -$0 } }
        }
    }
}

/// Removes a constant offset with a first-order high-pass at 5 Hz. The filter starts as if the opening block's
/// median had always been there, so an offset at the very start doesn't turn into a thump. (The median, not the
/// average: a short hit in the opening would move the average and leave a made-up offset in the silence before it.)
final class DCBlocker: AudioEffect {
    private let coefficient: Double
    private var previousInput: [Double]
    private var previousOutput: [Double]
    private var sums: [Double]
    private var medianSums: [Double]
    private var frames = 0
    private var started = false

    init(channels: Int, sampleRate: Double) {
        coefficient = exp(-2 * .pi * 5 / sampleRate)
        previousInput = Array(repeating: 0, count: channels)
        previousOutput = previousInput
        sums = previousInput
        medianSums = previousInput
    }

    /// The middle value of every `step`-th sample.
    private static func median(_ samples: UnsafeMutableBufferPointer<Float>, step: Int) -> Double {
        var picked = [Float]()
        picked.reserveCapacity(samples.count / step + 1)
        for index in Swift.stride(from: 0, to: samples.count, by: step) { picked.append(samples[index]) }
        picked.sort()
        let n = picked.count
        return n % 2 == 1 ? Double(picked[n / 2]) : (Double(picked[n / 2 - 1]) + Double(picked[n / 2])) / 2
    }

    func process(_ block: inout [[Float]]) {
        let count = frameCount(block)
        guard count > 0 else { return }
        for channel in block.indices {
            var x1 = previousInput[channel], y1 = previousOutput[channel], sum = 0.0
            let r = coefficient
            block[channel].withUnsafeMutableBufferPointer { samples in
                // Every sample of the opening block, about a thousand of each later one (only for the note).
                let middle = Self.median(samples, step: started ? max(1, count / 1024) : 1)
                medianSums[channel] += middle * Double(count)
                if !started { x1 = middle }
                for index in 0..<count {
                    let x = Double(samples[index])
                    sum += x
                    let y = x - x1 + r * y1
                    x1 = x
                    y1 = y
                    samples[index] = Float(y)
                }
            }
            previousInput[channel] = x1
            previousOutput[channel] = y1
            sums[channel] += sum
        }
        frames += count
        started = true
    }

    /// The source's offset, largest channel, as a fraction of full scale: its average level, when that comes from a
    /// steady offset. A short, lopsided sound in silence (a hit) has an average too, but the middle values of its
    /// blocks stay at zero, so it counts as none.
    var offset: Double {
        guard frames > 0 else { return 0 }
        let steady = medianSums.map { abs($0) / Double(frames) }.max() ?? 0
        return steady < 0.0005 ? 0 : sums.map { abs($0) / Double(frames) }.max() ?? 0
    }
}

/// Fourth-order Butterworth high-pass and/or low-pass (24 dB per octave, −3 dB at the set frequency).
final class ButterworthFilter: AudioEffect {
    struct Section {
        var b0, b1, b2, a1, a2: Double
    }

    private let sections: [Section]
    /// state[channel][section] = (z1, z2)
    private var state: [[(Double, Double)]]

    init(channels: Int, sampleRate: Double, highPass: Double?, lowPass: Double?) {
        var sections: [Section] = []
        for q in [0.54119610014619698, 1.3065629648763766] {
            if let highPass { sections.append(Self.section(highPass: true, frequency: highPass, q: q, sampleRate: sampleRate)) }
            if let lowPass { sections.append(Self.section(highPass: false, frequency: lowPass, q: q, sampleRate: sampleRate)) }
        }
        self.sections = sections
        state = Array(repeating: Array(repeating: (0, 0), count: sections.count), count: channels)
    }

    /// Robert Bristow-Johnson's biquad, normalized.
    static func section(highPass: Bool, frequency: Double, q: Double, sampleRate: Double) -> Section {
        let w0 = 2 * .pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q), c = cos(w0)
        let a0 = 1 + alpha
        let b0 = (highPass ? 1 + c : 1 - c) / 2
        let b1 = highPass ? -(1 + c) : 1 - c
        return Section(b0: b0 / a0, b1: b1 / a0, b2: b0 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }

    var isEmpty: Bool { sections.isEmpty }

    func process(_ block: inout [[Float]]) {
        let count = frameCount(block)
        guard count > 0, !sections.isEmpty else { return }
        for channel in block.indices {
            var channelState = state[channel]
            block[channel].withUnsafeMutableBufferPointer { samples in
                for (index, s) in sections.enumerated() {
                    var (z1, z2) = channelState[index]
                    for frame in 0..<count {
                        let x = Double(samples[frame])
                        let y = s.b0 * x + z1
                        z1 = s.b1 * x - s.a1 * y + z2
                        z2 = s.b2 * x - s.a2 * y
                        samples[frame] = Float(y)
                    }
                    channelState[index] = (z1, z2)
                }
            }
            state[channel] = channelState
        }
    }
}

/// Keeps frames `start..<end` of the stream.
final class Trim: AudioEffect {
    let start: Int64
    let end: Int64
    private var position: Int64 = 0

    init(start: Int64, end: Int64) {
        self.start = start
        self.end = max(start, end)
    }

    func process(_ block: inout [[Float]]) {
        let count = Int64(frameCount(block))
        let from = max(0, min(count, start - position)), to = max(from, min(count, end - position))
        position += count
        guard from > 0 || to < count else { return }
        block = block.map { Array($0[Int(from)..<Int(to)]) }
    }
}

/// Fades in over the first frames and out over the last ones (`total` is the stream's length), with a raised-cosine
/// curve: the first and last samples are silent and the curve has no corners.
final class Fade: AudioEffect {
    let inFrames: Int64
    let outFrames: Int64
    let total: Int64?
    private var position: Int64 = 0

    init(inFrames: Int64, outFrames: Int64, total: Int64?) {
        self.inFrames = inFrames
        self.outFrames = total == nil ? 0 : outFrames
        self.total = total
    }

    static func curve(_ x: Double) -> Float { Float(0.5 - 0.5 * cos(.pi * min(1, max(0, x)))) }

    func process(_ block: inout [[Float]]) {
        let count = Int64(frameCount(block))
        defer { position += count }
        guard count > 0 else { return }
        if inFrames > 0, position < inFrames {
            for frame in 0..<min(count, inFrames - position) {
                let gain = Fade.curve(Double(position + frame) / Double(inFrames))
                for channel in block.indices { block[channel][Int(frame)] *= gain }
            }
        }
        if outFrames > 0, let total {
            let fadeStart = total - outFrames
            let first = max(0, fadeStart - position)
            guard first < count else { return }
            for frame in first..<count {
                let remaining = total - 1 - (position + frame)
                let gain = Fade.curve(Double(remaining) / Double(outFrames))
                for channel in block.indices { block[channel][Int(frame)] *= gain }
            }
        }
    }
}

/// Adds silence before and after.
final class Pad: AudioEffect {
    let startFrames: Int
    let endFrames: Int
    private var started = false

    init(startFrames: Int, endFrames: Int) {
        self.startFrames = startFrames
        self.endFrames = endFrames
    }

    func process(_ block: inout [[Float]]) {
        guard !started else { return }
        started = true
        if startFrames > 0 { block = block.map { [Float](repeating: 0, count: startFrames) + $0 } }
    }

    func finish(_ block: inout [[Float]]) {
        process(&block)
        if endFrames > 0 { block = block.map { $0 + [Float](repeating: 0, count: endFrames) } }
    }
}

/// Applies a gain, then keeps the true peak (4× oversampled, as BS.1770 measures it) under a ceiling. The gain
/// reduction is the same on every channel. It looks 5 ms ahead, so it starts lowering the level before a peak and
/// never clips it; it recovers over about 80 ms. The look-ahead delay is taken out again, so the output lines up
/// with the input and has the same length.
final class Limiter: AudioEffect {
    let gain: Float
    let ceiling: Float
    let window: Int
    let latency: Int
    private let channels: Int
    private let release: Double
    /// Per channel, 2 × taps samples so the last `taps` can be read without wrapping.
    private var history: [[Float]]
    private var historyPosition = 0
    private var framePeaks = [Float](repeating: 0, count: 8)
    private var lastInterpolated: Float = 0
    private var minimum: SlidingMinimum
    private var recovered = 1.0
    private var average: [Double]
    private var averagePosition = 0
    private var averageSum: Double
    private var delay: [[Float]]
    private var received = 0
    private(set) var smallestGain: Float = 1

    init(channels: Int, sampleRate: Double, gain: Float, ceilingDB: Double) {
        self.channels = channels
        self.gain = gain
        ceiling = Float(pow(10, ceilingDB / 20))
        window = max(1, Int((sampleRate * 0.005).rounded()))
        // The interpolator's output lags its input by about 6 samples (it covers the gap between n-6 and n-5).
        latency = window + 5
        release = 1 - exp(-1 / (0.08 * sampleRate))
        history = Array(repeating: [Float](repeating: 0, count: 2 * LoudnessMeter.taps), count: channels)
        minimum = SlidingMinimum(window: window)
        average = Array(repeating: 1, count: window)
        averageSum = Double(window)
        delay = Array(repeating: [Float](repeating: 0, count: latency + 1), count: channels)
    }

    func process(_ block: inout [[Float]]) {
        let count = frameCount(block)
        var output = Array(repeating: [Float](), count: channels)
        for channel in 0..<channels { output[channel].reserveCapacity(count) }
        var frame = [Float](repeating: 0, count: channels)
        for index in 0..<count {
            for channel in 0..<channels { frame[channel] = block[channel][index] * gain }
            step(frame, into: &output)
        }
        block = output
    }

    func finish(_ block: inout [[Float]]) {
        process(&block)
        let silence = [Float](repeating: 0, count: channels)
        for _ in 0..<latency { step(silence, into: &block) }
    }

    private func step(_ frame: [Float], into output: inout [[Float]]) {
        let n = received
        received += 1
        let size = latency + 1
        var framePeak: Float = 0, interpolated: Float = 0
        let taps = LoudnessMeter.taps
        let coefficients = LoudnessMeter.coefficients
        for channel in 0..<channels {
            let sample = frame[channel]
            delay[channel][n % size] = sample
            framePeak = max(framePeak, abs(sample))
            history[channel].withUnsafeMutableBufferPointer { line in
                line[historyPosition] = sample
                line[historyPosition + taps] = sample
                // x[n - t] sits at historyPosition + taps - t.
                for phase in 0..<LoudnessMeter.phases {
                    var sum: Float = 0
                    let row = coefficients[phase]
                    for tap in 0..<taps { sum += row[tap] * line[historyPosition + taps - tap] }
                    interpolated = max(interpolated, abs(sum))
                }
            }
        }
        historyPosition = (historyPosition + 1) % taps
        framePeaks[n % 8] = framePeak
        let previous = lastInterpolated
        lastInterpolated = interpolated
        guard n >= 6 else { return }
        // Sample m = n - 6, with the peaks between it and its neighbours on both sides.
        let m = n - 6
        let level = max(framePeaks[m % 8], interpolated, previous)
        let target = level > ceiling ? Double(ceiling / level) : 1
        let held = minimum.push(target, at: m)
        recovered = min(held, recovered + (1 - recovered) * release)
        averageSum += recovered - average[averagePosition]
        average[averagePosition] = recovered
        averagePosition = (averagePosition + 1) % window
        // Holding the lowest gain for a window and then averaging over the same window ramps the gain down ahead of
        // each peak and reaches the needed reduction exactly at it.
        guard n >= latency else { return }
        let applied = Float(min(1, averageSum / Double(window)))
        smallestGain = min(smallestGain, applied)
        let read = (n + 1) % size
        for channel in 0..<channels { output[channel].append(delay[channel][read] * applied) }
    }
}

/// The smallest of the last `window` values pushed, in constant time per push.
struct SlidingMinimum {
    private let window: Int
    private var values: [Double]
    private var indices: [Int]
    private var head = 0
    private var count = 0

    init(window: Int) {
        self.window = window
        values = Array(repeating: 0, count: window + 1)
        indices = Array(repeating: 0, count: window + 1)
    }

    mutating func push(_ value: Double, at index: Int) -> Double {
        let capacity = values.count
        while count > 0, values[(head + count - 1) % capacity] >= value { count -= 1 }
        values[(head + count) % capacity] = value
        indices[(head + count) % capacity] = index
        count += 1
        while indices[head] <= index - window {
            head = (head + 1) % capacity
            count -= 1
        }
        return values[head]
    }
}

/// Finds where the sound starts and ends: the first and last frames with any channel at or above a level.
final class SilenceScanner {
    let threshold: Float
    private(set) var frames: Int64 = 0
    private(set) var first: Int64?
    private(set) var last: Int64?
    /// When aligning for layering: where the hit starts and which way it swings.
    let hit: HitScanner?

    init(thresholdDB: Double, hit: HitScanner? = nil) {
        threshold = Float(pow(10, thresholdDB / 20))
        self.hit = hit
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        let channels = buffer.format.channelCount.intValue
        func loud(_ index: Int) -> Bool {
            for channel in 0..<channels where abs(data[channel][index]) >= threshold { return true }
            return false
        }
        if first == nil, let index = (0..<count).first(where: loud) { first = frames + Int64(index) }
        if let index = (0..<count).reversed().first(where: loud) { last = frames + Int64(index) }
        hit?.process(data, count: count, channels: channels, at: frames, onset: first)
        frames += Int64(count)
    }
}

/// For one-shots: the zero crossing just before the sound starts, and which way its first strong swing goes.
/// It follows the channels' average (the mid); when the channels mostly cancel, the loudest one decides the swing.
final class HitScanner {
    enum Swing: Equatable { case up, down, unclear }

    /// How far before the start a zero crossing may be, and how long the opening looked at for the swing is.
    private let reach: Int64
    private let openingFrames: Int64
    private var previousMid: Float?
    private var crossing: Int64?
    private(set) var start: Int64?
    private var opening: [[Float]] = []
    private var peak: Float = 0

    init(sampleRate: Double) {
        reach = Int64((sampleRate * 0.010).rounded())
        openingFrames = max(1, Int64((sampleRate * 0.050).rounded()))
    }

    func process(_ data: UnsafePointer<UnsafeMutablePointer<Float>>, count: Int, channels: Int, at position: Int64, onset: Int64?) {
        if opening.isEmpty { opening = Array(repeating: [], count: channels) }
        for index in 0..<count {
            let frame = position + Int64(index)
            var mid: Float = 0
            for channel in 0..<channels {
                let sample = data[channel][index]
                mid += sample
                peak = max(peak, abs(sample))
            }
            mid /= Float(channels)
            if start == nil {
                // Up to and including the first loud frame: note the latest zero crossing, at whichever of the two
                // frames around it is nearer zero.
                if mid == 0 {
                    crossing = frame
                } else if let previousMid, (previousMid < 0) != (mid < 0) {
                    crossing = abs(mid) <= abs(previousMid) ? frame : frame - 1
                }
                previousMid = mid
                if let onset, frame == onset {
                    start = crossing.map { onset - $0 <= reach ? $0 : onset } ?? onset
                }
            }
            if let onset, frame >= onset, frame < onset + openingFrames {
                for channel in 0..<channels { opening[channel].append(data[channel][index]) }
            }
        }
    }

    /// Which way the first strong swing goes: the first sample of the opening 50 ms at half its peak or more. It's
    /// unclear when the opening is more than 12 dB under the file's peak (a swell, not a hit).
    var swing: Swing {
        let openingPeak = opening.map { $0.map(abs).max() ?? 0 }
        guard let loudest = openingPeak.indices.max(by: { openingPeak[$0] < openingPeak[$1] }),
              openingPeak[loudest] > 0, openingPeak[loudest] >= peak * 0.25 else { return .unclear }
        let length = opening[0].count
        var reference = (0..<length).map { index in opening.reduce(0) { $0 + $1[index] } / Float(opening.count) }
        if (reference.map(abs).max() ?? 0) < openingPeak[loudest] * 0.25 { reference = opening[loudest] }
        let top = reference.map(abs).max() ?? 0
        guard let first = reference.first(where: { abs($0) >= top * 0.5 }) else { return .unclear }
        return first < 0 ? .down : .up
    }
}

/// The processing settings for one file, and the effects built from them for each pass over the audio.
struct Processing {
    let settings: ConversionSettings
    let sampleRate: Double
    let channels: Int
    private(set) var notes: [String] = []
    private let highPass: Double?
    private let lowPass: Double?
    /// From the scan: the frames kept by trimming and how many there are.
    private var kept: (start: Int64, end: Int64)?
    /// Set once the plugin pass has applied the clean-up effects (and the plugins) into a file the later passes read.
    var cleanedUp = false
    /// From the scan, when aligning for layering: the file's polarity is turned over after trimming.
    private var flipsPolarity = false

    init(settings: ConversionSettings, sampleRate: Double, channels: Int) {
        self.settings = settings
        self.sampleRate = sampleRate
        self.channels = channels
        let nyquist = sampleRate / 2
        var notes: [String] = []
        func usable(_ on: Bool, _ frequency: Double, _ name: String) -> Double? {
            guard on else { return nil }
            guard frequency > 0, frequency < nyquist * 0.95 else {
                notes.append("\(name) at \(Self.frequencyText(frequency)) skipped: \(ConversionSettings.rateText(sampleRate)) audio only goes up to \(Self.frequencyText(nyquist)).")
                return nil
            }
            return frequency
        }
        highPass = usable(settings.highPass, settings.highPassFrequency, "High-pass")
        lowPass = usable(settings.lowPass, settings.lowPassFrequency, "Low-pass")
        self.notes = notes
    }

    var hasFlip: Bool { settings.invertPolarity || (settings.swapChannels && channels == 2) }
    var plugins: [PluginEffect] { settings.plugins.filter { !$0.bypassed } }
    var fadeInFrames: Int64 { frames(settings.fadeInMS) }
    var fadeOutFrames: Int64 { frames(settings.fadeOutMS) }
    var padFrames: (start: Int, end: Int) { (Int(frames(settings.padStartMS)), Int(frames(settings.padEndMS))) }
    var trim: TrimMode { settings.appliedTrim }

    /// Whether any effect before the level change is on.
    var isActive: Bool {
        hasFlip || settings.removesDCOffset || highPass != nil || lowPass != nil || trim != .off
            || fadeInFrames > 0 || fadeOutFrames > 0 || padFrames.start > 0 || padFrames.end > 0 || !plugins.isEmpty
    }

    /// Trimming and fading out need to know where the file ends, so they read it once first.
    var needsScan: Bool { trim != .off || fadeOutFrames > 0 }

    /// What the scan pass reads.
    func scanner() -> SilenceScanner {
        SilenceScanner(thresholdDB: settings.trimThreshold, hit: settings.alignForLayering ? HitScanner(sampleRate: sampleRate) : nil)
    }

    /// Effects that change the level, so stored ReplayGain values no longer apply.
    var changesLevel: Bool {
        settings.removesDCOffset || highPass != nil || lowPass != nil || fadeInFrames > 0 || fadeOutFrames > 0 || !plugins.isEmpty
    }

    private func frames(_ milliseconds: Double) -> Int64 {
        milliseconds > 0 ? Int64((milliseconds / 1000 * sampleRate).rounded()) : 0
    }

    /// The effects up to the trim: what the scan looks at (nothing once the plugin pass has applied them).
    func cleanUpEffects() -> (effects: [AudioEffect], dc: DCBlocker?) {
        guard !cleanedUp else { return ([], nil) }
        var effects: [AudioEffect] = []
        if hasFlip { effects.append(ChannelFlip(swap: settings.swapChannels, invert: settings.invertPolarity)) }
        var dc: DCBlocker?
        if settings.removesDCOffset {
            let blocker = DCBlocker(channels: channels, sampleRate: sampleRate)
            effects.append(blocker)
            dc = blocker
        }
        if highPass != nil || lowPass != nil {
            effects.append(ButterworthFilter(channels: channels, sampleRate: sampleRate, highPass: highPass, lowPass: lowPass))
        }
        return (effects, dc)
    }

    /// Every effect before the level change, fresh for one pass.
    func effects() -> (effects: [AudioEffect], dc: DCBlocker?) {
        var (effects, dc) = cleanUpEffects()
        if let kept, trim != .off { effects.append(Trim(start: kept.start, end: kept.end)) }
        if flipsPolarity { effects.append(ChannelFlip(swap: false, invert: true)) }
        if fadeInFrames > 0 || fadeOutFrames > 0 {
            effects.append(Fade(inFrames: fadeInFrames, outFrames: fadeOutFrames, total: kept.map { $0.end - $0.start }))
        }
        let pad = padFrames
        if pad.start > 0 || pad.end > 0 { effects.append(Pad(startFrames: pad.start, endFrames: pad.end)) }
        return (effects, dc)
    }

    func limiter(gain: Float) -> Limiter {
        Limiter(channels: channels, sampleRate: sampleRate, gain: gain, ceilingDB: settings.truePeakCeiling)
    }

    /// Records where the sound is, from a scan over `cleanUpEffects()`.
    mutating func record(_ scan: SilenceScanner) {
        var start: Int64 = 0, end = scan.frames
        if trim != .off {
            if let first = scan.first, let last = scan.last {
                if trim.trimsStart { start = scan.hit?.start ?? first }
                if trim.trimsEnd { end = last + 1 }
                var parts: [String] = []
                if start > 0 { parts.append("\(durationText(start)) from the start") }
                if end < scan.frames { parts.append("\(durationText(scan.frames - end)) from the end") }
                if !parts.isEmpty { notes.append("Trimmed silence: \(parts.joined(separator: " and ")).") }
            } else if scan.frames > 0 {
                notes.append(String(format: "Nothing trimmed: the whole file is below %.0f dB.", settings.trimThreshold))
            }
        }
        if let hit = scan.hit, scan.first != nil {
            // The scan heard the file after Invert polarity, which then asks for the swing to go down instead.
            let wanted: HitScanner.Swing = settings.invertPolarity ? .down : .up
            switch hit.swing {
            case .unclear:
                notes.append("Polarity left as it is: there's no clear hit near the start.")
            case wanted:
                break
            default:
                flipsPolarity = true
                notes.append("Flipped the polarity so the first strong swing goes \(wanted == .up ? "up" : "down").")
            }
        }
        kept = (start, end)
    }

    /// How long the output will be, given how many frames the decoder delivers.
    func outputFrames(decoded: Int64) -> Int64 {
        let length = kept.map { $0.end - $0.start } ?? decoded
        return length + Int64(padFrames.start + padFrames.end)
    }

    private func durationText(_ frames: Int64) -> String {
        let seconds = Double(frames) / sampleRate
        return seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.1f s", seconds)
    }

    static func frequencyText(_ hertz: Double) -> String {
        hertz >= 1000 ? "\(ConversionSettings.trimmed(hertz / 1000)) kHz" : "\(Int(hertz.rounded())) Hz"
    }
}
