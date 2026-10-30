Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")
ps = sh.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
q = Chr(34)
cmd = q & ps & q & " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & q & base & "\CampusConnect.ps1" & q
sh.Run cmd, 0, False
