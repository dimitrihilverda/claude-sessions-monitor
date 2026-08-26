# install-hooks.ps1 -- register the beacon hooks in your global Claude Code settings
# Run once. Idempotent: running it again adds nothing twice.
# Backs up an existing settings.json first.
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'platformlib.ps1')

$settingsDir  = Get-DashClaudeDir
$settingsPath = Get-DashSettingsFile
$beacon = Join-Path $PSScriptRoot 'beacon.ps1'
if (-not (Test-Path $beacon)) { throw "beacon.ps1 not found next to this script ($beacon)" }

<#
  Which PowerShell runs the hook. On Windows that is the one already on every
  machine; on macOS it is PowerShell 7 (brew install powershell), which the rest
  of the Mac side needs anyway.

  -ExecutionPolicy is deliberately absent from the Mac command: pwsh on Unix has
  no execution policy, and passing the switch there is an error rather than
  something harmlessly ignored.
#>
if ($DashOnWindows) {
    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$beacon`""
} else {
    $exe = (Get-Process -Id $PID).Path
    if (-not $exe) { $exe = 'pwsh' }
    $cmd = "`"$exe`" -NoProfile -File `"$beacon`""
}
# PostToolUse fires on every tool call and is what takes a session out of the
# "needs you" state once you have approved a permission request. Without it a
# session stays orange until it fully finishes, because Claude Code fires
# nothing at all between Notification and Stop. beacon.ps1 returns immediately
# in most cases, so the cost per tool call is negligible.
$events = 'SessionStart','UserPromptSubmit','PostToolUse','Notification','Stop','SessionEnd'

New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null

$settings = $null
if (Test-Path $settingsPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item $settingsPath "$settingsPath.bak-$stamp"
    Write-Host "Backup written: settings.json.bak-$stamp"
    $raw = Get-Content $settingsPath -Raw
    if ($raw.Trim()) { $settings = $raw | ConvertFrom-Json }
}
if ($null -eq $settings) { $settings = [pscustomobject]@{} }

if (-not ($settings.PSObject.Properties.Name -contains 'hooks')) {
    $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
}

foreach ($ev in $events) {
    $entryJson = '{"hooks":[{"type":"command","command":' + ($cmd | ConvertTo-Json) + '}]}'
    $entry = $entryJson | ConvertFrom-Json
    $prop = $settings.hooks.PSObject.Properties[$ev]
    if ($null -eq $prop) {
        $settings.hooks | Add-Member -NotePropertyName $ev -NotePropertyValue @($entry)
        Write-Host "Added:        $ev"
    } else {
        $already = $false
        foreach ($e in @($prop.Value)) {
            foreach ($h in @($e.hooks)) {
                if ("$($h.command)" -like '*beacon.ps1*') { $already = $true }
            }
        }
        if ($already) {
            Write-Host "Already set:  $ev"
        } else {
            $prop.Value = @($prop.Value) + @($entry)
            Write-Host "Added:        $ev"
        }
    }
}

$settings | ConvertTo-Json -Depth 16 | Set-Content -Path $settingsPath -Encoding UTF8
Write-Host ""
Write-Host "Done. Hooks are in $settingsPath"
Write-Host "Claude Code sessions you start from now on will report in."
