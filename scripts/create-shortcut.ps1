[CmdletBinding()]
param(
  [string]$ConfigPath = "",
  [string]$ShortcutName = "Codex - All Chats",
  [string]$ShortcutDirectory = ""
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
if (-not $ShortcutDirectory) {
  $ShortcutDirectory = [Environment]::GetFolderPath("Desktop")
}
if (-not $ShortcutDirectory) {
  $ShortcutDirectory = Join-Path $env:USERPROFILE "Desktop"
}

$package = Get-AppxPackage -Name ([string]$config.packageName) |
  Sort-Object Version -Descending |
  Select-Object -First 1
if (-not $package) { throw "Installed package $($config.packageName) was not found." }
if ($package.Version.ToString() -ne [string]$config.packageVersion) {
  throw "Codex version changed. Run npm run setup before recreating the shortcut."
}
$iconPath = Join-Path $package.InstallLocation ([string]$config.appExeRelativePath)
$launcher = Join-Path $PSScriptRoot "launch-codex.ps1"
$powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

New-Item -ItemType Directory -Path $ShortcutDirectory -Force | Out-Null
$safeName = $ShortcutName -replace '[<>:"/\\|?*]', '-'
$shortcutPath = Join-Path $ShortcutDirectory "$safeName.lnk"
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powershellExe
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcher`""
$shortcut.WorkingDirectory = $rootDir
$shortcut.Description = "Launch the installed normal Codex app through the all-chat catalog shim."
$shortcut.IconLocation = "$iconPath,0"
$shortcut.Save()

[pscustomobject]@{
  shortcutPath = $shortcutPath
  targetPath = $shortcut.TargetPath
  profile = "normal-installed-app"
} | ConvertTo-Json -Depth 3
