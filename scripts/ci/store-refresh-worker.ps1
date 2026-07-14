[CmdletBinding()]
param(
  [string]$ProductId = "9PLM9XGG6VKS",
  [string]$StatusPath = "C:\ProgramData\CodexShimCI\store-refresh-status.json",
  [string]$LogPath = "C:\ProgramData\CodexShimCI\store-refresh.log"
)

$ErrorActionPreference = "Stop"
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$startedAt = [DateTime]::UtcNow
$statusDir = Split-Path -Parent $StatusPath
$logDir = Split-Path -Parent $LogPath
New-Item -ItemType Directory -Path $statusDir -Force | Out-Null
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

function Write-RefreshStatus {
  param(
    [bool]$Succeeded,
    [string]$Operation,
    [int]$ExitCode,
    [string[]]$Output,
    [string]$ErrorMessage = ""
  )

  $tail = @(
    $Output |
      ForEach-Object {
        $line = ([string]$_) -replace "`e\[[0-9;?]*[ -/]*[@-~]", ""
        $line = $line -replace "[`b`r]", ""
        $line = $line.Trim()
        if ($line -and $line -notmatch '^[\s\-\\/|.\u2580-\u259f]+$') {
          if ($line.Length -gt 500) { $line.Substring(0, 500) } else { $line }
        }
      } |
      Select-Object -Last 40
  )
  $value = [ordered]@{
    schemaVersion = 1
    productId = $ProductId
    startedAtUtc = $startedAt.ToString("o")
    finishedAtUtc = [DateTime]::UtcNow.ToString("o")
    succeeded = $Succeeded
    operation = $Operation
    exitCode = $ExitCode
    error = $ErrorMessage
    outputTail = $tail
  }
  $json = $value | ConvertTo-Json -Depth 5
  [IO.File]::WriteAllText($StatusPath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

try {
  $winget = Get-Command winget.exe -ErrorAction Stop
  $listOutput = @(& $winget.Source list --id $ProductId --exact --source msstore --accept-source-agreements 2>&1)
  $installed = $LASTEXITCODE -eq 0
  $operation = if ($installed) { "upgrade" } else { "install" }
  $arguments = @(
    $operation,
    "--id", $ProductId,
    "--exact",
    "--source", "msstore",
    "--silent",
    "--accept-package-agreements",
    "--accept-source-agreements",
    "--disable-interactivity"
  )
  $output = @(& $winget.Source @arguments 2>&1)
  $exitCode = $LASTEXITCODE
  $allOutput = @($listOutput + $output)
  Add-Content -LiteralPath $LogPath -Value @(
    "$(Get-Date -Format o) operation=$operation product=$ProductId exitCode=$exitCode",
    ($allOutput -join [Environment]::NewLine)
  )

  # WinGet uses a nonzero result when no applicable upgrade exists. The package
  # inventory is the authoritative postcondition for this dedicated CI guest.
  $postList = @(& $winget.Source list --id $ProductId --exact --source msstore --accept-source-agreements 2>&1)
  $postListExitCode = $LASTEXITCODE
  if ($postListExitCode -ne 0) {
    Write-RefreshStatus -Succeeded $false -Operation $operation -ExitCode $exitCode -Output @($allOutput + $postList) -ErrorMessage "The Store product was not installed after refresh."
    exit 1
  }
  Write-RefreshStatus -Succeeded $true -Operation $operation -ExitCode $exitCode -Output @($allOutput + $postList)
} catch {
  Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format o) ERROR: $($_.Exception.Message)"
  Write-RefreshStatus -Succeeded $false -Operation "unknown" -ExitCode 1 -Output @() -ErrorMessage $_.Exception.Message
  exit 1
}
