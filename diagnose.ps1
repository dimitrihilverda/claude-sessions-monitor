# =============================================================================
#  diagnose.ps1 -- werkt de koppeling met Claude Code?
#
#  Loopt de hele keten na en doet een echte proefaanroep van de beacon, zodat
#  je ziet waar het misgaat in plaats van te moeten raden.
#
#      powershell -ExecutionPolicy Bypass -File diagnose.ps1
# =============================================================================
$ErrorActionPreference = 'Continue'
$Hier   = $PSScriptRoot
$Status = Join-Path $Hier 'session-status'
$goed = 0; $fout = 0

function OK($t)   { Write-Host "  [ok]   $t"   -ForegroundColor Green;      $script:goed++ }
function NIET($t) { Write-Host "  [fout] $t"   -ForegroundColor Red;        $script:fout++ }
function LET($t)  { Write-Host "  [let]  $t"   -ForegroundColor DarkYellow }
function INFO($t) { Write-Host "         $t"   -ForegroundColor DarkGray }
function Kop($t)  { Write-Host ''; Write-Host $t -ForegroundColor Cyan }

Kop 'Claude Deck diagnose'
INFO "map: $Hier"
INFO "PowerShell $($PSVersionTable.PSVersion)"

# ---- 1. bestanden -----------------------------------------------------------
Kop '1. Bestanden'
foreach ($f in @('sessionlib.ps1', 'focuslib.ps1', 'beacon.ps1', 'hud.ps1', 'hud.vbs')) {
    if (Test-Path (Join-Path $Hier $f)) { OK $f } else { NIET "$f ontbreekt" }
}

# ---- 2. hooks ---------------------------------------------------------------
Kop '2. Hooks in Claude Code'
$settingsPad = Join-Path $env:USERPROFILE '.claude\settings.json'
$beacon = Join-Path $Hier 'beacon.ps1'
if (-not (Test-Path $settingsPad)) {
    NIET "$settingsPad bestaat niet -- is Claude Code geinstalleerd en al eens gestart?"
} else {
    $s = $null
    try { $s = Get-Content $settingsPad -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    if (-not $s) {
        NIET "$settingsPad is geen geldige JSON"
    } elseif (-not $s.hooks) {
        NIET 'er staan helemaal geen hooks in settings.json -- draai install.ps1 opnieuw'
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
            if ($gevonden) { OK "hook $ev" } else { NIET "hook $ev ontbreekt" }
        }
        if ($paden.Keys.Count -gt 1) {
            LET 'de hooks wijzen naar meer dan een beacon.ps1; dat vuurt dubbel:'
            foreach ($k in $paden.Keys) { INFO "  $k" }
        }
        foreach ($k in $paden.Keys) {
            if (-not (Test-Path $k)) { NIET "hook wijst naar $k, maar dat bestand bestaat niet" }
            elseif ($k -ne $beacon)  { LET  "hooks wijzen naar een andere installatie: $k" }
        }
    }
}

# ---- 3. proefaanroep --------------------------------------------------------
Kop '3. Proefaanroep van de beacon'
$testId = 'diagnose-' + (Get-Date -Format 'HHmmss')
$testBestand = Join-Path $Status "$testId.json"
try {
    $payload = @{
        session_id      = $testId
        hook_event_name = 'UserPromptSubmit'
        cwd             = $Hier
        prompt          = 'proefaanroep vanuit diagnose.ps1'
        transcript_path = ''
    } | ConvertTo-Json -Compress

    $payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $beacon
    Start-Sleep -Milliseconds 400

    if (Test-Path $testBestand) {
        OK 'beacon.ps1 draait en schrijft een statusbestand'
        if (Test-Path (Join-Path $Hier 'sessions.json')) { OK 'sessions.json wordt bijgewerkt' }
        else { NIET 'sessions.json is niet aangemaakt' }
    } else {
        NIET 'beacon.ps1 schreef niets -- kijk of PowerShell het script mag draaien'
        INFO "probeer met de hand:  Get-Content -Raw <json> | powershell -File `"$beacon`""
    }
} catch {
    NIET "proefaanroep mislukt: $($_.Exception.Message)"
} finally {
    if (Test-Path $testBestand) { Remove-Item $testBestand -Force -ErrorAction SilentlyContinue }
}

# ---- 4. echte sessies -------------------------------------------------------
Kop '4. Sessies die zich gemeld hebben'
if (-not (Test-Path $Status)) {
    NIET "de map session-status bestaat niet"
} else {
    $b = @(Get-ChildItem $Status -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if (-not $b.Count) {
        NIET 'nog geen enkele sessie heeft zich gemeld'
        INFO 'Hooks gelden pas vanaf de volgende keer dat je een sessie start.'
        INFO 'Sluit je draaiende Claude Code-sessies af en start er een nieuwe;'
        INFO 'geef daarin een opdracht en draai deze diagnose opnieuw.'
    } else {
        OK "$($b.Count) statusbestand(en) gevonden"
        foreach ($f in ($b | Sort-Object LastWriteTime -Descending | Select-Object -First 6)) {
            $min = [int]((Get-Date) - $f.LastWriteTime).TotalMinutes
            $d = $null
            try { $d = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
            INFO ("  {0,-22} {1,-18} {2,4} min geleden" -f $f.BaseName.Substring(0, [Math]::Min(20, $f.BaseName.Length)), $d.event, $min)
        }
    }
}

# ---- 5. de HUD zelf ---------------------------------------------------------
Kop '5. De HUD'
$draait = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*hud.ps1*' })
if ($draait.Count) { OK "draait (pid $($draait[0].ProcessId))" } else { NIET 'draait niet -- start hud.vbs' }

$cfgPad = Join-Path $Hier 'hud-config.json'
if (Test-Path $cfgPad) {
    $cfg = $null
    try { $cfg = Get-Content $cfgPad -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    if ($cfg -and $cfg.onlyAttention) {
        LET 'het filter "alleen aandacht nodig" staat AAN -- daardoor lijkt de HUD leeg'
        INFO 'rechtermuis op de HUD om het uit te zetten'
    }
    if ($cfg) { INFO "positie: x=$($cfg.x) y=$($cfg.y)" }
} else {
    INFO 'nog geen hud-config.json; die komt er zodra de HUD een keer heeft gedraaid'
}

# ---- slot -------------------------------------------------------------------
Write-Host ''
if ($fout -eq 0) {
    Write-Host "  Alles in orde ($goed controles)." -ForegroundColor Green
    Write-Host '  Zie je toch niets, start dan een nieuwe Claude Code-sessie:' -ForegroundColor Green
    Write-Host '  sessies die al draaiden kennen de hooks nog niet.' -ForegroundColor Green
} else {
    Write-Host "  $fout probleem(en) gevonden, $goed controles in orde." -ForegroundColor Red
}
Write-Host ''
Read-Host '  Druk op Enter om te sluiten' | Out-Null
