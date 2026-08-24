' Start de Claude sessie-API (voor de CYD) zonder consolevenster.
Set sh = CreateObject("WScript.Shell")
here = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = here
q = Chr(34)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & q & here & "\session-api.ps1" & q, 0, False
