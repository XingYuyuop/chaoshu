$ErrorActionPreference = 'Continue'
$root = "c:\Users\xing\Documents\1\chaoshu"
Set-Location $root
$p = Start-Process -FilePath "build\windows\x64\runner\Release\chaoshu.exe" -RedirectStandardError "tools\app_stderr.log" -RedirectStandardOutput "tools\app_stdout.log" -PassThru
Start-Sleep -Seconds 3
& powershell -NoProfile -ExecutionPolicy Bypass -File tools\focus2.ps1
Start-Sleep -Milliseconds 400
# 进入书 → 第一章
& powershell -NoProfile -ExecutionPolicy Bypass -File tools\click.ps1 -x 175 -y 300
Start-Sleep -Milliseconds 1500
& powershell -NoProfile -ExecutionPolicy Bypass -File tools\click.ps1 -x 220 -y 358
Start-Sleep -Milliseconds 1500
# 点击输入框，输入拼音 tang
& powershell -NoProfile -ExecutionPolicy Bypass -File tools\click.ps1 -x 895 -y 425
Start-Sleep -Milliseconds 400
& powershell -NoProfile -ExecutionPolicy Bypass -File tools\sendkeys.ps1 -text "tang"
Start-Sleep -Milliseconds 1000
& powershell -NoProfile -ExecutionPolicy Bypass -File tools\shoot.ps1
Copy-Item "$env:TEMP\cu_screen.png" "tools\shot1_composing.png" -Force
# 空格提交
& powershell -NoProfile -ExecutionPolicy Bypass -File tools\sendkeys.ps1 -text "{SPACE}"
Start-Sleep -Milliseconds 1000
& powershell -NoProfile -ExecutionPolicy Bypass -File tools\shoot.ps1
Copy-Item "$env:TEMP\cu_screen.png" "tools\shot2_committed.png" -Force
$p.Refresh()
Write-Output "app alive: $(-not $p.HasExited)"
