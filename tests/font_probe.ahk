#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Include %A_ScriptDir%\..\src\win32_fonts.ahk

OnError(ProbeError)

if A_Args.Length && A_Args[1] = "target" {
    probeGui := Gui()
    probeGui.SetFont("s9", "Segoe UI")
    probeText := probeGui.AddText("w240 h40", "Font probe 字体测试")
    probeGui.Show("Hide w280 h100")
    OnMessage(0x8001, (*) => FontHeight(probeText.Hwnd))
    OnMessage(0x8002, (*) => SelectedFontHeight(probeText.Hwnd))
    OnMessage(0x8003, (*) => SetTimer(() => ExitApp(), -10))
    FileAppend(probeGui.Hwnd "`n" probeText.Hwnd, A_Args[2], "UTF-8")
    Persistent()
} else {
    probeReady := A_ScriptDir "\font_probe_" DllCall("GetCurrentProcessId") ".txt"
    probePid := 0
    probeFont := 0
    probeFailure := 0
    try {
        SplitPath(A_AhkPath, , &runtimeDirectory)
        targetRuntime := A_Args.Length && A_Args[1] = "x86" ? runtimeDirectory "\AutoHotkey32.exe" : A_AhkPath
        Run('"' targetRuntime '" /ErrorStdOut "' A_ScriptFullPath '" target "' probeReady '"', , "Hide", &probePid)
        loop 100 {
            if FileExist(probeReady)
                break
            Sleep(50)
        }
        handles := StrSplit(FileRead(probeReady, "UTF-8"), "`n")
        targetGui := Integer(handles[1])
        targetText := Integer(handles[2])
        FileAppend("before: remote=" ProbeSend(targetGui, 0x8001) " parent=" FontHeight(targetText) " selected=" ProbeSend(
            targetGui, 0x8002) "`n", "*")
        probeFont := DllCall("CreateFontW", "Int", -32, "Int", 0, "Int", 0, "Int", 0, "Int", 400,
            "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 1, "UInt", 0, "UInt", 0, "UInt", 5, "UInt", 0, "Str",
            "Microsoft YaHei UI", "Ptr")
        ProbeSend(targetText, 0x30, probeFont, 1)
        FileAppend("after: remote=" ProbeSend(targetGui, 0x8001) " parent=" FontHeight(targetText) " selected=" ProbeSend(
            targetGui, 0x8002) "`n", "*")
        fontProcess := Win32FontProcess(probePid)
        FileAppend("opened target process`n", "*")
        logicalFont := Buffer(92, 0)
        DllCall("GetObjectW", "Ptr", probeFont, "Int", 92, "Ptr", logicalFont)
        remoteFont := fontProcess.GetFont(logicalFont)
        FileAppend("created target font: " remoteFont "`n", "*")
        ProbeSend(targetText, 0x30, remoteFont, 1)
        selectedHeight := ProbeSend(targetGui, 0x8002)
        FileAppend("fixed: remote=" ProbeSend(targetGui, 0x8001) " parent=" FontHeight(targetText) " selected=" selectedHeight "`n",
        "*")
        if selectedHeight != 32
            throw Error("Target could not select the new font")
        if fontProcess.GetFont(logicalFont) != remoteFont
            throw Error("Font cache did not reuse the font")
        ; 字体名结束后的填充不影响字体；旋转参数不同则必须创建另一支字体。
        NumPut("UInt", 0xFFFFFFFF, logicalFont, 88)
        if fontProcess.GetFont(logicalFont) != remoteFont
            throw Error("Unused font-name padding bypassed the cache")
        NumPut("Int", 900, logicalFont, 8)
        rotatedFont := fontProcess.GetFont(logicalFont)
        actualFont := Buffer(92, 0)
        if rotatedFont = remoteFont || DllCall("GetObjectW", "Ptr", rotatedFont, "Int", 92, "Ptr", actualFont) != 92
        || NumGet(actualFont, 8, "Int") != 900
            throw Error("Different font parameters were lost in the cache")
        fontProcess.Close()
        ProbeSend(targetGui, 0x8003)
        ProcessWaitClose(probePid, 3)
    } catch as err {
        probeFailure := err
    } finally {
        if probePid && ProcessExist(probePid)
            ProcessClose(probePid)
        if probeFont
            DllCall("DeleteObject", "Ptr", probeFont)
        if FileExist(probeReady)
            FileDelete(probeReady)
    }
    if probeFailure
        ProbeError(probeFailure)
    ExitApp()
}

ProbeError(err, *) {
    FileAppend("ERROR: " err.Message "`n" err.Stack "`n", "*")
    ExitApp(1)
}

ProbeSend(hwnd, message, wParam := 0, lParam := 0) {
    result := 0
    if !DllCall("SendMessageTimeoutW", "Ptr", hwnd, "UInt", message, "Ptr", wParam, "Ptr", lParam,
        "UInt", 0x22, "UInt", 1000, "Ptr*", &result, "Ptr")
        throw Error("Message failed: " message)
    return result
}

FontHeight(hwnd) {
    font := ProbeSend(hwnd, 0x31)
    logicalFont := Buffer(92, 0)
    if !DllCall("GetObjectW", "Ptr", font, "Int", 92, "Ptr", logicalFont)
        return -1
    return Abs(NumGet(logicalFont, 0, "Int"))
}

SelectedFontHeight(hwnd) {
    font := ProbeSend(hwnd, 0x31)
    dc := DllCall("GetDC", "Ptr", hwnd, "Ptr")
    oldFont := DllCall("SelectObject", "Ptr", dc, "Ptr", font, "Ptr")
    if !oldFont {
        DllCall("ReleaseDC", "Ptr", hwnd, "Ptr", dc)
        return -1
    }
    metrics := Buffer(60, 0)
    DllCall("GetTextMetricsW", "Ptr", dc, "Ptr", metrics)
    height := NumGet(metrics, 0, "Int") - NumGet(metrics, 12, "Int")
    DllCall("SelectObject", "Ptr", dc, "Ptr", oldFont)
    DllCall("ReleaseDC", "Ptr", hwnd, "Ptr", dc)
    return height
}

