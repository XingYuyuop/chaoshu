Add-Type @"
using System;
using System.Runtime.InteropServices;
public class MN {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
}
"@
# 最小化除 chaoshu 外的主窗口（SW_MINIMIZE=6）
Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -and $_.ProcessName -notmatch 'chaoshu|explorer|TextInput|Search|StartMenu|ShellExperience|SystemSettings' } | ForEach-Object {
  [MN]::ShowWindow($_.MainWindowHandle, 6) | Out-Null
}
Write-Output "minimized others"
