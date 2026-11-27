import AVFoundation
import AudioToolbox
import Foundation

/// An Audio Unit effect in the processing chain, with its own settings.
public struct PluginEffect: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var manufacturer: String
    public var type: UInt32
    public var subtype: UInt32
    public var manufacturerCode: UInt32
    /// The plugin's full state as a binary property list; nil keeps its defaults.
    public var state: Data?
    public var bypassed: Bool

    public init(id: UUID = UUID(), name: String, manufacturer: String, description: AudioComponentDescription,
                state: Data? = nil, bypassed: Bool = false) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        type = description.componentType
        subtype = description.componentSubType
        manufacturerCode = description.componentManufacturer
        self.state = state
        self.bypassed = bypassed
    }

    /// Settings saved by a later version may lack keys; only the plugin's identity is required.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(UInt32.self, forKey: .type)
        subtype = try container.decode(UInt32.self, forKey: .subtype)
        manufacturerCode = try container.decode(UInt32.self, forKey: .manufacturerCode)
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        manufacturer = (try? container.decodeIfPresent(String.self, forKey: .manufacturer)) ?? ""
        state = try? container.decodeIfPresent(Data.self, forKey: .state)
        bypassed = (try? container.decodeIfPresent(Bool.self, forKey: .bypassed)) ?? false
    }

    public var componentDescription: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subtype, componentManufacturer: manufacturerCode,
                                  componentFlags: 0, componentFlagsMask: 0)
    }

    /// e.g. "AUDelay (Apple)".
    public var title: String { manufacturer.isEmpty ? name : "\(name) (\(manufacturer))" }

    /// The type, subtype and manufacturer codes, e.g. "aufx dely appl".
    public var codes: String { [type, subtype, manufacturerCode].map(Self.fourCC).joined(separator: " ") }

    static func fourCC(_ value: UInt32) -> String {
        let bytes = [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(value)
    }
}

/// Finding, loading and saving Audio Unit effects.
public enum PluginHost {
    /// Every effect installed on this Mac (Audio Units of the effect and music-effect types), by manufacturer and
    /// name, each with its default settings.
    public static func installedEffects() -> [PluginEffect] {
        let manager = AVAudioUnitComponentManager.shared()
        let components = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect].flatMap { type in
            manager.components(matching: AudioComponentDescription(componentType: type, componentSubType: 0,
                                                                   componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0))
        }
        return components
            .map { PluginEffect(name: $0.name, manufacturer: $0.manufacturerName, description: $0.audioComponentDescription) }
            .sorted { ($0.manufacturer.lowercased(), $0.name.lowercased()) < ($1.manufacturer.lowercased(), $1.name.lowercased()) }
    }

    public static func isInstalled(_ effect: PluginEffect) -> Bool {
        !AVAudioUnitComponentManager.shared().components(matching: effect.componentDescription).isEmpty
    }

    /// Loads a plugin with its saved settings. It runs in a separate process when macOS allows: a plugin that
    /// crashes then fails one file instead of taking Recast down, Intel-only plugins work on Apple silicon, and a
    /// signed Recast needs no exception to load other developers' code. Plugins that can't run that way load into
    /// Recast itself.
    public static func load(_ effect: PluginEffect) throws -> AUAudioUnit {
        guard isInstalled(effect) else {
            throw ConversionError.plugin("“\(effect.name)”\(effect.manufacturer.isEmpty ? "" : " by \(effect.manufacturer)") isn't installed on this Mac.")
        }
        let unit: AUAudioUnit
        do {
            unit = try instantiate(effect.componentDescription, options: .loadOutOfProcess)
        } catch {
            do {
                unit = try instantiate(effect.componentDescription, options: .loadInProcess)
            } catch {
                throw ConversionError.plugin("Couldn't load “\(effect.name)”: \(error.localizedDescription)")
            }
        }
        if let data = effect.state {
            guard let state = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
                throw ConversionError.plugin("The saved settings of “\(effect.name)” can't be read.")
            }
            unit.fullStateForDocument = state
        }
        return unit
    }

    /// A plugin's current settings, to store in a `PluginEffect`.
    public static func state(of unit: AUAudioUnit) -> Data? {
        guard let state = unit.fullStateForDocument ?? unit.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    /// Settings from an `.aupreset` file (a property list the plugin wrote), to store in a `PluginEffect`.
    public static func state(fromPresetFile url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard let state = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ConversionError.plugin("“\(url.lastPathComponent)” isn't an Audio Unit preset.")
        }
        return try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    /// Instantiates and waits. On the main thread (the command line, tests) the run loop keeps turning meanwhile,
    /// in case macOS answers there.
    static func instantiate(_ description: AudioComponentDescription, options: AudioComponentInstantiationOptions) throws -> AUAudioUnit {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var result: Result<AUAudioUnit, Error>?
        }
        let box = Box()
        AUAudioUnit.instantiate(with: description, options: options) { unit, error in
            box.lock.withLock {
                if let unit { box.result = .success(unit) } else { box.result = .failure(error ?? ConversionError.plugin("The plugin didn't load.")) }
            }
        }
        let deadline = Date(timeIntervalSinceNow: 30)
        while Date() < deadline {
            if let result = box.lock.withLock({ box.result }) { return try result.get() }
            if Thread.isMainThread {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
            } else {
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        throw ConversionError.plugin("The plugin took more than 30 seconds to load.")
    }
}

/// One loaded plugin, rendering offline block by block. Its reported latency is taken out (the output lines up with
/// the input), and at the end it can play out its tail (reverb, echoes), at most 30 seconds.
final class PluginStage {
    let name: String
    let channels: Int
    let latency: Int
    let tail: Int
    private let unit: AUAudioUnit
    private let render: AURenderBlock
    private let maxFrames: Int
    private let input: [UnsafeMutablePointer<Float>]
    private let output: [UnsafeMutablePointer<Float>]
    private let outputList: UnsafeMutableAudioBufferListPointer
    private let clock: Clock
    private var toDrop: Int

    /// The render position, shared with the musical-context blocks the plugin may call.
    private final class Clock: @unchecked Sendable {
        var sampleTime = 0.0
    }

    init(effect: PluginEffect, sampleRate: Double, channels: Int) throws {
        name = effect.name
        self.channels = channels
        unit = try PluginHost.load(effect)
        let format = floatFormat(rate: sampleRate, channels: channels)
        do {
            try unit.inputBusses[0].setFormat(format)
            try unit.outputBusses[0].setFormat(format)
        } catch {
            let layout = channels == 1 ? "mono" : channels == 2 ? "stereo" : "\(channels)-channel"
            throw ConversionError.plugin("“\(effect.name)” can't process \(layout) audio at \(ConversionSettings.rateText(sampleRate)).")
        }
        unit.inputBusses[0].isEnabled = true
        unit.outputBusses[0].isEnabled = true
        unit.maximumFramesToRender = 4096
        unit.isRenderingOffline = true
        // A steady 120 BPM in 4/4, playing from the start, for plugins that follow the host's tempo.
        let clock = Clock()
        self.clock = clock
        unit.musicalContextBlock = { tempo, numerator, denominator, beat, offset, downbeat in
            let beats = clock.sampleTime / sampleRate * 2
            tempo?.pointee = 120
            numerator?.pointee = 4
            denominator?.pointee = 4
            beat?.pointee = beats
            offset?.pointee = Int((beats.rounded(.up) - beats) * sampleRate / 2)
            downbeat?.pointee = (beats / 4).rounded(.down) * 4
            return true
        }
        unit.transportStateBlock = { flags, position, _, _ in
            flags?.pointee = .moving
            position?.pointee = clock.sampleTime
            return true
        }
        do {
            try unit.allocateRenderResources()
        } catch {
            throw ConversionError.plugin("“\(effect.name)” couldn't start: \(error.localizedDescription)")
        }
        maxFrames = max(1, Int(unit.maximumFramesToRender))
        latency = max(0, Int((unit.latency * sampleRate).rounded()))
        let tailTime = unit.tailTime
        tail = tailTime.isFinite && tailTime > 0 ? Int((min(tailTime, 30) * sampleRate).rounded()) : 0
        toDrop = latency
        render = unit.renderBlock
        input = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 4096) }
        output = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 4096) }
        outputList = AudioBufferList.allocate(maximumBuffers: channels)
    }

    deinit {
        unit.deallocateRenderResources()
        input.forEach { $0.deallocate() }
        output.forEach { $0.deallocate() }
        free(outputList.unsafeMutablePointer)
    }

    /// Passes frames through; the first `latency` frames out are dropped.
    func process(_ block: [[Float]]) throws -> [[Float]] {
        var result = Array(repeating: [Float](), count: channels)
        let count = block.first?.count ?? 0
        var start = 0
        while start < count {
            let frames = min(maxFrames, count - start)
            for channel in 0..<channels {
                block[channel].withUnsafeBufferPointer { input[channel].update(from: $0.baseAddress! + start, count: frames) }
            }
            try renderChunk(frames, into: &result)
            start += frames
        }
        return result
    }

    /// Feeds silence to bring out the frames still inside the plugin, and its tail when `keepTail` is set.
    func flush(keepTail: Bool) throws -> [[Float]] {
        var result = Array(repeating: [Float](), count: channels)
        var remaining = latency + (keepTail ? tail : 0)
        while remaining > 0 {
            let frames = min(maxFrames, remaining)
            for channel in 0..<channels { input[channel].update(repeating: 0, count: frames) }
            try renderChunk(frames, into: &result)
            remaining -= frames
        }
        return result
    }

    private func renderChunk(_ frames: Int, into result: inout [[Float]]) throws {
        let bytes = UInt32(frames * MemoryLayout<Float>.size)
        for channel in 0..<channels {
            outputList[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(output[channel]))
        }
        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = clock.sampleTime
        timestamp.mFlags = .sampleTimeValid
        let input = self.input
        let status = render(&flags, &timestamp, AUAudioFrameCount(frames), 0, outputList.unsafeMutablePointer) { _, _, count, _, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            for index in 0..<min(buffers.count, input.count) {
                let size = UInt32(Int(count) * MemoryLayout<Float>.size)
                if let data = buffers[index].mData {
                    data.copyMemory(from: input[index], byteCount: Int(size))
                } else {
                    buffers[index].mData = UnsafeMutableRawPointer(input[index])
                }
                buffers[index].mDataByteSize = size
            }
            return noErr
        }
        guard status == noErr else { throw ConversionError.plugin("“\(name)” stopped with an error (\(fourCharText(status))).") }
        clock.sampleTime += Double(frames)
        let skip = min(toDrop, frames)
        toDrop -= skip
        guard skip < frames else { return }
        for channel in 0..<channels {
            // The plugin may hand back its own buffer instead of filling ours.
            let data = (outputList[channel].mData ?? UnsafeMutableRawPointer(output[channel])).assumingMemoryBound(to: Float.self)
            result[channel].append(contentsOf: UnsafeBufferPointer(start: data + skip, count: frames - skip))
        }
    }
}

/// The plugins of one conversion, in order, bypassed ones left out.
final class PluginChain {
    let stages: [PluginStage]
    let keepTails: Bool

    init(effects: [PluginEffect], sampleRate: Double, channels: Int, keepTails: Bool) throws {
        stages = try effects.filter { !$0.bypassed }.map { try PluginStage(effect: $0, sampleRate: sampleRate, channels: channels) }
        self.keepTails = keepTails
    }

    func process(_ block: [[Float]]) throws -> [[Float]] {
        try stages.reduce(block) { try $1.process($0) }
    }

    /// Everything the plugins still hold after the last block, each plugin's held frames passing through the ones
    /// after it.
    func finish() throws -> [[Float]] {
        var block = Array(repeating: [Float](), count: stages.first?.channels ?? 0)
        for stage in stages {
            let processed = try stage.process(block)
            let held = try stage.flush(keepTail: keepTails)
            block = zip(processed, held).map { $0 + $1 }
        }
        return block
    }
}
