# =============================================================================
#  f12-audit-repair.ps1 - reproducible F12 console self-check + repair pipeline
#  (pure ASCII on purpose: safe under Windows PowerShell 5.1 ANSI parsing)
#
#  Replicates the manual process that keeps the dsh web console clean:
#    1. probe the dsh web service, Ollama, and OpenViking
#    2. ensure the idempotent plugin adaptation patches are present
#       (re-runs apply-adaptations.ps1 when any marker is missing)
#    3. smoke-test host API routes with the authenticated token URL
#    4. capture real browser console/exception/network errors headlessly
#       (embedded f12-capture.mjs + cdp-lib.mjs from the launcher tools dir)
#    5. classify every captured error against a known signature table and
#       write a timestamped report next to this script
#
#  Usage:
#    powershell -ExecutionPolicy Bypass -File f12-audit-repair.ps1
#    powershell -ExecutionPolicy Bypass -File f12-audit-repair.ps1 -SkipCapture
#    powershell -ExecutionPolicy Bypass -File f12-audit-repair.ps1 -NoRepair
#    powershell -ExecutionPolicy Bypass -File f12-audit-repair.ps1 -LiveUrl <url>
# =============================================================================
[CmdletBinding()]
param(
    [int]$Port = 3080,
    [switch]$SkipCapture,
    [switch]$NoRepair,
    [string]$LiveUrl = ''
)

$ErrorActionPreference = 'Continue'

function Write-Ok   { param([string]$Msg) Write-Host ('  [OK]    ' + $Msg) -ForegroundColor Green }
function Write-Fail { param([string]$Msg) Write-Host ('  [FAIL]  ' + $Msg) -ForegroundColor Red }
function Write-Warn { param([string]$Msg) Write-Host ('  [WARN]  ' + $Msg) -ForegroundColor Yellow }
function Write-Info { param([string]$Msg) Write-Host ('  [..]    ' + $Msg) -ForegroundColor DarkGray }

# -----------------------------------------------------------------------------
# environment discovery
# -----------------------------------------------------------------------------
$script:DataDir     = $PSScriptRoot
$script:LauncherDir = Split-Path -Parent $script:DataDir
if ($env:DSH_HOME -and (Test-Path -LiteralPath $env:DSH_HOME)) {
    $script:DshHome = $env:DSH_HOME
} else {
    $script:DshHome = Join-Path $script:DataDir 'dsh-home'
}
$script:ProfileWeb = Join-Path $script:DshHome 'profiles\web'
$script:EngineDir  = Join-Path $env:LOCALAPPDATA 'DeepSeek-Harness'
$script:ToolsDir   = Join-Path $script:EngineDir 'tools'
$script:LogDir     = Join-Path $script:EngineDir 'logs'
$script:ReportPath = Join-Path $script:DataDir ('f12-report-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.md')
$script:Report     = New-Object System.Collections.Generic.List[string]

function Find-NodeExe {
    $bundled = Join-Path $script:LauncherDir 'runtime\node.exe'
    if (Test-Path -LiteralPath $bundled) { return $bundled }
    $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Find-BrowserExe {
    $cands = @(
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
    )
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Get-AuthUrlForPort {
    param([int]$PortNum)
    foreach ($log in @(
        (Join-Path $script:LogDir ('web-' + $PortNum + '.out.log')),
        (Join-Path $script:LauncherDir ('logs\web-' + $PortNum + '.out.log'))
    )) {
        if (-not (Test-Path -LiteralPath $log)) { continue }
        try {
            $m = Select-String -Path $log -Pattern 'dsh web:\s*(https?://\S+)' -ErrorAction Stop | Select-Object -Last 1
            if ($m) { return $m.Matches[0].Groups[1].Value }
        } catch {}
    }
    return $null
}

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

function Write-TextNoBom {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Add-ReportLine {
    param([string]$Line)
    $script:Report.Add($Line)
}

# -----------------------------------------------------------------------------
# HTTP probes (HttpClient: robust in both sandboxed and normal PowerShell)
# -----------------------------------------------------------------------------
function Invoke-HttpStatus {
    param([string]$Uri, [string]$Method = 'GET')
    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(8)
        if ($Method -eq 'POST') {
            $content = [System.Net.Http.StringContent]::new('{}', [System.Text.Encoding]::UTF8, 'application/json')
            $resp = $client.PostAsync($Uri, $content).Result
            $content.Dispose()
        } else {
            $resp = $client.GetAsync($Uri).Result
        }
        $code = [int]$resp.StatusCode
        $resp.Dispose()
        $client.Dispose()
        return $code
    } catch {
        return 0
    }
}

function Invoke-Api {
    param([string]$Origin, [string]$Query, [string]$PathName, [string]$Method = 'GET')
    $uri = $Origin + $PathName
    if ($Query) {
        $q = $Query
        if ($q.StartsWith('?')) { $q = $q.Substring(1) }
        $sep = '?'
        if ($PathName.Contains('?')) { $sep = '&' }
        $uri = $uri + $sep + $q
    }
    return Invoke-HttpStatus $uri $Method
}

# -----------------------------------------------------------------------------
# Ollama models-link repair (dangling junction -> restore latest models.bak-*)
# -----------------------------------------------------------------------------
function Repair-OllamaModelsLink {
    $ollama = Join-Path $env:USERPROFILE '.ollama'
    $models = Join-Path $ollama 'models'
    if (-not (Test-Path -LiteralPath $models)) { return 'absent' }
    $item = Get-Item -LiteralPath $models -Force -ErrorAction SilentlyContinue
    if (-not $item) { return 'unreadable' }
    if (-not $item.LinkType) { return 'ok-dir' }
    $target = ($item.Target -join '')
    if ($target -and (Test-Path -LiteralPath $target)) { return 'ok-link' }
    $bak = Get-ChildItem -LiteralPath $ollama -Directory -Filter 'models.bak-*' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $bak) { return 'dangling-no-bak' }
    if ($NoRepair) { return 'dangling-needs-repair' }
    try {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Rename-Item -LiteralPath $models -NewName ('models.broken-' + $stamp) -Force -ErrorAction Stop
        Rename-Item -LiteralPath $bak.FullName -NewName 'models' -Force -ErrorAction Stop
        return 'repaired'
    } catch {
        return 'denied'
    }
}

# -----------------------------------------------------------------------------
# patch markers (JSON targets + whale-widget) -- the update-compatible core
# -----------------------------------------------------------------------------
function Test-PatchMarkers {
    $results = @()
    $json = Read-JsonUtf8 (Join-Path $script:DataDir 'patch-data.json')
    if ($json -and $json.targets) {
        foreach ($t in $json.targets) {
            $file = Join-Path $script:ProfileWeb $t.file
            if (-not (Test-Path -LiteralPath $file)) {
                $results += [pscustomobject]@{ Id = $t.id; State = 'MISSING'; Note = $t.file }
                continue
            }
            $txt = Read-TextNoBom $file
            if ($null -eq $txt) {
                $results += [pscustomobject]@{ Id = $t.id; State = 'READFAIL'; Note = $t.file }
                continue
            }
            $all = $true
            foreach ($m in $t.markers) {
                if ($txt.IndexOf([string]$m) -lt 0) { $all = $false; break }
            }
            $results += [pscustomobject]@{ Id = $t.id; State = $(if ($all) { 'OK' } else { 'MISSING' }); Note = $t.file }
        }
    }
    $whale = Join-Path $script:ProfileWeb 'node_modules\dsh-whale-widget\assets\whale-widget.js'
    $whaleState = 'MISSING'
    if (Test-Path -LiteralPath $whale) {
        $wtxt = Read-TextNoBom $whale
        if ($wtxt -and $wtxt.Contains('var dshwvGestureOk = false')) { $whaleState = 'OK' }
    }
    $results += [pscustomobject]@{ Id = 'whale-widget'; State = $whaleState; Note = 'assets\whale-widget.js' }
    return ,$results
}

# -----------------------------------------------------------------------------
# headless F12 capture tool (embedded; written into the launcher tools dir)
# -----------------------------------------------------------------------------
$script:CaptureTool = @'
// f12-capture.mjs - headless F12 capture for dsh web.
// Captures console errors, exceptions, log entries and HTTP 4xx/5xx while the
// authenticated page boots and settles, then prints one JSON result object.
// usage: node f12-capture.mjs <authenticated-url> [cdpPort] [waitMs]
// env:   DSH_CDP_LIB  absolute path of cdp-lib.mjs (required)
//        DSH_CHROME   browser binary (optional; cdp-lib has its own default)
import { pathToFileURL } from 'node:url'

const url = process.argv[2]
const cdpPort = Number(process.argv[3] ?? 9335)
const waitMs = Number(process.argv[4] ?? 15000)
if (!url) {
  console.error('usage: node f12-capture.mjs <authenticated-url> [cdpPort] [waitMs]')
  process.exit(2)
}
if (!process.env.DSH_CDP_LIB) {
  console.error('DSH_CDP_LIB env required (absolute path of cdp-lib.mjs)')
  process.exit(2)
}
const { launchChrome, connectPage, sleep } = await import(pathToFileURL(process.env.DSH_CDP_LIB).href)

const browser = launchChrome({ port: cdpPort, windowSize: '1600,1000', captureStderr: true })
const ws = await connectPage(cdpPort, { attempts: 60, intervalMs: 250 })
if (ws === null) {
  console.error('CAPTURE: could not reach CDP page target')
  if (browser.stderr) console.error(browser.stderr.slice(0, 800))
  await browser.cleanup().catch(() => {})
  process.exit(1)
}

let id = 0
const pending = new Map()
const consoleErrors = []
const exceptions = []
const logErrors = []
const logWarnings = []
const httpErrors = []
const seen = new Set()
const pushOnce = (key, fn) => { if (!seen.has(key)) { seen.add(key); fn() } }

ws.onmessage = (ev) => {
  let msg
  try { msg = JSON.parse(ev.data) } catch { return }
  if (msg.id && pending.has(msg.id)) {
    const entry = pending.get(msg.id)
    pending.delete(msg.id)
    if (msg.error) entry.reject(new Error(msg.error.message ?? 'cdp error'))
    else entry.resolve(msg.result)
    return
  }
  const p = msg.params ?? {}
  if (msg.method === 'Runtime.exceptionThrown') {
    const text = String(p.exceptionDetails?.exception?.description ?? p.exceptionDetails?.text ?? '')
    pushOnce('exc:' + text, () => exceptions.push(text.split('\n').slice(0, 2).join(' | ')))
  } else if (msg.method === 'Runtime.consoleAPICalled' && p.type === 'error') {
    const text = (p.args ?? []).map((a) => a.value ?? a.description ?? a.type).join(' ')
    pushOnce('con:' + text, () => consoleErrors.push(text.split('\n').slice(0, 2).join(' | ')))
  } else if (msg.method === 'Log.entryAdded') {
    const level = p.entry?.level
    const text = String(p.entry?.text ?? '')
    if (level === 'error') pushOnce('log:' + text, () => logErrors.push(text.split('\n').slice(0, 2).join(' | ')))
    else if (level === 'warning') pushOnce('warn:' + text, () => logWarnings.push(text.split('\n').slice(0, 2).join(' | ')))
  } else if (msg.method === 'Network.responseReceived') {
    const status = p.response?.status ?? 0
    if (status >= 400) {
      const u = p.response?.url ?? ''
      pushOnce(status + ':' + u, () => httpErrors.push({ status, url: u }))
    }
  } else if (msg.method === 'Network.loadingFailed') {
    const errText = String(p.errorText ?? '')
    if (errText.includes('ERR_ABORTED')) return
    pushOnce('netfail:' + errText, () => httpErrors.push({ status: 0, url: errText }))
  }
}

const send = (method, params = {}) => new Promise((resolve, reject) => {
  const mid = ++id
  pending.set(mid, { resolve, reject })
  try { ws.send(JSON.stringify({ id: mid, method, params })) }
  catch (err) { pending.delete(mid); reject(err) }
})

await send('Runtime.enable')
await send('Page.enable')
await send('Log.enable')
await send('Network.enable')
await send('Page.navigate', { url })

let state = null
const deadline = Date.now() + waitMs
while (Date.now() < deadline) {
  await sleep(500)
  try {
    const res = await send('Runtime.evaluate', {
      expression: `(() => {
        const q = (s) => document.querySelector(s)
        const has = (s) => q(s) ? 'yes' : 'no'
        const txt = document.body ? (document.body.innerText ?? '') : ''
        return {
          ready: document.readyState,
          bodyLen: document.body ? (document.body.innerHTML.length ?? 0) : 0,
          bootPage: has('.bootPage, [class*=boot]'),
          fail: has('[class*=fail]'),
          sidebar: has('[class*=sidebar]'),
          bodyHead: txt.slice(0, 200)
        }
      })()`,
      returnByValue: true
    })
    state = res?.result?.value ?? null
  } catch { state = null }
  if (state && state.bodyLen > 3000) break
}

console.log(JSON.stringify({
  ok: {
    pageMounted: !!state && state.bodyLen > 3000,
    noBootFail: !!state && state.fail !== 'yes',
    noExceptions: exceptions.length === 0,
    noConsoleErrors: consoleErrors.length === 0
  },
  state,
  exceptions: exceptions.slice(0, 12),
  consoleErrors: consoleErrors.slice(0, 12),
  logErrors: logErrors.slice(0, 12),
  logWarnings: logWarnings.slice(0, 12),
  httpErrors: httpErrors.slice(0, 40)
}, null, 2))
ws.close()
await browser.cleanup().catch(() => {})
process.exit(0)
'@

function Get-WritableToolsDir {
    if (Test-Path -LiteralPath $script:ToolsDir) {
        try {
            $probe = Join-Path $script:ToolsDir ('.write-probe-' + [guid]::NewGuid().ToString('N'))
            [System.IO.File]::WriteAllText($probe, 'ok')
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            return $script:ToolsDir
        } catch {}
    }
    $fallback = Join-Path $script:DataDir '.f12-tools'
    New-Item -ItemType Directory -Path $fallback -Force | Out-Null
    return $fallback
}

$script:ToolDir = Get-WritableToolsDir

function Ensure-Tool {
    param([string]$Name, [string]$Content)
    $p = Join-Path $script:ToolDir $Name
    $needWrite = $true
    if (Test-Path -LiteralPath $p) {
        try {
            $existing = Get-Content -LiteralPath $p -Raw -Encoding UTF8
            if ($existing -ceq $Content) { $needWrite = $false }
        } catch { $needWrite = $true }
    }
    if ($needWrite) {
        Write-TextNoBom $p $Content
    }
    return $p
}

function Invoke-NodeTool {
    param([string]$ToolPath, [string[]]$ArgList)
    if (-not $script:NodeExe) {
        return [pscustomobject]@{ ExitCode = 127; Out = ''; Err = 'node.exe missing' }
    }
    if (-not (Test-Path -LiteralPath $ToolPath)) {
        return [pscustomobject]@{ ExitCode = 127; Out = ''; Err = 'tool missing: ' + $ToolPath }
    }
    $outFile = Join-Path $script:DataDir ('.f12-' + [System.IO.Path]::GetFileNameWithoutExtension($ToolPath) + '.out.txt')
    $errFile = Join-Path $script:DataDir ('.f12-' + [System.IO.Path]::GetFileNameWithoutExtension($ToolPath) + '.err.txt')
    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    & $script:NodeExe $ToolPath @ArgList > $outFile 2> $errFile
    $rc = $LASTEXITCODE
    $out = ''
    $err = ''
    if (Test-Path -LiteralPath $outFile) { $out = Get-Content -LiteralPath $outFile -Raw -Encoding UTF8 }
    if (Test-Path -LiteralPath $errFile) { $err = Get-Content -LiteralPath $errFile -Raw -Encoding UTF8 }
    return [pscustomobject]@{ ExitCode = $rc; Out = $out; Err = $err }
}

# -----------------------------------------------------------------------------
# error signature classification (the manual diagnosis, encoded)
# -----------------------------------------------------------------------------
function Classify-Entry {
    param([string]$Kind, [string]$Text, [int]$Status, [string]$Url)
    $t = $Text
    $u = $Url
    if ($u -and $u.Contains('/api/pet/') -and $Status -eq 404) { return 'pet-404 (pet patch missing or stale)' }
    if ($u -and $u.Contains('/api/ego/watch/stop') -and $Status -eq 409) { return 'ego-watch-stop-409 (ego patch missing or stale)' }
    if ($u -and $u.Contains('/api/changes.summary') -and $Status -eq 404) { return 'changes-summary-404 (core design behavior: no changes at that seq)' }
    if ($u -and $u.Contains('11434/api/tags') -and $Status -eq 500) { return 'ollama-tags-500 (models junction dangling)' }
    if ($t -match 'React error #130|slot entry crashed|Minified React error') { return 'agent-team-react130 (legacy Icon*16/MessageText API)' }
    if ($t -match 'AudioContext') { return 'whale-audio-warning (gesture gate missing)' }
    if ($t -match 'Failed to load resource' -and $u -match 'changes\.summary') { return 'changes-summary-404 (core design behavior)' }
    if ($Status -eq 404) { return 'other-404 (unclassified)' }
    if ($Status -ge 500) { return 'other-5xx (unclassified)' }
    if ($t -match 'ERR_ABORTED') { return 'net-abort (benign navigation abort)' }
    return 'unclassified'
}

# =============================================================================
# main
# =============================================================================
Write-Host '================================================' -ForegroundColor DarkCyan
Write-Host '   dsh web F12 self-check + repair pipeline'
Write-Host '================================================' -ForegroundColor DarkCyan
Write-Host ''
Add-ReportLine '# dsh web F12 self-check report'
Add-ReportLine ''
Add-ReportLine ('- time: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Add-ReportLine ('- port: ' + $Port)
Add-ReportLine ('- profile web: ' + $script:ProfileWeb)
Add-ReportLine ''

$script:NodeExe = Find-NodeExe
if (-not $script:NodeExe) {
    Write-Fail 'node.exe not found (runtime\node.exe or PATH).'
    Add-ReportLine '- node.exe: NOT FOUND'
    Write-TextNoBom $script:ReportPath ($script:Report -join "`r`n")
    exit 1
}
Write-Ok ('node.exe: ' + $script:NodeExe)
Add-ReportLine ('- node.exe: ' + $script:NodeExe)

# ---- phase 1: service probes ------------------------------------------------
Write-Host ''
Write-Info 'Phase 1/5: service probes'
Add-ReportLine ''
Add-ReportLine '## 1. Service probes'
Add-ReportLine ''

$webStatus = Invoke-HttpStatus ('http://127.0.0.1:' + $Port + '/')
if ($webStatus -eq 401 -or ($webStatus -ge 200 -and $webStatus -lt 500)) {
    Write-Ok ('dsh web port ' + $Port + ' alive (HTTP ' + $webStatus + ')')
    Add-ReportLine ('- dsh web: alive (HTTP ' + $webStatus + ')')
} elseif ($webStatus -eq 0) {
    Write-Fail ('dsh web port ' + $Port + ' DOWN. Start the service first (launcher).')
    Add-ReportLine '- dsh web: DOWN'
} else {
    Write-Warn ('dsh web port ' + $Port + ' responded HTTP ' + $webStatus)
    Add-ReportLine ('- dsh web: HTTP ' + $webStatus)
}

$ollamaStatus = Invoke-HttpStatus 'http://127.0.0.1:11434/api/tags'
if ($ollamaStatus -eq 200) {
    Write-Ok 'Ollama /api/tags: 200'
    Add-ReportLine '- Ollama /api/tags: 200'
} elseif ($ollamaStatus -eq 500) {
    Write-Warn 'Ollama /api/tags: 500 - checking models junction...'
    Add-ReportLine '- Ollama /api/tags: 500'
    $repair = Repair-OllamaModelsLink
    switch ($repair) {
        'repaired' {
            Write-Ok 'Ollama models junction repaired (dangling link moved aside, models.bak-* restored).'
            Add-ReportLine '  - repair: dangling models junction moved aside; latest models.bak-* restored'
            $ollamaStatus = Invoke-HttpStatus 'http://127.0.0.1:11434/api/tags'
            Write-Ok ('Ollama /api/tags after repair: ' + $ollamaStatus)
            Add-ReportLine ('  - Ollama /api/tags after repair: ' + $ollamaStatus)
        }
        'denied' {
            Write-Fail 'Ollama models junction repair denied (run this script from an elevated prompt, or repair manually).'
            Add-ReportLine '  - repair: DENIED (elevated prompt required); see repair records for manual steps'
        }
        'dangling-needs-repair' {
            Write-Warn 'Ollama models junction is dangling; re-run without -NoRepair to auto-repair.'
            Add-ReportLine '  - repair: dangling junction detected; -NoRepair was set'
        }
        'dangling-no-bak' {
            Write-Warn 'Ollama models junction is dangling and no models.bak-* backup exists; manual repair required.'
            Add-ReportLine '  - repair: dangling junction with no models.bak-* backup; manual repair required'
        }
        default {
            Write-Info ('Ollama models path state: ' + $repair)
            Add-ReportLine ('  - models path state: ' + $repair)
        }
    }
} elseif ($ollamaStatus -eq 0) {
    Write-Info 'Ollama not reachable (not running) - skipping.'
    Add-ReportLine '- Ollama: not reachable'
} else {
    Write-Warn ('Ollama /api/tags: ' + $ollamaStatus)
    Add-ReportLine ('- Ollama /api/tags: ' + $ollamaStatus)
}

$ovStatus = Invoke-HttpStatus 'http://127.0.0.1:1933/health'
Write-Info ('OpenViking /health: ' + $(if ($ovStatus -gt 0) { [string]$ovStatus } else { 'not reachable' }))
Add-ReportLine ('- OpenViking /health: ' + $(if ($ovStatus -gt 0) { [string]$ovStatus } else { 'not reachable' }))

# ---- phase 2: patch markers + auto re-apply ---------------------------------
Write-Host ''
Write-Info 'Phase 2/5: patch integrity (update-compatible core)'
Add-ReportLine ''
Add-ReportLine '## 2. Patch integrity'
Add-ReportLine ''

$markers = Test-PatchMarkers
$missing = @($markers | Where-Object { $_.State -ne 'OK' })
if ($missing.Count -gt 0 -and -not $NoRepair) {
    Write-Warn ('patch markers missing: ' + (($missing | ForEach-Object { $_.Id }) -join ', ') + ' - running apply-adaptations.ps1')
    Add-ReportLine ('- missing markers: ' + (($missing | ForEach-Object { $_.Id }) -join ', ') + ' -> re-applied')
    $adapt = Join-Path $script:DataDir 'apply-adaptations.ps1'
    if (Test-Path -LiteralPath $adapt) {
        & $adapt | Out-Host
        $markers = Test-PatchMarkers
    } else {
        Write-Warn 'apply-adaptations.ps1 not found; manual re-apply required.'
    }
} elseif ($missing.Count -gt 0) {
    Write-Warn ('patch markers missing: ' + (($missing | ForEach-Object { $_.Id }) -join ', ') + ' (-NoRepair set; not re-applied)')
    Add-ReportLine ('- missing markers: ' + (($missing | ForEach-Object { $_.Id }) -join ', ') + ' (not repaired)')
}

$patchOk = $true
foreach ($m in $markers) {
    $ok = $m.State -eq 'OK'
    if (-not $ok) { $patchOk = $false }
    if ($ok) { Write-Ok ('patch ' + $m.Id + ': present') }
    else { Write-Fail ('patch ' + $m.Id + ': ' + $m.State + ' (' + $m.Note + ')') }
    Add-ReportLine ('- ' + $m.Id + ': ' + $m.State)
}
$patchState = $(if ($patchOk) { 'OK' } else { 'MISSING' })
Add-ReportLine ('- patch integrity: ' + $patchState)
Add-ReportLine ''
Add-ReportLine '- watched plugin versions:'
try {
    $pj = Get-Content -LiteralPath (Join-Path $script:ProfileWeb 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in @('@linxin666/dsh-web-all', 'dsh-whale-widget', 'dsh-prompt-enhance', 'dsh-context', 'dshmarket')) {
        $v = $pj.dependencies.$p
        if (-not $v) { $v = 'not in package.json' }
        Add-ReportLine ('  - ' + $p + ': ' + $v)
    }
} catch {
    Add-ReportLine '  - (package.json unreadable)'
}

# ---- phase 3: host route smoke (authenticated) ------------------------------
Write-Host ''
Write-Info 'Phase 3/5: host route smoke'
Add-ReportLine ''
Add-ReportLine '## 3. Host route smoke'
Add-ReportLine ''

$authUrl = $LiveUrl
if (-not $authUrl) { $authUrl = Get-AuthUrlForPort $Port }
if (-not $authUrl) {
    Write-Warn 'authenticated URL not found in launcher logs; route checks will be unauthenticated (401 = route exists).'
    $origin = 'http://127.0.0.1:' + $Port
    $query = ''
} else {
    try {
        $u = New-Object System.Uri $authUrl
        $origin = $u.GetLeftPart([System.UriPartial]::Authority)
        $query = $u.Query
        Write-Ok ('authenticated URL: ' + $origin + ' (query ' + $query.Length + ' chars)')
    } catch {
        $origin = 'http://127.0.0.1:' + $Port
        $query = ''
    }
}
Add-ReportLine ('- origin: ' + $origin)

$routes = @(
    @{ Name = 'pet/pets';        Path = '/api/pet/pets';                              Method = 'GET';  Ok = { param($s) $s -eq 200 };                     Note = '200 expected (token auth works on webServer routes)' },
    @{ Name = 'pet/state';       Path = '/api/pet/state';                             Method = 'GET';  Ok = { param($s) $s -eq 200 };                     Note = '200 expected (token auth works on webServer routes)' },
    @{ Name = 'ego/watch/stop';  Path = '/api/ego/watch/stop';                        Method = 'POST'; Ok = { param($s) $s -eq 200 -or $s -eq 401 };        Note = '200 idempotent / 401 = route registered behind connection auth' },
    @{ Name = 'changes.summary'; Path = '/api/changes.summary?sessionId=none&seq=1';  Method = 'GET';  Ok = { param($s) $s -eq 404 -or $s -eq 401 -or $s -eq 400 }; Note = '404 = no changes (design behavior) / 401 = behind connection auth' }
)
$routeFail = 0
foreach ($r in $routes) {
    $s = Invoke-Api $origin $query $r.Path $r.Method
    $ok = & $r.Ok $s
    if (-not $ok) { $routeFail++ }
    $label = $(if ($ok) { 'OK' } else { 'FAIL' })
    if ($ok) { Write-Ok ($r.Name + ': HTTP ' + $s + ' - ' + $r.Note) } else { Write-Fail ($r.Name + ': HTTP ' + $s + ' - ' + $r.Note) }
    Add-ReportLine ('- ' + $r.Name + ': HTTP ' + $s + ' (' + $r.Note + ') [' + $label + ']')
}

# ---- phase 4: real browser F12 capture --------------------------------------
$capture = $null
$captureFailed = $false
if (-not $SkipCapture) {
    Write-Host ''
    Write-Info 'Phase 4/5: headless browser F12 capture (15s window)'
    Add-ReportLine ''
    Add-ReportLine '## 4. Browser F12 capture'
    Add-ReportLine ''

    if (-not $authUrl) {
        $captureFailed = $true
        Write-Warn 'no authenticated URL; skipping capture (use -LiveUrl to provide one).'
        Add-ReportLine '- skipped: no authenticated URL'
    } else {
        $browser = Find-BrowserExe
        $cdpLib = Join-Path $script:ToolsDir 'cdp-lib.mjs'
        if (-not (Test-Path -LiteralPath $cdpLib)) { $cdpLib = Join-Path $script:ToolDir 'cdp-lib.mjs' }
        if (-not $browser) {
            $captureFailed = $true
            Write-Warn 'Chrome/Edge not found; skipping capture.'
            Add-ReportLine '- skipped: browser not found'
        } elseif (-not (Test-Path -LiteralPath $cdpLib)) {
            $captureFailed = $true
            Write-Warn 'cdp-lib.mjs not found in launcher tools dir; skipping capture.'
            Add-ReportLine '- skipped: cdp-lib.mjs missing'
        } else {
            $tool = Ensure-Tool 'f12-capture.mjs' $script:CaptureTool
            $env:DSH_CDP_LIB = $cdpLib
            $env:DSH_CHROME = $browser
            $cdpPort = 9335
            $res = Invoke-NodeTool $tool @($authUrl, [string]$cdpPort, '15000')
            if ($res.ExitCode -eq 0 -and $res.Out) {
                try {
                    $capture = ($res.Out | ConvertFrom-Json)
                    $okAll = $capture.ok.pageMounted -and $capture.ok.noBootFail -and $capture.ok.noExceptions -and $capture.ok.noConsoleErrors
                    if ($okAll) { Write-Ok 'capture clean: page mounted, no boot fail, no JS console errors/exceptions.' }
                    else {
                        Write-Warn ('capture issues: ' + (($capture.ok | Get-Member -MemberType NoteProperty | Where-Object { -not $capture.ok.($_.Name) } | ForEach-Object { $_.Name }) -join ', '))
                    }
                    Add-ReportLine ('- pageMounted: ' + $capture.ok.pageMounted)
                    Add-ReportLine ('- noBootFail: ' + $capture.ok.noBootFail)
                    Add-ReportLine ('- noExceptions: ' + $capture.ok.noExceptions)
                    Add-ReportLine ('- noConsoleErrors: ' + $capture.ok.noConsoleErrors)
                    Add-ReportLine ('- httpErrors captured: ' + @($capture.httpErrors).Count)
                    Add-ReportLine ('- logWarnings captured: ' + @($capture.logWarnings).Count)
                } catch {
                    Write-Warn 'capture JSON parse failed; see tool output files in launcher logs dir.'
                    Add-ReportLine '- capture: JSON parse failed'
                }
            } else {
                $captureFailed = $true
                Write-Warn ('capture failed (exit ' + $res.ExitCode + ').')
                Add-ReportLine ('- capture failed (exit ' + $res.ExitCode + ')')
            }
        }
    }
} else {
    Write-Info 'Phase 4/5: skipped (-SkipCapture)'
    Add-ReportLine ''
    Add-ReportLine '## 4. Browser F12 capture'
    Add-ReportLine '- skipped (-SkipCapture)'
}

# ---- phase 5: classification + report ---------------------------------------
Write-Host ''
Write-Info 'Phase 5/5: classification + report'
Add-ReportLine ''
Add-ReportLine '## 5. Classification'
Add-ReportLine ''

$classCounts = @{}
if ($capture) {
    $entries = @()
    foreach ($e in @($capture.consoleErrors))    { $entries += @{ Kind = 'console'; Text = [string]$e; Status = 0; Url = '' } }
    foreach ($e in @($capture.exceptions))       { $entries += @{ Kind = 'exception'; Text = [string]$e; Status = 0; Url = '' } }
    foreach ($e in @($capture.logErrors))        { $entries += @{ Kind = 'log'; Text = [string]$e; Status = 0; Url = '' } }
    foreach ($e in @($capture.httpErrors))       {
        $st = 0
        [int]::TryParse([string]$e.status, [ref]$st) | Out-Null
        $entries += @{ Kind = 'http'; Text = ''; Status = $st; Url = [string]$e.url }
    }
    foreach ($entry in $entries) {
        $sig = Classify-Entry $entry.Kind $entry.Text $entry.Status $entry.Url
        if ($classCounts.ContainsKey($sig)) { $classCounts[$sig]++ } else { $classCounts[$sig] = 1 }
    }
    if ($classCounts.Count -eq 0) {
        Write-Ok 'no console/network errors to classify.'
        Add-ReportLine '- no errors to classify'
    } else {
        foreach ($k in ($classCounts.Keys | Sort-Object)) {
            $n = $classCounts[$k]
            $isDesign = $k -match 'changes-summary-404|net-abort'
            if ($isDesign) { Write-Info ('  ' + $k + ' x ' + $n + ' (design/benign)') }
            else { Write-Warn ('  ' + $k + ' x ' + $n) }
            Add-ReportLine ('- ' + $k + ' x ' + $n + $(if ($isDesign) { ' [design/benign]' } else { '' }))
        }
    }
} else {
    Write-Info 'no capture data (skipped or failed); classification limited to route smoke.'
    Add-ReportLine '- no capture data'
}

$verdictOk = ($webStatus -ne 0) -and $patchOk -and ($routeFail -eq 0) -and (-not $captureFailed) -and
    ($null -eq $capture -or ($capture.ok.pageMounted -and $capture.ok.noBootFail -and $capture.ok.noExceptions -and $capture.ok.noConsoleErrors))

Add-ReportLine ''
Add-ReportLine ('- overall: ' + $(if ($verdictOk) { 'PASS' } else { 'REVIEW' }))

Write-TextNoBom $script:ReportPath ($script:Report -join "`r`n")

# temp capture files cleanup (report already written)
Get-ChildItem -LiteralPath $script:DataDir -Filter '.f12-*.txt' -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($verdictOk) {
    Write-Ok 'F12 self-check PASS. Core flows are clean and update-compatible patches are in place.'
} else {
    Write-Warn 'F12 self-check finished with items to review. See the report and classification above.'
}
Write-Ok ('report: ' + $script:ReportPath)
exit $(if ($verdictOk) { 0 } else { 1 })
