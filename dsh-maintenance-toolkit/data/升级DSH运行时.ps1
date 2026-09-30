# DSH 宿主升级引擎（通用版）—— 配置驱动，可复现同一套流程
#
# 与冻结实例 升级DSH到0.2.0-rc.2.ps1 的关系：
#   那份是「0.2.0-rc.2 这一目标」的已验证实例；本引擎把同一套流程参数化，
#   换目标版本时只改 升级配置.json（或 -TargetVersion），不必重写脚本。
#
# 流程（每步都有门禁，失败即停并回滚）：
#   P0 前置检查     宿主已停止 / 暂存区版本 / pnpm / 磁盘
#   P1 兼容缺口分析  调 tools\analyze-compat.mjs：谁不兼容、能升到哪个版本、还是只能豁免
#   P2 配置一致性    分析结果必须被 升级配置.json 覆盖，否则报未覆盖项（防漏项）
#   P3 全局适配      本地 link/file 包的 peer 上界放宽（对旧宿主中性，可提前做）
#   P4 备份 + 原子交换  profile 关键文件备份；runtime ↔ 暂存区互换（旧版改名保存）
#   P5 profile 变更  bundles 补项 / 插件升版 / 撤销旧豁免 + 授予新豁免
#   P6 组合树断言     0 个 skipping profile bundle + 关键条目在册，否则自动回滚
#   P7 启动 + 就绪    启动一键启动器并轮询端口
#
# 用法：
#   .\升级DSH运行时.ps1 -Analyze        只分析（含配置一致性检查），不改任何文件
#   .\升级DSH运行时.ps1 -DryRun         分析 + 打印完整计划，不改任何文件
#   .\升级DSH运行时.ps1 -StageOnly      只把目标版本装进暂存区（做原生件探针）
#   .\升级DSH运行时.ps1                 正式升级
#   .\升级DSH运行时.ps1 -Rollback       回滚
#   .\升级DSH运行时.ps1 -VerifyOnly     只对当前 runtime 跑组合树断言
#   .\升级DSH运行时.ps1 -Root <沙箱目录>  在沙箱里跑同一套流程（演练交换/回滚，不碰生产）
[CmdletBinding()]
param(
    [string]$TargetVersion,
    [string]$ConfigPath,
    [string]$Root,
    [string]$StageDir = 'runtime-next',
    [switch]$Analyze,
    [switch]$DryRun,
    [switch]$StageOnly,
    [switch]$VerifyOnly,
    [switch]$ApplyRuntimePatches,
    # 升级成功后跳过维护链（maintain.ps1 -Update；仅生产模式会跑）
    [switch]$SkipMaintain,
    [switch]$Rollback,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
# 脚本可放在数据目录里：向上探测启动器根目录（含 runtime\ 与数据目录的目录）作为路径锚点。
# -Root 仍可指向沙箱目录，用于在不动生产环境的前提下做「完整破坏性演练」（含交换与回滚）
$LauncherRoot = $PSScriptRoot
while ($true) {
    if ((Test-Path -LiteralPath (Join-Path $LauncherRoot 'runtime')) -and
        (Test-Path -LiteralPath (Join-Path $LauncherRoot 'deepseek-Harness插件及其数据'))) { break }
    $parent = Split-Path -Parent $LauncherRoot
    if (-not $parent -or $parent -eq $LauncherRoot) { break }
    $LauncherRoot = $parent
}
if (-not $Root) { $Root = $LauncherRoot }
# 生产模式 = Root 指向探测到的启动器根目录；指向其他目录（沙箱演练）时跳过宿主停止检查等生产约束
$isProduction = ($Root -eq $LauncherRoot)
$Runtime   = Join-Path $Root 'runtime'
$Stage     = Join-Path $Root $StageDir
$DataHome  = Join-Path $Root 'deepseek-Harness插件及其数据\dsh-home'
$Profile   = Join-Path $DataHome 'profiles\web'
# 显式设置 DSH_HOME：从资源管理器双击 .cmd 运行时，用户环境里可能没有这个变量；
# 不设置的话 dsh 会去定位 %USERPROFILE%\.dsh 这个**错误的** profile，
# 导致豁免写入与组合树断言全部打在别处。
$env:DSH_HOME = $DataHome
$Launcher  = Join-Path $Root '一键启动DeepSeek-Harness.bat'
$LogDir    = Join-Path $Root 'logs'
$Tools     = Join-Path $Root 'tools'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Utf8Bom   = New-Object System.Text.UTF8Encoding($true)

if (-not $ConfigPath) { $ConfigPath = Join-Path $Root 'deepseek-Harness插件及其数据\升级配置.json' }

function Write-Step($m)  { Write-Host ("== " + $m) -ForegroundColor Cyan }
function Write-Ok($m)    { Write-Host ("   OK  " + $m) -ForegroundColor Green }
function Write-Warn2($m) { Write-Host ("   !   " + $m) -ForegroundColor Yellow }
function Write-Bad($m)   { Write-Host ("   X   " + $m) -ForegroundColor Red }

$script:LastNativeExit = 0
function Invoke-Native([scriptblock]$Block) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Block 2>&1
        $script:LastNativeExit = $LASTEXITCODE
        return $out
    } finally { $ErrorActionPreference = $prev }
}

function Test-Listening([int]$Port) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { $c.Connect('127.0.0.1', $Port); return $true } catch { return $false } finally { $c.Dispose() }
}

function Get-DshVersion([string]$RuntimeDir) {
    $p = Join-Path $RuntimeDir 'node_modules\@deepseek-ai\dsh\package.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return ([System.IO.File]::ReadAllText($p, $Utf8NoBom) | ConvertFrom-Json).version
}

function Read-Json([string]$Path) { return ([System.IO.File]::ReadAllText($Path, $Utf8NoBom) | ConvertFrom-Json) }

function Get-Composition([string]$RuntimeDir) {
    $node = Join-Path $RuntimeDir 'node.exe'
    $bin  = Join-Path $RuntimeDir 'node_modules\@deepseek-ai\dsh\lib\bin.js'
    return ((Invoke-Native { & $node $bin --profile web --dump-config }) | Out-String)
}

function Test-Composition([string]$RuntimeDir, $Config) {
    $text  = Get-Composition $RuntimeDir
    $skips = @([regex]::Matches($text, 'skipping profile bundle "([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    $missing = @()
    foreach ($need in $Config.assertContains) { if (-not $text.Contains($need)) { $missing += $need } }
    return [pscustomobject]@{ Skips = $skips; Missing = $missing; Text = $text }
}

function Get-Analysis($Config) {
    $node = Join-Path $Stage 'node.exe'
    $script = Join-Path $Tools 'analyze-compat.mjs'
    $raw = (Invoke-Native { & $node $script $Stage $Profile $Config.targetVersion }) | Out-String
    $json = $raw.Trim()
    $start = $json.IndexOf('{')
    if ($start -lt 0) { throw "分析器没有输出 JSON：$raw" }
    return ($json.Substring($start) | ConvertFrom-Json)
}

function Test-ConfigCoverage($Analysis, $Config) {
    $upgrades = @{}
    if ($Config.packageUpgrades) { foreach ($p in $Config.packageUpgrades.PSObject.Properties) { $upgrades[$p.Name] = [string]$p.Value } }
    $patches = @()
    if ($Config.localPeerPatches) { $patches = @($Config.localPeerPatches.PSObject.Properties.Name) }
    $exempt  = @($Config.exemptions)
    # profile 里已有的豁免（compatibility.json）同样算覆盖：那是上一轮已经确认过的风险
    $existing = @()
    $compatPath = Join-Path $Profile 'compatibility.json'
    if (Test-Path -LiteralPath $compatPath) {
        try {
            $compat = ([System.IO.File]::ReadAllText($compatPath, $Utf8NoBom) | ConvertFrom-Json)
            foreach ($p in $compat.PSObject.Properties) { if (@($p.Value) -contains $Config.targetVersion) { $existing += $p.Name } }
        } catch { }
    }

    $rows = @()
    foreach ($r in $Analysis.results) {
        if ($r.status -ne 'incompatible') { continue }
        $name = [string]$r.name
        $plan = $null; $ok = $false
        if ($upgrades.ContainsKey($name)) {
            $cand = $upgrades[$name]
            $nativeOk = $false
            if ($r.candidate -and [string]$r.candidate.version -eq $cand) { $nativeOk = [bool]$r.candidate.compatible }
            if ($nativeOk) { $plan = "升级到 $cand（原生兼容）"; $ok = $true }
            elseif ($exempt -contains "$name@$cand") { $plan = "升级到 $cand + 精确豁免"; $ok = $true }
            else { $plan = "升级到 $cand，但既非原生兼容也未豁免"; $ok = $false }
        } elseif ($patches -contains $name) {
            $plan = '本地 peer 放宽（原生通过）'; $ok = $true
        } elseif ($exempt -contains "$name@$([string]$r.installed)") {
            $plan = "对当前版本 $($r.installed) 开精确豁免"; $ok = $true
        } elseif ($existing -contains "$name@$([string]$r.installed)") {
            $plan = "profile 里已有该版本在 $($Config.targetVersion) 上的豁免"; $ok = $true
        } else {
            $plan = '配置未覆盖'; $ok = $false
        }
        $rows += [pscustomobject]@{ Name = $name; Installed = [string]$r.installed; Plan = $plan; Covered = $ok }
    }
    return $rows
}

function Save-State($State, [string]$Path) {
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, ($State | ConvertTo-Json -Depth 6), $Utf8Bom)
}

function Restore-ProfileFiles($State) {
    if (-not $State.ProfileBackup -or -not (Test-Path -LiteralPath $State.ProfileBackup)) { Write-Warn2 '没有可用的 profile 备份'; return }
    foreach ($f in @('package.json', 'pnpm-lock.yaml', 'compatibility.json', 'cordis.patch.yml')) {
        $src = Join-Path $State.ProfileBackup $f
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $Profile $f) -Force; Write-Ok ("已还原 " + $f) }
    }
}

function Invoke-Rollback($State) {
    Write-Step '回滚到升级前状态'
    if ($isProduction -and (Test-Listening 3080)) { Write-Bad '宿主仍在运行（3080 被占用），请先停止服务再回滚。'; return $false }
    $ok = $false
    if ($State.RuntimeBackup -and (Test-Path -LiteralPath $State.RuntimeBackup)) {
        # 被换下的新运行时放回暂存区（若暂存区被占用则改名留存），这样修好问题后可直接重试
        $parked = $Stage
        if (Test-Path -LiteralPath $parked) { $parked = Join-Path $Root ("runtime.broken-" + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
        if (Test-Path -LiteralPath $Runtime) { Move-Item -LiteralPath $Runtime -Destination $parked }
        Move-Item -LiteralPath $State.RuntimeBackup -Destination $Runtime
        Write-Ok ("runtime 已还原为 " + (Get-DshVersion $Runtime) + "；被换下的版本放回 " + (Split-Path -Leaf $parked))
        $ok = $true
    } else { Write-Warn2 '状态里没有 runtime 备份' }
    Restore-ProfileFiles $State
    $pnpm = Get-Command pnpm.cmd -ErrorAction SilentlyContinue
    if ($pnpm -and $isProduction) {
        Push-Location $Profile
        try { [void](Invoke-Native { & $pnpm.Source install }) } finally { Pop-Location }
        Write-Ok 'profile 依赖已按旧版清单重装'
    } elseif ($pnpm) {
        Write-Warn2 '沙箱模式：跳过 profile 依赖重装（避免写穿 junction 指向的真实 node_modules）'
    } else { Write-Warn2 ('请手动执行：pnpm -C "' + $Profile + '" install') }
    return $ok
}

# ============================================================ 载入配置
if (-not (Test-Path -LiteralPath $ConfigPath)) { Write-Bad ("找不到配置：" + $ConfigPath); exit 2 }
$Config = Read-Json $ConfigPath
if ($TargetVersion) { $Config.targetVersion = $TargetVersion }
if (-not $Config.targetVersion) { Write-Bad '配置里没有 targetVersion'; exit 2 }
$StatePath = Join-Path $LogDir ('升级DSH-' + $Config.targetVersion + '.state.json')

Write-Host '============================================' -ForegroundColor DarkCyan
Write-Host ('  DSH 宿主升级引擎   目标 ' + $Config.targetVersion) -ForegroundColor DarkCyan
Write-Host '============================================' -ForegroundColor White

if ($Rollback) {
    $state = Read-Json $StatePath
    $done = Invoke-Rollback $state
    if (-not $NoStart -and $done) { Start-Process -FilePath $Launcher }
    exit $(if ($done) { 0 } else { 1 })
}

# ============================================================ P0 前置检查
Write-Step 'P0 前置检查'
Write-Ok ('DSH_HOME = ' + $env:DSH_HOME)
$bad = $false
$cur = Get-DshVersion $Runtime
$stageVer = Get-DshVersion $Stage
Write-Ok ('当前 runtime = ' + $cur)
if ($stageVer) { Write-Ok ('暂存区 = ' + $stageVer) } else { Write-Warn2 ('暂存区不可用：' + $Stage) }
if (-not (Test-Path -LiteralPath (Join-Path $Profile 'package.json'))) { Write-Bad ('找不到 profile：' + $Profile); $bad = $true } else { Write-Ok ('profile = ' + $Profile) }
$pnpmCmd = Get-Command pnpm.cmd -ErrorAction SilentlyContinue
if ($pnpmCmd) { Write-Ok ('pnpm = ' + $pnpmCmd.Source) } else { Write-Bad '未找到 pnpm.cmd'; $bad = $true }
# 生产模式才要求宿主停止；-Root 指向沙箱时跳过（用于完整破坏性演练，不碰生产运行时）
# （$isProduction 已在脚本开头按「Root 是否指向探测到的启动器根目录」算出）
$hostRunning = $false
if ($isProduction) {
    $hostRunning = Test-Listening 3080
    if ($hostRunning) { Write-Warn2 '3080 正在监听：宿主还在运行（升级会中止）' } else { Write-Ok '宿主已停止（3080 空闲）' }
} else {
    Write-Ok ('沙箱模式（-Root ' + $Root + '）：跳过宿主运行检查，用于演练交换/回滚')
}
if ($bad) { exit 2 }

if ($VerifyOnly) {
    Write-Step 'P6 组合树断言（当前 runtime）'
    $v = Test-Composition $Runtime $Config
    if ($v.Skips.Count) { Write-Bad ('被跳过：' + ($v.Skips -join ', ')) } else { Write-Ok '0 个 bundle 被跳过' }
    if ($v.Missing.Count) { Write-Bad ('缺失：' + ($v.Missing -join ', ')) } else { Write-Ok '关键条目齐全' }
    exit $(if ($v.Skips.Count -or $v.Missing.Count) { 1 } else { 0 })
}

# ============================================================ P1 兼容缺口分析
Write-Step 'P1 兼容缺口分析（宿主的 peer 门禁判定）'
if (-not $stageVer) { Write-Bad '需要可用的暂存区才能分析（先跑 -StageOnly）'; exit 2 }
$analysis = Get-Analysis $Config
$incompat = @($analysis.results | Where-Object { $_.status -eq 'incompatible' })
Write-Host ('   共 ' + $analysis.bundleCount + ' 个 bundle，不兼容 ' + $incompat.Count + ' 个') -ForegroundColor DarkGray
foreach ($r in $incompat) {
    Write-Host ('   - ' + $r.name + '@' + $r.installed) -ForegroundColor Yellow
    if ($r.advice) { Write-Host ('       分析建议：' + $r.advice + ' —— ' + $r.hint) -ForegroundColor DarkGray }
}
if ($incompat.Count -eq 0) { Write-Ok '没有兼容性缺口' }

# ============================================================ P2 配置一致性
Write-Step 'P2 配置一致性（分析结果必须被升级配置.json 覆盖）'
$coverage = Test-ConfigCoverage $analysis $Config
foreach ($row in $coverage) {
    if ($row.Covered) { Write-Ok ($row.Name + ' → ' + $row.Plan) } else { Write-Bad ($row.Name + ' → ' + $row.Plan) }
}
$uncovered = @($coverage | Where-Object { -not $_.Covered })
if ($uncovered.Count) { Write-Warn2 ('有 ' + $uncovered.Count + ' 项未覆盖：升级会在 P6 断言时被拦下，请先补进配置') }

# ============================================================ P2.5 本地运行时补丁门禁
# 本机对 runtime 里的 client UI 包打过私有补丁（patch-runtime-tree.mjs：挽具框架 CSS、暗色默认、
# 服务状态点、skip-link、移动端适配）。换了干净的 npm 运行时就会丢掉它们，所以交换前必须确认。
Write-Step 'P2.5 本地运行时补丁（本机 UI 定制）'
$patchGateOk = $true
$dataDir    = Split-Path -Parent $DataHome
$patchScript = Join-Path $dataDir 'patch-runtime-tree.mjs'
$checker     = Join-Path $Tools 'check-runtime-patches.mjs'
$applier     = Join-Path $Tools 'apply-runtime-patches.mjs'
if (-not (Test-Path -LiteralPath $patchScript) -or -not (Test-Path -LiteralPath $checker)) {
    Write-Warn2 '未找到 patch-runtime-tree.mjs / check-runtime-patches.mjs，跳过补丁门禁'
} else {
    $raw = (Invoke-Native { & (Join-Path $Stage 'node.exe') $checker $patchScript $Stage $dataDir }) | Out-String
    $idx = $raw.IndexOf('{')
    if ($idx -lt 0) { Write-Warn2 '补丁检查器没有输出，跳过'; }
    else {
        $chk = $raw.Substring($idx) | ConvertFrom-Json
        if ($chk.totalAnchors -gt 0 -and $chk.appliedAnchors -eq $chk.totalAnchors) {
            Write-Warn2 ("暂存运行时是干净态：锚点 " + $chk.appliedAnchors + "/" + $chk.totalAnchors + " 全未打（会让 UI 退回原版）")
            if ($ApplyRuntimePatches -and -not ($DryRun -or $Analyze)) {
                $raw2 = (Invoke-Native { & (Join-Path $Stage 'node.exe') $applier $patchScript $Stage $dataDir }) | Out-String
                $idx2 = $raw2.IndexOf('{')
                $ap = if ($idx2 -ge 0) { $raw2.Substring($idx2) | ConvertFrom-Json } else { $null }
                if ($script:LastNativeExit -eq 0 -and $ap -and $ap.written) {
                    Write-Ok ('本地补丁已应用到暂存运行时：' + $ap.sectionsApplied.Count + ' 个小节')
                } else { Write-Bad '本地补丁应用失败（未写回），中止升级'; $patchGateOk = $false }
            } else {
                Write-Bad '暂存运行时未打本地补丁：直接交换会丢失本机 UI 定制。加 -ApplyRuntimePatches，或先手工应用'
                $patchGateOk = $false
            }
        } else {
            $themeF  = Join-Path $Stage 'node_modules\@deepseek-ai\dsh-client-ui-theme\lib\client.js'
            $layoutF = Join-Path $Stage 'node_modules\@deepseek-ai\dsh-client-ui-layout\lib\client.js'
            $marks = 0
            if (Test-Path -LiteralPath $themeF)  { $tt = [System.IO.File]::ReadAllText($themeF, $Utf8NoBom);  if ($tt.Contains('DEFAULT_PREFERENCE = "dark"')) { $marks++ } }
            if (Test-Path -LiteralPath $layoutF) { $lt = [System.IO.File]::ReadAllText($layoutF, $Utf8NoBom); if ($lt.Contains('svcDot_root')) { $marks++ }; if ($lt.Contains('skipLink')) { $marks++ } }
            if ($marks -eq 3) { Write-Ok '暂存运行时已带本地补丁（暗色默认 + 服务状态点 + skip-link 齐备）' }
            else { Write-Warn2 ('暂存运行时补丁痕迹只找到 ' + $marks + '/3，建议复跑 check-runtime-patches.mjs 人工确认'); $patchGateOk = $false }
        }
    }
}

if ($Analyze) { Write-Host ''; Write-Ok '分析模式结束（未改动任何文件）'; exit 0 }

# ============================================================ P3 全局适配（本地包 peer 放宽）
Write-Step 'P3 全局适配：本地 link/file 包的 peer 上界放宽'
$pkg = Read-Json (Join-Path $Profile 'package.json')
$applyLocal = -not ($DryRun -or $StageOnly)   # 演练模式只报告、不写入
$hasLocalPatches = ($Config.localPeerPatches -ne $null) -and (@($Config.localPeerPatches.PSObject.Properties).Count -gt 0)
if ($hasLocalPatches) {
    foreach ($p in $Config.localPeerPatches.PSObject.Properties) {
        $name = $p.Name; $from = [string]$p.Value.from; $to = [string]$p.Value.to
        $spec = [string]$pkg.dependencies.$name
        if (-not $spec) { Write-Warn2 ($name + ' 不在 profile 依赖里，跳过'); continue }
        $localPath = ($spec -replace '^(link:|file:)', '')
        $manifest = Join-Path $localPath 'package.json'
        if (-not (Test-Path -LiteralPath $manifest)) { Write-Warn2 ($name + ' 本地目录不存在：' + $localPath); continue }
        $text = [System.IO.File]::ReadAllText($manifest, $Utf8NoBom)
        if (-not $text.Contains($from)) {
            if ($text.Contains($to)) { Write-Ok ($name + ' 已是放宽后的范围，跳过') } else { Write-Warn2 ($name + ' 未找到待替换范围：' + $from) }
            continue
        }
        $count = ([regex]::Matches($text, [regex]::Escape($from))).Count
        if (-not $applyLocal) { Write-Warn2 ($name + ' 待放宽 ' + $count + ' 条 peer（演练模式，未写入）'); continue }
        Copy-Item -LiteralPath $manifest -Destination ($manifest + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
        [System.IO.File]::WriteAllText($manifest, $text.Replace($from, $to), $Utf8NoBom)
        Write-Ok ($name + ' 已放宽 ' + $count + ' 条 peer：' + $from + ' → ' + $to)
    }
} else { Write-Host '   配置未定义本地补丁，跳过' -ForegroundColor DarkGray }

# ============================================================ DryRun 到此为止
if ($DryRun -or $StageOnly) {
    Write-Host ''
    Write-Step '计划（本次未改动 runtime / profile）'
    Write-Host ('   1) 备份 profile 关键文件 → launcher-backup\profile-upgrade-<时间戳>')
    Write-Host ('   2) runtime\ → runtime-backup-' + $cur + '-<时间戳>；' + $StageDir + '\ → runtime\')
    if ($Config.bundlesToAdd) { Write-Host ('   3) bundles 补：' + ($Config.bundlesToAdd -join ', ')) }
    if ($hasLocalPatches) { Write-Host ('   3b) 本地包 peer 放宽：' + (($Config.localPeerPatches.PSObject.Properties | ForEach-Object { $_.Name }) -join ', ')) }
    if ($upgradeProps.Count -gt 0) { Write-Host ('   4) 插件升版：' + (($upgradeProps | ForEach-Object { $_.Name + '@' + $_.Value }) -join ', ')) }
    if ($Config.exemptionsToRevoke) { Write-Host ('   5) 撤销豁免：' + ($Config.exemptionsToRevoke -join ', ')) }
    if ($Config.exemptions) { Write-Host ('   6) 授予豁免：' + ($Config.exemptions -join ', ')) }
    Write-Host '   6b) 本地 UI 补丁门禁（-ApplyRuntimePatches 可在暂存区自动应用）'
    Write-Host '   7) 组合树断言（0 跳过 + assertContains），失败自动回滚'
    if (-not $NoStart) { Write-Host '   8) 启动一键启动器并轮询 3080' }
    Write-Host ''
    if ($uncovered.Count) { Write-Warn2 '注意：仍有未覆盖项（见 P2）' }
    Write-Ok '结束（未改动任何文件）'
    exit 0
}

if ($hostRunning) { Write-Bad '宿主仍在运行，请先关闭启动器窗口再重试。'; exit 2 }
if (-not $patchGateOk) { Write-Bad '本地运行时补丁门禁未通过，已停止（未做任何改动）。'; exit 2 }

# ============================================================ P4 备份 + 交换
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runtimeBackup = Join-Path $Root ('runtime-backup-' + $cur + '-' + $stamp)
$profileBackup = Join-Path $Root ('launcher-backup\profile-upgrade-' + $stamp)
$state = [pscustomobject]@{
    StartedAt = (Get-Date).ToString('o'); FromVersion = $cur; ToVersion = $Config.targetVersion
    RuntimeBackup = $runtimeBackup; ProfileBackup = $profileBackup; Finished = $false
}

Write-Step ('P4 备份 profile 关键文件 → ' + (Split-Path -Leaf $profileBackup))
New-Item -ItemType Directory -Path $profileBackup -Force | Out-Null
foreach ($f in @('package.json', 'pnpm-lock.yaml', 'compatibility.json', 'cordis.patch.yml')) {
    $src = Join-Path $Profile $f
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $profileBackup $f) -Force }
}
Save-State $state $StatePath
Write-Ok '已备份并写入状态文件'

Write-Step 'P4 交换内置运行时'
Move-Item -LiteralPath $Runtime -Destination $runtimeBackup
Move-Item -LiteralPath $Stage -Destination $Runtime
Write-Ok ('runtime 现在是 ' + (Get-DshVersion $Runtime) + '；旧版保存为 ' + (Split-Path -Leaf $runtimeBackup))

# ============================================================ P5 profile 变更
Write-Step 'P5 profile 变更'
$dshExe = Join-Path $Runtime 'node.exe'
$dshBin = Join-Path $Runtime 'node_modules\@deepseek-ai\dsh\lib\bin.js'

if ($Config.bundlesToAdd) {
    $pkgPath = Join-Path $Profile 'package.json'
    $text = [System.IO.File]::ReadAllText($pkgPath, $Utf8NoBom)
    foreach ($bundle in $Config.bundlesToAdd) {
        if ($text.Contains('"' + $bundle + '"')) { Write-Ok ($bundle + ' 已在 bundles 里'); continue }
        $anchor = '"@deepseek-ai/dsh-web-app",'
        $bundlesIdx = $text.IndexOf('"bundles"')
        if ($bundlesIdx -ge 0) { $idx = $text.IndexOf($anchor, $bundlesIdx) } else { $idx = -1 }
        if ($idx -lt 0) { Write-Bad ('找不到锚点 ' + $anchor + '，无法插入 ' + $bundle); Invoke-Rollback $state | Out-Null; exit 1 }
        $lineStart = $text.LastIndexOf("`n", $idx) + 1
        $indent = $text.Substring($lineStart, $idx - $lineStart) -replace "[`r`n]", ""
        $text = $text.Insert($idx + $anchor.Length, "`r`n" + $indent + '"' + $bundle + '",')
        Write-Ok ('bundles 已补 ' + $bundle)
    }
    [System.IO.File]::WriteAllText($pkgPath, $text, $Utf8NoBom)
}

$upgradeProps = if ($Config.packageUpgrades -ne $null) { @($Config.packageUpgrades.PSObject.Properties) } else { @() }
if ($upgradeProps.Count -gt 0) {
    $list = @()
    foreach ($p in $upgradeProps) { $list += ($p.Name + '@' + $p.Value) }
    Push-Location $Profile
    try { $out = Invoke-Native { & $pnpmCmd.Source add @list }; $rc = $script:LastNativeExit } finally { Pop-Location }
    $out | Select-Object -Last 6 | ForEach-Object { Write-Host ('      ' + $_) }
    if ($rc -ne 0) { Write-Bad ('pnpm add 失败（退出码 ' + $rc + '），回滚'); Invoke-Rollback $state | Out-Null; exit 1 }
    Write-Ok ('已升版：' + ($list -join ', '))
}

foreach ($e in @($Config.exemptionsToRevoke)) {
    if (-not $e) { continue }
    $out = Invoke-Native { & $dshExe $dshBin plugin --profile web revoke-version $e --dsh-version $Config.targetVersion }
    $out | ForEach-Object { Write-Host ('      ' + $_) }
    Write-Ok ('已撤销豁免 ' + $e)
}
foreach ($e in @($Config.exemptions)) {
    if (-not $e) { continue }
    $out = Invoke-Native { & $dshExe $dshBin plugin --profile web allow-version $e --dsh-version $Config.targetVersion --accept-risk }
    $out | ForEach-Object { Write-Host ('      ' + $_) }
    Write-Ok ('已授予豁免 ' + $e)
}

# ============================================================ P6 断言
Write-Step 'P6 组合树断言'
$v = Test-Composition $Runtime $Config
if ($v.Skips.Count) { Write-Bad ('仍被跳过：' + ($v.Skips -join ', ')) } else { Write-Ok '0 个 bundle 被跳过' }
if ($v.Missing.Count) { Write-Bad ('缺失条目：' + ($v.Missing -join ', ')) } else { Write-Ok '关键条目齐全' }
if ($v.Skips.Count -or $v.Missing.Count) {
    Write-Host ''
    Invoke-Rollback $state | Out-Null
    exit 1
}

# --- P6.6 维护链（仅生产模式；沙箱跳过，避免在真实 profile 上动作）---
if ($isProduction -and -not $SkipMaintain) {
    $maintainScript = Join-Path (Split-Path -Parent $DataHome) 'maintain.ps1'
    if (Test-Path -LiteralPath $maintainScript) {
        Write-Step 'P6.6 维护链（maintain.ps1 -Update，非致命）'
        $mOut = Invoke-Native { & powershell -NoProfile -ExecutionPolicy Bypass -File $maintainScript -Update }
        $mOut | Out-File -LiteralPath (Join-Path $LogDir ('升级DSH-' + $Config.targetVersion + '-maintain.log')) -Encoding UTF8
        if ($script:LastNativeExit -eq 0) { Write-Ok '维护链完成（插件层已按新宿主对齐）' }
        else { Write-Warn2 ('维护链退出码 ' + $script:LastNativeExit + '（非致命，可稍后手动跑 维护DeepSeek-Harness.cmd -Update）') }
    } else {
        Write-Warn2 '未找到 maintain.ps1，跳过维护链'
    }
}

$state.Finished = $true
Save-State $state $StatePath
Write-Host ''
Write-Ok ('升级完成：' + $cur + ' → ' + (Get-DshVersion $Runtime))
Write-Host ('   旧版运行时：' + (Split-Path -Leaf $runtimeBackup)) -ForegroundColor DarkGray
Write-Host ('   profile 备份：' + $profileBackup) -ForegroundColor DarkGray
Write-Host ('   回滚：.\升级DSH运行时.ps1 -Rollback -ConfigPath "' + $ConfigPath + '"') -ForegroundColor DarkGray

if ($NoStart) { exit 0 }

# ============================================================ P7 启动 + 就绪
Write-Step 'P7 启动并等待就绪'
Start-Process -FilePath $Launcher
$deadline = (Get-Date).AddSeconds(180)
$ready = $false
while ((Get-Date) -lt $deadline) { Start-Sleep -Seconds 2; if (Test-Listening 3080) { $ready = $true; break } }
if ($ready) { Write-Ok '3080 已就绪' } else { Write-Warn2 '180 秒内未见就绪，请查看启动器窗口；必要时 -Rollback' }
