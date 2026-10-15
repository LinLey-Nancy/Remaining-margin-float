$script:UpdateRepository = 'LinLey-Nancy/Remaining-margin-float'
$script:UpdateApiUri = (
    'https://api.github.com/repos/{0}/releases/latest' -f
        $script:UpdateRepository
)
$script:UpdateLatestReleaseUri = (
    'https://github.com/{0}/releases/latest' -f
        $script:UpdateRepository
)
$script:UpdateCheckInterval = [TimeSpan]::FromHours(6)

# A failed check must not stay silent for the full interval: startup happens
# while WiFi, VPN and proxies are often still coming up, so the first attempt
# is the one most likely to fail. Retry on this ladder and only fall back to
# the normal interval after a check actually succeeds.
$script:UpdateCheckRetryLadder = @(
    [TimeSpan]::FromMinutes(1)
    [TimeSpan]::FromMinutes(5)
    [TimeSpan]::FromMinutes(20)
    [TimeSpan]::FromMinutes(60)
)
$script:UpdateMetadataRequestTimeout = [TimeSpan]::FromSeconds(20)
$script:UpdateOperationDeadline = [TimeSpan]::FromSeconds(90)
$script:UpdateDownloadDeadline = [TimeSpan]::FromSeconds(300)
$script:UpdateDownloadStallDeadline = [TimeSpan]::FromSeconds(30)
$script:UpdateDownloadAttempts = 2
$script:UpdateDownloadChunkBytes = 65536

function Get-UpdateRetryDelay {
    param([int]$FailureCount)

    if ($FailureCount -lt 1) {
        $FailureCount = 1
    }
    $index = $FailureCount - 1
    if ($index -ge $script:UpdateCheckRetryLadder.Count) {
        $index = $script:UpdateCheckRetryLadder.Count - 1
    }
    return $script:UpdateCheckRetryLadder[$index]
}

function ConvertTo-RmfVersion {
    param([string]$Value)

    $normalized = ([string]$Value).Trim()
    if ($normalized.StartsWith('v', [StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(1)
    }
    if ($normalized -notmatch '^\d+\.\d+\.\d+$') {
        throw (
            "版本号格式无效：$Value。" +
            '远端标签必须是三段式版本号，形如 v1.13.3；' +
            '预发布或非标准命名不在自动更新支持范围内。'
        )
    }
    return New-Object Version $normalized
}

function Test-RmfUpdateAvailable {
    param(
        [string]$CurrentVersion,
        [string]$LatestVersion
    )

    return (
        (ConvertTo-RmfVersion -Value $LatestVersion) -gt
        (ConvertTo-RmfVersion -Value $CurrentVersion)
    )
}

function Test-GitHubUpdateAssetUrl {
    param(
        [string]$Url,
        [string]$Tag,
        [string]$FileName
    )

    if (
        [string]::IsNullOrWhiteSpace($Url) -or
        [string]::IsNullOrWhiteSpace($Tag) -or
        [string]::IsNullOrWhiteSpace($FileName)
    ) {
        return $false
    }
    try {
        $uri = New-Object Uri $Url
        $expectedPath = '/{0}/releases/download/{1}/{2}' -f
            $script:UpdateRepository,
            $Tag,
            $FileName
        return (
            $uri.Scheme -eq [Uri]::UriSchemeHttps -and
            $uri.Host.Equals('github.com', [StringComparison]::OrdinalIgnoreCase) -and
            [Uri]::UnescapeDataString($uri.AbsolutePath).Equals(
                $expectedPath,
                [StringComparison]::OrdinalIgnoreCase
            )
        )
    }
    catch {
        return $false
    }
}

function ConvertFrom-GitHubRelease {
    param($Release)

    if (-not $Release) {
        throw 'GitHub Release 响应为空。'
    }
    $tag = [string]$Release.tag_name
    if ([bool]$Release.draft -or [bool]$Release.prerelease) {
        throw 'GitHub 返回的最新版本不是稳定正式版。'
    }
    $version = (ConvertTo-RmfVersion -Value $tag).ToString()

    $installerName = "Remaining-Margin-Float-v$version-Setup.exe"
    $checksumName = "$installerName.sha256"
    $installerAsset = $null
    $checksumAsset = $null
    foreach ($asset in @($Release.assets)) {
        if ([string]$asset.name -eq $installerName) {
            $installerAsset = $asset
        }
        elseif ([string]$asset.name -eq $checksumName) {
            $checksumAsset = $asset
        }
    }

    $releaseUrl = [string]$Release.html_url
    $expectedReleaseUrl = (
        'https://github.com/{0}/releases/tag/{1}' -f
            $script:UpdateRepository,
            $tag
    )
    if (-not $releaseUrl.Equals(
        $expectedReleaseUrl,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'GitHub Release 页面地址不符合预期。'
    }

    $installerUrl = if ($installerAsset) {
        [string]$installerAsset.browser_download_url
    } else {
        ''
    }
    $checksumUrl = if ($checksumAsset) {
        [string]$checksumAsset.browser_download_url
    } else {
        ''
    }
    $installerSize = if ($installerAsset) {
        [long]$installerAsset.size
    } else {
        0L
    }
    $checksumSize = if ($checksumAsset) {
        [long]$checksumAsset.size
    } else {
        0L
    }
    $hasInstaller = (
        $installerAsset -and
        $checksumAsset -and
        $installerSize -gt 0 -and
        $installerSize -le 50MB -and
        $checksumSize -gt 0 -and
        $checksumSize -le 4KB -and
        (Test-GitHubUpdateAssetUrl `
            -Url $installerUrl `
            -Tag $tag `
            -FileName $installerName) -and
        (Test-GitHubUpdateAssetUrl `
            -Url $checksumUrl `
            -Tag $tag `
            -FileName $checksumName)
    )

    return [pscustomobject]@{
        Tag = $tag
        Version = $version
        ReleaseUrl = $releaseUrl
        InstallerName = $installerName
        InstallerUrl = $installerUrl
        ChecksumName = $checksumName
        ChecksumUrl = $checksumUrl
        InstallerSize = $installerSize
        ChecksumSize = $checksumSize
        InstallerSizeExact = $true
        HasInstaller = [bool]$hasInstaller
    }
}

function Get-GitHubRedirectReleaseTag {
    param($Response)

    if (-not $Response -or -not $Response.IsSuccessStatusCode) {
        throw 'GitHub 最新 Release 页面不可用。'
    }
    $finalUri = $Response.RequestMessage.RequestUri
    if (-not $finalUri) {
        throw 'GitHub 最新 Release 重定向缺少目标地址。'
    }
    $pathPrefix = '/{0}/releases/tag/' -f $script:UpdateRepository
    $path = [Uri]::UnescapeDataString($finalUri.AbsolutePath)
    if (
        $finalUri.Scheme -ne [Uri]::UriSchemeHttps -or
        -not $finalUri.Host.Equals(
            'github.com',
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not $path.StartsWith(
            $pathPrefix,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw 'GitHub 最新 Release 重定向地址不符合预期。'
    }
    $tag = $path.Substring($pathPrefix.Length)
    if ([string]::IsNullOrWhiteSpace($tag) -or $tag.Contains('/')) {
        throw 'GitHub 最新 Release 标签无效。'
    }
    [void](ConvertTo-RmfVersion -Value $tag)
    $expectedUrl = 'https://github.com/{0}/releases/tag/{1}' -f
        $script:UpdateRepository,
        $tag
    if (-not $finalUri.AbsoluteUri.Equals(
        $expectedUrl,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'GitHub 最新 Release 页面地址不符合预期。'
    }
    return $tag
}

function Get-GitHubAssetListUri {
    param([string]$Tag)

    return 'https://github.com/{0}/releases/expanded_assets/{1}' -f
        $script:UpdateRepository,
        $Tag
}

# The API is rate limited per source address and easily exhausted on shared or
# mobile networks. The expanded-assets fragment lives on github.com and answers
# with the authoritative asset list, so the HTML fallback path uses it instead
# of probing the download endpoints, which GitHub throttles much harder.
function ConvertFrom-GitHubAssetListHtml {
    param(
        [string]$Html,
        [string]$Tag
    )

    if ([string]::IsNullOrWhiteSpace($Html) -or
        [string]::IsNullOrWhiteSpace($Tag)) {
        throw 'GitHub Release 资产清单为空。'
    }
    $version = (ConvertTo-RmfVersion -Value $Tag).ToString()
    $installerName = "Remaining-Margin-Float-v$version-Setup.exe"
    $checksumName = "$installerName.sha256"
    $releaseUrl = 'https://github.com/{0}/releases/tag/{1}' -f
        $script:UpdateRepository,
        $Tag
    $installerUrl = 'https://github.com/{0}/releases/download/{1}/{2}' -f
        $script:UpdateRepository,
        $Tag,
        $installerName
    $checksumUrl = 'https://github.com/{0}/releases/download/{1}/{2}' -f
        $script:UpdateRepository,
        $Tag,
        $checksumName

    $hrefPattern = 'href\s*=\s*"(?<url>[^"]*releases/download/[^"]+)"'
    $foundHrefs = @(
        [regex]::Matches(
            $Html,
            $hrefPattern,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        ) | ForEach-Object {
            [Uri]::UnescapeDataString($_.Groups['url'].Value.Trim())
        }
    )
    $baseUri = New-Object Uri 'https://github.com'
    $hasInstaller = $false
    $hasChecksum = $false
    foreach ($href in $foundHrefs) {
        $candidate = New-Object Uri -ArgumentList @($baseUri, $href)
        if (
            $candidate.Scheme -ne [Uri]::UriSchemeHttps -or
            -not $candidate.Host.Equals(
                'github.com',
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            continue
        }
        if (Test-GitHubUpdateAssetUrl `
            -Url $candidate.AbsoluteUri `
            -Tag $Tag `
            -FileName $installerName) {
            $hasInstaller = $true
        }
        elseif (Test-GitHubUpdateAssetUrl `
            -Url $candidate.AbsoluteUri `
            -Tag $Tag `
            -FileName $checksumName) {
            $hasChecksum = $true
        }
    }

    return [pscustomobject]@{
        Tag = $Tag
        Version = $version
        ReleaseUrl = $releaseUrl
        InstallerName = $installerName
        InstallerUrl = $installerUrl
        ChecksumName = $checksumName
        ChecksumUrl = $checksumUrl
        InstallerSize = 0L
        ChecksumSize = 0L
        # The fragment only carries human readable sizes, so the exact byte
        # count the API provides is not available here. Integrity still rests
        # on the full-file SHA-256 and the embedded version check.
        InstallerSizeExact = $false
        HasInstaller = [bool]($hasInstaller -and $hasChecksum)
        HasChecksum = [bool]$hasChecksum
    }
}

function New-GitHubRedirectRelease {
    param(
        [string]$Tag,
        [long]$InstallerSize,
        [long]$ChecksumSize
    )

    $version = (ConvertTo-RmfVersion -Value $Tag).ToString()
    $installerName = "Remaining-Margin-Float-v$version-Setup.exe"
    $checksumName = "$installerName.sha256"
    $releaseUrl = 'https://github.com/{0}/releases/tag/{1}' -f
        $script:UpdateRepository,
        $Tag
    $installerUrl = 'https://github.com/{0}/releases/download/{1}/{2}' -f
        $script:UpdateRepository,
        $Tag,
        $installerName
    $checksumUrl = 'https://github.com/{0}/releases/download/{1}/{2}' -f
        $script:UpdateRepository,
        $Tag,
        $checksumName
    $hasInstaller = (
        $InstallerSize -gt 0 -and
        $InstallerSize -le 50MB -and
        $ChecksumSize -gt 0 -and
        $ChecksumSize -le 4KB -and
        (Test-GitHubUpdateAssetUrl `
            -Url $installerUrl `
            -Tag $Tag `
            -FileName $installerName) -and
        (Test-GitHubUpdateAssetUrl `
            -Url $checksumUrl `
            -Tag $Tag `
            -FileName $checksumName)
    )

    return [pscustomobject]@{
        Tag = $Tag
        Version = $version
        ReleaseUrl = $releaseUrl
        InstallerName = $installerName
        InstallerUrl = $installerUrl
        ChecksumName = $checksumName
        ChecksumUrl = $checksumUrl
        InstallerSize = $InstallerSize
        ChecksumSize = $ChecksumSize
        InstallerSizeExact = $true
        HasInstaller = [bool]$hasInstaller
    }
}

function Get-UpdateChecksum {
    param(
        [string]$Text,
        [string]$ExpectedFileName
    )

    $normalizedText = ([string]$Text).Trim()
    $match = [regex]::Match(
        $normalizedText,
        '^(?<hash>[0-9a-f]{64})\s+\*?(?<name>[^\r\n]+?)$',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    if (-not $match.Success) {
        throw '安装程序校验文件格式无效。'
    }
    $actualFileName = $match.Groups['name'].Value.Trim()
    if (-not $actualFileName.Equals(
        $ExpectedFileName,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw '安装程序校验文件指向了其他文件。'
    }
    return $match.Groups['hash'].Value.ToLowerInvariant()
}

function Get-ByteArraySha256 {
    param([byte[]]$Bytes)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return (
            [BitConverter]::ToString($sha256.ComputeHash($Bytes)).
                Replace('-', '').
                ToLowerInvariant()
        )
    }
    finally {
        $sha256.Dispose()
    }
}

function Assert-UpdatePayload {
    param(
        $Release,
        [byte[]]$InstallerBytes,
        [byte[]]$ChecksumBytes
    )

    $sizeMismatch = if ($Release.InstallerSizeExact) {
        $InstallerBytes.LongLength -ne [long]$Release.InstallerSize
    }
    else {
        # The HTML fallback only exposes rounded human readable sizes, so the
        # exact byte count is unavailable there. The ceiling below still
        # applies, and the full-file SHA-256 plus the embedded version check
        # remain the authoritative integrity guarantees.
        $InstallerBytes.LongLength -le 0
    }
    if (
        $sizeMismatch -or
        $InstallerBytes.LongLength -gt 50MB -or
        $ChecksumBytes.LongLength -ne [long]$Release.ChecksumSize -or
        $ChecksumBytes.LongLength -gt 4KB
    ) {
        throw '下载文件大小与 GitHub Release 元数据不一致。'
    }
    $checksumText = [Text.Encoding]::UTF8.GetString($ChecksumBytes)
    $expectedHash = Get-UpdateChecksum `
        -Text $checksumText `
        -ExpectedFileName $Release.InstallerName
    $actualHash = Get-ByteArraySha256 -Bytes $InstallerBytes
    if (-not $actualHash.Equals(
        $expectedHash,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw '安装程序 SHA-256 校验失败，文件不会运行。'
    }
}

function Assert-UpdateInstallerVersionInfo {
    param(
        $VersionInfo,
        [string]$ExpectedVersion
    )

    $allowedVersions = @($ExpectedVersion, "$ExpectedVersion.0")
    $fileVersion = ([string]$VersionInfo.FileVersion).Trim()
    $productVersion = ([string]$VersionInfo.ProductVersion).Trim()
    if (
        $allowedVersions -notcontains $fileVersion -or
        $allowedVersions -notcontains $productVersion
    ) {
        throw (
            '安装程序内嵌版本与 GitHub Release 不一致：' +
            "FileVersion=$fileVersion, ProductVersion=$productVersion"
        )
    }
}

function Assert-UpdateInstallerMetadata {
    param(
        [string]$InstallerPath,
        $Release
    )

    $versionInfo = if (
        $script:UpdateDiagnosticMode -and
        $script:UpdateDiagnosticFileVersionInfo
    ) {
        $script:UpdateDiagnosticFileVersionInfo
    }
    else {
        [Diagnostics.FileVersionInfo]::GetVersionInfo($InstallerPath)
    }
    Assert-UpdateInstallerVersionInfo `
        -VersionInfo $versionInfo `
        -ExpectedVersion $Release.Version
}

function Test-TrustedUpdateInstallerSignature {
    param([string]$InstallerPath)

    if ($script:UpdateTrustedSignerThumbprints.Count -eq 0) {
        return $false
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $InstallerPath
    if (
        $signature.Status -ne
            [System.Management.Automation.SignatureStatus]::Valid -or
        -not $signature.SignerCertificate
    ) {
        return $false
    }
    $thumbprint = (
        [string]$signature.SignerCertificate.Thumbprint
    ).Replace(' ', '').ToUpperInvariant()
    return $script:UpdateTrustedSignerThumbprints -contains $thumbprint
}

function Get-UpdateHttpClient {
    param(
        [TimeSpan]$Timeout = [TimeSpan]::Zero
    )

    if ($Timeout -le [TimeSpan]::Zero) {
        $Timeout = $script:UpdateMetadataRequestTimeout
    }
    if (
        $script:UpdateHttpClient -and
        $script:UpdateHttpClient.Timeout -ne $Timeout
    ) {
        $previous = $script:UpdateHttpClient
        $script:UpdateHttpClient = $null
        $previous.Dispose()
    }
    if (-not $script:UpdateHttpClient) {
        $client = New-Object Net.Http.HttpClient
        $client.Timeout = $Timeout
        [void]$client.DefaultRequestHeaders.TryAddWithoutValidation(
            'User-Agent',
            "RemainingMarginFloat/$($script:AppVersion)"
        )
        [void]$client.DefaultRequestHeaders.TryAddWithoutValidation(
            'Accept',
            'application/vnd.github+json'
        )
        $script:UpdateHttpClient = $client
    }
    return $script:UpdateHttpClient
}

function Reset-UpdateHttpClient {
    if (-not $script:UpdateHttpClient) { return }
    $previous = $script:UpdateHttpClient
    $script:UpdateHttpClient = $null
    $previous.Dispose()
}

function Write-UpdateLog {
    param(
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Level = 'Info',
        [Parameter(Mandatory = $true)]
        [string]$Event,
        [AllowEmptyString()]
        [string]$Message = '',
        [Collections.IDictionary]$Data
    )

    if ($isDiagnosticRun) { return }
    Write-RuntimeLog `
        -Level $Level `
        -Event "Update.$Event" `
        -Message $Message `
        -Data $Data
}

function Get-AutoUpdateNetworkAssessment {
    param(
        [string]$ConnectivityLevel,
        [string]$CostType,
        [bool]$Roaming,
        [bool]$OverDataLimit,
        [bool]$ApproachingDataLimit,
        [bool]$BackgroundDataUsageRestricted
    )

    $reason = if ($ConnectivityLevel -ne 'InternetAccess') {
        if ($ConnectivityLevel -eq 'None') {
            '当前没有可用的网络连接。'
        }
        elseif ($ConnectivityLevel -eq 'Unknown') {
            '无法确认当前网络是否适合自动更新。'
        }
        else {
            '当前网络不能访问互联网。'
        }
    }
    elseif ($Roaming) {
        '当前网络处于漫游状态。'
    }
    elseif ($OverDataLimit) {
        '当前网络已经超过流量限制。'
    }
    elseif ($ApproachingDataLimit) {
        '当前网络即将达到流量限制。'
    }
    elseif ($BackgroundDataUsageRestricted) {
        'Windows 已限制当前网络的后台流量。'
    }
    elseif ($CostType -ne 'Unrestricted') {
        '当前网络可能按流量计费。'
    }
    else {
        ''
    }

    return [pscustomobject]@{
        Suitable = [string]::IsNullOrWhiteSpace($reason)
        Reason = $reason
        ConnectivityLevel = $ConnectivityLevel
        CostType = $CostType
        Roaming = $Roaming
        OverDataLimit = $OverDataLimit
        ApproachingDataLimit = $ApproachingDataLimit
        BackgroundDataUsageRestricted = $BackgroundDataUsageRestricted
    }
}

function Get-AutoUpdateNetworkState {
    if (
        $script:UpdateDiagnosticMode -and
        $script:UpdateDiagnosticNetworkState
    ) {
        $state = $script:UpdateDiagnosticNetworkState
        return Get-AutoUpdateNetworkAssessment `
            -ConnectivityLevel ([string]$state.ConnectivityLevel) `
            -CostType ([string]$state.CostType) `
            -Roaming ([bool]$state.Roaming) `
            -OverDataLimit ([bool]$state.OverDataLimit) `
            -ApproachingDataLimit ([bool]$state.ApproachingDataLimit) `
            -BackgroundDataUsageRestricted (
                [bool]$state.BackgroundDataUsageRestricted
            )
    }

    try {
        $networkInformation = (
            [Windows.Networking.Connectivity.NetworkInformation,Windows,ContentType=WindowsRuntime]
        )
        $connectionProfile = $networkInformation::GetInternetConnectionProfile()
        if (-not $connectionProfile) {
            return Get-AutoUpdateNetworkAssessment `
                -ConnectivityLevel None `
                -CostType Unknown `
                -Roaming $false `
                -OverDataLimit $false `
                -ApproachingDataLimit $false `
                -BackgroundDataUsageRestricted $false
        }

        $connectivityLevel = [string]$connectionProfile.GetNetworkConnectivityLevel()
        $cost = $connectionProfile.GetConnectionCost()
        $costType = [string]$cost.NetworkCostType
        $roaming = [bool]$cost.Roaming
        $overDataLimit = [bool]$cost.OverDataLimit
        $approachingDataLimit = [bool]$cost.ApproachingDataLimit
        $backgroundRestricted = [bool]$cost.BackgroundDataUsageRestricted

        return Get-AutoUpdateNetworkAssessment `
            -ConnectivityLevel $connectivityLevel `
            -CostType $costType `
            -Roaming $roaming `
            -OverDataLimit $overDataLimit `
            -ApproachingDataLimit $approachingDataLimit `
            -BackgroundDataUsageRestricted $backgroundRestricted
    }
    catch {
        return Get-AutoUpdateNetworkAssessment `
            -ConnectivityLevel Unknown `
            -CostType Unknown `
            -Roaming $false `
            -OverDataLimit $false `
            -ApproachingDataLimit $false `
            -BackgroundDataUsageRestricted $false
    }
}

function Test-AutoUpdateInstalledMode {
    if (
        $script:UpdateDiagnosticMode -and
        $null -ne $script:UpdateDiagnosticInstalledMode
    ) {
        return [bool]$script:UpdateDiagnosticInstalledMode
    }

    try {
        $launchSpec = Get-StartupLaunchSpec
        return [string]$launchSpec.Source -eq 'InstalledExe'
    }
    catch {
        return $false
    }
}

function Get-AutoUpdateInstallerArguments {
    return (
        '/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER ' +
        '/CLOSEAPPLICATIONS /RMFAUTORESTART=1'
    )
}

function Show-AutoUpdateNotification {
    param(
        [string]$Title,
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'None')]
        [string]$Icon = 'Info'
    )

    if ($script:UpdateDiagnosticMode) {
        $script:UpdateDiagnosticMessages += "$Title：$Message"
        return
    }
    if (-not $script:TrayNotifyIcon) { return }
    try {
        $toolTipIconType = [Type]::GetType(
            'System.Windows.Forms.ToolTipIcon, System.Windows.Forms'
        )
        $toolTipIcon = [Enum]::Parse($toolTipIconType, $Icon)
        $script:TrayNotifyIcon.ShowBalloonTip(
            8000,
            $Title,
            $Message,
            $toolTipIcon
        )
    }
    catch {
        # 通知失败不影响下一次自动更新检查。
    }
}

function Sync-AutoUpdateMenuState {
    if ($script:AutoUpdateMenuItem) {
        $script:AutoUpdateMenuItem.IsChecked = $script:AutoUpdateEnabled
    }
    if ($script:TrayAutoUpdateItem) {
        $script:TrayAutoUpdateItem.Checked = $script:AutoUpdateEnabled
    }
}

function Clear-DeferredAutoUpdate {
    $script:DeferredAutoUpdateRelease = $null
    $script:DeferredAutoUpdateInstaller = $null
    $script:NextAutoUpdateNetworkRetryAt = $null
}

function Set-AutoUpdateEnabled {
    param(
        [bool]$Enabled,
        [switch]$Confirm
    )

    if ($Enabled -and -not (Test-AutoUpdateInstalledMode)) {
        Sync-AutoUpdateMenuState
        Show-UpdateMessage -Message (
            '自动更新仅支持通过安装程序安装的版本。' +
            '源码或便携运行时仍可手动检查、下载并安装更新。'
        )
        return $false
    }

    if ($Enabled -and $Confirm -and -not $script:UpdateDiagnosticMode) {
        $choice = [Windows.MessageBox]::Show(
            $window,
            (
                '启用后，软件只会在 Windows 判定为非按流量计费、非漫游、' +
                '未接近流量限制且后台流量未受限时自动更新。' +
                "`n`n安装程序会经过 GitHub Release 来源、文件大小、" +
                'SHA-256 和内嵌版本校验，然后静默安装并自动重启。' +
                "`n`n当前发布物尚未进行可信代码签名，SHA-256 不能单独证明" +
                '发布者身份。是否仍要启用自动更新？'
            ),
            'Remaining Margin Float 自动更新',
            [Windows.MessageBoxButton]::YesNo,
            [Windows.MessageBoxImage]::Warning
        )
        if ($choice -ne [Windows.MessageBoxResult]::Yes) {
            Sync-AutoUpdateMenuState
            return $false
        }
    }

    $script:AutoUpdateEnabled = $Enabled
    if (-not $Enabled) {
        Clear-DeferredAutoUpdate
        $script:AutoUpdateDeferredNotifications = @{}
    }
    Sync-AutoUpdateMenuState
    Save-Settings
    if ($Enabled) {
        $script:NextAutomaticUpdateCheckAt = [DateTimeOffset]::Now
    }
    return $true
}

function Format-UpdateProgressText {
    param(
        [long]$Bytes,
        [long]$Total
    )

    if ($Bytes -le 0) { return '' }
    if ($Total -gt 0) {
        $percent = [Math]::Min(
            100,
            [Math]::Max(0, [int][Math]::Floor($Bytes * 100 / $Total))
        )
        return ('{0}%（{1:N1} MB / {2:N1} MB）' -f
            $percent,
            ($Bytes / 1MB),
            ($Total / 1MB))
    }
    return ('{0:N1} MB' -f ($Bytes / 1MB))
}

function Sync-UpdateMenuState {
    $enabled = -not $script:UpdateContext.IsBusy
    $text = switch ($script:UpdateContext.Phase) {
        'Release' { '正在检查更新…' }
        'ReleaseFallback' { '正在检查更新…' }
        'ReleaseAssets' { '正在检查更新…' }
        'DownloadResponse' { '正在下载安装程序…' }
        'DownloadStream' { '正在下载安装程序…' }
        'DownloadCopy' { '正在下载安装程序…' }
        default { '检查更新…' }
    }
    if ($script:UpdateContext.IsBusy) {
        $waited = 0
        if ($script:UpdateContext.StartedAt) {
            $waited = [int][Math]::Max(
                0,
                [Math]::Floor(
                    ([DateTimeOffset]::Now - $script:UpdateContext.StartedAt).
                        TotalSeconds
                )
            )
        }
        $progress = Format-UpdateProgressText `
            -Bytes $script:UpdateContext.ProgressBytes `
            -Total $script:UpdateContext.ProgressTotal
        if ($progress) {
            $text = "正在下载安装程序 · $progress"
        }
        $text = "$text · 已等待 $waited 秒"
    }
    if ($script:UpdateMenuItem) {
        $script:UpdateMenuItem.IsEnabled = $enabled
        $script:UpdateMenuItem.Header = $text
    }
    if ($script:TrayUpdateItem) {
        $script:TrayUpdateItem.Enabled = $enabled
        $script:TrayUpdateItem.Text = $text
    }
    Sync-AutoUpdateMenuState
}

function Close-UpdateTransferStreams {
    if ($script:UpdateContext.File) {
        try { $script:UpdateContext.File.Dispose() } catch { }
        $script:UpdateContext.File = $null
    }
    if ($script:UpdateContext.Stream) {
        try { $script:UpdateContext.Stream.Dispose() } catch { }
        $script:UpdateContext.Stream = $null
    }
    # Disposing the response disposes its content and aborts an unfinished
    # transfer, so the response may only be released once the copy is done.
    if ($script:UpdateContext.Response) {
        try { $script:UpdateContext.Response.Dispose() } catch { }
        $script:UpdateContext.Response = $null
    }
    if ($script:UpdateContext.Cancellation) {
        try {
            [void]$script:UpdateContext.Cancellation.Dispose()
        }
        catch { }
        $script:UpdateContext.Cancellation = $null
    }
}

function Reset-UpdateContext {
    Close-UpdateTransferStreams
    $script:UpdateContext.IsBusy = $false
    $script:UpdateContext.Manual = $false
    $script:UpdateContext.AutomaticInstall = $false
    $script:UpdateContext.Phase = 'Idle'
    $script:UpdateContext.Client = $null
    $script:UpdateContext.ReleaseTask = $null
    $script:UpdateContext.InstallerTask = $null
    $script:UpdateContext.ChecksumTask = $null
    $script:UpdateContext.Release = $null
    $script:UpdateContext.ReleaseTag = $null
    $script:UpdateContext.SourceClient = $null
    $script:UpdateContext.Response = $null
    $script:UpdateContext.StreamTask = $null
    $script:UpdateContext.CopyTask = $null
    $script:UpdateContext.TemporaryPath = $null
    $script:UpdateContext.StartedAt = $null
    $script:UpdateContext.PhaseStartedAt = $null
    $script:UpdateContext.ProgressBytes = 0L
    $script:UpdateContext.ProgressTotal = 0L
    $script:UpdateContext.LastProgressBytes = 0L
    $script:UpdateContext.LastProgressAt = $null
    $script:UpdateContext.Attempt = 1
    $script:UpdateContext.ManualEscalated = $false
    Sync-UpdateMenuState
}

function Show-UpdateMessage {
    param(
        [string]$Message,
        [Windows.MessageBoxImage]$Image = [Windows.MessageBoxImage]::Information
    )

    if ($script:UpdateDiagnosticMode) {
        $script:UpdateDiagnosticMessages += $Message
        return
    }
    Show-ExistingWindow
    [void][Windows.MessageBox]::Show(
        $window,
        $Message,
        'Remaining Margin Float 更新',
        [Windows.MessageBoxButton]::OK,
        $Image
    )
}

function Set-UpdateCheckSchedule {
    param([bool]$Succeeded)

    if ($Succeeded) {
        $script:AutomaticUpdateFailureCount = 0
        $script:NextAutomaticUpdateCheckAt = (
            [DateTimeOffset]::Now + $script:UpdateCheckInterval
        )
        return
    }
    $script:AutomaticUpdateFailureCount++
    $delay = Get-UpdateRetryDelay -FailureCount $script:AutomaticUpdateFailureCount
    $script:NextAutomaticUpdateCheckAt = [DateTimeOffset]::Now + $delay
    Write-UpdateLog -Level Warning -Event 'CheckRescheduled' -Data ([ordered]@{
        FailureCount = $script:AutomaticUpdateFailureCount
        RetrySeconds = [long]$delay.TotalSeconds
    })
}

function Stop-UpdateOperation {
    param(
        [string]$Message,
        [switch]$AlwaysShow,
        [string]$Event = 'Failed',
        [string]$Stage = '',
        [Collections.IDictionary]$Data
    )

    $wasManual = $script:UpdateContext.Manual
    $phase = $script:UpdateContext.Phase
    $shouldShow = $AlwaysShow -or $wasManual
    if ($script:UpdateContext.Phase -in @('Release', 'ReleaseFallback',
        'ReleaseAssets')) {
        Set-UpdateCheckSchedule -Succeeded $false
    }
    Reset-UpdateContext
    $logData = [ordered]@{
        Stage = $Stage
        Phase = $phase
        Manual = $wasManual
        FailureCount = $script:AutomaticUpdateFailureCount
    }
    if ($Data) {
        foreach ($key in @($Data.Keys)) { $logData[[string]$key] = $Data[$key] }
    }
    Write-UpdateLog `
        -Level Warning `
        -Event $Event `
        -Message $Message `
        -Data $logData
    if ($shouldShow -and -not [string]::IsNullOrWhiteSpace($Message)) {
        Show-UpdateMessage `
            -Message $Message `
            -Image ([Windows.MessageBoxImage]::Warning)
    }
}

function Start-UpdateCheck {
    param(
        [switch]$Manual,
        $Client = $null
    )

    if ($script:UpdateContext.IsBusy) {
        if ($Manual) {
            # Dismissing the click would leave the user with no way to find out
            # what is happening. Upgrade the running operation instead and
            # report its result; the watchdog guarantees it cannot hang.
            $script:UpdateContext.Manual = $true
            $script:UpdateContext.ManualEscalated = $true
            Write-UpdateLog -Event 'CheckEscalatedToManual' -Data ([ordered]@{
                Phase = $script:UpdateContext.Phase
            })
            Sync-UpdateMenuState
        }
        return
    }

    try {
        if (-not $Client) {
            $Client = Get-UpdateHttpClient
        }
        $script:UpdateContext.SourceClient = $Client
        $script:UpdateContext.IsBusy = $true
        $script:UpdateContext.Manual = [bool]$Manual
        $script:UpdateContext.ManualEscalated = $false
        $script:UpdateContext.Phase = 'Release'
        $script:UpdateContext.Client = $Client
        $script:UpdateContext.Attempt = 1
        $script:UpdateContext.StartedAt = [DateTimeOffset]::Now
        $script:UpdateContext.PhaseStartedAt = [DateTimeOffset]::Now
        $script:UpdateContext.ReleaseTask = $Client.GetAsync(
            $script:UpdateApiUri,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead
        )
        Sync-UpdateMenuState
        Write-UpdateLog -Event 'CheckStarted' -Data ([ordered]@{
            Manual = [bool]$Manual
            Source = 'Api'
        })
    }
    catch {
        Stop-UpdateOperation `
            -Event 'CheckStartFailed' `
            -Stage 'Release' `
            -Message ("无法开始检查更新。`n`n$($_.Exception.Message)")
    }
}

function Start-GitHubReleaseFallback {
    param($Client)

    if (-not $Client) {
        $Client = Get-UpdateHttpClient
    }
    $script:UpdateContext.Phase = 'ReleaseFallback'
    $script:UpdateContext.PhaseStartedAt = [DateTimeOffset]::Now
    $script:UpdateContext.Client = $Client
    $script:UpdateContext.ReleaseTask = $Client.GetAsync(
        $script:UpdateLatestReleaseUri,
        [Net.Http.HttpCompletionOption]::ResponseHeadersRead
    )
    Sync-UpdateMenuState
    Write-UpdateLog -Event 'FallbackStarted' -Data ([ordered]@{
        From = 'Api'
        To = 'ReleasePage'
    })
}

function Start-GitHubAssetMetadataFallback {
    param(
        $Client,
        [string]$Tag
    )

    if (-not $Client) {
        $Client = Get-UpdateHttpClient
    }
    $script:UpdateContext.Phase = 'ReleaseAssets'
    $script:UpdateContext.PhaseStartedAt = [DateTimeOffset]::Now
    $script:UpdateContext.Client = $Client
    $script:UpdateContext.ReleaseTag = $Tag
    $script:UpdateContext.ReleaseTask = $Client.GetAsync(
        (Get-GitHubAssetListUri -Tag $Tag),
        [Net.Http.HttpCompletionOption]::ResponseHeadersRead
    )
    Write-UpdateLog -Event 'AssetListRequested' -Data ([ordered]@{ Tag = $Tag })
    Sync-UpdateMenuState
}

function Test-UpdateOperationDeadline {
    if (-not $script:UpdateContext.IsBusy) { return }

    $now = [DateTimeOffset]::Now
    $phase = $script:UpdateContext.Phase
    $isDownload = $phase -in @('DownloadResponse', 'DownloadStream',
        'DownloadCopy')
    $start = $script:UpdateContext.StartedAt
    if (-not $start) { $start = $script:UpdateContext.PhaseStartedAt }
    if (-not $start) { return }

    $total = $now - $start
    $limit = if ($isDownload) {
        $script:UpdateDownloadDeadline
    }
    else {
        $script:UpdateOperationDeadline
    }

    # Stall means the byte counter stopped growing, not that the transfer is
    # slow. A legitimately slow link keeps raising ProgressBytes and must not
    # be cancelled.
    $stalled = $false
    if (
        $isDownload -and
        $script:UpdateContext.LastProgressAt -and
        ($now - $script:UpdateContext.LastProgressAt) -ge
            $script:UpdateDownloadStallDeadline
    ) {
        $stalled = $true
    }

    if (-not $stalled -and $total -lt $limit) { return }

    $waited = [int]$total.TotalSeconds
    if ($script:UpdateContext.Cancellation) {
        try { $script:UpdateContext.Cancellation.Cancel() } catch { }
    }
    Write-UpdateLog -Level Warning -Event 'WatchdogReset' -Data ([ordered]@{
        Phase = $phase
        WaitedSeconds = $waited
        Stalled = $stalled
        Attempt = $script:UpdateContext.Attempt
    })
    $wasAutomatic = $script:UpdateContext.AutomaticInstall
    Stop-UpdateOperation `
        -Event 'OperationTimedOut' `
        -Stage $phase `
        -AlwaysShow:(-not $wasAutomatic) `
        -Message (
            "更新操作超时（已等待 $waited 秒）。`n`n" +
            '请检查网络连接后重试；软件会在后台继续定期检查。'
        )
    return
}

function Complete-ResolvedUpdateRelease {
    param($Release)

    $manual = $script:UpdateContext.Manual
    $escalated = $script:UpdateContext.ManualEscalated
    Reset-UpdateContext
    if (Test-RmfUpdateAvailable `
        -CurrentVersion $script:AppVersion `
        -LatestVersion $Release.Version) {
        Show-UpdateAvailable -Release $Release -Manual:($manual -or $escalated)
    }
    elseif ($manual -or $escalated) {
        Show-UpdateMessage -Message (
            "当前已是最新版本 v$($script:AppVersion)。"
        )
    }
}

function Open-UpdateReleasePage {
    param([string]$ReleaseUrl)

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $ReleaseUrl
    $startInfo.UseShellExecute = $true
    [void][Diagnostics.Process]::Start($startInfo)
}

function Get-UpdateDownloadsRoot {
    if (
        $script:UpdateDiagnosticMode -and
        -not [string]::IsNullOrWhiteSpace($script:UpdateDiagnosticUpdatesRoot)
    ) {
        return $script:UpdateDiagnosticUpdatesRoot
    }
    return Join-Path (Get-AppDataDirectory) 'updates'
}

function Start-UpdateDownload {
    param(
        $Release,
        $Client = $null,
        [switch]$AutomaticInstall
    )

    try {
        if (-not $Client) {
            $Client = Get-UpdateHttpClient
        }
        $script:UpdateContext.SourceClient = $Client
        $script:UpdateContext.IsBusy = $true
        $script:UpdateContext.Manual = -not [bool]$AutomaticInstall
        $script:UpdateContext.AutomaticInstall = [bool]$AutomaticInstall
        $script:UpdateContext.Phase = 'DownloadResponse'
        $script:UpdateContext.PhaseStartedAt = [DateTimeOffset]::Now
        $script:UpdateContext.StartedAt = [DateTimeOffset]::Now
        $script:UpdateContext.Release = $Release
        $script:UpdateContext.Client = $Client
        $script:UpdateContext.Attempt = 1
        $script:UpdateContext.ProgressBytes = 0L
        $script:UpdateContext.ProgressTotal = 0L
        $script:UpdateContext.LastProgressBytes = 0L
        $script:UpdateContext.LastProgressAt = [DateTimeOffset]::Now
        $script:UpdateContext.Cancellation = New-Object Threading.CancellationTokenSource
        $script:UpdateContext.InstallerTask = $Client.GetAsync(
            $Release.InstallerUrl,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead
        )
        $script:UpdateContext.ChecksumTask = $Client.GetByteArrayAsync(
            $Release.ChecksumUrl
        )
        Sync-UpdateMenuState
        Write-UpdateLog -Event 'DownloadStarted' -Data ([ordered]@{
            Version = $Release.Version
            AutomaticInstall = [bool]$AutomaticInstall
            InstallerSizeExact = [bool]$Release.InstallerSizeExact
        })
    }
    catch {
        if ($AutomaticInstall) {
            Reset-UpdateContext
            $script:NextAutomaticUpdateCheckAt = (
                [DateTimeOffset]::Now + [TimeSpan]::FromMinutes(10)
            )
            Write-UpdateLog -Level Warning `
                -Event 'DownloadStartFailed' `
                -Message $_.Exception.Message
            Show-AutoUpdateNotification `
                -Title '自动更新暂未完成' `
                -Message '无法开始下载安装程序，稍后会再次检查。' `
                -Icon Warning
        }
        else {
            Stop-UpdateOperation `
                -AlwaysShow `
                -Event 'DownloadStartFailed' `
                -Stage 'DownloadResponse' `
                -Message ("无法开始下载安装程序。`n`n$($_.Exception.Message)")
        }
    }
}

# Restart the transfer from the response stage with a brand new connection.
# A long lived HttpClient reuses pooled connections; when GitHub has throttled
# this address the pooled socket keeps failing, and a fresh one is measurably
# more likely to succeed.
function Restart-UpdateDownloadAttempt {
    param($Release)

    Close-UpdateTransferStreams
    # Production always recreates the pooled connection; a caller-supplied
    # client (diagnostics) is reused so the injected sequence stays in control.
    $client = if ($script:UpdateContext.SourceClient) {
        $script:UpdateContext.SourceClient
    }
    else {
        Reset-UpdateHttpClient
        Get-UpdateHttpClient
    }
    $script:UpdateContext.Attempt++
    $script:UpdateContext.Phase = 'DownloadResponse'
    $script:UpdateContext.PhaseStartedAt = [DateTimeOffset]::Now
    $script:UpdateContext.Client = $client
    $script:UpdateContext.ProgressBytes = 0L
    $script:UpdateContext.ProgressTotal = 0L
    $script:UpdateContext.LastProgressBytes = 0L
    $script:UpdateContext.LastProgressAt = [DateTimeOffset]::Now
    $script:UpdateContext.Cancellation = New-Object Threading.CancellationTokenSource
    $script:UpdateContext.InstallerTask = $client.GetAsync(
        $Release.InstallerUrl,
        [Net.Http.HttpCompletionOption]::ResponseHeadersRead
    )
    $script:UpdateContext.ChecksumTask = $client.GetByteArrayAsync(
        $Release.ChecksumUrl
    )
    Sync-UpdateMenuState
    Write-UpdateLog -Event 'DownloadRetried' -Data ([ordered]@{
        Version = $Release.Version
        Attempt = $script:UpdateContext.Attempt
    })
}

function Save-VerifiedUpdateInstaller {
    param(
        $Release,
        [byte[]]$ChecksumBytes
    )

    $updatesRoot = Get-UpdateDownloadsRoot
    $versionDirectory = Join-Path $updatesRoot $Release.Tag
    New-Item -Path $versionDirectory -ItemType Directory -Force | Out-Null
    $installerPath = Join-Path $versionDirectory $Release.InstallerName
    $temporaryPath = "$installerPath.download"
    if (-not (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
        throw '安装程序临时文件不存在。'
    }

    try {
        $installerBytes = [IO.File]::ReadAllBytes($temporaryPath)
        Assert-UpdatePayload `
            -Release $Release `
            -InstallerBytes $installerBytes `
            -ChecksumBytes $ChecksumBytes
        Assert-UpdateInstallerMetadata `
            -InstallerPath $temporaryPath `
            -Release $Release
        if (Test-Path -LiteralPath $installerPath) {
            Remove-Item -LiteralPath $installerPath -Force
        }
        Move-Item -LiteralPath $temporaryPath -Destination $installerPath
    }
    catch {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        throw
    }
    return $installerPath
}

function Start-VerifiedUpdateInstaller {
    param(
        [string]$InstallerPath,
        [string]$Version,
        [switch]$AutomaticInstall
    )

    if ($script:UpdateDiagnosticMode) {
        $script:UpdateDiagnosticInstallerPath = $InstallerPath
        $script:UpdateDiagnosticInstallerVersion = $Version
        $script:UpdateDiagnosticAutomaticInstall = [bool]$AutomaticInstall
        if ($AutomaticInstall) {
            $script:UpdateDiagnosticInstallerArguments = (
                Get-AutoUpdateInstallerArguments
            )
            $script:UpdateDiagnosticWindowCloseRequested = $true
        }
        return
    }

    if ($AutomaticInstall) {
        if (-not $script:AutoUpdateEnabled) { return }
        if (-not (Test-AutoUpdateInstalledMode)) {
            Clear-DeferredAutoUpdate
            Show-AutoUpdateNotification `
                -Title '自动更新未启动' `
                -Message '自动更新仅支持通过安装程序安装的版本。' `
                -Icon Warning
            return
        }

        $networkState = Get-AutoUpdateNetworkState
        if (-not $networkState.Suitable) {
            Set-DeferredAutoUpdateInstaller `
                -InstallerPath $InstallerPath `
                -Version $Version `
                -Reason $networkState.Reason
            return
        }

        Save-Settings
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $InstallerPath
        $startInfo.Arguments = Get-AutoUpdateInstallerArguments
        $startInfo.UseShellExecute = $true
        [void][Diagnostics.Process]::Start($startInfo)
        Clear-DeferredAutoUpdate
        Show-AutoUpdateNotification `
            -Title "正在安装 v$Version" `
            -Message '软件即将关闭，更新完成后会自动重新启动。'
        $window.Close()
        return
    }

    if (-not (Test-TrustedUpdateInstallerSignature -InstallerPath $InstallerPath)) {
        $choice = [Windows.MessageBox]::Show(
            $window,
            (
                "v$Version 已通过 SHA-256 完整性和内嵌版本校验。`n`n" +
                '当前项目尚未配置可信代码签名，因此软件不会自动运行安装程序。' +
                '是否打开文件所在位置，由你手动确认后安装？'
            ),
            'Remaining Margin Float 更新',
            [Windows.MessageBoxButton]::YesNo,
            [Windows.MessageBoxImage]::Warning
        )
        if ($choice -eq [Windows.MessageBoxResult]::Yes) {
            $explorerPath = Join-Path $env:SystemRoot 'explorer.exe'
            $startInfo = New-Object Diagnostics.ProcessStartInfo
            $startInfo.FileName = $explorerPath
            $startInfo.Arguments = "/select,`"$InstallerPath`""
            $startInfo.UseShellExecute = $true
            [void][Diagnostics.Process]::Start($startInfo)
        }
        return
    }

    $choice = [Windows.MessageBox]::Show(
        $window,
        (
            "v$Version 已通过完整性、版本和可信发布者校验。`n`n" +
            '现在关闭软件并启动安装程序吗？安装过程中可以选择安装位置。'
        ),
        'Remaining Margin Float 更新',
        [Windows.MessageBoxButton]::YesNo,
        [Windows.MessageBoxImage]::Question
    )
    if ($choice -ne [Windows.MessageBoxResult]::Yes) {
        return
    }

    Save-Settings
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $InstallerPath
    $startInfo.UseShellExecute = $true
    [void][Diagnostics.Process]::Start($startInfo)
    $window.Close()
}

function Set-DeferredAutoUpdateRelease {
    param(
        $Release,
        [string]$Reason
    )

    $script:DeferredAutoUpdateRelease = $Release
    $script:DeferredAutoUpdateInstaller = $null
    $script:NextAutoUpdateNetworkRetryAt = (
        [DateTimeOffset]::Now + [TimeSpan]::FromMinutes(1)
    )
    $notificationKey = "release-$($Release.Version)"
    if (-not $script:AutoUpdateDeferredNotifications.ContainsKey(
        $notificationKey
    )) {
        $script:AutoUpdateDeferredNotifications[$notificationKey] = $true
        Show-AutoUpdateNotification `
            -Title "v$($Release.Version) 等待合适网络" `
            -Message "$Reason 将在网络条件合适时自动更新。"
    }
}

function Set-DeferredAutoUpdateInstaller {
    param(
        [string]$InstallerPath,
        [string]$Version,
        [string]$Reason
    )

    $script:DeferredAutoUpdateInstaller = [pscustomobject]@{
        InstallerPath = $InstallerPath
        Version = $Version
    }
    $script:DeferredAutoUpdateRelease = $null
    $script:NextAutoUpdateNetworkRetryAt = (
        [DateTimeOffset]::Now + [TimeSpan]::FromMinutes(1)
    )
    $notificationKey = "installer-$Version"
    if (-not $script:AutoUpdateDeferredNotifications.ContainsKey(
        $notificationKey
    )) {
        $script:AutoUpdateDeferredNotifications[$notificationKey] = $true
        Show-AutoUpdateNotification `
            -Title "v$Version 等待安装" `
            -Message "$Reason 将在网络条件合适时自动安装并重启。"
    }
}

function Start-DeferredAutoUpdateIfReady {
    if (-not $script:AutoUpdateEnabled) {
        Clear-DeferredAutoUpdate
        return
    }
    if ($script:UpdateContext.IsBusy) { return }
    if (
        -not $script:DeferredAutoUpdateRelease -and
        -not $script:DeferredAutoUpdateInstaller
    ) {
        return
    }
    if (
        $script:NextAutoUpdateNetworkRetryAt -and
        [DateTimeOffset]::Now -lt $script:NextAutoUpdateNetworkRetryAt
    ) {
        return
    }

    $networkState = Get-AutoUpdateNetworkState
    if (-not $networkState.Suitable) {
        $script:NextAutoUpdateNetworkRetryAt = (
            [DateTimeOffset]::Now + [TimeSpan]::FromMinutes(1)
        )
        return
    }
    if (-not (Test-AutoUpdateInstalledMode)) {
        Clear-DeferredAutoUpdate
        return
    }

    if ($script:DeferredAutoUpdateInstaller) {
        $installer = $script:DeferredAutoUpdateInstaller
        $script:DeferredAutoUpdateInstaller = $null
        $script:NextAutoUpdateNetworkRetryAt = $null
        Start-VerifiedUpdateInstaller `
            -InstallerPath $installer.InstallerPath `
            -Version $installer.Version `
            -AutomaticInstall
        return
    }

    $release = $script:DeferredAutoUpdateRelease
    $script:DeferredAutoUpdateRelease = $null
    $script:NextAutoUpdateNetworkRetryAt = $null
    Show-AutoUpdateNotification `
        -Title "正在下载 v$($release.Version)" `
        -Message '已连接到合适网络，开始自动下载并校验更新。'
    Start-UpdateDownload -Release $release -AutomaticInstall
}

function Show-UpdateAvailable {
    param(
        $Release,
        [switch]$Manual
    )

    if ($script:AutoUpdateEnabled) {
        if (-not $Release.HasInstaller) {
            if (
                $Manual -or
                -not $script:PromptedUpdateVersions.ContainsKey(
                    $Release.Version
                )
            ) {
                $script:PromptedUpdateVersions[$Release.Version] = $true
                if ($Manual) {
                    Show-UpdateMessage -Message (
                        "v$($Release.Version) 未提供可验证的安装程序，" +
                        '请从 Release 页面手动更新。'
                    )
                }
                else {
                    Show-AutoUpdateNotification `
                        -Title "v$($Release.Version) 需要手动更新" `
                        -Message '此版本未提供可验证的安装程序。' `
                        -Icon Warning
                }
            }
            return
        }
        if (-not (Test-AutoUpdateInstalledMode)) {
            if ($Manual) {
                Show-UpdateMessage -Message (
                    '自动更新仅支持通过安装程序安装的版本。' +
                    '当前运行方式请继续手动更新。'
                )
            }
            return
        }

        $networkState = Get-AutoUpdateNetworkState
        if (-not $networkState.Suitable) {
            Set-DeferredAutoUpdateRelease `
                -Release $Release `
                -Reason $networkState.Reason
            if ($Manual) {
                Show-UpdateMessage -Message (
                    "已发现 v$($Release.Version)，但$($networkState.Reason)" +
                    "`n`n更新会在网络条件合适时自动下载、安装并重启。"
                )
            }
            return
        }

        $script:PromptedUpdateVersions[$Release.Version] = $true
        Show-AutoUpdateNotification `
            -Title "正在下载 v$($Release.Version)" `
            -Message '安装程序通过校验后将自动安装并重启软件。'
        Start-UpdateDownload -Release $Release -AutomaticInstall
        return
    }

    if (
        -not $Manual -and
        $script:PromptedUpdateVersions.ContainsKey($Release.Version)
    ) {
        return
    }
    $script:PromptedUpdateVersions[$Release.Version] = $true
    Show-ExistingWindow

    $message = (
        "发现新版本 v$($Release.Version)，当前版本为 v$($script:AppVersion)。`n`n"
    )
    if ($Release.HasInstaller) {
        $message += '是否下载并校验此 Release 的安装程序？'
    }
    else {
        $message += '此版本未提供可验证的安装程序，是否打开 Release 页面？'
    }
    $choice = [Windows.MessageBox]::Show(
        $window,
        $message,
        'Remaining Margin Float 更新',
        [Windows.MessageBoxButton]::YesNo,
        [Windows.MessageBoxImage]::Information
    )
    if ($choice -ne [Windows.MessageBoxResult]::Yes) {
        return
    }
    if ($Release.HasInstaller) {
        Start-UpdateDownload -Release $Release
    }
    else {
        Open-UpdateReleasePage -ReleaseUrl $Release.ReleaseUrl
    }
}

function Complete-UpdateDownloadResponse {
    $task = $script:UpdateContext.InstallerTask
    if (-not $task -or -not $task.IsCompleted) { return }
    $response = $null
    try {
        $response = $task.GetAwaiter().GetResult()
        [void]$response.EnsureSuccessStatusCode()
        $declaredLength = $response.Content.Headers.ContentLength
        $script:UpdateContext.ProgressTotal = if ($null -eq $declaredLength) {
            0L
        }
        else {
            [long]$declaredLength
        }
        $script:UpdateContext.Response = $response
        $script:UpdateContext.StreamTask = $response.Content.ReadAsStreamAsync()
        $script:UpdateContext.Phase = 'DownloadStream'
        $script:UpdateContext.PhaseStartedAt = [DateTimeOffset]::Now
        $script:UpdateContext.LastProgressAt = [DateTimeOffset]::Now
        Sync-UpdateMenuState
        $response = $null
    }
    catch {
        $release = $script:UpdateContext.Release
        $statusCode = if ($response) { [int]$response.StatusCode } else { 0 }
        if ($response) { $response.Dispose() }
        $response = $null
        if (
            $script:UpdateContext.Attempt -lt $script:UpdateDownloadAttempts
        ) {
            Restart-UpdateDownloadAttempt -Release $release
            return
        }
        Stop-UpdateDownload `
            -Event 'DownloadResponseFailed' `
            -StatusCode $statusCode `
            -Message (
                "下载更新失败。`n`n$($_.Exception.Message)"
            )
    }
    finally {
        if ($response) { $response.Dispose() }
    }
}

function Complete-UpdateDownloadStream {
    $task = $script:UpdateContext.StreamTask
    if (-not $task -or -not $task.IsCompleted) { return }
    $stream = $null
    try {
        $stream = $task.GetAwaiter().GetResult()
        $versionDirectory = Join-Path (
            Get-UpdateDownloadsRoot
        ) $script:UpdateContext.Release.Tag
        New-Item `
            -Path $versionDirectory `
            -ItemType Directory `
            -Force | Out-Null
        $installerPath = Join-Path `
            $versionDirectory `
            $script:UpdateContext.Release.InstallerName
        $temporaryPath = "$installerPath.download"
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        $script:UpdateContext.File = [IO.File]::Create($temporaryPath)
        $script:UpdateContext.TemporaryPath = $temporaryPath
        $script:UpdateContext.Stream = $stream
        $script:UpdateContext.CopyTask = $stream.CopyToAsync(
            $script:UpdateContext.File,
            $script:UpdateDownloadChunkBytes,
            $script:UpdateContext.Cancellation.Token
        )
        $script:UpdateContext.Phase = 'DownloadCopy'
        $script:UpdateContext.PhaseStartedAt = [DateTimeOffset]::Now
        $script:UpdateContext.LastProgressAt = [DateTimeOffset]::Now
        Sync-UpdateMenuState
    }
    catch {
        $release = $script:UpdateContext.Release
        if ($stream) { $stream.Dispose() }
        if (
            $script:UpdateContext.Attempt -lt $script:UpdateDownloadAttempts
        ) {
            Restart-UpdateDownloadAttempt -Release $release
            return
        }
        Stop-UpdateDownload `
            -Event 'DownloadStreamFailed' `
            -StatusCode 0 `
            -Message ("下载更新失败。`n`n$($_.Exception.Message)")
    }
}

function Complete-UpdateDownloadCopy {
    $file = $script:UpdateContext.File
    if ($file) {
        try {
            $written = $file.Length
        }
        catch {
            $written = $script:UpdateContext.ProgressBytes
        }
        if ($written -gt $script:UpdateContext.LastProgressBytes) {
            $script:UpdateContext.LastProgressBytes = $written
            $script:UpdateContext.LastProgressAt = [DateTimeOffset]::Now
        }
        $script:UpdateContext.ProgressBytes = $written
        Sync-UpdateMenuState
    }

    $task = $script:UpdateContext.CopyTask
    if (-not $task -or -not $task.IsCompleted) { return }
    $release = $script:UpdateContext.Release
    $automaticInstall = [bool]$script:UpdateContext.AutomaticInstall
    $temporaryPath = $script:UpdateContext.TemporaryPath
    try {
        # VoidTaskResult leaks into the pipeline unless it is discarded.
        [void]$task.GetAwaiter().GetResult()
        Close-UpdateTransferStreams
        if (-not $script:UpdateContext.ChecksumTask -or
            -not $script:UpdateContext.ChecksumTask.IsCompleted) {
            throw '校验文件尚未下载完成。'
        }
        $checksumBytes = $script:UpdateContext.ChecksumTask.
            GetAwaiter().GetResult()
        $installerPath = Save-VerifiedUpdateInstaller `
            -Release $release `
            -ChecksumBytes $checksumBytes
        Write-UpdateLog -Event 'DownloadCompleted' -Data ([ordered]@{
            Version = $release.Version
            Bytes = (Get-Item -LiteralPath $installerPath).Length
        })
        Write-UpdateLog -Event 'Verified' -Data ([ordered]@{
            Version = $release.Version
            Sha256 = (Get-ByteArraySha256 -Bytes (
                [IO.File]::ReadAllBytes($installerPath)
            )).Substring(0, 12)
        })
        Reset-UpdateContext
        Start-VerifiedUpdateInstaller `
            -InstallerPath $installerPath `
            -Version $release.Version `
            -AutomaticInstall:$automaticInstall
    }
    catch {
        $exception = $_.Exception
        if ($temporaryPath -and
            (Test-Path -LiteralPath $temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        if (
            $script:UpdateContext.Attempt -lt $script:UpdateDownloadAttempts
        ) {
            Restart-UpdateDownloadAttempt -Release $release
            return
        }
        Stop-UpdateDownload `
            -Event 'DownloadVerificationFailed' `
            -StatusCode 0 `
            -Message ("下载更新失败。`n`n$($exception.Message)")
    }
}

function Stop-UpdateDownload {
    param(
        [string]$Event,
        [int]$StatusCode = 0,
        [string]$Message
    )

    if ($script:UpdateContext.AutomaticInstall) {
        Reset-UpdateContext
        $script:NextAutomaticUpdateCheckAt = (
            [DateTimeOffset]::Now + [TimeSpan]::FromMinutes(10)
        )
        Write-UpdateLog -Level Warning `
            -Event $Event `
            -Message $Message `
            -Data ([ordered]@{ StatusCode = $StatusCode })
        Show-AutoUpdateNotification `
            -Title '自动更新暂未完成' `
            -Message '下载或校验失败，稍后会再次检查。' `
            -Icon Warning
        return
    }
    Stop-UpdateOperation `
        -AlwaysShow `
        -Event $Event `
        -Stage $script:UpdateContext.Phase `
        -Data ([ordered]@{ StatusCode = $StatusCode }) `
        -Message $Message
}

# The streaming transfer resolves through real asynchronous file I/O, so the
# diagnostic cannot rely on a single synchronous step to finish it.
function Complete-UpdateOperationUntilIdle {
    param([int]$MaxMilliseconds = 20000)

    $deadline = [DateTimeOffset]::Now.AddMilliseconds($MaxMilliseconds)
    while ($script:UpdateContext.IsBusy) {
        Complete-UpdateOperation
        if (-not $script:UpdateContext.IsBusy) { break }
        if ([DateTimeOffset]::Now -ge $deadline) { break }
        Start-Sleep -Milliseconds 20
    }
}

function Complete-UpdateOperation {
    if (-not $script:UpdateContext.IsBusy) { return }

    if ($script:UpdateContext.Phase -eq 'Release') {
        $task = $script:UpdateContext.ReleaseTask
        if (-not $task -or -not $task.IsCompleted) { return }
        $response = $null
        $statusCode = 0
        $reason = ''
        try {
            $response = $task.GetAwaiter().GetResult()
            $statusCode = [int]$response.StatusCode
            if ($statusCode -notin @(403, 429)) {
                [void]$response.EnsureSuccessStatusCode()
                $releaseJson = (
                    $response.Content.ReadAsStringAsync().
                        GetAwaiter().GetResult()
                )
                $release = ConvertFrom-GitHubRelease -Release (
                    $releaseJson | ConvertFrom-Json
                )
                Set-UpdateCheckSchedule -Succeeded $true
                Write-UpdateLog -Event 'CheckCompleted' -Data ([ordered]@{
                    Source = 'Api'
                    Version = $release.Version
                    HasInstaller = [bool]$release.HasInstaller
                    Manual = [bool]$script:UpdateContext.Manual
                })
                Complete-ResolvedUpdateRelease -Release $release
                return
            }
        }
        catch {
            # A timeout, TLS, DNS or reset failure carries no HTTP status code.
            # The public release page is still reachable in those cases, so the
            # check must continue on the fallback path instead of failing.
            if ($response) { $statusCode = [int]$response.StatusCode }
            $reason = $_.Exception.Message
        }
        finally {
            if ($response) { $response.Dispose() }
        }
        Write-UpdateLog -Event 'CheckFallback' -Data ([ordered]@{
            From = 'Api'
            StatusCode = $statusCode
            Reason = $reason
        })
        try {
            Start-GitHubReleaseFallback `
                -Client $script:UpdateContext.Client
        }
        catch {
            Stop-UpdateOperation `
                -Event 'CheckFailed' `
                -Stage 'ReleaseFallback' `
                -Message (
                    "检查更新失败。`n`n$($_.Exception.Message)"
                )
        }
        return
    }

    if ($script:UpdateContext.Phase -eq 'ReleaseFallback') {
        $task = $script:UpdateContext.ReleaseTask
        if (-not $task -or -not $task.IsCompleted) { return }
        $response = $null
        try {
            $response = $task.GetAwaiter().GetResult()
            $tag = Get-GitHubRedirectReleaseTag -Response $response
            Start-GitHubAssetMetadataFallback `
                -Client $script:UpdateContext.Client `
                -Tag $tag
        }
        catch {
            Stop-UpdateOperation `
                -Event 'CheckFailed' `
                -Stage 'ReleaseFallback' `
                -Message (
                    '无法从 GitHub 获取最新版本信息。' +
                    "`n`n$($_.Exception.Message)"
                )
        }
        finally {
            if ($response) { $response.Dispose() }
        }
        return
    }

    if ($script:UpdateContext.Phase -eq 'ReleaseAssets') {
        $task = $script:UpdateContext.ReleaseTask
        if (-not $task -or -not $task.IsCompleted) { return }
        $response = $null
        try {
            $response = $task.GetAwaiter().GetResult()
            [void]$response.EnsureSuccessStatusCode()
            $html = (
                $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            )
            $release = ConvertFrom-GitHubAssetListHtml `
                -Html $html `
                -Tag $script:UpdateContext.ReleaseTag
            Set-UpdateCheckSchedule -Succeeded $true
            Write-UpdateLog -Event 'AssetListParsed' -Data ([ordered]@{
                Tag = $release.Tag
                Version = $release.Version
                HasInstaller = [bool]$release.HasInstaller
            })
            Write-UpdateLog -Event 'CheckCompleted' -Data ([ordered]@{
                Source = 'ReleasePage'
                Version = $release.Version
                HasInstaller = [bool]$release.HasInstaller
                Manual = [bool]$script:UpdateContext.Manual
            })
            Complete-ResolvedUpdateRelease -Release $release
        }
        catch {
            Stop-UpdateOperation `
                -Event 'CheckFailed' `
                -Stage 'ReleaseAssets' `
                -Message (
                    '无法读取 GitHub Release 的安装程序清单。' +
                    "`n`n$($_.Exception.Message)"
                )
        }
        finally {
            if ($response) { $response.Dispose() }
        }
        return
    }

    if ($script:UpdateContext.Phase -eq 'DownloadResponse') {
        Complete-UpdateDownloadResponse
        return
    }

    if ($script:UpdateContext.Phase -eq 'DownloadStream') {
        Complete-UpdateDownloadStream
        return
    }

    if ($script:UpdateContext.Phase -eq 'DownloadCopy') {
        Complete-UpdateDownloadCopy
        return
    }
}

function Invoke-UpdateTimerTick {
    if ($script:UpdateContext.IsBusy) {
        Test-UpdateOperationDeadline
    }
    Complete-UpdateOperation
    if (-not $script:UpdateContext.IsBusy) {
        Start-DeferredAutoUpdateIfReady
    }
    if (
        -not $script:UpdateContext.IsBusy -and
        $script:NextAutomaticUpdateCheckAt -and
        [DateTimeOffset]::Now -ge $script:NextAutomaticUpdateCheckAt
    ) {
        Start-UpdateCheck
    }
}

function New-UpdateDiagnosticClient {
    param(
        [object[]]$ResponseTasks = @(),
        [object[]]$ByteTasks = @()
    )

    $client = [pscustomobject]@{
        ResponseTasks = @($ResponseTasks)
        ResponseTaskIndex = 0
        ByteTasks = @($ByteTasks)
        ByteTaskIndex = 0
    }
    $client | Add-Member -MemberType ScriptMethod -Name GetAsync -Value {
        param(
            [string]$Url,
            $CompletionOption = $null
        )
        $task = $this.ResponseTasks[$this.ResponseTaskIndex]
        $this.ResponseTaskIndex++
        return $task
    }
    $client | Add-Member `
        -MemberType ScriptMethod `
        -Name GetByteArrayAsync `
        -Value {
            param([string]$Url)
            $task = $this.ByteTasks[$this.ByteTaskIndex]
            $this.ByteTaskIndex++
            return $task
        }
    return $client
}

function New-UpdateDiagnosticResponseTask {
    param($Response)

    $completion = New-Object (
        'Threading.Tasks.TaskCompletionSource[' +
        'System.Net.Http.HttpResponseMessage]'
    )
    $completion.SetResult($Response)
    return $completion.Task
}

function New-UpdateDiagnosticPayloadResponse {
    param([byte[]]$Bytes)

    $response = New-Object Net.Http.HttpResponseMessage(
        [Net.HttpStatusCode]::OK
    )
    $response.Content = New-Object Net.Http.ByteArrayContent `
        -ArgumentList (,$Bytes)
    return $response
}

function Invoke-UpdateDiagnostic {
    $release = [pscustomobject]@{
        tag_name = 'v1.8.0'
        html_url = (
            'https://github.com/LinLey-Nancy/Remaining-margin-float/' +
            'releases/tag/v1.8.0'
        )
        draft = $false
        prerelease = $false
        assets = @(
            [pscustomobject]@{
                name = 'Remaining-Margin-Float-v1.8.0-Setup.exe'
                size = 1048576
                browser_download_url = (
                    'https://github.com/LinLey-Nancy/Remaining-margin-float/' +
                    'releases/download/v1.8.0/' +
                    'Remaining-Margin-Float-v1.8.0-Setup.exe'
                )
            }
            [pscustomobject]@{
                name = 'Remaining-Margin-Float-v1.8.0-Setup.exe.sha256'
                size = 112
                browser_download_url = (
                    'https://github.com/LinLey-Nancy/Remaining-margin-float/' +
                    'releases/download/v1.8.0/' +
                    'Remaining-Margin-Float-v1.8.0-Setup.exe.sha256'
                )
            }
        )
    }
    $parsed = ConvertFrom-GitHubRelease -Release $release
    $sampleHash = 'a' * 64
    $checksum = Get-UpdateChecksum `
        -Text "$sampleHash  $($parsed.InstallerName)" `
        -ExpectedFileName $parsed.InstallerName
    $multiLineChecksumRejected = try {
        [void](Get-UpdateChecksum `
            -Text "unexpected`n$sampleHash  $($parsed.InstallerName)" `
            -ExpectedFileName $parsed.InstallerName)
        $false
    }
    catch {
        $true
    }
    $payloadBytes = [Text.Encoding]::ASCII.GetBytes('abc')
    $payloadHash = Get-ByteArraySha256 -Bytes $payloadBytes
    $payloadChecksumBytes = [Text.Encoding]::ASCII.GetBytes(
        "$payloadHash  $($parsed.InstallerName)"
    )
    $assetListHtml = (
        '<a href="/LinLey-Nancy/Remaining-margin-float/releases/download/' +
        'v1.8.0/Remaining-Margin-Float-v1.8.0-Setup.exe">setup</a>' +
        '<a href="/LinLey-Nancy/Remaining-margin-float/releases/download/' +
        'v1.8.0/Remaining-Margin-Float-v1.8.0-Setup.exe.sha256">sha</a>'
    )
    $payloadRelease = [pscustomobject]@{
        InstallerName = $parsed.InstallerName
        InstallerSize = [long]$payloadBytes.LongLength
        ChecksumSize = [long]$payloadChecksumBytes.LongLength
        InstallerSizeExact = $true
    }
    $payloadVerified = try {
        Assert-UpdatePayload `
            -Release $payloadRelease `
            -InstallerBytes $payloadBytes `
            -ChecksumBytes $payloadChecksumBytes
        $true
    }
    catch {
        $false
    }
    $payloadMismatchRejected = try {
        $wrongChecksumBytes = [Text.Encoding]::ASCII.GetBytes(
            "$sampleHash  $($parsed.InstallerName)"
        )
        $wrongRelease = [pscustomobject]@{
            InstallerName = $parsed.InstallerName
            InstallerSize = [long]$payloadBytes.LongLength
            ChecksumSize = [long]$wrongChecksumBytes.LongLength
        }
        Assert-UpdatePayload `
            -Release $wrongRelease `
            -InstallerBytes $payloadBytes `
            -ChecksumBytes $wrongChecksumBytes
        $false
    }
    catch {
        $true
    }
    $embeddedVersionMismatchRejected = try {
        Assert-UpdateInstallerVersionInfo `
            -VersionInfo ([pscustomobject]@{
                FileVersion = '1.7.0.0'
                ProductVersion = '1.7.0'
            }) `
            -ExpectedVersion '1.8.0'
        $false
    }
    catch {
        $true
    }

    $releaseStateStarted = $false
    $releaseStateCompleted = $false
    $rateLimitFallbackCompleted = $false
    $fallbackInstallerSelected = $false
    $untrustedReleaseRedirectRejected = $false
    $downloadStateStarted = $false
    $partialDownloadFailureReset = $false
    $successfulDownloadCompleted = $false
    $cancelledReleaseReset = $false
    $unrestrictedAutoUpdateAllowed = $false
    $meteredAutoUpdateDeferred = $false
    $restrictedAutoUpdateBlocked = $false
    $sourceModeAutoUpdateRejected = $false
    $autoDownloadIntentPreserved = $false
    $automaticInstallerArgumentsSafe = $false
    $automaticRestartRequested = $false
    $transportFailureFallsBack = $false
    $transportFailureEnteredFallback = $false
    $transportFailureReachedAssetList = $false
    $checkFailureBackoffScheduled = $false
    $manualClickDuringBusyEscalated = $false
    $htmlAssetListParsed = $false
    $htmlAssetListMissingRejected = $false
    $installerSizeExactFalseAllowsRoundedSize = $false
    $installerSizeExactFalseStillVerifiesHash = $false
    $watchdogResetAfterDeadline = $false
    $streamingDownloadVerified = $false
    $streamingDownloadProgressReported = $false
    $streamingDownloadRetriedOnFailure = $false
    $originalContext = $script:UpdateContext
    $originalTrayUpdateItem = $script:TrayUpdateItem
    $originalAutoUpdateEnabled = $script:AutoUpdateEnabled
    $originalDeferredAutoUpdateRelease = $script:DeferredAutoUpdateRelease
    $originalDeferredAutoUpdateInstaller = (
        $script:DeferredAutoUpdateInstaller
    )
    $originalNextAutoUpdateNetworkRetryAt = (
        $script:NextAutoUpdateNetworkRetryAt
    )
    $originalAutoUpdateDeferredNotifications = (
        $script:AutoUpdateDeferredNotifications
    )
    $originalNextCheck = $script:NextAutomaticUpdateCheckAt
    $originalDiagnosticMode = $script:UpdateDiagnosticMode
    $originalDiagnosticMessages = $script:UpdateDiagnosticMessages
    $originalDiagnosticUpdatesRoot = $script:UpdateDiagnosticUpdatesRoot
    $originalDiagnosticInstallerPath = $script:UpdateDiagnosticInstallerPath
    $originalDiagnosticInstallerVersion = (
        $script:UpdateDiagnosticInstallerVersion
    )
    $originalDiagnosticFileVersionInfo = (
        $script:UpdateDiagnosticFileVersionInfo
    )
    $originalDiagnosticNetworkState = (
        $script:UpdateDiagnosticNetworkState
    )
    $originalDiagnosticInstalledMode = (
        $script:UpdateDiagnosticInstalledMode
    )
    $originalDiagnosticInstallerArguments = (
        $script:UpdateDiagnosticInstallerArguments
    )
    $originalDiagnosticAutomaticInstall = (
        $script:UpdateDiagnosticAutomaticInstall
    )
    $originalDiagnosticWindowCloseRequested = (
        $script:UpdateDiagnosticWindowCloseRequested
    )
    $diagnosticUpdatesRoot = Join-Path (
        [IO.Path]::GetTempPath()
    ) ('rmf-update-diagnostic-' + [Guid]::NewGuid().ToString('N'))
    try {
        $script:UpdateDiagnosticMode = $true
        $script:UpdateDiagnosticMessages = @()
        $script:UpdateDiagnosticUpdatesRoot = $diagnosticUpdatesRoot
        $script:UpdateDiagnosticInstallerPath = $null
        $script:UpdateDiagnosticInstallerVersion = $null
        $script:UpdateDiagnosticNetworkState = $null
        $script:UpdateDiagnosticInstalledMode = $null
        $script:UpdateDiagnosticInstallerArguments = ''
        $script:UpdateDiagnosticAutomaticInstall = $false
        $script:UpdateDiagnosticWindowCloseRequested = $false
        $script:AutoUpdateEnabled = $false
        Clear-DeferredAutoUpdate
        $script:AutoUpdateDeferredNotifications = @{}
        $script:UpdateDiagnosticFileVersionInfo = [pscustomobject]@{
            FileVersion = '1.8.0.0'
            ProductVersion = '1.8.0'
        }
        $script:TrayUpdateItem = [pscustomobject]@{
            Enabled = $true
            Text = '检查更新…'
        }

        $releaseResponse = New-Object Net.Http.HttpResponseMessage(
            [Net.HttpStatusCode]::OK
        )
        $releaseResponse.Content = New-Object Net.Http.StringContent(
            ($release | ConvertTo-Json -Depth 6)
        )
        $releaseResponse.RequestMessage =
            New-Object Net.Http.HttpRequestMessage(
                [Net.Http.HttpMethod]::Get,
                $script:UpdateApiUri
            )
        $releaseCompletion = New-Object (
            'Threading.Tasks.TaskCompletionSource[' +
            'System.Net.Http.HttpResponseMessage]'
        )
        $releaseCompletion.SetResult($releaseResponse)
        $releaseClient = New-UpdateDiagnosticClient `
            -ResponseTasks @($releaseCompletion.Task)
        Start-UpdateCheck -Client $releaseClient
        $releaseStateStarted = (
            $script:UpdateContext.IsBusy -and
            $script:UpdateContext.Phase -eq 'Release' -and
            -not $script:TrayUpdateItem.Enabled -and
            $script:TrayUpdateItem.Text -match '^正在检查更新… · 已等待 \d+ 秒$'
        )
        Invoke-UpdateTimerTick
        $releaseStateCompleted = (
            -not $script:UpdateContext.IsBusy -and
            $script:UpdateContext.Phase -eq 'Idle' -and
            $script:TrayUpdateItem.Enabled -and
            $script:TrayUpdateItem.Text -eq '检查更新…'
        )

        $rateLimitResponse = New-Object Net.Http.HttpResponseMessage(
            [Net.HttpStatusCode]::Forbidden
        )
        $rateLimitResponse.RequestMessage =
            New-Object Net.Http.HttpRequestMessage(
                [Net.Http.HttpMethod]::Get,
                $script:UpdateApiUri
            )
        $redirectResponse = New-Object Net.Http.HttpResponseMessage(
            [Net.HttpStatusCode]::OK
        )
        $redirectResponse.RequestMessage =
            New-Object Net.Http.HttpRequestMessage(
                [Net.Http.HttpMethod]::Get,
                (
                    'https://github.com/LinLey-Nancy/' +
                    'Remaining-margin-float/releases/tag/v1.8.0'
                )
            )
        $fallbackAssetListResponse =
            New-Object Net.Http.HttpResponseMessage(
                [Net.HttpStatusCode]::OK
        )
        $fallbackAssetListResponse.Content = New-Object Net.Http.StringContent(
            $assetListHtml
        )
        $diagnosticFallbackRelease = New-GitHubRedirectRelease `
            -Tag 'v1.8.0' `
            -InstallerSize $payloadBytes.LongLength `
            -ChecksumSize $payloadChecksumBytes.LongLength
        $fallbackInstallerSelected = (
            $diagnosticFallbackRelease.HasInstaller -and
            $diagnosticFallbackRelease.InstallerName -eq
                'Remaining-Margin-Float-v1.8.0-Setup.exe'
        )
        $fallbackTasks = @(
            (New-UpdateDiagnosticResponseTask -Response $rateLimitResponse)
            (New-UpdateDiagnosticResponseTask -Response $redirectResponse)
            (New-UpdateDiagnosticResponseTask -Response $fallbackAssetListResponse)
        )
        $fallbackClient = New-UpdateDiagnosticClient `
            -ResponseTasks $fallbackTasks
        Start-UpdateCheck -Client $fallbackClient
        Complete-UpdateOperation
        $rateLimitFallbackStarted = (
            $script:UpdateContext.IsBusy -and
            $script:UpdateContext.Phase -eq 'ReleaseFallback'
        )
        Complete-UpdateOperation
        $rateLimitAssetProbeStarted = (
            $script:UpdateContext.IsBusy -and
            $script:UpdateContext.Phase -eq 'ReleaseAssets'
        )
        Complete-UpdateOperation
        $rateLimitFallbackCompleted = (
            $rateLimitFallbackStarted -and
            $rateLimitAssetProbeStarted -and
            -not $script:UpdateContext.IsBusy -and
            $script:UpdateContext.Phase -eq 'Idle' -and
            $script:UpdateDiagnosticMessages.Count -eq 0
        )
        $untrustedRedirect = New-Object Net.Http.HttpResponseMessage(
            [Net.HttpStatusCode]::OK
        )
        $untrustedRedirect.RequestMessage =
            New-Object Net.Http.HttpRequestMessage(
                [Net.Http.HttpMethod]::Get,
                'https://example.com/releases/tag/v1.8.0'
            )
        $untrustedReleaseRedirectRejected = try {
            [void](Get-GitHubRedirectReleaseTag -Response $untrustedRedirect)
            $false
        }
        catch {
            $true
        }
        finally {
            $untrustedRedirect.Dispose()
        }

        $checksumFailure = New-Object (
            'Threading.Tasks.TaskCompletionSource[byte[]]'
        )
        $checksumFailure.SetException(
            (New-Object InvalidOperationException 'checksum download failed')
        )
        $checksumFailureRetry = New-Object (
            'Threading.Tasks.TaskCompletionSource[byte[]]'
        )
        $checksumFailureRetry.SetException(
            (New-Object InvalidOperationException 'checksum retry failed')
        )
        $payloadResponse = New-UpdateDiagnosticResponseTask -Response (
            New-UpdateDiagnosticPayloadResponse -Bytes $payloadBytes
        )
        $payloadResponseRetry = New-UpdateDiagnosticResponseTask -Response (
            New-UpdateDiagnosticPayloadResponse -Bytes $payloadBytes
        )
        $downloadClient = New-UpdateDiagnosticClient -ResponseTasks @(
            $payloadResponse
            $payloadResponseRetry
        ) -ByteTasks @(
            $checksumFailure.Task
            $checksumFailureRetry.Task
        )
        $messagesBeforePartialFailure = $script:UpdateDiagnosticMessages.Count
        Start-UpdateDownload -Release $parsed -Client $downloadClient
        $downloadStateStarted = (
            $script:UpdateContext.IsBusy -and
            $script:UpdateContext.Phase -eq 'DownloadResponse' -and
            -not $script:TrayUpdateItem.Enabled -and
            $script:TrayUpdateItem.Text -match '^正在下载安装程序'
        )
        Complete-UpdateOperationUntilIdle
        $partialDownloadFailureReset = (
            -not $script:UpdateContext.IsBusy -and
            $script:UpdateContext.Phase -eq 'Idle' -and
            $script:UpdateDiagnosticMessages.Count -eq
                ($messagesBeforePartialFailure + 1)
        )

        $successfulRelease = [pscustomobject]@{
            Tag = 'v1.8.0'
            Version = '1.8.0'
            InstallerName = $parsed.InstallerName
            InstallerUrl = $parsed.InstallerUrl
            ChecksumUrl = $parsed.ChecksumUrl
            InstallerSize = [long]$payloadBytes.LongLength
            ChecksumSize = [long]$payloadChecksumBytes.LongLength
            InstallerSizeExact = $true
        }
        $successfulChecksum = New-Object (
            'Threading.Tasks.TaskCompletionSource[byte[]]'
        )
        $successfulChecksum.SetResult($payloadChecksumBytes)
        $successfulClient = New-UpdateDiagnosticClient -ResponseTasks @(
            (New-UpdateDiagnosticResponseTask -Response (
                New-UpdateDiagnosticPayloadResponse -Bytes $payloadBytes
            ))
        ) -ByteTasks @(
            $successfulChecksum.Task
        )
        Start-UpdateDownload `
            -Release $successfulRelease `
            -Client $successfulClient
        Complete-UpdateOperationUntilIdle
        $successfulDownloadCompleted = (
            -not $script:UpdateContext.IsBusy -and
            $script:UpdateContext.Phase -eq 'Idle' -and
            $script:UpdateDiagnosticInstallerVersion -eq '1.8.0' -and
            (Test-Path `
                -LiteralPath $script:UpdateDiagnosticInstallerPath `
                -PathType Leaf) -and
            (Get-ByteArraySha256 -Bytes (
                [IO.File]::ReadAllBytes(
                    $script:UpdateDiagnosticInstallerPath
                )
            )) -eq $payloadHash
        )

        $cancelledRelease = New-Object (
            'Threading.Tasks.TaskCompletionSource[' +
            'System.Net.Http.HttpResponseMessage]'
        )
        $cancelledRelease.SetCanceled()
        $cancelledFallback = New-Object (
            'Threading.Tasks.TaskCompletionSource[' +
            'System.Net.Http.HttpResponseMessage]'
        )
        $cancelledFallback.SetCanceled()
        $cancelledClient = New-UpdateDiagnosticClient `
            -ResponseTasks @($cancelledRelease.Task, $cancelledFallback.Task)
        Start-UpdateCheck -Client $cancelledClient
        Complete-UpdateOperation
        Complete-UpdateOperation
        $cancelledReleaseReset = (
            -not $script:UpdateContext.IsBusy -and
            $script:UpdateContext.Phase -eq 'Idle'
        )

        $unrestrictedNetwork = [pscustomobject]@{
            Suitable = $true
            Reason = ''
            ConnectivityLevel = 'InternetAccess'
            CostType = 'Unrestricted'
            Roaming = $false
            OverDataLimit = $false
            ApproachingDataLimit = $false
            BackgroundDataUsageRestricted = $false
        }
        $meteredNetwork = [pscustomobject]@{
            Suitable = $false
            Reason = '当前网络可能按流量计费。'
            ConnectivityLevel = 'InternetAccess'
            CostType = 'Fixed'
            Roaming = $false
            OverDataLimit = $false
            ApproachingDataLimit = $false
            BackgroundDataUsageRestricted = $false
        }
        $restrictedNetwork = [pscustomobject]@{
            Suitable = $false
            Reason = ''
            ConnectivityLevel = 'InternetAccess'
            CostType = 'Unrestricted'
            Roaming = $true
            OverDataLimit = $false
            ApproachingDataLimit = $true
            BackgroundDataUsageRestricted = $true
        }
        $script:UpdateDiagnosticNetworkState = $unrestrictedNetwork
        $unrestrictedAutoUpdateAllowed = (
            (Get-AutoUpdateNetworkState).Suitable
        )
        $script:UpdateDiagnosticNetworkState = $restrictedNetwork
        $restrictedAutoUpdateBlocked = -not (
            (Get-AutoUpdateNetworkState).Suitable
        )
        $script:UpdateDiagnosticNetworkState = $unrestrictedNetwork
        $script:UpdateDiagnosticInstalledMode = $false
        $sourceModeAutoUpdateRejected = -not (
            Test-AutoUpdateInstalledMode
        )

        $pendingInstaller = New-Object (
            'Threading.Tasks.TaskCompletionSource[byte[]]'
        )
        $pendingChecksum = New-Object (
            'Threading.Tasks.TaskCompletionSource[byte[]]'
        )
        $automaticDownloadClient = New-UpdateDiagnosticClient -ByteTasks @(
            $pendingInstaller.Task
            $pendingChecksum.Task
        )
        Start-UpdateDownload `
            -Release $parsed `
            -Client $automaticDownloadClient `
            -AutomaticInstall
        $autoDownloadIntentPreserved = (
            $script:UpdateContext.IsBusy -and
            $script:UpdateContext.Phase -eq 'DownloadResponse' -and
            $script:UpdateContext.AutomaticInstall -and
            -not $script:UpdateContext.Manual
        )
        Reset-UpdateContext

        $script:UpdateDiagnosticInstalledMode = $true
        $script:UpdateDiagnosticNetworkState = $meteredNetwork
        $script:AutoUpdateEnabled = $true
        Show-UpdateAvailable -Release $parsed
        $meteredAutoUpdateDeferred = (
            $null -ne $script:DeferredAutoUpdateRelease -and
            $script:DeferredAutoUpdateRelease.Version -eq '1.8.0' -and
            $null -ne $script:NextAutoUpdateNetworkRetryAt
        )
        Clear-DeferredAutoUpdate

        $script:UpdateDiagnosticNetworkState = $unrestrictedNetwork
        Start-VerifiedUpdateInstaller `
            -InstallerPath 'C:\diagnostic\update.exe' `
            -Version '1.8.0' `
            -AutomaticInstall
        $automaticInstallerArgumentsSafe = (
            $script:UpdateDiagnosticAutomaticInstall -and
            $script:UpdateDiagnosticInstallerArguments -match '/VERYSILENT' -and
            $script:UpdateDiagnosticInstallerArguments -match '/NORESTART' -and
            $script:UpdateDiagnosticInstallerArguments -match '/CURRENTUSER' -and
            $script:UpdateDiagnosticInstallerArguments -match '/CLOSEAPPLICATIONS' -and
            $script:UpdateDiagnosticInstallerArguments -match '/RMFAUTORESTART=1' -and
            $script:UpdateDiagnosticInstallerArguments -notmatch '/DIR=' -and
            $script:UpdateDiagnosticInstallerArguments -notmatch '/TASKS=' -and
            $script:UpdateDiagnosticInstallerArguments -notmatch (
                '/FORCECLOSEAPPLICATIONS'
            )
        )
        $automaticRestartRequested = (
            $script:UpdateDiagnosticWindowCloseRequested
        )

        # --- Update reliability probes -------------------------------------
        # These cover the "update check sometimes fails or takes too long"
        # report. Every probe here is written so that it also runs against the
        # pre-fix code: probes that need API surface the fix introduces guard
        # on Get-Command and report $false instead of throwing under
        # StrictMode, so a red run on the old code is real evidence rather than
        # a crash.
        $messagesBeforeReliabilityProbes = (
            $script:UpdateDiagnosticMessages.Count
        )

        # A transport-level failure (timeout, TLS, DNS, reset) is not an HTTP
        # status code, so the pre-fix code aborted instead of falling back to
        # the public release page that still works.
        $transportFault = New-Object (
            'Threading.Tasks.TaskCompletionSource[' +
            'System.Net.Http.HttpResponseMessage]'
        )
        $transportFault.SetException(
            (
                New-Object Net.Http.HttpRequestException (
                    'simulated transport failure'
                )
            )
        )
        $transportRedirect = New-Object Net.Http.HttpResponseMessage(
            [Net.HttpStatusCode]::OK
        )
        $transportRedirect.RequestMessage =
            New-Object Net.Http.HttpRequestMessage(
                [Net.Http.HttpMethod]::Get,
                (
                    'https://github.com/LinLey-Nancy/' +
                    'Remaining-margin-float/releases/tag/v1.8.0'
                )
            )
        $transportAssetList = New-Object Net.Http.HttpResponseMessage(
            [Net.HttpStatusCode]::OK
        )
        $transportAssetList.Content = New-Object Net.Http.StringContent(
            $assetListHtml
        )
        $transportClient = New-UpdateDiagnosticClient -ResponseTasks @(
            $transportFault.Task
            (New-UpdateDiagnosticResponseTask -Response $transportRedirect)
            (New-UpdateDiagnosticResponseTask -Response $transportAssetList)
        )
        Start-UpdateCheck -Client $transportClient
        Complete-UpdateOperation
        $transportFailureEnteredFallback = (
            $script:UpdateContext.IsBusy -and
            $script:UpdateContext.Phase -eq 'ReleaseFallback'
        )
        Complete-UpdateOperation
        $transportFailureReachedAssetList = (
            $script:UpdateContext.IsBusy -and
            $script:UpdateContext.Phase -eq 'ReleaseAssets'
        )
        Complete-UpdateOperation
        $transportFailureFallsBack = (
            $transportFailureEnteredFallback -and
            $transportFailureReachedAssetList -and
            -not $script:UpdateContext.IsBusy -and
            $script:UpdateContext.Phase -eq 'Idle' -and
            $script:UpdateDiagnosticMessages.Count -eq
                $messagesBeforeReliabilityProbes
        )

        # A failed check must fall back to a short retry ladder instead of
        # waiting the full interval.
        $backoffApiFault = New-Object (
            'Threading.Tasks.TaskCompletionSource[' +
            'System.Net.Http.HttpResponseMessage]'
        )
        $backoffApiFault.SetException(
            (
                New-Object Net.Http.HttpRequestException (
                    'simulated api failure'
                )
            )
        )
        $backoffFallbackFault = New-Object (
            'Threading.Tasks.TaskCompletionSource[' +
            'System.Net.Http.HttpResponseMessage]'
        )
        $backoffFallbackFault.SetException(
            (
                New-Object Net.Http.HttpRequestException (
                    'simulated fallback failure'
                )
            )
        )
        $script:NextAutomaticUpdateCheckAt = $null
        $backoffClient = New-UpdateDiagnosticClient -ResponseTasks @(
            $backoffApiFault.Task
            $backoffFallbackFault.Task
        )
        Start-UpdateCheck -Client $backoffClient
        Complete-UpdateOperation
        Complete-UpdateOperation
        $checkFailureBackoffScheduled = (
            $script:NextAutomaticUpdateCheckAt -and
            (
                $script:NextAutomaticUpdateCheckAt - [DateTimeOffset]::Now
            ) -le [TimeSpan]::FromMinutes(61)
        )

        # Clicking "check for updates" while a background check is running must
        # not be dismissed; it must upgrade the running operation instead.
        $pendingManualRelease = New-Object (
            'Threading.Tasks.TaskCompletionSource[' +
            'System.Net.Http.HttpResponseMessage]'
        )
        $pendingManualClient = New-UpdateDiagnosticClient -ResponseTasks @(
            $pendingManualRelease.Task
        )
        Start-UpdateCheck -Client $pendingManualClient
        $messagesBeforeEscalation = $script:UpdateDiagnosticMessages.Count
        Start-UpdateCheck -Manual -Client $pendingManualClient
        $manualClickDuringBusyEscalated = (
            $script:UpdateContext.IsBusy -and
            $script:UpdateContext.Phase -eq 'Release' -and
            $script:UpdateDiagnosticMessages.Count -eq $messagesBeforeEscalation
        )
        Reset-UpdateContext

        # Asset list parsing, rounded-size tolerance and hash enforcement on
        # the HTML fallback path.
        $htmlAssetListParsed = $false
        $htmlAssetListMissingRejected = $false
        $installerSizeExactFalseAllowsRoundedSize = $false
        $installerSizeExactFalseStillVerifiesHash = $false
        if (Get-Command -Name 'ConvertFrom-GitHubAssetListHtml' `
            -ErrorAction SilentlyContinue) {
            $parsedAssetList = ConvertFrom-GitHubAssetListHtml `
                -Html $assetListHtml `
                -Tag 'v1.8.0'
            $htmlAssetListParsed = (
                $parsedAssetList.HasInstaller -and
                $parsedAssetList.HasChecksum -and
                -not $parsedAssetList.InstallerSizeExact
            )
            $missingAssetList = ConvertFrom-GitHubAssetListHtml -Html (
                '<a href="/LinLey-Nancy/Remaining-margin-float/releases/' +
                'download/v1.8.0/Remaining-Margin-Float-v1.8.0-Setup.exe' +
                '.sha256">sha</a>'
            ) -Tag 'v1.8.0'
            $htmlAssetListMissingRejected = -not $missingAssetList.HasInstaller

            $roundedChecksumBytes = [Text.Encoding]::ASCII.GetBytes(
                "$payloadHash  $($parsed.InstallerName)"
            )
            $installerSizeExactFalseAllowsRoundedSize = try {
                Assert-UpdatePayload -Release ([pscustomobject]@{
                    InstallerName = $parsed.InstallerName
                    InstallerSize = [long]$payloadBytes.LongLength + 1L
                    ChecksumSize = [long]$roundedChecksumBytes.LongLength
                    InstallerSizeExact = $false
                }) -InstallerBytes $payloadBytes `
                    -ChecksumBytes $roundedChecksumBytes
                $true
            }
            catch {
                $false
            }
            $installerSizeExactFalseStillVerifiesHash = try {
                Assert-UpdatePayload -Release ([pscustomobject]@{
                    InstallerName = $parsed.InstallerName
                    InstallerSize = [long]$payloadBytes.LongLength
                    ChecksumSize = [long]$roundedChecksumBytes.LongLength
                    InstallerSizeExact = $false
                }) -InstallerBytes $payloadBytes `
                    -ChecksumBytes (
                        [Text.Encoding]::ASCII.GetBytes(
                            "$sampleHash  $($parsed.InstallerName)"
                        )
                    )
                $false
            }
            catch {
                $true
            }
        }

        # An operation that never completes must be reset by a deadline so the
        # menu can never stay permanently disabled.
        $watchdogResetAfterDeadline = $false
        $watchdogDeadlineAvailable = (
            $script:UpdateContext.PSObject.Properties.Name -contains 'StartedAt'
        )
        if ($watchdogDeadlineAvailable -and
            (Get-Command -Name 'Test-UpdateOperationDeadline' `
                -ErrorAction SilentlyContinue)) {
            Start-UpdateCheck -Client $pendingManualClient
            $script:UpdateContext.StartedAt = (
                [DateTimeOffset]::Now - [TimeSpan]::FromMinutes(30)
            )
            Test-UpdateOperationDeadline
            $watchdogResetAfterDeadline = (
                -not $script:UpdateContext.IsBusy -and
                $script:UpdateContext.Phase -eq 'Idle'
            )
            Reset-UpdateContext
        }

        # Streaming download: the payload lands on disk, progress text is
        # produced, and a stale connection is retried with a fresh one.
        $streamingDownloadVerified = $false
        $streamingDownloadProgressReported = $false
        $streamingDownloadRetriedOnFailure = $false
        if (Get-Command -Name 'Format-UpdateProgressText' `
            -ErrorAction SilentlyContinue) {
            $progressTexts = @(
                Format-UpdateProgressText -Bytes 0 -Total 0
                Format-UpdateProgressText -Bytes 512 -Total 1024
                Format-UpdateProgressText -Bytes 2048 -Total 2048
            )
            $streamingDownloadProgressReported = (
                $progressTexts[0] -ne $progressTexts[2] -and
                $progressTexts[1] -match '\d+%'
            )
        }
        if ((Get-Command -Name 'Start-UpdateDownload' `
                -ErrorAction SilentlyContinue) -and
            ($script:UpdateContext.PSObject.Properties.Name -contains 'Attempt')) {
            $streamPayload = [Text.Encoding]::ASCII.GetBytes(
                ('x' * 524288)
            )
            $streamHash = Get-ByteArraySha256 -Bytes $streamPayload
            $streamChecksumBytes = [Text.Encoding]::ASCII.GetBytes(
                "$streamHash  $($parsed.InstallerName)"
            )
            $streamRelease = [pscustomobject]@{
                Tag = 'v1.8.0'
                Version = '1.8.0'
                InstallerName = $parsed.InstallerName
                InstallerUrl = $parsed.InstallerUrl
                ChecksumUrl = $parsed.ChecksumUrl
                InstallerSize = [long]$streamPayload.LongLength
                ChecksumSize = [long]$streamChecksumBytes.LongLength
                InstallerSizeExact = $true
            }
            $streamStaleFault = New-Object (
                'Threading.Tasks.TaskCompletionSource[' +
                'System.Net.Http.HttpResponseMessage]'
            )
            $streamStaleFault.SetException(
                (
                    New-Object Net.Http.HttpRequestException (
                        'simulated stale connection'
                    )
                )
            )
            $streamChecksum = New-Object (
                'Threading.Tasks.TaskCompletionSource[byte[]]'
            )
            $streamChecksum.SetResult($streamChecksumBytes)
            $streamClient = New-UpdateDiagnosticClient -ResponseTasks @(
                $streamStaleFault.Task
                (New-UpdateDiagnosticResponseTask -Response (
                    New-UpdateDiagnosticPayloadResponse -Bytes $streamPayload
                ))
            ) -ByteTasks @(
                $streamChecksum.Task
                $streamChecksum.Task
            )
            $messagesBeforeStreamRetry = $script:UpdateDiagnosticMessages.Count
            Start-UpdateDownload -Release $streamRelease -Client $streamClient
            $streamDeadline = [DateTimeOffset]::Now.AddSeconds(20)
            $streamSawRetry = $false
            while (
                $script:UpdateContext.IsBusy -and
                [DateTimeOffset]::Now -lt $streamDeadline
            ) {
                if ($script:UpdateContext.Attempt -ge 2) {
                    $streamSawRetry = $true
                }
                Complete-UpdateOperation
                if (-not $script:UpdateContext.IsBusy) { break }
                Start-Sleep -Milliseconds 20
            }
            $streamingDownloadRetriedOnFailure = (
                $streamSawRetry -and
                $script:UpdateDiagnosticInstallerPath -and
                $script:UpdateDiagnosticMessages.Count -eq
                    $messagesBeforeStreamRetry
            )
            $streamingDownloadVerified = (
                $streamingDownloadRetriedOnFailure -and
                (Test-Path `
                    -LiteralPath $script:UpdateDiagnosticInstallerPath `
                    -PathType Leaf) -and
                (Get-Item `
                    -LiteralPath $script:UpdateDiagnosticInstallerPath).Length -eq
                    $streamPayload.LongLength -and
                (Get-ByteArraySha256 -Bytes (
                    [IO.File]::ReadAllBytes(
                        $script:UpdateDiagnosticInstallerPath
                    )
                )) -eq $streamHash
            )
        }
    }
    finally {
        $script:UpdateContext = $originalContext
        $script:TrayUpdateItem = $originalTrayUpdateItem
        $script:AutoUpdateEnabled = $originalAutoUpdateEnabled
        $script:DeferredAutoUpdateRelease = (
            $originalDeferredAutoUpdateRelease
        )
        $script:DeferredAutoUpdateInstaller = (
            $originalDeferredAutoUpdateInstaller
        )
        $script:NextAutoUpdateNetworkRetryAt = (
            $originalNextAutoUpdateNetworkRetryAt
        )
        $script:AutoUpdateDeferredNotifications = (
            $originalAutoUpdateDeferredNotifications
        )
        $script:NextAutomaticUpdateCheckAt = $originalNextCheck
        $script:UpdateDiagnosticMode = $originalDiagnosticMode
        $script:UpdateDiagnosticMessages = $originalDiagnosticMessages
        $script:UpdateDiagnosticUpdatesRoot = $originalDiagnosticUpdatesRoot
        $script:UpdateDiagnosticInstallerPath = (
            $originalDiagnosticInstallerPath
        )
        $script:UpdateDiagnosticInstallerVersion = (
            $originalDiagnosticInstallerVersion
        )
        $script:UpdateDiagnosticFileVersionInfo = (
            $originalDiagnosticFileVersionInfo
        )
        $script:UpdateDiagnosticNetworkState = (
            $originalDiagnosticNetworkState
        )
        $script:UpdateDiagnosticInstalledMode = (
            $originalDiagnosticInstalledMode
        )
        $script:UpdateDiagnosticInstallerArguments = (
            $originalDiagnosticInstallerArguments
        )
        $script:UpdateDiagnosticAutomaticInstall = (
            $originalDiagnosticAutomaticInstall
        )
        $script:UpdateDiagnosticWindowCloseRequested = (
            $originalDiagnosticWindowCloseRequested
        )
        if (Test-Path -LiteralPath $diagnosticUpdatesRoot) {
            Remove-Item `
                -LiteralPath $diagnosticUpdatesRoot `
                -Recurse `
                -Force
        }
    }

    return [pscustomobject]@{
        NewerVersionDetected = (
            Test-RmfUpdateAvailable `
                -CurrentVersion '1.7.0' `
                -LatestVersion 'v1.8.0'
        )
        CurrentVersionNotNewer = -not (
            Test-RmfUpdateAvailable `
                -CurrentVersion '1.8.0' `
                -LatestVersion 'v1.8.0'
        )
        InstallerSelected = (
            $parsed.HasInstaller -and
            $parsed.InstallerName -eq
                'Remaining-Margin-Float-v1.8.0-Setup.exe'
        )
        TrustedAssetUrlAccepted = (
            Test-GitHubUpdateAssetUrl `
                -Url $parsed.InstallerUrl `
                -Tag $parsed.Tag `
                -FileName $parsed.InstallerName
        )
        UntrustedAssetUrlRejected = -not (
            Test-GitHubUpdateAssetUrl `
                -Url 'https://example.com/update.exe' `
                -Tag $parsed.Tag `
                -FileName $parsed.InstallerName
        )
        ChecksumParsed = $checksum -eq $sampleHash
        MultiLineChecksumRejected = $multiLineChecksumRejected
        ByteHashVerified = (
            $payloadHash -eq
            'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
        )
        PayloadVerified = $payloadVerified
        PayloadMismatchRejected = $payloadMismatchRejected
        EmbeddedVersionMismatchRejected = $embeddedVersionMismatchRejected
        UnsignedInstallerNotAutoTrusted = (
            -not (Test-TrustedUpdateInstallerSignature -InstallerPath '')
        )
        ReleaseStateStarted = $releaseStateStarted
        ReleaseStateCompleted = $releaseStateCompleted
        RateLimitFallbackCompleted = $rateLimitFallbackCompleted
        FallbackInstallerSelected = $fallbackInstallerSelected
        UntrustedReleaseRedirectRejected = (
            $untrustedReleaseRedirectRejected
        )
        DownloadStateStarted = $downloadStateStarted
        PartialDownloadFailureReset = $partialDownloadFailureReset
        SuccessfulDownloadCompleted = $successfulDownloadCompleted
        CancelledReleaseReset = $cancelledReleaseReset
        UnrestrictedAutoUpdateAllowed = $unrestrictedAutoUpdateAllowed
        MeteredAutoUpdateDeferred = $meteredAutoUpdateDeferred
        RestrictedAutoUpdateBlocked = $restrictedAutoUpdateBlocked
        SourceModeAutoUpdateRejected = $sourceModeAutoUpdateRejected
        AutoDownloadIntentPreserved = $autoDownloadIntentPreserved
        AutomaticInstallerArgumentsSafe = $automaticInstallerArgumentsSafe
        AutomaticRestartRequested = $automaticRestartRequested
        TransportFailureFallsBack = $transportFailureFallsBack
        TransportFailureEnteredFallback = $transportFailureEnteredFallback
        TransportFailureReachedAssetList = $transportFailureReachedAssetList
        CheckFailureBackoffScheduled = $checkFailureBackoffScheduled
        ManualClickDuringBusyEscalated = $manualClickDuringBusyEscalated
        HtmlAssetListParsed = $htmlAssetListParsed
        HtmlAssetListMissingRejected = $htmlAssetListMissingRejected
        InstallerSizeExactFalseAllowsRoundedSize = (
            $installerSizeExactFalseAllowsRoundedSize
        )
        InstallerSizeExactFalseStillVerifiesHash = (
            $installerSizeExactFalseStillVerifiesHash
        )
        WatchdogResetAfterDeadline = $watchdogResetAfterDeadline
        StreamingDownloadVerified = $streamingDownloadVerified
        StreamingDownloadProgressReported = (
            $streamingDownloadProgressReported
        )
        StreamingDownloadRetriedOnFailure = (
            $streamingDownloadRetriedOnFailure
        )
        Version = $parsed.Version
    }
}

if ($CheckUpdates) {
    Invoke-UpdateDiagnostic | ConvertTo-Json
    $script:RmfStopLoading = $true
    return
}
