' REA ePortal daemon watchdog - hidden (no console window)
' Uses Windows PowerShell 5.1 so it works without PowerShell 7.
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
daemon = base & "\rea-daemon.ps1"
Set sh = CreateObject("WScript.Shell")
ps = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
Do
    cmd = """" & ps & """ -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & daemon & """"
    rc = sh.Run(cmd, 0, True)
    If rc = 3 Then
        WScript.Sleep 300000
    Else
        WScript.Sleep 5000
    End If
Loop
