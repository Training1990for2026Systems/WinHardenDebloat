> **WHD USB Image - ISO build** - by **Training1990for2026Systems** - contact: t90018273@gmail.com
> License: [MIT](LICENSE) - Security reports: see [SECURITY.md](SECURITY.md) - Built with Claude by Anthropic.

**Version: USB Image ISO 1.0 preview 1** (2026-10-10) - a fork of WHD USB Image (branch `usb-image` of
WinHardenDebloat): the same image changes, another way to get the image and to make the stick. Still in
development.

# WHD USB Image - ISO build

Makes a **Windows 11 install USB stick from one Windows ISO file**:

1. It takes **one edition, Windows 11 Home**, out of the ISO file.
2. It can take bundled apps, optional features, capabilities and services **out of that Home image**.
3. It can write machine-wide settings **into that image** (policies, services, protocols).
4. It can have Windows Setup start **one script at the first sign-in**, for the settings that need a running
   Windows (Microsoft Defender, password rules, NetBIOS, DNS, OneDrive, firewall rules, UAC).
5. It **erases the stick**, formats it and puts everything on it: the files of the ISO and the changed image.

Native and offline. No third-party APIs, no downloads, no web calls: **you download the ISO file yourself**, from
Microsoft. Everything runs on Windows PowerShell 5.1, DISM, reg.exe and the disk commands built into Windows.
The Windows files are Microsoft's and are **not** part of this folder.

## How it differs from WHD USB Image (the stick-based tool)

| | WHD USB Image | ISO build (this folder) |
|---|---|---|
| Where the image comes from | a stick made by Microsoft's media creation tool | one ISO file you downloaded |
| Who makes the stick | the media creation tool; the script only replaces the image files | this script: erase, format, copy |
| What is kept as "the original" | the image files, copied into the folder `original` | the ISO file itself; it is only read |
| Can check the download | no | yes: it shows the ISO file's SHA-256 and compares it with `-IsoSha256` |
| What happens to other files on the stick | they stay | **everything on the stick is deleted** |
| Script | `Apply-HomeImage.ps1`, `Finish-HomeUsb.ps1` | `Build-HomeUsbFromIso.ps1` |

The three lists, the first sign-in script, the answer file and `Check-InstalledPc.ps1` are the same in both.

## Read this before you run it

Released under the [MIT License](LICENSE): **as is, with no warranty**. You run it at your own risk.

- **This is a preview, used once.** On 2026-10-10 it ran on one PC with one ISO file and one 32 GB stick: it
  built the image (133 changes, 0 failed), erased and formatted the stick, copied the 976 files of the ISO and
  the two image pieces with every checksum the same, and the PC starts from that stick. **No Windows has been
  installed from such a stick yet.** Not run on a real PC: `-CheckOnly`, `-IsoSha256`, `-WorkDir`, a stick
  larger than 32 GB, an ISO with `install.esd`; those were checked with the PowerShell parser and with
  simulated runs against stand-ins for DISM, reg.exe and the disk commands. Do your first run with `-NoStick`,
  and use a stick that has nothing on it.
- **The stick is erased - all of it.** The script shows the disk, lists what is on it and waits for you to type
  `ERASE <letter>`. It refuses a drive that is not a removable USB drive, a disk larger than 256 GB, the disk
  Windows starts from, and a disk that holds the work folder, this folder or the ISO file. Read what it shows
  before you type.
- **Installing Windows from the stick erases the drive you install to.** Back up everything you cannot lose first.
- **`remove-list.txt`, `image-settings.txt` and `first-signin\first-signin-list.txt` are examples**: a strict
  lock-down taken from the WHD Classic `standard` profile. Read every group before you use them. Among other
  things they switch off SMB file sharing, dial-up and the built-in VPN, Wi-Fi Direct, automatic Windows, driver
  and Store updates, and they delete every Windows Firewall rule at the first sign-in. Switch a group or a part
  off by changing `on` to `off` on its line.
- **Have your drivers ready.** The example settings switch off Windows' own driver search. The test PC of WHD USB
  Image came up with 19 devices without a driver, and without a network connection until its Wi-Fi driver was
  installed by hand. The stick is erased by this script, so put your driver files on it **after** the script has
  finished, or keep them on a second stick.
- **Windows Home may not keep to every setting**, and **WHD Classic and WHD Next do not know about what is set
  here**: their Undo, Verify and update guard work from their own change history. The record of what was set is
  `C:\Windows\Setup\Scripts\WHD-Image-applied.txt` on the installed PC.
- **Never upload or share the Windows files** (`*.iso`, `*.wim`, `*.swm`, `*.esd`). They are Microsoft's.

## What you need

- A **Windows 11 ISO file** (64-bit, several editions), downloaded by you from Microsoft.
- A USB stick of 8 GB or more that may be erased. A stick larger than 32 GB gets one partition of 30 GB: Windows
  formats FAT32 only up to 32 GB.
- A Windows PC with Windows PowerShell 5.1, an administrator account, and free space on an **NTFS** drive: about
  20 GB plus two and a half times the size of the ISO file.
- This folder on that PC, not on the stick. When ransomware protection (Controlled folder access) is on in
  Windows Security, keep this folder and the work folder outside the protected folders (Documents, Pictures,
  Videos, Music, Favorites): writes into those are blocked for PowerShell.

## Step 1 - a first try that touches no stick

Open Windows PowerShell as administrator, go to this folder:

```
powershell -ExecutionPolicy Bypass -File .\Build-HomeUsbFromIso.ps1 -IsoFile C:\Downloads\Win11.iso -NoStick
```

It reads the lists, works out the SHA-256 of the ISO file, opens the ISO, exports the Home edition to
`install.wim`, changes a copy of it and splits the result into the folder `usb-custom`. No stick is needed. It
writes `Build-HomeUsbFromIso.log` and ends with a `RESULT:` line.

**Check the download.** The log shows `SHA-256 of the ISO file: ...`. When the place you downloaded from shows a
SHA-256 value for the file, compare the two. Or give the value to the script; it stops when the file differs:

```
powershell -ExecutionPolicy Bypass -File .\Build-HomeUsbFromIso.ps1 -IsoFile C:\Downloads\Win11.iso -IsoSha256 <value> -NoStick
```

## Step 2 - make the stick

Plug the stick in, note its letter in Explorer (the examples use `F:`):

```
powershell -ExecutionPolicy Bypass -File .\Build-HomeUsbFromIso.ps1 -IsoFile C:\Downloads\Win11.iso -UsbDrive F
```

1. It checks the stick and shows it: disk number, name, size, label, and what is on it at the top.
2. It asks you to type `ERASE F`. Anything else stops the run and nothing is changed. It asks **at the start**,
   so that the long part can run without you; the erase itself comes at the end.
3. It builds the image as in step 1. `install.wim` from step 1 is used again when it came from the same ISO
   file; the changes are made anew on a fresh copy.
4. Only after the changed image is saved and split it erases the stick, makes one FAT32 partition, copies every
   file of the ISO except the install image, copies the pieces, and compares the SHA-256 checksum of **every**
   file on the stick with its source.
5. It writes the note `WHD-USB-Image.txt` on the stick and closes the ISO file again.

If the build fails, the stick is as it was. If something fails after the erase, the log says so in plain words:
the stick is then empty or incomplete until the script has run to its end again.

Windows may answer part of the checksum check from memory right after a copy. To be sure, eject the stick, plug
it in again and run (it only reads and compares):

```
powershell -ExecutionPolicy Bypass -File .\Build-HomeUsbFromIso.ps1 -IsoFile C:\Downloads\Win11.iso -UsbDrive F -CheckOnly
```

## The lists

Three list files say what is changed in the image. Each is plain text, one item per line; a line that starts with
`#` is a comment. The script reads all three before it changes anything and stops on a line it does not
understand.

**`remove-list.txt`** - what is taken out:

```
app:<display name>            a bundled app
feature:<feature name>        an optional feature to switch off
capability:<capability name>  an installed capability to remove
service-off:<service name>    a service to set to "disabled" in the image's registry
```

**`image-settings.txt`** - what is set in the image:

```
part:<name> on|off            machine-settings, removed-app-marks, first-signin
group:<name> on|off           starts a group; the lines below it belong to it
reg:<hive>|<key>|<value name>|<type>|<data>     hive SOFTWARE or SYSTEM, type dword or string
service-off:<service name>
```

**`first-signin\first-signin-list.txt`** - what the first sign-in script does on the installed PC: Microsoft
Defender (unwanted apps, network protection, folder protection, 14 attack-surface rules), password and lockout
rules, NetBIOS off, DNS with encrypted DNS, OneDrive, the firewall (backup, delete every rule, add the listed
allow rules), UAC "Always notify". Each part has its own `on` / `off` line.

To see the names of the apps, features and capabilities in the image: run step 1 once, then

```
powershell -ExecutionPolicy Bypass -File .\List-HomeImage.ps1
```

It opens `install.wim` in this folder read-only and writes `image-contents.txt`. It does not know `-WorkDir`.

## The first sign-in script

The script and its list are copied into the image (`C:\Windows\Setup\Scripts` on the installed PC), and the
answer file `first-signin\Autounattend.xml` is copied into the image as `Windows\Panther\unattend.xml`. The answer
file does one thing: it tells Windows Setup to start the script once, after the first sign-in of the first user.
It answers no Setup question.

- **Not known: whether Windows Setup starts the script from there.** In the test install of WHD USB Image the
  answer file was on the root of the stick; Setup found it and passed it over. Microsoft Learn ("Replace the
  answer file in an offline image") names the place inside the image as the one Setup uses. No install has tried
  it yet.
- **Check after the install:** `C:\ProgramData\WHD-Image\FirstSignIn.log` says near its top who started the
  script ("Started by Windows Setup" or "Started by hand") and ends with a `RESULT:` line. If the file is not
  there, start the script by hand - **after you have signed in with your own account**, not from a command
  window during setup - in an administrator PowerShell:

  ```
  powershell -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\WHD-FirstSignIn.ps1
  ```

- At the first sign-in a PowerShell window opens and works for several minutes. Leave it alone; it closes by
  itself. Restart the PC once afterwards.
- It runs once. A second start does nothing unless `-Again` is given. Do not use `-Again` after WHD Classic or
  WHD Next has set up the firewall: the firewall part would delete their rules too (it does nothing while
  outbound is set to Block).

## After the install: check what holds

On the installed PC, in an administrator PowerShell, from a copy of this folder:

```
powershell -ExecutionPolicy Bypass -File .\Check-InstalledPc.ps1
```

It only reads. It compares the three lists with the running Windows and writes
`test-results\<date_time>\report.txt`. The report names the PC's hardware and programs: keep it private.

## What the script keeps to

- The ISO file is only read: never changed, moved or deleted. Windows opens it as a read-only drive; the script
  closes it again when it opened it.
- It writes only into its work folder (this folder, or `-WorkDir`) and onto the stick you confirmed.
- Before the erase it checks again that the drive letter still belongs to the same disk as at the start.
- It refuses: a drive that is not connected by USB, one that Windows does not call removable, a disk larger than
  256 GB or smaller than 8 GB, the disk Windows starts from, a disk that holds the work folder, this folder or
  the ISO file, a work folder that is not on NTFS, and an `install.wim` that it changed before.
- Nothing in the work folder is deleted. Older work files are renamed (names with `_old_`). They are several GB
  each: delete them by hand once the stick has installed Windows correctly.
- Everything it does is written to `Build-HomeUsbFromIso.log`.

## Files in this folder

| File | What it is |
|---|---|
| `Build-HomeUsbFromIso.ps1` | Builds the changed Home image from an ISO file and makes the stick. Erases the stick. |
| `List-HomeImage.ps1` | Lists what is inside `install.wim`. Changes nothing. |
| `remove-list.txt` | Example list of what to take out. |
| `image-settings.txt` | Example list of what to set in the image, and the three part switches. |
| `first-signin\WHD-FirstSignIn.ps1` | The script that runs once at the first sign-in. |
| `first-signin\first-signin-list.txt` | Example list of what that script does. |
| `first-signin\Autounattend.xml` | The answer file; copied into the image as `Windows\Panther\unattend.xml`. |
| `Check-InstalledPc.ps1` | Read-only check of the installed PC against the three lists; writes a report. |
| `SHA256SUMS.txt` | SHA-256 checksums of the files in this folder. |

Files the script creates in the work folder (`install.wim`, `install-source.txt`, `install-custom.wim`,
`install-partial.wim`, the folders `usb-custom`, `mount`, everything with `_old_` in its name, the logs,
`image-contents.txt` and `test-results`) are kept out of Git by `.gitignore`.

## Known problems in this version

- **Used once, on one PC** (see "Read this before you run it"). No Windows has been installed from a stick of
  this build, so it is not known whether Setup starts the first sign-in script. Other sticks and other PCs may
  behave differently at the erase, the format and the start from the stick. In that one run the stick part took
  16 minutes on a USB 3 stick, nearly all of it for the two image pieces.
- The script formats the new partition before it gives it a drive letter. Should Windows still show a window
  "You need to format the disk" while the script works on the stick, close it with Cancel.
- Only an ISO with one image file is tried in the simulated runs: `sources\install.wim` or `install.esd`.
- The stick gets no `sources\ei.cfg`. The sticks used for the two test installs of WHD USB Image had one (edition
  left blank); an install without it has not been tried.
- The stick must have a drive letter before the run. A stick that Windows shows without a letter has to be
  formatted once by hand.
- A stick that Windows calls a fixed drive (some large or "to go" sticks) is refused.
- There is no way back to a plain stick in this folder: make a plain stick with Microsoft's media creation tool.
- The Edge Update services of the example settings are switched on again when Microsoft Edge is updated (seen in
  the test install of WHD USB Image).
- The scripts read DISM's output in English (`/English`) and look for the edition name `Windows 11 Home`
  (`-HomeName` changes it). Install media in other languages is untested.

WHD is an independent project; it is not made, endorsed or supported by Anthropic or Microsoft.
