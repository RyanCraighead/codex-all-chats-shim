[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$CandidatePath,
  [string]$Remote = "origin",
  [string]$BranchPrefix = "automation/codex-candidate",
  [string]$GitUserName = "Codex compatibility bot",
  [string]$GitUserEmail = "codex-compatibility@localhost"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$rootDir = Get-RepositoryRoot
if (-not (Test-Path -LiteralPath $CandidatePath -PathType Leaf)) {
  throw "Candidate manifest was not found: $CandidatePath"
}
$candidate = Get-Content -LiteralPath $CandidatePath -Raw | ConvertFrom-Json
$versionPart = ConvertTo-BranchComponent -Value ([string]$candidate.packageVersion)
$hashPart = ([string]$candidate.cliSha256).Substring(0, 8).ToLowerInvariant()
$basePart = ([string]$candidate.baseCommit).Substring(0, 8).ToLowerInvariant()
$branchName = "$($BranchPrefix.TrimEnd('/'))/$versionPart-$hashPart-$basePart"
$branchRef = "refs/heads/$branchName"

Push-Location $rootDir
try {
  Invoke-Git -Arguments @("fetch", $Remote, "main", "--prune") | Out-Null
  $remoteMain = (Invoke-Git -Arguments @("rev-parse", "$Remote/main")).Output[0].Trim()
  if ($remoteMain -ne [string]$candidate.baseCommit) {
    throw "Candidate base $($candidate.baseCommit) no longer matches $Remote/main $remoteMain. Run detection again."
  }

  $existing = Invoke-Git -Arguments @("ls-remote", "--exit-code", "--heads", $Remote, $branchRef) -AllowFailure
  if ($existing.ExitCode -eq 0) {
    Set-ActionsOutput -Name "created" -Value "false"
    Set-ActionsOutput -Name "branch" -Value $branchName
    [pscustomobject]@{ created = $false; branch = $branchName; reason = "already-exists" } |
      ConvertTo-Json -Depth 3
    return
  }

  Invoke-Git -Arguments @("switch", "--create", $branchName, $remoteMain) | Out-Null
  $destination = Join-Path $rootDir "compatibility\candidate.json"
  Copy-Item -LiteralPath $CandidatePath -Destination $destination -Force
  Invoke-Git -Arguments @("add", "compatibility/candidate.json") | Out-Null
  Invoke-Git -Arguments @(
    "-c", "user.name=$GitUserName",
    "-c", "user.email=$GitUserEmail",
    "commit", "-m", "Test Codex $($candidate.packageVersion) candidate"
  ) | Out-Null
  Invoke-Git -Arguments @("push", $Remote, "HEAD:$branchRef") | Out-Null

  Set-ActionsOutput -Name "created" -Value "true"
  Set-ActionsOutput -Name "branch" -Value $branchName
  [pscustomobject]@{ created = $true; branch = $branchName; baseCommit = $remoteMain } |
    ConvertTo-Json -Depth 3
} finally {
  Pop-Location
}
