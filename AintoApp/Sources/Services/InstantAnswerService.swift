import Foundation
import AintoCore

enum InstantAnswerKind: String {
    case calculator
    case currency
}

struct InstantAnswer {
    let id: String
    let kind: InstantAnswerKind
    let title: String
    let subtitle: String
    let systemIcon: String
    let copyText: String?
    let input: String
    var swapQuery: String?
    var sourceURL: URL?
    var canRefresh = false
    var isPending = false
}

@MainActor
protocol InstantAnswerProvider {
    func matches(_ query: String) -> Bool
    func answer(for query: String) async -> InstantAnswer?
}

@MainActor
final class InstantAnswerService {
    private let calculator = CalculatorInstantAnswerProvider()
    private let currency = CurrencyInstantAnswerProvider()

    func pendingAnswer(for query: String) -> InstantAnswer? {
        guard currency.matches(query) else { return nil }
        return InstantAnswer(
            id: "currency-pending:\(query)",
            kind: .currency,
            title: "Fetching exchange rates…",
            subtitle: "Daily reference rates · Frankfurter",
            systemIcon: "arrow.triangle.2.circlepath",
            copyText: nil,
            input: query,
            isPending: true
        )
    }

    func answers(for query: String) async -> [InstantAnswer] {
        let providers: [any InstantAnswerProvider] = [calculator, currency]
        var answers: [InstantAnswer] = []
        for provider in providers where provider.matches(query) {
            if Task.isCancelled { return [] }
            if let answer = await provider.answer(for: query) {
                answers.append(answer)
            }
        }
        return answers
    }

    func refreshCurrencyRates() async -> Bool {
        await currency.forceRefresh()
    }
}

@MainActor
final class CalculatorInstantAnswerProvider: InstantAnswerProvider {
    func matches(_ query: String) -> Bool {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789.,+-*/^%()= \\t＋－−×＊÷／（）％，")
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        let operators = CharacterSet(charactersIn: "+-*/^%=＋－−×＊÷／％")
        return value.hasPrefix("=") || value.unicodeScalars.contains(where: operators.contains)
    }

    func answer(for query: String) async -> InstantAnswer? {
        var result = 0.0
        guard rc_calculate(query, &result), result.isFinite else { return nil }
        let formatted = Self.format(result)
        return InstantAnswer(
            id: "calculator:\(query)",
            kind: .calculator,
            title: formatted,
            subtitle: "Calculator · \(query.trimmingCharacters(in: .whitespacesAndNewlines))",
            systemIcon: "function",
            copyText: formatted,
            input: query
        )
    }

    private static func format(_ result: Double) -> String {
        if result == 0 { return "0" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 10
        formatter.maximumIntegerDigits = 100
        if let value = formatter.string(from: NSNumber(value: result)) {
            return value
        }
        return String(format: "%.10g", result)
    }
}
