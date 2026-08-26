# =============================================================================
#  updatelib.ps1 -- which version is this, is there a newer one, and install it
#
#  Dot-source it:  . (Join-Path $PSScriptRoot 'updatelib.ps1')
#
#  Two ways this project ends up on a machine, and they need different handling:
#
#    a git checkout      -- what you get by cloning; updating means git pull, and
#                           it must refuse when there is uncommitted work, because
#                           quietly discarding someone's edits is unforgivable
#    an installed copy   -- what Install.cmd puts in %LOCALAPPDATA%\ClaudeDeck;
#                           no git, so updating means fetching the release zip and
#                           running its installer, which already knows how to keep
#                           your actions.json and re-point the hooks
#
#  So it works out which of the two it is looking at rather than assuming.
# =============================================================================

$DashRepo = 'dimitrihilverda/claude-sessions-monitor'

# ---- which version is this ---------------------------------------------------
<#
  A plain VERSION file rather than a git tag: a zip install has no git, and asking
  the network what you are running would be absurd. The release workflow checks
  that this file and the tag agree, so they cannot drift apart unnoticed.
#>
function Get-DashVersion([string]$Root) {
    $p = Join-Path $Root 'VERSION'
    if (Test-Path $p) {
        try {
            $v = (Get-Content $p -Raw -ErrorAction Stop).Trim()
            if ($v) { return $v }
        } catch { }
    }
    return '0.0.0'
}

function ConvertTo-DashVersion([string]$s) {
    $t = ([string]$s).Trim().TrimStart('v', 'V')
    # Keep only the numeric part: a tag like v1.2.0-beta must still compare.
    if ($t -match '^(\d+(\.\d+){0,3})') { $t = $Matches[1] }
    try { return [version]$t } catch { return [version]'0.0.0' }
}

# ---- is there a newer one ----------------------------------------------------
function Get-DashLatestRelease {
    try {
        # Older PowerShell defaults to a TLS version GitHub no longer accepts.
        try {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch { }

        $url = "https://api.github.com/repos/$DashRepo/releases/latest"
        # GitHub rejects requests without a User-Agent.
        $r = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'claude-sessions-monitor' } `
                 -TimeoutSec 10 -ErrorAction Stop

        $zip = ''
        foreach ($a in @($r.assets)) {
            if ($a.name -eq 'ClaudeDeck.zip') { $zip = [string]$a.browser_download_url; break }
        }
        return [pscustomobject]@{
            Tag     = [string]$r.tag_name
            Version = ConvertTo-DashVersion $r.tag_name
            Page    = [string]$r.html_url
            Zip     = $zip
            Notes   = [string]$r.body
        }
    } catch {
        return $null
    }
}

# ---- which kind of install is this ------------------------------------------
function Get-DashInstallKind([string]$Root) {
    $git = $false
    if (Test-Path (Join-Path $Root '.git')) {
        try { $null = & git --version 2>$null; $git = ($LASTEXITCODE -eq 0) } catch { $git = $false }
    }
    if ($git) { return 'git' }
    return 'copy'
}

# Uncommitted work, in the widest sense: modified, staged or untracked.
function Test-DashGitDirty([string]$Root) {
    try {
        $out = & git -C $Root status --porcelain 2>$null
        return ([string]::Join('', @($out)).Trim().Length -gt 0)
    } catch { return $true }   # cannot tell: assume dirty, never discard silently
}

# ---- do it ------------------------------------------------------------------
<#
  Returns @{ Ok; Message; Restart }.

  Restart says whether the caller should bounce the HUD and the web service: the
  files on disk changed underneath them, and they only read those at startup.
#>
function Invoke-DashUpdate {
    param([Parameter(Mandatory = $true)][string]$Root, $Release)

    $soort = Get-DashInstallKind $Root

    if ($soort -eq 'git') {
        if (Test-DashGitDirty $Root) {
            return @{ Ok = $false; Restart = $false
                      Message = (T 'upd.dirty') }
        }
        try {
            # --ff-only: bring in what is there, but never invent a merge commit
            # in somebody's working copy.
            $out = & git -C $Root pull --ff-only 2>&1
            if ($LASTEXITCODE -ne 0) {
                return @{ Ok = $false; Restart = $false
                          Message = (T 'upd.gitFailed') + "`r`n" + ([string]::Join("`r`n", @($out)) ) }
            }
            return @{ Ok = $true; Restart = $true; Message = (T 'upd.done') }
        } catch {
            return @{ Ok = $false; Restart = $false; Message = (T 'upd.gitFailed') + "`r`n" + $_.Exception.Message }
        }
    }

    # ---- installed copy: fetch the release and let its installer do the work
    if (-not $Release -or -not $Release.Zip) {
        return @{ Ok = $false; Restart = $false; Message = (T 'upd.noAsset') }
    }
    $tmp = Join-Path $env:TEMP ('claudedeck-update-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        $zip = Join-Path $tmp 'ClaudeDeck.zip'
        Invoke-WebRequest -Uri $Release.Zip -OutFile $zip -TimeoutSec 120 `
            -Headers @{ 'User-Agent' = 'claude-sessions-monitor' } -ErrorAction Stop

        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        $inst = Get-ChildItem $tmp -Recurse -Filter 'install.ps1' -File | Select-Object -First 1
        if (-not $inst) { return @{ Ok = $false; Restart = $false; Message = (T 'upd.noInstaller') } }

        <#
          Keep the choices already made on this machine instead of asking again:
          the touchscreen service is present if session-api.ps1 is, and autostart
          is on if the Startup shortcut exists. Getting this wrong would silently
          turn off something the user had enabled.
        #>
        $touch = Test-Path (Join-Path $Root 'session-api.ps1')
        $auto  = Test-Path (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\Claude HUD.lnk')

        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $inst.FullName + '"'),
                  '-Doel', ('"' + $Root + '"'), '-Stil')
        if ($touch) { $args += '-MetTouchscreen' }
        if ($auto)  { $args += '-Autostart' }

        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -ne 0) {
            return @{ Ok = $false; Restart = $false; Message = (T 'upd.installFailed') + " (exit $($p.ExitCode))" }
        }
        # The installer starts the HUD itself, so do not ask for another restart.
        return @{ Ok = $true; Restart = $false; Message = (T 'upd.done') }
    } catch {
        return @{ Ok = $false; Restart = $false; Message = (T 'upd.downloadFailed') + "`r`n" + $_.Exception.Message }
    } finally {
        try { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

$DashFlashPage = 'https://dimitrihilverda.github.io/claude-sessions-monitor/'

<#
  ---- the display's firmware -------------------------------------------------

  Two questions, two sources. What is on the display comes from the web service,
  which learns it from the display itself. What is published comes from the
  flasher's manifest. CI writes the same string into both the firmware and that
  manifest, which is the only reason they can be compared at all.

  Neither call is allowed to matter much: no display and no network are both
  perfectly normal, and the About box has to open regardless.
#>
function Get-DashDisplayInfo([int]$ApiPort = 8787) {
    try {
        return Invoke-RestMethod -Uri "http://127.0.0.1:$ApiPort/display" -TimeoutSec 3 -ErrorAction Stop
    } catch { return $null }
}

function Get-DashPublishedFirmware {
    try {
        try {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch { }
        $m = Invoke-RestMethod -Uri ($DashFlashPage + 'manifest.json') `
                 -Headers @{ 'User-Agent' = 'claude-sessions-monitor' } -TimeoutSec 8 -ErrorAction Stop
        return [string]$m.version
    } catch { return '' }
}

<#
  Hand the COM port back before sending somebody to the flasher.

  The web service holds it to feed the display over USB, and the browser cannot
  take a port that is already open -- the flash would fail with a port error and
  nothing on the page would explain why. Five minutes is enough to pick the port
  and let it write; the bridge takes it back by itself afterwards.
#>
function Open-DashFlasher([int]$ApiPort = 8787) {
    try {
        Invoke-WebRequest -Uri "http://127.0.0.1:$ApiPort/serial/release?sec=300" `
            -TimeoutSec 4 -UseBasicParsing | Out-Null
    } catch { }
    try { Start-Process $DashFlashPage } catch { }
}
