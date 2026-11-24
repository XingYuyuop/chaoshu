param([int]$x, [int]$y, [int]$clicks = 1)
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class M {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
}
"@
[M]::SetCursorPos($x, $y) | Out-Null
Start-Sleep -Milliseconds 120
for ($i = 0; $i -lt $clicks; $i++) {
  [M]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)  # LEFTDOWN
  [M]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)  # LEFTUP
  Start-Sleep -Milliseconds 90
}
Write-Output "clicked $x,$y x$clicks"
