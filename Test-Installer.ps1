param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist'),
    [string]$Version = (
        (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()
    )
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must use semantic versioning: $Version"
}
$installerName = "Remaining-Margin-Float-v$Version-Setup.exe"
$packageRoot = Join-Path $outputRoot "Remaining-Margin-Float-v$Version"
$installerPath = Join-Path $outputRoot $installerName
$checksumPath = "$installerPath.sha256"
foreach ($requiredPath in @($installerPath, $checksumPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Installer artifact is missing: $requiredPath"
    }
}

$checksumFields = (
    (Get-Content -LiteralPath $checksumPath -Raw).Trim() -split '\s+'
)
if (
    $checksumFields.Count -lt 2 -or
    $checksumFields[1] -ne $installerName
) {
    throw 'Installer checksum file does not name the installer.'
}
$expectedHash = $checksumFields[0]
$actualHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
if (-not $actualHash.Equals(
    $expectedHash,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw 'Installer checksum does not match.'
}

$fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($installerPath)
$normalizedFileVersion = ([string]$fileVersion.FileVersion).Trim()
if ($normalizedFileVersion -ne "$Version.0") {
    throw "Installer version mismatch: $($fileVersion.FileVersion)"
}

$uninstallRegistryPath = (
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' +
    '{62A9B547-A78D-4BCA-94AC-C6022AC592D2}_is1'
)
$applicationRegistryPath = 'HKCU:\Software\RemainingMarginFloat'
$startupRunRegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$startupRunValueName = 'RemainingMarginFloat'
$startupShortcutPath = Join-Path (
    [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
) 'Remaining Margin Float.lnk'
$startupTaskName = 'Remaining Margin Float'

function Test-InstallerRegistrationExists {
    return (
        (Test-Path -LiteralPath $uninstallRegistryPath) -or
        (Test-Path -LiteralPath $applicationRegistryPath)
    )
}

$startupTaskExists = $false
$taskQueryTool = Join-Path $env:SystemRoot 'System32\schtasks.exe'
if (Test-Path -LiteralPath $taskQueryTool -PathType Leaf) {
    $taskQueryProcess = Start-Process `
        -FilePath $taskQueryTool `
        -ArgumentList @(
            '/Query'
            '/TN'
            ('"{0}"' -f $startupTaskName)
        ) `
        -WindowStyle Hidden `
        -Wait `
        -PassThru
    $startupTaskExists = $taskQueryProcess.ExitCode -eq 0
}
$startupRunExists = $null -ne (
    Get-ItemProperty `
        -LiteralPath $startupRunRegistryPath `
        -Name $startupRunValueName `
        -ErrorAction SilentlyContinue
)
if (
    (Test-InstallerRegistrationExists) -or
    $startupTaskExists -or
    $startupRunExists -or
    (Test-Path -LiteralPath $startupShortcutPath -PathType Leaf)
) {
    throw (
        'Installer verification refused to modify an existing installation ' +
        'or startup registration. Run this test in a clean CI account.'
    )
}

$testRoot = Join-Path $outputRoot (
    '.installer-test-{0}-{1}' -f $PID, [Guid]::NewGuid().ToString('N')
)
$installRoot = Join-Path $testRoot 'app'
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
if (-not $resolvedTestRoot.StartsWith(
    $outputRoot + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw 'Installer test directory escaped the output directory.'
}

function Wait-InstallerCleanup {
    param([string[]]$ExpectedFiles)

    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        $applicationFilesRemain = @(
            $ExpectedFiles |
                Where-Object {
                    Test-Path -LiteralPath (Join-Path $installRoot $_)
                }
        ).Count -gt 0
        if (
            -not $applicationFilesRemain -and
            -not (Test-InstallerRegistrationExists)
        ) {
            return $true
        }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Invoke-TestUninstaller {
    param([string]$UninstallerPath)

    $uninstallProcess = Start-Process `
        -FilePath $UninstallerPath `
        -ArgumentList @(
            '/VERYSILENT'
            '/SUPPRESSMSGBOXES'
            '/NORESTART'
        ) `
        -Wait `
        -PassThru
    if ($uninstallProcess.ExitCode -ne 0) {
        throw "Silent uninstall check failed: $($uninstallProcess.ExitCode)"
    }
}

$expectedInstalledFiles = @(
    'LICENSE'
    'PRIVACY.md'
    'README.txt'
    'RemainingMarginFloat.exe'
    'RemainingMarginFloat.ps1'
)
$installSucceeded = $false
$uninstallCompleted = $false
$cleanupUninstallerPath = $null

try {
    New-Item -Path $testRoot -ItemType Directory | Out-Null
    $installArguments = @(
        '/VERYSILENT'
        '/SUPPRESSMSGBOXES'
        '/NORESTART'
        '/CURRENTUSER'
        '/TASKS=""'
        "/DIR=`"$installRoot`""
    )
    $installProcess = Start-Process `
        -FilePath $installerPath `
        -ArgumentList $installArguments `
        -Wait `
        -PassThru
    if ($installProcess.ExitCode -ne 0) {
        throw "Silent installer check failed: $($installProcess.ExitCode)"
    }
    $installSucceeded = $true
    foreach ($fileName in $expectedInstalledFiles) {
        $installedPath = Join-Path $installRoot $fileName
        $packagePath = Join-Path $packageRoot $fileName
        if (-not (Test-Path -LiteralPath $installedPath -PathType Leaf)) {
            throw "Installed application file is missing: $fileName"
        }
        if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
            throw "Package source file is missing: $fileName"
        }
        $installedHash = (Get-FileHash `
            -LiteralPath $installedPath `
            -Algorithm SHA256).Hash
        $packageHash = (Get-FileHash `
            -LiteralPath $packagePath `
            -Algorithm SHA256).Hash
        if ($installedHash -ne $packageHash) {
            throw "Installer changed application payload: $fileName"
        }
    }
    $actualPayloadFiles = @(
        Get-ChildItem -LiteralPath $installRoot -File |
            Where-Object { $_.Name -notlike 'unins*' } |
            ForEach-Object { $_.Name } |
            Sort-Object
    )
    if (
        $actualPayloadFiles.Count -ne $expectedInstalledFiles.Count -or
        (Compare-Object `
            -ReferenceObject ($expectedInstalledFiles | Sort-Object) `
            -DifferenceObject $actualPayloadFiles)
    ) {
        throw (
            'Installer contains unexpected application payload: ' +
            ($actualPayloadFiles -join ', ')
        )
    }
    $installedRegistration = Get-ItemProperty `
        -LiteralPath $uninstallRegistryPath `
        -ErrorAction Stop
    if (-not [IO.Path]::GetFullPath(
        [string]$installedRegistration.InstallLocation
    ).TrimEnd('\').Equals(
        [IO.Path]::GetFullPath($installRoot).TrimEnd('\'),
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Installer registration contains an unexpected install location.'
    }
    $applicationRegistration = Get-ItemProperty `
        -LiteralPath $applicationRegistryPath `
        -ErrorAction Stop
    if (-not [IO.Path]::GetFullPath(
        [string]$applicationRegistration.InstallLocation
    ).TrimEnd('\').Equals(
        [IO.Path]::GetFullPath($installRoot).TrimEnd('\'),
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Application registration contains an unexpected install location.'
    }

    $upgradeSentinel = Join-Path $installRoot '.upgrade-preserve-test'
    Set-Content `
        -LiteralPath $upgradeSentinel `
        -Value 'preserve across in-place upgrade' `
        -Encoding UTF8
    $upgradeProcess = Start-Process `
        -FilePath $installerPath `
        -ArgumentList $installArguments `
        -Wait `
        -PassThru
    if ($upgradeProcess.ExitCode -ne 0) {
        throw "Silent in-place upgrade check failed: $($upgradeProcess.ExitCode)"
    }
    if (-not (Test-Path -LiteralPath $upgradeSentinel -PathType Leaf)) {
        throw 'In-place upgrade removed an existing user-owned file.'
    }
    Remove-Item -LiteralPath $upgradeSentinel -Force
    foreach ($fileName in $expectedInstalledFiles) {
        $installedPath = Join-Path $installRoot $fileName
        $packagePath = Join-Path $packageRoot $fileName
        if (
            (Get-FileHash -LiteralPath $installedPath -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash
        ) {
            throw "In-place upgrade installed an unexpected payload: $fileName"
        }
    }

    $processEnvironment = [EnvironmentVariableTarget]::Process
    $previousLauncher = [Environment]::GetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_LAUNCHER',
        $processEnvironment
    )
    $previousScript = [Environment]::GetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_SCRIPT',
        $processEnvironment
    )
    try {
        $installedLauncher = Join-Path $installRoot 'RemainingMarginFloat.exe'
        $installedScript = Join-Path $installRoot 'RemainingMarginFloat.ps1'
        [Environment]::SetEnvironmentVariable(
            'REMAINING_MARGIN_FLOAT_LAUNCHER',
            $installedLauncher,
            $processEnvironment
        )
        [Environment]::SetEnvironmentVariable(
            'REMAINING_MARGIN_FLOAT_SCRIPT',
            $installedScript,
            $processEnvironment
        )
        $startupOutput = @(
            & powershell.exe `
                -NoProfile `
                -NonInteractive `
                -STA `
                -ExecutionPolicy Bypass `
                -File $installedScript `
                -CheckStartup 2>&1
        )
        if ($LASTEXITCODE -ne 0) {
            throw (
                'Installed startup diagnostic failed: ' +
                ($startupOutput -join [Environment]::NewLine)
            )
        }
        $startup = (
            $startupOutput -join [Environment]::NewLine
        ) | ConvertFrom-Json
        if (
            $startup.Source -ne 'InstalledExe' -or
            -not [IO.Path]::GetFullPath([string]$startup.FilePath).Equals(
                [IO.Path]::GetFullPath($installedLauncher),
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            throw 'Installed startup diagnostic did not use the stable install path.'
        }
    }
    finally {
        [Environment]::SetEnvironmentVariable(
            'REMAINING_MARGIN_FLOAT_LAUNCHER',
            $previousLauncher,
            $processEnvironment
        )
        [Environment]::SetEnvironmentVariable(
            'REMAINING_MARGIN_FLOAT_SCRIPT',
            $previousScript,
            $processEnvironment
        )
    }
    $uninstaller = Get-ChildItem `
        -LiteralPath $installRoot `
        -Filter 'unins*.exe' `
        -File |
        Select-Object -First 1
    if (-not $uninstaller) {
        throw 'The installer did not create an uninstaller.'
    }
    $cleanupUninstallerPath = $uninstaller.FullName

    Invoke-TestUninstaller -UninstallerPath $cleanupUninstallerPath
    [void](Wait-InstallerCleanup -ExpectedFiles $expectedInstalledFiles)
    foreach ($fileName in $expectedInstalledFiles) {
        if (Test-Path -LiteralPath (Join-Path $installRoot $fileName)) {
            throw "Uninstaller left an application file behind: $fileName"
        }
    }
    if (
        (Test-Path -LiteralPath $uninstallRegistryPath) -or
        (Test-Path -LiteralPath $applicationRegistryPath)
    ) {
        throw 'Uninstaller left registry registration behind.'
    }
    $uninstallCompleted = $true
}
finally {
    if ($installSucceeded -and -not $uninstallCompleted) {
        if (
            [string]::IsNullOrWhiteSpace($cleanupUninstallerPath) -or
            -not (Test-Path -LiteralPath $cleanupUninstallerPath -PathType Leaf)
        ) {
            $cleanupUninstaller = Get-ChildItem `
                -LiteralPath $installRoot `
                -Filter 'unins*.exe' `
                -File `
                -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($cleanupUninstaller) {
                $cleanupUninstallerPath = $cleanupUninstaller.FullName
            }
        }
        if (
            -not [string]::IsNullOrWhiteSpace($cleanupUninstallerPath) -and
            (Test-Path -LiteralPath $cleanupUninstallerPath -PathType Leaf)
        ) {
            try {
                Invoke-TestUninstaller -UninstallerPath $cleanupUninstallerPath
                [void](Wait-InstallerCleanup `
                    -ExpectedFiles $expectedInstalledFiles)
            }
            catch {
                Write-Warning (
                    'Automatic installer-test cleanup failed; preserving the ' +
                    "test uninstaller at $cleanupUninstallerPath. " +
                    $_.Exception.Message
                )
            }
        }
    }
    if (
        (Test-Path -LiteralPath $resolvedTestRoot) -and
        -not (Test-InstallerRegistrationExists) -and
        $resolvedTestRoot.StartsWith(
            $outputRoot + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
    elseif (Test-InstallerRegistrationExists) {
        Write-Warning (
            'Installer-test registration remains; the test directory was ' +
            "preserved for recovery: $resolvedTestRoot"
        )
    }
}

[pscustomobject]@{
    Version = $Version
    Installer = $installerPath
    InstallerSha256 = $actualHash.ToLowerInvariant()
    InstallCheck = 'Passed'
    InPlaceUpgradeCheck = 'Passed'
    InstalledStartupCheck = 'Passed'
    UninstallCheck = 'Passed'
    ExpectedFileCount = $expectedInstalledFiles.Count
}
