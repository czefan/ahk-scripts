param([string]$TestScript = 'file_picker_test.ahk', [int]$TimeoutSeconds = 45,
      [ValidateSet('isolated','x64','x86')][string]$TestMode = 'isolated', [switch]$CaptureStdout)
$ErrorActionPreference = 'Stop'
$testPath = Join-Path $PSScriptRoot $TestScript
$workspacePath = Split-Path -Parent $PSScriptRoot
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class PickerDesktop {
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct SI {
 public int cb; public string reserved, desktop, title; public int x,y,cx,cy,charsX,charsY,fill,flags;
 public short show, reserved2; public IntPtr reservedPtr, input, output, error;
 }
 [StructLayout(LayoutKind.Sequential)] public struct PI { public IntPtr process,thread; public int pid,tid; }
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr CreateDesktopW(string name,IntPtr device,IntPtr devmode,int flags,uint access,IntPtr security);
 [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr desktop);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool CreateProcessW(string app,StringBuilder command,IntPtr pa,IntPtr ta,bool inherit,int flags,IntPtr env,string cwd,ref SI startup,out PI process);
 [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr handle,uint ms);
 [DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr handle,out uint code);
 [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
 [DllImport("kernel32.dll")] public static extern bool TerminateProcess(IntPtr handle,uint code);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool SetHandleInformation(IntPtr handle,uint mask,uint flags);
}
"@
$name='AHKPickerTest_'+[guid]::NewGuid().ToString('N')
$outputDirectory=Join-Path $PSScriptRoot 'output'
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$report=Join-Path $outputDirectory ($name+'.log')
$desktop=[PickerDesktop]::CreateDesktopW($name,[IntPtr]::Zero,[IntPtr]::Zero,0,0x01FF,[IntPtr]::Zero)
if($desktop -eq [IntPtr]::Zero){throw ('CreateDesktop failed: '+[Runtime.InteropServices.Marshal]::GetLastWin32Error())}
$si=New-Object PickerDesktop+SI
$si.cb=[Runtime.InteropServices.Marshal]::SizeOf($si)
$si.desktop='WinSta0\'+$name
$si.flags=1
$si.show=0
$pi=New-Object PickerDesktop+PI
$captureStream=$null
try {
 if($CaptureStdout){
  $captureStream=[IO.File]::Open($report,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
  $captureHandle=$captureStream.SafeFileHandle.DangerousGetHandle()
  if(-not [PickerDesktop]::SetHandleInformation($captureHandle,1,1)){throw 'Could not prepare test output handle'}
  $si.flags=$si.flags -bor 0x100
  $si.output=$captureHandle; $si.error=$captureHandle
 }
 $cmd=New-Object Text.StringBuilder ('"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" /ErrorStdOut "'+$testPath+'" '+$TestMode+' "'+$report+'"')
 if(-not [PickerDesktop]::CreateProcessW('C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe',$cmd,[IntPtr]::Zero,[IntPtr]::Zero,[bool]$CaptureStdout,0,[IntPtr]::Zero,$workspacePath,[ref]$si,[ref]$pi)){throw ('CreateProcess failed: '+[Runtime.InteropServices.Marshal]::GetLastWin32Error())}
 $deadline=(Get-Date).AddSeconds($TimeoutSeconds)
 while([PickerDesktop]::WaitForSingleObject($pi.process,500) -eq 258){
  if((Get-Date) -gt $deadline){[PickerDesktop]::TerminateProcess($pi.process,1) | Out-Null;throw 'Isolated picker test timed out'}
 }
 $exitCode=0
 [PickerDesktop]::GetExitCodeProcess($pi.process,[ref]$exitCode) | Out-Null
 if(Test-Path -LiteralPath $report){Get-Content -LiteralPath $report}
 Write-Output ('Report: '+$report)
 Write-Output ('Test exit: '+$exitCode)
 if($exitCode -ne 0){throw 'Picker test failed'}
} finally {
 if($pi.pid){
  Get-CimInstance Win32_Process | Where-Object {
   $_.ParentProcessId -eq $pi.pid -and $_.Name -like 'AutoHotkey*' -and $_.CommandLine -and
   $_.CommandLine.IndexOf($testPath,[StringComparison]::OrdinalIgnoreCase) -ge 0
  } | ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
 }
 if($captureStream){$captureStream.Dispose()}
 if($pi.thread -ne [IntPtr]::Zero){[PickerDesktop]::CloseHandle($pi.thread) | Out-Null}
 if($pi.process -ne [IntPtr]::Zero){[PickerDesktop]::CloseHandle($pi.process) | Out-Null}
 [PickerDesktop]::CloseDesktop($desktop) | Out-Null
}


