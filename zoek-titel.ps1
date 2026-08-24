# =============================================================================
#  zoek-titel.ps1 -- waar bewaart Claude Code de naam van een sessie?
#
#  Heb je een sessie een naam gegeven met de rename-functie, dan staat die
#  ergens op schijf. Dit script zoekt hem op en laat zien wat het vindt, zodat
#  het dashboard daarna de juiste bron kan lezen.
#
#      powershell -ExecutionPolicy Bypass -File zoek-titel.ps1
#      powershell -ExecutionPolicy Bypass -File zoek-titel.ps1 -SessionId 04240c10-...
# =============================================================================
param(
    [string]$SessionId = ''
)
$ErrorActionPreference = 'Continue'
$claude = Join-Path $env:USERPROFILE '.claude'

# ---- welke sessie? ----------------------------------------------------------
if (-not $SessionId) {
    $laatste = Get-ChildItem (Join-Path $PSScriptRoot 'session-status') -Filter '*.json' -File -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($laatste) { $SessionId = $laatste.BaseName }
}
if (-not $SessionId) { Write-Host "Geen session_id gevonden."; exit 1 }
Write-Host "== sessie $SessionId" -ForegroundColor Cyan

# ---- 1. het transcript ------------------------------------------------------
$tr = Get-ChildItem (Join-Path $claude 'projects') -Recurse -Filter "$SessionId.jsonl" -File -ErrorAction SilentlyContinue |
      Select-Object -First 1
if (-not $tr) {
    Write-Host "-- geen transcript gevonden onder $claude\projects" -ForegroundColor DarkYellow
} else {
    Write-Host "-- transcript: $($tr.FullName)  ($([int]($tr.Length/1kb)) kB)" -ForegroundColor Cyan
    $regels = Get-Content -LiteralPath $tr.FullName -Encoding UTF8

    Write-Host "   regeltypen in dit transcript:"
    $regels | ForEach-Object {
        if ($_ -match '"type"\s*:\s*"([^"]+)"') { $Matches[1] }
    } | Group-Object | Sort-Object Count -Descending |
        ForEach-Object { Write-Host ("     {0,5}x  {1}" -f $_.Count, $_.Name) }

    Write-Host "   regels die geen user/assistant zijn (eerste 12), ingekort:"
    $anders = $regels | Where-Object { $_ -notmatch '"type"\s*:\s*"(user|assistant)"' } | Select-Object -First 12
    if (-not $anders) { Write-Host "     (geen)" }
    foreach ($r in $anders) {
        $k = $r; if ($k.Length -gt 300) { $k = $k.Substring(0, 300) + ' ...' }
        Write-Host "     $k"
    }

    Write-Host "   regels met title/name/summary erin (eerste 6), ingekort:"
    $tn = $regels | Where-Object { $_ -match '"(title|name|summary|customName|displayName)"\s*:' } | Select-Object -First 6
    if (-not $tn) { Write-Host "     (geen)" }
    foreach ($r in $tn) {
        $k = $r; if ($k.Length -gt 300) { $k = $k.Substring(0, 300) + ' ...' }
        Write-Host "     $k"
    }
}

# ---- 2. losse bestanden in .claude ------------------------------------------
Write-Host "-- bestanden in $claude die vandaag zijn aangepast:" -ForegroundColor Cyan
Get-ChildItem $claude -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-1) } |
    Sort-Object LastWriteTime -Descending |
    ForEach-Object { Write-Host ("     {0,-34} {1,8} kB  {2:HH:mm}" -f $_.Name, [int]($_.Length/1kb), $_.LastWriteTime) }

Write-Host "-- mappen in $claude :" -ForegroundColor Cyan
Get-ChildItem $claude -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host ("     " + $_.Name) }

# ---- 3. waar komt dit session_id nog voor? ---------------------------------
Write-Host "-- andere bestanden waarin dit session_id voorkomt:" -ForegroundColor Cyan
$gevonden = $false
Get-ChildItem $claude -Recurse -File -Include *.json,*.jsonl,*.db,*.txt -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notlike '*\projects\*' -and $_.Length -lt 20mb } |
    ForEach-Object {
        try {
            if (Select-String -LiteralPath $_.FullName -Pattern $SessionId -SimpleMatch -Quiet -ErrorAction Stop) {
                Write-Host ("     " + $_.FullName)
                $gevonden = $true
            }
        } catch { }
    }
if (-not $gevonden) { Write-Host "     (nergens anders)" }
Write-Host ""
