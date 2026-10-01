#Requires AutoHotkey v2.0 64-bit
#SingleInstance Force
#Include %A_LineFile%\..\src\toolbox.ahk

if A_LineFile = A_ScriptFullPath {
    ; 主进程用管理员权限处理系统窗口，自动重试独立以普通权限运行。
    if !A_IsAdmin {
        try {
            Run('*RunAs "' A_ProgramFiles '\AutoHotkey\v2\AutoHotkey64.exe" "' A_ScriptFullPath '"', A_ScriptDir)
            ExitApp()
        }
    }
    try {
        global Manager := Toolbox(ToolboxSettings.Load())
        Manager.Start()
    } catch as err {
        MsgBox(err.Message, "AHK 工具箱启动失败", "Icon!")
        ExitApp(1)
    }
}
