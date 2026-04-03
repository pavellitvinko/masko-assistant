import Foundation

struct SmartFeatureSettings: Equatable {
    var spatialEnabled: Bool
    var behaviorEnabled: Bool
    var screenpipeEnabled: Bool
    var ollamaEnabled: Bool

    static let `default` = SmartFeatureSettings(
        spatialEnabled: false,
        behaviorEnabled: true,
        screenpipeEnabled: true,
        ollamaEnabled: true
    )

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            Constants.spatialEnabledKey: Self.default.spatialEnabled,
            Constants.behaviorEnabledKey: Self.default.behaviorEnabled,
            Constants.screenpipeEnabledKey: Self.default.screenpipeEnabled,
            Constants.ollamaEnabledKey: Self.default.ollamaEnabled
        ])
    }

    static func load(from defaults: UserDefaults = .standard) -> SmartFeatureSettings {
        SmartFeatureSettings(
            spatialEnabled: defaults.bool(forKey: Constants.spatialEnabledKey),
            behaviorEnabled: defaults.bool(forKey: Constants.behaviorEnabledKey),
            screenpipeEnabled: defaults.bool(forKey: Constants.screenpipeEnabledKey),
            ollamaEnabled: defaults.bool(forKey: Constants.ollamaEnabledKey)
        )
    }

    func persist(in defaults: UserDefaults = .standard) {
        defaults.set(spatialEnabled, forKey: Constants.spatialEnabledKey)
        defaults.set(behaviorEnabled, forKey: Constants.behaviorEnabledKey)
        defaults.set(screenpipeEnabled, forKey: Constants.screenpipeEnabledKey)
        defaults.set(ollamaEnabled, forKey: Constants.ollamaEnabledKey)
    }

    static func migrateLegacySettings(in defaults: UserDefaults = .standard) {
        let currentVersion = 1
        let storedVersion = defaults.integer(forKey: Constants.smartSettingsMigrationVersionKey)
        guard storedVersion < currentVersion else { return }

        for key in Constants.legacySmartFeatureKeys {
            defaults.removeObject(forKey: key)
        }

        defaults.set(currentVersion, forKey: Constants.smartSettingsMigrationVersionKey)
    }
}

#if DEBUG
enum BehaviorDebugSettings {
    static let commentInterestThresholdKey = "debug_comment_interest_threshold"

    static func load(from defaults: UserDefaults = .standard) -> Double? {
        guard defaults.object(forKey: commentInterestThresholdKey) != nil else { return nil }
        return defaults.double(forKey: commentInterestThresholdKey)
    }

    static func persist(_ value: Double?, in defaults: UserDefaults = .standard) {
        guard let value else {
            defaults.removeObject(forKey: commentInterestThresholdKey)
            return
        }
        defaults.set(value, forKey: commentInterestThresholdKey)
    }
}
#endif
