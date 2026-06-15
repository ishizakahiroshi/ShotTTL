Option Explicit

' run-hidden.vbs runs shotttl.ps1 hidden (no PowerShell console window) for
' Task Scheduler use. It quotes arguments using the Windows CommandLineToArgvW
' convention so that quotes/backslashes survive the wscript -> powershell hop,
' uses an absolute powershell.exe path to avoid PATH hijacking, fails loud if
' shotttl.ps1 is missing, and runs synchronously so Task Scheduler receives the
' real PowerShell exit code.

Dim shell
Dim fso
Dim scriptDir
Dim psScript
Dim powerShellExe
Dim arguments
Dim extraArguments
Dim command
Dim exitCode

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psScript = fso.BuildPath(scriptDir, "shotttl.ps1")

If Not fso.FileExists(psScript) Then
    LogStartupError "shotttl.ps1 not found at " & psScript
    WScript.Quit 2
End If

powerShellExe = fso.BuildPath(shell.ExpandEnvironmentStrings("%SystemRoot%"), "System32\WindowsPowerShell\v1.0\powershell.exe")
If Not fso.FileExists(powerShellExe) Then
    ' Fall back to PATH resolution so unusual layouts (e.g. Nano Server) still work.
    powerShellExe = "powershell.exe"
End If

extraArguments = JoinArguments(WScript.Arguments)
arguments = "-NoProfile -ExecutionPolicy Bypass -File " & Quote(psScript) & " -Quiet"
If Len(extraArguments) > 0 Then
    arguments = arguments & " " & extraArguments
End If
command = Quote(powerShellExe) & " " & arguments

' Window style 0 keeps the PowerShell window hidden.
' bWaitOnReturn = True so that the PowerShell exit code propagates to Task Scheduler.
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode

' Quote a single argument following the rules CommandLineToArgvW expects:
'   - Embedded backslash runs that precede a double quote are doubled.
'   - Each embedded double quote is then escaped as \".
'   - Trailing backslashes (right before the closing quote) are doubled.
' This is the same rule used by the CRT/CommandLineToArgvW pair, which is what
' powershell.exe ultimately uses to split its command line.
Function Quote(value)
    Dim s, i, ch, backslashes, j, result
    s = CStr(value)
    result = Chr(34)
    i = 1
    Do While i <= Len(s)
        backslashes = 0
        Do While i <= Len(s) And Mid(s, i, 1) = "\"
            backslashes = backslashes + 1
            i = i + 1
        Loop
        If i > Len(s) Then
            For j = 1 To backslashes * 2
                result = result & "\"
            Next
        ElseIf Mid(s, i, 1) = Chr(34) Then
            For j = 1 To backslashes * 2
                result = result & "\"
            Next
            result = result & "\" & Chr(34)
            i = i + 1
        Else
            For j = 1 To backslashes
                result = result & "\"
            Next
            result = result & Mid(s, i, 1)
            i = i + 1
        End If
    Loop
    result = result & Chr(34)
    Quote = result
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

' Append a one-line ERROR record to %APPDATA%\ShotTTL\logs\run-hidden_yyyymmdd.log
' so launch-time failures (missing shotttl.ps1, etc.) are visible even without
' a console.
Sub LogStartupError(message)
    Dim appData, logDir, logFile, stream, stamp

    On Error Resume Next
    appData = shell.ExpandEnvironmentStrings("%APPDATA%")
    If Len(appData) = 0 Or appData = "%APPDATA%" Then
        Exit Sub
    End If

    logDir = fso.BuildPath(appData, "ShotTTL\logs")
    If Not fso.FolderExists(fso.BuildPath(appData, "ShotTTL")) Then
        fso.CreateFolder fso.BuildPath(appData, "ShotTTL")
    End If
    If Not fso.FolderExists(logDir) Then
        fso.CreateFolder logDir
    End If

    stamp = FormatDateTime(Now, vbGeneralDate)
    logFile = fso.BuildPath(logDir, "run-hidden_" & Year(Now) & Right("0" & Month(Now), 2) & Right("0" & Day(Now), 2) & ".log")
    Set stream = fso.OpenTextFile(logFile, 8, True)
    If Not stream Is Nothing Then
        stream.WriteLine stamp & " [ERROR] " & message
        stream.Close
    End If
    On Error Goto 0
End Sub
