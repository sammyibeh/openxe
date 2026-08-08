import Foundation
import OpenXECore

// Developer tool, not shipped. Writes the two fixtures
// scripts/verify-font-batching.sh needs — substitutions.txt and fonts.reg —
// straight from FontProvisioning, so the equivalence proof can never drift
// from the table the app actually uses.
//
//   swift run openxe-dump-fontcmds <output-directory>

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: openxe-dump-fontcmds <output-directory>\n".utf8))
    exit(2)
}

let directory = URL(fileURLWithPath: args[1], isDirectory: true)
do {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FontProvisioning.writeVerificationFixtures(to: directory)
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}

print("wrote substitutions.txt (\(FontProvisioning.substitutions.count) rows) "
      + "and fonts.reg to \(directory.path)")
