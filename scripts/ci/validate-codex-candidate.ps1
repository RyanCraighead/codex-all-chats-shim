[CmdletBinding()]
param(
  [Alias("CandidatePath", "ManifestPath")]
  [string]$CandidateManifestPath = "",

  [Alias("CandidateCacheRoot")]
  [string]$CacheRoot = "",

  [Alias("OutputPath")]
  [string]$ReportPath = "",

  [switch]$KeepFixture,

  [string]$NodeExecutable = "node",

  [ValidateRange(1000, 600000)]
  [int]$TimeoutMs = 60000
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function New-ValidationReport {
  param(
    [AllowNull()][string]$PackageName,
    [AllowNull()][string]$PackageVersion,
    [AllowNull()][string]$CliSha256
  )

  return [pscustomobject][ordered]@{
    schemaVersion = 1
    test = "real-offline-codex-pagination"
    passed = $false
    packageName = $PackageName
    packageVersion = $PackageVersion
    cliSha256 = $CliSha256
    validatedAtUtc = [DateTime]::UtcNow.ToString("o")
    fixtureThreadCount = 125
    checks = [pscustomobject][ordered]@{
      directAppServer = [pscustomobject][ordered]@{
        passed = $false
        returnedThreadCount = 0
        pageCount = 0
        uniqueThreadCount = 0
        threadReadPassed = $false
        nextCursorIsNull = $false
      }
      shim = [pscustomobject][ordered]@{
        passed = $false
        returnedThreadCount = 0
        pageCount = 0
        uniqueThreadCount = 0
        nextCursorIsNull = $false
      }
    }
  }
}

function ConvertTo-SanitizedReportMessage {
  param(
    [AllowEmptyString()][string]$Message,
    [string[]]$SensitivePaths = @()
  )

  $sanitized = ($Message -replace '[\r\n]+', ' ').Trim()
  foreach ($sensitivePath in $SensitivePaths) {
    if (-not $sensitivePath) {
      continue
    }
    $sanitized = $sanitized.Replace($sensitivePath, "<redacted-path>")
    $sanitized = $sanitized.Replace($sensitivePath.Replace("\", "/"), "<redacted-path>")
  }
  $sanitized = $sanitized -replace '(?i)\b[A-Z]:\\Users\\[^\\\s]+', '<home>'
  $sanitized = $sanitized -replace '(?i)/(home|Users)/[^/\s]+', '<home>'
  $sanitized = $sanitized -replace '(?i)\b(Bearer\s+)?(sk-|sess-|key-)[A-Za-z0-9._-]{12,}\b', '<redacted>'
  if ($sanitized.Length -gt 2000) {
    $sanitized = $sanitized.Substring(0, 2000)
  }
  return $sanitized
}

function Test-NonNegativeJsonInteger {
  param([AllowNull()]$Value)

  return (
    ($Value -is [int] -or $Value -is [long]) -and
    [decimal]$Value -ge 0
  )
}

function Test-RequiredReportShape {
  param([Parameter(Mandatory = $true)]$Report)

  if ($Report.schemaVersion -isnot [int] -or
      [int]$Report.schemaVersion -ne 1 -or
      [string]$Report.test -ne "real-offline-codex-pagination" -or
      $Report.passed -isnot [bool] -or
      $Report.packageName -isnot [string] -or
      [string]::IsNullOrWhiteSpace([string]$Report.packageName) -or
      $Report.packageVersion -isnot [string] -or
      [string]::IsNullOrWhiteSpace([string]$Report.packageVersion) -or
      $Report.cliSha256 -isnot [string] -or
      [string]$Report.cliSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
      $Report.validatedAtUtc -isnot [string] -or
      -not (Test-NonNegativeJsonInteger -Value $Report.fixtureThreadCount) -or
      $null -eq $Report.checks -or
      $null -eq $Report.checks.directAppServer -or
      $null -eq $Report.checks.shim) {
    return $false
  }

  $direct = $Report.checks.directAppServer
  $shim = $Report.checks.shim
  $validatedAt = [DateTimeOffset]::MinValue
  if (-not [DateTimeOffset]::TryParse(
      [string]$Report.validatedAtUtc,
      [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::RoundtripKind,
      [ref]$validatedAt
    ) -or $validatedAt.Offset -ne [TimeSpan]::Zero) {
    return $false
  }
  return (
    $direct.passed -is [bool] -and
    (Test-NonNegativeJsonInteger -Value $direct.returnedThreadCount) -and
    (Test-NonNegativeJsonInteger -Value $direct.pageCount) -and
    (Test-NonNegativeJsonInteger -Value $direct.uniqueThreadCount) -and
    $direct.threadReadPassed -is [bool] -and
    $direct.nextCursorIsNull -is [bool] -and
    $shim.passed -is [bool] -and
    (Test-NonNegativeJsonInteger -Value $shim.returnedThreadCount) -and
    (Test-NonNegativeJsonInteger -Value $shim.pageCount) -and
    (Test-NonNegativeJsonInteger -Value $shim.uniqueThreadCount) -and
    $shim.nextCursorIsNull -is [bool]
  )
}

$rootDir = Get-RepositoryRoot
if (-not $CandidateManifestPath) {
  $CandidateManifestPath = Join-Path $rootDir "compatibility\candidate.json"
}
if (-not $CacheRoot) {
  if ($env:CODEX_CI_CACHE_ROOT) {
    $CacheRoot = $env:CODEX_CI_CACHE_ROOT
  } else {
    $programData = if ($env:ProgramData) { $env:ProgramData } else { "C:\ProgramData" }
    $CacheRoot = Join-Path $programData "CodexShimCI\candidates"
  }
}
if (-not $ReportPath) {
  $ReportPath = Join-Path $rootDir "artifacts\codex-candidate-validation.json"
}

$CandidateManifestPath = [IO.Path]::GetFullPath($CandidateManifestPath)
$CacheRoot = [IO.Path]::GetFullPath($CacheRoot)
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
$nodeScript = Join-Path $rootDir "test\real-pagination-smoke.cjs"
$candidate = $null
$candidateCli = $null
$expectedSha = $null
$packageName = $null
$packageVersion = $null
$candidateManifestSchemaValidated = $false
$cacheShaVerified = $false
$nodeExitCode = $null
$nodeReportShapeValid = $false
$failure = $null
$report = New-ValidationReport -PackageName $null -PackageVersion $null -CliSha256 $null
$startedAt = [DateTime]::UtcNow

try {
  if (-not (Test-Path -LiteralPath $CandidateManifestPath -PathType Leaf)) {
    throw "Candidate manifest was not found."
  }
  if (-not (Test-Path -LiteralPath $nodeScript -PathType Leaf)) {
    throw "Real pagination smoke test script was not found."
  }

  $candidate = Get-Content -LiteralPath $CandidateManifestPath -Raw | ConvertFrom-Json
  if ($candidate.schemaVersion -isnot [int] -or [int]$candidate.schemaVersion -ne 1) {
    throw "Candidate manifest schemaVersion must be 1."
  }
  if ($candidate.packageName -isnot [string] -or
      [string]::IsNullOrWhiteSpace([string]$candidate.packageName)) {
    throw "Candidate manifest packageName is required."
  }
  if ($candidate.packageVersion -isnot [string] -or
      [string]::IsNullOrWhiteSpace([string]$candidate.packageVersion)) {
    throw "Candidate manifest packageVersion is required."
  }
  if ($candidate.cliSha256 -isnot [string]) {
    throw "Candidate manifest cliSha256 must contain 64 hexadecimal characters."
  }
  $packageName = [string]$candidate.packageName
  $packageVersion = [string]$candidate.packageVersion
  $expectedSha = ([string]$candidate.cliSha256).ToUpperInvariant()
  if ($expectedSha -notmatch '^[A-F0-9]{64}$') {
    throw "Candidate manifest cliSha256 must contain 64 hexadecimal characters."
  }
  $candidateManifestSchemaValidated = $true
  $report = New-ValidationReport `
    -PackageName $packageName `
    -PackageVersion $packageVersion `
    -CliSha256 $expectedSha

  $candidateCli = Join-Path (Join-Path $CacheRoot $expectedSha.ToLowerInvariant()) "codex.exe"
  if (-not (Test-Path -LiteralPath $candidateCli -PathType Leaf)) {
    throw "Cached candidate CLI was not found."
  }
  $actualSha = Get-FileSha256Hex -Path $candidateCli
  if ($actualSha -ne $expectedSha) {
    throw "Cached candidate CLI failed SHA-256 validation."
  }
  $cacheShaVerified = $true

  $nodeCommand = Get-Command -Name $NodeExecutable -CommandType Application -ErrorAction Stop |
    Select-Object -First 1
  if (-not $nodeCommand) {
    throw "Node.js executable was not found."
  }

  $reportParent = Split-Path -Parent $ReportPath
  if ($reportParent) {
    New-Item -ItemType Directory -Path $reportParent -Force | Out-Null
  }
  if (Test-Path -LiteralPath $ReportPath -PathType Leaf) {
    [IO.File]::Delete($ReportPath)
  }

  $nodeArguments = @(
    $nodeScript,
    "--candidate-manifest", $CandidateManifestPath,
    "--candidate-cache-root", $CacheRoot,
    "--output", $ReportPath,
    "--timeout-ms", $TimeoutMs.ToString([Globalization.CultureInfo]::InvariantCulture)
  )
  if ($KeepFixture) {
    $nodeArguments += "--keep-fixture"
  }

  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $nodeOutput = @(& $nodeCommand.Source @nodeArguments 2>&1)
    $nodeExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }

  if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
    throw "Node validation did not produce a structured report."
  }
  $report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
  $nodeReportShapeValid = Test-RequiredReportShape -Report $report
  if (-not $nodeReportShapeValid) {
    throw "Node validation report does not match the required promotion schema."
  }

  $identityMatches = (
    [string]$report.packageName -eq $packageName -and
    [string]$report.packageVersion -eq $packageVersion -and
    ([string]$report.cliSha256).ToUpperInvariant() -eq $expectedSha
  )
  $direct = $report.checks.directAppServer
  $shim = $report.checks.shim
  $promotionChecksMatch = (
    [int]$report.fixtureThreadCount -eq 125 -and
    [bool]$direct.passed -and
    [int]$direct.returnedThreadCount -eq 125 -and
    [int]$direct.pageCount -eq 2 -and
    [int]$direct.uniqueThreadCount -eq 125 -and
    [bool]$direct.threadReadPassed -and
    [bool]$direct.nextCursorIsNull -and
    [bool]$shim.passed -and
    [int]$shim.returnedThreadCount -eq 125 -and
    [int]$shim.pageCount -eq 2 -and
    [int]$shim.uniqueThreadCount -eq 125 -and
    [bool]$shim.nextCursorIsNull
  )
  $overallPassed = (
    $nodeExitCode -eq 0 -and
    [bool]$report.passed -and
    $identityMatches -and
    $promotionChecksMatch
  )
  $report.passed = [bool]$overallPassed
  if (-not $overallPassed) {
    throw "Candidate failed one or more promotion checks."
  }
} catch {
  $failure = $_
  if (-not $nodeReportShapeValid) {
    $report = New-ValidationReport `
      -PackageName $packageName `
      -PackageVersion $packageVersion `
      -CliSha256 $expectedSha
  } else {
    $report.passed = $false
  }
}

$report.validatedAtUtc = [DateTime]::UtcNow.ToString("o")
$validation = [pscustomobject][ordered]@{
  wrapperPassed = [bool]$report.passed
  candidateManifestSchemaValidated = $candidateManifestSchemaValidated
  cacheSha256Verified = $cacheShaVerified
  nodeReportShapeValidated = $nodeReportShapeValid
  nodeExitCode = $nodeExitCode
  powershellVersion = $PSVersionTable.PSVersion.ToString()
  durationMs = [int][Math]::Round(([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
}
$report | Add-Member -NotePropertyName validation -NotePropertyValue $validation -Force

if ($failure) {
  $sensitivePaths = @($rootDir, $CandidateManifestPath, $CacheRoot, $candidateCli, $ReportPath)
  $safeMessage = ConvertTo-SanitizedReportMessage `
    -Message ([string]$failure.Exception.Message) `
    -SensitivePaths $sensitivePaths
  if (-not $report.PSObject.Properties["error"]) {
    $report | Add-Member `
      -NotePropertyName error `
      -NotePropertyValue ([pscustomobject][ordered]@{ message = $safeMessage }) `
      -Force
  }
}

Write-Utf8Json -Value $report -Path $ReportPath -Depth 12
Set-ActionsOutput -Name "report_path" -Value $ReportPath
$report | ConvertTo-Json -Depth 12

if ($failure -or -not [bool]$report.passed) {
  throw "Candidate Codex compatibility validation failed. See the structured report."
}
