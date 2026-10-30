' ===========================================================================
'  Translate.vbs - silent launcher for TranslateNamesApp.ps1
'
'  Starts the PowerShell GUI with no console window and no flash. Pass a
'  folder (or a file inside one) as the first argument, or wire this up as a
'  context-menu verb with:  TranslateNamesApp.ps1 -InstallContextMenu
' ===========================================================================
Option Explicit

Const SW_HIDE      = 0
Const WAIT_NO      = False
Const SCRIPT_NAME  = "TranslateNamesApp.ps1"

Dim objShell, objFSO, scriptDir, psScript, psExe, psArgs, cmd, firstArg

Set objShell = CreateObject("WScript.Shell")
Set objFSO   = CreateObject("Scripting.FileSystemObject")

scriptDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
psScript  = objFSO.BuildPath(scriptDir, SCRIPT_NAME)

If Not objFSO.FileExists(psScript) Then
    MsgBox "Cannot find " & SCRIPT_NAME & " next to this launcher." & vbCrLf & vbCrLf & _
           "Expected:" & vbCrLf & psScript, vbCritical, "Translate Names"
    WScript.Quit 1
End If

' Use the absolute path so a broken PATH cannot hijack the launch.
psExe = objShell.ExpandEnvironmentStrings( _
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
If Not objFSO.FileExists(psExe) Then psExe = "powershell.exe"

' Only the first argument is forwarded: the script takes a single folder, and
' a multi-selection in Explorer would otherwise fail positional binding.
psArgs = ""
If WScript.Arguments.Count > 0 Then
    firstArg = WScript.Arguments(0)
    If Len(firstArg) > 0 Then psArgs = " " & QuoteArg(firstArg)
End If

' -STA is required for drag-and-drop (OLE); Windows PowerShell defaults to it,
' but stating it keeps the behaviour identical if psExe is ever repointed.
cmd = QuoteArg(psExe) & _
      " -NoProfile -NoLogo -STA -ExecutionPolicy Bypass" & _
      " -WindowStyle Hidden -File " & QuoteArg(psScript) & psArgs

On Error Resume Next
objShell.Run cmd, SW_HIDE, WAIT_NO
If Err.Number <> 0 Then
    MsgBox "Could not start PowerShell." & vbCrLf & vbCrLf & _
           "Error " & Err.Number & ": " & Err.Description, vbCritical, "Translate Names"
    WScript.Quit 1
End If
On Error GoTo 0

' ---------------------------------------------------------------------------
' Quote one argument the way CommandLineToArgvW expects: embedded quotes are
' doubled up, and a trailing backslash is escaped so it cannot swallow the
' closing quote (the classic "C:\Some Folder\" bug).
' ---------------------------------------------------------------------------
Function QuoteArg(value)
    Dim s, trailing, i
    s = Replace(value, """", """""")

    ' Count the run of backslashes at the end and double it. "C:\" must be
    ' emitted as "C:\\" or the closing quote is escaped away.
    trailing = 0
    i = Len(s)
    Do While i > 0
        If Mid(s, i, 1) <> "\" Then Exit Do
        trailing = trailing + 1
        i = i - 1
    Loop
    If trailing > 0 Then s = s & String(trailing, "\")

    QuoteArg = """" & s & """"
End Function