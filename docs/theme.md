# WHD Next - the optional theme

"An old ship, held together by its crew and its AI."

The theme is an extra. It is not part of any profile, Verify and the update guard do not watch it, and nothing
else in WHD Next depends on it. Everything it sets belongs to the Windows user WHD Next runs as.

- Menu version: main menu `X. Theme (optional)`.
- Window version (`Start-WHD.ps1 -Gui`): tab "Theme" - the same items as buttons.

Like every change in WHD Next, the items below preview only (DRY-RUN) until EXECUTE is switched on, ask before
they change anything, and write one line each into the change history. In the Undo center they show as "manual"
with a hint, because the way back is the matching "put back" item of the theme menu.

## The items

| Key | What it does | Put back with |
|---|---|---|
| `A` | Everything on, one question: makes the sound files if they are missing, then `3`, `7`, `9` and last `5` (which needs your click in Settings). | `Z` |
| `Z` | Everything put back, one question: `10`, `8`, `4` and last `6` (click in Settings). An item that is not on is passed over. | `A` |
| `1` | Makes 20 sound files (.wav). No Windows setting is changed. | - (files stay) |
| `2` | Plays them. `2 lock` plays one, `2 ?` lists the names. Changes nothing. | - |
| `3` | Windows sound scheme "WHD Next": 21 everyday Windows sounds become the WHD sounds. Works at once. | `4` |
| `5` | The look: the pictures as a desktop slide show (a new one every 30 minutes, shuffled), dark mode for Windows and apps, accent colour sky blue - also on Start, the taskbar and window title bars. | `6` |
| `5R` | The same look with hot rod red instead of sky blue. | `6` |
| `7` | Lock screen and sign-in screen show the WHD pictures; a new one is chosen at every sign-in and unlock. | `8` |
| `9` | A sound at sign-in, lock and unlock - and, when Windows lets it, at sign-out and shut-down / restart. | `10` |

## Sounds (1 - 4)

- The 20 sounds are made on your PC by `tools\New-WHDThemeSounds.ps1` - plain arithmetic written to .wav files
  (one channel, 22,050 samples a second, 16 bit). They are tuned for small laptop speakers. Nothing is downloaded.
- Place: `C:\ProgramData\WinHardenDebloatNext\theme\sounds`.
- `3` adds the scheme "WHD Next" under `HKEY_CURRENT_USER\AppEvents\Schemes` and makes it the scheme in use:
  notification, message, mail, reminder, error, warning, information, beep, device in / out / failed,
  administrator prompt, battery low / critical, nearby device. Every other event keeps what the Windows default
  scheme has for it: silent ones stay silent, alarm and ring loops stay Windows' own.
- Before the first change every event's sound in use is written to
  `...\theme\state\sound-scheme-before_<user>.json`. `4` puts exactly that back and takes "WHD Next" out of
  Windows' list. Windows' own Sound window can also switch schemes at any time.

## The look (5, 5R, 6)

- WHD Next writes two theme files into your own theme folder (`%LOCALAPPDATA%\Microsoft\Windows\Themes`):
  `WHD Next.theme` (sky blue) and `WHD Next (red).theme` (hot rod red). Both are the theme you had before with only
  these parts replaced: name, desktop picture, slide show, dark mode, accent colour. Mouse pointers, desktop
  icons and the sounds stay as they are.
- Windows lists themes in Settings > Personalization > Themes. **Windows 11 does not switch by itself: you
  click the theme there.** WHD opens the Settings window, names the theme to click, and waits for you.
  (If the other colour is not in the list yet, choose it once with `5` / `5R`; after that both are there.)
- **The colour never changes by itself.** Windows has no documented way for a program to change the accent
  colour, so there is no automatic swap. To change between sky blue and hot rod red: `5` / `5R`, or a click on the
  other theme in Settings.
- After Windows has applied a theme it may show it as "Unsaved theme" and offer "Save". That is Windows' own
  behaviour; saving is not needed - and it is better left alone, see "Known oddity" below.
- "Accent colour on Start, taskbar and title bars" is not part of a theme file. WHD sets two values of your
  account for it (`ColorPrevalence`, see "Values Microsoft does not document"). What was there before is saved and
  `6` puts it back.
- A theme can reset sounds. WHD notes every sound before Windows applies the theme and puts back any that changed.
- `6` puts the theme you had before into the list as "Before WHD Next" (or names Windows' own theme when that was
  the one in use) and asks for the click. The note of "before" is in `...\theme\state\look-before_<user>.json`
  with a copy of the old theme file beside it; it is not overwritten while the WHD look is on.

### Known oddity: "Save" in Settings changes the accent colour

Seen on Windows 11 Home 26H2 (October 2026); the cause is not known, and nothing in WHD Next sets that colour.

- After the look is on, Settings > Personalization > Themes shows it as "Unsaved theme" with a "Save" button.
- When "Save" is pressed, Windows writes a theme file of its own into your theme folder. It gives it the same
  display name, so the list then has a second "WHD Next" (file `WHD Next (2).theme`, with a new id and the slide
  show stored in Windows' own way).
- With that, **the accent colour on Start, taskbar and title bars turns from sky blue into a blue-gray.** The file
  Windows wrote holds `ColorizationColor=0XC4506773`; WHD's own file has `0XC440A4FF`. WHD's two theme files are
  not changed by this.
- What to do: leave the theme "unsaved". If it was saved: `5` (or `5R`) puts WHD's own theme on again, which has
  the right colour. The extra entry can be removed in Settings with right-click > Delete; WHD Next deletes nothing.
- While such a saved copy is the theme in use, WHD Next still shows the look as "in use" but cannot tell which
  colour is on; `5` / `5R` then ask for the click as usual and say so in the log.

### Your own pictures

- `5` asks before it makes `C:\ProgramData\WinHardenDebloatNext\theme\my-pictures`, opens it and waits.
  Kinds: .jpg .jpeg .png .bmp. Names in plain English letters, digits, spaces, `-` and `_`.
- Your account gets "modify" permission on **that one folder only**, so copying into it does not ask for the
  administrator prompt. No other folder is opened up. A folder or file that is a link to another place is not
  followed.
- WHD copies your pictures into its slide-show folder (`...\theme\pictures`, as `my-<name>`); your files stay
  where you put them. A picture the slide show already has is shown once.
- Choose `5` again after adding pictures. `A` (everything on) uses the folder as it is and does not wait.

### The 24 pictures

- 8 open space, 8 hull, 8 bridge; 1920 x 1080. They ship in `theme\pictures` of the program folder.
- All 24 are original. They were drawn by the project's own script from arithmetic (noise, stars, lit spheres,
  plates and panels) - no photograph, film still or outside picture is in them, and nothing from any film or
  series was used or imitated. The drawing script is not part of the program folder.
- Each picture carries a caption along its top edge saying where it came from:
  `Created with Claude by Anthropic (https://claude.ai) on <date and time> Hawaii time at the request of <project e-mail>`.
- The picture files may also hold a signed "content credentials" record added when they were delivered. It does
  not change the picture.

## Lock screen and sign-in screen (7, 8)

- The screen with the clock at power-on, restart and lock is the lock screen. Windows shows the same picture
  behind the sign-in box when Settings > Personalization > Lock screen > "Show the lock screen background picture
  on the sign-in screen" is on (Windows has it on unless it was changed).
- Windows' own call for setting that picture exists in Windows PowerShell 5.1 only. So a small helper,
  `tools\Invoke-WHDThemeEvent.ps1`, is copied to `C:\ProgramData\WinHardenDebloatNext\theme\` and started by three
  scheduled tasks under `\WinHardenDebloatNext\` - `ThemeSignIn`, `ThemeLock`, `ThemeUnlock` - as you, **without
  administrator rights**. A window may flash for a moment when they run.
- At sign-in and at unlock the helper picks another picture (not the last one). The lock screen is already
  showing when the PC is locked, so the new picture is the one you see at the *next* lock, restart or power-on.
- If Windows spotlight is on for the lock screen, choose "Picture" once in Settings > Personalization > Lock
  screen. WHD does not switch that setting.
- `7` runs the helper once before it adds the tasks. If Windows refuses the picture, nothing is added and the item
  reports FAILED.
- `8` stops it and gives Windows the picture from before, when that file still exists.

## Sounds at sign-in, lock, unlock, sign-out and shut-down (9, 10)

- Windows no longer has a setting for these sounds. The same helper plays them, started by scheduled tasks.
- Sign-in, lock and unlock use the three tasks above.
- **Sign-out and shut-down / restart have no task trigger in Windows.** Two more tasks, `ThemeSignOut` and
  `ThemeShutDown`, are started by a line Windows writes into its System event log: the sign-out notice (source
  Winlogon, number 7002) and "shut-down / restart was started" (source User32, number 1074).
  **Windows is closing programs at that moment, so these two sounds may be cut short or not be heard at all.**
- At shut-down only the shut-down sound plays; the sign-out that is part of a shut-down stays silent.
- `9` looks once (read-only) whether your Windows has written those two lines before and says what it found.
- On a PC with several accounts signed in at once, the sign-out line of another account can start your sign-out
  sound. The tasks only run while you are signed in.
- `10` switches all five sounds off. The three shared tasks stay while the lock-screen pictures (`7`) use them.

What is switched on is kept in your own folder, `%LOCALAPPDATA%\WinHardenDebloatNext\theme\events.json`. The
helper writes one line per run to `events.log` in the same folder (kept under 100 KB) - the place to look when a
sound or picture did not come.

## Where everything is

| Place | What |
|---|---|
| `<program folder>\theme\pictures` | the 24 pictures as shipped |
| `<program folder>\tools\New-WHDThemeSounds.ps1` | the sound generator |
| `<program folder>\tools\Invoke-WHDThemeEvent.ps1` | the helper as shipped |
| `C:\ProgramData\WinHardenDebloatNext\theme\sounds` | the 20 sound files |
| `C:\ProgramData\WinHardenDebloatNext\theme\pictures` | the slide-show / lock-screen pictures (WHD's + copies of yours) |
| `C:\ProgramData\WinHardenDebloatNext\theme\my-pictures` | your own pictures |
| `C:\ProgramData\WinHardenDebloatNext\theme\state` | the notes of "before" (sound scheme, look, lock screen) |
| `C:\ProgramData\WinHardenDebloatNext\theme\Invoke-WHDThemeEvent.ps1` | the helper the tasks start |
| `%LOCALAPPDATA%\Microsoft\Windows\Themes` | `WHD Next.theme`, `WHD Next (red).theme`, `Before WHD Next.theme` |
| `%LOCALAPPDATA%\WinHardenDebloatNext\theme` | `events.json`, `events.log` |
| Task Scheduler `\WinHardenDebloatNext\` | `ThemeSignIn`, `ThemeLock`, `ThemeUnlock`, `ThemeSignOut`, `ThemeShutDown` |

**WHD Next deletes nothing.** "Put back" switches things off and restores what was there; files stay, so the item
can be used again. To remove the files for good, put everything back (`Z`) and then delete the `theme` folders
above yourself; old theme entries are removed in Settings > Personalization > Themes with right-click > Delete.

## What the theme never does

- No policy, nothing under `HKEY_LOCAL_MACHINE`, no service, no download, no program from anywhere else.
- No task with administrator rights.
- Nothing for other user accounts.
- Nothing by itself: no colour swap, no timed change other than Windows' own slide show.

## Values Microsoft does not document

Used because Windows offers no documented way for these:

- **Set** (and put back exactly): `ColorPrevalence` under
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize` (accent on Start and taskbar) and under
  `HKCU\Software\Microsoft\Windows\DWM` (accent on title bars and window borders).
- **Written into the theme file**: `SystemMode=Dark`, `AppMode=Dark`. They are not on Microsoft's "Theme File
  Format" page; Windows' own `dark.theme` uses them.
- **Read only**: `RotatingLockScreenEnabled` (is Windows spotlight on for the lock screen), to give the hint above.

A Windows update may change what these do. If the look stops working after an update, `6` still puts the saved
theme back.

## Tested and not tested

Run on Windows 11 Home 26H2 (October 2026): the sound scheme, the look with the click in Settings, the red look
(`5R`), lock-screen pictures, sounds at sign-in / lock / unlock, "everything on" (`A`) and "everything put back"
(`Z`). `9` found both event-log lines on that Windows (sign-out: Winlogon 7002; shut-down / restart: User32 1074),
and the five tasks were accepted.

**Not yet confirmed on Windows** when this was written: that the sign-out and shut-down sounds are actually heard,
and the Theme tab of the window version on screen. The project's own checks cover their logic with stand-ins for
Windows; what Windows itself does with them shows on the PC.

One oddity is known and not explained: see "Known oddity" under "The look".
