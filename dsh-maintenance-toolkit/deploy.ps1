# =============================================================================
#  deploy.ps1 - verify / copy dsh-maintenance-toolkit into the deployed layout
#  (pure ASCII on purpose: safe under Windows PowerShell 5.1 ANSI parsing;
#   saved as UTF-8 with BOM + CRLF by the packager)
#
#  Layout contract (same as SKILL.md):
#    repo\data\*           -> <launcher root>\deepseek-Harness插件及其数据\
#    repo\launcher-root\*  -> <launcher root>\           (tools\ only)
#    repo\docs\*.md        -> <launcher root>\deepseek-Harness插件及其数据\
#
#  Usage:
#    powershell -ExecutionPolicy Bypass -File deploy.ps1              # verify only
#    powershell -ExecutionPolicy Bypass -File deploy.ps1 -Apply       # copy changed/missing
#    powershell -ExecutionPolicy Bypass -File deploy.ps1 -Root <dir> [-Apply]
#
#  Default target root: auto-detected by walking up from this repo until
#  a directory containing both runtime\ and deepseek-Harness插件及其数据\
#  is found (the launcher root). The repo itself may live anywhere.
#  Exit code: 0 = all consistent, 1 = differences found (verify mode)
#  or a copy error.
# =============================================================================
[CmdletBinding()]
param(
    [string]$Root = '',
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$Repo = $PSScriptRoot
if (-not $Root) {
    $Root = $Repo
    while ($true) {
        if ((Test-Path -LiteralPath (Join-Path $Root 'runtime')) -and
            (Test-Path -LiteralPath (Join-Path $Root 'deepseek-Harness插件及其数据'))) { break }
        $parent = Split-Path -Parent $Root
        if (-not $parent -or $parent -eq $Root) { $Root = ''; break }
        $Root = $parent
    }
    if (-not $Root) {
        $Root = Split-Path -Parent $Repo
        Write-Warning 'launcher root not auto-detected; falling back to repo parent. Pass -Root to override.'
    }
}
$DataDir = Join-Path $Root 'deepseek-Harness插件及其数据'

Write-Host '=== dsh-maintenance-toolkit deploy/verify ==='
Write-Host ("repo : {0}" -f $Repo)
Write-Host ("root : {0}" -f $Root)
Write-Host ("data : {0}" -f $DataDir)
Write-Host ("mode : {0}" -f (& { if ($Apply) { 'APPLY' } else { 'VERIFY-ONLY' } }))
Write-Host ''

$pairs = New-Object System.Collections.Generic.List[object]
foreach ($map in @(
    @{ Src = (Join-Path $Repo 'data');          Dst = $DataDir; Name = 'data' },
    @{ Src = (Join-Path $Repo 'launcher-root'); Dst = $Root;    Name = 'launcher-root' }
)) {
    if (-not (Test-Path -LiteralPath $map.Src)) { Write-Warning ("missing source dir: " + $map.Src); continue }
    Get-ChildItem -LiteralPath $map.Src -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($map.Src.Length).TrimStart('\','/')
        $pairs.Add(@{ Src = $_.FullName; Dst = (Join-Path $map.Dst $rel) })
    }
}
foreach ($f in @(
    @{ Src = (Join-Path $Repo 'docs\DSH宿主升级SOP.md');    Dst = (Join-Path $DataDir 'DSH宿主升级SOP.md') },
    @{ Src = (Join-Path $Repo 'docs\F12自查修复流程说明.md'); Dst = (Join-Path $DataDir 'F12自查修复流程说明.md') },
    @{ Src = (Join-Path $Repo 'docs\插件无损升级流程.md');    Dst = (Join-Path $DataDir '插件无损升级流程.md') }
)) {
    if (Test-Path -LiteralPath $f.Src) { $pairs.Add(@{ Src = $f.Src; Dst = $f.Dst }) }
}

if ($pairs.Count -eq 0) { Write-Error 'nothing to deploy (repo layout broken?)'; exit 1 }

$ok = 0; $diff = 0; $missing = 0; $copied = 0
foreach ($p in $pairs) {
    $label = $p.Dst.Substring($Root.Length).TrimStart('\','/')
    if (Test-Path -LiteralPath $p.Dst) {
        $h1 = (Get-FileHash -LiteralPath $p.Src -Algorithm SHA256).Hash
        $h2 = (Get-FileHash -LiteralPath $p.Dst -Algorithm SHA256).Hash
        if ($h1 -eq $h2) { $ok++; Write-Host ("  [OK]   {0}" -f $label) }
        else {
            $diff++
            if ($Apply) {
                Copy-Item -LiteralPath $p.Src -Destination $p.Dst -Force
                $copied++; Write-Host ("  [COPY] {0} (content differs)" -f $label) -ForegroundColor Yellow
            } else {
                Write-Host ("  [DIFF] {0} (content differs; run -Apply to overwrite)" -f $label) -ForegroundColor Yellow
            }
        }
    } else {
        $missing++
        if ($Apply) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p.Dst) | Out-Null
            Copy-Item -LiteralPath $p.Src -Destination $p.Dst -Force
            $copied++; Write-Host ("  [COPY] {0} (was missing)" -f $label) -ForegroundColor Yellow
        } else {
            Write-Host ("  [MISS] {0}" -f $label) -ForegroundColor Red
        }
    }
}

Write-Host ''
Write-Host ("checked {0} files: {1} consistent, {2} differ, {3} missing" -f $pairs.Count, $ok, $diff, $missing)
if ($Apply) { Write-Host ("copied {0} file(s)." -f $copied) }

if (-not (Test-Path -LiteralPath (Join-Path $DataDir 'dsh-home'))) {
    Write-Warning ("dsh-home not found under data dir: scripts will not run until the real data dir exists (this repo is a toolkit, not the launcher itself).")
}

if ($Apply) {
    if ($diff -eq 0 -and $missing -eq 0) { Write-Host 'nothing to copy.'; exit 0 }
    exit 0
} else {
    if ($diff -eq 0 -and $missing -eq 0) { Write-Host 'verify passed.'; exit 0 }
    Write-Host 'differences found: run with -Apply to copy.' -ForegroundColor Yellow
    exit 1
}