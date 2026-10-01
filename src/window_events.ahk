#Requires AutoHotkey v2.0

; 页面实际显示后再调字号，避免干扰隐藏页面的初始化。
class RescaleWindowEvents {
    __New(pidFilter := 0, acceptWindow := 0) {
        this.jobs := Map()
        this.closed := false
        this.lastError := ""
        this.candidate := acceptWindow ? acceptWindow : IsRescaleCandidateWindow
        this.callback := CallbackCreate(ObjBindMethod(this, "Event"), , 7)
        ; 只监听显示/销毁；隐藏控件的创建无需唤醒脚本。
        this.hook := DllCall("SetWinEventHook", "UInt", 0x8001, "UInt", 0x8002, "Ptr", 0,
            "Ptr", this.callback, "UInt", pidFilter, "UInt", 0, "UInt", 2, "Ptr")
        if !this.hook {
            CallbackFree(this.callback)
            throw OSError(A_LastError, , "无法监听窗口事件")
        }
        try {
            ; 仅启动时扫描一次，兼顾已经打开的窗口。
            for hwnd in WinGetList() {
                try {
                    if (!pidFilter || WinGetPID(hwnd) = pidFilter) && this.candidate.Call(hwnd)
                        this.Queue(hwnd)
                } catch TargetError {
                    continue ; 枚举后窗口可能立即关闭，不应使整个监听器启动失败。
                }
            }
        } catch as err {
            this.Close()
            throw err
        }
    }

    Event(hook, event, hwnd, objectId, childId, threadId, timestamp) {
        if this.closed || !hwnd || objectId || childId
            return
        try {
            if event = 0x8001 {
                if this.jobs.Has(hwnd) {
                    SetTimer this.jobs[hwnd], 0
                    this.jobs.Delete(hwnd)
                }
                if ScaledHwnds.Has(hwnd)
                    ScaledHwnds.Delete(hwnd)
                return
            }
            root := DllCall("GetAncestor", "Ptr", hwnd, "UInt", 2, "Ptr")
            ; 顶层 SHOW 可能早于可见状态更新；延后到 Apply 检查，避免漏掉新窗口。
            if hwnd != root && !DllCall("IsWindowVisible", "Ptr", hwnd)
                return
            ; 回调只做廉价筛选；子控件排除规则留到 Apply 合并后检查。
            if root && !this.jobs.Has(root) && this.candidate.Call(root)
                this.Queue(root)
        } catch as err {
            this.lastError := err.Message
            OutputDebug("窗口事件：" err.Message)
        }
    }

    Queue(hwnd) {
        if !this.closed && !this.jobs.Has(hwnd) {
            this.jobs[hwnd] := ObjBindMethod(this, "Apply", hwnd)
            SetTimer this.jobs[hwnd], -15
        }
    }

    Apply(hwnd) {
        if this.closed || !this.jobs.Has(hwnd)
            return
        if RescaleBusy {
            SetTimer this.jobs[hwnd], -15
            return
        }
        this.jobs.Delete(hwnd)
        try {
            if DllCall("IsWindowVisible", "Ptr", hwnd)
                SafeRescaleWindow(hwnd, this.candidate)
        } catch as err {
            this.lastError := err.Message
            OutputDebug("窗口调整：" err.Message)
        }
        PruneRescaleProcesses()
    }

    Close() {
        if this.closed
            return
        this.closed := true
        DllCall("UnhookWinEvent", "Ptr", this.hook)
        CallbackFree(this.callback)
        for hwnd, timer in this.jobs
            SetTimer timer, 0
        this.jobs.Clear()
    }
}
