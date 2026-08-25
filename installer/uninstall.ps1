# =============================================================================
#  uninstall.ps1 -- Claude Deck weer weghalen
#      powershell -ExecutionPolicy Bypass -File uninstall.ps1
# =============================================================================
param(
    [switch]$Stil,
    [switch]$BewaarMap
)
$ErrorActionPreference = 'Continue'
$Doel = $PSScriptRoot

function Zeg($t, $k = 'Gray') { Write-Host $t -ForegroundColor $k }
Write-Host ''
Zeg 'Claude Deck verwijderen' Cyan

# ---- draaiende onderdelen stoppen -------------------------------------------
# let op: dit script draait zelf ook vanuit $Doel, dus onszelf overslaan
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='wscript.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*$Doel*" -and $_.ProcessId -ne $PID -and $_.CommandLine -notlike '*uninstall.ps1*' } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
Zeg '  HUD en webservice gestopt'

# ---- hooks eruit ------------------------------------------------------------
$settingsPad = Join-Path $env:USERPROFILE '.claude\settings.json'
if (Test-Path $settingsPad) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item $settingsPad "$settingsPad.bak-$stamp"
    $settings = Get-Content $settingsPad -Raw | ConvertFrom-Json
    $weg = 0
    if ($settings.hooks) {
        foreach ($prop in @($settings.hooks.PSObject.Properties)) {
            $over = @()
            foreach ($e in @($prop.Value)) {
                $isOnze = $false
                foreach ($hk in @($e.hooks)) {
                    if ("$($hk.command)" -like '*beacon.ps1*') { $isOnze = $true }
                }
                if ($isOnze) { $weg++ } else { $over += $e }
            }
            if ($over.Count) { $prop.Value = @($over) }
            else { $settings.hooks.PSObject.Properties.Remove($prop.Name) }
        }
    }
    $settings | ConvertTo-Json -Depth 16 | Set-Content -Path $settingsPad -Encoding UTF8
    Zeg "  $weg hook(s) verwijderd uit settings.json (backup: settings.json.bak-$stamp)"
}

# ---- snelkoppelingen --------------------------------------------------------
$paden = @(
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Claude HUD.lnk'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Claude Deck API.lnk'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\Claude HUD.lnk'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\Claude Deck API.lnk')
)
foreach ($p in $paden) { if (Test-Path $p) { Remove-Item $p -Force; Zeg "  - $(Split-Path -Leaf $p)" } }

# ---- de map zelf ------------------------------------------------------------
if ($BewaarMap) {
    Zeg "  Map blijft staan: $Doel"
} else {
    $doen = $true
    if (-not $Stil) {
        $a = Read-Host "  Ook de map $Doel weggooien? [j/N]"
        $doen = ($a -match '^[jJyY]')
    }
    if ($doen) {
        Zeg '  De map wordt na afsluiten verwijderd.'
        # jezelf verwijderen kan niet vanuit de map zelf: even via cmd
        Start-Process -FilePath 'cmd.exe' -WindowStyle Hidden `
            -ArgumentList @('/c', 'timeout /t 2 >nul & rmdir /s /q "' + $Doel + '"')
    } else {
        Zeg "  Map blijft staan: $Doel"
    }
}
Write-Host ''
Zeg 'Klaar.' Green
if (-not $Stil) { Read-Host '  Druk op Enter om te sluiten' | Out-Null }
