# The AI system packages (menu step 5)

## What they are

Windows 11 (26H2, build 26300.9457) carries these packages under `C:\Windows\SystemApps`. They are signed
**System** (part of Windows):

| Package family | Folder |
|---|---|
| `MicrosoftWindows.Client.CoreAI_cw5n1h2txyewy` | `SystemApps` |
| `Microsoft.AIFabric.CBS.1.6_8wekyb3d8bbwe` | `SystemApps` |
| `Microsoft.Windows.AugLoop.CBS_8wekyb3d8bbwe` | `SystemApps` |
| `MicrosoftWindows.Client.AIX_cw5n1h2txyewy` | `SystemApps` (folder only, no app manifest) |
| `MicrosoftWindows.61869720.Voiess_cw5n1h2txyewy` | `SystemApps\SxS` |
| `MicrosoftWindows.61869721.Livtop_cw5n1h2txyewy` | `SystemApps\SxS` |
| `MicrosoftWindows.61869722.Speion_cw5n1h2txyewy` | `SystemApps\SxS` |

On a running Windows they cannot be removed: `Remove-AppxPackage` answers "Removal failed", and two of them came
back after a restart. In the install image none of them is a provisioned app, a servicing package that DISM lists,
a capability or a feature (`tools\Inventory-AiPackages.ps1` shows this). AIX belongs to the hidden servicing
package `UserExperience-AIX-Package`, which is part of `UserExperience-Recall-Package`. **No supported DISM command
takes them out** (Microsoft Learn: DISM app package servicing, "Add or remove packages offline using DISM").

## What step 5 does, per package switched on in `lists\ai-list.txt`

1. **Block** - Windows' "deprovisioned" mark (`...\AppxAllUserStore\Deprovisioned\<family>`).
2. **Block** - an AppLocker packaged-app deny rule (all versions) under `HKLM\SOFTWARE\Policies\Microsoft\Windows\SrpV2\Appx`,
   with one allow rule for every other signed packaged app (without an allow rule no packaged app could start),
   EnforcementMode 1, and the Application Identity service (AppIDSvc) set to start automatically - AppLocker needs it.
   When the image already has packaged-app rules of its own, nothing is mixed in. AIX gets no rule (no manifest).
3. **Remove** - its app entries (`InboxApplications`, `Config`, `UpdatedApplications`), each saved with `reg export`
   into `ai-removed_<date_time>` first.
4. **Remove** - its folder (taken over with takeown / icacls, then deleted).
5. **Recheck** - `ai-block:` lines in the first sign-in list: at the first sign-in the mark is written again when
   missing and a package that came back is removed for all users.

`WinSxS` (the component store) is not touched: that would break Windows servicing.

## The risk

This is **not supported by Microsoft**. On the installed PC: `DISM /ScanHealth` or `sfc /scannow` can report the
missing files; `/RestoreHealth` can put them back; a cumulative update can bring them back or fail to install.
The rules and marks stay in place, so a package that comes back should still be blocked - that has not been
seen yet. Watch the first cumulative updates.

## What the test install showed

One install, Windows 11 Home 26300.9457, 2026-10-12: all 7 stayed out after the install; marks and deny rules in
place; AppIDSvc running; `C:\Windows\System32\AppLocker\Appx.AppLocker` present (Windows took the rules in). Not
yet seen: the behaviour over cumulative updates and health checks.
