' No-console launcher for the WinForms download/convert tools.
' Double-click this file (or drop links/files onto it). WScript is a GUI host,
' so no cmd.exe / powershell.exe console window is created at all.
' The target script is chosen by this file's name:
'   contains "m3u8" -> m3u8_gui.ps1, otherwise -> x_video_gui.ps1
Option Explicit

Dim fso, sh, here, self, script, ps1, cmd, i

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

here = fso.GetParentFolderName(WScript.ScriptFullName)
self = fso.GetBaseName(WScript.ScriptFullName)

If InStr(1, self, "m3u8", vbTextCompare) > 0 Then
    script = "m3u8_gui.ps1"
Else
    script = "x_video_gui.ps1"
End If

ps1 = fso.BuildPath(here, script)
If Not fso.FileExists(ps1) Then
    MsgBox "Cannot find " & script & " in the same folder." & vbCrLf & _
           "Keep this launcher and the .ps1 file together.", 16, "Launcher error"
    WScript.Quit 2
End If

cmd = "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Q(ps1)
For i = 0 To WScript.Arguments.Count - 1
    cmd = cmd & " " & Q(WScript.Arguments(i))
Next

' 0 = hidden window; False = do not wait, the launcher exits immediately
sh.Run cmd, 0, False

Function Q(s)
    Dim t
    t = CStr(s)
    If Len(t) > 0 Then
        If Right(t, 1) = "\" Then t = t & "\"
    End If
    Q = """" & Replace(t, """", "\""") & """"
End Function
