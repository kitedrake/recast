import AVFoundation
import XCTest
@testable import RecastCore

/// Audio Unit hosting, with the effects every Mac has (Apple's).
final class PluginTests: XCTestCase {
    override func setUp() { Fixtures.currentTest = self }

    private static func code(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    /// One of Apple's effects with some parameters set, saved the way the app saves them.
    private func apple(_ subtype: String, _ parameters: [AUParameterAddress: AUValue] = [:]) throws -> PluginEffect {
        var effect = try XCTUnwrap(PluginHost.installedEffects().first { $0.manufacturerCode == Self.code("appl") && $0.subtype == Self.code(subtype) })
        let unit = try PluginHost.load(effect)
        for (address, value) in parameters { unit.parameterTree?.parameter(withAddress: address)?.value = value }
        effect.state = PluginHost.state(of: unit)
        return effect
    }

    private func source(_ samples: [[Float]], in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("source.wav")
        try Fixtures.writePCM(samples, rate: 44100, bits: 32, float: true, to: url)
        return url
    }

    private func floatWAV(_ edit: (inout ConversionSettings) -> Void) -> ConversionSettings {
        Fixtures.settings(.wav) { $0.pcmDepth = .float32; edit(&$0) }
    }

    func testAppleEffectsAreListed() {
        let effects = PluginHost.installedEffects()
        XCTAssertTrue(effects.contains { $0.name == "AUDelay" && $0.manufacturer == "Apple" && $0.codes == "aufx dely appl" }, "\(effects.map(\.title))")
    }

    func testSettingsReachThePlugin() throws {
        let folder = try Fixtures.folder()
        let samples = Fixtures.signal(frames: 44100, channels: 2, rate: 44100)
        let url = try source(samples, in: folder)
        // AUSampleDelay set to 100 samples: a pure delay, so the result can be checked exactly.
        let delay = try apple("sdly", [0: 100])
        let outcome = try Fixtures.convert(url, floatWAV { $0.plugins = [delay] })
        let result = try Fixtures.read(outcome.output).samples
        XCTAssertEqual(result[0].count, samples[0].count)
        for channel in 0..<2 {
            XCTAssertTrue(result[channel].prefix(100).allSatisfy { $0 == 0 })
            XCTAssertEqual(Array(result[channel].dropFirst(100)), Array(samples[channel].dropLast(100)))
        }
    }

    func testLatencyIsTakenOut() throws {
        let folder = try Fixtures.folder()
        // A sweep, not a steady tone, so there's only one way to line it up.
        let samples = Fixtures.signal(frames: 44100, channels: 2, rate: 44100, level: 0.1)
        let url = try source(samples, in: folder)
        // AUPeakLimiter looks 2 ms ahead and says so; far below its threshold it only delays the sound.
        let limiter = try apple("lmtr")
        let outcome = try Fixtures.convert(url, floatWAV { $0.plugins = [limiter] })
        let result = try Fixtures.read(outcome.output).samples
        XCTAssertEqual(result[0].count, samples[0].count)
        let (lag, correlation) = Fixtures.alignment(samples[0], result[0])
        XCTAssertEqual(lag, 0)
        XCTAssertGreaterThan(correlation, 0.9999)
    }

    func testPluginsRunBeforeTrimming() throws {
        let folder = try Fixtures.folder()
        var samples = Fixtures.signal(frames: 44100, channels: 2, rate: 44100)
        samples[0][0] = 0.3
        let url = try source(samples, in: folder)
        // The delay's 1000 silent samples at the start are trimmed away; the end stops at the file's length.
        let delay = try apple("sdly", [0: 1000])
        let outcome = try Fixtures.convert(url, floatWAV { $0.plugins = [delay]; $0.trim = .start })
        let result = try Fixtures.read(outcome.output).samples
        XCTAssertEqual(result[0], Array(samples[0].prefix(44100 - 1000)))
    }

    func testTailsAreCutOrKept() throws {
        let folder = try Fixtures.folder()
        let samples = Fixtures.sine(frequency: 440, frames: 44100, rate: 44100, amplitude: 0.3)
        let url = try source(samples, in: folder)
        // AUDelay: a single echo a quarter second later.
        let echo = try apple("dely", [0: 50, 1: 0.25, 2: 0])
        let cut = try Fixtures.convert(url, floatWAV { $0.plugins = [echo] }, name: "cut")
        XCTAssertEqual(try Fixtures.read(cut.output).samples[0].count, 44100)

        let kept = try Fixtures.convert(url, floatWAV { $0.plugins = [echo]; $0.keepPluginTails = true }, name: "kept")
        let keptLength = try Fixtures.read(kept.output).samples[0].count
        // AUDelay reports exactly its echo time as its tail when there's no feedback.
        XCTAssertGreaterThanOrEqual(keptLength, 44100 + 11025, "the echo plays out")
        XCTAssertTrue(kept.notes.contains { $0.hasPrefix("Kept ") && $0.hasSuffix(" s of effect tails.") }, "\(kept.notes)")

        // With trimming, only the audible part of the tail stays: the echo ends a quarter second after the sound.
        let trimmed = try Fixtures.convert(url, floatWAV { $0.plugins = [echo]; $0.keepPluginTails = true; $0.trim = .end }, name: "trimmed")
        XCTAssertEqual(Double(try Fixtures.read(trimmed.output).samples[0].count), 44100 + 11025, accuracy: 300)
    }

    func testBypassedPluginsAreLeftOut() throws {
        let folder = try Fixtures.folder()
        let samples = Fixtures.signal(frames: 4410, channels: 2, rate: 44100)
        let url = try source(samples, in: folder)
        var delay = try apple("sdly", [0: 100])
        delay.bypassed = true
        var missing = PluginEffect(name: "Nothing", manufacturer: "Nobody",
                                   description: AudioComponentDescription(componentType: Self.code("aufx"), componentSubType: Self.code("zzzz"),
                                                                          componentManufacturer: Self.code("zzzz"), componentFlags: 0, componentFlagsMask: 0))
        missing.bypassed = true
        let outcome = try Fixtures.convert(url, floatWAV { $0.plugins = [delay, missing] })
        XCTAssertEqual(try Fixtures.read(outcome.output).samples, samples)
    }

    func testMissingPluginStopsTheFile() throws {
        let folder = try Fixtures.folder()
        let url = try source(Fixtures.signal(frames: 4410, channels: 2, rate: 44100), in: folder)
        let missing = PluginEffect(name: "Nothing", manufacturer: "Nobody",
                                   description: AudioComponentDescription(componentType: Self.code("aufx"), componentSubType: Self.code("zzzz"),
                                                                          componentManufacturer: Self.code("zzzz"), componentFlags: 0, componentFlagsMask: 0))
        XCTAssertThrowsError(try Fixtures.convert(url, floatWAV { $0.plugins = [missing] })) { error in
            XCTAssertEqual(error as? ConversionError, .plugin("“Nothing” by Nobody isn't installed on this Mac."))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("source-out.wav").path))
    }

    func testPluginSettingsAreStored() throws {
        let delay = try apple("dely", [1: 0.5])
        var settings = Fixtures.settings(.flac) { $0.plugins = [delay]; $0.keepPluginTails = true }
        XCTAssertEqual(ConversionSettings.decode(try JSONEncoder().encode(settings)), settings)
        // The stored state brings the parameter back.
        let unit = try PluginHost.load(delay)
        XCTAssertEqual(try XCTUnwrap(unit.parameterTree?.parameter(withAddress: 1)).value, 0.5, accuracy: 0.0001)
        // A plugin entry with only its identity still loads.
        let minimal = #"{"plugins": [{"name": "AUDelay", "type": 1635083896, "subtype": 1684368505, "manufacturerCode": 1634758764}]}"#
        settings = ConversionSettings.decode(Data(minimal.utf8))
        XCTAssertEqual(settings.plugins.first?.codes, "aufx dely appl")
        XCTAssertEqual(settings.plugins.first?.bypassed, false)
    }
}
