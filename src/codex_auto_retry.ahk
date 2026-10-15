#Requires AutoHotkey v2.0 64-bit
#SingleInstance Ignore
#Include %A_LineFile%\..\toolbox_settings.ahk
#Include %A_LineFile%\..\..\Lib\UIA.ahk

; UIA 只在重试进程首次实际检查时加载，不改变全局屏幕阅读器设置。
global IUIAutomationActivateScreenReader := 0

if A_LineFile = A_ScriptFullPath
    StartCodexRetry()

StartCodexRetry() {
    global RetryWorker, RetryParentHandle := 0, RetryParentWindow := 0, RetrySettingsPath := ToolboxSettings.Path
    if A_IsAdmin {
        OutputDebug("自动重试不接受管理员权限，请通过工具箱或普通权限启动")
        ExitApp(1)
    }
    managed := A_Args.Length >= 3 && A_Args[1] = "--managed"
    if managed {
        if A_Args.Length >= 4
            RetrySettingsPath := A_Args[4]
        RetryParentWindow := Integer(A_Args[3])
        RetryParentHandle := DllCall("OpenProcess", "UInt", 0x100000, "Int", false, "UInt", Integer(A_Args[2]), "Ptr")
        if !RetryParentHandle
            ExitApp()
        A_IconHidden := true
        ; OnExit 返回非零会取消退出，不能直接返回 CloseHandle 的成功值。
        OnExit((*) => (DllCall("CloseHandle", "Ptr", RetryParentHandle), 0))
    }
    try RetryWorker := CodexRetry(ToolboxSettings.Load(RetrySettingsPath))
    catch as err {
        OutputDebug("自动重试配置：" err.Message)
        ExitApp(1)
    }
    OnMessage(0x8052, RetryControl)
    DllCall("SetPropW", "Ptr", A_ScriptHwnd, "Str", "AHK.CodexRetry.Parent", "Ptr", RetryParentWindow)
    if !managed {
        A_IconTip := "Codex 自动重试"
        A_TrayMenu.Delete()
        A_TrayMenu.Add("暂停 / 继续检查", (*) => ToggleRetryTimer())
        A_TrayMenu.Add("退出", (*) => ExitApp())
    }
    SetTimer(RetryWorkerTick, RetryWorker.settings["RetryInterval"] * 1000)
    Persistent()
}

RetryWorkerTick() {
    global RetryParentHandle, RetryWorker
    if RetryParentHandle && DllCall("WaitForSingleObject", "Ptr", RetryParentHandle, "UInt", 0) != 0x102
        ExitApp()
    RetryWorker.Tick()
}

RetryControl(command, parent, *) {
    global RetryParentWindow, RetryWorker, RetrySettingsPath
    Critical() ; 合并到达的设置/停止消息须排队，不能在前一回调执行时丢失停止命令。
    if !RetryParentWindow || parent != RetryParentWindow
        return
    if command = 0
        ExitApp()
    if command = 1 {
        try {
            previousInterval := RetryWorker.settings["RetryInterval"]
            RetryWorker.settings := ToolboxSettings.Load(RetrySettingsPath)
            if RetryWorker.settings["RetryInterval"] != previousInterval
                SetTimer(RetryWorkerTick, RetryWorker.settings["RetryInterval"] * 1000)
        }
    }
}

ToggleRetryTimer() {
    global RetryWorker
    static paused := false
    paused := !paused
    SetTimer(RetryWorkerTick, paused ? 0 : RetryWorker.settings["RetryInterval"] * 1000)
    A_IconTip := "Codex 自动重试（" (paused ? "已暂停" : "运行中") "）"
    A_TrayMenu.ToggleCheck("暂停 / 继续检查")
}

class CodexRetry {
    __New(settings) {
        this.settings := settings
        this.busy := false
        this.lastButton := ""
        this.lastWindow := 0
        this.lastStatus := "等待首次检查"
    }

    Tick() {
        if this.busy
            return
        this.busy := true
        hiddenWindows := DetectHiddenWindows(true)
        try {
            hwnd := this.FindWindow()
            if !hwnd {
                this.lastStatus := "未找到可读取的目标主窗口"
                return
            }
            backgroundHidden := WinGetMinMax(hwnd) = -1 || !DllCall("IsWindowVisible", "Ptr", hwnd)
            this.TryContinue(this.ReadRoot(hwnd), hwnd, backgroundHidden)
        } catch as err {
            ; 窗口关闭、元素消失、UIA 超时是常见状态，不能弹出异常打断使用。
            this.lastStatus := "本次跳过：" err.Message
        } finally {
            DetectHiddenWindows(hiddenWindows)
            this.busy := false
        }
    }

    FindWindow() {
        ; 可见/最小化窗口优先，避免误选同进程里的隐藏旧窗口。
        candidates := []
        for hwnd in WinGetList(this.settings["RetryTarget"]) {
            if WinGetClass(hwnd) != "Chrome_WidgetWin_1" || WinGetTitle(hwnd) = ""
                continue
            if DllCall("IsWindowVisible", "Ptr", hwnd)
                return this.lastWindow := hwnd
            candidates.Push(hwnd)
        }
        for hwnd in candidates {
            if hwnd = this.lastWindow
                return hwnd ; 缩到托盘后仍跟踪同一主窗口。
        }
        ; 脚本首次启动时窗口可能已经在托盘，只认仍提供输入框按钮的窗口。
        found := 0
        for hwnd in candidates {
            try {
                if this.ReadRoot(hwnd).FindElements({Type: "Button", ClassName: this.settings["RetryClass"], mm: 2}).Length {
                    if found
                        return 0 ; 多个隐藏窗口都像主窗口时，不猜测当前聊天。
                    found := hwnd
                }
            }
        }
        return this.lastWindow := found
    }

    ReadRoot(hwnd) {
        static configured := false
        ; 不激活、不还原窗口，不向 Chromium 强制发送辅助功能激活消息。
        if !configured {
            UIA.AutoSetFocus := false
            UIA.ConnectionTimeout := 500
            UIA.TransactionTimeout := 500
            configured := true
        }
        try return UIA.ElementFromChromium(hwnd, 0)
        catch
            return UIA.ElementFromHandle(hwnd, , false)
    }

    TryContinue(root, hwnd, backgroundHidden := false) {
        buttons := root.FindElements({Type: "Button", ClassName: this.settings["RetryClass"], mm: 2})
        if buttons.Length != 1 {
            this.lastButton := ""
            this.lastStatus := "没有唯一的继续按钮，跳过"
            return false
        }
        button := buttons[1]
        ; 隐藏整个窗口时 IsOffscreen 自然为真，不能因此拒绝可用的后台按钮。
        if !this.IsContinueButton(button.Name) || !button.IsEnabled || (button.IsOffscreen && !backgroundHidden)
            return false
        identity := hwnd ":" button.RuntimeId
        if identity = this.lastButton || !button.IsInvokePatternAvailable
            return false
        ; 查询期间按钮可能已变成“停止”；调用前再核对一次，缩小状态变化的误触窗口。
        if !this.IsContinueButton(button.Name) || !button.IsEnabled
            return false
        ; 失败后也不反复触发同一按钮；观察到按钮消失或身份变化后才重新允许。
        this.lastButton := identity
        button.Invoke()
        this.lastStatus := "已调用继续按钮"
        return true
    }

    IsContinueButton(name) {
        trimmed := Trim(name)
        if trimmed = "停止" || trimmed = "Stop" || trimmed = ""
            return false
        if trimmed = this.settings["RetryName"]
            return true
        for target in ["继续", "继续生成", "Resume", "Continue", "Retry"] {
            if StrCompare(trimmed, target, false) = 0
                return true
        }
        return false
    }
}
