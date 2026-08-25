# =============================================================================
#  find-title.ps1 -- where does Claude Code keep the name of a session?
#
#  If you renamed a session, that name is stored somewhere on disk. This script
#  hunts it down and shows what it finds, so the rest of the project knows
#  which source to read.
#
#      powershell -ExecutionPolicy Bypass -File find-title.ps1
#      powershell -ExecutionPolicy Bypass -File find-title.ps1 -SessionId 04240c10-...
# =============================================================================
param(
    [string]$SessionId = '',
    [string]$Naam = ''        # the name you gave the session yourself
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'sessionlib.ps1')
$claude = Join-Path $env:USERPROFILE '.claude'
$appdat = Join-Path $env:APPDATA 'Claude'

# ---- 0. search for the name itself ------------------------------------------
# This is the quickest route: if you named the session, that name is literally
# in a file and we see straight away where.
if ($Naam) {
    Write-Host "== searching for '$Naam'" -ForegroundColor Cyan
    $iets = $false
    foreach ($wortel in @($claude, $appdat)) {
        if (-not (Test-Path $wortel)) { continue }
        Get-ChildItem $wortel -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -lt 60mb -and $_.FullName -notlike '*\node_modules\*' } |
            ForEach-Object {
                try {
                    $hit = Select-String -LiteralPath $_.FullName -Pattern $Naam -SimpleMatch -ErrorAction Stop |
                           Select-Object -First 1
                    if ($hit) {
                        $iets = $true
                        Write-Host ("  -- " + $_.FullName) -ForegroundColor Green
                        $regel = [string]$hit.Line
                        # only show the part around the name, otherwise it is unreadable
                        $i = $regel.IndexOf($Naam)
                        $van = [Math]::Max(0, $i - 160)
                        $tot = [Math]::Min($regel.Length, $i + $Naam.Length + 160)
                        Write-Host ("     line " + $hit.LineNumber + ": ..." + $regel.Substring($van, $tot - $van) + "...")
                    }
                } catch {
                    # do not fail quietly: on large files with extremely long lines
                    # Select-String breaks, and it then looks as though the name is
                    # nowhere to be found
                    Write-Host ("  !! could not search " + $_.Name + ": " + $_.Exception.Message) -ForegroundColor DarkYellow
                }
            }
    }
    if (-not $iets) {
        Write-Host "  (nothing found -- is the spelling exact? case does not matter)" -ForegroundColor DarkYellow
    }
    Write-Host ""
}

# ---- which session? ---------------------------------------------------------
if (-not $SessionId) {
    $laatste = Get-ChildItem (Join-Path $PSScriptRoot 'session-status') -Filter '*.json' -File -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($laatste) { $SessionId = $laatste.BaseName }
}
if (-not $SessionId) { Write-Host "No session_id found."; exit 1 }
Write-Host "== session $SessionId" -ForegroundColor Cyan

# ---- 1. the transcript ------------------------------------------------------
$tr = Get-ChildItem (Join-Path $claude 'projects') -Recurse -Filter "$SessionId.jsonl" -File -ErrorAction SilentlyContinue |
      Select-Object -First 1
if (-not $tr) {
    Write-Host "-- no transcript found under $claude\projects" -ForegroundColor DarkYellow
} else {
    Write-Host "-- transcript: $($tr.FullName)  ($([int]($tr.Length/1kb)) kB)" -ForegroundColor Cyan
    $regels = Get-Content -LiteralPath $tr.FullName -Encoding UTF8

    Write-Host "   line types in this transcript:"
    $regels | ForEach-Object {
        if ($_ -match '"type"\s*:\s*"([^"]+)"') { $Matches[1] }
    } | Group-Object | Sort-Object Count -Descending |
        ForEach-Object { Write-Host ("     {0,5}x  {1}" -f $_.Count, $_.Name) }

    Write-Host "   lines that are not user/assistant (first 12), shortened:"
    $anders = $regels | Where-Object { $_ -notmatch '"type"\s*:\s*"(user|assistant)"' } | Select-Object -First 12
    if (-not $anders) { Write-Host "     (none)" }
    foreach ($r in $anders) {
        $k = $r; if ($k.Length -gt 300) { $k = $k.Substring(0, 300) + ' ...' }
        Write-Host "     $k"
    }

    Write-Host "   the title lines (custom-title / ai-title / summary), last 6:"
    $tn = $regels | Where-Object { $_ -match '"type"\s*:\s*"(custom-title|ai-title|summary)"' } |
          Select-Object -Last 6
    if (-not $tn) { Write-Host "     (none)" }
    foreach ($r in $tn) {
        $k = $r; if ($k.Length -gt 400) { $k = $k.Substring(0, 400) + ' ...' }
        Write-Host "     $k" -ForegroundColor Green
    }

    Write-Host "   what this project makes of it:"
    Write-Host ("     " + (Get-DashTitle $tr.FullName $SessionId)) -ForegroundColor Green
}

# ---- 2. loose files in .claude ----------------------------------------------
Write-Host "-- files in $claude changed today:" -ForegroundColor Cyan
Get-ChildItem $claude -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-1) } |
    Sort-Object LastWriteTime -Descending |
    ForEach-Object { Write-Host ("     {0,-34} {1,8} kB  {2:HH:mm}" -f $_.Name, [int]($_.Length/1kb), $_.LastWriteTime) }

Write-Host "-- folders in $claude :" -ForegroundColor Cyan
Get-ChildItem $claude -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host ("     " + $_.Name) }

# ---- 3. where else does this session_id appear? -----------------------------
Write-Host "-- other files containing this session_id:" -ForegroundColor Cyan
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
if (-not $gevonden) { Write-Host "     (nowhere else)" }
Write-Host ""
