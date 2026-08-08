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
artifact is **`OpenXE.zip`** — a zipped `.app` attached to a GitHub release. There is
no `.dmg` and no installer package.

The consequence is unavoidable and universal: **macOS blocks OpenXE on first launch
for every user, on both architectures.** It blocks *before any OpenXE code runs*, so
it precedes the Rosetta gate in the user's actual experience, and it is a larger
onboarding barrier than Rosetta.

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
| Ad-hoc signature is rejected by Gatekeeper | **Verified** on macOS 27.0 / Apple Silicon |
| A quarantined ad-hoc app does not execute | **Verified** on macOS 27.0 / Apple Silicon |
| Gatekeeper / Settings on-screen strings | **Verified** by reading macOS 27's own resource tables |
| Live dialog headline + button layout | **Not verified** (needs Accessibility permission) |
| Right-click → Open still bypasses on macOS 27 | **Not verified** |
| Gatekeeper behaviour on macOS 14–26 | **Assumed**, not tested |
| Rosetta gate is a silent no-op on Intel | **Verified** by unit test (`01a7d50`) |
| Anything at all on real Intel hardware | **Never tested.** The project owns no Intel Mac. Intel support is a reasoned expectation from a native x86_64 engine and a native x86_64 app slice — it is not a tested claim |
| macOS 26.4+ deprecation dialog | **Not verified** — this machine runs macOS 27.0. Documented on Apple's stated behaviour |
| Sonoma-capable model list | **Not verified.** See §2 |
