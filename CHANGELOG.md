# Changelog

Every version of WinHardenDebloat, newest first. Each version is a Release with a tag of the same name
(`v3.0.0`, `v2.0`, ... `v1.4`); the full text of each version is in that version's own README.

## WHD Next 3.0.0 (2026-10-25) - `v3.0.0`

A rewrite of WHD Next 2.0 for **PowerShell 7.6 or a newer stable version only**. It keeps 2.0's features
and names, takes over 2.0's change history, and adds the items listed below.

### Changed against WHD Next 2.0
- **PowerShell 7.6 only.** Preview versions are refused, and a newer stable version runs after a warning.
  There is no Windows PowerShell 5.1 fallback. Only two small files use 5.1:
  - the starting tool `Start-WHD.ps1`;
  - the update guard's front door `Start-WHDGuard.ps1`.
- **A real PowerShell module** (`WHDNext\`: manifest, Private engine, Public commands, Features).
- **The starter** checks and explains:
  - administrator rights, Windows, PowerShell 7 (machine-wide, stable, not the Store version), winget,
    folder protection and the program files;
  - if PowerShell 7.6 is missing, it offers Microsoft's machine-wide installer (winget, or the signed MSI in
    `installers\`), only after your yes;
  - it can re-open itself as administrator.
- **Safe mode, running on 7.6.** Status screens, the inventory, the full dry-run, Verify, the Undo center,
  re-apply / re-remove and restore points work; new changes do not.
- **2.0's change history** is copied once, or read in place, at the first start (you choose). 2.0's folder
  is never changed. History from another PC or an earlier Windows install is recognised and can be moved
  to `archive\` (Undo center H).
- **The same keys in every menu:** X = EXECUTE, S = safe mode, B = back. Keys that clashed moved:
  - Security = SE and Theme = TH on the main menu;
  - status = ST in Updates, Devices and Time & region;
  - Store suppression = SS in the AI menu;
  - block an .exe = K in the Win32 menu;
  - firewall export = E.
- **Firewall:** 2.0's block lists are copied once and checked. The default-deny rollback task runs Windows'
  own netsh, so it works even without PowerShell.
- **Permissions:** the full Privacy & security list as this PC shows it.
  - Lock also locks the newer switches (voice activation, app diagnostics, screenshots, text and image
    generation, passkeys, and more).
  - Balanced denies the new sensitive switches.
  - Per-app R removes an app's entry; it is saved to a .reg file first.
- **Component store:** R (ResetBase) needs RESETBASE typed.
- **The theme was redone:**
  - new film-like ship sounds with a spoken ship's computer (Windows' Zira voice, offline);
  - 24 new pictures drawn by the project's own code;
  - one sky-blue look;
  - a lock-screen slide show;
  - sounds at sign-in, lock and unlock;
  - the sound files are made only with EXECUTE on.
- **The window** (`Start-WHD.cmd -Gui`):
  - the same tabs as 2.0, plus Devices, Time & region and Profiles;
  - the buttons are read from each console menu, so window and console never differ;
  - it runs on its own thread, so it stays alive during long actions and shows WORKING;
  - questions come up as dialogs.

### New in 3.0
- **PowerShell 7 telemetry off** (Security T): machine-wide, recorded, and watched by Verify and the update
  guard.
- **Inventory compare (D):** what appeared, went or changed between two scans; apps WHD removed that are
  back are flagged as CAME BACK.
- **`WHD.ps1 -Plan`:** the full dry-run of everything.
- **The update guard (main menu G),** alert only:
  - it runs from a locked copy in `ProgramData\WinHardenDebloatNext\guard3`;
  - the task `\WinHardenDebloatNext3\UpdateGuard` runs 10 minutes after sign-in and daily at 16:30;
  - it checks every recorded change, removed apps after Windows updates, and refused clock jumps;
  - it alerts through the Application log and a small window;
  - if PowerShell 7.6 is missing or broken, the 5.1 front door alerts instead.
- **Profiles (main menu P, the Profiles tab, `WHD.ps1 -Profile <name>`):**
  - `minimum`, `average` and `strict`, written new;
  - editable JSON, and you can add your own;
  - one question, then every step; each step is recorded.
- **The publish tool** `tools\Publish-WHD.ps1` (for the maintainer): a cleaned copy, a zip and / or the
  GitHub branch, with this PC's details removed and a leak scan.

## WHD Next 2.0 (2026-10-10) - `v2.0`

Changed since Next 2.0 preview 1:

- **Time sync (Firewall T):** the Windows Time service is set to Automatic (preview 1: Automatic, delayed
  start), and Windows' own start triggers are taken off it. A copy of the triggers is saved first; when no
  copy can be saved, nothing is taken off.
- **Putting them back:** the Undo center and Firewall N (Windows default time) import the saved copy. The
  triggers count again after a restart.
- **Verify and re-apply** know the item and report when the triggers are on the service again.
- **Undo of a service start type** can put "Automatic (delayed start)" back, also in SAFE mode.
- **Time status (Firewall S)** says what the triggers are, or "none".
- **Live test** on 2026-10-08 and 2026-10-09 (15 sessions in FULL mode with the files of preview 1); the 2.0
  change itself was run on Windows on 2026-10-10.

## WHD Next 2.0 preview 1 (2026-10-05) - `v2.0-preview1`

The first upload of the PowerShell 7.6 line. WHD Next started on 2026-10-01 as a copy of WHD Classic 1.4.
Different from Classic:

- **A launcher:** `Start-WHD.cmd` / `Start-WHD.ps1` (add `-Gui` for the window version).
- **FULL mode** needs PowerShell 7.6 or newer; the launcher offers to install it through winget, only after
  your yes. **SAFE mode** (Windows PowerShell 5.1) allows the read-only screens, the dry-run plan, Verify,
  Undo, re-apply and re-remove.
- **Its own identity:** firewall groups `WinHardenDebloatNext-*`, rule names `WHDN-*`, its own update guard
  task and its own change history. Next does not manage what Classic set up.
- **Optional theme:** ship sounds, 24 original space pictures, dark mode, pictures on the lock screen and
  sign-in screen. Not part of any profile.
- It did not have all of Classic's fixes of 1.4.1, 1.4.2 and 1.5: see "Known problems in this version" in
  its README.

## WHD Classic 1.5 (2026-10-10) - `v1.5`

Improvements carried over by hand from WHD Next; Classic stays on Windows PowerShell 5.1 and makes no web
calls. Written 2026-10-05 to 2026-10-07, live-tested 2026-10-06 and 2026-10-08, released 2026-10-10.

- **Several items at once** in the AI, General apps and More privacy settings menus: a list (`1,3,5`), a
  range (`2-6`) or `*` for the recommended items; one question for the whole list.
- **Update gate: a third position, PROGRAMS.**
- **Blocked connections** view (Firewall V).
- Changes to the **firewall wipe**, the **update guard** and **Security+ E**; safety fixes found while
  merging; the window version follows.
- **Rules WHD did not make** (Firewall K, Updates K): WHD finds firewall rules that Windows or installers
  wrote after the gate was set, alerts, and lets you remove or keep them.
- **The gate and the firewall tools tell each other's changes:** the gate names what it switches off, the
  Firewall-menu tools say what they change of the gate, and Status tells when the gate is not what its
  record says.
- **Copilot off-switch** also sets two Edge Update policies.

## WHD Classic 1.4.2 (2026-10-04) - `v1.4.2`

Fixes from the live test of 1.4.1:

- **Win32 programs:** when an uninstaller ends with an unusual exit code, WHD checks whether Windows still
  lists the program (the OneDrive case). Gone = done and recorded; still listed = FAILED.
- **Ransomware folder protection:** WHD warns when its own folder is inside a protected folder, before the
  protection is switched to BLOCK and at start-up.
- **Defender definitions (Updates D):** clearer messages; on a failure WHD logs the gate state and
  Defender's own error details.
- Partly live-tested on 2026-10-04.

## WHD Classic 1.4.1 (2026-10-03, test result added 2026-10-04) - `v1.4.1`

Pre-release review fixes, live-tested on a fresh Windows 11 Home image:

- **Default-deny outbound:** the auto-rollback is a one-time SYSTEM task with no script file; default-deny
  is not switched on if the task cannot be armed or the DNS / DHCP allow rules are missing.
- **Firewall menu:** every changing option asks y/N in EXECUTE mode; no change without a backup.
- **Update gate:** refuses to close while an adapter does not use the pinned DNS servers.
- **Win32 programs:** uninstallers start with correct quoting and their exit code is checked.
- **Engine, profiles, permissions, updates, devices, component store, update guard:** a list of smaller
  fixes; WHD refuses to start in PowerShell 7.
- **Wording:** texts that referred to the author's PC were made neutral. `.gitattributes` keeps files
  byte-for-byte, so `SHA256SUMS.txt` also matches for a Git clone.
- Known issues found in the live test are listed in that version's README.

## WHD Classic 1.4 (2026-10-03) - `v1.4`

The first version on GitHub. Built from 2026-09 on; versions 1.0 to 1.3 were not published (their notes are
in the README of 1.4). New in 1.4 (2026-09-30):

- **Time & region** (main menu T): pick the time zone, set date and time by hand, status. Recorded, with
  Undo, Verify and the update guard watching the zone.
- **Apps found on this PC:** General debloat lists every non-Microsoft Store app found on the PC WHD runs
  on; nothing is hard-coded per PC model.
- **Clean publish copy:** `tools\Build-PublishCopy.ps1` builds a copy with the PC's details replaced, a
  leak scan and `SHA256SUMS.txt`.
