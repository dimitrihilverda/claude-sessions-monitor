# =============================================================================
#  hud.ps1 -- klein always-on-top venster met je live Claude-sessies
#
#  Starten (zonder consolevenster):  wscript.exe hud.vbs
#  Of om te testen:                  powershell -ExecutionPolicy Bypass -File hud.ps1
#
#  Slepen         : met de linkermuisknop ergens in het venster
#  Klik op een rij: probeert de terminal van die sessie naar voren te halen
#  Rechtermuis    : menu (vastzetten, compact, alleen aandacht, autostart, sluiten)
#  Dubbelklik tray: HUD verbergen of terugtoveren
# =============================================================================
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Root = $PSScriptRoot
. (Join-Path $Root 'sessionlib.ps1')

$StatusDir  = Join-Path $Root 'session-status'
$ConfigPath = Join-Path $Root 'hud-config.json'
$RefreshMs  = 3000

# Ook sessions.json / sessions.js bijwerken, zodat de webpagina en de CYD
# meeliften op de HUD-verversing (en dode sessies daar ook verdwijnen).
$WritePayload = $true

# ---- kleuren (Moving-In) ----------------------------------------------------
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

# ---- instellingen bewaren ---------------------------------------------------
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

# ---- venster naar voren halen ----------------------------------------------
# De vensterzoeker zit in focuslib.ps1, zodat de HUD en de CYD-API dezelfde
# logica gebruiken.
. (Join-Path $Root 'focuslib.ps1')

function Show-SessionWindow($sess, [switch]$Explain) {
    $cwd = [string]$sess.cwd

    # Shift ingedrukt? Dan wil je de map, niet het venster.
    if ([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Shift) {
        try { if ($cwd -and (Test-Path $cwd)) { Start-Process explorer.exe $cwd; return } } catch { }
    }

    # Ctrl+klik: laat zien waarom de HUD dit venster kiest. Handig als hij het
    # verkeerde projectvenster pakt -- dan zie je meteen welke titels er zijn.
    if ($Explain) {
        $cands = @(Get-DashWindowCandidates -Cwd $cwd -OwnerPid ([int]$sess.owner_pid))
        $chain = @()
        if ([int]$sess.owner_pid -gt 0) { $chain = Get-DashProcChain ([int]$sess.owner_pid) }
        $txt = "Sessie: $($sess.name)`nMap: $cwd`nOuderketen (PID's): $($chain -join ', ')`n`nKandidaten:`n"
        foreach ($c in ($cands | Select-Object -First 8)) {
            $txt += "  {0,4}  {1} ({2})  {3}`n" -f $c.Score, $c.Proc, $c.Pid, $c.Title
        }
        if (-not $cands.Count) { $txt += "  (geen enkel venster gaf een treffer)`n" }
        $best = if ($cands.Count -and $cands[0].Score -ge 30) { $cands[0] } else { $null }
        $txt += "`nGekozen: " + $(if ($best) { "$($best.Title)  [score $($best.Score)]" } else { 'niets -- opent de map' })
        [void][System.Windows.Forms.MessageBox]::Show($txt, 'Vensterkeuze', 'OK', 'Information')
        return
    }

    [void](Invoke-DashSessionFocus -Session $sess -FolderFallback)
}

# ---- het venster ------------------------------------------------------------
$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'Claude-sessies'
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

# ---- staat ------------------------------------------------------------------
$state = [ordered]@{
    rows      = @()          # zichtbare sessies
    known     = 0
    hitboxes  = @()          # @{ Rect; Sess }
    hover     = -1
    seen      = @{}          # session_id|updated -> al gemeld
    lastOk    = $null
    dragging  = $false
    dragFrom  = $null
    formFrom  = $null
    fp        = ''
    fpUi      = ''          # hoe het venster er nu uitziet
    lastCount = -1          # aantal rijen bij de vorige tekening
    clock     = '--:--'
}

$HeadH = 30
function Get-RowH { if ($cfg.compact) { return 30 } else { return 46 } }

function Update-Layout {
    $n = [Math]::Max(1, @($state.rows).Count)
    $h = $HeadH + ($n * (Get-RowH)) + 24
    $form.Height = [int][Math]::Min(720, $h)
    Set-Rounded
}

# ---- tekenen ----------------------------------------------------------------
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

    # kop
    $hb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(24, 30, 38))
    $g.FillRectangle($hb, 0, 0, $W, $HeadH); $hb.Dispose()

    $att = @($state.rows | Where-Object { $_.state -eq 'attention' }).Count
    $dotCol = if ($att -gt 0) { $C.Orange } elseif (@($state.rows).Count -gt 0) { $C.Green } else { $C.Muted }
    $db = New-Object System.Drawing.SolidBrush $dotCol
    $g.FillEllipse($db, 12, 12, 8, 8); $db.Dispose()

    $tb = New-Object System.Drawing.SolidBrush $C.Text
    $g.DrawString('CLAUDE-SESSIES', $F.Head, $tb, 26, 7)
    $tb.Dispose()

    $mb = New-Object System.Drawing.SolidBrush $C.Muted
    $meta = "$(@($state.rows).Count) live  ·  $($state.clock)"
    if ($cfg.onlyAttention) { $meta = "filter aan  ·  " + $meta }
    $mw = $g.MeasureString($meta, $F.Small).Width
    $g.DrawString($meta, $F.Small, $mb, ($W - $mw - 12), 9)
    $mb.Dispose()

    $lp = New-Object System.Drawing.Pen $C.Line
    $g.DrawLine($lp, 0, $HeadH, $W, $HeadH); $lp.Dispose()

    # rijen
    $state.hitboxes = @()
    $y  = $HeadH + 6
    $rh = Get-RowH

    if (@($state.rows).Count -eq 0) {
        $eb = New-Object System.Drawing.SolidBrush $C.Muted
        if ($cfg.onlyAttention) {
            # anders lijkt de HUD kapot terwijl er alleen een filter aan staat
            $ob = New-Object System.Drawing.SolidBrush $C.Orange
            $g.DrawString('Geen sessie vraagt aandacht.', $F.Why, $eb, 14, ($y + 6))
            $g.DrawString('Filter "alleen aandacht nodig" staat aan — rechtermuis om hem uit te zetten.',
                          $F.Small, $ob, 14, ($y + 24))
            $ob.Dispose()
        } else {
            $g.DrawString('Geen actieve sessies.', $F.Why, $eb, 14, ($y + 6))
            $g.DrawString("$($state.known) beacons bekend", $F.Small, $eb, 14, ($y + 24))
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
            # regel 1 is de titel van de sessie, regel 2 vertelt waar hij draait
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

# ---- verversen --------------------------------------------------------------
function Refresh-Now {
    try {
        $all = @(Get-DashSessions -Dir $StatusDir)
        $vis = @($all | Where-Object { $_.visible })
        if ($cfg.onlyAttention) { $vis = @($vis | Where-Object { $_.state -eq 'attention' }) }

        $state.rows  = $vis
        $state.known = $all.Count
        $state.lastOk = Get-Date

        # alleen naar schijf schrijven als er echt iets veranderd is
        if ($WritePayload) {
            $fp = (($vis | ForEach-Object { $_.session_id + $_.state + $_.updated }) -join ';')
            if ($fp -ne $state.fp) {
                $state.fp = $fp
                [void](Write-DashPayload -Root $Root -Sessions $all)
            }
        }

        # nieuwe aandachtsvraag -> geluid + tray-ballon
        foreach ($r in @($vis | Where-Object { $_.state -eq 'attention' })) {
            $key = $r.session_id + '|' + $r.updated
            if (-not $state.seen.ContainsKey($key)) {
                $state.seen[$key] = $true
                try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
                try { $tray.ShowBalloonTip(6000, "Claude wacht op je: $($r.name)", [string]$r.why, 'Warning') } catch { }
            }
        }

        $att = @($vis | Where-Object { $_.state -eq 'attention' }).Count
        $tray.Text = if ($att) { "Claude: $att wacht op jou" } else { "Claude: $($vis.Count) actief" }
        Set-TrayIcon $att $vis.Count
    } catch {
        $state.lastOk = $null
    }
    # Hertekenen is wat je als geknipper zag: doe het alleen als er echt iets
    # verandert. Wisselt alleen de klok, dan is de kopregel genoeg.
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

$miTop = Add-Check 'Altijd bovenop' $cfg.topmost {
    $cfg.topmost = -not $cfg.topmost
    $form.TopMost = [bool]$cfg.topmost
    Save-Cfg
}
$miCompact = Add-Check 'Compacte rijen' $cfg.compact {
    $cfg.compact = -not $cfg.compact
    $state.lastCount = -1
    Save-Cfg; Refresh-Now
}
$miOnly = Add-Check 'Alleen aandacht nodig (verbergt de rest)' $cfg.onlyAttention {
    $cfg.onlyAttention = -not $cfg.onlyAttention
    $state.lastCount = -1
    Save-Cfg; Refresh-Now
}
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miDash = New-Object System.Windows.Forms.ToolStripMenuItem 'Dashboard openen'
$miDash.Add_Click({ try { Start-Process (Join-Path $Root 'dashboard.html') } catch { } })
[void]$menu.Items.Add($miDash)

$miStart = New-Object System.Windows.Forms.ToolStripMenuItem 'Starten bij inloggen'
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
            $sc.Description = 'Claude-sessies HUD'
            $sc.Save()
        }
    } catch { }
})
[void]$menu.Items.Add($miStart)

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miQuit = New-Object System.Windows.Forms.ToolStripMenuItem 'HUD afsluiten'
$miQuit.Add_Click({ Save-Cfg; $tray.Visible = $false; $form.Close() })
[void]$menu.Items.Add($miQuit)

$form.ContextMenuStrip = $menu
$tray.ContextMenuStrip = $menu
$tray.Add_DoubleClick({ $form.Visible = -not $form.Visible })

# ---- muis en toetsen --------------------------------------------------------
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
        $state.hover = $idx
        $form.Cursor = if ($idx -ge 0) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default }
        $form.Invalidate()
    }
})
$form.Add_MouseLeave({ $state.hover = -1; $form.Invalidate() })
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
    # WS_EX_COMPOSITED laat Windows het hele venster in een buffer tekenen;
    # samen met DoubleBuffered is dat het einde van het geflikker.
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
