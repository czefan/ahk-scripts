#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Include %A_ScriptDir%\..\src\dialog_rescaler.ahk
DirCreate(A_ScriptDir "\output")

; 由独立测试桌面启动。不调用主工具箱，不选择文件，不提交保存。
if A_Args.Length && A_Args[1] = "target" {
    mode := A_Args[2]
    if mode = "folder"
        DirSelect((A_ScriptDir "\output"), 3, "Picker regression")
    else if SubStr(mode, 1, 6) = "legacy" {
        name := Buffer(520, 0), ofn := Buffer(152, 0)
        NumPut("UInt", ofn.Size, ofn)
        NumPut("Ptr", name.Ptr, ofn, 48)
        NumPut("UInt", 260, ofn, 56)
        NumPut("UInt", 0x1008 | (mode = "legacy-explorer" ? 0x80000 : 0), ofn, 96)
        DllCall("comdlg32\GetOpenFileNameW", "Ptr", ofn)
    } else {
        if SubStr(mode, 1, 5) = "pmv2-"
            DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
        FileSelect(InStr(mode, "save") ? "S16" : (mode = "multi" ? "M3" : "3"), (A_ScriptDir "\output"), "Picker regression")
    }
    ExitApp()
}

if A_Args.Length != 2 || A_Args[1] != "isolated"
    ExitApp(2)
global Report := A_Args[2]
try {
    for mode in ["open", "save", "multi", "folder", "legacy", "legacy-explorer", "pmv2-open", "pmv2-save"]
        TestPicker(mode)
    Log("PASS: eight picker variants inspected and cancelled; no selection or save")
} catch as err {
    Log("FAIL: " err.Message "`n" err.Stack)
    ExitApp(1)
}
ExitApp()

TestPicker(mode) {
    global RescaleNativePercent, RescaleBlacklist
    pid := hwnd := 0
    try {
        Run('"' A_AhkPath '" /ErrorStdOut "' A_ScriptFullPath '" target ' mode, , , &pid)
        hwnd := WinWait("ahk_class #32770 ahk_pid " pid, , 8)
        Assert(hwnd, "No picker: " mode)
        Sleep(250)
        RescaleNativePercent := 175
        RescaleBlacklist := CompileExclusionRules(DefaultExclusionRules())
        before := GetRescaleRect(hwnd)
        dpiBefore := DllCall("GetDpiForWindow", "Ptr", hwnd, "UInt")
        direct := HasRescaleDirectUI(hwnd), native := !!CanRescaleNatively(hwnd)
        baselineExcluded := IsRescaleExcludedWindow(hwnd)
        candidate := IsAutomaticRescaleWindow(hwnd)
        ; 精确复现删除前的两个文件选择框识别分支，仅在测试里加入。
        RescaleBlacklist.Push(WindowExclusionRule({ Name: "Old picker", Window: "ahk_class #32770",
            Features: ":root{1148/1152}`n:root > ComboBox*@1136", Scope: "all" }))
        RescaleBlacklist.Push(WindowExclusionRule({ Name: "New picker", Window: "ahk_class #32770",
            Features: "DUIViewWndClassName | SHBrowseForFolder ShellNameSpace Control", Scope: "all" }))
        withRule := IsRescaleExcludedWindow(hwnd)
        withCandidate := IsAutomaticRescaleWindow(hwnd)
        if withRule
            Assert(!SafeRescaleWindow(hwnd), "Historical exclusion was ignored")
        RescaleBlacklist.Pop(), RescaleBlacklist.Pop()
        result := SafeRescaleWindow(hwnd)
        after := GetRescaleRect(hwnd)
        unchanged := before.x = after.x && before.y = after.y && before.w = after.w && before.h = after.h
        dpiAfter := DllCall("GetDpiForWindow", "Ptr", hwnd, "UInt")
        if native && dpiBefore = 168
            Assert(unchanged && dpiAfter = dpiBefore, "Already-175% native picker changed")
        if direct && !native
            Assert(!candidate && !result && unchanged, "DirectUI fallback exclusion failed")
        buttons := 0, outside := 0
        for control in WinGetControlsHwnd(hwnd) {
            if WinGetClass(control) != "Button" || !DllCall("IsWindowVisible", "Ptr", control)
                continue
            buttons++
            rect := GetRescaleRect(control)
            if rect.x < after.x || rect.y < after.y || rect.x + rect.w > after.x + after.w || rect.y + rect.h > after.y +
                after.h
                outside++
        }
        Assert(!outside, "A standard button moved outside the picker")
        Log(mode ": dpi=" dpiBefore "->" dpiAfter " native=" native " DirectUI=" direct
            " baseline-excluded=" baselineExcluded " with-picker-rule=" withRule
            " candidate-with/without=" withCandidate "/" candidate " applied=" (!!result)
            " geometry-unchanged=" unchanged " standard-buttons=" buttons " outside=" outside)
    } finally {
        CleanupDialogRescaler()
        if hwnd && DllCall("IsWindow", "Ptr", hwnd)
            WinClose(hwnd)
        if pid {
            ProcessWaitClose(pid, 2)
            if ProcessExist(pid)
                ProcessClose(pid)
        }
    }
}
Assert(value, message) {
    if !value
        throw Error(message)
}
Log(message) => FileAppend(message "`r`n", Report, "UTF-8")

