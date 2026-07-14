[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$CandidatePath,
  [Parameter(Mandatory = $true)][string]$ValidationReportPath,
  [string]$Remote = "origin",
  [string]$MainBranch = "main",
  [string]$GitUserName = "Codex compatibility bot",
  [string]$GitUserEmail = "codex-compatibility@localhost"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Get-RequiredString {
  param(
    [Parameter(Mandatory = $true)]$Value,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $text = [string]$Value
  if (-not $text) {
    throw "Validation report is missing $Name."
  }
  return $text
}

function Select-CheckEvidence {
  param([Parameter(Mandatory = $true)]$Check)

  $returnedThreadCount = $Check.PSObject.Properties["returnedThreadCount"]
  $uniqueThreadCount = $Check.PSObject.Properties["uniqueThreadCount"]
  $pageCount = $Check.PSObject.Properties["pageCount"]
  $threadReadPassed = $Check.PSObject.Properties["threadReadPassed"]
  $nextCursorIsNull = $Check.PSObject.Properties["nextCursorIsNull"]
  $durationMs = $Check.PSObject.Properties["durationMs"]
  return [ordered]@{
    passed = [bool]$Check.passed
    returnedThreadCount = if ($returnedThreadCount) { [int]$returnedThreadCount.Value } else { $null }
    uniqueThreadCount = if ($uniqueThreadCount) { [int]$uniqueThreadCount.Value } else { $null }
    pageCount = if ($pageCount) { [int]$pageCount.Value } else { $null }
    threadReadPassed = if ($threadReadPassed) { [bool]$threadReadPassed.Value } else { $null }
    nextCursorIsNull = if ($nextCursorIsNull) { [bool]$nextCursorIsNull.Value } else { $null }
    durationMs = if ($durationMs) { [int64]$durationMs.Value } else { $null }
  }
}

$rootDir = Get-RepositoryRoot
foreach ($path in @($CandidatePath, $ValidationReportPath)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Required promotion input was not found: $path"
  }
}

$candidate = Get-Content -LiteralPath $CandidatePath -Raw | ConvertFrom-Json
$report = Get-Content -LiteralPath $ValidationReportPath -Raw | ConvertFrom-Json
if (-not [bool]$report.passed) {
  throw "The candidate cannot be promoted because validation did not pass."
}

$candidateName = Get-RequiredString -Value $candidate.packageName -Name "candidate packageName"
$candidateVersion = Get-RequiredString -Value $candidate.packageVersion -Name "candidate packageVersion"
$candidateHash = (Get-RequiredString -Value $candidate.cliSha256 -Name "candidate cliSha256").ToUpperInvariant()
$baseCommit = Get-RequiredString -Value $candidate.baseCommit -Name "candidate baseCommit"
$reportName = Get-RequiredString -Value $report.packageName -Name "packageName"
$reportVersion = Get-RequiredString -Value $report.packageVersion -Name "packageVersion"
$reportHash = (Get-RequiredString -Value $report.cliSha256 -Name "cliSha256").ToUpperInvariant()

if ($candidateName -ne $reportName -or $candidateVersion -ne $reportVersion -or $candidateHash -ne $reportHash) {
  throw "Validation evidence does not identify the candidate being promoted."
}
$directReport = $report.checks.directAppServer
$shimReport = $report.checks.shim
$exactGatePassed = (
  [int]$report.fixtureThreadCount -eq 125 -and
  [bool]$directReport.passed -and
  [int]$directReport.returnedThreadCount -eq 125 -and
  [int]$directReport.pageCount -eq 2 -and
  [int]$directReport.uniqueThreadCount -eq 125 -and
  [bool]$directReport.threadReadPassed -and
  [bool]$directReport.nextCursorIsNull -and
  [bool]$shimReport.passed -and
  [int]$shimReport.returnedThreadCount -eq 125 -and
  [int]$shimReport.pageCount -eq 2 -and
  [int]$shimReport.uniqueThreadCount -eq 125 -and
  [bool]$shimReport.nextCursorIsNull -and
  $report.validation -and
  [bool]$report.validation.wrapperPassed -and
  [bool]$report.validation.candidateManifestSchemaValidated -and
  [bool]$report.validation.cacheSha256Verified -and
  [bool]$report.validation.nodeReportShapeValidated -and
  [int]$report.validation.nodeExitCode -eq 0
)
if (-not $exactGatePassed) {
  throw "Candidate did not satisfy the exact 125-task direct app-server and shim promotion gate."
}

$versionPart = ConvertTo-BranchComponent -Value $candidateVersion
$hashPart = $candidateHash.Substring(0, 8).ToLowerInvariant()
$evidenceRelativePath = "compatibility/verification/$versionPart-$hashPart.json"
$evidencePath = Join-Path $rootDir ($evidenceRelativePath -replace '/', '\')
$verifiedPath = Join-Path $rootDir "compatibility\verified-codex.json"
$candidateRepositoryPath = Join-Path $rootDir "compatibility\candidate.json"

Push-Location $rootDir
try {
  $status = (Invoke-Git -Arguments @("status", "--porcelain")).Output
  if (@($status).Count -gt 0) {
    throw "Candidate checkout is not clean; refusing automated promotion.`n$($status -join [Environment]::NewLine)"
  }

  $candidateCommit = ([string](Invoke-Git -Arguments @("rev-parse", "HEAD")).Output[0]).Trim()
  $candidateBranch = ([string](Invoke-Git -Arguments @("branch", "--show-current")).Output[0]).Trim()
  if ($candidateBranch -notlike "automation/codex-candidate/*") {
    throw "Promotion must run from an immutable automation/codex-candidate branch. Current branch: $candidateBranch"
  }

  Invoke-Git -Arguments @("fetch", $Remote, $MainBranch, "--prune") | Out-Null
  $remoteMain = ([string](Invoke-Git -Arguments @("rev-parse", "$Remote/$MainBranch")).Output[0]).Trim()
  if ($remoteMain -ne $baseCommit) {
    throw "Candidate is stale: its base is $baseCommit but $Remote/$MainBranch is $remoteMain. A later monitor run will create a fresh candidate."
  }
  $ancestor = Invoke-Git -Arguments @("merge-base", "--is-ancestor", $baseCommit, "HEAD") -AllowFailure
  if ($ancestor.ExitCode -ne 0) {
    throw "Candidate commit is not descended from its declared base commit."
  }

  $directEvidence = Select-CheckEvidence -Check $report.checks.directAppServer
  $shimEvidence = Select-CheckEvidence -Check $report.checks.shim
  $validatedAtUtc = Get-RequiredString -Value $report.validatedAtUtc -Name "validatedAtUtc"
  $evidence = [ordered]@{
    schemaVersion = 1
    passed = $true
    packageName = $candidateName
    packageVersion = $candidateVersion
    cliSha256 = $candidateHash
    validatedAtUtc = $validatedAtUtc
    fixtureThreadCount = [int]$report.fixtureThreadCount
    checks = [ordered]@{
      directAppServer = $directEvidence
      shim = $shimEvidence
    }
    source = [ordered]@{
      baseCommit = $baseCommit
      candidateCommit = $candidateCommit
      candidateBranch = $candidateBranch
      giteaRunId = [string]$env:GITEA_RUN_ID
      giteaRunNumber = [string]$env:GITEA_RUN_NUMBER
    }
  }
  Write-Utf8Json -Value $evidence -Path $evidencePath -Depth 8

  $verified = [ordered]@{
    schemaVersion = 1
    packageName = $candidateName
    packageFullName = [string]$candidate.packageFullName
    packageVersion = $candidateVersion
    appExeRelativePath = [string]$candidate.appExeRelativePath
    cliRelativePath = [string]$candidate.cliRelativePath
    cliSha256 = $candidateHash
    verifiedAtUtc = $validatedAtUtc
    verification = [ordered]@{
      provenance = "gitea-windows-automation"
      baseCommit = $baseCommit
      candidateCommit = $candidateCommit
      candidateBranch = $candidateBranch
      evidencePath = $evidenceRelativePath
      fixtureThreadCount = [int]$report.fixtureThreadCount
      directAppServer = $directEvidence
      shim = $shimEvidence
    }
  }
  Write-Utf8Json -Value $verified -Path $verifiedPath -Depth 8
  Remove-Item -LiteralPath $candidateRepositoryPath -Force

  Invoke-Git -Arguments @("add", "compatibility/verified-codex.json", $evidenceRelativePath, "compatibility/candidate.json") | Out-Null
  Invoke-Git -Arguments @(
    "-c", "user.name=$GitUserName",
    "-c", "user.email=$GitUserEmail",
    "commit", "-m", "Verify Codex $candidateVersion ($hashPart)"
  ) | Out-Null
  $promotionCommit = ([string](Invoke-Git -Arguments @("rev-parse", "HEAD")).Output[0]).Trim()

  # This is intentionally a normal fast-forward push. If main changed after the
  # comparison above, Git rejects the push instead of overwriting newer work.
  Invoke-Git -Arguments @("push", $Remote, "HEAD:refs/heads/$MainBranch") | Out-Null

  $tagName = "codex-verified/$versionPart-$hashPart"
  $remoteTag = Invoke-Git -Arguments @("ls-remote", "--exit-code", "--tags", $Remote, "refs/tags/$tagName") -AllowFailure
  if ($remoteTag.ExitCode -ne 0) {
    Invoke-Git -Arguments @(
      "-c", "user.name=$GitUserName",
      "-c", "user.email=$GitUserEmail",
      "tag", "-a", $tagName, "-m", "Verified Codex $candidateVersion"
    ) | Out-Null
    Invoke-Git -Arguments @("push", $Remote, "refs/tags/$tagName") | Out-Null
  }

  Set-ActionsOutput -Name "promoted" -Value "true"
  Set-ActionsOutput -Name "promotion_commit" -Value $promotionCommit
  Set-ActionsOutput -Name "verified_tag" -Value $tagName
  [pscustomobject]@{
    promoted = $true
    packageVersion = $candidateVersion
    cliSha256 = $candidateHash
    promotionCommit = $promotionCommit
    tag = $tagName
    evidencePath = $evidenceRelativePath
  } | ConvertTo-Json -Depth 5
} finally {
  Pop-Location
}
