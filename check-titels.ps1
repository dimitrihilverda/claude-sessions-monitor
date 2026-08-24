# =============================================================================
#  check-titels.ps1 -- laat zien waar de naam van elke sessie vandaan komt.
#  Handig als een sessie niet de titel toont die je in je terminal ziet staan.
#
#      powershell -ExecutionPolicy Bypass -File check-titels.ps1
# =============================================================================
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'sessionlib.ps1')

$sessies = @(Get-DashSessions -Dir (Join-Path $PSScriptRoot 'session-status'))
$zicht   = @($sessies | Where-Object { $_.visible })

if (-not $zicht.Count) {
    Write-Host "Geen zichtbare sessies. Start een Claude Code-sessie en probeer opnieuw."
    exit 0
}

foreach ($s in $zicht) {
    $procNaam = '(onbekend)'
    $venster  = ''
    if ($s.host_pid -gt 0) {
        try {
            $p = Get-Process -Id $s.host_pid -ErrorAction Stop
            $procNaam = $p.ProcessName
            $venster  = $p.MainWindowTitle
        } catch { $procNaam = '(proces weg)' }
    }

    $bron = if ($s.tab)        { 'tabtitel van de terminal' }
            elseif ($s.title)  { 'transcript' }
            else               { 'mapnaam' }

    Write-Host ""
    Write-Host ("  naam        : " + $s.name)          -ForegroundColor Green
    Write-Host ("  komt uit    : " + $bron)
    Write-Host ("  map         : " + $s.folder)
    Write-Host ("  status      : " + $s.label)
    Write-Host ("  venster     : " + $procNaam + "  (pid " + $s.host_pid + ")")
    Write-Host ("  venstertitel: " + $(if ($venster) { $venster } else { '(leeg)' }))
    Write-Host ("  transcript  : " + $(if ($s.title) { $s.title } else { '(nog niets)' }))

    if (-not $s.tab -and $s.host_pid -gt 0 -and ($DashTerminals -notcontains $procNaam.ToLower())) {
        Write-Host ("  -> " + $procNaam + " geeft de tabnaam van Claude niet door aan de venstertitel.") -ForegroundColor DarkYellow
        Write-Host ("     Zet die sessie in Windows Terminal, of vul " + '$DashTerminals' + " aan in sessionlib.ps1") -ForegroundColor DarkYellow
        Write-Host ("     als jouw terminal dat wel doet.") -ForegroundColor DarkYellow
    }
}
Write-Host ""
