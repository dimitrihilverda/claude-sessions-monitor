<#
  platformlib.ps1 -- the handful of things that are not the same on Windows and
  on macOS, behind one seam each.

  The same idea as gfx.h on the display side: the rest of the code should not
  have to know which machine it is on. Almost all of this project is portable
  already -- reading beacons, deriving state, serving HTTP, framing the serial
  push -- and what is left is small and specific:

    * where the home directory is, and how to join a path inside it
    * the process table, for walking from a session to the program that owns it
    * bringing that program to the front

  On Windows the process table comes from one bulk CIM query, which is what made
  the API fast (757 ms cold, 0-5 ms warm, against 640 ms per level when each
  level was queried separately). On macOS it comes from one `ps` call, for the
  same reason.

  What is deliberately NOT here: the HUD. WinForms has no macOS counterpart, and
  pretending otherwise would mean a second UI to keep in step. On a Mac you run
  the API and use the display, or the status page in a browser.

  Written without a Mac to test on. Every platform-specific call therefore says
  what it could not do rather than failing silently, and selftest.ps1 checks all
  of them in one go on the machine itself.
#>

# ---- which machine are we on -----------------------------------------------
# $IsWindows and friends only exist in PowerShell 6 and up. On 5.1 they are
# undefined, and 5.1 is Windows-only, so absent means Windows.
$DashOnWindows = if (Test-Path variable:IsWindows) { [bool]$IsWindows } else { $true }
$DashOnMac     = if (Test-Path variable:IsMacOS)   { [bool]$IsMacOS }   else { $false }
$DashOnLinux   = if (Test-Path variable:IsLinux)   { [bool]$IsLinux }   else { $false }

function Get-DashPlatformName {
    if ($DashOnWindows) { return 'Windows' }
    if ($DashOnMac)     { return 'macOS' }
    if ($DashOnLinux)   { return 'Linux' }
    return 'unknown'
}

# ---- paths ------------------------------------------------------------------
function Get-DashHome {
    if ($DashOnWindows) {
        if ($env:USERPROFILE) { return $env:USERPROFILE }
        return (Join-Path $env:HOMEDRIVE $env:HOMEPATH)
    }
    return $env:HOME
}

<#
  Join a path made of several segments, so callers never write a separator
  themselves. This is not pedantry: Join-Path $HOME '.claude\projects' quietly
  produces "/Users/you/.claude\projects" on a Mac -- one directory with a
  backslash in its name, which exists nowhere, and the transcript lookup that
  supplies every session title comes back empty with no error at all.
#>
function Join-DashPath {
    param([Parameter(Mandatory)][string[]]$Parts)
    $p = $Parts[0]
    foreach ($deel in $Parts[1..($Parts.Count - 1)]) { $p = Join-Path $p $deel }
    return $p
}

function Get-DashClaudeDir    { Join-DashPath @((Get-DashHome), '.claude') }
function Get-DashProjectsDir  { Join-DashPath @((Get-DashHome), '.claude', 'projects') }
function Get-DashSettingsFile { Join-DashPath @((Get-DashHome), '.claude', 'settings.json') }

# ---- the process table ------------------------------------------------------
$script:DashProcTable   = $null
$script:DashProcTableAt = [datetime]::MinValue

<#
  Elapsed time as `ps` prints it -- [[dd-]hh:]mm:ss -- back into a start time.
  We only ever compare two of these against each other: a parent that started
  after its child means the real parent has gone and the PID has been reused.
#>
function ConvertFrom-DashElapsed([string]$s) {
    if (-not $s) { return $null }
    $dagen = 0
    $rest  = $s.Trim()
    if ($rest -match '^(\d+)-(.+)$') { $dagen = [int]$Matches[1]; $rest = $Matches[2] }
    $stukken = $rest.Split(':')
    if ($stukken.Count -lt 2) { return $null }
    try {
        if ($stukken.Count -eq 3) {
            $span = New-TimeSpan -Days $dagen -Hours ([int]$stukken[0]) -Minutes ([int]$stukken[1]) -Seconds ([int]$stukken[2])
        } else {
            $span = New-TimeSpan -Days $dagen -Minutes ([int]$stukken[0]) -Seconds ([int]$stukken[1])
        }
    } catch { return $null }
    return ((Get-Date) - $span)
}

function Get-DashProcTableWindows {
    $tab = @{}
    try {
        foreach ($p in (Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,CreationDate,Name -ErrorAction Stop)) {
            $tab[[int]$p.ProcessId] = @{
                Parent = [int]$p.ParentProcessId
                Start  = $p.CreationDate
                Name   = [string]$p.Name
            }
        }
    } catch { }
    return $tab
}

<#
  One `ps` for every process. The command name comes last on purpose: on macOS
  it is a full path and application bundles have spaces in them, so anything
  after the third column belongs to the name.
#>
function Get-DashProcTableUnix {
    $tab = @{}
    try {
        $regels = & ps -Ao 'pid=,ppid=,etime=,comm=' 2>$null
    } catch { return $tab }
    foreach ($r in $regels) {
        if ($r -notmatch '^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.+)$') { continue }
        $naam = $Matches[4].Trim()
        # /Applications/Ghostty.app/Contents/MacOS/ghostty -> ghostty, so the
        # name means the same thing it does on Windows.
        $leaf = $naam
        try { if ($naam -match '[\\/]') { $leaf = Split-Path -Leaf $naam } } catch { }
        $tab[[int]$Matches[1]] = @{
            Parent   = [int]$Matches[2]
            Start    = ConvertFrom-DashElapsed $Matches[3]
            Name     = $leaf
            FullName = $naam
        }
    }
    return $tab
}

function Get-DashProcTable {
    if ($null -ne $script:DashProcTable -and
        ([datetime]::UtcNow - $script:DashProcTableAt).TotalMilliseconds -lt 2000) {
        return $script:DashProcTable
    }
    $tab = if ($DashOnWindows) { Get-DashProcTableWindows } else { Get-DashProcTableUnix }
    $script:DashProcTable   = $tab
    $script:DashProcTableAt = [datetime]::UtcNow
    return $tab
}

<#
  The command line of one process. Deliberately not in the shared table: on
  Windows asking CIM for CommandLine across every process is markedly slower
  than asking for the four fields the table needs, and on macOS `ps -o args=`
  cannot be had in the same call as `comm=`. Only two places want it, and both
  want it for a single process.
#>
function Get-DashProcArgs([int]$id) {
    if ($id -le 0) { return '' }
    if ($DashOnWindows) {
        try {
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop
            return [string]$p.CommandLine
        } catch { return '' }
    }
    try {
        $uit = & ps -o 'args=' -p $id 2>$null
        return (($uit -join ' ').Trim())
    } catch { return '' }
}

# One process, from the same table -- so a single call does not cost a query.
function Get-DashProcEntry([int]$id) {
    $tab = Get-DashProcTable
    if ($tab.ContainsKey($id)) { return $tab[$id] }
    return $null
}

# ---- bringing a window to the front ----------------------------------------
<#
  On macOS there is no window enumeration to score, the way focuslib.ps1 does it
  through user32. What there is: the process tree, and AppleScript to raise an
  application. So we walk up from the session's own process until we meet
  something that is a program with windows rather than a shell, and raise that.

  This is genuinely coarser than the Windows side. There it picks the right
  window out of several -- two PhpStorm projects, four terminal tabs -- by
  matching the session title against window titles. Here you get the right
  application, and which tab is on top inside it is up to the application.

  It also needs permission: System Events driving another program counts as
  automation, so the first attempt raises a dialog and until it is granted this
  returns the refusal instead of pretending it worked. selftest.ps1 checks it.
#>
$DashUnixNeverApp = @(
    'login', 'sh', 'bash', 'zsh', 'fish', 'dash', 'tcsh', 'csh',
    'node', 'claude', 'python', 'python3', 'ruby', 'perl',
    'tmux', 'tmux: server', 'screen', 'launchd', 'ps', 'pwsh', 'powershell',
    'env', 'sudo', 'ssh', 'git'
)

function Get-DashMacApp([int]$startPid) {
    $tab = Get-DashProcTable
    $id  = $startPid
    for ($i = 0; $i -lt 10 -and $id -gt 1; $i++) {
        $e = $null
        if ($tab.ContainsKey($id)) { $e = $tab[$id] }
        if (-not $e) { break }
        $naam = [string]$e.Name
        if ($naam -and ($DashUnixNeverApp -notcontains $naam)) {
            return [pscustomobject]@{ Pid = $id; Name = $naam; FullName = [string]$e.FullName }
        }
        $id = [int]$e.Parent
    }
    return $null
}

<#
  Raise the application owning this PID. Returns $true only when AppleScript
  said nothing went wrong: reporting success on a failure is how you end up
  staring at a display that says "raised" while nothing moved on screen.
#>
function Show-DashMacApp([int]$appPid) {
    if ($appPid -le 0) { return $false }
    $script = @"
tell application "System Events"
    set procs to (every application process whose unix id is $appPid)
    if (count of procs) is 0 then error "no such process"
    set frontmost of item 1 of procs to true
end tell
"@
    try {
        $uit = & osascript -e $script 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Verbose ("osascript: " + ($uit -join ' '))
            return $false
        }
        return $true
    } catch {
        Write-Verbose ("osascript failed: " + $_.Exception.Message)
        return $false
    }
}

# ---- the serial port the display hangs off ---------------------------------
<#
  .NET's GetPortNames is reliable on Windows and not on Unix, where it lists
  every /dev/tty* it can find -- hundreds of them, none of which is a display.
  On macOS a USB serial adapter appears as /dev/cu.usbserial-* or
  /dev/cu.usbmodem*, and cu.* rather than tty.* is what you want: tty.* blocks
  on open waiting for carrier detect.
#>
$DashUnixSerialPatterns = @(
    'cu.usbserial*',      # CH340 on most Cheap Yellow Displays
    'cu.wchusbserial*',   # CH340 with the manufacturer's own driver
    'cu.SLAB_USBtoUART*', # CP210x, on some board revisions
    'cu.usbmodem*'        # native USB, which is how the ESP32-S3 appears
)

function Get-DashSerialCandidates {
    if ($DashOnWindows) {
        try { return @([System.IO.Ports.SerialPort]::GetPortNames()) } catch { return @() }
    }
    $uit = @()
    foreach ($pat in $DashUnixSerialPatterns) {
        try {
            $uit += @(Get-ChildItem -Path '/dev' -Filter $pat -ErrorAction SilentlyContinue |
                      ForEach-Object { $_.FullName })
        } catch { }
    }
    return @($uit | Sort-Object -Unique)
}
