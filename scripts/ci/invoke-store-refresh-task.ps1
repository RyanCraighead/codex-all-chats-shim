[CmdletBinding()]
param(
  [string]$TaskName = "Codex Shim CI Store Refresh",
  [string]$StatusPath = "C:\ProgramData\CodexShimCI\store-refresh-status.json",
  [int]$TimeoutSeconds = 900
)

$ErrorActionPreference = "Stop"
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) {
  throw "The interactive Store refresh task is not installed. Run scripts\ci\install-store-refresh-task.ps1 once from the Windows CI user's desktop session."
}

$startedAt = [DateTime]::UtcNow
Start-ScheduledTask -TaskName $TaskName
$deadline = $startedAt.AddSeconds($TimeoutSeconds)
do {
  Start-Sleep -Seconds 2
  if (Test-Path -LiteralPath $StatusPath -PathType Leaf) {
    $status = Get-Content -LiteralPath $StatusPath -Raw | ConvertFrom-Json
    $finishedAt = [DateTime]::Parse([string]$status.finishedAtUtc).ToUniversalTime()
    if ($finishedAt -ge $startedAt.AddSeconds(-2)) {
      if (-not [bool]$status.succeeded) {
        throw "Store refresh failed: $($status.error)"
      }
      $status | ConvertTo-Json -Depth 6
      return
    }
  }
} while ([DateTime]::UtcNow -lt $deadline)

throw "Timed out after $TimeoutSeconds seconds waiting for Store refresh task '$TaskName'."
