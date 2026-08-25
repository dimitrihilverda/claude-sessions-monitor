# =============================================================================
#  focuslib.ps1 -- which window belongs to which Claude session, and how to
#  bring it to the front. Shared by hud.ps1 (clicking) and session-api.ps1
#  (tapping the display, and the button actions).
#
#  Dot-source:  . (Join-Path $PSScriptRoot 'focuslib.ps1')
# =============================================================================

Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

# Walking the parent chain alone is not enough: with "attach project" two
# projects share one process, and MainWindowHandle then returns an arbitrary
# one of the two windows. So we look at every visible window and score it on
# the parent chain AND on the project name in the window title.
if (-not ('Dash.Win' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace Dash {
  public class WinInfo {
    public IntPtr Handle;
    public int    Pid;
    public string Title;
  }

  public static class Win {
    [DllImport("user32.dll")] public static extern bool   SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool   ShowWindow(IntPtr h, int nCmdShow);
    [DllImport("user32.dll")] public static extern int    GetWindowLong(IntPtr h, int nIndex);
    [DllImport("user32.dll")] public static extern int    SetWindowLong(IntPtr h, int nIndex, int v);
    [DllImport("user32.dll")] public static extern bool   IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool   IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern void   SwitchToThisWindow(IntPtr h, bool altTab);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool   AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("user32.dll")] public static extern bool   BringWindowToTop(IntPtr h);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", EntryPoint = "GetWindowThreadProcessId")]
    public static extern uint ThreadOf(IntPtr h, IntPtr pid);

    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    delegate bool EnumProc(IntPtr h, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);

    public static List<WinInfo> TopLevel() {
      List<WinInfo> list = new List<WinInfo>();
      EnumWindows(delegate(IntPtr h, IntPtr l) {
        if (!IsWindowVisible(h)) return true;
        int len = GetWindowTextLength(h);
        if (len < 1) return true;
        StringBuilder sb = new StringBuilder(len + 2);
        GetWindowText(h, sb, sb.Capacity);
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        WinInfo w = new WinInfo();
        w.Handle = h; w.Pid = (int)pid; w.Title = sb.ToString();
        list.Add(w);
        return true;
      }, IntPtr.Zero);
      return list;
    }
  }
}
'@
}

# Processes that can host a session window. Your editor or terminal not in the
# list? Add it -- it is only worth a bonus point.
$DashHostProcs = @(
    'phpstorm64','phpstorm','idea64','idea','webstorm64','pycharm64','rider64',
    'windowsterminal','openconsole','conhost','cmd','powershell','pwsh',
    'code','wt','alacritty','wezterm-gui','mintty'
)

# Parent chain of the Claude process, with a start-time check: if the real
# parent has already exited, ParentProcessId points at a reused PID and you
# would end up at some unrelated window.
<#
  The process table, fetched in one go and kept for a moment.

  Walking a parent chain used to cost one filtered CIM query per level, and a
  single one of those takes about 640 ms on this machine -- four levels came to
  two full seconds. One unfiltered query returns all 566 processes in roughly
  550 ms, so we ask once and walk it in memory: a fixed cost instead of one that
  grows with the depth of the chain.

  The short cache matters for the case that hurt: raising a window does several
  chain walks in a row while scoring candidate windows. Without it each one paid
  the query again. Two seconds is short enough that a process which has since
  exited is still caught by the liveness checks elsewhere.
#>
$script:DashProcTable   = $null
$script:DashProcTableAt = [datetime]::MinValue

function Get-DashProcTable {
    if ($null -ne $script:DashProcTable -and
        ([datetime]::UtcNow - $script:DashProcTableAt).TotalMilliseconds -lt 2000) {
        return $script:DashProcTable
    }
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
    $script:DashProcTable   = $tab
    $script:DashProcTableAt = [datetime]::UtcNow
    return $tab
}

function Get-DashProcChain([int]$startPid) {
    $tab = Get-DashProcTable
    $chain = @()
    $id = $startPid
    $childStart = $null
    for ($i = 0; $i -lt 8 -and $id -gt 4; $i++) {
        if (-not $tab.ContainsKey($id)) { break }
        $p = $tab[$id]
        $start = $p.Start
        # A parent that started later than its child means the real parent has
        # exited and this PID has been reused; stop rather than follow it to a
        # window that has nothing to do with this session.
        if ($childStart -and $start -and $start -gt $childStart) { break }
        $chain += [int]$id
        $childStart = $start
        $id = [int]$p.Parent
    }
    return $chain
}

# Every window with a score > 0, highest first.
function Get-DashWindowCandidates {
    param([string]$Cwd, [int]$OwnerPid = 0, [int]$HostPid = 0)

    $leaf = ''
    if ($Cwd) { try { $leaf = Split-Path -Leaf $Cwd } catch { } }
    $cwdLow  = ([string]$Cwd).ToLower()
    $leafLow = ([string]$leaf).ToLower()

    # The parent chain starts at the Claude process; if we do not know it, start
    # at the window the beacon recorded.
    $chain = @()
    if     ($OwnerPid -gt 0) { $chain = Get-DashProcChain $OwnerPid }
    elseif ($HostPid  -gt 0) { $chain = Get-DashProcChain $HostPid }

    $out = @()
    try {
        foreach ($w in [Dash.Win]::TopLevel()) {
            $pn = ''
            try { $pn = (Get-Process -Id $w.Pid -ErrorAction Stop).ProcessName.ToLower() } catch { continue }
            $t = $w.Title.ToLower()

            $score = 0
            if ($HostPid -gt 0 -and $w.Pid -eq $HostPid) { $score += 120 }  # the window from the beacon
            if ($chain -contains $w.Pid)                 { $score += 100 }  # belongs to this session
            if     ($cwdLow  -and $t.Contains($cwdLow))  { $score += 45  }  # full path in the title
            elseif ($leafLow -and $t.Contains($leafLow)) { $score += 30  }  # project name in the title
            if ($DashHostProcs -contains $pn)            { $score += 10  }  # looks like an IDE or terminal
            if ($score -le 0) { continue }

            $out += [pscustomobject]@{
                Score = $score; Proc = $pn; Pid = $w.Pid
                Title = $w.Title; Handle = $w.Handle
            }
        }
    } catch { }

    return ($out | Sort-Object Score -Descending)
}

function Get-DashBestWindow {
    param([string]$Cwd, [int]$OwnerPid = 0, [int]$HostPid = 0, [int]$MinScore = 30)
    $c = @(Get-DashWindowCandidates -Cwd $Cwd -OwnerPid $OwnerPid -HostPid $HostPid)
    if ($c.Count -and $c[0].Score -ge $MinScore) { return $c[0] }
    return $null
}

<#
  Bring a window to the front, and say honestly whether it worked.

  Windows only lets a process call SetForegroundWindow under narrow conditions --
  roughly, it has to own the current foreground window or have just handled user
  input. The HUD is a real GUI process and usually qualifies. session-api.ps1 does
  not: it runs hidden, started by wscript, so its calls are silently ignored and
  the window stays exactly where it was.

  Hence three attempts, cheapest first. The third briefly attaches our input
  queue to the target window's thread, which makes Windows treat the call as
  coming from that thread and is the long-standing remedy for precisely this. We
  detach again in a finally, because leaving the queues attached would tie our
  input handling to another process.
#>
function Show-DashWindow {
    param([Parameter(Mandatory = $true)]$Handle)
    try {
        if ([Dash.Win]::IsIconic($Handle)) { [void][Dash.Win]::ShowWindow($Handle, 9) }  # SW_RESTORE

        [void][Dash.Win]::SetForegroundWindow($Handle)
        if ([Dash.Win]::GetForegroundWindow() -eq $Handle) { return $true }

        [Dash.Win]::SwitchToThisWindow($Handle, $true)
        Start-Sleep -Milliseconds 60
        if ([Dash.Win]::GetForegroundWindow() -eq $Handle) { return $true }

        $eigen = [Dash.Win]::GetCurrentThreadId()
        $doel  = [Dash.Win]::ThreadOf($Handle, [IntPtr]::Zero)
        if ($doel -ne 0 -and $doel -ne $eigen) {
            $vast = $false
            try {
                $vast = [Dash.Win]::AttachThreadInput($eigen, $doel, $true)
                [void][Dash.Win]::BringWindowToTop($Handle)
                [void][Dash.Win]::SetForegroundWindow($Handle)
            } finally {
                if ($vast) { [void][Dash.Win]::AttachThreadInput($eigen, $doel, $false) }
            }
            Start-Sleep -Milliseconds 60
            if ([Dash.Win]::GetForegroundWindow() -eq $Handle) { return $true }
        }

        <#
          Last resort, through the shell. Windows blocks a process from taking the
          foreground for a while after somebody else just took it, and none of the
          calls above get past that. AppActivate goes via WScript.Shell, which does
          the activation dance the shell is allowed to do, and it demonstrably
          raises windows the calls above give up on -- including Windows Terminal.
        #>
        try {
            $procId = 0
            [void][Dash.Win]::ThreadOf($Handle, [IntPtr]::Zero)
            $sh = New-Object -ComObject WScript.Shell
            foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
                if ($p.MainWindowHandle -eq $Handle) { $procId = $p.Id; break }
            }
            if ($procId -gt 0) { [void]$sh.AppActivate([int]$procId) }
            Start-Sleep -Milliseconds 150
        } catch { }

        return ([Dash.Win]::GetForegroundWindow() -eq $Handle)
    } catch { return $false }
}

# Brings a session's window to the front. Returns the chosen window, or $null
# if nothing matched.
<#
  Raising a window through the HUD instead of doing it ourselves.

  Windows only grants SetForegroundWindow to a process that meets certain
  conditions, and session-api.ps1 does not: it runs hidden under wscript. The HUD
  is a real GUI process and does. Same code, different standing -- which is why
  clicking in the HUD always worked while a tap on the display often did not.

  So the API asks instead of trying. It drops a request file; the HUD picks it up
  on a short timer, raises the window with its own rights, and writes the outcome
  back. The API waits briefly for that answer so the display still learns whether
  it worked.

  Deliberately a file rather than a pipe or a window message: the HUD is a
  single-threaded WinForms app, and a blocking read would freeze its UI. Checking
  whether a file exists, four times a second, costs nothing.

  The nonce matters. Without it a reply to an earlier request could be mistaken
  for the answer to this one, and you would be told a different window came
  forward than the one you tapped.
#>
function Get-DashFocusPaths([string]$Root) {
    return @{
        Request = (Join-Path $Root 'focus-request.json')
        Result  = (Join-Path $Root 'focus-result.json')
    }
}

# --- API side -----------------------------------------------------------------
function Request-DashFocus {
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][string]$Root,
        [int]$TimeoutMs = 1500
    )
    $paden = Get-DashFocusPaths $Root
    $nonce = [guid]::NewGuid().ToString()
    try {
        @{ id = [string]$Session.session_id; nonce = $nonce
           at = (Get-Date).ToString('o') } | ConvertTo-Json -Compress |
            Set-Content -Path $paden.Request -Encoding UTF8
    } catch { return $null }

    $klaar = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([datetime]::UtcNow -lt $klaar) {
        Start-Sleep -Milliseconds 60
        if (-not (Test-Path $paden.Result)) { continue }
        try {
            $r = Get-Content $paden.Result -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($r.nonce -ne $nonce) { continue }      # antwoord op een ouder verzoek
            Remove-Item $paden.Result -Force -ErrorAction SilentlyContinue
            if (-not $r.found) { return @{ Found = $false; Raised = $false; Title = ''; Handle = [IntPtr]::Zero } }
            # A window handle is valid across processes, so the HUD can hand it
            # over and we skip searching for the same window twice.
            $h = [IntPtr]::Zero
            try { if ($r.handle) { $h = [IntPtr][int64]$r.handle } } catch { }
            return @{ Found = $true; Raised = [bool]$r.ok; Title = [string]$r.title; Handle = $h }
        } catch { }
    }
    # Geen HUD, of hij reageerde niet. Verzoek opruimen, anders wordt het later
    # alsnog uitgevoerd en springt er zomaar een venster naar voren.
    Remove-Item $paden.Request -Force -ErrorAction SilentlyContinue
    return $null
}

# --- HUD side -----------------------------------------------------------------
function Read-DashFocusRequest([string]$Root) {
    $paden = Get-DashFocusPaths $Root
    if (-not (Test-Path $paden.Request)) { return $null }
    try {
        $r = Get-Content $paden.Request -Raw -Encoding UTF8 | ConvertFrom-Json
        Remove-Item $paden.Request -Force -ErrorAction SilentlyContinue
        # Ouder dan een paar seconden: de vrager wacht niet meer, dus niets doen.
        try { if (((Get-Date) - [datetime]$r.at).TotalSeconds -gt 5) { return $null } } catch { }
        return $r
    } catch {
        Remove-Item $paden.Request -Force -ErrorAction SilentlyContinue
        return $null
    }
}

function Write-DashFocusResult {
    param([string]$Root, [string]$Nonce, [bool]$Found, [bool]$Ok, [string]$Title, $Handle = 0)
    $paden = Get-DashFocusPaths $Root
    try {
        $h = 0
        try { $h = [int64]$Handle } catch { }
        @{ nonce = $Nonce; found = $Found; ok = $Ok; title = $Title; handle = $h } |
            ConvertTo-Json -Compress | Set-Content -Path $paden.Result -Encoding UTF8
    } catch { }
}

function Invoke-DashSessionFocus {
    param($Session, [switch]$FolderFallback)

    $hostPid = 0
    if ($Session.PSObject.Properties['host_pid'] -and $Session.host_pid) { $hostPid = [int]$Session.host_pid }
    $best = Get-DashBestWindow -Cwd ([string]$Session.cwd) -OwnerPid ([int]$Session.owner_pid) -HostPid $hostPid
    if ($best) {
        # Niet weggooien wat we net hebben uitgezocht: Show-DashWindow weet of het
        # venster echt naar voren kwam, en zonder die uitkomst meldt de API "ok"
        # terwijl er op het scherm niets gebeurt. Dat kostte een halve middag.
        $gelukt = Show-DashWindow -Handle $best.Handle
        $best | Add-Member -NotePropertyName Raised -NotePropertyValue $gelukt -Force
        return $best
    }
    if ($FolderFallback) {
        try {
            $cwd = [string]$Session.cwd
            if ($cwd -and (Test-Path $cwd)) { Start-Process explorer.exe $cwd }
        } catch { }
    }
    return $null
}

# Send keystrokes to a session's window (SendKeys notation: {ENTER}, {ESC},
# ^c, ...). Only sends if that window really is in the foreground -- otherwise
# you would be typing into some other window.
function Send-DashKeys {
    param(
        [Parameter(Mandatory = $true)]$Handle,
        [Parameter(Mandatory = $true)][string]$Keys,
        [int]$DelayMs = 250
    )
    if (-not (Show-DashWindow -Handle $Handle)) { return $false }
    Start-Sleep -Milliseconds $DelayMs
    if ([Dash.Win]::GetForegroundWindow() -ne $Handle) { return $false }
    try {
        [System.Windows.Forms.SendKeys]::SendWait($Keys)
        return $true
    } catch { return $false }
}
