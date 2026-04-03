import XCTest
@testable import masko_code

final class CommentCacheTests: XCTestCase {
    func testNormalizationDeduplicatesCaseAndPunctuation() {
        let cache = CommentCache()

        cache.add("Great work!!!")

        XCTAssertFalse(cache.isOriginal("great work"))
        XCTAssertFalse(cache.isOriginal("Great, work."))
        XCTAssertTrue(cache.isOriginal("Different sentence"))
    }
}
