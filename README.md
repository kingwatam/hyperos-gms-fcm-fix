# HyperOS GMS FCM Fix

Diagnose and repair Xiaomi HyperOS freezing Google Play services, from PowerShell over ADB.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)](https://learn.microsoft.com/powershell/)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20macOS-lightgrey.svg)](#)

No root. No unlocked bootloader. No Shizuku. No APK on the phone.

| Approach | Root | Unlocked bootloader | Shizuku | APK on phone |
|---|:---:|:---:|:---:|:---:|
| This script | ❌ | ❌ | ❌ | ❌ |
| App using Shizuku | ❌ | ❌ | ✅ | ✅ |
| Root via Magisk | ✅ | ✅ | ❌ | ❌ |

This matters if you use banking apps, or anything else that checks bootloader
state. Rooting needs an unlocked bootloader, and unlocking wipes the device.

Targets official China ROM, HyperOS 3, Android 16 (API 36), on Xiaomi, Redmi and
POCO devices. It is a script you run from your own PC, and it reads state
without changing anything until you pass a write switch.

Installing or uninstalling an app, or changing a battery setting, drops the
no-restrictions entry, because PowerKeeper rebuilds that list from its own
database. The predownload gate below is not rebuilt and survives it. Reboots and
app updates leave both alone. Nothing watches for the entry disappearing, so you
find out when notifications stop arriving. See [Limitations](#limitations).

## Why

HyperOS freezes background apps to save power, and a frozen process cannot hold
a socket open. When Google Play services is frozen its connection to Google's
push servers drops, and nothing arrives until something thaws it.

Two separate settings carry an exemption from that freeze. Neither is offered in
the user interface for Play services, because the battery policy screen hides
itself for any package without a launcher icon, and Play services is one of them.

- `MILLET_NO_RESTRICT_APP`, the list Greezer checks before its quick-freeze and
  `PowerStrategyMode` paths
- `com.miui.game.allowlist`, a lower gate checked before any freeze is applied,
  with no nighttime restriction

The second of those is the one doing the work. With the first entry absent and the
second present, Play services logged no freeze events at all across the 38 hours
after the entry was dropped, while Greezer logged about 1,500 freeze events for
other packages over the same span. An earlier short test gave the opposite result,
eight events in six minutes with only the second gate populated, but the Greezer
limiter was in an unusual state during it, which is why it needed repeating. Whether
the first entry works on its own is untested.

Symptoms:

- notifications do not arrive until you unlock the phone
- Google 2FA prompts need Play services restarted before they show up
- WhatsApp or Messenger seem to need opening before new messages appear
- toggling Developer options > System optimization appears to help

That last one looks like a fix but is not. Play services thaws on screen-on and
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

### Why the entry keeps disappearing

PowerKeeper rebuilds `MILLET_NO_RESTRICT_APP` from its own database and replaces
the whole string. It selects rows whose policy is literally `noRestrict`.

Play services has a row, but its policy is `miuiAuto`, which is what the
scenario compiler assigns to a package the system already reports as ignoring
battery optimisation. PowerKeeper has a helper, `isNoRestrict()`, that treats
that value as unrestricted, and the code that builds the published list does not
call it. The same package is therefore unrestricted in one code path and excluded
in another.

That inconsistency is the underlying defect. The entry cannot be created through
any supported route, so it has to be written from outside, and PowerKeeper
discards it on the next rebuild.

### Measured on a Xiaomi 14, HyperOS 3, Android 16

With both exemption lists cleared and the Greezer limiter at its factory value,
over roughly eight and a half hours of ordinary use:

```
GMS freeze events       45
frozenTime              23,399 s
activeTime              30,523 s
frozen share            77%
```

With the repair applied, no freeze events at all over the same period of use.
Toggling the repair off and on again inside a single session reproduced both
halves of that comparison on the same phone minutes apart.

### One remedy that does not work

Setting Google Gboard as the default keyboard is widely recommended for this,
and was measured here over the same eight and a half hours. Play services froze
77% of the time with Gboard as the default IME, thawing only on screen-on, an
activity resume, a provider query, a sync binder call or a service start. Not
one thaw in nine hours referenced the input method.

If you want to try it, the test is simple and needs no tooling. Take a
notification while the phone is face down and untouched. If it arrives, the
keyboard is doing something. If it only ever arrives while you are holding the
phone, screen-on is thawing Play services as it always did.

## What it does

- reports whether Play services is present in both exemption lists
- reports Greezer freeze events for Play services since boot
- reports whether the FCM socket is established on port 5228
- adds Play services to both lists without disturbing entries already there
- sends a thaw and a reconnect broadcast, since restoring an exemption does not
  unfreeze a process that is already frozen
- applies the `MILLET_NO_RESTRICT_APP` exemption to any other package you name
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

To reverse a repair, including the Greezer limiter flag that `-Repair` changes:

```powershell
powershell -ExecutionPolicy Bypass -File .\hyperos-gms-fcm-fix.ps1 -Undo
```

## Options

| Switch | Effect |
|---|---|
| *(none)* | Status report. Writes nothing. |
| `-Repair` | Exempt Play services at both gates, disable the Greezer GMS limiter, send a thaw |
| `-CheckFreeze` | Count Play services freeze events since boot |
| `-AddPackage <pkg>` | Add other packages to `MILLET_NO_RESTRICT_APP` |
| `-RemovePackage <pkg>` | Remove packages. Use to undo. |
| `-ListCandidates` | List third-party packages you can pass to `-AddPackage` |
| `-Watch` | Repeat the report until interrupted, `-Seconds N` to set the interval |
| `-Serial <id>` | Which device to use. Detected automatically for wireless duplicates. |
| `-KeepShellWrite` | Leave the `WRITE_SETTINGS` grant in place after writing |
| `-AllowEmptyList` | Allow writing when the list reads back empty |
| `-Undo` | Reverse a repair, including the Greezer limiter flag |
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

The repair runs these steps:

1. Grants `WRITE_SETTINGS` to `com.android.shell`. Android 16 dropped this from
   the shell defaults, and without it every `Settings.System` write fails with
   `SecurityException`. The script confirms the permission works using a
   throwaway key before touching anything real, and sets it back to `ignore`
   afterwards so the grant exists only while a repair runs. Pass
   `-KeepShellWrite` to leave it in place.
2. Reads `MILLET_NO_RESTRICT_APP` and appends `com.google.android.gms` for user
   0, keeping every entry already there. Only user 0 is written, because Greezer
   resolves the list from that profile. The value is stored comma-separated
   without spaces, since a value containing `", "` reaches the device shell as
   two arguments and `settings` rejects it.
3. Appends `com.google.android.gms` to `com.miui.game.allowlist` for user 0,
   underscore-separated. Only Play services is managed there. The key belongs to
   the game predownload components, so it is not a list to add arbitrary
   packages to.
4. Runs `dumpsys greezer IM GMS disable` and `dumpsys greezer LM add`. Both are
   runtime state and reset on reboot. Treat them as belt and braces.
5. Sends `com.xiaomi.mipush.REFRESH_WHITE_LIST_ACTION`, which thaws the target
   uid and needs no permission, then a `GCM_RECONNECT` broadcast. Order matters,
   since asking a frozen process for its socket back does nothing.

Every write is idempotent.

### Not overwriting the list by accident

PowerKeeper rebuilds the list by replacing the whole string, and that rebuild is
not atomic from the outside. A read landing in the middle of one comes back
empty. Appending to that and writing it back would replace every other
no-restrictions package with a single entry, silently.

A repair therefore retries an empty read three times, falls back to the last
copy it saved, and stops with a message rather than guess. The saved copy is
written beside the script as `hyperos-gms-fcm-fix.lastgood` during a repair only,
so a read-only run still changes nothing. It names the packages installed on
your phone, so the repository ignores it. `-AllowEmptyList` overrides the stop
for anyone whose list really is empty.

## Limitations

**A frozen Play services is not the only reason a notification does not arrive.**
This is the part worth being straight about.

Keeping Play services unfixed keeps the socket up and the queue drains. It does
not control whether the broadcast then reaches the app that should show it.
`GreezeManagerService.isRestrictReceiver` consults a broadcast allowlist that
defaults to almost nothing, and the restricted branch runs without thawing the
target. The result is a frozen app reporting no response to a broadcast that
arrived on time.

That allowlist lives in `Settings.Global aurogon_enable`, and on the device this
was built against it cannot be written at all:

```
$ adb shell settings --user 0 put global aurogon_enable broadcastctrl:false
java.lang.SecurityException: Permission denial, must have one of:
 [android.permission.WRITE_SECURE_SETTINGS]
```

`com.android.shell` holds `WRITE_SECURE_SETTINGS` and the write is still denied,
and it is not an AppOps operation, so there is no way to grant it. Reaching this
key needs root or a privileged app. If notifications still do not arrive once
`-CheckFreeze` reports no freezes, that is the likely reason, and this script
cannot address it.

**Changing a battery setting, or installing an app, drops the fix.**

PowerKeeper treats the list as generated output from its private per-app
database, and rebuilds the whole thing whenever a policy row changes. The entry
this script adds is not in that database, so it is discarded along with
everything else.

Confirmed on a Xiaomi 14, HyperOS 3, Android 16: installing one app took the
list from nine entries to eight, dropped `com.google.android.gms`, and Play
services was frozen twice within minutes. `com.android.vending` survived the same
rebuild, because it is present in PowerKeeper's database. Only shell-added entries
are lost.

Uninstalling an app did the same, nine entries to eight again. Updating one did not.
A Play Store update went through the full replace path and left the entry in place,
with the freeze counters unchanged.

The rebuild is a write to PowerKeeper's own policy row. What decides it is whether
that row changes:

Measured on one device on one build. Package handling can differ on another
build, so check it on yours.

| Action | Effect on the no-restrictions entry | Basis |
|---|---|---|
| Installing an app | drops it | measured |
| Uninstalling an app | drops it | measured |
| Changing an app's Battery saver setting | drops it | measured |
| Updating an app | survives | measured, one update |
| Reboot | survives | measured |
| First launch of an app, which can promote a policy row | drops it | from the code |
| OTA | unknown | not tested |

Updates are the one worth explaining, because Play Store updates are routine and
the platform does broadcast `PACKAGE_ADDED` for them as well as for an install.
PowerKeeper's manifest does not listen for it. Nothing writes the row, so no
rebuild follows.

So run `-Repair` after installing or removing anything, or after changing a
battery setting, to put the projection entry back. You may not need to. The
predownload gate survives the same events, and on this build it held Play services
unfrozen for 38 hours on its own.

`com.miui.game.allowlist` is not managed by PowerKeeper, so it does not get
dropped the same way. Two components do rewrite it, SecurityCenter and Joyose,
for game predownload, and each clears the whole value on stop, error or timeout.

`-AddPackage` is not a general app fixer. Exemption from Greezer is one of
several gates. It does not override MIUI per-app battery policy, AOSP Doze, or
Aurogon broadcast control.

**HyperOS 4 changes this.** On HyperOS 4, which runs Android 17, a policy runs
from 23:00 to 07:59 during deep idle that treats no-restriction packages as
freeze candidates. `MILLET_NO_RESTRICT_APP` does not protect against it, so on
that build an entry there does not stop a night freeze even when present. The
freeze reason reads `nightDoze` rather than the usual one.
`com.miui.game.allowlist` has no nighttime predicate and does hold.

Xiaomi can change any of this. The setting names and the Greezer code paths that
read them are vendor internals, not public API.

`-Watch` needs the PC tethered, so it is a diagnostic aid rather than a
replacement for a watchdog app.

## Alternatives

An app applies the same fix and keeps it watched with no PC attached:

- [dingwen07/hyperos-fcm-fix](https://github.com/dingwen07/hyperos-fcm-fix)
  runs on Shizuku, and also handles per-app Aurogon, autostart and auto-unstop

You get unattended repair across reboots, and a background app gains system
settings access. This script trades that for having to notice when the fix lapses
and re-run it yourself.

An app using only `WRITE_SETTINGS` has to aim below target SDK 22, because
`SettingsProvider` refuses writes to OEM-added keys from any app with a modern
target SDK and the write throws rather than failing quietly. Android 14 and later
refuse such an app by default, but the installer accepts
`adb install --bypass-low-target-sdk-block`, confirmed on this build, so both
requirements can be met with one command on a tethered PC.
[ReedGAOOO/FCMGuard-HyperOS](https://github.com/ReedGAOOO/FCMGuard-HyperOS) takes
that route: open source, no `INTERNET` permission, and shipped as a debug-signed
build. It watches the no-restrictions entry only, so on this build it covers one
of the two gates.

## Credits

The mechanism, the reverse engineering, and the identification of
`MILLET_NO_RESTRICT_APP` as the exemption that matters come from
[dingwen07's investigation](https://github.com/dingwen07/hyperos-fcm-fix/blob/main/docs/xiaomi-hyperos-gms-fcm-greezer-investigation.md)
and the
[rewrite investigation](https://github.com/dingwen07/hyperos-fcm-fix/blob/main/docs/xiaomi-millet-no-restrict-app-rewrite-investigation.md).
The second freeze gate and the thaw broadcast come from the
[HyperOS 4 nighttime investigation](https://github.com/dingwen07/hyperos-fcm-fix/blob/main/docs/xiaomi-hyperos4-nighttime-fcm-investigation.md).
No source was copied from those projects.

Findings here that go beyond them:

- Android 16 no longer grants `com.android.shell` `WRITE_SETTINGS` by default,
  which breaks the shell route they document.
- The list value has to be comma-separated without spaces.
- `Settings.Global` writes are refused for `com.android.shell` even though it
  holds the permission, which closes off the Aurogon broadcast route.
- `MILLET_NO_RESTRICT_APP` cannot be read reliably enough to append to, because
  the rebuild is not atomic from the outside.