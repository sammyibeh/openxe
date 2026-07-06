import Foundation

/// PE resource-directory walker — just enough to pull the primary icon group
/// and the VS_VERSIONINFO ProductName out of an .exe. Spec §9.3.
/// Never throws into the launch path: every failure is a nil.
public enum PEResources {

    private enum ResourceType {
        static let icon: UInt32 = 3        // RT_ICON
        static let groupIcon: UInt32 = 14  // RT_GROUP_ICON
        static let version: UInt32 = 16    // RT_VERSION
    }

    // MARK: public API

    /// Rebuilds a valid .ico from the exe's first icon group, picking the best
    /// entry (largest pixel size, then highest bit depth; width byte 0 = 256).
    /// PNG-compressed and BMP/DIB entries are both carried through verbatim.
    public static func extractPrimaryIconICO(from data: Data) -> Data? {
        guard let map = PEMap(data: data) else { return nil }
        guard let groupData = map.firstResource(ofType: ResourceType.groupIcon) else { return nil }

        // GRPICONDIR: reserved u16, type u16, count u16, then 14-byte entries.
        guard groupData.count >= 6 else { return nil }
        let count = Int(u16(groupData, 4))
        guard count > 0, groupData.count >= 6 + count * 14 else { return nil }

        struct GroupEntry {
            let width: UInt8, height: UInt8, colors: UInt8
            let planes: UInt16, bitCount: UInt16
            let bytesInRes: UInt32, id: UInt16
            var effectiveWidth: Int { width == 0 ? 256 : Int(width) }
        }
        var entries: [GroupEntry] = []
        for i in 0..<count {
            let base = 6 + i * 14
            entries.append(GroupEntry(
                width: groupData[groupData.startIndex + base],
                height: groupData[groupData.startIndex + base + 1],
                colors: groupData[groupData.startIndex + base + 2],
                planes: u16(groupData, base + 4),
                bitCount: u16(groupData, base + 6),
                bytesInRes: u32(groupData, base + 8),
                id: u16(groupData, base + 12)))
        }
        let best = entries.max { a, b in
            (a.effectiveWidth, a.bitCount) < (b.effectiveWidth, b.bitCount)
        }!

        guard let payload = map.resource(ofType: ResourceType.icon, id: UInt32(best.id)) else {
            return nil
        }

        // ICONDIR + one ICONDIRENTRY + payload (offset 6 + 16 = 22).
        var ico = Data()
        ico.append(contentsOf: [0, 0, 1, 0, 1, 0])
        ico.append(best.width)
        ico.append(best.height)
        ico.append(best.colors)
        ico.append(0)
        ico.append(le16(best.planes))
        ico.append(le16(best.bitCount))
        ico.append(le32(UInt32(payload.count)))
        ico.append(le32(22))
        ico.append(payload)
        return ico
    }

    /// VS_VERSIONINFO ProductName, if the exe carries one. Pragmatic parser:
    /// locates the UTF-16LE "ProductName" key and reads the 32-bit-aligned
    /// value string that follows it.
    public static func productName(from data: Data) -> String? {
        guard let map = PEMap(data: data),
              let version = map.firstResource(ofType: ResourceType.version)
        else { return nil }

        let key = Data("ProductName".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        guard let keyRange = version.range(of: key) else { return nil }

        var i = keyRange.upperBound
        // key's UTF-16 NUL terminator
        guard i + 2 <= version.endIndex, version[i] == 0, version[i + 1] == 0 else { return nil }
        i += 2
        // padding to 32-bit alignment (relative to resource start)
        while (i - version.startIndex) % 4 != 0, i < version.endIndex { i += 1 }

        var chars: [UInt16] = []
        while i + 2 <= version.endIndex {
            let c = UInt16(version[i]) | (UInt16(version[i + 1]) << 8)
            if c == 0 { break }
            chars.append(c)
            i += 2
        }
        let name = String(decoding: chars, as: UTF16.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    public static func extractPrimaryIconICO(fromFileAt url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return extractPrimaryIconICO(from: data)
    }

    public static func productName(fromFileAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return productName(from: data)
    }
}

// MARK: - PE image map (sections + resource tree)

private struct PEMap {
    let data: Data
    let resourceBase: Int   // file offset of the resource directory
    let resourceRVA: UInt32
    private let sections: [(va: UInt32, size: UInt32, raw: UInt32)]

    init?(data: Data) {
        self.data = data
        guard data.count >= 0x40,
              data[data.startIndex] == 0x4D, data[data.startIndex + 1] == 0x5A,
              let eLfanew = try? u32Checked(data, 0x3C)
        else { return nil }
        let pe = Int(eLfanew)
        guard pe > 0, pe + 24 <= data.count,
              data[data.startIndex + pe] == 0x50, data[data.startIndex + pe + 1] == 0x45,
              data[data.startIndex + pe + 2] == 0, data[data.startIndex + pe + 3] == 0
        else { return nil }

        let numSections = Int(u16(data, pe + 6))
        let optSize = Int(u16(data, pe + 20))
        let optStart = pe + 24
        guard optStart + optSize <= data.count, optSize >= 2 else { return nil }

        let magic = u16(data, optStart)
        let pe32Plus: Bool
        switch magic {
        case 0x10B: pe32Plus = false
        case 0x20B: pe32Plus = true
        default: return nil
        }
        let numDirsOffset = optStart + (pe32Plus ? 108 : 92)
        guard let numDirs = try? u32Checked(data, numDirsOffset), numDirs > 2 else { return nil }
        let resourceDirEntry = numDirsOffset + 4 + 2 * 8
        guard let rva = try? u32Checked(data, resourceDirEntry), rva != 0 else { return nil }

        // Section table.
        var sections: [(va: UInt32, size: UInt32, raw: UInt32)] = []
        let sectionTable = optStart + optSize
        for i in 0..<numSections {
            let s = sectionTable + i * 40
            guard s + 40 <= data.count else { return nil }
            let virtualSize = u32(data, s + 8)
            let va = u32(data, s + 12)
            let rawSize = u32(data, s + 16)
            let rawPtr = u32(data, s + 20)
            sections.append((va: va, size: max(virtualSize, rawSize), raw: rawPtr))
        }
        self.sections = sections

        guard let base = Self.fileOffset(of: rva, in: sections),
              base < data.count
        else { return nil }
        self.resourceRVA = rva
        self.resourceBase = base
    }

    private static func fileOffset(of rva: UInt32, in sections: [(va: UInt32, size: UInt32, raw: UInt32)]) -> Int? {
        for s in sections where rva >= s.va && rva < s.va &+ s.size {
            return Int(s.raw &+ (rva &- s.va))
        }
        return nil
    }

    func fileOffset(of rva: UInt32) -> Int? {
        Self.fileOffset(of: rva, in: sections)
    }

    // MARK: resource tree

    /// Entries of a resource directory at `rel` (relative to resource base):
    /// [(id, childOffset, isSubdirectory)]. Named entries are skipped — icon
    /// and version resources of interest are ID-based.
    private func directoryEntries(at rel: Int) -> [(id: UInt32, child: UInt32, isDir: Bool)] {
        let dir = resourceBase + rel
        guard dir + 16 <= data.count else { return [] }
        let named = Int(u16(data, dir + 12))
        let ids = Int(u16(data, dir + 14))
        var result: [(UInt32, UInt32, Bool)] = []
        for i in named..<(named + ids) {
            let e = dir + 16 + i * 8
            guard e + 8 <= data.count else { break }
            let id = u32(data, e)
            let raw = u32(data, e + 4)
            result.append((id, raw & 0x7FFF_FFFF, raw & 0x8000_0000 != 0))
        }
        return result
    }

    private func dataEntryPayload(atRel rel: Int) -> Data? {
        let e = resourceBase + rel
        guard e + 16 <= data.count else { return nil }
        let rva = u32(data, e)
        let size = Int(u32(data, e + 4))
        guard size > 0, size < 64 << 20,
              let offset = fileOffset(of: rva),
              offset + size <= data.count
        else { return nil }
        return data.subdata(in: data.startIndex + offset..<data.startIndex + offset + size)
    }

    /// First language payload beneath a level-2 (id) directory entry.
    private func firstPayload(under entry: (id: UInt32, child: UInt32, isDir: Bool)) -> Data? {
        if !entry.isDir { return dataEntryPayload(atRel: Int(entry.child)) }
        guard let lang = directoryEntries(at: Int(entry.child)).first else { return nil }
        return firstPayload(under: lang)
    }

    /// First resource payload of the given type (first id, first language).
    func firstResource(ofType type: UInt32) -> Data? {
        guard let typeEntry = directoryEntries(at: 0).first(where: { $0.id == type && $0.isDir }),
              let idEntry = directoryEntries(at: Int(typeEntry.child)).first
        else { return nil }
        return firstPayload(under: idEntry)
    }

    /// Resource payload of a given type and id (first language).
    func resource(ofType type: UInt32, id: UInt32) -> Data? {
        guard let typeEntry = directoryEntries(at: 0).first(where: { $0.id == type && $0.isDir }),
              let idEntry = directoryEntries(at: Int(typeEntry.child)).first(where: { $0.id == id })
        else { return nil }
        return firstPayload(under: idEntry)
    }
}

// MARK: - bounded little-endian reads

private func u16(_ data: Data, _ offset: Int) -> UInt16 {
    let i = data.startIndex + offset
    guard i + 2 <= data.endIndex else { return 0 }
    return UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
}

private func u32(_ data: Data, _ offset: Int) -> UInt32 {
    let i = data.startIndex + offset
    guard i + 4 <= data.endIndex else { return 0 }
    return UInt32(data[i]) | (UInt32(data[i + 1]) << 8)
        | (UInt32(data[i + 2]) << 16) | (UInt32(data[i + 3]) << 24)
}

private struct BoundsError: Error {}
private func u32Checked(_ data: Data, _ offset: Int) throws -> UInt32 {
    guard offset >= 0, offset + 4 <= data.count else { throw BoundsError() }
    return u32(data, offset)
}

private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
