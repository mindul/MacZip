import Foundation

/// XCTest/Swift Testing이 없는 환경용 최소 검사 러너.
enum Harness {
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var currentSuite = ""

    /// `--`로 시작하는 인자(예: `--big`).
    static let flags: Set<String> = Set(CommandLine.arguments.dropFirst().filter { $0.hasPrefix("--") })
    /// `--`로 시작하지 않는 인자: suite 이름 필터.
    static let filters: [String] = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }

    static func suite(_ name: String, _ body: () throws -> Void) {
        guard filters.isEmpty || filters.contains(where: { name.contains($0) }) else { return }
        currentSuite = name
        print("▶︎ \(name)")
        do {
            try body()
        } catch {
            checks += 1
            failures += 1
            print("  ✗ [\(name)] 예상치 못한 오류: \(error)")
        }
    }

    static func expect(_ cond: Bool, _ message: @autoclosure () -> String,
                       file: StaticString = #fileID, line: UInt = #line) {
        checks += 1
        if !cond {
            failures += 1
            print("  ✗ \(file):\(line) [\(currentSuite)] \(message())")
        }
    }

    static func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: @autoclosure () -> String = "",
                                          file: StaticString = #fileID, line: UInt = #line) {
        expect(a == b, "\(message()) — 기대값 불일치: \(a) != \(b)", file: file, line: line)
    }

    static func expectThrows(_ body: () throws -> Void, matching: (Error) -> Bool,
                             _ message: @autoclosure () -> String = "",
                             file: StaticString = #fileID, line: UInt = #line) {
        do {
            try body()
            expect(false, "\(message()) — 오류가 던져지지 않음", file: file, line: line)
        } catch {
            expect(matching(error), "\(message()) — 다른 오류: \(error)", file: file, line: line)
        }
    }

    static func finish() -> Never {
        if failures > 0 {
            print("FAILED (\(failures) of \(checks) checks)")
            exit(1)
        }
        print("ALL PASSED (\(checks) checks)")
        exit(0)
    }
}
