import AppKit
import RecastCore
import SwiftUI

/// Development aid: `RECAST_SNAPSHOT=<folder> RECAST_FILES=<a:b:c>` adds the files, saves PNGs of the main states
/// (light and dark, default and minimum size) into the folder, converts copies into `<folder>/converted` and quits.
/// `RECAST_SNAPSHOT_ONLY=<name>,<name>` takes only those shots and skips the waits for the others, so a retake
/// takes seconds. Settings are restored afterwards; originals are never touched.
enum Snapshot {
    nonisolated(unsafe) private static var only: Set<String>?

    static func runIfRequested(_ model: AppModel) {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["RECAST_SNAPSHOT"].map({ URL(fileURLWithPath: $0, isDirectory: true) }) else { return }
        let files = (environment["RECAST_FILES"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        only = environment["RECAST_SNAPSHOT_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        /// Lets the window settle before a shot, unless that shot isn't wanted.
        func settle(_ milliseconds: Int, for names: String...) async {
            guard names.contains(where: wanted) else { return }
            try? await Task.sleep(for: .milliseconds(milliseconds))
        }
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let saved = model.settings, savedInspector = model.showInspector, savedRecent = model.recentFolders
            var fresh = ConversionSettings()
            fresh.format = .mp3
            model.settings = fresh
            model.showInspector = false
            NSApp.appearance = NSAppearance(named: .aqua)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
            resize(860, 560)
            await settle(1000, for: "1-empty")
            capture(folder, "1-empty")

            model.add(files)
            try? await Task.sleep(for: .milliseconds(300))
            while model.isReading { try? await Task.sleep(for: .milliseconds(100)) }
            await settle(500, for: "2-list")
            capture(folder, "2-list")

            model.showInspector = true
            resize(1180, 760)
            await settle(800, for: "3-settings-mp3")
            capture(folder, "3-settings-mp3")
            model.settings.format = .flac
            model.settings.flacDepth = .int16
            model.settings.sampleRate = 44100
            model.settings.volume = .loudness
            model.settings.destination = .folder
            model.settings.folderPath = folder.appendingPathComponent("converted").path
            await settle(800, for: "4-settings-flac")
            capture(folder, "4-settings-flac")
            NSApp.appearance = NSAppearance(named: .darkAqua)
            await settle(600, for: "4-settings-flac-dark")
            capture(folder, "4-settings-flac-dark")
            NSApp.appearance = NSAppearance(named: .aqua)
            model.settings.format = .aac
            model.settings.aacMode = .vbr
            model.settings.volume = .peak
            await settle(600, for: "5-settings-aac")
            capture(folder, "5-settings-aac")

            // Processing: same format, cleaned up and levelled, scrolled to the Processing section.
            model.settings.keepFormat = true
            model.settings.sampleRate = nil
            model.settings.trim = .both
            model.settings.trimThreshold = -50
            model.settings.fadeInMS = 10
            model.settings.fadeOutMS = 500
            model.settings.highPass = true
            model.settings.removeDC = true
            model.settings.volume = .loudness
            model.settings.loudnessTarget = -16
            model.settings.limiter = true
            // Taller, so the Volume section with the limiter fits under Processing.
            resize(1180, 1060)
            await settle(300, for: "12-processing", "12-processing-dark")
            NotificationCenter.default.post(name: SettingsInspector.scrollRequest, object: "processing")
            await settle(800, for: "12-processing", "12-processing-dark")
            capture(folder, "12-processing")
            NSApp.appearance = NSAppearance(named: .darkAqua)
            await settle(600, for: "12-processing-dark")
            capture(folder, "12-processing-dark")
            NSApp.appearance = NSAppearance(named: .aqua)

            // Audio Units: three of Apple's effects, the reverb switched off, scrolled to their section.
            let installed = PluginHost.installedEffects()
            model.settings.plugins = ["aufx nbeq appl", "aufx dcmp appl", "aufx rvb2 appl"].compactMap { codes in
                installed.first { $0.codes == codes }
            }
            if model.settings.plugins.count == 3 { model.settings.plugins[2].bypassed = true }
            model.settings.keepPluginTails = true
            model.loadInstalledEffects()
            await settle(300, for: "13-plugins", "13-plugins-dark")
            NotificationCenter.default.post(name: SettingsInspector.scrollRequest, object: "plugins")
            await settle(800, for: "13-plugins", "13-plugins-dark")
            capture(folder, "13-plugins")
            NSApp.appearance = NSAppearance(named: .darkAqua)
            await settle(600, for: "13-plugins-dark")
            capture(folder, "13-plugins-dark")
            NSApp.appearance = NSAppearance(named: .aqua)
            // The first plugin's own window, opened as Edit… does.
            if let first = model.settings.plugins.first, wanted("14-plugin-window") {
                model.editPlugin(first)
                for _ in 0..<100 where PluginEditors.shared.window(for: first.id) == nil { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(1000))
                if let window = PluginEditors.shared.window(for: first.id) {
                    capture(folder, "14-plugin-window", window: window)
                    PluginEditors.shared.close(first.id)
                } else {
                    FileHandle.standardError.write(Data("The plugin window didn't open.\n".utf8))
                }
            }
            model.settings.plugins = []
            NotificationCenter.default.post(name: SettingsInspector.scrollRequest, object: "top")
            resize(1180, 760)

            model.showInspector = false
            await settle(600, for: "6-converting", "7-done")
            resize(860, 560)
            await settle(400, for: "6-converting", "7-done")
            var convert = ConversionSettings()
            convert.format = .mp3
            convert.destination = .folder
            convert.folderPath = folder.appendingPathComponent("converted").path
            model.settings = convert
            if ["6-converting", "7-done", "8-done-dark"].contains(where: wanted) {
                model.convert()
                try? await Task.sleep(for: .milliseconds(150))
                capture(folder, "6-converting")
                while model.isConverting { try? await Task.sleep(for: .milliseconds(100)) }
            }
            await settle(500, for: "7-done")
            capture(folder, "7-done")

            NSApp.appearance = NSAppearance(named: .darkAqua)
            await settle(600, for: "8-done-dark")
            capture(folder, "8-done-dark")
            model.showInspector = true
            resize(1180, 760)
            await settle(700, for: "9-settings-dark")
            capture(folder, "9-settings-dark")
            model.showInspector = false
            model.clear()
            await settle(500, for: "10-empty-dark")
            capture(folder, "10-empty-dark")
            NSApp.appearance = nil
            model.add(files)
            while model.isReading || model.items.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            resize(620, 420)
            await settle(700, for: "11-minimum-size")
            capture(folder, "11-minimum-size")

            model.settings = saved
            model.showInspector = savedInspector
            model.recentFolders = savedRecent
            NSApp.terminate(nil)
        }
    }

    @MainActor static func resize(_ width: CGFloat, _ height: CGFloat) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        var frame = window.frame
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: width, height: height)
        window.setFrame(frame, display: true)
    }

    static func wanted(_ name: String) -> Bool { only?.contains(name) ?? true }

    @MainActor static func capture(_ folder: URL, _ name: String, window chosen: NSWindow? = nil) {
        guard wanted(name) else { return }
        let url = folder.appendingPathComponent(name + ".png")
        guard let window = chosen ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        // The real on-screen pixels. AppKit's own rendering can't draw Liquid Glass or the list, so there is no
        // fallback: launch from a terminal that has Screen Recording permission.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", url.path]
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 || !FileManager.default.fileExists(atPath: url.path) {
            FileHandle.standardError.write(Data("Couldn't capture \(name): screencapture needs Screen Recording permission.\n".utf8))
        }
    }
}
