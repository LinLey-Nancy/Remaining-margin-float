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

function ConvertTo-RmfVersion {
    param([string]$Value)

    $normalized = ([string]$Value).Trim()
    if ($normalized.StartsWith('v', [StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(1)
    }
    if ($normalized -notmatch '^\d+\.\d+\.\d+$') {
        throw "版本号格式无效：$Value"
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
    $version = (ConvertTo-RmfVersion -Value $tag).ToString()
    if ([bool]$Release.draft -or [bool]$Release.prerelease) {
        throw 'GitHub 返回的最新版本不是稳定正式版。'
    }

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

function Get-GitHubAssetResponseSize {
    param(
        $Response,
        [long]$MaximumSize
    )

    if (-not $Response -or -not $Response.IsSuccessStatusCode) {
        return 0L
    }
    $contentLength = $Response.Content.Headers.ContentLength
    if (
        $null -eq $contentLength -or
        [long]$contentLength -le 0 -or
        [long]$contentLength -gt $MaximumSize
    ) {
        return 0L
    }
    return [long]$contentLength
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

    if (
        $InstallerBytes.LongLength -ne [long]$Release.InstallerSize -or
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
    if (-not $script:UpdateHttpClient) {
        $client = New-Object Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(20)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd(
            "RemainingMarginFloat/$($script:AppVersion)"
        )
        $client.DefaultRequestHeaders.Accept.ParseAdd(
            'application/vnd.github+json'
        )
        $script:UpdateHttpClient = $client
    }
    return $script:UpdateHttpClient
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
        $profile = $networkInformation::GetInternetConnectionProfile()
        if (-not $profile) {
            return Get-AutoUpdateNetworkAssessment `
                -ConnectivityLevel None `
                -CostType Unknown `
                -Roaming $false `
                -OverDataLimit $false `
                -ApproachingDataLimit $false `
                -BackgroundDataUsageRestricted $false
        }

        $connectivityLevel = [string]$profile.GetNetworkConnectivityLevel()
        $cost = $profile.GetConnectionCost()
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

function Sync-UpdateMenuState {
    $enabled = -not $script:UpdateContext.IsBusy
    $text = switch ($script:UpdateContext.Phase) {
        'Release' { '正在检查更新…' }
        'ReleaseFallback' { '正在检查更新…' }
        'ReleaseAssets' { '正在检查更新…' }
        'Download' { '正在下载安装程序…' }
        default { '检查更新…' }
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

function Reset-UpdateContext {
    $script:UpdateContext.IsBusy = $false
    $script:UpdateContext.Manual = $false
    $script:UpdateContext.AutomaticInstall = $false
    $script:UpdateContext.Phase = 'Idle'
    $script:UpdateContext.Client = $null
    $script:UpdateContext.ReleaseTask = $null
    $script:UpdateContext.InstallerTask = $null
    $script:UpdateContext.ChecksumTask = $null
    $script:UpdateContext.Release = $null
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

function Stop-UpdateOperation {
    param(
        [string]$Message,
        [switch]$AlwaysShow
    )

    $shouldShow = $AlwaysShow -or $script:UpdateContext.Manual
    Reset-UpdateContext
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
            Show-UpdateMessage -Message '更新检查或下载正在进行，请稍候。'
        }
        return
    }

    try {
        if (-not $Client) {
            $Client = Get-UpdateHttpClient
        }
        $script:UpdateContext.IsBusy = $true
        $script:UpdateContext.Manual = [bool]$Manual
        $script:UpdateContext.Phase = 'Release'
        $script:UpdateContext.Client = $Client
        $script:UpdateContext.ReleaseTask = $Client.GetAsync(
            $script:UpdateApiUri,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead
        )
        $script:NextAutomaticUpdateCheckAt = (
            [DateTimeOffset]::Now + $script:UpdateCheckInterval
        )
        Sync-UpdateMenuState
    }
    catch {
        Stop-UpdateOperation -Message (
            "无法开始检查更新。`n`n$($_.Exception.Message)"
        )
    }
}

function Start-GitHubReleaseFallback {
    param($Client)

    if (-not $Client) {
        throw '无法启动 GitHub Release 回退检查。'
    }
    $script:UpdateContext.Phase = 'ReleaseFallback'
    $script:UpdateContext.ReleaseTask = $Client.GetAsync(
        $script:UpdateLatestReleaseUri,
        [Net.Http.HttpCompletionOption]::ResponseHeadersRead
    )
    Sync-UpdateMenuState
}

function Start-GitHubAssetMetadataFallback {
    param(
        $Client,
        [string]$Tag
    )

    $release = New-GitHubRedirectRelease `
        -Tag $Tag `
        -InstallerSize 0 `
        -ChecksumSize 0
    $script:UpdateContext.Phase = 'ReleaseAssets'
    $script:UpdateContext.Release = $release
    $script:UpdateContext.InstallerTask = $Client.GetAsync(
        $release.InstallerUrl,
        [Net.Http.HttpCompletionOption]::ResponseHeadersRead
    )
    $script:UpdateContext.ChecksumTask = $Client.GetAsync(
        $release.ChecksumUrl,
        [Net.Http.HttpCompletionOption]::ResponseHeadersRead
    )
    Sync-UpdateMenuState
}

function Complete-ResolvedUpdateRelease {
    param($Release)

    $manual = $script:UpdateContext.Manual
    Reset-UpdateContext
    if (Test-RmfUpdateAvailable `
        -CurrentVersion $script:AppVersion `
        -LatestVersion $Release.Version) {
        Show-UpdateAvailable -Release $Release -Manual:$manual
    }
    elseif ($manual) {
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
        $script:UpdateContext.IsBusy = $true
        $script:UpdateContext.Manual = -not [bool]$AutomaticInstall
        $script:UpdateContext.AutomaticInstall = [bool]$AutomaticInstall
        $script:UpdateContext.Phase = 'Download'
        $script:UpdateContext.Release = $Release
        $script:UpdateContext.InstallerTask = $Client.GetByteArrayAsync(
            $Release.InstallerUrl
        )
        $script:UpdateContext.ChecksumTask = $Client.GetByteArrayAsync(
            $Release.ChecksumUrl
        )
        Sync-UpdateMenuState
    }
    catch {
        if ($AutomaticInstall) {
            Reset-UpdateContext
            $script:NextAutomaticUpdateCheckAt = (
                [DateTimeOffset]::Now + [TimeSpan]::FromMinutes(10)
            )
            Show-AutoUpdateNotification `
                -Title '自动更新暂未完成' `
                -Message '无法开始下载安装程序，稍后会再次检查。' `
                -Icon Warning
        }
        else {
            Stop-UpdateOperation `
                -AlwaysShow `
                -Message ("无法开始下载安装程序。`n`n$($_.Exception.Message)")
        }
    }
}

function Save-VerifiedUpdateInstaller {
    param(
        $Release,
        [byte[]]$InstallerBytes,
        [byte[]]$ChecksumBytes
    )

    Assert-UpdatePayload `
        -Release $Release `
        -InstallerBytes $InstallerBytes `
        -ChecksumBytes $ChecksumBytes

    $updatesRoot = if (
        $script:UpdateDiagnosticMode -and
        -not [string]::IsNullOrWhiteSpace(
            $script:UpdateDiagnosticUpdatesRoot
        )
    ) {
        $script:UpdateDiagnosticUpdatesRoot
    }
    else {
        Join-Path (Get-AppDataDirectory) 'updates'
    }
    $versionDirectory = Join-Path $updatesRoot $Release.Tag
    New-Item -Path $versionDirectory -ItemType Directory -Force | Out-Null
    $installerPath = Join-Path $versionDirectory $Release.InstallerName
    $temporaryPath = "$installerPath.download"
    try {
        [IO.File]::WriteAllBytes($temporaryPath, $InstallerBytes)
        Assert-UpdateInstallerMetadata `
            -InstallerPath $temporaryPath `
            -Release $Release
        if (Test-Path -LiteralPath $installerPath) {
            Remove-Item -LiteralPath $installerPath -Force
        }
        Move-Item -LiteralPath $temporaryPath -Destination $installerPath
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
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

function Complete-UpdateOperation {
    if (-not $script:UpdateContext.IsBusy) { return }

    if ($script:UpdateContext.Phase -eq 'Release') {
        $task = $script:UpdateContext.ReleaseTask
        if (-not $task -or -not $task.IsCompleted) { return }
        $response = $null
        try {
            $response = $task.GetAwaiter().GetResult()
            if ([int]$response.StatusCode -in @(403, 429)) {
                $client = $script:UpdateContext.Client
                $response.Dispose()
                $response = $null
                Start-GitHubReleaseFallback -Client $client
                return
            }
            [void]$response.EnsureSuccessStatusCode()
            $releaseJson = (
                $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            )
            $release = ConvertFrom-GitHubRelease -Release (
                $releaseJson | ConvertFrom-Json
            )
            Complete-ResolvedUpdateRelease -Release $release
        }
        catch {
            Stop-UpdateOperation -Message (
                "检查更新失败。`n`n$($_.Exception.Message)"
            )
        }
        finally {
            if ($response) {
                $response.Dispose()
            }
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
            Stop-UpdateOperation -Message (
                'GitHub API 请求受限，且公共 Release 回退检查失败。' +
                "`n`n$($_.Exception.Message)"
            )
        }
        finally {
            if ($response) {
                $response.Dispose()
            }
        }
        return
    }

    if ($script:UpdateContext.Phase -eq 'ReleaseAssets') {
        $installerTask = $script:UpdateContext.InstallerTask
        $checksumTask = $script:UpdateContext.ChecksumTask
        if (
            -not $installerTask -or
            -not $checksumTask -or
            -not $installerTask.IsCompleted -or
            -not $checksumTask.IsCompleted
        ) {
            return
        }
        $installerResponse = $null
        $checksumResponse = $null
        try {
            $installerResponse = $installerTask.GetAwaiter().GetResult()
            $checksumResponse = $checksumTask.GetAwaiter().GetResult()
            $installerSize = Get-GitHubAssetResponseSize `
                -Response $installerResponse `
                -MaximumSize 50MB
            $checksumSize = Get-GitHubAssetResponseSize `
                -Response $checksumResponse `
                -MaximumSize 4KB
            $release = New-GitHubRedirectRelease `
                -Tag $script:UpdateContext.Release.Tag `
                -InstallerSize $installerSize `
                -ChecksumSize $checksumSize
            Complete-ResolvedUpdateRelease -Release $release
        }
        catch {
            Stop-UpdateOperation -Message (
                'GitHub API 请求受限，且 Release 资产检查失败。' +
                "`n`n$($_.Exception.Message)"
            )
        }
        finally {
            if ($installerResponse) {
                $installerResponse.Dispose()
            }
            if ($checksumResponse) {
                $checksumResponse.Dispose()
            }
        }
        return
    }

    if ($script:UpdateContext.Phase -eq 'Download') {
        $installerTask = $script:UpdateContext.InstallerTask
        $checksumTask = $script:UpdateContext.ChecksumTask
        $automaticInstall = [bool](
            $script:UpdateContext.AutomaticInstall
        )
        if (
            -not $installerTask -or
            -not $checksumTask -or
            -not $installerTask.IsCompleted -or
            -not $checksumTask.IsCompleted
        ) {
            return
        }
        try {
            $release = $script:UpdateContext.Release
            $installerPath = Save-VerifiedUpdateInstaller `
                -Release $release `
                -InstallerBytes $installerTask.GetAwaiter().GetResult() `
                -ChecksumBytes $checksumTask.GetAwaiter().GetResult()
            Reset-UpdateContext
            Start-VerifiedUpdateInstaller `
                -InstallerPath $installerPath `
                -Version $release.Version `
                -AutomaticInstall:$automaticInstall
        }
        catch {
            if ($automaticInstall) {
                Reset-UpdateContext
                $script:NextAutomaticUpdateCheckAt = (
                    [DateTimeOffset]::Now + [TimeSpan]::FromMinutes(10)
                )
                Show-AutoUpdateNotification `
                    -Title '自动更新暂未完成' `
                    -Message '下载或校验失败，稍后会再次检查。' `
                    -Icon Warning
            }
            else {
                Stop-UpdateOperation `
                    -AlwaysShow `
                    -Message ("下载更新失败。`n`n$($_.Exception.Message)")
            }
        }
    }
}

function Invoke-UpdateTimerTick {
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
    $payloadRelease = [pscustomobject]@{
        InstallerName = $parsed.InstallerName
        InstallerSize = [long]$payloadBytes.LongLength
        ChecksumSize = [long]$payloadChecksumBytes.LongLength
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
            $script:TrayUpdateItem.Text -eq '正在检查更新…'
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
        $fallbackInstallerResponse =
            New-Object Net.Http.HttpResponseMessage(
                [Net.HttpStatusCode]::OK
        )
        $fallbackInstallerResponse.Content =
            New-Object Net.Http.ByteArrayContent -ArgumentList (,$payloadBytes)
        $fallbackChecksumResponse =
            New-Object Net.Http.HttpResponseMessage(
                [Net.HttpStatusCode]::OK
        )
        $fallbackChecksumResponse.Content =
            New-Object Net.Http.ByteArrayContent `
                -ArgumentList (,$payloadChecksumBytes)
        $diagnosticFallbackRelease = New-GitHubRedirectRelease `
            -Tag 'v1.8.0' `
            -InstallerSize $payloadBytes.LongLength `
            -ChecksumSize $payloadChecksumBytes.LongLength
        $fallbackInstallerSelected = (
            $diagnosticFallbackRelease.HasInstaller -and
            $diagnosticFallbackRelease.InstallerName -eq
                'Remaining-Margin-Float-v1.8.0-Setup.exe'
        )
        $fallbackTasks = @()
        foreach ($fallbackResponse in @(
            $rateLimitResponse
            $redirectResponse
            $fallbackInstallerResponse
            $fallbackChecksumResponse
        )) {
            $completion = New-Object (
                'Threading.Tasks.TaskCompletionSource[' +
                'System.Net.Http.HttpResponseMessage]'
            )
            $completion.SetResult($fallbackResponse)
            $fallbackTasks += $completion.Task
        }
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

        $installerCompletion = New-Object (
            'Threading.Tasks.TaskCompletionSource[byte[]]'
        )
        $installerCompletion.SetResult($payloadBytes)
        $checksumFailure = New-Object (
            'Threading.Tasks.TaskCompletionSource[byte[]]'
        )
        $checksumFailure.SetException(
            (New-Object InvalidOperationException 'checksum download failed')
        )
        $downloadClient = New-UpdateDiagnosticClient -ByteTasks @(
            $installerCompletion.Task
            $checksumFailure.Task
        )
        Start-UpdateDownload -Release $parsed -Client $downloadClient
        $downloadStateStarted = (
            $script:UpdateContext.IsBusy -and
            $script:UpdateContext.Phase -eq 'Download' -and
            -not $script:TrayUpdateItem.Enabled -and
            $script:TrayUpdateItem.Text -eq '正在下载安装程序…'
        )
        Complete-UpdateOperation
        $partialDownloadFailureReset = (
            -not $script:UpdateContext.IsBusy -and
            $script:UpdateContext.Phase -eq 'Idle' -and
            $script:UpdateDiagnosticMessages.Count -eq 1
        )

        $successfulRelease = [pscustomobject]@{
            Tag = 'v1.8.0'
            Version = '1.8.0'
            InstallerName = $parsed.InstallerName
            InstallerUrl = $parsed.InstallerUrl
            ChecksumUrl = $parsed.ChecksumUrl
            InstallerSize = [long]$payloadBytes.LongLength
            ChecksumSize = [long]$payloadChecksumBytes.LongLength
        }
        $successfulInstaller = New-Object (
            'Threading.Tasks.TaskCompletionSource[byte[]]'
        )
        $successfulInstaller.SetResult($payloadBytes)
        $successfulChecksum = New-Object (
            'Threading.Tasks.TaskCompletionSource[byte[]]'
        )
        $successfulChecksum.SetResult($payloadChecksumBytes)
        $successfulClient = New-UpdateDiagnosticClient -ByteTasks @(
            $successfulInstaller.Task
            $successfulChecksum.Task
        )
        Start-UpdateDownload `
            -Release $successfulRelease `
            -Client $successfulClient
        Complete-UpdateOperation
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
        $cancelledClient = New-UpdateDiagnosticClient `
            -ResponseTasks @($cancelledRelease.Task)
        Start-UpdateCheck -Client $cancelledClient
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
            $script:UpdateContext.Phase -eq 'Download' -and
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
        Version = $parsed.Version
    }
}

if ($CheckUpdates) {
    Invoke-UpdateDiagnostic | ConvertTo-Json
    $script:RmfStopLoading = $true
    return
}
