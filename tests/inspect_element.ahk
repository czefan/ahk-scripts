#Requires AutoHotkey v2.0 64-bit
#SingleInstance Force
#Include %A_LineFile%\..\..\Lib\UIA.ahk

; ==============================================================================
; UIA 元素层级属性探测工具
;
; 功能说明：
; 1. 获取鼠标光标所在叶子元素的 UIA 属性（Name、LocalizedType、ClassName、AutomationId）。
; 2. 向上遍历并打印 3 层父级容器属性。
; 3. 结果输出至系统剪贴板与屏幕提示。
;
; 使用方式：鼠标悬停于目标元素上，按 F8 执行读取。
; ==============================================================================

ToolTip("UIA 元素探测工具`n悬停于目标元素后按 F8 获取属性并复制到剪贴板")
SetTimer(() => ToolTip(), -3000)

F8:: {
    try {
        el := UIA.SmallestElementFromPoint()
        if !el {
            ToolTip("未检测到光标下的元素")
            SetTimer(() => ToolTip(), -2000)
            return
        }

        res := "【当前元素】`n"
        res .= Format("Name: '{1}' | Type: '{2}' | Class: '{3}' | AutoId: '{4}'`n", 
            el.Name, el.LocalizedType, el.ClassName, el.AutomationId)

        curr := el
        loop 3 {
            try {
                curr := curr.Parent
                if !curr
                    break
                res .= Format("`n【第 {1} 层父级】`nName: '{2}' | Type: '{3}' | Class: '{4}' | AutoId: '{5}'`n", 
                    A_Index, curr.Name, curr.LocalizedType, curr.ClassName, curr.AutomationId)
            } catch {
                break
            }
        }

        A_Clipboard := res
        ToolTip("属性已复制到剪贴板：`n" . res)
        SetTimer(() => ToolTip(), -5000)
    } catch as err {
        ToolTip("读取失败: " . err.Message)
        SetTimer(() => ToolTip(), -2000)
    }
}
