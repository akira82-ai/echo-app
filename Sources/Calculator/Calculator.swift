import Foundation
import Expression

public enum Calculation: Equatable {
    case empty, incomplete, invalid, nonFinite, tooLong
    case result(String)
}

public enum Calculator {
    public static func evaluate(_ input: String) -> Calculation {
        guard input.count <= 1000 else { return .tooLong }
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for (from, to) in [("（", "("), ("）", ")"), ("×", "*"), ("÷", "/"), ("−", "-"), ("＝", "=")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        if text.last == "=" { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        // Limit nesting before parsing to keep live evaluation bounded.
        var depth = 0
        for char in text {
            if char == "(" { depth += 1 }
            if char == ")" { depth -= 1 }
            if depth < 0 { return .invalid }
            if depth > 32 { return .tooLong }
        }
        do {
            let value = try NumericExpression(text).evaluate()
            guard value.isFinite else { return .nonFinite }
            return .result(value == 0 ? "0" : String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), value))
        } catch {
            if depth > 0 || text.last.map({ "+-*/%,".contains($0) }) == true { return .incomplete }
            return .invalid
        }
    }
}
