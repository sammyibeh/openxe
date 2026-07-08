import XCTest
@testable import OpenXECore

final class RunnerTests: XCTestCase {

    // The wrapper's CFBundleExecutable is named after the program, not `wine`,
    // so no Dock/menu-bar surface can fall back to "wine" (spec §9.5).

    func testSanitizerKeepsSpacesAndReturnsPlainName() {
        XCTAssertEqual(Runner.sanitizedExecutableName("New World Scheduler"),
                       "New World Scheduler")
        XCTAssertEqual(Runner.sanitizedExecutableName("NW Scheduler"), "NW Scheduler")
    }

    func testSanitizerReplacesPathSeparators() {
        XCTAssertEqual(Runner.sanitizedExecutableName("Adobe/Reader"), "Adobe Reader")
        XCTAssertEqual(Runner.sanitizedExecutableName("Foo:Bar"), "Foo Bar")
    }

    func testSanitizerCollapsesAndTrimsWhitespace() {
        XCTAssertEqual(Runner.sanitizedExecutableName("  Notepad\t\tPlus  "), "Notepad Plus")
    }

    func testSanitizerNeverEmptyAndNeverWine() {
        XCTAssertEqual(Runner.sanitizedExecutableName(""), "app")
        XCTAssertEqual(Runner.sanitizedExecutableName("   "), "app")
        XCTAssertEqual(Runner.sanitizedExecutableName("///"), "app")
    }

    func testSanitizerCapsLength() {
        let long = String(repeating: "A", count: 200)
        XCTAssertEqual(Runner.sanitizedExecutableName(long).count, 60)
    }
}
