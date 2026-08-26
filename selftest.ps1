<#
  selftest.ps1 -- check, on this machine, whether the PC side can actually work.

  Written for the Mac, useful on Windows. The Mac support was written without a
  Mac to try it on, so rather than a README full of "this should work", every
  assumption it rests on is a check here. Run it first; what it reports is the
  truth about the machine you are on.

  It changes nothing. The one exception is a file it writes into session-status
  and removes again, because "can I write a beacon" cannot be answered by
  looking.

      pwsh -NoProfile -File selftest.ps1

  Exit code 0 if nothing failed, 1 otherwise, so it can gate a script.
#>
[CmdletBinding()]
param(
    [int]$Port = 8787
)

$Root = $PSScriptRoot
. (Join-Path $Root 'platformlib.ps1')

$script:fouten = 0
$script:waars  = 0

function Report {
    param(
        [string]$Wat,
        [ValidateSet('ok', 'fail', 'warn', 'skip')][string]$Hoe,
        [string]$Detail = '',
        [string]$Hint = ''
    )
    $merk = switch ($Hoe) {
        'ok'   { '  ok  ' }
        'fail' { ' FAIL ' }
        'warn' { ' warn ' }
        'skip' { ' --   ' }
    }
    $regel = '[' + $merk + '] ' + $Wat
    if ($Detail) { $regel += '  --  ' + $Detail }
    Write-Host $regel
    if ($Hint -and $Hoe -ne 'ok') { Write-Host ('          ' + $Hint) }
    if ($Hoe -eq 'fail') { $script:fouten++ }
    if ($Hoe -eq 'warn') { $script:waars++ }
}

Write-Host ''
Write-Host ('Claude Sessions Monitor -- self test on ' + (Get-DashPlatformName))
Write-Host ('PowerShell ' + $PSVersionTable.PSVersion)
Write-Host ''

# ---- 1. the runtime ---------------------------------------------------------
if ($DashOnWindows) {
    Report 'PowerShell edition' 'ok' ($PSVersionTable.PSEdition)
} elseif ($PSVersionTable.PSVersion.Major -ge 7) {
    Report 'PowerShell 7 or newer' 'ok' ($PSVersionTable.PSVersion.ToString())
} else {
    Report 'PowerShell 7 or newer' 'fail' ($PSVersionTable.PSVersion.ToString()) 'brew install powershell'
}

# ---- 2. where things live ---------------------------------------------------
$home_ = Get-DashHome
if ($home_ -and (Test-Path -LiteralPath $home_)) {
    Report 'home directory' 'ok' $home_
} else {
    Report 'home directory' 'fail' ([string]$home_) 'HOME is not set, or points nowhere'
}

$claude = Get-DashClaudeDir
Report '~/.claude' $(if (Test-Path -LiteralPath $claude) { 'ok' } else { 'fail' }) $claude 'Claude Code has not run on this machine yet'

<#
  This one is the reason Join-DashPath exists. On a Mac, joining '.claude\projects'
  in one piece yields a directory with a backslash in its name, which never
  exists -- and the failure is silent: no titles, no error.
#>
$proj = Get-DashProjectsDir
if ($proj -match '\\' -and -not $DashOnWindows) {
    Report 'transcript directory' 'fail' $proj 'a backslash slipped into the path'
} elseif (Test-Path -LiteralPath $proj) {
    $n = @(Get-ChildItem -LiteralPath $proj -Filter '*.jsonl' -Recurse -File -ErrorAction SilentlyContinue).Count
    Report 'transcript directory' 'ok' ($proj + '  (' + $n + ' transcripts)')
} else {
    Report 'transcript directory' 'warn' $proj 'no transcripts yet, so sessions get their folder name as title'
}

# ---- 3. can we write a beacon ----------------------------------------------
$statusDir = Join-Path $Root 'session-status'
try {
    New-Item -ItemType Directory -Force -Path $statusDir -ErrorAction Stop | Out-Null
    $probe = Join-Path $statusDir 'selftest-probe.json'
    '{}' | Set-Content -LiteralPath $probe -Encoding UTF8 -ErrorAction Stop
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    Report 'session-status is writable' 'ok' $statusDir
} catch {
    Report 'session-status is writable' 'fail' $_.Exception.Message
}

# ---- 4. the hooks -----------------------------------------------------------
$sf = Get-DashSettingsFile
if (-not (Test-Path -LiteralPath $sf)) {
    Report 'hooks registered' 'fail' 'no settings.json' 'run install-hooks.ps1'
} else {
    try {
        $st = Get-Content -LiteralPath $sf -Raw -Encoding UTF8 | ConvertFrom-Json
        $nodig = @('SessionStart', 'UserPromptSubmit', 'PostToolUse', 'Notification', 'Stop', 'SessionEnd')
        $mist = @()
        $cmds = @()
        foreach ($ev in $nodig) {
            $p = $null
            if ($st.hooks) { $p = $st.hooks.PSObject.Properties[$ev] }
            if (-not $p) { $mist += $ev; continue }
            foreach ($groep in @($p.Value)) {
                foreach ($h in @($groep.hooks)) { if ($h.command) { $cmds += [string]$h.command } }
            }
        }
        $onze = @($cmds | Where-Object { $_ -match 'beacon\.ps1' })
        if ($mist.Count) {
            Report 'hooks registered' 'fail' ('missing: ' + ($mist -join ', ')) 'run install-hooks.ps1'
        } elseif ($onze.Count -eq 0) {
            Report 'hooks registered' 'fail' 'all six events present, none of them ours' 'run install-hooks.ps1'
        } else {
            Report 'hooks registered' 'ok' ('all six, ' + $onze.Count + ' pointing at beacon.ps1')
        }

        # Does the interpreter in that command line exist? A hook whose command
        # cannot start fails per event, silently, and the display just stays empty.
        foreach ($c in ($onze | Select-Object -Unique)) {
            $exe = ''
            if ($c -match '^"([^"]+)"') { $exe = $Matches[1] } elseif ($c -match '^(\S+)') { $exe = $Matches[1] }
            $gevonden = $false
            if ($exe) {
                if (Test-Path -LiteralPath $exe) { $gevonden = $true }
                elseif (Get-Command $exe -ErrorAction SilentlyContinue) { $gevonden = $true }
            }
            if ($gevonden) { Report 'hook interpreter' 'ok' $exe }
            else { Report 'hook interpreter' 'fail' $exe 'the hook command cannot start; re-run install-hooks.ps1' }
        }
    } catch {
        Report 'hooks registered' 'fail' $_.Exception.Message
    }
}

# ---- 5. the process table ---------------------------------------------------
$sw  = [Diagnostics.Stopwatch]::StartNew()
$tab = Get-DashProcTable
$ms  = $sw.ElapsedMilliseconds
if ($tab.Count -eq 0) {
    Report 'process table' 'fail' 'empty' 'without this, sessions cannot be tied to a program or pruned when it exits'
} else {
    Report 'process table' 'ok' ([string]$tab.Count + ' processes in ' + $ms + ' ms')
    if ($tab.ContainsKey($PID)) {
        $me = $tab[$PID]
        $par = if ($tab.ContainsKey([int]$me.Parent)) { [string]$tab[[int]$me.Parent].Name } else { '(gone)' }
        Report 'own process in it' 'ok' ([string]$me.Name + ', parent ' + $me.Parent + ' ' + $par)
        if ($null -eq $me.Start) {
            Report 'process start times' 'warn' 'not parsed' 'PID reuse cannot be detected, so a stale session may linger'
        } else {
            Report 'process start times' 'ok' ([datetime]$me.Start).ToString('HH:mm:ss')
        }
    } else {
        Report 'own process in it' 'fail' ('PID ' + $PID + ' is not in the table') 'the ps output is not being parsed as expected'
    }
}

$args_ = Get-DashProcArgs $PID
if ($args_) { Report 'command line of a process' 'ok' ($args_.Substring(0, [Math]::Min(60, $args_.Length))) }
else { Report 'command line of a process' 'warn' 'empty' "an editor's agent session cannot be told apart from your own" }

# ---- 6. reading sessions ----------------------------------------------------
try {
    . (Join-Path $Root 'sessionlib.ps1')
    $Error.Clear()
    $ss = @(Get-DashSessions -Dir $statusDir)
    if ($Error.Count) {
        Report 'reading sessions' 'fail' ($Error[$Error.Count - 1].ToString())
    } else {
        Report 'reading sessions' 'ok' ([string]$ss.Count + ' beacons, ' + @($ss | Where-Object { $_.visible }).Count + ' visible')
    }
} catch {
    Report 'reading sessions' 'fail' $_.Exception.Message
}

# ---- 7. the port the display talks to --------------------------------------
try {
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
    $l.Start(); $l.Stop()
    Report ('port ' + $Port + ' is free') 'ok' 'the API can bind it'
} catch {
    Report ('port ' + $Port + ' is free') 'warn' $_.Exception.Message 'something is already listening -- the API itself, probably'
}

# ---- 8. the cable -----------------------------------------------------------
$poorten = @(Get-DashSerialCandidates)
if ($poorten.Count) { Report 'serial ports' 'ok' ($poorten -join ', ') }
else { Report 'serial ports' 'warn' 'none found' 'only matters if you want to drive the display over USB' }

# ---- 9. macOS only ---------------------------------------------------------
if ($DashOnWindows) {
    Report 'raising a window' 'ok' 'user32, and the window is picked by title'
} else {
    if (Get-Command osascript -ErrorAction SilentlyContinue) {
        Report 'osascript present' 'ok'
        <#
          Counting processes through System Events is the cheapest thing that
          still needs the same permission raising an application does. If this
          fails, tapping a row on the display will do nothing at all, and the
          fix is a checkbox rather than code: System Settings > Privacy &
          Security > Automation (and Accessibility for some macOS versions).
        #>
        try {
            $uit = & osascript -e 'tell application "System Events" to count processes' 2>&1
            if ($LASTEXITCODE -eq 0 -and ($uit -join '') -match '\d') {
                Report 'permission to drive other apps' 'ok' (($uit -join ' ').Trim() + ' processes visible')
            } else {
                Report 'permission to drive other apps' 'fail' (($uit -join ' ').Trim()) 'System Settings > Privacy & Security > Automation, allow this terminal to control System Events'
            }
        } catch {
            Report 'permission to drive other apps' 'fail' $_.Exception.Message
        }
    } else {
        Report 'osascript present' 'fail' 'not found' 'without it nothing can be brought to the front'
    }
    Report 'the floating HUD' 'skip' 'Windows only' ('use the display, or the status page at http://localhost:' + $Port + '/')
}

Write-Host ''
if ($script:fouten) {
    Write-Host ('' + $script:fouten + ' failed, ' + $script:waars + ' warnings.') -ForegroundColor Red
    exit 1
}
Write-Host ('Nothing failed' + $(if ($script:waars) { ', ' + $script:waars + ' warnings' } else { '' }) + '.') -ForegroundColor Green
exit 0
