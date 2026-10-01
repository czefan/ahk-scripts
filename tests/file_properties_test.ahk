#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Include %A_ScriptDir%\..\src\dialog_rescaler.ahk
DirCreate(A_ScriptDir "\output")

; 在独立测试桌面调用系统属性页；仅切换页签，最终取消，不保存属性。
if A_Args.Length && A_Args[1] = "target" {
    page := A_Args.Length > 2 ? A_Args[3] : ""
    DllCall("shell32\SHObjectProperties", "Ptr", 0, "UInt", 2, "Str", A_Args[2], "Ptr", page = "" ? 0 : StrPtr(page),
    "Int")
    if hwnd := WinWait("ahk_class #32770 ahk_pid " DllCall("GetCurrentProcessId"), , 5)
        WinWaitClose(hwnd)
    ExitApp()
}
if A_Args.Length != 2 || A_Args[1] != "isolated"
    ExitApp(2)

global Report := A_Args[2]
global HistoricalRules := []
for feature in ["#32770{13057,13156/102}", "CHECKLIST_ACLUI", "*{101,103} > NativeFontCtl", "*{271} > SysLink@272"]
    HistoricalRules.Push(WindowExclusionRule({ Name: "baseline", Window: "ahk_class #32770", Scope: "all", Features: ":root{12320}`n" feature }))
global Unique := [0, 0, 0, 0], Samples := 0
directory := (A_ScriptDir "\output") "\AHKProperties_" DllCall("GetCurrentProcessId")
DirCreate(directory)
try {
    FileAppend("Temporary file for property-page inspection.`r`n", directory "\sample.txt", "UTF-8")
    DirCreate(directory "\folder")
    FileCreateShortcut(A_AhkPath, directory "\sample.lnk")
    image := Buffer(58, 0)
    NumPut("UShort", 0x4D42, "UInt", 58, image)
    NumPut("UInt", 54, "UInt", 40, "Int", 1, "Int", 1, "UShort", 1, "UShort", 24, image, 10)
    bitmap := FileOpen(directory "\sample.bmp", "w")
    bitmap.RawWrite(image), bitmap.Close()
    signedExe := A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"
    for fixture in [["text", directory "\sample.txt"], ["folder", directory "\folder"],
    ["shortcut", directory "\sample.lnk"], ["bitmap", directory "\sample.bmp"], ["signed-exe", signedExe]]
        InspectProperties(fixture[1], fixture[2])
    ; 请求直接进入非“常规”页，检查常规页尚未创建时是否仍能识别。
    for page in ["Security", "安全", "Details", "详细信息", "Digital Signatures", "数字签名"]
        InspectProperties("direct-" page, signedExe, page, false)
    InspectProperties("direct-shortcut", directory "\sample.lnk", "快捷方式", false)
    for index, hits in Unique
        Assert(hits > 0, "No exclusive coverage for branch " index)
    Log("UNIQUE general=" Unique[1] " security=" Unique[2] " signature=" Unique[3] " details=" Unique[4] " samples=" Samples
    )
    Log("PASS: property pages inspected and cancelled; no attributes saved")
} catch as err {
    Log("FAIL: " err.Message "`n" err.Stack)
    ExitApp(1)
} finally {
    ; 只删除本测试在专用目录创建的文件，不递归处理任何其他路径。
    for name in ["sample.txt", "sample.lnk", "sample.bmp"] {
        if FileExist(directory "\" name)
            FileDelete(directory "\" name)
    }
    if DirExist(directory "\folder")
        DirDelete(directory "\folder")
    DirDelete(directory)
}
ExitApp()

InspectProperties(label, path, page := "", visitAll := true) {
    pid := hwnd := 0
    try {
        Run('"' A_AhkPath '" /ErrorStdOut "' A_ScriptFullPath '" target "' path '" "' page '"', , , &pid)
        hwnd := WinWait("ahk_class #32770 ahk_pid " pid, , 8)
        Assert(hwnd, "No properties window: " label)
        Sleep(200)
        tab := DllCall("GetDlgItem", "Ptr", hwnd, "Int", 12320, "Ptr")
        Assert(tab, "No property-page tabs: " label)
        count := SendMessage(0x1304, 0, 0, tab)
        index := SendMessage(0x130B, 0, 0, tab)
        Probe(hwnd, label " initial=" index "/" count)
        if visitAll {
            loop count {
                SendMessage(0x465, A_Index - 1, 0, hwnd) ; PSM_SETCURSEL，仅换页。
                Sleep(100)
                Probe(hwnd, label " page=" (A_Index - 1))
            }
        }
    } finally {
        if hwnd && DllCall("IsWindow", "Ptr", hwnd) {
            ; IDCANCEL，防止有 Apply 页面时提交任何改动。
            PostMessage(0x111, 2, 0, , hwnd)
        }
        if pid {
            ProcessWaitClose(pid, 2)
            if ProcessExist(pid)
                ProcessClose(pid)
        }
    }
}

Probe(hwnd, label) {
    global Samples
    bits := "", matches := 0, only := 0
    for index, rule in HistoricalRules {
        found := !!rule.Call(hwnd)
        bits .= found
        if found
            matches++, only := index
    }
    if matches = 1
        Unique[only]++
    Samples++
    Assert(WindowExclusionRule(DefaultExclusionRules()[1]).Call(hwnd) = (matches > 0),
    "Merged rule differs from historical predicates: " label)
    Log(label " matches(general/security/signature/details)=" bits)
    Assert(matches, "No historical predicate matched: " label)
}
Assert(value, message) {
    if !value
        throw Error(message)
}
Log(message) => FileAppend(message "`r`n", Report, "UTF-8")

