# Changelog

## WHD Next 3.0.0

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
