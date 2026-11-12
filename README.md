> **WinHardenDebloat (WHD)** - by **Training1990for2026Systems** - contact: t90018273@gmail.com
> License: [MIT](LICENSE) - Security reports: see [SECURITY.md](SECURITY.md) - Built with Claude by Anthropic.

# WinHardenDebloat (WHD)

Windows hardening and debloat for a newly installed, non-domain Windows 11 PC. Offline, native PowerShell,
dry-run first, every change recorded and undoable.

**Current version: WHD Next 3.0.0** (2026-10-25), for **PowerShell 7.6 or a newer stable version**.
This is what you get when you clone the repository or download the latest Release.
Earlier versions are kept as Releases: see [Versions](#versions).

## What it does
- **Debloat:** AI surfaces (Copilot, Recall, Bing, Widgets, Click to Do, Edge AI), promoted Store apps,
  Win32 programs, telemetry and more privacy settings.
- **Harden:** Defender protections and attack-surface rules, old network protocols and services, UAC,
  password rules, app permissions, devices (Bluetooth network, Wi-Fi Direct, WAN Miniports).
- **Network:** firewall baseline, allow-list, default-deny outbound with an automatic rollback, IP and
  host block lists (your own files), Cloudflare DNS (encrypted) and time, the firewall log.
- **Updates:** an update gate, Windows Update / driver / Store policies, app self-updaters.
- **Look after it:**
  - an inventory and compare (removed apps that came back are flagged);
  - Verify (are all changes still in place?);
  - the Undo center;
  - the update guard (alert only, after sign-in and daily).
- **Profiles:** minimum, average or strict - many actions in one go.
- **Optional theme:** ship sounds with a spoken ship's computer, pictures, a sky-blue look, a lock-screen
  slide show, and sounds at sign-in, lock and unlock.

## Requirements
- Windows 11 and an administrator account.
- PowerShell 7.6 or a newer stable version, installed machine-wide. Preview versions are refused. If it is
  missing, the starter offers to install Microsoft's version (winget, or the MSI you put in `installers\`),
  and only after your yes.
- Windows PowerShell 5.1 is used by only two small files: the starter and the update guard's front door.

## Get it
- **Download:** open [Releases](../../releases/latest), download **Source code (zip)** and unpack it.
- **Or clone:** `git clone https://github.com/Training1990for2026Systems/WinHardenDebloat.git`

`SHA256SUMS.txt` lists the SHA-256 checksum of every file. The scripts are not code-signed.

## Start
1. Put the folder somewhere outside Documents / Desktop, for example `C:\WHD`.
2. Double-click **`Start-WHD.cmd`**. The starter checks the PC, shows a short table, then opens the main
   menu. Run `Start-WHD.cmd -Gui` for the window instead.
3. WHD starts in **dry-run**: every action only says what it would do. Press **X** to turn EXECUTE on; each
   change still asks first. A System Restore point is made before the first change of a session.

In every menu: **X** = EXECUTE on/off, **S** = safe mode on/off, **B** = back (**Q** quits the main menu).

Other ways to start (`WHD.ps1`, run by the starter):

| Command | What it does |
|---|---|
| `-Plan` | The full dry-run of everything (changes nothing) |
| `-Verify` | Checks every recorded change |
| `-Profile minimum`, `average` or `strict` | Applies a profile (dry-run unless `-Execute`) |
| `-Menu <name>` | Opens one menu directly |

## Versions

In order of creation. Each one is a Release with its own notes and download; the code of each is also in
this repository's history under its tag.

| Version | Date | Runs on | Release |
|---|---|---|---|
| WHD Classic 1.4 | 2026-10-03 | Windows PowerShell 5.1 | [`v1.4`](../../releases/tag/v1.4) |
| WHD Classic 1.4.1 | 2026-10-04 | Windows PowerShell 5.1 | [`v1.4.1`](../../releases/tag/v1.4.1) |
| WHD Classic 1.4.2 | 2026-10-04 | Windows PowerShell 5.1 | [`v1.4.2`](../../releases/tag/v1.4.2) |
| WHD Classic 1.5 | 2026-10-10 | Windows PowerShell 5.1 | [`v1.5`](../../releases/tag/v1.5) |
| WHD Next 2.0 preview 1 | 2026-10-05 | PowerShell 7.6 (safe mode on 5.1) | [`v2.0-preview1`](../../releases/tag/v2.0-preview1) |
| WHD Next 2.0 | 2026-10-10 | PowerShell 7.6 (safe mode on 5.1) | [`v2.0`](../../releases/tag/v2.0) |
| **WHD Next 3.0.0** | 2026-10-25 | PowerShell 7.6 or a newer stable version | [`v3.0.0`](../../releases/tag/v3.0.0) - **current** |

- **WHD Classic (1.x)** is the first line, for the Windows PowerShell 5.1 that is built into every Windows.
- **WHD Next 2.0** started on 2026-10-01 as a copy of Classic 1.4, moved to PowerShell 7.6.
- **WHD Next 3.0** is 2.0 rewritten as a PowerShell module for 7.6 only. It takes over 2.0's change history.

Each line keeps its own change history on the PC: the Undo center and Verify of one line do not cover what
another line set. What changed in each version: [`CHANGELOG.md`](CHANGELOG.md).

## Related
- **[WHD-Imaging-Helper](https://github.com/Training1990for2026Systems/WHD-Imaging-Helper)** - prepares a
  Windows 11 Home install USB stick *before* Windows is installed. A separate tool with its own repository.
- **[WinHardenDebloat-archive](https://github.com/Training1990for2026Systems/WinHardenDebloat-archive)** -
  this project's repository as it was until 2026-11, with one branch per version. Kept for the record.

## Learn more
- `docs\GUIDE.md` - a short guide: first run, the main menu, profiles, Undo, the update guard.
- `CHANGELOG.md` - what changed in every version.
- `SECURITY.md` - how to report a problem.

## Coming from WHD Next 2.0
At its first start WHD Next 3.0 asks once how to take over 2.0's change history: copy it once, or read it
in place. 2.0's folder is never changed. Changes 2.0 made can then be verified and undone here.

## Your files
- `profiles\` holds the profiles, the firewall baseline and your own block lists (`blacklist-ip.txt`,
  `blacklist-hosts.txt`). The block lists are not shipped.
- `logs\` holds the log of every run.
- `restore\` holds the change history and backups.

---

WHD is an independent project; it is not made, endorsed or supported by Anthropic or Microsoft.
