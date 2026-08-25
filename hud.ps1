# =============================================================================
#  hud.ps1 -- a small always-on-top window with your live Claude sessions
#
#  Start (no console window):  wscript.exe hud.vbs
#  Or to test:                 powershell -ExecutionPolicy Bypass -File hud.ps1
#
#  Drag        : left mouse button anywhere in the window
#  Click a row : tries to bring that session's terminal to the front
#  Right-click : menu (pin, compact, attention only, autostart, quit)
#  Double-click tray: hide or restore the HUD
# =============================================================================
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Root = $PSScriptRoot
. (Join-Path $Root 'sessionlib.ps1')

$StatusDir  = Join-Path $Root 'session-status'
$ConfigPath = Join-Path $Root 'hud-config.json'
$RefreshMs  = 3000

# Also refresh sessions.json / sessions.js, so the web page and the display
# ride along on the HUD's refresh (and dead sessions disappear there too).
$WritePayload = $true

# ---- colours ----------------------------------------------------------------
$C = @{
    Bg        = [System.Drawing.Color]::FromArgb(31, 38, 47)
    Row       = [System.Drawing.Color]::FromArgb(38, 46, 56)
    RowAlt    = [System.Drawing.Color]::FromArgb(44, 53, 64)
    Line      = [System.Drawing.Color]::FromArgb(56, 66, 79)
    Text      = [System.Drawing.Color]::FromArgb(240, 244, 249)
    Muted     = [System.Drawing.Color]::FromArgb(138, 151, 166)
    Green     = [System.Drawing.Color]::FromArgb(141, 198, 63)
    Orange    = [System.Drawing.Color]::FromArgb(232, 163, 61)
    Steel     = [System.Drawing.Color]::FromArgb(155, 176, 199)
}

$F = @{
    Head  = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Bold)
    Name  = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    Why   = New-Object System.Drawing.Font('Segoe UI', 8.25)
    Chip  = New-Object System.Drawing.Font('Segoe UI', 7.5, [System.Drawing.FontStyle]::Bold)
    Small = New-Object System.Drawing.Font('Segoe UI', 7.5)
}

# ---- persisting settings ----------------------------------------------------
$cfg = [ordered]@{
    x = -1; y = -1; compact = $false; onlyAttention = $false
    topmost = $true; opacity = 0.94
}
if (Test-Path $ConfigPath) {
    try {
        $saved = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @($cfg.Keys)) {
            if ($saved.PSObject.Properties[$k]) { $cfg[$k] = $saved.$k }
        }
    } catch { }
}
function Save-Cfg {
    try {
        $cfg.x = $form.Left; $cfg.y = $form.Top
        ($cfg | ConvertTo-Json) | Set-Content -Path $ConfigPath -Encoding UTF8
    } catch { }
}

# ---- bringing a window to the front -----------------------------------------
# The window finder lives in focuslib.ps1, so the HUD and the display API share
# the same logic.
. (Join-Path $Root 'focuslib.ps1')
. (Join-Path $Root 'langlib.ps1')

function Show-SessionWindow($sess, [switch]$Explain) {
    $cwd = [string]$sess.cwd

    # Shift held down? Then you want the folder, not the window.
    if ([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Shift) {
        try { if ($cwd -and (Test-Path $cwd)) { Start-Process explorer.exe $cwd; return } } catch { }
    }

    # Ctrl+click: show why the HUD picks this window. Useful when it grabs the
    # wrong project window -- you immediately see which titles exist.
    if ($Explain) {
        $cands = @(Get-DashWindowCandidates -Cwd $cwd -OwnerPid ([int]$sess.owner_pid))
        $chain = @()
        if ([int]$sess.owner_pid -gt 0) { $chain = Get-DashProcChain ([int]$sess.owner_pid) }
        $txt = "Session: $($sess.name)`nFolder: $cwd`nParent chain (PIDs): $($chain -join ', ')`n`nCandidates:`n"
        foreach ($c in ($cands | Select-Object -First 8)) {
            $txt += "  {0,4}  {1} ({2})  {3}`n" -f $c.Score, $c.Proc, $c.Pid, $c.Title
        }
        if (-not $cands.Count) { $txt += "  (no window matched at all)`n" }
        $best = if ($cands.Count -and $cands[0].Score -ge 30) { $cands[0] } else { $null }
        $txt += "`nChosen: " + $(if ($best) { "$($best.Title)  [score $($best.Score)]" } else { 'nothing -- opens the folder' })
        [void][System.Windows.Forms.MessageBox]::Show($txt, (T 'notify.pickWindow'), 'OK', 'Information')
        return
    }

    # No Explorer fallback: you clicked a session, not a folder. If it does not
    # work, just say so -- shift+click opens the folder anyway.
    $w = Invoke-DashSessionFocus -Session $sess
    if (-not $w) {
        try {
            $tray.ShowBalloonTip(4000, (T 'notify.noWindow'),
                "No window found for '$($sess.name)'. Shift+click opens the folder.", 'Info')
        } catch { }
    }
}

# ---- the window -------------------------------------------------------------
$form                 = New-Object System.Windows.Forms.Form
$form.Text            = (T 'app.title')
$form.FormBorderStyle = 'None'
$form.BackColor       = $C.Bg
$form.ShowInTaskbar   = $false
$form.TopMost         = [bool]$cfg.topmost
$form.StartPosition   = 'Manual'
$form.Width           = 360
$form.Height          = 160
$form.Opacity         = [double]$cfg.opacity
$form.KeyPreview      = $true
$form.GetType().GetProperty('DoubleBuffered', 'Instance,NonPublic').SetValue($form, $true, $null)

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ($cfg.x -lt 0 -or $cfg.y -lt 0) {
    $form.Left = $screen.Right - $form.Width - 18
    $form.Top  = $screen.Top + 18
} else {
    $form.Left = [int]$cfg.x
    $form.Top  = [int]$cfg.y
}

function Set-Rounded {
    try {
        $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
        $r  = 14
        $w  = $form.Width; $h = $form.Height
        $gp.AddArc(0, 0, $r, $r, 180, 90)
        $gp.AddArc($w - $r - 1, 0, $r, $r, 270, 90)
        $gp.AddArc($w - $r - 1, $h - $r - 1, $r, $r, 0, 90)
        $gp.AddArc(0, $h - $r - 1, $r, $r, 90, 90)
        $gp.CloseAllFigures()
        $form.Region = New-Object System.Drawing.Region($gp)
    } catch { }
}

# ---- state ------------------------------------------------------------------
$state = [ordered]@{
    rows      = @()          # visible sessions
    known     = 0
    hitboxes  = @()          # @{ Rect; Sess }
    hover     = -1
    seen      = @{}          # session_id|updated -> already announced
    lastOk    = $null
    dragging  = $false
    dragFrom  = $null
    formFrom  = $null
    fp        = ''
    restart   = $false      # set by 'Restart HUD' in the menu
    fpUi      = ''          # what the window currently looks like
    lastCount = -1          # number of rows at the previous paint
    clock     = '--:--'
}

$HeadH = 30
function Get-RowH { if ($cfg.compact) { return 30 } else { return 46 } }

# Only repaint the given rows. The paint routine still walks every row -- it
# has to, because that is where the click targets are rebuilt -- but Windows
# clips away everything outside these rectangles.
function Invalidate-Rijen($indexen) {
    $iets = $false
    foreach ($i in $indexen) {
        if ($null -eq $i) { continue }
        if ($i -lt 0 -or $i -ge @($state.hitboxes).Count) { continue }
        $r = $state.hitboxes[$i].Rect
        $form.Invalidate((New-Object System.Drawing.Rectangle $r.X, $r.Y, $r.Width, $r.Height))
        $iets = $true
    }
    if (-not $iets) { $form.Invalidate() }
}

function Update-Layout {
    $n = [Math]::Max(1, @($state.rows).Count)
    $h = $HeadH + ($n * (Get-RowH)) + 24
    $form.Height = [int][Math]::Min(720, $h)
    Set-Rounded
}

# ---- painting ---------------------------------------------------------------
function Draw-Chip($g, $x, $y, $text, $col) {
    $sz = $g.MeasureString($text, $F.Chip)
    $w  = [int]$sz.Width + 14
    $h  = 16
    $rect = New-Object System.Drawing.Rectangle ([int]($x - $w)), ([int]$y), $w, $h
    $br = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(38, $col))
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(150, $col))
    $g.FillRectangle($br, $rect)
    $g.DrawRectangle($pen, $rect)
    $tb = New-Object System.Drawing.SolidBrush $col
    $g.DrawString($text, $F.Chip, $tb, ($rect.X + 7), ($rect.Y + 1))
    $br.Dispose(); $pen.Dispose(); $tb.Dispose()
    return $rect
}

$form.Add_Paint({
    param($s, $e)
  try {
    $g = $e.Graphics
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    $W = $form.Width

    # header
    $hb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(24, 30, 38))
    $g.FillRectangle($hb, 0, 0, $W, $HeadH); $hb.Dispose()

    $att = @($state.rows | Where-Object { $_.state -eq 'attention' }).Count
    $dotCol = if ($att -gt 0) { $C.Orange } elseif (@($state.rows).Count -gt 0) { $C.Green } else { $C.Muted }
    $db = New-Object System.Drawing.SolidBrush $dotCol
    $g.FillEllipse($db, 12, 12, 8, 8); $db.Dispose()

    $tb = New-Object System.Drawing.SolidBrush $C.Text
    $g.DrawString((T 'app.header'), $F.Head, $tb, 26, 7)
    $tb.Dispose()

    $mb = New-Object System.Drawing.SolidBrush $C.Muted
    $meta = "$(@($state.rows).Count) live  ·  $($state.clock)"
    if ($cfg.onlyAttention) { $meta = "filter aan  ·  " + $meta }
    $mw = $g.MeasureString($meta, $F.Small).Width
    $g.DrawString($meta, $F.Small, $mb, ($W - $mw - 12), 9)
    $mb.Dispose()

    $lp = New-Object System.Drawing.Pen $C.Line
    $g.DrawLine($lp, 0, $HeadH, $W, $HeadH); $lp.Dispose()

    # rows
    $state.hitboxes = @()
    $y  = $HeadH + 6
    $rh = Get-RowH

    if (@($state.rows).Count -eq 0) {
        $eb = New-Object System.Drawing.SolidBrush $C.Muted
        if ($cfg.onlyAttention) {
            # otherwise the HUD looks broken when it is only a filter being on
            $ob = New-Object System.Drawing.SolidBrush $C.Orange
            $g.DrawString((T 'empty.filtered'), $F.Why, $eb, 14, ($y + 6))
            $g.DrawString((T 'empty.filterHint'),
                          $F.Small, $ob, 14, ($y + 24))
            $ob.Dispose()
        } else {
            $g.DrawString((T 'empty.none'), $F.Why, $eb, 14, ($y + 6))
            $g.DrawString((T 'empty.beacons' @($state.known)), $F.Small, $eb, 14, ($y + 24))
        }
        $eb.Dispose()
        return
    }

    $i = 0
    foreach ($r in $state.rows) {
        $rect = New-Object System.Drawing.Rectangle 6, $y, ($W - 12), ($rh - 4)

        $bg = if ($state.hover -eq $i) { $C.RowAlt } else { $C.Row }
        $rb = New-Object System.Drawing.SolidBrush $bg
        $g.FillRectangle($rb, $rect); $rb.Dispose()

        $col = switch ($r.state) {
            'attention' { $C.Orange }
            'active'    { $C.Green }
            default     { $C.Steel }
        }
        $cb = New-Object System.Drawing.SolidBrush $col
        $g.FillRectangle($cb, $rect.X, $rect.Y, 3, $rect.Height); $cb.Dispose()

        $nb = New-Object System.Drawing.SolidBrush $C.Text
        $g.DrawString($r.name, $F.Name, $nb, ($rect.X + 12), ($rect.Y + 4)); $nb.Dispose()

        [void](Draw-Chip $g ($rect.Right - 8) ($rect.Y + 6) $r.label $col)

        if (-not $cfg.compact) {
            # line 1 is the session title, line 2 says where it runs
            $why = [string]$r.why
            if (-not $why) { $why = $r.cwd }
            $waar = [string]$r.folder
            if ($waar) { $why = "$waar  ·  $why" }
            $wb = New-Object System.Drawing.SolidBrush $C.Muted
            $fmt = New-Object System.Drawing.StringFormat
            $fmt.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
            $fmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
            $wr = New-Object System.Drawing.RectangleF ($rect.X + 12), ($rect.Y + 23), ($rect.Width - 78), 14
            $g.DrawString("$($r.since)  $why", $F.Why, $wb, $wr, $fmt)
            $wb.Dispose(); $fmt.Dispose()
        }

        $state.hitboxes += @{ Rect = $rect; Sess = $r }
        $y += $rh
        $i++
    }
  } catch { }
})

# ---- refreshing -------------------------------------------------------------
function Refresh-Now {
    try {
        $all = @(Get-DashSessions -Dir $StatusDir)
        $vis = @($all | Where-Object { $_.visible })
        if ($cfg.onlyAttention) { $vis = @($vis | Where-Object { $_.state -eq 'attention' }) }

        $state.rows  = $vis
        $state.known = $all.Count
        $state.lastOk = Get-Date

        # only write to disk when something really changed
        if ($WritePayload) {
            $fp = (($vis | ForEach-Object { $_.session_id + $_.state + $_.updated }) -join ';')
            if ($fp -ne $state.fp) {
                $state.fp = $fp
                [void](Write-DashPayload -Root $Root -Sessions $all)
            }
        }

        # a new attention request -> sound + tray balloon
        foreach ($r in @($vis | Where-Object { $_.state -eq 'attention' })) {
            $key = $r.session_id + '|' + $r.updated
            if (-not $state.seen.ContainsKey($key)) {
                $state.seen[$key] = $true
                try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
                try { $tray.ShowBalloonTip(6000, (T 'notify.waiting' @($r.name)), [string]$r.why, 'Warning') } catch { }
            }
        }

        $att = @($vis | Where-Object { $_.state -eq 'attention' }).Count
        $tray.Text = if ($att) { "Claude: $att wacht op jou" } else { "Claude: $($vis.Count) actief" }
        Set-TrayIcon $att $vis.Count
    } catch {
        $state.lastOk = $null
    }
    # Repainting is what you saw as flicker: only do it when something really
    # changes. If only the clock ticks, the header line is enough.
    $rows  = @($state.rows)
    $fpUi  = (($rows | ForEach-Object { $_.session_id + '|' + $_.state + '|' + $_.label + '|' + $_.name + '|' + $_.why + '|' + $_.since }) -join ';') + '#' + $state.known + '#' + $cfg.onlyAttention
    $clock = if ($state.lastOk) { $state.lastOk.ToString('HH:mm') } else { '--:--' }

    $countChanged = ($rows.Count -ne $state.lastCount)
    $uiChanged    = ($fpUi -ne $state.fpUi)
    $clockChanged = ($clock -ne $state.clock)

    $state.fpUi      = $fpUi
    $state.lastCount = $rows.Count
    $state.clock     = $clock

    if ($countChanged) {
        Update-Layout
        $form.Invalidate()
    } elseif ($uiChanged) {
        $form.Invalidate()
    } elseif ($clockChanged) {
        $form.Invalidate((New-Object System.Drawing.Rectangle 0, 0, $form.Width, $HeadH))
    }
}

# ---- tray -------------------------------------------------------------------
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Visible = $true
$iconCache = @{}
function Set-TrayIcon([int]$att, [int]$n) {
    $key = "$att-$n"
    if ($tray.Icon -and $iconCache.ContainsKey($key)) { return }
    try {
        $bmp = New-Object System.Drawing.Bitmap 16, 16
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $col = if ($att -gt 0) { $C.Orange } elseif ($n -gt 0) { $C.Green } else { $C.Muted }
        $b   = New-Object System.Drawing.SolidBrush $col
        $g.FillEllipse($b, 2, 2, 12, 12)
        $b.Dispose(); $g.Dispose()
        $h = $bmp.GetHicon()
        $tray.Icon = [System.Drawing.Icon]::FromHandle($h)
        $iconCache[$key] = $true
    } catch { }
}
Set-TrayIcon 0 0

# ---- menu -------------------------------------------------------------------
$menu = New-Object System.Windows.Forms.ContextMenuStrip

function Add-Check($text, $checked, $action) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem $text
    $mi.CheckOnClick = $true
    $mi.Checked = [bool]$checked
    $mi.Add_Click($action)
    [void]$menu.Items.Add($mi)
    return $mi
}

$miTop = Add-Check (T 'menu.topmost') $cfg.topmost {
    $cfg.topmost = -not $cfg.topmost
    $form.TopMost = [bool]$cfg.topmost
    Save-Cfg
}
$miCompact = Add-Check (T 'menu.compact') $cfg.compact {
    $cfg.compact = -not $cfg.compact
    $state.lastCount = -1
    Save-Cfg; Refresh-Now
}
$miOnly = Add-Check (T 'menu.onlyAttention') $cfg.onlyAttention {
    $cfg.onlyAttention = -not $cfg.onlyAttention
    $state.lastCount = -1
    Save-Cfg; Refresh-Now
}
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miDash = New-Object System.Windows.Forms.ToolStripMenuItem (T 'menu.dashboard')
$miDash.Add_Click({ try { Start-Process (Join-Path $Root 'dashboard.html') } catch { } })
[void]$menu.Items.Add($miDash)

# ---- address for the touchscreen --------------------------------------------
<#
  This PC usually has more than one IPv4 address: VirtualBox, WSL and Docker
  each add one. Only one of them is usable for the display, namely the address
  of the interface the default route runs over. We select on that, rather than
  "anything that is not loopback" -- which throws in 172.19.x and 192.168.56.x
  for free and leaves you guessing which one to type into the display.
#>
$ApiPort = 8787          # same as the default in session-api.ps1

function Get-LanIp {
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
                 Sort-Object RouteMetric, ifMetric | Select-Object -First 1
        if ($route) {
            $ip = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop |
                  Where-Object { $_.IPAddress -notlike '169.254.*' } |
                  Select-Object -First 1 -ExpandProperty IPAddress
            if ($ip) { return $ip }
        }
    } catch { }
    # no default route (no network): better to promise nothing
    return $null
}

$miAdres = New-Object System.Windows.Forms.ToolStripMenuItem (T 'menu.address')
$miAdres.ToolTipText = (T 'menu.addressTip')
$miAdres.Add_Click({
    $ip = Get-LanIp
    if ($ip) { try { Set-Clipboard -Value "$($ip):$ApiPort" } catch { } }
})
[void]$menu.Items.Add($miAdres)

$miStatus = New-Object System.Windows.Forms.ToolStripMenuItem (T 'menu.statusPage')
$miStatus.Add_Click({
    $ip = Get-LanIp
    if ($ip) { try { Start-Process "http://$($ip):$ApiPort/" } catch { } }
})
[void]$menu.Items.Add($miStatus)

$miStart = New-Object System.Windows.Forms.ToolStripMenuItem (T 'menu.autostart')
$lnkDir  = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$lnkPath = Join-Path $lnkDir 'Claude HUD.lnk'
$miStart.CheckOnClick = $true
$miStart.Checked = (Test-Path $lnkPath)
$miStart.Add_Click({
    try {
        if (Test-Path $lnkPath) { Remove-Item $lnkPath -Force }
        else {
            $ws = New-Object -ComObject WScript.Shell
            $sc = $ws.CreateShortcut($lnkPath)
            $sc.TargetPath = 'wscript.exe'
            $sc.Arguments  = '"' + (Join-Path $Root 'hud.vbs') + '"'
            $sc.WorkingDirectory = $Root
            $sc.Description = (T 'hud.shortcutDesc')
            $sc.Save()
        }
    } catch { }
})
[void]$menu.Items.Add($miStart)

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# Restarting only launches the new HUD after this one has closed (see the
# bottom of the script). Otherwise two run at once and both write to
# hud-config.json and sessions.json.
$miRestart = New-Object System.Windows.Forms.ToolStripMenuItem (T 'menu.restart')
$miRestart.Add_Click({
    $state.restart = $true
    Save-Cfg
    $tray.Visible = $false
    $form.Close()
})
[void]$menu.Items.Add($miRestart)

$miQuit = New-Object System.Windows.Forms.ToolStripMenuItem (T 'menu.quit')
$miQuit.Add_Click({ Save-Cfg; $tray.Visible = $false; $form.Close() })
[void]$menu.Items.Add($miQuit)

# Work out the address when you open the menu, not once at startup: after a
# router restart or a change of network a remembered address is wrong, and it
# is exactly that stale address that leaves you stuck at the display.
$menu.Add_Opening({
    <#
      dashboard.html is a personal page that is not shipped with this project
      (it is in .gitignore: it contains private data). If somebody does not
      have it, no menu entry should point at it. We check when the menu opens
      rather than once, so it appears the moment you do add one.

    #>
    $miDash.Visible = (Test-Path (Join-Path $Root 'dashboard.html'))

    $ip = Get-LanIp
    if ($ip) {
        $miAdres.Text    = (T 'menu.addressWith' @("$($ip):$ApiPort"))
        $miAdres.Enabled = $true
        $miStatus.Enabled = $true
    } else {
        $miAdres.Text    = (T 'menu.addressNone')
        $miAdres.Enabled = $false
        $miStatus.Enabled = $false
    }
})

$form.ContextMenuStrip = $menu
$tray.ContextMenuStrip = $menu
$tray.Add_DoubleClick({ $form.Visible = -not $form.Visible })

# ---- mouse and keys ---------------------------------------------------------
$form.Add_MouseDown({
    param($s, $e)
    if ($e.Button -eq 'Left') {
        $state.dragging = $true
        $state.dragFrom = [System.Windows.Forms.Cursor]::Position
        $state.formFrom = New-Object System.Drawing.Point $form.Left, $form.Top
    }
})
$form.Add_MouseUp({
    param($s, $e)
    if ($e.Button -ne 'Left') { return }
    $moved = $false
    if ($state.dragFrom) {
        $now = [System.Windows.Forms.Cursor]::Position
        $moved = ([Math]::Abs($now.X - $state.dragFrom.X) + [Math]::Abs($now.Y - $state.dragFrom.Y)) -gt 4
    }
    $state.dragging = $false
    if ($moved) { Save-Cfg; return }

    $ctrl = [bool]([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Control)
    foreach ($h in $state.hitboxes) {
        if ($h.Rect.Contains($e.Location)) {
            if ($ctrl) { Show-SessionWindow $h.Sess -Explain } else { Show-SessionWindow $h.Sess }
            break
        }
    }
})
$form.Add_MouseMove({
    param($s, $e)
    if ($state.dragging -and $state.dragFrom) {
        $now = [System.Windows.Forms.Cursor]::Position
        $form.Left = $state.formFrom.X + ($now.X - $state.dragFrom.X)
        $form.Top  = $state.formFrom.Y + ($now.Y - $state.dragFrom.Y)
        return
    }
    $idx = -1; $i = 0
    foreach ($h in $state.hitboxes) {
        if ($h.Rect.Contains($e.Location)) { $idx = $i }
        $i++
    }
    if ($idx -ne $state.hover) {
        $oud = $state.hover
        $state.hover = $idx
        $form.Cursor = if ($idx -ge 0) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default }
        # Only repaint the two rows involved. Invalidating the whole window produced a
        # brief flicker on every mouse move.
        Invalidate-Rijen @($oud, $idx)
    }
})
$form.Add_MouseLeave({
    $oud = $state.hover
    $state.hover = -1
    Invalidate-Rijen @($oud)
})
$form.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq 'Escape') { $form.Visible = $false }
    if ($e.KeyCode -eq 'F5')     { Refresh-Now }
})

# ---- timer ------------------------------------------------------------------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $RefreshMs
$timer.Add_Tick({ Refresh-Now })

$form.Add_Shown({
    # WS_EX_COMPOSITED makes Windows draw the whole window into a buffer; together
    # with DoubleBuffered that is the end of the flicker.
    try {
        $GWL_EXSTYLE      = -20
        $WS_EX_COMPOSITED = 0x02000000
        $ex = [Dash.Win]::GetWindowLong($form.Handle, $GWL_EXSTYLE)
        [void][Dash.Win]::SetWindowLong($form.Handle, $GWL_EXSTYLE, ($ex -bor $WS_EX_COMPOSITED))
    } catch { }
    Refresh-Now
    $timer.Start()
})
$form.Add_FormClosing({ $timer.Stop(); $tray.Visible = $false; Save-Cfg })

Set-Rounded
[void]$form.ShowDialog()
$tray.Dispose()

if ($state.restart) {
    try {
        $vbs = Join-Path $Root 'hud.vbs'
        if (Test-Path $vbs) {
            Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $vbs + '"') -WorkingDirectory $Root
        } else {
            Start-Process -FilePath 'powershell.exe' -WorkingDirectory $Root -WindowStyle Hidden `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                                ('"' + (Join-Path $Root 'hud.ps1') + '"'))
        }
    } catch { }
}
