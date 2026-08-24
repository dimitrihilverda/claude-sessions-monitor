' Start de Claude-HUD zonder dat er een PowerShell-venster opflitst.
Set sh = CreateObject("WScript.Shell")
here = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = here
q = Chr(34)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & q & here & "\hud.ps1" & q, 0, False
