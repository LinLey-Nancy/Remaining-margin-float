param(
    [string]$DestinationDirectory = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$innoVersion = '6.7.3'
$expectedInstallerSha256 = (
    '9c73c3bae7ed48d44112a0f48e66742c00090bdb5bef71d9d3c056c66e97b732'
)
$expectedCompilerSha256 = (
    '0a8757031b33777e4c9cbffee40f11a5062b36d25cbe144c1db73b6102b80ad7'
)
$downloadUri = (
    'https://github.com/jrsoftware/issrc/releases/download/' +
    "is-6_7_3/innosetup-$innoVersion.exe"
)
if ([string]::IsNullOrWhiteSpace($DestinationDirectory)) {
    $temporaryRoot = if (
        -not [string]::IsNullOrWhiteSpace([string]$env:RUNNER_TEMP)
    ) {
        $env:RUNNER_TEMP
    } else {
        [IO.Path]::GetTempPath()
    }
    $DestinationDirectory = Join-Path $temporaryRoot "inno-setup-$innoVersion"
}
$installRoot = [IO.Path]::GetFullPath($DestinationDirectory)
$compilerPath = Join-Path $installRoot 'ISCC.exe'

function Assert-InnoAuthenticodePublisher {
    param([string]$Path)

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if (
        $signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
        -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch
            '(^|,\s*)CN=Pyrsys B\.V\.(,|$)'
    ) {
        throw (
            'Inno Setup file has an invalid or unexpected Authenticode ' +
            "signature: $Path ($($signature.Status))"
        )
    }
}

function Assert-InnoVersionMetadata {
    param(
        [string]$Path,
        [string]$Label
    )

    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    $allowedVersions = @($innoVersion, "$innoVersion.0")
    $reportedVersions = @(
        @(
            ([string]$versionInfo.FileVersion).Trim()
            ([string]$versionInfo.ProductVersion).Trim()
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $matchingVersions = @(
        $reportedVersions |
            Where-Object { $allowedVersions -contains $_ }
    )
    if (
        $reportedVersions.Count -eq 0 -or
        $matchingVersions.Count -eq 0
    ) {
        throw (
            "Unexpected $Label version metadata: " +
            ($reportedVersions -join ', ')
        )
    }
}

function Assert-FileSha256 {
    param(
        [string]$Path,
        [string]$ExpectedHash,
        [string]$Label
    )

    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if (-not $actualHash.Equals(
        $ExpectedHash,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Unexpected $Label SHA-256: $actualHash"
    }
}

if (Test-Path -LiteralPath $compilerPath -PathType Leaf) {
    Assert-InnoAuthenticodePublisher -Path $compilerPath
    Assert-FileSha256 `
        -Path $compilerPath `
        -ExpectedHash $expectedCompilerSha256 `
        -Label 'Inno Setup compiler'
    Write-Output $compilerPath
    return
}

$downloadRoot = [IO.Path]::GetTempPath()
$downloadPath = Join-Path $downloadRoot (
    'RemainingMarginFloat-InnoSetup-{0}-{1}.exe' -f
        $innoVersion,
        [Guid]::NewGuid().ToString('N')
)
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest `
        -UseBasicParsing `
        -Uri $downloadUri `
        -OutFile $downloadPath

    Assert-InnoAuthenticodePublisher -Path $downloadPath
    Assert-InnoVersionMetadata -Path $downloadPath -Label 'Inno Setup installer'
    Assert-FileSha256 `
        -Path $downloadPath `
        -ExpectedHash $expectedInstallerSha256 `
        -Label 'Inno Setup installer'

    New-Item -Path $installRoot -ItemType Directory -Force | Out-Null
    $arguments = @(
        '/VERYSILENT'
        '/SUPPRESSMSGBOXES'
        '/NORESTART'
        '/NOICONS'
        '/CURRENTUSER'
        "/DIR=`"$installRoot`""
    )
    $process = Start-Process `
        -FilePath $downloadPath `
        -ArgumentList $arguments `
        -Wait `
        -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Inno Setup installation failed: $($process.ExitCode)"
    }
    if (-not (Test-Path -LiteralPath $compilerPath -PathType Leaf)) {
        throw "Inno Setup compiler was not installed at $compilerPath"
    }
    Assert-InnoAuthenticodePublisher -Path $compilerPath
    Assert-FileSha256 `
        -Path $compilerPath `
        -ExpectedHash $expectedCompilerSha256 `
        -Label 'Inno Setup compiler'
}
finally {
    if (Test-Path -LiteralPath $downloadPath) {
        Remove-Item -LiteralPath $downloadPath -Force
    }
}

if (-not [string]::IsNullOrWhiteSpace([string]$env:GITHUB_PATH)) {
    Add-Content -LiteralPath $env:GITHUB_PATH -Value $installRoot
}
Write-Output $compilerPath
