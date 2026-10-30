<#
.SYNOPSIS
    ePortal 会话保活工具（后台常驻版）

.DESCRIPTION
    定期向认证服务器发送 keepalive，防止会话被网关静默回收。
    已验证：该 portal 的 keepalive 能有效续期，且 token 不会轮换。

    仅使用你本人的 userIndex 维持自己的会话。

.PARAMETER UserIndex
    会话标识。可从 success.jsp 链接中提取。

.PARAMETER FromClipboard
    从剪贴板提取（复制 success.jsp 完整链接即可）。

.PARAMETER IntervalMinutes
    保活间隔（分钟），默认 3。

.PARAMETER Background
    以隐藏窗口后台运行（日志写入 keepalive.log）。

.PARAMETER Once
    只探测一次，用于验证 token 是否有效。

.EXAMPLE
    .\rea-keepalive.ps1 -FromClipboard -Once
    .\rea-keepalive.ps1 -FromClipboard -Background
    .\rea-keepalive.ps1 -UserIndex "<从 success.jsp 复制的 userIndex>" -IntervalMinutes 5
#>
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$UserIndex,
    [string]$ConfigPath = '',
    [int]$IntervalMinutes = 3,
    [string]$Portal = 'http://10.130.128.9/eportal/InterFace.do?method=',
    [string]$LogFile = '',
    [string]$LoginUrl = 'http://10.130.128.9/',
    [switch]$FromClipboard,
    [switch]$Once,
    [switch]$Background,
    [switch]$OpenLoginOnFail
)

$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'rea-connect.config.json' }
if (-not $LogFile) { $LogFile = Join-Path $PSScriptRoot 'keepalive.log' }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERR' { 'Red' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 2MB) {
            Move-Item $LogFile "$LogFile.1" -Force
        }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch { }
}

function Get-UserIndexFromText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $m = [regex]::Match($Text, 'userIndex=([^&\s"'']+)')
    if ($m.Success) { return $m.Groups[1].Value }
    $t = $Text.Trim()
    if ($t -match '^[0-9a-zA-Z]{8,}_[\d.]+_\d+$') { return $t }
    return $null
}

function Invoke-Portal {
    param([string]$Method, [string]$Ui)
    $r = Invoke-WebRequest -Uri ($Portal + $Method) -Method POST `
        -Body "userIndex=$([Uri]::EscapeDataString($Ui))" `
        -ContentType 'application/x-www-form-urlencoded; charset=UTF-8' `
        -UseBasicParsing -TimeoutSec 15
    $text = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    try { return ($text | ConvertFrom-Json) } catch { return [pscustomobject]@{ result = 'unknown'; message = $text } }
}

# ---------- 解析 token ----------
if (-not $UserIndex -and -not $FromClipboard -and (Test-Path $ConfigPath)) {
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $UserIndex = $cfg.userIndex
    if ($UserIndex) { Write-Log "已从配置读取 userIndex：$($UserIndex.Substring(0,[Math]::Min(12,$UserIndex.Length)))…" }
}
if (-not $UserIndex -and $FromClipboard) {
    $clip = try { Get-Clipboard -Raw } catch { '' }
    $UserIndex = Get-UserIndexFromText -Text $clip
    if (-not $UserIndex) {
        Write-Log '剪贴板里没有 userIndex，请复制 success.jsp 的完整链接' 'ERR'
        exit 1
    }
    Write-Log "已从剪贴板提取 userIndex：$($UserIndex.Substring(0,[Math]::Min(12,$UserIndex.Length)))…"
}
elseif ($UserIndex) {
    $parsed = Get-UserIndexFromText -Text $UserIndex
    if ($parsed) { $UserIndex = $parsed }
}

if (-not $UserIndex) {
    Write-Log '缺少 userIndex。用法：.\rea-keepalive.ps1 -ConfigPath <配置>  或  -FromClipboard  或  -UserIndex <值>' 'ERR'
    exit 1
}

# ---------- 单次探测 ----------
if ($Once) {
    try {
        $r = Invoke-Portal -Method 'keepalive' -Ui $UserIndex
        if ($r.result -eq 'success') { Write-Log '会话有效，keepalive 成功' 'OK'; exit 0 }
        Write-Log "会话无效：$($r.message)" 'WARN'
        exit 2
    }
    catch { Write-Log "请求失败：$($_.Exception.Message)" 'ERR'; exit 3 }
}

# ---------- 后台启动 ----------
if ($Background) {
    $exe = (Get-Process -Id $PID).Path
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
        '-IntervalMinutes', $IntervalMinutes,
        '-Portal', "`"$Portal`"", '-LogFile', "`"$LogFile`""
    )
    if ($PSBoundParameters.ContainsKey('UserIndex') -or $FromClipboard) {
        $argList += @('-UserIndex', "`"$UserIndex`"")
    } else {
        $argList += @('-ConfigPath', "`"$ConfigPath`"")
    }
    if ($OpenLoginOnFail) { $argList += '-OpenLoginOnFail' }
    $child = Start-Process -FilePath $exe -ArgumentList $argList -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 1
    if ($child.HasExited) { Write-Host '后台启动失败，请查看日志。' -ForegroundColor Red; exit 1 }
    Write-Host "已启动后台保活进程（每 ${IntervalMinutes} 分钟一次）" -ForegroundColor Green
    Write-Host "日志：$LogFile" -ForegroundColor DarkGray
    Write-Host '查看状态：Get-Content .\keepalive.log -Tail 10' -ForegroundColor DarkGray
    Write-Host '停止：Get-Process pwsh | Where-Object { $_.CommandLine -like "*rea-keepalive*" } | Stop-Process' -ForegroundColor DarkGray
    exit 0
}

# ---------- 前台循环 ----------
$mutex = [Threading.Mutex]::new($false, 'Local\REA-ePortal-Keepalive')
try { $acquired = $mutex.WaitOne(0) } catch { $acquired = $true }
if (-not $acquired) { Write-Log '已有保活进程在运行，退出' 'WARN'; exit 0 }

Write-Log "开始保活 | 间隔 ${IntervalMinutes} 分钟 | token $($UserIndex.Substring(0,[Math]::Min(12,$UserIndex.Length)))…"
Write-Log '按 Ctrl+C 停止'

$failures = 0
$consecutiveOk = 0

while ($true) {
    try {
        $r = Invoke-Portal -Method 'keepalive' -Ui $UserIndex

        # 若服务端下发新 token，自动跟随
        if ($r.PSObject.Properties.Name -contains 'userIndex' -and $r.userIndex -and $r.userIndex -ne 'null' -and $r.userIndex -ne $UserIndex) {
            Write-Log '服务端下发新 token，已切换' 'WARN'
            $UserIndex = $r.userIndex
        }

        if ($r.result -eq 'success') {
            $failures = 0
            $consecutiveOk++
            # 每 20 次成功才记一条，避免日志膨胀
            if ($consecutiveOk -eq 1 -or $consecutiveOk % 20 -eq 0) {
                Write-Log "保活成功（累计 $consecutiveOk 次）" 'OK'
            }
        }
        else {
            $failures++
            Write-Log "保活被拒：$($r.message)（连续 $failures 次）" 'WARN'
            if ($failures -ge 2) {
                Write-Log '会话已失效，需要重新认证' 'ERR'
                if ($OpenLoginOnFail) { Start-Process $LoginUrl }
                if ($failures -ge 3) { Write-Log '连续 3 次失败，退出' 'ERR'; exit 2 }
            }
        }
    }
    catch {
        $failures++
        Write-Log "网络异常：$($_.Exception.Message)（连续 $failures 次）" 'ERR'
        if ($failures -ge 5) { Write-Log '连续网络异常，退出' 'ERR'; exit 3 }
    }

    Start-Sleep -Seconds ($IntervalMinutes * 60)
}
