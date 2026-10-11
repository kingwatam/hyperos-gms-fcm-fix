<#
.SYNOPSIS
    Report and repair Xiaomi HyperOS freezing Google Play services.

.DESCRIPTION
    PowerKeeper publishes a list of apps exempt from freezing to
    Settings.System MILLET_NO_RESTRICT_APP. Greezer checks that list before
    freezing a process, and a frozen process cannot hold a socket open, so a
    missing com.google.android.gms means the FCM connection drops whenever the
    screen goes off.

    Scope: official China ROM, HyperOS 3, Android 16 (API 36), Xiaomi / Redmi /
    POCO. Needs adb from Android SDK platform-tools on PATH and USB debugging
    enabled in Developer options. The first time you plug the phone in, Android
    shows an "Allow USB debugging" dialog with an RSA fingerprint; tap "Allow
    USB debugging". Until you do, adb reports the phone as unauthorized.

    Read-only unless a write switch is passed. Writes are idempotent and keep
    every list entry already present.

    Typical sequence:
      1. no switch        see current state, change nothing
      2. -Repair          add GMS to the list, disable the Greezer limiter
      3. lock ~10 min, unlock
      4. -CheckFreeze      confirm GMS was not frozen while the screen was off
    Repeat step 2 when push starts lagging: PowerKeeper rebuilds the list from
    its own database and drops entries without warning.

    -AddPackage and -RemovePackage use the same mechanism on any package.
    That exempts an app from Greezer freezing only. It does not override MIUI
    battery policy, AOSP Doze, or Aurogon broadcast control.

    Findings: https://github.com/dingwen07/hyperos-fcm-fix

.PARAMETER Repair
    Add com.google.android.gms to the no-restrictions list if it is missing, and
    run "dumpsys greezer IM GMS disable". Both steps are idempotent.

.PARAMETER CheckFreeze
    Count GMS freeze events logged since boot. Run after locking the phone for
    ten minutes and unlocking. Read-only.

.PARAMETER AddPackage
    Add packages to the no-restrictions list, e.g. -AddPackage com.whatsapp.
    Can be combined with -Repair.

.PARAMETER RemovePackage
    Remove packages from the no-restrictions list. Use to undo this tool.

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
    .\hyperos-gms-fcm-fix.ps1 -RemovePackage com.google.android.gms
    Undo the GMS entry.
#>

[CmdletBinding()]
param(
    [switch]$Repair,
    [switch]$CheckFreeze,
    [string[]]$AddPackage,
    [string[]]$RemovePackage,
    [switch]$ListCandidates,
    [switch]$Watch,
    [int]$Seconds = 5,
    [string]$Serial,
    [switch]$KeepShellWrite,
    [switch]$Help
)

if ($Help) { Get-Help $PSCommandPath -Detailed; exit }

$SettingsKey = "MILLET_NO_RESTRICT_APP"
$DefaultPkg  = "com.google.android.gms"
$ProbeKey    = "hyperos_gms_fcm_fix_probe"
$User        = 0

# How to invoke this script here, for the hints it prints. $IsWindows is absent
# on Windows PowerShell 5.1, so the edition check covers that case too.
$self = if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
    ".\hyperos-gms-fcm-fix.ps1"
} else {
    "./hyperos-gms-fcm-fix.ps1"
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
function Sh($cmd) { @(adb @adbArgs shell $cmd 2>$null) }
function ShText($cmd) { ((Sh $cmd) -join "`n").Trim() }

# greezer output is ~60 KB, which survives the pipe, but writing it to disk
# keeps -CheckFreeze independent of console width and pipe buffering.
function Sh-ToFile($cmd, $path) { adb @adbArgs shell $cmd > $path }

function Get-Setting($name) { ShText "settings --user $User get system $name" }

# Normalise a package list from a parameter. Wrapping an unset parameter in @()
# still yields one $null element, so .Trim() would be called on null. The
# string cast handles that before any method is invoked.
function PkgList($values) {
    @($values | Where-Object { $null -ne $_ } |
        ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne "" })
}

# pm list packages -U is used rather than parsing "userId=" out of
# dumpsys package. For com.google.android.gms that dump is about 2 MB of
# Activity Resolver Table and the per-package block never reaches the client,
# so the pattern matches nothing. pm returns the uid directly:
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
    $joined = ($entries | Select-Object -Unique) -join ","
    Sh "settings --user $User put system $SettingsKey $joined" | Out-Null
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

    Head "NO-RESTRICTIONS LIST  ($($entries.Count) entries)"
    $entries | ForEach-Object { Note "    $_" }
    $miss = @()
    if ($entries -notcontains $DefaultPkg) { $miss += $DefaultPkg }
    foreach ($p in (PkgList $AddPackage)) { if ($entries -notcontains $p) { $miss += $p } }
    if ($miss.Count -eq 0) { Ok "all target packages present" }
    else { Bad "missing: $($miss -join ', ')" }

    # One dumpsys call feeds both readings, so a large output is fetched once.
    $greezer = Sh "dumpsys greezer"

    $mLimiter = $greezer | Select-String -SimpleMatch "mGmsLimitEnabled" | Select-Object -First 1
    Row "Greezer GMS limiter" $(if ($mLimiter) { $mLimiter.Line.Trim() } else { "not reported by this build" })

    $uid = Get-GmsUid
    $fz = @($greezer | Select-String -SimpleMatch "FZ uid = $uid ").Count
    Row "GMS freeze events" "$fz (since boot)"

    $sock = @(Sh "cat /proc/net/tcp /proc/net/tcp6" | Select-String ":146[CDE]")
    if ($sock.Count) {
        if (@($sock | Where-Object { $_.Line -match "\s01\s" }).Count) { Ok "FCM socket established" }
        else { Warn "FCM port present but not established" }
    } else { Warn "no FCM socket (screen off, or GMS frozen)" }
}

function Show-FreezeCheck {
    Head "FREEZE CHECK (since boot)"
    $uid = Get-GmsUid
    if (-not $uid) { Bad "GMS not found."; return }

    $f = Join-Path ([System.IO.Path]::GetTempPath()) "greezer_gms_check.txt"
    Sh-ToFile "dumpsys greezer" $f
    $events = @(Select-String -Path $f -Pattern "FZ uid = $uid ")
    $total  = @(Select-String -Path $f -Pattern "FZ uid")

    Row "total freeze events"       $total.Count
    Row "events for GMS (uid $uid)" $events.Count

    if ($events.Count -eq 0) {
        Ok "GMS was not frozen. The list entry is holding."
    } else {
        Bad "GMS was frozen since boot:"
        $events | Select-Object -Last 5 | ForEach-Object { Note "  $_" }
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
        ForEach-Object { ((adb -s $_ shell getprop ro.serialno 2>$null) -join "").Trim() } |
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

if ($CheckFreeze) { Show-FreezeCheck; exit 0 }
if ($ListCandidates) { Show-Candidates; exit 0 }

if ($Watch) {
    Head "WATCH MODE - Ctrl+C to stop"
    Note "Read-only. Needs the PC tethered, so this is a diagnostic aid rather"
    Note "than a permanent fix. For continuous protection use a Shizuku app."
    while ($true) {
        Show-Status
        Write-Host ("`n  -- {0} - Ctrl+C to stop" -f (Get-Date -Format "HH:mm:ss")) -ForegroundColor DarkGray
        Start-Sleep -Seconds $Seconds
    }
}

$add = @()
if ($Repair) { $add += $DefaultPkg }
$add += PkgList $AddPackage
$remove = PkgList $RemovePackage

if ($add.Count -eq 0 -and $remove.Count -eq 0) {
    Show-Status
    Head "NEXT"
    Note "Read-only run. Pass -Repair, -AddPackage or -RemovePackage to write."
    if ((Get-Entries) -notcontains $DefaultPkg) {
        Note "To fix:  $self -Repair"
    }
    exit 0
}

Head "REPAIR"
if (-not (Enable-ShellWrite)) {
    Bad "shell cannot write Settings.System even after appops and pm grant."
    Note "Aborting. No changes were made."
    exit 1
}
Ok "shell can write Settings.System"

$entries = Get-Entries

foreach ($p in $remove) {
    if ($entries -contains $p) { $entries = $entries | Where-Object { $_ -ne $p }; Ok "removed $p" }
    else { Note "$p not present" }
}
foreach ($p in $add) {
    if ($entries -notcontains $p) { $entries += $p; Ok "added $p" }
    else { Note "$p already present" }
}

$entries = Set-Entries $entries
if (($add | Where-Object { $entries -notcontains $_ }).Count -gt 0) {
    Bad "write did not land for at least one package"
} else {
    Ok "list written ($($entries.Count) entries)"
}

# Volatile: resets on reboot. Greezer checks the list before this limiter acts,
# so the entry above is the part that matters.
$limiter = Sh "dumpsys greezer" | Select-String "mGmsLimitEnabled" |
    ForEach-Object { $_.ToString().Trim() }
if ($limiter -notmatch "false") {
    Sh "dumpsys greezer IM GMS disable" | Out-Null
    $now = Sh "dumpsys greezer" | Select-String "mGmsLimitEnabled" |
        ForEach-Object { $_.ToString().Trim() }
    if ($now -match "false") { Ok "Greezer GMS limiter disabled" }
    else { Warn "limiter not available on this build (harmless)" }
} else { Ok "Greezer GMS limiter already disabled" }

Show-Status

if (-not $KeepShellWrite) {
    Revoke-ShellWrite
    if (Enable-ShellWrite) { Revoke-ShellWrite }   # confirm it stuck
    Ok "shell WRITE_SETTINGS revoked again"
}

Head "RESULT"
Ok "Repair applied."
Note "Lock the phone for 10 minutes, unlock, then run:"
Note "  $self -CheckFreeze"
Note ""
Note "PowerKeeper rebuilds the list from its own database and can drop these"
Note "entries again without warning. Re-run -Repair when notifications lag."