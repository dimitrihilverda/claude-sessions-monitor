# =============================================================================
#  focuslib.ps1 -- welk venster hoort bij welke Claude-sessie, en hoe haal je
#  het naar voren. Gedeeld door hud.ps1 (klikken) en session-api.ps1 (tikken
#  op de CYD en de knopacties).
#
#  Dot-source:  . (Join-Path $PSScriptRoot 'focuslib.ps1')
# =============================================================================

Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

# Alleen de ouderketen aflopen is niet genoeg: bij "attach project" hebben twee
# projecten hetzelfde proces, en MainWindowHandle geeft dan willekeurig een van
# de twee vensters. Daarom kijken we naar alle zichtbare vensters en scoren we
# ze op ouderketen EN op de projectnaam in de venstertitel.
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

# Processen die een sessievenster kunnen huisvesten. Staat jouw editor of
# terminal er niet bij? Zet hem erbij -- het is alleen een bonuspunt.
$DashHostProcs = @(
    'phpstorm64','phpstorm','idea64','idea','webstorm64','pycharm64','rider64',
    'windowsterminal','openconsole','conhost','cmd','powershell','pwsh',
    'code','wt','alacritty','wezterm-gui','mintty'
)

# Ouderketen van het Claude-proces, met controle op starttijd: is de echte
# ouder al afgesloten, dan wijst ParentProcessId naar een hergebruikte PID en
# zou je bij een willekeurig ander venster uitkomen.
function Get-DashProcChain([int]$startPid) {
    $chain = @()
    $id = $startPid
    $childStart = $null
    for ($i = 0; $i -lt 8 -and $id -gt 4; $i++) {
        $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
        if (-not $ci) { break }
        $start = $ci.CreationDate
        if ($childStart -and $start -and $start -gt $childStart) { break }
        $chain += [int]$id
        $childStart = $start
        $id = [int]$ci.ParentProcessId
    }
    return $chain
}

# Alle vensters met een score > 0, hoogste eerst.
function Get-DashWindowCandidates {
    param([string]$Cwd, [int]$OwnerPid = 0, [int]$HostPid = 0)

    $leaf = ''
    if ($Cwd) { try { $leaf = Split-Path -Leaf $Cwd } catch { } }
    $cwdLow  = ([string]$Cwd).ToLower()
    $leafLow = ([string]$leaf).ToLower()

    # De ouderketen begint bij het Claude-proces; kennen we dat niet, dan bij
    # het venster dat de beacon heeft vastgelegd.
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
            if ($HostPid -gt 0 -and $w.Pid -eq $HostPid) { $score += 120 }  # het venster uit de beacon
            if ($chain -contains $w.Pid)                 { $score += 100 }  # hoort bij deze sessie
            if     ($cwdLow  -and $t.Contains($cwdLow))  { $score += 45  }  # volledig pad in de titel
            elseif ($leafLow -and $t.Contains($leafLow)) { $score += 30  }  # projectnaam in de titel
            if ($DashHostProcs -contains $pn)            { $score += 10  }  # ziet eruit als IDE of terminal
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

function Show-DashWindow {
    param([Parameter(Mandatory = $true)]$Handle)
    try {
        if ([Dash.Win]::IsIconic($Handle)) { [void][Dash.Win]::ShowWindow($Handle, 9) }  # SW_RESTORE
        if (-not [Dash.Win]::SetForegroundWindow($Handle)) {
            [Dash.Win]::SwitchToThisWindow($Handle, $true)
        }
        Start-Sleep -Milliseconds 60
        return ([Dash.Win]::GetForegroundWindow() -eq $Handle)
    } catch { return $false }
}

# Haalt het venster van een sessie naar voren. Geeft het gekozen venster terug,
# of $null als er niets bij paste.
function Invoke-DashSessionFocus {
    param($Session, [switch]$FolderFallback)

    $hostPid = 0
    if ($Session.PSObject.Properties['host_pid'] -and $Session.host_pid) { $hostPid = [int]$Session.host_pid }
    $best = Get-DashBestWindow -Cwd ([string]$Session.cwd) -OwnerPid ([int]$Session.owner_pid) -HostPid $hostPid
    if ($best) {
        [void](Show-DashWindow -Handle $best.Handle)
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

# Toetsaanslagen naar het venster van een sessie sturen (SendKeys-notatie:
# {ENTER}, {ESC}, ^c, ...). Stuurt alleen als dat venster ook echt op de
# voorgrond staat -- anders zou je in een willekeurig ander venster typen.
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
