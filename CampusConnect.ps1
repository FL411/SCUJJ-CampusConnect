#Requires -Version 5.1
<#
CampusConnect 图形界面
- 首次运行输入学号/密码（DPAPI 保存）
- 启动/停止/重启后台守护
- 开机自启开关、查看日志、打开目录、停用/卸载
不主动连接 WiFi；Windows 连接后由守护进程按当前 SSID 判断是否需要认证。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 高 DPI：必须在创建任何窗口前设置（Per-Monitor V2，失败则回退）
try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class CampusConnectDpi {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
}
"@ -ErrorAction Stop
    $dpiOk = [CampusConnectDpi]::SetProcessDpiAwarenessContext([IntPtr](-4))
    if (-not $dpiOk) {
        try { $hr = [CampusConnectDpi]::SetProcessDpiAwareness(2) } catch { $hr = -1 }
        if ($hr -ne 0) { [void][CampusConnectDpi]::SetProcessDPIAware() }
    }
} catch { }

# 防止从 PowerShell 7 继承 PSModulePath，导致 5.1 误加载 PS7 的 Security 模块
$winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules'
$pfPs = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'
$userPs = Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Modules'
$env:PSModulePath = (@($userPs, $pfPs, $winPs) | Where-Object { Test-Path $_ }) -join ';'
try {
    Import-Module Microsoft.PowerShell.Security -ErrorAction Stop
} catch {
    try { Add-Content (Join-Path $PSScriptRoot 'CampusConnect-gui.log') ('{0} security module: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message) -Encoding UTF8 } catch { }
}

$root = $PSScriptRoot
$configPath = Join-Path $root 'rea-connect.config.json'
$logPath = Join-Path $root 'rea-daemon.log'
$cachePath = Join-Path $root 'wifi-cache.json'
$watchdog = Join-Path $root 'rea-daemon-watchdog.vbs'
$daemon = Join-Path $root 'rea-daemon.ps1'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName = 'REA-ePortal'

# 按当前显示器 DPI 缩放整窗（设计基准 96 DPI）
function Scale-FormForDpi {
    param($Form)
    if ($Form.Tag -eq 'dpi-scaled') { return }
    $Form.Tag = 'dpi-scaled'
    $dpi = 96
    try { if ($Form.DeviceDpi -gt 0) { $dpi = $Form.DeviceDpi } } catch { }
    try { $wdpi = [CampusConnectDpi]::GetDpiForWindow($Form.Handle); if ($wdpi -gt 0) { $dpi = $wdpi } } catch { }
    $factor = $dpi / 96.0
    if ($factor -gt 1.01) {
        try { $Form.Scale((New-Object System.Drawing.SizeF($factor, $factor))) } catch { }
    }
    try {
        $margin = [int](16 * $factor)
        $maxRight = 0
        $maxBottom = 0
        foreach ($c in $Form.Controls) {
            if ($c.Visible) {
                if ($c.Right -gt $maxRight) { $maxRight = $c.Right }
                if ($c.Bottom -gt $maxBottom) { $maxBottom = $c.Bottom }
            }
        }
        $cw = [Math]::Max($Form.ClientSize.Width, $maxRight + $margin)
        $ch = [Math]::Max($Form.ClientSize.Height, $maxBottom + $margin)
        $Form.ClientSize = New-Object System.Drawing.Size([int]$cw, [int]$ch)
    } catch { }
}

function Center-FormOnScreen {
    param($Form)
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $x = [int]($wa.Left + ($wa.Width - $Form.Width) / 2)
    $y = [int]($wa.Top + ($wa.Height - $Form.Height) / 2)
    $Form.Location = New-Object System.Drawing.Point($x, $y)
}

function Get-Config {
    if (Test-Path $configPath) {
        try { return (Get-Content $configPath -Raw | ConvertFrom-Json) } catch { return $null }
    }
    return $null
}

function Save-Config {
    param($Config)
    $tmp = "$configPath.tmp"
    $Config | ConvertTo-Json -Depth 6 | Set-Content $tmp -Encoding UTF8
    Move-Item $tmp $configPath -Force
}

function Test-UsableSsid {
    param([string]$Ssid)
    if (-not $Ssid) { return $false }
    return ($Ssid.Trim() -notmatch '^(正在识别|识别中|未知|未连接|Identifying|Unknown|Unidentified)')
}

function Get-CurrentSsid {
    try {
        $p = Get-NetConnectionProfile -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceAlias -like '*WLAN*' } |
            Select-Object -First 1
        if ($p -and $p.Name -and (Test-UsableSsid ([string]$p.Name))) { return [string]$p.Name }
    } catch { }
    try {
        $out = & netsh wlan show interfaces 2>$null
        foreach ($line in $out) {
            if ($line -match '^\s*SSID\s*:\s*(.+)$') {
                $ssid = $matches[1].Trim()
                if (Test-UsableSsid $ssid) { return $ssid }
            }
        }
    } catch { }
    return ''
}

function Get-DaemonProcess {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$daemon*" -and $_.CommandLine -notlike '*-Once*' }
}

function Get-WatchdogProcess {
    Get-CimInstance Win32_Process -Filter "Name='wscript.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$watchdog*" }
}

function Start-Watchdog {
    if (-not (Get-WatchdogProcess)) {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') `
            -ArgumentList ('"' + $watchdog + '"') -WindowStyle Hidden
    }
}

function Stop-Watchdog {
    Get-WatchdogProcess | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Stop-Daemon {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$daemon*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Get-Autostart {
    try {
        $v = (Get-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue).$runName
        return [bool]($v -and $v -like "*$watchdog*")
    } catch { return $false }
}

function Set-Autostart {
    param([bool]$Enable)
    if ($Enable) {
        $cmd = '"' + (Join-Path $env:SystemRoot 'System32\wscript.exe') + '" "' + $watchdog + '"'
        New-Item -Path $runKey -Force | Out-Null
        Set-ItemProperty -Path $runKey -Name $runName -Value $cmd
    } else {
        try {
            $v = (Get-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue).$runName
            if ($v -and $v -like "*$watchdog*") { Remove-ItemProperty -Path $runKey -Name $runName }
        } catch { }
    }
}

function Show-SetupForm {
    $existing = Get-Config
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'CampusConnect - 设置账号'
    $f.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $f.Size = New-Object System.Drawing.Size(430, 260)
    $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $lblUser = New-Object System.Windows.Forms.Label
    $lblUser.Text = '学号/账号'; $lblUser.Location = New-Object System.Drawing.Point(24, 24); $lblUser.AutoSize = $true
    $txtUser = New-Object System.Windows.Forms.TextBox
    $txtUser.Location = New-Object System.Drawing.Point(120, 21); $txtUser.Size = New-Object System.Drawing.Size(270, 25)

    $lblPass = New-Object System.Windows.Forms.Label
    $lblPass.Text = '密码'; $lblPass.Location = New-Object System.Drawing.Point(24, 64); $lblPass.AutoSize = $true
    $txtPass = New-Object System.Windows.Forms.TextBox
    $txtPass.Location = New-Object System.Drawing.Point(120, 61); $txtPass.Size = New-Object System.Drawing.Size(270, 25)
    $txtPass.UseSystemPasswordChar = $true

    $lblPortal = New-Object System.Windows.Forms.Label
    $lblPortal.Text = '门户地址'; $lblPortal.Location = New-Object System.Drawing.Point(24, 104); $lblPortal.AutoSize = $true
    $txtPortal = New-Object System.Windows.Forms.TextBox
    $txtPortal.Location = New-Object System.Drawing.Point(120, 101); $txtPortal.Size = New-Object System.Drawing.Size(270, 25)
    $txtPortal.Text = 'http://10.130.128.9'

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = '密码用 Windows DPAPI 加密，仅当前用户可解密。'
    $lblHint.Location = New-Object System.Drawing.Point(24, 136); $lblHint.AutoSize = $true
    $lblHint.ForeColor = [System.Drawing.Color]::Gray

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = '保存'; $btnOK.Location = New-Object System.Drawing.Point(210, 180); $btnOK.Size = New-Object System.Drawing.Size(80, 28)
    $btnOK.DialogResult = [System.Windows.Forms.DialogResult]::None
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'; $btnCancel.Location = New-Object System.Drawing.Point(300, 180); $btnCancel.Size = New-Object System.Drawing.Size(80, 28)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    if ($existing) {
        $txtUser.Text = [string]$existing.user
        if ($existing.portal) { $txtPortal.Text = [string]$existing.portal }
    }

    $saveRoot = $root
    $saveConfigPath = $configPath
    $saveHandler = {
        $u = $txtUser.Text.Trim()
        if (-not $u) { [System.Windows.Forms.MessageBox]::Show('账号不能为空。', 'CampusConnect'); return }
        $portal = $txtPortal.Text.Trim()
        if (-not $portal) { $portal = 'http://10.130.128.9' }

        $sec = $null
        try {
            if ($txtPass.Text.Length -gt 0) {
                $sec = ConvertTo-SecureString $txtPass.Text -AsPlainText -Force
            } elseif ($existing -and $existing.passwordEnc) {
                if ($existing.user -and $existing.user -ne $u) {
                    [System.Windows.Forms.MessageBox]::Show('换账号时请重新输入密码。', 'CampusConnect'); return
                }
                $sec = ConvertTo-SecureString $existing.passwordEnc
            } else {
                [System.Windows.Forms.MessageBox]::Show('请输入密码。', 'CampusConnect'); return
            }
        } catch {
            try { Add-Content (Join-Path $saveRoot 'CampusConnect-gui.log') ('{0} sec error: {1}' -f (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message) -Encoding UTF8 } catch { }
            [System.Windows.Forms.MessageBox]::Show('密码处理失败：' + $_.Exception.Message, 'CampusConnect')
            return
        }

        try {
            $new = [ordered]@{
                user           = $u
                passwordEnc    = (ConvertFrom-SecureString $sec)
                service        = ''
                portal         = $portal
                savedAt        = (Get-Date).ToString('s')
                userIndex      = $null
                redirect       = $null
                campusPrefixes = @('10.13')
                campusSsids    = @()
            }
        } catch {
            try { Add-Content (Join-Path $saveRoot 'CampusConnect-gui.log') ('{0} new error: {1}' -f (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message) -Encoding UTF8 } catch { }
            [System.Windows.Forms.MessageBox]::Show('配置生成失败：' + $_.Exception.Message, 'CampusConnect')
            return
        }
        if ($existing -and $existing.user -eq $u) {
            $new.userIndex = $existing.userIndex
            $new.redirect = $existing.redirect
        }
        try {
            $tmp = "$saveConfigPath.tmp"
            $new | ConvertTo-Json -Depth 6 | Set-Content $tmp -Encoding UTF8
            Move-Item $tmp $saveConfigPath -Force
        } catch {
            try { Add-Content (Join-Path $saveRoot 'CampusConnect-gui.log') ('{0} save error: {1}' -f (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message) -Encoding UTF8 } catch { }
            [System.Windows.Forms.MessageBox]::Show('保存失败：' + $_.Exception.Message, 'CampusConnect')
            return
        }
        $f.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $f.Close()
    }.GetNewClosure()
    $btnOK.Add_Click($saveHandler)

    [void]$f.Controls.AddRange(@($lblUser, $txtUser, $lblPass, $txtPass, $lblPortal, $txtPortal, $lblHint, $btnOK, $btnCancel))
    $f.AcceptButton = $btnOK
    $f.CancelButton = $btnCancel
    $f.Add_Load({
        Scale-FormForDpi $f
        Center-FormOnScreen $f
    })
    $result = $f.ShowDialog()
    $f.Dispose()
    return ($result -eq [System.Windows.Forms.DialogResult]::OK)
}

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
$form = New-Object System.Windows.Forms.Form
$form.Text = 'CampusConnect - 校园网自动认证'
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.Size = New-Object System.Drawing.Size(580, 390)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$grp = New-Object System.Windows.Forms.GroupBox
$grp.Text = '状态'; $grp.Location = New-Object System.Drawing.Point(18, 15); $grp.Size = New-Object System.Drawing.Size(530, 190)

$lblDaemonCap = New-Object System.Windows.Forms.Label
$lblDaemonCap.Text = '守护进程：'; $lblDaemonCap.Location = New-Object System.Drawing.Point(18, 28); $lblDaemonCap.AutoSize = $true
$lblDaemon = New-Object System.Windows.Forms.Label
$lblDaemon.Text = '检测中…'; $lblDaemon.Location = New-Object System.Drawing.Point(120, 28); $lblDaemon.AutoSize = $true

$lblWifiCap = New-Object System.Windows.Forms.Label
$lblWifiCap.Text = '当前 WiFi：'; $lblWifiCap.Location = New-Object System.Drawing.Point(18, 58); $lblWifiCap.AutoSize = $true
$lblWifi = New-Object System.Windows.Forms.Label
$lblWifi.Text = '-'; $lblWifi.Location = New-Object System.Drawing.Point(120, 58); $lblWifi.AutoSize = $true

$lblAuthCap = New-Object System.Windows.Forms.Label
$lblAuthCap.Text = '认证状态：'; $lblAuthCap.Location = New-Object System.Drawing.Point(18, 88); $lblAuthCap.AutoSize = $true
$lblAuth = New-Object System.Windows.Forms.Label
$lblAuth.Text = '-'; $lblAuth.Location = New-Object System.Drawing.Point(120, 88); $lblAuth.AutoSize = $true

$lblTokenCap = New-Object System.Windows.Forms.Label
$lblTokenCap.Text = '会话令牌：'; $lblTokenCap.Location = New-Object System.Drawing.Point(18, 118); $lblTokenCap.AutoSize = $true
$lblToken = New-Object System.Windows.Forms.Label
$lblToken.Text = '-'; $lblToken.Location = New-Object System.Drawing.Point(120, 118); $lblToken.AutoSize = $true

$lblLogCap = New-Object System.Windows.Forms.Label
$lblLogCap.Text = '最近日志：'; $lblLogCap.Location = New-Object System.Drawing.Point(18, 148); $lblLogCap.AutoSize = $true
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = '-'; $lblLog.Location = New-Object System.Drawing.Point(120, 148); $lblLog.Size = New-Object System.Drawing.Size(390, 22)
$lblLog.AutoEllipsis = $true

[void]$grp.Controls.AddRange(@($lblDaemonCap, $lblDaemon, $lblWifiCap, $lblWifi, $lblAuthCap, $lblAuth, $lblTokenCap, $lblToken, $lblLogCap, $lblLog))

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = '启动'; $btnStart.Location = New-Object System.Drawing.Point(18, 220); $btnStart.Size = New-Object System.Drawing.Size(90, 30)
$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = '停止'; $btnStop.Location = New-Object System.Drawing.Point(120, 220); $btnStop.Size = New-Object System.Drawing.Size(90, 30)
$btnRestart = New-Object System.Windows.Forms.Button
$btnRestart.Text = '重启'; $btnRestart.Location = New-Object System.Drawing.Point(222, 220); $btnRestart.Size = New-Object System.Drawing.Size(90, 30)
$btnSetup = New-Object System.Windows.Forms.Button
$btnSetup.Text = '设置账号'; $btnSetup.Location = New-Object System.Drawing.Point(324, 220); $btnSetup.Size = New-Object System.Drawing.Size(100, 30)
$btnLog = New-Object System.Windows.Forms.Button
$btnLog.Text = '查看日志'; $btnLog.Location = New-Object System.Drawing.Point(436, 220); $btnLog.Size = New-Object System.Drawing.Size(100, 30)

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = '开机自启'; $chkAuto.Location = New-Object System.Drawing.Point(18, 268); $chkAuto.AutoSize = $true
$btnFolder = New-Object System.Windows.Forms.Button
$btnFolder.Text = '打开目录'; $btnFolder.Location = New-Object System.Drawing.Point(120, 262); $btnFolder.Size = New-Object System.Drawing.Size(100, 30)
$btnUninstall = New-Object System.Windows.Forms.Button
$btnUninstall.Text = '停用/卸载'; $btnUninstall.Location = New-Object System.Drawing.Point(232, 262); $btnUninstall.Size = New-Object System.Drawing.Size(110, 30)
$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Text = '退出'; $btnExit.Location = New-Object System.Drawing.Point(436, 262); $btnExit.Size = New-Object System.Drawing.Size(100, 30)

$lblNote = New-Object System.Windows.Forms.Label
$lblNote.Text = '关闭窗口不会停止后台守护；Windows 负责连接 WiFi，本工具只负责认证。'
$lblNote.Location = New-Object System.Drawing.Point(18, 310); $lblNote.AutoSize = $true
$lblNote.ForeColor = [System.Drawing.Color]::Gray

[void]$form.Controls.AddRange(@($grp, $btnStart, $btnStop, $btnRestart, $btnSetup, $btnLog, $chkAuto, $btnFolder, $btnUninstall, $btnExit, $lblNote))

function Update-Status {
    $daemonRunning = [bool](Get-DaemonProcess)
    $watchRunning = [bool](Get-WatchdogProcess)
    if ($daemonRunning) { $lblDaemon.Text = '运行中' }
    elseif ($watchRunning) { $lblDaemon.Text = '看门狗在运行（守护未启动）' }
    else { $lblDaemon.Text = '已停止' }

    $ssid = Get-CurrentSsid
    $lblWifi.Text = if ($ssid) { $ssid } else { '<未连接>' }

    $authText = '未检测'
    if ($ssid -and (Test-Path $cachePath)) {
        try {
            $cache = Get-Content $cachePath -Raw | ConvertFrom-Json
            $entry = $cache.PSObject.Properties[$ssid]
            if ($entry) {
                if ($entry.Value.Auth -eq $true) { $authText = '需要认证（已记录）' }
                elseif ($entry.Value.Auth -eq $false) { $authText = '无需认证（已记录）' }
            }
        } catch { }
    }
    $lblAuth.Text = $authText

    $cfg = Get-Config
    $lblToken.Text = if ($cfg -and $cfg.userIndex) { '已获取' } else { '无（等待认证）' }

    if (Test-Path $logPath) {
        try {
            $line = Get-Content $logPath -Tail 1 -Encoding UTF8
            $lblLog.Text = if ($line) { [string]$line } else { '-' }
        } catch { $lblLog.Text = '-' }
    } else { $lblLog.Text = '<暂无日志>' }

    $chkAuto.Checked = Get-Autostart
}

$btnStart.Add_Click({
    if (-not (Get-Config)) { if (-not (Show-SetupForm)) { return } }
    Start-Watchdog
    Start-Sleep -Milliseconds 800
    Update-Status
})
$btnStop.Add_Click({ Stop-Watchdog; Stop-Daemon; Update-Status })
$btnRestart.Add_Click({ Stop-Watchdog; Stop-Daemon; Start-Sleep -Milliseconds 500; Start-Watchdog; Start-Sleep -Milliseconds 800; Update-Status })
$btnSetup.Add_Click({ if (Show-SetupForm) { Update-Status } })
$btnLog.Add_Click({
    if (Test-Path $logPath) { Start-Process notepad.exe $logPath }
    else { [System.Windows.Forms.MessageBox]::Show('还没有日志。', 'CampusConnect') }
})
$btnFolder.Add_Click({ Start-Process explorer.exe $root })
$chkAuto.Add_Click({ Set-Autostart $chkAuto.Checked })
$btnUninstall.Add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show(
        '将停止后台守护，并移除开机自启。' + "`n`n" + '之后你可以直接删除整个文件夹。是否继续？',
        'CampusConnect 停用',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
        Stop-Watchdog
        Stop-Daemon
        Set-Autostart $false
        Update-Status
        [System.Windows.Forms.MessageBox]::Show('已停止并移除开机自启。', 'CampusConnect')
    }
})
$btnExit.Add_Click({ $form.Close() })

$form.Add_Load({
    Scale-FormForDpi $form
    Center-FormOnScreen $form
})

$form.Add_Shown({
    if (-not (Get-Config)) { [void](Show-SetupForm) }
    Update-Status
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ Update-Status })
$timer.Start()

try {
    [void][System.Windows.Forms.Application]::Run($form)
} catch {
    try { Add-Content (Join-Path $root 'CampusConnect-gui.log') ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message) -Encoding UTF8 } catch { }
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'CampusConnect 错误', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
}
