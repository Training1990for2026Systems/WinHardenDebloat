# WHD Next 3.0

Windows hardening and debloat for Windows 11, rebuilt for **PowerShell 7.6 or a newer stable version**.
Dry-run first, every change recorded and undoable. Built with Claude by Anthropic. MIT License.

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

## Learn more
- `docs\GUIDE.md` - a short guide: first run, the main menu, profiles, Undo, the update guard.
- `CHANGELOG.md` - what changed against WHD Next 2.0.
- `SECURITY.md` - how to report a problem.

## Coming from WHD Next 2.0
At its first start WHD Next 3.0 asks once how to take over 2.0's change history: copy it once, or read it
in place. 2.0's folder is never changed. Changes 2.0 made can then be verified and undone here.

## Your files
- `profiles\` holds the profiles, the firewall baseline and your own block lists (`blacklist-ip.txt`,
  `blacklist-hosts.txt`). The block lists are not shipped.
- `logs\` holds the log of every run.
- `restore\` holds the change history and backups.
