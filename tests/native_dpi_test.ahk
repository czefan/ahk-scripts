#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Include ..\src\dialog_rescaler.ahk

OnError(NativeTestError)
if A_Args.Length && A_Args[1] = "task_target" {
    DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
    DllCall("comctl32\TaskDialog", "Ptr", 0, "Ptr", 0, "Str", "Isolated DPI API experiment",
        "Str", "Native TaskDialog DPI test", "Str", "Both buttons should remain visible.",
        "UInt", 9, "Ptr", 0, "Int*", &choice := 0)
    ExitApp()
}
if A_Args.Length && A_Args[1] = "target" {
    global FixtureContext := A_Args.Length > 1 ? Integer(A_Args[2]) : -4
    global FixtureCallback := CallbackCreate((*) => 0, , 4)
    global FixtureMain := MakeFixture("Native DPI main"), FixturePopup := 0
    OnMessage(0x8801, (*) => NewPopup())
    OnMessage(0x8802, (*) => ClosePopup())
    OnMessage(0x8803, (hwnd, *) => FixtureFont(hwnd))
    OnMessage(0x8804, (*) => SetTimer(() => ExitApp(), -10))
    Persistent()
    return
}

DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
DetectHiddenWindows(true)
pid := 0
try {
    Run('"' A_AhkPath '" /ErrorStdOut "' A_ScriptFullPath '" target', , "Hide", &pid)
    hwnd := WinWait("Native DPI main ahk_pid " pid, , 5)
    Assert(hwnd, "Fixture startup failed")
    script := WinExist("ahk_class AutoHotkey ahk_pid " pid)
    baseline := Dpi(hwnd)
    if baseline = 168 {
        before := Dimensions(hwnd)
        Assert(SafeRescaleWindow(hwnd, AcceptNativeFixture), "Already-target DPI check failed")
        Assert(Dimensions(hwnd) = before && !ScaledHwnds.Count && !RescaleProcesses.Count,
            "Already-target window was modified or allocated resources")
    }
    RescaleNativePercent := baseline = 168 ? 200 : 175
    targetDpi := Round(RescaleNativePercent * 96 / 100)
    expectedFont := Round(9 * targetDpi / 72)
    RescaleEvents := RescaleWindowEvents(pid, AcceptNativeFixture)
    DllCall("ShowWindow", "Ptr", hwnd, "Int", 4)
    WaitUntil(() => Dpi(hwnd) = targetDpi && ScaledHwnds.Has(hwnd))
    Assert(ScaledHwnds[hwnd].HasOwnProp("dpi"), "Native state not recorded")
    Assert(SendMessage(0x8803, hwnd, 0, script) = expectedFont, "Native font size is incorrect")
    Assert(!RescaleProcesses.Count, "Native path allocated remote font resources")
    size := Dimensions(hwnd)
    Loop 3
        Assert(SafeRescaleWindow(hwnd, AcceptNativeFixture), "Idempotent application failed")
    Assert(size = Dimensions(hwnd), "Repeated call enlarged the window again")

    popup := SendMessage(0x8801, 0, 0, script)
    Assert(Dpi(popup) = baseline, "Owned fixture did not start at monitor DPI")
    DllCall("ShowWindow", "Ptr", popup, "Int", 4)
    WaitUntil(() => Dpi(popup) = targetDpi && ScaledHwnds.Has(popup))
    WaitUntil(() => SendMessage(0x8803, popup, 0, script) = expectedFont)
    SendMessage(0x8802, 0, 0, script)
    WaitUntil(() => !ScaledHwnds.Has(popup))

    RescaleBlacklist.Push("Native DPI child")
    popup := SendMessage(0x8801, 0, 0, script)
    DllCall("ShowWindow", "Ptr", popup, "Int", 4)
    Sleep(150)
    Assert(!SafeRescaleWindow(popup, AcceptNativeFixture) && Dpi(popup) = baseline, "Blacklist was bypassed")
    RescaleBlacklist.Pop()
    Assert(SafeRescaleWindow(popup, AcceptNativeFixture) && Dpi(popup) = targetDpi, "Removing blacklist did not enable native path")
    SendMessage(0x8802, 0, 0, script)
    WaitUntil(() => !ScaledHwnds.Has(popup))

    Loop 15 {
        popup := SendMessage(0x8801, 0, 0, script)
        DllCall("ShowWindow", "Ptr", popup, "Int", 4)
        WaitUntil(() => Dpi(popup) = targetDpi && ScaledHwnds.Has(popup))
        Assert(!RescaleProcesses.Count, "Resource cache entered legacy mode")
        SendMessage(0x8802, 0, 0, script)
        WaitUntil(() => !ScaledHwnds.Has(popup))
    }
    Assert(ScaledHwnds.Count = 1, "Closed popup state accumulated")
    RescaleEvents.Close()
    popup := SendMessage(0x8801, 0, 0, script)
    work := GetRescaleWorkArea(popup)
    WinMove(work.x + 10, work.y + 10, work.w - 20, work.h - 100, popup)
    DllCall("ShowWindow", "Ptr", popup, "Int", 4)
    Assert(!SafeRescaleWindow(popup, AcceptNativeFixture), "Oversized native dialog was accepted")
    Assert(Dpi(popup) = baseline, "Oversized dialog DPI was not restored")
    SendMessage(0x8802, 0, 0, script)
    ; 新的最大化窗口，用实际可调整大小的 Win32 对话框验证，而非固定大小 TaskDialog。
    popup := SendMessage(0x8801, 0, 0, script)
    WinMaximize(popup)
    Sleep(150)
    Assert(WinGetMinMax(popup) = 1, "Fixture not maximized")
    Assert(SafeRescaleWindow(popup, AcceptNativeFixture), "Maximized native application failed")
    Assert(Dpi(popup) = targetDpi && WinGetMinMax(popup) = 1, "Maximized state or DPI lost")
    rect := GetRescaleRect(popup), work := GetRescaleWorkArea(popup)
    Assert(Abs(rect.w - work.w) < 40 && Abs(rect.h - work.h) < 40, "Maximized window did not fit work area")
    Assert(SendMessage(0x8803, popup, 0, script) = expectedFont, "Maximized font not scaled")
    Assert(!RescaleProcesses.Count, "Native tests created remote fonts")
    CleanupDialogRescaler()
    Assert(!ScaledHwnds.Count && !RescaleEvents.jobs.Count, "Cleanup left state or timers")
    RescaleNativePercent := 0
    RescaleLegacyEnabled := true
    Assert(!SafeRescaleWindow(popup, AcceptNativeFixture), "Cleanup/disable allowed legacy scaling on a native window")
    Assert(!RescaleProcesses.Count, "Switching mode stacked remote fonts on native DPI")
    FileAppend("PASS native: target=" targetDpi " DPI, owned popup, blacklist, idempotence, 15 resource cycles, oversize rollback, maximize, cleanup`n", "*")
    SendMessage(0x8804, 0, 0, script)
    ProcessWaitClose(pid, 2)
} finally {
    CleanupDialogRescaler()
    if pid && ProcessExist(pid)
        ProcessClose(pid)
}
TestTaskDialog()
ExitApp()

TestTaskDialog() {
    global RescaleNativePercent, RescaleEvents
    RescaleNativePercent := 175
    pid := 0
    try {
        Run('"' A_AhkPath '" /ErrorStdOut "' A_ScriptFullPath '" task_target', , "Hide", &pid)
        hwnd := WinWait("Isolated DPI API experiment ahk_pid " pid, , 5)
        Assert(hwnd, "TaskDialog startup failed")
        RescaleEvents := RescaleWindowEvents(pid)
        WaitUntil(() => Dpi(hwnd) = 168)
        Sleep(200) ; DPI 字段先更新，等待目标进程完成原生布局和重绘。
        Assert(HasRescaleDirectUI(hwnd), "TaskDialog fixture has no DirectUI")
        Assert(!RescaleProcesses.Count, "TaskDialog entered manual font path")
        outer := GetRescaleRect(hwnd), buttons := 0
        for child in WinGetControlsHwnd(hwnd) {
            if WinGetClass(child) != "Button" || !DllCall("IsWindowVisible", "Ptr", child)
                continue
            r := GetRescaleRect(child)
            Assert(r.w > 0 && r.h > 0 && r.x >= outer.x && r.y >= outer.y
                && r.x + r.w <= outer.x + outer.w && r.y + r.h <= outer.y + outer.h,
                "TaskDialog button lies outside the window")
            buttons++
        }
        Assert(buttons = 2, "TaskDialog buttons missing")
        FileAppend("PASS real TaskDialog: automatic native 175%, two buttons intact, no remote fonts`n", "*")
    } finally {
        CleanupDialogRescaler()
        if IsSet(hwnd) && DllCall("IsWindow", "Ptr", hwnd)
            WinClose(hwnd)
        if pid && ProcessExist(pid) {
            ProcessWaitClose(pid, 2)
            if ProcessExist(pid)
                ProcessClose(pid)
        }
    }
}

WaitUntil(check) {
    limit := A_TickCount + 4000
    while !check.Call() {
        if A_TickCount > limit
            throw Error("Timed out: " RescaleEvents.lastError)
        Sleep(20)
    }
}
Assert(condition, message) {
    if !condition
        throw Error(message)
}
Dpi(hwnd) => DllCall("GetDpiForWindow", "Ptr", hwnd, "UInt")
AcceptNativeFixture(hwnd) => WinGetClass(hwnd) = "NativeDpiTestDialog"
Dimensions(hwnd) {
    r := GetRescaleRect(hwnd)
    return r.w "x" r.h
}
NewPopup() {
    global FixturePopup
    FixturePopup := MakeFixture("Native DPI child", FixtureMain)
    return FixturePopup
}
ClosePopup() {
    global FixturePopup
    if FixturePopup
        DllCall("DestroyWindow", "Ptr", FixturePopup)
    FixturePopup := 0
    return 1
}
FixtureFont(hwnd) {
    child := DllCall("GetDlgItem", "Ptr", hwnd, "Int", 1, "Ptr")
    font := SendMessage(0x31, 0, 0, child)
    lf := Buffer(92, 0)
    return DllCall("GetObjectW", "Ptr", font, "Int", 92, "Ptr", lf) ? Abs(NumGet(lf, 0, "Int")) : -1
}
MakeFixture(title, owner := 0) {
    previous := DllCall("SetThreadDpiAwarenessContext", "Ptr", FixtureContext, "Ptr")
    try {
        instance := DllCall("GetModuleHandleW", "Ptr", 0, "Ptr")
        static dialogAtom := 0
        if !dialogAtom {
            wc := Buffer(80, 0)
            NumPut("UInt", 80, wc)
            if !DllCall("GetClassInfoExW", "Ptr", 0, "Str", "#32770", "Ptr", wc)
                throw OSError()
            dialogClass := "NativeDpiTestDialog"
            NumPut("Ptr", instance, wc, 24)
            NumPut("Ptr", StrPtr(dialogClass), wc, 64)
            dialogAtom := DllCall("RegisterClassExW", "Ptr", wc, "UShort")
            if !dialogAtom
                throw OSError()
        }
        b := Buffer(1024, 0)
        NumPut("UInt", 0x00CF0040, "UInt", 0, "UShort", 1, "Short", 30, "Short", 30, "Short", 220, "Short", 90, b)
        offset := 20
        PutText(b, &offset, "NativeDpiTestDialog")
        PutText(b, &offset, title)
        NumPut("UShort", 9, b, offset), offset += 2
        PutText(b, &offset, "Segoe UI")
        offset := (offset + 3) & ~3
        NumPut("UInt", 0x50000000, "UInt", 0, "Short", 150, "Short", 60, "Short", 60, "Short", 18, "UShort", 1, b, offset)
        offset += 18
        NumPut("UShort", 0xFFFF, "UShort", 0x80, b, offset), offset += 4
        PutText(b, &offset, "OK")
        instance := DllCall("GetModuleHandleW", "Ptr", 0, "Ptr")
        hwnd := DllCall("CreateDialogIndirectParamW", "Ptr", instance, "Ptr", b, "Ptr", owner, "Ptr", FixtureCallback, "Ptr", 0, "Ptr")
        if !hwnd
            throw OSError()
        return hwnd
    } finally {
        DllCall("SetThreadDpiAwarenessContext", "Ptr", previous, "Ptr")
    }
}
PutText(b, &offset, text) {
    StrPut(text, b.Ptr + offset, StrLen(text) + 1, "UTF-16")
    offset += (StrLen(text) + 1) * 2
}

NativeTestError(err, *) {
    global pid
    FileAppend("FAIL " err.Message "`n" err.Stack "`n", "*")
    if IsSet(pid) && pid && ProcessExist(pid) {
        try ProcessClose(pid)
    }
    ExitApp(1)
}

