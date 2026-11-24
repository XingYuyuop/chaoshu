Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class FW {
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
  public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
}
"@
$target = [IntPtr]::Zero
$cb = [FW+EnumWindowsProc]{
  param($h, $l)
  if ([FW]::IsWindowVisible($h)) {
    $sb = New-Object System.Text.StringBuilder 256
    [FW]::GetWindowText($h, $sb, 256) | Out-Null
    if ($sb.ToString() -match '抄书') { $script:target = $h; Write-Output "match: '$($sb.ToString())' hwnd=$h"; return $false }
  }
  return $true
}
[FW]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
if ($target -ne [IntPtr]::Zero) {
  [FW]::ShowWindow($target, 9) | Out-Null  # SW_RESTORE
  # 移到左上并置顶（HWND_TOPMOST 再 TOPNOTOPMOST 保证前台）
  [FW]::SetWindowPos($target, [IntPtr]::Zero, 40, 60, 1200, 800, 0x0040) | Out-Null
  [FW]::SetForegroundWindow($target) | Out-Null
  Write-Output "focused hwnd=$target moved to 40,60"
} else {
  Write-Output "window not found"
}
