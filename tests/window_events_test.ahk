#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Include %A_ScriptDir%\..\src\dialog_rescaler.ahk

RescaleLegacyEnabled := true ; 此测试覆盖旧式路径和公共事件队列。
RescaleNativePercent := 0

global ObservedWindow := 0
global HiddenCount := 0
try {
    RunEventTest()
} catch as err {
    FileAppend("FAIL: " err.Message "`n" err.Stack "`n", "*")
    ExitApp(1)
}
ExitApp()

AcceptTestWindow(hwnd) => WinGetClass(hwnd) = "AutoHotkeyGUI"

VanishedCandidate(hwnd) {
    throw TargetError("Simulated window closing during startup enumeration")
}

RunEventTest() {
    global RescaleEvents, ScaledHwnds, ObservedWindow, RescaleFrozen
    pid := 0
    hook := callback := 0
    ready := A_ScriptDir "\event_" DllCall("GetCurrentProcessId") ".txt"
    try {
        Run('"' A_AhkPath '" /ErrorStdOut "' A_ScriptDir '\dialog_rescaler_test.ahk" target "' ready '" x64', , "Hide", &
            pid)
        WaitFor(() => FileExist(ready), 3000, "Target did not start")
        handles := StrSplit(Trim(FileRead(ready, "UTF-8"), "`r`n"), "`n")
        hwnd := ObservedWindow := Integer(handles[1])
        original := GetRescaleRect(hwnd)
        expected := Round(RescaleFontSize * DllCall("GetDpiForWindow", "Ptr", hwnd, "UInt") / 72)
        callback := CallbackCreate(RecordHidden, , 7)
        hook := DllCall("SetWinEventHook", "UInt", 0x8003, "UInt", 0x8003, "Ptr", 0,
            "Ptr", callback, "UInt", pid, "UInt", 0, "UInt", 2, "Ptr")
        if !hook
            throw OSError(A_LastError)
        RescaleEvents := MeasuredWindowEvents(pid, AcceptTestWindow)
        started := DllCall("GetTickCount64", "UInt64")
        DllCall("ShowWindowAsync", "Ptr", hwnd, "Int", 8)
        try WaitFor(() => ScaledHwnds.Has(hwnd), 1500, "Show event did not trigger scaling")
        catch as err {
            throw Error(err.Message " (visible=" DllCall("IsWindowVisible", "Ptr", hwnd)
            ", queued=" RescaleEvents.jobs.Count ", last=" RescaleEvents.lastError ")")
        }
        elapsed := DllCall("GetTickCount64", "UInt64") - started
        WaitFor(() => !RescaleEvents.jobs.Count, 1000, "Event queue did not settle")
        Check(GetRescaleRect(hwnd).w > original.w, "Window did not enlarge")
        Check(RescaleSend(hwnd, 0x8101, Integer(handles[2])) = expected, "Target font is invalid")
        enlargedWidth := GetRescaleRect(hwnd).w
        page := RescaleSend(hwnd, 0x8103)
        child := DllCall("GetWindow", "Ptr", page, "UInt", 5, "Ptr")
        try WaitFor(() => ScaledHwnds[hwnd].nodes.Has(child), 1500, "Delayed page did not trigger processing")
        catch as err {
            throw Error(err.Message " (page=" page ", child=" child ", valid=" DllCall("IsWindow", "Ptr", child)
            ", queued=" RescaleEvents.jobs.Count ", last=" RescaleEvents.lastError ")")
        }
        Check(RescaleSend(hwnd, 0x8101, child) = expected, "Delayed page font is invalid")
        Check(GetRescaleRect(hwnd).w = enlargedWidth, "Child events rescaled the main window again")
        DllCall("ShowWindow", "Ptr", page, "Int", 0)
        WaitFor(() => !RescaleEvents.jobs.Count, 1000, "Page event queue did not settle")
        appliesBefore := RescaleEvents.applies
        initializingPage := RescaleSend(hwnd, 0x8108)
        Sleep(150)
        Check(!ScaledHwnds[hwnd].nodes.Has(initializingPage),
        "A hidden page was processed before initialization finished")
        Check(RescaleEvents.applies = appliesBefore, "Hidden page creation triggered unnecessary processing")
        initializingLabel := RescaleSend(hwnd, 0x8109, initializingPage)
        WaitFor(() => ScaledHwnds[hwnd].nodes.Has(initializingLabel), 1500, "First page display was not handled")
        Check(RescaleSend(hwnd, 0x8101, initializingLabel) = expected, "New page font is incorrect")
        Check(RescaleSend(hwnd, 0x8102, initializingLabel),
        "First page display clips text until switching away and back")
        Check(GetRescaleRect(hwnd).w = enlargedWidth, "New page enlarged the whole window again")
        Check(HiddenCount = 0 && DllCall("IsWindowVisible", "Ptr", hwnd), "Processing hid the window")
        RunResourceCycles(hwnd, expected)
        StopDialogRescaler()
        Check(DllCall("IsWindowVisible", "Ptr", hwnd), "Stopping the listener affected visibility")
        Check(ScaledHwnds.Has(hwnd), "Pausing discarded the live window state")
        ; 不可能匹配的条件隔离测试快捷键，不覆盖日常脚本的 Win+F11。
        HotIf((*) => false)
        StartDialogRescaler(pid, AcceptTestWindow)
        WaitFor(() => !RescaleEvents.jobs.Count, 1000, "Resume queue did not settle")
        Check(GetRescaleRect(hwnd).w = enlargedWidth, "Resume enlarged the same window twice")
        StopDialogRescaler()
        HotIf()
        racing := RescaleWindowEvents(pid, VanishedCandidate)
        Check(!racing.closed && !racing.jobs.Count, "A vanished window aborted listener startup")
        racing.Close()
        RescaleSend(hwnd, 0xB, false)
        RescaleFrozen := hwnd
        CleanupDialogRescaler()
        Check(DllCall("IsWindowVisible", "Ptr", hwnd)
        && !DllCall("GetPropW", "Ptr", hwnd, "Str", "SysSetRedraw", "Ptr"), "Exit cleanup did not restore drawing")
        Check(!ScaledHwnds.Count && !RescaleProcesses.Count && !HasRescaleMarker(hwnd),
        "Exit cleanup retained window state, process handles or markers")
        FileAppend("PASS: event scaling in " elapsed "ms; no hide events; delayed page and repeat checks passed`n", "*"
        )
    } finally {
        CleanupDialogRescaler()
        RescaleEvents := 0
        if hook
            DllCall("UnhookWinEvent", "Ptr", hook)
        if callback
            CallbackFree(callback)
        if pid && ProcessExist(pid)
            ProcessClose(pid)
        if FileExist(ready)
            FileDelete(ready)
    }
}

class MeasuredWindowEvents extends RescaleWindowEvents {
    __New(pid, acceptWindow) {
        this.applies := 0
        this.processingMs := []
        super.__New(pid, acceptWindow)
    }

    Apply(hwnd) {
        this.applies += 1
        started := PerformanceMs()
        super.Apply(hwnd)
        this.processingMs.Push(PerformanceMs() - started)
    }
}

RunResourceCycles(target, expected) {
    ; 同一目标进程反复打开新窗口，检验字体复用和窗口状态回收。
    latencies := []
    loop 55 {
        started := PerformanceMs()
        hwnd := RescaleSend(target, 0x810A)
        try WaitFor(() => ScaledHwnds.Has(hwnd), 1500, "New window was not processed")
        catch as err {
            throw Error(err.Message " (visible=" DllCall("IsWindowVisible", "Ptr", hwnd)
            ", queued=" RescaleEvents.jobs.Count ", last=" RescaleEvents.lastError ")")
        }
        if A_Index > 5
            latencies.Push(PerformanceMs() - started)
        label := DllCall("GetWindow", "Ptr", hwnd, "UInt", 5, "Ptr")
        Check(RescaleSend(target, 0x8101, label) = expected, "Repeated dialog font is invalid")
        Check(RescaleSend(target, 0x810B) = 1, "Target did not acknowledge window destruction")
        Check(!DllCall("IsWindow", "Ptr", hwnd), "The test window is still alive after destruction")
        try WaitFor(() => !ScaledHwnds.Has(hwnd) && !RescaleEvents.jobs.Count, 1000,
        "Closed window state was not released")
        catch as err {
            throw Error(err.Message " (hwnd=" hwnd ", cached=" ScaledHwnds.Has(hwnd)
            ", queued=" RescaleEvents.jobs.Count ", busy=" RescaleBusy ", last=" RescaleEvents.lastError ")")
        }
        if A_Index = 5 || A_Index = 30 || A_Index = 55 {
            resources := ReadTestResources(target)
            FileAppend("RESOURCES cycles=" (A_Index - 5) ": handles=" resources.handles
            ", gdi=" resources.gdi ", target-gdi=" resources.targetGdi
            ", private-MiB=" Round(resources.private / 1048576, 2) "`n", "*")
            if A_Index = 5
                baseline := resources
            else {
                Check(resources.handles <= baseline.handles, "Process handles grew after opening/closing dialogs")
                Check(resources.gdi <= baseline.gdi && resources.targetGdi <= baseline.targetGdi,
                    "GDI objects grew after opening/closing dialogs")
                Check(ScaledHwnds.Count = 1, "Destroyed windows remain in the state cache")
            }
        }
    }
    PrintTimings("warm dialog create-to-scaled", latencies)
    PrintTimings("handler duration (includes cold/refresh)", RescaleEvents.processingMs)
}

PerformanceMs() {
    static frequency := 0
    if !frequency
        DllCall("QueryPerformanceFrequency", "Int64*", &frequency)
    DllCall("QueryPerformanceCounter", "Int64*", &counter := 0)
    return counter * 1000 / frequency
}

PrintTimings(label, values) {
    sorted := []
    total := 0
    for value in values {
        index := 1
        while index <= sorted.Length && sorted[index] <= value
            index++
        sorted.InsertAt(index, value)
        total += value
    }
    if sorted.Length
        FileAppend(label ": n=" sorted.Length " avg=" Round(total / sorted.Length, 2)
        "ms p50=" Round(sorted[Ceil(sorted.Length * 0.5)], 2)
        "ms p95=" Round(sorted[Ceil(sorted.Length * 0.95)], 2)
        "ms max=" Round(sorted[-1], 2) "ms`n", "*")
}

ReadTestResources(target) {
    process := DllCall("GetCurrentProcess", "Ptr")
    handles := 0
    Check(DllCall("GetProcessHandleCount", "Ptr", process, "UInt*", &handles), "Could not read handle count")
    memory := Buffer(80, 0)
    Check(DllCall("psapi\GetProcessMemoryInfo", "Ptr", process, "Ptr", memory, "UInt", memory.Size),
    "Could not read process memory")
    return { handles: handles, private: NumGet(memory, 72, "UPtr"),
        gdi: DllCall("GetGuiResources", "Ptr", process, "UInt", 0, "UInt"), targetGdi: RescaleSend(target, 0x8106) }
}

RecordHidden(hook, event, hwnd, objectId, childId, threadId, time) {
    global HiddenCount
    if hwnd = ObservedWindow && !objectId && !childId
        HiddenCount += 1
}

WaitFor(predicate, timeout, message) {
    deadline := DllCall("GetTickCount64", "UInt64") + timeout
    while DllCall("GetTickCount64", "UInt64") < deadline {
        if predicate()
            return
        Sleep(5)
    }
    throw Error(message)
}

Check(condition, message) {
    if !condition
        throw Error(message)
}

