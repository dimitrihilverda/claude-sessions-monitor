# =============================================================================
#  session-api.ps1 -- web service exposing your live Claude sessions, for the
#  Cheap Yellow Display (and your phone).
#
#  Start:  powershell -ExecutionPolicy Bypass -File session-api.ps1
#  Quiet:  wscript.exe api.vbs
#
#  Endpoints:
#    GET /cyd.txt              plain text, one line per session -- for the ESP32
#    GET /sessions.json        the same data as JSON
#    GET /focus?id=<sid>       bring that session's window to the front (tapping)
#    GET /action?id=<sid>&b=N  run button action N (see actions.json)
#    GET /                     a tiny status page (fine on a phone)
#
#  Uses System.Net.Sockets.TcpListener rather than HttpListener: the latter
#  needs a urlacl reservation when run from a non-elevated prompt.
#  The first time, Windows Firewall does ask for permission -- choose
#  "allow on private networks". Or up front, from an admin prompt:
#    netsh advfirewall firewall add rule name="Claude sessions API" ^
#      dir=in action=allow protocol=TCP localport=8787
#
#  WARNING: /action can send keystrokes into your terminal, and anyone on your
#  network can call it. Set "token" in actions.json if you are on a network you
#  do not trust; the display will send it along.
# =============================================================================
param(
    [int]$Port = 8787,
    # How long the session list may be reused. 0 = rebuild every time (the old
    # behaviour, slow). See the explanation at Get-SessieCache.
    [int]$CacheMs = 1500,
    # How long a one-shot command stays on offer for the display. A few polls'
    # worth, so a stray request cannot swallow it first.
    [int]$CommandTtlSec = 6,
    # How fresh sessions.json has to be before we trust it instead of rebuilding.
    # Larger than the HUD's 3 s refresh, so one slow write does not cost us a
    # 1.3 s WMI rebuild.
    [int]$PayloadMaxAgeSec = 10,
    # Log every incoming request, for when you need to know whether the display
    # is reaching the PC at all.
    [switch]$LogRequests
)
$ErrorActionPreference = 'Continue'

$Root = $PSScriptRoot
. (Join-Path $Root 'sessionlib.ps1')
. (Join-Path $Root 'focuslib.ps1')
. (Join-Path $Root 'langlib.ps1')

$StatusDir   = Join-Path $Root 'session-status'
$ActionsPath = Join-Path $Root 'actions.json'
$SnoozePath  = Join-Path $Root 'snooze.json'
$LogPath     = Join-Path $Root 'actions.log'

function Write-DashLog([string]$txt) {
    try {
        $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $txt
        Add-Content -Path $LogPath -Value $line -Encoding UTF8
        Write-Host $line
    } catch { }
}

<#
  The label shown on a button. An explicit "label" in actions.json always wins;
  without one we fall back to "labelKey", which points at langlib.ps1 so the
  buttons follow the Windows display language like everything else. Any
  "minutes" is passed in, which is what makes "Snooze {0} min" work.
#>
<#
  A one-shot command for the display. The display polls; the PC cannot push, so
  a command waits here until the next poll picks it up and is then cleared. That
  keeps it to one field in the header line and no extra state on the device.
#>
$script:pendingCmd   = ''
$script:pendingUntil = [datetime]::MinValue

function Set-DisplayCommand([string]$cmd) {
    $script:pendingCmd   = $cmd
    $script:pendingUntil = [datetime]::UtcNow.AddSeconds($CommandTtlSec)
}

<#
  Deliberately NOT cleared on the first read. Clearing on read meant whoever
  polled first won it -- and a browser on the status page, or a curl while
  testing, would swallow the command before the display ever saw it. Instead it
  stays on offer for a few seconds. The display re-arms only once the field is
  empty again, so a handful of polls inside the window still act once.
#>
function Read-DisplayCommand {
    if ([datetime]::UtcNow -gt $script:pendingUntil) { $script:pendingCmd = '' }
    return $script:pendingCmd
}

<#
  Get a window forward, preferring the HUD.

  The HUD is a GUI process and Windows lets it call SetForegroundWindow; this
  service runs hidden under wscript and largely does not. So ask the HUD first,
  and only fall back to doing it here if it does not answer -- the service must
  keep working on a machine where the HUD is not running.

  Returns @{ Found; Raised; Title }.
#>
function Resolve-DashFocus($sess) {
    $viaHud = Request-DashFocus -Session $sess -Root $Root
    if ($null -ne $viaHud) {
        if ($viaHud.Found) { Write-DashLog "via HUD" }
        return $viaHud
    }
    $w = Invoke-DashSessionFocus -Session $sess
    if (-not $w) { return @{ Found = $false; Raised = $false; Title = ''; Handle = [IntPtr]::Zero } }
    return @{ Found = $true; Raised = [bool]$w.Raised; Title = [string]$w.Title; Handle = $w.Handle }
}

function Get-ButtonLabel($def, [string]$btn) {
    if ($def -and $def.label)    { return [string]$def.label }
    if ($def -and $def.labelKey) { return (T ([string]$def.labelKey) @($def.minutes)) }
    return "$btn"
}

function Get-Actions {
    # re-read every time: that way an edit takes effect immediately
    if (-not (Test-Path $ActionsPath)) { return $null }
    try { return (Get-Content $ActionsPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-Sessions {
    return @(Get-DashSessions -Dir $StatusDir -SnoozeFile $SnoozePath)
}

function Get-Payload($all) {
    return (Write-DashPayload -Root $Root -Sessions $all)
}

# ---- plain text for the ESP32 -----------------------------------------------
# Line 1:  the header described below
# Then  :  <state>|<name>|<since>|<why>|<session_id>
# Separate lines, no JSON: that way the sketch needs no JSON library.
function Format-Cyd($p) {
    # The button labels travel in the header line, so the display can show what the
    # three buttons do. Edit actions.json and the display follows -- without
    # reflashing.
    $labels = @()
    $cfg = Get-Actions
    foreach ($n in @('1','2','3')) {
        $l = ''
        if ($cfg -and $cfg.buttons -and $cfg.buttons.PSObject.Properties[$n]) { $l = Get-ButtonLabel $cfg.buttons.$n $n }
        $labels += ($l -replace '[\r\n\|;]', ' ')
    }

    <#
      The header line also carries the display's text, so it follows the
      language of this PC without a table of its own and without reflashing.

        field 1  #<attention>
        field 2  <active>
        field 3  <done>
        field 4  <HH:mm>           -- no seconds: on a small screen a ticking
                                     seconds counter is nothing but restlessness
        field 5  button labels      separated by ;
        field 6  header text        composed here, because only the PC knows
                                    whether it is "1 needs you" or "2 need you"
        field 7  state labels       attention;active;done;no-sessions
        field 8  one-shot command   empty, or e.g. "cracktro"
    #>
    $kop =
        if     ($p.attention -gt 0) { T 'cyd.waitingCount' @($p.attention, $(if ($p.attention -eq 1) { '' } else { $(if ($script:DashLang -eq 'nl') { 'EN' } else { '' }) })) }
        elseif ($p.active    -gt 0) { T 'cyd.activeCount'  @($p.active) }
        else                        { T 'cyd.idle' }

    $statusLabels = @(
        (T 'cyd.attention'), (T 'cyd.active'), (T 'cyd.done'), (T 'cyd.noSessions')
    ) -join ';'

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('#').Append($p.attention).Append('|').Append($p.active).Append('|').Append($p.done).Append('|').Append((Get-Date).ToString('HH:mm')).Append('|').Append(($labels -join ';')).Append('|').Append(($kop -replace '[

\|;]', ' ')).Append('|').Append($statusLabels).Append('|').Append((Read-DisplayCommand)).Append("`n")
    foreach ($s in $p.sessions) {
        $why = ([string]$s.why -replace '[\r\n\|]', ' ')
        # the name is the session title; put the folder in front of the second line
        if ($s.folder) { $why = ([string]$s.folder -replace '[\r\n\|]', ' ') + ' - ' + $why }
        if ($why.Length -gt 64) { $why = $why.Substring(0, 64) }
        $nm = ([string]$s.name -replace '[\r\n\|]', ' ')
        [void]$sb.Append($s.state).Append('|').Append($nm).Append('|').Append($s.since).Append('|').Append($why).Append('|').Append($s.session_id).Append("`n")
    }
    return $sb.ToString()
}

function Format-Html($p) {
    $rows = ''
    foreach ($s in $p.sessions) {
        $col = switch ($s.state) { 'attention' { '#E8A33D' } 'active' { '#8DC63F' } default { '#9BB0C7' } }
        $why = [System.Web.HttpUtility]::HtmlEncode([string]$s.why)
        $nm  = [System.Web.HttpUtility]::HtmlEncode([string]$s.name)
        $sid = [System.Web.HttpUtility]::UrlEncode([string]$s.session_id)
        $rows += "<a class=r href='/focus?id=$sid' style='border-left-color:$col'><b>$nm</b> <span class=c style='color:$col'>$($s.label)</span><br><small>$($s.since) &middot; $why</small></a>"
    }
    if (-not $rows) { $rows = "<div class=r><small>$(T empty.none)</small></div>" }
    return @"
<!DOCTYPE html><html lang=nl><head><meta charset=utf-8>
<meta name=viewport content='width=device-width,initial-scale=1'>
<meta http-equiv=refresh content=5><title>$(T 'web.title')</title><style>
body{background:#1F262F;color:#F0F4F9;font:15px/1.5 'Segoe UI',system-ui,sans-serif;margin:0;padding:16px}
h1{font-size:13px;letter-spacing:1.2px;text-transform:uppercase;color:#8A97A6;margin:0 0 12px}
.r{display:block;background:#262E38;border-left:3px solid #9BB0C7;border-radius:8px;padding:10px 12px;margin-bottom:8px;color:inherit;text-decoration:none}
.c{float:right;font-size:11px;text-transform:uppercase;letter-spacing:.6px}
small{color:#8A97A6}</style></head><body>
<h1>$(T 'web.summary' @($p.attention, $p.active))</h1>
$rows
<small>$(T 'web.updated' @((Get-Date).ToString('HH:mm:ss'))) &middot; $(T 'web.tapHint')</small>
</body></html>
"@
}

# ---- snooze -----------------------------------------------------------------
function Set-DashSnooze([string]$sid, [int]$minutes) {
    $map = @{}
    if (Test-Path $SnoozePath) {
        try {
            $cur = Get-Content $SnoozePath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($prop in $cur.PSObject.Properties) {
                try { if (([datetime]$prop.Value) -gt (Get-Date)) { $map[$prop.Name] = [string]$prop.Value } } catch { }
            }
        } catch { }
    }
    $map[$sid] = (Get-Date).AddMinutes($minutes).ToString('yyyy-MM-ddTHH:mm:sszzz')
    try {
        ($map | ConvertTo-Json) | Set-Content -Path $SnoozePath -Encoding UTF8
        return $true
    } catch { return $false }
}

# ---- button actions ---------------------------------------------------------
function Invoke-DashAction($sess, [string]$btn) {
    $cfg = Get-Actions
    if (-not $cfg) { return (T 'err.noActions') }
    $def = $null
    if ($cfg.buttons -and $cfg.buttons.PSObject.Properties[$btn]) { $def = $cfg.buttons.$btn }
    if (-not $def) { return (T 'err.buttonUnset' @($btn)) }

    $label = Get-ButtonLabel $def $btn
    $type  = ([string]$def.type).ToLower()
    $name  = [string]$sess.name

    # Only send keys when the session is genuinely asking for them: a mis-tap must
    # not push Enter into a session that is simply working.
    if ($def.requireAttention -and $sess.state -ne 'attention') {
        Write-DashLog "REFUSED $label on $name -- that session is not asking for anything (state=$($sess.state))"
        return (T 'err.needsAttention' @($label))
    }

    switch ($type) {
        'focus' {
            $w = Invoke-DashSessionFocus -Session $sess
            if ($w) { Write-DashLog "$label -> $name : $($w.Title)"; return (T 'ok.action' @($label)) }
            Write-DashLog "$label -> $name : no window found"
            return (T 'err.noWindow')
        }
        'keys' {
            $keys = [string]$def.send
            if (-not $keys) { return (T 'err.noKeys') }
            # Ook hier via de HUD: toetsen worden alleen gestuurd als het venster
            # echt vooraan staat, en dat naar voren halen lukt vanuit deze
            # verstopte service nauwelijks.
            $f = Resolve-DashFocus $sess
            if (-not $f.Found) { Write-DashLog "$label -> $name : no window"; return (T 'err.noWindow') }
            if (-not $f.Raised) {
                Write-DashLog "$label -> $name : window would not come forward, sent nothing"
                return (T 'err.windowNotRaised')
            }
            $delay = 250
            if ($cfg.keyDelayMs) { $delay = [int]$cfg.keyDelayMs }
            if (Send-DashKeys -Handle $f.Handle -Keys $keys -DelayMs $delay) {
                Write-DashLog "$label -> $name : '$keys' naar '$($f.Title)'"
                return (T 'ok.action' @($label))
            }
            Write-DashLog "$label -> $name : venster kwam niet naar voren, niets gestuurd"
            return (T 'err.windowNotActive')
        }
        'snooze' {
            $min = 10
            if ($def.minutes) { $min = [int]$def.minutes }
            if (Set-DashSnooze ([string]$sess.session_id) $min) {
                Write-DashLog "$label -> $name : $min minuten stil"
                return "ok $min min stil"
            }
            return (T 'err.snoozeFailed')
        }
        'run' {
            $cmd = ([string]$def.command) -replace '\{cwd\}', [string]$sess.cwd
            if (-not $cmd) { return (T 'err.noCommand') }
            try {
                # do not use $args: that is an automatic variable
                $argstr = ([string]$def.args) -replace '\{cwd\}', [string]$sess.cwd
                if ($argstr) { Start-Process -FilePath $cmd -ArgumentList $argstr } else { Start-Process -FilePath $cmd }
                Write-DashLog "$label -> $name : $cmd $argstr"
                return (T 'ok.action' @($label))
            } catch { return (T 'err.startFailed') }
        }
        'open' {
            $path = ([string]$def.path) -replace '\{cwd\}', [string]$sess.cwd
            if (-not $path) { return (T 'err.noPath') }
            try { Start-Process $path; Write-DashLog "$label -> $name : $path"; return (T 'ok.action' @($label)) }
            catch { return 'err openen mislukt' }
        }
        default { return "err onbekend type '$type'" }
    }
}

# ---- server -----------------------------------------------------------------
Add-Type -AssemblyName System.Web

function Split-Query([string]$qs) {
    $h = @{}
    foreach ($pair in ($qs -split '&')) {
        if (-not $pair) { continue }
        $kv = $pair.Split('=', 2)
        $k = [System.Uri]::UnescapeDataString($kv[0])
        $v = if ($kv.Count -gt 1) { [System.Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) } else { '' }
        $h[$k] = $v
    }
    return $h
}

<#
  Cache the session list briefly.

  Get-Sessions goes through sessionlib to Get-CimInstance Win32_Process, and
  a WMI process query costs hundreds of milliseconds -- per session.
  Measured: 1.4 s per request, with spikes to 4.25 s when WMI is slow, and
  that was redone on every request while the display asks every 3 seconds.

  The result: the display (2.5 s timeout) gave up on the spikes, and because
  this server is a single AcceptTcpClient loop, a second client queued behind
  that as well. Hence "sometimes it works, sometimes it does not".

  With a cache of 1500 ms by default, nearly every request is served from
  memory. State is then at most a second and a half old -- unnoticeable on
  something that changes at human speed, and a thousandfold cheaper.
#>
$script:cacheAt   = [datetime]::MinValue
$script:cacheAll  = $null
$script:cachePay  = $null

<#
  Prefer reading sessions.json over rebuilding.

  The HUD already writes that file every 3 seconds, from the same sessionlib
  code, so rebuilding here duplicates the expensive part for nothing. Measured:
  rebuilding costs 1.17-1.45 s because it walks WMI process queries per session,
  while reading the file costs a few milliseconds.

  That mattered more than it looks. The display polls every 3 s with a timeout of
  its own, and every poll was landing on a fresh 1.3 s rebuild -- so a hiccup on
  the Wi-Fi was enough to tip it into "no connection", and the in-memory cache
  never helped because its TTL was shorter than the poll interval.

  We only rebuild when the file is missing or stale, which means the HUD is not
  running. $PayloadMaxAgeSec is deliberately larger than the HUD's 3 s refresh so
  a single slow write does not send us back to WMI.
#>
function Read-PayloadFile {
    $pad = Join-Path $Root 'sessions.json'
    if (-not (Test-Path $pad)) { return $null }
    try {
        $leeftijd = ((Get-Date) - (Get-Item $pad).LastWriteTime).TotalSeconds
        if ($leeftijd -gt $PayloadMaxAgeSec) { return $null }
        $p = Get-Content $pad -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $p -or -not $p.PSObject.Properties['sessions']) { return $null }
        # everything in the file is a visible session; the action code filters on it
        foreach ($s in @($p.sessions)) {
            if (-not $s.PSObject.Properties['visible']) {
                $s | Add-Member -NotePropertyName visible -NotePropertyValue $true
            }
        }
        return $p
    } catch { return $null }
}

function Get-SessieCache {
    $oud = ([datetime]::UtcNow - $script:cacheAt).TotalMilliseconds
    if ($null -ne $script:cacheAll -and $oud -lt $CacheMs) {
        return @{ all = $script:cacheAll; payload = $script:cachePay }
    }

    $p = Read-PayloadFile
    if ($p) {
        $script:cachePay = $p
        $script:cacheAll = @($p.sessions)
    } else {
        $script:cacheAll = Get-Sessions
        $script:cachePay = Get-Payload $script:cacheAll
    }
    $script:cacheAt = [datetime]::UtcNow
    return @{ all = $script:cacheAll; payload = $script:cachePay }
}

# After an action the cache is stale: the next poll must see the result.
function Reset-SessieCache { $script:cacheAt = [datetime]::MinValue }

$listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Any), $Port
try { $listener.Start() } catch {
    Write-Host "Kan poort $Port niet openen: $($_.Exception.Message)"
    exit 1
}

$ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
         Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
         Select-Object -ExpandProperty IPAddress)
Write-Host "Claude sessie-API draait op poort $Port"
foreach ($ip in $ips) { Write-Host "  http://$($ip):$Port/cyd.txt" }
Write-Host 'Stoppen met Ctrl+C.'

while ($true) {
    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
        # -LogRequests writes one line per request with the client address. Off by
        # default (it would fill actions.log at three requests per second), but
        # invaluable when the display claims it cannot reach us: it settles in one
        # look whether requests arrive at all, or never leave the device.
        if ($LogRequests) {
            try { Write-DashLog ("REQ van " + $client.Client.RemoteEndPoint.ToString()) } catch { }
        }
        $client.ReceiveTimeout = 2000
        $client.SendTimeout    = 4000
        $ns = $client.GetStream()
        $ns.ReadTimeout = 2000

        $sr  = New-Object System.IO.StreamReader ($ns, [System.Text.Encoding]::ASCII)
        $req = $sr.ReadLine()
        while ($true) {
            $l = $sr.ReadLine()
            if ($null -eq $l -or $l -eq '') { break }
        }

        $path = '/'
        if ($req -match '^[A-Z]+\s+(\S+)') { $path = $Matches[1] }
        $qs = ''
        if ($path.Contains('?')) {
            $parts = $path.Split('?', 2)
            $path  = $parts[0]
            $qs    = $parts[1]
        }
        $q = Split-Query $qs

        $snap = Get-SessieCache
        $all  = $snap.all
        $p    = $snap.payload
        $ctype = 'text/plain; charset=utf-8'

        switch ($path) {
            '/demo' {
                # Kick the display into its cracktro from the PC. Handy for showing
                # it off without walking over to press BOOT.
                Set-DisplayCommand 'cracktro'
                Write-DashLog 'DEMO -> cracktro'
                $body = 'ok cracktro'
            }

            '/cyd.txt'       { $body = Format-Cyd  $p }
            '/sessions.json' { $body = ($p | ConvertTo-Json -Depth 6 -Compress); $ctype = 'application/json; charset=utf-8' }

            { $_ -eq '/focus' -or $_ -eq '/action' } {
                $cfg = Get-Actions
                $token = if ($cfg -and $cfg.token) { [string]$cfg.token } else { '' }
                if ($token -and $q['t'] -ne $token) {
                    $body = (T 'err.badToken')
                } else {
                    $sid  = [string]$q['id']
                    $sess = $null
                    foreach ($s in ($all | Where-Object { $_.visible })) {
                        if ($s.session_id -eq $sid) { $sess = $s; break }
                    }
                    # no id sent? then the session that has been waiting longest
                    if (-not $sess) {
                        $sess = @($all | Where-Object { $_.visible -and $_.state -eq 'attention' } | Sort-Object sort_ts)[0]
                    }
                    if (-not $sess) {
                        $body = (T 'err.noSession')
                    } elseif ($path -eq '/focus') {
                        Reset-SessieCache
                        $w = Resolve-DashFocus $sess
                        if ($w.Found -and $w.Raised) {
                            Write-DashLog "TIK -> $($sess.name) : $($w.Title)"
                            $body = (T 'ok.action' @($sess.name))
                        } elseif ($w.Found) {
                            # Gevonden, maar Windows liet het niet naar voren komen.
                            # Dat is iets anders dan "geen venster", en het scherm
                            # hoort dat verschil te zien.
                            Write-DashLog "TIK -> $($sess.name) : gevonden maar niet naar voren gekomen ($($w.Title))"
                            $body = (T 'err.windowNotRaised')
                        } else {
                            Write-DashLog "TIK -> $($sess.name) : geen venster gevonden"
                            $body = 'err geen venster'
                        }
                    } else {
                        $btn  = [string]$q['b']
                        if (-not $btn) { $btn = '1' }
                        $body = Invoke-DashAction $sess $btn
                        Reset-SessieCache
                    }
                }
            }

            default { $body = Format-Html $p; $ctype = 'text/html; charset=utf-8' }
        }

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $head  = "HTTP/1.1 200 OK`r`n" +
                 "Content-Type: $ctype`r`n" +
                 "Content-Length: $($bytes.Length)`r`n" +
                 "Cache-Control: no-store`r`n" +
                 "Access-Control-Allow-Origin: *`r`n" +
                 "Connection: close`r`n`r`n"
        $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
        $ns.Write($hb, 0, $hb.Length)
        $ns.Write($bytes, 0, $bytes.Length)
        $ns.Flush()
    } catch {
        # a silent connection or a timeout: just carry on
    } finally {
        if ($client) { try { $client.Close() } catch { } }
    }
}
