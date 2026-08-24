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

    if (-not $s.tab -and $s.host_pid -gt 0) {
        $pn = $procNaam.ToLower()
        if ($DashDesktopHosts -contains $pn) {
            Write-Host "  -> Cowork-sessie: dat venster heet altijd 'Claude', daar zit geen titel in." -ForegroundColor DarkGray
        } elseif ($DashTerminals -contains $pn) {
            Write-Host "  -> Terminal gevonden, maar de titel was leeg of te generiek." -ForegroundColor DarkYellow
        } else {
            Write-Host ("  -> " + $procNaam + " houdt de tabnaam van Claude binnen zijn eigen vensters.") -ForegroundColor DarkYellow
            Write-Host "     Bij een IDE-terminal is die niet uit te lezen; daarom de transcript-titel." -ForegroundColor DarkYellow
            Write-Host ("     Is dit toch een terminal, zet hem dan in " + '$DashTerminals' + " in sessionlib.ps1.") -ForegroundColor DarkYellow
        }
    }
}
Write-Host ""
