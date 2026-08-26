# =============================================================================
#  sessionlib.ps1 -- shared session logic
#  Dot-source this file:   . (Join-Path $PSScriptRoot 'sessionlib.ps1')
#  Used by: beacon.ps1 (hooks), hud.ps1 (floating HUD), session-api.ps1 (display)
# =============================================================================

# ---- settings ---------------------------------------------------------------
# A session disappears as soon as the Claude process is gone. The TTL is only a
# safety net for beacons whose PID we could not determine.
$DashMaxAgeMinutes = 45

# Never show sessions in these folders. Empty by default: you want to see
# everything, including the session you are using to work on this project.
# To filter a folder out, put its full path here.
$DashHideCwds = @()

# ---- state names ------------------------------------------------------------
#  attention = Claude genuinely wants something from you (hook event Notification)
#  active    = Claude is working (SessionStart / UserPromptSubmit /
#              PreToolUse / PostToolUse -- the last two fire during the work and
#              therefore take a session out of the attention state once you have
#              approved a permission request)
#  done      = Claude has finished answering (Stop) -- no alarm, your turn
#  ended     = session closed (SessionEnd) -> hide and clean up
<#
  The state labels come from langlib.ps1. We load it here rather than in every
  calling script: beacon.ps1, check-titles.ps1 and find-title.ps1 only load
  sessionlib, and would otherwise break on a missing T.
  The guard avoids loading it twice if the caller already had it.
#>
if (-not (Get-Command T -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'langlib.ps1')
}

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
    # The text lives in langlib.ps1, so it follows the Windows display language.
    switch ($state) {
        'attention' { return (T 'state.attention') }
        'active'    { return (T 'state.active') }
        'done'      { return (T 'state.done') }
        'ended'     { return (T 'state.ended') }
        default     { return (T 'state.unknown') }
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

# ---- process owner ----------------------------------------------------------
# The hook runs as a grandchild of the Claude Code process (claude/node). We
# walk the parent chain upwards until we find it, and store PID + start time.
# That lets us tell later whether the session is genuinely still alive; a
# SessionStart without a SessionEnd (terminal closed with the X, a crash) then
# disappears at once instead of lingering as "working" for an hour.
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
            <#
              Is this an editor's AI panel rather than a session you opened?
              PhpStorm and friends run Claude Code through the Agent SDK over ACP,
              which is a genuine session and fires the same hooks -- but it is not
              a terminal you are sitting in, and seeing it appear next to your own
              session in the same folder is baffling until it is labelled.
              The command line is already on the object we fetched, so this is free.
            #>
            $cmd = [string]$par.CommandLine
            $agent = ($cmd -match 'claude-agent-sdk|claude-agent-acp|acp-agents')
            return [pscustomobject]@{ OwnerPid = $ppid; Start = $start; Agent = $agent }
        }
        $cur = $ppid
    }
    return [pscustomobject]@{ OwnerPid = 0; Start = ''; Agent = $false }
}

# $true = alive, $false = gone, $null = unknown (old beacon without a PID)
function Test-DashOwnerAlive($s) {
    $opid = 0
    if ($s.PSObject.Properties['owner_pid'] -and $s.owner_pid) { $opid = [int]$s.owner_pid }
    if ($opid -le 0) { return $null }

    $p = $null
    try { $p = Get-Process -Id $opid -ErrorAction Stop } catch { return $false }
    if (-not $p) { return $false }

    # PIDs get reused; the start time has to match as well.
    if ($s.PSObject.Properties['owner_start'] -and $s.owner_start) {
        try {
            $st = [datetime]::Parse([string]$s.owner_start, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
            if ([math]::Abs(($p.StartTime - $st).TotalSeconds) -gt 5) { return $false }
        } catch { }
    }
    return $true
}

# ---- the terminal tab title -------------------------------------------------
# Claude Code keeps its terminal tab title up to date live. That is the real
# name of a session. Two limits are unavoidable here:
#   * only a terminal passes that title on to the window. If the session runs
#     in the PhpStorm terminal, the window title is PhpStorm's and not
#     Claude's, so it falls back to the transcript title.
#   * with several sessions in the same terminal window (tabs), the window
#     title belongs to the active tab. We cannot tell which, so we use it for
#     neither.
$DashTerminals = @(
    'windowsterminal','openconsole','conhost','cmd','powershell','pwsh','wt',
    'alacritty','wezterm-gui','mintty','kitty','tabby'
)

# The Claude desktop app (Cowork) also has a window, but it is always simply
# called "Claude". That title says nothing, so those sessions get their folder
# name with a label in front.
$DashDesktopHosts = @('claude')

# A Cowork session's beacon may have been written without a process ID. In that
# case we look up the desktop app's window ourselves, so clicking such a
# session still works.
function Get-DashDesktopPid {
    foreach ($naam in $DashDesktopHosts) {
        $p = Get-Process -Name $naam -ErrorAction SilentlyContinue |
             Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } |
             Select-Object -First 1
        if ($p) { return [int]$p.Id }
    }
    return 0
}

<#
  First ancestor with a real window; that goes into the beacon file.

  Not explorer, though. Every chain ends at the shell, and explorer always has a
  window -- the desktop, titled "Program Manager". Recording that as the session's
  window meant clicking a row raised the desktop: no error, no visible effect, and
  nothing to suggest where to look. A session's window is never the desktop.
#>
$DashNeverHost = @('explorer', 'dwm')

function Get-DashHostPid([int]$fromPid) {
    $id = $fromPid
    for ($i = 0; $i -lt 8 -and $id -gt 4; $i++) {
        try {
            $p = Get-Process -Id $id -ErrorAction Stop
            if ($p.MainWindowHandle -ne [IntPtr]::Zero -and
                ($DashNeverHost -notcontains $p.ProcessName.ToLower())) { return $id }
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
    # strip the status dots and asterisks Claude Code puts in front
    $t = ($t -replace '^[^\p{L}\p{N}]+', '').Trim()
    if (-not $t) { return '' }
    # a bare terminal name or a path is not a session title
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

# ---- the title of a session -------------------------------------------------
# The folder name is not a good name: two sessions in the same folder would
# both be called the same thing. Claude Code maintains a summary in the
# transcript the hook passes along; we use that as the title, and otherwise the
# first instruction from the conversation.
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

    # Claude Code writes a session's name as separate lines in the transcript.
    # Three kinds, in this order of preference:
    #   custom-title  your own name (the rename function)  -- always wins
    #   ai-title      the title Claude Code maintains and keeps updating
    #   summary       the summary after a /compact, or when resuming
    # We take the last of each kind; renaming happens after the fact, after all.
    # Which field holds the text varies between versions, so we take the first
    # field from this list that contains a non-empty string.
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

    # None of that: then the first real instruction from the conversation.
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

# ---- the session list -------------------------------------------------------
# Reads every beacon, works out state and visibility, merges /clear duplicates
# (same Claude process = one session) and with -Prune cleans up dead files.
function Get-DashSessions {
    param(
        [Parameter(Mandatory = $true)][string]$Dir,
        [string]$SnoozeFile = '',
        [switch]$Prune
    )

    if (-not (Test-Path $Dir)) { return @() }
    $now  = Get-Date
    $list = @()

    # Snoozed sessions: still visible, but not orange and no beep.
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

        # title from the transcript; falls back to the folder name
        $title = ''
        if ($s.PSObject.Properties['title']) { $title = [string]$s.title }

        $hostPid = 0
        if ($s.PSObject.Properties['host_pid'] -and $s.host_pid) { $hostPid = [int]$s.host_pid }
        $bron = ''
        if ($s.PSObject.Properties['source']) { $bron = [string]$s.source }
        if ($hostPid -le 0 -and $bron -eq 'cowork') { $hostPid = Get-DashDesktopPid }

        $name = if ($title) { $title } else { $folder }

        <#
          An editor's AI panel, rather than a session you opened. PhpStorm and
          friends run Claude Code through the Agent SDK over ACP: a genuine
          session firing the same hooks, from the same folder, and without a
          label it appears as the bare folder name right next to your own.

          This belongs here and not further down. It first sat after the
          host-window loop, which only visits sessions that have a host_pid --
          so with none of those, $x was null and the whole thing threw on every
          call. Silently, because ErrorActionPreference is Continue.
        #>
        if (-not $title -and $s.PSObject.Properties['owner_agent'] -and $s.owner_agent) {
            $name = 'Agent · ' + $folder
        }

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
            label      = $(if ($snoozedUntil) { (T 'state.snoozeUntil' @($snoozedUntil.ToString('HH:mm'))) } else { Get-DashStateLabel $state })
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

    # The terminal tab title is the real name. Only use it when there is exactly
    # one visible session in that terminal window -- with several tabs you cannot
    # tell which one the title belongs to.
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
            # the transcript title is more specific (your rename lives there), so the
            # tab title only fills in where that is missing
            if ($tab) {
                $x.tab = $tab
                if (-not $x.title) { $x.name = $tab }
            }
        } elseif ($DashDesktopHosts -contains $info.Name) {
            # Cowork session: the window is called "Claude", so there is nothing to
            # take from it. Do make clear it is not a terminal session.
            if (-not $x.title) { $x.name = 'Cowork · ' + $x.folder }
        }
    }

    # Two sessions with the same name (for instance the same folder twice, with no
    # title) get a short piece of their session_id appended, otherwise you cannot
    # tell which is which.
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

    # /clear gives the same terminal a new session_id: per Claude process (and per
    # folder when the PID is unknown) we keep only the newest.
    $groups = @{}
    foreach ($x in ($list | Where-Object { $_.visible } | Sort-Object sort_ts -Descending)) {
        if ($x.owner_pid -gt 0) { $key = 'p' + $x.owner_pid } else { $key = 'c' + $x.cwd.ToLower() }
        if ($groups.ContainsKey($key)) { $x.visible = $false } else { $groups[$key] = $true }
    }

    return ($list | Sort-Object @{Expression='rank'}, @{Expression='sort_ts'; Descending=$true})
}

# ---- output for the page and the display ------------------------------------
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
            sort_ts    = $s.sort_ts
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

    # sessions.json = for the HUD and the display, sessions.js = for a web page
    # (a <script src> is allowed on file://, a fetch() is not)
    # sessions.json is for the HUD and the display. sessions.js is only needed for
    # the dashboard page, so we write that file only when the page actually exists.
    $targets = @( @{ Path = (Join-Path $Root 'sessions.json'); Text = $json } )
    if (Test-Path (Join-Path $Root 'dashboard.html')) {
        $targets += @{ Path = (Join-Path $Root 'sessions.js'); Text = ('window.__SESSIONS_PAYLOAD = ' + $json + ';') }
    }
    # Write to .tmp and then swap: the HUD writes every 3 seconds and the page
    # reads sessions.js every 15 -- without this trick you occasionally read half
    # a file.
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
                # Replace() can fail if the page has sessions.js open at that moment; clean up
                # the temporary file in that case, otherwise it lingers.
                try { if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } } catch { }
            }
        }
    }
    return $payload
}
