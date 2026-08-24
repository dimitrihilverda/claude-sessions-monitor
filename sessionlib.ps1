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

# ---- de tabtitel van de terminal --------------------------------------------
# Claude Code werkt de titel van zijn terminaltab live bij. Dat is de echte
# naam van een sessie. Twee beperkingen zijn hier onvermijdelijk:
#   * alleen een terminal geeft die titel door aan het venster. Draait de sessie
#     in de PhpStorm-terminal, dan is de venstertitel die van PhpStorm en niet
#     die van Claude; dan valt hij terug op de transcript-titel.
#   * staan er meer sessies in hetzelfde terminalvenster (tabs), dan hoort de
#     venstertitel bij het actieve tabblad. Welke dat is weten we niet, dus dan
#     gebruiken we hem voor geen van beide.
$DashTerminals = @(
    'windowsterminal','openconsole','conhost','cmd','powershell','pwsh','wt',
    'alacritty','wezterm-gui','mintty','kitty','tabby'
)

# De Claude-desktopapp (Cowork) hangt ook aan een venster, maar dat heet altijd
# gewoon "Claude". Die titel zegt niets, dus die sessies krijgen hun mapnaam met
# een label ervoor.
$DashDesktopHosts = @('claude')

# Een beacon van een Cowork-sessie kan zonder proces-ID zijn geschreven. Dan
# zoeken we het venster van de desktopapp er zelf bij, zodat klikken op zo'n
# sessie ook gewoon werkt.
function Get-DashDesktopPid {
    foreach ($naam in $DashDesktopHosts) {
        $p = Get-Process -Name $naam -ErrorAction SilentlyContinue |
             Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } |
             Select-Object -First 1
        if ($p) { return [int]$p.Id }
    }
    return 0
}

# eerste voorouder met een echt venster; die zetten we in het beacon-bestand
function Get-DashHostPid([int]$fromPid) {
    $id = $fromPid
    for ($i = 0; $i -lt 8 -and $id -gt 4; $i++) {
        try {
            $p = Get-Process -Id $id -ErrorAction Stop
            if ($p.MainWindowHandle -ne [IntPtr]::Zero) { return $id }
        } catch { }
        $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
        if (-not $ci) { break }
        $id = [int]$ci.ParentProcessId
    }
    return 0
}

function Get-DashHostInfo([int]$hostPid) {
    if ($hostPid -le 0) { return $null }
    try { $p = Get-Process -Id $hostPid -ErrorAction Stop } catch { return $null }
    if (-not $p) { return $null }
    return [pscustomobject]@{
        Name  = $p.ProcessName.ToLower()
        Title = [string]$p.MainWindowTitle
    }
}

function Get-DashCleanTab([string]$raw) {
    $t = ([string]$raw -replace '\s+', ' ').Trim()
    if (-not $t) { return '' }
    # statusbolletjes en sterretjes die Claude Code ervoor zet weghalen
    $t = ($t -replace '^[^\p{L}\p{N}]+', '').Trim()
    if (-not $t) { return '' }
    # een kale terminalnaam of een pad is geen sessietitel
    if ($t -match '^(Windows PowerShell|Command Prompt|cmd|cmd\.exe|pwsh|powershell|Terminal)$') { return '' }
    if ($t -match '^[A-Za-z]:\\') { return '' }
    if ($t -match '^Administrator:') { $t = ($t -replace '^Administrator:\s*', '') }
    return (Get-DashShort $t 48)
}

function Get-DashTabTitle([int]$hostPid) {
    $info = Get-DashHostInfo $hostPid
    if (-not $info) { return '' }
    if ($DashTerminals -notcontains $info.Name) { return '' }
    return (Get-DashCleanTab $info.Title)
}

# ---- de titel van een sessie ------------------------------------------------
# De mapnaam is geen goede naam: draaien er twee sessies in dezelfde map, dan
# heten ze allebei hetzelfde. Claude Code houdt zelf een samenvatting bij in het
# transcript dat de hook meestuurt; die gebruiken we als titel, en anders de
# eerste opdracht uit het gesprek.
function Get-DashTranscript([string]$path, [string]$sessionId) {
    if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    if ($sessionId) {
        $root = Join-Path $env:USERPROFILE '.claude\projects'
        if (Test-Path $root) {
            $hit = Get-ChildItem -Path $root -Filter ($sessionId + '.jsonl') -Recurse -File -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    return ''
}

function Get-DashShort([string]$s, [int]$max = 34) {
    $s = ([string]$s -replace '\s+', ' ').Trim()
    if ($s.Length -gt $max) { $s = $s.Substring(0, $max - 1) + '...' }
    return $s
}

function Get-DashTitle([string]$path, [string]$sessionId) {
    $file = Get-DashTranscript $path $sessionId
    if (-not $file) { return '' }

    # Claude Code schrijft de naam van een sessie als losse regels in het
    # transcript. Drie soorten, in deze voorkeursvolgorde:
    #   custom-title  jouw eigen naam (de rename-functie)  -- wint altijd
    #   ai-title      de titel die Claude Code zelf bijhoudt en blijft bijwerken
    #   summary       de samenvatting na een /compact of bij hervatten
    # We nemen van elk soort de laatste; renamen doe je immers achteraf.
    # Het veld waarin de tekst staat kan per versie verschillen, dus we pakken
    # het eerste veld uit deze lijst dat een niet-lege tekst bevat.
    $velden = @('title','customTitle','aiTitle','name','text','value','content','summary')
    $custom = ''
    $ai     = ''
    $sum    = ''

    try {
        foreach ($line in (Get-Content -LiteralPath $file -Tail 1500 -Encoding UTF8 -ErrorAction Stop)) {
            if ($line -notmatch '"type"\s*:\s*"(custom-title|ai-title|summary)"') { continue }
            $soort = $Matches[1]
            $o = $null
            try { $o = $line | ConvertFrom-Json } catch { continue }
            if (-not $o) { continue }

            $waarde = ''
            foreach ($v in $velden) {
                if ($o.PSObject.Properties[$v]) {
                    $kandidaat = $o.$v
                    if ($kandidaat -is [string] -and $kandidaat) { $waarde = [string]$kandidaat; break }
                }
            }
            if (-not $waarde) { continue }

            switch ($soort) {
                'custom-title' { $custom = $waarde }
                'ai-title'     { $ai     = $waarde }
                'summary'      { $sum    = $waarde }
            }
        }
    } catch { }

    if ($custom) { return (Get-DashShort $custom 48) }
    if ($ai)     { return (Get-DashShort $ai 48) }
    if ($sum)    { return (Get-DashShort $sum 48) }

    # Niets van dat al: dan de eerste echte opdracht uit het gesprek.
    try {
        foreach ($line in (Get-Content -LiteralPath $file -TotalCount 40 -Encoding UTF8 -ErrorAction Stop)) {
            if ($line -notmatch '"type"\s*:\s*"user"') { continue }
            $o = $null
            try { $o = $line | ConvertFrom-Json } catch { continue }
            $c = $o.message.content
            $t = ''
            if ($c -is [string]) { $t = $c }
            elseif ($c) {
                foreach ($b in $c) { if ($b.type -eq 'text' -and $b.text) { $t = [string]$b.text; break } }
            }
            if (-not $t) { continue }
            if ($t -match '^\s*<' -or $t -match 'command-name' -or $t -match '^\s*Caveat:') { continue }
            return (Get-DashShort $t)
        }
    } catch { }
    return ''
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

        $cwd    = [string]$s.cwd
        $folder = 'Claude'
        if ($cwd) { try { $folder = Split-Path -Leaf $cwd } catch { } }
        if (-not $folder) { $folder = 'Claude' }

        # titel uit het transcript; valt terug op de mapnaam
        $title = ''
        if ($s.PSObject.Properties['title']) { $title = [string]$s.title }

        $hostPid = 0
        if ($s.PSObject.Properties['host_pid'] -and $s.host_pid) { $hostPid = [int]$s.host_pid }
        $bron = ''
        if ($s.PSObject.Properties['source']) { $bron = [string]$s.source }
        if ($hostPid -le 0 -and $bron -eq 'cowork') { $hostPid = Get-DashDesktopPid }

        $name = if ($title) { $title } else { $folder }

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
            title      = $title
            folder     = $folder
            host_pid   = $hostPid
            source     = $bron
            tab        = ''
            host       = ''
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

    # De tabtitel van de terminal is de echte naam. Alleen gebruiken als er
    # precies een zichtbare sessie in dat terminalvenster zit -- bij meerdere
    # tabs weet je niet bij welke de titel hoort.
    $perHost = @{}
    foreach ($x in ($list | Where-Object { $_.visible -and $_.host_pid -gt 0 })) {
        if (-not $perHost.ContainsKey($x.host_pid)) { $perHost[$x.host_pid] = 0 }
        $perHost[$x.host_pid] = $perHost[$x.host_pid] + 1
    }
    foreach ($x in ($list | Where-Object { $_.visible -and $_.host_pid -gt 0 })) {
        if ($perHost[$x.host_pid] -ne 1) { continue }
        $info = Get-DashHostInfo $x.host_pid
        if (-not $info) { continue }
        $x.host = $info.Name
        if ($DashTerminals -contains $info.Name) {
            $tab = Get-DashCleanTab $info.Title
            # de titel uit het transcript is specifieker (daar zit je rename in),
            # dus de tabtitel vult alleen aan waar die ontbreekt
            if ($tab) {
                $x.tab = $tab
                if (-not $x.title) { $x.name = $tab }
            }
        } elseif ($DashDesktopHosts -contains $info.Name) {
            # Cowork-sessie: het venster heet "Claude", dus daar valt niets uit
            # te halen. Wel duidelijk maken dat het geen terminalsessie is.
            if (-not $x.title) { $x.name = 'Cowork · ' + $x.folder }
        }
    }

    # Twee sessies met dezelfde naam (bijvoorbeeld twee keer dezelfde map,
    # zonder titel) krijgen er een kort stukje van hun session_id achter, anders
    # weet je niet welke welke is.
    $perNaam = @{}
    foreach ($x in ($list | Where-Object { $_.visible })) {
        if (-not $perNaam.ContainsKey($x.name)) { $perNaam[$x.name] = @() }
        $perNaam[$x.name] += $x
    }
    foreach ($k in @($perNaam.Keys)) {
        if ($perNaam[$k].Count -gt 1) {
            foreach ($x in $perNaam[$k]) {
                $x.name = $x.name + '  #' + $x.session_id.Substring(0, 4)
            }
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
            folder     = $s.folder
            host_pid   = $s.host_pid
            owner_pid  = $s.owner_pid
            tab        = $s.tab
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
