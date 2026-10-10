> **WHD USB Image** - by **Training1990for2026Systems** - contact: t90018273@gmail.com
> License: [MIT](LICENSE) - Security reports: see [SECURITY.md](SECURITY.md) - Built with Claude by Anthropic.

**Version: USB Image 1.0 preview 2** (2026-10-10) - the install-stick part of WinHardenDebloat (WHD). Still in development.

> **New in preview 2** (since 1.0 preview 1 of 2026-10-07): settings written into the image
> (`image-settings.txt`), "do not bring back" marks for removed apps, a script that runs once at the first
> sign-in (`first-signin`), `-WorkDir` / `-OriginalDir`, a check of the installed PC (`Check-InstalledPc.ps1`).
> The answer file that starts the first sign-in script goes **into the image** instead of onto the stick,
> `Apply-HomeImage.ps1` takes the image files off a fresh stick itself (`-FromStick`), leaves a note on the stick
> (`WHD-USB-Image.txt`), and has no default stick letter any more.
>
> **What has run on a real PC.** One Windows was installed (2026-10-08) from a stick made by the version of
> 2026-10-07: the image held; Windows Setup did **not** start the first sign-in script from the answer file on
> the stick, which is why that file moved into the image. The image-changing part as it is now, with the answer
> file copied into the image, built an image on 2026-10-10 in the ISO build (a fork of this tool that shares
> that code), and a PC starts from the stick it made.
> **What has not:** taking the image files off the stick, the note on the stick, and the changes to
> `Finish-HomeUsb.ps1` and `Check-InstalledPc.ps1`. **No Windows has been installed with the answer file inside
> the image**: whether Setup starts the script from there is not known. See "What the test install showed" and
> "Known problems in this version".

# WHD USB Image

Prepares a **Windows 11 install USB stick** before Windows is installed:

1. It reduces the stick from several editions to **one edition, Windows 11 Home**.
2. It can take bundled apps, optional features, capabilities and services **out of that Home image**, so they are
   not there on the first start.
3. It can write machine-wide settings **into that image** (policies, services, protocols), so the PC comes up
   with them.
4. It can have Windows Setup start **one script at the first sign-in**, for the settings that need a running
   Windows (Microsoft Defender, password rules, NetBIOS, DNS, OneDrive, firewall rules, UAC).

Native and offline. No third-party APIs, no downloads, no web calls. Everything runs on Windows PowerShell 5.1,
DISM and reg.exe, all built into Windows. The Windows image files themselves are Microsoft's and are **not** part of
this branch: you bring your own install stick.

WHD USB Image works before the install. WHD Classic (branch `classic`) and WHD Next (branch `next`) work after it,
on the running Windows.

## Read this before you run it

WHD USB Image changes the install image on your USB stick. It is released under the [MIT License](LICENSE):
**as is, with no warranty**. You run it at your own risk.

- **This is a preview.** It was written for one stick and used for **two real installs on one PC** (Windows 11
  Home): one with only apps, features and two services taken out, one with everything of this version as
  it was on 2026-10-08. Both installs completed. Other sticks, editions, versions and languages are untested.
- **Installing Windows from the stick erases the drive you install to.** Back up everything you cannot lose first.
- **Keep the original image files.** They end up in the folder `original` (the script copies them there, or you
  move them there by hand). They are your only way back to the stick as it was. The scripts never change or
  delete them.
- **Removed apps can come back.** In the first test install, with only the apps taken out, some of them were
  installed again by Windows after the first sign-in. In the second one, with the settings of
  `image-settings.txt` in the image, none of those came back. Use WHD Classic or WHD Next after the install for
  what comes back on your PC.
- **Have your drivers ready.** The example settings switch off Windows' own driver search. The test PC came up
  with 19 devices without a driver, and without a network connection until the Wi-Fi driver was installed by
  hand. Switch the groups `driver-search-off` and `no-drivers-in-updates` off if you want Windows to fetch them.
- **Disabled services have consequences.** The example list switches off the Workstation and Server services. With
  Workstation off the PC cannot open shared folders on other machines; with Server off it cannot share its own
  folders or printers. Take those two lines out of `remove-list.txt` if you need file sharing.
- **`remove-list.txt` is an example**, the list used for the test install. Read it and change it to your own choice.
- **`image-settings.txt` and `first-signin\first-signin-list.txt` are examples too**: a strict lock-down taken from
  the WHD Classic `standard` profile. Read every group before you use them. Among other things they switch off
  SMB file sharing, dial-up and the built-in VPN, Wi-Fi Direct (Mobile hotspot, casting), automatic Windows,
  driver and Store updates, and they delete every Windows Firewall rule at the first sign-in. Switch a group or
  a part off by changing `on` to `off` on its line.
- **Windows Home may not keep to every setting.** Microsoft documents most of the policy values for
  Pro / Enterprise / Education. On Home they do no harm, but only a test install shows which ones hold.
- **WHD Classic and WHD Next do not know about what this branch sets.** Their Undo, Verify and update guard work
  from their own change history. The record of what was set in the image is `C:\Windows\Setup\Scripts\WHD-Image-applied.txt`
  on the installed PC; the first sign-in script writes `C:\ProgramData\WHD-Image\FirstSignIn.log`.
- **The image does not get smaller.** Removing items stops them being installed; the image file keeps its size.
- **Never upload or share the Windows image files** (`*.wim`, `*.swm`, `*.esd`). They are Microsoft's.

## What you need

- A **fresh** Windows 11 install USB stick, as Microsoft's media creation tool makes it: an image with several
  editions, split into pieces (`sources\install.swm`, `sources\install2.swm`, ...). That layout is the tested
  one. `Apply-HomeImage.ps1` also takes a single `sources\install.wim` or `sources\install.esd`; that was only
  tried in simulated runs. `Finish-HomeUsb.ps1` works with split pieces only.
- A Windows PC with Windows PowerShell 5.1, an administrator account, and about 40 GB of free space on an
  **NTFS** drive. DISM cannot open an image in a folder on a FAT32 or exFAT drive.
- A work folder on that PC that holds the files of this branch. The examples use `C:\WHD-USB` for the folder and
  `F:` for the stick. Give the letter of your stick with `-UsbDrive` (one letter) every time.
  `Apply-HomeImage.ps1` has no default letter and stops without it; `Finish-HomeUsb.ps1` looks at `F:` when none
  is given.
- `Apply-HomeImage.ps1` can keep its big work files somewhere else: `-WorkDir <folder>` (the folder must exist, on
  an NTFS drive, not on the stick; use a path without spaces). The scripts, the lists and the log stay where the
  script is. `-OriginalDir <folder>` tells it where the kept original pieces are when they are not in `original` in
  the work folder or next to the script. `Finish-HomeUsb.ps1` knows `-OriginalDir` but not `-WorkDir`;
  `List-HomeImage.ps1` knows neither: it looks next to itself.

## The short way: a fresh stick and one script

1. Make a fresh install stick with Microsoft's media creation tool.
2. Read and change the three lists (step 4 and step 5 below say what is in them).
3. In an administrator Windows PowerShell, in the folder with these files:

```
powershell -ExecutionPolicy Bypass -File .\Apply-HomeImage.ps1 -UsbDrive F
```

When the work folder holds no original image yet, the script copies the image files from the stick into the
folder `original` (checksums compared), makes the Home-only image from them, changes it and puts it on the stick.
It takes the stick's files only when the image on it has **more than one edition** - that is what a fresh stick
looks like. A stick that holds the changed image (it carries the note `WHD-USB-Image.txt`) or a single edition is
never taken as an original.

For the next fresh stick, when older originals are still in the work folder:

```
powershell -ExecutionPolicy Bypass -File .\Apply-HomeImage.ps1 -UsbDrive F -FromStick
```

`-FromStick` renames what was made from the older originals (`original`, `usb`, `usb-max`, `install.wim`,
`install-max.wim` get `_old_<date_time>` in their names; nothing is deleted) and takes the stick's files as the new
originals. Without `-FromStick`, a stick with a several-edition image that is not the kept original makes the
script **stop and ask**: `-FromStick` to build from the stick, `-KeepOriginal` to build from the kept original.

Steps 1 and 2 below are the way by hand, for a stick that should hold the plain Home image and nothing else.

## Step 1 - make the Home-only image (by hand)

Open Windows PowerShell as administrator.

```
cd C:\WHD-USB
dism /Get-WimInfo /WimFile:F:\sources\install.swm
```

Find the entry named exactly `Windows 11 Home` and note its `Index` number. Use it for `N` below.

```
dism /Export-Image /SourceImageFile:F:\sources\install.swm /SWMFile:F:\sources\install*.swm /SourceIndex:N /DestinationImageFile:C:\WHD-USB\install.wim /Compress:max /CheckIntegrity
mkdir C:\WHD-USB\usb
dism /Split-Image /ImageFile:C:\WHD-USB\install.wim /SWMFile:C:\WHD-USB\usb\install.swm /FileSize:3800
mkdir C:\WHD-USB\original
move F:\sources\install*.swm C:\WHD-USB\original\
```

The split is needed because a FAT32 stick cannot hold a file of 4 GB or more. After the last line the stick has no
install image on it until step 2 has run.

## Step 2 - put the Home-only image on the stick

```
powershell -ExecutionPolicy Bypass -File .\Finish-HomeUsb.ps1 -UsbDrive F
```

`Finish-HomeUsb.ps1` copies the pieces from `usb` to `F:\sources`, compares SHA-256 checksums with the source, copies
a file again once when it differs, and checks that the stick reads as one image, `Windows 11 Home`. It writes
`Finish-HomeUsb.log` and ends with a `RESULT:` line. If the pieces do not fit on the stick, it makes a new export
with maximum compression from `original` and uses that.

You can stop here: the stick now installs Windows 11 Home and nothing else.

## Step 3 - see what is inside the image (changes nothing)

```
powershell -ExecutionPolicy Bypass -File .\List-HomeImage.ps1
```

`List-HomeImage.ps1` opens `install.wim` read-only and writes three lists to `image-contents.txt`: the optional
features that are enabled, the capabilities that are installed, and the apps that are set up for every new user.

## Step 4 - change the image

Three list files say what `Apply-HomeImage.ps1` does. Each is plain text, one item per line; a line that starts
with `#` is a comment. The script reads all three before it changes anything and stops on a line it does not
understand.

**`remove-list.txt`** - what is taken out:

```
app:<display name>            a bundled app, by the name in image-contents.txt
feature:<feature name>        an optional feature to switch off
capability:<capability name>  an installed capability to remove, by the name in image-contents.txt
service-off:<service name>    a service to set to "disabled" in the image's registry
```

**`image-settings.txt`** - what is set in the image:

```
part:<name> on|off            machine-settings, removed-app-marks, first-signin
group:<name> on|off           starts a group; the lines below it belong to it
reg:<hive>|<key>|<value name>|<type>|<data>     hive SOFTWARE or SYSTEM, type dword or string
service-off:<service name>
```

- `part:machine-settings` - the groups of this file. Every value is machine-wide (HKEY_LOCAL_MACHINE). A SYSTEM
  key is given below the control set (`Services\...` or `Control\...`).
- `part:removed-app-marks` - for every app the run removes, Windows' own "deprovisioned" mark is written
  (`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\<package family name>`).
  Microsoft: the mark tells Windows not to reinstall that app at a Windows update. In the real run DISM had
  already written all 29 marks itself when it removed the apps, so this part only adds a mark that is missing.
  That also means the marks were in the image of the first test install, where Dev Home, Cross Device and
  Copilot came back all the same: the mark alone does not stop the Store or Edge.
- `part:first-signin` - see step 5.
- The script refuses to switch off the service `WinHttpAutoProxySvc`: with it disabled, Wi-Fi did not come up in
  WHD Classic's tests.

Then:

```
powershell -ExecutionPolicy Bypass -File .\Apply-HomeImage.ps1 -UsbDrive F
```

`Apply-HomeImage.ps1`:

0. takes the image files from a fresh stick into `original` when there is no original yet, or with `-FromStick`
   (see "The short way"), and makes `install.wim` from the original when it is missing (maximum compression;
   the originals are only read),
1. copies `install.wim` to `install-custom.wim` (`install.wim` itself is never changed),
2. opens the copy, removes the listed apps and capabilities, switches the listed features off, sets the listed
   services to disabled, writes the listed registry values and the marks, copies the first sign-in files and
   the answer file into the image, writes the record `Windows\Setup\Scripts\WHD-Image-applied.txt` into it, and
   saves it,
3. splits it into the folder `usb-custom`,
4. replaces the image pieces on the stick with those and compares checksums,
5. writes the note `WHD-USB-Image.txt` on the root of the stick (what the stick holds, with the checksums of the
   pieces), and moves an `Autounattend.xml` of an earlier version of this script off the stick.

It refuses an `install.wim` that it changed before (it finds its own record inside): the changes would be made a
second time on top.

An item that fails is reported and the run goes on. When nothing on the lists could be done, or the image's
registry cannot be opened, the copy is closed without saving and the stick is left as it was. It writes
`Apply-HomeImage.log` (always in the folder of the script) and ends with a `RESULT:` line. It always starts from
the plain `install.wim`, so running it again with shorter lists gives fewer changes.

## Step 5 - the first sign-in script (part first-signin)

Some settings need a running Windows. For those, `Apply-HomeImage.ps1` copies `first-signin\WHD-FirstSignIn.ps1`
and `first-signin\first-signin-list.txt` into the image (`C:\Windows\Setup\Scripts` on the installed PC) and
copies `first-signin\Autounattend.xml` into the image as `Windows\Panther\unattend.xml`.

- **The answer file does one thing**: it tells Windows Setup to start that script once, after the first sign-in of
  the first user (Microsoft Learn: Microsoft-Windows-Shell-Setup, FirstLogonCommands). It answers no Setup
  question; language, edition, disk and account are still asked on screen. It is for a 64-bit (x64) image.
  Microsoft disables the other way to run a script at the end of Setup (`SetupComplete.cmd`) when Windows is
  installed with a manufacturer's (OEM) key, which is why an answer file is used.
- **Why inside the image.** Until 2026-10-08 the answer file was put on the root of the stick. In the test install
  Windows Setup found it there, wrote "does not meet criteria to be used for this unattend pass" into its log
  each time, kept no copy, and never started the script. Microsoft Learn ("Replace the answer file in an offline
  image") names `Windows\Panther\unattend.xml` inside the image as the place where Setup "finds and uses this
  answer file". **This has not been tried in a real install yet.** When the image already has a file there that
  is not ours, the script does not replace it and reports that as a failed item.
- **If Setup does not start the script, start it by hand** (the command is below) - after you have signed in with
  your own account. In the test install it was started from a command window during setup: it then ran as
  Setup's temporary account, so the OneDrive part worked on that account and not on the owner's, and DNS was
  skipped because no network adapter was up. The script now says so in its log when it runs that way.
- **Edit `first-signin-list.txt` before you run `Apply-HomeImage.ps1`.** The copy inside the image is the one used.
  `Apply-HomeImage.ps1` lets the script check its own list first and stops when a line is not understood.
- **What the example list does**, each part with its own `on` / `off` line:

  | Part | What it does |
  |---|---|
  | `defender-pua`, `defender-network-protection`, `defender-folder-protection` | Microsoft Defender: block unwanted apps, network protection = Block, ransomware folder protection = Block |
  | `defender-asr` | the 14 attack-surface rules of the list, each `block`, `audit`, `warn` or `off` |
  | `password-rules` | local password and lockout rules with `net accounts` |
  | `netbios-off` | NetBIOS over TCP/IP off on every adapter |
  | `dns` | the listed DNS servers on every adapter that is up, encrypted (DoH), no fall-back to plain DNS |
  | `onedrive-remove` | takes away the entry that starts the OneDrive install for this user; runs OneDrive's own uninstaller when it is already installed |
  | `firewall` | saves the whole firewall policy, deletes every rule, adds the listed allow rules; default actions are not changed |
  | `uac-always-notify` | UAC "Always notify", as the last step |

- **At the first sign-in a PowerShell window opens and works for several minutes.** Leave it alone: do not close
  it and do not click in it. It closes by itself. Restart the PC once afterwards.
- **Check afterwards:** `C:\ProgramData\WHD-Image\FirstSignIn.log` ends with a `RESULT:` line, and near its top
  it says who started the script: "Started by Windows Setup" or "Started by hand". If the file is not there,
  Setup did not start the script. Start it by hand, in an administrator PowerShell:

  ```
  powershell -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\WHD-FirstSignIn.ps1
  ```

- **Try it without changing anything:** `-Preview` only says what the script would do on the PC it runs on, and
  writes `FirstSignIn-preview.log` next to the script.

  ```
  powershell -ExecutionPolicy Bypass -File .\first-signin\WHD-FirstSignIn.ps1 -Preview
  ```

- **It runs once.** A second start does nothing unless `-Again` is given. Do not use `-Again` after WHD Classic
  has set up the firewall: the firewall part would delete WHD Classic's rules too (it does nothing while outbound
  is set to Block).
- **The firewall part.** The backup is `C:\ProgramData\WHD-Image\firewall-before-first-signin.wfw`. Nothing is
  deleted without it, and when an allow rule cannot be added afterwards the backup is put back. To put
  everything back by hand: `netsh advfirewall import "C:\ProgramData\WHD-Image\firewall-before-first-signin.wfw"`.
  Windows and apps add rules of their own again later.

## Step 6 - after the install: check what holds

On the PC that was installed from the stick, in an administrator PowerShell, from the folder with these files:

```
powershell -ExecutionPolicy Bypass -File .\Check-InstalledPc.ps1
```

`Check-InstalledPc.ps1` only reads. It compares the three lists with the running Windows and writes
`test-results\<date_time>\report.txt`: whether Setup started the first sign-in script (and who started it),
which values and services of the image are still in place, which removed apps came back, what the first sign-in
script set, the firewall rules that Windows and apps added since the wipe, programs, devices without a driver,
the devices of the deny list, and what is in `C:\Windows.old`. When WHD Classic or WHD Next has put its own
firewall rules in place since, the report says so and does not count the script's rules as missing. The report
names the PC's hardware and programs: keep it private (`.gitignore` leaves `test-results` out of Git).

### What the test install showed (2026-10-08, Windows 11 Home, one PC)

- Windows Setup went through with every example group on: the services switched off and the device deny list
  did not disturb it.
- Before the first sign-in: every value, service and feature of the image as set; all 29 removed apps gone.
- Windows Setup did not start the first sign-in script (see step 5). Started by hand it ended with
  `RESULT: DONE`, 23 changes, 0 failed; the firewall part deleted 393 rules in under two minutes.
- After a day online, with WHD Classic and WHD Next used on the PC and updates let through: 82 of 84 values still
  as set (the two others were changed by the owner); the removed apps that came back in the first test (Dev
  Home, Cross Device, Copilot, manufacturer apps) did **not** come back. Which setting did that is not separated.
- **The two Edge Update services were switched on again** after Microsoft Edge was updated: setting them to
  disabled in the image does not hold.
- With driver search off, 19 devices had no driver until drivers were installed (see "Read this before you run it").

### What the WHD Classic `standard` profile does and the example lists do not

Per-user settings (the default-user part was left out on purpose); the per-user half of the app permissions; the
proxy "Automatically detect settings" switch; the update gate and the update guard; the firewall log, the IPv6
block rules, the time-server pin and the rest of the firewall baseline; Windows Time from Cloudflare and IPv6 off
(both are in `image-settings.txt`, switched off); the Edge Update scheduled tasks; the Bluetooth network part;
disabling / removing the Wi-Fi Direct and WAN Miniport devices that are present; the component clean-up; the
question about manufacturer apps. Use WHD Classic on the installed PC for those.

Windows may answer part of the checksum check from memory right after a copy. To be sure, eject the stick, plug it
in again and run:

```
powershell -ExecutionPolicy Bypass -File .\Apply-HomeImage.ps1 -UsbDrive F -CheckOnly
```

That run only reads the stick and compares it with `usb-custom`. It also says whether the note
`WHD-USB-Image.txt` is on the stick, and whether an `Autounattend.xml` is. Give it the same `-WorkDir` as the run
before; the end of the log shows the full line.

The example `remove-list.txt` removes 29 bundled apps (the app list of the WHD Classic `standard` profile),
switches off four features (Work Folders, Internet printing client, Remote Differential Compression, the old
Windows Media Player) and disables two services (Workstation, Server). No capability is removed.

To switch the two services back on in the installed Windows, in an administrator PowerShell:

```
Set-Service LanmanWorkstation -StartupType Automatic
Set-Service LanmanServer -StartupType Automatic
```

Then restart.

## Going back

- **Plain Home on the stick again:** run `Finish-HomeUsb.ps1 -UsbDrive F -ReplaceCustom`. Without `-ReplaceCustom` it stops
  when the stick holds the changed image from `Apply-HomeImage.ps1` and changes nothing: it never replaces the
  changed image without being told to. It knows the changed image by the note `WHD-USB-Image.txt` on the stick,
  by the pieces kept in `usb-custom`, or by an answer file of an earlier version. With the switch it puts the
  plain pieces from `usb` back (when there are none, it says so and makes them again from `original`), and it
  moves the note and such an answer file off the stick into the work folder.
- **The stick as it was:** delete `install.swm`, `install2.swm`, ... from `F:\sources` and copy the files from
  `original` back to `F:\sources`.

## What the scripts keep to

- They work only inside their own folder (and the `-WorkDir` folder), in `<stick>:\sources`, on their own note
  `<stick>:\WHD-USB-Image.txt` and on `<stick>:\Autounattend.xml`. The folder `original` is only read; it is
  written once, when the image files are taken from a fresh stick.
- On the stick they touch only files named `install*.swm`, `install*.wim` or `install*.esd`, the note
  `WHD-USB-Image.txt`, and an `Autounattend.xml` that an earlier version of `Apply-HomeImage.ps1` put on the
  root (it names the first sign-in script; it is moved into the work folder, not deleted). An image file is
  removed from the stick only when a copy with the same name and the same size is kept on the PC; any other one
  is moved into the work folder, not deleted. An `Autounattend.xml` that is not from these scripts is left
  where it is.
- Nothing in the work folder is deleted. Older work files are renamed (names with `_old_`, and `from-usb_*`).
  They are several GB each: delete them by hand once the stick has installed Windows correctly.
- `Apply-HomeImage.ps1` refuses a work folder or an `-OriginalDir` on the stick itself, and a work folder that is
  not on an NTFS drive.
- They refuse a drive that is not a removable drive, and a stick without `sources\boot.wim`.
- Everything they do is written to a log in the work folder.

## Files in this branch

| File | What it is |
|---|---|
| `Finish-HomeUsb.ps1` | Puts the plain Home-only pieces on the stick and checks them. Stops when the stick holds the changed image, unless `-ReplaceCustom` is given. |
| `List-HomeImage.ps1` | Lists what is inside the Home-only image. Changes nothing. |
| `Apply-HomeImage.ps1` | Applies the lists to a copy of the image and puts the result on the stick. |
| `remove-list.txt` | Example list of what to take out. |
| `image-settings.txt` | Example list of what to set in the image, and the three part switches. |
| `first-signin\WHD-FirstSignIn.ps1` | The script that runs once at the first sign-in. |
| `first-signin\first-signin-list.txt` | Example list of what that script does. |
| `first-signin\Autounattend.xml` | The answer file that makes Windows Setup start that script. It is copied into the image as `Windows\Panther\unattend.xml`. |
| `Check-InstalledPc.ps1` | Read-only check of the installed PC against the three lists; writes a report. |
| `SHA256SUMS.txt` | SHA-256 checksums of the files in this branch. |

Files the steps create in the work folder (`install.wim`, `install-custom.wim`, `install-partial.wim`, the folders
`original`, `usb`, `usb-custom`, `mount`, `from-usb_*`, everything with `_old_` in its name, the logs,
`image-contents.txt` and `test-results`) are kept out of Git by `.gitignore`.

## Known problems in this version

- **Not run on a real PC yet:** taking the image files off the stick (`-FromStick`, `-KeepOriginal`), the note
  on the stick, the changes to `Finish-HomeUsb.ps1` and to `Check-InstalledPc.ps1`. They were checked with the
  PowerShell parser and with simulated runs against stand-ins for DISM, reg.exe and the drive commands. Also
  never run on a real PC: `-WorkDir`, capability removal, a stick with a single `install.wim` / `install.esd`.
  (Copying the answer file into the image has run on a real PC, in the ISO build; an install from such an image
  has not been made.)
- **Not known: whether Windows Setup starts the first sign-in script from the answer file inside the image.**
  From the answer file on the stick it did not. Until a real install shows it, expect to start the script by
  hand after the first sign-in (step 5).
- The Edge Update services (`edge-update-services-off`) are switched on again when Microsoft Edge is updated.
- Not known: which of the policy values Windows Home keeps to over time, and which of them kept the removed apps
  from coming back in the second test install.
- The app-permission group `permissions-switches-off` sets the PC-wide camera, microphone, radios and location
  switches to Deny while Windows Setup runs. A camera sign-in (Windows Hello) offered during setup may not work
  until the switch is turned on in Settings.
- OneDrive: the first sign-in script stops the install for the account it runs as only. A second user account
  gets OneDrive again.
- With the example settings Windows does not fetch drivers. A PC without a built-in driver for its network
  adapter has no network until that driver is installed by hand.
- `Finish-HomeUsb.ps1` supports only split originals (`original\install.swm`) and does not know `-WorkDir`;
  `List-HomeImage.ps1` does not know `-WorkDir` either. `Finish-HomeUsb.ps1` has run on a real PC only in its
  first version (before `-ReplaceCustom`, `-OriginalDir` and the note).
- The part of `Finish-HomeUsb.ps1` that makes a maximum-compression export when the pieces do not fit has never run.
- In the test, the Home-only image came out larger than the multi-edition image it was taken from. The reason is
  not known. It installs as it is.
- The scripts read DISM's output in English (`/English`) and look for the edition name `Windows 11 Home`
  (`-HomeName` changes it). Install media in other languages is untested.
- The stick used in the tests also had a `sources\ei.cfg` with the edition left blank. The scripts do not create,
  need or change that file; an install from a stick without it has not been tried.

WHD is an independent project; it is not made, endorsed or supported by Anthropic or Microsoft.
