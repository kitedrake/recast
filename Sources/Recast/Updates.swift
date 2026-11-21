import Combine
import Sparkle
import SwiftUI

/// In-app updates through Sparkle.
///
/// Only release builds can update: build.sh writes `SUFeedURL` and `SUPublicEDKey` into Info.plist when
/// `UPDATE_FEED_URL` and `UPDATE_PUBLIC_KEY` are set. Local builds (and omso Builder's) have neither, so
/// they never contact anything and show no update menu items.
///
/// Sparkle asks on the second launch whether to check automatically; until then nothing is sent. A check
/// downloads the app's update feed, and the request carries only the app's name and version (system
/// profiling stays off).
@MainActor
final class Updates: ObservableObject {
    /// Nil in builds without an update feed.
    static let shared: Updates? = {
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["SUFeedURL"] != nil, info["SUPublicEDKey"] != nil else { return nil }
        return Updates()
    }()

    private let controller: SPUStandardUpdaterController
    @Published private(set) var canCheck = false
    @Published private(set) var checksAutomatically = false

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheck)
        updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main).assign(to: &$checksAutomatically)
    }

    func checkNow() { controller.checkForUpdates(nil) }

    func setChecksAutomatically(_ on: Bool) { controller.updater.automaticallyChecksForUpdates = on }
}

/// "Check for Updates…" and "Check Automatically" in the app menu.
struct UpdateCommands: View {
    @ObservedObject var updates: Updates

    var body: some View {
        Button("Check for Updates…") { updates.checkNow() }
            .disabled(!updates.canCheck)
        Toggle("Check for Updates Automatically", isOn: Binding(
            get: { updates.checksAutomatically },
            set: { updates.setChecksAutomatically($0) }
        ))
    }
}
