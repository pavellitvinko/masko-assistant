import XCTest
@testable import masko_code

final class SmartFeatureSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "SmartFeatureSettingsTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testRegisterDefaultsUsesOnlyRetainedSmartFeatureKeys() {
        SmartFeatureSettings.registerDefaults(in: defaults)

        XCTAssertEqual(defaults.object(forKey: Constants.spatialEnabledKey) as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: Constants.behaviorEnabledKey) as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: Constants.screenpipeEnabledKey) as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: Constants.ollamaEnabledKey) as? Bool, true)

        for key in Constants.legacySmartFeatureKeys {
            XCTAssertNil(defaults.object(forKey: key), "Unexpected default for legacy key \(key)")
        }
    }

    func testMigrateLegacySettingsRemovesRemovedKeys() {
        defaults.set(0.0, forKey: "comment_interest_threshold")
        defaults.set(false, forKey: "comment_require_interest_threshold")

        SmartFeatureSettings.migrateLegacySettings(in: defaults)

        XCTAssertNil(defaults.object(forKey: "comment_interest_threshold"))
        XCTAssertNil(defaults.object(forKey: "comment_require_interest_threshold"))
        XCTAssertEqual(defaults.integer(forKey: Constants.smartSettingsMigrationVersionKey), 1)
    }

    func testPersistRoundTripsRetainedSettings() {
        let settings = SmartFeatureSettings(
            spatialEnabled: true,
            behaviorEnabled: false,
            screenpipeEnabled: false,
            ollamaEnabled: true
        )

        settings.persist(in: defaults)

        XCTAssertEqual(SmartFeatureSettings.load(from: defaults), settings)
    }
}
