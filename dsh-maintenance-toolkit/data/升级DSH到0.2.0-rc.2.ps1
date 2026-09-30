# DeepSeek Harness 内置运行时升级：0.1.7-rc.2 → 0.2.0-rc.2（无损 + 可回滚）
#
# 为什么必须用它、而不是启动器的 -UpgradeDsh：
#   启动器实际运行的宿主是内置运行时 runtime\（runtime\dsh.cmd 优先于 PATH 与 npm 全局），
#   而 -UpgradeDsh 执行的是 npm install -g，装到 %APPDATA%\npm，宿主版本不会变。
#   本脚本直接把暂存区 runtime-next\（已验证的 0.2.0-rc.2）换到 runtime\ 位置。
#
# 用法（宿主必须已停止：先关掉一键启动器窗口，或运行 一键启动DeepSeek-Harness.bat -Stop）：
#   .\升级DSH到0.2.0-rc.2.ps1 -DryRun     只做前置检查并打印计划，不改任何东西
#   .\升级DSH到0.2.0-rc.2.ps1             执行升级（含插件适配、组合树验证、失败自动回滚）
#   .\升级DSH到0.2.0-rc.2.ps1 -NoStart    同上，但升级完不自动启动服务
#   .\升级DSH到0.2.0-rc.2.ps1 -Rollback   用最近一次的状态文件回滚
#
# 升级内容（全部已在 3099 暂存宿主上实测通过）：
#   1. runtime\  ← runtime-next\（@deepseek-ai/dsh 0.2.0-rc.2，内置 node v26.10.0 + npm 11.19.1）
#   2. profile bundles 增加 @deepseek-ai/dsh-experimental-schedule-bundle
#      （0.2.0 把 time-context / schedule / ui-schedule 移出了默认 Web 组合，必须显式加回）
#   3. dsh-better-sidebar → 0.24.1、dsh-session-insights → 0.5.1（两者原生兼容 0.2.0）
#   4. 撤销 0.5.0 的豁免，并为 0.5.1 开精确豁免（它 pin 0.2.0-rc.1，而宿主是 rc.2）
#   5. 组合树断言：0 个 skipping profile bundle + schedule 三件套在册
#
# 已授予的精确豁免（用户已确认风险，写入 profile 的 compatibility.json）：
#   dsh-session-insights@0.5.1、dsh-context-doctor@0.7.2、@loserfox/distill@0.1.0 → 可用 0.2.0-rc.2
#   （这两个插件上游仍为 0.1.x，升无可升）
# 本地适配：deepseek-idesign 的 4 条 peer 范围已放宽为 <0.3.0-0（原包备份在同目录 package.json.bak-*）
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Rollback,
    [switch]$NoStart,
    # 升级完成后跳过维护链（maintain.ps1 -Update）
    [switch]$SkipMaintain
)

$ErrorActionPreference = 'Stop'

# 脚本可放在数据目录里：向上探测启动器根目录（含 runtime\ 与数据目录的目录）作为路径锚点
$Root = $PSScriptRoot
while ($true) {
    if ((Test-Path -LiteralPath (Join-Path $Root 'runtime')) -and
        (Test-Path -LiteralPath (Join-Path $Root 'deepseek-Harness插件及其数据'))) { break }
    $parent = Split-Path -Parent $Root
    if (-not $parent -or $parent -eq $Root) { break }
    $Root = $parent
}
$Runtime   = Join-Path $Root 'runtime'
$Staging   = Join-Path $Root 'runtime-next'
$DataHome  = Join-Path $Root 'deepseek-Harness插件及其数据\dsh-home'
$Profile   = Join-Path $DataHome 'profiles\web'
# 显式设置 DSH_HOME：从资源管理器双击 .cmd 运行时，用户环境里可能没有这个变量；
# 不设置的话 dsh 会去定位 %USERPROFILE%\.dsh 这个**错误的** profile，
# 导致豁免写入与组合树断言全部打在别处。
$env:DSH_HOME = $DataHome
$Launcher  = Join-Path $Root '一键启动DeepSeek-Harness.bat'
$LogDir    = Join-Path $Root 'logs'
$StatePath = Join-Path $LogDir '升级DSH-0.2.0-rc.2.state.json'
$NewVer    = '0.2.0-rc.2'
$OldVer    = '0.1.7-rc.2'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Utf8Bom   = New-Object System.Text.UTF8Encoding($true)

function Write-Step($m)  { Write-Host ("== " + $m) -ForegroundColor Cyan }
function Write-Ok($m)    { Write-Host ("   OK  " + $m) -ForegroundColor Green }
function Write-Warn2($m) { Write-Host ("   !   " + $m) -ForegroundColor Yellow }
function Write-Bad($m)   { Write-Host ("   X   " + $m) -ForegroundColor Red }

function Test-Listening([int]$Port) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { $c.Connect('127.0.0.1', $Port); return $true } catch { return $false } finally { $c.Dispose() }
}

# 原生调用统一入口：dsh / pnpm 会把告警写到 stderr，而 ErrorActionPreference=Stop
# 会把 stderr 记录升级成终止错误，导致脚本误判失败。这里临时降级并把退出码带出来。
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

function Get-DshVersion([string]$RuntimeDir) {
    $p = Join-Path $RuntimeDir 'node_modules\@deepseek-ai\dsh\package.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return ([System.IO.File]::ReadAllText($p, $Utf8NoBom) | ConvertFrom-Json).version
}

function Invoke-Dsh([string]$RuntimeDir, [string[]]$DshArgs) {
    $node = Join-Path $RuntimeDir 'node.exe'
    $bin  = Join-Path $RuntimeDir 'node_modules\@deepseek-ai\dsh\lib\bin.js'
    $out  = Invoke-Native { & $node $bin @DshArgs }
    return ($out | Out-String)
}

function Get-CompositionCheck([string]$RuntimeDir) {
    $text  = Invoke-Dsh $RuntimeDir @('--profile', 'web', '--dump-config')
    $skips = @([regex]::Matches($text, 'skipping profile bundle "([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    $need  = @('@linxin666/dsh-web-all', 'web-ui-task-board', '- id: time-context', '- id: schedule', '- id: ui-schedule')
    $missing = @()
    foreach ($n in $need) { if (-not $text.Contains($n)) { $missing += $n } }
    return [pscustomobject]@{ Skips = $skips; Missing = $missing; Text = $text }
}

function Save-State($State) {
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($StatePath, ($State | ConvertTo-Json -Depth 6), $Utf8Bom)
}

function Read-State {
    if (-not (Test-Path -LiteralPath $StatePath)) { throw "找不到状态文件：$StatePath" }
    return ([System.IO.File]::ReadAllText($StatePath, $Utf8NoBom) | ConvertFrom-Json)
}

function Restore-ProfileFiles($State) {
    if (-not $State.ProfileBackup) { Write-Warn2 '状态里没有 profile 备份目录'; return }
    if (-not (Test-Path -LiteralPath $State.ProfileBackup)) { Write-Warn2 ("profile 备份目录不存在：" + $State.ProfileBackup); return }
    foreach ($f in @('package.json', 'pnpm-lock.yaml', 'compatibility.json', 'cordis.patch.yml')) {
        $src = Join-Path $State.ProfileBackup $f
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $Profile $f) -Force
            Write-Ok ("已还原 " + $f)
        }
    }
}

function Invoke-Rollback($State) {
    Write-Step '回滚到升级前状态'
    if (Test-Listening 3080) { Write-Bad '宿主仍在运行（3080 被占用），请先停止服务再回滚。'; return $false }

    $restored = $false
    if ($State.RuntimeBackup -and (Test-Path -LiteralPath $State.RuntimeBackup)) {
        $broken = Join-Path $Root ("runtime.broken-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        if (Test-Path -LiteralPath $Runtime) { Move-Item -LiteralPath $Runtime -Destination $broken }
        Move-Item -LiteralPath $State.RuntimeBackup -Destination $Runtime
        Write-Ok ("runtime 已还原为 " + (Get-DshVersion $Runtime) + "（0.2.0 挪到 " + (Split-Path -Leaf $broken) + "）")
        $restored = $true
    } else {
        Write-Warn2 '状态里没有可用的 runtime 备份，跳过运行时还原'
    }

    Restore-ProfileFiles $State

    $pnpm = Get-Command pnpm.cmd -ErrorAction SilentlyContinue
    if ($pnpm) {
        Write-Step '按还原后的 package.json 重装 profile 依赖（恢复旧版插件）'
        Push-Location $Profile
        $rbOut = Invoke-Native { & $pnpm.Source install }
        $rbOut | Select-Object -Last 6 | ForEach-Object { Write-Host ("      " + $_) }
        Pop-Location
        Write-Ok 'profile 依赖已按旧版清单重装'
    } else {
        Write-Warn2 '未找到 pnpm.cmd；请手动执行：pnpm -C "' + $Profile + '" install'
    }
    return $restored
}

Write-Host '============================================' -ForegroundColor DarkCyan
Write-Host ('  DSH 内置运行时升级  ' + $OldVer + ' → ' + $NewVer) -ForegroundColor DarkCyan
Write-Host '============================================' -ForegroundColor DarkCyan
Write-Host ''

# ---------------------------------------------------------------- 回滚模式
if ($Rollback) {
    $state = Read-State
    $ok = Invoke-Rollback $state
    Write-Host ''
    if ($ok) { Write-Ok '回滚完成。重新双击一键启动器即回到旧版。' } else { Write-Bad '回滚未完全成功，请看上面的提示。' }
    if (-not $NoStart -and $ok) { Start-Process -FilePath $Launcher }
    exit $(if ($ok) { 0 } else { 1 })
}

# ---------------------------------------------------------------- 前置检查
Write-Step '前置检查'
Write-Ok ('DSH_HOME = ' + $env:DSH_HOME)
$checksFailed = $false

if (-not (Test-Path -LiteralPath $Runtime)) { Write-Bad ('缺少 ' + $Runtime); $checksFailed = $true }
else { $curVer = Get-DshVersion $Runtime; Write-Ok ("当前 runtime 版本 = " + $curVer) }

if (-not (Test-Path -LiteralPath $Staging)) { Write-Bad ('缺少暂存区 ' + $Staging + '（应先完成 0.2.0-rc.2 的安装与验证）'); $checksFailed = $true }
else {
    $stageVer = Get-DshVersion $Staging
    if ($stageVer -eq $NewVer) { Write-Ok ('暂存区版本 = ' + $stageVer) }
    else { Write-Bad ('暂存区版本是 ' + $stageVer + '，期望 ' + $NewVer); $checksFailed = $true }
}

if (-not (Test-Path -LiteralPath (Join-Path $Profile 'package.json'))) { Write-Bad ('找不到 profile：' + $Profile); $checksFailed = $true }
else { Write-Ok ('profile = ' + $Profile) }

$pnpmCmd = Get-Command pnpm.cmd -ErrorAction SilentlyContinue
if ($pnpmCmd) { Write-Ok ('pnpm = ' + $pnpmCmd.Source) } else { Write-Bad '未找到 pnpm.cmd（升级插件需要它）'; $checksFailed = $true }

$d = New-Object System.IO.DriveInfo((Split-Path -Qualifier $Root).TrimEnd(':'))
$freeGB = [math]::Round($d.AvailableFreeSpace / 1GB, 1)
if ($freeGB -lt 3) { Write-Bad ('磁盘可用仅 ' + $freeGB + ' GB，交换运行时需要空间'); $checksFailed = $true }
else { Write-Ok ('磁盘可用 ' + $freeGB + ' GB') }

$hostRunning = Test-Listening 3080
if ($hostRunning) { Write-Warn2 '检测到 3080 正在监听：宿主还在运行，升级会被中止（请先关掉启动器窗口）' }
else { Write-Ok '宿主已停止（3080 空闲）' }

if ($checksFailed) { Write-Host ''; Write-Bad '前置检查未通过，未做任何改动。'; exit 2 }

# ---------------------------------------------------------------- 演练模式
if ($DryRun) {
    Write-Host ''
    Write-Step '演练模式：以下是将要执行的步骤（本次未改动任何文件）'
    Write-Host '   0) 本地 UI 补丁门禁（暂存运行时必须已带本机补丁，否则中止）'
    Write-Host '   1) 备份 profile 的 package.json / pnpm-lock.yaml / compatibility.json / cordis.patch.yml'
    Write-Host ('   2) runtime\ → runtime-backup-' + $OldVer + '-<时间戳>；runtime-next\ → runtime\')
    Write-Host '   3) package.json 的 dsh.profile.bundles 加入 @deepseek-ai/dsh-experimental-schedule-bundle'
    Write-Host '   4) pnpm add dsh-better-sidebar@0.24.1 dsh-session-insights@0.5.1'
    Write-Host '   5) 撤销 0.5.0 豁免并为 0.5.1 开精确豁免（peer 精确 pin 0.2.0-rc.1）'
    Write-Host '   6) 组合树断言（0 跳过 + schedule 三件套 + 家族包挂载），失败自动回滚'
    Write-Host '   6.6) 运行维护链 maintain.ps1 -Update（插件层按新宿主对齐，失败不致命）'
    if (-not $NoStart) { Write-Host '   7) 启动一键启动器并轮询 3080 就绪' }
    Write-Host ''
    Write-Host ('当前暂存区组合树预检（用 ' + $NewVer + ' 跑，未改动 profile）：') -ForegroundColor DarkGray
    $pre = Get-CompositionCheck $Staging
    Write-Host ('   跳过 bundle：' + $(if ($pre.Skips.Count -eq 0) { '无' } else { ($pre.Skips -join ', ') }))
    Write-Host ('   缺失要点：' + $(if ($pre.Missing.Count -eq 0) { '无' } else { ($pre.Missing -join ', ') }))
    Write-Host ''
    Write-Ok '演练结束（未改动任何文件）'
    exit 0
}

if ($hostRunning) { Write-Host ''; Write-Bad '宿主仍在运行，请先停止（关闭启动器窗口）后重试。'; exit 2 }

# 本地 UI 补丁门禁：runtime 里带本机私有补丁（挽具框架 CSS / 暗色默认 / 服务状态点 / skip-link），
# 干净的 npm 运行时没有这些；换上去 UI 会退回原版，所以交换前必须确认。
Write-Step '0/6 本地 UI 补丁门禁'
$themeF  = Join-Path $Staging 'node_modules\@deepseek-ai\dsh-client-ui-theme\lib\client.js'
$layoutF = Join-Path $Staging 'node_modules\@deepseek-ai\dsh-client-ui-layout\lib\client.js'
$marks = 0
$markNames = @()
if (Test-Path -LiteralPath $themeF) {
    if ([System.IO.File]::ReadAllText($themeF, $Utf8NoBom).Contains('DEFAULT_PREFERENCE = "dark"')) { $marks++; $markNames += '暗色默认' }
}
if (Test-Path -LiteralPath $layoutF) {
    $layoutText = [System.IO.File]::ReadAllText($layoutF, $Utf8NoBom)
    if ($layoutText.Contains('svcDot_root')) { $marks++; $markNames += '服务状态点' }
    if ($layoutText.Contains('skipLink'))   { $marks++; $markNames += 'skip-link' }
}
if ($marks -eq 3) {
    Write-Ok ('暂存运行时已带本地 UI 补丁：' + ($markNames -join ' / '))
} else {
    Write-Bad ('暂存运行时的本地补丁痕迹只有 ' + $marks + '/3，交换会让 UI 退回原版。')
    Write-Host '   修复：node tools\apply-runtime-patches.mjs "<数据目录>\patch-runtime-tree.mjs" runtime-next "<数据目录>"' -ForegroundColor Yellow
    Write-Host '   或用通用引擎：.\升级DSH运行时.ps1 -StageOnly -ApplyRuntimePatches' -ForegroundColor Yellow
    exit 2
}

# ---------------------------------------------------------------- 正式升级
$stamp         = Get-Date -Format 'yyyyMMdd-HHmmss'
$runtimeBackup = Join-Path $Root ('runtime-backup-' + $OldVer + '-' + $stamp)
$profileBackup = Join-Path $Root ('launcher-backup\profile-upgrade-' + $stamp)

$state = [pscustomobject]@{
    StartedAt      = (Get-Date).ToString('o')
    FromVersion    = $curVer
    ToVersion      = $NewVer
    RuntimeBackup  = $runtimeBackup
    ProfileBackup  = $profileBackup
    BundlesEdited  = $false
    PluginsUpgraded = $false
    ExemptionRevoked = $false
    Finished       = $false
}

Write-Step ('1/6 备份 profile 关键文件 → ' + (Split-Path -Leaf $profileBackup))
New-Item -ItemType Directory -Path $profileBackup -Force | Out-Null
foreach ($f in @('package.json', 'pnpm-lock.yaml', 'compatibility.json', 'cordis.patch.yml')) {
    $src = Join-Path $Profile $f
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $profileBackup $f) -Force }
}
Save-State $state
Write-Ok '已备份并写入状态文件（回滚依据）'

Write-Step '2/6 交换内置运行时'
Move-Item -LiteralPath $Runtime -Destination $runtimeBackup
Move-Item -LiteralPath $Staging -Destination $Runtime
Write-Ok ('runtime 现在是 ' + (Get-DshVersion $Runtime) + '；旧版保存在 ' + (Split-Path -Leaf $runtimeBackup))

Write-Step '3/6 把实验 schedule bundle 加进 profile bundles'
$pkgPath = Join-Path $Profile 'package.json'
$pkgText = [System.IO.File]::ReadAllText($pkgPath, $Utf8NoBom)
$needle  = 'dsh-experimental-schedule-bundle'
if ($pkgText.Contains($needle)) {
    Write-Warn2 'bundles 里已存在，跳过'
} else {
    $anchor = '"@deepseek-ai/dsh-web-app",'
    $bundlesIdx = $pkgText.IndexOf('"bundles"')
    if ($bundlesIdx -ge 0) { $idx = $pkgText.IndexOf($anchor, $bundlesIdx) } else { $idx = -1 }
    if ($idx -lt 0) { Write-Bad '在 package.json 的 bundles 数组里找不到锚点 "@deepseek-ai/dsh-web-app",，无法安全插入'; Invoke-Rollback $state | Out-Null; exit 1 }
    $lineStart = $pkgText.LastIndexOf("`n", $idx) + 1
    $indent = $pkgText.Substring($lineStart, $idx - $lineStart) -replace "[`r`n]", ""
    $insertAt = $idx + $anchor.Length
    $newLine = "`r`n" + $indent + '"@deepseek-ai/dsh-experimental-schedule-bundle",'
    $pkgText = $pkgText.Insert($insertAt, $newLine)
    [System.IO.File]::WriteAllText($pkgPath, $pkgText, $Utf8NoBom)
    $state.BundlesEdited = $true
    Save-State $state
    Write-Ok '已插入 @deepseek-ai/dsh-experimental-schedule-bundle'
}

Write-Step '4/6 升级两个插件到 0.2.x 原生兼容版'
Push-Location $Profile
try {
    $pnpmOut = Invoke-Native { & $pnpmCmd.Source add 'dsh-better-sidebar@0.24.1' 'dsh-session-insights@0.5.1' }
    $pnpmRc = $script:LastNativeExit
} finally { Pop-Location }
$pnpmOut | Select-Object -Last 8 | ForEach-Object { Write-Host ('      ' + $_) }
if ($pnpmRc -ne 0) {
    Write-Bad ('pnpm add 失败（退出码 ' + $pnpmRc + '），开始回滚')
    Invoke-Rollback $state | Out-Null
    exit 1
}
$state.PluginsUpgraded = $true
Save-State $state
Write-Ok 'better-sidebar → 0.24.1，session-insights → 0.5.1'

Write-Step '5/6 豁免调整：撤销 0.5.0，并为 0.5.1 开精确豁免'
$dshExe = Join-Path $Runtime 'node.exe'
$dshBin = Join-Path $Runtime 'node_modules\@deepseek-ai\dsh\lib\bin.js'
$revokeOut = Invoke-Native { & $dshExe $dshBin plugin --profile web revoke-version 'dsh-session-insights@0.5.0' --dsh-version $NewVer }
$revokeOut | ForEach-Object { Write-Host ('      ' + $_) }
# session-insights 0.5.1 的 peer 精确 pin 的是 0.2.0-rc.1，而本机宿主是 0.2.0-rc.2；
# 宿主门按精确版本比对会判不兼容。它已面向 0.2.x API，故按精确版本开豁免（用户已确认风险）。
$allowOut = Invoke-Native { & $dshExe $dshBin plugin --profile web allow-version 'dsh-session-insights@0.5.1' --dsh-version $NewVer --accept-risk }
$allowOut | ForEach-Object { Write-Host ('      ' + $_) }
$state.ExemptionRevoked = $true
Save-State $state
Write-Ok '已撤销 0.5.0 豁免，并授予 0.5.1 精确豁免'

Write-Step '6/6 组合树断言'
$check = Get-CompositionCheck $Runtime
if ($check.Skips.Count -gt 0) { Write-Bad ('仍被跳过的 bundle：' + ($check.Skips -join ', ')) }
else { Write-Ok '0 个 bundle 被跳过' }
if ($check.Missing.Count -gt 0) { Write-Bad ('组合树缺失：' + ($check.Missing -join ', ')) }
else { Write-Ok '家族包 + schedule 三件套均在册' }

if ($check.Skips.Count -gt 0 -or $check.Missing.Count -gt 0) {
    Write-Host ''
    Write-Bad '验证未通过，自动回滚'
    Invoke-Rollback $state | Out-Null
    exit 1
}

# --- P6.5 插件级适配重放 ---
# pnpm add 会重装插件包，可能把本机的插件级适配（pet 404 抑制、whale-widget AudioContext、
# link: 插件的绝对 junction）重置掉；apply-adaptations.ps1 是幂等的，重放一遍即可。
$adaptScript = Join-Path (Split-Path -Parent $DataHome) 'apply-adaptations.ps1'
if (Test-Path -LiteralPath $adaptScript) {
    Write-Step '6.5/6 重放插件级适配（apply-adaptations.ps1，幂等）'
    $adaptLog = Join-Path $LogDir '升级DSH-0.2.0-rc.2-adapt.log'
    $adaptOut = Invoke-Native { & powershell -NoProfile -ExecutionPolicy Bypass -File $adaptScript }
    $adaptOut | Out-File -LiteralPath $adaptLog -Encoding UTF8
    if ($script:LastNativeExit -eq 0) { Write-Ok '插件级适配已重放（pet / whale-widget / link 软链）' }
    else { Write-Warn2 ('插件级适配重放未完全成功（退出码 ' + $script:LastNativeExit + '）；可稍后运行 维护DeepSeek-Harness.cmd -Fix，日志：' + $adaptLog) }
} else {
    Write-Warn2 '未找到 apply-adaptations.ps1，跳过插件级适配重放'
}

# --- P6.6 维护链：让插件层按**新宿主**对齐 ---
# 维护工具链已改为以「内置运行时」为准探测宿主（本次修复），所以这里直接跑即可：
# 它会带上正确的宿主版本、按该版本判定插件是否需要动，并产出报告。失败只告警、不回滚升级。
$maintainScript = Join-Path (Split-Path -Parent $DataHome) 'maintain.ps1'
if ($SkipMaintain) {
    Write-Host '已指定 -SkipMaintain，跳过维护链。' -ForegroundColor DarkGray
} elseif (Test-Path -LiteralPath $maintainScript) {
    Write-Step '6.6/6 运行维护链（maintain.ps1 -Update，非致命）'
    $maintLog = Join-Path $LogDir '升级DSH-0.2.0-rc.2-maintain.log'
    $maintOut = Invoke-Native { & powershell -NoProfile -ExecutionPolicy Bypass -File $maintainScript -Update }
    $maintOut | Out-File -LiteralPath $maintLog -Encoding UTF8
    if ($script:LastNativeExit -eq 0) { Write-Ok '维护链完成（插件层已按 0.2.0-rc.2 对齐）' }
    else { Write-Warn2 ('维护链退出码 ' + $script:LastNativeExit + '（非致命；可稍后手动跑 维护DeepSeek-Harness.cmd -Update，日志：' + $maintLog + '）') }
} else {
    Write-Warn2 '未找到 maintain.ps1，跳过维护链'
}

$state.Finished = $true
Save-State $state
Write-Host ''
Write-Ok ('升级完成：' + $curVer + ' → ' + (Get-DshVersion $Runtime))
Write-Host ('   旧版运行时备份：' + (Split-Path -Leaf $runtimeBackup)) -ForegroundColor DarkGray
Write-Host ('   profile 备份：' + $profileBackup) -ForegroundColor DarkGray
Write-Host ('   回滚命令：.\升级DSH到0.2.0-rc.2.ps1 -Rollback') -ForegroundColor DarkGray
Write-Host '   升级后插件维护：维护工具链已改为以「内置运行时」为准探测宿主（本次升级已同步修复）。' -ForegroundColor DarkGray
Write-Host '     日常：维护DeepSeek-Harness.cmd -Update   （自动带上正确宿主版本并透传）' -ForegroundColor DarkGray
Write-Host '     直接调 update-plugins.ps1 也可，-HostVersion 0.2.0-rc.2 现在是可选覆盖项。' -ForegroundColor DarkGray
Write-Host '   建议自检（不改动任何文件）：' -ForegroundColor DarkGray
Write-Host '     引擎：powershell -ExecutionPolicy Bypass -File .\升级DSH运行时.ps1 -VerifyOnly' -ForegroundColor DarkGray
Write-Host '     启动器：一键启动DeepSeek-Harness.bat -Doctor    /    -VerifyPlugins' -ForegroundColor DarkGray
Write-Host ''

if ($NoStart) {
    Write-Host '按要求未自动启动。双击 一键启动DeepSeek-Harness.bat 即可。' -ForegroundColor Yellow
    exit 0
}

Write-Step '启动一键启动器并等待就绪'
Start-Process -FilePath $Launcher
$deadline = (Get-Date).AddSeconds(180)
$ready = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    if (Test-Listening 3080) { $ready = $true; break }
}
Write-Host ''
if ($ready) { Write-Ok '3080 已就绪，升级完成（浏览器会自动打开带 token 的页面）' }
else { Write-Warn2 '180 秒内未见 3080 就绪，请查看启动器窗口；必要时用 -Rollback 回滚' }
