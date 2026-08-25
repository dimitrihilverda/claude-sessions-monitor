# =============================================================================
#  uninstall.ps1 -- remove Claude Sessions Monitor again
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
Zeg 'Removing Claude Sessions Monitor' Cyan

# ---- stop anything that is running ------------------------------------------
# note: this script runs from $Doel as well, so skip ourselves
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='wscript.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*$Doel*" -and $_.ProcessId -ne $PID -and $_.CommandLine -notlike '*uninstall.ps1*' } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
Zeg '  HUD and web service stopped'

# ---- remove the hooks -------------------------------------------------------
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
    Zeg "  $weg hook(s) removed from settings.json (backup: settings.json.bak-$stamp)"
}

# ---- shortcuts --------------------------------------------------------------
$paden = @(
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Claude HUD.lnk'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Claude Deck API.lnk'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\Claude HUD.lnk'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\Claude Deck API.lnk')
)
foreach ($p in $paden) { if (Test-Path $p) { Remove-Item $p -Force; Zeg "  - $(Split-Path -Leaf $p)" } }

# ---- the folder itself ------------------------------------------------------
if ($BewaarMap) {
    Zeg "  Folder kept: $Doel"
} else {
    $doen = $true
    if (-not $Stil) {
        $a = Read-Host "  Delete the folder $Doel as well? [y/N]"
        $doen = ($a -match '^[yYjJ]')
    }
    if ($doen) {
        Zeg '  The folder will be removed after this closes.'
        # you cannot delete the folder you are running from: go via cmd
        Start-Process -FilePath 'cmd.exe' -WindowStyle Hidden `
            -ArgumentList @('/c', 'timeout /t 2 >nul & rmdir /s /q "' + $Doel + '"')
    } else {
        Zeg "  Folder kept: $Doel"
    }
}
Write-Host ''
Zeg 'Done.' Green
if (-not $Stil) { Read-Host '  Press Enter to close' | Out-Null }
