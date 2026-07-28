param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist'),
    [string]$Version = ((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim())
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must use semantic versioning: $Version"
}

$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$productName = "Remaining-Margin-Float-v$Version"
$packageRoot = Join-Path $outputRoot $productName
$executablePath = Join-Path $packageRoot 'RemainingMarginFloat.exe'
$scriptPath = Join-Path $packageRoot 'RemainingMarginFloat.ps1'
$archivePath = Join-Path $outputRoot "$productName.zip"
$checksumPath = "$archivePath.sha256"

foreach ($requiredPath in @($executablePath, $scriptPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Package input is missing: $requiredPath"
    }
}

foreach ($oldOutput in @($archivePath, $checksumPath)) {
    if (Test-Path -LiteralPath $oldOutput) {
        Remove-Item -LiteralPath $oldOutput -Force
    }
}

Compress-Archive -LiteralPath $packageRoot -DestinationPath $archivePath -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content `
    -LiteralPath $checksumPath `
    -Value "$hash  $([IO.Path]::GetFileName($archivePath))" `
    -Encoding ASCII

[pscustomobject]@{
    Version = $Version
    Archive = $archivePath
    Sha256 = $hash
    SizeBytes = (Get-Item -LiteralPath $archivePath).Length
}
