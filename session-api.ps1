# =============================================================================
#  session-api.ps1 -- webservice met je live Claude-sessies, voor de Cheap
#  Yellow Display (en je telefoon).
#
#  Starten:  powershell -ExecutionPolicy Bypass -File session-api.ps1
#  Of stil:  wscript.exe api.vbs
#
#  Endpoints:
#    GET /cyd.txt              platte tekst, 1 regel per sessie -- voor de ESP32
#    GET /sessions.json        dezelfde data als JSON
#    GET /focus?id=<sid>       venster van die sessie naar voren halen (tikken)
#    GET /action?id=<sid>&b=N  knopactie N uitvoeren (zie actions.json)
#    GET /                     piepklein statuspaginaatje (ook op je telefoon)
#
#  Gebruikt System.Net.Sockets.TcpListener in plaats van HttpListener: die
#  laatste heeft op een niet-verhoogde prompt een urlacl-reservering nodig.
#  De eerste keer vraagt Windows Firewall wel om toestemming -- kies
#  "Prive-netwerken toestaan". Of vooraf, in een admin-prompt:
#    netsh advfirewall firewall add rule name="Claude sessie-API" ^
#      dir=in action=allow protocol=TCP localport=8787
#
#  LET OP: /action kan toetsen naar je terminal sturen. Iedereen op je netwerk
#  kan dat aanroepen. Zet daarom "token" in actions.json als je op een netwerk
#  zit dat je niet vertrouwt; de CYD stuurt hem dan mee.
# =============================================================================
param(
    [int]$Port = 8787
)
$ErrorActionPreference = 'Continue'

$Root = $PSScriptRoot
. (Join-Path $Root 'sessionlib.ps1')
. (Join-Path $Root 'focuslib.ps1')

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

function Get-Actions {
    # elke keer opnieuw lezen: dan werkt een wijziging meteen
    if (-not (Test-Path $ActionsPath)) { return $null }
    try { return (Get-Content $ActionsPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-Sessions {
    return @(Get-DashSessions -Dir $StatusDir -SnoozeFile $SnoozePath)
}

function Get-Payload($all) {
    return (Write-DashPayload -Root $Root -Sessions $all)
}

# ---- platte tekst voor de ESP32 --------------------------------------------
# Regel 1:  #<attention>|<active>|<done>|<HH:mm:ss>
# Daarna :  <state>|<naam>|<sinds>|<waarom>|<session_id>
# Losse regels, geen JSON: dan heeft de sketch geen ArduinoJson nodig.
function Format-Cyd($p) {
    # De knoplabels gaan mee in de kopregel, zodat de CYD onder in beeld laat
    # zien wat de drie knoppen doen. Pas je actions.json aan, dan verandert het
    # schermpje mee -- zonder opnieuw te flashen.
    $labels = @()
    $cfg = Get-Actions
    foreach ($n in @('1','2','3')) {
        $l = ''
        if ($cfg -and $cfg.buttons -and $cfg.buttons.PSObject.Properties[$n]) { $l = [string]$cfg.buttons.$n.label }
        $labels += ($l -replace '[\r\n\|;]', ' ')
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('#').Append($p.attention).Append('|').Append($p.active).Append('|').Append($p.done).Append('|').Append((Get-Date).ToString('HH:mm:ss')).Append('|').Append(($labels -join ';')).Append("`n")
    foreach ($s in $p.sessions) {
        $why = ([string]$s.why -replace '[\r\n\|]', ' ')
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
    if (-not $rows) { $rows = "<div class=r><small>Geen actieve sessies.</small></div>" }
    return @"
<!DOCTYPE html><html lang=nl><head><meta charset=utf-8>
<meta name=viewport content='width=device-width,initial-scale=1'>
<meta http-equiv=refresh content=5><title>Claude-sessies</title><style>
body{background:#1F262F;color:#F0F4F9;font:15px/1.5 'Segoe UI',system-ui,sans-serif;margin:0;padding:16px}
h1{font-size:13px;letter-spacing:1.2px;text-transform:uppercase;color:#8A97A6;margin:0 0 12px}
.r{display:block;background:#262E38;border-left:3px solid #9BB0C7;border-radius:8px;padding:10px 12px;margin-bottom:8px;color:inherit;text-decoration:none}
.c{float:right;font-size:11px;text-transform:uppercase;letter-spacing:.6px}
small{color:#8A97A6}</style></head><body>
<h1>Claude-sessies &middot; $($p.attention) wachten &middot; $($p.active) actief</h1>
$rows
<small>bijgewerkt $((Get-Date).ToString('HH:mm:ss')) &middot; tik een rij aan om dat venster naar voren te halen</small>
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

# ---- knopacties -------------------------------------------------------------
function Invoke-DashAction($sess, [string]$btn) {
    $cfg = Get-Actions
    if (-not $cfg) { return 'err geen actions.json' }
    $def = $null
    if ($cfg.buttons -and $cfg.buttons.PSObject.Properties[$btn]) { $def = $cfg.buttons.$btn }
    if (-not $def) { return "err knop $btn niet ingesteld" }

    $label = if ($def.label) { [string]$def.label } else { "knop $btn" }
    $type  = ([string]$def.type).ToLower()
    $name  = [string]$sess.name

    # Toetsen alleen sturen als de sessie er ook echt om vraagt: een misklik
    # mag geen Enter in een sessie duwen die gewoon aan het werk is.
    if ($def.requireAttention -and $sess.state -ne 'attention') {
        Write-DashLog "GEWEIGERD $label op $name -- sessie vraagt geen aandacht (state=$($sess.state))"
        return "err $label kan alleen als die sessie wacht"
    }

    switch ($type) {
        'focus' {
            $w = Invoke-DashSessionFocus -Session $sess -FolderFallback
            if ($w) { Write-DashLog "$label -> $name : $($w.Title)"; return "ok $label" }
            Write-DashLog "$label -> $name : geen venster gevonden"
            return 'err geen venster'
        }
        'keys' {
            $keys = [string]$def.send
            if (-not $keys) { return 'err geen toetsen ingesteld' }
            $best = Get-DashBestWindow -Cwd ([string]$sess.cwd) -OwnerPid ([int]$sess.owner_pid)
            if (-not $best) { Write-DashLog "$label -> $name : geen venster"; return 'err geen venster' }
            $delay = 250
            if ($cfg.keyDelayMs) { $delay = [int]$cfg.keyDelayMs }
            if (Send-DashKeys -Handle $best.Handle -Keys $keys -DelayMs $delay) {
                Write-DashLog "$label -> $name : '$keys' naar '$($best.Title)'"
                return "ok $label"
            }
            Write-DashLog "$label -> $name : venster kwam niet naar voren, niets gestuurd"
            return 'err venster niet actief'
        }
        'snooze' {
            $min = 10
            if ($def.minutes) { $min = [int]$def.minutes }
            if (Set-DashSnooze ([string]$sess.session_id) $min) {
                Write-DashLog "$label -> $name : $min minuten stil"
                return "ok $min min stil"
            }
            return 'err snooze mislukt'
        }
        'run' {
            $cmd = ([string]$def.command) -replace '\{cwd\}', [string]$sess.cwd
            if (-not $cmd) { return 'err geen command' }
            try {
                # niet $args gebruiken: dat is een automatische variabele
                $argstr = ([string]$def.args) -replace '\{cwd\}', [string]$sess.cwd
                if ($argstr) { Start-Process -FilePath $cmd -ArgumentList $argstr } else { Start-Process -FilePath $cmd }
                Write-DashLog "$label -> $name : $cmd $argstr"
                return "ok $label"
            } catch { return 'err start mislukt' }
        }
        'open' {
            $path = ([string]$def.path) -replace '\{cwd\}', [string]$sess.cwd
            if (-not $path) { return 'err geen path' }
            try { Start-Process $path; Write-DashLog "$label -> $name : $path"; return "ok $label" }
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

        $all = Get-Sessions
        $p   = Get-Payload $all
        $ctype = 'text/plain; charset=utf-8'

        switch ($path) {
            '/cyd.txt'       { $body = Format-Cyd  $p }
            '/sessions.json' { $body = ($p | ConvertTo-Json -Depth 6 -Compress); $ctype = 'application/json; charset=utf-8' }

            { $_ -eq '/focus' -or $_ -eq '/action' } {
                $cfg = Get-Actions
                $token = if ($cfg -and $cfg.token) { [string]$cfg.token } else { '' }
                if ($token -and $q['t'] -ne $token) {
                    $body = 'err token'
                } else {
                    $sid  = [string]$q['id']
                    $sess = $null
                    foreach ($s in ($all | Where-Object { $_.visible })) {
                        if ($s.session_id -eq $sid) { $sess = $s; break }
                    }
                    # geen id meegestuurd? dan de sessie die het langst wacht
                    if (-not $sess) {
                        $sess = @($all | Where-Object { $_.visible -and $_.state -eq 'attention' } | Sort-Object sort_ts)[0]
                    }
                    if (-not $sess) {
                        $body = 'err geen sessie'
                    } elseif ($path -eq '/focus') {
                        $w = Invoke-DashSessionFocus -Session $sess -FolderFallback
                        if ($w) {
                            Write-DashLog "TIK -> $($sess.name) : $($w.Title)"
                            $body = "ok $($sess.name)"
                        } else {
                            Write-DashLog "TIK -> $($sess.name) : geen venster gevonden"
                            $body = 'err geen venster'
                        }
                    } else {
                        $btn  = [string]$q['b']
                        if (-not $btn) { $btn = '1' }
                        $body = Invoke-DashAction $sess $btn
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
        # stille verbinding of time-out: gewoon door
    } finally {
        if ($client) { try { $client.Close() } catch { } }
    }
}
