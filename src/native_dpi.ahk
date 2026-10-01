#Requires AutoHotkey v2.0

; 内部测试 API：只用于原生 DPI 重排的 PMv2 窗口；不修改控件字体或坐标。
GetNativeDpiApi() {
    static api := DllCall("GetProcAddress", "Ptr", DllCall("GetModuleHandleW", "Str", "win32u.dll", "Ptr"),
        "AStr", "NtUserForceWindowToDpiForTest", "Ptr")
    return api
}

CanRescaleNatively(hwnd) {
    if !RescaleNativePercent || !GetNativeDpiApi()
        return false
    context := DllCall("GetWindowDpiAwarenessContext", "Ptr", hwnd, "Ptr")
    return context && DllCall("AreDpiAwarenessContextsEqual", "Ptr", context, "Ptr", -4)
}

ApplyNativeRescale(hwnd) {
    desired := Round(96 * RescaleNativePercent / 100)
    current := DllCall("GetDpiForWindow", "Ptr", hwnd, "UInt")
    if !current
        return false
    if DllCall("GetPropW", "Ptr", hwnd, "Str", RescaleModeProperty, "Ptr") = 2
        return false ; 已经手动改过字体的窗口须重开，避免叠加放大。
    if current = desired
        return true
    ; 同步调用前先检查窗口响应，避免明显挂起的窗口拖住事件队列。
    RescaleSend(hwnd, 0)
    maximized := DllCall("IsZoomed", "Ptr", hwnd)
    if maximized
        WinRestore(hwnd)
    try {
        if !DllCall(GetNativeDpiApi(), "Ptr", hwnd, "UInt", desired, "Int")
            throw OSError(A_LastError, , "窗口拒绝原生 DPI 调整")
    } finally {
        if maximized && DllCall("IsWindow", "Ptr", hwnd)
            WinMaximize(hwnd) ; 用新的 DPI 重新计算最大化布局。
    }
    if DllCall("GetDpiForWindow", "Ptr", hwnd, "UInt") != desired
        return false
    if !maximized {
        rect := GetRescaleRect(hwnd), work := GetRescaleWorkArea(hwnd)
        if rect.w > work.w || rect.h > work.h {
            if !DllCall(GetNativeDpiApi(), "Ptr", hwnd, "UInt", current, "Int")
                throw OSError(A_LastError, , "放大超出屏幕，恢复原 DPI 失败")
            return false
        }
    }
    ScaledHwnds[hwnd] := {dpi: desired}
    DllCall("SetPropW", "Ptr", hwnd, "Str", RescaleModeProperty, "Ptr", 1)
    DllCall("SetPropW", "Ptr", hwnd, "Str", RescaleProperty, "Ptr", RescaleOwner)
    return true
}

RescaleSkipReason(hwnd) {
    if IsRescaleExcludedWindow(hwnd)
        return "此窗口在黑名单中，已跳过"
    if DllCall("GetPropW", "Ptr", hwnd, "Str", RescaleModeProperty, "Ptr")
        return "此窗口已按另一种方式调整；切换缩放模式请关闭后重开"
    if !RescaleNativePercent
        return "原生 DPI 缩放已关闭，此窗口未应用旧式字体"
    context := DllCall("GetWindowDpiAwarenessContext", "Ptr", hwnd, "Ptr")
    awareness := context ? DllCall("GetAwarenessFromDpiAwarenessContext", "Ptr", context) : -1
    if awareness = 0
        return "此窗口不感知 DPI，无法使用原生 " RescaleNativePercent "% 缩放，已保留原界面"
    if IsRescaleExcludedWindow(hwnd, "legacy")
        return "此窗口命中了仅针对字体兜底的排除规则"
    return "此窗口不支持、已处理为旧式字体或放大后超出屏幕；可关闭重开后再试"
}
