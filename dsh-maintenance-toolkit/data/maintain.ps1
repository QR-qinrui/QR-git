# =============================================================================
#  DeepSeek Harness 独立深度维护脚本（maintain.ps1）
#
#  职责：自检测 · 依赖补全 · 版本更新 · 诊断报告（独立于启动器，可单独运行）
#  定位：与启动器内嵌的轻量检测互补。启动器在启动时做轻量自检测告警，
#        本脚本负责深度维护：联网检查上游最新版本、补齐缺失依赖、执行更新。
#
#  用法（Windows PowerShell 5.1 / PowerShell 7 均兼容）：
#    powershell -ExecutionPolicy Bypass -File maintain.ps1             全量自检测 + 诊断报告（只读）
#    powershell -ExecutionPolicy Bypass -File maintain.ps1 -CheckUpdate  检查上游最新版本
#    powershell -ExecutionPolicy Bypass -File maintain.ps1 -Fix          自检测 + 自动补齐缺失依赖
#    powershell -ExecutionPolicy Bypass -File maintain.ps1 -Update       检查并执行更新（插件 + 主框架）
#    powershell -ExecutionPolicy Bypass -File maintain.ps1 -Report <路径> 将诊断报告导出到文件
#    powershell -ExecutionPolicy Bypass -File maintain.ps1 -Help         帮助
#    powershell -ExecutionPolicy Bypass -File maintain.ps1 -Update -HostVersion 0.2.0-rc.2
#                                         指定宿主版本（透传给插件更新工作流 update-plugins.ps1）
#
#  双击「维护DeepSeek-Harness.cmd」即可运行（.cmd 引导，避免 .ps1 被记事本打开）。
# =============================================================================
[CmdletBinding()]
param(
    [switch]$CheckUpdate,
    [switch]$Fix,
    [switch]$Update,
    [switch]$Report,
    [string]$ReportPath,
    [switch]$Help,
    # 宿主版本：留空则自动解析（显式参数 > 内置运行时 runtime\ > 环境变量 DSH_HOST_VERSION > 源码 checkout）
    [string]$HostVersion = '',
    # -Update 时跳过插件更新工作流（只想更新主框架时用）
    [switch]$SkipPluginUpdate
)

$ErrorActionPreference = 'Continue'
$OutputEncoding = [System.Text.Encoding]::UTF8

# -----------------------------------------------------------------------------
# 基础输出
# -----------------------------------------------------------------------------
function Write-Ok   { param([string]$Msg) Write-Host ('  [OK]   ' + $Msg) -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host ('  [WARN] ' + $Msg) -ForegroundColor Yellow }
function Write-Fail { param([string]$Msg) Write-Host ('  [FAIL] ' + $Msg) -ForegroundColor Red }
function Write-Info { param([string]$Msg) Write-Host ('  [..]   ' + $Msg) -ForegroundColor DarkGray }

$script:ReportLines = New-Object System.Collections.ArrayList
function Add-Report { param([string]$Line) [void]$script:ReportLines.Add($Line) }

# 宿主版本解析：插件层工具（update-plugins.ps1）原来会先读「源码 checkout」的版本，
# 宿主升级后会误判成旧版本，进而把插件挑回旧版。这里以**内置运行时**为准。
function Resolve-HostVersion {
    param([string]$Explicit)
    if ($Explicit -and $Explicit.Trim() -ne '') { return @{ Version = $Explicit.Trim(); Source = '参数 -HostVersion' } }
    $launcherDir = Split-Path -Parent $script:DataDir
    $rt = Join-Path $launcherDir 'runtime\node_modules\@deepseek-ai\dsh\package.json'
    if (Test-Path -LiteralPath $rt) {
        try {
            $v = ([System.IO.File]::ReadAllText($rt, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json).version
            if ($v) { return @{ Version = [string]$v; Source = '内置运行时 runtime\' } }
        } catch { }
    }
    if ($env:DSH_HOST_VERSION -and $env:DSH_HOST_VERSION.Trim() -ne '') { return @{ Version = $env:DSH_HOST_VERSION.Trim(); Source = '环境变量 DSH_HOST_VERSION' } }
    $src = Join-Path $script:DataDir 'deepseek-harness\package.json'
    if (Test-Path -LiteralPath $src) {
        try {
            $v = ([System.IO.File]::ReadAllText($src, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json).version
            if ($v) { return @{ Version = [string]$v; Source = '源码 checkout（可能滞后于运行时）' } }
        } catch { }
    }
    return @{ Version = '0.1.7-rc.2'; Source = '兜底默认值' }
}

function Write-Banner {
    Write-Host '================================================' -ForegroundColor DarkCyan
    Write-Host '   DeepSeek Harness 独立深度维护工具'
    Write-Host '   自检测 · 依赖补全 · 版本更新 · 诊断报告'
    Write-Host '================================================' -ForegroundColor DarkCyan
    Write-Host ''
}

# -----------------------------------------------------------------------------
# 路径自适配（与启动器保持一致）
# -----------------------------------------------------------------------------
# 本脚本位于「deepseek-Harness插件及其数据」目录内，启动器在上一级。
$script:DataDir   = $PSScriptRoot
$script:LauncherDir = [System.IO.Path]::GetFullPath((Join-Path $script:DataDir '..'))
$script:DshHome   = Join-Path $script:DataDir 'dsh-home'
$script:ProfilesRoot = Join-Path $script:DshHome 'profiles'
$script:DefaultPort  = 3080

# -----------------------------------------------------------------------------
# 自适配：探测 Node / npm / dsh
# -----------------------------------------------------------------------------
function Get-NodeExe {
    $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = New-Object System.Collections.ArrayList
    [void]$candidates.Add('D:\Ai相关软件程序\node.js本体')
    if ($env:ProgramFiles)        { [void]$candidates.Add((Join-Path $env:ProgramFiles 'nodejs')) }
    if (${env:ProgramFiles(x86)}) { [void]$candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'nodejs')) }
    if ($env:LOCALAPPDATA)        { [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\nodejs')) }
    try {
        $reg = Get-ItemProperty 'HKLM:\SOFTWARE\Node.js' -ErrorAction Stop
        if ($reg -and $reg.InstallPath) { [void]$candidates.Add($reg.InstallPath) }
    } catch {}
    foreach ($d in $candidates) {
        if (-not $d) { continue }
        $p = Join-Path $d 'node.exe'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Get-NpmCliJs {
    param([string]$NodeExePath)
    if (-not $NodeExePath) { return $null }
    $p = Join-Path (Split-Path -Parent $NodeExePath) 'node_modules\npm\bin\npm-cli.js'
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

# -----------------------------------------------------------------------------
# 版本比较（语义化版本：返回 1=左新, 0=相等, -1=右新）
# -----------------------------------------------------------------------------
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
            # 非数字段：rc < 正式版；字符串比较兜底
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
# 网络请求（返回 JSON 解析后的对象；失败返回 $null）
# -----------------------------------------------------------------------------
function Invoke-JsonGet {
    param([string]$Url, [int]$TimeoutSec = 15)
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        return ($r.Content | ConvertFrom-Json)
    } catch {
        return $null
    }
}

# -----------------------------------------------------------------------------
# 上游版本查询
#   - 主框架 deepseek-harness：GitHub tags（api.github.com），tag 格式 dsh-vX.Y.Z
#   - idesign：GitHub iPolloWork 仓库（无 tag 时回退 package.json version）
#   - chat-manager / open-in-tui：随主框架版本，无独立发布流
# -----------------------------------------------------------------------------
function Get-UpstreamVersions {
    $result = @{ Main = $null; MainSource = ''; Idesign = $null; IdesignSource = '' }

    # 主框架：GitHub tags
    $tags = Invoke-JsonGet 'https://api.github.com/repos/deepseek-ai/deepseek-harness/tags?per_page=30'
    if ($tags) {
        $latest = $null
        foreach ($t in $tags) {
            if ($t.name -match '^dsh-v([0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.\-]+)?)$') {
                $latest = $Matches[1]
                break
            }
        }
        if ($latest) {
            $result.Main = $latest
            $result.MainSource = 'github:deepseek-ai/deepseek-harness tags'
        }
    }

    # idesign：npm registry 的 dist-tags.latest（这是 deepseek-idesign 的权威发布版本源。
    # 注意：不能用 Devin-AXIS/iPolloWork 仓库的 tags —— 那是 iPolloWork 本体（v0.50.x），
    # 与 deepseek-harness 插件 deepseek-idesign（0.2.x）是不同版本体系。）
    $iMeta = Invoke-JsonGet 'https://registry.npmjs.org/deepseek-idesign'
    if ($iMeta -and $iMeta.'dist-tags' -and $iMeta.'dist-tags'.latest) {
        $result.Idesign = [string]$iMeta.'dist-tags'.latest
        $result.IdesignSource = 'npm:deepseek-idesign dist-tags'
    }
    return $result
}

# -----------------------------------------------------------------------------
# 本地版本读取
# -----------------------------------------------------------------------------
function Get-LocalVersions {
    $r = @{ Main = $null; Idesign = $null; ChatManager = $null; OpenInTui = $null }

    # 主框架版本：**内置运行时优先**（宿主升级后源码 checkout 的版本号会滞后，先读它会显示旧版本），
    # 其次主项目根 package.json（C:/Users/QR/deepseek-harness）/ 数据目录内的源码 checkout
    $runtimePkg = Join-Path (Split-Path -Parent $script:DataDir) 'runtime\node_modules\@deepseek-ai\dsh\package.json'
    if (Test-Path -LiteralPath $runtimePkg) {
        try {
            $rj = ([System.IO.File]::ReadAllText($runtimePkg, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json)
            if ($rj -and $rj.version) { $r.Main = [string]$rj.version; $r.MainSource = '内置运行时 runtime\' }
        } catch {}
    }
    $mainPkgCandidates = @(
        'C:\Users\QR\deepseek-harness\package.json',
        (Join-Path $script:DataDir 'deepseek-harness\package.json')
    )
    foreach ($c in $mainPkgCandidates) {
        if ($r.Main) { break }
        if (Test-Path -LiteralPath $c) {
            try {
                $pj = Get-Content -LiteralPath $c -Raw | ConvertFrom-Json
                if ($pj.version) { $r.Main = [string]$pj.version; $r.MainSource = '源码 checkout'; break }
            } catch {}
        }
    }

    # idesign
    $idesignPkg = Join-Path $script:DataDir 'deepseek-idesign\package.json'
    if (Test-Path -LiteralPath $idesignPkg) {
        try { $pj = Get-Content -LiteralPath $idesignPkg -Raw | ConvertFrom-Json; if ($pj.version) { $r.Idesign = [string]$pj.version } } catch {}
    }

    # chat-manager
    $cmPkg = Join-Path $script:DataDir 'dsh-chat-manager\packages\dsh-chat-manager\package.json'
    if (Test-Path -LiteralPath $cmPkg) {
        try { $pj = Get-Content -LiteralPath $cmPkg -Raw | ConvertFrom-Json; if ($pj.version) { $r.ChatManager = [string]$pj.version } } catch {}
    }

    # open-in-tui
    $tuiPkg = Join-Path $script:DataDir 'dsh-open-in-tui\package.json'
    if (Test-Path -LiteralPath $tuiPkg) {
        try { $pj = Get-Content -LiteralPath $tuiPkg -Raw | ConvertFrom-Json; if ($pj.version) { $r.OpenInTui = [string]$pj.version } } catch {}
    }

    return $r
}

# -----------------------------------------------------------------------------
# 依赖完整性自检测
# -----------------------------------------------------------------------------
function Test-Dependencies {
    $node = Get-NodeExe
    $npm = Get-NpmCliJs $node
    $cmPkg = Join-Path $script:DataDir 'dsh-chat-manager\packages\dsh-chat-manager'
    $cmNm = Join-Path $cmPkg 'node_modules'

    $deps = @{
        Node = $null -ne $node
        Npm  = $null -ne $npm
        ChatManagerPkg = Test-Path -LiteralPath $cmPkg
        ChatManagerLib = Test-Path -LiteralPath (Join-Path $cmPkg 'lib\index.js')
        ChatManagerNodeModules = Test-Path -LiteralPath $cmNm
    }

    # chat-manager node_modules 是否包含关键依赖
    $deps.Esbuild = Test-Path -LiteralPath (Join-Path $cmNm 'esbuild')
    $deps.Typescript = Test-Path -LiteralPath (Join-Path $cmNm 'typescript')
    $deps.Cordis = Test-Path -LiteralPath (Join-Path $cmNm '@deepseek-ai\cordis')

    return $deps
}

# -----------------------------------------------------------------------------
# 执行模式
# -----------------------------------------------------------------------------
function Invoke-CheckUpdate {
    Write-Host '【检查上游最新版本】' -ForegroundColor Cyan
    Write-Host ''
    $up = Get-UpstreamVersions
    $local = Get-LocalVersions

    Write-Info ('主框架 deepseek-harness 本地版本：' + ($(if ($local.Main) { $local.Main } else { '未知' })))
    if ($up.Main) {
        $cmp = Compare-Version $local.Main $up.Main
        if ($cmp -lt 0) { Write-Warn ('  上游最新：' + $up.Main + '（' + $up.MainSource + '）→ 有更新可用') }
        elseif ($cmp -gt 0) { Write-Info ('  上游最新：' + $up.Main + '（本地超前，可能为本地开发版）') }
        else { Write-Ok ('  上游最新：' + $up.Main + ' → 已是最新') }
    } else {
        Write-Warn '  无法访问 GitHub 上游（网络受限或 API 不可达），跳过主框架版本检查'
    }

    Write-Info ('idesign 本地版本：' + ($(if ($local.Idesign) { $local.Idesign } else { '未知' })))
    if ($up.Idesign) {
        # 本地版本可能带 dsh 适配后缀（如 0.2.2-dsh017.6），提取主版本再比较
        $localIdesignMain = $local.Idesign
        if ($localIdesignMain -match '^([0-9]+\.[0-9]+\.[0-9]+)') { $localIdesignMain = $Matches[1] }
        $cmp = Compare-Version $localIdesignMain $up.Idesign
        if ($cmp -lt 0) { Write-Warn ('  上游最新：' + $up.Idesign + '（' + $up.IdesignSource + '）→ 有更新可用') }
        elseif ($cmp -gt 0) { Write-Info ('  上游最新：' + $up.Idesign + '（本地超前，可能为本地适配版）') }
        else { Write-Ok ('  上游最新：' + $up.Idesign + ' → 已是最新（本地含 dsh 适配补丁）') }
    } else {
        Write-Info '  idesign 无独立发布信息或无法访问 npm，跳过'
    }

    Write-Info ('chat-manager / open-in-tui 随主框架版本（' + $(if ($local.Main) { $local.Main } else { '未知' }) + '），无独立发布流，跳过单独检查')
    Write-Host ''
}

function Invoke-SelfCheck {
    Write-Host '【环境与依赖自检测】' -ForegroundColor Cyan
    Write-Host ''

    $node = Get-NodeExe
    $npm = Get-NpmCliJs $node
    if ($node) {
        $v = ''
        try { $v = (& $node -v 2>$null | Select-Object -First 1) } catch {}
        Write-Ok ('Node.js：' + $node + '  ' + $v)
        Add-Report ('Node.js: OK ' + $v)
    } else {
        Write-Fail 'Node.js：未找到 node.exe'
        Add-Report 'Node.js: FAIL 未找到'
    }

    if ($npm) {
        Write-Ok 'npm：可用'
        Add-Report 'npm: OK'
    } else {
        Write-Warn 'npm：不可用（依赖补齐功能将受限）'
        Add-Report 'npm: WARN 不可用'
    }

    $deps = Test-Dependencies
    if ($deps.ChatManagerPkg) {
        Write-Ok 'chat-manager 包：存在'
        if ($deps.ChatManagerLib) { Write-Ok 'chat-manager lib 产物：存在' } else { Write-Warn 'chat-manager lib 产物：缺失（需构建）' }
        if ($deps.ChatManagerNodeModules) { Write-Ok 'chat-manager node_modules：存在' } else { Write-Warn 'chat-manager node_modules：缺失（需 npm install）' }
        if ($deps.Esbuild) { Write-Ok 'esbuild：已安装' } else { Write-Warn 'esbuild：缺失' }
        if ($deps.Typescript) { Write-Ok 'typescript：已安装' } else { Write-Warn 'typescript：缺失' }
        if ($deps.Cordis) { Write-Ok '@deepseek-ai/cordis：已安装' } else { Write-Warn '@deepseek-ai/cordis：缺失' }
    } else {
        Write-Warn 'chat-manager 包：未找到'
        Add-Report 'chat-manager: WARN 未找到'
    }

    # dsh-home 数据目录
    if (Test-Path -LiteralPath $script:DshHome) {
        Write-Ok ('数据目录 dsh-home：' + $script:DshHome)
    } else {
        Write-Warn '数据目录 dsh-home：不存在（首次运行会自动创建）'
    }

    # 服务状态
    $listener = $null
    try { $listener = Get-NetTCPConnection -LocalPort $script:DefaultPort -State Listen -ErrorAction Stop | Select-Object -First 1 } catch {}
    if ($listener) {
        Write-Ok ('服务：端口 ' + $script:DefaultPort + ' 在线（PID ' + $listener.OwningProcess + '）')
    } else {
        Write-Warn ('服务：端口 ' + $script:DefaultPort + ' 无监听，服务未运行')
    }

    Write-Host ''
    return $deps
}

function Invoke-Fix {
    Write-Host '【自动补齐缺失依赖】' -ForegroundColor Cyan
    Write-Host ''
    $node = Get-NodeExe
    $npm = Get-NpmCliJs $node
    if (-not $node) { Write-Fail '未找到 Node.js，无法补齐依赖。'; return }
    if (-not $npm) { Write-Fail '未找到 npm，无法补齐依赖。'; return }

    $deps = Test-Dependencies
    $cmPkg = Join-Path $script:DataDir 'dsh-chat-manager\packages\dsh-chat-manager'
    $cmNm = Join-Path $cmPkg 'node_modules'

    if (-not $deps.ChatManagerPkg) {
        Write-Fail 'chat-manager 包目录不存在，无法补齐。请先恢复源码。'
        return
    }

    $needInstall = $false
    if (-not $deps.ChatManagerNodeModules) { $needInstall = $true }
    elseif (-not $deps.Esbuild -or -not $deps.Typescript -or -not $deps.Cordis) { $needInstall = $true }

    if ($needInstall) {
        Write-Warn '检测到 chat-manager 依赖缺失，执行 npm install（联网下载，可能需要几分钟）...'
        try {
            Push-Location $cmPkg
            & $node $npm install --no-audit --no-fund 2>&1 | ForEach-Object { Write-Info $_ }
            $rc = $LASTEXITCODE
            Pop-Location
            if ($rc -eq 0) { Write-Ok '依赖补齐完成' } else { Write-Fail ('依赖补齐失败（npm 退出码 ' + $rc + '）') }
        } catch {
            Pop-Location -ErrorAction SilentlyContinue
            Write-Fail ('依赖补齐异常：' + $_.Exception.Message)
        }
    } else {
        Write-Ok '依赖完整，无需补齐'
    }

    # 构建 lib 产物
    if (-not $deps.ChatManagerLib -or $needInstall) {
        Write-Warn '构建 chat-manager lib 产物...'
        try {
            Push-Location $cmPkg
            & $node $npm run build 2>&1 | ForEach-Object { Write-Info $_ }
            $rc = $LASTEXITCODE
            Pop-Location
            if ($rc -eq 0) { Write-Ok 'lib 产物构建完成' } else { Write-Fail ('构建失败（退出码 ' + $rc + '）') }
        } catch {
            Pop-Location -ErrorAction SilentlyContinue
            Write-Fail ('构建异常：' + $_.Exception.Message)
        }
    }

    # 应用 dsh web 插件适配补丁（dsh-pet 路由常驻 / whale 挂件音频门控）
    $adapt = Join-Path $script:DataDir 'apply-adaptations.ps1'
    if (Test-Path -LiteralPath $adapt) {
        Write-Info '应用 dsh web 插件适配补丁...'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $adapt
    } else {
        Write-Warn '适配补丁脚本 apply-adaptations.ps1 不存在，跳过'
    }

    Write-Host ''
}

function Invoke-Update {
    Write-Host '【执行更新】' -ForegroundColor Cyan
    Write-Host ''
    Invoke-CheckUpdate

    $up = Get-UpstreamVersions
    $local = Get-LocalVersions

    $mainRepo = 'C:\Users\QR\deepseek-harness'
    if (Test-Path -LiteralPath (Join-Path $mainRepo '.git')) {
        Write-Warn ('主框架仓库存在（' + $mainRepo + '），尝试 git pull 更新...')
        $git = Get-Command git.exe -ErrorAction SilentlyContinue
        if ($git) {
            try {
                Push-Location $mainRepo
                & git.exe fetch origin 2>&1 | ForEach-Object { Write-Info $_ }
                & git.exe pull --ff-only 2>&1 | ForEach-Object { Write-Info $_ }
                $rc = $LASTEXITCODE
                Pop-Location
                if ($rc -eq 0) { Write-Ok '主框架更新完成' } else { Write-Warn ('git pull 返回退出码 ' + $rc + '，可能需手动处理合并冲突') }
            } catch {
                Pop-Location -ErrorAction SilentlyContinue
                Write-Fail ('git 更新异常：' + $_.Exception.Message)
            }
        } else {
            Write-Fail '未找到 git，无法更新主框架'
        }
    } else {
        Write-Info '主框架仓库不在 C:\Users\QR\deepseek-harness，跳过 git 更新'
    }

    Write-Info '插件层更新：执行依赖补齐 + 构建'
    Invoke-Fix

    # 插件层无损更新：**透传宿主版本**，避免工作流按源码 checkout 版本误判（会把插件挑回旧版）
    $updater = Join-Path $script:DataDir 'update-plugins.ps1'
    if ($SkipPluginUpdate) {
        Write-Info '已指定 -SkipPluginUpdate，跳过插件更新工作流。'
    } elseif (Test-Path -LiteralPath $updater) {
        Write-Info ('插件更新工作流：update-plugins.ps1 -Apply -HostVersion ' + $script:HostVersion)
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updater -Apply -HostVersion $script:HostVersion
        if ($LASTEXITCODE -eq 0) { Write-Ok '插件更新工作流完成' } else { Write-Warn ('插件更新工作流退出码 ' + $LASTEXITCODE + '（详见 插件自愈中心\logs）') }
    } else {
        Write-Warn '未找到 update-plugins.ps1，跳过插件更新工作流'
    }

    Write-Host ''
    Write-Info '提示：主框架依赖（pnpm install）需在非沙箱环境（系统 PowerShell/CMD）运行，'
    Write-Info '      因沙箱会拦截 pnpm 的符号链接与文件删除操作。命令：'
    Write-Info '        cd C:\Users\QR\deepseek-harness && pnpm install --frozen-lockfile'
    Write-Host ''
}

function Invoke-Housekeeping {
    # 残留清理 + 数据目录自愈（安全：只读扫描 + 归档/隔离，不删除用户数据）
    # 1) 数据目录空壳自愈：dsh-home/data 下 0 字节的 lock / meta 文件是初始化
    #    不完整的标志，此处仅检测并提示（不擅自删除，交由 dsh 重建）。
    # 2) 临时/残留文件归档：启动器目录内的 .tmp-* / *.corrupt-* / *.bak-* /
    #    *.heal-* 文件，保留最近 7 天，其余归档到 launcher-backup\housekeeping-<时间戳>。
    Write-Host '【残留清理与数据目录自愈】' -ForegroundColor Cyan
    Write-Host ''

    # 1) 空壳数据目录检测（只读提示）
    $dataDir = Join-Path $script:DataDir 'data'
    if (Test-Path -LiteralPath $dataDir) {
        $shellFiles = @()
        Get-ChildItem -LiteralPath $dataDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Length -eq 0 -and ($_.Name -match '\.lock$|\.json$|meta')) { $shellFiles += $_.FullName }
        }
        if ($shellFiles.Count -gt 0) {
            Write-Warn ('检测到 ' + $shellFiles.Count + ' 个空壳数据文件（初始化可能不完整）：')
            $shellFiles | Select-Object -First 5 | ForEach-Object { Write-Info ('  ' + $_) }
            Write-Info '  这些文件将由 dsh 首次运行时自动重建，无需手动干预。'
            Add-Report ('空壳数据文件：' + $shellFiles.Count + ' 个（自动重建，无需干预）')
        } else {
            Write-Ok '数据目录：无空壳文件'
        }
    }

    # 2) 临时/残留文件归档（保留最近 7 天，归档到 launcher-backup）
    $patterns = @('.tmp-', '.corrupt-', '.bak-', '.heal-', '.restore-')
    $cutoff = (Get-Date).AddDays(-7)
    $archiveRoot = Join-Path $script:LauncherDir 'launcher-backup'
    $moved = 0
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Get-ChildItem -LiteralPath $script:LauncherDir -File -ErrorAction SilentlyContinue | ForEach-Object {
        $name = $_.Name
        $match = $false
        foreach ($p in $patterns) {
            if ($name -match [regex]::Escape($p)) { $match = $true; break }
        }
        if (-not $match) { return }
        if ($_.LastWriteTime -gt $cutoff) { return }
        $destDir = Join-Path $archiveRoot ('housekeeping-' + $stamp)
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        try {
            Move-Item -LiteralPath $_.FullName -Destination (Join-Path $destDir $name) -Force -ErrorAction Stop
            $moved++
        } catch {
            Write-Warn ('归档失败（跳过）：' + $name + '（' + $_.Exception.Message + '）')
        }
    }
    if ($moved -gt 0) {
        Write-Ok ('已归档 ' + $moved + ' 个过期临时/残留文件到 launcher-backup\housekeeping-' + $stamp)
        Add-Report ('归档过期残留文件：' + $moved + ' 个')
    } else {
        Write-Ok '临时/残留文件：无需清理（最近 7 天内的保留，无过期文件）'
    }
    Write-Host ''
}

function Show-Help {
    Write-Host 'DeepSeek Harness 独立深度维护工具'
    Write-Host ''
    Write-Host '用法：'
    Write-Host '  maintain.ps1                 全量自检测 + 诊断报告（只读，默认）'
    Write-Host '  maintain.ps1 -CheckUpdate    检查上游最新版本（GitHub tags）'
    Write-Host '  maintain.ps1 -Fix            自检测 + 自动补齐缺失依赖 + 构建'
    Write-Host '  maintain.ps1 -Update         检查版本 + 更新主框架 + 补齐插件依赖'
    Write-Host '  maintain.ps1 -Report <路径>  将诊断报告导出到指定文件'
    Write-Host '  maintain.ps1 -Help           本帮助'
    Write-Host '  maintain.ps1 -Update -HostVersion 0.2.0-rc.2   指定宿主版本并透传给插件更新工作流'
    Write-Host '  maintain.ps1 -Update -SkipPluginUpdate        只更新主框架，跳过插件更新工作流'
    Write-Host ''
    Write-Host '说明：'
    Write-Host '  - 本脚本独立于启动器，可单独运行，用于深度维护。'
    Write-Host '  - 启动器内嵌轻量检测（-Doctor / -CheckUpdate），两者互补。'
    Write-Host '  - 主框架依赖（pnpm install）需在非沙箱环境运行（沙箱拦截符号链接）。'
    Write-Host '  - 宿主版本默认取内置运行时 runtime\；-HostVersion 可显式覆盖，并透传给'
    Write-Host '    update-plugins.ps1（它自身默认先读源码 checkout，宿主升级后会误判）。'
}

# -----------------------------------------------------------------------------
# 主流程
# -----------------------------------------------------------------------------
if ($Help) { Write-Banner; Show-Help; exit 0 }

Write-Banner

# 宿主版本：解析 → 导出环境变量（子工具可读）→ 打印来源
$hostInfo = Resolve-HostVersion $HostVersion
$script:HostVersion = $hostInfo.Version
$script:HostVersionSource = $hostInfo.Source
$env:DSH_HOST_VERSION = $script:HostVersion
Write-Info ('宿主版本：' + $script:HostVersion + '   ← ' + $script:HostVersionSource)
Write-Host ''

if ($Update) {
    Invoke-Update
} elseif ($CheckUpdate) {
    Invoke-CheckUpdate
} elseif ($Fix) {
    Invoke-SelfCheck | Out-Null
    Invoke-Fix
    Invoke-Housekeeping
} else {
    # 默认：全量自检测 + 诊断报告
    $deps = Invoke-SelfCheck
    Invoke-CheckUpdate
    Invoke-Housekeeping
}

# 导出报告
if ($Report -or $ReportPath) {
    $path = $ReportPath
    if (-not $path) { $path = Join-Path $script:DataDir '诊断报告.md' }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $lines = @('# DeepSeek Harness 诊断报告', '', ('生成时间：' + $stamp), '')
    $lines += @($script:ReportLines)
    try {
        [System.IO.File]::WriteAllLines($path, $lines, (New-Object System.Text.UTF8Encoding($true)))
        Write-Ok ('诊断报告已导出：' + $path)
    } catch {
        Write-Fail ('报告导出失败：' + $_.Exception.Message)
    }
}

Write-Host ''
Write-Host '维护完成。' -ForegroundColor Cyan
