#Requires AutoHotkey v2.0

; 条件是数据，不执行用户代码。每行必须满足；| 表示任选，> 表示直接父子。
DefaultExclusionRules() => [
    ; 四种特征均有独立命中的属性页；共同的窗口/页签条件只检查一次。
    {Name: "文件属性窗口", Window: "ahk_class #32770", Features: ":root{12320}`n#32770{13057,13156/102} | CHECKLIST_ACLUI | *{101,103} > NativeFontCtl | *{271} > SysLink@272", Scope: "all"},
    {Name: "DirectUI 控件", Window: "", Features: "DirectUIHWND", Scope: "legacy"}
]

CompileExclusionRules(rules) {
    result := []
    for rule in rules
        result.Push(WindowExclusionRule(rule))
    return result
}

class WindowExclusionRule {
    __New(rule) {
        for field in ["Name", "Window", "Scope"] {
            if RegExMatch(rule.%field%, "[\r\n]")
                throw ValueError("规则字段不能包含换行：" field)
        }
        if Trim(rule.Name) = "" || (Trim(rule.Window) = "" && Trim(rule.Features) = "")
            throw ValueError("规则需要名称，且至少填写窗口匹配或控件特征")
        if rule.Scope != "all" && rule.Scope != "legacy"
            throw ValueError("规则范围必须为 all 或 legacy")
        if StrSplit(rule.Features, "`n").Length > 50 || StrLen(rule.Features) > 16000
            throw ValueError("每条规则最多50行控件条件、16000个字符")
        this.Window := Trim(rule.Window)
        this.Scope := rule.Scope
        this.lines := []
        for line in StrSplit(rule.Features, "`n", "`r") {
            if Trim(line) = ""
                continue
            alternatives := []
            for expression in StrSplit(line, "|") {
                if Trim(expression) = ""
                    throw ValueError("| 两侧都需要填写控件条件")
                path := []
                for part in StrSplit(expression, ">") {
                    part := Trim(part)
                    if !RegExMatch(part, "^([^@{}>]+?)(?:@(\d+))?(?:\{([0-9,/]+)\})?$", &match)
                        throw ValueError("控件条件格式无效：" part)
                    cls := Trim(match[1]), children := []
                    if cls = "" || (match[2] != "" && Integer(match[2]) > 65535)
                        throw ValueError("控件类名或 ID 无效：" part)
                    if InStr(cls, "*") && cls != "*" && !RegExMatch(cls, "^[^*]+\*$")
                        throw ValueError("类名只支持末尾 *，例如 ComboBox*")
                    if match[3] != "" {
                        for group in StrSplit(match[3], ",") {
                            if !RegExMatch(group, "^\d+(?:/\d+)*$")
                                throw ValueError("子控件 ID 分组无效：" group)
                            ids := StrSplit(group, "/")
                            for id in ids {
                                if !RegExMatch(id, "^\d+$") || Integer(id) > 65535
                                    throw ValueError("子控件 ID 无效：" id)
                            }
                            children.Push(ids)
                        }
                    }
                    path.Push({Class: cls, Id: match[2], Children: children})
                }
                alternatives.Push(path)
            }
            this.lines.Push(alternatives)
        }
    }

    Call(hwnd, context := unset) {
        if this.Window != "" && WinExist(this.Window " ahk_id " hwnd) != hwnd
            return false
        if !this.lines.Length
            return true
        if !IsSet(context)
            context := {}
        for alternatives in this.lines {
            found := false
            for path in alternatives {
                if path.Length = 1 && path[1].Class = ":root" {
                    found := this.MatchNode(hwnd, hwnd, path[1])
                } else {
                    ; 根窗口条件不满足时直接结束，避免无意义地遍历整个控件树。
                    if !context.HasOwnProp("controls")
                        context.controls := WinGetControlsHwnd(hwnd)
                    for control in context.controls {
                        if this.MatchPath(control, hwnd, path) {
                            found := true
                            break
                        }
                    }
                }
                if found
                    break
            }
            if !found
                return false
        }
        return true
    }

    MatchPath(control, root, path) {
        index := path.Length
        while index {
            if !control || !this.MatchNode(control, root, path[index])
                return false
            if --index {
                if control = root
                    return false
                control := DllCall("GetParent", "Ptr", control, "Ptr")
            }
        }
        return true
    }

    MatchNode(control, root, node) {
        if node.Class = ":root" {
            if control != root
                return false
        } else if node.Class != "*" {
            cls := WinGetClass(control)
            if SubStr(node.Class, -1) = "*" {
                if SubStr(cls, 1, StrLen(node.Class) - 1) != SubStr(node.Class, 1, -1)
                    return false
            } else if cls != node.Class
                return false
        }
        if node.Id != "" && DllCall("GetDlgCtrlID", "Ptr", control) != Integer(node.Id)
            return false
        for ids in node.Children {
            found := false
            for id in ids {
                if DllCall("GetDlgItem", "Ptr", control, "Int", Integer(id), "Ptr") {
                    found := true
                    break
                }
            }
            if !found
                return false
        }
        return true
    }
}

