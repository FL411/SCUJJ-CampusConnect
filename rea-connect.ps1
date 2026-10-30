<#
.SYNOPSIS
    ePortal 自动连接 / 保活一体化工具

.DESCRIPTION
    -Setup : 一次性配置。注销当前会话 → 捕获 NAS 重定向 → 抓取登录页 →
             解析 RSA 公钥 → 提示输入账号密码 → 登录验证 → 保存加密凭据。
    默认    : 日常运行。在线则保活；离线则自动重登录。

    密码使用 Windows DPAPI 加密存储（仅当前用户可解密），不落明文。

.EXAMPLE
    .\rea-connect.ps1 -Setup
    .\rea-connect.ps1
#>
#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Setup,
    [switch]$Auto,
    [switch]$NonInteractive,
    [switch]$SaveOnly,
    [string]$User,
    [Security.SecureString]$SecurePassword,
    [string[]]$CampusSsids = @(),
    [string[]]$CampusPrefixes = @('10.13'),
    [string]$Portal = 'http://10.130.128.9',
    [string]$ProbeUrl = 'http://connect.rom.miui.com/generate_204',
    [string]$ConfigPath = '',
    [string]$DumpDir = '',
    [int]$IntervalMinutes = 3
)

$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'rea-connect.config.json' }
if (-not $DumpDir) { $DumpDir = Join-Path $PSScriptRoot 'dump' }
# 兼容 -File 命令行传入的逗号分隔值
$CampusSsids = @($CampusSsids | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$CampusPrefixes = @($CampusPrefixes | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
New-Item -ItemType Directory -Force -Path $DumpDir | Out-Null

function Write-Step { param($m) Write-Host "`n» $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "  ✓ $m" -ForegroundColor Green }
function Write-Warn2{ param($m) Write-Host "  ! $m" -ForegroundColor Yellow }
function Write-Err2 { param($m) Write-Host "  ✗ $m" -ForegroundColor Red }

# ---------- 工具函数 ----------
function Convert-HexToBytes {
    param([string]$Hex)
    $Hex = $Hex.Trim() -replace '[^0-9a-fA-F]', ''
    if ($Hex.Length % 2) { $Hex = '0' + $Hex }
    $bytes = New-Object byte[] ($Hex.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16)
    }
    return $bytes
}

function Get-JsEncode {
    param([string]$s)
    $sb = [Text.StringBuilder]::new()
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -match '[A-Za-z0-9\-_.!~*''()]') { [void]$sb.Append($ch) }
        elseif ($ch -eq ' ') { [void]$sb.Append('%20') }
        else {
            $bytes = [Text.Encoding]::UTF8.GetBytes([string]$ch)
            foreach ($b in $bytes) { [void]$sb.Append('%' + $b.ToString('X2')) }
        }
    }
    return $sb.ToString()
}

function Get-PlainText {
    param([Security.SecureString]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-RsaHex {
    param([string]$Text, [string]$ModulusHex, [string]$ExponentHex)
    $rsa = [Security.Cryptography.RSA]::Create()
    $p = [Security.Cryptography.RSAParameters]::new()
    $p.Modulus = Convert-HexToBytes $ModulusHex
    $p.Exponent = Convert-HexToBytes $ExponentHex
    $rsa.ImportParameters($p)
    $enc = $rsa.Encrypt([Text.Encoding]::UTF8.GetBytes($Text), [Security.Cryptography.RSAEncryptionPadding]::Pkcs1)
    return (-join ($enc | ForEach-Object { $_.ToString('x2') }))
}

function Get-HttpProbe {
    <# 不跟随跳转的轻量 HTTP 探测，兼容 Windows PowerShell 5.1 #>
    param([string]$Url)
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.AllowAutoRedirect = $false
    $req.Timeout = 6000
    $req.UserAgent = 'Mozilla/5.0'
    $resp = $null
    try { $resp = $req.GetResponse() }
    catch [System.Net.WebException] { $resp = $_.Exception.Response }
    if (-not $resp) { return @{ Code = $null; Location = $null; Body = '' } }
    $code = [int]$resp.StatusCode
    $loc = [string]$resp.Headers['Location']
    $body = ''
    try {
        $stream = $resp.GetResponseStream()
        if ($stream) {
            $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::UTF8)
            $body = $reader.ReadToEnd()
            $reader.Close()
        }
    } catch { }
    $resp.Close()
    return @{ Code = $code; Location = $loc; Body = $body }
}

function Test-OnlineState {
    <# 返回 @{ Online=$true/false/unknown; Location=$null/url } #>
    $p = Get-HttpProbe $ProbeUrl
    if ($p.Code -eq 204) { return @{ Online = $true; Location = $null } }
    if ($p.Code -eq 200) {
        $body = [string]$p.Body
        # 200 拦截页：从 JS/meta 跳转里提取登录地址
        $m = [regex]::Match($body, "(?is)(?:location\.href|location\.replace|window\.location)\s*(?:=|\()\s*['""]([^'""]+)['""]")
        if (-not $m.Success) { $m = [regex]::Match($body, "(?is)http-equiv=[""']refresh[""'][^>]*content=[""'][^;]+;\s*url=([^'""]+)") }
        if ($m.Success) { return @{ Online = $false; Location = $m.Groups[1].Value } }
        if ($ProbeUrl -notlike '*generate_204*') { return @{ Online = $true; Location = $null } }
    }
    if ($p.Code -in 301, 302, 303, 307, 308) { return @{ Online = $false; Location = $p.Location } }
    if ($p.Code -ge 400) { return @{ Online = $false; Location = $null } }
    if ($null -eq $p.Code) { return @{ Online = $null; Location = $null } }
    return @{ Online = $false; Location = $null }
}

function Invoke-InterFace {
    param([string]$Method, [string]$Body)
    $url = "$Portal/eportal/InterFace.do?method=$Method"
    $r = Invoke-WebRequest -Uri $url -Method POST -Body $Body `
        -ContentType 'application/x-www-form-urlencoded; charset=UTF-8' `
        -UseBasicParsing -TimeoutSec 20
    $text = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    try { return ($text | ConvertFrom-Json) } catch { return [pscustomobject]@{ result = 'unknown'; message = $text } }
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

# ============================================================
#  Setup 模式
# ============================================================
if ($Setup) {
    $token = $null
    $redirect = $null

    if ($SaveOnly) {
        Write-Step '保存账号密码（不联网，稍后由守护进程自动认证）'
        if ($User) {
            $user = $User
        } else {
            $user = Read-Host '  账号'
        }
        if (-not $user) { Write-Err2 '账号不能为空。'; exit 1 }
        $sec = if ($SecurePassword) { $SecurePassword } else { Read-Host '  密码' -AsSecureString }

        $cfg = [ordered]@{
            user           = $user
            passwordEnc    = (ConvertFrom-SecureString $sec)
            service        = ''
            portal         = $Portal
            savedAt        = (Get-Date).ToString('s')
            userIndex      = $null
            redirect       = $null
            campusPrefixes = @($CampusPrefixes)
            campusSsids    = @()
        }
        $cfg | ConvertTo-Json -Depth 4 | Set-Content $ConfigPath -Encoding UTF8
        Write-Ok "已保存 $ConfigPath"
        Write-Host '  守护进程会在 Windows 连接到需要认证的 WiFi 时自动登录。' -ForegroundColor DarkGray
        exit 0
    }

    if ($Auto) {
        Write-Step '自动捕获登录页'
        $maxTry = if ($NonInteractive) { 40 } else { 10 }
        for ($i = 0; $i -lt $maxTry; $i++) {
            $s = Test-OnlineState
            if ($s.Online -eq $false -and $s.Location) { $redirect = $s.Location; break }
            if ($s.Online -eq $true) {
                if ($i -eq 0) {
                    Write-Warn2 '当前已在线。安装/重配需要先下线一次。'
                    Write-Host "  正在打开门户：$Portal" -ForegroundColor DarkGray
                    try { Start-Process $Portal } catch { }
                    if ($NonInteractive) {
                        Write-Host '  请在浏览器中点击「下线」，安装会自动继续（最多等 2 分钟）…' -ForegroundColor Yellow
                    } else {
                        Write-Host '  请在浏览器中点击「下线」，然后回到这里按回车…' -ForegroundColor Yellow
                    }
                }
                if ($NonInteractive) { Start-Sleep -Seconds 3 } else { Read-Host | Out-Null }
            }
            else {
                Start-Sleep -Seconds 2
            }
        }
        if (-not $redirect) { Write-Err2 '未捕获到登录页。请确认已连接校园 WiFi 且已下线。'; exit 2 }
        Write-Ok '已捕获登录页'
    }
    else {
        Write-Step '检查当前网络状态'
        $state = Test-OnlineState
        Write-Host ("  在线状态: {0}" -f ($(if ($state.Online -eq $true) { '在线' } elseif ($state.Online -eq $false) { '离线/被劫持' } else { '未知' })))

        if ($state.Online -eq $true) {
            Write-Step '注销当前会话以触发登录页'
            Write-Host '  请把 success.jsp 链接复制到剪贴板（用于注销），或直接回车跳过' -ForegroundColor DarkGray
            $clip = try { Get-Clipboard -Raw } catch { '' }
            $token = Get-UserIndexFromText -Text $clip
            if (-not $token) {
                $token = Get-UserIndexFromText -Text (Read-Host '  粘贴 success.jsp 链接或 userIndex')
            }
            if (-not $token) { Write-Err2 '没有可用 token，无法主动注销。请先在浏览器点「下线」后重新运行本脚本。'; exit 1 }

            $body = "userIndex=$([Uri]::EscapeDataString($token))"
            $res = Invoke-InterFace -Method 'logout' -Body $body
            Write-Ok "已请求注销：$($res.result) $($res.message)"
            Start-Sleep -Seconds 2
        }

        Write-Step '等待 NAS 重定向（最多 90 秒）'
        Write-Host '  正在探测未认证跳转…' -ForegroundColor DarkGray
        $deadline = (Get-Date).AddSeconds(90)
        while ((Get-Date) -lt $deadline) {
            $s = Test-OnlineState
            if ($s.Online -eq $false -and $s.Location) { $redirect = $s.Location; break }
            Start-Sleep -Seconds 2
        }

        if (-not $redirect) {
            Write-Err2 '未捕获到重定向。可能：1) 仍在线 2) 网关不做 HTTP 劫持'
            Write-Host '  请手动在浏览器打开任意 http 网站，被跳到登录页后复制地址栏，然后运行：' -ForegroundColor Yellow
            Write-Host '  .\rea-connect.ps1 -Setup  并粘贴该地址' -ForegroundColor Yellow
            $manual = Read-Host '  直接粘贴登录页完整地址（回车跳过）'
            if ($manual) { $redirect = $manual.Trim() } else { exit 2 }
        }
        Write-Ok "捕获到：$redirect"
    }

    Write-Step '抓取登录页'
    $lr = Invoke-WebRequest -Uri $redirect -UseBasicParsing -TimeoutSec 20
    $html = [System.Text.Encoding]::GetEncoding(936).GetString($lr.RawContentStream.ToArray())
    $loginFile = Join-Path $DumpDir 'login-page.html'
    [IO.File]::WriteAllText($loginFile, $html, [Text.Encoding]::UTF8)
    Write-Ok "已保存 $loginFile ($($html.Length) 字符)"
    if ($html -match '(?is)<title>(.*?)</title>') { Write-Host "  标题: $($matches[1].Trim())" }

    Write-Step '解析 RSA 公钥'
    $mod = $null; $exp = $null
    foreach ($pat in @(
        '(?i)id=["'']publicKeyModulus["''][^>]*value=["'']([0-9a-fA-F]+)',
        '(?i)name=["'']publicKeyModulus["''][^>]*value=["'']([0-9a-fA-F]+)',
        '(?i)publicKeyModulus\s*=\s*["'']([0-9a-fA-F]+)'
    )) { $m = [regex]::Match($html, $pat); if ($m.Success) { $mod = $m.Groups[1].Value; break } }
    foreach ($pat in @(
        '(?i)id=["'']publicKeyExponent["''][^>]*value=["'']([0-9a-fA-F]+)',
        '(?i)name=["'']publicKeyExponent["''][^>]*value=["'']([0-9a-fA-F]+)',
        '(?i)publicKeyExponent\s*=\s*["'']([0-9a-fA-F]+)'
    )) { $m = [regex]::Match($html, $pat); if ($m.Success) { $exp = $m.Groups[1].Value; break } }

    if ($mod) { Write-Ok "modulus 长度 $($mod.Length)" } else { Write-Warn2 '未找到 publicKeyModulus（可能用明文模式）' }
    if ($exp) { Write-Ok "exponent: $exp" } else { Write-Warn2 '未找到 publicKeyExponent' }

    # 服务列表
    $services = @()
    foreach ($m in [regex]::Matches($html, '(?is)<option[^>]*value=["'']([^"'']*)["''][^>]*>(.*?)</option>')) {
        $services += [pscustomobject]@{ Value = $m.Groups[1].Value; Text = ($m.Groups[2].Value -replace '<[^>]+>', '').Trim() }
    }
    if ($services.Count) {
        Write-Host '  可选服务：'
        $services | ForEach-Object { Write-Host "    [$($_.Value)] $($_.Text)" }
    }

    Write-Step '输入账号密码'
    $defUser = if ($token) { ($token -split '_')[-1] } else { '' }
    if ($User) {
        $user = $User
    } else {
        $user = Read-Host "  账号$(if($defUser){" [$defUser]"})"
        if (-not $user) { $user = $defUser }
    }
    $sec = if ($SecurePassword) { $SecurePassword } else { Read-Host '  密码' -AsSecureString }
    $plain = Get-PlainText $sec

    $service = if ($services.Count -gt 0) { $services[0].Value } else { '' }
    $search = if ($redirect -match '\?(.+)$') { $matches[1] } else { '' }
    $qs = Get-JsEncode (Get-JsEncode $search)

    Write-Step '尝试登录（RSA 加密）'
    $loginOk = $false
    $result = $null
    if ($mod -and $exp) {
        $chars = $plain.ToCharArray(); [array]::Reverse($chars); $rev = -join $chars
        try {
            $enc = Get-RsaHex -Text $rev -ModulusHex $mod -ExponentHex $exp
            $body = "userId=$([Uri]::EscapeDataString($user))&password=$enc&service=$([Uri]::EscapeDataString($service))&queryString=$qs&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=true"
            $result = Invoke-InterFace -Method 'login' -Body $body
            Write-Host "  响应: $($result.result) | $($result.message)"
            if ($result.result -eq 'success') { $loginOk = $true }
        } catch { Write-Err2 "RSA 登录异常：$($_.Exception.Message)" }
    }

    if (-not $loginOk) {
        Write-Step '尝试明文模式'
        try {
            $body = "userId=$([Uri]::EscapeDataString($user))&password=$([Uri]::EscapeDataString($plain))&service=$([Uri]::EscapeDataString($service))&queryString=$qs&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false"
            $result = Invoke-InterFace -Method 'login' -Body $body
            Write-Host "  响应: $($result.result) | $($result.message)"
            if ($result.result -eq 'success') { $loginOk = $true }
        } catch { Write-Err2 "明文登录异常：$($_.Exception.Message)" }
    }

    if (-not $loginOk) {
        Write-Err2 '自动登录失败。'
        Write-Host "  登录页已保存在：$loginFile" -ForegroundColor Yellow
        Write-Host '  请在浏览器手动登录，然后把上面的 dump 目录内容发给分析者。' -ForegroundColor Yellow
        exit 3
    }

    Write-Step '保存配置'
    $cfg = [ordered]@{
        user           = $user
        passwordEnc    = (ConvertFrom-SecureString $sec)
        service        = $service
        portal         = $Portal
        savedAt        = (Get-Date).ToString('s')
        userIndex      = $result.userIndex
        redirect       = $redirect
        campusPrefixes = @($CampusPrefixes)
        campusSsids    = @($CampusSsids)
    }
    $cfg | ConvertTo-Json -Depth 4 | Set-Content $ConfigPath -Encoding UTF8
    Write-Ok "已保存 $ConfigPath（密码经 DPAPI 加密）"
    if ($result.userIndex) {
        $preview = [string]$result.userIndex
        if ($preview.Length -gt 12) { $preview = $preview.Substring(0,12) }
        Write-Ok "当前 userIndex：$preview…"
    }
    Write-Host "`n配置完成。日常直接运行：.\rea-connect.ps1" -ForegroundColor Green
    exit 0
}

# ============================================================
#  日常模式
# ============================================================
if (-not (Test-Path $ConfigPath)) {
    Write-Err2 "未找到配置 $ConfigPath，请先运行：.\rea-connect.ps1 -Setup"
    exit 1
}
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

Write-Step '检查网络状态'
$state = Test-OnlineState
if ($state.Online -eq $true) {
    Write-Ok '当前在线，仅执行保活'
    $daemonRunning = $false
    try { $m = [Threading.Mutex]::OpenExisting('Local\REA-ePortal-Daemon'); $m.Dispose(); $daemonRunning = $true } catch { }
    if ($daemonRunning) {
        Write-Ok '守护进程已在运行，无需额外保活'
        exit 0
    }
    $token = $cfg.userIndex
    if (-not $token) {
        $clip = try { Get-Clipboard -Raw } catch { '' }
        $token = Get-UserIndexFromText -Text $clip
    }
    if ($token) {
        $kaArgs = if ($cfg.userIndex) { @{ ConfigPath = $ConfigPath } } else { @{ UserIndex = $token } }
        & (Join-Path $PSScriptRoot 'rea-keepalive.ps1') @kaArgs -IntervalMinutes $IntervalMinutes -Background
    } else {
        Write-Warn2 '配置和剪贴板里都没有 userIndex。请先运行 -Setup，或在浏览器打开门户复制 success.jsp 链接后重试。'
    }
    exit 0
}

Write-Step '当前离线，尝试自动登录'
$redirect = $state.Location
if (-not $redirect) { $redirect = (Test-OnlineState).Location }
if (-not $redirect) { Write-Err2 '无法获取登录页地址（网关未做 HTTP 劫持）。请手动登录一次。'; exit 2 }
$lr = Invoke-WebRequest -Uri $redirect -UseBasicParsing -TimeoutSec 20
$html = [System.Text.Encoding]::GetEncoding(936).GetString($lr.RawContentStream.ToArray())

$mod = $null; $exp = $null
$m = [regex]::Match($html, '(?i)(?:id|name)=["'']publicKeyModulus["''][^>]*value=["'']([0-9a-fA-F]+)')
if ($m.Success) { $mod = $m.Groups[1].Value }
$m = [regex]::Match($html, '(?i)(?:id|name)=["'']publicKeyExponent["''][^>]*value=["'']([0-9a-fA-F]+)')
if ($m.Success) { $exp = $m.Groups[1].Value }

$search = if ($redirect -match '\?(.+)$') { $matches[1] } else { '' }
$qs = Get-JsEncode (Get-JsEncode $search)
$sec = ConvertTo-SecureString $cfg.passwordEnc
$plain = Get-PlainText $sec

$ok = $false
if ($mod -and $exp) {
    $chars = $plain.ToCharArray(); [array]::Reverse($chars)
    $enc = Get-RsaHex -Text (-join $chars) -ModulusHex $mod -ExponentHex $exp
    $body = "userId=$([Uri]::EscapeDataString($cfg.user))&password=$enc&service=$([Uri]::EscapeDataString($cfg.service))&queryString=$qs&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=true"
    $res = Invoke-InterFace -Method 'login' -Body $body
    Write-Host "  登录响应: $($res.result) | $($res.message)"
    if ($res.result -eq 'success') { $ok = $true }
}
if (-not $ok) {
    $body = "userId=$([Uri]::EscapeDataString($cfg.user))&password=$([Uri]::EscapeDataString($plain))&service=$([Uri]::EscapeDataString($cfg.service))&queryString=$qs&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false"
    $res = Invoke-InterFace -Method 'login' -Body $body
    Write-Host "  明文响应: $($res.result) | $($res.message)"
    if ($res.result -eq 'success') { $ok = $true }
}

if ($ok) {
    Write-Ok '登录成功'
    if ($res.userIndex) {
        & (Join-Path $PSScriptRoot 'rea-keepalive.ps1') -UserIndex $res.userIndex -IntervalMinutes $IntervalMinutes -Background
    }
    exit 0
}

Write-Err2 '自动登录失败'
exit 3
