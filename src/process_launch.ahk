#Requires AutoHotkey v2.0 64-bit

; Windows 的父进程属性会继承所选进程的令牌。选择桌面 Explorer，
; 让子进程始终以桌面用户的普通权限运行，并取得真实 PID，便于可靠启停。
RunUnelevated(program, arguments, directory, &pid) {
    shellWindow := DllCall("GetShellWindow", "Ptr"), shellPid := 0
    if !shellWindow
        throw Error("桌面 Explorer 尚未就绪，请稍后重试")
    DllCall("GetWindowThreadProcessId", "Ptr", shellWindow, "UInt*", &shellPid)
    if IsProcessElevated(shellPid)
        throw Error("桌面 Explorer 不是普通权限，已取消启动")
    parent := DllCall("OpenProcess", "UInt", 0x80, "Int", false, "UInt", shellPid, "Ptr")
    if !parent
        throw OSError(A_LastError, , "无法使用桌面用户启动子进程")
    attributes := 0
    try {
        bytes := 0
        DllCall("InitializeProcThreadAttributeList", "Ptr", 0, "UInt", 1, "UInt", 0, "UPtr*", &bytes)
        attributes := Buffer(bytes, 0)
        if !DllCall("InitializeProcThreadAttributeList", "Ptr", attributes, "UInt", 1, "UInt", 0, "UPtr*", &bytes) {
            attributes := 0
            throw OSError(A_LastError)
        }
        parentValue := Buffer(A_PtrSize, 0)
        NumPut("Ptr", parent, parentValue)
        if !DllCall("UpdateProcThreadAttribute", "Ptr", attributes, "UInt", 0, "UPtr", 0x20000,
            "Ptr", parentValue, "UPtr", parentValue.Size, "Ptr", 0, "Ptr", 0)
            throw OSError(A_LastError)
        startup := Buffer(112, 0), process := Buffer(24, 0)
        NumPut("UInt", startup.Size, startup)
        NumPut("UInt", 1, startup, 60) ; STARTF_USESHOWWINDOW，SW_HIDE = 0。
        NumPut("Ptr", attributes.Ptr, startup, 104)
        command := '"' program '" ' arguments
        mutableCommand := Buffer(StrPut(command, "UTF-16") * 2)
        StrPut(command, mutableCommand, "UTF-16")
        if !DllCall("CreateProcessW", "Str", program, "Ptr", mutableCommand, "Ptr", 0, "Ptr", 0,
            "Int", false, "UInt", 0x80000, "Ptr", 0, "Str", directory, "Ptr", startup, "Ptr", process)
            throw OSError(A_LastError, , "无法以桌面用户的权限启动子进程")
        pid := NumGet(process, 16, "UInt")
        DllCall("CloseHandle", "Ptr", NumGet(process, 8, "Ptr"))
        DllCall("CloseHandle", "Ptr", NumGet(process, 0, "Ptr"))
    } finally {
        if attributes
            DllCall("DeleteProcThreadAttributeList", "Ptr", attributes)
        DllCall("CloseHandle", "Ptr", parent)
    }
}

IsProcessElevated(pid) {
    process := DllCall("OpenProcess", "UInt", 0x1000, "Int", false, "UInt", pid, "Ptr"), token := 0
    if !process
        throw OSError(A_LastError)
    try {
        if !DllCall("advapi32\OpenProcessToken", "Ptr", process, "UInt", 8, "Ptr*", &token)
            throw OSError(A_LastError)
        if !DllCall("advapi32\GetTokenInformation", "Ptr", token, "Int", 20, "UInt*", &elevated := 0,
            "UInt", 4, "UInt*", &size := 0)
            throw OSError(A_LastError)
        return !!elevated
    } finally {
        if token
            DllCall("CloseHandle", "Ptr", token)
        DllCall("CloseHandle", "Ptr", process)
    }
}

