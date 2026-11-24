param([string]$text, [string]$procName = "chaoshu")
Add-Type -AssemblyName Microsoft.VisualBasic, System.Windows.Forms
$p = Get-Process | Where-Object { $_.ProcessName -like "*$procName*" } | Select-Object -First 1
if ($p) {
  [Microsoft.VisualBasic.Interaction]::AppActivate($p.Id) | Out-Null
  Start-Sleep -Milliseconds 300
  if ($text -eq "{SPACE}") {
    [System.Windows.Forms.SendKeys]::SendWait(" ")
  } else {
    [System.Windows.Forms.SendKeys]::SendWait($text)
  }
  Write-Output "sent to pid $($p.Id): $text"
} else {
  Write-Output "process $procName not found"
}
