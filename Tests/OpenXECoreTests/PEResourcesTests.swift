import XCTest
@testable import OpenXECore

// MARK: - Synthetic PE builder with a .rsrc section

/// Builds a minimal PE32+ image whose resource directory contains the given
/// icon groups/icons and optional VS_VERSIONINFO block. Mirrors the real
/// on-disk structures: section table RVA mapping, IMAGE_RESOURCE_DIRECTORY
/// three-level tree (type -> id -> language), IMAGE_RESOURCE_DATA_ENTRY.
private struct ResourceFixture {
    struct IconEntry {
        let id: UInt16
        let width: UInt8   // 0 means 256
        let height: UInt8
        let bitCount: UInt16
        let payload: Data  // raw RT_ICON bytes (PNG or DIB)
    }

    var icons: [IconEntry] = []
    var groupEntries: [UInt16] = [] // icon ids in the (single) RT_GROUP_ICON, in order
    var versionInfo: Data? = nil
    var includeResourceDirectory = true

    func build() -> Data {
        let rsrcRVA: UInt32 = 0x1000
        let rsrcFileOffset = 0x400

        var rsrc = Data()
        var dataBlobs: [(offsetField: Int, payload: Data)] = []

        if includeResourceDirectory {
            // ---- plan the tree ----
            // root -> [RT_ICON(3) -> per-icon id dirs, RT_GROUP_ICON(14) -> id 1 dir, RT_VERSION(16) -> id 1 dir]
            var types: [(UInt32, [(UInt32, Data)])] = []
            if !icons.isEmpty {
                types.append((3, icons.map { (UInt32($0.id), $0.payload) }))
            }
            if !groupEntries.isEmpty {
                types.append((14, [(1, groupIconData())]))
            }
            if let versionInfo {
                types.append((16, [(1, versionInfo)]))
            }

            // ---- serialize ----
            rsrc.append(directoryHeader(idEntries: types.count))
            var typeEntryOffsets: [Int] = []
            for (typeID, _) in types {
                typeEntryOffsets.append(rsrc.count)
                rsrc.append(dirEntry(id: typeID, offset: 0, isDir: true))
            }
            var idDirFixups: [(entryOffset: Int, items: [(UInt32, Data)])] = []
            for (i, (_, items)) in types.enumerated() {
                patchEntryOffset(&rsrc, at: typeEntryOffsets[i], to: UInt32(rsrc.count), isDir: true)
                rsrc.append(directoryHeader(idEntries: items.count))
                var itemEntryOffsets: [Int] = []
                for (itemID, _) in items {
                    itemEntryOffsets.append(rsrc.count)
                    rsrc.append(dirEntry(id: itemID, offset: 0, isDir: true))
                }
                idDirFixups.append((0, []))
                // language level per item
                for (j, (_, payload)) in items.enumerated() {
                    patchEntryOffset(&rsrc, at: itemEntryOffsets[j], to: UInt32(rsrc.count), isDir: true)
                    rsrc.append(directoryHeader(idEntries: 1))
                    let langEntryOffset = rsrc.count
                    rsrc.append(dirEntry(id: 0x409, offset: 0, isDir: false))
                    patchEntryOffset(&rsrc, at: langEntryOffset, to: UInt32(rsrc.count), isDir: false)
                    // data entry: RVA + size + codepage + reserved
                    dataBlobs.append((rsrc.count, payload))
                    rsrc.append(le32(0)) // RVA patched below
                    rsrc.append(le32(UInt32(payload.count)))
                    rsrc.append(le32(0))
                    rsrc.append(le32(0))
                }
            }
            // append payloads and patch their RVAs
            for (offsetField, payload) in dataBlobs {
                let rva = rsrcRVA + UInt32(rsrc.count)
                rsrc.replaceSubrange(offsetField..<offsetField + 4, with: le32(rva))
                rsrc.append(payload)
            }
        }

        // ---- wrap in a PE32+ file ----
        var d = Data(count: 0x40)
        d[0] = 0x4D; d[1] = 0x5A
        d.replaceSubrange(0x3C..<0x40, with: le32(0x40))
        d.append(contentsOf: [0x50, 0x45, 0x00, 0x00])
        d.append(le16(0x8664))               // machine
        d.append(le16(1))                    // 1 section
        d.append(Data(count: 12))
        d.append(le16(240))                  // optional header size (PE32+)
        d.append(le16(0x0022))               // characteristics
        var opt = Data(count: 240)
        opt.replaceSubrange(0..<2, with: le16(0x20B))
        opt.replaceSubrange(108..<112, with: le32(16)) // NumberOfRvaAndSizes
        // DataDirectory[2] = resource table (each dir entry is 8 bytes, table starts at 112)
        if includeResourceDirectory {
            opt.replaceSubrange(112 + 16..<112 + 20, with: le32(rsrcRVA))
            opt.replaceSubrange(112 + 20..<112 + 24, with: le32(UInt32(rsrc.count)))
        }
        d.append(opt)
        // section header: ".rsrc"
        var sect = Data(count: 40)
        sect.replaceSubrange(0..<5, with: Data(".rsrc".utf8))
        sect.replaceSubrange(8..<12, with: le32(UInt32(rsrc.count)))   // VirtualSize
        sect.replaceSubrange(12..<16, with: le32(rsrcRVA))             // VirtualAddress
        sect.replaceSubrange(16..<20, with: le32(UInt32(rsrc.count))) // SizeOfRawData
        sect.replaceSubrange(20..<24, with: le32(UInt32(rsrcFileOffset)))
        d.append(sect)
        // pad to rsrc file offset, then the section data
        d.append(Data(count: rsrcFileOffset - d.count))
        d.append(rsrc)
        return d
    }

    private func groupIconData() -> Data {
        var g = Data()
        g.append(le16(0)); g.append(le16(1)) // reserved, type=icon
        g.append(le16(UInt16(groupEntries.count)))
        for id in groupEntries {
            guard let icon = icons.first(where: { $0.id == id }) else { continue }
            g.append(icon.width)
            g.append(icon.height)
            g.append(0); g.append(0)         // colors, reserved
            g.append(le16(1))                // planes
            g.append(le16(icon.bitCount))
            g.append(le32(UInt32(icon.payload.count)))
            g.append(le16(id))
        }
        return g
    }

    private func directoryHeader(idEntries: Int) -> Data {
        var h = Data(count: 12) // characteristics, timestamp, version
        h.append(le16(0))       // named entries
        h.append(le16(UInt16(idEntries)))
        return h
    }

    private func dirEntry(id: UInt32, offset: UInt32, isDir: Bool) -> Data {
        var e = le32(id)
        e.append(le32(isDir ? (offset | 0x8000_0000) : offset))
        return e
    }

    private func patchEntryOffset(_ data: inout Data, at entryOffset: Int, to offset: UInt32, isDir: Bool) {
        let value = isDir ? (offset | 0x8000_0000) : offset
        data.replaceSubrange(entryOffset + 4..<entryOffset + 8, with: le32(value))
    }
}

private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

private let fakePNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data("png-body".utf8)

private func fakeDIB(width: Int32, height: Int32) -> Data {
    var d = Data()
    d.append(le32(40)) // biSize
    d.append(withUnsafeBytes(of: width.littleEndian) { Data($0) })
    d.append(withUnsafeBytes(of: (height * 2).littleEndian) { Data($0) }) // doubled (XOR+AND)
    d.append(le16(1))   // planes
    d.append(le16(32))  // bitcount
    d.append(Data(count: 16 + 64)) // rest of header + pixel bytes
    return d
}

private func versionBlock(productName: String) -> Data {
    // Pragmatic VS_VERSIONINFO fragment: ... "ProductName"\0 <pad to 4> "value"\0 ...
    var d = Data(count: 6) // arbitrary prefix
    d.append(Data("ProductName".utf16LEBytes))
    d.append(contentsOf: [0, 0]) // UTF-16 NUL
    while d.count % 4 != 0 { d.append(0) }
    d.append(Data(productName.utf16LEBytes))
    d.append(contentsOf: [0, 0])
    return d
}

private extension String {
    var utf16LEBytes: [UInt8] {
        utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    }
}

// MARK: - Tests

final class PEResourcesTests: XCTestCase {

    func testExtractsPNGIconAsValidICO() throws {
        var fx = ResourceFixture()
        fx.icons = [.init(id: 1, width: 32, height: 32, bitCount: 32, payload: fakePNG)]
        fx.groupEntries = [1]
        let ico = try XCTUnwrap(PEResources.extractPrimaryIconICO(from: fx.build()))

        // ICONDIR: reserved 0, type 1, count 1
        XCTAssertEqual(Array(ico.prefix(6)), [0, 0, 1, 0, 1, 0])
        // ICONDIRENTRY at 6: width, height
        XCTAssertEqual(ico[6], 32)
        XCTAssertEqual(ico[7], 32)
        // image data offset (u32 at 18) must be 22 (6 + 16), payload follows verbatim
        let offset = ico.subdata(in: 18..<22).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(offset, 22)
        XCTAssertEqual(ico.suffix(from: 22), fakePNG)
    }

    func testExtractsDIBIconCarryingBytesThrough() throws {
        let dib = fakeDIB(width: 48, height: 48)
        var fx = ResourceFixture()
        fx.icons = [.init(id: 7, width: 48, height: 48, bitCount: 32, payload: dib)]
        fx.groupEntries = [7]
        let ico = try XCTUnwrap(PEResources.extractPrimaryIconICO(from: fx.build()))
        XCTAssertEqual(ico.suffix(from: 22), dib)
        XCTAssertEqual(ico[6], 48)
    }

    func testPicksLargestEntryFromGroupAndTreatsZeroWidthAs256() throws {
        let small = fakeDIB(width: 16, height: 16)
        var fx = ResourceFixture()
        fx.icons = [
            .init(id: 1, width: 16, height: 16, bitCount: 32, payload: small),
            .init(id: 2, width: 0, height: 0, bitCount: 32, payload: fakePNG), // 256 px
        ]
        fx.groupEntries = [1, 2]
        let ico = try XCTUnwrap(PEResources.extractPrimaryIconICO(from: fx.build()))
        XCTAssertEqual(ico.suffix(from: 22), fakePNG, "should pick the 256px (width byte 0) entry")
        XCTAssertEqual(ico[6], 0) // 0 == 256 in ICO too
    }

    func testReadsProductNameFromVersionResource() {
        var fx = ResourceFixture()
        fx.versionInfo = versionBlock(productName: "Wine Notepad")
        XCTAssertEqual(PEResources.productName(from: fx.build()), "Wine Notepad")
    }

    func testNoResourceDirectoryYieldsNil() {
        var fx = ResourceFixture()
        fx.includeResourceDirectory = false
        let data = fx.build()
        XCTAssertNil(PEResources.extractPrimaryIconICO(from: data))
        XCTAssertNil(PEResources.productName(from: data))
    }

    func testGarbageYieldsNil() {
        XCTAssertNil(PEResources.extractPrimaryIconICO(from: Data("not a pe file at all".utf8)))
        XCTAssertNil(PEResources.productName(from: Data()))
    }
}
