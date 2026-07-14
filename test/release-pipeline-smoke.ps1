[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$tempBase = [IO.Path]::GetTempPath().TrimEnd('\', '/')
$root = Join-Path $tempBase ("codex-release-pipeline-test-" + [guid]::NewGuid().ToString("N"))
$root = [IO.Path]::GetFullPath($root)
$expectedPrefix = [IO.Path]::GetFullPath((Join-Path $tempBase "codex-release-pipeline-test-"))
if (-not $root.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Refusing to use an unsafe release-pipeline test directory."
}

$repo = Join-Path $root "repo"
$bare = Join-Path $root "remote.git"
$fakePackage = Join-Path $root "fake-package"
$cache = Join-Path $root "cache"
$candidatePath = Join-Path $root "candidate.json"
$reportPath = Join-Path $root "validation.json"

function Invoke-TestGit {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)

  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = @(& git @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  if ($exitCode -ne 0) {
    throw "git $($Arguments -join ' ') failed.`n$($output -join [Environment]::NewLine)"
  }
  return $output
}

try {
  New-Item -ItemType Directory -Path $repo -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $repo "scripts\ci") -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $repo "compatibility") -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $fakePackage "app\resources") -Force | Out-Null

  $ciScripts = @(
    "common.ps1",
    "detect-codex-candidate.ps1",
    "create-candidate-branch.ps1",
    "promote-verified-candidate.ps1"
  )
  foreach ($script in $ciScripts) {
    Copy-Item `
      -LiteralPath (Join-Path $sourceRoot "scripts\ci\$script") `
      -Destination (Join-Path $repo "scripts\ci\$script")
  }
  Copy-Item `
    -LiteralPath (Join-Path $sourceRoot "compatibility\verified-codex.json") `
    -Destination (Join-Path $repo "compatibility\verified-codex.json")
  Copy-Item -LiteralPath $env:ComSpec -Destination (Join-Path $fakePackage "app\ChatGPT.exe")
  Copy-Item -LiteralPath $env:ComSpec -Destination (Join-Path $fakePackage "app\resources\codex.exe")

  Invoke-TestGit -Arguments @("init", "--bare", $bare) | Out-Null
  Invoke-TestGit -Arguments @("-C", $repo, "init", "-b", "main") | Out-Null
  Invoke-TestGit -Arguments @("-C", $repo, "add", ".") | Out-Null
  Invoke-TestGit -Arguments @(
    "-C", $repo,
    "-c", "user.name=Release pipeline test",
    "-c", "user.email=release-pipeline@example.invalid",
    "commit", "-m", "Initial test state"
  ) | Out-Null
  Invoke-TestGit -Arguments @("-C", $repo, "remote", "add", "origin", $bare) | Out-Null
  Invoke-TestGit -Arguments @("-C", $repo, "push", "-u", "origin", "main") | Out-Null
  $baseOutput = @(Invoke-TestGit -Arguments @("-C", $repo, "rev-parse", "HEAD"))
  $baseCommit = ([string]$baseOutput[0]).Trim()

  & (Join-Path $repo "scripts\ci\detect-codex-candidate.ps1") `
    -PackageInstallLocation $fakePackage `
    -PackageVersion "99.1.2.3" `
    -PackageName "OpenAI.Codex" `
    -PackageFullName "OpenAI.Codex_99.1.2.3_x64__test" `
    -BaseCommit $baseCommit `
    -CacheRoot $cache `
    -CandidateOutputPath $candidatePath | Out-Null

  & (Join-Path $repo "scripts\ci\create-candidate-branch.ps1") `
    -CandidatePath $candidatePath | Out-Null

  $repositoryCandidatePath = Join-Path $repo "compatibility\candidate.json"
  $candidate = Get-Content -LiteralPath $repositoryCandidatePath -Raw | ConvertFrom-Json
  $validation = [ordered]@{
    schemaVersion = 1
    test = "real-offline-codex-pagination"
    passed = $true
    packageName = [string]$candidate.packageName
    packageVersion = [string]$candidate.packageVersion
    cliSha256 = [string]$candidate.cliSha256
    validatedAtUtc = [DateTime]::UtcNow.ToString("o")
    fixtureThreadCount = 125
    checks = [ordered]@{
      directAppServer = [ordered]@{
        passed = $true
        returnedThreadCount = 125
        uniqueThreadCount = 125
        pageCount = 2
        threadReadPassed = $true
        nextCursorIsNull = $true
      }
      shim = [ordered]@{
        passed = $true
        returnedThreadCount = 125
        uniqueThreadCount = 125
        pageCount = 2
        nextCursorIsNull = $true
      }
    }
    validation = [ordered]@{
      wrapperPassed = $true
      candidateManifestSchemaValidated = $true
      cacheSha256Verified = $true
      nodeReportShapeValidated = $true
      nodeExitCode = 0
    }
  }
  [IO.File]::WriteAllText(
    $reportPath,
    ($validation | ConvertTo-Json -Depth 10) + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false)
  )

  & (Join-Path $repo "scripts\ci\promote-verified-candidate.ps1") `
    -CandidatePath $repositoryCandidatePath `
    -ValidationReportPath $reportPath | Out-Null

  $remoteMainOutput = @(Invoke-TestGit -Arguments @(
    "--git-dir=$bare", "rev-parse", "refs/heads/main"
  ))
  $remoteMain = ([string]$remoteMainOutput[0]).Trim()
  $verifiedText = Invoke-TestGit -Arguments @(
    "--git-dir=$bare", "show", "$remoteMain`:compatibility/verified-codex.json"
  )
  $verified = ($verifiedText -join [Environment]::NewLine) | ConvertFrom-Json
  $tags = @(Invoke-TestGit -Arguments @("--git-dir=$bare", "tag", "-l", "codex-verified/*"))

  if ([string]$verified.packageVersion -ne "99.1.2.3") {
    throw "The promoted manifest contains the wrong package version."
  }
  if ([int]$verified.verification.fixtureThreadCount -ne 125) {
    throw "The promoted manifest is missing the exact fixture count."
  }
  if ($tags.Count -ne 1) {
    throw "Expected exactly one verified tag, found $($tags.Count)."
  }

  $candidateBranchOutput = @(Invoke-TestGit -Arguments @(
    "-C", $repo, "branch", "--show-current"
  ))
  [pscustomobject]@{
    test = "release-pipeline-smoke"
    passed = $true
    candidateBranch = ([string]$candidateBranchOutput[0]).Trim()
    verifiedVersion = [string]$verified.packageVersion
    fixtureThreadCount = [int]$verified.verification.fixtureThreadCount
    verifiedTagCount = $tags.Count
  } | ConvertTo-Json -Depth 4
} finally {
  if (Test-Path -LiteralPath $root) {
    Remove-Item -LiteralPath $root -Recurse -Force
  }
}
