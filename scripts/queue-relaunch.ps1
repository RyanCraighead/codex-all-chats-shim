[CmdletBinding()]
param(
  [string]$ConfigPath = "",
  [int]$WaitTimeoutSeconds = 0
)

$ErrorActionPreference = "Stop"
$rootDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if (-not $ConfigPath) {
  $ConfigPath = Join-Path $rootDir "config.local.json"
}
if (-not (Test-Path -LiteralPath $ConfigPath)) {
  throw "Local configuration is missing. Run npm run setup first."
}
$launcher = Join-Path $PSScriptRoot "launch-codex.ps1"
$logDir = Join-Path $rootDir "logs"
$queueLog = Join-Path $logDir "queue.log"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

$powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$arguments = @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", ('"' + $launcher + '"'),
  "-ConfigPath", ('"' + $ConfigPath + '"'),
  "-WaitForClose",
  "-RestartShim"
) -join " "
if ($WaitTimeoutSeconds -gt 0) {
  $arguments += " -WaitTimeoutSeconds $WaitTimeoutSeconds"
}

$commandLine = '"' + $powershellExe + '" ' + $arguments
$startup = ([WmiClass]"Win32_ProcessStartup").CreateInstance()
$startup.ShowWindow = 0
$created = ([WmiClass]"Win32_Process").Create($commandLine, $rootDir, $startup)
if ($created.ReturnValue -ne 0) {
  throw "Win32_Process.Create failed with return value $($created.ReturnValue)."
}
Add-Content -LiteralPath $queueLog -Value "$(Get-Date -Format o) Queued close-time relaunch as PID $($created.ProcessId)."

[pscustomobject]@{
  queued = $true
  waiterPid = $created.ProcessId
  behavior = "wait-for-normal-codex-close-then-start-shim-and-relaunch-normal-app"
  queueLog = $queueLog
  launcherLog = (Join-Path $logDir "launcher.log")
} | ConvertTo-Json -Depth 4
