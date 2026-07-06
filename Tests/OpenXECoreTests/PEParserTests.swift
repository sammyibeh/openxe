import XCTest
@testable import OpenXECore

/// Builds a minimal synthetic PE image in memory:
/// DOS header (MZ, e_lfanew=0x80) -> PE signature -> COFF header ->
/// optional header (PE32 or PE32+) with 16 data directories.
private func makePE(machine: UInt16, pe32Plus: Bool, clrRVA: UInt32 = 0) -> Data {
    var d = Data(count: 0x80) // DOS header + stub, zero-filled
    d[0] = 0x4D // 'M'
    d[1] = 0x5A // 'Z'
    d.replaceSubrange(0x3C..<0x40, with: withUnsafeBytes(of: UInt32(0x80).littleEndian) { Data($0) })

    // PE signature at 0x80
    d.append(contentsOf: [0x50, 0x45, 0x00, 0x00]) // "PE\0\0"

    // COFF header (20 bytes)
    d.append(contentsOf: withUnsafeBytes(of: machine.littleEndian) { Data($0) })
    d.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })  // NumberOfSections
    d.append(Data(count: 12)) // timestamp, symtab ptr, nsyms
    let optSize: UInt16 = pe32Plus ? 240 : 224
    d.append(contentsOf: withUnsafeBytes(of: optSize.littleEndian) { Data($0) })
    d.append(contentsOf: withUnsafeBytes(of: UInt16(0x0102).littleEndian) { Data($0) }) // Characteristics

    // Optional header
    let optStart = d.count
    var opt = Data(count: Int(optSize))
    let magic: UInt16 = pe32Plus ? 0x20B : 0x10B
    opt.replaceSubrange(0..<2, with: withUnsafeBytes(of: magic.littleEndian) { Data($0) })
    // NumberOfRvaAndSizes: offset 92 (PE32) / 108 (PE32+)
    let numDirsOffset = pe32Plus ? 108 : 92
    opt.replaceSubrange(numDirsOffset..<numDirsOffset + 4,
                        with: withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
    // Data directories begin right after NumberOfRvaAndSizes; CLR directory is index 14.
    let dirsStart = numDirsOffset + 4
    let clrOffset = dirsStart + 14 * 8
    opt.replaceSubrange(clrOffset..<clrOffset + 4,
                        with: withUnsafeBytes(of: clrRVA.littleEndian) { Data($0) })
    d.append(opt)
    _ = optStart
    return d
}

final class PEParserTests: XCTestCase {

    func testClassifiesWin32() {
        XCTAssertEqual(PEParser.classify(makePE(machine: 0x014C, pe32Plus: false)), .win32)
    }

    func testClassifiesWin64() {
        XCTAssertEqual(PEParser.classify(makePE(machine: 0x8664, pe32Plus: true)), .win64)
    }

    func testClassifiesDotNET() {
        XCTAssertEqual(PEParser.classify(makePE(machine: 0x014C, pe32Plus: false, clrRVA: 0x2000)), .dotNET)
        XCTAssertEqual(PEParser.classify(makePE(machine: 0x8664, pe32Plus: true, clrRVA: 0x2000)), .dotNET)
    }

    func testClassifiesARMWindows() {
        XCTAssertEqual(PEParser.classify(makePE(machine: 0xAA64, pe32Plus: true)), .armWindows)  // ARM64
        XCTAssertEqual(PEParser.classify(makePE(machine: 0x01C0, pe32Plus: false)), .armWindows) // ARM
        XCTAssertEqual(PEParser.classify(makePE(machine: 0x01C4, pe32Plus: false)), .armWindows) // ARMNT
    }

    func testClassifiesDOS16WhenMZButNoPESignature() {
        var d = Data(count: 0x80)
        d[0] = 0x4D; d[1] = 0x5A
        // e_lfanew points into garbage (zeros -> "MZ" at 0? offset 0 bytes are MZ.. not PE)
        d.replaceSubrange(0x3C..<0x40, with: withUnsafeBytes(of: UInt32(0x40).littleEndian) { Data($0) })
        XCTAssertEqual(PEParser.classify(d), .dos16)
    }

    func testClassifiesNotPEForGarbage() {
        XCTAssertEqual(PEParser.classify(Data([0x7F, 0x45, 0x4C, 0x46, 0x00, 0x00])), .notPE) // ELF magic
        XCTAssertEqual(PEParser.classify(Data()), .notPE)
        XCTAssertEqual(PEParser.classify(Data([0x4D])), .notPE) // truncated before magic completes
    }

    func testTruncatedAfterMZIsDOS16() {
        // Valid MZ magic but file ends before e_lfanew field exists.
        XCTAssertEqual(PEParser.classify(Data([0x4D, 0x5A, 0x90, 0x00])), .dos16)
    }

    func testTruncatedPEHeaderIsDOS16() {
        // e_lfanew points past end of file.
        var d = Data(count: 0x40)
        d[0] = 0x4D; d[1] = 0x5A
        d.replaceSubrange(0x3C..<0x40, with: withUnsafeBytes(of: UInt32(0x4000).littleEndian) { Data($0) })
        XCTAssertEqual(PEParser.classify(d), .dos16)
    }

    func testUnknownMachineIsNotPE() {
        XCTAssertEqual(PEParser.classify(makePE(machine: 0x0200, pe32Plus: false)), .notPE) // Itanium
    }

    func testVerdictExplanationsExist() {
        for v: PEVerdict in [.win32, .win64, .dotNET, .armWindows, .dos16, .notPE] {
            XCTAssertFalse(v.explanation.isEmpty)
        }
        XCTAssertTrue(PEVerdict.armWindows.explanation.contains("ARM"))
    }

    func testLaunchability() {
        XCTAssertTrue(PEVerdict.win32.isLaunchable)
        XCTAssertTrue(PEVerdict.win64.isLaunchable)
        XCTAssertTrue(PEVerdict.dotNET.isLaunchable)
        XCTAssertFalse(PEVerdict.armWindows.isLaunchable)
        XCTAssertFalse(PEVerdict.dos16.isLaunchable)
        XCTAssertFalse(PEVerdict.notPE.isLaunchable)
    }

    func testClassifyFromFileReadsHeader() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openxe-test-\(UUID().uuidString).exe")
        defer { try? FileManager.default.removeItem(at: url) }
        try makePE(machine: 0x8664, pe32Plus: true).write(to: url)
        XCTAssertEqual(try PEParser.classify(fileAt: url), .win64)
    }
}
