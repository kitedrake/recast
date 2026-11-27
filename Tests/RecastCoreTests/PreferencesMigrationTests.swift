import XCTest
@testable import RecastCore

/// Settings saved under the earlier bundle ID are carried over once, without overwriting anything newer.
final class PreferencesMigrationTests: XCTestCase {
    func testCopiesMissingKeysOnceAndKeepsNewerOnes() throws {
        let old = "test.recast.old.\(UUID().uuidString)"
        let new = "test.recast.new.\(UUID().uuidString)"
        let earlier = try XCTUnwrap(UserDefaults(suiteName: old))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: new))
        defer {
            earlier.removePersistentDomain(forName: old)
            defaults.removePersistentDomain(forName: new)
        }
        earlier.setPersistentDomain(["showInspector": true, "recentFolders": ["/tmp/out"], "settings": Data([1, 2, 3])],
                                    forName: old)
        defaults.set(false, forKey: "showInspector")

        XCTAssertEqual(PreferencesMigration.carryOver(from: old, into: defaults), 2)
        XCTAssertEqual(defaults.object(forKey: "showInspector") as? Bool, false)
        XCTAssertEqual(defaults.stringArray(forKey: "recentFolders"), ["/tmp/out"])
        XCTAssertEqual(defaults.data(forKey: "settings"), Data([1, 2, 3]))

        // A second launch copies nothing, even if the old copy of the app changed its settings since.
        earlier.setPersistentDomain(["recentFolders": ["/tmp/elsewhere"]], forName: old)
        defaults.removeObject(forKey: "recentFolders")
        XCTAssertEqual(PreferencesMigration.carryOver(from: old, into: defaults), 0)
        XCTAssertNil(defaults.object(forKey: "recentFolders"))
        // The earlier app's own settings stay where they were.
        XCTAssertEqual(UserDefaults(suiteName: old)?.stringArray(forKey: "recentFolders"), ["/tmp/elsewhere"])
    }

    func testNothingToCarryOverStillMarksItDone() throws {
        let new = "test.recast.new.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: new))
        defer { defaults.removePersistentDomain(forName: new) }
        XCTAssertEqual(PreferencesMigration.carryOver(from: "test.recast.none.\(UUID().uuidString)", into: defaults), 0)
        XCTAssertNotNil(defaults.string(forKey: "PreferencesCarriedOverFrom"))
    }
}
