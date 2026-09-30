# 自动升级看守器：等宿主停止后自动完成 DSH 运行时升级
#
# 为什么要"看守"、且**必须由用户从宿主体外启动**：
#   升级要先把宿主停掉（运行中的 node 锁着 runtime\node.exe 与原生模块），而宿主体内派生出来的
#   进程会随宿主一起退出——所以看守器只能由用户双击 开始自动升级.cmd 启动（它不是宿主的子进程，
#   关掉启动器窗口后它依然活着），由它来等待并接手升级。
# 升级必须先把正在运行的宿主停掉（运行中的 node 锁着 runtime\node.exe 与原生模块），
# 而升级过程本身又在宿主体内跑（DSH 会话），所以由本脚本在宿主体外等待：
#   1) 轮询端口（默认 3080）直到空闲 = 启动器窗口已关闭
#   2) 再等几秒让文件句柄彻底释放
#   3) 调用升级脚本（默认 升级DSH到0.2.0-rc.2.ps1），它自带备份/断言/失败回滚，并在成功后就地重启启动器
# 全过程落日志到 logs\自动升级-<时间戳>.log
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tools\watch-and-upgrade.ps1              # 正式看守
#   powershell -ExecutionPolicy Bypass -File tools\watch-and-upgrade.ps1 -DryRun      # 只演练等待逻辑，不升级
#   powershell -ExecutionPolicy Bypass -File tools\watch-and-upgrade.ps1 -Port 3199   # 换探测端口（自测用）
[CmdletBinding()]
param(
    [int]$Port = 3080,
    [int]$WaitMinutes = 30,
    [int]$PollSeconds = 3,
    [int]$GraceSeconds = 5,
    [int]$ReadyTimeoutSeconds = 120,
    [string]$UpgradeScript,
    [string]$Root,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$toolsDir = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $toolsDir }
if (-not $UpgradeScript) { $UpgradeScript = Join-Path $Root 'deepseek-Harness插件及其数据\升级DSH到0.2.0-rc.2.ps1' }
$logDir = Join-Path $Root 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log = Join-Path $logDir ('自动升级-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

function Say($msg, $color = 'Gray') {
    $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $msg
    Write-Host $line -ForegroundColor $color
    Add-Content -LiteralPath $log -Value $line -Encoding UTF8
}

function Test-Busy([int]$p) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { $c.Connect('127.0.0.1', $p); return $true } catch { return $false } finally { $c.Dispose() }
}

function Get-RuntimeVersion {
    $p = Join-Path $Root 'runtime\node_modules\@deepseek-ai\dsh\package.json'
    if (-not (Test-Path -LiteralPath $p)) { return '未知' }
    try { return ([System.IO.File]::ReadAllText($p, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json).version } catch { return '未知' }
}
$versionBefore = Get-RuntimeVersion

Say '=== DSH 自动升级看守器 ===' 'Cyan'
Say ('根目录   : ' + $Root)
Say ('升级脚本 : ' + $UpgradeScript)
Say ('日志     : ' + $log)
if ($DryRun) { Say '模式     : DryRun（只演练等待逻辑，不会真的升级）' 'Yellow' }

if (-not (Test-Path -LiteralPath $UpgradeScript)) { Say ('找不到升级脚本：' + $UpgradeScript) 'Red'; exit 2 }

Say ('等待端口 ' + $Port + ' 空闲（即：请关闭一键启动器窗口）...') 'Yellow'
$deadline = (Get-Date).AddMinutes($WaitMinutes)
$waited = 0
while ($true) {
    if (-not (Test-Busy $Port)) { break }
    if ((Get-Date) -ge $deadline) {
        Say ('等待超过 ' + $WaitMinutes + ' 分钟，宿主仍在运行，放弃自动升级。') 'Red'
        Say '（可重新运行本看守器，或关闭窗口后手动执行升级脚本）'
        exit 3
    }
    Start-Sleep -Seconds $PollSeconds
    $waited += $PollSeconds
    if ($waited % 30 -eq 0) { Say ('  已等待 ' + $waited + ' 秒...') }
}

Say ('端口 ' + $Port + ' 已空闲，宿主已停止。') 'Green'
Say ('再等 ' + $GraceSeconds + ' 秒确保文件句柄释放...')
Start-Sleep -Seconds $GraceSeconds

if ($DryRun) {
    Say '[DryRun] 本应执行：' 'Yellow'
    Say ('  powershell -NoProfile -ExecutionPolicy Bypass -File "' + $UpgradeScript + '"')
    Say '[DryRun] 结束，未做任何改动。' 'Green'
    exit 0
}

Say '开始执行升级（自带备份 / 断言 / 失败回滚 / 成功后重启启动器）...' 'Cyan'
& powershell -NoProfile -ExecutionPolicy Bypass -File $UpgradeScript 2>&1 | Tee-Object -FilePath $log -Append
$rc = $LASTEXITCODE
Say ('升级脚本退出码 = ' + $rc) $(if ($rc -eq 0) { 'Green' } else { 'Red' })
if ($rc -eq 0) {
    Say '自动升级完成。启动器应已由升级脚本重新拉起。' 'Green'

    # --- 升级后自检（不依赖任何会话，证据直接落盘）---
    $versionAfter = Get-RuntimeVersion
    Say ('runtime 版本：' + $versionBefore + ' -> ' + $versionAfter) 'Green'
    $engine = Join-Path $Root 'deepseek-Harness插件及其数据\升级DSH运行时.ps1'
    $verifyText = '(未找到引擎，跳过 -VerifyOnly)'
    if (Test-Path -LiteralPath $engine) {
        Say '运行升级后自检（-VerifyOnly）...'
        $verifyText = (& powershell -NoProfile -ExecutionPolicy Bypass -File $engine -VerifyOnly 2>&1) -join "`r`n"
        Say ('自检退出码 = ' + $LASTEXITCODE) $(if ($LASTEXITCODE -eq 0) { 'Green' } else { 'Yellow' })
    }
    # 等启动器把服务拉起来，记下 HTTP 结果
    $ready = $false
    $rounds = [Math]::Max(1, [Math]::Ceiling($ReadyTimeoutSeconds / 2))
    for ($i = 0; $i -lt $rounds; $i++) { Start-Sleep -Seconds 2; if (Test-Busy $Port) { $ready = $true; break } }
    $report = Join-Path $logDir ('升级后自检报告-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
    $readyText = if ($ready) { '是（端口 ' + $Port + ' 已监听）' } else { '否（' + $ReadyTimeoutSeconds + ' 秒内未见监听）' }
    $lines = @(
        'DSH 宿主升级后自检报告',
        ('时间        : ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')),
        ('runtime 前  : ' + $versionBefore),
        ('runtime 后  : ' + $versionAfter),
        ('服务就绪    : ' + $readyText),
        ('升级日志    : ' + $log),
        '',
        '--- -VerifyOnly 输出 ---',
        $verifyText
    )
    $lines | Set-Content -LiteralPath $report -Encoding UTF8
    Say ('自检报告：' + $report) 'Cyan'
} else {
    Say '升级未成功。请查看上面的输出与 logs 下的备份目录；必要时运行：' 'Red'
    Say ('  powershell -ExecutionPolicy Bypass -File "' + $UpgradeScript + '" -Rollback')
}
exit $rc
