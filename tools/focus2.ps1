Add-Type @"
using System;
using System.Runtime.InteropServices;
public class FW2 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  public struct RECT { public int L, T, R, B; }
}
"@
$p = Get-Process chaoshu | Select-Object -First 1
$h = $p.MainWindowHandle
$r = New-Object FW2+RECT
[FW2]::GetWindowRect($h, [ref]$r) | Out-Null
Write-Output "hwnd=$h rect=$($r.L),$($r.T)-$($r.R),$($r.B)"
[FW2]::ShowWindow($h, 9) | Out-Null
[FW2]::SetWindowPos($h, [IntPtr]::Zero, 40, 60, 1200, 800, 0x0040) | Out-Null
[FW2]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 400
[FW2]::GetWindowRect($h, [ref]$r) | Out-Null
Write-Output "after: rect=$($r.L),$($r.T)-$($r.R),$($r.B)"
