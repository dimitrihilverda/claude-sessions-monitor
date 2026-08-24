# =============================================================================
#  beacon.ps1 -- Claude sessie-beacon voor het dashboard, de HUD en de CYD
#  Wordt aangeroepen door Claude Code hooks (zie claude-hooks-snippet.json).
#  Leest de hook-JSON van stdin, schrijft session-status\<session_id>.json en
#  bundelt alles in sessions.json + sessions.js.
#
#  v2: legt de PID van het Claude-proces vast, zodat sessies die zonder
#      SessionEnd verdwijnen (terminal dichtgeslagen, crash, /clear) niet meer
#      als "Actief" blijven hangen.
# =============================================================================
$ErrorActionPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'sessionlib.ps1')

# --- instellingen voor de Windows-meldingen --------------------------------
# Notification = Claude vraagt permissie of wacht op invoer -> altijd melden.
# Stop         = Claude is klaar. Alleen melden als de run langer dan
#                $ToastStopMinSeconds duurde; bij korte antwoorden zit je zelf
#                toch in de terminal. Dit is puur de toast: in het dashboard,
#                de HUD en op de CYD is Stop een neutrale "Klaar"-status en
#                nooit een oranje alarm.
$ToastEnabled        = $true
$ToastStopMinSeconds = 60

function Show-DashToast([string]$title, [string]$body) {
    # 1e keus: echte Windows-toast (blijft in het meldingencentrum staan).
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $tmpl  = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $nodes = $tmpl.GetElementsByTagName('text')
        [void]$nodes.Item(0).AppendChild($tmpl.CreateTextNode($title))
        [void]$nodes.Item(1).AppendChild($tmpl.CreateTextNode($body))
        $toast = New-Object Windows.UI.Notifications.ToastNotification $tmpl
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
        Start-Sleep -Milliseconds 250
        return
    } catch { }

    # 2e keus: BurntToast, als die module toevallig staat.
    try {
        if (Get-Module -ListAvailable -Name BurntToast) {
            Import-Module BurntToast -ErrorAction Stop
            New-BurntToastNotification -Text $title, $body
            return
        }
    } catch { }

    # 3e keus: ballontip bij de klok.
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon    = [System.Drawing.SystemIcons]::Information
        $ni.Visible = $true
        $ni.ShowBalloonTip(6000, $title, $body, [System.Windows.Forms.ToolTipIcon]::Info)
        Start-Sleep -Milliseconds 900
        $ni.Dispose()
    } catch { }
}

$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $j = $raw | ConvertFrom-Json } catch { exit 0 }
if (-not $j.session_id) { exit 0 }

$dir = Join-Path $PSScriptRoot 'session-status'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

# --- vorige stand lezen ------------------------------------------------------
$file       = Join-Path $dir ($j.session_id + '.json')
$prev       = $null
$prevEvent  = ''
$prevState  = ''
$prevPrompt = ''
$prevAge    = [double]::MaxValue
$prevPid    = 0
$prevStart  = ''
$prevTitle  = ''
$prevHost   = 0
if (Test-Path $file) {
    try {
        $prev       = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
        $prevEvent  = [string]$prev.event
        $prevPrompt = [string]$prev.prompt
        $prevAge    = ((Get-Date) - [datetime]$prev.updated).TotalSeconds
        if ($prev.PSObject.Properties['state'])       { $prevState = [string]$prev.state }
        if ($prev.PSObject.Properties['title'])       { $prevTitle = [string]$prev.title }
        if ($prev.PSObject.Properties['host_pid'])    { $prevHost  = [int]$prev.host_pid }
        if ($prev.PSObject.Properties['owner_pid'])   { $prevPid   = [int]$prev.owner_pid }
        if ($prev.PSObject.Properties['owner_start']) { $prevStart = [string]$prev.owner_start }
    } catch { }
}
if (-not $prevState) { $prevState = Get-DashState $prevEvent }

$ev = [string]$j.hook_event_name

# --- snelle route voor de tool-hooks ----------------------------------------
# PreToolUse/PostToolUse vuren bij elke tool-aanroep. Ze zijn er alleen om een
# sessie uit de attention- of klaar-stand te halen zodra Claude weer werkt.
# Staat de sessie al kort daarvoor op 'active', dan is er niets te melden en
# zijn we meteen weg: geen procesboom aflopen, geen toast, niets herschrijven.
$HeartbeatSeconds = 20
if (($ev -eq 'PostToolUse' -or $ev -eq 'PreToolUse') -and
    $prevState -eq 'active' -and $prevAge -lt $HeartbeatSeconds) {
    exit 0
}

$prompt = ''
if ($j.prompt) {
    $prompt = ([string]$j.prompt -replace '\s+', ' ').Trim()
    if ($prompt.Length -gt 140) { $prompt = $prompt.Substring(0, 140) + '...' }
}
$msg = ''
if ($j.message) { $msg = [string]$j.message }

# Bij Stop/Notification/PostToolUse stuurt de hook geen prompt mee: de laatste
# opdracht uit de vorige stand vasthouden, anders staat er "Klaar" zonder
# waarover het ging.
if (-not $prompt -and $prevPrompt) { $prompt = $prevPrompt }

# De procesboom aflopen kost een paar CIM-aanroepen; kennen we de PID van deze
# sessie al, dan nemen we die over. Een sessie verhuist niet van proces.
if ($prevPid -gt 0) {
    $owner = [pscustomobject]@{ OwnerPid = $prevPid; Start = $prevStart }
} else {
    $owner = Get-DashOwner
}

# De titel komt uit het transcript. Eenmaal gevonden bewaren we hem; bij Stop
# kijken we opnieuw, want dan kan Claude Code net een nieuwe samenvatting
# hebben weggeschreven.
$title = $prevTitle
if (-not $title -or $ev -eq 'Stop') {
    $t = Get-DashTitle ([string]$j.transcript_path) ([string]$j.session_id)
    if ($t) { $title = $t }
}

# Het venster waarin deze sessie draait. Een keer opzoeken is genoeg; daarna
# hoeft het dashboard alleen nog de titel van dat venster te lezen.
$hostPid = $prevHost
if ($hostPid -le 0 -and $owner.OwnerPid -gt 0) { $hostPid = Get-DashHostPid ([int]$owner.OwnerPid) }

$status = [ordered]@{
    session_id  = $j.session_id
    event       = $ev                  # SessionStart | UserPromptSubmit | PreToolUse | PostToolUse | Notification | Stop | SessionEnd
    state       = (Get-DashState $ev)
    tool        = [string]$j.tool_name # bij de tool-hooks: waar Claude mee bezig is
    title       = $title            # echte naam van de sessie, uit het transcript
    cwd         = $j.cwd
    prompt      = $prompt              # laatste opdracht (ingekort) -> "waar mee bezig"
    message     = $msg                 # bij Notification: waarom er aandacht nodig is
    owner_pid   = $owner.OwnerPid      # PID van het Claude-proces
    owner_start = $owner.Start         # starttijd, tegen hergebruikte PID's
    host_pid    = $hostPid             # het terminalvenster; daar staat de tabtitel
    updated     = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
}
$status | ConvertTo-Json | Set-Content -Path $file -Encoding UTF8

# ---------------------------------------------------------------------------
# Windows-melding zodra een sessie op je wacht.
# ---------------------------------------------------------------------------
if ($ToastEnabled -and ($ev -eq 'Notification' -or $ev -eq 'Stop')) {
    $leaf = ''
    if ($j.cwd) { $leaf = Split-Path -Leaf ([string]$j.cwd) }
    if (-not $leaf) { $leaf = 'Claude' }

    $doToast = $false
    $title   = ''
    $body    = ''

    if ($ev -eq 'Notification' -and $prevEvent -ne 'Notification') {
        $doToast = $true
        $title   = "Claude wacht op je: $leaf"
        $body    = if ($msg) { $msg } else { 'Claude heeft je input nodig.' }
    }
    elseif ($ev -eq 'Stop' -and $prevEvent -ne 'Stop' -and $prevAge -ge $ToastStopMinSeconds) {
        $doToast = $true
        $title   = "Claude is klaar: $leaf"
        $body    = if ($prompt) { $prompt } else { 'De opdracht is afgerond.' }
    }

    if ($doToast) {
        if ($body.Length -gt 180) { $body = $body.Substring(0, 180) + '...' }
        Show-DashToast $title $body
    }
}

# ---------------------------------------------------------------------------
# Alle beacons bundelen. -Prune gooit afgeronde sessies en beacons van
# verdwenen processen meteen weg, dus de map blijft klein en eerlijk.
# ---------------------------------------------------------------------------
$sessions = Get-DashSessions -Dir $dir -Prune
[void](Write-DashPayload -Root $PSScriptRoot -Sessions $sessions)

exit 0
