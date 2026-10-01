#Requires AutoHotkey v2.0 64-bit

; 点火后立即脱钩退出，由 main.ahk 独立管理生命周期与托盘
Run('"' A_AhkPath '" "' A_ScriptDir '\main.ahk"', A_ScriptDir)
ExitApp()
