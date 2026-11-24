$p = Start-Process "build\windows\x64\runner\Release\chaoshu.exe" -PassThru
Start-Sleep -Seconds 5
Write-Output "before click: HasExited=$($p.HasExited) Id=$($p.Id)"
powershell -NoProfile -ExecutionPolicy Bypass -File tools\click.ps1 -x 180 -y 300
Start-Sleep -Seconds 3
$p.Refresh()
Write-Output "after click: HasExited=$($p.HasExited) ExitCode=$($p.ExitCode)"
if (-not $p.HasExited) { powershell -NoProfile -ExecutionPolicy Bypass -File tools\shoot.ps1 }
