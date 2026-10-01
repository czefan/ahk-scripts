#Requires AutoHotkey v2.0

; LOGFONT 前 28 字节的字体参数和字体名，供测量和创建共用。
Win32FontKey(data) {
    key := StrLower(StrGet(data.Ptr + 28, 32, "UTF-16"))
    Loop 7
        key .= "|" NumGet(data, (A_Index - 1) * 4, "UInt")
    return key
}

; HFONT 不能跨进程用于绘制。这里只把 LOGFONTW 数据写入目标进程，
; 由目标进程调用自己的 CreateFontIndirectW；不传入 AHK 回调或机器码。
; 字体由目标进程持有，AHK 重载/退出后仍然有效，目标进程退出时由系统回收。
class Win32FontProcess {
    __New(pid) {
        this.pid := pid
        this.handle := DllCall("OpenProcess", "UInt", 0x10043A, "Int", false, "UInt", pid, "Ptr")
        if !this.handle
            throw OSError(A_LastError, , "无法在目标程序中创建字体")
        this.fonts := Map()
        this.pending := []
        this.createFontAddress := 0
    }

    IsAlive() {
        return this.handle && DllCall("WaitForSingleObject", "Ptr", this.handle, "UInt", 0, "UInt") = 0x102
    }

    GetFont(logFont) {
        this.Collect()
        key := Win32FontKey(logFont)
        if this.fonts.Has(key)
            return this.fonts[key]
        for request in this.pending {
            if request.key = key
                throw Error("目标程序尚未完成字体创建，请稍后重试")
        }
        if !this.IsAlive()
            throw Error("目标程序已经退出")
        if !this.createFontAddress
            this.createFontAddress := this.ResolveExport("gdi32.dll", "CreateFontIndirectW")

        remoteData := DllCall("VirtualAllocEx", "Ptr", this.handle, "Ptr", 0,
            "UPtr", logFont.Size, "UInt", 0x3000, "UInt", 0x04, "Ptr")
        if !remoteData
            throw OSError(A_LastError, , "无法分配字体参数")
        thread := 0
        try {
            written := 0
            if !DllCall("WriteProcessMemory", "Ptr", this.handle, "Ptr", remoteData,
                "Ptr", logFont, "UPtr", logFont.Size, "UPtr*", &written) || written != logFont.Size
                throw OSError(A_LastError, , "无法写入字体参数")
            ; CreateFontIndirectW 和线程入口均只接收一个指针参数。
            ; GDI 句柄的有效值为 32 位，可通过线程退出码取回，兼容 32/64 位目标。
            thread := DllCall("CreateRemoteThread", "Ptr", this.handle, "Ptr", 0, "UPtr", 0,
                "Ptr", this.createFontAddress, "Ptr", remoteData, "UInt", 0, "Ptr", 0, "Ptr")
            if !thread
                throw OSError(A_LastError, , "目标程序不允许创建字体")
            ; 同步完成和超时请求都由 Collect 统一取结果、释放资源。
            this.pending.Push({key: key, thread: thread, data: remoteData})
            if DllCall("WaitForSingleObject", "Ptr", thread, "UInt", 1500, "UInt") != 0
                throw Error("目标程序创建字体超时，请稍后重试")
            this.Collect()
            if !this.fonts.Has(key)
                throw Error("目标程序创建字体失败")
            return this.fonts[key]
        } finally {
            ; 线程启动后，参数必须保留到线程完成，超时时也不能提前释放。
            if !thread
                DllCall("VirtualFreeEx", "Ptr", this.handle, "Ptr", remoteData, "UPtr", 0, "UInt", 0x8000)
        }
    }

    Collect() {
        index := this.pending.Length
        while index > 0 {
            request := this.pending[index]
            if DllCall("WaitForSingleObject", "Ptr", request.thread, "UInt", 0, "UInt") = 0 {
                font := 0
                if DllCall("GetExitCodeThread", "Ptr", request.thread, "UInt*", &font) && font
                    && DllCall("GetObjectW", "Ptr", font, "Int", 92, "Ptr", Buffer(92)) = 92
                    this.fonts[request.key] := font
                DllCall("VirtualFreeEx", "Ptr", this.handle, "Ptr", request.data, "UPtr", 0, "UInt", 0x8000)
                DllCall("CloseHandle", "Ptr", request.thread)
                this.pending.RemoveAt(index)
            }
            index -= 1
        }
    }

    Close() {
        if !this.handle
            return
        this.Collect()
        for request in this.pending
            DllCall("CloseHandle", "Ptr", request.thread)
        this.pending := []
        DllCall("CloseHandle", "Ptr", this.handle)
        this.handle := 0
    }

    __Delete() {
        this.Close()
    }

    Read(address, size) {
        data := Buffer(size, 0)
        bytesRead := 0
        if !DllCall("ReadProcessMemory", "Ptr", this.handle, "Ptr", address,
            "Ptr", data, "UPtr", size, "UPtr*", &bytesRead) || bytesRead != size
            throw OSError(A_LastError, , "无法读取目标程序的系统模块")
        return data
    }

    ReadString(address, limit := 260) {
        value := ""
        while StrLen(value) < limit {
            size := Min(64, limit - StrLen(value), 4096 - Mod(address, 4096))
            part := StrGet(this.Read(address, size), size, "CP0") ; PE 导出名称为 ASCII。
            value .= part
            if StrLen(part) < size
                return value
            address += size
        }
        throw Error("无效的系统函数名称")
    }

    LoadModules() {
        entries := Buffer(1024 * A_PtrSize)
        needed := 0
        Loop 4 {
            if !DllCall("psapi\EnumProcessModulesEx", "Ptr", this.handle, "Ptr", entries,
                "UInt", entries.Size, "UInt*", &needed, "UInt", 3) ; LIST_MODULES_ALL：包括 WOW64 模块。
                throw OSError(A_LastError, , "无法枚举目标模块")
            if needed <= entries.Size
                break
            if A_Index = 4
                throw Error("目标程序的模块列表暂不可用")
            entries := Buffer(needed)
        }
        name := Buffer(512)
        info := Buffer(3 * A_PtrSize)
        modules := Map()
        Loop needed // A_PtrSize {
            module := NumGet(entries, (A_Index - 1) * A_PtrSize, "Ptr")
            if DllCall("psapi\GetModuleBaseNameW", "Ptr", this.handle, "Ptr", module, "Ptr", name, "UInt", 256)
                && DllCall("psapi\GetModuleInformation", "Ptr", this.handle, "Ptr", module, "Ptr", info, "UInt", info.Size)
                modules[StrLower(StrGet(name))] := {address: module, size: NumGet(info, A_PtrSize, "UInt")}
        }
        return modules
    }

    ; 从目标进程自己的 PE 导出表解析地址，不能假设两进程 DLL 地址/位数相同。
    ResolveExport(moduleName, functionName, depth := 0, modules := unset) {
        if depth > 8
            throw Error("系统函数转发层数异常")
        moduleName := StrLower(moduleName)
        if !IsSet(modules) || !modules.Has(moduleName)
            modules := this.LoadModules()
        if !modules.Has(moduleName)
            throw Error("目标程序尚未加载 " moduleName)
        module := modules[moduleName]
        dos := this.Read(module.address, 64)
        peOffset := NumGet(dos, 60, "UInt")
        if NumGet(dos, 0, "UShort") != 0x5A4D || peOffset + 160 > module.size
            throw Error("无效的模块头或大小")
        pe := this.Read(module.address + peOffset, 160)
        magic := NumGet(pe, 24, "UShort")
        if NumGet(pe, 0, "UInt") != 0x4550 || (magic != 0x20B && magic != 0x10B)
            throw Error("无效的 PE 头或目标架构")
        exportOffset := magic = 0x20B ? 136 : 120
        exportRva := NumGet(pe, exportOffset, "UInt")
        exportSize := NumGet(pe, exportOffset + 4, "UInt")
        if !exportRva || exportRva + exportSize > module.size
            throw Error("无效的模块导出表")
        directory := this.Read(module.address + exportRva, 40)
        count := NumGet(directory, 24, "UInt")
        functionCount := NumGet(directory, 20, "UInt")
        if count > 65536 || functionCount > 65536
            throw Error("异常的模块导出数量")
        functions := this.Read(module.address + NumGet(directory, 28, "UInt"), functionCount * 4)
        ordinal := -1
        if SubStr(functionName, 1, 1) = "#" {
            ordinal := Integer(SubStr(functionName, 2)) - NumGet(directory, 16, "UInt")
        } else if count {
            names := this.Read(module.address + NumGet(directory, 32, "UInt"), count * 4)
            ordinals := this.Read(module.address + NumGet(directory, 36, "UInt"), count * 2)
            low := 0
            high := count - 1
            while low <= high {
                middle := (low + high) // 2
                name := this.ReadString(module.address + NumGet(names, middle * 4, "UInt"))
                comparison := StrCompare(name, functionName, true)
                if comparison = 0 {
                    ordinal := NumGet(ordinals, middle * 2, "UShort")
                    break
                }
                if comparison < 0
                    low := middle + 1
                else
                    high := middle - 1
            }
        }
        if ordinal < 0 || ordinal >= functionCount
            throw Error("找不到系统函数 " functionName)
        rva := NumGet(functions, ordinal * 4, "UInt")
        if !rva || rva >= module.size
            throw Error("无效的系统函数地址")
        if rva >= exportRva && rva < exportRva + exportSize {
            forward := this.ReadString(module.address + rva)
            separator := InStr(forward, ".", , -1)
            if !separator
                throw Error("无效的系统函数转发")
            return this.ResolveExport(SubStr(forward, 1, separator - 1) ".dll", SubStr(forward, separator + 1), depth + 1, modules)
        }
        return module.address + rva
    }
}
