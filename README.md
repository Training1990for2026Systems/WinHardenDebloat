> **WHD USB Image** - by **Training1990for2026Systems** - contact: t90018273@gmail.com
> License: [MIT](LICENSE) - Security reports: see [SECURITY.md](SECURITY.md) - Built with Claude by Anthropic.

**Version: USB Image 1.0 preview 1** (2026-10-07) - the install-stick part of WinHardenDebloat (WHD). Still in development.

# WHD USB Image

Prepares a **Windows 11 install USB stick** before Windows is installed:

1. It reduces the stick from several editions to **one edition, Windows 11 Home**.
2. It can take bundled apps, optional features and services **out of that Home image**, so they are not there on
   the first start.

Native and offline. No third-party APIs, no downloads, no web calls. Everything runs on Windows PowerShell 5.1,
DISM and reg.exe, all built into Windows. The Windows image files themselves are Microsoft's and are **not** part of
this branch: you bring your own install stick.

WHD USB Image works before the install. WHD Classic (branch `classic`) and WHD Next (branch `next`) work after it,
on the running Windows.

## Read this before you run it

WHD USB Image changes the install image on your USB stick. It is released under the [MIT License](LICENSE):
**as is, with no warranty**. You run it at your own risk.

- **This is a preview.** It was written for one stick and used for **one real install on one PC** (Windows 11 Home).
  That install completed; the one problem seen is "Some removed apps come back" below. Other sticks, editions, versions and
  languages are untested.
- **Installing Windows from the stick erases the drive you install to.** Back up everything you cannot lose first.
- **Keep the original image files.** The steps below move them off the stick into the folder `original`. They are
  your only way back to the stick as it was. The scripts never change or delete them.
- **Some removed apps come back.** In the test install, some of the apps removed from the image were installed
  again by Windows after the first sign-in. Removing them from the image does not stop that. Use WHD Classic or
  WHD Next after the install for what comes back.
- **Disabled services have consequences.** The example list switches off the Workstation and Server services. With
  Workstation off the PC cannot open shared folders on other machines; with Server off it cannot share its own
  folders or printers. Take those two lines out of `remove-list.txt` if you need file sharing.
- **`remove-list.txt` is an example**, the list used for the test install. Read it and change it to your own choice.
- **The image does not get smaller.** Removing items stops them being installed; the image file keeps its size.
- **Never upload or share the Windows image files** (`*.wim`, `*.swm`, `*.esd`). They are Microsoft's.

## What you need

- A Windows 11 install USB stick whose image is split into pieces: `sources\install.swm`, `sources\install2.swm`, ...
  The scripts expect this layout. A stick with a single `install.wim` or `install.esd` needs the hand steps adapted
  and is untested.
- A Windows PC with Windows PowerShell 5.1, an administrator account, and about 40 GB of free space.
- A work folder on that PC that holds the files of this branch. The examples use `C:\WHD-USB` for the folder and
  `F:` for the stick. `Finish-HomeUsb.ps1` and `Apply-HomeImage.ps1` take `-UsbDrive` (one letter) when your stick has
  another letter.

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
powershell -ExecutionPolicy Bypass -File .\Finish-HomeUsb.ps1
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

## Step 4 - take things out of the image

Edit `remove-list.txt`. One item per line:

```
app:<display name>            a bundled app, by the name in image-contents.txt
feature:<feature name>        an optional feature to switch off
service-off:<service name>    a service to set to "disabled" in the image's registry
```

Then:

```
powershell -ExecutionPolicy Bypass -File .\Apply-HomeImage.ps1
```

`Apply-HomeImage.ps1`:

1. copies `install.wim` to `install-custom.wim` (`install.wim` itself is never changed),
2. opens the copy, removes the listed apps, switches the listed features off, sets the listed services to disabled,
   and saves it,
3. splits it into the folder `usb-custom`,
4. replaces the image pieces on the stick with those and compares checksums.

An item that fails is reported and the run goes on. When nothing on the list could be done, the copy is closed
without saving and the stick is left as it was. It writes `Apply-HomeImage.log` and ends with a `RESULT:` line.
It always starts from the plain `install.wim`, so running it again with a shorter list gives fewer removals.

Windows may answer part of the checksum check from memory right after a copy. To be sure, eject the stick, plug it
in again and run:

```
powershell -ExecutionPolicy Bypass -File .\Apply-HomeImage.ps1 -CheckOnly
```

That run only reads the stick and compares it with `usb-custom`.

The example list removes 29 bundled apps (the app list of the WHD Classic `standard` profile plus Bing News and
Bing Weather), switches off four features (Work Folders, Internet printing client, Remote Differential Compression,
the old Windows Media Player) and disables two services (Workstation, Server). Capabilities are not touched.

To switch the two services back on in the installed Windows, in an administrator PowerShell:

```
Set-Service LanmanWorkstation -StartupType Automatic
Set-Service LanmanServer -StartupType Automatic
```

Then restart.

## Going back

- **Plain Home on the stick again:** run `Finish-HomeUsb.ps1`. It puts the pieces from `usb` back.
- **The stick as it was:** delete `install.swm`, `install2.swm`, ... from `F:\sources` and copy the files from
  `original` back to `F:\sources`.

## What the scripts keep to

- They work only inside their own folder and in `<stick>:\sources`.
- On the stick they touch only files named `install*.swm`, `install*.wim` or `install*.esd`. Such a file is removed
  from the stick only when a copy with the same name and the same size is kept in the work folder. Any other one is
  moved into the work folder, not deleted.
- Nothing in the work folder is deleted. Older work files are renamed.
- They refuse a drive that is not a removable drive, and a stick without `sources\boot.wim`.
- Everything they do is written to a log in the work folder.

## Files in this branch

| File | What it is |
|---|---|
| `Finish-HomeUsb.ps1` | Puts the plain Home-only pieces on the stick and checks them. |
| `List-HomeImage.ps1` | Lists what is inside the Home-only image. Changes nothing. |
| `Apply-HomeImage.ps1` | Applies `remove-list.txt` to a copy of the image and puts the result on the stick. |
| `remove-list.txt` | Example list of what to take out. |
| `SHA256SUMS.txt` | SHA-256 checksums of the files in this branch. |

Files the steps create in the work folder (`install.wim`, `install-custom.wim`, the folders `original`, `usb`,
`usb-custom`, `mount`, the logs and `image-contents.txt`) are kept out of Git by `.gitignore`.

## Known problems in this version

- Some apps removed from the image are installed again by Windows after the first sign-in. Which ones was not
  recorded in the test.
- Only the split layout (`install.swm`) is supported. `Finish-HomeUsb.ps1` and `Apply-HomeImage.ps1` stop when
  `original\install.swm` is missing.
- Step 1 is done by hand; there is no script for it yet.
- The part of `Finish-HomeUsb.ps1` that makes a maximum-compression export when the pieces do not fit has never run.
- In the test, the Home-only image came out larger than the multi-edition image it was taken from. The reason is
  not known. It installs as it is.
- The scripts read DISM's output in English (`/English`) and look for the edition name `Windows 11 Home`
  (`-HomeName` changes it). Install media in other languages is untested.
- The stick used in the test also had a `sources\ei.cfg` with the edition left blank. The scripts do not create,
  need or change that file.

WHD is an independent project; it is not made, endorsed or supported by Anthropic or Microsoft.
