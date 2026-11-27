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
/// average had always been there, so an offset at the very start doesn't turn into a thump.
final class DCBlocker: AudioEffect {
    private let coefficient: Double
    private var previousInput: [Double]
    private var previousOutput: [Double]
    private var sums: [Double]
    private var frames = 0
    private var started = false

    init(channels: Int, sampleRate: Double) {
        coefficient = exp(-2 * .pi * 5 / sampleRate)
        previousInput = Array(repeating: 0, count: channels)
        previousOutput = previousInput
        sums = previousInput
    }

    func process(_ block: inout [[Float]]) {
        let count = frameCount(block)
        guard count > 0 else { return }
        for channel in block.indices {
            var x1 = previousInput[channel], y1 = previousOutput[channel], sum = 0.0
            let r = coefficient
            block[channel].withUnsafeMutableBufferPointer { samples in
                if !started {
                    var opening = 0.0
                    for index in 0..<count { opening += Double(samples[index]) }
                    x1 = opening / Double(count)
                }
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

    /// The source's average level, largest channel, as a fraction of full scale.
    var offset: Double {
        guard frames > 0 else { return 0 }
        return sums.map { abs($0) / Double(frames) }.max() ?? 0
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

    init(thresholdDB: Double) {
        threshold = Float(pow(10, thresholdDB / 20))
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
        frames += Int64(count)
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

    /// Whether any effect before the level change is on.
    var isActive: Bool {
        hasFlip || settings.removeDC || highPass != nil || lowPass != nil || settings.trim != .off
            || fadeInFrames > 0 || fadeOutFrames > 0 || padFrames.start > 0 || padFrames.end > 0 || !plugins.isEmpty
    }

    /// Trimming and fading out need to know where the file ends, so they read it once first.
    var needsScan: Bool { settings.trim != .off || fadeOutFrames > 0 }

    /// Effects that change the level, so stored ReplayGain values no longer apply.
    var changesLevel: Bool {
        settings.removeDC || highPass != nil || lowPass != nil || fadeInFrames > 0 || fadeOutFrames > 0 || !plugins.isEmpty
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
        if settings.removeDC {
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
        if let kept, settings.trim != .off { effects.append(Trim(start: kept.start, end: kept.end)) }
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
        if settings.trim != .off {
            if let first = scan.first, let last = scan.last {
                if settings.trim.trimsStart { start = first }
                if settings.trim.trimsEnd { end = last + 1 }
                var parts: [String] = []
                if start > 0 { parts.append("\(durationText(start)) from the start") }
                if end < scan.frames { parts.append("\(durationText(scan.frames - end)) from the end") }
                if !parts.isEmpty { notes.append("Trimmed silence: \(parts.joined(separator: " and ")).") }
            } else if scan.frames > 0 {
                notes.append(String(format: "Nothing trimmed: the whole file is below %.0f dB.", settings.trimThreshold))
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
