import Foundation

/// Keeps the per-prefix wineserver from decaying into the "Can't check in
/// server_mach_port" failure (diagnosed 2026-07-20). A persistent `wineserver
/// -p` daemonises and can outlive its own `/tmp` socket: macOS periodically
/// reaps stale files under `/tmp`, and once the server's unix-domain `socket`
/// is gone the still-running server is unreachable — yet it keeps holding its
/// Mach bootstrap name, so the next launch spawns a fresh wineserver that
/// collides on check-in and aborts ("the wine server failed to run").
///
/// Defences, all dependency-free:
///   1. Runner bounds the warm server's idle life (`wineserver -p<seconds>`) so
///      it self-terminates long before the multi-day `/tmp` reap window.
///   2. Before each launch we sweep an *unreachable* server for this prefix:
///      one that a launch can't reach (no live listening `socket`) even though a
///      wineserver process for the prefix is still alive — including an orphan
///      that holds an already-unlinked server dir, which a `/tmp`-path lookup
///      cannot see. We find it by the process's open WINEPREFIX handle instead.
///   3. On the first launch of a new build we reap *any* wineserver bound to
///      this prefix, so a leftover server from a previous build (e.g. one
///      started with the old unbounded `-p`) can't squat the Mach name — the
///      exact upgrade-transition failure observed on 2026-07-20.
public enum WineServerHousekeeping {

    // MARK: server-dir path (Wine's own naming)

    /// Wine names a prefix's server dir `/tmp/.wine-<uid>/server-<dev>-<ino>`,
    /// where dev/ino are the WINEPREFIX directory's `st_dev`/`st_ino` in hex.
    /// Verified 2026-07-20 against a live prefix.
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

    /// True when the server dir has decayed to a stale husk with no owning
    /// process: it exists and still carries a `lock` marker, but its `socket`
    /// has been reaped. Used only as a fallback to clear a process-less husk.
    static func isStale(serverDir: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: serverDir.path, isDirectory: &isDir), isDir.boolValue
        else { return false }
        let lock = fm.fileExists(atPath: serverDir.appendingPathComponent("lock").path)
        let socket = fm.fileExists(atPath: serverDir.appendingPathComponent("socket").path)
        return lock && !socket
    }

    /// True when a live listening socket exists at the prefix's server path — a
    /// reachable server binds one there. Its absence is the reachability signal:
    /// a wineserver process may be alive yet unreachable (socket reaped/unlinked).
    static func hasLiveServerSocket(forPrefix prefix: URL, uid: uid_t = getuid()) -> Bool {
        guard let dir = serverDir(forPrefix: prefix, uid: uid) else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("socket").path)
    }

    // MARK: prefix-scoped process detection (by open WINEPREFIX handle)

    /// PIDs of wineserver processes bound to `prefix` — i.e. holding the
    /// WINEPREFIX directory open. This is robust where the `/tmp` server-dir
    /// path is not: an orphan that holds an already-unlinked server dir still
    /// holds the prefix handle (that is how PID 17385 was located on 2026-07-20
    /// when the path lookup found nothing). Prefix-scoped by construction — only
    /// this prefix's wineserver holds this prefix's dir node.
    public static func wineserverPIDs(forPrefix prefix: URL) -> [pid_t] {
        guard let out = try? Subprocess.run(
            URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-F", "pc", "--", prefix.path], timeout: 15).output
        else { return [] }
        return parseLsofPIDs(out, commandPrefix: "wineserv")
    }

    /// Parse `lsof -F pc` field output, returning the PIDs whose command begins
    /// with `commandPrefix`. Pure, so the detection is unit-tested without lsof.
    /// `-F` emits one field per line: `p<pid>` opens a process record, `c<cmd>`
    /// gives its command (lsof truncates long names, so we match a prefix).
    static func parseLsofPIDs(_ output: String, commandPrefix: String) -> [pid_t] {
        var pids: [pid_t] = []
        var seen = Set<pid_t>()
        var current: pid_t?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            switch tag {
            case "p": current = pid_t(value)
            case "c":
                if let pid = current, value.hasPrefix(commandPrefix), seen.insert(pid).inserted {
                    pids.append(pid)
                }
            default: break
            }
        }
        return pids
    }

    // MARK: reaping

    /// SIGTERM the given PIDs (wineserver handles it as a clean shutdown), then
    /// SIGKILL any that survive a brief grace period.
    private static func terminate(_ pids: [pid_t]) {
        guard !pids.isEmpty else { return }
        for pid in pids { kill(pid, SIGTERM) }
        usleep(400_000) // 0.4s grace for a clean shutdown
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// Pre-launch sweep for an *unreachable* server. If a wineserver is bound to
    /// this prefix but there is no live listening socket at its server path
    /// (reaped/unlinked — the orphan a `/tmp`-path lookup misses), SIGTERM it and
    /// clear the dir. Also clears a process-less husk (lock without socket).
    /// A healthy, reachable server (live socket) is left untouched. Prefix-scoped
    /// and best-effort — never throws, never blocks a launch. Returns true when
    /// it acted.
    @discardableResult
    public static func sweepStaleServer(forPrefix prefix: URL, uid: uid_t = getuid()) -> Bool {
        let dir = serverDir(forPrefix: prefix, uid: uid)
        let socketAlive = hasLiveServerSocket(forPrefix: prefix, uid: uid)
        let bound = wineserverPIDs(forPrefix: prefix)

        // Unreachable orphan: a bound wineserver with no live socket at its path.
        if !bound.isEmpty && !socketAlive {
            terminate(bound)
            if let dir { try? FileManager.default.removeItem(at: dir) }
            return true
        }
        // Process-less husk: clear a lock-without-socket dir left by a dead server.
        if let dir, bound.isEmpty, isStale(serverDir: dir) {
            try? FileManager.default.removeItem(at: dir)
            return true
        }
        return false
    }

    /// Reap *every* wineserver bound to this prefix, regardless of health, and
    /// clear its server dir. Used by the one-time upgrade reap.
    @discardableResult
    public static func reapAllServers(forPrefix prefix: URL, uid: uid_t = getuid()) -> [pid_t] {
        let pids = wineserverPIDs(forPrefix: prefix)
        guard !pids.isEmpty else { return [] }
        terminate(pids)
        if let dir = serverDir(forPrefix: prefix, uid: uid) {
            try? FileManager.default.removeItem(at: dir)
        }
        return pids
    }

    /// One-time upgrade reap. When `buildID` differs from what the marker last
    /// recorded (a new build, or first run), reap any wineserver bound to this
    /// prefix so a server from the previous build can't squat the Mach name,
    /// then record `buildID`. Returns true when the build changed (reap fired).
    /// A no-op on every subsequent launch of the same build.
    @discardableResult
    public static func upgradeReapIfNeeded(forPrefix prefix: URL, buildID: String,
                                           markerURL: URL, uid: uid_t = getuid()) -> Bool {
        let stored = (try? String(contentsOf: markerURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard stored != buildID else { return false }
        reapAllServers(forPrefix: prefix, uid: uid)
        try? FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data(buildID.utf8).write(to: markerURL)
        return true
    }
}
