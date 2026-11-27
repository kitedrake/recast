import AVFoundation
import AppKit
import Foundation
import RecastCore

/// `Recast --self-test FOLDER`: makes a tagged 24-bit test file in FOLDER, converts it to every format with the
/// built app and checks the results (bit-exact lossless audio, lengths, tags, cover art, loudness matching).
enum SelfTest {
    static func run(folder: URL?) -> Int32 {
        let folder = folder ?? FileManager.default.temporaryDirectory.appendingPathComponent("Recast self-test \(UUID().uuidString.prefix(6))")
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        do {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let rate = 44100.0, frames = 88200
            let samples = (0..<2).map { channel in
                (0..<frames).map { index -> Float in
                    let t = Double(index) / rate
                    let value = 0.5 * sin(2 * .pi * (220 * t + 600 * t * t)) * (channel == 0 ? 1 : 0.6)
                    return Float((value * 8_388_608).rounded() / 8_388_608)
                }
            }
            let source = folder.appendingPathComponent("Self Test.wav")
            try writeWAV(samples, rate: rate, to: source)
            var tags = AudioTags()
            tags.title = "Self Test"
            tags.artist = "Recast"
            tags.album = "Checks"
            tags.track = 1
            tags.trackTotal = 9
            tags.artwork = Artwork(data: coverArt(), mimeType: "image/png")
            try TagIO.write(tags, to: source)

            for format in OutputFormat.allCases {
                var settings = ConversionSettings()
                settings.format = format
                let name = folder.appendingPathComponent("Self Test \(format.rawValue.uppercased())").appendingPathExtension(format.fileExtension)
                do {
                    let outcome = try Converter.convert(input: source, to: name, settings: settings)
                    let info = try AudioProbe.info(outcome.output)
                    expect(abs(info.duration - 2) < 0.06, "\(format.title): \(info.duration) s instead of 2 s")
                    let read = TagIO.read(outcome.output)
                    expect(read.title == "Self Test", "\(format.title): title not copied")
                    expect(read.track == 1, "\(format.title): track number not copied")
                    if format != .caf { expect(read.artwork?.data == tags.artwork?.data, "\(format.title): cover art not copied") }
                    if format.isLossless { expect(try decode(outcome.output) == samples, "\(format.title): audio isn't bit-exact") }
                    print("ok \(format.title): \(info.summary), \(outcome.bytes) bytes")
                } catch {
                    failures.append("\(format.title): \(error.localizedDescription)")
                }
            }

            var loud = ConversionSettings()
            loud.format = .mp3
            loud.volume = .loudness
            loud.loudnessTarget = -16
            let podcast = try Converter.convert(input: source, to: folder.appendingPathComponent("Self Test -16 LUFS.mp3"), settings: loud)
            let level = try AudioAnalysis.measure(podcast.output)
            expect(abs(level.loudness + 16) < 0.5, String(format: "loudness matching: %.2f LUFS instead of -16", level.loudness))
            print(String(format: "ok loudness: %.2f LUFS, true peak %.2f dBTP", level.loudness, level.truePeak))

            // Processing: the test file with a click every half second and silence around it, trimmed, faded, filtered
            // and made louder, with the limiter catching the clicks.
            let padded = folder.appendingPathComponent("Self Test padded.wav")
            let silence = [Float](repeating: 0, count: 22050)
            let clicked = samples.map { channel in channel.enumerated().map { index, value in index % 22050 < 20 ? 0.95 : value } }
            try writeWAV(clicked.map { silence + $0 + silence }, rate: rate, to: padded)
            var processing = ConversionSettings()
            processing.keepFormat = true
            processing.trim = .both
            processing.fadeInMS = 10
            processing.fadeOutMS = 100
            processing.highPass = true
            processing.removeDC = true
            processing.volume = .loudness
            processing.loudnessTarget = -6
            processing.limiter = true
            let processedURL = folder.appendingPathComponent("Self Test processed.wav")
            let processed = try Converter.convert(input: padded, to: processedURL, settings: processing)
            let processedInfo = try AudioProbe.info(processed.output)
            let processedLevel = try AudioAnalysis.measure(processed.output)
            expect(processedInfo.bitDepth == 24, "processing: \(processedInfo.summary) instead of the source's 24-bit WAV")
            // The high-pass filter rings on a little after the sound stops, so the end trim keeps a few milliseconds more.
            expect(processedInfo.duration > 1.99 && processedInfo.duration < 2.06, "processing: \(processedInfo.duration) s after trimming instead of 2 s")
            expect(abs(processedLevel.loudness + 6) < 0.3, String(format: "processing: %.2f LUFS instead of -6", processedLevel.loudness))
            expect(processedLevel.truePeak < -0.9, String(format: "processing: true peak %.2f dBTP over the -1 dBTP limit", processedLevel.truePeak))
            expect(processed.notes.contains { $0.hasPrefix("The limiter held peaks") }, "processing: the limiter didn't work (\(processed.notes))")
            print(String(format: "ok processing: %.3f s, %.2f LUFS, true peak %.2f dBTP", processedInfo.duration, processedLevel.loudness, processedLevel.truePeak))

            // Audio Units: Apple's sample delay set to 100 samples, then Apple's peak limiter, whose 2 ms look-ahead
            // must be taken out again. Far below the limiter's threshold, the result is the source 100 samples later.
            let installed = PluginHost.installedEffects()
            if var delay = installed.first(where: { $0.codes == "aufx sdly appl" }), let limiter = installed.first(where: { $0.codes == "aufx lmtr appl" }) {
                let unit = try PluginHost.load(delay)
                unit.parameterTree?.parameter(withAddress: 0)?.value = 100
                delay.state = PluginHost.state(of: unit)
                var plugins = ConversionSettings()
                plugins.format = .wav
                plugins.pcmDepth = .float32
                plugins.plugins = [delay, limiter]
                let quiet = samples.map { $0.map { $0 * 0.2 } }
                let quietURL = folder.appendingPathComponent("Self Test quiet.wav")
                try writeWAV(quiet, rate: rate, to: quietURL)
                let pluginOutcome = try Converter.convert(input: quietURL, to: folder.appendingPathComponent("Self Test plugins.wav"), settings: plugins)
                let result = try decode(pluginOutcome.output)
                expect(result[0].count == frames, "Audio Units: \(result[0].count) samples instead of \(frames)")
                let error = zip(result[0].dropFirst(100), quiet[0].dropLast(100)).map { abs($0 - $1) }.max() ?? 1
                expect(error < 0.001, "Audio Units: the result is \(error) away from the delayed source")
                print(String(format: "ok Audio Units: sample delay and peak limiter, largest difference %.6f", error))
            } else {
                failures.append("Audio Units: Apple's AUSampleDelay or AUPeakLimiter isn't installed")
            }
        } catch {
            failures.append(error.localizedDescription)
        }
        if failures.isEmpty {
            print("Self-test passed (\(folder.path)).")
            return 0
        }
        print("Self-test FAILED:\n" + failures.map { "  \($0)" }.joined(separator: "\n"))
        return 1
    }

    private static func writeWAV(_ samples: [[Float]], rate: Double, to url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: samples.count,
                                       AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples[0].count))!
        buffer.frameLength = buffer.frameCapacity
        for (channel, values) in samples.enumerated() { buffer.floatChannelData![channel].update(from: values, count: values.count) }
        try file.write(from: buffer)
    }

    private static func decode(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let channels = Int(file.processingFormat.channelCount)
        var result = Array(repeating: [Float](), count: channels)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32768)!
        while file.framePosition < file.length {
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            for channel in 0..<channels {
                result[channel] += UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength))
            }
        }
        return result
    }

    private static func coverArt() -> Data {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemIndigo.setFill()
            rect.fill()
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }
}
