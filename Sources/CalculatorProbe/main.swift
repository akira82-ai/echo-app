import Foundation
import Calculator

func XCTAssertEqual(_ actual: Calculation, _ expected: Calculation, _ label: String = "") {
    guard actual == expected else {
        print("FAIL \(label): \(actual), expected \(expected)")
        exit(1)
    }
}

final class CalculatorTests {
    func testExpressions() {
        for (input, expected) in [("128*0.85", "108.8"), ("（128+36）÷4＝", "41"), ("2+3*4", "14"), ("0.1+0.2", "0.3"), ("sqrt(81)+pow(2,3)", "17"), ("-2*(3+4)", "-14"), ("10%3", "1")] {
            XCTAssertEqual(Calculator.evaluate(input), .result(expected), input)
        }
    }
    func testStates() {
        XCTAssertEqual(Calculator.evaluate(""), .empty)
        XCTAssertEqual(Calculator.evaluate("128*"), .incomplete)
        XCTAssertEqual(Calculator.evaluate("(2+3"), .incomplete)
        XCTAssertEqual(Calculator.evaluate("2+3)"), .invalid)
        XCTAssertEqual(Calculator.evaluate("hello"), .invalid)
        XCTAssertEqual(Calculator.evaluate("1/0"), .nonFinite)
        XCTAssertEqual(Calculator.evaluate("sqrt(-1)"), .nonFinite)
        XCTAssertEqual(Calculator.evaluate(String(repeating: "(", count: 33)), .tooLong)
    }
}
let checks = CalculatorTests()
checks.testExpressions()
checks.testStates()
print("PASS calculator expressions and error states")
