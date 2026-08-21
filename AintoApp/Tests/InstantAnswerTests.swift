import AppKit
import XCTest
#if canImport(AintoApp)
@testable import AintoApp
#elseif canImport(Ainto)
@testable import Ainto
#endif

@MainActor
private final class MockCurrencyRateSource: CurrencyRateSource {
    let cacheKey = "test-\(UUID().uuidString)"
    let name = "Mock Rates"
    let website = URL(string: "https://example.com/rates")!

    func fetchLatestRates() async throws -> CurrencyRateSnapshot {
        CurrencyRateSnapshot(
            fetchedAt: Date(),
            rates: [
                "USD": CurrencyRateQuote(date: "2026-08-21", rate: 1),
                "TWD": CurrencyRateQuote(date: "2026-08-21", rate: 31.5),
                "JPY": CurrencyRateQuote(date: "2026-08-21", rate: 150),
            ]
        )
    }
}

@MainActor
final class InstantAnswerTests: XCTestCase {
    func testCalculatorProviderRecognizesExpressionsButNotPlainNumbers() async {
        let provider = CalculatorInstantAnswerProvider()
        XCTAssertTrue(provider.matches("200 + 10%"))
        XCTAssertTrue(provider.matches("（100＋20）×3"))
        XCTAssertFalse(provider.matches("200"))
        XCTAssertFalse(provider.matches("Safari"))

        let answer = await provider.answer(for: "200 + 10%")
        XCTAssertEqual(answer?.title, "220")
    }

    func testCurrencyParserSupportsEnglishForms() {
        XCTAssertEqual(
            CurrencyInstantAnswerProvider.parse("200 USD to TWD"),
            CurrencyConversionQuery(amount: 200, source: "USD", target: "TWD")
        )
        XCTAssertEqual(
            CurrencyInstantAnswerProvider.parse("200 usd twd"),
            CurrencyConversionQuery(amount: 200, source: "USD", target: "TWD")
        )
        XCTAssertEqual(
            CurrencyInstantAnswerProvider.parse("100usd twd"),
            CurrencyConversionQuery(amount: 100, source: "USD", target: "TWD")
        )
        XCTAssertEqual(
            CurrencyInstantAnswerProvider.parse("usd100 twd"),
            CurrencyConversionQuery(amount: 100, source: "USD", target: "TWD")
        )
        XCTAssertEqual(
            CurrencyInstantAnswerProvider.parse("100rmb twd"),
            CurrencyConversionQuery(amount: 100, source: "CNY", target: "TWD")
        )
        XCTAssertEqual(
            CurrencyInstantAnswerProvider.parse("USD 200 in JPY"),
            CurrencyConversionQuery(amount: 200, source: "USD", target: "JPY")
        )
    }

    func testCurrencyParserSupportsChineseNamesAndSyntax() {
        XCTAssertEqual(
            CurrencyInstantAnswerProvider.parse("200美元換台幣"),
            CurrencyConversionQuery(amount: 200, source: "USD", target: "TWD")
        )
        XCTAssertEqual(
            CurrencyInstantAnswerProvider.parse("200 台幣 日圓"),
            CurrencyConversionQuery(amount: 200, source: "TWD", target: "JPY")
        )
        XCTAssertEqual(
            CurrencyInstantAnswerProvider.parse("歐元 50 轉 英鎊"),
            CurrencyConversionQuery(amount: 50, source: "EUR", target: "GBP")
        )
    }

    func testCurrencyParserRequiresBothCurrenciesAndRejectsCrypto() {
        XCTAssertNil(CurrencyInstantAnswerProvider.parse("200 USD"))
        XCTAssertNil(CurrencyInstantAnswerProvider.parse("1,2 USD TWD"))
        XCTAssertNil(CurrencyInstantAnswerProvider.parse("200 USD BTC"))
        XCTAssertNil(CurrencyInstantAnswerProvider.parse("weather Taipei"))
    }

    func testSearchViewModelPromotesInstantAnswerAboveNormalResults() async {
        let pasteboard = NSPasteboard.general
        let previousClipboard = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let previousClipboard {
                pasteboard.setString(previousClipboard, forType: .string)
            }
        }
        let viewModel = SearchViewModel()
        viewModel.query = "200 + 10%"
        viewModel.performSearch(query: viewModel.query)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(viewModel.results.first?.title, "220")
        XCTAssertEqual(viewModel.results.first?.score, 9_000)
        XCTAssertNotNil(viewModel.results.first?.alternateAction)
        viewModel.results.first?.action()
        XCTAssertEqual(pasteboard.string(forType: .string), "220")
    }

    func testCurrencyShowsPendingInstantAnswerBeforeNetworkCompletes() {
        let service = InstantAnswerService()
        let pending = service.pendingAnswer(for: "200 USD TWD")
        XCTAssertEqual(pending?.title, "Fetching exchange rates…")
        XCTAssertTrue(pending?.isPending == true)
        XCTAssertNil(service.pendingAnswer(for: "200 USD"))
    }

    func testCurrencyProviderUsesPluggableRateSource() async {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ainto-fx-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let provider = CurrencyInstantAnswerProvider(
            rateSource: MockCurrencyRateSource(),
            cacheDirectory: cacheDirectory
        )
        let answer = await provider.answer(for: "200 USD TWD")
        XCTAssertEqual(answer?.title, "6,300.00 TWD")
        XCTAssertTrue(answer?.subtitle.contains("Mock Rates") == true)
    }

    func testCurrencyFormattingAlwaysUsesTwoDecimalsAndCode() async {
        XCTAssertEqual(CurrencyInstantAnswerProvider.format(Decimal(string: "6520")!), "6,520.00")
        let provider = CurrencyInstantAnswerProvider()
        let answer = await provider.answer(for: "200 USD USD")
        XCTAssertEqual(answer?.title, "200.00 USD")
        XCTAssertEqual(answer?.copyText, "200.00 USD")
    }
}
