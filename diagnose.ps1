# =============================================================================
#  diagnose.ps1 -- is the link with Claude Code working?
#
#  Walks the whole chain and makes a real test call to the beacon, so you can
#  see where it breaks instead of having to guess.
#
#      powershell -ExecutionPolicy Bypass -File diagnose.ps1
# =============================================================================
$ErrorActionPreference = 'Continue'
$Hier   = $PSScriptRoot
$Status = Join-Path $Hier 'session-status'
$goed = 0; $fout = 0

function OK($t)   { Write-Host "  [ok]   $t"   -ForegroundColor Green;      $script:goed++ }
function NIET($t) { Write-Host "  [fail] $t"   -ForegroundColor Red;        $script:fout++ }
function LET($t)  { Write-Host "  [note] $t"   -ForegroundColor DarkYellow }
function INFO($t) { Write-Host "         $t"   -ForegroundColor DarkGray }
function Kop($t)  { Write-Host ''; Write-Host $t -ForegroundColor Cyan }

Kop 'Claude Sessions Monitor -- diagnostics'
INFO "folder: $Hier"
INFO "PowerShell $($PSVersionTable.PSVersion)"

# ---- 1. files ---------------------------------------------------------------
Kop '1. Files'
foreach ($f in @('sessionlib.ps1', 'focuslib.ps1', 'beacon.ps1', 'hud.ps1', 'hud.vbs')) {
    if (Test-Path (Join-Path $Hier $f)) { OK $f } else { NIET "$f is missing" }
}

# ---- 2. hooks ---------------------------------------------------------------
Kop '2. Hooks in Claude Code'
$settingsPad = Join-Path $env:USERPROFILE '.claude\settings.json'
$beacon = Join-Path $Hier 'beacon.ps1'
if (-not (Test-Path $settingsPad)) {
    NIET "$settingsPad does not exist -- is Claude Code installed and has it been run?"
} else {
    $s = $null
    try { $s = Get-Content $settingsPad -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    if (-not $s) {
        NIET "$settingsPad is not valid JSON"
    } elseif (-not $s.hooks) {
        NIET 'there are no hooks at all in settings.json -- run install.ps1 again'
    } else {
        $verwacht = 'SessionStart', 'UserPromptSubmit', 'PostToolUse', 'Notification', 'Stop', 'SessionEnd'
        $paden = @{}
        foreach ($ev in $verwacht) {
            $gevonden = $false
            foreach ($e in @($s.hooks.$ev)) {
                foreach ($hk in @($e.hooks)) {
                    $c = "$($hk.command)"
                    if ($c -like '*beacon.ps1*') {
                        $gevonden = $true
                        if ($c -match '"([^"]*beacon\.ps1)"') { $paden[$Matches[1]] = $true }
                    }
                }
            }
            if ($gevonden) { OK "hook $ev" } else { NIET "hook $ev is missing" }
        }
        if ($paden.Keys.Count -gt 1) {
            LET 'the hooks point at more than one beacon.ps1; that fires twice:'
            foreach ($k in $paden.Keys) { INFO "  $k" }
        }
        foreach ($k in $paden.Keys) {
            if (-not (Test-Path $k)) { NIET "hook points at $k, but that file does not exist" }
            elseif ($k -ne $beacon)  { LET  "hooks point at a different install: $k" }
        }
    }
}

# ---- 3. test call -----------------------------------------------------------
Kop '3. Test call to the beacon'
$testId = 'diagnose-' + (Get-Date -Format 'HHmmss')
$testBestand = Join-Path $Status "$testId.json"
try {
    $payload = @{
        session_id      = $testId
        hook_event_name = 'UserPromptSubmit'
        cwd             = $Hier
        prompt          = 'test call from diagnose.ps1'
        transcript_path = ''
    } | ConvertTo-Json -Compress

    $payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $beacon
    Start-Sleep -Milliseconds 400

    if (Test-Path $testBestand) {
        OK 'beacon.ps1 runs and writes a status file'
        if (Test-Path (Join-Path $Hier 'sessions.json')) { OK 'sessions.json is being updated' }
        else { NIET 'sessions.json was not created' }
    } else {
        NIET 'beacon.ps1 wrote nothing -- check that PowerShell is allowed to run the script'
        INFO "try by hand:  Get-Content -Raw <json> | powershell -File `"$beacon`""
    }
} catch {
    NIET "test call failed: $($_.Exception.Message)"
} finally {
    if (Test-Path $testBestand) { Remove-Item $testBestand -Force -ErrorAction SilentlyContinue }
}

# ---- 4. real sessions -------------------------------------------------------
Kop '4. Sessions that have reported in'
if (-not (Test-Path $Status)) {
    NIET "the session-status folder does not exist"
} else {
    $b = @(Get-ChildItem $Status -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if (-not $b.Count) {
        NIET 'no session has reported in yet'
        INFO 'Hooks are read when a session starts, not afterwards.'
        INFO ' * terminal: close your running Claude Code sessions and start a new one'
        INFO ' * desktop app: quit Claude completely, including from the system tray'
        INFO '   next to the clock, and start it again. A new chat in an app that was'
        INFO '   already running still uses the settings from when it started.'
        INFO 'Then give it an instruction and run this diagnostic again.'
    } else {
        OK "$($b.Count) status file(s) found"
        foreach ($f in ($b | Sort-Object LastWriteTime -Descending | Select-Object -First 6)) {
            $min = [int]((Get-Date) - $f.LastWriteTime).TotalMinutes
            $d = $null
            try { $d = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
            INFO ("  {0,-22} {1,-18} {2,4} min ago" -f $f.BaseName.Substring(0, [Math]::Min(20, $f.BaseName.Length)), $d.event, $min)
        }
    }
}

# ---- 5. the HUD itself ------------------------------------------------------
Kop '5. The HUD'
$draait = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*hud.ps1*' })
if ($draait.Count) { OK "running (pid $($draait[0].ProcessId))" } else { NIET 'not running -- start hud.vbs' }

$cfgPad = Join-Path $Hier 'hud-config.json'
if (Test-Path $cfgPad) {
    $cfg = $null
    try { $cfg = Get-Content $cfgPad -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    if ($cfg -and $cfg.onlyAttention) {
        LET 'the "only sessions that need me" filter is ON -- that makes the HUD look empty'
        INFO 'right-click the HUD to turn it off'
    }
    if ($cfg) { INFO "position: x=$($cfg.x) y=$($cfg.y)" }
} else {
    INFO 'no hud-config.json yet; it appears once the HUD has run at least once'
}

# ---- summary ----------------------------------------------------------------
Write-Host ''
if ($fout -eq 0) {
    Write-Host "  All good ($goed checks)." -ForegroundColor Green
    Write-Host '  If you still see nothing, that session was already running before' -ForegroundColor Green
    Write-Host '  the hooks were in place. Restart the terminal session, or quit the' -ForegroundColor Green
    Write-Host '  Claude desktop app completely (including the system tray) and' -ForegroundColor Green
    Write-Host '  start it again -- a new chat in a running app is not enough.' -ForegroundColor Green
} else {
    Write-Host "  $fout problem(s) found, $goed checks passed." -ForegroundColor Red
}
Write-Host ''
Read-Host '  Press Enter to close' | Out-Null
