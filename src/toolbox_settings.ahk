#Requires AutoHotkey v2.0 64-bit
#Include %A_LineFile%\..\exclusion_rules.ahk

; 一个 INI 保存所有模块的设置；不在后台轮询文件。
class ToolboxSettings {
    ; 代码和数据统一位于 D 盘工程目录；data 单独保留普通用户写入权限。
    static Directory := RegExReplace(A_LineFile, "\\[^\\]+\\[^\\]+$")
    static ConfigDirectory := this.Directory "\data"
    static Path := this.ConfigDirectory "\toolbox.ini"

    static Defaults() => Map(
        "WindowEnabled", 1, "HotkeysEnabled", 1, "RetryEnabled", 0,
        "NativePercent", 175, "LegacyEnabled", 1, "FontName", "Microsoft YaHei", "FontSize", 12,
        "TerminalKey", "#w", "EverythingKey", "#s", "TaskManagerKey", "#c",
        "EverythingPath", "C:\Program Files\Everything\Everything.exe",
        "RetryInterval", 60, "RetryTarget", "ahk_exe ChatGPT.exe",
        "RetryName", "继续", "RetryClass", "size-token-button-composer", "ExclusionRules", DefaultExclusionRules(), "CustomHotkeys", [])

    static Load(path := this.Path) {
        settings := this.Defaults()
        for key, fallback in settings {
            if key != "ExclusionRules" && key != "CustomHotkeys"
                settings[key] := IniRead(path, "Toolbox", key, fallback)
        }
        count := IniRead(path, "Hotkeys", "Count", 0)
        if !IsInteger(count) || count < 0 || count > 100
            throw ValueError("自定义快捷键数量范围为 0～100")
        loop count
            settings["CustomHotkeys"].Push({Name: IniRead(path, "Hotkey" A_Index, "Name", ""),
                Key: IniRead(path, "Hotkey" A_Index, "Key", ""), Program: IniRead(path, "Hotkey" A_Index, "Program", "")})
        count := IniRead(path, "Rules", "Count", "missing")
        if count = "missing" {
            ; 旧配置只有自定义字符串：保留它们，并且仅在迁移时加入初始规则。
            for line in StrSplit(IniRead(path, "Exclusions", , ""), "`n", "`r") {
                if position := InStr(line, "=") {
                    value := Trim(SubStr(line, position + 1))
                    if value != ""
                        settings["ExclusionRules"].Push({Name: value, Window: value, Features: "", Scope: "all"})
                }
            }
        } else {
            if !IsInteger(count) || count < 0 || count > 200
                throw ValueError("排除规则数量范围为 0～200")
            settings["ExclusionRules"] := []
            loop count {
                section := "Rule" A_Index
                rule := {Name: IniRead(path, section, "Name", ""), Window: IniRead(path, section, "Window", ""),
                    Scope: IniRead(path, section, "Scope", "all"), Features: ""}
                lines := IniRead(path, section, "Lines", 0)
                if !IsInteger(lines) || lines < 0 || lines > 50
                    throw ValueError("每条规则最多50行控件条件")
                loop lines
                    rule.Features .= (A_Index > 1 ? "`n" : "") IniRead(path, section, "Condition" A_Index, "")
                settings["ExclusionRules"].Push(rule)
            }
        }
        return this.Validate(settings)
    }

    static Validate(settings) {
        for key, value in settings {
            if key != "ExclusionRules" && key != "CustomHotkeys" && RegExMatch(value, "[\r\n]")
                throw ValueError("设置不能包含换行：" key)
        }
        for key in ["WindowEnabled", "HotkeysEnabled", "RetryEnabled", "LegacyEnabled"] {
            if !IsInteger(settings[key]) || (settings[key] != 0 && settings[key] != 1)
                throw ValueError("开关必须为 0 或 1：" key)
            settings[key] := Integer(settings[key])
        }
        dpi := settings["NativePercent"]
        if !IsInteger(dpi) || (dpi != 0 && (dpi < 100 || dpi > 500 || Mod(dpi, 25)))
            throw ValueError("原生 DPI 请填写 0，或 100～500 之间的 25% 档位")
        size := settings["FontSize"]
        if !IsNumber(size) || size < 8 || size > 24
            throw ValueError("字号范围为 8～24pt")
        seconds := settings["RetryInterval"]
        if !IsInteger(seconds) || seconds < 15 || seconds > 3600
            throw ValueError("检查间隔范围为 15～3600 秒")
        for key in ["FontName", "EverythingPath", "RetryTarget", "RetryName", "RetryClass"] {
            settings[key] := Trim(settings[key])
            if settings[key] = "" || InStr(settings[key], Chr(34))
                throw ValueError("设置不能为空或包含双引号：" key)
        }
        if StrLen(settings["FontName"]) > 31
            throw ValueError("字体名不能超过31个字符")
        used := Map("#f11", true)
        for key in ["TerminalKey", "EverythingKey", "TaskManagerKey"] {
            value := NormalizeToolboxHotkey(settings[key])
            if value != "" && used.Has(value)
                throw ValueError("快捷键重复，或占用了字体工具的 Win+F11：" settings[key])
            if value != ""
                used[value] := true
            settings[key] := value
        }
        if !(settings["CustomHotkeys"] is Array) || settings["CustomHotkeys"].Length > 100
            throw ValueError("最多添加100个自定义快捷键")
        for entry in settings["CustomHotkeys"] {
            for field in ["Name", "Key", "Program"] {
                entry.%field% := Trim(entry.%field%)
                if entry.%field% = "" || RegExMatch(entry.%field%, '[\r\n"]')
                    throw ValueError("名称、快捷键和程序不能为空，也不能包含换行或双引号")
            }
            entry.Key := NormalizeToolboxHotkey(entry.Key)
            if used.Has(entry.Key)
                throw ValueError("快捷键重复，或占用了 Win+F11：" entry.Key)
            if !RegExMatch(entry.Program, "i)\.exe$")
                throw ValueError("请选择 exe 程序，自定义绑定不接受命令行参数")
            used[entry.Key] := true
        }
        if !(settings["ExclusionRules"] is Array) || settings["ExclusionRules"].Length > 200
            throw ValueError("最多保存200条排除规则")
        CompileExclusionRules(settings["ExclusionRules"])
        return settings
    }

    static Copy(settings) {
        result := settings.Clone()
        for key in ["CustomHotkeys", "ExclusionRules"] {
            result[key] := []
            for entry in settings[key]
                result[key].Push(entry.Clone())
        }
        return result
    }

    static Save(settings, path := this.Path) {
        this.Validate(settings)
        SplitPath(path, , &directory)
        DirCreate(directory)
        text := "[Toolbox]`r`n"
        for key, value in settings {
            if key != "ExclusionRules" && key != "CustomHotkeys"
                text .= key "=" value "`r`n"
        }
        text .= "`r`n[Hotkeys]`r`nCount=" settings["CustomHotkeys"].Length "`r`n"
        for index, entry in settings["CustomHotkeys"]
            text .= "`r`n[Hotkey" index "]`r`nName=" entry.Name "`r`nKey=" entry.Key "`r`nProgram=" entry.Program "`r`n"
        text .= "`r`n[Rules]`r`nCount=" settings["ExclusionRules"].Length "`r`n"
        for index, rule in settings["ExclusionRules"] {
            lines := rule.Features = "" ? [] : StrSplit(rule.Features, "`n", "`r")
            text .= "`r`n[Rule" index "]`r`nName=" rule.Name "`r`nWindow=" rule.Window "`r`nScope=" rule.Scope "`r`n"
            text .= "Lines=" lines.Length "`r`n"
            for lineIndex, line in lines
                text .= "Condition" lineIndex "=" line "`r`n"
        }
        temporary := path "." DllCall("GetCurrentProcessId") ".tmp"
        try {
            file := FileOpen(temporary, "w", "UTF-16")
            try file.Write(text)
            finally file.Close()
            FileMove(temporary, path, true)
        } finally {
            if FileExist(temporary)
                FileDelete(temporary)
        }
    }
}

NormalizeToolboxHotkey(value) {
    value := StrLower(Trim(value))
    if value = ""
        return "" ; 留空表示不分配此快捷键。
    if !RegExMatch(value, "^([#^!+]*)([a-z0-9]+)$", &match) || !GetKeyVK(match[2])
        throw ValueError("快捷键格式无效：" value "（例如 #w 或 ^!w）")
    modifiers := ""
    for symbol in StrSplit("#^!+") {
        if InStr(match[1], symbol)
            modifiers .= symbol
    }
    if modifiers = "" && StrLen(match[2]) = 1
        throw ValueError("字母和数字快捷键需要搭配 Win、Ctrl、Alt 或 Shift")
    return modifiers StrLower(GetKeyName(match[2]))
}
