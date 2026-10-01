#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#Include %A_ScriptDir%\..\main.ahk
#Include %A_ScriptDir%\..\src\codex_auto_retry.ahk
DirCreate(A_ScriptDir "\output")

; 只使用内存中的假按钮和隐藏测试窗口，不检测或点击真实 Codex，不注册日常快捷键。
try {
    TestSettings()
    TestRetryDecisions()
    TestRetryDeadline()
    TestHiddenWindowSelection()
    TestNativeUIA()
    TestSettingsPanel()
    TestManagerCommit()
    TestWorkerLifecycle()
    FileAppend(
        "PASS: settings, retry guards, hidden/minimized window selection, local UIA, panel, commit rollback and worker exit`n",
        "*")
} catch as err {
    FileAppend("FAIL: " err.Message "`n" err.Stack "`n", "*")
    ExitApp(1)
}
ExitApp()

Check(value, message) {
    if !value
        throw Error(message)
}

TestSettings() {
    SplitPath(A_ScriptDir, , &workspace)
    Check(ToolboxSettings.Directory = workspace && ToolboxSettings.Path = workspace "\data\toolbox.ini",
        "Moving source files changed the configuration location")
    path := (A_ScriptDir "\output") "\ahk-toolbox-test-" DllCall("GetCurrentProcessId") ".ini"
    try {
        settings := ToolboxSettings.Load(path)
        customIndex := settings["ExclusionRules"].Length + 1
        Check(!settings["RetryEnabled"], "Retry must be opt-in")
        settings["ExclusionRules"].Push({ Name: "自定义", Window: "窗口 = 测试 ahk_exe example.exe", Features: "", Scope: "all" })
        settings["TerminalKey"] := "^#W"
        ToolboxSettings.Save(settings, path)
        loaded := ToolboxSettings.Load(path)
        Check(loaded["ExclusionRules"][customIndex].Window = settings["ExclusionRules"][customIndex].Window,
            "Blacklist roundtrip changed data")
        Check(loaded["ExclusionRules"][1].Features = settings["ExclusionRules"][1].Features,
            "Multiline features changed")
        Check(loaded["TerminalKey"] = "#^w", "Hotkey normalization failed")
        for entry in [["RetryInterval", 0], ["FontSize", "abc"], ["NativePercent", 176],
        ["TerminalKey", "#F11"], ["EverythingKey", "^#w"], ["TerminalKey", "w"],
        ["RetryEnabled", 2], ["FontName", "bad`nname"], ["FontName", "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"]] {
            bad := loaded.Clone(), bad[entry[1]] := entry[2], rejected := false
            try ToolboxSettings.Validate(bad)
            catch
                rejected := true
            Check(rejected, "Invalid setting was accepted: " entry[1])
        }
        Check(ToolboxSettings.Load(path)["FontSize"] = 12, "Validation changed saved data")
        loaded["TerminalKey"] := ""
        loaded["CustomHotkeys"].Push({ Name: "示例程序", Key: "^!j", Program: "C:\Program Files\Example\app.exe" })
        ToolboxSettings.Save(loaded, path)
        roundtrip := ToolboxSettings.Load(path)
        Check(roundtrip["TerminalKey"] = "" && roundtrip["CustomHotkeys"].Length = 1,
            "Deleted/default and added/custom bindings did not survive reload")
        Check(roundtrip["CustomHotkeys"][1].Program = loaded["CustomHotkeys"][1].Program,
            "Custom program path roundtrip failed")
        copy := ToolboxSettings.Copy(roundtrip)
        copy["CustomHotkeys"][1].Name := "changed"
        Check(roundtrip["CustomHotkeys"][1].Name = "示例程序", "Draft changed live settings")
        copy["CustomHotkeys"][1].Key := copy["EverythingKey"]
        rejected := false
        try ToolboxSettings.Validate(copy)
        catch
            rejected := true
        Check(rejected, "Custom shortcut collided with built-in shortcut")
        roundtrip["ExclusionRules"] := []
        ToolboxSettings.Save(roundtrip, path)
        Check(!ToolboxSettings.Load(path)["ExclusionRules"].Length, "Deleted initial rules returned after reload")
        FileDelete(path)
        IniWrite("ahk_exe old.exe", path, "Exclusions", "1")
        migrated := ToolboxSettings.Load(path)
        Check(migrated["ExclusionRules"].Length = customIndex && migrated["ExclusionRules"][customIndex].Window =
            "ahk_exe old.exe", "Legacy rules were lost")
    } finally {
        if FileExist(path)
            FileDelete(path)
    }
}

class FakeButton {
    Name := "继续"
    RuntimeId := "button-1"
    IsEnabled := true
    IsOffscreen := false
    IsInvokePatternAvailable := true
    calls := 0
    fail := false
    Invoke() {
        this.calls++
        if this.fail
            throw Error("Provider failed after accepting the invocation")
    }
}

class RetryTimerFixture {
    __New(settings) => this.settings := settings
    fired := false
    Tick() => this.fired := true
}

TestRetryDeadline() {
    global RetryWorker, RetryParentHandle := 0, RetryParentWindow := A_ScriptHwnd, RetrySettingsPath
    RetrySettingsPath := A_ScriptDir "\output\retry-deadline-" DllCall("GetCurrentProcessId") ".ini"
    RetryWorker := RetryTimerFixture(ToolboxSettings.Defaults())
    try {
        changed := ToolboxSettings.Defaults()
        changed["FontSize"] := 13 ; 修改无关设置，保持检查间隔为60秒。
        ToolboxSettings.Save(changed, RetrySettingsPath)
        SetTimer(RetryWorkerTick, -100) ; 模拟当前检查只剩100ms就到期。
        RetryControl(1, A_ScriptHwnd)
        Critical("Off") ; 此处直接调用回调，没有消息线程替我们恢复状态。
        deadline := A_TickCount + 1500
        while !RetryWorker.fired && A_TickCount < deadline
            Sleep(10)
        Check(RetryWorker.fired, "Unrelated settings reset the pending retry deadline")
    } finally {
        Critical("Off")
        SetTimer(RetryWorkerTick, 0)
        if FileExist(RetrySettingsPath)
            FileDelete(RetrySettingsPath)
        RetryWorker := 0
    }
}

class FakeRoot {
    __New(buttons) => this.buttons := buttons
    FindElements(condition) => this.buttons
}

class WindowFixtureRetry extends CodexRetry {
    roots := Map()
    ReadRoot(hwnd) => this.roots[hwnd]
}

TestHiddenWindowSelection() {
    foreground := WinActive("A")
    instance := DllCall("GetModuleHandleW", "Ptr", 0, "Ptr")
    wc := Buffer(80, 0), className := "Chrome_WidgetWin_1"
    NumPut("UInt", 80, wc)
    Check(DllCall("GetClassInfoExW", "Ptr", 0, "Str", "Static", "Ptr", wc), "Fixture class unavailable")
    NumPut("Ptr", instance, wc, 24)
    NumPut("Ptr", StrPtr(className), wc, 64)
    Check(DllCall("RegisterClassExW", "Ptr", wc, "UShort"), "Fixture class registration failed")
    windows := []
    hidden := DetectHiddenWindows(true)
    try {
        loop 2 {
            hwnd := DllCall("CreateWindowExW", "UInt", 0x80, "Str", className, "Str", "Retry test window",
                "UInt", 0x00CF0000, "Int", -10000, "Int", -10000, "Int", 200, "Int", 100,
                "Ptr", 0, "Ptr", 0, "Ptr", instance, "Ptr", 0, "Ptr")
            Check(hwnd, "Fixture window failed")
            windows.Push(hwnd)
        }
        current := windows[1], stale := windows[2]
        settings := ToolboxSettings.Defaults()
        settings["RetryTarget"] := "ahk_pid " DllCall("GetCurrentProcessId")
        retry := WindowFixtureRetry(settings)
        retry.roots[current] := FakeRoot([FakeButton()])
        retry.roots[stale] := FakeRoot([])
        DllCall("ShowWindow", "Ptr", current, "Int", 8)
        Check(retry.FindWindow() = current, "Hidden old window outranked visible main")
        DllCall("ShowWindow", "Ptr", current, "Int", 7)
        Check(WinGetMinMax(current) = -1 && retry.FindWindow() = current, "Minimized main was lost")
        DllCall("ShowWindow", "Ptr", current, "Int", 0)
        Check(retry.FindWindow() = current, "Tray-hidden main was lost")
        retry.lastWindow := 0
        Check(retry.FindWindow() = current, "Cold start in tray did not identify the composer")
        retry.lastWindow := 0, retry.roots[stale] := FakeRoot([FakeButton()])
        Check(!retry.FindWindow(), "Ambiguous hidden windows were not skipped")
        Check(WinActive("A") = foreground, "Window selection changed foreground")
    } finally {
        for hwnd in windows
            DllCall("DestroyWindow", "Ptr", hwnd)
        DetectHiddenWindows(hidden)
        DllCall("UnregisterClassW", "Str", className, "Ptr", instance)
    }
}

TestRetryDecisions() {
    retry := CodexRetry(ToolboxSettings.Defaults())
    changing := FakeButton()
    changing.reads := 0
    changing.DefineProp("Name", { Get: (button) => (++button.reads = 1 ? "继续" : "停止") })
    Check(!retry.TryContinue(FakeRoot([changing]), 124) && !changing.calls, "Button changing to Stop was invoked")
    button := FakeButton(), root := FakeRoot([button])
    Check(retry.TryContinue(root, 123), "Continue button wasn't invoked")
    Check(!retry.TryContinue(root, 123) && button.calls = 1, "Duplicate continue was invoked")
    root.buttons := []
    Check(!retry.TryContinue(root, 123), "Missing button wasn't skipped")
    root.buttons := [button]
    Check(retry.TryContinue(root, 123), "Button did not rearm after disappearing")
    for name in ["停止", "发送", "继续生成其他内容"] {
        button.Name := name, button.RuntimeId := name
        Check(!retry.TryContinue(root, 123), "Non-continue button invoked: " name)
    }
    button.Name := "继续", button.RuntimeId := "button-2", button.IsEnabled := false
    Check(!retry.TryContinue(root, 123), "Disabled button invoked")
    button.IsEnabled := true, button.IsOffscreen := true
    Check(!retry.TryContinue(root, 123), "Offscreen button invoked")
    Check(retry.TryContinue(root, 123, true), "Background-hidden button was incorrectly rejected")
    Check(!retry.TryContinue(root, 123, true), "Background-hidden button was invoked twice")
    button.RuntimeId := "button-3"
    button.IsOffscreen := false, button.IsInvokePatternAvailable := false
    Check(!retry.TryContinue(root, 123), "Unsupported button invoked")
    button.IsInvokePatternAvailable := true
    root.buttons := [button, FakeButton()]
    Check(!retry.TryContinue(root, 123), "Ambiguous buttons invoked")
    root.buttons := [button], button.fail := true
    try retry.TryContinue(root, 123)
    Check(!retry.TryContinue(root, 123) && button.calls = 4, "Failed Invoke retried same button")
    retry.settings["RetryTarget"] := "ahk_exe no-such-toolbox-test-process.exe"
    retry.Tick()
    Check(!retry.busy, "Busy flag leaked after skip")
}

TestNativeUIA() {
    ; 仅检查我们自己的隐藏 GUI，确认真实 UIA 库接受组合条件。
    fixture := Gui("+ToolWindow -Caption")
    fixture.AddButton("w140", "继续")
    fixture.AddButton("w140", "继续其他内容")
    fixture.Show("x-10000 y-10000 w200 h100 NA")
    try {
        UIA.AutoSetFocus := false
        root := UIA.ElementFromHandle(fixture.Hwnd, , false)
        matches := root.FindElements({ Type: "Button", Name: "继续", and: { ClassName: "But", mm: 2 } })
        Check(matches.Length = 1, "UIA mixed exact/substring condition failed")
    } finally {
        fixture.Destroy()
    }
}

TestSettingsPanel() {
    ; 拦截 Show：完整构造和销毁控件，但不显示窗口、不抢前台。
    original := Gui.Prototype.GetOwnPropDesc("Show")
    Gui.Prototype.DefineProp("Show", { Call: (*) => 0 })
    manager := Toolbox(ToolboxSettings.Defaults())
    try {
        manager.ShowSettings()
        defaultCount := manager.draft["ExclusionRules"].Length
        newIndex := defaultCount + 1
        Check(manager.controls.Count = 8, "Settings fields missing")
        Check(!manager.controls.Has("EverythingPath"), "Program path should not occupy the daily settings panel")
        Check(manager.controls["RetryInterval"].Value = "60", "Panel defaults incorrect")
        manager.EditEntry("shortcuts", true)
        Check(WinGetStyle(manager.window.Hwnd) & 0x08000000, "Editor did not disable its owner")
        manager.CloseEntry()
        Check(!manager.editor && !(WinGetStyle(manager.window.Hwnd) & 0x08000000), "Cancel left the settings panel disabled")
        manager.EditEntry("rules", true)
        manager.entryControls["Name"].Value := "测试规则"
        manager.entryControls["Window"].Value := "ahk_exe example.exe"
        manager.AcceptEntry("rules", 0)
        Check(manager.ruleList.GetCount() = newIndex, "Initial rules or new rule missing")
        manager.ruleList.Modify(newIndex, "Select Focus")
        manager.EditEntry("rules", false)
        manager.entryControls["Window"].Value := "ahk_exe other.exe"
        manager.AcceptEntry("rules", newIndex)
        Check(manager.draft["ExclusionRules"][newIndex].Window = "ahk_exe other.exe", "Window rule was not edited")
        manager.ruleList.Modify(newIndex, "Select Focus")
        manager.DeleteEntry("rules")
        Check(manager.draft["ExclusionRules"].Length = defaultCount, "Rule was not deleted")
        manager.ruleList.Modify(defaultCount, "Select Focus")
        manager.DeleteEntry("rules")
        Check(manager.draft["ExclusionRules"].Length = defaultCount - 1 && manager.settings["ExclusionRules"].Length =
            defaultCount,
            "Initial rule could not be deleted, or draft mutated active settings")
        manager.EditEntry("shortcuts", true)
        manager.entryControls["Name"].Value := "示例应用"
        manager.entryControls["Key"].Value := "^!j"
        manager.entryControls["Program"].Value := "C:\Example\app.exe"
        manager.AcceptEntry("shortcuts", 0)
        Check(manager.shortcutList.GetCount() = 4, "Shortcut was not added")
        Check(AppHotkeyEntries(manager.draft)[4].Target = "ahk_exe app.exe", "Custom target did not match exe")
        manager.shortcutList.Modify(1, "Select Focus")
        manager.DeleteEntry("shortcuts")
        Check(manager.draft["TerminalKey"] = "", "Built-in shortcut was not deleted")
        manager.shortcutList.Modify(3, "Select Focus")
        manager.EditEntry("shortcuts", false)
        manager.entryControls["Name"].Value := "修改后的应用"
        manager.entryControls["Key"].Value := "^!k"
        manager.AcceptEntry("shortcuts", 1)
        Check(manager.draft["CustomHotkeys"][1].Key = "^!k", "Custom shortcut was not edited")
        manager.shortcutList.Modify(3, "Select Focus")
        manager.DeleteEntry("shortcuts")
        Check(!manager.draft["CustomHotkeys"].Length, "Custom shortcut was not deleted")
        Check(manager.settings["TerminalKey"] = "#w" && !manager.settings["CustomHotkeys"].Length,
            "Unsaved list changes leaked into live settings")
        manager.CloseSettings()
        Check(!manager.window && !manager.controls.Count, "Panel retained GUI objects")
    } finally {
        manager.CloseSettings()
        Gui.Prototype.DefineProp("Show", original)
    }
}

TestWorkerLifecycle() {
    path := (A_ScriptDir "\output") "\ahk-worker-test-" DllCall("GetCurrentProcessId") ".ini"
    settings := ToolboxSettings.Defaults()
    settings["RetryTarget"] := "ahk_exe no-such-toolbox-test-process.exe"
    manager := Toolbox(settings, path)
    pid := 0
    try {
        ToolboxSettings.Save(settings, path)
        manager.StartWorker()
        Check(manager.WorkerWindow(), "Worker wasn't ready")
        pid := manager.worker.pid
        manager.StartWorker()
        Check(manager.worker.pid = pid, "Settings update created another worker")
        manager.StopWorker()
        ProcessWaitClose(pid, 3)
        Check(!ProcessExist(pid), "Worker did not stop")
        loop 3 {
            manager.StartWorker()
            oldPid := manager.worker.pid
            manager.StopWorker()
            manager.StartWorker() ; 不手动等待，验证快速关开不会误报重复进程。
            pid := manager.worker.pid
            Check(manager.WorkerWindow() && !ProcessExist(oldPid), "Quick restart left the old worker running")
            manager.StopWorker()
            ProcessWaitClose(pid, 3)
            Check(!ProcessExist(pid), "Quick restart worker did not stop")
        }
    } finally {
        manager.StopWorker()
        if pid && ProcessExist(pid)
            ProcessClose(pid)
        if FileExist(path)
            FileDelete(path)
    }
}

class CommitFixtureToolbox extends Toolbox {
    Apply(settings) {
        if settings["FontSize"] = 13
            throw Error("Simulated module start failure")
        super.Apply(settings)
    }
}

TestManagerCommit() {
    path := (A_ScriptDir "\output") "\ahk-manager-test-" DllCall("GetCurrentProcessId") ".ini"
    settings := ToolboxSettings.Defaults()
    settings["WindowEnabled"] := settings["HotkeysEnabled"] := settings["RetryEnabled"] := 0
    manager := CommitFixtureToolbox(settings, path)
    try {
        manager.Start()
        changed := settings.Clone(), changed["FontSize"] := 14
        manager.Commit(changed)
        Check(ToolboxSettings.Load(path)["FontSize"] = 14, "Manager did not save new settings")
        changed := changed.Clone(), changed["FontSize"] := 13, rejected := false
        try manager.Commit(changed)
        catch
            rejected := true
        Check(rejected && manager.settings["FontSize"] = 14, "Failed apply changed active settings")
        Check(ToolboxSettings.Load(path)["FontSize"] = 14, "Failed apply overwrote last working settings")
        external := ToolboxSettings.Load(path)
        external["FontSize"] := 15
        ToolboxSettings.Save(external, path)
        rejected := false
        try manager.Commit(manager.settings.Clone())
        catch
            rejected := true
        Check(rejected && ToolboxSettings.Load(path)["FontSize"] = 15, "Stale settings overwrote an external edit")
    } finally {
        if FileExist(path)
            FileDelete(path)
    }
}


