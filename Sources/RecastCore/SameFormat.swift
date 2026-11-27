import Foundation

extension AudioFileInfo {
    /// The format Recast writes that matches this file's own, if there is one.
    public var matchingFormat: OutputFormat? {
        switch formatName {
        case "WAV": return .wav
        case "AIFF": return .aiff
        case "CAF": return .caf
        case "FLAC": return .flac
        case "Apple Lossless": return .alac
        case "AAC", "HE-AAC", "HE-AAC v2": return .aac
        case "MP3": return .mp3
        case "Ogg Vorbis": return .vorbis
        case "Opus": return .opus
        default: return nil
        }
    }
}

extension ConversionSettings {
    /// The format a file is saved in: the chosen one, or with "same as source" the file's own. Files in a format
    /// Recast can't write become WAV when they are uncompressed (Wave64, AU, Sound Designer II), FLAC otherwise.
    public func outputFormat(for info: AudioFileInfo?) -> OutputFormat {
        guard keepFormat, let info else { return format }
        return info.matchingFormat ?? (info.isLossless ? .wav : .flac)
    }

    /// The settings one file is converted with. With "same as source" the file keeps its format: lossless files
    /// their bit depth, compressed files about their bit rate. The notes say when a file can't keep its format, and
    /// that compressed files lose a little each time they are encoded again.
    public func resolved(for info: AudioFileInfo) -> (settings: ConversionSettings, notes: [String]) {
        guard keepFormat else { return (self, []) }
        var settings = self
        settings.keepFormat = false
        settings.format = outputFormat(for: info)
        var notes: [String] = []
        if info.matchingFormat == nil {
            notes.append("Saved as \(settings.format.title): Recast doesn't write \(info.formatName).")
        }
        let kbps = (info.bitRate ?? 0) / 1000
        func nearest(_ rates: [Int]) -> Int? {
            guard kbps > 0 else { return nil }
            // The smallest listed rate that keeps about as many bits as the source, else the highest.
            return rates.first { Double($0) >= Double(kbps) * 0.97 } ?? rates.last
        }
        switch settings.format {
        case .wav, .aiff, .caf, .flac, .alac:
            settings.setDepth(.match)
        case .mp3:
            if let rate = nearest([32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]) {
                settings.mp3Mode = .cbr
                settings.mp3Bitrate = rate
            }
        case .aac:
            settings.aacProfile = info.formatName.hasPrefix("HE-AAC") ? .he : .lc
            let rates = settings.aacProfile == .he ? [24, 32, 40, 48, 56, 64, 80] : [64, 80, 96, 112, 128, 160, 192, 224, 256, 288, 320]
            if let rate = nearest(rates) {
                settings.aacMode = .constrainedVBR
                settings.aacBitrate = rate
            }
        case .vorbis:
            if let rate = nearest([48, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 500]) {
                settings.vorbisMode = .bitrate
                settings.vorbisBitrate = rate
            }
        case .opus:
            if kbps > 0 { settings.opusBitrate = min(510, max(6, kbps)) }
        }
        if !settings.format.isLossless {
            let quality = settings.qualitySummary
            notes.append("Encoded as \(settings.format.title) again at \(quality.prefix(1).lowercased() + quality.dropFirst()): each new encoding loses a little quality.")
        }
        return (settings, notes)
    }
}
