# Distribution — sharing OpenXE without making friends compile Wine

The goal: a friend downloads `OpenXE.app`, clears the Gatekeeper quarantine, and on
first run OpenXE **downloads a prebuilt Wine engine** — they never compile anything.
This note describes how that is wired and what is still deferred.

## The mechanism (already implemented)

`EngineManager` (in
[`Sources/OpenXECore/EngineManager.swift`](../Sources/OpenXECore/EngineManager.swift))
installs an engine from an `EngineDescriptor`:

```swift
public struct EngineDescriptor {
    let id: String            // stable dir name
    let displayName: String
    let version: String
    let url: URL              // download source — ANY URL, incl. a GitHub Release asset
    let sha256: String        // expected archive checksum
    let wineBinaryName: String// "wine" or "wine64"
}
```

On first run, `install(_:)`:

1. **Downloads** `url` (HTTP-range **resumable** — a dropped connection continues).
2. **Verifies** the SHA-256 against `sha256` (one automatic re-download on mismatch).
3. **Extracts** the tarball (`tar` auto-detects `.xz`/`.gz`), finds the `wine/`
   root, strips quarantine, and records a self-describing `descriptor.json`.

Because `url` is just data, pointing first-run at a **GitHub Release asset on this
repo** is a one-line catalog change — **no new code is required**. `EngineCatalog`
holds the known-good engines and picks the `default` installed on first run.

There is also `installLocalArchive(_:archive:)` for installing a pre-downloaded
tarball (used by the from-source build path and tests) — same checksum guarantee, no
network.

**Status: verified.** The download → verify → extract → install path exists and is
tested. The only thing not done in this session is *hosting the 1.7 GB engine asset*
(disk/bandwidth) — see "Deferred" below.

## Intended hosting: a GitHub Release asset on this repo

The plan for distributing the prebuilt engine:

1. Build the engine from source (LGPL path):
   ```sh
   scripts/build-engine.sh          # needs ~10-15 GB free working space
   ```
2. Package it into a distributable tarball and compute its checksum:
   ```sh
   make package-engine
   ```
   This runs [`scripts/package-engine.sh`](../scripts/package-engine.sh), which:
   - tars the staged `wine/` tree into `dist/<id>.tar.xz`,
   - computes the tarball's **SHA-256**,
   - prints a ready-to-paste `EngineDescriptor` (Swift) and a JSON descriptor, with
     the intended Release-asset URL filled in.
3. Create a GitHub Release on this repo and **upload the tarball as a release asset**
   (Releases can host large binaries; the git repo does not carry them).
4. Add (or update) the descriptor in `EngineCatalog` with the asset URL and the
   printed SHA-256, and set it as the `default` if it should be what friends get on
   first run. Ship an app build with that catalog.

After that, a friend's first run downloads the engine from the Release asset,
verifies the checksum, and installs it — no compilation.

## LGPL compliance for a hosted engine

If/when a prebuilt engine is hosted here, the Release must, alongside the binary,
link to the **corresponding source and build recipe**
([`scripts/build-engine.sh`](../scripts/build-engine.sh) plus the upstream source
URLs in [`THIRD-PARTY.md`](../THIRD-PARTY.md)). The engine is unmodified LGPL Wine we
own the build of; OpenXE itself stays MIT and never links or patches Wine.

## Deferred (follow-up, not done this session)

- **Publishing the ~1.7 GB engine Release asset** is intentionally **not** done here
  (disk/bandwidth). Until it is, first-run downloads the pinned upstream Gcenx build
  (the current `EngineCatalog.default`), which is already hosted and checksum-pinned.
- **Signing/notarization** of the app for distribution is out of scope by design —
  OpenXE is ad-hoc signed; end users clear the quarantine once (see
  [`INSTALL.md`](../INSTALL.md)).

## Summary

| Piece | State |
|---|---|
| Resumable, checksum-verified engine download (`EngineDescriptor` url + sha256) | Implemented & tested |
| Install from a pre-downloaded tarball (`installLocalArchive`) | Implemented & tested |
| Point first-run at a GitHub Release asset (data-only catalog change) | Supported, one-line change |
| `make package-engine` — tarball + checksum + descriptor for a built engine | Implemented (this session) |
| Reproducible engine build from LGPL source (`build-engine.sh`) | Present |
| Actually hosting the 1.7 GB engine asset | **Deferred** (follow-up) |
