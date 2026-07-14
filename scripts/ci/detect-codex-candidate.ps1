[CmdletBinding()]
param(
  [string[]]$PackageNames = @("OpenAI.Codex"),
  [string]$PackageInstallLocation = "",
  [string]$PackageVersion = "",
  [string]$PackageName = "",
  [string]$PackageFullName = "",
  [string]$VerifiedManifestPath = "",
  [string]$CandidateOutputPath = "",
  [string]$CacheRoot = "",
  [string]$BaseCommit = "",
  [switch]$AllUsers
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$rootDir = Get-RepositoryRoot
if (-not $VerifiedManifestPath) {
  $VerifiedManifestPath = Join-Path $rootDir "compatibility\verified-codex.json"
}
if (-not $CandidateOutputPath) {
  $CandidateOutputPath = Join-Path $rootDir "artifacts\codex-candidate.json"
}
if (-not $CacheRoot) {
  if ($env:CODEX_CI_CACHE_ROOT) {
    $CacheRoot = $env:CODEX_CI_CACHE_ROOT
  } else {
    $programData = if ($env:ProgramData) { $env:ProgramData } else { $env:TEMP }
    $CacheRoot = Join-Path $programData "CodexShimCI\candidates"
  }
}

if (-not (Test-Path -LiteralPath $VerifiedManifestPath)) {
  throw "Verified Codex manifest was not found: $VerifiedManifestPath"
}
$verified = Get-Content -LiteralPath $VerifiedManifestPath -Raw | ConvertFrom-Json

if ($PackageInstallLocation) {
  if (-not $PackageVersion) {
    throw "-PackageVersion is required with -PackageInstallLocation."
  }
  if (-not $PackageName) {
    $PackageName = [string]$verified.packageName
  }
  if (-not $PackageFullName) {
    $PackageFullName = "$PackageName`_$PackageVersion"
  }
} else {
  $packages = @()
  foreach ($candidateName in $PackageNames) {
    if ($AllUsers) {
      $packages += @(Get-AppxPackage -AllUsers -Name $candidateName -ErrorAction SilentlyContinue)
    } else {
      $packages += @(Get-AppxPackage -Name $candidateName -ErrorAction SilentlyContinue)
    }
  }
  $package = $packages |
    Where-Object { $_.InstallLocation } |
    Sort-Object Version -Descending |
    Select-Object -First 1
  if (-not $package) {
    $scope = if ($AllUsers) { "all users" } else { "the current user" }
    throw "No supported Codex desktop package was found for $scope. Tried: $($PackageNames -join ', ')."
  }
  $PackageInstallLocation = [string]$package.InstallLocation
  $PackageVersion = $package.Version.ToString()
  $PackageName = [string]$package.Name
  $PackageFullName = [string]$package.PackageFullName
}

$appExeRelativePath = [string]$verified.appExeRelativePath
$cliRelativePath = [string]$verified.cliRelativePath
if (-not $appExeRelativePath) { $appExeRelativePath = "app\ChatGPT.exe" }
if (-not $cliRelativePath) { $cliRelativePath = "app\resources\codex.exe" }

$appExe = Join-Path $PackageInstallLocation $appExeRelativePath
$packageCli = Join-Path $PackageInstallLocation $cliRelativePath
if (-not (Test-Path -LiteralPath $appExe -PathType Leaf)) {
  throw "Candidate package is missing the desktop executable at $appExeRelativePath."
}
if (-not (Test-Path -LiteralPath $packageCli -PathType Leaf)) {
  throw "Candidate package is missing the Codex CLI at $cliRelativePath."
}

$cliSha256 = Get-FileSha256Hex -Path $packageCli
$cacheDir = Join-Path $CacheRoot $cliSha256.ToLowerInvariant()
$cachedCli = Join-Path $cacheDir "codex.exe"
New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
$copyNeeded = -not (Test-Path -LiteralPath $cachedCli -PathType Leaf)
if (-not $copyNeeded) {
  $copyNeeded = (Get-FileSha256Hex -Path $cachedCli) -ne $cliSha256
}
if ($copyNeeded) {
  Copy-Item -LiteralPath $packageCli -Destination $cachedCli -Force
}
if ((Get-FileSha256Hex -Path $cachedCli) -ne $cliSha256) {
  throw "Cached Codex CLI failed SHA-256 verification."
}

if (-not $BaseCommit) {
  $gitResult = Invoke-Git -Arguments @("rev-parse", "HEAD")
  $BaseCommit = ([string]$gitResult.Output[0]).Trim()
}

$isNew = (
  [string]$verified.packageName -ne $PackageName -or
  [string]$verified.packageVersion -ne $PackageVersion -or
  [string]$verified.cliSha256 -ne $cliSha256
)
$signatureStatus = "Unavailable"
$signerSubject = $null
try {
  Import-Module Microsoft.PowerShell.Security -ErrorAction Stop
  $signature = Get-AuthenticodeSignature -LiteralPath $packageCli -ErrorAction Stop
  $signatureStatus = $signature.Status.ToString()
  if ($signature.SignerCertificate) {
    $signerSubject = $signature.SignerCertificate.Subject
  }
} catch {
  # Signature metadata is useful evidence but is not the executable identity;
  # the SHA-256 pin remains the required validation boundary.
}
$candidate = [ordered]@{
  schemaVersion = 1
  packageName = $PackageName
  packageFullName = $PackageFullName
  packageVersion = $PackageVersion
  appExeRelativePath = $appExeRelativePath
  cliRelativePath = $cliRelativePath
  cliSha256 = $cliSha256
  cliSignatureStatus = $signatureStatus
  cliSignerSubject = $signerSubject
  baseCommit = $BaseCommit
  detectedAtUtc = [DateTime]::UtcNow.ToString("o")
  detectionSource = if ($PackageInstallLocation) { "installed-appx-or-explicit-package" } else { "installed-appx" }
}
Write-Utf8Json -Value $candidate -Path $CandidateOutputPath

Set-ActionsOutput -Name "changed" -Value $isNew.ToString().ToLowerInvariant()
Set-ActionsOutput -Name "package_name" -Value $PackageName
Set-ActionsOutput -Name "package_version" -Value $PackageVersion
Set-ActionsOutput -Name "cli_sha256" -Value $cliSha256
Set-ActionsOutput -Name "candidate_path" -Value ([IO.Path]::GetFullPath($CandidateOutputPath))

[pscustomobject]@{
  changed = $isNew
  packageName = $PackageName
  packageVersion = $PackageVersion
  cliSha256 = $cliSha256
  candidatePath = [IO.Path]::GetFullPath($CandidateOutputPath)
  cachedCli = $cachedCli
  verifiedPackageVersion = [string]$verified.packageVersion
  verifiedCliSha256 = [string]$verified.cliSha256
} | ConvertTo-Json -Depth 5
