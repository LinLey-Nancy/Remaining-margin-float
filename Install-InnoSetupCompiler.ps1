param(
    [string]$DestinationDirectory = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$innoVersion = '6.7.3'
$expectedInstallerSha256 = (
    '9c73c3bae7ed48d44112a0f48e66742c00090bdb5bef71d9d3c056c66e97b732'
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
$versionMarkerPath = Join-Path $installRoot '.rmf-inno-version'

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

if (Test-Path -LiteralPath $compilerPath -PathType Leaf) {
    Assert-InnoAuthenticodePublisher -Path $compilerPath
    $cachedVersion = if (Test-Path -LiteralPath $versionMarkerPath -PathType Leaf) {
        (Get-Content -LiteralPath $versionMarkerPath -Raw).Trim()
    }
    else {
        ''
    }
    if ($cachedVersion -ne $innoVersion) {
        throw "Cached Inno Setup compiler version is not trusted: $cachedVersion"
    }
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
    $downloadHash = (
        Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256
    ).Hash
    if (-not $downloadHash.Equals(
        $expectedInstallerSha256,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Unexpected Inno Setup installer SHA-256: $downloadHash"
    }

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
    Set-Content `
        -LiteralPath $versionMarkerPath `
        -Value $innoVersion `
        -Encoding ASCII
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
