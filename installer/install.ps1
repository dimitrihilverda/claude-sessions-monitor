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
    $hint = if ($standaard) { '[Y/n]' } else { '[y/N]' }
    $a = Read-Host "$vraag $hint"
    if (-not $a) { return $standaard }
    return ($a -match '^[yYjJ]')   # accept j as well, for Dutch keyboards out of habit
}

Kop 'Installing Claude Sessions Monitor'

function Stop-Netjes($tekst) {
    Zeg $tekst Red
    Write-Host ''
    if (-not $Stil) { Read-Host '  Press Enter to close' | Out-Null }
    exit 1
}

# ---- 1. voorwaarden ---------------------------------------------------------
# Windows lets you open a zip as if it were a folder, and this script then runs
# from a temporary folder that does not hold everything.
if ($bron -match '\\Temp\\Temp\d*_' -or $bron -match '\.zip\\') {
    Stop-Netjes ("  You are running this from inside the zip file.`r`n" +
                 "  Unpack the folder first (right-click the zip -> Extract All)`r`n" +
                 "  then double-click Install.cmd in the unpacked folder.")
}
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Stop-Netjes "  PowerShell 5.1 or newer is required; you have $($PSVersionTable.PSVersion)."
}
$claudeMap = Join-Path $env:USERPROFILE '.claude'
if (-not (Test-Path $claudeMap)) {
    Zeg "  Note: $claudeMap does not exist yet." DarkYellow
    Zeg "  That is the Claude Code folder. Is it installed?" DarkYellow
    if (-not (Vraag '  Continue anyway?' $false)) { return }
}

# ---- 2. waarheen ------------------------------------------------------------
if (-not $Stil) {
    $a = Read-Host "  Install folder [$Doel]"
    if ($a) { $Doel = $a }
}
Zeg "  Folder: $Doel"

$draaide = @(Get-Process -Name powershell, pwsh -ErrorAction SilentlyContinue |
             Where-Object { $_.MainWindowTitle -like '*Claude-sessies*' })
if ($draaide) { Zeg '  A HUD is already running; it will be closed.' DarkGray }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='wscript.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*hud.ps1*' -or $_.CommandLine -like '*hud.vbs*' } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }

# ---- 3. kopieren ------------------------------------------------------------
Kop 'Copying files'
New-Item -ItemType Directory -Force -Path $Doel | Out-Null

$kern = @('sessionlib.ps1', 'focuslib.ps1', 'langlib.ps1', 'beacon.ps1', 'hud.ps1', 'hud.vbs',
          'check-titles.ps1', 'find-title.ps1', 'diagnose.ps1', 'Diagnose.cmd',
          'uninstall.ps1', 'README-installer.md', 'updatelib.ps1', 'VERSION')
$touch = @('session-api.ps1', 'api.vbs', 'actions.json')

foreach ($f in $kern) {
    $pad = Join-Path $bron $f
    if (Test-Path $pad) { Copy-Item $pad -Destination $Doel -Force; Zeg "  + $f" }
    else { Zeg "  ! $f is missing from the package" DarkYellow }
}

if (-not $Stil) {
    $MetTouchscreen = Vraag '  Also the web service for a touchscreen (Cheap Yellow Display)?' $MetTouchscreen.IsPresent
}
if ($MetTouchscreen) {
    foreach ($f in $touch) {
        $pad = Join-Path $bron $f
        if (Test-Path $pad) {
            # do not overwrite an existing actions.json holding your own button actions
            $doelpad = Join-Path $Doel $f
            if ($f -eq 'actions.json' -and (Test-Path $doelpad)) { Zeg "  = $f (keeping your existing settings)"; continue }
            Copy-Item $pad -Destination $Doel -Force; Zeg "  + $f"
        }
    }
    $cydBron = Join-Path $bron 'cyd'
    if (Test-Path $cydBron) { Copy-Item $cydBron -Destination $Doel -Recurse -Force; Zeg '  + cyd\ (sketch and instructions)' }
}

New-Item -ItemType Directory -Force -Path (Join-Path $Doel 'session-status') | Out-Null

# ---- 4. hooks ---------------------------------------------------------------
Kop 'Linking to Claude Code'
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
    # replace existing references to a beacon.ps1: that way an older install
    # migrates cleanly instead of firing twice
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
Zeg "  $nieuw hook(s) added, $bijgewerkt updated in $settingsPad"
Zeg '  Sessions already running pick this up only after they restart.' DarkGray

# ---- 5. snelkoppelingen -----------------------------------------------------
Kop 'Shortcuts'
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
Zeg '  + Start menu: Claude HUD'

if (-not $Stil) { $Autostart = Vraag '  Start when you log in?' $Autostart.IsPresent }
$startup     = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$startupLnk  = Join-Path $startup 'Claude HUD.lnk'
$startupApi  = Join-Path $startup 'Claude Deck API.lnk'
if ($Autostart) {
    Maak-Snelkoppeling $startupLnk (Join-Path $Doel 'hud.vbs') 'Claude-sessies in beeld'
    Zeg '  + autostart on'
} elseif (Test-Path $startupLnk) {
    Remove-Item $startupLnk -Force
    Zeg '  - autostart off'
}

if ($MetTouchscreen) {
    Maak-Snelkoppeling (Join-Path $startMenu 'Claude Deck API.lnk') (Join-Path $Doel 'api.vbs') 'Webservice voor het touchscreen'
    Zeg '  + Start menu: Claude Deck API'

    # De API hoort mee te starten met de HUD. Zonder die service staat er op het
    # touchscreen "GEEN VERBINDING" en ga je zoeken bij het schermpje, terwijl
    # de bron op je pc simpelweg uit staat.
    if ($Autostart) {
        Maak-Snelkoppeling $startupApi (Join-Path $Doel 'api.vbs') 'Webservice voor het touchscreen'
        Zeg '  + autostart on for the web service'
    } elseif (Test-Path $startupApi) {
        Remove-Item $startupApi -Force
        Zeg '  - autostart off for the web service'
    }
} elseif (Test-Path $startupApi) {
    # touchscreen niet (meer) gekozen: de autostart van de webservice weghalen
    Remove-Item $startupApi -Force
    Zeg '  - web service autostart removed'
}

# ---- 6. starten -------------------------------------------------------------
Kop 'Done'
Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + (Join-Path $Doel 'hud.vbs') + '"') -WorkingDirectory $Doel
Zeg '  The HUD is now in the top right. Drag it wherever you like.' Green
Zeg '  Right-click for the menu: compact, attention only, restart, quit.'
if ($MetTouchscreen) {
    # De HUD start hierboven al; de webservice hoort er meteen bij te komen,
    # anders staat het touchscreen tot de volgende keer inloggen op
    # "GEEN VERBINDING" terwijl de installatie zegt dat alles klaar is.
    Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + (Join-Path $Doel 'api.vbs') + '"') -WorkingDirectory $Doel
    Zeg ''
    Zeg '  The web service for the touchscreen is running too.' Green
    if ($Autostart) { Zeg '  From now on it starts every time you log in.' }
    else            { Zeg '  After a restart, start it via "Claude Deck API" in the Start menu.' DarkYellow }
    Zeg '  Windows Firewall asks for permission the first time -- choose private networks.'
    Zeg "  Flashing instructions are in $Doel\cyd\README-cyd.md"
}
Zeg ''
Zeg "  To remove it: $Doel\uninstall.ps1" DarkGray
Write-Host ''
if (-not $Stil) { Read-Host '  Druk op Enter om te sluiten' | Out-Null }
