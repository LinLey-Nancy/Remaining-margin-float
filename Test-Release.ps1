param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist'),
    [string]$Version = ((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()),
    [switch]$RequireSignature,
    [string]$ExpectedSignerThumbprint = '',
    [switch]$RequireTimestamp,
    [switch]$RequireArchive
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$productName = "Remaining-Margin-Float-v$Version"
$packageRoot = Join-Path $outputRoot $productName
$executablePath = Join-Path $packageRoot 'RemainingMarginFloat.exe'
$scriptPath = Join-Path $packageRoot 'RemainingMarginFloat.ps1'
$archivePath = Join-Path $outputRoot "$productName.zip"
$checksumPath = "$archivePath.sha256"
$componentManifestPath = Join-Path $PSScriptRoot 'src\Components.psd1'
$packageLicensePath = Join-Path $packageRoot 'LICENSE'
$packagePrivacyPath = Join-Path $packageRoot 'PRIVACY.md'

foreach ($requiredPath in @(
    $executablePath
    $scriptPath
    $packageLicensePath
    $packagePrivacyPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Release input is missing: $requiredPath"
    }
}

$legacyExecutable = Join-Path $outputRoot "$productName.exe"
if (Test-Path -LiteralPath $legacyExecutable) {
    throw "Legacy single-file launcher must not be published: $legacyExecutable"
}

$runtimeFiles = @(
    (Join-Path $PSScriptRoot 'Build-Package.ps1'),
    (Join-Path $PSScriptRoot 'Start-RemainingMarginFloat.cmd')
)
$runtimeFiles += @(
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src') -Recurse -File |
        Where-Object { $_.Extension -in @('.ps1', '.psd1') } |
        ForEach-Object { $_.FullName }
)
$forbiddenPatterns = @(
    'ExecutionPolicy\s+Bypass',
    '-EncodedCommand',
    'CreateNoWindow\s*=\s*true',
    'ProcessWindowStyle\.Hidden',
    'private const string EmbeddedScript',
    'Convert\.FromBase64String\(EmbeddedScript\)',
    'ExtractScript\('
)
foreach ($runtimeFile in $runtimeFiles) {
    $content = Get-Content -LiteralPath $runtimeFile -Raw
    foreach ($pattern in $forbiddenPatterns) {
        if ($content -match $pattern) {
            throw "Forbidden release behavior '$pattern' found in $runtimeFile"
        }
    }
}

$runtimeVersionPattern =
    '(?i)(?:remaining-margin-float|RemainingMarginFloat)/(?<version>\d+\.\d+\.\d+)'
$runtimeVersionMatches = @(
    foreach ($runtimeFile in $runtimeFiles) {
        $content = Get-Content -LiteralPath $runtimeFile -Raw
        [regex]::Matches($content, $runtimeVersionPattern)
    }
)
if ($runtimeVersionMatches.Count -eq 0) {
    throw 'No runtime User-Agent version marker was found.'
}
foreach ($runtimeVersionMatch in $runtimeVersionMatches) {
    if ($runtimeVersionMatch.Groups['version'].Value -ne $Version) {
        throw (
            'Runtime User-Agent version does not match VERSION: ' +
            $runtimeVersionMatch.Value
        )
    }
}

$releaseWorkflowPath = Join-Path $PSScriptRoot '.github\workflows\release.yml'
$releaseWorkflowText = Get-Content -LiteralPath $releaseWorkflowPath -Raw
if (
    $releaseWorkflowText -notmatch
        '\$releaseTitle\s*=\s*\$env:GITHUB_REF_NAME' -or
    $releaseWorkflowText -notmatch
        'gh release edit \$releaseTag --title \$releaseTag' -or
    $releaseWorkflowText -notmatch
        'Remaining-Margin-Float-v\$version-Setup\.exe' -or
    $releaseWorkflowText -notmatch
        'gh release upload \$env:GITHUB_REF_NAME \$installer \$checksum --clobber' -or
    $releaseWorkflowText -match
        '\$releaseTitle\s*=\s*"Remaining Margin Float'
) {
    throw (
        'GitHub releases must use tag-only titles and installer-first assets.'
    )
}

$installerScriptPath = Join-Path $PSScriptRoot 'installer\RemainingMarginFloat.iss'
$installerScriptText = Get-Content -LiteralPath $installerScriptPath -Raw
foreach ($requiredInstallerPattern in @(
    '(?m)^\[UninstallRun\]$'
    'schtasks\.exe.*Remaining Margin Float'
    'reg\.exe.*RemainingMarginFloat'
    '(?m)^\[UninstallDelete\]$'
    'Remaining Margin Float\.lnk'
)) {
    if ($installerScriptText -notmatch $requiredInstallerPattern) {
        throw (
            'Installer does not remove every supported startup registration: ' +
            $requiredInstallerPattern
        )
    }
}

$componentManifest = Import-PowerShellDataFile -LiteralPath $componentManifestPath
$componentPaths = @($componentManifest.Components)
$packagedScriptText = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8
$bundledComponentMarkers = @(
    [regex]::Matches($packagedScriptText, '(?m)^# component: (.+)$') |
        ForEach-Object { $_.Groups[1].Value.Trim() }
)
if (
    $componentPaths.Count -ne $bundledComponentMarkers.Count -or
    (Compare-Object `
        -ReferenceObject $componentPaths `
        -DifferenceObject $bundledComponentMarkers `
        -SyncWindow 0)
) {
    throw (
        'Bundled release components do not match src\Components.psd1. ' +
        "Expected: $($componentPaths -join ', '); " +
        "actual: $($bundledComponentMarkers -join ', ')"
    )
}

$signature = Get-AuthenticodeSignature -LiteralPath $executablePath
if ($RequireSignature) {
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid) {
        throw "Release executable signature is not valid: $($signature.Status)"
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedSignerThumbprint)) {
        throw 'ExpectedSignerThumbprint is required when RequireSignature is enabled.'
    }
    $expectedThumbprint = $ExpectedSignerThumbprint -replace '[^0-9A-Fa-f]', ''
    $actualThumbprint = [string]$signature.SignerCertificate.Thumbprint
    if (-not $actualThumbprint.Equals(
        $expectedThumbprint,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Unexpected signer certificate thumbprint: $actualThumbprint"
    }
    if ($RequireTimestamp -and -not $signature.TimeStamperCertificate) {
        throw 'The release executable does not contain a trusted timestamp.'
    }
}

$fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($executablePath)
if ($fileVersion.FileVersion -ne "$Version.0") {
    throw "Executable version mismatch: $($fileVersion.FileVersion)"
}

function Invoke-LauncherCheck {
    param([string]$Path)

    $launcherProcess = Start-Process -FilePath $Path -PassThru
    if (-not $launcherProcess.WaitForExit(30000)) {
        $launcherProcess.Kill()
        throw "Launcher runtime check timed out: $Path"
    }
    return $launcherProcess.ExitCode
}

$processEnvironment = [EnvironmentVariableTarget]::Process
$previousLauncherCheck = [Environment]::GetEnvironmentVariable(
    'REMAINING_MARGIN_FLOAT_LAUNCHER_CHECK',
    $processEnvironment
)
$previousGuiCheck = [Environment]::GetEnvironmentVariable(
    'REMAINING_MARGIN_FLOAT_GUI_CHECK',
    $processEnvironment
)
$previousInstanceScope = [Environment]::GetEnvironmentVariable(
    'REMAINING_MARGIN_FLOAT_INSTANCE_SCOPE',
    $processEnvironment
)
$previousGuiCheckResult = [Environment]::GetEnvironmentVariable(
    'REMAINING_MARGIN_FLOAT_GUI_CHECK_RESULT',
    $processEnvironment
)
$negativeTestRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'RemainingMarginFloat.ReleaseTest.{0}.{1}' -f $PID, [Guid]::NewGuid().ToString('N')
)
try {
    New-Item -Path $negativeTestRoot -ItemType Directory | Out-Null
    $launcherCheckResultPath =
        Join-Path $negativeTestRoot 'launcher-check-result.txt'
    [Environment]::SetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_GUI_CHECK_RESULT',
        $launcherCheckResultPath,
        $processEnvironment
    )
    [Environment]::SetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_LAUNCHER_CHECK',
        '1',
        $processEnvironment
    )
    $validExitCode = Invoke-LauncherCheck -Path $executablePath
    if ($validExitCode -ne 0) {
        $launcherCheckDetails = if (
            Test-Path -LiteralPath $launcherCheckResultPath
        ) {
            Get-Content -LiteralPath $launcherCheckResultPath -Raw
        } else {
            'No launcher diagnostic result was written.'
        }
        throw (
            "Launcher runtime check failed: $validExitCode`n" +
            $launcherCheckDetails
        )
    }

    $negativeExecutable = Join-Path $negativeTestRoot 'RemainingMarginFloat.exe'
    $negativeScript = Join-Path $negativeTestRoot 'RemainingMarginFloat.ps1'
    Copy-Item -LiteralPath $executablePath -Destination $negativeExecutable
    if ((Invoke-LauncherCheck -Path $negativeExecutable) -eq 0) {
        throw 'Launcher accepted a package with a missing script.'
    }
    Copy-Item -LiteralPath $scriptPath -Destination $negativeScript
    Add-Content -LiteralPath $negativeScript -Value "`n# release-integrity-negative-test"
    if ((Invoke-LauncherCheck -Path $negativeExecutable) -eq 0) {
        throw 'Launcher accepted a package with a modified script.'
    }

    [Environment]::SetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_LAUNCHER_CHECK',
        $null,
        $processEnvironment
    )
    [Environment]::SetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_GUI_CHECK',
        '1',
        $processEnvironment
    )
    $guiCheckResultPath = Join-Path $negativeTestRoot 'gui-check-result.txt'
    [Environment]::SetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_GUI_CHECK_RESULT',
        $guiCheckResultPath,
        $processEnvironment
    )
    $guiCheckExitCode = Invoke-LauncherCheck -Path $executablePath
    if ($guiCheckExitCode -ne 0) {
        $guiCheckDetails = if (Test-Path -LiteralPath $guiCheckResultPath) {
            Get-Content -LiteralPath $guiCheckResultPath -Raw
        } else {
            'No GUI diagnostic result was written.'
        }
        throw (
            "Packaged GUI callback check failed: $guiCheckExitCode`n" +
            $guiCheckDetails
        )
    }

    [Environment]::SetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_GUI_CHECK',
        $null,
        $processEnvironment
    )
    $instanceScope = 'ReleaseTest.{0}.{1}' -f
        $PID,
        [Guid]::NewGuid().ToString('N')
    [Environment]::SetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_INSTANCE_SCOPE',
        $instanceScope,
        $processEnvironment
    )
    $activationEventName = "Local\RemainingMarginFloat.Activate.$instanceScope"
    $mutexName = "Local\RemainingMarginFloat.Singleton.$instanceScope"
    $activationEvent = New-Object Threading.EventWaitHandle(
        $false,
        [Threading.EventResetMode]::AutoReset,
        $activationEventName
    )
    $ownsTestMutex = $false
    $testMutex = New-Object Threading.Mutex(
        $true,
        $mutexName,
        [ref]$ownsTestMutex
    )
    try {
        if (-not $ownsTestMutex) {
            throw 'Could not create isolated single-instance test mutex.'
        }
        $secondLaunchExitCode = Invoke-LauncherCheck -Path $executablePath
        if ($secondLaunchExitCode -ne 0) {
            throw (
                'Second launcher instance reported a startup error: ' +
                $secondLaunchExitCode
            )
        }
        if (-not $activationEvent.WaitOne(1000)) {
            throw 'Second launcher instance did not signal the active instance.'
        }
    }
    finally {
        if ($ownsTestMutex) {
            $testMutex.ReleaseMutex()
        }
        $testMutex.Dispose()
        $activationEvent.Dispose()
    }
}
finally {
    [Environment]::SetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_LAUNCHER_CHECK',
        $previousLauncherCheck,
        $processEnvironment
    )
    [Environment]::SetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_GUI_CHECK',
        $previousGuiCheck,
        $processEnvironment
    )
    [Environment]::SetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_INSTANCE_SCOPE',
        $previousInstanceScope,
        $processEnvironment
    )
    [Environment]::SetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_GUI_CHECK_RESULT',
        $previousGuiCheckResult,
        $processEnvironment
    )
    if (Test-Path -LiteralPath $negativeTestRoot) {
        Remove-Item -LiteralPath $negativeTestRoot -Recurse -Force
    }
}

$previousPackagedLauncher = [Environment]::GetEnvironmentVariable(
    'REMAINING_MARGIN_FLOAT_LAUNCHER',
    $processEnvironment
)
$previousPackagedScript = [Environment]::GetEnvironmentVariable(
    'REMAINING_MARGIN_FLOAT_SCRIPT',
    $processEnvironment
)
try {
    [Environment]::SetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_LAUNCHER',
        $executablePath,
        $processEnvironment
    )
    [Environment]::SetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_SCRIPT',
        $scriptPath,
        $processEnvironment
    )
    $startupOutput = @(
        & powershell.exe -NoProfile -NonInteractive -STA `
            -File $scriptPath -CheckStartup 2>&1
    )
    if ($LASTEXITCODE -ne 0) {
        throw "Packaged startup diagnostic failed:`n$($startupOutput -join [Environment]::NewLine)"
    }
    $startupResult = ($startupOutput -join [Environment]::NewLine) | ConvertFrom-Json
    if (
        $startupResult.Source -ne 'PackagedExe' -or
        [IO.Path]::GetFileName([string]$startupResult.FilePath) -ne 'RemainingMarginFloat.exe' -or
        -not [string]::IsNullOrWhiteSpace([string]$startupResult.Arguments)
    ) {
        throw 'Packaged startup diagnostic did not select the managed EXE path.'
    }
}
finally {
    [Environment]::SetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_LAUNCHER',
        $previousPackagedLauncher,
        $processEnvironment
    )
    [Environment]::SetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_SCRIPT',
        $previousPackagedScript,
        $processEnvironment
    )
}

$previousStartCheck = [Environment]::GetEnvironmentVariable(
    'REMAINING_MARGIN_FLOAT_START_CHECK',
    $processEnvironment
)
try {
    [Environment]::SetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_START_CHECK',
        '1',
        $processEnvironment
    )
    $startCommandPath = Join-Path $PSScriptRoot 'Start-RemainingMarginFloat.cmd'
    $startOutput = @(& $env:ComSpec /d /c "`"$startCommandPath`"" 2>&1)
    if ($LASTEXITCODE -ne 0 -or 'Mode=PackagedExe' -notin $startOutput) {
        throw "Start command did not select the packaged launcher:`n$($startOutput -join [Environment]::NewLine)"
    }

    [Environment]::SetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_START_CHECK',
        $null,
        $processEnvironment
    )
    [Environment]::SetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_LAUNCHER_CHECK',
        '1',
        $processEnvironment
    )
    $startStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $launchOutput = @(& $env:ComSpec /d /c "`"$startCommandPath`"" 2>&1)
    $launchExitCode = $LASTEXITCODE
    $startStopwatch.Stop()
    if ($launchExitCode -ne 0 -or $startStopwatch.Elapsed.TotalSeconds -gt 10) {
        throw (
            "Start command did not return promptly: exit=$launchExitCode, " +
            "seconds=$([Math]::Round($startStopwatch.Elapsed.TotalSeconds, 2))`n" +
            ($launchOutput -join [Environment]::NewLine)
        )
    }
}
finally {
    [Environment]::SetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_START_CHECK',
        $previousStartCheck,
        $processEnvironment
    )
    [Environment]::SetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_LAUNCHER_CHECK',
        $previousLauncherCheck,
        $processEnvironment
    )
}

if ($RequireArchive) {
    foreach ($requiredArchivePath in @($archivePath, $checksumPath)) {
        if (-not (Test-Path -LiteralPath $requiredArchivePath -PathType Leaf)) {
            throw "Final release artifact is missing: $requiredArchivePath"
        }
    }
    $expectedArchiveHash = (
        (Get-Content -LiteralPath $checksumPath -Raw).Trim() -split '\s+'
    )[0]
    $actualArchiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).
        Hash.ToLowerInvariant()
    if (-not $actualArchiveHash.Equals(
        $expectedArchiveHash,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Archive checksum does not match the final ZIP.'
    }

    $archiveTestRoot = Join-Path ([IO.Path]::GetTempPath()) (
        'RemainingMarginFloat.ArchiveTest.{0}.{1}' -f $PID, [Guid]::NewGuid().ToString('N')
    )
    try {
        Expand-Archive -LiteralPath $archivePath -DestinationPath $archiveTestRoot
        $expandedPackageRoot = Join-Path $archiveTestRoot $productName
        $actualFiles = @(
            Get-ChildItem -LiteralPath $expandedPackageRoot -Recurse -File |
                ForEach-Object {
                    $_.FullName.Substring($expandedPackageRoot.Length + 1).
                        Replace('\', '/')
                } |
                Sort-Object
        )
        $expectedFiles = @(
            'LICENSE'
            'PRIVACY.md'
            'README.txt'
            'RemainingMarginFloat.exe'
            'RemainingMarginFloat.ps1'
        )
        if (
            $actualFiles.Count -ne $expectedFiles.Count -or
            (Compare-Object -ReferenceObject $expectedFiles -DifferenceObject $actualFiles)
        ) {
            throw "Unexpected final ZIP contents: $($actualFiles -join ', ')"
        }
        foreach ($fileName in @(
            'LICENSE'
            'PRIVACY.md'
            'RemainingMarginFloat.exe'
            'RemainingMarginFloat.ps1'
        )) {
            $expandedHash = (Get-FileHash `
                -LiteralPath (Join-Path $expandedPackageRoot $fileName) `
                -Algorithm SHA256).Hash
            $packageHash = (Get-FileHash `
                -LiteralPath (Join-Path $packageRoot $fileName) `
                -Algorithm SHA256).Hash
            if ($expandedHash -ne $packageHash) {
                throw "Final ZIP changed $fileName."
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $archiveTestRoot) {
            Remove-Item -LiteralPath $archiveTestRoot -Recurse -Force
        }
    }
}

[pscustomobject]@{
    Version = $Version
    Executable = $executablePath
    SignatureStatus = [string]$signature.Status
    Publisher = if ($signature.SignerCertificate) {
        $signature.SignerCertificate.Subject
    } else {
        ''
    }
    Timestamped = $null -ne $signature.TimeStamperCertificate
    RuntimePolicyCheck = 'Passed'
    RuntimeVersionCheck = 'Passed'
    BundledComponentCheck = 'Passed'
    LauncherRuntimeCheck = 'Passed'
    WpfEventCallbackCheck = 'Passed'
    RefreshTimerCheck = 'Passed'
    SecondLaunchActivationCheck = 'Passed'
    MissingScriptRejected = 'Passed'
    ModifiedScriptRejected = 'Passed'
    PackagedStartupCheck = 'Passed'
    StartCommandSelectionCheck = 'Passed'
    StartCommandLaunchCheck = 'Passed'
    ArchiveCheck = if ($RequireArchive) { 'Passed' } else { 'Skipped' }
}
