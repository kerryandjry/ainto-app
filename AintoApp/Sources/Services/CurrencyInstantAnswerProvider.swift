import Foundation

struct CurrencyConversionQuery: Equatable {
    let amount: Decimal
    let source: String
    let target: String

    var swapQuery: String {
        "\(CurrencyInstantAnswerProvider.format(amount)) \(target) \(source)"
    }
}

struct CurrencyRateQuote: Codable {
    let date: String
    let rate: Double
}

struct CurrencyRateSnapshot: Codable {
    let fetchedAt: Date
    let rates: [String: CurrencyRateQuote]
}

/// Pluggable source boundary. A future real-time market provider can conform
/// without changing parsing, caching, result actions, or the launcher UI.
@MainActor
protocol CurrencyRateSource {
    var cacheKey: String { get }
    var name: String { get }
    var website: URL { get }
    func fetchLatestRates() async throws -> CurrencyRateSnapshot
}

@MainActor
final class FrankfurterCurrencyRateSource: CurrencyRateSource {
    private struct RemoteRate: Decodable {
        let date: String
        let quote: String
        let rate: Double
    }

    let cacheKey = "frankfurter"
    let name = "Frankfurter"
    let website = URL(string: "https://frankfurter.dev/")!
    private let endpoint = URL(string: "https://api.frankfurter.dev/v2/rates?base=USD")!

    func fetchLatestRates() async throws -> CurrencyRateSnapshot {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 10
        request.setValue("Ainto/1 Currency Instant Answer", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode)
        else { throw URLError(.badServerResponse) }
        let rows = try JSONDecoder().decode([RemoteRate].self, from: data)
        guard !rows.isEmpty else { throw URLError(.cannotParseResponse) }
        var rates: [String: CurrencyRateQuote] = [:]
        for row in rows {
            // Assignment safely lets the latest duplicate win if a provider
            // ever emits malformed/repeated quote rows.
            rates[row.quote.uppercased()] = CurrencyRateQuote(date: row.date, rate: row.rate)
        }
        let newestDate = rows.map(\.date).max() ?? ""
        rates["USD"] = CurrencyRateQuote(date: newestDate, rate: 1)
        return CurrencyRateSnapshot(fetchedAt: Date(), rates: rates)
    }
}

@MainActor
final class CurrencyInstantAnswerProvider: InstantAnswerProvider {
    private static let cacheLifetime: TimeInterval = 12 * 60 * 60

    private let rateSource: any CurrencyRateSource
    private let cacheDirectory: URL
    private var cache: CurrencyRateSnapshot?
    private var didLoadCache = false
    private var refreshTask: Task<CurrencyRateSnapshot, Error>?

    init(
        rateSource: any CurrencyRateSource = FrankfurterCurrencyRateSource(),
        cacheDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ainto")
    ) {
        self.rateSource = rateSource
        self.cacheDirectory = cacheDirectory
    }

    func matches(_ query: String) -> Bool {
        Self.parse(query) != nil
    }

    func answer(for query: String) async -> InstantAnswer? {
        guard let conversion = Self.parse(query) else { return nil }
        if conversion.source == conversion.target {
            return makeAnswer(
                conversion: conversion,
                converted: conversion.amount,
                rateDate: "same currency",
                isStale: false
            )
        }

        loadCacheIfNeeded()
        if let cache, let result = convert(conversion, using: cache) {
            let stale = Date().timeIntervalSince(cache.fetchedAt) >= Self.cacheLifetime
            if stale {
                Task { [weak self] in try? await self?.refreshRates() }
            }
            return makeAnswer(
                conversion: conversion,
                converted: result.amount,
                rateDate: result.date,
                isStale: stale
            )
        }

        do {
            let refreshed = try await refreshRates()
            guard let result = convert(conversion, using: refreshed) else {
                return unavailableAnswer(for: conversion, message: "Currency is not available from the rate provider")
            }
            return makeAnswer(
                conversion: conversion,
                converted: result.amount,
                rateDate: result.date,
                isStale: false
            )
        } catch {
            return unavailableAnswer(for: conversion, message: "Exchange rates are unavailable")
        }
    }

    func forceRefresh() async -> Bool {
        do {
            _ = try await refreshRates()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func refreshRates() async throws -> CurrencyRateSnapshot {
        if let refreshTask {
            return try await refreshTask.value
        }
        let source = rateSource
        let task = Task<CurrencyRateSnapshot, Error> {
            try await source.fetchLatestRates()
        }
        refreshTask = task
        defer { refreshTask = nil }
        let refreshed = try await task.value
        cache = refreshed
        save(refreshed)
        return refreshed
    }

    private func convert(
        _ query: CurrencyConversionQuery,
        using cache: CurrencyRateSnapshot
    ) -> (amount: Decimal, date: String)? {
        guard let sourceRate = cache.rates[query.source],
              let targetRate = cache.rates[query.target],
              sourceRate.rate > 0,
              targetRate.rate > 0
        else { return nil }
        let source = Decimal(sourceRate.rate)
        let target = Decimal(targetRate.rate)
        let converted = query.amount / source * target
        return (converted, min(sourceRate.date, targetRate.date))
    }

    private func makeAnswer(
        conversion: CurrencyConversionQuery,
        converted: Decimal,
        rateDate: String,
        isStale: Bool
    ) -> InstantAnswer {
        let output = "\(Self.format(converted)) \(conversion.target)"
        let input = "\(Self.format(conversion.amount)) \(conversion.source)"
        let freshness = isStale ? "Cached reference rate" : "Reference rate"
        let date = rateDate == "same currency" ? "" : " \(rateDate)"
        return InstantAnswer(
            id: "currency:\(conversion.source):\(conversion.target):\(conversion.amount)",
            kind: .currency,
            title: output,
            subtitle: "\(input) · \(freshness)\(date) · \(rateSource.name)",
            systemIcon: "arrow.left.arrow.right",
            copyText: output,
            input: input,
            swapQuery: conversion.swapQuery,
            sourceURL: rateSource.website,
            canRefresh: conversion.source != conversion.target
        )
    }

    private func unavailableAnswer(
        for conversion: CurrencyConversionQuery,
        message: String
    ) -> InstantAnswer {
        InstantAnswer(
            id: "currency-error:\(conversion.source):\(conversion.target)",
            kind: .currency,
            title: message,
            subtitle: "Check your connection or try again later",
            systemIcon: "exclamationmark.triangle",
            copyText: nil,
            input: "\(Self.format(conversion.amount)) \(conversion.source)",
            swapQuery: conversion.swapQuery,
            sourceURL: rateSource.website,
            canRefresh: true
        )
    }

    private func loadCacheIfNeeded() {
        guard !didLoadCache else { return }
        didLoadCache = true
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        cache = try? decoder.decode(CurrencyRateSnapshot.self, from: data)
    }

    private func save(_ cache: CurrencyRateSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cache) else { return }
        let directory = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private var cacheURL: URL {
        cacheDirectory.appendingPathComponent("fx-rates-\(rateSource.cacheKey).json")
    }

    static func parse(_ rawQuery: String) -> CurrencyConversionQuery? {
        guard rawQuery.count <= 256 else { return nil }
        var query = normalizeWidth(rawQuery).lowercased()
        for (name, code) in currencyAliases.sorted(by: { $0.key.count > $1.key.count }) {
            query = query.replacingOccurrences(of: name, with: " \(code.lowercased()) ")
        }
        for separator in ["→", "->", "換成", "轉成", "兌換", "換", "轉"] {
            query = query.replacingOccurrences(of: separator, with: " ")
        }
        // Accept compact amount/code forms such as `100usd` and `usd100`
        // without weakening validation of the amount or ISO currency code.
        query = query.replacingOccurrences(
            of: #"(?<=[0-9.,])(?=[a-z])|(?<=[a-z])(?=[0-9])"#,
            with: " ",
            options: .regularExpression
        )
        let ignored = Set(["to", "in", "into", "convert"])
        let tokens = query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !ignored.contains($0) }
        guard tokens.count == 3 else { return nil }

        let amountToken: String
        let sourceToken: String
        let targetToken: String
        if decimal(tokens[0]) != nil {
            amountToken = tokens[0]
            sourceToken = tokens[1]
            targetToken = tokens[2]
        } else if decimal(tokens[1]) != nil {
            sourceToken = tokens[0]
            amountToken = tokens[1]
            targetToken = tokens[2]
        } else {
            return nil
        }

        guard let amount = decimal(amountToken), amount >= 0 else { return nil }
        let source = sourceToken.uppercased()
        let target = targetToken.uppercased()
        guard supportedCurrencyCodes.contains(source),
              supportedCurrencyCodes.contains(target),
              !cryptoCodes.contains(source),
              !cryptoCodes.contains(target)
        else { return nil }
        return CurrencyConversionQuery(amount: amount, source: source, target: target)
    }

    nonisolated static func format(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .halfUp
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }

    private static func decimal(_ token: String) -> Decimal? {
        let plainPattern = #"^[0-9]+(?:\.[0-9]+)?$"#
        let groupedPattern = #"^[0-9]{1,3}(?:,[0-9]{3})+(?:\.[0-9]+)?$"#
        guard token.range(of: plainPattern, options: .regularExpression) != nil
                || token.range(of: groupedPattern, options: .regularExpression) != nil
        else { return nil }
        let normalized = token.replacingOccurrences(of: ",", with: "")
        return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func normalizeWidth(_ value: String) -> String {
        value.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? value
    }

    private static let cryptoCodes: Set<String> = ["BTC", "ETH", "USDT", "USDC", "SOL", "XRP"]

    private static let supportedCurrencyCodes: Set<String> = {
        var codes = Set(Locale.commonISOCurrencyCodes.map { $0.uppercased() })
        codes.formUnion(currencyAliases.values)
        return codes
    }()

    private static let currencyAliases: [String: String] = [
        "new taiwan dollars": "TWD", "new taiwan dollar": "TWD",
        "taiwan dollars": "TWD", "taiwan dollar": "TWD",
        "us dollars": "USD", "us dollar": "USD", "american dollars": "USD",
        "japanese yen": "JPY", "hong kong dollars": "HKD",
        "singapore dollars": "SGD", "australian dollars": "AUD",
        "canadian dollars": "CAD", "new zealand dollars": "NZD",
        "swiss francs": "CHF", "british pounds": "GBP",
        "dollars": "USD", "dollar": "USD", "euros": "EUR", "euro": "EUR",
        "yen": "JPY", "pounds": "GBP", "pound": "GBP", "yuan": "CNY",
        "won": "KRW", "rupees": "INR", "rupee": "INR", "rmb": "CNY",
        "新臺幣": "TWD", "新台幣": "TWD", "臺幣": "TWD", "台幣": "TWD",
        "美元": "USD", "美金": "USD", "日圓": "JPY", "日元": "JPY", "日幣": "JPY",
        "人民幣": "CNY", "歐元": "EUR", "英鎊": "GBP", "港幣": "HKD", "港元": "HKD",
        "韓元": "KRW", "韓圜": "KRW", "加幣": "CAD", "澳幣": "AUD",
        "紐西蘭元": "NZD", "紐幣": "NZD", "新加坡元": "SGD", "新幣": "SGD",
        "瑞士法郎": "CHF", "泰銖": "THB", "越南盾": "VND", "印度盧比": "INR"
    ]
}
