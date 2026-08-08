import XCTest
@testable import OpenXECore

/// Spec §5.3. The generator is pure, so its output is fully testable without
/// Wine. Registry *equivalence* is proven separately by
/// scripts/verify-font-batching.sh, which needs a real prefix.
final class FontProvisioningTests: XCTestCase {

    func testBatchedImportIsTheDefault() {
        XCTAssertTrue(FontProvisioning.useBatchedImport)
    }

    func testRegFileHasTheREGEDIT4HeaderAndIsASCII() {
        let reg = FontProvisioning.regFileContents()
        XCTAssertTrue(reg.hasPrefix("REGEDIT4\r\n"),
                      "wine's regedit needs the REGEDIT4 magic on line 1")
        XCTAssertTrue(reg.allSatisfy { $0.isASCII },
                      "ASCII only — chosen so no UTF-16LE/BOM handling is needed")
        XCTAssertTrue(reg.hasSuffix("\r\n"), "trailing newline required")
    }

    /// All three keys the per-write path touches, and no others.
    func testRegFileDeclaresExactlyTheThreeExpectedKeys() {
        let keys = FontProvisioning.regFileContents()
            .split(separator: "\r\n").filter { $0.hasPrefix("[") }.map(String.init)
        XCTAssertEqual(keys, [
            #"[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\Fonts]"#,
            #"[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes]"#,
            #"[HKEY_CURRENT_USER\Software\Wine\Fonts\Replacements]"#,
        ])
    }

    /// 1 FontAwesome + 28 substitutes + 28 replacements = 57, matching the
    /// per-write path exactly.
    func testRegFileContainsAll57Values() {
        let values = FontProvisioning.regFileContents()
            .split(separator: "\r\n").filter { $0.hasPrefix("\"") }
        XCTAssertEqual(values.count, PrefixManager.fontWriteCount)
        XCTAssertEqual(values.count, 57)
    }

    /// The substitution table stays the single source of truth — the .reg file
    /// is generated from it, never hand-maintained.
    func testEverySubstitutionAppearsInBothTables() {
        let reg = FontProvisioning.regFileContents()
        for (from, to) in FontProvisioning.substitutions {
            XCTAssertTrue(reg.contains("\"\(from)\"=\"\(to)\""),
                          "missing \(from) -> \(to)")
        }
        XCTAssertTrue(reg.contains(#""FontAwesome (TrueType)"="FontAwesome.ttf""#))
    }

    /// A family name containing a quote or backslash would corrupt the file.
    /// The table has none today; this guards against a future addition.
    func testNoSubstitutionNeedsEscaping() {
        for (from, to) in FontProvisioning.substitutions {
            XCTAssertFalse(from.contains("\"") || from.contains("\\"), "unescaped: \(from)")
            XCTAssertFalse(to.contains("\"") || to.contains("\\"), "unescaped: \(to)")
        }
    }

    /// The verification script must never hand-maintain the substitution list;
    /// it reads what the app itself would write.
    func testVerificationFixturesMatchTheLiveTable() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("openxe-fontfixtures-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        try FontProvisioning.writeVerificationFixtures(to: dir)

        let subs = try String(contentsOf: dir.appendingPathComponent("substitutions.txt"),
                              encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(subs.count, FontProvisioning.substitutions.count)
        XCTAssertEqual(subs.first, "Segoe UI|Verdana")

        let reg = try String(contentsOf: dir.appendingPathComponent("fonts.reg"),
                             encoding: .utf8)
        XCTAssertEqual(reg, FontProvisioning.regFileContents())
    }
}
