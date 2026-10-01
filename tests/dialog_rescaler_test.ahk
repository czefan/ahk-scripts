#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Include %A_ScriptDir%\..\src\dialog_rescaler.ahk

; 本文件专门回归可选的旧式实现；日常配置仍关闭此回退。
RescaleLegacyEnabled := true
RescaleNativePercent := 0

OnError(TestError)
global TestLogPath := A_Args.Length >= 2 && SubStr(A_Args[1], 1, 7) = "system_" ? A_Args[2] : ""
DirCreate(A_ScriptDir "\output")
if A_Args.Length && A_Args[1] = "file_target" {
    Run('properties "' A_Args[2] '"')
    Persistent()
} else if A_Args.Length && A_Args[1] = "picker_target" {
    if A_Args[2] = "folder"
        DirSelect(A_ScriptDir, 3, "Font rescaler picker test")
    else if A_Args[2] = "legacy" {
        fileName := Buffer(520, 0)
        dialog := Buffer(A_PtrSize = 8 ? 152 : 88, 0)
        NumPut("UInt", dialog.Size, dialog)
        NumPut("Ptr", fileName.Ptr, dialog, A_PtrSize = 8 ? 48 : 28)
        NumPut("UInt", 260, dialog, A_PtrSize = 8 ? 56 : 32)
        NumPut("UInt", 0x1008, dialog, A_PtrSize = 8 ? 96 : 52) ; 不使用 OFN_EXPLORER。
        DllCall("comdlg32\GetOpenFileNameW", "Ptr", dialog)
    }
    else
        FileSelect(A_Args[2] = "save" ? "S16" : "3", A_ScriptDir, "Font rescaler picker test", "Text files (*.txt)")
    ExitApp()
} else if A_Args.Length && A_Args[1] = "dialog_target" {
    if A_Args[2] = "directui" {
        button := 0
        result := DllCall("comctl32\TaskDialog", "Ptr", 0, "Ptr", 0,
            "Str", "DirectUI guard regression", "Str", "原生确认框布局测试",
            "Str", "测试内容，不会粘贴或执行任何终端命令。", "UInt", 9, "Ptr", 0xFFFF, "Int*", &button, "Int")
        AssertTest(result = 0, "TaskDialog failed: " result)
    } else if A_Args[2] = "input"
        InputBox("Standard input 输入框字体测试", "Application Properties", "w400 h160")
    else
        MsgBox("Standard dialog 标准对话框字体测试", "Application Properties")
    ExitApp()
} else if A_Args.Length && A_Args[1] = "target" {
    BuildTestWindow()
    Persistent()
} else {
    try {
        if A_Args.Length && A_Args[1] = "system_directui" {
            RunDirectUITest()
        } else if A_Args.Length && A_Args[1] = "system_blacklist" {
            RunBlacklistTest()
        } else if A_Args.Length && A_Args[1] = "system_scope" {
            RunScopeTest()
        } else if A_Args.Length && A_Args[1] = "system_file_skip" {
            RunFileSkipTest()
        } else if A_Args.Length && A_Args[1] = "system_first_pages" {
            RunFirstPageTest()
        } else if A_Args.Length && A_Args[1] = "system_all" {
            for mode in ["system_properties", "system_devices_large"]
                RunSystemWindowTest(mode)
        } else if A_Args.Length && SubStr(A_Args[1], 1, 7) = "system_" {
            RunSystemWindowTest(A_Args[1])
        } else {
            RunLayoutTest()
        }
    } catch as err {
        TestError(err)
    }
    ExitApp()
}

RunDirectUITest() {
    global RescaleBlacklist, RescaleEvents
    savedRules := RescaleBlacklist
    restart := false
    pid := hwnd := 0
    try {
        restart := StopMainForTest()
        RescaleBlacklist := CompileExclusionRules(DefaultExclusionRules())
        CheckDirectUISubtree()
        Run('"' A_AhkPath '" "' A_ScriptFullPath '" dialog_target directui', , , &pid)
        RescaleEvents := RescaleWindowEvents(pid)
        hwnd := WinWait("ahk_class #32770 ahk_pid " pid, , 8)
        AssertTest(hwnd, "TaskDialog did not open")
        Sleep(150)
        AssertTest(HasRescaleDirectUI(hwnd), "The native TaskDialog has no DirectUIHWND")
        before := CaptureRescaleTree(hwnd)
        WaitForPage(() => !RescaleEvents.jobs.Count)
        AssertTest(!IsAutomaticRescaleWindow(hwnd) && !SafeRescaleWindow(hwnd),
        "DirectUI bypassed the initial exclusion rule")
        WinActivate(hwnd)
        AssertTest(WinWaitActive(hwnd, , 2), "Could not activate the test TaskDialog")
        RescaleActiveWindow() ; 检查 Win + F11 入口，不发送按键或点击确认按钮。
        ToolTip()
        for record in before {
            rect := GetRescaleRect(record.hwnd, record.parent)
            AssertTest(rect.x = record.rect.x && rect.y = record.rect.y
                && rect.w = record.rect.w && rect.h = record.rect.h, "TaskDialog geometry was changed: " record.cls)
            if record.acceptsFont
                AssertTest(RescaleSend(record.hwnd, 0x31) = record.oldFont, "TaskDialog font was changed")
        }
        AssertTest(!ScaledHwnds.Count && !RescaleProcesses.Count, "DirectUI allocated scaling state or remote fonts")
        CaptureTestBitmap(hwnd, A_ScriptDir "\output\directui_task_dialog.bmp", true)
        TestLog(
            "PASS DirectUI: native TaskDialog unchanged with empty blacklist; automatic/manual guard; deep/hidden/exact-class checks`n"
        )
    } finally {
        ToolTip()
        CleanupDialogRescaler()
        if hwnd && DllCall("IsWindow", "Ptr", hwnd)
            WinClose(hwnd) ; 仅关闭本测试创建的确认框，按取消处理。
        if pid && ProcessExist(pid) {
            ProcessWaitClose(pid, 2)
            if ProcessExist(pid)
                ProcessClose(pid)
        }
        RescaleBlacklist := savedRules
        if restart
            ReloadMainForTest()
    }
}

CheckDirectUISubtree() {
    ; 注册同名空测试控件，只检验类名/层级匹配；真实渲染另由 TaskDialog 验证。
    host := Gui("-DPIScale", "DirectUIHWND is only a title")
    host.AddText(, "DirectUIHWND")
    host.Show("Hide w240 h80")
    panel := Gui("-Caption +Parent" host.Hwnd)
    instance := DllCall("GetModuleHandleW", "Ptr", 0, "Ptr")
    proc := DllCall("GetProcAddress", "Ptr", DllCall("GetModuleHandleW", "Str", "user32.dll", "Ptr"),
    "AStr", "DefWindowProcW", "Ptr")
    registered := []
    try {
        AssertTest(!HasRescaleDirectUI(host.Hwnd), "Title or text was mistaken for a window class")
        for className in ["DirectUIHWND_Test", "DirectUIHWND"] {
            wc := Buffer(A_PtrSize = 8 ? 80 : 48, 0)
            NumPut("UInt", wc.Size, wc)
            NumPut("Ptr", proc, wc, 8)
            NumPut("Ptr", instance, wc, A_PtrSize = 8 ? 24 : 20)
            NumPut("Ptr", StrPtr(className), wc, A_PtrSize = 8 ? 64 : 40)
            AssertTest(DllCall("RegisterClassExW", "Ptr", wc, "UShort"), "Could not register test class")
            registered.Push(className)
            child := DllCall("CreateWindowExW", "UInt", 0, "Str", className, "Str", "", "UInt", 0x40000000,
                "Int", 0, "Int", 0, "Int", 10, "Int", 10, "Ptr", panel.Hwnd,
                "Ptr", 0, "Ptr", instance, "Ptr", 0, "Ptr")
            AssertTest(child, "Could not create test control")
            if className = "DirectUIHWND_Test"
                AssertTest(!HasRescaleDirectUI(host.Hwnd), "A similar class name was excluded")
            else {
                AssertTest(!DllCall("IsWindowVisible", "Ptr", child) && HasRescaleDirectUI(panel.Hwnd)
                && HasRescaleDirectUI(host.Hwnd), "Deep or hidden DirectUI was missed")
                AssertTest(!SafeRescaleWindow(host.Hwnd, AcceptLayoutTestWindow),
                "A custom candidate bypassed the DirectUI guard")
            }
        }
    } finally {
        panel.Destroy()
        host.Destroy()
        for className in registered
            DllCall("UnregisterClassW", "Str", className, "Ptr", instance)
    }
}

RunBlacklistTest() {
    global RescaleBlacklist, RescaleEvents
    originalRules := RescaleBlacklist
    originalMode := A_TitleMatchMode
    originalHidden := A_DetectHiddenWindows
    pid := hwnd := decoy := 0
    restart := StopMainForTest()
    try {
        Run('"' A_AhkPath '" "' A_ScriptFullPath '" dialog_target message', , , &pid)
        hwnd := WinWait("ahk_class #32770 ahk_pid " pid, , 8)
        AssertTest(hwnd, "Blacklist test dialog did not open")
        original := GetRescaleRect(hwnd)
        fonts := Map()
        for child in WinGetControlsHwnd(hwnd) {
            if IsRescaleFontControl(WinGetClass(child), WinGetStyle(child))
                fonts[child] := RescaleSend(child, 0x31)
        }
        exe := WinGetProcessName(hwnd)
        rule := "Properties ahk_exe " exe " ahk_class #32770"
        SetTitleMatchMode(3)
        DetectHiddenWindows(false)
        for test in [{ rule: rule, matches: true }, { rule: "ahk_exe " StrLower(exe), matches: true }, { rule: "ahk_class #32770",
            matches: true }, { rule: "Missing title ahk_exe " exe, matches: false }, { rule: "Properties ahk_exe nonexistent_blacklist_test.exe",
                matches: false }, { rule: "Properties ahk_class AutoHotkeyGUI", matches: false }, { rule: "   ",
                    matches: false }
        ] {
            RescaleBlacklist := ["", test.rule]
            AssertTest(IsRescaleExcludedWindow(hwnd) = test.matches, "Wrong blacklist match: " test.rule)
            AssertTest(A_TitleMatchMode = 3 && !A_DetectHiddenWindows,
                "Blacklist changed the caller's matching settings")
        }
        decoy := Gui(, "Unrelated blacklist test window")
        RescaleBlacklist := ["ahk_exe " exe]
        AssertTest(IsRescaleExcludedWindow(decoy.Hwnd), "A hidden window bypassed the blacklist")
        RescaleBlacklist := [rule]
        AssertTest(!IsRescaleExcludedWindow(decoy.Hwnd), "A different matching window caused a false positive")
        RescaleBlacklist := originalRules.Clone()
        RescaleBlacklist.Push(rule)

        RescaleEvents := RescaleWindowEvents(pid)
        WaitForPage(() => !RescaleEvents.jobs.Count)
        AssertTest(!IsAutomaticRescaleWindow(hwnd) && !SafeRescaleWindow(hwnd), "Blacklist was bypassed")
        WinActivate(hwnd)
        AssertTest(WinWaitActive(hwnd, , 2), "Could not activate the blacklist test dialog")
        RescaleActiveWindow() ; 与 Win + F11 使用同一入口。
        ToolTip()
        after := GetRescaleRect(hwnd)
        AssertTest(!HasRescaleMarker(hwnd) && original.w = after.w && original.h = after.h,
        "A blacklisted dialog was resized")
        for child, font in fonts
            AssertTest(RescaleSend(child, 0x31) = font, "A blacklisted control's font was changed")
        AssertTest(!RescaleProcesses.Count, "A blacklisted dialog allocated remote font resources")
        RescaleBlacklist := originalRules.Clone()
        RescaleActiveWindow()
        ToolTip()
        AssertTest(HasRescaleMarker(hwnd) && GetRescaleRect(hwnd).w > original.w,
        "Removing the rule did not restore manual scaling")
        TestLog(
            "PASS blacklist: combined/blank/hidden rules, settings restored, automatic/manual blocking and re-enable`n"
        )
    } finally {
        ToolTip()
        CleanupDialogRescaler()
        if IsObject(decoy)
            decoy.Destroy()
        if hwnd && DllCall("IsWindow", "Ptr", hwnd)
            WinClose(hwnd)
        if pid && ProcessExist(pid) {
            ProcessWaitClose(pid, 2)
            if ProcessExist(pid)
                ProcessClose(pid)
        }
        RescaleBlacklist := originalRules
        SetTitleMatchMode(originalMode)
        DetectHiddenWindows(originalHidden)
        if restart
            ReloadMainForTest()
    }
}

RunScopeTest() {
    mainPid := ReloadMainForTest()
    for mode in ["message", "input", "open", "save", "folder", "legacy"] {
        pid := hwnd := 0
        try {
            ordinary := mode = "message" || mode = "input"
            target := ordinary ? "dialog_target" : "picker_target"
            Run('"' A_AhkPath '" "' A_ScriptFullPath '" ' target ' ' mode, , , &pid)
            hwnd := WinWait("ahk_class #32770 ahk_pid " pid, , 8)
            AssertTest(hwnd, "Standard dialog did not open: " mode)
            AssertTest(!!IsAutomaticRescaleWindow(hwnd) = (ordinary || !HasRescaleDirectUI(hwnd)),
            "Wrong automatic scope: " mode)
            if ordinary {
                WaitForPage(() => DllCall("GetPropW", "Ptr", hwnd, "Str", RescaleProperty, "Ptr") = mainPid)
                CheckFirstPageText(hwnd)
                count := 0
                for child in WinGetControlsHwnd(hwnd) {
                    if !IsRescaleFontControl(WinGetClass(child), WinGetStyle(child))
                        continue
                    font := ReadRescaleLogFont(RescaleSend(child, 0x31))
                    dpi := DllCall("GetDpiForWindow", "Ptr", child, "UInt")
                    AssertTest(font && StrGet(font.Ptr + 28, 32, "UTF-16") = RescaleFontName
                    && NumGet(font, 0, "Int") = -Round(RescaleFontSize * dpi / 72),
                    "Ordinary dialog font was not enlarged")
                    count += 1
                }
                AssertTest(count, "No standard font controls were checked")
            } else if HasRescaleDirectUI(hwnd) {
                AssertTest(!SafeRescaleWindow(hwnd), "File picker bypassed the shared entry point")
                before := GetRescaleRect(hwnd)
                Sleep(250)
                after := GetRescaleRect(hwnd)
                AssertTest(!DllCall("GetPropW", "Ptr", hwnd, "Str", RescaleProperty, "Ptr")
                && before.w = after.w && before.h = after.h, "File picker was modified: " mode)
            }
            TestLog("PASS scope " mode ": " (ordinary ? "automatically enlarged" : "unchanged") "`n")
        } finally {
            if hwnd && DllCall("IsWindow", "Ptr", hwnd)
                WinClose(hwnd)
            if pid && ProcessExist(pid) {
                ProcessWaitClose(pid, 2)
                if ProcessExist(pid)
                    ProcessClose(pid)
            }
        }
    }
}

ReloadMainForTest() {
    SplitPath(A_ScriptDir, , &workspace)
    Run('"' A_AhkPath '" "' workspace '\main.ahk"', , "Hide", &mainPid)
    DetectHiddenWindows(true)
    WaitForPage(() => DllCall("GetPropW", "Ptr", WinExist("ahk_class AutoHotkey ahk_pid " mainPid),
    "Str", "AHK.FontRescaler.Ready", "Ptr"))
    DetectHiddenWindows(false)
    return mainPid
}

StopMainForTest() {
    SplitPath(A_ScriptDir, , &workspace)
    DetectHiddenWindows(true)
    stopped := false
    for hwnd in WinGetList(workspace "\main.ahk ahk_class AutoHotkey") {
        WinClose(hwnd)
        WinWaitClose(hwnd, , 3)
        stopped := true
    }
    DetectHiddenWindows(false)
    return stopped
}

RunFileSkipTest() {
    pid := hwnd := 0
    testFile := A_ScriptDir "\output\font_layout_test.lnk"
    try {
        mainPid := ReloadMainForTest()
        FileCreateShortcut(A_AhkPath, testFile)
        Run('"' A_AhkPath '" "' A_ScriptFullPath '" file_target "' testFile '"', , , &pid)
        hwnd := WinWait("font_layout_test Properties ahk_class #32770", , 10)
        AssertTest(hwnd, "File properties did not open")
        loop RescaleSend(DllCall("GetDlgItem", "Ptr", hwnd, "Int", 12320, "Ptr"), 0x1304) {
            RescaleSend(hwnd, 0x465, A_Index - 1)
            AssertTest(!IsAutomaticRescaleWindow(hwnd), "File property page was included: " A_Index)
        }
        AssertTest(!IsAutomaticRescaleWindow(hwnd), "File properties was included in automatic scaling")
        AssertBlacklistRule(hwnd, WindowExclusionRule(DefaultExclusionRules()[1]))
        AssertTest(!SafeRescaleWindow(hwnd), "File properties bypassed the shared entry point")
        before := GetRescaleRect(hwnd)
        font := RescaleSend(hwnd, 0x31)
        Sleep(300)
        after := GetRescaleRect(hwnd)
        AssertTest(!DllCall("GetPropW", "Ptr", hwnd, "Str", RescaleProperty, "Ptr")
        && before.w = after.w && before.h = after.h && RescaleSend(hwnd, 0x31) = font,
        "Unsupported file properties was modified")
        TestLog("PASS: file properties keeps its native font and layout; main=" mainPid "`n")
    } finally {
        if hwnd && DllCall("IsWindow", "Ptr", hwnd)
            WinClose(hwnd)
        if pid && ProcessExist(pid) {
            ProcessWaitClose(pid, 2)
            if ProcessExist(pid)
                ProcessClose(pid)
        }
        if FileExist(testFile)
            FileDelete(testFile)
    }
}

RunFirstPageTest() {
    pid := 0
    hwnd := 0
    environment := 0
    try {
        mainPid := ReloadMainForTest()
        TestLog("MAIN " mainPid "`n")
        Run('"' A_WinDir '\System32\SystemPropertiesAdvanced.exe"', , , &pid)
        TestLog("TARGET " pid "`n")
        hwnd := WinWait("ahk_class #32770 ahk_pid " pid, , 8)
        AssertTest(hwnd, "No fresh System Properties window; an existing instance may have been reused")
        try WaitForPage(() => DllCall("GetPropW", "Ptr", hwnd, "Str", RescaleProperty, "Ptr") = mainPid)
        catch as err {
            TestLog("DETAIL main-alive=" ProcessExist(mainPid) " actual-owner=" DllCall("GetPropW", "Ptr", hwnd, "Str",
                RescaleProperty, "Ptr")
            " visible=" DllCall("IsWindowVisible", "Ptr", hwnd) "`n")
            throw err
        }
        for index in [0, 3] {
            selected := 0
            DllCall("SendMessageTimeoutW", "Ptr", hwnd, "UInt", 0x465, "Ptr", 2, "Ptr", 0,
                "UInt", 0x22, "UInt", 5000, "Ptr*", &selected, "Ptr")
            Sleep(60)
            AssertTest(DllCall("SendMessageTimeoutW", "Ptr", hwnd, "UInt", 0x465, "Ptr", index, "Ptr", 0,
                "UInt", 0x22, "UInt", 5000, "Ptr*", &selected, "Ptr"), "Page selection timed out")
            page := WaitForPage(() => ActiveTestPage(hwnd, mainPid))
            Sleep(60)
            CheckFirstPageText(page)
            Sleep(220)
            CheckFirstPageText(page)
            CaptureTestBitmap(hwnd, A_ScriptDir "\output\first_page_" index ".bmp", true)
            TestLog("PASS first page " index ": visible text fits without switching away/back`n")
        }
        RescaleSend(hwnd, 0x465, 2) ; 回到 Advanced，通过原生按钮打开环境变量。
        button := 0
        for child in WinGetControlsHwnd(hwnd) {
            if WinGetClass(child) = "Button" && DllCall("IsWindowVisible", "Ptr", child)
            && RegExMatch(StrReplace(ReadRescaleCaption(child), "&"), "i)Environment Variables|环境变量") {
                button := child
                break
            }
        }
        AssertTest(button, "Environment Variables button was not found")
        title := InStr(StrReplace(ReadRescaleCaption(button), "&"), "Environment") ? "Environment Variables" : "环境变量"
        WinActivate(hwnd) ; BM_CLICK 在未激活的对话框中可能无效。
        WinWaitActive(hwnd, , 2)
        AssertTest(DllCall("PostMessageW", "Ptr", button, "UInt", 0xF5, "Ptr", 0, "Ptr", 0),
        "Could not open Environment Variables")
        environment := WinWait(title " ahk_class #32770 ahk_pid " pid, , 8)
        AssertTest(environment, "Environment Variables did not open from Advanced")
        WaitForPage(() => DllCall("GetPropW", "Ptr", environment, "Str", RescaleProperty, "Ptr") = mainPid)
        AssertTest(DllCall("IsWindowVisible", "Ptr", environment), "Environment Variables was left hidden")
        AssertTest(!DllCall("GetPropW", "Ptr", environment, "Str", "SysSetRedraw", "Ptr"), "Redrawing was not restored"
        )
        CheckFirstPageText(environment)
        CaptureTestBitmap(environment, A_ScriptDir "\output\system_env_from_advanced.bmp", true)
        TestLog("PASS Advanced -> Environment Variables: visible text fits and drawing is restored`n")
    } finally {
        if environment && DllCall("IsWindow", "Ptr", environment) {
            try WinClose(environment)
        }
        if hwnd && DllCall("IsWindow", "Ptr", hwnd) {
            try WinClose(hwnd)
        }
        if pid && ProcessExist(pid) {
            ProcessWaitClose(pid, 2)
            if ProcessExist(pid)
                ProcessClose(pid)
        }
    }
}

WaitForPage(predicate) {
    loop 200 {
        if (value := predicate())
            return value
        Sleep(15)
    }
    throw Error("Page was not processed by the background script")
}

ActiveTestPage(hwnd, owner) {
    for child in WinGetControlsHwnd(hwnd) {
        if WinGetClass(child) = "#32770" && DllCall("GetParent", "Ptr", child, "Ptr") = hwnd
        && DllCall("IsWindowVisible", "Ptr", child)
        && DllCall("GetPropW", "Ptr", child, "Str", RescaleProperty, "Ptr") = owner
            return child
    }
    return 0
}

CheckFirstPageText(page) {
    for hwnd in WinGetControlsHwnd(page) {
        if !DllCall("IsWindowVisible", "Ptr", hwnd)
            continue
        cls := WinGetClass(hwnd)
        style := WinGetStyle(hwnd)
        if (cls != "Static" && cls != "Button") || !IsRescaleFontControl(cls, style)
            continue
        caption := ReadRescaleCaption(hwnd)
        if !caption || (cls = "Static" && (style & 0xC000))
            continue
        data := ReadRescaleLogFont(RescaleSend(hwnd, 0x31))
        AssertTest(data, "A visible caption has no usable font")
        font := DllCall("CreateFontIndirectW", "Ptr", data, "Ptr")
        dc := DllCall("GetDC", "Ptr", hwnd, "Ptr")
        previous := DllCall("SelectObject", "Ptr", dc, "Ptr", font, "Ptr")
        try {
            client := GetRescaleClient(hwnd)
            dpi := DllCall("GetDpiForWindow", "Ptr", hwnd, "UInt")
            padding := cls = "Button" ? Round(12 * dpi / 96) : 0
            if cls = "Button" && RegExMatch(style & 0xF, "^(2|3|4|5|6|9)$")
                padding := Round(24 * dpi / 96)
            wrap := cls = "Static" ? (style & 0x1F) <= 2 : (style & 0x2000)
            rect := Buffer(16, 0)
            NumPut("Int", Max(1, client.w - padding), rect, 8)
            flags := 0x400 | (wrap ? 0x10 : 0x20) | (cls = "Static" && (style & 0x80) ? 0x800 : 0)
            DllCall("DrawTextW", "Ptr", dc, "Str", caption, "Int", StrLen(caption), "Ptr", rect, "UInt", flags)
            AssertTest(NumGet(rect, 12, "Int") <= client.h, "Caption clipped: " cls " id=" DllCall("GetDlgCtrlID",
                "Ptr", hwnd)
            " needs=" NumGet(rect, 12, "Int") " has=" client.h)
        } finally {
            DllCall("SelectObject", "Ptr", dc, "Ptr", previous)
            DllCall("ReleaseDC", "Ptr", hwnd, "Ptr", dc)
            DllCall("DeleteObject", "Ptr", font)
        }
    }
}

RunSystemWindowTest(mode) {
    global RescaleFontSize
    pid := 0
    hwnd := 0
    restart := false
    if mode = "system_env" {
        command := '"' A_WinDir '\System32\rundll32.exe" sysdm.cpl,EditEnvironmentVariables'
        cls := "#32770"
    } else if mode = "system_properties" {
        command := '"' A_WinDir '\System32\SystemPropertiesAdvanced.exe"'
        cls := "#32770"
    } else if mode = "system_devices" || mode = "system_devices_large" {
        command := '"' A_WinDir '\System32\mmc.exe" "' A_WinDir '\System32\devmgmt.msc" /s'
        cls := "MMCMainFrame"
        if mode = "system_devices_large"
            RescaleFontSize := 16 ; 验证 MDI 窗口在更大字号下仍由原生布局管理。
    } else {
        throw Error("Unknown system test mode")
    }
    try {
        restart := StopMainForTest()
        DetectHiddenWindows(true)
        TestLog("START " mode " admin=" A_IsAdmin " tester=" DllCall("GetCurrentProcessId") "`n")
        Run(command, , "Hide", &pid)
        TestLog("TARGET pid=" pid "`n")
        loop 300 {
            for candidate in WinGetList("ahk_pid " pid) {
                if WinGetClass(candidate) = cls {
                    hwnd := candidate
                    break
                }
            }
            if hwnd
                break
            Sleep(100)
        }
        if !hwnd {
            for candidate in WinGetList("ahk_pid " pid)
                TestLog("WINDOW " candidate " class=" WinGetClass(candidate) " title=" WinGetTitle(candidate) "`n")
            for candidate in WinGetList("ahk_class #32770")
                TestLog("DIALOG pid=" WinGetPID(candidate) " title=" WinGetTitle(candidate) "`n")
        }
        AssertTest(hwnd, "The test application did not create its own window")
        Sleep(250)
        context := DllCall("GetWindowDpiAwarenessContext", "Ptr", hwnd, "Ptr")
        previous := DllCall("SetThreadDpiAwarenessContext", "Ptr", context, "Ptr")
        TestLog("WINDOW class=" WinGetClass(hwnd) " dpi=" DllCall("GetDpiForWindow", "Ptr", hwnd, "UInt") "`n")
        CaptureTestBitmap(hwnd, A_ScriptDir "\output\" mode "_before.bmp")
        if HasRescaleDirectUI(hwnd) {
            AssertTest(!IsAutomaticRescaleWindow(hwnd) && !SafeRescaleWindow(hwnd),
            "DirectUI system window bypassed the guard")
            AssertTest(!HasRescaleMarker(hwnd) && !RescaleProcesses.Count, "A guarded system window was modified")
            TestLog("PASS " mode ": kept native UI because it contains DirectUIHWND`n")
            return
        }
        AssertTest(SafeRescaleWindow(hwnd), "No standard controls were rescaled (candidate=" IsRescaleCandidateWindow(
            hwnd)
        ", blacklist=" IsRescaleExcludedWindow(hwnd) ", DirectUI=" HasRescaleDirectUI(hwnd) ")")
        Sleep(200)
        SafeRescaleWindow(hwnd)
        state := ScaledHwnds[hwnd]
        updated := 0
        overflow := 0
        for control, record in state.nodes {
            if record.applied {
                font := ReadRescaleLogFont(RescaleSend(control, 0x31))
                dpi := DllCall("GetDpiForWindow", "Ptr", control, "UInt")
                AssertTest(font && NumGet(font, 0, "Int") = -Round(RescaleFontSize * dpi / 72),
                "System control font height is incorrect: " record.cls)
                AssertTest(StrGet(font.Ptr + 28, 32, "UTF-16") = RescaleFontName,
                "System control font family is incorrect")
                updated += 1
                if record.HasOwnProp("originalTextWidth") && record.originalTextWidth <= record.rect.w {
                    AssertTest(GetRescaleClient(control).w >= record.targetTextWidth,
                    "A previously fitting caption would wrap after scaling")
                    AssertTest(GetRescaleClient(control).h >= record.textHeight,
                    "A caption is too short for the new font")
                }
            }
            if record.parent && record.layout && record.cls != "ComboBox" && (record.style & 0x10000000) {
                rect := GetRescaleRect(control, record.parent)
                client := GetRescaleClient(record.parent)
                if rect.x < -2 || rect.y < -2 || rect.x + rect.w > client.w + 2 || rect.y + rect.h > client.h + 2 {
                    overflow += 1
                    TestLog("OVERFLOW " record.cls " x=" rect.x " y=" rect.y " w=" rect.w " h=" rect.h " parent=" client
                        .w "x" client.h "`n")
                }
            }
        }
        CaptureTestBitmap(hwnd, A_ScriptDir "\output\" mode "_after.bmp")
        TestLog("PASS " mode ": controls=" updated ", scale=" state.scale ", parent overflow=" overflow "`n")
        AssertTest(overflow = 0, "A system control extends outside its parent")
        if mode = "system_properties" {
            loop 5 {
                pageIndex := A_Index
                selected := 0
                AssertTest(DllCall("SendMessageTimeoutW", "Ptr", hwnd, "UInt", 0x465,
                    "Ptr", pageIndex - 1, "Ptr", 0, "UInt", 0x22, "UInt", 5000, "Ptr*", &selected, "Ptr"),
                "Property page switch timed out")
                Sleep(300)
                SafeRescaleWindow(hwnd)
                for child, record in state.nodes {
                    if !record.parent || !record.layout || record.cls = "ComboBox" || !(WinGetStyle(child) & 0x10000000
                    )
                        continue
                    rect := GetRescaleRect(child, record.parent)
                    client := GetRescaleClient(record.parent)
                    AssertTest(rect.x >= -2 && rect.y >= -2 && rect.x + rect.w <= client.w + 2
                        && rect.y + rect.h <= client.h + 2, "Property page " pageIndex " overflows: " record.cls
                        " rect=" rect.x "," rect.y "," rect.w "," rect.h " parent=" client.w "x" client.h)
                    if record.applied && record.HasOwnProp("originalTextWidth") && record.originalTextWidth <= record.rect
                    .w
                        AssertTest(GetRescaleClient(child).w >= record.targetTextWidth,
                        "A new property-page caption wraps")
                }
                CaptureTestBitmap(hwnd, A_ScriptDir "\output\system_properties_page" pageIndex "_after.bmp")
                TestLog("PAGE " pageIndex " checked`n")
            }
        }
        DllCall("SetThreadDpiAwarenessContext", "Ptr", previous, "Ptr")
    } finally {
        CleanupDialogRescaler()
        if hwnd && DllCall("IsWindow", "Ptr", hwnd) {
            try WinClose(hwnd)
        }
        if pid && ProcessExist(pid) {
            ProcessWaitClose(pid, 2)
            if ProcessExist(pid)
                ProcessClose(pid)
        }
        if restart
            ReloadMainForTest()
    }
}

BuildTestWindow() {
    global TestGui, TestButton, TestLabel, TestOriginalFont, TestLatePage
    if A_Args.Length >= 3 && A_Args[3] = "unaware"
        DllCall("SetThreadDpiAwarenessContext", "Ptr", -1, "Ptr")
    TestGui := Gui("+Resize -DPIScale", "Win32 font regression")
    TestGui.SetFont("s9", "Segoe UI")
    tab := TestGui.AddTab3("x12 y12 w450 h250", ["环境变量", "系统属性"])
    tab.UseTab(1)
    ; 固定像素夹具为175%下较高的页签标题留出空间，避免测试前就已越界。
    TestLabel := TestGui.AddText("x30 y60 w140 h28", "环境变量：")
    edit := TestGui.AddEdit("x180 y60 w240 h32", "C:\Windows")
    button := TestGui.AddButton("x275 y105 w145 h34", "编辑变量(&E)…")
    list := TestGui.AddListView("x30 y155 w390 h95", ["变量", "值"])
    list.Add(, "PATH", "C:\Windows\System32")
    list.Add(, "TEMP", "C:\Temp")
    list.ModifyCol(1, 110)
    list.ModifyCol(2, 255)
    tab.UseTab()
    tree := TestGui.AddTreeView("x12 y278 w205 h112")
    device := tree.Add("设备管理器")
    tree.Add("显示适配器", device)
    tree.Modify(device, "Expand")
    combo := TestGui.AddDropDownList("x235 y278 w225 h160 Choose1", ["微软雅黑", "Segoe UI", "Tahoma"])
    TestButton := TestGui.AddButton("x325 y350 w135 h34", "确定(&O)")
    panel := Gui("-Caption -DPIScale +Parent" TestGui.Hwnd)
    inner := Gui("-Caption -DPIScale +Parent" panel.Hwnd)
    inner.SetFont("s9", "Segoe UI")
    deep := inner.AddText("x10 y8 w330 h26", "多层容器中的中文文本标签")
    inner.Show("NA x5 y5 w400 h40")
    panel.Show("NA x12 y402 w450 h50")
    TestGui.Show("Hide w480 h535")
    TestGui.TestChildren := [panel, inner]
    TestOriginalFont := RescaleSend(TestLabel.Hwnd, 0x31)
    TestLatePage := 0
    OnMessage(0x8101, (control, *) => TargetFontHeight(control))
    OnMessage(0x8102, (control, *) => TargetTextFits(control))
    OnMessage(0x8103, (*) => AddTestPage())
    OnMessage(0x8104, (*) => SetTimer(() => ExitApp(), -10))
    OnMessage(0x8105, (*) => RescaleSend(TestLabel.Hwnd, 0x30, TestOriginalFont, 1))
    OnMessage(0x8106, (*) => DllCall("GetGuiResources", "Ptr", DllCall("GetCurrentProcess", "Ptr"), "UInt", 0, "UInt"))
    OnMessage(0x8108, CreateInitializingPage)
    OnMessage(0x8109, FinishInitializingPage)
    OnMessage(0x810A, CreateResourceDialog)
    OnMessage(0x810B, DestroyResourceDialog)
    OnMessage(0x0005, TargetAutoLayout)
    handles := [TestGui.Hwnd, TestLabel.Hwnd, edit.Hwnd, button.Hwnd, list.Hwnd, tree.Hwnd, combo.Hwnd, TestButton.Hwnd,
        deep.Hwnd, tab.Hwnd]
    output := ""
    for hwnd in handles
        output .= hwnd "`n"
    FileAppend(output, A_Args[2], "UTF-8")
}

CreateResourceDialog(*) {
    global ResourceTestGui
    ResourceTestGui := Gui("-DPIScale", "Font cache regression")
    ResourceTestGui.SetFont("s9", "Segoe UI")
    ResourceTestGui.AddText("x10 y10 w240 h30", "Repeated dialog 字体测试")
    ResourceTestGui.AddButton("x155 y55 w90 h30", "确定")
    ResourceTestGui.Show("NA w270 h100")
    return ResourceTestGui.Hwnd
}

DestroyResourceDialog(*) {
    global ResourceTestGui
    ResourceTestGui.Destroy()
    ResourceTestGui := 0
    return 1
}

CreateInitializingPage(*) {
    ; 属性页先隐藏创建，应用完成初始化后才显示。
    page := DllCall("CreateWindowExW", "UInt", 0, "Str", "#32770", "Str", "",
        "UInt", 0x40000400, "Int", 12, "Int", 466, "Int", 450, "Int", 50,
        "Ptr", TestGui.Hwnd, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr")
    label := DllCall("CreateWindowExW", "UInt", 0, "Str", "Static", "Str", "首次初始化的属性页文本",
        "UInt", 0x50000000, "Int", 10, "Int", 10, "Int", 330, "Int", 26,
        "Ptr", page, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr")
    RescaleSend(label, 0x30, TestOriginalFont, 1)
    return page
}

FinishInitializingPage(page, *) {
    label := DllCall("GetWindow", "Ptr", page, "UInt", 5, "Ptr")
    metrics := MeasureRescaleFont(ReadRescaleLogFont(TestOriginalFont))
    RescaleSend(label, 0x30, TestOriginalFont, 1)
    MoveRescaleRect(label, { x: 10, y: 10, w: 330, h: metrics.height })
    MoveRescaleRect(page, { x: 12, y: 466, w: 450, h: 50 })
    DllCall("ShowWindow", "Ptr", page, "Int", 8)
    return label
}

TargetAutoLayout(wParam, lParam, message, hwnd) {
    if hwnd = TestGui.Hwnd
        TestButton.Move((lParam & 0xFFFF) - 155, ((lParam >> 16) & 0xFFFF) - 185, 135, 34)
}

AddTestPage() {
    global TestLatePage
    TestLatePage := DllCall("CreateWindowExW", "UInt", 0, "Str", "#32770", "Str", "",
        "UInt", 0x50000400, "Int", 12, "Int", 466, "Int", 450, "Int", 50,
        "Ptr", TestGui.Hwnd, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr")
    label := DllCall("CreateWindowExW", "UInt", 0, "Str", "Static", "Str", "延迟创建的属性页文本",
        "UInt", 0x50000000, "Int", 10, "Int", 10, "Int", 330, "Int", 26,
        "Ptr", TestLatePage, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr")
    RescaleSend(label, 0x30, TestOriginalFont, 1)
    return TestLatePage
}

AssertBlacklistRule(hwnd, rule) {
    global RescaleBlacklist
    saved := RescaleBlacklist
    try {
        RescaleBlacklist := [rule]
        AssertTest(IsRescaleExcludedWindow(hwnd), "Default blacklist rule did not match")
        RescaleBlacklist := []
        AssertTest(!IsRescaleExcludedWindow(hwnd), "A default rule remained active outside the blacklist")
    } finally {
        RescaleBlacklist := saved
    }
}

AcceptLayoutTestWindow(hwnd) => WinGetClass(hwnd) = "AutoHotkeyGUI"

RunLayoutTest() {
    global ScaledHwnds, RescaleFontSize
    mode := A_Args.Length ? A_Args[1] : "x64"
    SplitPath(A_AhkPath, , &runtimeDirectory)
    runtime := mode = "x86" ? runtimeDirectory "\AutoHotkey32.exe" : A_AhkPath
    ready := A_ScriptDir "\layout_" DllCall("GetCurrentProcessId") ".txt"
    pid := 0
    try {
        Run('"' runtime '" /ErrorStdOut "' A_ScriptFullPath '" target "' ready '" ' mode, , "Hide", &pid)
        loop 100 {
            if FileExist(ready)
                break
            Sleep(50)
        }
        handles := StrSplit(Trim(FileRead(ready, "UTF-8"), "`r`n"), "`n")
        hwnd := Integer(handles[1])
        if mode = "embedded" {
            RunEmbeddedFontTest(hwnd, handles)
            return
        }
        context := DllCall("GetWindowDpiAwarenessContext", "Ptr", hwnd, "Ptr")
        previous := DllCall("SetThreadDpiAwarenessContext", "Ptr", context, "Ptr")
        dpi := DllCall("GetDpiForWindow", "Ptr", hwnd, "UInt")
        expectedFontHeight := Round(RescaleFontSize * dpi / 72)
        before := CaptureRescaleTree(hwnd)
        originalClient := GetRescaleClient(hwnd)
        if mode = "x64" {
            originalFont := RescaleSend(Integer(handles[2]), 0x31)
            RescaleFontSize := 72
            AssertTest(!SafeRescaleWindow(hwnd, AcceptLayoutTestWindow), "An oversized layout was applied")
            unchanged := GetRescaleClient(hwnd)
            AssertTest(unchanged.w = originalClient.w && unchanged.h = originalClient.h
                && RescaleSend(Integer(handles[2]), 0x31) = originalFont, "Screen-size fallback changed the window")
            RescaleFontSize := 12
        }
        DirCreate(A_ScriptDir "\output")
        if mode = "visual"
            CaptureTestBitmap(hwnd, A_ScriptDir "\output\" mode "_before.bmp")
        AssertTest(SafeRescaleWindow(hwnd, AcceptLayoutTestWindow), "Window was not rescaled")
        Sleep(100)
        state := ScaledHwnds[hwnd]
        after := GetRescaleClient(hwnd)
        work := GetRescaleWorkArea(hwnd)
        window := GetRescaleRect(hwnd)
        AssertTest(window.w <= work.w && window.h <= work.h, "Window exceeds its monitor work area")
        AssertTest(window.x >= work.x && window.y >= work.y && window.x + window.w <= work.x + work.w
            && window.y + window.h <= work.y + work.h, "Window extends off screen")
        AssertTest(after.w = Round(originalClient.w * state.scale), "Client width did not scale correctly")
        AssertTest(after.h = Round(originalClient.h * state.scale), "Client height did not scale correctly")
        for index in [2, 3, 4, 5, 6, 7, 8, 9, 10] {
            control := Integer(handles[index])
            AssertTest(RescaleSend(hwnd, 0x8101, control) = expectedFontHeight,
            "Font could not be selected in target: " WinGetClass(control))
        }
        for index in [2, 4, 8, 9]
            AssertTest(RescaleSend(hwnd, 0x8102, Integer(handles[index])), "Text is clipped: " index)
        for record in before {
            if !record.parent || !record.layout || record.cls = "ComboBox"
                continue
            actual := GetRescaleRect(record.hwnd, record.parent)
            client := GetRescaleClient(record.parent)
            AssertTest(actual.x >= 0 && actual.y >= 0 && actual.x + actual.w <= client.w + 1
                && actual.y + actual.h <= client.h + 1, "Control extends outside its parent: " record.cls
                " rect=" actual.x "," actual.y "," actual.w "," actual.h " parent=" client.w "," client.h
                " original=" record.rect.x "," record.rect.y "," record.rect.w "," record.rect.h)
        }
        list := Integer(handles[5])
        tree := Integer(handles[6])
        combo := Integer(handles[7])
        AssertTest(RescaleSend(list, 0x101D, 0) >= MeasureRescaleFont(state.nodes[list].logFont, "变量").width,
        "List header is truncated")
        AssertTest(RescaleSend(tree, 0x111C) >= state.nodes[tree].textHeight, "Tree row is shorter than its text")
        dropped := Buffer(16, 0)
        RescaleSend(combo, 0x152, 0, dropped.Ptr)
        AssertTest(NumGet(dropped, 12, "Int") - NumGet(dropped, 4, "Int") > state.nodes[combo].textHeight * 3,
        "Combo dropdown was collapsed by layout")
        dimensions := GetRescaleRect(hwnd)
        gdiCount := RescaleSend(hwnd, 0x8106)
        loop 3
            AssertTest(SafeRescaleWindow(hwnd, AcceptLayoutTestWindow), "Repeated application failed")
        AssertTest(GetRescaleRect(hwnd).w = dimensions.w, "Repeated application enlarged the window again")
        AssertTest(RescaleSend(hwnd, 0x8106) = gdiCount, "Repeated application allocated more GDI objects")
        RescaleSend(hwnd, 0x8105)
        SafeRescaleWindow(hwnd, AcceptLayoutTestWindow)
        AssertTest(RescaleSend(hwnd, 0x8101, Integer(handles[2])) = expectedFontHeight, "Font reset was not repaired")
        page := RescaleSend(hwnd, 0x8103)
        AssertTest(page != 0, "Could not create delayed property page")
        SafeRescaleWindow(hwnd, AcceptLayoutTestWindow)
        lateLabel := DllCall("GetWindow", "Ptr", page, "UInt", 5, "Ptr")
        AssertTest(RescaleSend(hwnd, 0x8101, lateLabel) = expectedFontHeight, "Delayed page font was not updated")
        AssertTest(RescaleSend(hwnd, 0x8102, lateLabel), "Delayed page text is clipped")
        if mode = "visual"
            CaptureTestBitmap(hwnd, A_ScriptDir "\output\" mode "_after.bmp")
        CleanupDialogRescaler()
        AssertTest(RescaleSend(hwnd, 0x8101, Integer(handles[2])) = expectedFontHeight,
        "Font became invalid after AHK released the process handle")
        AssertTest(SafeRescaleWindow(hwnd, AcceptLayoutTestWindow), "Reapplication after reload failed")
        AssertTest(GetRescaleRect(hwnd).w = dimensions.w, "Reload enlarged the window again")
        RescaleSend(hwnd, 0x8104)
        ProcessWaitClose(pid, 3)
        FileAppend("PASS " mode ": dpi=" dpi ", scale=" state.scale ", font=" expectedFontHeight "px; nested controls, text bounds, list/tree/combo, late page, repeat/reload`n",
            "*")
        DllCall("SetThreadDpiAwarenessContext", "Ptr", previous, "Ptr")
    } finally {
        CleanupDialogRescaler()
        if pid && ProcessExist(pid)
            ProcessClose(pid)
        if FileExist(ready)
            FileDelete(ready)
    }
}

RunEmbeddedFontTest(child, handles) {
    host := Gui("-DPIScale")
    host.SetFont("s9", "Segoe UI")
    ownLabel := host.AddText("x10 y10 w400 h30", "Host process 字体测试")
    host.Show("Hide w600 h720")
    try {
        WinSetStyle((WinGetStyle(child) | 0x40000000) & ~0x80000000, child)
        DllCall("SetParent", "Ptr", child, "Ptr", host.Hwnd, "Ptr")
        size := GetRescaleRect(child)
        MoveRescaleRect(child, { x: 10, y: 60, w: size.w, h: size.h })
        AssertTest(SafeRescaleWindow(host.Hwnd, AcceptLayoutTestWindow), "Embedded window was not rescaled")
        expected := Round(RescaleFontSize * DllCall("GetDpiForWindow", "Ptr", child, "UInt") / 72)
        for index in [2, 3, 4, 5, 6, 7, 8, 9, 10]
            AssertTest(RescaleSend(child, 0x8101, Integer(handles[index])) = expected,
            "Embedded child received a font owned by the host process")
        AssertTest(TargetFontHeight(ownLabel.Hwnd) = expected, "Host font is invalid")
        FileAppend("PASS embedded: host and embedded controls use fonts owned by their own processes`n", "*")
    } finally {
        host.Destroy()
    }
}

TargetFontHeight(hwnd) {
    font := RescaleSend(hwnd, 0x31)
    dc := DllCall("GetDC", "Ptr", hwnd, "Ptr")
    previous := DllCall("SelectObject", "Ptr", dc, "Ptr", font, "Ptr")
    try {
        if !previous
            return 0
        tm := Buffer(60, 0)
        DllCall("GetTextMetricsW", "Ptr", dc, "Ptr", tm)
        face := Buffer(64, 0)
        DllCall("GetTextFaceW", "Ptr", dc, "Int", 32, "Ptr", face)
        actualFace := StrGet(face, "UTF-16")
        if actualFace != RescaleFontName && actualFace != "微软雅黑" {
            return 0
        }
        return NumGet(tm, 0, "Int") - NumGet(tm, 12, "Int")
    } finally {
        if previous
            DllCall("SelectObject", "Ptr", dc, "Ptr", previous)
        DllCall("ReleaseDC", "Ptr", hwnd, "Ptr", dc)
    }
}

TargetTextFits(hwnd) {
    font := RescaleSend(hwnd, 0x31)
    dc := DllCall("GetDC", "Ptr", hwnd, "Ptr")
    previous := DllCall("SelectObject", "Ptr", dc, "Ptr", font, "Ptr")
    try {
        if !previous
            return false
        text := StrReplace(ControlGetText(hwnd), "&", "")
        extent := Buffer(8, 0)
        DllCall("GetTextExtentPoint32W", "Ptr", dc, "Str", text, "Int", StrLen(text), "Ptr", extent)
        client := GetRescaleClient(hwnd)
        return NumGet(extent, 0, "Int") <= client.w && NumGet(extent, 4, "Int") <= client.h
    } finally {
        if previous
            DllCall("SelectObject", "Ptr", dc, "Ptr", previous)
        DllCall("ReleaseDC", "Ptr", hwnd, "Ptr", dc)
    }
}

CaptureTestBitmap(hwnd, path, keepVisible := false) {
    if !keepVisible {
        DllCall("ShowWindow", "Ptr", hwnd, "Int", 4) ; 短暂显示，但不激活/抢焦点。
        RedrawRescaleWindow(hwnd)
        Sleep(100)
    }
    rect := GetRescaleRect(hwnd)
    screen := DllCall("GetDC", "Ptr", 0, "Ptr")
    dc := DllCall("CreateCompatibleDC", "Ptr", screen, "Ptr")
    info := Buffer(40, 0)
    NumPut("UInt", 40, "Int", rect.w, "Int", -rect.h, "UShort", 1, "UShort", 32, info)
    pixels := 0
    bitmap := DllCall("CreateDIBSection", "Ptr", dc, "Ptr", info, "UInt", 0, "Ptr*", &pixels, "Ptr", 0, "UInt", 0,
        "Ptr")
    previous := DllCall("SelectObject", "Ptr", dc, "Ptr", bitmap, "Ptr")
    try {
        DllCall("PrintWindow", "Ptr", hwnd, "Ptr", dc, "UInt", 2)
        if InStr(path, "system_env") {
            ; 留存测试图像只需要表头和布局，遮住环境变量的具体值。
            for child in WinGetControlsHwnd(hwnd) {
                if WinGetClass(child) != "SysListView32"
                    continue
                list := GetRescaleRect(child)
                headerWindow := RescaleSend(child, 0x101F)
                headerHeight := headerWindow ? GetRescaleRect(headerWindow).h : 32
                mask := Buffer(16, 0)
                NumPut("Int", list.x - rect.x + 2, "Int", list.y - rect.y + headerHeight + 2,
                    "Int", list.x - rect.x + list.w - 2, "Int", list.y - rect.y + list.h - 2, mask)
                DllCall("FillRect", "Ptr", dc, "Ptr", mask, "Ptr", DllCall("GetStockObject", "Int", 0, "Ptr"))
            }
        }
        size := rect.w * rect.h * 4
        header := Buffer(14, 0)
        NumPut("UShort", 0x4D42, "UInt", 54 + size, header)
        NumPut("UInt", 54, header, 10)
        output := FileOpen(path, "w")
        output.RawWrite(header)
        output.RawWrite(info)
        output.RawWrite(pixels, size)
        output.Close()
    } finally {
        DllCall("SelectObject", "Ptr", dc, "Ptr", previous)
        DllCall("DeleteObject", "Ptr", bitmap)
        DllCall("DeleteDC", "Ptr", dc)
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", screen)
        if !keepVisible
            DllCall("ShowWindow", "Ptr", hwnd, "Int", 0)
    }
}

AssertTest(condition, message) {
    if !condition
        throw Error(message)
}

TestError(err, *) {
    TestLog("FAIL: " err.Message "`n" err.Stack "`n")
    ExitApp(1)
}

TestLog(value) {
    if TestLogPath
        FileAppend(value, TestLogPath, "UTF-8")
    else
        FileAppend(value, "*")
}

