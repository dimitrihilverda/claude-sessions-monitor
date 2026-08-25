# =============================================================================
#  check-titles.ps1 -- shows where each session's name comes from.
#  Useful when a session does not show the title you see in your terminal.
#
#      powershell -ExecutionPolicy Bypass -File check-titles.ps1
# =============================================================================
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'sessionlib.ps1')

$sessies = @(Get-DashSessions -Dir (Join-Path $PSScriptRoot 'session-status'))
$zicht   = @($sessies | Where-Object { $_.visible })

if (-not $zicht.Count) {
    Write-Host "No visible sessions. Start a Claude Code session and try again."
    exit 0
}

foreach ($s in $zicht) {
    $procNaam = '(unknown)'
    $windowTitle  = ''
    if ($s.host_pid -gt 0) {
        try {
            $p = Get-Process -Id $s.host_pid -ErrorAction Stop
            $procNaam = $p.ProcessName
            $windowTitle  = $p.MainWindowTitle
        } catch { $procNaam = '(process gone)' }
    }

    $bron = if ($s.tab)        { 'terminal tab title' }
            elseif ($s.title)  { 'transcript' }
            else               { 'folder name' }

    Write-Host ""
    Write-Host ("  name        : " + $s.name)          -ForegroundColor Green
    Write-Host ("  comes from  : " + $bron)
    Write-Host ("  folder      : " + $s.folder)
    Write-Host ("  state       : " + $s.label)
    Write-Host ("  window      : " + $procNaam + "  (pid " + $s.host_pid + ")")
    Write-Host ("  window title: " + $(if ($windowTitle) { $windowTitle } else { '(empty)' }))
    Write-Host ("  transcript  : " + $(if ($s.title) { $s.title } else { '(nothing yet)' }))

    if (-not $s.tab -and $s.host_pid -gt 0) {
        $pn = $procNaam.ToLower()
        if ($DashDesktopHosts -contains $pn) {
            Write-Host "  -> Cowork session: that window is always called 'Claude', so there is no title in it." -ForegroundColor DarkGray
        } elseif ($DashTerminals -contains $pn) {
            Write-Host "  -> Terminal found, but its title was empty or too generic." -ForegroundColor DarkYellow
        } else {
            Write-Host ("  -> " + $procNaam + " keeps Claude's tab name inside its own windows.") -ForegroundColor DarkYellow
            Write-Host "     For an IDE terminal that cannot be read, hence the transcript title." -ForegroundColor DarkYellow
            Write-Host ("     If this really is a terminal, add it to " + '$DashTerminals' + " in sessionlib.ps1.") -ForegroundColor DarkYellow
        }
    }
}
Write-Host ""
