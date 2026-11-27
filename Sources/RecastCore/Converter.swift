import AVFoundation
import Foundation

public struct ConversionOutcome: Sendable, Equatable {
    public var output: URL
    public var bytes: Int64
    /// Anything the listener should know: resampling forced by the format, gain applied, clipping.
    public var notes: [String]
}

/// How one file will be converted: decided before any audio is read.
public struct ConversionPlan: Sendable, Equatable {
    public var sampleRate: Double
    public var channels: Int
    /// Integer width for PCM and lossless outputs; nil for float or compressed.
    public var bits: Int?
    public var isFloat: Bool
    public var notes: [String]

    public init(info: AudioFileInfo, settings: ConversionSettings) {
        let format = settings.format
        var notes: [String] = []
        let wanted = settings.sampleRate ?? info.sampleRate
        sampleRate = format.supportedRate(for: wanted)
        if sampleRate != wanted {
            let reason = format == .opus ? "Opus always uses 48 kHz" : "\(format.title) goes up to \(ConversionSettings.rateText(format.sampleRates?.max() ?? sampleRate))"
            notes.append("Resampled to \(ConversionSettings.rateText(sampleRate)) (\(reason)).")
        }
        var channelCount: Int
        switch settings.channels {
        case .keep: channelCount = info.channels
        case .mono: channelCount = 1
        case .stereo: channelCount = 2
        }
        if channelCount > format.maxChannels {
            notes.append("Mixed down to stereo (\(format.title) holds \(format.maxChannels) channels at most).")
            channelCount = format.maxChannels
        }
        channels = max(1, channelCount)

        bits = nil
        isFloat = false
        self.notes = notes
        guard format.isLossless else { return }
        let sourceBits = info.isLossless ? (info.bitDepth ?? 24) : 24
        let sourceFloat = info.isLossless && info.isFloat
        switch settings.selectedDepth {
        case .float32:
            isFloat = true
        case .match:
            if format.isPCM {
                if sourceFloat { isFloat = true } else { bits = sourceBits <= 16 ? 16 : sourceBits <= 24 ? 24 : 32 }
            } else if format == .flac {
                bits = sourceBits <= 16 && !sourceFloat ? 16 : 24
                if sourceFloat || sourceBits > 24 { self.notes.append("FLAC stores up to 24 bits, so this file was reduced to 24-bit.") }
            } else {
                bits = sourceFloat ? 32 : sourceBits <= 16 ? 16 : sourceBits <= 20 ? 20 : sourceBits <= 24 ? 24 : 32
            }
        case .int16: bits = 16
        case .int24: bits = 24
        case .int32: bits = 32
        }
    }
}

public enum Converter {
    static let blockFrames: AVAudioFrameCount = 8192

    /// Converts one file. Writes to a hidden file next to `output` and moves it into place at the end, replacing
    /// whatever is at `output` (resolve names with `OutputPlanner` first). Never writes over `input`.
    ///
    /// The audio is decoded at the planned rate, mixed to the planned channels, run through the processing effects,
    /// set to its level (the limiter comes after the gain), rounded to the output's bit depth and encoded. Trimming
    /// and fading out read the file once first to find where it ends; matching loudness or peaks reads it once more
    /// to measure the processed sound (and, when the limiter has to work, again to measure what it left).
    public static func convert(input: URL, to output: URL, settings requested: ConversionSettings,
                               progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws -> ConversionOutcome {
        guard !OutputPlanner.samePath(input, output) else { throw ConversionError.wouldReplaceOriginal }
        let info = try AudioProbe.info(input)
        let (settings, formatNotes) = requested.resolved(for: info)
        let plan = ConversionPlan(info: info, settings: settings)
        var notes = formatNotes + plan.notes
        var tags = settings.copyTags ? TagIO.read(input) : AudioTags()
        if !settings.copyArtwork { tags.artwork = nil }

        let rateChanged = plan.sampleRate != info.sampleRate
        let mixer = ChannelMixer.make(from: info.channels, to: plan.channels)
        let decodedFrames = Int64((Double(info.frames) * plan.sampleRate / info.sampleRate).rounded(.up))
        var processing = Processing(settings: settings, sampleRate: plan.sampleRate, channels: plan.channels)
        notes += processing.notes
        let analysing = settings.volume == .loudness || settings.volume == .peak
        let mayCorrect = settings.limiter && settings.volume == .loudness

        // Each pass reads the whole file; progress is shared out equally.
        let passes = Double((processing.needsScan ? 1 : 0) + (analysing ? 1 : 0) + (mayCorrect ? 1 : 0) + 1)
        var pass = 0.0
        func read(_ effects: [AudioEffect], _ body: (AVAudioPCMBuffer) throws -> Void) throws {
            let base = pass
            pass += 1
            try decode(input: input, plan: plan, mixer: mixer, sourceChannels: info.channels, effects: effects, onBlock: { done in
                if isCancelled() { throw ConversionError.cancelled }
                progress((base + min(1, Double(done) / Double(max(1, decodedFrames)))) / passes)
            }, body)
        }

        if processing.needsScan {
            let scanner = SilenceScanner(thresholdDB: settings.trimThreshold)
            try read(processing.cleanUpEffects().effects) { scanner.process($0) }
            processing.record(scanner)
            notes += processing.notes.filter { !notes.contains($0) }
        }

        // Level: a fixed gain, or measured in a pass over the processed signal.
        var gain: Float = 1
        if settings.volume == .gain {
            gain = Float(pow(10, settings.gainDB / 20))
        } else if analysing {
            let meter = LoudnessMeter(channels: plan.channels, sampleRate: plan.sampleRate)
            try read(processing.effects().effects) { meter.process($0) }
            let peak = LoudnessMeter.decibels(meter.samplePeak)
            if settings.volume == .peak {
                if peak.isFinite {
                    gain = Float(pow(10, (settings.peakTarget - peak) / 20))
                    notes.append(String(format: "Peaks set to %.1f dB (%@).", settings.peakTarget, gainText(gain)))
                } else {
                    notes.append("The file is silent, so its level was left alone.")
                }
            } else {
                let loudness = meter.integratedLoudness
                if loudness.isFinite {
                    var change = settings.loudnessTarget - loudness
                    let truePeak = LoudnessMeter.decibels(meter.truePeak)
                    if truePeak + change > settings.truePeakCeiling, settings.limiter {
                        // The limiter will take some loudness off with the peaks: measure what it leaves and make up for it.
                        let check = LoudnessMeter(channels: plan.channels, sampleRate: plan.sampleRate)
                        try read(processing.effects().effects + [processing.limiter(gain: Float(pow(10, change / 20)))]) { check.process($0) }
                        if check.integratedLoudness.isFinite { change += settings.loudnessTarget - check.integratedLoudness }
                        notes.append(String(format: "Loudness set to %.1f LUFS (was %.1f, %@).", settings.loudnessTarget, loudness,
                                            gainText(Float(pow(10, change / 20)))))
                    } else if truePeak + change > settings.truePeakCeiling {
                        change = settings.truePeakCeiling - truePeak
                        notes.append(String(format: "Reached %.1f LUFS instead of %.1f: the peaks would have gone over %.1f dBTP (%@).",
                                            loudness + change, settings.loudnessTarget, settings.truePeakCeiling, gainText(Float(pow(10, change / 20)))))
                    } else {
                        notes.append(String(format: "Loudness set to %.1f LUFS (was %.1f, %@).", settings.loudnessTarget, loudness,
                                            gainText(Float(pow(10, change / 20)))))
                    }
                    gain = Float(pow(10, change / 20))
                } else {
                    notes.append("The file is too quiet to measure, so its level was left alone.")
                }
            }
        }

        let (effects, dcBlocker) = processing.effects()
        let limiter = settings.limiter ? processing.limiter(gain: gain) : nil
        // With the limiter, the gain is applied in front of it; otherwise when rounding, as before.
        let finalGain: Float = limiter == nil ? gain : 1
        let outputFrames = processing.outputFrames(decoded: decodedFrames)

        let directory = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).recast-\(UUID().uuidString.prefix(8)).\(output.pathExtension)")
        var encoder: AudioEncoder?
        do {
            // Tags go into some encoders at the start, so decide now whether the level changes.
            if gain != 1 || processing.changesLevel || limiter != nil { tags.dropLevelInformation() }
            let setup = EncoderSetup(url: temporary, format: settings.format, sampleRate: plan.sampleRate, channels: plan.channels,
                                     bits: plan.bits, isFloat: plan.isFloat, settings: settings, tags: tags,
                                     includeArtwork: settings.copyArtwork, estimatedFrames: outputFrames, sourceRate: info.sampleRate)
            let created = try EncoderFactory.make(setup)
            encoder = created
            let integer = created.inputFormat.commonFormat == .pcmFormatInt32
            // Dither only when the samples really change: shorter words, or any processing at all.
            let sourcePrecision = info.isLossless && !info.isFloat ? (info.bitDepth ?? 32) : 64
            let processed = gain != 1 || rateChanged || mixer != nil || processing.isActive || limiter != nil
            let bits = plan.bits ?? 32
            let needsDither = settings.dither && integer && bits < 32 && (processed || sourcePrecision > bits)
            var quantizer = integer ? Quantizer(bits: bits, channels: plan.channels, dither: needsDither,
                                                shaping: settings.noiseShaping && (plan.sampleRate == 44100 || plan.sampleRate == 48000)) : nil
            let integerBuffer = integer ? AVAudioPCMBuffer(pcmFormat: created.inputFormat, frameCapacity: blockFrames) : nil
            var overs = 0
            try read(effects + (limiter.map { [$0] } ?? [])) { buffer in
                if var active = quantizer, let integerBuffer {
                    active.process(buffer, gain: finalGain, into: integerBuffer)
                    quantizer = active
                    try created.write(integerBuffer)
                } else {
                    overs += applyGain(buffer, gain: finalGain)
                    try created.write(buffer)
                }
            }
            try created.finish()
            notes += created.notes
            if let dcBlocker, dcBlocker.offset >= 0.0005 {
                notes.append(String(format: "Removed a DC offset of %.2f%% of full scale.", dcBlocker.offset * 100))
            }
            if let limiter, limiter.smallestGain < 0.9988 {
                notes.append(String(format: "The limiter held peaks at %.1f dBTP, lowering them by up to %.1f dB.",
                                    settings.truePeakCeiling, -20 * log10(Double(limiter.smallestGain))))
            }
            if let clipped = quantizer?.clipped, clipped > 0 {
                notes.append("\(clipped) samples went over full scale and were clipped. Lower the level, or use Match loudness or the limiter.")
            } else if overs > 0, !settings.format.isLossless {
                notes.append("\(overs) samples go over full scale and may distort when played. Lower the level, or use Match loudness or the limiter.")
            }
            if needsDither { notes.append(settings.noiseShaping && quantizer?.shaping == true ? "Dithered to \(bits)-bit with noise shaping." : "Dithered to \(bits)-bit.") }
            if settings.copyTags, !tags.isEmpty {
                try TagIO.writeAfterEncoding(tags, includeArtwork: settings.copyArtwork, format: settings.format, to: temporary)
            }
            if settings.keepFileDates, let attributes = try? FileManager.default.attributesOfItem(atPath: input.path) {
                var dates: [FileAttributeKey: Any] = [:]
                dates[.creationDate] = attributes[.creationDate]
                dates[.modificationDate] = attributes[.modificationDate]
                try? FileManager.default.setAttributes(dates, ofItemAtPath: temporary.path)
            }
            if FileManager.default.fileExists(atPath: output.path) {
                _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: output)
            }
        } catch {
            encoder?.abort()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        progress(1)
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: output.path))?[.size] as? NSNumber)?.int64Value ?? 0
        return ConversionOutcome(output: output, bytes: bytes, notes: notes)
    }

    /// Decodes at the plan's rate and channel count, block by block, through `effects` when there are any.
    /// `onBlock` gets the number of frames decoded so far after each block.
    private static func decode(input: URL, plan: ConversionPlan, mixer: ChannelMixer?, sourceChannels: Int, effects: [AudioEffect],
                               onBlock: (Int64) throws -> Void, _ body: (AVAudioPCMBuffer) throws -> Void) throws {
        let reader = try SourceReader(url: input, rate: plan.sampleRate)
        let sourceBuffer = AVAudioPCMBuffer(pcmFormat: floatFormat(rate: plan.sampleRate, channels: sourceChannels), frameCapacity: blockFrames)!
        let mixed = mixer.map { _ in AVAudioPCMBuffer(pcmFormat: floatFormat(rate: plan.sampleRate, channels: plan.channels), frameCapacity: blockFrames)! }
        let processed = effects.isEmpty ? nil : AVAudioPCMBuffer(pcmFormat: floatFormat(rate: plan.sampleRate, channels: plan.channels), frameCapacity: blockFrames)!
        // Effects can hand back more or fewer frames than they got: pass them on in buffer-sized pieces.
        func emit(_ block: [[Float]]) throws {
            guard let processed else { return }
            let total = block.first?.count ?? 0
            var start = 0
            while start < total {
                let count = min(Int(blockFrames), total - start)
                processed.frameLength = AVAudioFrameCount(count)
                for channel in 0..<plan.channels {
                    block[channel].withUnsafeBufferPointer { processed.floatChannelData![channel].update(from: $0.baseAddress! + start, count: count) }
                }
                try body(processed)
                start += count
            }
        }
        var done: Int64 = 0
        while true {
            let frames = try reader.read(into: sourceBuffer)
            if frames == 0 { break }
            done += Int64(frames)
            var buffer = sourceBuffer
            if let mixer, let mixed {
                mixer.process(sourceBuffer, into: mixed)
                buffer = mixed
            }
            if effects.isEmpty {
                try body(buffer)
            } else {
                let count = Int(buffer.frameLength)
                var block = (0..<plan.channels).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: count)) }
                for effect in effects { effect.process(&block) }
                try emit(block)
            }
            try onBlock(done)
        }
        if !effects.isEmpty {
            var block = Array(repeating: [Float](), count: plan.channels)
            for effect in effects { effect.finish(&block) }
            try emit(block)
        }
    }

    private static func gainText(_ gain: Float) -> String {
        let decibels = 20 * log10(Double(gain))
        return abs(decibels) < 0.05 ? "no change" : String(format: "%@%.1f dB", decibels > 0 ? "+" : "−", abs(decibels))
    }
}
