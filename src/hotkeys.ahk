#Requires AutoHotkey v2.0 64-bit
#SingleInstance Force
#Include %A_LineFile%\..\toolbox_settings.ahk
#Include %A_LineFile%\..\process_launch.ahk

if A_LineFile = A_ScriptFullPath
    ConfigureAppHotkeys(ToolboxSettings.Load())

ConfigureAppHotkeys(settings) {
    static bindings := []
    SetWinDelay(0)
    A_MenuMaskKey := "vkE8"
    for key in bindings
        Hotkey(key, "Off")
    bindings := []
    if !settings["HotkeysEnabled"]
        return
    for app in AppHotkeyEntries(settings) {
        if app.Key {
            Hotkey(app.Key, ToggleApp.Bind(app.Target, app.Program, app.Options), "On")
            bindings.Push(app.Key)
        }
    }
}

; 运行和列表界面共用同一份绑定定义；数字 Id 对应自定义条目。
AppHotkeyEntries(settings) {
    entries := [
        {Id: "TerminalKey", Name: "Windows Terminal", Key: settings["TerminalKey"], Target: "ahk_exe WindowsTerminal.exe", Program: "wt.exe", Options: ""},
        {Id: "EverythingKey", Name: "Everything", Key: settings["EverythingKey"], Target: "ahk_exe Everything.exe", Program: settings["EverythingPath"], Options: "close"},
        {Id: "TaskManagerKey", Name: "任务管理器", Key: settings["TaskManagerKey"], Target: "ahk_exe Taskmgr.exe", Program: A_WinDir "\System32\Taskmgr.exe", Options: "admin"}
    ]
    for index, entry in settings["CustomHotkeys"] {
        SplitPath(entry.Program, &exe)
        entries.Push({Id: index, Name: entry.Name, Key: entry.Key, Target: "ahk_exe " exe, Program: entry.Program, Options: ""})
    }
    return entries
}

; 窗口操作固定到同一个 HWND；程序关闭、启动失败均不弹出阻塞式异常框。
ToggleApp(winTitle, launchCmd, options := "", *) {
    try {
        hwnd := WinExist(winTitle)
        if hwnd && WinActive(hwnd) {
            if options = true || InStr(options, "close")
                WinClose(hwnd)
            else
                WinMinimize(hwnd)
            return
        }
        if !hwnd {
            if InStr(options, "admin")
                Run((A_IsAdmin ? "" : "*RunAs ") '"' launchCmd '"')
            else
                ShellRun(launchCmd)
            if !hwnd := WinWait(winTitle, , 3)
                return
        }
        WinActivate(hwnd)
    } catch as err {
        ToolTip("快捷键未能执行：" err.Message)
        SetTimer(() => ToolTip(), -3500)
    }
}

; 经桌面 Explorer 启动，避免继承工具箱的管理员令牌。
; Explorer 重启后重新连接一次；仍失败就交给调用者提示，不退回提权启动。
ShellRun(filePath, arguments := "", directory := "") {
    static shellDispatch := 0
    loop 2 {
        try {
            if !shellDispatch
                shellDispatch := ComObject("Shell.Application").Windows.Item(ComValue(0x13, 8)).Document.Application
            shellDispatch.ShellExecute(filePath, arguments, directory)
            return
        } catch as err {
            shellDispatch := 0
            if A_Index = 2
                throw err
        }
    }
}
