import Foundation

/// Keeps the per-prefix wineserver from decaying into the "Can't check in
/// server_mach_port" failure (diagnosed 2026-07-20). A persistent `wineserver
/// -p` daemonises and can outlive its own `/tmp` socket: macOS periodically
/// reaps stale files under `/tmp`, and once the server's unix-domain `socket`
/// is gone the still-running server is unreachable — yet it keeps holding its
/// Mach bootstrap name, so the next launch spawns a fresh wineserver that
/// collides on check-in and aborts ("the wine server failed to run").
///
/// Two defences, both cheap and dependency-free:
///   1. Runner bounds the warm server's idle life (`wineserver -p<seconds>`) so
///      it self-terminates long before the multi-day `/tmp` reap window — the
///      orphan can no longer form in normal use.
///   2. Before each launch we sweep a server dir that has already decayed to
///      `lock`-without-`socket`: SIGTERM the orphaned server for THIS prefix and
///      remove the dir, so the launch starts from a clean slate even if an
///      orphan somehow survived.
public enum WineServerHousekeeping {

    /// Wine names a prefix's server dir `/tmp/.wine-<uid>/server-<dev>-<ino>`,
    /// where dev/ino are the WINEPREFIX directory's `st_dev`/`st_ino` in hex.
    /// Verified 2026-07-20 against a live prefix. Deriving the exact path (rather
    /// than globbing `server-*`) keeps the sweep from ever touching another
    /// prefix's — or another Wine install's — server.
    static func serverDirName(dev: UInt64, ino: UInt64) -> String {
        String(format: "server-%llx-%llx", dev, ino)
    }

    /// The socket dir for `prefix`, or nil when the prefix can't be stat'd.
    public static func serverDir(forPrefix prefix: URL, uid: uid_t = getuid()) -> URL? {
        var st = stat()
        guard stat(prefix.path, &st) == 0 else { return nil }
        let name = serverDirName(dev: UInt64(st.st_dev), ino: UInt64(st.st_ino))
        return URL(fileURLWithPath: "/tmp/.wine-\(uid)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// True when the server dir has decayed to a stale husk: it exists and still
    /// carries a `lock` marker, but its `socket` has been reaped — precisely the
    /// state that leaves a running server unreachable and breaks the next launch.
    static func isStale(serverDir: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: serverDir.path, isDirectory: &isDir), isDir.boolValue
        else { return false }
        let lock = fm.fileExists(atPath: serverDir.appendingPathComponent("lock").path)
        let socket = fm.fileExists(atPath: serverDir.appendingPathComponent("socket").path)
        return lock && !socket
    }

    /// Pre-launch sweep. If THIS prefix's server dir has gone stale, SIGTERM the
    /// orphaned wineserver(s) holding it and remove the dir, so the next launch
    /// starts a clean server. Prefix-scoped and best-effort — never throws, never
    /// blocks a launch. Returns true when it acted.
    @discardableResult
    public static func sweepStaleServer(forPrefix prefix: URL, uid: uid_t = getuid()) -> Bool {
        guard let dir = serverDir(forPrefix: prefix, uid: uid), isStale(serverDir: dir)
        else { return false }
        terminateServers(holding: dir)
        try? FileManager.default.removeItem(at: dir)
        return true
    }

    /// SIGTERM every process holding an open file under `dir` (a wineserver keeps
    /// this dir as its cwd and the `lock` open). `lsof +D` scopes the kill to
    /// exactly this prefix's server dir — no broad `pkill wineserver` that could
    /// hit an unrelated Wine install. wineserver handles SIGTERM as a clean
    /// shutdown.
    private static func terminateServers(holding dir: URL) {
        guard let out = try? Subprocess.run(
            URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-t", "+D", dir.path], timeout: 15).output
        else { return }
        for pid in out.split(whereSeparator: \.isNewline).compactMap({ pid_t($0) }) {
            kill(pid, SIGTERM)
        }
    }
}
