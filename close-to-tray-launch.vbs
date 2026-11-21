' Launches close-to-tray.ps1 with zero console window flash on Windows.
Option Explicit

Dim fso, shell, scriptDir, psScript, psExe, args, i, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psScript = fso.BuildPath(scriptDir, "close-to-tray.ps1")
psExe = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")

args = ""
For i = 0 To WScript.Arguments.Count - 1
    args = args & " " & Chr(34) & Replace(WScript.Arguments(i), Chr(34), "\" & Chr(34)) & Chr(34)
Next

cmd = Chr(34) & psExe & Chr(34) & " -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " & Chr(34) & psScript & Chr(34) & args
shell.Run cmd, 0, False
