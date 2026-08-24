# =============================================================================
#  sessionlib.ps1 -- gedeelde sessielogica voor het Claude-dashboard van Dimmy
#  Dot-source dit bestand:   . (Join-Path $PSScriptRoot 'sessionlib.ps1')
#  Gebruikt door: beacon.ps1 (hooks), hud.ps1 (floating HUD), session-api.ps1 (CYD)
# =============================================================================

# ---- instellingen -----------------------------------------------------------
# Een sessie verdwijnt uit beeld zodra het Claude-proces weg is. De TTL is
# alleen nog een vangnet voor beacons waarvan we de PID niet konden bepalen.
$DashMaxAgeMinutes = 45

# Sessies in deze mappen nooit tonen. Standaard leeg: je wilt alles zien,
# inclusief de Cowork-sessie waarin je met Claude aan het dashboard werkt.
# Wil je een map toch wegfilteren, zet het volledige pad hier neer.
$DashHideCwds = @()

# ---- statusnamen ------------------------------------------------------------
#  attention = Claude vraagt echt iets van je (hook-event Notification)
#  active    = Claude is aan het werk (SessionStart / UserPromptSubmit /
#              PreToolUse / PostToolUse -- die laatste twee vuren tijdens het
#              werk en halen een sessie dus uit de attention-stand zodra je een
#              permissievraag hebt goedgekeurd)
#  done      = Claude is klaar met antwoorden (Stop) -- geen alarm, jouw beurt
#  ended     = sessie afgesloten (SessionEnd) -> niet tonen, opruimen
function Get-DashState([string]$ev) {
    switch ($ev) {
        'Notification'     { return 'attention' }
        'Stop'             { return 'done' }
        'SessionStart'     { return 'active' }
        'UserPromptSubmit' { return 'active' }
        'PreToolUse'       { return 'active' }
        'PostToolUse'      { return 'active' }
        'SessionEnd'       { return 'ended' }
        default            { return 'unknown' }
    }
}

function Get-DashStateLabel([string]$state) {
    switch ($state) {
        'attention' { return 'Aandacht nodig' }
        'active'    { return 'Actief' }
        'done'      { return 'Klaar' }
        'ended'     { return 'Afgerond' }
        default     { return 'Onbekend' }
    }
}

function Get-DashRank([string]$state) {
    switch ($state) {
        'attention' { return 0 }
        'active'    { return 1 }
        'done'      { return 2 }
        default     { return 3 }
    }
}

# ---- proceseigenaar ---------------------------------------------------------
# De hook draait als kleinkind van het Claude Code-proces (claude/node).
# We lopen de ouderketen omhoog tot we dat proces vinden en bewaren PID +
# starttijd. Zo weet het dashboard later of de sessie nog echt leeft; een
# SessionStart zonder SessionEnd (terminal hard afgesloten, crash) verdwijnt
# dan meteen in plaats van een uur als "Actief" te blijven staan.
function Get-DashOwner {
    param([int]$FromPid = $PID)

    $cur = $FromPid
    for ($i = 0; $i -lt 8; $i++) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue
        if (-not $p) { break }
        $ppid = [int]$p.ParentProcessId
        if ($ppid -le 4) { break }
        $par = Get-CimInstance Win32_Process -Filter "ProcessId=$ppid" -ErrorAction SilentlyContinue
        if (-not $par) { break }
        if ([string]$par.Name -match '^(node|claude)\.exe$') {
            $start = ''
            try { $start = (Get-Process -Id $ppid -ErrorAction Stop).StartTime.ToString('o') } catch { }
            return [pscustomobject]@{ OwnerPid = $ppid; Start = $start }
        }
        $cur = $ppid
    }
    return [pscustomobject]@{ OwnerPid = 0; Start = '' }
}

# $true = leeft, $false = weg, $null = onbekend (oude beacon zonder PID)
function Test-DashOwnerAlive($s) {
    $opid = 0
    if ($s.PSObject.Properties['owner_pid'] -and $s.owner_pid) { $opid = [int]$s.owner_pid }
    if ($opid -le 0) { return $null }

    $p = $null
    try { $p = Get-Process -Id $opid -ErrorAction Stop } catch { return $false }
    if (-not $p) { return $false }

    # PID's worden hergebruikt; de starttijd moet ook kloppen.
    if ($s.PSObject.Properties['owner_start'] -and $s.owner_start) {
        try {
            $st = [datetime]::Parse([string]$s.owner_start, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
            if ([math]::Abs(($p.StartTime - $st).TotalSeconds) -gt 5) { return $false }
        } catch { }
    }
    return $true
}

# ---- de sessielijst ---------------------------------------------------------
# Leest alle beacons, bepaalt status en zichtbaarheid, voegt /clear-dubbelingen
# samen (zelfde Claude-proces = een sessie) en ruimt met -Prune dode bestanden op.
function Get-DashSessions {
    param(
        [Parameter(Mandatory = $true)][string]$Dir,
        [string]$SnoozeFile = '',
        [switch]$Prune
    )

    if (-not (Test-Path $Dir)) { return @() }
    $now  = Get-Date
    $list = @()

    # Gesnoozede sessies: wel zichtbaar, maar niet oranje en geen piepje.
    if (-not $SnoozeFile) { $SnoozeFile = Join-Path (Split-Path -Parent $Dir) 'snooze.json' }
    $snooze = @{}
    if (Test-Path $SnoozeFile) {
        try {
            $sn = Get-Content $SnoozeFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($prop in $sn.PSObject.Properties) {
                try {
                    $until = [datetime]$prop.Value
                    if ($until -gt $now) { $snooze[$prop.Name] = $until }
                } catch { }
            }
        } catch { }
    }

    foreach ($f in (Get-ChildItem -Path $Dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $s = $null
        try { $s = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        if (-not $s -or -not $s.session_id) { continue }

        $upd = $f.LastWriteTime
        try { if ($s.updated) { $upd = [datetime]$s.updated } } catch { }
        $ageMin = [math]::Round(($now - $upd).TotalMinutes, 1)

        $state = Get-DashState ([string]$s.event)
        $alive = Test-DashOwnerAlive $s

        $snoozedUntil = $null
        if ($state -eq 'attention' -and $snooze.ContainsKey([string]$s.session_id)) {
            $snoozedUntil = $snooze[[string]$s.session_id]
            $state = 'done'
        }

        if ($Prune -and ($state -eq 'ended' -or $alive -eq $false -or $ageMin -gt 1440)) {
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
            continue
        }

        $cwd  = [string]$s.cwd
        $name = 'Claude'
        if ($cwd) { try { $name = Split-Path -Leaf $cwd } catch { } }
        if (-not $name) { $name = 'Claude' }

        $hidden = $false
        foreach ($h in $DashHideCwds) {
            if ($h -and $cwd -and ($cwd.TrimEnd('\') -ieq ([string]$h).TrimEnd('\'))) { $hidden = $true }
        }

        if ($state -eq 'attention') {
            $why = if ($s.message) { [string]$s.message } else { 'Claude heeft je input nodig.' }
        } else {
            $why = [string]$s.prompt
        }

        $visible = (-not $hidden) -and (@('attention','active','done') -contains $state) -and ($alive -ne $false)
        if ($visible -and ($null -eq $alive) -and ($ageMin -gt $DashMaxAgeMinutes)) { $visible = $false }

        $opid = 0
        if ($s.PSObject.Properties['owner_pid'] -and $s.owner_pid) { $opid = [int]$s.owner_pid }

        $list += [pscustomobject]@{
            session_id = [string]$s.session_id
            event      = [string]$s.event
            state      = $state
            rank       = (Get-DashRank $state)
            cwd        = $cwd
            name       = $name
            label      = $(if ($snoozedUntil) { 'Snooze tot ' + $snoozedUntil.ToString('HH:mm') } else { Get-DashStateLabel $state })
            snoozed    = [bool]$snoozedUntil
            why        = $why
            updated    = $upd.ToString('yyyy-MM-ddTHH:mm:sszzz')
            since      = $upd.ToString('HH:mm')
            age_min    = $ageMin
            owner_pid  = $opid
            alive      = $alive
            hidden     = $hidden
            visible    = $visible
            sort_ts    = $upd
        }
    }

    # /clear geeft dezelfde terminal een nieuwe session_id: per Claude-proces
    # (en bij onbekende PID per map) houden we alleen de nieuwste over.
    $groups = @{}
    foreach ($x in ($list | Where-Object { $_.visible } | Sort-Object sort_ts -Descending)) {
        if ($x.owner_pid -gt 0) { $key = 'p' + $x.owner_pid } else { $key = 'c' + $x.cwd.ToLower() }
        if ($groups.ContainsKey($key)) { $x.visible = $false } else { $groups[$key] = $true }
    }

    return ($list | Sort-Object @{Expression='rank'}, @{Expression='sort_ts'; Descending=$true})
}

# ---- uitvoer voor de pagina en de CYD --------------------------------------
function Write-DashPayload {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$Sessions
    )

    $vis = @($Sessions | Where-Object { $_.visible })
    $out = @()
    foreach ($s in $vis) {
        $out += [ordered]@{
            session_id = $s.session_id
            snoozed    = [bool]$s.snoozed
            event      = $s.event
            state      = $s.state
            cwd        = $s.cwd
            name       = $s.name
            label      = $s.label
            why        = $s.why
            since      = $s.since
            updated    = $s.updated
        }
    }

    $payload = [ordered]@{
        generated = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        attention = @($vis | Where-Object { $_.state -eq 'attention' }).Count
        active    = @($vis | Where-Object { $_.state -eq 'active' }).Count
        done      = @($vis | Where-Object { $_.state -eq 'done' }).Count
        known     = @($Sessions).Count
        sessions  = @($out)
    }

    $json = $payload | ConvertTo-Json -Depth 6 -Compress
    $utf8 = New-Object System.Text.UTF8Encoding($false)

    # sessions.json = voor de HUD en de CYD, sessions.js = voor dashboard.html
    # (een <script src> mag wel op file://, een fetch() niet)
    $targets = @(
        @{ Path = (Join-Path $Root 'sessions.json'); Text = $json },
        @{ Path = (Join-Path $Root 'sessions.js');   Text = ('window.__SESSIONS_PAYLOAD = ' + $json + ';') }
    )
    # Eerst naar .tmp en dan omwisselen: de HUD schrijft elke 3 seconden en het
    # dashboard leest sessions.js elke 15 seconden -- zonder deze truc lees je
    # af en toe een half bestand.
    foreach ($t in $targets) {
        $tmp = $t.Path + '.tmp'
        for ($i = 0; $i -lt 5; $i++) {
            try {
                [System.IO.File]::WriteAllText($tmp, $t.Text, $utf8)
                if (Test-Path $t.Path) { [System.IO.File]::Replace($tmp, $t.Path, $null) }
                else                   { [System.IO.File]::Move($tmp, $t.Path) }
                break
            } catch {
                Start-Sleep -Milliseconds 120
                try { [System.IO.File]::WriteAllText($t.Path, $t.Text, $utf8) } catch { }
                # Replace() kan mislukken als de pagina sessions.js net openheeft;
                # ruim het tijdelijke bestand dan op, anders blijft het rondslingeren.
                try { if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } } catch { }
            }
        }
    }
    return $payload
}
