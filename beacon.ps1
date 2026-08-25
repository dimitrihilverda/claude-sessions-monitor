# =============================================================================
#  beacon.ps1 -- the Claude session beacon, feeding the HUD and the display.
#  Called by the Claude Code hooks (see claude-hooks-snippet.json). Reads the
#  hook JSON from stdin, writes session-status\<session_id>.json and merges
#  everything into sessions.json + sessions.js.
#
#  v2: records the PID of the Claude process, so sessions that vanish without
#      a SessionEnd (terminal closed with the X, a crash, /clear) no longer
#      linger as "working".
# =============================================================================
$ErrorActionPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'sessionlib.ps1')

# --- Windows notification settings ------------------------------------------
# Notification = Claude wants permission or input -> always notify.
# Stop         = Claude has finished. Only notify if the run took longer than
#                $ToastStopMinSeconds; for short answers you are sitting in the
#                terminal anyway. This is purely about the toast: in the HUD
#                and on the display, Stop is a neutral "done" state and never
#                an orange alarm.
$ToastEnabled        = $true
$ToastStopMinSeconds = 60

function Show-DashToast([string]$title, [string]$body) {
    # First choice: a real Windows toast (stays in the notification centre).
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

    # Second choice: BurntToast, if that module happens to be installed.
    try {
        if (Get-Module -ListAvailable -Name BurntToast) {
            Import-Module BurntToast -ErrorAction Stop
            New-BurntToastNotification -Text $title, $body
            return
        }
    } catch { }

    # Third choice: a balloon tip near the clock.
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

# --- read the previous state -------------------------------------------------
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

# --- fast path for the tool hooks -------------------------------------------
# PreToolUse/PostToolUse fire on every tool call. They exist only to take a
# session out of the attention or done state once Claude is working again. If
# the session was already 'active' moments ago there is nothing to report, so
# we leave straight away: no process tree, no toast, nothing rewritten.
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

# On Stop/Notification/PostToolUse the hook sends no prompt, so hold on to the
# last instruction from the previous state. Otherwise it reads "done" without
# saying what it was about.
if (-not $prompt -and $prevPrompt) { $prompt = $prevPrompt }

# Walking the process tree costs a few CIM calls; if we already know this
# session's PID we reuse it. A session does not move between processes.
if ($prevPid -gt 0) {
    $owner = [pscustomobject]@{ OwnerPid = $prevPid; Start = $prevStart }
} else {
    $owner = Get-DashOwner
}

# The title comes from the transcript. Once found we keep it; on Stop we look
# again, because Claude Code may just have written a new summary.
# hebben weggeschreven.
$title = $prevTitle
if (-not $title -or $ev -eq 'Stop') {
    $t = Get-DashTitle ([string]$j.transcript_path) ([string]$j.session_id)
    if ($t) { $title = $t }
}

# The window this session runs in. Looking it up once is enough; after that we
# only need to read that window's title.
$hostPid = $prevHost
if ($hostPid -le 0 -and $owner.OwnerPid -gt 0) { $hostPid = Get-DashHostPid ([int]$owner.OwnerPid) }

$status = [ordered]@{
    session_id  = $j.session_id
    event       = $ev                  # SessionStart | UserPromptSubmit | PreToolUse | PostToolUse | Notification | Stop | SessionEnd
    state       = (Get-DashState $ev)
    tool        = [string]$j.tool_name # on the tool hooks: what Claude is busy with
    title       = $title            # real session name, from the transcript
    cwd         = $j.cwd
    prompt      = $prompt              # last instruction (shortened) -> "what it is doing"
    message     = $msg                 # on Notification: why attention is needed
    owner_pid   = $owner.OwnerPid      # PID of the Claude process
    owner_start = $owner.Start         # start time, against reused PIDs
    host_pid    = $hostPid             # the terminal window; that holds the tab title
    updated     = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
}
$status | ConvertTo-Json | Set-Content -Path $file -Encoding UTF8

# ---------------------------------------------------------------------------
# Windows notification as soon as a session is waiting for you.
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
# Merge every beacon. -Prune drops finished sessions and beacons of vanished
# processes right away, so the folder stays small and honest.
# ---------------------------------------------------------------------------
$sessions = Get-DashSessions -Dir $dir -Prune
[void](Write-DashPayload -Root $PSScriptRoot -Sessions $sessions)

exit 0
