#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\win32_fonts.ahk
#Include %A_LineFile%\..\window_events.ahk
#Include %A_LineFile%\..\native_dpi.ahk

; 支持原生重排的窗口使用独立 DPI；0 关闭原生路径。范围 100~500%，每档 25%。
global RescaleNativePercent := 175
global RescaleLegacyEnabled := true ; 原生 DPI 不支持时，才对兼容的经典对话框使用字体兜底。
; 以下字体配置仅用于旧式回退，不会叠加到原生 DPI 窗口。
global RescaleFontName := "Microsoft YaHei" ; 微软雅黑
global RescaleFontSize := 12

#Include %A_LineFile%\..\exclusion_rules.ahk
global RescaleBlacklist := CompileExclusionRules(DefaultExclusionRules())

global ScaledHwnds := Map()
global RescaleProcesses := Map()
global RescaleBusy := false
global RescaleFrozen := 0
global RescaleEvents := 0
global RescaleProperty := "AHK.Win32FontRescaler"
global RescaleModeProperty := "AHK.WindowRescale.Mode" ; 1=原生 DPI，2=旧式字体；窗口销毁时由系统移除。
global RescaleOwner := DllCall("GetCurrentProcessId", "UInt")

StartDialogRescaler(pidFilter := 0, acceptWindow := 0) {
    global RescaleEvents
    if RescaleNativePercent && (RescaleNativePercent < 100 || RescaleNativePercent > 500 || Mod(RescaleNativePercent,
        25))
        throw ValueError("原生缩放请设为 0，或 100~500 之间的 25% 档位")
    if IsObject(RescaleEvents) && !RescaleEvents.closed
        return
    for hwnd in ScaledHwnds {
        if !DllCall("IsWindow", "Ptr", hwnd) || !HasRescaleMarker(hwnd)
            ScaledHwnds.Delete(hwnd)
    }
    OnExit CleanupDialogRescaler
    RescaleEvents := RescaleWindowEvents(pidFilter, acceptWindow)
    Hotkey("#F11", RescaleActiveWindow, "On")
    DllCall("SetPropW", "Ptr", A_ScriptHwnd, "Str", "AHK.FontRescaler.Ready", "Ptr", 1)
}

; 暂停监听但保留仍打开窗口的状态，重新开启不会叠加放大。
StopDialogRescaler() {
    if IsObject(RescaleEvents)
        RescaleEvents.Close()
    try Hotkey("#F11", "Off")
    DllCall("RemovePropW", "Ptr", A_ScriptHwnd, "Str", "AHK.FontRescaler.Ready", "Ptr")
}

; Win + F11：处理当前窗口，并显示实际使用的路径或跳过原因。
RescaleActiveWindow(*) {
    hwnd := WinActive("A")
    if !hwnd
        return
    try {
        result := SafeRescaleWindow(hwnd)
        message := result ? (CanRescaleNatively(hwnd) ? "窗口 DPI 已设为 " RescaleNativePercent "%（原生布局）"
            : "已应用旧式字体「" RescaleFontName " " ScaledHwnds[hwnd].fontSize "pt」") : RescaleSkipReason(hwnd)
    } catch as err {
        message := "未能调整窗口：" err.Message
    }
    ToolTip(message)
    SetTimer () => ToolTip(), -2500
}

; 事件回调只按顶层窗口类型筛选，完整排除规则在事件合并后检查。
IsRescaleCandidateWindow(hwnd) {
    cls := WinGetClass(hwnd)
    if (cls != "#32770" && cls != "MMCMainFrame")
    || (WinGetStyle(hwnd) & 0x40000000) || WinGetPID(hwnd) = RescaleOwner
        return false
    ; 标准对话框默认尝试处理，具体排除项由统一黑名单决定。
    if cls = "MMCMainFrame"
        return WinGetProcessName(hwnd) = "mmc.exe" && (CanRescaleNatively(hwnd)
        || RegExMatch(WinGetTitle(hwnd), "i)^(Device Manager|设备管理器)$"))
    return true
}

IsAutomaticRescaleWindow(hwnd, acceptWindow := 0) {
    return (acceptWindow ? acceptWindow : IsRescaleCandidateWindow).Call(hwnd)
    && !IsRescaleExcludedWindow(hwnd)
    && (CanRescaleNatively(hwnd) || (RescaleLegacyEnabled && !IsRescaleExcludedWindow(hwnd, "legacy")))
}

; 查询实际控件树，供诊断使用；是否排除由可编辑规则决定。
HasRescaleDirectUI(hwnd) {
    for child in WinGetControlsHwnd(hwnd) {
        if WinGetClass(child) = "DirectUIHWND"
            return true
    }
    return false
}

IsRescaleExcludedWindow(hwnd, scope := "all") {
    if !RescaleBlacklist.Length
        return false
    mode := SetTitleMatchMode(2)
    hidden := DetectHiddenWindows(true)
    try {
        context := {}
        for rule in RescaleBlacklist {
            if rule is WindowExclusionRule {
                if rule.Scope = scope && rule.Call(hwnd, context)
                    return true
            } else if scope != "all" {
                continue
            } else if IsObject(rule) {
                if rule.Call(hwnd)
                    return true
            } else {
                rule := Trim(rule)
                if rule != "" && WinExist(rule " ahk_id " hwnd) = hwnd
                    return true
            }
        }
        return false
    } finally {
        SetTitleMatchMode(mode)
        DetectHiddenWindows(hidden)
    }
}

SafeRescaleWindow(hwnd, acceptWindow := 0) {
    global RescaleBusy, RescaleFrozen
    if !DllCall("IsWindow", "Ptr", hwnd) || !IsAutomaticRescaleWindow(hwnd, acceptWindow)
        return false
    if RescaleBusy
        throw Error("正在调整另一个窗口，请稍后重试")
    RescaleBusy := true
    previousDpi := 0
    try {
        context := DllCall("GetWindowDpiAwarenessContext", "Ptr", hwnd, "Ptr")
        if context
            previousDpi := DllCall("SetThreadDpiAwarenessContext", "Ptr", context, "Ptr")
        if CanRescaleNatively(hwnd)
            return ApplyNativeRescale(hwnd)
        if DllCall("GetPropW", "Ptr", hwnd, "Str", RescaleModeProperty, "Ptr") = 1
            return false ; 原生处理过的窗口不再叠加旧式字体。
        if ScaledHwnds.Has(hwnd) && HasRescaleMarker(hwnd)
            return RefreshRescaledWindow(hwnd, ScaledHwnds[hwnd])

        records := CaptureRescaleTree(hwnd)
        root := records[1]
        native := root.cls = "MMCMainFrame"
        original := root.rect
        work := GetRescaleWorkArea(hwnd)
        fontSize := RescaleFontSize
        minimumSize := Max(Min(fontSize, 10), fontSize - 2)
        loop {
            scale := PrepareRescaleFonts(records, fontSize)
            if !scale
                return false
            scale := native ? 1 : scale
            width := Round(root.client.w * scale) + original.w - root.client.w
            height := Round(root.client.h * scale) + original.h - root.client.h
            if native || (width <= work.w && height <= work.h)
                break
            if fontSize <= minimumSize
                return false
            ; 最多下调2pt、每次0.5pt；先测量，不强行压缩原窗口或裁掉按钮。
            fontSize := Max(minimumSize, fontSize - 0.5)
        }
        width := Min(width, work.w)
        height := Min(height, work.h)
        bounds := { x: Max(work.x, Min(original.x, work.x + work.w - width)),
            y: Max(work.y, Min(original.y, work.y + work.h - height)), w: width, h: height }
        ResolveRescaleFonts(records)
        try {
            ; 字体已准备好，再暂停绘制，统一应用字体和位置。
            if DllCall("IsWindowVisible", "Ptr", hwnd) {
                RescaleFrozen := hwnd
                RescaleSend(hwnd, 0xB, false) ; WM_SETREDRAW
            }
            if !ApplyRescaleFonts(records)
                return false
            MoveRescaleRect(hwnd, bounds)
            ApplyRescaleLayout(records, scale, !native)
        } catch as err {
            for record in records {
                if record.applied {
                    try RescaleSend(record.hwnd, 0x30, record.oldFont, 1)
                }
            }
            try MoveRescaleRect(hwnd, original)
            for record in records {
                if record.parent && record.layout {
                    try MoveRescaleRect(record.hwnd, record.rect)
                }
            }
            throw err
        } finally {
            RedrawRescaleWindow(hwnd)
        }
        nodes := Map()
        RememberRescaleNodes(nodes, records, hwnd)
        ScaledHwnds[hwnd] := { nodes: nodes, scale: scale, native: native, fontSize: fontSize }
        DllCall("SetPropW", "Ptr", hwnd, "Str", RescaleModeProperty, "Ptr", 2)
        return true
    } finally {
        if previousDpi
            DllCall("SetThreadDpiAwarenessContext", "Ptr", previousDpi, "Ptr")
        RescaleBusy := false
    }
}

HasRescaleMarker(hwnd) {
    ; 窗口销毁时标记由系统移除，可区分 Windows 复用的 HWND。
    return DllCall("GetPropW", "Ptr", hwnd, "Str", RescaleProperty, "Ptr") = RescaleOwner
}

RememberRescaleNodes(nodes, records, root := 0) {
    for record in records {
        nodes[record.hwnd] := record
        marked := DllCall("SetPropW", "Ptr", record.hwnd, "Str", RescaleProperty, "Ptr", RescaleOwner)
        if record.hwnd = root && !marked
            throw OSError(A_LastError, , "无法标记已处理的窗口")
    }
}

GetRescaleProcess(pid) {
    if !RescaleProcesses.Has(pid) || !RescaleProcesses[pid].IsAlive()
        RescaleProcesses[pid] := Win32FontProcess(pid)
    return RescaleProcesses[pid]
}

PruneRescaleProcesses() {
    for pid, process in RescaleProcesses.Clone() {
        if !process.IsAlive() {
            process.Close()
            RescaleProcesses.Delete(pid)
        }
    }
}

CaptureRescaleTree(hwnd, parent := 0, parentClass := "", records := unset) {
    if !IsSet(records)
        records := []
    cls := WinGetClass(hwnd)
    style := WinGetStyle(hwnd)
    record := { hwnd: hwnd, pid: WinGetPID(hwnd), parent: parent, cls: cls, style: style,
        rect: GetRescaleRect(hwnd, parent), client: GetRescaleClient(hwnd), layout: !IsManagedRescaleChild(parentClass)
        && !(parentClass = "MDIClient" && (style & 0x01000000)),
        acceptsFont: IsRescaleFontControl(cls, style), font: 0, fontScale: 1, applied: false }
    if record.acceptsFont
        record.oldFont := RescaleSend(hwnd, 0x31) ; WM_GETFONT
    record.columns := []
    if cls = "SysListView32" {
        header := RescaleSend(hwnd, 0x101F) ; LVM_GETHEADER
        if header {
            count := RescaleSend(header, 0x1200) ; HDM_GETITEMCOUNT
            if count > 0 && count <= 256 {
                loop count
                    record.columns.Push(RescaleSend(hwnd, 0x101D, A_Index - 1))
            }
        }
    }
    if cls = "SysTreeView32"
        record.itemHeight := RescaleSend(hwnd, 0x111C) ; TVM_GETITEMHEIGHT
    if cls = "ComboBox" {
        record.selectionHeight := RescaleSend(hwnd, 0x154, -1)
        record.itemHeight := RescaleSend(hwnd, 0x154, 0)
        dropped := Buffer(16, 0)
        ; CB_GETDROPPEDCONTROLRECT < WM_USER，由 Windows 正确封送 RECT。
        if (style & 3) != 1 && RescaleSend(hwnd, 0x152, 0, dropped.Ptr)
            record.rect.h := NumGet(dropped, 12, "Int") - NumGet(dropped, 4, "Int")
    }
    records.Push(record)
    child := DllCall("GetWindow", "Ptr", hwnd, "UInt", 5, "Ptr")
    while child {
        next := DllCall("GetWindow", "Ptr", child, "UInt", 2, "Ptr")
        ; 隐藏的属性页可能还在 WM_INITDIALOG 中，留到首次显示时处理。
        if WinGetClass(child) != "#32770" || (WinGetStyle(child) & 0x10000000)
            CaptureRescaleTree(child, hwnd, cls, records)
        child := next
    }
    return records
}

IsRescaleFontControl(cls, style) {
    if cls = "Static"
        return (style & 0x1F) <= 2 || (style & 0x1F) = 11 || (style & 0x1F) = 12
    return RegExMatch(cls,
        "i)^(Button|Edit|RichEdit.*|ComboBox|ComboBoxEx32|ListBox|SysListView32|SysTreeView32|SysTabControl32|SysHeader32|SysLink|msctls_statusbar32|SysDateTimePick32|SysMonthCal32)$"
    ) != 0
}

IsManagedRescaleChild(parentClass) {
    ; 这些复合控件会自行布局内部编辑框、表头等，不能再次缩放它们的坐标。
    return RegExMatch(parentClass,
        "i)^(ComboBox|ComboBoxEx32|SysListView32|SysTreeView32|ToolbarWindow32|ReBarWindow32|msctls_statusbar32)$") !=
    0
}

PrepareRescaleFonts(records, fontSize := 0) {
    if !fontSize
        fontSize := RescaleFontSize
    if RescaleFontSize <= 0 || RescaleFontSize > 72 || !RescaleFontName || StrLen(RescaleFontName) > 31
        throw Error("请使用 0～72pt 的有效字号及不超过 31 个字符的字体名")
    fallback := 0
    for record in records {
        if record.acceptsFont && record.oldFont {
            fallback := ReadRescaleLogFont(record.oldFont)
            if fallback
                break
        }
    }
    if !fallback
        fallback := ReadRescaleLogFont(DllCall("GetStockObject", "Int", 17, "Ptr"))
    if !fallback
        throw Error("无法读取窗口的原始字体")
    metrics := Map()
    scale := 0
    for record in records {
        if !record.acceptsFont
            continue
        record.font := 0
        source := ReadRescaleLogFont(record.oldFont)
        sourceValid := IsObject(source)
        if !source
            source := fallback
        dpi := DllCall("GetDpiForWindow", "Ptr", record.hwnd, "UInt")
        target := Buffer(92, 0)
        DllCall("RtlMoveMemory", "Ptr", target, "Ptr", source, "UPtr", 28)
        NumPut("Int", -Round(fontSize * (dpi ? dpi : 96) / 72), target, 0)
        NumPut("Int", 0, target, 4)
        NumPut("UChar", 5, target, 26)
        StrPut(RescaleFontName, target.Ptr + 28, 32, "UTF-16")
        record.logFont := target
        oldKey := Win32FontKey(source)
        newKey := Win32FontKey(target)
        if !metrics.Has(oldKey)
            metrics[oldKey] := MeasureRescaleFont(source)
        if !metrics.Has(newKey)
            metrics[newKey] := MeasureRescaleFont(target)
        oldMetrics := metrics[oldKey]
        newMetrics := metrics[newKey]
        record.textHeight := newMetrics.height
        record.fontScale := Max(1.0, newMetrics.height / oldMetrics.height,
            newMetrics.width / oldMetrics.width, newMetrics.cjkWidth / oldMetrics.cjkWidth)
        if record.cls = "Static" || record.cls = "Button" {
            caption := ReadRescaleCaption(record.hwnd)
            if caption {
                originalText := MeasureRescaleFont(source, caption)
                targetText := MeasureRescaleFont(target, caption)
                record.originalTextWidth := originalText.width
                record.targetTextWidth := targetText.width
                if originalText.width > 0
                    record.fontScale := Max(record.fontScale, targetText.width / originalText.width)
                paddingX := record.cls = "Button" ? Round(12 * dpi / 96) : 0
                paddingY := record.cls = "Button" && (record.style & 0xF) != 7 ? Round(4 * dpi / 96) : 0
                if record.cls = "Button" && RegExMatch(record.style & 0xF, "^(2|3|4|5|6|9)$")
                    paddingX := Round(24 * dpi / 96)
                singleLine := (record.cls = "Button" && !(record.style & 0x2000))
                || (!InStr(caption, "`n") && record.client.h < oldMetrics.height * 1.6)
                || (record.cls = "Static" && ((record.style & 0x1F) = 11 || (record.style & 0x1F) = 12))
                if singleLine && !(record.cls = "Static" && (record.style & 0xC000)) && record.rect.w > 0
                    record.fontScale := Max(record.fontScale,
                        (targetText.width + paddingX + record.rect.w - record.client.w) / record.rect.w)
                if record.rect.h > 0
                    record.fontScale := Max(record.fontScale,
                        (newMetrics.height + paddingY + record.rect.h - record.client.h) / record.rect.h)
            }
        }
        scale := Max(scale, record.fontScale)
        if sourceValid && oldKey = newKey
            record.font := record.oldFont
    }
    return Ceil(scale * 100) / 100 ; 没有可调整的字体时返回 0。
}

ReadRescaleLogFont(font) {
    if !font
        return 0
    data := Buffer(92, 0)
    return DllCall("GetObjectW", "Ptr", font, "Int", 92, "Ptr", data) = 92 ? data : 0
}

MeasureRescaleFont(data, sample := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz") {
    font := DllCall("CreateFontIndirectW", "Ptr", data, "Ptr")
    dc := DllCall("GetDC", "Ptr", 0, "Ptr")
    previous := DllCall("SelectObject", "Ptr", dc, "Ptr", font, "Ptr")
    try {
        if !font || !dc || !previous
            throw Error("无法测量字体")
        tm := Buffer(60, 0)
        extent := Buffer(8, 0)
        cjk := "环境变量系统属性设备管理器"
        cjkExtent := Buffer(8, 0)
        if !DllCall("GetTextMetricsW", "Ptr", dc, "Ptr", tm)
        || !DllCall("GetTextExtentPoint32W", "Ptr", dc, "Str", sample, "Int", StrLen(sample), "Ptr", extent)
        || !DllCall("GetTextExtentPoint32W", "Ptr", dc, "Str", cjk, "Int", StrLen(cjk), "Ptr", cjkExtent)
            throw Error("无法获取字体尺寸")
        return { height: NumGet(tm, 0, "Int"), width: NumGet(extent, 0, "Int"), cjkWidth: NumGet(cjkExtent, 0, "Int") }
    } finally {
        if previous
            DllCall("SelectObject", "Ptr", dc, "Ptr", previous)
        if dc
            DllCall("ReleaseDC", "Ptr", 0, "Ptr", dc)
        if font
            DllCall("DeleteObject", "Ptr", font)
    }
}

ResolveRescaleFonts(records) {
    process := 0
    for record in records {
        if record.acceptsFont && !record.font {
            if !process || process.pid != record.pid
                process := GetRescaleProcess(record.pid)
            record.font := process.GetFont(record.logFont)
        }
    }
}

ApplyRescaleFonts(records) {
    count := 0
    for record in records {
        if !record.acceptsFont
            continue
        RescaleSend(record.hwnd, 0x30, record.font, 0) ; 字体和位置都调整好后统一重绘。
        if RescaleSend(record.hwnd, 0x31) = record.font {
            record.applied := true
            count += 1
        }
    }
    return count
}

ApplyRescaleLayout(records, scale, move := true) {
    for record in records {
        if move && record.parent && record.layout
            MoveRescaleRect(record.hwnd, record.rect, scale)
        AdjustRescaleItems(record, scale)
    }
}

AdjustRescaleItems(record, scale) {
    if record.cls = "SysListView32" {
        for index, width in record.columns {
            if width <= 0
                continue
            RescaleSend(record.hwnd, 0x101E, index - 1, -2) ; 按表头自动定宽，无跨进程指针。
            fitted := RescaleSend(record.hwnd, 0x101D, index - 1)
            RescaleSend(record.hwnd, 0x101E, index - 1, Max(fitted, Round(width * scale)))
        }
    } else if record.cls = "SysTreeView32" && record.applied {
        RescaleSend(record.hwnd, 0x111B, Max(record.itemHeight, record.textHeight + 4))
    } else if record.cls = "ComboBox" && record.applied {
        if record.selectionHeight > 0 && record.selectionHeight < 1000
            RescaleSend(record.hwnd, 0x153, -1, Max(record.selectionHeight, record.textHeight + 2))
        if record.itemHeight > 0 && record.itemHeight < 1000
            RescaleSend(record.hwnd, 0x153, 0, Max(record.itemHeight, record.textHeight + 2))
    }
}

RefreshRescaledWindow(hwnd, state) {
    ; 隐藏的属性页完成初始化、首次显示后再处理，已有控件不会重复放大。
    changed := false
    for child in state.nodes.Clone() {
        if !HasRescaleMarker(child)
            state.nodes.Delete(child)
    }
    for child in WinGetControlsHwnd(hwnd) {
        if state.nodes.Has(child) || !IsRescaleContentVisible(child, hwnd)
            continue
        parent := DllCall("GetParent", "Ptr", child, "Ptr")
        if parent != hwnd && !state.nodes.Has(parent)
            continue
        records := CaptureRescaleTree(child)
        records[1].rect := GetRescaleRect(child, parent)
        scale := PrepareRescaleFonts(records, state.fontSize)
        if scale {
            ResolveRescaleFonts(records)
            ApplyRescaleFonts(records)
            if records[1].cls = "#32770" && !state.native {
                page := records[1].rect
                pagePosition := page
                pageScale := scale
                parentClass := WinGetClass(parent)
                propertyHost := parentClass = "SysTabControl32" || (parentClass = "#32770"
                    && DllCall("FindWindowExW", "Ptr", parent, "Ptr", 0, "Str", "SysTabControl32", "Ptr", 0, "Ptr"))
                for sibling, oldRecord in state.nodes {
                    if oldRecord.parent = parent && oldRecord.cls = "#32770" && DllCall("IsWindow", "Ptr", sibling)
                    && (propertyHost || (Abs(oldRecord.rect.x - page.x) <= 2 && Abs(oldRecord.rect.y - page.y) <= 2)) {
                        ; 复用已经放大的属性页区域，避免再次缩放。
                        pagePosition := GetRescaleRect(sibling, parent)
                        pageScale := 1
                        records[1].rect := oldRecord.rect
                        break
                    }
                }
                MoveRescaleRect(child, pagePosition, pageScale)
                ApplyRescaleLayout(records, scale)
            } else {
                for record in records
                    AdjustRescaleItems(record, record.fontScale)
            }
            changed := true
        }
        ; 布局后再关联父窗口，避免把子树根节点再次缩放。
        records[1].parent := parent
        RememberRescaleNodes(state.nodes, records)
    }
    for child, record in state.nodes {
        if record.applied && IsRescaleContentVisible(child, hwnd) && RescaleSend(child, 0x31) != record.font {
            RescaleSend(child, 0x30, record.font, 0)
            changed := true
        }
    }
    if changed
        RedrawRescaleWindow(hwnd)
    return true
}

IsRescaleContentVisible(child, root) {
    while child && child != root {
        if !(DllCall("GetWindowLongW", "Ptr", child, "Int", -16, "UInt") & 0x10000000)
            return false
        child := DllCall("GetParent", "Ptr", child, "Ptr")
    }
    return child = root
}

GetRescaleRect(hwnd, parent := 0) {
    rect := Buffer(16, 0)
    if !DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", rect)
        throw OSError(A_LastError)
    if parent
        DllCall("MapWindowPoints", "Ptr", 0, "Ptr", parent, "Ptr", rect, "UInt", 2)
    return { x: NumGet(rect, 0, "Int"), y: NumGet(rect, 4, "Int"),
        w: NumGet(rect, 8, "Int") - NumGet(rect, 0, "Int"), h: NumGet(rect, 12, "Int") - NumGet(rect, 4, "Int") }
}

GetRescaleClient(hwnd) {
    WinGetClientPos(, , &width, &height, hwnd)
    return { w: width, h: height }
}

GetRescaleWorkArea(hwnd) {
    monitor := DllCall("MonitorFromWindow", "Ptr", hwnd, "UInt", 2, "Ptr")
    info := Buffer(40, 0)
    NumPut("UInt", 40, info)
    if DllCall("GetMonitorInfoW", "Ptr", monitor, "Ptr", info) {
        left := NumGet(info, 20, "Int")
        top := NumGet(info, 24, "Int")
        right := NumGet(info, 28, "Int")
        bottom := NumGet(info, 32, "Int")
        return { x: left, y: top, w: right - left, h: bottom - top }
    }
    return { x: 0, y: 0, w: A_ScreenWidth, h: A_ScreenHeight }
}

MoveRescaleRect(hwnd, rect, scale := 1) {
    if !DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0, "Int", Round(rect.x * scale), "Int", Round(rect.y * scale),
    "Int", Round(rect.w * scale), "Int", Round(rect.h * scale), "UInt", 0x001C) ; NOZORDER | NOACTIVATE | NOREDRAW
        throw OSError(A_LastError, , "无法调整控件位置")
}

RescaleSend(hwnd, message, wParam := 0, lParam := 0) {
    result := 0
    if !DllCall("SendMessageTimeoutW", "Ptr", hwnd, "UInt", message, "Ptr", wParam, "Ptr", lParam,
        "UInt", 0x22, "UInt", 250, "Ptr*", &result, "Ptr")
        throw OSError(A_LastError, , "窗口无响应或权限不足")
    return result
}

RedrawRescaleWindow(hwnd) {
    global RescaleFrozen
    if RescaleFrozen = hwnd {
        RescaleFrozen := 0
        try RescaleSend(hwnd, 0xB, true)
    }
    DllCall("RedrawWindow", "Ptr", hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x0185)
}

ReadRescaleCaption(hwnd) {
    length := Min(32768, RescaleSend(hwnd, 0x0E)) ; WM_GETTEXTLENGTH
    if !length
        return ""
    text := Buffer((length + 1) * 2, 0)
    RescaleSend(hwnd, 0x0D, length + 1, text.Ptr) ; WM_GETTEXT，由 Windows 封送字符串。
    return StrGet(text, "UTF-16")
}

; 退出/测试清理统一放在这里；目标程序持有的字体仍有效。
CleanupDialogRescaler(*) {
    if RescaleFrozen
        RedrawRescaleWindow(RescaleFrozen) ; 重载/退出也要恢复尚未完成的绘制。
    if IsObject(RescaleEvents)
        RescaleEvents.Close()
    for hwnd, state in ScaledHwnds {
        if state.HasOwnProp("dpi") {
            if HasRescaleMarker(hwnd)
                DllCall("RemovePropW", "Ptr", hwnd, "Str", RescaleProperty, "Ptr")
            continue
        }
        for child, record in state.nodes {
            if HasRescaleMarker(child)
                DllCall("RemovePropW", "Ptr", child, "Str", RescaleProperty, "Ptr")
        }
    }
    for pid, process in RescaleProcesses
        process.Close()
    ScaledHwnds.Clear()
    RescaleProcesses.Clear()
}



