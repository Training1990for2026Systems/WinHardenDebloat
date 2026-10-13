# The lists

All lists are plain text, one item per line; a line that starts with `#` is a comment. They are **examples**:
the author's choices for the test install. Change them in the menu (step 3) or in any text editor before you build.

| File | Line types | Read by |
|---|---|---|
| `lists\remove-list.txt` | `app:<display name>`, `feature:<feature name>`, `capability:<capability name>`, `service-off:<service>` | menu step 4, `tools\Build-HomeUsbFromIso.ps1`, `tools\Apply-HomeImage.ps1`, `Check-InstalledPc.ps1` |
| `lists\image-settings.txt` | `part:<name> on/off`, `group:<name> on/off`, `reg:<hive>\|<key>\|<value>\|<type>\|<data>`, `service-off:<service>` | the same |
| `lists\ai-list.txt` | `ai:<package family name> on/off` | menu steps 2, 3, 5; `Check-InstalledPc.ps1` |
| `drivers-list.txt` (made by step 2, private) | `driver:<folder> on/off` | menu step 4, `tools\Build-HomeUsbFromIso.ps1` |
| `first-signin\first-signin-list.txt` | `part:<name> on/off`, `asr:`, `password:`, `dns:`, `doh:`, `fw-allow:`, `ai-block:<family>` | `WHD-FirstSignIn.ps1` on the installed PC |

When the menu switches an app, feature or capability off, the line becomes `# app:X (off - menu)`; switched on
again, it becomes active again. On/off lines are changed in place; comments stay.

`ai-block:` lines are written by the menu from `lists\ai-list.txt` (step 4 and step 5): the first sign-in part
`ai-recheck` writes the deprovisioned mark again when it is missing and removes a package that came back.

## What the WHD Classic `standard` profile does and the example lists do not

Per-user settings; the per-user half of the app permissions; the proxy "Automatically detect settings" switch; the
update gate and the update guard; the firewall log, the IPv6 block rules, the time-server pin and the rest of the
firewall baseline; the Edge Update scheduled tasks; the Bluetooth network part; disabling the Wi-Fi Direct and WAN
Miniport devices that are present; the component clean-up; the question about manufacturer apps. Use WHD Classic or
WHD Next on the installed PC for those.

## Things the example lists switch off that you may want

- **File sharing**: `service-off:LanmanWorkstation` and `LanmanServer` in `remove-list.txt`, group `smb-off`.
- **Driver downloads**: groups `driver-search-off` and `no-drivers-in-updates` - have your drivers ready (the menu
  puts the building PC's drivers into the image).
- **Updates**: `windows-update-no-auto`, `store-auto-update-off` - installing updates is then up to you.
- **VPN / dial-up / Mobile hotspot / casting**: `dialup-vpn-off`, `wifi-direct-off`, `wan-miniports-off`.
- **The firewall** (first sign-in part `firewall`): every rule is deleted and a short allow-list added.
