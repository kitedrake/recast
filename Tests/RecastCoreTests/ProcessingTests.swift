import AVFoundation
import XCTest
@testable import RecastCore

final class ProcessingTests: XCTestCase {
    override func setUp() { Fixtures.currentTest = self }

    /// Float WAV so the processed samples can be compared exactly.
    private func floatWAV(_ edit: (inout ConversionSettings) -> Void) -> ConversionSettings {
        Fixtures.settings(.wav) { $0.pcmDepth = .float32; edit(&$0) }
    }

    private func write(_ samples: [[Float]], rate: Double = 44100, to folder: URL, _ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Fixtures.writePCM(samples, rate: rate, bits: 32, float: true, to: url)
        return url
    }

    private func level(_ values: ArraySlice<Float>) -> Double { Fixtures.rms(Array(values)) }

    func testTrimSilence() throws {
        let folder = try Fixtures.folder()
        let tone = Fixtures.sine(frequency: 440, frames: 44100, rate: 44100, amplitude: 0.5)
        // 0.5 s of a quiet buzz (-80 dB) before, 0.25 s after.
        let quiet = { (count: Int) in (0..<count).map { $0 % 2 == 0 ? Float(0.0001) : -0.0001 } }
        let samples = tone.map { quiet(22050) + [0.3] + $0.dropFirst() + quiet(11025) }
        let source = try write(samples, to: folder, "padded.wav")

        let both = try Fixtures.convert(source, floatWAV { $0.trim = .both }, name: "both")
        let trimmed = try Fixtures.read(both.output).samples
        XCTAssertEqual(trimmed[0].count, 44100)
        XCTAssertEqual(trimmed[0], Array(samples[0][22050..<66150]), "trimming must keep the sound untouched")
        XCTAssertTrue(both.notes.contains("Trimmed silence: 500 ms from the start and 250 ms from the end."), "\(both.notes)")

        let start = try Fixtures.read(Fixtures.convert(source, floatWAV { $0.trim = .start }, name: "start").output).samples
        XCTAssertEqual(start[0].count, 44100 + 11025)
        let end = try Fixtures.read(Fixtures.convert(source, floatWAV { $0.trim = .end }, name: "end").output).samples
        XCTAssertEqual(end[0].count, 22050 + 44100)

        // A threshold under the noise keeps everything.
        let low = try Fixtures.convert(source, floatWAV { $0.trim = .both; $0.trimThreshold = -90 }, name: "low")
        XCTAssertEqual(try Fixtures.read(low.output).samples[0].count, samples[0].count)

        // A file that's silence through and through is left as it is, with a note.
        let silent = try write([quiet(4410)], to: folder, "silent.wav")
        let kept = try Fixtures.convert(silent, floatWAV { $0.trim = .both })
        XCTAssertEqual(try Fixtures.read(kept.output).samples[0].count, 4410)
        XCTAssertTrue(kept.notes.contains { $0.hasPrefix("Nothing trimmed") }, "\(kept.notes)")
    }

    func testFadesAndPadding() throws {
        let folder = try Fixtures.folder()
        let flat = [[Float](repeating: 0.5, count: 44100)]
        let source = try write(flat, to: folder, "flat.wav")
        let outcome = try Fixtures.convert(source, floatWAV { $0.fadeInMS = 100; $0.fadeOutMS = 200; $0.padStartMS = 50; $0.padEndMS = 25 })
        let result = try Fixtures.read(outcome.output).samples[0]
        let pad = 2205, inFrames = 4410, outFrames = 8820
        XCTAssertEqual(result.count, 44100 + pad + 1103)
        XCTAssertTrue(result[0..<pad].allSatisfy { $0 == 0 }, "silence before")
        XCTAssertTrue(result[(pad + 44100)...].allSatisfy { $0 == 0 }, "silence after")
        XCTAssertEqual(result[pad], 0, "the fade-in starts silent")
        XCTAssertEqual(result[pad + inFrames / 2], 0.25, accuracy: 1e-4, "halfway through the fade-in")
        XCTAssertEqual(result[pad + inFrames], 0.5, "the fade-in ends at full level")
        XCTAssertTrue(result[(pad + inFrames)..<(pad + 44100 - outFrames)].allSatisfy { $0 == 0.5 }, "the middle is untouched")
        XCTAssertEqual(result[pad + 44100 - 1], 0, "the fade-out ends silent")
        XCTAssertEqual(result[pad + 44100 - 1 - outFrames / 2], 0.25, accuracy: 1e-4, "halfway through the fade-out")
        // The curve rises smoothly.
        let fadeIn = result[pad..<(pad + inFrames)]
        XCTAssertTrue(zip(fadeIn, fadeIn.dropFirst()).allSatisfy { $0 <= $1 })
    }

    func testFadeOutEndsSilentWhenResampling() throws {
        let folder = try Fixtures.folder()
        let source = try write(Fixtures.sine(frequency: 300, frames: 30000, rate: 44100, amplitude: 0.8), to: folder, "tone.wav")
        let outcome = try Fixtures.convert(source, floatWAV { $0.sampleRate = 48000; $0.fadeOutMS = 50 })
        let result = try Fixtures.read(outcome.output).samples
        XCTAssertLessThan(abs(result[0].last!), 1e-6)
        XCTAssertLessThan(Fixtures.peak([Array(result[0].suffix(48))]), 0.01)
    }

    func testFilters() throws {
        let folder = try Fixtures.folder()
        let rate = 48000.0, frames = 48000
        func passed(_ frequency: Double, _ edit: (inout ConversionSettings) -> Void) throws -> Double {
            let source = try write(Fixtures.sine(frequency: frequency, frames: frames, rate: rate, amplitude: 0.5, channels: 1),
                                   rate: rate, to: folder, "tone-\(Int(frequency)).wav")
            let output = try Fixtures.convert(source, floatWAV(edit), name: "filtered-\(UUID().uuidString.prefix(4))").output
            let samples = try Fixtures.read(output).samples[0]
            // Skip the filter settling in at the start.
            return 20 * log10(level(samples[(frames / 4)...]) / (0.5 / sqrt(2)))
        }
        XCTAssertEqual(try passed(1000) { $0.highPass = true; $0.highPassFrequency = 1000 }, -3.01, accuracy: 0.1, "−3 dB at the corner")
        XCTAssertEqual(try passed(10000) { $0.highPass = true; $0.highPassFrequency = 1000 }, 0, accuracy: 0.05)
        XCTAssertEqual(try passed(500) { $0.highPass = true; $0.highPassFrequency = 1000 }, -24.1, accuracy: 0.5, "24 dB per octave")
        XCTAssertEqual(try passed(1000) { $0.lowPass = true; $0.lowPassFrequency = 1000 }, -3.01, accuracy: 0.1)
        XCTAssertEqual(try passed(100) { $0.lowPass = true; $0.lowPassFrequency = 1000 }, 0, accuracy: 0.05)
        XCTAssertEqual(try passed(2000) { $0.lowPass = true; $0.lowPassFrequency = 1000 }, -24.1, accuracy: 0.5)

        // A low-pass above what the rate can hold is skipped, with a note.
        let source = try write(Fixtures.sine(frequency: 1000, frames: 4800, rate: rate, amplitude: 0.5), rate: rate, to: folder, "short.wav")
        let skipped = try Fixtures.convert(source, floatWAV { $0.lowPass = true; $0.lowPassFrequency = 30000 })
        XCTAssertTrue(skipped.notes.contains { $0.hasPrefix("Low-pass at 30 kHz skipped") }, "\(skipped.notes)")
    }

    func testDCOffsetRemoval() throws {
        let folder = try Fixtures.folder()
        let tone = Fixtures.sine(frequency: 1000, frames: 44100, rate: 44100, amplitude: 0.4, channels: 1)[0]
        let source = try write([tone.map { $0 + 0.1 }], to: folder, "offset.wav")
        let outcome = try Fixtures.convert(source, floatWAV { $0.removeDC = true })
        XCTAssertTrue(outcome.notes.contains("Removed a DC offset of 10.00% of full scale."), "\(outcome.notes)")
        let result = try Fixtures.read(outcome.output).samples[0]
        // No thump at the start, no offset left, and the tone itself unchanged.
        XCTAssertLessThan(Fixtures.peak([result]), 0.41)
        XCTAssertEqual(result.reduce(0, +) / Float(result.count), 0, accuracy: 0.001)
        // The 5 Hz filter shifts a 1 kHz tone by 0.3°, about 0.002 here; the first moments settle a little more.
        XCTAssertLessThan(zip(result, tone).map { abs($0 - $1) }.max()!, 0.006)
        XCTAssertLessThan(zip(result.dropFirst(4410), tone.dropFirst(4410)).map { abs($0 - $1) }.max()!, 0.0025)
    }

    func testSwapAndInvert() throws {
        let folder = try Fixtures.folder()
        let samples = Fixtures.signal(frames: 4410, channels: 2, rate: 44100)
        let source = try write(samples, to: folder, "stereo.wav")
        let swapped = try Fixtures.read(Fixtures.convert(source, floatWAV { $0.swapChannels = true }, name: "swapped").output).samples
        XCTAssertEqual(swapped, [samples[1], samples[0]])
        let inverted = try Fixtures.read(Fixtures.convert(source, floatWAV { $0.invertPolarity = true }, name: "inverted").output).samples
        XCTAssertEqual(inverted, samples.map { $0.map { -$0 } })
    }

    func testLimiterHoldsTruePeaksWithoutDelay() throws {
        let folder = try Fixtures.folder()
        let samples = Fixtures.signal(frames: 88200, channels: 2, rate: 44100, level: 0.5)
        let source = try write(samples, to: folder, "signal.wav")
        let outcome = try Fixtures.convert(source, floatWAV { $0.volume = .gain; $0.gainDB = 12; $0.limiter = true; $0.truePeakCeiling = -1 })
        XCTAssertTrue(outcome.notes.contains { $0.hasPrefix("The limiter held peaks at -1.0 dBTP") }, "\(outcome.notes)")
        let level = try AudioAnalysis.measure(outcome.output)
        XCTAssertLessThanOrEqual(level.truePeak, -0.95, "true peak")
        let result = try Fixtures.read(outcome.output).samples
        XCTAssertEqual(result[0].count, samples[0].count, "same length")
        let (lag, correlation) = Fixtures.alignment(samples[0], result[0])
        XCTAssertEqual(lag, 0, "the look-ahead delay is taken out")
        XCTAssertGreaterThan(correlation, 0.97)

        // Below the ceiling it changes nothing.
        let quiet = try Fixtures.convert(source, floatWAV { $0.limiter = true; $0.truePeakCeiling = -1 }, name: "untouched")
        XCTAssertEqual(try Fixtures.read(quiet.output).samples, samples)
        XCTAssertFalse(quiet.notes.contains { $0.contains("limiter") })
    }

    func testLoudnessWithLimiterReachesTheTarget() throws {
        let folder = try Fixtures.folder()
        // A -20 dBFS tone with a short click every half second: quiet, but with peaks near full scale.
        let samples = Fixtures.sine(frequency: 1000, frames: 44100 * 4, rate: 44100, amplitude: 0.1).map { channel in
            channel.enumerated().map { index, value in index % 22050 < 20 ? value + 0.8 : value }
        }
        let source = try write(samples, to: folder, "clicks.wav")
        // Without the limiter, the peak limit stops it short of -8 LUFS.
        let capped = try Fixtures.convert(source, floatWAV { $0.volume = .loudness; $0.loudnessTarget = -8 }, name: "capped")
        XCTAssertTrue(capped.notes.contains { $0.contains("instead of -8.0") }, "\(capped.notes)")
        for format in [OutputFormat.wav, .flac] {
            let settings = Fixtures.settings(format) { $0.volume = .loudness; $0.loudnessTarget = -8; $0.limiter = true; $0.truePeakCeiling = -1 }
            let outcome = try Fixtures.convert(source, settings, name: "limited-\(format.rawValue)")
            let level = try AudioAnalysis.measure(outcome.output)
            XCTAssertEqual(level.loudness, -8, accuracy: 0.2, "\(format) loudness")
            XCTAssertLessThanOrEqual(level.truePeak, -0.95, "\(format) true peak")
            XCTAssertTrue(outcome.notes.contains { $0.hasPrefix("Loudness set to -8.0 LUFS") }, "\(outcome.notes)")
            XCTAssertTrue(outcome.notes.contains { $0.hasPrefix("The limiter held peaks") }, "\(outcome.notes)")
        }
    }

    func testProcessingInCompressedFormats() throws {
        let folder = try Fixtures.folder()
        let samples = Fixtures.quantized(Fixtures.signal(frames: 44100 * 2, channels: 2, rate: 44100), bits: 24)
        let silence = [Float](repeating: 0, count: 8820)
        let source = folder.appendingPathComponent("source.wav")
        try Fixtures.writePCM(samples.map { silence + $0 + silence }, rate: 44100, bits: 24, to: source)
        try ChunkTags.writeWAV(Fixtures.tags, includeArtwork: true, to: source)
        for format in OutputFormat.allCases {
            let settings = Fixtures.settings(format) { $0.trim = .both; $0.fadeInMS = 5; $0.fadeOutMS = 20; $0.padEndMS = 100; $0.limiter = true }
            let outcome = try Fixtures.convert(source, settings, name: "processed-\(format.rawValue)")
            let info = try AudioProbe.info(outcome.output)
            XCTAssertEqual(info.duration, 2.1, accuracy: 0.06, "\(format) length")
            XCTAssertEqual(TagIO.read(outcome.output).title, Fixtures.tags.title, "\(format) tags")
        }
    }

    func testSameFormat() throws {
        let folder = try Fixtures.folder()
        let samples = Fixtures.quantized(Fixtures.signal(frames: 44100, channels: 2, rate: 44100), bits: 16)
        let source = folder.appendingPathComponent("cd.wav")
        try Fixtures.writePCM(samples, rate: 44100, bits: 16, to: source)
        var same = ConversionSettings()
        same.keepFormat = true
        same.format = .mp3
        same.pcmDepth = .int24 // ignored: lossless files keep their depth

        // Lossless: same format, same depth, bit-exact; the name gets a number next to the original.
        let flac = try Fixtures.convert(source, Fixtures.settings(.flac), name: "cd")
        let planned = OutputPlanner.plannedURL(for: flac.output, sourceRoot: nil, settings: same, tags: AudioTags())
        XCTAssertEqual(planned.pathExtension, "flac")
        guard case .write(let output) = OutputPlanner.resolve(planned, input: flac.output, policy: .replace, taken: [OutputPlanner.pathKey(flac.output)]) else {
            return XCTFail("planned a skip")
        }
        XCTAssertEqual(output.lastPathComponent, "cd 2.flac")
        let kept = try Converter.convert(input: flac.output, to: output, settings: same)
        XCTAssertTrue(kept.notes.isEmpty, "\(kept.notes)")
        XCTAssertEqual(try AudioProbe.info(kept.output).formatName, "FLAC")
        XCTAssertEqual(try AudioProbe.info(kept.output).bitDepth, 16)
        XCTAssertEqual(try Fixtures.read(kept.output).samples, samples)

        // Compressed: about the same bit rate, with a note.
        let mp3 = try Fixtures.convert(source, Fixtures.settings(.mp3) { $0.mp3Bitrate = 128 }, name: "song")
        let again = try Converter.convert(input: mp3.output, to: folder.appendingPathComponent("song again.mp3"), settings: same)
        XCTAssertTrue(again.notes.contains("Encoded as MP3 again at 128 kbps: each new encoding loses a little quality."), "\(again.notes)")
        XCTAssertEqual(try AudioProbe.info(again.output).formatName, "MP3")
        XCTAssertEqual(Double(try AudioProbe.info(again.output).bitRate ?? 0), 128_000, accuracy: 4000)

        // Formats Recast doesn't write.
        func info(_ name: String, lossless: Bool, kbps: Int = 0) -> AudioFileInfo {
            AudioFileInfo(formatName: name, sampleRate: 48000, channels: 2, bitDepth: lossless ? 24 : nil, isFloat: false,
                          isLossless: lossless, frames: 48000, bitRate: kbps * 1000, fileSize: 0)
        }
        XCTAssertEqual(same.outputFormat(for: info("Wave64", lossless: true)), .wav)
        XCTAssertEqual(same.outputFormat(for: info("MP2", lossless: false)), .flac)
        XCTAssertEqual(same.resolved(for: info("MP2", lossless: false)).notes, ["Saved as FLAC: Recast doesn't write MP2."])
        let he = same.resolved(for: info("HE-AAC", lossless: false, kbps: 48)).settings
        XCTAssertEqual(he.format, .aac)
        XCTAssertEqual(he.aacProfile, .he)
        XCTAssertEqual(he.aacBitrate, 48)
        XCTAssertEqual(same.resolved(for: info("Opus", lossless: false, kbps: 97)).settings.opusBitrate, 97)
        XCTAssertEqual(same.resolved(for: info("Ogg Vorbis", lossless: false, kbps: 170)).settings.vorbisBitrate, 192)
    }

    func testSavedPresetsWithoutNewSettingsStillLoad() throws {
        // A preset saved by 0.1.1, before processing existed.
        let saved = #"[{"id":"1D2E3F40-0000-4000-8000-000000000001","name":"Mine","isBuiltIn":false,"settings":{"format":"aac","aacBitrate":192,"volume":"loudness","loudnessTarget":-16}}]"#
        let presets = Preset.decodeList(Data(saved.utf8))
        XCTAssertEqual(presets.count, 1)
        XCTAssertEqual(presets.first?.name, "Mine")
        XCTAssertEqual(presets.first?.settings.format, .aac)
        XCTAssertEqual(presets.first?.settings.aacBitrate, 192)
        XCTAssertEqual(presets.first?.settings.loudnessTarget, -16)
        XCTAssertEqual(presets.first?.settings.trim, .off)
        XCTAssertFalse(presets.first?.settings.limiter ?? true)
        // And today's presets round-trip.
        let current = Preset(name: "New", settings: Fixtures.settings(.opus) { $0.trim = .start; $0.highPass = true; $0.keepFormat = true })
        XCTAssertEqual(Preset.decodeList(try JSONEncoder().encode([current])), [current])
    }
}
