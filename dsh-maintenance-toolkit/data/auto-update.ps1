# =============================================================================
#  auto-update.ps1 - scheduled wrapper around update-plugins.ps1 -AutoApply
#  (pure ASCII for Windows PowerShell 5.1 safety)
#
#  Behaviour:
#    1. runs the full loss-less update workflow in AUTO mode:
#       registry (npm) plugins only - git deps such as dsh-ego-browser are
#       skipped so a live agent-browser session is never restarted unattended
#    2. everything (detection, mirror gate, backups, patches, verification)
#       is logged to 插件自愈中心\logs\auto-update-<timestamp>.log
#    3. a one-line outcome is appended to
#       插件自愈中心\logs\auto-update-history.log  (rolling audit trail)
#
#  Install the schedule (daily 02:30, runs when the user is logged on):
#    schtasks.exe /Create /F /SC DAILY /ST 02:30 ^
#      /TN "DSH-Plugin-Lossless-AutoUpdate" ^
#      /TR "\"powershell.exe\" -NoProfile -ExecutionPolicy Bypass -File \"<this dir>\auto-update.ps1\""
#  Remove: schtasks.exe /Delete /TN "DSH-Plugin-Lossless-AutoUpdate" /F
# =============================================================================
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$script:DataDir = $PSScriptRoot
$logDir = Join-Path $script:DataDir ('插件自愈中心\logs')
$null = New-Item -ItemType Directory -Force -Path $logDir

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $logDir ('auto-update-' + $ts + '.log')
$history = Join-Path $logDir 'auto-update-history.log'

$logLines = New-Object System.Collections.Generic.List[string]
function Write-Log {
    param([string]$Line)
    $stamped = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $Line
    $logLines.Add($stamped)
    Write-Host $stamped
}

Write-Log ('auto-update started; data dir: ' + $script:DataDir)

# make sure pnpm is reachable before spending a detection cycle
$pnpmProbe = & pnpm.cmd --version 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Log ('FATAL: pnpm not found on PATH (' + ($pnpmProbe -join ' ') + '); aborting before detection')
    $logLines | Set-Content -LiteralPath $logFile -Encoding UTF8
    Add-Content -LiteralPath $history -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  FATAL pnpm-missing' -Encoding UTF8
    exit 3
}
Write-Log ('pnpm version: ' + ($pnpmProbe -join '').Trim())

$wf = Join-Path $script:DataDir 'update-plugins.ps1'
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wf -AutoApply 2>&1
$code = $LASTEXITCODE
foreach ($line in $out) { Write-Log ([string]$line) }

$verdict = switch ($code) {
    0 { 'OK' }
    1 { 'ERROR' }
    2 { 'INSTALL-FAILED' }
    3 { 'PNPM-MISSING' }
    default { 'EXIT-' + $code }
}
Write-Log ('auto-update finished; workflow exit code: ' + $code + ' (' + $verdict + ')')

# flush logs
$logLines | Set-Content -LiteralPath $logFile -Encoding UTF8
Add-Content -LiteralPath $history -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $verdict + '  log=' + $logFile) -Encoding UTF8

exit $code
