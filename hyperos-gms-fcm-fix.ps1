<#
.SYNOPSIS
    Report and repair Xiaomi HyperOS freezing Google Play services.

.DESCRIPTION
    HyperOS freezes Google Play services, and a frozen process cannot hold a
    socket open, so push notifications stop arriving until something thaws it.
    Two settings carry an exemption from that freeze and this script keeps both
    of them correct:

      MILLET_NO_RESTRICT_APP    the list Greezer checks before its quick-freeze
                                and PowerStrategyMode paths. PowerKeeper owns
                                it, rebuilds it from its own database, and
                                drops entries this script adds.
      com.miui.game.allowlist   a lower gate, checked by preCheckInterest, with
                                no nighttime predicate. PowerKeeper does not
                                manage it. Game predownload components do, and
                                they rewrite the whole string.

    Both hold package names for user 0, comma-separated and underscore-separated
    respectively.

    Scope: official China ROM, HyperOS 3, Android 16 (API 36), Xiaomi / Redmi /
    POCO. Needs adb from Android SDK platform-tools on PATH and USB debugging
    enabled in Developer options. The first time you plug the phone in, Android
    shows an "Allow USB debugging" dialog with an RSA fingerprint; tap "Allow
    USB debugging". Until you do, adb reports the phone as unauthorized.

    Read-only unless a write switch is passed. Writes are idempotent and keep
    every list entry already present. A repair also saves the list it reads to a
    file beside this script, so that a read landing in the middle of a
    PowerKeeper rebuild cannot be mistaken for an empty list and overwrite the
    rest of it.

    Typical sequence:
      1. no switch        see current state, change nothing
      2. -Repair          exempt GMS at both gates, disable the Greezer limiter
      3. lock ~10 min, unlock
      4. -CheckFreeze      confirm GMS was not frozen while the screen was off
    Repeat step 2 when push starts lagging: PowerKeeper rebuilds the list from
    its own database and drops entries without warning.

    -AddPackage and -RemovePackage use the MILLET list on any package. That
    exempts an app from Greezer freezing only. It does not override MIUI battery
    policy, AOSP Doze, or Aurogon broadcast control.

    Findings: https://github.com/dingwen07/hyperos-fcm-fix

.PARAMETER Menu
    Interactive menu covering every action below. Each choice runs and then the
    menu comes back, until you quit. Modifiers such as -Serial, -KeepShellWrite
    and -AllowEmptyList can be passed alongside it and apply to the whole session.

.PARAMETER Repair
    Put com.google.android.gms in both freeze exemption lists if it is missing,
    run "dumpsys greezer IM GMS disable" and "dumpsys greezer LM add", then send
    a thaw and a reconnect broadcast. All steps are idempotent.

.PARAMETER CheckFreeze
    Count GMS freeze events logged since boot. Run after locking the phone for
    ten minutes and unlocking. Read-only.

.PARAMETER AddPackage
    Add packages to MILLET_NO_RESTRICT_APP, e.g. -AddPackage com.whatsapp.
    Can be combined with -Repair.

.PARAMETER RemovePackage
    Remove packages from MILLET_NO_RESTRICT_APP. Use to undo this tool.

.PARAMETER ListCandidates
    List third-party packages that can be passed to -AddPackage, split into
    those already in the no-restrictions list and those not. Read-only.

.PARAMETER Watch
    Repeat the read-only report until interrupted. Diagnostic aid only: it needs
    the PC tethered, so it is not a substitute for a watchdog app.

.PARAMETER Seconds
    Interval between reports under -Watch. Default 5.

.PARAMETER Serial
    Which attached device to use, as shown by "adb devices". Required when more
    than one is attached, which happens when wireless debugging registers the
    same phone twice. Detected automatically when they are duplicates.

.PARAMETER KeepShellWrite
    Leave the WRITE_SETTINGS grant in place after a write operation. By default
    it is revoked, so the privilege exists only while a repair runs.

.PARAMETER AllowEmptyList
    Write to the list even when it reads back empty three times and no saved
    copy exists. Without this a repair stops rather than risk replacing every
    other entry. Only needed on a phone whose list really is empty.

.PARAMETER Undo
    Reverse a repair. Removes com.google.android.gms from both lists and
    returns "dumpsys greezer IM GMS enable" to its factory value, which
    -RemovePackage alone does not do. The Aurogon allowlist entry a repair adds
    has no documented reverse verb; it is runtime-only and clears on reboot.

.EXAMPLE
    .\hyperos-gms-fcm-fix.ps1
    Status report. Writes nothing.

.EXAMPLE
    .\hyperos-gms-fcm-fix.ps1 -Repair
    Apply the repair, then print the resulting state.

.EXAMPLE
    .\hyperos-gms-fcm-fix.ps1 -CheckFreeze
    Was GMS frozen during the last screen-off period?

.EXAMPLE
    .\hyperos-gms-fcm-fix.ps1 -Repair -AddPackage com.whatsapp
    Repair GMS and exempt another app in one pass.

.EXAMPLE
    .\hyperos-gms-fcm-fix.ps1 -Menu
    Pick actions from a menu instead of typing a switch each time.

.EXAMPLE
    .\hyperos-gms-fcm-fix.ps1 -RemovePackage com.google.android.gms
    Undo the GMS entry.
#>

[CmdletBinding()]
param(
    [switch]$Menu,
    [switch]$Repair,
    [switch]$CheckFreeze,
    [string[]]$AddPackage,
    [string[]]$RemovePackage,
    [switch]$ListCandidates,
    [switch]$Watch,
    [int]$Seconds = 5,
    [string]$Serial,
    [switch]$KeepShellWrite,
    [switch]$AllowEmptyList,
    [switch]$Undo,
    [switch]$Help
)

if ($Help) { Get-Help $PSCommandPath -Detailed; exit }

$SettingsKey = "MILLET_NO_RESTRICT_APP"
# Second, independent freeze gate. Checked by GreezeManagerService.preCheckInterest
# through AurogonImmobulusMode.isGameAllowListApp, below both the Aurogon quick-freeze
# path and PowerStrategyMode that MILLET covers, and with no nighttime predicate.
# PowerKeeper does not write it. SecurityCenter and Joyose do, for game predownload,
# and they rewrite the whole string.
$GameKey     = "com.miui.game.allowlist"
# Java String.split("_"), so an underscore cannot appear in a package name and
# trailing separators are dropped on read.
$GameSep     = "_"
$DefaultPkg  = "com.google.android.gms"
$ProbeKey    = "hyperos_gms_fcm_fix_probe"
$StateFile   = "hyperos-gms-fcm-fix.lastgood"
$User        = 0

# How to invoke this script here, for the hints it prints. $IsWindows is absent
# on Windows PowerShell 5.1, so the edition check covers that case too.
$self = if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
    ".\hyperos-gms-fcm-fix.ps1"
} else {
    "./hyperos-gms-fcm-fix.ps1"
}

# Last known-good copy of the no-restrictions list. See Get-SafeEntries for why
# this exists. Written only during a repair, so a read-only run still creates
# nothing and the promise in the help text holds.
$statePath = if ($PSScriptRoot) {
    Join-Path $PSScriptRoot $StateFile
} else {
    Join-Path ([System.IO.Path]::GetTempPath()) $StateFile
}

function Head($t) { Write-Host "`n$t" -ForegroundColor Cyan }
function Row($k, $v) { Write-Host ("  {0,-26}: {1}" -f $k, $v) }
function Ok($t)   { Write-Host "  [ OK ] $t" -ForegroundColor Green }
function Warn($t) { Write-Host "  [WARN] $t" -ForegroundColor Yellow }
function Bad($t)  { Write-Host "  [FAIL] $t" -ForegroundColor Red }
function Note($t) { Write-Host "  $t" -ForegroundColor DarkGray }

# Splatted as a variable, not a function call. PowerShell does not splat
# @function(), so the -s argument would be dropped silently.
$adbArgs = @()
if ($Serial) { $adbArgs = @("-s", $Serial) }

# Sh returns an array of lines, not one joined string. Piping a single
# Out-String blob into Select-String misparses multi-line output: MatchInfo.Line
# then reports the wrong text, which is how "mGmsLimitEnabled" once printed as
# "Settings:".
#
# The empty array on the left of the pipe is not decoration. Without it adb
# inherits this script's stdin and swallows it, so the interactive menu loses
# whatever the user typed. Confirmed: with a plain adb call, a piped answer to
# Read-Host came back empty; with @() | adb it came back intact.
function Sh($cmd) { @(@() | adb @adbArgs shell $cmd 2>$null) }
function ShText($cmd) { ((Sh $cmd) -join "`n").Trim() }

# greezer output is ~60 KB, which survives the pipe, but writing it to disk
# keeps -CheckFreeze independent of console width and pipe buffering.
function Sh-ToFile($cmd, $path) { @() | adb @adbArgs shell $cmd > $path }

function Get-Setting($name) { ShText "settings --user $User get system $name" }

# Normalise a package list from a parameter. Wrapping an unset parameter in @()
# still yields one $null element, so .Trim() would be called on null. The
# string cast handles that before any method is invoked.
function PkgList($values) {
    @($values | Where-Object { $null -ne $_ } |
        ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne "" })
}

# pm list packages -U returns the uid directly. Parsing "userId=" out of
# dumpsys package does not work: for com.google.android.gms that dump is about
# 2 MB of Activity Resolver Table and the per-package block never reaches the
# client, so the pattern matches nothing.
#   package:com.google.android.gms uid:<owner>,<clone profile>
# The first uid is the owner; the rest are other profiles.
function Get-PkgUid($pkg) {
    $m = Sh "pm list packages -U $pkg" |
        Select-String -SimpleMatch "package:$pkg " | Select-Object -First 1
    if (-not $m) { return $null }
    return ($m.Line -split "uid:")[1].Split(",")[0].Trim()
}

# Greezer and PowerKeeper both split on "," and trim, so whitespace in the
# stored value is never significant.
function Get-Entries {
    $raw = Get-Setting $SettingsKey
    if (-not $raw -or $raw -eq "null") { return @() }
    @(($raw -split ",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}

function Save-State($entries) {
    if (-not $entries -or $entries.Count -eq 0) { return }
    try { $entries | Set-Content -Path $statePath -Encoding utf8 } catch { }
}

function Read-State {
    if (-not (Test-Path $statePath)) { return @() }
    @(Get-Content $statePath -ErrorAction SilentlyContinue |
        ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne "" })
}

# The list read for writing is not trusted to be complete.
#
# PowerKeeper rebuilds the whole string from its own database, and the rebuild is
# not atomic from the outside. A read that lands during one returns empty or
# null. Appending GMS to that and writing it back replaces every other
# no-restrictions package the user had with a single entry, silently.
#
# Three defences: retry, because most rebuilds finish inside a few hundred ms;
# fall back to the last known-good copy; and refuse to write at all rather than
# guess. A genuinely empty list is almost never what anyone wants, so this costs
# nothing in practice and -AllowEmptyList is there for the rare case.
function Get-SafeEntries {
    for ($i = 0; $i -lt 3; $i++) {
        $entries = Get-Entries
        if ($entries.Count -gt 0) { return $entries }
        if ($i -lt 2) { Start-Sleep -Milliseconds 400 }
    }

    $cached = Read-State
    if ($cached.Count -gt 0) {
        Warn "list read back empty three times. Using the saved copy ($($cached.Count) entries)."
        Note "A read during a PowerKeeper rebuild can come back empty."
        return $cached
    }

    if ($AllowEmptyList) {
        Warn "list is empty and no saved copy exists. Writing anyway, as asked."
        return @()
    }

    Bad "the list read back empty three times and there is no saved copy."
    Note "PowerKeeper was probably rebuilding it. Nothing has been changed."
    Note "Re-run in a moment. If it keeps happening, pass -AllowEmptyList"
    Note "to write anyway, which will leave the list holding only what you add."
    exit 1
}

# Writing an empty value needs the quotes to survive the trip. adb joins the
# arguments and the device shell drops a trailing empty one, so
# "put system KEY " arrives as "put system KEY" and is rejected. The write then
# silently leaves the old value in place while the caller reports success, which
# is how removing the last entry used to do nothing at all.
function Set-Setting($key, $value) {
    if ($value -eq "") {
        Sh ('settings --user {0} put system {1} ''""''' -f $User, $key) | Out-Null
    } else {
        Sh "settings --user $User put system $key $value" | Out-Null
    }
}

# Second freeze gate. Separate namespace, separate separator, separate owner, so
# it needs its own parse and join rather than a shared helper.
function Get-GameEntries {
    $raw = Get-Setting $GameKey
    if (-not $raw -or $raw -eq "null") { return @() }
    @(($raw -split "_") | Where-Object { $_ -ne "" })
}

function Set-GameEntries($entries) {
    Set-Setting $GameKey (($entries | Select-Object -Unique) -join $GameSep)
    return Get-GameEntries
}

# The only thaw vector found that needs no permission and beats Greezer. The
# receiver is exported with no receiver permission, and it thaws the target uid
# before it looks at the option value, so -1 changes no MiPush membership.
function Send-Thaw($pkg) {
    Sh "am broadcast --user $User -a com.xiaomi.mipush.REFRESH_WHITE_LIST_ACTION -p android --es pkgName $pkg --ei option -1" | Out-Null
}

# Restoring an exemption does not thaw a process that is already frozen. Order
# matters: thaw, then ask for the socket back.
function Send-Reconnect($pkg) {
    Sh "am broadcast --user $User -a com.google.android.intent.action.GCM_RECONNECT -p $pkg" | Out-Null
}

# Android 16 no longer grants com.android.shell WRITE_SETTINGS by default.
# Without it every Settings.System write fails with SecurityException.
function Enable-ShellWrite {
    Sh "appops set com.android.shell WRITE_SETTINGS allow" | Out-Null
    Sh "pm grant com.android.shell android.permission.WRITE_SETTINGS" | Out-Null

    # Prove it rather than assume, using a throwaway key.
    Sh "settings --user $User put system $ProbeKey ok" | Out-Null
    $back = Get-Setting $ProbeKey
    Sh "settings --user $User delete system $ProbeKey" | Out-Null
    return ($back -eq "ok")
}

# Drop the grant once the writes are done, so the privilege exists only for the
# duration of a repair. Enable-ShellWrite restores it on the next run, and the
# probe there fails loudly if the revoke left the state inconsistent.
function Revoke-ShellWrite {
    # Only the AppOp is effective. "pm revoke" needs REVOKE_RUNTIME_PERMISSIONS,
    # which adb shell does not hold on Android 16: it throws
    # "Neither user 2000 nor current process has ... REVOKE_RUNTIME_PERMISSIONS"
    # and changes nothing. Setting the AppOp to ignore is what blocks the write,
    # confirmed by a direct settings put failing with SecurityException after.
    Sh "appops set com.android.shell WRITE_SETTINGS ignore" | Out-Null
}

# Written comma-separated without spaces. The device shell splits arguments on
# spaces, so a value containing ", " arrives as two arguments and settings
# rejects it with "Bad arguments".
function Set-Entries($entries) {
    Set-Setting $SettingsKey (($entries | Select-Object -Unique) -join ",")
    return Get-Entries
}

function Get-GmsUid { Get-PkgUid $DefaultPkg }

# Third-party packages worth passing to -AddPackage. Vendor and framework
# packages are dropped; com.google.* is kept, since those are often the ones
# with delayed push.
function Get-Candidates {
    @(Sh "pm list packages -3 --user $User" |
        ForEach-Object { ($_ -replace '^package:', '').Trim() } |
        Where-Object { $_ -ne "" -and $_ -notmatch '^(com\.miui\.|com\.xiaomi\.|com\.android\.|android\.)' } |
        Sort-Object -Unique)
}

function Show-Candidates {
    $cands   = Get-Candidates
    $entries = Get-Entries
    $already = @($cands | Where-Object { $entries -contains $_ })
    $todo    = @($cands | Where-Object { $entries -notcontains $_ })

    Head "CANDIDATE PACKAGES  ($($cands.Count) third-party, vendor packages excluded)"
    if ($already.Count) {
        Write-Host "  already in the list ($($already.Count)):"
        $already | ForEach-Object { Note "    $_" }
    }
    if ($todo.Count) {
        Write-Host "  not in the list ($($todo.Count)):"
        $todo | ForEach-Object { Note "    $_" }
    }
    Write-Host ""
    Note "Add one with:  -AddPackage <name>"
}

function Show-Status {
    $entries = Get-Entries
    if ($entries.Count -gt 0) { Save-State $entries }

    Head "NO-RESTRICTIONS LIST  ($($entries.Count) entries)"
    $entries | ForEach-Object { Note "    $_" }
    $miss = @()
    if ($entries -notcontains $DefaultPkg) { $miss += $DefaultPkg }
    foreach ($p in (PkgList $AddPackage)) { if ($entries -notcontains $p) { $miss += $p } }
    if ($miss.Count -eq 0) { Ok "all target packages present" }
    else { Bad "missing: $($miss -join ', ')" }
    if ($entries.Count -eq 0) {
        Warn "list is empty. A repair will refuse to write over this unless"
        Note "-AllowEmptyList is passed."
    }

    $game = Get-GameEntries

    # One dumpsys call feeds both readings, so a large output is fetched once.
    $greezer = Sh "dumpsys greezer"

    $mLimiter = $greezer | Select-String -SimpleMatch "mGmsLimitEnabled" | Select-Object -First 1
    Row "Greezer GMS limiter" $(if ($mLimiter) { $mLimiter.Line.Trim() } else { "not reported by this build" })

    $uid = Get-GmsUid
    $fz  = @(Split-SinceBoot @($greezer | Select-String -SimpleMatch "FZ uid = $uid "))
    Row "GMS freezes, this boot" "$($fz.Count)"
    if ($fz.Count) {
        # The count is cumulative for this boot, so it still includes freezes
        # that happened before the current repair landed. Saying "run -Undo"
        # to someone who just ran -Repair would be nonsense.
        if ($entries -contains $DefaultPkg) {
            Note "may predate the current repair. Lock the phone, then re-check."
        } else {
            Warn "GMS is not exempted. Run -Repair."
        }
    }

    $sock = @(Sh "cat /proc/net/tcp /proc/net/tcp6" | Select-String ":146[CDE]")
    if ($sock.Count) {
        if (@($sock | Where-Object { $_.Line -match "\s01\s" }).Count) { Ok "FCM socket established" }
        else { Warn "FCM port present but not established" }
    } else { Warn "no FCM socket (screen off, or GMS frozen)" }

    Head "PREDOWNLOAD EXEMPTION  ($GameKey)"
    if ($game.Count) { $game | ForEach-Object { Note "    $_" } }
    else { Note "    (absent on this build)" }
    if ($game -contains $DefaultPkg) { Ok "Play services exempt from the lower freeze gate" }
    else { Bad "Play services missing from $GameKey" }
}

# Greezer's history is a file on the device, not a per-boot counter. It
# survives a reboot and keeps accumulating, so a raw count is lifetime history
# and not what "did it freeze since I last rebooted" means. /proc/uptime gives
# how long the phone has been up; combined with the device clock that gives the
# boot instant to filter against.
function Get-BootTime {
    $now = ShText "date +%s"
    if ($now -notmatch '^\d+$') { return $null }
    $up = ShText "cat /proc/uptime"
    if ($up -notmatch '^([\d.]+)') { return $null }
    return [long]$now - [long][double]$Matches[1]
}

function Split-SinceBoot($matches) {
    $boot = Get-BootTime
    if ($null -eq $boot) { return , $matches }
    $cut = ([DateTimeOffset]::FromUnixTimeSeconds($boot)).DateTime
    @($matches | Where-Object {
        # Accepts Select-String MatchInfo or a plain line, so the same filter
        # works whether the text came from a file or from a live adb call.
        $line = if ($_ -is [string]) { $_ } else { $_.Line }
        if ($line.Length -lt 19) { return $true }
        $ts = [datetime]::MinValue
        if ([datetime]::TryParse($line.Substring(0, 19), [ref]$ts)) { $ts -ge $cut }
        else { $true }
    })
}

function Show-FreezeCheck {
    Head "FREEZE CHECK"
    $uid = Get-GmsUid
    if (-not $uid) { Bad "GMS not found."; return }

    $f = Join-Path ([System.IO.Path]::GetTempPath()) "greezer_gms_check.txt"
    Sh-ToFile "dumpsys greezer" $f
    $allEvents = @(Select-String -Path $f -Pattern "FZ uid")

    $events = Split-SinceBoot @(Select-String -Path $f -Pattern "FZ uid = $uid ")
    $total  = Split-SinceBoot $allEvents
    $lifetime = @($allEvents | Where-Object { $_.Line -match "FZ uid = $uid " }).Count

    Row "freezes, this boot (all packages)" $total.Count
    Row "freezes, this boot (GMS)"          $events.Count
    Row "freezes, lifetime (GMS)"           $lifetime

    if ($events.Count -eq 0) {
        Ok "GMS has not been frozen since boot."
    } else {
        Bad "GMS was frozen this boot:"
        $events | Select-Object -Last 5 | ForEach-Object { Note "  $_" }
    }
}

# Read-only report plus what to do next. Shared by the no-switch run and by the
# menu, so both give the same advice.
function Show-StatusAndNext {
    Show-Status
    Head "NEXT"
    Note "Read-only run. Nothing was changed."
    if ((Get-Entries) -notcontains $DefaultPkg) {
        Note "To fix:  $self -Repair"
    }
}

function Invoke-Watch([int]$Every = 5) {
    Head "WATCH MODE - Ctrl+C to stop"
    Note "Read-only. Needs the PC tethered, so this is a diagnostic aid rather"
    Note "than a permanent fix. For continuous protection use a Shizuku app."
    while ($true) {
        Show-Status
        Write-Host ("`n  -- {0} - Ctrl+C to stop" -f (Get-Date -Format "HH:mm:ss")) -ForegroundColor DarkGray
        Start-Sleep -Seconds $Every
    }
}

# The write path, shared by the switches and the menu so both behave identically.
# -Add and -Remove are package lists. -WithGameGate also touches the predownload
# gate, which only a full repair does: -AddPackage deliberately covers the
# no-restrictions list alone, because that key belongs to the game predownload
# components. -IsUndo additionally returns the Greezer limiter to its factory
# value, which -RemovePackage on its own does not.
function Invoke-Write {
    param(
        [string[]]$Add    = @(),
        [string[]]$Remove = @(),
        [switch]$WithGameGate,
        [switch]$IsUndo
    )

    Head "REPAIR"
    if (-not (Enable-ShellWrite)) {
        Bad "shell cannot write Settings.System even after appops and pm grant."
        Note "Aborting. No changes were made."
        exit 1
    }
    Ok "shell can write Settings.System"

    $entries = Get-SafeEntries
    Save-State $entries

    foreach ($p in $Remove) {
        if ($entries -contains $p) { $entries = $entries | Where-Object { $_ -ne $p }; Ok "removed $p" }
        else { Note "$p not present" }
    }
    foreach ($p in $Add) {
        if ($entries -notcontains $p) { $entries += $p; Ok "added $p" }
        else { Note "$p already present" }
    }

    $entries = Set-Entries $entries
    if (($Add | Where-Object { $entries -notcontains $_ }).Count -gt 0) {
        Bad "write did not land for at least one package"
    } else {
        Ok "list written ($($entries.Count) entries)"
        Save-State $entries
    }

    $game = Get-GameEntries
    if ($Remove -contains $DefaultPkg) {
        if ($game -contains $DefaultPkg) {
            $game = Set-GameEntries @($game | Where-Object { $_ -ne $DefaultPkg })
            Ok "Play services removed from $GameKey"
        }
    } elseif ($WithGameGate -and $game -notcontains $DefaultPkg) {
        $game = Set-GameEntries ($game + $DefaultPkg)
        if ($game -contains $DefaultPkg) { Ok "Play services added to $GameKey" }
        else { Warn "write to $GameKey did not land (harmless, the list entry above still applies)" }
    } elseif ($WithGameGate) {
        Ok "Play services already in $GameKey"
    }

    # Volatile: resets on reboot. Greezer checks the list before this limiter acts,
    # so the entries above are the part that matters.
    $limiter = Sh "dumpsys greezer" | Select-String "mGmsLimitEnabled" |
        ForEach-Object { $_.ToString().Trim() }
    if ($limiter -notmatch "false") {
        Sh "dumpsys greezer IM GMS disable" | Out-Null
        $now = Sh "dumpsys greezer" | Select-String "mGmsLimitEnabled" |
            ForEach-Object { $_.ToString().Trim() }
        if ($now -match "false") { Ok "Greezer GMS limiter disabled" }
        else { Warn "limiter not available on this build (harmless)" }
    } else { Ok "Greezer GMS limiter already disabled" }

    # Restores GMS to the ordinary Aurogon allowlist, which triggerGMSLimitAction
    # removes it from. Does not cover PowerStrategyMode, so this is the third
    # layer rather than a replacement for the list.
    Sh "dumpsys greezer LM add $DefaultPkg" | Out-Null

    foreach ($p in $Add) {
        Send-Thaw $p
        Send-Reconnect $p
    }
    if ($Add.Count) { Ok "thaw and reconnect broadcast sent" }

    # An undo also has to put the Greezer limiter back, which a plain removal would
    # leave disabled. That flag is the most intrusive thing a repair changes, so
    # leaving it flipped after an undo would be the worst version of this bug. The
    # "dumpsys greezer LM add" allowlist entry has no documented reverse verb and is
    # runtime-only, so it clears on the next reboot and nothing more is attempted.
    if ($IsUndo) {
        Sh "dumpsys greezer IM GMS enable" | Out-Null
        $back = Sh "dumpsys greezer" | Select-String "mGmsLimitEnabled" |
            ForEach-Object { $_.ToString().Trim() }
        if ($back -notmatch "false") { Ok "Greezer GMS limiter returned to its factory value" }
        else { Warn "could not re-enable the limiter; run 'dumpsys greezer IM GMS enable' by hand" }
        Note "The Aurogon allowlist entry added by a repair has no reverse verb."
        Note "It is runtime-only and clears on the next reboot."
    }

    Show-Status

    if (-not $KeepShellWrite) {
        Revoke-ShellWrite
        if (Enable-ShellWrite) { Revoke-ShellWrite }   # confirm it stuck
        Ok "shell WRITE_SETTINGS revoked again"
    }

    Head "RESULT"
    if ($IsUndo) {
        Ok "Repair undone."
    } elseif ($WithGameGate) {
        Ok "Repair applied."
        Note "Lock the phone for 10 minutes, unlock, then run:"
        Note "  $self -CheckFreeze"
        Note ""
        Note "PowerKeeper rebuilds the list from its own database and can drop these"
        Note "entries again without warning. Re-run -Repair when notifications lag."
    } else {
        Ok "List updated."
    }
}

# One menu, one action per choice, then straight back to it. The switches stay
# working, so this is a convenience rather than the only route to any action.
# An empty answer quits, which also stops a scripted run from looping forever.
#
# The screen is cleared on every pass except the first, so the menu lands at the
# top of the window rather than below the last report, which on a tall phone
# screen meant scrolling up to find it. The "Press Enter" pause before the clear
# is what gives you a chance to read the result of the action you just ran.
# The first pass keeps the DEVICE block, which says which phone it found.
function Invoke-Menu {
    $first = $true
    while ($true) {
        if (-not $first) { try { Clear-Host } catch { } }
        $first = $false

        Head "MENU"
        Note "  1  Status report, changes nothing"
        Note "  2  Repair, exempt Play services at both gates"
        Note "  3  Check freeze events since boot"
        Note "  4  Add a package to the no-restrictions list"
        Note "  5  Remove a package from the no-restrictions list"
        Note "  6  List packages you can add or remove"
        Note "  7  Watch, repeat the status report"
        Note "  8  Undo the repair"
        Note "  q  Quit"

        $choice = Read-Host "  Choose"
        if (-not $choice) { return }
        $choice = "$choice".Trim().ToLower()
        if (-not $choice) { return }

        switch ($choice) {
            "1" { Show-StatusAndNext }
            "2" { Invoke-Write -Add @($DefaultPkg) -WithGameGate }
            "3" { Show-FreezeCheck }
            "4" {
                $pkg = Read-Host "  Package name to add"
                if ($pkg -and $pkg.Trim()) { Invoke-Write -Add @($pkg.Trim()) }
                else { Warn "nothing entered, nothing changed" }
            }
            "5" {
                $pkg = Read-Host "  Package name to remove"
                if ($pkg -and $pkg.Trim()) { Invoke-Write -Remove @($pkg.Trim()) }
                else { Warn "nothing entered, nothing changed" }
            }
            "6" { Show-Candidates }
            "7" {
                $raw = Read-Host "  Seconds between reports (default $Seconds)"
                $every = $Seconds
                $parsed = 0
                if ($raw -and [int]::TryParse($raw, [ref]$parsed) -and $parsed -gt 0) { $every = $parsed }
                Invoke-Watch $every
            }
            "8" { Invoke-Write -Remove @($DefaultPkg) -IsUndo }
            "q" { return }
            default { Warn "no such choice: $choice" }
        }

        Write-Host ""
        [void](Read-Host "  Press Enter for the menu")
    }
}

# Preflight
if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
    Bad "adb not found on PATH."
    Note "Install Android SDK platform-tools, then add its folder to PATH."
    exit 1
}

# Wireless debugging registers one phone twice, once for the TCP connection and
# once for the mDNS name. adb then refuses any command without -s, so when every
# attached serial reports the same hardware serial number, the duplicates are
# the same phone and the first one is used.
$attached = @(adb devices | Select-String "device$" |
    ForEach-Object { ($_ -split "\s+")[0].Trim() })
if ($attached.Count -eq 0) {
    Bad "No authorised phone on adb."
    Note "Plug it in, then tap 'Allow USB debugging' on the phone. Enable it"
    Note "first under Settings > Additional settings > Developer options."
    exit 1
}
if ($attached.Count -gt 1 -and -not $Serial) {
    # Queried with an explicit -s per serial. Sh cannot be used here because
    # $adbArgs is still empty, which is the thing being resolved.
    $hwSerials = @($attached |
        ForEach-Object { ((@() | adb -s $_ shell getprop ro.serialno 2>$null) -join "").Trim() } |
        Where-Object { $_ -ne "" } |
        Select-Object -Unique)
    if ($hwSerials.Count -eq 1) {
        Note "Wireless debugging listed the same phone $($attached.Count) times. Using $($attached[0])."
        $Serial = $attached[0]
        # $adbArgs was built before this block, so rebuild it now that the
        # serial is resolved.
        $adbArgs = @("-s", $Serial)
    } else {
        Bad "$($attached.Count) different devices attached. Pick one with -Serial:"
        $attached | ForEach-Object { Note "  -Serial $_" }
        exit 1
    }
}

$manufacturer = Sh "getprop ro.product.manufacturer"
if ($manufacturer -notmatch "Xiaomi|Redmi|POCO") {
    Bad "Not a Xiaomi device. This script targets HyperOS."
    exit 1
}
if (-not (Get-GmsUid)) {
    Bad "$DefaultPkg not found. This script targets China ROM with Google services."
    exit 1
}

Head "DEVICE"
Row "manufacturer" $manufacturer
Row "HyperOS"      (Sh "getprop ro.miui.ui.version.name")
Row "Android"      "$(Sh 'getprop ro.build.version.release') (API $(Sh 'getprop ro.build.version.sdk'))"
Row "profile"      "user $User (Greezer reads this one only)"

if ($Menu)           { Invoke-Menu; exit 0 }
if ($CheckFreeze)    { Show-FreezeCheck; exit 0 }
if ($ListCandidates) { Show-Candidates; exit 0 }
if ($Watch)          { Invoke-Watch $Seconds; exit 0 }

$add = @()
if ($Repair) { $add += $DefaultPkg }
$add += PkgList $AddPackage
$remove = PkgList $RemovePackage
if ($Undo) { $remove += $DefaultPkg }

if ($add.Count -eq 0 -and $remove.Count -eq 0) {
    Show-StatusAndNext
    exit 0
}

Invoke-Write -Add $add -Remove $remove -WithGameGate:$Repair -IsUndo:$Undo