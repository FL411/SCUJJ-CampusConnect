#Requires -Version 5.1
<#
构建分享包：把根目录的“应用文件”复制到临时目录并压缩为 dist\CampusConnect.zip。
不会包含个人配置、日志、缓存、review、tools、dist 自身。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dist = Join-Path $root 'dist'
$zip = Join-Path $dist 'CampusConnect.zip'
$files = @(
    'CampusConnect.ps1',
    'CampusConnect.cmd',
    'CampusConnect.vbs',
    'rea-daemon.ps1',
    'rea-daemon-watchdog.vbs',
    'rea-connect.ps1',
    'rea-keepalive.ps1',
    'README.txt'
)

if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Force -Path $dist | Out-Null }
$stage = Join-Path $env:TEMP ('CampusConnect-build-' + [guid]::NewGuid().ToString('N'))
$app = Join-Path $stage 'CampusConnect'
New-Item -ItemType Directory -Force -Path $app | Out-Null
try {
    foreach ($f in $files) {
        $src = Join-Path $root $f
        if (-not (Test-Path $src)) { throw "缺少文件：$f" }
        Copy-Item $src (Join-Path $app $f) -Force
    }
    Compress-Archive -Path $app -DestinationPath $zip -Force
    "built $zip ($((Get-Item $zip).Length) bytes)"
} finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}
