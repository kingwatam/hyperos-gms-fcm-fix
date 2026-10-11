# HyperOS GMS FCM Fix

Diagnose and repair Xiaomi HyperOS freezing Google Play services, from PowerShell over ADB.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)](https://learn.microsoft.com/powershell/)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20macOS-lightgrey.svg)](#)

No root. No unlocked bootloader. No Shizuku. No APK on the phone.

| Approach | Root | Unlocked bootloader | Shizuku | APK on phone |
|---|:---:|:---:|:---:|:---:|
| This script | ❌ | ❌ | ❌ | ❌ |
| App using `WRITE_SETTINGS` | ❌ | ❌ | ❌ | ✅ |
| App using Shizuku | ❌ | ❌ | ✅ | ✅ |
| Root via Magisk | ✅ | ✅ | ❌ | ❌ |

This matters if you use banking apps, or anything else that checks bootloader
state. Rooting needs an unlocked bootloader, and unlocking wipes the device.

Targets official China ROM, HyperOS 3, Android 16 (API 36), on Xiaomi, Redmi
and POCO devices. It is a script you run from your own PC, and it reads state
without changing anything until you pass a write switch.

## Why

Xiaomi's PowerKeeper publishes a list of apps exempt from freezing to
`Settings.System MILLET_NO_RESTRICT_APP`. Greezer checks that list before it
freezes a process, and a frozen process cannot hold a socket open.

`com.google.android.gms` is usually missing from the list. Play services gets
frozen once the screen goes off, the FCM connection drops, and push
notifications stop arriving until you unlock the phone.

Play Store membership does not help. The list is per package, so having
`com.android.vending` on it says nothing about `com.google.android.gms`.

Symptoms:

- notifications arrive minutes or hours late, or only after unlocking
- Google 2FA prompts need Play services restarted before they show up
- WhatsApp or Messenger seem to need opening before new messages appear
- toggling Developer options > System optimization appears to help

That last one looks like a fix but is not. The app thaws on screen-on and
freezes again seconds later, so toggling makes the cycle visible.
`dumpsys greezer` shows `screen on` dominating the thaw reasons.

### Why the usual advice does not help

The common fix is a set of ADB commands granting `WAKE_LOCK` and
`RUN_ANY_IN_BACKGROUND` AppOps and adding Play services to the AOSP Doze
whitelist.

Those control AOSP Doze and AppOps. Greezer runs its own cgroup freezer,
separate from both. On affected devices Play services is already in the Doze
whitelist as `system` and `system-excidle` and gets frozen anyway.
`am unfreeze --sticky` does not override it either.

Check before applying them:

```powershell
adb shell dumpsys deviceidle whitelist | Select-String gms
adb shell cmd appops get com.google.android.gms | Select-String "RUN_ANY_IN_BACKGROUND"
```

If both already report what you want, those commands have nothing left to do.

## What it does

- reports whether Play services is missing from the no-restrictions list
- reports Greezer freeze events for Play services since boot
- reports whether the FCM socket is established on port 5228
- adds Play services to the list without disturbing entries already there
- applies the same exemption to any other package you name
- read-only by default

## Quick start

Needs [platform-tools](https://developer.android.com/tools/releases/platform-tools) on
`PATH`, and USB debugging enabled under Developer options. Cross-platform:
Windows PowerShell 5.1 or later, and PowerShell 7 on Linux and macOS. Untested
on Linux and macOS so far.

The first time you plug the phone in, Android shows an **Allow USB debugging**
dialog on screen with an RSA fingerprint. Tap **Allow USB debugging**, and tick
**Always allow from this computer** if you want to skip it later. Until you do,
`adb devices` lists the phone as `unauthorized` and this script stops with a
message.

```powershell
git clone https://github.com/kingwatam/hyperos-gms-fcm-fix
cd hyperos-gms-fcm-fix
```

Run it with no arguments for a status report:

```powershell
powershell -ExecutionPolicy Bypass -File .\hyperos-gms-fcm-fix.ps1
```

To apply the repair:

```powershell
powershell -ExecutionPolicy Bypass -File .\hyperos-gms-fcm-fix.ps1 -Repair
```

Then lock the phone for about ten minutes, unlock, and check whether Play
services froze while it was off:

```powershell
powershell -ExecutionPolicy Bypass -File .\hyperos-gms-fcm-fix.ps1 -CheckFreeze
```

## Options

| Switch | Effect |
|---|---|
| *(none)* | Status report. Writes nothing. |
| `-Repair` | Add `com.google.android.gms` and disable the Greezer GMS limiter |
| `-CheckFreeze` | Count Play services freeze events since boot |
| `-AddPackage <pkg>` | Add other packages, e.g. `-AddPackage com.whatsapp` |
| `-RemovePackage <pkg>` | Remove packages. Use to undo. |
| `-ListCandidates` | List third-party packages you can pass to `-AddPackage` |
| `-Watch` | Repeat the report until interrupted, `-Seconds N` to set the interval |
| `-Serial <id>` | Which device to use. Detected automatically for wireless duplicates. |
| `-KeepShellWrite` | Leave the `WRITE_SETTINGS` grant in place after writing |
| `-Help` | Full parameter reference |

`-Repair` and `-AddPackage` can be combined in one pass:

```powershell
powershell -ExecutionPolicy Bypass -File .\hyperos-gms-fcm-fix.ps1 -Repair -AddPackage com.whatsapp
```

To see what you can add, list the installed third-party packages and which of
them are already in the list:

```powershell
powershell -ExecutionPolicy Bypass -File .\hyperos-gms-fcm-fix.ps1 -ListCandidates
```

## How it works

The repair runs three steps:

1. Grants `WRITE_SETTINGS` to `com.android.shell`. Android 16 dropped this from
   the shell defaults, and without it every `Settings.System` write fails with
   `SecurityException`. The script confirms the permission works using a
   throwaway key before touching anything real, and sets it back to `ignore`
   afterwards so the grant exists only while a repair runs. Pass
   `-KeepShellWrite` to leave it in place.
2. Appends `com.google.android.gms` to `MILLET_NO_RESTRICT_APP` for user 0,
   keeping every entry already there. Only user 0 is written, because Greezer
   resolves the list from that profile.
3. Runs `dumpsys greezer IM GMS disable`. The flag resets on reboot, so treat it
   as belt and braces rather than the fix itself.

Writes are idempotent, and the list is rewritten comma-separated without
spaces. A value containing `", "` reaches the device shell as two separate
arguments and `settings` rejects it.

## Limits

**Changing any app's battery setting drops the fix.** This is the main thing
to know, and it is not obvious.

PowerKeeper treats the list as generated output from its private per-app
database, and rebuilds the whole thing whenever a policy row changes. The entry
this script adds is not in that database, so it is discarded along with
everything else. Any of these triggers a rebuild:

- changing an app's Battery saver setting in the HyperOS UI
- installing or removing an app
- first launch of an app
- boot reconciliation, which can also happen after an OTA

So after you touch battery settings, run `-Repair` again. The list itself
survives reboots, which is verified, and PowerKeeper does not rewrite it on
every boot. But this is a papercut, not a background service: nothing watches
for the entry disappearing, so you find out when notifications stop arriving.

This is a repair tool, not a daemon. Re-run `-Repair` when notifications start
lagging, after changing any battery setting, or use one of the alternatives
below to keep it watched.

`-AddPackage` is not a general app fixer. Exemption from Greezer is one of
several gates. It does not override MIUI per-app battery policy, AOSP Doze, or
Aurogon broadcast control.

Xiaomi can change any of this. The setting name and the Greezer code paths that
read it are vendor internals, not public API.

`-Watch` needs the PC tethered, so it is a diagnostic aid rather than a
replacement for a watchdog app.

## Alternatives

Two apps apply the same fix and keep it watched with no PC attached:

- [dingwen07/hyperos-fcm-fix](https://github.com/dingwen07/hyperos-fcm-fix)
  runs on Shizuku, and also handles per-app Aurogon, autostart and auto-unstop
- [ReedGAOOO/FCMGuard-HyperOS](https://github.com/ReedGAOOO/FCMGuard-HyperOS)
  needs no Shizuku, only `WRITE_SETTINGS`

Each installs an APK and runs continuously. You get unattended repair across
reboots, and a background app gains system settings access. This script trades
that for having to notice when the fix lapses and re-run it yourself.

FCM Guard targets API 22, and Android 14 and later refuse to install apps below
that. On Android 16 you need
`adb install --bypass-low-target-sdk-block FCMGuard-HyperOS.apk` before it will
run, so it is not as unattended as it looks.

## Credits

The mechanism, the reverse engineering, and the identification of
`MILLET_NO_RESTRICT_APP` as the exemption that matters come from
[dingwen07's investigation](https://github.com/dingwen07/hyperos-fcm-fix/blob/main/docs/xiaomi-hyperos-gms-fcm-greezer-investigation.md)
and the
[rewrite investigation](https://github.com/dingwen07/hyperos-fcm-fix/blob/main/docs/xiaomi-millet-no-restrict-app-rewrite-investigation.md).
No source was copied from either project.

Two findings here go beyond those documents. Android 16 no longer grants
`com.android.shell` `WRITE_SETTINGS` by default, which breaks the shell route
they document. And the list value has to be comma-separated without spaces.