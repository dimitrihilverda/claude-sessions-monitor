# =============================================================================
#  install.ps1 -- Claude Deck installeren op Windows
#
#  Zet de HUD neer, koppelt hem aan de hooks van Claude Code en maakt
#  snelkoppelingen. Draaien zonder administratorrechten.
#
#      powershell -ExecutionPolicy Bypass -File install.ps1
#
#  Of zonder vragen, bijvoorbeeld om uit te rollen:
#      install.ps1 -Stil -Autostart -MetTouchscreen
# =============================================================================
[CmdletBinding()]
param(
    [string]$Doel = (Join-Path $env:LOCALAPPDATA 'ClaudeDeck'),
    [switch]$Autostart,
    [switch]$MetTouchscreen,
    [switch]$Stil
)
$ErrorActionPreference = 'Stop'
$bron = $PSScriptRoot

function Zeg($tekst, $kleur = 'Gray') { Write-Host $tekst -ForegroundColor $kleur }
function Kop($tekst) { Write-Host ''; Write-Host $tekst -ForegroundColor Cyan }

function Vraag($vraag, $standaard) {
    if ($Stil) { return $standaard }
    $hint = if ($standaard) { '[J/n]' } else { '[j/N]' }
    $a = Read-Host "$vraag $hint"
    if (-not $a) { return $standaard }
    return ($a -match '^[jJyY]')
}

Kop 'Claude Deck installeren'

function Stop-Netjes($tekst) {
    Zeg $tekst Red
    Write-Host ''
    if (-not $Stil) { Read-Host '  Druk op Enter om te sluiten' | Out-Null }
    exit 1
}

# ---- 1. voorwaarden ---------------------------------------------------------
# Windows laat je een zipbestand openen alsof het een map is, en dan draait dit
# script vanuit een tijdelijke map waar niet alles in staat.
if ($bron -match '\\Temp\\Temp\d*_' -or $bron -match '\.zip\\') {
    Stop-Netjes ("  Je draait dit vanuit het zipbestand zelf.`r`n" +
                 "  Pak de map eerst uit (rechtermuis op de zip -> Alles uitpakken)`r`n" +
                 "  en dubbelklik daarna Installeer.cmd in de uitgepakte map.")
}
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Stop-Netjes "  PowerShell 5.1 of nieuwer is nodig; je hebt $($PSVersionTable.PSVersion)."
}
$claudeMap = Join-Path $env:USERPROFILE '.claude'
if (-not (Test-Path $claudeMap)) {
    Zeg "  Let op: $claudeMap bestaat nog niet." DarkYellow
    Zeg "  Dat is de map van Claude Code. Is die wel geinstalleerd?" DarkYellow
    if (-not (Vraag '  Toch doorgaan?' $false)) { return }
}

# ---- 2. waarheen ------------------------------------------------------------
if (-not $Stil) {
    $a = Read-Host "  Installatiemap [$Doel]"
    if ($a) { $Doel = $a }
}
Zeg "  Map: $Doel"

$draaide = @(Get-Process -Name powershell, pwsh -ErrorAction SilentlyContinue |
             Where-Object { $_.MainWindowTitle -like '*Claude-sessies*' })
if ($draaide) { Zeg '  Er draait al een HUD; die sluit ik zo af.' DarkGray }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='wscript.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*hud.ps1*' -or $_.CommandLine -like '*hud.vbs*' } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }

# ---- 3. kopieren ------------------------------------------------------------
Kop 'Bestanden neerzetten'
New-Item -ItemType Directory -Force -Path $Doel | Out-Null

$kern = @('sessionlib.ps1', 'focuslib.ps1', 'beacon.ps1', 'hud.ps1', 'hud.vbs',
          'check-titels.ps1', 'zoek-titel.ps1', 'diagnose.ps1', 'Diagnose.cmd',
          'uninstall.ps1', 'LEESMIJ.md')
$touch = @('session-api.ps1', 'api.vbs', 'actions.json')

foreach ($f in $kern) {
    $pad = Join-Path $bron $f
    if (Test-Path $pad) { Copy-Item $pad -Destination $Doel -Force; Zeg "  + $f" }
    else { Zeg "  ! $f ontbreekt in het pakket" DarkYellow }
}

if (-not $Stil) {
    $MetTouchscreen = Vraag '  Ook de webservice voor een touchscreen (Cheap Yellow Display)?' $MetTouchscreen.IsPresent
}
if ($MetTouchscreen) {
    foreach ($f in $touch) {
        $pad = Join-Path $bron $f
        if (Test-Path $pad) {
            # een bestaande actions.json met eigen knopacties niet overschrijven
            $doelpad = Join-Path $Doel $f
            if ($f -eq 'actions.json' -and (Test-Path $doelpad)) { Zeg "  = $f (bestaande instellingen behouden)"; continue }
            Copy-Item $pad -Destination $Doel -Force; Zeg "  + $f"
        }
    }
    $cydBron = Join-Path $bron 'cyd'
    if (Test-Path $cydBron) { Copy-Item $cydBron -Destination $Doel -Recurse -Force; Zeg '  + cyd\ (sketch en instructies)' }
}

New-Item -ItemType Directory -Force -Path (Join-Path $Doel 'session-status') | Out-Null

# ---- 4. hooks ---------------------------------------------------------------
Kop 'Koppelen aan Claude Code'
$settingsPad = Join-Path $claudeMap 'settings.json'
$beacon = Join-Path $Doel 'beacon.ps1'
$cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$beacon`""
$events = 'SessionStart', 'UserPromptSubmit', 'PostToolUse', 'Notification', 'Stop', 'SessionEnd'

New-Item -ItemType Directory -Force -Path $claudeMap | Out-Null
$settings = $null
if (Test-Path $settingsPad) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item $settingsPad "$settingsPad.bak-$stamp"
    Zeg "  Backup: settings.json.bak-$stamp"
    $rauw = Get-Content $settingsPad -Raw
    if ($rauw.Trim()) { $settings = $rauw | ConvertFrom-Json }
}
if ($null -eq $settings) { $settings = [pscustomobject]@{} }
if (-not ($settings.PSObject.Properties.Name -contains 'hooks')) {
    $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
}

$nieuw = 0; $bijgewerkt = 0
foreach ($ev in $events) {
    $entry = ('{"hooks":[{"type":"command","command":' + ($cmd | ConvertTo-Json) + '}]}') | ConvertFrom-Json
    $prop = $settings.hooks.PSObject.Properties[$ev]
    if ($null -eq $prop) {
        $settings.hooks | Add-Member -NotePropertyName $ev -NotePropertyValue @($entry)
        $nieuw++
        continue
    }
    # bestaande verwijzingen naar een beacon.ps1 vervangen: zo verhuist een
    # oudere installatie netjes mee in plaats van dubbel te vuren
    $anderen = @()
    $had = $false
    foreach ($e in @($prop.Value)) {
        $isBeacon = $false
        foreach ($hk in @($e.hooks)) { if ("$($hk.command)" -like '*beacon.ps1*') { $isBeacon = $true } }
        if ($isBeacon) { $had = $true } else { $anderen += $e }
    }
    $prop.Value = @($anderen) + @($entry)
    if ($had) { $bijgewerkt++ } else { $nieuw++ }
}
$settings | ConvertTo-Json -Depth 16 | Set-Content -Path $settingsPad -Encoding UTF8
Zeg "  $nieuw hook(s) toegevoegd, $bijgewerkt bijgewerkt in $settingsPad"
Zeg '  Sessies die al draaien pikken dit pas op na een herstart van die sessie.' DarkGray

# ---- 5. snelkoppelingen -----------------------------------------------------
Kop 'Snelkoppelingen'
$ws = New-Object -ComObject WScript.Shell

function Maak-Snelkoppeling($pad, $doelBestand, $omschrijving) {
    $sc = $ws.CreateShortcut($pad)
    $sc.TargetPath = 'wscript.exe'
    $sc.Arguments = '"' + $doelBestand + '"'
    $sc.WorkingDirectory = $Doel
    $sc.Description = $omschrijving
    $sc.Save()
}

$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
Maak-Snelkoppeling (Join-Path $startMenu 'Claude HUD.lnk') (Join-Path $Doel 'hud.vbs') 'Claude-sessies in beeld'
Zeg '  + startmenu: Claude HUD'

if (-not $Stil) { $Autostart = Vraag '  HUD starten bij inloggen?' $Autostart.IsPresent }
$startup     = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$startupLnk  = Join-Path $startup 'Claude HUD.lnk'
$startupApi  = Join-Path $startup 'Claude Deck API.lnk'
if ($Autostart) {
    Maak-Snelkoppeling $startupLnk (Join-Path $Doel 'hud.vbs') 'Claude-sessies in beeld'
    Zeg '  + autostart aan'
} elseif (Test-Path $startupLnk) {
    Remove-Item $startupLnk -Force
    Zeg '  - autostart uit'
}

if ($MetTouchscreen) {
    Maak-Snelkoppeling (Join-Path $startMenu 'Claude Deck API.lnk') (Join-Path $Doel 'api.vbs') 'Webservice voor het touchscreen'
    Zeg '  + startmenu: Claude Deck API'

    # De API hoort mee te starten met de HUD. Zonder die service staat er op het
    # touchscreen "GEEN VERBINDING" en ga je zoeken bij het schermpje, terwijl
    # de bron op je pc simpelweg uit staat.
    if ($Autostart) {
        Maak-Snelkoppeling $startupApi (Join-Path $Doel 'api.vbs') 'Webservice voor het touchscreen'
        Zeg '  + autostart aan voor de webservice'
    } elseif (Test-Path $startupApi) {
        Remove-Item $startupApi -Force
        Zeg '  - autostart uit voor de webservice'
    }
} elseif (Test-Path $startupApi) {
    # touchscreen niet (meer) gekozen: de autostart van de webservice weghalen
    Remove-Item $startupApi -Force
    Zeg '  - autostart webservice weggehaald'
}

# ---- 6. starten -------------------------------------------------------------
Kop 'Klaar'
Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + (Join-Path $Doel 'hud.vbs') + '"') -WorkingDirectory $Doel
Zeg '  De HUD staat nu rechtsboven in beeld. Sleep hem waar je wilt.' Green
Zeg '  Rechtermuisknop geeft het menu: compact, alleen aandacht, herstarten, afsluiten.'
if ($MetTouchscreen) {
    # De HUD start hierboven al; de webservice hoort er meteen bij te komen,
    # anders staat het touchscreen tot de volgende keer inloggen op
    # "GEEN VERBINDING" terwijl de installatie zegt dat alles klaar is.
    Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + (Join-Path $Doel 'api.vbs') + '"') -WorkingDirectory $Doel
    Zeg ''
    Zeg '  De webservice voor het touchscreen draait nu ook.' Green
    if ($Autostart) { Zeg '  Hij komt vanaf nu bij elke keer inloggen mee.' }
    else            { Zeg '  Start hem na een herstart via "Claude Deck API" in het startmenu.' DarkYellow }
    Zeg '  Windows Firewall vraagt de eerste keer om toestemming -- kies prive-netwerken.'
    Zeg "  Flash-instructies staan in $Doel\cyd\README-cyd.md"
}
Zeg ''
Zeg "  Verwijderen kan met: $Doel\uninstall.ps1" DarkGray
Write-Host ''
if (-not $Stil) { Read-Host '  Druk op Enter om te sluiten' | Out-Null }
