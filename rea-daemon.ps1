<#
.SYNOPSIS
    ePortal 无感连接守护进程

.DESCRIPTION
    循环执行：检测在线状态 → 在线则保活 → 离线则自动重新认证。
    凭据来自 rea-connect.ps1 -Setup 生成的配置（密码经 DPAPI 加密）。

    已验证行为：
      - 在线时调用 login 会返回当前会话的 userIndex（不会踢掉自己）
      - keepalive 可有效续期，token 不轮换
      - 该部署未启用 RSA，使用明文密码模式

.EXAMPLE
    .\rea-daemon.ps1 -Once        # 跑一轮看结果
    .\rea-daemon.ps1 -Background  # 后台常驻
    .\rea-daemon.ps1              # 前台常驻（Ctrl+C 停止）
#>
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string[]]$ProbeUrls = @(
        'http://connect.rom.miui.com/generate_204',
        'http://www.msftconnecttest.com/connecttest.txt',
        'http://captive.apple.com/hotspot-detect.html',
        'http://neverssl.com'
    ),
    [int]$CheckSeconds = 20,
    [switch]$Once,
    [switch]$Background
)

$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'rea-connect.config.json' }
$LogFile = Join-Path $PSScriptRoot 'rea-daemon.log'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERR' { 'Red' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 2MB) { Move-Item $LogFile "$LogFile.1" -Force }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch { }
}

if (-not (Test-Path $ConfigPath)) {
    Write-Log "未找到配置 $ConfigPath，请先运行 .\rea-connect.ps1 -Setup" 'ERR'
    exit 1
}

# 单实例保护：长驻模式用命名互斥量；-Once 与 -Background 启动器不参与
$mutex = $null
if (-not $Once -and -not $Background) {
    $mutex = [Threading.Mutex]::new($false, 'Local\REA-ePortal-Daemon')
    try { $acquired = $mutex.WaitOne(0) } catch { $acquired = $true }
    if (-not $acquired) {
        Write-Log '已有守护进程在运行，退出。' 'WARN'
        exit 3
    }
}
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

# 门户地址：优先配置，保持旧默认值
$Portal = if ($cfg.portal) { ([string]$cfg.portal).TrimEnd('/') } else { 'http://10.130.128.9' }
$WifiCachePath = Join-Path $PSScriptRoot 'wifi-cache.json'
$script:lastSsid = ''

function Save-Config {
    $tmp = "$ConfigPath.tmp"
    $cfg | ConvertTo-Json -Depth 6 | Set-Content $tmp -Encoding UTF8
    Move-Item $tmp $ConfigPath -Force
}

function Get-PlainPassword {
    $sec = ConvertTo-SecureString $cfg.passwordEnc
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-JsEncode {
    param([string]$s)
    $sb = [Text.StringBuilder]::new()
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -match '[A-Za-z0-9\-_.!~*''()]') { [void]$sb.Append($ch) }
        elseif ($ch -eq ' ') { [void]$sb.Append('%20') }
        else { foreach ($b in [Text.Encoding]::UTF8.GetBytes([string]$ch)) { [void]$sb.Append('%' + $b.ToString('X2')) } }
    }
    return $sb.ToString()
}

function Invoke-InterFace {
    param([string]$Method, [string]$Body)
    $r = Invoke-WebRequest -Uri "$Portal/eportal/InterFace.do?method=$Method" `
        -Method POST -Body $Body `
        -ContentType 'application/x-www-form-urlencoded; charset=UTF-8' `
        -UseBasicParsing -TimeoutSec 20
    $text = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    try { return ($text | ConvertFrom-Json) } catch { return [pscustomobject]@{ result = 'unknown'; message = $text } }
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
    <# 204=在线；3xx 或 200 拦截页=离线并给出登录页地址 #>
    $unknown = @{ Online = $null; Location = $null }
    foreach ($url in $ProbeUrls) {
        $p = Get-HttpProbe $url
        if ($p.Code -eq 204) { return @{ Online = $true; Location = $null } }
        if ($p.Code -eq 200) {
            $body = [string]$p.Body
            $online = $null
            switch -Wildcard ($url) {
                '*generate_204*' { $online = $false }
                '*connecttest.txt*' { $online = $body -match 'Microsoft Connect Test' }
                '*hotspot-detect.html*' { $online = $body -match 'Success' }
            }
            if ($online -eq $true) { return @{ Online = $true; Location = $null } }

            # 200 拦截页：从 JS/meta 跳转里提取登录地址
            $m = [regex]::Match($body, "(?is)(?:location\.href|location\.replace|window\.location)\s*(?:=|\()\s*['""]([^'""]+)['""]")
            if (-not $m.Success) { $m = [regex]::Match($body, "(?is)http-equiv=[""']refresh[""'][^>]*content=[""'][^;]+;\s*url=([^'""]+)") }
            if ($m.Success) { return @{ Online = $false; Location = $m.Groups[1].Value } }

            # neverssl 等普通 200 页面视为在线；其余继续试下一个探测点
            if ($null -eq $online) { return @{ Online = $true; Location = $null } }
        }
        elseif ($p.Code -in 301, 302, 303, 307, 308 -and $p.Location) {
            return @{ Online = $false; Location = $p.Location }
        }
        elseif ($p.Code -ge 400) {
            return @{ Online = $false; Location = $null }
        }
    }
    return $unknown
}

function Get-CurrentSsid {
    try {
        $p = Get-NetConnectionProfile -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceAlias -like '*WLAN*' } |
            Select-Object -First 1
        if ($p -and $p.Name) { return [string]$p.Name }
    } catch { }
    try {
        $out = & netsh wlan show interfaces 2>$null
        foreach ($line in $out) {
            if ($line -match '^\s*SSID\s*:\s*(.+)$') { return $matches[1].Trim() }
        }
    } catch { }
    return ''
}

function Get-WifiCache {
    $cache = @{}
    if (Test-Path $WifiCachePath) {
        try {
            $obj = Get-Content $WifiCachePath -Raw | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) { $cache[$p.Name] = $p.Value }
        } catch { }
    }
    return $cache
}

function Set-WifiCache {
    param([string]$Ssid, [bool]$Auth)
    if (-not $Ssid) { return }
    $cache = Get-WifiCache
    $cache[$Ssid] = [pscustomobject]@{ Auth = $Auth; CheckedAt = (Get-Date).ToString('s') }
    try {
        $tmp = "$WifiCachePath.tmp"
        $cache | ConvertTo-Json -Depth 4 | Set-Content $tmp -Encoding UTF8
        Move-Item $tmp $WifiCachePath -Force
    } catch { }
}

function Test-SchoolPortal {
    $p = Get-HttpProbe $Portal
    return ($null -ne $p.Code)
}

function Test-CampusWifi {
    <# 只检查当前 WiFi：需要认证返回 true；无需认证/内网返回 false，并缓存结果 #>
    $ssid = Get-CurrentSsid
    if (-not $ssid) { return $false }
    if ($ssid -ne $script:lastSsid) {
        Write-Log "当前 WiFi：$ssid" 'INFO'
        $script:lastSsid = $ssid
    }

    $cache = Get-WifiCache
    $entry = $cache[$ssid]
    if ($entry) {
        if ($entry.Auth -eq $false) { return $false }
        if ($entry.Auth -eq $true) { return $true }
    }

    $state = Test-OnlineState
    if ($state.Online -eq $false -and $state.Location) {
        $hostName = ([Uri]$Portal).Host
        if ($state.Location -match [regex]::Escape($hostName)) {
            Set-WifiCache $ssid $true
            Write-Log "WiFi $ssid 需要认证（已记录）" 'OK'
            return $true
        }
    }
    if ($state.Online -eq $true) {
        if (Test-SchoolPortal) {
            Set-WifiCache $ssid $true
            Write-Log "WiFi $ssid 是校园网（已记录）" 'OK'
            return $true
        }
        if ($ssid -like '*SCJJXY*') {
            Write-Log "WiFi $ssid 名称匹配 SCJJXY，按认证候选继续" 'INFO'
            return $true
        }
        Set-WifiCache $ssid $false
        Write-Log "WiFi $ssid 无需认证（已记录，后续跳过）" 'INFO'
        return $false
    }
    if ($ssid -like '*SCJJXY*') {
        Write-Log "WiFi $ssid 名称匹配 SCJJXY，按认证候选继续" 'INFO'
        return $true
    }
    Set-WifiCache $ssid $false
    Write-Log "WiFi $ssid 内网/无响应（已记录为无需认证）" 'INFO'
    return $false
}

function Invoke-Login {
    param([string]$RedirectUrl)
    $search = if ($RedirectUrl -and $RedirectUrl -match '\?(.+)$') { $matches[1] } else { '' }
    $qs = Get-JsEncode (Get-JsEncode $search)
    $plain = Get-PlainPassword
    $body = "userId=$([Uri]::EscapeDataString($cfg.user))" +
            "&password=$([Uri]::EscapeDataString($plain))" +
            "&service=$([Uri]::EscapeDataString([string]$cfg.service))" +
            "&queryString=$qs&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false"
    try {
        $res = Invoke-InterFace -Method 'login' -Body $body
        if ($res.result -eq 'success' -and $res.userIndex) {
            $cfg | Add-Member -NotePropertyName userIndex -NotePropertyValue $res.userIndex -Force
            if ($RedirectUrl) { $cfg | Add-Member -NotePropertyName redirect -NotePropertyValue $RedirectUrl -Force }
            Save-Config
        }
        return $res
    }
    catch {
        return [pscustomobject]@{ result = 'exception'; message = $_.Exception.Message }
    }
}

function Invoke-Keepalive {
    if (-not $cfg.userIndex) { return [pscustomobject]@{ result = 'no_token'; message = '本地无 token' } }
    try {
        return Invoke-InterFace -Method 'keepalive' -Body "userIndex=$([Uri]::EscapeDataString($cfg.userIndex))"
    }
    catch { return [pscustomobject]@{ result = 'exception'; message = $_.Exception.Message } }
}

function Get-PortalToken {
    <# 已在线但没有本地 token 时，从门户的 success 跳转里取当前会话 token #>
    $p = Get-HttpProbe "$Portal/eportal/redirectortosuccess.jsp"
    if ($p.Location -match 'userIndex=([^&]+)') {
        $t = [Uri]::UnescapeDataString($matches[1])
        if ($t -and $t -ne 'null') { return $t }
    }
    if ($p.Body -match 'userIndex=([0-9a-fA-F]{8,}_[^&"''\s]+)') { return $matches[1] }
    $p2 = Get-HttpProbe "$Portal/"
    if ($p2.Location -match 'userIndex=([^&]+)') {
        $t = [Uri]::UnescapeDataString($matches[1])
        if ($t -and $t -ne 'null') { return $t }
    }
    return $null
}

function Invoke-Cycle {
    if (-not (Test-CampusWifi)) { return $null }
    $state = Test-OnlineState

    if ($state.Online -eq $true) {
        # 在线：保活
        if (-not $cfg.userIndex) {
            Write-Log '在线但无 token，尝试从门户获取…'
            $tok = Get-PortalToken
            if ($tok) {
                $cfg | Add-Member -NotePropertyName userIndex -NotePropertyValue $tok -Force
                Save-Config
                Write-Log '已从门户获取 token' 'OK'
            } else {
                Write-Log '未能从门户获取 token，尝试登录…' 'WARN'
                $lr = Invoke-Login $cfg.redirect
                if ($lr.result -eq 'success') { Write-Log '已获取 token' 'OK' } else { Write-Log "获取 token 失败：$($lr.message)" 'WARN' }
            }
        }
        $k = Invoke-Keepalive
        if ($k.result -eq 'success') { Write-Log '保活成功' 'OK'; return $true }

        Write-Log "保活失败：$($k.result) $($k.message)，尝试重新登录" 'WARN'
        $lr = Invoke-Login $cfg.redirect
        if ($lr.result -eq 'success') { Write-Log '重新登录成功' 'OK'; return $true }
        Write-Log "重新登录失败：$($lr.message)" 'ERR'
        return $false
    }

    # 离线：自动认证
    $red = $state.Location
    if (-not $red) { $red = $cfg.redirect }
    if (-not $red) { Write-Log '离线且无登录页地址，无法自动认证' 'ERR'; return $false }

    Write-Log '检测到离线，执行自动认证…' 'WARN'
    $lr = Invoke-Login $red
    if ($lr.result -eq 'success') {
        $preview = [string]$lr.userIndex
        if ($preview.Length -gt 10) { $preview = $preview.Substring(0,10) }
        Write-Log "自动认证成功（新 token $preview…）" 'OK'
        return $true
    }
    Write-Log "自动认证失败：$($lr.message)" 'ERR'
    return $false
}

# ---------- 入口 ----------
if ($Once) {
    $ok = Invoke-Cycle
    if ($null -eq $ok) { Write-Log '当前 WiFi 不需要认证/未连接，跳过' 'INFO'; exit 0 }
    exit $(if ($ok) { 0 } else { 2 })
}

if ($Background) {
    $exe = (Get-Process -Id $PID).Path
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                 '-ConfigPath', "`"$ConfigPath`"",
                 '-CheckSeconds', $CheckSeconds)
    $child = Start-Process -FilePath $exe -ArgumentList $argList -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 1
    if ($child.HasExited) {
        Write-Host '后台启动失败，请查看日志。' -ForegroundColor Red
        exit 1
    }
    Write-Host "已启动后台守护（每 ${CheckSeconds}s 一次心跳检测）" -ForegroundColor Green
    Write-Host "日志：$LogFile" -ForegroundColor DarkGray
    exit 0
}

Write-Log "守护启动 | 每 ${CheckSeconds}s 一次心跳检测"
$lastOkLog = Get-Date
$nextWifiNotice = Get-Date
$failures = 0

while ($true) {
    try {
        if (-not (Test-CampusWifi)) {
            if ((Get-Date) -ge $nextWifiNotice) {
                Write-Log '当前 WiFi 不需要认证/未连接，暂停认证' 'INFO'
                $nextWifiNotice = (Get-Date).AddMinutes(10)
            }
            Start-Sleep -Seconds $CheckSeconds
            continue
        }

        # 首次在认证 WiFi 上运行且没有 token：从门户 success 跳转取当前会话 token
        if (-not $cfg.userIndex) {
            $tok = Get-PortalToken
            if ($tok) {
                $cfg | Add-Member -NotePropertyName userIndex -NotePropertyValue $tok -Force
                Save-Config
                Write-Log '已从门户获取 token' 'OK'
            }
        }

        # 以门户心跳为唯一判据（公网探测会被代理接管，不可靠）
        $k = Invoke-Keepalive
        if ($k.result -eq 'success') {
            $failures = 0
            if (((Get-Date) - $lastOkLog).TotalMinutes -ge 5) {
                Write-Log '保活正常' 'OK'
                $lastOkLog = Get-Date
            }
            Start-Sleep -Seconds $CheckSeconds
            continue
        }

        Write-Log "心跳失败：$($k.message)，尝试重新登录" 'WARN'

        # 优先用已保存的 NAS 参数（IP 未变时依然有效）
        $lr = Invoke-Login $cfg.redirect
        if ($lr.result -eq 'success') {
            $failures = 0
            Write-Log '重新登录成功（已存 NAS 参数）' 'OK'
            Start-Sleep -Seconds $CheckSeconds
            continue
        }

        # 回退：抓取新的重定向参数
        $lr2 = $null
        $s = Test-OnlineState
        if ($s.Location) {
            $lr2 = Invoke-Login $s.Location
            if ($lr2.result -eq 'success') {
                $failures = 0
                Write-Log '自动认证成功（新捕获的 NAS 参数）' 'OK'
                Start-Sleep -Seconds $CheckSeconds
                continue
            }
        }

        $failures++
        $msg = if ($lr2) { $lr2.message } else { $lr.message }
        Write-Log "自动认证失败：$msg" 'ERR'
    }
    catch {
        $failures++
        Write-Log "循环异常：$($_.Exception.Message)" 'ERR'
    }

    $sleep = [Math]::Min(300, [int]($CheckSeconds * [Math]::Pow(2, [Math]::Min($failures, 4))))
    if ($failures -gt 0) { Write-Log "连续失败 $failures 次，${sleep}s 后重试" 'WARN' }
    Start-Sleep -Seconds $sleep
}
