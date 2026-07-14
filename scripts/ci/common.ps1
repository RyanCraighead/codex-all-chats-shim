Set-StrictMode -Version Latest
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop

function Get-FileSha256Hex {
  param([Parameter(Mandatory = $true)][string]$Path)

  $stream = [IO.File]::OpenRead([IO.Path]::GetFullPath($Path))
  try {
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
      $bytes = $sha256.ComputeHash($stream)
    } finally {
      $sha256.Dispose()
    }
  } finally {
    $stream.Dispose()
  }
  return ([BitConverter]::ToString($bytes)).Replace("-", "").ToUpperInvariant()
}

function Get-RepositoryRoot {
  return (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

function Write-Utf8Json {
  param(
    [Parameter(Mandatory = $true)]$Value,
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$Depth = 8
  )

  $parent = Split-Path -Parent $Path
  if ($parent) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $json = $Value | ConvertTo-Json -Depth $Depth
  [IO.File]::WriteAllText(
    [IO.Path]::GetFullPath($Path),
    $json + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false)
  )
}

function Set-ActionsOutput {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
  )

  if (-not $env:GITHUB_OUTPUT) {
    return
  }
  Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$Name=$Value"
}

function ConvertTo-BranchComponent {
  param([Parameter(Mandatory = $true)][string]$Value)

  $normalized = $Value.ToLowerInvariant() -replace '[^a-z0-9._-]+', '-'
  $normalized = $normalized.Trim('-', '.', '_')
  if (-not $normalized) {
    throw "Value cannot be converted into a branch-name component."
  }
  return $normalized
}

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [switch]$AllowFailure
  )

  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = @(& git @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  if ($exitCode -ne 0 -and -not $AllowFailure) {
    throw "git $($Arguments -join ' ') failed with exit code $exitCode.`n$($output -join [Environment]::NewLine)"
  }
  return [pscustomobject]@{
    ExitCode = $exitCode
    Output = $output
  }
}
