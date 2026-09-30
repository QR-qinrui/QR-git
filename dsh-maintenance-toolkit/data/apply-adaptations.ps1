# =============================================================================
#  apply-adaptations.ps1 - idempotent dsh-web plugin adaptation patches
#  (pure ASCII on purpose: safe under Windows PowerShell 5.1 ANSI parsing
#   even if the UTF-8 BOM is ever stripped by an editor)
#
#  Background: the F12 console accumulated hundreds of errors:
#    1) @linxin666/dsh-pet 0.4.x: with pet config enabled=false the host
#       unregisters every /api/pet/* route, while the browser half keeps
#       polling /api/pet/pets every 2s -> endless 404 spam.
#    2) dsh-whale-widget 0.3.16: creates/resumes AudioContext before any
#       user gesture -> one browser warning per audio fragment; hit-test
#       canvas reads back without willReadFrequently.
#    3) link: plugins (dsh-chat-manager, deepseek-idesign) are installed by
#       pnpm as RELATIVE symlinks. When DSH_HOME is reached through the
#       <user-home>\.dsh junction the relative targets dangle and the
#       loader reports "cannot resolve profile bundle" (plugin shows error).
#       Absolute junctions resolve through both paths.
#
#  Usage: powershell -ExecutionPolicy Bypass -File apply-adaptations.ps1
#  maintain.ps1 -Fix runs this script automatically.
# =============================================================================
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

function Write-Ok   { param([string]$Msg) Write-Host ('  [OK]   ' + $Msg) -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host ('  [WARN] ' + $Msg) -ForegroundColor Yellow }
function Write-Info { param([string]$Msg) Write-Host ('  [..]   ' + $Msg) -ForegroundColor DarkGray }

$script:DataDir = $PSScriptRoot
if ($env:DSH_HOME -and (Test-Path -LiteralPath $env:DSH_HOME)) {
    $script:DshHome = $env:DSH_HOME
} else {
    $script:DshHome = Join-Path $script:DataDir 'dsh-home'
}
$script:ProfileWeb = Join-Path $script:DshHome 'profiles\web'

function Read-TextNoBom {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $len = $bytes.Length
    if ($len -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $clean = New-Object byte[] ($len - 3)
        [Array]::Copy($bytes, 3, $clean, 0, $clean.Length)
        return [System.Text.Encoding]::UTF8.GetString($clean)
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Write-TextNoBom {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# Pair-wise replace: old -> new; if every marker is already present, skip.
function Apply-PatchPairs {
    param([string]$Path, [string[]]$Old, [string[]]$New, [string[]]$Markers)
    if (-not (Test-Path -LiteralPath $Path)) { return 'MISSING' }
    $txt = Read-TextNoBom $Path
    if ($null -eq $txt) { return 'READFAIL' }
    $already = $true
    foreach ($m in $Markers) {
        if ($txt.IndexOf($m) -lt 0) { $already = $false; break }
    }
    if ($already) { return 'ALREADY' }
    for ($i = 0; $i -lt $Old.Count; $i++) {
        $idx = $txt.IndexOf($Old[$i])
        if ($idx -lt 0) { return ('NOMATCH#' + ($i + 1)) }
        $txt = $txt.Substring(0, $idx) + $New[$i] + $txt.Substring($idx + $Old[$i].Length)
    }
    Write-TextNoBom $Path $txt
    return 'PATCHED'
}

Write-Host '================================================' -ForegroundColor DarkCyan
Write-Host '   dsh web plugin adaptation patches (idempotent)'
Write-Host '================================================' -ForegroundColor DarkCyan
Write-Host ''
Write-Info ('profile web: ' + $script:ProfileWeb)

# -----------------------------------------------------------------------------
# Patch 1: JSON-driven artifact adaptations (patch-data.json)
# Covers: @linxin666/dsh-pet (route persistence + summon ball),
# dsh-prompt-enhance (settingsScope removed from top-level inject so the
# web-boot audit no longer races the asynchronously-mounted webUiSettings),
# dsh-ego-browser (idempotent watch/stop answers 200 when no worker exists).
# Patch payloads (incl. non-ASCII locale copy) live in patch-data.json next to
# this script, read explicitly as UTF-8 so Windows PowerShell 5.1 never
# mis-parses non-ASCII bytes.
# -----------------------------------------------------------------------------
function Read-JsonUtf8 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        return ($text | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Apply-JsonTarget {
    param($Target)
    $file = Join-Path $script:ProfileWeb $Target.file
    $oldArr = @($Target.pairs | ForEach-Object { [string]$_.old })
    $newArr = @($Target.pairs | ForEach-Object { [string]$_.new })
    $markers = @($Target.markers | ForEach-Object { [string]$_ })
    return (Apply-PatchPairs $file $oldArr $newArr $markers)
}

$petData = Read-JsonUtf8 (Join-Path $script:DataDir 'patch-data.json')
if ($null -eq $petData -or $null -eq $petData.targets) {
    Write-Warn 'dsh-pet: patch-data.json missing or unreadable; pet adaptations skipped'
} else {
    foreach ($target in $petData.targets) {
        $result = Apply-JsonTarget $target
        switch ($result) {
            'PATCHED' { Write-Ok ('adapt ' + $target.id + ': adaptations written') }
            'ALREADY' { Write-Ok ('adapt ' + $target.id + ': adaptations already present') }
            'MISSING' { Write-Warn ('adapt ' + $target.id + ': not found: ' + $target.file) }
            default   { Write-Warn ('adapt ' + $target.id + ': patch pattern did not match (' + $result + '); upstream structure may have changed - manual adaptation required') }
        }
    }
}

# -----------------------------------------------------------------------------
# Patch 2: dsh-whale-widget - gesture-gated AudioContext + canvas readback hint
# -----------------------------------------------------------------------------
$whaleJs = Join-Path $script:ProfileWeb 'node_modules\dsh-whale-widget\assets\whale-widget.js'
$whaleOld = @(
    "var dshwvAudioCtx = null",
    "    if (dshwvAudioCtx.state === 'suspended') { try { dshwvAudioCtx.resume() } catch (err) {} }",
    "  if (dshwvSoundOff()) return`n  try { dshwvAudio() } catch (err) {}",
    "    if (dshwvSoundOff()) return`n    dshwvAudio()`n    try { document.removeEventListener('pointerdown', dshwvAudioUnlock, true) } catch (err) {}",
    "        var ctx = hitCanvas.getContext('2d')"
)
$whaleNew = @(
    "var dshwvAudioCtx = null`nvar dshwvGestureOk = false",
    "    if (dshwvGestureOk && dshwvAudioCtx.state === 'suspended') { try { dshwvAudioCtx.resume() } catch (err) {} }",
    "  if (dshwvSoundOff()) return`n  if (!dshwvGestureOk) return`n  try { dshwvAudio() } catch (err) {}",
    "    if (dshwvSoundOff()) return`n    dshwvGestureOk = true`n    dshwvAudio()`n    // Re-warm current press/release slots after the first gesture so the first click still plays from the sync path.`n    try { dshwvWarm([typeof pressAudio !== 'undefined' && pressAudio ? pressAudio._url : '', typeof releaseAudio !== 'undefined' && releaseAudio ? releaseAudio._url : '']) } catch (err) {}`n    try { document.removeEventListener('pointerdown', dshwvAudioUnlock, true) } catch (err) {}",
    "        var ctx = hitCanvas.getContext('2d', { willReadFrequently: true })"
)
$whaleResult = Apply-PatchPairs $whaleJs $whaleOld $whaleNew @('var dshwvGestureOk = false')
switch ($whaleResult) {
    'PATCHED' { Write-Ok 'dsh-whale-widget: gesture gate + canvas hint written to assets\whale-widget.js' }
    'ALREADY' { Write-Ok 'dsh-whale-widget: adaptation patches already present' }
    'MISSING' { Write-Warn ('dsh-whale-widget: not found: ' + $whaleJs) }
    default   { Write-Warn ('dsh-whale-widget: patch pattern did not match (' + $whaleResult + '); upstream structure may have changed - manual adaptation required') }
}

# -----------------------------------------------------------------------------
# Patch 3: link: plugins - replace relative symlinks with absolute junctions
# -----------------------------------------------------------------------------
$linkPairs = @(
    @('dsh-chat-manager', (Join-Path $script:DataDir 'dsh-chat-manager\packages\dsh-chat-manager')),
    @('deepseek-idesign', (Join-Path $script:DataDir 'deepseek-idesign'))
)
foreach ($pair in $linkPairs) {
    $link = Join-Path $script:ProfileWeb ('node_modules\' + $pair[0])
    $target = $pair[1]
    $fixed = $false
    if (Test-Path -LiteralPath $link) {
        $item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
        if ($item -and $item.LinkType -eq 'Junction') {
            if ([string]::Equals(($item.Target -join ''), $target, [System.StringComparison]::OrdinalIgnoreCase)) { $fixed = $true }
        }
    }
    if (-not $fixed) {
        # Remove only the link itself. For junctions use the .NET API so the
        # reparse point is deleted without ever recursing into the target.
        if (Test-Path -LiteralPath $link) {
            try {
                [System.IO.Directory]::Delete($link)
            } catch {
                Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
            }
        }
        try {
            New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop | Out-Null
            Write-Ok ('link repair: ' + $pair[0] + ' -> absolute junction')
        } catch {
            Write-Warn ('link repair failed: ' + $pair[0] + ' (' + $_.Exception.Message + ')')
        }
    } else {
        Write-Ok ('link check: ' + $pair[0] + ' already an absolute junction')
    }
}

# -----------------------------------------------------------------------------
# Patch 4: dsh-web-all family engine-floor compat (host-aware, on-demand).
# 上游家族包会把 engines.dsh / peer @deepseek-ai/dsh 声明成较高地板（如 >=0.2.0-rc.1），
# 在比该地板更旧的宿主上插件管理器会把它们标成异常，因此历史上统一压到宿主版本线。
# 现在改为**按需**归一：只有当地板高于当前宿主时才压到宿主版本；宿主已满足则保留真实声明
# （2026-09-30 升级到 0.2.0-rc.2 后，家族真实地板已被满足 → 不再改写，市场门读到真实信号）。
# 宿主版本优先取环境变量 DSH_HOST_VERSION（maintain.ps1 会导出），其次内置运行时 runtime\。
# Metadata-only; idempotent; re-applied after any family reinstall/upgrade.
# -----------------------------------------------------------------------------
function Compare-DshVersion {
    param([string]$A, [string]$B)
    $pa = @($A -split '-', 2); $pb = @($B -split '-', 2)
    $va = @($pa[0] -split '\.'); $vb = @($pb[0] -split '\.')
    for ($i = 0; $i -lt 3; $i++) {
        $x = 0; $y = 0
        if ($i -lt $va.Count) { [void][int]::TryParse($va[$i], [ref]$x) }
        if ($i -lt $vb.Count) { [void][int]::TryParse($vb[$i], [ref]$y) }
        if ($x -ne $y) { if ($x -gt $y) { return 1 } else { return -1 } }
    }
    $ra = ''; $rb = ''
    if ($pa.Count -gt 1) { $ra = $pa[1] }
    if ($pb.Count -gt 1) { $rb = $pb[1] }
    if ($ra -eq $rb) { return 0 }
    if ($ra -eq '') { return 1 }
    if ($rb -eq '') { return -1 }
    if ([string]::Compare($ra, $rb, [System.StringComparison]::OrdinalIgnoreCase) -gt 0) { return 1 }
    return -1
}

$script:HostLine = ''
if ($env:DSH_HOST_VERSION -and $env:DSH_HOST_VERSION.Trim() -ne '') { $script:HostLine = $env:DSH_HOST_VERSION.Trim() }
if (-not $script:HostLine) {
    $rtManifest = Join-Path (Split-Path -Parent $script:DataDir) 'runtime\node_modules\@deepseek-ai\dsh\package.json'
    if (Test-Path -LiteralPath $rtManifest) {
        try { $script:HostLine = [string]((Read-TextNoBom $rtManifest | ConvertFrom-Json).version) } catch { }
    }
}
if (-not $script:HostLine) { $script:HostLine = '0.1.7-rc.2' }
Write-Info ('family engine floor: host line = ' + $script:HostLine)
$familyDir = Join-Path $script:ProfileWeb 'node_modules\@linxin666'
if (Test-Path -LiteralPath $familyDir) {
    $floorPatched = 0
    $floorSkipped = 0
    Get-ChildItem -LiteralPath $familyDir -Directory | ForEach-Object {
        $pj = Join-Path $_.FullName 'package.json'
        if (-not (Test-Path -LiteralPath $pj)) { return }
        $txt = Read-TextNoBom $pj
        if ($null -eq $txt) { return }
        $changed = $false
        # 按需归一：地板 > 宿主才压到宿主版本线；宿主已满足则保留真实声明。
        $floorRx = '("(?:dsh|@deepseek-ai/dsh)"\s*:\s*">=)([0-9][^"]*)(")'
        $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
            param($m)
            $declared = $m.Groups[2].Value
            if ($declared -eq $script:HostLine) { return $m.Value }
            if ((Compare-DshVersion $script:HostLine $declared) -ge 0) { return $m.Value }
            return $m.Groups[1].Value + $script:HostLine + $m.Groups[3].Value
        }
        $replaced = [regex]::Replace($txt, $floorRx, $evaluator)
        if ($replaced -cne $txt) {
            $txt = $replaced
            $changed = $true
        }
        if ($changed) { Write-TextNoBom $pj $txt; $floorPatched++ } else { $floorSkipped++ }
    }
    Write-Ok ("family engine floor: {0} normalized to {1}, {2} already ok" -f $floorPatched, $script:HostLine, $floorSkipped)
} else {
    Write-Warn 'family engine floor: @linxin666 not found; skipped'
}

Write-Host ''
Write-Info 'Patches modify profile node_modules artifacts; re-run this script after reinstalling or upgrading the affected plugins (maintain.ps1 -Fix does it automatically).'
Write-Host ''
