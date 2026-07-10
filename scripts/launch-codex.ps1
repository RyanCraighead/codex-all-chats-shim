[CmdletBinding()]
param(
  [string]$ConfigPath = "",
  [switch]$WaitForClose,
  [int]$WaitTimeoutSeconds = 0,
  [switch]$RestartShim
)

$ErrorActionPreference = "Stop"
$rootDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if (-not $ConfigPath) {
  $ConfigPath = Join-Path $rootDir "config.local.json"
}
if (-not (Test-Path -LiteralPath $ConfigPath)) {
  throw "Local configuration is missing. Run npm run setup first."
}
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$logDir = Join-Path $rootDir "logs"
$logPath = Join-Path $logDir "launcher.log"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

function Write-LauncherLog {
  param([string]$Message)
  Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format o) $Message"
}
trap {
  $message = $_.Exception.Message
  Write-LauncherLog "ERROR: $message"
  Write-Error $message
  exit 1
}

$package = Get-AppxPackage -Name ([string]$config.packageName) |
  Sort-Object Version -Descending |
  Select-Object -First 1
if (-not $package) {
  throw "Installed package $($config.packageName) was not found."
}
if ($package.Version.ToString() -ne [string]$config.packageVersion) {
  throw "Codex updated from pinned version $($config.packageVersion) to $($package.Version). Run npm run setup and retest."
}
$appExe = [IO.Path]::GetFullPath(
  (Join-Path $package.InstallLocation ([string]$config.appExeRelativePath))
)
if (-not (Test-Path -LiteralPath $appExe)) {
  throw "Installed Codex executable was not found: $appExe"
}

function Get-NormalCodexRootProcesses {
  return @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($appExe)) -ErrorAction SilentlyContinue |
    Where-Object {
      if ($_.MainWindowHandle -eq 0) { return $false }
      try { return (-not $_.Path) -or ($_.Path -ieq $appExe) } catch { return $true }
    })
}

$existing = @(Get-NormalCodexRootProcesses)
if ($existing.Count -gt 0 -and -not $WaitForClose) {
  throw "The normal Codex app is already running. Close it first or use npm run queue."
}
if ($existing.Count -gt 0) {
  Write-LauncherLog "Waiting for normal Codex to close. Root PIDs: $($existing.Id -join ', ')."
  $startedWaiting = [DateTime]::UtcNow
  while (@(Get-NormalCodexRootProcesses).Count -gt 0) {
    if ($WaitTimeoutSeconds -gt 0 -and ([DateTime]::UtcNow - $startedWaiting).TotalSeconds -ge $WaitTimeoutSeconds) {
      throw "Timed out waiting for normal Codex to close."
    }
    Start-Sleep -Milliseconds 500
  }
  Start-Sleep -Milliseconds 1000
}

$shimArgs = @{ ConfigPath = $ConfigPath }
if ($RestartShim) { $shimArgs.Restart = $true }
$shimHealthJson = & (Join-Path $PSScriptRoot "start-shim.ps1") @shimArgs
$shimHealth = $shimHealthJson | ConvertFrom-Json
$shimUrl = "ws://$($config.host):$($config.port)$($shimHealth.wsPath)"
Write-LauncherLog "Catalog shim ready at its tokenized loopback endpoint, PID $($shimHealth.pid)."

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $appExe
$startInfo.WorkingDirectory = Split-Path -Parent $appExe
$startInfo.UseShellExecute = $false
$startInfo.EnvironmentVariables["CODEX_APP_SERVER_WS_URL"] = $shimUrl
[void]$startInfo.EnvironmentVariables.Remove("CODEX_APP_SERVER_FORCE_CLI")
$process = [System.Diagnostics.Process]::Start($startInfo)
Write-LauncherLog "Launched installed normal Codex PID $($process.Id) with its default profile."

[pscustomobject]@{
  appPid = $process.Id
  appExe = $appExe
  packageVersion = $package.Version.ToString()
  profile = "default"
  shimPid = $shimHealth.pid
  shimUrl = $shimUrl
  launcherLog = $logPath
} | ConvertTo-Json -Depth 4
