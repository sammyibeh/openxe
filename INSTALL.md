# Installing OpenXE

This guide is for **using** OpenXE. If you want to build it from source, see
[`CONTRIBUTING.md`](CONTRIBUTING.md) instead.

Setting up takes about ten minutes, most of it waiting for a download. Two of the
steps are macOS security prompts that look alarming and are not. Both are explained
below, in the order you will actually meet them.

---

## Will OpenXE run on your Mac?

**One check answers it.** Click the **Apple menu** (top-left of your screen) →
**About This Mac**. Look at the macOS version number.

| What you see | Can you use OpenXE? |
|---|---|
| **macOS 14 (Sonoma) or higher** | **Yes.** |
| **macOS 13 or lower**, and Software Update offers a newer version | Update macOS first, then yes. |
| **macOS 13 or lower**, and your Mac cannot update any further | **No — and this will not change.** Your Mac is too old for OpenXE. |

There is no workaround for the last row. If your Mac cannot be updated to macOS 14,
OpenXE will not start on it, and no future version will change that. Macs from
roughly 2015–2017 are commonly in this position. Nothing is wrong with your Mac —
it simply stopped receiving the macOS versions OpenXE is built for.

The same **About This Mac** screen tells you which kind of Mac you have:

- If it mentions a **chip** with a name like **M1, M2, M3, M4** (or similar), you have
  an **Apple silicon** Mac. There is one extra one-time step for you — see step 3.
- If it mentions an **Intel** processor, you have an **Intel** Mac. Step 3 does not
  apply to you; everything OpenXE needs is already there. Note that macOS 26 (Tahoe)
  is the last version of macOS for Intel Macs, so that is as far as yours will go.

### You will also need

- **About 2 GB of free disk space** for the one-time download and the Windows
  environment it sets up.
- **An internet connection**, for the first run only.
- **The password you use to log in to your Mac.** macOS asks for it once or twice
  during setup. If you use a Mac that someone else manages — a work or school
  computer — and you do not have that password, read
  [If you cannot enter an administrator password](#if-you-cannot-enter-an-administrator-password)
  before you start.

---

## Step 1 — Download OpenXE and put it in Applications

1. From the project's **Releases** page, download **`OpenXE.dmg`**. It lands in your
   **Downloads** folder.
2. **Double-click `OpenXE.dmg`.** A window opens showing the **OpenXE** app on one
   side and a shortcut to your **Applications** folder on the other.
3. **Drag OpenXE onto the Applications shortcut.** That copies it into place.
4. **Close the window and eject the disk image** — click the eject symbol next to
   **OpenXE** in the Finder sidebar, or drag it to the Trash. You can delete the
   downloaded `.dmg` afterwards; you do not need it again.
5. From now on, **open OpenXE from your Applications folder**, not from Downloads.

> **Do not skip the drag.** Opening the app directly from inside the disk image, or
> from your Downloads folder, makes macOS run it from a temporary read-only location.
> It behaves oddly there and the approval in the next step will not stick. Copying it
> to Applications first avoids that entirely — which is the whole reason the download
> is shaped this way.

## Step 2 — Let macOS open it the first time

**This is the step that stops most people, so read it before you start.**

The first time you open OpenXE, **macOS will refuse and show a warning.** You have
not done anything wrong and the app is not broken.

**Why it happens.** Apple offers a paid service that reviews apps before release, and
apps that go through it open without any warning. OpenXE is a free project and does
not pay for it, so macOS has no Apple stamp to check and refuses to open it until you
say it is all right. macOS gives you a way to approve **this one app**, which is what
the steps below do. You are not turning off any security setting, and everything else
on your Mac stays protected exactly as before.

**Do this:**

1. Open your **Applications** folder and **double-click OpenXE**.
2. A warning appears saying macOS could not verify the app is free of malware. It
   offers only **Move to Trash** or **Done**. **Click Done.** Do not click Move to
   Trash.
3. Open the **Apple menu** → **System Settings**.
4. In the sidebar, click **Privacy & Security**, then scroll down to the **Security**
   section near the bottom.
5. You will see a line saying **OpenXE** was blocked, with an **Open Anyway** button
   beside it. **Click Open Anyway.**
6. macOS asks for your **login password** (or Touch ID) and shows a strongly worded
   message about opening an app that may harm your Mac. This is the standard wording
   macOS uses for every app it has not verified. **Enter your password to confirm.**
7. One final dialog asks whether you are sure. **Confirm it**, and OpenXE opens.

**That is a one-time step.** From then on OpenXE opens by double-clicking it like any
other app.

> **A note on timing.** The **Open Anyway** button in step 5 only appears *after* you
> have tried to open the app and been blocked. If you cannot find it in System
> Settings, go back and double-click OpenXE first, then look again.

> **Some versions of macOS offer a shortcut.** Right-clicking (or Control-clicking)
> the app and choosing **Open** sometimes gets you a dialog with an **Open** button,
> which skips the System Settings trip. It is worth ten seconds, but recent versions
> of macOS have been removing this shortcut, so if the menu gives you nothing useful,
> use the System Settings route above — that one works.

### If you cannot enter an administrator password

Approving a blocked app requires an administrator account. On a Mac managed by an
employer, a school, or a family organiser, you may not have one.

**You cannot work around this yourself, and you should not try.** Ask whoever
administers the Mac to approve OpenXE for you — the steps they need are steps 3–7
above, and it takes them under a minute. If they decline, OpenXE cannot be installed
on that Mac. That is a legitimate answer and not a fault you can fix.

*We have not been able to test this situation ourselves, so we cannot promise how a
particular managed Mac will behave — some are locked down further than others.*

## Step 3 — Apple silicon only: the one-time compatibility step

**Skip this step if you have an Intel Mac.** Everything you need is already
installed, and nothing extra will be asked of you.

**If you have an Apple silicon Mac** (M1, M2, M3, M4, or similar), OpenXE needs one
extra piece from Apple, called **Rosetta**. It lets your Mac run software built for
the older kind of Mac processor, and the Windows engine OpenXE uses is built that
way. Rosetta comes from Apple, not from us, and it is not installed by default.

**You do not need to do anything in advance.** OpenXE checks for Rosetta before it
starts any real work, and if it is missing it explains the situation and offers to
install it for you. Accept the offer, enter your **login password** when macOS asks,
and wait — it usually takes a minute or two. OpenXE checks again afterwards and tells
you plainly if it did not work, rather than failing later with something cryptic.

This also needs an administrator password. If you do not have one, the same advice
applies as above: ask whoever administers the Mac. *We have not been able to test
this on a managed Mac, so we cannot tell you in advance exactly what such a Mac will
allow.*

### About Apple's "Rosetta is being discontinued" message

On **macOS 26.4 and later**, Apple shows its own message saying **Rosetta is being
discontinued**, and it may appear **every time** you launch a Windows program through
OpenXE.

**This message is from Apple, not from OpenXE, and nothing is wrong.** It is a
notice about Apple's own future plans. Your program will open normally. You can
dismiss it and carry on.

For what this means further out, see
[What happens to Rosetta later](#what-happens-to-rosetta-later).

## Step 4 — The setup wizard

With OpenXE open, a guided wizard walks you through the rest:

1. **Welcome** — what OpenXE is, and that it is an unofficial, independent project.
2. **Windows environment** — a one-time download of about 1.7 GB. It checks itself
   for corruption and **resumes** if your connection drops, so you never lose what
   already came down. A short setup step follows.
3. **New World Scheduler** — the wizard downloads it from its official source (you can
   choose the version) and installs it.
4. **Done** — launch New World Scheduler straight away, or finish without launching.

The big download happens **once**. Later launches reuse what is already there and are
much faster. Nothing is compiled on your Mac; it is simply downloaded.

After setup, New World Scheduler appears in **`Applications/OpenXE Apps/`** with its
own icon, and in Spotlight and Launchpad, like any other app.

---

## Running other Windows programs

OpenXE is built and tuned for New World Scheduler, but it also registers itself to
handle Windows program files, so **double-clicking a `.exe` file in Finder** runs it
through OpenXE.

If double-clicking opens something else, set OpenXE as the handler once:

1. Right-click the `.exe` file → **Get Info**.
2. Under **Open with**, choose **OpenXE**.
3. Click **Change All…** and confirm.

Once a program has launched successfully, OpenXE creates a shortcut for it in
**`Applications/OpenXE Apps/`** with the program's own icon.

## Settings and housekeeping

Open **OpenXE** from Applications to reach its small settings window:

- **Engine version** — which Windows engine is in use.
- **Open C: Drive** — shows the Windows side in Finder.
- **Per-App Settings…** — adjust the Windows version or compatibility options for one
  program.
- **Shut Down Windows Environment** — stops the background helper.
- **Reset Environment** — rebuilds the Windows environment from scratch. Last resort:
  you lose anything installed inside it.
- **Remove Generated Launchers** — removes the shortcuts in `OpenXE Apps`.

The first time OpenXE brings a Windows window to the front, macOS may ask for
**Accessibility** permission. Granting it lets OpenXE bring the program's window
forward; declining only means you may have to click the window yourself.

## What happens to Rosetta later

Only relevant on Apple silicon Macs; Intel Macs never use Rosetta.

Apple supports Rosetta fully **through macOS 27**. From **macOS 28**, expected around
autumn 2027, Apple is cutting it back to a narrow set of cases. What that means for
OpenXE is **not yet decided**, and we would rather say so than make a promise we
cannot keep. OpenXE was built so that its Windows engine can be swapped for a
different one without rebuilding the app, which is the groundwork for dealing with
it — but no replacement engine exists yet.

Nothing changes before then, and nothing you install today stops working because of
it.

---

## Troubleshooting

**"Apple could not verify OpenXE is free of malware."**
This is the expected first-launch block. Follow [Step 2](#step-2--let-macos-open-it-the-first-time).
Click **Done**, never **Move to Trash**.

**"OpenXE is damaged and can't be opened."**
Different message, different cause: this one points at a damaged copy of the app
rather than the ordinary block. Delete the copy in Applications, download
`OpenXE.dmg` again, and repeat [Step 1](#step-1--download-openxe-and-put-it-in-applications).
If it persists, see the fallback below.

**Fallback for a stubborn security block.**
Only if the steps above genuinely did not work. In the **Terminal** app, paste this
line exactly and press Return:

```sh
xattr -dr com.apple.quarantine /Applications/OpenXE.app
```

Then open the app normally. This clears the download marker on **this one app** and
changes no system-wide setting. Never disable Gatekeeper or your Mac's security
settings to run OpenXE — you do not need to, and you should not be asked to.

**A Windows program will not start on an Apple silicon Mac.**
Rosetta is probably missing or was not installed. Reopen OpenXE and let it check
again — see [Step 3](#step-3--apple-silicon-only-the-one-time-compatibility-step).

**A file ending in `.exe` refuses to run.**
OpenXE checks that a file really is a Windows program before launching it, and
explains in plain language when it is not — for example a file that was merely
renamed `.exe`, or a Windows program built for a processor the engine does not run.

**A program crashes.**
OpenXE's error message includes the end of its log. The full log is at
`~/Library/Logs/OpenXE/wine.log`. Please include the program's name and the relevant
log lines when reporting it.

**Something else.**
See [`docs/platform-support.md`](docs/platform-support.md) for the precise technical
detail behind everything above, including what we have tested and what we have not.
