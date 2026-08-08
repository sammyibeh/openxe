# Platform Support

**Status:** current as of 2026-08-09 · Technical reference. The plain-language
version for end users is [`INSTALL.md`](../INSTALL.md).

This note records exactly which Macs OpenXE runs on, why the boundaries sit where
they do, and — separately — which of those statements we have actually verified.
Binding scope decisions remain in
[`docs/design/specs/2026-07-06-openxe-design.md`](design/specs/2026-07-06-openxe-design.md).

---

## 1. The two independent constraints

OpenXE's support surface is the intersection of two constraints that move
independently. Conflating them is the usual source of confusion.

| | Constraint | Set by |
|---|---|---|
| **OS floor** | macOS 14 (Sonoma) or newer | `Package.swift` → `platforms: [.macOS(.v14)]`; `Resources/Info.plist` → `LSMinimumSystemVersion = 14.0` |
| **Engine architecture** | Wine engine is x86_64-only | `EngineCatalog.stock` in `Sources/OpenXECore/EngineManager.swift`; Gcenx publishes no arm64 build |

The app binary itself is **universal** — `scripts/build-app.sh` builds
`--arch arm64 --arch x86_64` and hard-fails if either slice is missing, so OpenXE
launches natively on both architectures. The x86_64-only constraint applies to the
**Wine engine**, not to OpenXE.

The consequence people get backwards: **Intel Macs run the engine natively.** They
are a first-class target, not a compatibility fallback. It is **Apple Silicon** that
needs a translation layer.

## 2. Support matrix

| Mac | macOS | OpenXE app | Wine engine | Rosetta 2 |
|---|---|---|---|---|
| Apple Silicon (M-series, A-series incl. MacBook Neo / A18 Pro) | 14 – current | arm64 slice, native | x86_64, **translated** | **Required.** Not preinstalled; OpenXE detects and offers a guided install |
| Intel | 14 – 26 (Tahoe) | x86_64 slice, native | x86_64, **native** | Not involved at all |
| Intel | 13 (Ventura) or older | **Will not launch** | — | — |
| Apple Silicon or Intel | Cannot update past macOS 13 | **Not supported** | — | — |

**macOS 26 (Tahoe) is the last macOS release supporting Intel Macs.** An Intel Mac
therefore has a supported window of macOS 14 through 26 and no further. Apple Silicon
has no upper bound today.

### Which Macs are excluded

The floor excludes any Mac that cannot run macOS 14 (Sonoma). Rather than publish a
model list, the honest test is the one the user can run on their own machine:
**Apple menu → About This Mac.** If it reads macOS 13 or lower and Software Update
offers nothing newer, that Mac is out of scope permanently.

> **Open question for verification (not published in user-facing docs).** The
> approximate cutoff is believed to be Intel Macs from roughly 2018 onward, with the
> iMac Pro as an earlier exception. **This has not been checked against Apple's
> published Sonoma compatibility list and must not be written down as fact until it
> is.** The user-facing guide deliberately relies on the "check About This Mac" test
> instead, which needs no list and cannot go stale.

## 3. Why the macOS 14 floor stays

The floor is **declared**, not derived — no source file carries an `@available`
annotation, and no API in use is known to require Sonoma specifically. It is set in
two places (`Package.swift`, `Info.plist`) and both agree.

It stays because it is the floor the project builds against, tests against, and can
support. Lowering it would extend the support claim to OS versions that are never
built for and never tested, on hardware nobody on the project has. A support claim
we cannot exercise is worse than a narrower one we can. **This is a settled decision
and not open for revisiting.**

## 4. Gatekeeper

The charter forbids notarization, so `scripts/build-app.sh` applies an **ad-hoc
signature only** (`codesign --force -s -`, verified per slice). The distributed
artifact is **`OpenXE.dmg`**, built by `scripts/package-app.sh` (`make package-app`).

The consequence is unavoidable and universal: **macOS blocks OpenXE on first launch
for every user, on both architectures.** It blocks *before any OpenXE code runs*, so
it precedes the Rosetta gate in the user's actual experience, and it is a larger
onboarding barrier than Rosetta.

### 4.1 Can an ad-hoc signed app be launched at all?

**Yes.** This was challenged directly — if ad-hoc signing made launch impossible, the
whole distribution approach would be void and `INSTALL.md` would be documenting an
impossible path. It does not. Three controlled launches of a disposable ad-hoc-signed
bundle (fresh bundle ID, therefore no prior approval on this machine), macOS 27.0:

| Signature | Quarantine state | Result |
|---|---|---|
| ad-hoc | none | **Launches** |
| ad-hoc | `0081` — downloaded, unapproved | **Blocked** |
| ad-hoc | `00c1` — approval bit `0x40` set | **Launches** |

The gate is the **quarantine approval state, not the signature class.** An ad-hoc
signature is a valid signature; it simply carries no Developer ID for Gatekeeper to
check, which is what triggers the one-time block. Approving the app clears the block
and it launches normally thereafter.

**Therefore Developer ID signing and notarization remain a *preference* — they would
remove first-launch friction — and are not a blocker.** The charter's ad-hoc-only
constraint stands.

*Caveat on the third row.* Setting bit `0x40` by hand is a faithful proxy for the
state **Open Anyway** produces, not a click-through of the button itself; the live
System Settings path could not be driven without Accessibility permission. The
inference is well-founded but is an inference.

**A confound worth recording.** Re-applying `com.apple.quarantine` to the *real*
`/Applications/OpenXE.app` on a development machine does **not** reproduce a virgin
first launch — all three states above launched. macOS had already recorded approval
for that bundle's cdhash from earlier runs. Consequently `scripts/reset-fresh.sh
--quarantine` does **not** fully re-arm Gatekeeper on a Mac that has already approved
that exact build; it restores the attribute but not the pre-approval state. Only a
changed cdhash (a rebuild) or a machine that has never approved the build gives a
true first-run. **Not fixed in this pass** — recorded so the tool is not trusted for
more than it does.

### 4.2 Why `.dmg` rather than `.zip`

The format change is **not** a Gatekeeper measure. Quarantine propagates through both
formats and an unnotarized app is blocked identically either way. Signature integrity
is not the motive either — verified on macOS 27.0 that the ad-hoc signature survives
intact through both a `ditto -c -k` archive and a plain `/usr/bin/zip` round trip, so
"damaged" reports do not originate in the archiving step.

The motive is **App Translocation.** A quarantined app launched from where it was
downloaded is executed by macOS from a randomised read-only path rather than its real
one. A `.dmg` containing the app beside an `/Applications` symlink makes dragging the
app across the obvious gesture, and a Finder move clears the quarantine flag, which
ends translocation. A `.zip` invites double-clicking the app straight out of
`~/Downloads`, which does not.

`package-app.sh` calls `build-app.sh --no-install` rather than re-implementing
assembly, so there is one definition of how the bundle is built and nothing to drift.
It uses `hdiutil` only — no third-party tooling — ad-hoc signs the image to match the
app, and verifies by mounting the image it just produced: app present and universal
(`lipo -archs`), signature intact inside the image, `/Applications` symlink resolving
to a real directory, clean detach. The **5120 KB budget stays on the app bundle** and
is enforced in `build-app.sh`; the compressed image is reported but never gated.

Current figures: **app bundle 2572 KB** (budget 5120 KB), **compressed image 1152 KB**.

### 4.3 Is OpenXE translocation-sensitive?

**No — audited, and the finding is reassuring.** Nothing in OpenXE derives a writable
or persistent location from its own bundle path.

- **`Sources/OpenXECore/Paths.swift`** roots every path OpenXE reads or writes at
  `~/Library/Application Support/OpenXE` and `~/Library/Logs/OpenXE`, resolved
  through `FileManager` domain lookups. The engine, prefix, logs, journal, generated
  app bundles and NWS download directory are all absolute and unaffected by where the
  app itself is running from.
- **Nothing writes into the app bundle.** A grep for bundle-relative writes returns
  nothing, so the read-only translocated mount cannot cause a write failure.
- The four `Bundle.main` uses are all safe:
  - `Sources/OpenXECore/Runner.swift:48` — `Bundle.main.executableURL`, used only to
    derive `currentBuildID` from the executable's **name, size and mtime**, not its
    path. Translocation preserves all three, so the warm-server upgrade reap is not
    spuriously triggered.
  - `Sources/OpenXECore/PrefixManager.swift:187` (bundled FontAwesome),
    `Sources/OpenXE/WizardWindow.swift:620` and `Sources/OpenXE/AppDelegate.swift:150`
    (fallback launcher icon) — read-only resource lookups, which resolve correctly
    under translocation.

The one place OpenXE depends on its own identity rather than an absolute path is
`Sources/OpenXECore/LauncherManager.swift:164`, where a generated launcher re-enters
OpenXE via `open -b dev.openxe.OpenXE` — a **bundle identifier**, not a hardcoded
path, so it survives the app being moved. How LaunchServices resolves that identifier
while the app is *translocated* has **not been tested**, and is not worth testing:
the install flow exists precisely to get the app out of that state. **Nothing was
changed in this pass.**

So translocation is a **user-experience** problem — an app running from a randomised
read-only path, whose approval does not stick — rather than a correctness problem in
OpenXE. The `.dmg` addresses the gesture that causes it.

**Verified on macOS 27.0 (build 26A5388g), Apple Silicon, 2026-08-09:**

- `spctl -a -t exec` rejects both `/Applications/OpenXE.app` and a throwaway app
  carrying an identical signature shape (`flags=0x2(adhoc)`, `TeamIdentifier=not set`).
- A quarantined ad-hoc-signed `.app` **does not execute**. Tested with a disposable
  bundle whose only job was to touch a sentinel file; the sentinel was never created,
  and `CoreServicesUIAgent` presented a dialog instead.
- The relevant strings, read from macOS 27's own resources rather than from memory:
  - `CoreServicesUIAgent.app/Contents/Resources/Quarantine.loctable` →
    `Q_DETAIL_CASPIAN_UNVERIFIED` = *"Apple could not verify “%@” is free of malware
    that may harm your Mac or compromise your privacy."*; buttons `Q_BUTTON_MOVE_TO_TRASH`
    = *"Move to Trash"*, `Q_BUTTON_DONE` = *"Done"*; `Q_OVERRIDE_AUTH_NAME` =
    *"Privacy & Security"*.
  - `Q_HEADLINE_CASPIAN_BAD_SIGNATURE` = *"“%@” is damaged and can’t be opened."* —
    note this headline is keyed to a **signature** problem, not to quarantine in
    general. Earlier documentation conflated the two.
  - `SecurityPrivacyExtension.appex/Contents/Resources/Localizable.loctable` →
    *"Open Anyway"*, *"Allow applications from"*, *"“%@” was blocked to protect your Mac."*

**Not verified.** The exact headline/button combination rendered by the live dialog
could not be read — that needs Accessibility permission, which was not granted for
this purpose. Whether the legacy Finder **right-click → Open** bypass still reaches a
usable *Open* button on macOS 27 is likewise unverified: the legacy strings
(`Q_HEADLINE_CASPIAN_WHITELISTED`, `Q_BUTTON_OPEN`) are still present in the resource
tables, but a string surviving in a bundle does not prove the code path is reachable
for an ad-hoc-signed app. Behaviour on macOS 14–26 is **assumed, not tested.**

Accordingly `INSTALL.md` documents **System Settings → Privacy & Security → Open
Anyway** as the primary path, because it is the one whose controls we have confirmed
exist, and treats right-click → Open only as a possible shortcut. `xattr -dr
com.apple.quarantine` is a support-channel fallback confined to troubleshooting.
Instructing a user to disable Gatekeeper system-wide is out of the question; the
per-app allow is the correct mechanism.

## 5. Rosetta 2

On Apple Silicon the x86_64 engine cannot run without Rosetta 2, which is **not
preinstalled**. `Sources/OpenXECore/RosettaGate.swift` gates first-run setup on this
before any Wine subprocess is spawned, so the user gets an explanation rather than a
raw `EBADARCH`.

- **Detection** is a direct experiment (`RosettaCheck.canRunX86_64` — run an x86_64
  binary and see), correct regardless of macOS version.
- **Remediation** tries `softwareupdate --install-rosetta` directly, then escalates to
  an explicitly authorized run raising the standard macOS password panel. Neither
  exit status is trusted; the machine is re-probed.
- Installing Rosetta requires **administrator rights**. A standard user on a managed
  Mac cannot complete it and must ask whoever administers the machine.
- The offer can be suppressed without a rebuild:
  `defaults write dev.openxe.OpenXE OpenXEOfferRosettaInstall -bool false`.

**Unverified:** the remediation path a non-admin user should follow after the
authorized install fails. `RosettaGate` classifies the failure and surfaces advice,
but no standard, tested escape route exists for a locked-down managed Mac, and none
is claimed in the user-facing documentation.

### Timeline — known future constraint

- Rosetta 2 is **fully supported through macOS 27**.
- From **macOS 28** (expected autumn 2027) it is **reduced to a subset** intended for
  unmaintained Intel-framework games. This is a reduction in scope, not a clean
  removal — earlier OpenXE documentation described it as outright "retirement", which
  overstated it.
- From **macOS 26.4** onward, Apple shows its own *"Rosetta is being discontinued"*
  dialog on every translated-app launch. It is cosmetic and does not indicate an
  OpenXE fault, but it is alarming enough that `INSTALL.md` warns about it explicitly.

**OpenXE makes no promise about how it will handle macOS 28.** That is undecided. The
only thing designed for it is optionality: the engine directory is versioned and
swappable behind the `engine/current` contract (design spec §4.1), so an arm64-native
Wine build drops in without touching the other components. No arm64 engine is pinned
or verified today. Note that this constraint does **not** affect Intel Macs, which
never involve Rosetta — but Intel Macs stop receiving macOS at 26 regardless.

## 6. Verification status

Stated plainly, because most of the matrix above is reasoning rather than testing.

| Claim | Status |
|---|---|
| App binary is universal (`arm64` + `x86_64`), both slices signed | **Verified** — enforced by `scripts/build-app.sh`, hard-fails otherwise |
| Ad-hoc signature is rejected by Gatekeeper assessment (`spctl`) | **Verified** on macOS 27.0 / Apple Silicon |
| A quarantined, unapproved ad-hoc app does not execute | **Verified** on macOS 27.0 / Apple Silicon |
| An ad-hoc app **launches once approved** — ad-hoc signing is not a blocker | **Verified** on macOS 27.0 (§4.1) |
| Open Anyway specifically produces that approved state | **Inferred**, not clicked through (§4.1) |
| Ad-hoc signature survives `ditto` and plain `zip` round trips | **Verified** — "damaged" does not originate in archiving |
| `.dmg` builds, mounts, is universal inside, symlink resolves, detaches | **Verified** — enforced by `scripts/package-app.sh` on every run |
| OpenXE is not translocation-sensitive | **Verified by audit** (§4.3), not by running translocated |
| `reset-fresh.sh --quarantine` fully re-arms Gatekeeper | **False.** Does not defeat existing cdhash approval (§4.1) |
| Gatekeeper / Settings on-screen strings | **Verified** by reading macOS 27's own resource tables |
| Live dialog headline + button layout | **Not verified** (needs Accessibility permission) |
| Right-click → Open still bypasses on macOS 27 | **Not verified** |
| Gatekeeper behaviour on macOS 14–26 | **Assumed**, not tested |
| Rosetta gate is a silent no-op on Intel | **Verified** by unit test (`01a7d50`) |
| Anything at all on real Intel hardware | **Never tested.** The project owns no Intel Mac. Intel support is a reasoned expectation from a native x86_64 engine and a native x86_64 app slice — it is not a tested claim |
| macOS 26.4+ deprecation dialog | **Not verified** — this machine runs macOS 27.0. Documented on Apple's stated behaviour |
| Sonoma-capable model list | **Not verified.** See §2 |
