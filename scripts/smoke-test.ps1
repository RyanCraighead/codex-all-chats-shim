[CmdletBinding()]
param([switch]$RestartShim)

$ErrorActionPreference = "Stop"
$rootDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$configPath = Join-Path $rootDir "config.local.json"
if (-not (Test-Path -LiteralPath $configPath)) {
  throw "Local configuration is missing. Run npm run setup first."
}
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$args = @{ ConfigPath = $configPath }
if ($RestartShim) { $args.Restart = $true }
$healthJson = & (Join-Path $PSScriptRoot "start-shim.ps1") @args
$health = $healthJson | ConvertFrom-Json
$url = "ws://$($config.host):$($config.port)$($health.wsPath)"
& node (Join-Path $rootDir "test\live-smoke.cjs") $url
if ($LASTEXITCODE -ne 0) {
  throw "Live smoke test failed with exit code $LASTEXITCODE."
}
