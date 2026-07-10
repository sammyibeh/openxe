# Installing OpenXE (for end users)

This guide is for **running** OpenXE, not building it. If you want to build from
source, see [`CONTRIBUTING.md`](CONTRIBUTING.md).

OpenXE is **ad-hoc signed** and **not notarized** (it's a free, personal-scale
open-source project — Apple notarization requires a paid Developer ID). macOS will
therefore warn you the first time you open it. That is expected; the steps below
clear the warning. **Only do this for a copy you got from a source you trust.**

---

## Requirements

- **macOS 14 (Sonoma) or newer.** Built and tested through macOS 27.
- **Apple Silicon or Intel.** On Apple Silicon you need **Rosetta 2** (the current
  Wine engine is x86_64). If it isn't installed, macOS will prompt you, or run:

  ```sh
  softwareupdate --install-rosetta --agree-to-license
  ```

- **~2 GB free disk** for the one-time engine download and Wine prefix.
- An internet connection for the first run only.

## 1. Get the app

Download `OpenXE.app` (typically as `OpenXE.zip` from the project's Releases page)
and unzip it. Move `OpenXE.app` to `/Applications` (or `~/Applications`).

## 2. Clear the Gatekeeper quarantine

Because the app isn't notarized, macOS quarantines it on download. Pick **one** of
these:

**Option A — Right-click → Open (simplest).**
In Finder, **right-click** (or Control-click) `OpenXE.app` → **Open** → in the
dialog, click **Open** again. You only do this once; afterwards it launches normally.

> On macOS 15+ / macOS 27, if the right-click dialog only offers *Move to Trash* /
> *Done* (no Open), open **System Settings → Privacy & Security**, scroll to the
> Security section, and click **Open Anyway** next to the OpenXE message. Then try
> opening the app again.

**Option B — Strip the quarantine attribute (Terminal).**
Faster if you're comfortable in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/OpenXE.app
```

Then double-click the app normally.

Either option is a **one-time** step. It removes the "unknown developer" block; it
does not disable Gatekeeper system-wide.

## 3. First run — the setup wizard

Open **OpenXE.app**. If New World Scheduler isn't installed yet, a guided setup
wizard walks you through everything:

1. **Welcome & disclaimer** — what OpenXE is (and that it's unofficial).
2. **Windows environment** — a one-time download (~1.7 GB) into
   `~/Library/Application Support/OpenXE/`. It is **checksum-verified** and
   **resumable**, so a dropped connection continues instead of restarting; a
   one-time environment setup (Wine Mono, Gecko, fonts) follows.
3. **New World Scheduler** — the wizard fetches the NWS installer from its
   official source (you can pick the version) and installs it.
4. **Done** — launch NWS right away, or finish without launching. NWS now appears
   in `/Applications/OpenXE Apps/` with its own icon, in Spotlight and Launchpad.

- The big download happens **once.** Later launches reuse the installed engine.
- You do **not** compile anything — the engine is prebuilt and just downloaded.

> Big download interrupted? It resumes on relaunch — you won't lose what already
> came down.

## 4. Run any other `.exe`

OpenXE is purpose-built for New World Scheduler, but it registers as the macOS
handler for `.exe` files: **double-click any `.exe` in Finder** and it runs
through OpenXE.

If double-clicking opens something else (another Wine app may have claimed `.exe`
files), set OpenXE as the handler **once**:

1. Right-click a `.exe` → **Get Info**.
2. Under **Open with**, choose **OpenXE**.
3. Click **Change All…** and confirm.

After a program launches successfully, OpenXE creates a small launcher for it in
**`/Applications/OpenXE Apps/`** with the program's own icon — so it shows up in
Spotlight and Launchpad like a native app.

## 5. Settings and housekeeping

Open **OpenXE.app** directly (from `/Applications`) to reach the small settings
window:

- **Engine version** — which Wine engine is active.
- **Open C: Drive** — reveals the Windows `C:` in Finder.
- **Per-App Settings…** — set a Windows version or DLL overrides for a specific app.
- **Shut Down Windows Environment** — stops the background `wineserver`.
- **Reset Environment** — deletes and rebuilds the prefix (last resort; you lose
  anything installed inside Windows).
- **Remove Generated Launchers** — removes the `OpenXE Apps` shortcuts.

The first time OpenXE brings a Windows window to the front, macOS may ask for the
**Accessibility** permission (attributed to OpenXE). Granting it lets OpenXE focus
the program's window; denying it only skips the focus — the program still runs.

## Troubleshooting

- **"OpenXE is damaged and can't be opened."** This is the quarantine block, not
  actual damage. Run the `xattr -dr com.apple.quarantine` command from step 2.
- **"You need Rosetta" / the program won't start on Apple Silicon.** Install
  Rosetta 2 (see Requirements) and try again.
- **A file with an `.exe` name won't run.** OpenXE checks the file is a real
  Windows program before launching and explains in plain language if it isn't
  (e.g. an ARM-only Windows binary, or a non-PE file that was just renamed `.exe`).
- **A program crashes.** OpenXE's error alert includes the tail of the Wine log.
  The full log lives at `~/Library/Logs/OpenXE/wine.log`. Please include the app
  name and the relevant log lines when filing a bug (see the issue template).
