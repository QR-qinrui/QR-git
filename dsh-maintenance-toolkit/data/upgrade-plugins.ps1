# =============================================================================
#  upgrade-plugins.ps1 - automated plugin upgrade + patch + restart + verify
#  (pure ASCII on purpose: safe under Windows PowerShell 5.1 ANSI parsing)
#
#  Upgrades the patched/compat-critical plugin set, re-applies the idempotent
#  adaptation patches, restarts the web service and runs the F12 audit as the
#  acceptance gate. This encodes the manual upgrade cycle that used to be:
#    upgrade -> apply-adaptations.ps1 -> restart -> f12-audit-repair.ps1
#
#  Usage:
#    powershell -ExecutionPolicy Bypass -File upgrade-plugins.ps1             check + verify (safe, no changes)
#    powershell -ExecutionPolicy Bypass -File upgrade-plugins.ps1 -Apply      check + upgrade + patch + restart + verify
#    powershell -ExecutionPolicy Bypass -File upgrade-plugins.ps1 -Apply -SkipRestart -SkipVerify
#
#  Exit code: 0 = ok (current or upgraded+verified), 1 = review needed.
# =============================================================================
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$SkipRestart,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Continue'

function Write-Ok   { param([string]$Msg) Write-Host ('  [OK]    ' + $Msg) -ForegroundColor Green }
function Write-Fail { param([string]$Msg) Write-Host ('  [FAIL]  ' + $Msg) -ForegroundColor Red }
function Write-Warn { param([string]$Msg) Write-Host ('  [WARN]  ' + $Msg) -ForegroundColor Yellow }
function Write-Info { param([string]$Msg) Write-Host ('  [..]    ' + $Msg) -ForegroundColor DarkGray }

# -----------------------------------------------------------------------------
# environment
# -----------------------------------------------------------------------------
$script:DataDir     = $PSScriptRoot
$script:LauncherDir = Split-Path -Parent $script:DataDir
$script:DshHome     = Join-Path $script:DataDir 'dsh-home'
$script:ProfileWeb  = Join-Path $script:DshHome 'profiles\web'
$script:ArchiveRoot = Join-Path $script:DataDir '_归档\backup'
$script:Port        = 3080
$script:Report      = New-Object System.Collections.Generic.List[string]

function Add-ReportLine { param([string]$Line) $script:Report.Add($Line) }

# Plugins whose upgrade must be followed by the adaptation patches + F12 audit.
$script:Watched = @(
    '@linxin666/dsh-web-all',
    'dsh-whale-widget',
    'dsh-prompt-enhance',
    'dsh-context',
    'dshmarket'
)

function Find-NodeExe {
    $bundled = Join-Path $script:LauncherDir 'runtime\node.exe'
    if (Test-Path -LiteralPath $bundled) { return $bundled }
    $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Find-Pnpm {
    $cmd = Get-Command pnpm.cmd -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command pnpm -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        (Join-Path $env:APPDATA 'npm\pnpm.cmd'),
        (Join-Path $env:LOCALAPPDATA 'pnpm\pnpm.cmd'),
        (Join-Path $env:ProgramFiles 'nodejs\pnpm.cmd')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

# -----------------------------------------------------------------------------
# version helpers
# -----------------------------------------------------------------------------
function Get-NpmLatest {
    param([string]$Package)
    try {
        $esc = $Package -replace '/', '%2F'
        $meta = (Invoke-WebRequest -Uri ('https://registry.npmjs.org/' + $esc) -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop).Content | ConvertFrom-Json
        return [string]$meta.'dist-tags'.latest
    } catch {
        return $null
    }
}

function Get-InstalledVersion {
    param([string]$Package)
    $pj = Join-Path $script:ProfileWeb 'package.json'
    if (Test-Path -LiteralPath $pj) {
        try {
            $json = Get-Content -LiteralPath $pj -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json.dependencies.$Package) { return [string]$json.dependencies.$Package }
        } catch {}
    }
    $nm = Join-Path $script:ProfileWeb ('node_modules\' + ($Package -replace '/', '\'))
    $npj = Join-Path $nm 'package.json'
    if (Test-Path -LiteralPath $npj) {
        try {
            $json = Get-Content -LiteralPath $npj -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json.version) { return [string]$json.version }
        } catch {}
    }
    return 'unknown'
}

function Normalize-Version {
    param([string]$V)
    if ($V -match '(\d+\.\d+\.\d+(?:-[A-Za-z0-9.\-]+)?)') { return $Matches[1] }
    return $V
}

function Compare-Version {
    param([string]$A, [string]$B)
    if ([string]::IsNullOrEmpty($A) -and [string]::IsNullOrEmpty($B)) { return 0 }
    if ([string]::IsNullOrEmpty($A)) { return -1 }
    if ([string]::IsNullOrEmpty($B)) { return 1 }
    $pa = $A -split '[.+-]'
    $pb = $B -split '[.+-]'
    $n = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $va = 0; if ($i -lt $pa.Count -and $pa[$i] -match '^\d+$') { $va = [int]$pa[$i] }
        $vb = 0; if ($i -lt $pb.Count -and $pb[$i] -match '^\d+$') { $vb = [int]$pb[$i] }
        $sa = if ($i -lt $pa.Count) { $pa[$i] } else { '' }
        $sb = if ($i -lt $pb.Count) { $pb[$i] } else { '' }
        if ($sa -match '^\d+$' -and $sb -match '^\d+$') {
            if ($va -gt $vb) { return 1 }
            if ($va -lt $vb) { return -1 }
        } else {
            if ($sa -eq '' -and $sb -ne '') { return 1 }
            if ($sb -eq '' -and $sa -ne '') { return -1 }
            $cmp = [string]::Compare($sa, $sb, $true)
            if ($cmp -gt 0) { return 1 }
            if ($cmp -lt 0) { return -1 }
        }
    }
    return 0
}

# -----------------------------------------------------------------------------
# backup current state (package.json / lock / workspace / cordis / patch-data)
# -----------------------------------------------------------------------------
function Backup-State {
    param([string]$Stamp)
    $dest = Join-Path $script:ArchiveRoot ('upgrade-auto-' + $Stamp)
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    foreach ($name in @('package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml', 'cordis.patch.yml')) {
        $src = Join-Path $script:ProfileWeb $name
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $dest $name) -Force }
    }
    $pd = Join-Path $script:DataDir 'patch-data.json'
    if (Test-Path -LiteralPath $pd) { Copy-Item -LiteralPath $pd -Destination (Join-Path $dest 'patch-data.json') -Force }
    $versions = @()
    foreach ($p in $script:Watched) { $versions += ($p + '|' + (Get-InstalledVersion $p)) }
    [System.IO.File]::WriteAllLines((Join-Path $dest 'installed-versions-before.txt'), $versions, (New-Object System.Text.UTF8Encoding($false)))
    return $dest
}

# -----------------------------------------------------------------------------
# service restart (stop listener + launch via launcher bat, wait for 401)
# -----------------------------------------------------------------------------
function Stop-DshListener {
    param([int]$PortNum)
    $line = $null
    try {
        $line = netstat -ano | Select-String (':' + $PortNum + '\s+.*LISTENING') | Select-Object -First 1
    } catch {}
    if (-not $line) { return $true }
    $m = [regex]::Match([string]$line, 'LISTENING\s+(\d+)')
    if (-not $m.Success) { return $false }
    $procId = [int]$m.Groups[1].Value
    Write-Info ('stopping dsh listener PID ' + $procId + ' ...')
    try {
        taskkill /PID $procId /F 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Start-DshWeb {
    $bat = Get-ChildItem -LiteralPath $script:LauncherDir -Filter '*DeepSeek-Harness.bat' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $bat) { return $false }
    Write-Info 'launching dsh web via launcher (new window keeps it alive) ...'
    Start-Process -FilePath $bat.FullName -WorkingDirectory $script:LauncherDir | Out-Null
    $deadline = (Get-Date).AddSeconds(90)
    do {
        Start-Sleep -Seconds 2
        $s = 0
        try {
            Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
            $c = New-Object System.Net.Http.HttpClient
            $c.Timeout = [TimeSpan]::FromSeconds(4)
            $r = $c.GetAsync(('http://127.0.0.1:' + $script:Port + '/')).Result
            $s = [int]$r.StatusCode
            $r.Dispose(); $c.Dispose()
        } catch { $s = 0 }
        if ($s -ne 0) { Write-Ok ('service ready (HTTP ' + $s + ')'); return $true }
    } until ((Get-Date) -gt $deadline)
    Write-Fail 'service did not become ready in time.'
    return $false
}

function Restart-DshWeb {
    if ($SkipRestart) { Write-Info 'restart skipped (-SkipRestart)'; return $true }
    Write-Host ''
    Write-Info 'restarting dsh web service ...'
    if (-not (Stop-DshListener $script:Port)) {
        Write-Warn 'could not stop the current listener; trying to continue anyway.'
    }
    Start-Sleep -Seconds 2
    return Start-DshWeb
}

# -----------------------------------------------------------------------------
# patch + verify acceptance gate
# -----------------------------------------------------------------------------
function Invoke-PatchAndVerify {
    Write-Host ''
    Write-Info 're-applying adaptation patches ...'
    $adapt = Join-Path $script:DataDir 'apply-adaptations.ps1'
    if (Test-Path -LiteralPath $adapt) {
        & $adapt | Out-Host
    } else {
        Write-Fail 'apply-adaptations.ps1 not found.'
        return $false
    }

    if ($SkipVerify) {
        Write-Info 'verification skipped (-SkipVerify)'
        return $true
    }
    Write-Host ''
    Write-Info 'running F12 audit acceptance gate ...'
    $audit = Join-Path $script:DataDir 'f12-audit-repair.ps1'
    if (-not (Test-Path -LiteralPath $audit)) {
        Write-Fail 'f12-audit-repair.ps1 not found.'
        return $false
    }
    & $audit | Out-Host
    return ($LASTEXITCODE -eq 0)
}

# =============================================================================
# main
# =============================================================================
Write-Host '================================================' -ForegroundColor DarkCyan
Write-Host '   automated plugin upgrade + patch + verify'
Write-Host '================================================' -ForegroundColor DarkCyan
Write-Host ''

Add-ReportLine '# Automated plugin upgrade report'
Add-ReportLine ''
Add-ReportLine ('- time: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Add-ReportLine ('- mode: ' + $(if ($Apply) { 'Apply' } else { 'Check+Verify' }))
Add-ReportLine ('- profile web: ' + $script:ProfileWeb)
Add-ReportLine ''

$script:NodeExe = Find-NodeExe
if (-not $script:NodeExe) {
    Write-Fail 'node.exe not found.'
    Add-ReportLine '- node.exe: NOT FOUND'
    exit 1
}
Write-Ok ('node.exe: ' + $script:NodeExe)
Add-ReportLine ('- node.exe: ' + $script:NodeExe)

# ---- 1. version check -------------------------------------------------------
Write-Host ''
Write-Info '1/4 version check (npm registry vs installed)'
Add-ReportLine ''
Add-ReportLine '## 1. Version check'
Add-ReportLine ''

$outdated = @()
foreach ($p in $script:Watched) {
    $latest = Get-NpmLatest $p
    $installed = Get-InstalledVersion $p
    $line = ('- {0}: installed {1}, latest {2}' -f $p, $installed, $latest)
    if ($null -eq $latest) {
        Write-Warn ($p + ': installed ' + $installed + ', latest UNKNOWN (registry unreachable)')
        Add-ReportLine ($line + ' [registry unreachable]')
    } elseif ((Compare-Version (Normalize-Version $installed) (Normalize-Version $latest)) -lt 0) {
        Write-Warn ($p + ': installed ' + $installed + ' -> latest ' + $latest)
        Add-ReportLine ($line + ' [UPDATE AVAILABLE]')
        $outdated += $p
    } else {
        Write-Ok ($p + ': ' + $installed + ' (latest)')
        Add-ReportLine ($line + ' [current]')
    }
}

if ($outdated.Count -eq 0) {
    Write-Ok 'all watched plugins are current.'
    Add-ReportLine ''
    Add-ReportLine '- all watched plugins: current'
} elseif (-not $Apply) {
    Write-Warn ('updates available: ' + ($outdated -join ', ') + ' - re-run with -Apply to upgrade.')
    Add-ReportLine ('- updates available: ' + ($outdated -join ', '))
}

# ---- 2. apply upgrades ------------------------------------------------------
$upgraded = @()
if ($Apply -and $outdated.Count -gt 0) {
    Write-Host ''
    Write-Info '2/4 applying upgrades'
    Add-ReportLine ''
    Add-ReportLine '## 2. Upgrade'
    Add-ReportLine ''

    $pnpm = Find-Pnpm
    if (-not $pnpm) {
        Write-Fail 'pnpm not found; cannot upgrade. Install pnpm or run manually.'
        Add-ReportLine '- pnpm: NOT FOUND'
    } else {
        Write-Ok ('pnpm: ' + $pnpm)
        Add-ReportLine ('- pnpm: ' + $pnpm)
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = Backup-State $stamp
        Write-Ok ('backup: ' + $backup)
        Add-ReportLine ('- backup: ' + $backup)

        foreach ($p in $outdated) {
            Write-Info ('upgrading ' + $p + ' to latest ...')
            try {
                Push-Location $script:ProfileWeb
                & $pnpm add ($p + '@latest') --save-exact --no-audit --no-fund 2>&1 | ForEach-Object { Write-Info $_ }
                $rc = $LASTEXITCODE
                Pop-Location
                if ($rc -eq 0) {
                    Write-Ok ($p + ' upgraded')
                    Add-ReportLine ('- ' + $p + ': upgraded')
                    $upgraded += $p
                } else {
                    Write-Fail ($p + ' upgrade failed (pnpm exit ' + $rc + ')')
                    Add-ReportLine ('- ' + $p + ': FAILED (pnpm exit ' + $rc + ')')
                }
            } catch {
                Pop-Location -ErrorAction SilentlyContinue
                Write-Fail ($p + ' upgrade exception: ' + $_.Exception.Message)
                Add-ReportLine ('- ' + $p + ': exception')
            }
        }
    }
} else {
    Write-Info '2/4 no upgrades to apply'
    Add-ReportLine ''
    Add-ReportLine '## 2. Upgrade'
    Add-ReportLine '- no upgrades to apply'
}

# ---- 3. restart -------------------------------------------------------------
Write-Host ''
Write-Info '3/4 restart service'
Add-ReportLine ''
Add-ReportLine '## 3. Restart'
$restartOk = $true
if ($upgraded.Count -gt 0) {
    $restartOk = Restart-DshWeb
    Add-ReportLine ('- restart: ' + $(if ($restartOk) { 'OK' } else { 'FAILED' }))
} else {
    Write-Info 'nothing upgraded; restart not required'
    Add-ReportLine '- restart: not required (nothing upgraded)'
}

# ---- 4. verify --------------------------------------------------------------
Write-Host ''
Write-Info '4/4 verification'
$verifyOk = Invoke-PatchAndVerify
Add-ReportLine ''
Add-ReportLine ('- patch+verify: ' + $(if ($verifyOk) { 'PASS' } else { 'REVIEW' }))

$reportPath = Join-Path $script:DataDir ('upgrade-report-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.md')
[System.IO.File]::WriteAllLines($reportPath, $script:Report, (New-Object System.Text.UTF8Encoding($true)))

$finalOk = ($outdated.Count -eq 0 -or ($Apply -and $upgraded.Count -eq $outdated.Count)) -and $restartOk -and $verifyOk
Write-Host ''
if ($finalOk) {
    Write-Ok 'upgrade pipeline finished clean.'
} else {
    Write-Warn 'upgrade pipeline finished with items to review. See report.'
}
Write-Ok ('report: ' + $reportPath)
exit $(if ($finalOk) { 0 } else { 1 })
