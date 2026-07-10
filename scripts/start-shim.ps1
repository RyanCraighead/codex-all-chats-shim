[CmdletBinding()]
param(
  [string]$ConfigPath = "",
  [string]$CodexHome = "",
  [switch]$Restart
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
if (-not $CodexHome) {
  $CodexHome = Join-Path $env:USERPROFILE ".codex"
}
$CodexHome = [IO.Path]::GetFullPath($CodexHome)
$upstreamCli = [IO.Path]::GetFullPath([string]$config.upstreamCliPath)
$hostName = [string]$config.host
$port = [int]$config.port
$healthUrl = "http://${hostName}:$port/health"
$shimScript = Join-Path $rootDir "src\catalog-shim.cjs"
$logDir = Join-Path $rootDir "logs"
$logPath = Join-Path $logDir "catalog-shim.log"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

function Get-ShimHealth {
  try {
    return Invoke-RestMethod -Uri $healthUrl -Method Get -TimeoutSec 2
  } catch {
    return $null
  }
}

$health = Get-ShimHealth
if ($health -and -not $Restart) {
  if ([IO.Path]::GetFullPath([string]$health.codexHome) -ne $CodexHome) {
    throw "A shim is already running for $($health.codexHome), not $CodexHome. Use -Restart."
  }
  if ([string]$health.upstreamCliSha256 -ne [string]$config.upstreamCliSha256) {
    throw "A shim for a different Codex CLI is already using port $port. Use -Restart."
  }
  $health | ConvertTo-Json -Depth 5
  return
}
if ($health -and $Restart) {
  Stop-Process -Id ([int]$health.pid) -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 500
}

if (-not (Test-Path -LiteralPath $upstreamCli)) {
  throw "Configured Codex CLI was not found. Run npm run setup again: $upstreamCli"
}
$actualHash = (Get-FileHash -LiteralPath $upstreamCli -Algorithm SHA256).Hash
if ($actualHash -ne [string]$config.upstreamCliSha256) {
  throw "Configured Codex CLI hash mismatch. Run npm run setup again."
}

$tokenBytes = New-Object byte[] 32
$random = [Security.Cryptography.RandomNumberGenerator]::Create()
try {
  $random.GetBytes($tokenBytes)
} finally {
  $random.Dispose()
}
$shimToken = -join ($tokenBytes | ForEach-Object { $_.ToString("x2") })
$node = Get-Command node.exe -ErrorAction Stop

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $node.Source
$startInfo.Arguments = '"' + $shimScript.Replace('"', '\"') + '"'
$startInfo.WorkingDirectory = $rootDir
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
$startInfo.EnvironmentVariables["CODEX_CATALOG_SHIM_CONFIG"] = [IO.Path]::GetFullPath($ConfigPath)
$startInfo.EnvironmentVariables["CODEX_CATALOG_SHIM_CODEX_HOME"] = $CodexHome
$startInfo.EnvironmentVariables["CODEX_CATALOG_SHIM_SQLITE_HOME"] = $CodexHome
$startInfo.EnvironmentVariables["CODEX_CATALOG_SHIM_UPSTREAM_CLI"] = $upstreamCli
$startInfo.EnvironmentVariables["CODEX_CATALOG_SHIM_EXPECTED_CLI_SHA256"] = [string]$config.upstreamCliSha256
$startInfo.EnvironmentVariables["CODEX_CATALOG_SHIM_HOST"] = $hostName
$startInfo.EnvironmentVariables["CODEX_CATALOG_SHIM_PORT"] = [string]$port
$startInfo.EnvironmentVariables["CODEX_CATALOG_SHIM_MAX_THREADS"] = [string]$config.maxThreads
$startInfo.EnvironmentVariables["CODEX_CATALOG_SHIM_TOKEN"] = $shimToken
$startInfo.EnvironmentVariables["CODEX_CATALOG_SHIM_LOG"] = $logPath
$startInfo.EnvironmentVariables["CODEX_CATALOG_SHIM_QUIET"] = "1"
$process = [System.Diagnostics.Process]::Start($startInfo)

$deadline = [DateTime]::UtcNow.AddSeconds(15)
do {
  Start-Sleep -Milliseconds 200
  $health = Get-ShimHealth
  if ($health) {
    $health | ConvertTo-Json -Depth 5
    return
  }
} while ([DateTime]::UtcNow -lt $deadline -and -not $process.HasExited)

$tail = if (Test-Path -LiteralPath $logPath) {
  (Get-Content -LiteralPath $logPath -Tail 25) -join [Environment]::NewLine
} else {
  "No shim log was created."
}
throw "Catalog shim failed to start.`n$tail"
