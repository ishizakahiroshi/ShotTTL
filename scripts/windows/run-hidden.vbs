Option Explicit

Dim shell
Dim fso
Dim scriptDir
Dim psScript
Dim powerShellExe
Dim arguments
Dim extraArguments
Dim command

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psScript = fso.BuildPath(scriptDir, "shotttl.ps1")
powerShellExe = "powershell.exe"

extraArguments = JoinArguments(WScript.Arguments)
arguments = "-NoProfile -ExecutionPolicy Bypass -File " & Quote(psScript) & " -Quiet"
If Len(extraArguments) > 0 Then
    arguments = arguments & " " & extraArguments
End If
command = powerShellExe & " " & arguments

' Window style 0 keeps the PowerShell window hidden.
shell.Run command, 0, False

Function Quote(value)
    Quote = Chr(34) & Replace(value, Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function

Function JoinArguments(values)
    Dim result
    Dim value

    result = ""
    For Each value In values
        If Len(result) > 0 Then
            result = result & " "
        End If
        result = result & Quote(CStr(value))
    Next

    JoinArguments = result
End Function
