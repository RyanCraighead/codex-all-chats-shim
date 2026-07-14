[CmdletBinding()]
param(
  [string]$TaskName = "Codex Shim CI Store Refresh",
  [string]$ProductId = "9PLM9XGG6VKS",
  [string]$InstallRoot = "C:\ProgramData\CodexShimCI",
  [switch]$RunNow
)

$ErrorActionPreference = "Stop"
$source = Join-Path $PSScriptRoot "store-refresh-worker.ps1"
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
  throw "Store refresh worker was not found: $source"
}

New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
$worker = Join-Path $InstallRoot "store-refresh-worker.ps1"
Copy-Item -LiteralPath $source -Destination $worker -Force
$statusPath = Join-Path $InstallRoot "store-refresh-status.json"
$logPath = Join-Path $InstallRoot "store-refresh.log"
$powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$arguments = @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", ('"' + $worker + '"'),
  "-ProductId", $ProductId,
  "-StatusPath", ('"' + $statusPath + '"'),
  "-LogPath", ('"' + $logPath + '"')
) -join " "

$action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments
$daily = New-ScheduledTaskTrigger -Daily -At "2:17 AM"
$logon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$principal = New-ScheduledTaskPrincipal `
  -UserId "$env:USERDOMAIN\$env:USERNAME" `
  -LogonType Interactive `
  -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -StartWhenAvailable `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $action `
  -Trigger @($daily, $logon) `
  -Principal $principal `
  -Settings $settings `
  -Force | Out-Null

if ($RunNow) {
  Start-ScheduledTask -TaskName $TaskName
}

[pscustomobject]@{
  installed = $true
  taskName = $TaskName
  user = "$env:USERDOMAIN\$env:USERNAME"
  worker = $worker
  statusPath = $statusPath
  logPath = $logPath
  started = [bool]$RunNow
} | ConvertTo-Json -Depth 4
