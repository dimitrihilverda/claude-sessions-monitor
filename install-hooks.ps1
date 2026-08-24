# install-hooks.ps1 — zet de dashboard-beacon-hooks in je globale Claude Code-settings
# Eenmalig draaien. Idempotent: nogmaals draaien voegt niets dubbel toe.
# Maakt eerst een backup van een bestaande settings.json.
$ErrorActionPreference = 'Stop'

$settingsDir  = Join-Path $env:USERPROFILE '.claude'
$settingsPath = Join-Path $settingsDir 'settings.json'
$beacon = Join-Path $PSScriptRoot 'beacon.ps1'
if (-not (Test-Path $beacon)) { throw "beacon.ps1 niet gevonden naast dit script ($beacon)" }
$cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$beacon`""
# PostToolUse vuurt bij elke tool-aanroep en is wat een sessie uit de
# "aandacht nodig"-stand haalt zodra je een permissievraag hebt goedgekeurd.
# beacon.ps1 stapt daar in de meeste gevallen meteen weer uit.
$events = 'SessionStart','UserPromptSubmit','PostToolUse','Notification','Stop','SessionEnd'

New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null

$settings = $null
if (Test-Path $settingsPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item $settingsPath "$settingsPath.bak-$stamp"
    Write-Host "Backup gemaakt: settings.json.bak-$stamp"
    $raw = Get-Content $settingsPath -Raw
    if ($raw.Trim()) { $settings = $raw | ConvertFrom-Json }
}
if ($null -eq $settings) { $settings = [pscustomobject]@{} }

if (-not ($settings.PSObject.Properties.Name -contains 'hooks')) {
    $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
}

foreach ($ev in $events) {
    $entryJson = '{"hooks":[{"type":"command","command":' + ($cmd | ConvertTo-Json) + '}]}'
    $entry = $entryJson | ConvertFrom-Json
    $prop = $settings.hooks.PSObject.Properties[$ev]
    if ($null -eq $prop) {
        $settings.hooks | Add-Member -NotePropertyName $ev -NotePropertyValue @($entry)
        Write-Host "Toegevoegd: $ev"
    } else {
        $already = $false
        foreach ($e in @($prop.Value)) {
            foreach ($h in @($e.hooks)) {
                if ("$($h.command)" -like '*beacon.ps1*') { $already = $true }
            }
        }
        if ($already) {
            Write-Host "Stond er al:  $ev"
        } else {
            $prop.Value = @($prop.Value) + @($entry)
            Write-Host "Toegevoegd: $ev"
        }
    }
}

$settings | ConvertTo-Json -Depth 16 | Set-Content -Path $settingsPath -Encoding UTF8
Write-Host ""
Write-Host "Klaar! Hooks staan in $settingsPath"
Write-Host "Nieuwe Claude Code-sessies melden zich vanaf nu op het dashboard."
