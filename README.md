> **WHD Imaging Helper** - by **Training1990for2026Systems** - contact: t90018273@gmail.com
> License: [MIT](LICENSE) - Security reports: see [SECURITY.md](SECURITY.md) - Built with Claude by Anthropic.

**Version: WHD Imaging Helper 1.5 preview 1** (2026-10-12) - the install-stick part of WinHardenDebloat (WHD).
It replaces the branches `usb-image` (WHD USB Image 1.0) and `usb-image-iso` (its ISO build). Still in development.

WHD Imaging Helper prepares a **Windows 11 Home install USB stick** before Windows is installed, in one terminal
menu - the way WHD Classic and WHD Next work after the install:

1. It takes the **Home edition** out of a Windows ISO file or a Windows install stick.
2. It looks inside that image and at the PC you build on (its **drivers**).
3. You **choose** in the menu what goes out, what is set, which drivers go in, what runs at the first sign-in.
4. It **applies** that to the image, can **block and remove the AI system packages** (see the warning below),
   saves the image and **makes the stick**.
5. After the install, `Check-InstalledPc.ps1` **checks what held**.

Native and offline. No third-party APIs, no downloads, no web calls. Only PowerShell, DISM, reg.exe, takeown,
icacls and the disk commands built into Windows. The Windows image files are Microsoft's and are **not** part of
this branch: you bring your own ISO file or install stick.

## Read this before you run it

Released under the [MIT License](LICENSE): **as is, with no warranty**. You run it at your own risk.

- **This is a preview.** One full run on one PC: Windows 11 Home 26H2, build 26300.9457, from Microsoft's ISO
  file, on 2026-10-12. The stick installed Windows; Windows Setup started the first sign-in script by itself; the
  check after the install is summed up under "What the test install showed". Other editions, builds, languages
  and PCs are untested.
- **Step 7 ERASES THE WHOLE STICK** after you typed `ERASE <letter>`. Installing Windows from the stick erases
  the drive you install to. Back up everything you cannot lose first.
- **The AI package removal (step 5) is NOT supported by Microsoft.** The AI system packages (CoreAI, AIFabric,
  AugLoop, AIX, and three speech/voice packages) are part of Windows itself: no supported DISM command takes them
  out. Step 5 deletes their `SystemApps` folders and their app entries in the image and blocks them. On the
  installed PC a health check (`DISM /ScanHealth`, `sfc /scannow`) can report the missing files as damage, a
  repair (`/RestoreHealth`) can put them back, and a cumulative update can fail or bring them back. Their component
  files in `WinSxS` are not touched. Switch them off in `lists\ai-list.txt` (or in the menu, step 3) if you do not
  want this. Details: [docs\ai-packages.md](docs/ai-packages.md).
- **The lists are examples** - the author's choices for the test install, a strict lock-down. Read them and change
  them (menu step 3) before you build. Among other things they switch off SMB file sharing, the Workstation and
  Server services, dial-up and VPN, Wi-Fi Direct, automatic Windows / driver / Store updates, and the first sign-in
  script deletes every Windows Firewall rule and adds a short allow-list. See [docs\lists.md](docs/lists.md).
- **The drivers of the PC you build on go into the image** when they are switched on. The menu copies them fresh in
  step 2 into the folder `drivers`, and writes `drivers-list.txt`. Both name that PC's hardware: they are in
  `.gitignore`, never upload them. On another PC the added drivers simply stay unused.
- **With the Wi-Fi driver in the image, Windows Setup can go online** at its network step, before the first
  sign-in script has set up Defender, DNS and the firewall.
- **WHD Classic and WHD Next do not know about what is set here.** The record of the image changes is
  `C:\Windows\Setup\Scripts\WHD-Image-applied.txt` on the installed PC; the first sign-in script writes
  `C:\ProgramData\WHD-Image\FirstSignIn.log`.
- **Never upload or share the Windows image files** (`*.iso`, `*.wim`, `*.swm`, `*.esd`). They are Microsoft's.

## What you need

- A Windows 11 ISO file from Microsoft (or a stick made by the media creation tool) that holds the edition
  **Windows 11 Home**.
- A Windows PC with **PowerShell 7** (for the menu; it stops and says so on Windows PowerShell 5.1 and installs
  nothing) and an **administrator** window. The scripts in `tools\` and `Check-InstalledPc.ps1` run on Windows
  PowerShell 5.1.
- About **30 GB free** on an **NTFS** drive for the work files (DISM cannot open an image on FAT32 or exFAT).
  `-WorkDir <folder>` puts them elsewhere.
- A USB stick of 16 GB or more that may be erased (8 GB at least; at most 256 GB; removable drives only).

## Start

Put the files of this branch in a folder (for example `C:\WHD-Imaging-Helper`), put the ISO file into the same
folder if you like (step 1 lists the ISO files it finds there), and start the menu in an administrator PowerShell 7:

```
pwsh -ExecutionPolicy Bypass -File .\WHD-ImageMenu.ps1
```

| Step | What it does |
|---|---|
| **1** | Opens the source: an **ISO file**, a **Windows USB stick**, or the `install.wim` kept from an earlier run. The Home edition is exported to `install.wim` (once per source), copied to `install-custom.wim` and opened. It stays open between the steps. From a stick, its setup files are copied to `setup-files` first, because that stick may be the one step 7 erases. |
| **2** | **Inventory.** The open image: bundled apps, optional features, capabilities, the AI system packages and the state of Recall / AIX, into `image-contents.txt`. This PC: its third-party driver packages, copied fresh into `drivers`, with `drivers-list.txt` (your on/off choices are kept by package name). |
| **3** | **Choose** - switch items on and off inside the menu: numbers (`1,3,5`), ranges (`2-6`), `a` all on, `n` all off, `s` save, `q` back without saving. Bundled apps, features and capabilities (`lists\remove-list.txt`), settings groups (`lists\image-settings.txt`), drivers (`drivers-list.txt`), first sign-in parts (`first-signin\first-signin-list.txt`), AI packages (`lists\ai-list.txt`). A list is copied once per session before its first change (`*_before-menu_*`). |
| **4** | **Apply** the choices to the open image: apps out, features off, capabilities out, drivers in, services disabled, registry values set, "deprovisioned" marks for the removed apps, the first sign-in script and its answer file into the image. |
| **5** | **AI packages** switched on in `lists\ai-list.txt`: blocked (deprovisioned mark, AppLocker deny rule, first sign-in recheck) and removed (their `SystemApps` folder, their app entries - saved to `ai-removed_<date_time>` first). Asks before it changes anything. **Not supported by Microsoft** (see above). |
| **6** | **Save** the image, check that it is one Home image, split it into pieces under 4 GB (`usb-custom`). |
| **7** | **Make the stick.** Shows the stick, asks you to type `ERASE <letter>`, erases it, one FAT32 partition, copies the setup files and the pieces, compares every file by SHA-256, writes the note `WHD-USB-Image.txt` on the stick. |
| **L** / **X** | The list of this session's changes. Exit: with the image still open it asks whether to keep it open or close it without saving. |

Nothing is saved into the image before step 6. Every start of the menu begins clean: an image it left open is
closed **without saving**. Nothing in the folder is deleted: older work files are renamed (`_old_<date_time>`).
Everything is written to `WHD-ImageMenu.log`.

## After the install: check what held

On the installed PC, with this folder copied there, in an administrator Windows PowerShell:

```
powershell -ExecutionPolicy Bypass -File .\Check-InstalledPc.ps1
```

It only reads and writes `test-results\<date_time>\report.txt`: whether Setup started the first sign-in script,
which image settings and services are still in place, which removed apps came back, the AI packages (folder gone,
not installed, mark, AppLocker rule, whether Windows took the AppLocker policy in), what the first sign-in script
set, the firewall rules, programs, devices without a driver. The report names the PC's hardware and programs:
keep it private (`test-results` is in `.gitignore`).

## What the test install showed (2026-10-12, Windows 11 Home 26300.9457, one PC)

- The menu ran steps 1 to 7 in one session: 311 changes made, 56 skipped, 3 refused by Windows
  (`Microsoft.DesktopAppInstaller`, `Microsoft.SecHealthUI`, capability `Language.Basic` - "permanent").
- **Windows Setup started the first sign-in script by itself** (the answer file inside the image).
  At that moment Defender was not ready: folder protection and the attack-surface rules were reported as failed;
  later they were all in place (see "Known problems").
- **All 7 AI system packages stayed out**: folders gone, not installed for any user, marks there, AppLocker deny
  rules there, the Application Identity service running, and Windows had compiled the AppLocker policy - so the
  packaged-app rules were taken in on Windows 11 Home. The first sign-in recheck found all 7 still out.
- 169 items as set, 4 different (camera and microphone permission changed afterwards, Windows Media Player
  feature reads empty because its capability was removed too, OneDrive installed later).
- The new Outlook app came back after the install, with its mark gone - most likely brought by a Microsoft 365
  install; not separated.

## The tools (without the menu)

The scripts in `tools\` are the earlier single-purpose tools, kept for those who want one script per job. They read
the same lists and write into this folder. Run them from this folder, e.g.
`powershell -ExecutionPolicy Bypass -File .\tools\List-HomeImage.ps1`. Notes: [docs\tools.md](docs/tools.md).

| Script | What it does |
|---|---|
| `tools\Build-HomeUsbFromIso.ps1` | The whole build in one run without questions in between: ISO file -> Home image -> lists + drivers -> stick (`-NoStick` builds only). Windows PowerShell 5.1. |
| `tools\Apply-HomeImage.ps1`, `tools\Finish-HomeUsb.ps1` | The stick-based way: the image is taken from a Windows stick and the changed image put back on it. |
| `tools\List-HomeImage.ps1` | Lists what is in `install.wim` (read-only). |
| `tools\Inventory-AiPackages.ps1` | Where the AI system packages sit in the image (read-only), into `ai-inventory.txt`. |
| `tools\Export-MyDrivers.ps1` | Copies this PC's driver packages into `drivers` and writes `drivers-list.txt` (the menu's step 2 does this too). |
| `tools\Build-PublishCopy.ps1` | Makes a clean, checked copy of this folder for publishing (see below). |

## Going back

- The ISO file and `install.wim` are never changed: run the menu again from step 1 for a fresh image.
- On the installed PC: the first sign-in script keeps a backup of the firewall policy before it deletes the rules:
  `netsh advfirewall import "C:\ProgramData\WHD-Image\firewall-before-first-signin.wfw"`.
- The AI packages cannot be put back on an installed PC by these scripts; install Windows again from a stick made
  with them switched off in `lists\ai-list.txt`. The registry entries step 5 deleted are saved in
  `ai-removed_<date_time>` (for reference).

## What the scripts keep to

- They write only into this folder (or `-WorkDir`), into the open image, and onto the stick you confirmed.
- The ISO file and the source stick are only read.
- Nothing in the folder is deleted; older work files get `_old_` in their name. They are several GB: delete them by
  hand once the stick has installed Windows correctly.
- The stick is refused when it is not a removable USB drive, is larger than 256 GB, smaller than 8 GB, or holds
  Windows, the work folder or the setup source.
- Every step writes what it did into a log in this folder.

## Making a publish copy

`tools\Build-PublishCopy.ps1` copies only what `.gitignore` lets through into `..\publish\<folder>_<date>_<time>`,
stops when a file holds one of the words in `private-words.txt` (or the Windows user name or computer name), stops
when a `.ps1` file does not read in Windows PowerShell 5.1 or is not ASCII, compares every copy and writes a new
`SHA256SUMS.txt`. Make `private-words.txt` yourself (one word per line); it is never copied.

```
powershell -ExecutionPolicy Bypass -File .\tools\Build-PublishCopy.ps1 -ListOnly
powershell -ExecutionPolicy Bypass -File .\tools\Build-PublishCopy.ps1
```

## Files in this branch

| File | What it is |
|---|---|
| `WHD-ImageMenu.ps1` | The menu (PowerShell 7). Start here. |
| `Check-InstalledPc.ps1` | Read-only check of the installed PC; writes a report. |
| `lists\remove-list.txt` | Example: what is taken out of the image. |
| `lists\image-settings.txt` | Example: what is set in the image, and the three part switches. |
| `lists\ai-list.txt` | Example: which AI system packages step 5 blocks and removes. |
| `first-signin\WHD-FirstSignIn.ps1` | Runs once at the first sign-in (Windows PowerShell 5.1). |
| `first-signin\first-signin-list.txt` | Example: what that script does. |
| `first-signin\Autounattend.xml` | The answer file that makes Windows Setup start that script; it goes into the image as `Windows\Panther\unattend.xml`. |
| `tools\*.ps1` | The single-purpose tools (see above). |
| `docs\*.md` | Notes: the lists, the tools, the AI packages. |
| `SHA256SUMS.txt` | SHA-256 checksums of the files in this branch. |

Work files (`install.wim`, `install-custom.wim`, `drivers`, `drivers-list.txt`, `usb-custom`, `setup-files`, the
`mount*` folders, `ai-removed_*`, logs, reports, everything with `_old_` or `_before-menu_`) stay out of Git
(`.gitignore`).

## Known problems in this version

- **Step 5 is not supported by Microsoft** (see "Read this before you run it").
- **Windows refuses some removals**: `Microsoft.DesktopAppInstaller` and `Microsoft.SecHealthUI` (error 15610) and
  the capability `Language.Basic` (permanent). The example list still names them; the run reports them as failed.
- **Defender may not be ready at the first sign-in**: folder protection and the attack-surface rules can fail
  there. Run the script again later: `powershell -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\WHD-FirstSignIn.ps1 -Again`
  (in the test they were in place later on).
- **A removed app can come back** when other software installs it (the new Outlook with Microsoft 365).
- Not tested: a Windows USB stick as the source in the menu, `-WorkDir`, editions other than Home, other builds.
- The Edge Update services (`edge-update-services-off`) are switched on again when Microsoft Edge updates itself.
