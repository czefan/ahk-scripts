#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#Include %A_LineFile%\..\..\src\toolbox.ahk
#SingleInstance Off
OnError(SecurityTestError)

if A_Args.Length && A_Args[1] = "child" {
    elevated := IsProcessElevated(DllCall("GetCurrentProcessId"))
    parent := DllCall("OpenProcess", "UInt", 0x100000, "Int", false, "UInt", Integer(A_Args[3]), "Ptr")
    parentReadable := !!parent
    if parent
        DllCall("CloseHandle", "Ptr", parent)
    FileAppend(elevated "," parentReadable, A_Args[2], "UTF-8")
    Sleep(800)
    ExitApp()
}

DirCreate(ToolboxSettings.Directory "\tests\output")
report := A_Args.Length ? A_Args[1] : ToolboxSettings.Directory "\tests\output\ahk-security-result.txt"
childReport := ToolboxSettings.Directory "\tests\output\ahk-security-child-" DllCall("GetCurrentProcessId") ".txt"
settingsPath := ToolboxSettings.Directory "\tests\output\ahk-security-settings-" DllCall("GetCurrentProcessId") ".ini"
pid := workerPid := 0, manager := 0
try {
    RunUnelevated(A_ProgramFiles "\AutoHotkey\v2\AutoHotkey64.exe", '"' A_ScriptFullPath '" child "'
        childReport '" ' DllCall("GetCurrentProcessId"), ToolboxSettings.Directory, &pid)
    Assert(!IsProcessElevated(pid), "Child retained administrator privileges")
    ProcessWaitClose(pid, 5)
    Assert(!ProcessExist(pid) && FileExist(childReport), "Child did not finish")
    values := StrSplit(FileRead(childReport, "UTF-8"), ",")
    Assert(values[1] = 0 && values[2] = 1, "Token or parent synchronization access check failed")
    settings := ToolboxSettings.Defaults()
    settings["RetryTarget"] := "ahk_exe no-such-security-test-process.exe"
    ToolboxSettings.Save(settings, settingsPath)
    manager := Toolbox(settings, settingsPath)
    manager.StartWorker()
    workerPid := manager.worker.pid
    Assert(!IsProcessElevated(workerPid), "Retry worker is elevated")
    manager.StopWorker()
    ProcessWaitClose(workerPid, 3)
    Assert(!ProcessExist(workerPid), "Retry worker could not be stopped")
    FileAppend("PASS parent-elevated=" A_IsAdmin " child-elevated=" values[1] " retry-worker-elevated=0`r`n", report, "UTF-8")
} catch as err {
    FileAppend("FAIL " err.Message "`r`n" err.Stack "`r`n", report, "UTF-8")
    ExitApp(1)
} finally {
    if manager
        try manager.StopWorker()
    for child in [pid, workerPid] {
        if child && ProcessExist(child)
            ProcessClose(child)
    }
    for path in [childReport, settingsPath] {
        if FileExist(path)
            FileDelete(path)
    }
}
ExitApp()
Assert(condition, message) {
    if !condition
        throw Error(message)
}
SecurityTestError(err, *) {
    destination := A_Args.Length && A_Args[1] = "child" ? A_Args[2] : (A_Args.Length ? A_Args[1] : ToolboxSettings.Directory "\tests\output\security-error.log")
    try FileAppend("FAIL " err.Message "`r`n", destination, "UTF-8")
    ExitApp(1)
}


