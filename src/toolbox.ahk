#Requires AutoHotkey v2.0 64-bit
#Include %A_LineFile%\..\dialog_rescaler.ahk
#Include %A_LineFile%\..\hotkeys.ahk

class Toolbox {
    __New(settings, settingsPath := ToolboxSettings.Path) {
        this.settings := settings
        this.settingsPath := settingsPath
        this.savedText := this.ReadSavedText()
        this.worker := 0
        this.window := 0
        this.controls := Map()
        this.editor := 0
    }

    Start() {
        A_IconTip := "AHK 工具箱"
        A_TrayMenu.Delete()
        A_TrayMenu.Add("设置…", ObjBindMethod(this, "ShowSettings"))
        A_TrayMenu.Default := "设置…"
        A_TrayMenu.ClickCount := 2
        A_TrayMenu.Add()
        for key, label in this.Switches
            A_TrayMenu.Add(label, ObjBindMethod(this, "Toggle", key))
        A_TrayMenu.Add()
        A_TrayMenu.Add("重新加载", (*) => Reload())
        A_TrayMenu.Add("打开脚本目录", (*) => ShellRun(ToolboxSettings.Directory))
        A_TrayMenu.Add("打开配置目录", (*) => this.OpenConfigDirectory())
        nativeMenu := Menu()
        nativeMenu.AddStandard()
        A_TrayMenu.Add("AHK 原生菜单", nativeMenu)
        A_TrayMenu.Add()
        A_TrayMenu.Add("退出工具箱", (*) => ExitApp())
        OnExit(ObjBindMethod(this, "StopWorker"))
        this.Apply(this.settings)
        this.UpdateMenu()
        Persistent()
    }

    Switches => Map("WindowEnabled", "窗口字体放大", "HotkeysEnabled", "应用快捷键", "RetryEnabled", "Codex 自动重试")

    Apply(settings) {
        global RescaleNativePercent, RescaleLegacyEnabled, RescaleFontName, RescaleFontSize, RescaleBlacklist
        ConfigureAppHotkeys(settings)
        RescaleNativePercent := Number(settings["NativePercent"])
        RescaleLegacyEnabled := settings["LegacyEnabled"]
        RescaleFontName := settings["FontName"]
        RescaleFontSize := Number(settings["FontSize"])
        RescaleBlacklist := CompileExclusionRules(settings["ExclusionRules"])
        if settings["WindowEnabled"]
            StartDialogRescaler()
        else
            StopDialogRescaler()
        if settings["RetryEnabled"]
            this.StartWorker()
        else
            this.StopWorker()
    }

    Commit(settings) {
        if RescaleBusy
            throw Error("正在调整窗口，请稍后再保存设置。")
        if !(this.ReadSavedText() == this.savedText)
            throw Error("配置文件已在外部更改。请关闭设置窗口并重载工具箱，再修改设置，避免覆盖新配置。")
        previous := this.settings
        ; Save 自身完成校验，避免同一次提交重复解析所有规则。
        ToolboxSettings.Save(settings, this.settingsPath)
        try this.Apply(settings)
        catch as err {
            ToolboxSettings.Save(previous, this.settingsPath)
            this.savedText := this.ReadSavedText()
            try this.Apply(previous)
            throw err
        }
        this.settings := settings
        this.savedText := this.ReadSavedText()
        this.UpdateMenu()
    }

    Toggle(key, *) {
        settings := ToolboxSettings.Copy(this.settings)
        settings[key] := !settings[key]
        try {
            this.Commit(settings)
            if this.window
                this.CloseSettings()
        } catch as err {
            MsgBox(err.Message, "未能更改设置", "Icon!")
        }
    }

    UpdateMenu() {
        for key, label in this.Switches {
            if this.settings[key]
                A_TrayMenu.Check(label)
            else
                A_TrayMenu.Uncheck(label)
        }
    }

    StartWorker() {
        if this.worker && this.worker.HasOwnProp("stopping") {
            hidden := DetectHiddenWindows(true)
            try {
                if hwnd := this.WorkerWindow()
                    WinWaitClose(hwnd, , 2)
                if this.WorkerWindow()
                    throw Error("自动重试正在结束上一轮检查，请稍后再开启。")
                this.worker := 0
            } finally {
                DetectHiddenWindows(hidden)
            }
        }
        if this.WorkerWindow() {
            if !DllCall("PostMessageW", "Ptr", this.worker.hwnd, "UInt", 0x8052, "UPtr", 1, "Ptr", A_ScriptHwnd)
                throw OSError(A_LastError, , "未能更新自动重试设置")
            return
        }
        workerPath := ToolboxSettings.Directory "\src\codex_auto_retry.ahk"
        hidden := DetectHiddenWindows(true)
        try {
            if existing := WinExist(workerPath " ahk_class AutoHotkey") {
                parent := DllCall("GetPropW", "Ptr", existing, "Str", "AHK.CodexRetry.Parent", "Ptr")
                ; Reload 后旧主进程已经退出，给正在关闭的旧工作进程一点收尾时间。
                if parent && !DllCall("IsWindow", "Ptr", parent)
                    WinWaitClose(existing, , 2)
                if DllCall("IsWindow", "Ptr", existing)
                    throw Error("自动重试脚本已经单独运行，请先从它的托盘退出，再在工具箱中开启。")
            }
            RunUnelevated(A_ProgramFiles "\AutoHotkey\v2\AutoHotkey64.exe", '"' workerPath '" --managed '
                DllCall("GetCurrentProcessId") ' ' A_ScriptHwnd ' "' this.settingsPath '"', ToolboxSettings.Directory, &pid)
            this.worker := {pid: pid, hwnd: 0}
            deadline := A_TickCount + 3000
            while ProcessExist(pid) && A_TickCount < deadline {
                if hwnd := WinExist("ahk_class AutoHotkey ahk_pid " pid) {
                    if DllCall("GetPropW", "Ptr", hwnd, "Str", "AHK.CodexRetry.Parent", "Ptr") = A_ScriptHwnd {
                        if IsProcessElevated(pid) {
                            ProcessClose(pid)
                            this.worker := 0
                            throw Error("自动重试意外取得管理员权限，已停止该进程")
                        }
                        this.worker.hwnd := hwnd
                        return
                    }
                }
                Sleep(20)
            }
            ; 仅终止刚刚由本次 Run 创建的进程，避免留下未受管理的定时器。
            if ProcessExist(pid)
                ProcessClose(pid)
            this.worker := 0
            throw Error("自动重试进程未能启动，请检查脚本或设置。")
        } finally {
            DetectHiddenWindows(hidden)
        }
    }

    WorkerWindow() {
        if !this.worker || !this.worker.hwnd
            return 0
        hwnd := this.worker.hwnd
        return DllCall("IsWindow", "Ptr", hwnd)
            && DllCall("GetPropW", "Ptr", hwnd, "Str", "AHK.CodexRetry.Parent", "Ptr") = A_ScriptHwnd ? hwnd : 0
    }

    StopWorker(exitReason := "", *) {
        if hwnd := this.WorkerWindow() {
            ; 异步退出，不等待 UIA；即使工具箱异常关闭，工作进程也会检测父进程退出。
            if !DllCall("PostMessageW", "Ptr", hwnd, "UInt", 0x8052, "UPtr", 0, "Ptr", A_ScriptHwnd) {
                stopErrorCode := A_LastError
                if !this.WorkerWindow() {
                    this.worker := 0
                    return
                }
                if exitReason != "" {
                    OutputDebug("退出时无法通知自动重试：" stopErrorCode)
                    return ; 父进程句柄仍能使工作进程自行退出，不用异常框打断退出。
                }
                throw OSError(stopErrorCode, , "未能通知自动重试停止")
            }
            this.worker.stopping := true
        } else
            this.worker := 0
    }

    ReadSavedText() => FileExist(this.settingsPath) ? FileRead(this.settingsPath) : ""

    OpenConfigDirectory() {
        SplitPath(this.settingsPath, , &directory)
        DirCreate(directory)
        ShellRun(directory)
    }

    ShowSettings(*) {
        if this.window {
            this.window.Show()
            return
        }
        this.draft := ToolboxSettings.Copy(this.settings)
        panel := this.window := Gui(, "AHK 工具箱设置")
        panel.SetFont("s12", "Microsoft YaHei UI")
        panel.MarginX := panel.MarginY := 20
        tabs := panel.AddTab3("w588 h438", ["窗口字体", "排除规则", "快捷键", "Codex 重试"])
        tabs.UseTab(1)
        this.Checkbox(panel, "WindowEnabled", "启用窗口字体放大", "x38 y70")
        this.Field(panel, "NativePercent", "原生 DPI（%，0 关闭）", 113)
        this.Checkbox(panel, "LegacyEnabled", "启用经典 Win32 字体兜底", "x38 y158")
        this.Field(panel, "FontName", "字体", 199)
        this.Field(panel, "FontSize", "字号（pt）", 245)
        panel.AddText("x38 y305 w542 BackgroundTrans", "不兼容的程序可在“排除规则”页添加。`n修改字体或 DPI 后，请重新打开目标窗口。")
        tabs.UseTab(3)
        this.Checkbox(panel, "HotkeysEnabled", "启用应用快捷键", "x38 y70")
        this.shortcutList := panel.AddListView("x38 y112 w545 h216 -Multi NoSortHdr", ["应用", "快捷键"])
        this.shortcutList.ModifyCol(1, 340)
        this.shortcutList.ModifyCol(2, 170)
        this.ListButtons(panel, "shortcuts", 342)
        panel.AddText("x38 y394 w542 BackgroundTrans", "# Win，^ Ctrl，! Alt，+ Shift；例如 #w。`n双击编辑；自定义应用再次按键时最小化。")
        tabs.UseTab(4)
        this.Checkbox(panel, "RetryEnabled", "启用 Codex 自动重试", "x38 y70")
        this.Field(panel, "RetryInterval", "检查间隔（秒）", 122)
        panel.AddText("x38 y182 w538 BackgroundTrans", "仅调用输入框“继续”按钮，不点击“停止”。`n后台、最小化、托盘隐藏时均尝试检查。`n不切换聊天，不恢复窗口，不移动鼠标。`n同一个按钮不会持续重复点击。")
        panel.AddText("x38 y300 w538 BackgroundTrans", "隐藏后仍提供按钮接口时，才能后台重试。`n开启时使用独立进程，关闭时退出。`n保存后等待下一个检查周期，不立即点击。")
        tabs.UseTab(2)
        panel.AddText("x38 y70 w542 BackgroundTrans", "列表中的规则均生效；不需要的条目可以删除。")
        this.ruleList := panel.AddListView("x38 y112 w545 h216 -Multi NoSortHdr", ["规则", "类型"])
        this.ruleList.ModifyCol(1, 350)
        this.ruleList.ModifyCol(2, 165)
        this.ListButtons(panel, "rules", 342)
        panel.AddText("x38 y394 w542 BackgroundTrans", "可新增程序或窗口排除；保存后重开目标窗口。`n复杂控件条件保留在配置文件，不放进日常界面。")
        this.RefreshLists()
        tabs.UseTab()
        panel.AddText("xm y474 w372", "关闭本窗口后，已启用的功能仍在托盘运行。")
        panel.AddButton("x408 y468 w94 Default", "保存").OnEvent("Click", ObjBindMethod(this, "SavePanel"))
        panel.AddButton("x514 y468 w94", "取消").OnEvent("Click", ObjBindMethod(this, "CloseSettings"))
        panel.OnEvent("Close", ObjBindMethod(this, "CloseSettings"))
        panel.OnEvent("Escape", ObjBindMethod(this, "CloseSettings"))
        panel.Show("w626 h522")
    }

    Checkbox(panel, key, label, options) {
        this.controls[key] := panel.AddCheckbox(options, label)
        this.controls[key].Value := this.settings[key]
    }

    Field(panel, key, label, y) {
        panel.AddText("x38 y" (y + 5) " w230 BackgroundTrans", label)
        this.controls[key] := panel.AddEdit("x276 y" y " w307", this.settings[key])
    }

    ListButtons(panel, kind, y) {
        for index, label in ["新增", "编辑", "删除"]
            panel.AddButton("x" (38 + (index - 1) * 104) " y" y " w94", label).OnEvent("Click",
                ObjBindMethod(this, index = 3 ? "DeleteEntry" : "EditEntry", kind, index = 1))
        list := kind = "rules" ? this.ruleList : this.shortcutList
        list.OnEvent("DoubleClick", (_, row) => row && this.EditEntry(kind, false))
    }

    RefreshLists() {
        this.ruleList.Delete()
        this.ruleItems := this.draft["ExclusionRules"]
        for rule in this.ruleItems
            this.ruleList.Add(, rule.Name, rule.Features = "" ? "窗口匹配" : "控件特征")
        this.shortcutList.Delete()
        this.shortcutItems := []
        for entry in AppHotkeyEntries(this.draft) {
            if entry.Key != "" {
                this.shortcutItems.Push(entry)
                this.shortcutList.Add(, entry.Name, entry.Key)
            }
        }
    }

    EditEntry(kind, adding, *) {
        list := kind = "rules" ? this.ruleList : this.shortcutList
        row := adding ? 0 : list.GetNext()
        if !adding && !row
            return
        if kind = "rules" {
            this.EditRule(row)
            return
        }
        id := row ? this.shortcutItems[row].Id : 0
        fields := [["Name", "名称", row ? this.shortcutItems[row].Name : ""],
                ["Key", "快捷键", row ? this.shortcutItems[row].Key : ""]]
        if kind = "shortcuts" && IsInteger(id)
            fields.Push(["Program", "程序", row ? this.shortcutItems[row].Program : ""])
        this.ShowEntryEditor(adding ? "新增快捷键" : "编辑快捷键", fields, kind, id)
    }

    ; 两类条目共用输入框、按钮和关闭流程，避免维护两套弹窗代码。
    ShowEntryEditor(title, fields, kind, id, width := 496, note := "") {
        dialog := this.editor := Gui("+Owner" this.window.Hwnd " +OwnDialogs", title)
        dialog.SetFont("s12", "Microsoft YaHei UI")
        this.entryControls := Map()
        for index, field in fields {
            y := 20 + (index - 1) * 44
            dialog.AddText("x20 y" (y + 5) " w96", field[2])
            this.entryControls[field[1]] := dialog.AddEdit("x126 y" y " w" (width - (field[1] = "Program" ? 234 : 146)), field[3])
            if kind = "shortcuts" && field[1] = "Name" && !IsInteger(id)
                this.entryControls[field[1]].Enabled := false
            if field[1] = "Program"
                dialog.AddButton("x" (width - 98) " y" y " w78", "选择…").OnEvent("Click", ObjBindMethod(this, "PickProgram"))
        }
        y := fields.Length * 44 + 30
        if note != "" {
            dialog.AddText("x20 y" y " w" (width - 40), note)
            y += 74
        }
        dialog.AddButton("x" (width - 208) " y" y " w88 Default", "确定").OnEvent("Click", ObjBindMethod(this, "AcceptEntry", kind, id))
        dialog.AddButton("x" (width - 108) " y" y " w88", "取消").OnEvent("Click", ObjBindMethod(this, "CloseEntry"))
        dialog.OnEvent("Close", ObjBindMethod(this, "CloseEntry"))
        dialog.OnEvent("Escape", ObjBindMethod(this, "CloseEntry"))
        this.window.Opt("+Disabled")
        dialog.Show("w" width " h" (y + 58))
    }

    PickProgram(*) {
        if path := FileSelect(1, this.entryControls["Program"].Value, "选择程序", "程序 (*.exe)")
            this.entryControls["Program"].Value := path
    }

    EditRule(row) {
        rule := row ? this.ruleItems[row] : {Name: "", Window: "", Features: "", Scope: "all"}
        note := rule.Features = ""
            ? "窗口匹配示例：ahk_exe example.exe 或窗口标题。"
            : "此条目的控件识别条件会保留。`n高级条件和作用范围在 toolbox.ini 中修改。"
        this.ShowEntryEditor(row ? "编辑排除规则" : "新增排除规则",
            [["Name", "名称", rule.Name], ["Window", "窗口匹配", rule.Window]], "rules", row, 590, note)
    }

    AcceptEntry(kind, id, *) {
        candidate := ToolboxSettings.Copy(this.draft)
        try {
            if kind = "rules" {
                rule := id ? candidate["ExclusionRules"][id].Clone() : {Features: "", Scope: "all"}
                rule.Name := Trim(this.entryControls["Name"].Value)
                rule.Window := Trim(this.entryControls["Window"].Value)
                if id
                    candidate["ExclusionRules"][id] := rule
                else
                    candidate["ExclusionRules"].Push(rule)
            } else if !IsInteger(id) {
                candidate[id] := this.entryControls["Key"].Value
            } else {
                entry := {Name: this.entryControls["Name"].Value, Key: this.entryControls["Key"].Value,
                    Program: this.entryControls["Program"].Value}
                if id
                    candidate["CustomHotkeys"][id] := entry
                else
                    candidate["CustomHotkeys"].Push(entry)
            }
            ToolboxSettings.Validate(candidate)
            this.draft := candidate
            this.RefreshLists()
            this.CloseEntry()
        } catch as err {
            MsgBox(err.Message, "条目未修改", "Icon!")
        }
    }

    DeleteEntry(kind, *) {
        list := kind = "rules" ? this.ruleList : this.shortcutList
        if !row := list.GetNext()
            return
        if kind = "rules" {
            this.draft["ExclusionRules"].RemoveAt(row)
        } else {
            id := this.shortcutItems[row].Id
            if IsInteger(id)
                this.draft["CustomHotkeys"].RemoveAt(id)
            else
                this.draft[id] := ""
        }
        this.RefreshLists()
    }

    CloseEntry(*) {
        if this.editor {
            this.window.Opt("-Disabled")
            this.editor.Destroy()
            this.editor := 0
            this.entryControls.Clear()
        }
    }

    SavePanel(*) {
        settings := ToolboxSettings.Copy(this.draft)
        for key, control in this.controls
            settings[key] := control.Value
        try {
            this.Commit(settings)
            this.CloseSettings()
        } catch as err {
            MsgBox(err.Message, "设置未保存", "Icon!")
        }
    }

    CloseSettings(*) {
        this.CloseEntry()
        if this.window
            this.window.Destroy()
        this.window := 0
        this.controls.Clear()
        this.draft := 0
        this.ruleList := this.shortcutList := 0
        this.ruleItems := this.shortcutItems := []
    }

}

