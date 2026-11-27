import Foundation
import RecastCore

/// `Recast --convert …`, `--info …` and `--self-test`: the same engine without the window.
enum CommandLineTool {
    static let usage = """
    Recast — audio converter and batch processor

      Recast --convert FILE|FOLDER… --format FORMAT [options]
      Recast --info FILE…
      Recast --self-test FOLDER

    Formats: wav aiff flac alac caf mp3 aac vorbis opus, or same (each file keeps its format)
    Options:
      --out FOLDER            write into FOLDER (default: next to each original)
      --preset NAME           start from a built-in preset (name or start of it)
      --bitrate KBPS          MP3, AAC, Opus, or Vorbis (average bit rate)
      --vbr LEVEL             MP3 V0–V9, AAC quality 0–127, Vorbis quality -1–10
      --bits 16|24|32|float   PCM and lossless bit depth
      --rate HZ               sample rate
      --mono | --stereo       channels
      --loudness LUFS         match loudness (true-peak limit --peak-limit, default -1)
      --peak DB               normalize peaks
      --gain DB               change the level
      --limit DBTP            true-peak limiter after the level change
      --no-dither             round without dither
      --name PATTERN          file name, e.g. "{track} {title}"
      --replace | --skip      when a file exists (default: keep both)
      --no-tags               don't copy tags
    Processing (in this order, before the level change):
      --swap                  swap left and right
      --invert                invert polarity
      --dc                    remove DC offset
      --highpass HZ           cut below HZ (24 dB/octave)
      --lowpass HZ            cut above HZ
      --trim DB               trim silence below DB (dBFS) at both ends
      --trim-start DB | --trim-end DB    at one end only
      --fade-in MS | --fade-out MS
      --pad-start MS | --pad-end MS      add silence
    """

    static func run(_ arguments: [String]) -> Int32 {
        guard let command = arguments.first else { print(usage); return 1 }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "--convert": return convert(rest)
        case "--info": return info(rest)
        case "--self-test": return SelfTest.run(folder: rest.first.map { URL(fileURLWithPath: $0, isDirectory: true) })
        default: print(usage); return command == "--help" ? 0 : 1
        }
    }

    private static func info(_ paths: [String]) -> Int32 {
        var status: Int32 = 0
        for path in paths {
            let url = URL(fileURLWithPath: path)
            do {
                let info = try AudioProbe.info(url)
                let level = try AudioAnalysis.measure(url)
                print("\(url.lastPathComponent): \(info.summary) · \(AudioFileInfo.durationText(info.duration))")
                print(String(format: "  loudness %.1f LUFS, peak %.1f dBFS, true peak %.1f dBTP", level.loudness, level.samplePeak, level.truePeak))
                let tags = TagIO.read(url)
                for (name, value) in tags.vorbisFields() { print("  \(name): \(value)") }
                if let artwork = tags.artwork { print("  cover art: \(artwork.mimeType), \(artwork.data.count) bytes") }
            } catch {
                print("\(url.lastPathComponent): \(error.localizedDescription)")
                status = 1
            }
        }
        return status
    }

    private static func convert(_ arguments: [String]) -> Int32 {
        var settings = ConversionSettings()
        var inputs: [URL] = []
        var index = 0
        func next() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        var formatGiven = false
        var bitrate: Int?, vbr: Double?
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--format":
                guard let name = next()?.lowercased() else { print(usage); return 1 }
                if name == "same" {
                    settings.keepFormat = true
                } else if let format = OutputFormat(rawValue: name) {
                    settings.keepFormat = false
                    settings.format = format
                } else {
                    print("Unknown format.\n\n\(usage)")
                    return 1
                }
                formatGiven = true
            case "--preset":
                guard let name = next()?.lowercased(),
                      let preset = Preset.builtIn.first(where: { $0.name.lowercased().hasPrefix(name) }) else {
                    print("Presets:\n" + Preset.builtIn.map { "  \($0.name)" }.joined(separator: "\n"))
                    return 1
                }
                settings = settings.applying(preset: preset.settings)
                formatGiven = true
            case "--out":
                guard let path = next() else { return 1 }
                settings.destination = .folder
                settings.folderPath = URL(fileURLWithPath: path).path
            case "--bitrate": bitrate = next().flatMap(Int.init)
            case "--vbr": vbr = next().flatMap(Double.init)
            case "--bits":
                let depth: BitDepth? = ["16": .int16, "24": .int24, "32": .int32, "float": .float32][next() ?? ""]
                guard let depth else { print("--bits takes 16, 24, 32 or float."); return 1 }
                settings.pcmDepth = depth; settings.flacDepth = depth; settings.alacDepth = depth
            case "--rate": settings.sampleRate = next().flatMap(Double.init)
            case "--mono": settings.channels = .mono
            case "--stereo": settings.channels = .stereo
            case "--loudness": settings.volume = .loudness; settings.loudnessTarget = next().flatMap(Double.init) ?? -14
            case "--peak-limit": settings.truePeakCeiling = next().flatMap(Double.init) ?? -1
            case "--peak": settings.volume = .peak; settings.peakTarget = next().flatMap(Double.init) ?? -1
            case "--gain": settings.volume = .gain; settings.gainDB = next().flatMap(Double.init) ?? 0
            case "--limit": settings.limiter = true; settings.truePeakCeiling = next().flatMap(Double.init) ?? -1
            case "--swap": settings.swapChannels = true
            case "--invert": settings.invertPolarity = true
            case "--dc": settings.removeDC = true
            case "--highpass":
                guard let hertz = next().flatMap(Double.init) else { print("--highpass takes a frequency in Hz."); return 1 }
                settings.highPass = true; settings.highPassFrequency = hertz
            case "--lowpass":
                guard let hertz = next().flatMap(Double.init) else { print("--lowpass takes a frequency in Hz."); return 1 }
                settings.lowPass = true; settings.lowPassFrequency = hertz
            case "--trim", "--trim-start", "--trim-end":
                guard let level = next().flatMap(Double.init) else { print("\(argument) takes a level in dB, e.g. -60."); return 1 }
                settings.trim = argument == "--trim" ? .both : argument == "--trim-start" ? .start : .end
                settings.trimThreshold = level
            case "--fade-in", "--fade-out", "--pad-start", "--pad-end":
                guard let milliseconds = next().flatMap(Double.init), milliseconds >= 0 else { print("\(argument) takes milliseconds."); return 1 }
                switch argument {
                case "--fade-in": settings.fadeInMS = milliseconds
                case "--fade-out": settings.fadeOutMS = milliseconds
                case "--pad-start": settings.padStartMS = milliseconds
                default: settings.padEndMS = milliseconds
                }
            case "--no-dither": settings.dither = false
            case "--name": settings.namePattern = next() ?? "{name}"
            case "--replace": settings.collision = .replace
            case "--skip": settings.collision = .skip
            case "--no-tags": settings.copyTags = false
            default:
                if argument.hasPrefix("--") { print("Unknown option \(argument).\n\n\(usage)"); return 1 }
                inputs.append(URL(fileURLWithPath: argument))
            }
            index += 1
        }
        guard formatGiven, !inputs.isEmpty else { print(usage); return 1 }
        if let bitrate {
            settings.mp3Bitrate = bitrate; settings.aacBitrate = bitrate; settings.opusBitrate = bitrate; settings.vorbisBitrate = bitrate
            if settings.format == .mp3, settings.mp3Mode == .vbr { settings.mp3Mode = .cbr }
            if settings.format == .vorbis { settings.vorbisMode = .bitrate }
            if settings.format == .aac, settings.aacMode == .vbr { settings.aacMode = .constrainedVBR }
        }
        if let vbr {
            settings.mp3Mode = .vbr; settings.mp3VBRQuality = Int(vbr)
            settings.aacMode = .vbr; settings.aacVBRQuality = Int(vbr)
            settings.vorbisMode = .quality; settings.vorbisQuality = vbr
        }

        let files = AudioFileScanner.scan(inputs)
        var taken = Set(files.map { OutputPlanner.pathKey($0.url) })
        var failures: Int32 = 0
        for file in files {
            let tags = TagIO.read(file.url)
            let planned = OutputPlanner.plannedURL(for: file.url, sourceRoot: file.root, settings: settings, tags: tags)
            switch OutputPlanner.resolve(planned, input: file.url, policy: settings.collision, taken: taken) {
            case .skip(let existing):
                print("skipped \(file.url.lastPathComponent): \(existing.path) exists")
            case .write(let output):
                taken.insert(OutputPlanner.pathKey(output))
                do {
                    let outcome = try Converter.convert(input: file.url, to: output, settings: settings)
                    print("\(file.url.lastPathComponent) → \(outcome.output.path) (\(ByteCountFormatter.string(fromByteCount: outcome.bytes, countStyle: .file)))")
                    for note in outcome.notes { print("  \(note)") }
                } catch {
                    print("failed \(file.url.lastPathComponent): \(error.localizedDescription)")
                    failures += 1
                }
            }
        }
        return failures == 0 ? 0 : 2
    }
}
