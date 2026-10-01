#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#Include %A_ScriptDir%\..\src\codex_auto_retry.ahk

; 只读诊断：可在普通、最小化或托盘状态运行；不调用按钮、不改变窗口状态。
foreground := WinActive("A")
hidden := DetectHiddenWindows(true)
try {
    retry := CodexRetry(ToolboxSettings.Load())
    for candidate in WinGetList(retry.settings["RetryTarget"]) {
        if WinGetClass(candidate) = "Chrome_WidgetWin_1" {
            WinGetPos(, , &width, &height, candidate)
            FileAppend("candidate=" candidate " title=" WinGetTitle(candidate) " visible="
            DllCall("IsWindowVisible", "Ptr", candidate) " size=" width "x" height "`n", "*")
        }
    }
    if !hwnd := retry.FindWindow()
        throw Error("Target main window not found")
    root := retry.ReadRoot(hwnd)
    buttons := root.FindElements({ Type: "Button", ClassName: retry.settings["RetryClass"], mm: 2 })
    FileAppend("visible=" DllCall("IsWindowVisible", "Ptr", hwnd) " minimized=" (WinGetMinMax(hwnd) = -1)
    " composer-buttons=" buttons.Length "`n", "*")
    for button in buttons
        FileAppend("button=" button.Name " enabled=" button.IsEnabled " offscreen=" button.IsOffscreen
            " invoke=" button.IsInvokePatternAvailable "`n", "*")
    FileAppend("foreground-unchanged=" (foreground = WinActive("A")) " (read-only; no invocation)`n", "*")
} catch as err {
    FileAppend("Unavailable: " err.Message " (read-only; no invocation)`n", "*")
} finally {
    DetectHiddenWindows(hidden)
}
ExitApp()
