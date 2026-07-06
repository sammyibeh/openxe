import Foundation

/// Classification of a candidate Windows executable. Spec §4.5.
public enum PEVerdict: Equatable, Sendable {
    case win32       // i386 PE
    case win64       // x86_64 PE
    case dotNET      // PE with a CLR header (Any CPU / managed)
    case armWindows  // ARM / ARM64 Windows PE — engine runs x86 only
    case dos16       // MZ executable with no valid PE header (16-bit DOS era)
    case notPE       // not a Windows executable at all (or unsupported machine)

    /// True when the pinned x86_64 Wine engine can run this binary.
    public var isLaunchable: Bool {
        switch self {
        case .win32, .win64, .dotNET: return true
        case .armWindows, .dos16, .notPE: return false
        }
    }

    /// Plain-language refusal/description shown to the user pre-launch.
    public var explanation: String {
        switch self {
        case .win32: return "32-bit Windows program"
        case .win64: return "64-bit Windows program"
        case .dotNET: return ".NET program"
        case .armWindows:
            return "This is a Windows-on-ARM program. OpenXE's engine runs x86 Windows programs only."
        case .dos16:
            return "This is a 16-bit DOS-era program, which OpenXE cannot run."
        case .notPE:
            return "This file is not a runnable Windows program (it may be corrupted or a different file type)."
        }
    }
}

/// Minimal PE header reader: enough to gate launches, nothing more. Spec §4.5.
public enum PEParser {

    private enum Machine {
        static let i386: UInt16 = 0x014C
        static let amd64: UInt16 = 0x8664
        static let arm: UInt16 = 0x01C0
        static let armnt: UInt16 = 0x01C4
        static let arm64: UInt16 = 0xAA64
    }

    /// Classify from an in-memory header (the first few KB of the file suffice).
    public static func classify(_ data: Data) -> PEVerdict {
        // DOS magic "MZ"
        guard data.count >= 2, data[data.startIndex] == 0x4D, data[data.startIndex + 1] == 0x5A else {
            return .notPE
        }
        // e_lfanew at 0x3C
        guard let eLfanew = readU32(data, at: 0x3C) else { return .dos16 }
        let peOffset = Int(eLfanew)
        // "PE\0\0"
        guard peOffset > 0, peOffset + 24 <= data.count,
              data[data.startIndex + peOffset] == 0x50,
              data[data.startIndex + peOffset + 1] == 0x45,
              data[data.startIndex + peOffset + 2] == 0x00,
              data[data.startIndex + peOffset + 3] == 0x00
        else { return .dos16 }

        guard let machine = readU16(data, at: peOffset + 4) else { return .dos16 }

        switch machine {
        case Machine.arm, Machine.armnt, Machine.arm64:
            return .armWindows
        case Machine.i386, Machine.amd64:
            break
        default:
            return .notPE // unknown machine type: not runnable by any supported path
        }

        // Optional header: magic decides PE32 vs PE32+, which fixes directory offsets.
        let optStart = peOffset + 24
        if let magic = readU16(data, at: optStart) {
            let pe32Plus = magic == 0x20B
            let numDirsOffset = optStart + (pe32Plus ? 108 : 92)
            if let numDirs = readU32(data, at: numDirsOffset), numDirs > 14 {
                let clrOffset = numDirsOffset + 4 + 14 * 8
                if let clrRVA = readU32(data, at: clrOffset), clrRVA != 0 {
                    return .dotNET
                }
            }
        }
        return machine == Machine.amd64 ? .win64 : .win32
    }

    /// Classify a file on disk; reads only the leading bytes.
    public static func classify(fileAt url: URL) throws -> PEVerdict {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 8192) ?? Data()
        return classify(head)
    }

    // MARK: little-endian bounded reads

    private static func readU16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        let i = data.startIndex + offset
        return UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
    }

    private static func readU32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let i = data.startIndex + offset
        return UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
    }
}
