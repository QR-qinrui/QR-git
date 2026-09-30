# =============================================================================
#  update-plugins.ps1 - reproducible LOSS-LESS plugin update workflow for DSH
#  (pure ASCII on purpose: safe under Windows PowerShell 5.1 ANSI parsing)
#
#  This script codifies the battle-tested workflow used to upgrade
#  @linxin666/dsh-web-all 0.4.3 -> 0.4.4 and the other 8 profile plugins on
#  2026-09-30 without losing any local adaptation patch:
#
#    Phase 1  Detect   : npm registry latest vs installed (npmjs ground truth)
#    Phase 2  Mirror   : confirm npmmirror has synced the target versions
#    Phase 3  Compat   : peer/engine-floor preflight against the local host
#                        version; a hard-incompatible release falls back to
#                        the newest host-compatible release (better-sidebar
#                        0.24.1 -> 0.22.1), a soft floor is noted and later
#                        normalized by apply-adaptations.ps1 Patch 4.
#    Phase 4  Backup   : profile manifests + patch data -> 插件自愈中心\备份
#    Phase 5  Install  : rewrite package.json specs, then
#                        pnpm install --ignore-scripts (family plugins are
#                        pure JS; native binaries are handled separately)
#    Phase 6  Adapt    : re-run apply-adaptations.ps1 (idempotent local
#                        patches incl. engine-floor normalization)
#    Phase 7  Verify   : installed versions, loopback API probes, degraded
#                        ledger, cloudflared binary restore
#    Phase 8  Report   : human-readable markdown report next to the backup
#
#  Usage:
#    powershell -ExecutionPolicy Bypass -File update-plugins.ps1            # check only
#    powershell -ExecutionPolicy Bypass -File update-plugins.ps1 -Apply     # check + upgrade
#    powershell -ExecutionPolicy Bypass -File update-plugins.ps1 -Deep      # also pre-flight local patch anchors (downloads tarballs)
#    powershell -ExecutionPolicy Bypass -File update-plugins.ps1 -HostVersion 0.2.0-rc.1
#
#  Rollback for any run: restore package.json / pnpm-lock.yaml /
#  pnpm-workspace.yaml from the backup dir, then
#    pnpm install --config.minimumReleaseAge=0 --ignore-scripts
#  in dsh-home\profiles\web and re-run apply-adaptations.ps1.
# =============================================================================
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$AutoApply,
    [switch]$Deep,
    [switch]$SelfTest,
    [string]$HostVersion = '',
    [string[]]$Filter = @()
)

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
$script:ProfileManifest = Join-Path $script:ProfileWeb 'package.json'
$script:BackupRoot = Join-Path $script:DataDir ('插件自愈中心\备份')
$script:NpmBase = 'https://registry.npmjs.org'
$script:MirrorBase = 'https://registry.npmmirror.com'

if (-not (Test-Path -LiteralPath $script:ProfileManifest)) {
    Write-Error "profile manifest not found: $script:ProfileManifest"
    exit 1
}

# ---------------------------------------------------------------------------
# text / json helpers (UTF-8 without BOM, PS 5.1 safe)
# ---------------------------------------------------------------------------
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

function Read-JsonUtf8 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $text = Read-TextNoBom $Path
        if ($null -eq $text) { return $null }
        return ($text | ConvertFrom-Json)
    } catch { return $null }
}

# ---------------------------------------------------------------------------
# network helper with three fallbacks: Invoke-RestMethod -> curl.exe -> node.
# CRITICAL PS 5.1 RULE: this function returns a STRING (JSON text) only. An
# object returned by a function that is called from inside ANOTHER function
# gets stringified by PowerShell 5.1; callers must ConvertFrom-Json at their
# own (top-level) call site.
# ---------------------------------------------------------------------------
function Get-UrlText {
    param([string]$Url, [int]$TimeoutSec = 30)
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $r = Invoke-RestMethod -Uri $Url -TimeoutSec $TimeoutSec -UseBasicParsing
        if ($null -ne $r) {
            return (ConvertTo-Json $r -Depth 10 -Compress)
        }
    } catch { }

    $tmp = Join-Path $env:TEMP ('dshup-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $code = & curl.exe -sL --connect-timeout 15 --max-time ($TimeoutSec * 2) -o $tmp -w '%{http_code}' $Url 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $tmp) -and $code -match '^2') {
            $raw = Read-TextNoBom $tmp
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            if ($raw) { return $raw }
        }
    } catch { } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }

    try {
        $js = "fetch(process.argv[1]).then(function(r){return r.text()}).then(function(j){console.log(j)}).catch(function(){process.exit(1)})"
        $raw = & node -e $js $Url 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) {
            return ($raw -join "`n")
        }
    } catch { }
    return $null
}

function ConvertFrom-JsonText {
    param([string]$Text)
    if ($null -eq $Text -or $Text -eq '') { return $null }
    try { return ($Text | ConvertFrom-Json) } catch { return $null }
}

# ---------------------------------------------------------------------------
# GitHub API with on-disk cache: unauthenticated api.github.com is rate
# limited (60/h per IP) and repeated runs burn it fast. 30-minute TTL, and a
# rate-limited probe falls back to the stale cache instead of failing.
# ---------------------------------------------------------------------------
$script:GitCacheFile = Join-Path $script:DataDir ('插件自愈中心\cache\git-api-cache.json')

function Get-GitJson {
    param([string]$Url, [int]$TtlMinutes = 30)
    # cache format: FLAT JSON array of {key, at, branch, sha} - no nested
    # objects (PS 5.1 mangles object round-trips across function calls), URL
    # never used as an object key. File is read and parsed INLINE here.
    $cache = @()
    if (Test-Path -LiteralPath $script:GitCacheFile) {
        $rawBytes = [System.IO.File]::ReadAllBytes($script:GitCacheFile)
        $rawLen = $rawBytes.Length
        $rawStart = 0
        if ($rawLen -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF) { $rawStart = 3 }
        $rawText = [System.Text.Encoding]::UTF8.GetString($rawBytes, $rawStart, $rawLen - $rawStart)
        $loaded = ($rawText | ConvertFrom-Json)
        if ($null -ne $loaded) { $cache = @($loaded) }
    }
    $entry = $null
    foreach ($e in $cache) {
        if ([string]$e.key -eq $Url) { $entry = $e; break }
    }
    if ($null -ne $entry) {
        $at = ([string]$entry.at) -as [datetime]
        if ($at -and (Get-Date) -lt $at.AddMinutes($TtlMinutes)) {
            $out = @{}
            if ($entry.PSObject.Properties['branch']) { $out.default_branch = [string]$entry.branch }
            if ($entry.PSObject.Properties['sha']) { $out.sha = [string]$entry.sha }
            return $out
        }
    }
    $text = Get-UrlText $Url 20
    if ($null -eq $text) {
        if ($null -ne $entry) {
            $out = @{}
            if ($entry.PSObject.Properties['branch']) { $out.default_branch = [string]$entry.branch }
            if ($entry.PSObject.Properties['sha']) { $out.sha = [string]$entry.sha }
            return $out
        }
        return $null
    }
    $val = ($text | ConvertFrom-Json)
    $branch = ''
    $sha = ''
    if ($null -ne $val) {
        if ($val.PSObject.Properties['default_branch']) { $branch = [string]$val.default_branch }
        if ($val.PSObject.Properties['sha']) { $sha = [string]$val.sha }
    }
    $fresh = @()
    foreach ($e in $cache) { if ([string]$e.key -ne $Url) { $fresh += $e } }
    $fresh += [pscustomobject]@{
        key = $Url
        at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        branch = $branch
        sha = $sha
    }
    try {
        $cacheDir = Split-Path -Parent $script:GitCacheFile
        $null = New-Item -ItemType Directory -Force -Path $cacheDir
        Write-TextNoBom $script:GitCacheFile ($fresh | ConvertTo-Json -Depth 5)
    } catch { }
    $out = @{}
    if ($branch -ne '') { $out.default_branch = $branch }
    if ($sha -ne '') { $out.sha = $sha }
    return $out
}

# ---------------------------------------------------------------------------
# small semver toolkit (x.y.z[-pre]) for the compat preflight.
# PS 5.1 pitfall: a PSCustomObject returned by a function is stringified when
# the function is called from inside another function, so every helper here
# passes ONLY scalars (ints / strings) across function boundaries.
# ---------------------------------------------------------------------------
function Convert-Semver {
    # zero-padded sortable key "0000.0005.0001!pre" (release = !zzzz) or $null
    param([string]$V)
    $v = $V.Trim().TrimStart('v').TrimStart('=')
    if ($v -match '^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$') {
        $pre = [string]$Matches[4]
        if ($pre -eq '') { $pre = 'zzzz' }
        return ('{0:d4}.{1:d4}.{2:d4}!{3}' -f [int]$Matches[1], [int]$Matches[2], [int]$Matches[3], $pre)
    }
    return $null
}

function Compare-Semver {
    param([string]$A, [string]$B)
    $aM = 0; $aN = 0; $aP = 0; $aPre = ''; $aOk = $false
    $bM = 0; $bN = 0; $bP = 0; $bPre = ''; $bOk = $false
    if ($A -match '^v?(\d+)\.(\d+)\.(\d+)(?:-(.+))?$') {
        $aM = [int]$Matches[1]; $aN = [int]$Matches[2]; $aP = [int]$Matches[3]
        $aPre = [string]$Matches[4]; $aOk = $true
    }
    if ($B -match '^v?(\d+)\.(\d+)\.(\d+)(?:-(.+))?$') {
        $bM = [int]$Matches[1]; $bN = [int]$Matches[2]; $bP = [int]$Matches[3]
        $bPre = [string]$Matches[4]; $bOk = $true
    }
    if (-not $aOk -or -not $bOk) { return 0 }
    if ($aM -ne $bM) { if ($aM -lt $bM) { return -1 } else { return 1 } }
    if ($aN -ne $bN) { if ($aN -lt $bN) { return -1 } else { return 1 } }
    if ($aP -ne $bP) { if ($aP -lt $bP) { return -1 } else { return 1 } }
    # release beats prerelease of the same numbers
    if ($aPre -eq '' -and $bPre -ne '') { return 1 }
    if ($aPre -ne '' -and $bPre -eq '') { return -1 }
    if ($aPre -ne '' -and $bPre -ne '') {
        return [string]::Compare($aPre, $bPre, $true)
    }
    return 0
}

# one comparator token like ^1.2.3, ~1.2.3, >=1.2.3, <2.0.0, exact
function Test-OneComparator {
    param([string]$Op, [string]$Bound, [string]$HostVer)
    $c = Compare-Semver $HostVer $Bound
    switch ($Op) {
        '^' {
            $max = ''
            if ($Bound -match '^v?(\d+)\.(\d+)\.(\d+)') {
                $bm = [int]$Matches[1]; $bn = [int]$Matches[2]; $bp = [int]$Matches[3]
                if ($bm -gt 0) { $max = ($bm + 1).ToString() + '.0.0' }
                elseif ($bn -gt 0) { $max = '0.' + ($bn + 1).ToString() + '.0' }
                else { $max = '0.0.' + ($bp + 1).ToString() }
            }
            return ($max -ne '') -and ($c -ge 0) -and ((Compare-Semver $HostVer $max) -lt 0)
        }
        '~' {
            $max = ''
            if ($Bound -match '^v?(\d+)\.(\d+)\.(\d+)') {
                $max = $Matches[1] + '.' + ([int]$Matches[2] + 1).ToString() + '.0'
            }
            return ($max -ne '') -and ($c -ge 0) -and ((Compare-Semver $HostVer $max) -lt 0)
        }
        '>=' { return $c -ge 0 }
        '>'  { return $c -gt 0 }
        '<=' { return $c -le 0 }
        '<'  { return $c -lt 0 }
        '='  { return $c -eq 0 }
        default { return $c -eq 0 }
    }
}

# one alternative: tokens separated by whitespace are AND-ed
function Test-OneAlternative {
    param([string]$Alt, [string]$HostVer)
    $alt = $Alt.Trim()
    if ($alt -eq '' -or $alt -eq '*' -or $alt -eq 'x' -or $alt -eq 'latest') { return $true }
    if ($alt -match '^(\d+)\.(\d+)\.x$') {
        $lo = $Matches[1] + '.' + $Matches[2] + '.0'
        $hi = $Matches[1] + '.' + ([int]$Matches[2] + 1).ToString() + '.0'
        return ((Compare-Semver $HostVer $lo) -ge 0) -and ((Compare-Semver $HostVer $hi) -lt 0)
    }
    $tokens = @($alt -split '\s+' | Where-Object { $_ -ne '' })
    foreach ($tok in $tokens) {
        $ok = $false
        $ops = @(
            @{ Rx = '^\^(\S+)$'; Op = '^' },
            @{ Rx = '^~(\S+)$'; Op = '~' },
            @{ Rx = '^>=(\S+)$'; Op = '>=' },
            @{ Rx = '^<=(\S+)$'; Op = '<=' },
            @{ Rx = '^>(\S+)$'; Op = '>' },
            @{ Rx = '^<(\S+)$'; Op = '<' },
            @{ Rx = '^=(\S+)$'; Op = '=' }
        )
        foreach ($op in $ops) {
            if ($tok -match $op.Rx) {
                if (Test-OneComparator $op.Op $Matches[1] $HostVer) { $ok = $true }
                break
            }
        }
        if (-not $ok -and $tok -match '^v?(\d+\.\d+\.\d+(?:-[^ ]+)?)$') {
            if (Test-OneComparator '=' $Matches[1] $HostVer) { $ok = $true }
        }
        if (-not $ok) { return $false }
    }
    return $true
}

# full range: alternatives separated by ||
function Test-PeerRange {
    param([string]$Range, [string]$HostVer)
    if ($null -eq $Range -or $Range -eq '') { return $true }
    foreach ($alt in @($Range -split '\|\|')) {
        if (Test-OneAlternative $alt $HostVer) { return $true }
    }
    return $false
}

# a package's @deepseek-ai/* peer set is hard-compatible when every peer range
# that speaks the HOST COHORT line (bounds major 0/1, e.g. ^0.1.7-rc.1 or
# ^0.2.0-rc.1) intersects the host version. Peers on their own line
# (@deepseek-ai/cordis ^4.0.4, schemastery ^3.x) are treated as satisfied.
function Test-HardCompatible {
    param($Manifest, [string]$HostVer)
    $peers = $Manifest.peerDependencies
    if ($null -eq $peers) { return $true }
    foreach ($p in $peers.PSObject.Properties) {
        if ($p.Name.StartsWith('@deepseek-ai/')) {
            $range = [string]$p.Value
            if ($range -match '(\d+)\.\d+\.\d+') {
                $boundMajor = [int]$Matches[1]
                if ($boundMajor -le 1) {
                    if (-not (Test-PeerRange $range $HostVer)) { return $false }
                }
            }
        }
    }
    return $true
}

# ---------------------------------------------------------------------------
# host version auto-detection
# ---------------------------------------------------------------------------
function Resolve-HostVersion {
    param([string]$Explicit)
    if ($Explicit -ne '') { return $Explicit.Trim() }
    # 内置运行时优先（2026-09-30 修复）：源码 checkout 里的版本号在宿主升级后会滞后，
    # 先读它会把宿主误判成旧版本，进而把插件挑回旧版（实测踩过）。runtime\ 才是权威。
    $launcherDir = Split-Path -Parent $script:DataDir
    $runtimeManifest = Join-Path $launcherDir 'runtime\node_modules\@deepseek-ai\dsh\package.json'
    if (Test-Path -LiteralPath $runtimeManifest) {
        $rtText = Read-TextNoBom $runtimeManifest
        if ($null -ne $rtText) {
            try {
                $rtJson = ($rtText | ConvertFrom-Json)
                if ($rtJson -and $rtJson.version) { return [string]$rtJson.version }
            } catch { }
        }
    }
    if ($env:DSH_HOST_VERSION -and $env:DSH_HOST_VERSION.Trim() -ne '') { return $env:DSH_HOST_VERSION.Trim() }
    $candidates = @(
        (Join-Path $script:DataDir 'deepseek-harness\package.json'),
        (Join-Path $script:ProfileWeb 'compatibility.json')
    )
    foreach ($c in $candidates) {
        if (-not (Test-Path -LiteralPath $c)) { continue }
        $rawText = Read-TextNoBom $c
        if ($null -eq $rawText) { continue }
        $j = ($rawText | ConvertFrom-Json)
        if ($null -eq $j) { continue }
        if ($j.version) { return [string]$j.version }
        foreach ($p in $j.PSObject.Properties) {
            foreach ($v in $p.Value) { if ($v -match '^\d+\.\d+\.\d+-rc\.\d+$') { return [string]$v } }
        }
    }
    return '0.1.7-rc.2'
}

# ---------------------------------------------------------------------------
# patch anchor preflight: simulate patch-data.json pairs against a fresh tarball
# ---------------------------------------------------------------------------
function Test-PatchAnchors {
    param([string]$TgzPath, [string]$TargetFile)
    # TargetFile is profile-relative like node_modules\<pkg>\lib\client.js.
    # Derive the path INSIDE the package (skip the scope and package segments).
    $rel = ($TargetFile -replace '\\', '/') -replace '^node_modules/', ''
    $parts = @($rel -split '/')
    $skip = if ($parts[0].StartsWith('@')) { 2 } else { 1 }
    $inner = $null
    if ($skip -lt $parts.Count) { $inner = ($parts[$skip..($parts.Count - 1)] -join '/') }
    if ($null -eq $inner) { return 'BAD-TARGET' }

    $extract = Join-Path $env:TEMP ('dshup-xt-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $extract
    try {
        tar -xzf $TgzPath -C $extract 2>$null
        if ($LASTEXITCODE -ne 0) { return 'EXTRACT-FAIL' }
        $pkgDir = Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
        if ($null -eq $pkgDir) { return 'NO-PKG' }
        $file = Join-Path $pkgDir.FullName $inner
        if (-not (Test-Path -LiteralPath $file)) { return 'MISSING-FILE' }
        $txt = Read-TextNoBom $file
        if ($null -eq $txt) { return 'READFAIL' }

        $patchDataPath = Join-Path $script:DataDir 'patch-data.json'
        $patchData = $null
        if (Test-Path -LiteralPath $patchDataPath) {
            $pdt = Read-TextNoBom $patchDataPath
            if ($pdt) { $patchData = ($pdt | ConvertFrom-Json) }
        }
        if ($null -eq $patchData) { return 'NO-PATCHDATA' }
        $target = $patchData.targets | Where-Object { ($_.file -replace '\\', '/') -eq ($TargetFile -replace '\\', '/') } | Select-Object -First 1
        if ($null -eq $target) { return 'NOT-PATCHED-TARGET' }

        foreach ($pair in $target.pairs) {
            $idx = $txt.IndexOf([string]$pair.old)
            if ($idx -lt 0) { return 'ANCHOR-MISS' }
            $txt = $txt.Substring(0, $idx) + [string]$pair.new + $txt.Substring($idx + ([string]$pair.old).Length)
        }
        return 'OK'
    } finally {
        Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# detection
# ---------------------------------------------------------------------------
$HostVer = Resolve-HostVersion $HostVersion
Write-Host ''
Write-Host '================================================' -ForegroundColor DarkCyan
Write-Host '   dsh plugin loss-less update workflow'
Write-Host '================================================' -ForegroundColor DarkCyan
Write-Info ('profile web : ' + $script:ProfileWeb)
Write-Info ('host version: ' + $HostVer)

$manifest = Read-JsonUtf8 $script:ProfileManifest
if ($null -eq $manifest -or $null -eq $manifest.dependencies) {
    Write-Error 'profile package.json unreadable or has no dependencies'
    exit 1
}

$patchData = Read-JsonUtf8 (Join-Path $script:DataDir 'patch-data.json')
$patchedFiles = @()
if ($null -ne $patchData -and $null -ne $patchData.targets) {
    $patchedFiles = @($patchData.targets | ForEach-Object { ($_.file -replace '\\', '/') })
}

# ---------------------------------------------------------------------------
# -SelfTest: health audit of the workflow's own guarantees (no upgrades).
#   1. semver comparator assertions
#   2. installed files still carry every local patch marker
#   3. patch anchors re-simulated against FRESH tarballs of the CURRENT
#      versions (the exact preflight -Deep runs before any real upgrade)
#   4. whale gesture-gate markers present
#   5. family engine floor fully normalized (Patch 4)
#   6. loopback API probes
# ---------------------------------------------------------------------------
if ($SelfTest) {
    $script:failures = 0
    function Write-Self { param([string]$Msg, [bool]$Ok)
        if ($Ok) { Write-Ok $Msg } else { $script:failures++; Write-Warn $Msg } }

    Write-Host ''
    Write-Host '================================================' -ForegroundColor DarkCyan
    Write-Host '   SELF TEST'
    Write-Host '================================================' -ForegroundColor DarkCyan

    $asserts = @(
        @('0.5.1', '0.5.0', 1), @('1.66.6', '1.66.2', 1), @('0.2.0-rc.1', '0.1.7-rc.2', 1),
        @('0.1.7-rc.2', '0.1.7-rc.2', 0), @('0.1.7-rc.2', '0.1.7', -1), @('0.1.7-rc.2', '0.1.7-rc.1', 1)
    )
    foreach ($a in $asserts) {
        $got = Compare-Semver $a[0] $a[1]
        Write-Self ("semver " + $a[0] + " vs " + $a[1] + " = " + $got + " (expect " + $a[2] + ")") ($got -eq $a[2])
    }

    # installed marker checks + fresh-tarball anchor simulation
    $lockText = Read-TextNoBom (Join-Path $script:ProfileWeb 'pnpm-lock.yaml')
    foreach ($target in $patchData.targets) {
        $installedFile = Join-Path $script:ProfileWeb $target.file
        $txt = Read-TextNoBom $installedFile
        if ($null -eq $txt) { Write-Self ("marker file missing: " + $target.file) $false; continue }
        $markersOk = $true
        foreach ($m in $target.markers) { if ($txt.IndexOf([string]$m) -lt 0) { $markersOk = $false } }
        Write-Self ("markers present   : " + $target.id) $markersOk

        # tarball URL for the CURRENT installed version
        $rel = ($target.file -replace '\\', '/') -replace '^node_modules/', ''
        $tparts = @($rel -split '/')
        $pkg = if ($tparts[0].StartsWith('@')) { $tparts[0] + '/' + $tparts[1] } else { $tparts[0] }
        $pkgJson = Read-JsonUtf8 (Join-Path $script:ProfileWeb ("node_modules\" + $pkg + "\package.json"))
        if ($null -eq $pkgJson) { Write-Self ("anchor skip (no package.json): " + $target.id) $false; continue }
        $ver = [string]$pkgJson.version
        $tgzUrl = ''
        if ($pkg -eq 'dsh-ego-browser') {
            if ($lockText -match ('codeload\.github\.com/Fisfzy/ego-browser/tar\.gz/([0-9a-f]{40})')) {
                $tgzUrl = 'https://codeload.github.com/Fisfzy/ego-browser/tar.gz/' + $Matches[1]
            }
        } else {
            $enc = $pkg -replace '/', '%2F'
            $tgzUrl = $script:NpmBase + '/' + $enc + '/-/' + ($pkg -split '/')[-1] + '-' + $ver + '.tgz'
        }
        if ($tgzUrl -eq '') { Write-Self ("anchor skip (no tarball url): " + $target.id) $false; continue }
        $tgz = Join-Path $env:TEMP ('dshup-st-' + [guid]::NewGuid().ToString('N') + '.tgz')
        $code = & curl.exe -sL --connect-timeout 15 --max-time 300 -o $tgz -w '%{http_code}' $tgzUrl 2>$null
        if ($LASTEXITCODE -eq 0 -and $code -match '^2' -and (Test-Path -LiteralPath $tgz)) {
            $anchorResult = Test-PatchAnchors $tgz $target.file
            Write-Self ("anchor sim on fresh " + $ver + " tarball: " + $target.id + " -> " + $anchorResult) ($anchorResult -eq 'OK')
            Remove-Item -LiteralPath $tgz -Force -ErrorAction SilentlyContinue
        } else {
            Write-Self ("anchor skip (download failed): " + $target.id) $false
            Remove-Item -LiteralPath $tgz -Force -ErrorAction SilentlyContinue
        }
    }

    # whale gesture-gate markers
    $whale = Read-TextNoBom (Join-Path $script:ProfileWeb 'node_modules\dsh-whale-widget\assets\whale-widget.js')
    $whaleOk = ($null -ne $whale) -and $whale.Contains('dshwvGestureOk') -and $whale.Contains('willReadFrequently')
    Write-Self 'whale gesture-gate + canvas markers present' $whaleOk

    # family engine floor fully normalized
    $floorLeft = 0
    if (Test-Path -LiteralPath (Join-Path $script:ProfileWeb 'node_modules\@linxin666')) {
        Get-ChildItem -LiteralPath (Join-Path $script:ProfileWeb 'node_modules\@linxin666') -Directory | ForEach-Object {
            $pj = Read-JsonUtf8 (Join-Path $_.FullName 'package.json')
            if ($pj) {
                $e = $pj.dsh.engines.dsh
                $p = $pj.peerDependencies.'@deepseek-ai/dsh'
                if ((($e -as [string]) -like '*0.2.0-rc.1*') -or (($p -as [string]) -like '*0.2.0-rc.1*')) { $floorLeft++ }
            }
        }
    }
    Write-Self ('family engine floor normalized (0 leftover 0.2.0-rc.1)') ($floorLeft -eq 0)

    # loopback API probes (per-probe error reporting; 401 = browser-trust
    # fence on a registered route, which still proves the plugin is mounted)
    foreach ($probePath in @('/api/dsh-web-all/degraded', '/api/dsh-web-all/rows', '/api/pet/pets', '/dsh-whale/wait.json', '/api/update/status')) {
        try {
            $probeTimeout = if ($probePath -eq '/api/update/status') { 25 } else { 8 }
            $r = Invoke-WebRequest -Uri ('http://127.0.0.1:3080' + $probePath) -TimeoutSec $probeTimeout -UseBasicParsing
            $probeOk = ($r.StatusCode -eq 200) -or ($r.StatusCode -eq 401)
            $probeNote = if ($r.StatusCode -eq 401) { ' (fenced, ok)' } else { '' }
            Write-Self ("probe " + $probePath + " -> " + $r.StatusCode + $probeNote) $probeOk
        } catch {
            # Invoke-WebRequest throws on 4xx; 401 still proves the fenced
            # route is registered and the plugin is mounted
            $probeStatus = 0
            if ($_.Exception.Response) { $probeStatus = [int]$_.Exception.Response.StatusCode }
            if ($probeStatus -eq 401) {
                Write-Self ("probe " + $probePath + " -> 401 (fenced, ok)") $true
            } else {
                $emsg = $_.Exception.Message
                if ($emsg.Length -gt 80) { $emsg = $emsg.Substring(0, 80) }
                Write-Self ("probe " + $probePath + " -> FAIL: " + $emsg) $false
            }
        }
    }

    Write-Host ''
    if ($script:failures -eq 0) { Write-Ok 'SELF TEST PASSED'; exit 0 }
    Write-Warn ("SELF TEST FAILED ({0} checks)" -f $script:failures)
    exit 1
}

$results = @()
$depNames = @($manifest.dependencies.PSObject.Properties | ForEach-Object { $_.Name })
if ($Filter.Count -gt 0) {
    $depNames = @($depNames | Where-Object { $n = $_; $Filter | Where-Object { $n -like $_ } })
}

foreach ($name in $depNames) {
    $spec = [string]$manifest.dependencies.$name
    if ($spec.StartsWith('file:') -or $spec.StartsWith('link:')) {
        Write-Info ("skip local spec : " + $name)
        continue
    }
    if ($name.StartsWith('@deepseek-ai/')) {
        Write-Info ("skip host cohort: " + $name)
        continue
    }

    $installedJson = Join-Path $script:ProfileWeb ("node_modules\" + $name + "\package.json")
    $current = ''
    if (Test-Path -LiteralPath $installedJson) {
        $ij = Read-JsonUtf8 $installedJson
        if ($ij) { $current = [string]$ij.version }
    }

    $isGit = $spec.StartsWith('github:')
    if ($isGit) {
        $repo = $spec.Substring('github:'.Length).Split('#')[0]
        $gitManifest = Get-GitJson ("https://api.github.com/repos/" + $repo + "?per_page=1")
        if ($null -eq $gitManifest -or $null -eq $gitManifest.default_branch) {
            Write-Warn ("git probe failed  : " + $name + " (rate limit? cached result will kick in on next run)")
            continue
        }
        $branch = [string]$gitManifest.default_branch
        $head = Get-GitJson ("https://api.github.com/repos/" + $repo + "/commits/" + $branch)
        if ($null -eq $head -or $null -eq $head.sha) {
            Write-Warn ("git head failed   : " + $name)
            continue
        }
        $headSha = [string]$head.sha
        $lockText = Read-TextNoBom (Join-Path $script:ProfileWeb 'pnpm-lock.yaml')
        $installedSha = ''
        if ($lockText -and $lockText -match ('codeload\.github\.com/' + [regex]::Escape($repo) + '/tar\.gz/([0-9a-f]{40})')) {
            $installedSha = $Matches[1]
        }
        $outdated = ($installedSha -ne '') -and ($installedSha -ne $headSha)
        $latest = 'git#' + $headSha
        $reason = ''
        if (-not $outdated) { $reason = 'current' }
        $results += [pscustomobject]@{ Name = $name; Kind = 'git'; Current = $current; Latest = $latest; Chosen = ''; Outdated = $outdated; Reason = $reason }
        if ($outdated) { Write-Warn ("outdated          : " + $name + " git " + $installedSha.Substring(0, 8) + " -> " + $headSha.Substring(0, 8)) }
        else { Write-Ok ("up to date        : " + $name + " (git " + $installedSha.Substring(0, 8) + ")") }
        continue
    }

    $enc = $name -replace '/', '%2F'
    $latestInfo = ((Get-UrlText ($script:NpmBase + '/' + $enc + '/latest') 30) | ConvertFrom-Json)
    if ($null -eq $latestInfo -or $null -eq $latestInfo.version) {
        Write-Warn ("registry probe failed: " + $name)
        continue
    }
    $latest = [string]$latestInfo.version
    $outdated = ($current -ne '') -and ((Compare-Semver $latest $current) -gt 0)

    if (-not $outdated) {
        $results += [pscustomobject]@{ Name = $name; Kind = 'npm'; Current = $current; Latest = $latest; Chosen = ''; Outdated = $false; Reason = 'current' }
        Write-Ok ("up to date        : " + $name + " (" + $current + ")")
        continue
    }

    # ---- candidate manifest + compat preflight ----
    $cand = ((Get-UrlText ($script:NpmBase + '/' + $enc + '/' + $latest) 30) | ConvertFrom-Json)
    $chosen = $latest
    $reason = ''
    if ($null -ne $cand -and -not (Test-HardCompatible $cand $HostVer)) {
        # fall back to the newest version whose deepseek peers accept this host
        $packument = ((Get-UrlText ($script:NpmBase + '/' + $enc) 60) | ConvertFrom-Json)
        $fallback = ''
        if ($null -ne $packument -and $null -ne $packument.versions) {
            $vers = @($packument.versions.PSObject.Properties | ForEach-Object { $_.Name } |
                Sort-Object { Convert-Semver $_ } -Descending)
            foreach ($v in $vers) {
                if ((Compare-Semver $v $current) -lt 0) { continue }
                $vm = $packument.versions.($v)
                if ($vm -and (Test-HardCompatible $vm $HostVer)) { $fallback = $v; break }
            }
        }
        if ($fallback -ne '') {
            if ((Compare-Semver $fallback $current) -gt 0) {
                $chosen = $fallback
                $reason = $latest + ' needs host >=0.2.0 peers; chose newest host-compatible ' + $fallback
            } else {
                # already sitting on the newest host-compatible release
                $results += [pscustomobject]@{ Name = $name; Kind = 'npm'; Current = $current; Latest = $latest; Chosen = ''; Outdated = $false; Reason = 'already at newest host-compatible ' + $fallback + ' (' + $latest + ' needs host >=0.2.0 peers)' }
                Write-Ok ("up to date (best) : " + $name + " " + $current + "  [" + $latest + " needs host >=0.2.0 peers]")
                continue
            }
        } else {
            $chosen = ''
            $reason = $latest + ' needs host >=0.2.0 peers; no compatible release found - DEFERRED (upgrade host first)'
        }
    } elseif ($null -ne $cand) {
        $eng = $cand.dsh.engines.dsh
        if ($eng -and ([string]$eng).Contains('0.2.0-rc.1') -and $HostVer -notlike '0.2.0-rc.1*') {
            $reason = 'soft engine floor (' + $eng + ') - runtime tolerates it; apply-adaptations Patch 4 normalizes the label'
        }
    }

    if ($chosen -eq '') {
        $results += [pscustomobject]@{ Name = $name; Kind = 'npm'; Current = $current; Latest = $latest; Chosen = ''; Outdated = $true; Reason = $reason }
        Write-Warn ("deferred          : " + $name + " - " + $reason)
        continue
    }

    # ---- deep patch-anchor preflight on fresh tarball ----
    if ($Deep) {
        $needAnchorCheck = $false
        foreach ($pf in $patchedFiles) {
            if ($pf -like ("node_modules/" + $name + "/*")) { $needAnchorCheck = $true; break }
        }
        if ($needAnchorCheck) {
            $tgzUrl = $script:NpmBase + '/' + $enc + '/-/' + ($name -split '/')[-1] + '-' + $chosen + '.tgz'
            $tgz = Join-Path $env:TEMP ('dshup-' + [guid]::NewGuid().ToString('N') + '.tgz')
            $code = & curl.exe -sL --connect-timeout 15 --max-time 300 -o $tgz -w '%{http_code}' $tgzUrl 2>$null
            if ($LASTEXITCODE -eq 0 -and $code -match '^2' -and (Test-Path -LiteralPath $tgz)) {
                foreach ($pf in $patchedFiles) {
                    if ($pf -like ("node_modules/" + $name + "/*")) {
                        $anchor = Test-PatchAnchors $tgz $pf
                        Write-Info ("anchor preflight : " + $pf + " -> " + $anchor)
                        if ($anchor -ne 'OK') {
                            $chosen = ''
                            $reason = 'local patch anchor failed on ' + $chosen + ' (' + $anchor + ') - needs manual adaptation'
                            break
                        }
                    }
                }
                Remove-Item -LiteralPath $tgz -Force -ErrorAction SilentlyContinue
            } else {
                Write-Warn ('anchor preflight tarball download failed for ' + $name + ' - continuing without anchor check')
                Remove-Item -LiteralPath $tgz -Force -ErrorAction SilentlyContinue
            }
            if ($chosen -eq '') {
                $results += [pscustomobject]@{ Name = $name; Kind = 'npm'; Current = $current; Latest = $latest; Chosen = ''; Outdated = $true; Reason = $reason }
                Write-Warn ("deferred          : " + $name + " - " + $reason)
                continue
            }
        }
    }

    # ---- mirror sync check ----
    $mirrorInfo = ((Get-UrlText ($script:MirrorBase + '/' + $enc) 30) | ConvertFrom-Json)
    $synced = $false
    if ($null -ne $mirrorInfo -and $null -ne $mirrorInfo.versions) {
        $synced = $null -ne ($mirrorInfo.versions.PSObject.Properties | Where-Object { $_.Name -eq $chosen })
    }
    $mirrorNote = ''
    if (-not $synced) {
        $mirrorNote = 'npmmirror has NOT synced ' + $chosen + ' yet; wait for sync or the install will stay on ' + $current
    }

    $results += [pscustomobject]@{ Name = $name; Kind = 'npm'; Current = $current; Latest = $latest; Chosen = $chosen; Outdated = $true; Reason = ($reason + ' ' + $mirrorNote).Trim() }
    $outTxt = "outdated          : " + $name + " " + $current + " -> " + $chosen
    if ($reason -ne '') { $outTxt += "  [" + $reason + "]" }
    Write-Warn $outTxt
    if ($mirrorNote -ne '') { Write-Warn ("                   " + $mirrorNote) }
}

$toUpgrade = @($results | Where-Object { $_.Outdated -and $_.Chosen -ne '' -and $_.Kind -eq 'npm' })
$gitToRefresh = @($results | Where-Object { $_.Outdated -and $_.Kind -eq 'git' })
$deferred = @($results | Where-Object { $_.Outdated -and $_.Chosen -eq '' })

Write-Host ''
if ($toUpgrade.Count -eq 0 -and $deferred.Count -eq 0) {
    Write-Ok 'all registry plugins are up to date'
}

if ($deferred.Count -gt 0) {
    Write-Warn 'DEFERRED (compatibility):'
    $deferred | ForEach-Object { Write-Warn ('  - ' + $_.Name + ' : ' + $_.Reason) }
}

$execApply = ($Apply -or $AutoApply)
if (-not $execApply) {
    Write-Host ''
    Write-Info 'check-only mode. re-run with -Apply to execute the upgrade plan above.'
    Write-Info 'use -Deep to also pre-flight local patch anchors against fresh tarballs.'
    Write-Info 'use -SelfTest to audit patch markers, anchor simulation and API health.'
    exit 0
}

if ($AutoApply) {
    if ($gitToRefresh.Count -gt 0) {
        Write-Info ('auto mode skips git deps (live browser restart risk): ' + (($gitToRefresh | ForEach-Object { $_.Name }) -join ', '))
    }
    $gitToRefresh = @()
}

if ($toUpgrade.Count -eq 0 -and $gitToRefresh.Count -eq 0) {
    Write-Host ''
    $modeName = $(if ($AutoApply) { '-AutoApply' } else { '-Apply' })
    Write-Info ('nothing to upgrade; ' + $modeName + ' does nothing.')
    exit 0
}

# ---------------------------------------------------------------------------
# apply phase
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '------------------------------------------------' -ForegroundColor DarkCyan
Write-Host '  APPLY PHASE'
Write-Host '------------------------------------------------' -ForegroundColor DarkCyan

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$bak = Join-Path $script:BackupRoot ('upgrade-auto-' + $ts)
New-Item -ItemType Directory -Force -Path $bak | Out-Null
Copy-Item -LiteralPath $script:ProfileManifest $bak -Force
Copy-Item -LiteralPath (Join-Path $script:ProfileWeb 'pnpm-lock.yaml') $bak -Force -ErrorAction SilentlyContinue
Copy-Item -LiteralPath (Join-Path $script:ProfileWeb 'pnpm-workspace.yaml') $bak -Force -ErrorAction SilentlyContinue
Copy-Item -LiteralPath (Join-Path $script:DataDir 'patch-data.json') $bak -Force -ErrorAction SilentlyContinue
Copy-Item -LiteralPath (Join-Path $script:DataDir 'apply-adaptations.ps1') $bak -Force -ErrorAction SilentlyContinue
$results | ForEach-Object { "{0}|{1}|{2}|{3}" -f $_.Name, $_.Current, $_.Latest, $_.Chosen } | Set-Content -LiteralPath (Join-Path $bak 'plan.txt') -Encoding UTF8
Write-Ok ('backup            : ' + $bak)

# mirror re-verify + wait gate: npmmirror sync lag once made a whole update a
# silent no-op (pnpm downloaded 0). Wait up to 10 minutes per package.
$dropList = @()
foreach ($u in $toUpgrade) {
    $uEnc = $u.Name -replace '/', '%2F'
    $uSynced = $false
    for ($try = 1; $try -le 10 -and -not $uSynced; $try++) {
        $mirrorInfo = ((Get-UrlText ($script:MirrorBase + '/' + $uEnc) 30) | ConvertFrom-Json)
        if ($null -ne $mirrorInfo -and $null -ne $mirrorInfo.versions) {
            $uSynced = $null -ne ($mirrorInfo.versions.PSObject.Properties | Where-Object { $_.Name -eq $u.Chosen })
        }
        if (-not $uSynced) {
            Write-Info ("mirror wait " + $try + "/10 : " + $u.Name + "@" + $u.Chosen)
            Start-Sleep -Seconds 60
        }
    }
    if (-not $uSynced) {
        Write-Warn ("mirror still unsynced for " + $u.Name + "@" + $u.Chosen + "; dropped from this run")
        $dropList += $u
    }
}
if ($dropList.Count -gt 0) {
    $toUpgrade = @($toUpgrade | Where-Object { $dropList -notcontains $_ })
}

# rewrite package.json specs (preserve range style)
$manifestText = Read-TextNoBom $script:ProfileManifest
$manifestObj = Read-JsonUtf8 $script:ProfileManifest

# pin host-gated packages to exact versions: a caret spec could otherwise pull
# a host-incompatible release later (e.g. dsh-session-insights ^0.5.0 -> 0.5.1)
foreach ($r in $results) {
    if ($r.Kind -eq 'npm' -and ($r.Reason -match 'needs host')) {
        $pinSpec = [string]$manifestObj.dependencies.($r.Name)
        if ($pinSpec -and ($pinSpec.StartsWith('^') -or $pinSpec.StartsWith('~'))) {
            $pinLine = '"' + $r.Name + '": "' + $pinSpec + '"'
            if ($manifestText.Contains($pinLine)) {
                $manifestText = $manifestText.Replace($pinLine, '"' + $r.Name + '": "' + $r.Current + '"')
                Write-Ok ('pin host-gated   : ' + $r.Name + ' ' + $pinSpec + ' -> ' + $r.Current)
            }
        }
    }
}

foreach ($u in $toUpgrade) {
    $oldSpec = [string]$manifestObj.dependencies.($u.Name)
    $newSpec = $u.Chosen
    if ($oldSpec.StartsWith('^')) { $newSpec = '^' + $u.Chosen }
    elseif ($oldSpec.StartsWith('~')) { $newSpec = '~' + $u.Chosen }
    $line = '"' + $u.Name + '": "' + $oldSpec + '"'
    if ($manifestText.Contains($line)) {
        $manifestText = $manifestText.Replace($line, '"' + $u.Name + '": "' + $newSpec + '"')
        Write-Ok ('manifest          : ' + $u.Name + ' ' + $oldSpec + ' -> ' + $newSpec)
    } else {
        Write-Warn ('manifest line not found for ' + $u.Name + '; skipping its spec rewrite')
    }
}
Write-TextNoBom $script:ProfileManifest $manifestText

# install
Push-Location $script:ProfileWeb
try {
    $installOut = & pnpm.cmd install --config.minimumReleaseAge=0 --ignore-scripts 2>&1
    $installCode = $LASTEXITCODE
} finally {
    Pop-Location
}
if ($installCode -ne 0) {
    Write-Warn ('pnpm install exited ' + $installCode + '; see output above. rollback files are in ' + $bak)
    Write-Warn ($installOut | Select-Object -Last 15)
    exit 2
}
Write-Ok 'pnpm install completed'

# git deps re-resolve (github: specs pin a commit in the lockfile)
foreach ($g in $gitToRefresh) {
    Push-Location $script:ProfileWeb
    try {
        $gitOut = & pnpm.cmd update $g.Name --config.minimumReleaseAge=0 --ignore-scripts 2>&1
        $gitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($gitCode -ne 0) {
        Write-Warn ('pnpm update failed for ' + $g.Name + ' (exit ' + $gitCode + ')')
        Write-Warn ($gitOut | Select-Object -Last 8)
    } else {
        Write-Ok ('git refresh       : ' + $g.Name)
    }
}

# local adaptations (idempotent; includes family engine-floor Patch 4)
$adaptOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $script:DataDir 'apply-adaptations.ps1') 2>&1
Write-Ok 'apply-adaptations.ps1 executed'
$adaptOut | ForEach-Object { Write-Info ([string]$_) }

# cloudflared binary restore (dsh-remote-web-ui tunnel; postinstall skipped by --ignore-scripts)
$cfBin = Join-Path $script:ProfileWeb 'node_modules\cloudflared\bin\cloudflared.exe'
if (-not (Test-Path -LiteralPath $cfBin)) {
    $cfDir = Split-Path $cfBin
    New-Item -ItemType Directory -Force -Path $cfDir | Out-Null
    $cfOut = & curl.exe -sL --fail --retry 3 --connect-timeout 30 -o $cfBin "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" 2>&1
    if ((Test-Path -LiteralPath $cfBin) -and ((Get-Item $cfBin).Length -gt 10000000)) {
        Write-Ok ('cloudflared.exe restored (' + (Get-Item $cfBin).Length + ' bytes)')
    } else {
        Write-Warn 'cloudflared.exe download failed; the remote-access tunnel feature stays degraded until it is restored'
    }
} else {
    Write-Ok 'cloudflared.exe present'
}

# ---------------------------------------------------------------------------
# verify phase
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '------------------------------------------------' -ForegroundColor DarkCyan
Write-Host '  VERIFY PHASE'
Write-Host '------------------------------------------------' -ForegroundColor DarkCyan

$verifyLines = @()
foreach ($u in $toUpgrade) {
    $pkgJson = Join-Path $script:ProfileWeb ("node_modules\" + $u.Name + "\package.json")
    $v = ''
    if (Test-Path -LiteralPath $pkgJson) {
        $pj = Read-JsonUtf8 $pkgJson
        if ($pj) { $v = [string]$pj.version }
    }
    $ok = ($v -eq $u.Chosen)
    $line = ("{0,-45} expected {1,-12} installed {2,-12} {3}" -f $u.Name, $u.Chosen, $v, ($(if ($ok) { 'OK' } else { 'MISMATCH' })))
    $verifyLines += $line
    if ($ok) { Write-Ok $line } else { Write-Warn $line }
}

# loopback API probes (only when the web host is up; 401 = browser-trust fence
# on a registered route, which still proves the plugin is mounted)
$probeLines = @()
foreach ($probePath in @('/api/dsh-web-all/degraded', '/api/dsh-web-all/rows', '/api/pet/pets', '/dsh-whale/wait.json', '/api/update/status')) {
    try {
        $probeTimeout = if ($probePath -eq '/api/update/status') { 25 } else { 8 }
        $r = Invoke-WebRequest -Uri ('http://127.0.0.1:3080' + $probePath) -TimeoutSec $probeTimeout -UseBasicParsing
        $probeOk = ($r.StatusCode -eq 200) -or ($r.StatusCode -eq 401)
        $probeLines += ("{0} -> {1}{2}" -f $probePath, $r.StatusCode, $(if ($probeOk) { ' OK' } else { ' FAIL' }))
    } catch {
        $probeStatus = 0
        if ($_.Exception.Response) { $probeStatus = [int]$_.Exception.Response.StatusCode }
        if ($probeStatus -eq 401) {
            $probeLines += ("{0} -> 401 (fenced, ok)" -f $probePath)
        } else {
            $probeLines += ("{0} -> FAIL ({1})" -f $probePath, $_.Exception.Message)
        }
    }
}
$probeLines | ForEach-Object { Write-Ok ("probe " + $_) }

# report
$reportPath = Join-Path $script:DataDir ('修复记录-' + $ts + '-自动升级.md')
$report = @()
$report += '# 修复记录：插件无损升级（自动工作流）'
$report += ''
$report += '时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
$report += ''
$report += '## 升级清单'
$report += ''
$report += '| 插件 | 旧版本 | 目标版本 | 备注 |'
$report += '|---|---|---|---|'
foreach ($u in $toUpgrade) { $report += ('| {0} | {1} | {2} | {3} |' -f $u.Name, $u.Current, $u.Chosen, $u.Reason) }
foreach ($g in $gitToRefresh) { $report += ('| {0} | {1} | {2} | {3} |' -f $g.Name, $g.Current, $g.Latest, 'git branch head refresh') }
$report += ''
if ($deferred.Count -gt 0) {
    $report += '## 暂缓（兼容性）'
    $report += ''
    foreach ($d in $deferred) { $report += ('- {0}: {1}' -f $d.Name, $d.Reason) }
    $report += ''
}
$report += '## 验证'
$report += ''
$verifyLines | ForEach-Object { $report += ('- ' + $_) }
$probeLines | ForEach-Object { $report += ('- probe ' + $_) }
$report += ''
$report += '## 回滚'
$report += ''
$report += ('备份目录: ' + $bak)
$report += ''
$report += '恢复备份中的 package.json / pnpm-lock.yaml / pnpm-workspace.yaml 到 profile 目录后执行:'
$report += ''
$report += '    pnpm install --config.minimumReleaseAge=0 --ignore-scripts'
$report += '    powershell -ExecutionPolicy Bypass -File apply-adaptations.ps1'
$report += ''
Write-TextNoBom $reportPath ($report -join "`r`n")
Write-Ok ('report            : ' + $reportPath)

Write-Host ''
Write-Info 'Browser verification checklist (manual, 2 min):'
Write-Info '  1. hard-refresh the web UI; F12 console must show 0 errors / 0 page errors'
Write-Info '  2. Settings -> Plugins list must show no "abnormal" row'
Write-Info '  3. whale widget renders bottom-right; pet summon ball behaves as configured'
Write-Info '  4. task board / context dashboard / market panels render'
Write-Info 'If any check fails, restore from backup (see report).'
Write-Host ''
