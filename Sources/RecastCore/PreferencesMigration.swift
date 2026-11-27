import Foundation

/// Carries settings over from an earlier bundle ID. Builds before 0.1.0's first release used `local.recast.app`,
/// whose preferences stay under that name; the first launch with the current ID copies them across.
public enum PreferencesMigration {
    /// The bundle ID local builds used before the release ID.
    public static let earlierDomain = "local.recast.app"
    static let marker = "PreferencesCarriedOverFrom"

    /// Copies every key of `oldDomain` that `defaults` doesn't have yet, once (a marker key records that it ran), and
    /// leaves the old domain as it is. Returns how many keys it copied.
    @discardableResult
    public static func carryOver(from oldDomain: String = earlierDomain, into defaults: UserDefaults = .standard) -> Int {
        guard defaults.string(forKey: marker) == nil else { return 0 }
        var copied = 0
        for (key, value) in defaults.persistentDomain(forName: oldDomain) ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        defaults.set(oldDomain, forKey: marker)
        return copied
    }
}
