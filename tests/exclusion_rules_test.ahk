#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#Include %A_ScriptDir%\..\src\dialog_rescaler.ahk

; 仅创建自己的隐藏控件树；不运行字体调整，不操作用户窗口。
DetectHiddenWindows(true)
SetTitleMatchMode(2)
host := Gui(, "Rule fixture")
try {
    parent := MakeControl("Static", 100, host.Hwnd)
    MakeControl("Static", 271, parent)
    button := MakeControl("Button", 272, parent)
    CheckMatch("Static{271} > Button@272", true)
    CheckMatch("Static{271} > Button@273", false)
    CheckMatch(":root{271}", false)
    context := {}
    early := WindowExclusionRule({ Name: "early", Window: "", Scope: "all", Features: ":root{12320}`nButton" })
    Assert(!early.Call(host.Hwnd, context) && !context.HasOwnProp("controls"),
    "Failed root predicate still enumerated children")
    CheckMatch(":root{100}`nButton@272", true)
    CheckMatch("OtherClass | Button@272", true)
    CheckMatch("Button*", true)
    CheckMatch("Butto", false)
    CheckMatch(":root > Button@272", false)
    CheckMatch(":root > Static@100 > Button@272", true)
    for invalid in ["Button@abc", "Button{1,}", "Button |", "But*ton", "Button@999999"] {
        rejected := false
        try WindowExclusionRule({ Name: "bad", Window: "", Features: invalid, Scope: "all" })
        catch
            rejected := true
        Assert(rejected, "Invalid expression accepted: " invalid)
    }
    defaults := DefaultExclusionRules()
    combo := MakeControl("ComboBox", 1136, host.Hwnd)
    fileName := MakeControl("Edit", 1152, host.Hwnd)
    CheckMatch(":root{1148/1152}`n:root > ComboBox*@1136", true)
    DllCall("DestroyWindow", "Ptr", fileName)
    CheckMatch(":root{1148/1152}`n:root > ComboBox*@1136", false)
    MakeControl("Static", 12320, host.Hwnd)
    page := MakeControl("#32770", 200, host.Hwnd)
    MakeControl("Static", 13057, page)
    name := MakeControl("Edit", 102, page)
    CheckDefault(1, true)
    DllCall("DestroyWindow", "Ptr", name)
    CheckDefault(1, false)

    ; 用真实 DirectUI 类名验证删除规则确实放行，但不实际缩放。
    instance := DllCall("GetModuleHandleW", "Ptr", 0, "Ptr")
    wc := Buffer(80, 0), cls := "DirectUIHWND"
    NumPut("UInt", 80, wc)
    DllCall("GetClassInfoExW", "Ptr", 0, "Str", "Static", "Ptr", wc)
    NumPut("Ptr", instance, wc, 24), NumPut("Ptr", StrPtr(cls), wc, 64)
    Assert(DllCall("RegisterClassExW", "Ptr", wc, "UShort"), "Class registration failed")
    direct := MakeControl(cls, 500, parent, instance)
    RescaleNativePercent := 0
    Assert(HasRescaleDirectUI(host.Hwnd), "Hidden nested DirectUI not detected")
    Assert(IsRescaleExcludedWindow(host.Hwnd, "legacy"), "Legacy scope missing")
    Assert(!IsRescaleExcludedWindow(host.Hwnd), "Legacy rule blocked native scope")
    Assert(!IsAutomaticRescaleWindow(host.Hwnd, (*) => true), "Initial rule did not exclude")
    ; 同一窗口同时满足“文件选择框”和 DirectUI 时，删掉前者仍被后者排除。
    redundant := WindowExclusionRule({ Name: "Picker fixture", Window: "ahk_id " host.Hwnd, Features: "DirectUIHWND",
        Scope: "all" })
    RescaleBlacklist.Push(redundant)
    Assert(!IsAutomaticRescaleWindow(host.Hwnd, (*) => true), "Overlapping rule failed")
    RescaleBlacklist.Pop()
    Assert(!IsAutomaticRescaleWindow(host.Hwnd, (*) => true), "Removing overlap unexpectedly bypassed DirectUI")
    RescaleBlacklist := []
    Assert(IsAutomaticRescaleWindow(host.Hwnd, (*) => true), "Deleted rule still excluded window")
    DllCall("DestroyWindow", "Ptr", direct)
    DllCall("UnregisterClassW", "Str", cls, "Ptr", instance)
    FileAppend("PASS: control classes, IDs, AND/OR, parent/child, default predicates, scope and deletion`n", "*")
} catch as err {
    FileAppend("FAIL: " err.Message "`n" err.Stack "`n", "*")
    ExitApp(1)
} finally {
    host.Destroy()
}
ExitApp()

MakeControl(cls, id, parent, instance := 0) {
    hwnd := DllCall("CreateWindowExW", "UInt", 0, "Str", cls, "Str", "", "UInt", 0x40000000,
        "Int", 0, "Int", 0, "Int", 50, "Int", 20, "Ptr", parent, "Ptr", id, "Ptr", instance, "Ptr", 0, "Ptr")
    Assert(hwnd, "Could not create fixture control: " cls)
    return hwnd
}
CheckMatch(features, expected) {
    rule := WindowExclusionRule({ Name: "fixture", Window: "", Features: features, Scope: "all" })
    Assert(rule.Call(host.Hwnd) = expected, "Unexpected match: " features)
}
CheckDefault(index, expected) {
    rule := defaults[index].Clone()
    rule.Window := "" ; 测试宿主是隐藏的 AHK GUI，控件特征保持初始值。
    Assert(WindowExclusionRule(rule).Call(host.Hwnd) = expected, "Initial rule mismatch: " rule.Name)
}
Assert(value, message) {
    if !value
        throw Error(message)
}

