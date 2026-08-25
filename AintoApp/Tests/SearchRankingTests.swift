import XCTest
#if canImport(AintoApp)
@testable import AintoApp
#elseif canImport(Ainto)
@testable import Ainto
#endif

final class SearchRankingTests: XCTestCase {
    func testStrongContiguousMatchBeatsFrequentWeakSubsequence() {
        let weakMatch = rankedFuzzyScore("set", "Translate to English", ranking: 100)
        let strongMatch = rankedFuzzyScore("set", "System Settings", ranking: 0)

        XCTAssertLessThan(weakMatch, strongMatch)
    }

    func testFrecencyCanReorderResultsWithinSubsequenceTier() {
        let unused = rankedFuzzyScore("set", "Snippets", ranking: 0)
        let frequent = rankedFuzzyScore("set", "Translate to English", ranking: 100)

        XCTAssertGreaterThanOrEqual(frequent, unused)
        XCTAssertLessThan(frequent, fuzzyScore("set", "System Settings"))
    }

    func testExactPrefixAndContainsTiersRemainStrict() {
        let exact = rankedFuzzyScore("set", "set", ranking: 0)
        let prefix = rankedFuzzyScore("set", "Settings", ranking: 100)
        let contains = rankedFuzzyScore("set", "System Settings", ranking: 100)
        let subsequence = rankedFuzzyScore("set", "Translate to English", ranking: 100)

        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, contains)
        XCTAssertGreaterThan(contains, subsequence)
    }
}
