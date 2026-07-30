param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist'),
    [string]$Version = (
        (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()
    ),
    [string]$InnoCompilerPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$packageRoot = Join-Path $outputRoot "Remaining-Margin-Float-v$Version"
$installerScriptPath = Join-Path $PSScriptRoot 'installer\RemainingMarginFloat.iss'
$installerName = "Remaining-Margin-Float-v$Version-Setup.exe"
$installerPath = Join-Path $outputRoot $installerName
$checksumPath = "$installerPath.sha256"

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must use semantic versioning: $Version"
}
foreach ($requiredPath in @(
    $installerScriptPath
    (Join-Path $packageRoot 'RemainingMarginFloat.exe')
    (Join-Path $packageRoot 'RemainingMarginFloat.ps1')
    (Join-Path $packageRoot 'README.txt')
    (Join-Path $packageRoot 'LICENSE')
    (Join-Path $packageRoot 'PRIVACY.md')
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Installer input is missing: $requiredPath"
    }
}

if ([string]::IsNullOrWhiteSpace($InnoCompilerPath)) {
    $compilerCandidates = @(
        [Environment]::GetEnvironmentVariable(
            'INNO_SETUP_COMPILER',
            [EnvironmentVariableTarget]::Process
        )
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe')
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
        (Join-Path $env:ProgramFiles 'Inno Setup 7\ISCC.exe')
    )
    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($command) {
        $compilerCandidates = @($command.Source) + $compilerCandidates
    }
    $InnoCompilerPath = @(
        $compilerCandidates |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and
                (Test-Path -LiteralPath $_ -PathType Leaf)
            }
    ) | Select-Object -First 1
}
if (
    [string]::IsNullOrWhiteSpace($InnoCompilerPath) -or
    -not (Test-Path -LiteralPath $InnoCompilerPath -PathType Leaf)
) {
    throw 'Inno Setup command-line compiler ISCC.exe was not found.'
}
$compilerPath = [IO.Path]::GetFullPath($InnoCompilerPath)

foreach ($oldOutput in @($installerPath, $checksumPath)) {
    if (Test-Path -LiteralPath $oldOutput) {
        Remove-Item -LiteralPath $oldOutput -Force
    }
}
New-Item -Path $outputRoot -ItemType Directory -Force | Out-Null

& $compilerPath `
    '/Qp' `
    "/DAppVersion=$Version" `
    "/DPackageDirectory=$packageRoot" `
    "/DOutputDirectory=$outputRoot" `
    $installerScriptPath
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compilation failed with exit code $LASTEXITCODE."
}
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "Inno Setup did not create the expected installer: $installerPath"
}

$fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($installerPath)
$normalizedFileVersion = ([string]$fileVersion.FileVersion).Trim()
if ($normalizedFileVersion -ne "$Version.0") {
    throw "Installer file version mismatch: $($fileVersion.FileVersion)"
}
$hash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).
    Hash.ToLowerInvariant()
Set-Content `
    -LiteralPath $checksumPath `
    -Value "$hash  $installerName" `
    -Encoding ASCII

[pscustomobject]@{
    Version = $Version
    Compiler = $compilerPath
    Installer = $installerPath
    Sha256 = $hash
    SizeBytes = (Get-Item -LiteralPath $installerPath).Length
}
