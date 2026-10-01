#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Include ..\src\dialog_rescaler.ahk
#Include %A_LineFile%\..\..\Lib\UIA.ahk

global envPid := 0
OnError(EnvironmentTestError)
try {
    Run('"' A_WinDir '\System32\rundll32.exe" sysdm.cpl,EditEnvironmentVariables', , , &envPid)
    environment := WinWait("ahk_class #32770 ahk_pid " envPid, , 8)
    if !environment
        throw Error("Environment Variables did not open")
    CheckEnvironmentFonts(environment)
    root := UIA.ElementFromHandle(environment)
    root.FindElement({Name: "Path", Type: "ListItem", MatchMode: 2}).Select()
    editButton := root.FindElement({Type: "Button", Name: "^(Edit|编辑).*", MatchMode: "RegEx"})
    editButton.Invoke()
    editor := 0
    deadline := A_TickCount + 5000
    while !editor && A_TickCount < deadline {
        for candidate in WinGetList("ahk_class #32770 ahk_pid " envPid) {
            if candidate != environment {
                editor := candidate
                break
            }
        }
        Sleep(40)
    }
    if !editor
        throw Error("Environment editor did not open")
    CheckEnvironmentFonts(editor)
    WinClose(editor) ; 未修改变量，关闭编辑窗口，不提交。
    WinWaitClose(editor, , 3)
    FileAppend("PASS environment dialog and Path editor: fitted fonts and visible button bounds`n", "*")
} finally {
    CleanupDialogRescaler()
    if IsSet(environment) && DllCall("IsWindow", "Ptr", environment)
        WinClose(environment)
    if envPid && ProcessExist(envPid) {
        ProcessWaitClose(envPid, 3)
        if ProcessExist(envPid)
            ProcessClose(envPid)
    }
}
ExitApp()

CheckEnvironmentFonts(hwnd) {
    global RescaleFontSize
    context := DllCall("GetWindowDpiAwarenessContext", "Ptr", hwnd, "Ptr")
    FileAppend("Window=" WinGetTitle(hwnd) " dpi=" DllCall("GetDpiForWindow", "Ptr", hwnd, "UInt")
        " awareness=" DllCall("GetAwarenessFromDpiAwarenessContext", "Ptr", context) "`n", "*")
    if !SafeRescaleWindow(hwnd)
        throw Error("Environment window was not processed")
    if !ScaledHwnds.Has(hwnd) || ScaledHwnds[hwnd].HasOwnProp("dpi")
        throw Error("Environment window did not enter font fallback")
    old := DllCall("SetThreadDpiAwarenessContext", "Ptr", context, "Ptr")
    count := 0
    try {
        outer := GetRescaleRect(hwnd)
        for control in WinGetControlsHwnd(hwnd) {
            if !DllCall("IsWindowVisible", "Ptr", control) || !RegExMatch(WinGetClass(control), "^(Button|Static|Edit|SysListView32)$")
                continue
            font := RescaleSend(control, 0x31)
            if !font
                continue
            lf := ReadRescaleLogFont(font)
            dpi := DllCall("GetDpiForWindow", "Ptr", control, "UInt")
            if !lf || Abs(NumGet(lf, 0, "Int")) != Round(ScaledHwnds[hwnd].fontSize * dpi / 72)
                throw Error("Unexpected font height")
            if WinGetClass(control) = "Button" {
                r := GetRescaleRect(control)
                if r.x < outer.x || r.y < outer.y || r.x + r.w > outer.x + outer.w || r.y + r.h > outer.y + outer.h
                    throw Error("A visible button is outside the window")
            }
            count++
        }
    } finally {
        DllCall("SetThreadDpiAwarenessContext", "Ptr", old, "Ptr")
    }
    if !count
        throw Error("No font controls were inspected")
    FileAppend("Verified " ScaledHwnds[hwnd].fontSize "pt on " count " visible controls`n", "*")
}
EnvironmentTestError(err, *) {
    FileAppend("FAIL " err.Message "`n" err.Stack "`n", "*")
    if envPid && ProcessExist(envPid) {
        try ProcessClose(envPid)
    }
    ExitApp(1)
}

