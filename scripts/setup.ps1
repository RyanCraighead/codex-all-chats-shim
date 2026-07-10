[CmdletBinding()]
param(
  [int]$Port = 47850,
  [int]$MaxThreads = 10000,
  [switch]$SkipShortcut
)

$ErrorActionPreference = "Stop"
$rootDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$configPath = Join-Path $rootDir "config.local.json"

$package = Get-AppxPackage -Name "OpenAI.Codex" |
  Sort-Object Version -Descending |
  Select-Object -First 1
if (-not $package) {
  throw "The installed OpenAI.Codex package was not found. Install and launch Codex once, then rerun setup."
}

$appRelativePath = "app\ChatGPT.exe"
$cliRelativePath = "app\resources\codex.exe"
$appExe = Join-Path $package.InstallLocation $appRelativePath
$packageCli = Join-Path $package.InstallLocation $cliRelativePath
if (-not (Test-Path -LiteralPath $appExe)) {
  throw "Codex app executable was not found: $appExe"
}
if (-not (Test-Path -LiteralPath $packageCli)) {
  throw "Codex CLI was not found: $packageCli"
}

$cliHash = (Get-FileHash -LiteralPath $packageCli -Algorithm SHA256).Hash.ToUpperInvariant()
$runtimeDir = Join-Path $env:LOCALAPPDATA "CodexAllChatsShim\bin\$($cliHash.ToLowerInvariant())"
$runtimeCli = Join-Path $runtimeDir "codex.exe"
New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null

$copySource = $packageCli
$relocatedRoot = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin"
$relocatedCli = Get-ChildItem -LiteralPath $relocatedRoot -Recurse -Filter codex.exe -ErrorAction SilentlyContinue |
  Where-Object {
    (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash -eq $cliHash
  } |
  Select-Object -First 1
if ($relocatedCli) {
  $copySource = $relocatedCli.FullName
}

$copyNeeded = -not (Test-Path -LiteralPath $runtimeCli)
if (-not $copyNeeded) {
  $copyNeeded = (Get-FileHash -LiteralPath $runtimeCli -Algorithm SHA256).Hash -ne $cliHash
}
if ($copyNeeded) {
  Copy-Item -LiteralPath $copySource -Destination $runtimeCli -Force
}
if ((Get-FileHash -LiteralPath $runtimeCli -Algorithm SHA256).Hash -ne $cliHash) {
  throw "The user-owned Codex CLI copy failed SHA-256 verification."
}

$config = [ordered]@{
  schemaVersion = 1
  packageName = "OpenAI.Codex"
  packageVersion = $package.Version.ToString()
  appExeRelativePath = $appRelativePath
  upstreamCliPath = $runtimeCli
  upstreamCliSha256 = $cliHash
  host = "127.0.0.1"
  port = $Port
  maxThreads = $MaxThreads
}
$json = $config | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText($configPath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

$node = Get-Command node.exe -ErrorAction Stop
$npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
$npmCli = if ($npm) { Join-Path (Split-Path -Parent $npm.Source) "npm-cli.js" } else { "" }
if ($npmCli -and (Test-Path -LiteralPath $npmCli)) {
  & $node.Source $npmCli install --ignore-scripts
} else {
  $npm = Get-Command npm -ErrorAction Stop
  & $npm.Source install --ignore-scripts
}
if ($LASTEXITCODE -ne 0) {
  throw "npm install failed with exit code $LASTEXITCODE."
}

$shortcut = $null
if (-not $SkipShortcut) {
  $shortcut = & (Join-Path $PSScriptRoot "create-shortcut.ps1") -ConfigPath $configPath | ConvertFrom-Json
}

[pscustomobject]@{
  configured = $true
  packageVersion = $config.packageVersion
  cliSha256 = $cliHash
  runtimeCli = $runtimeCli
  configPath = $configPath
  shortcutPath = $shortcut.shortcutPath
} | ConvertTo-Json -Depth 4
