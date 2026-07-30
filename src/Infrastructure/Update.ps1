$script:UpdateRepository = 'LinLey-Nancy/Remaining-margin-float'
$script:UpdateApiUri = (
    'https://api.github.com/repos/{0}/releases/latest' -f
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

function Sync-UpdateMenuState {
    if (-not $script:TrayUpdateItem) { return }
    $script:TrayUpdateItem.Enabled = -not $script:UpdateContext.IsBusy
    $script:TrayUpdateItem.Text = switch ($script:UpdateContext.Phase) {
        'Release' { '正在检查更新…' }
        'Download' { '正在下载安装程序…' }
        default { '检查更新…' }
    }
}

function Reset-UpdateContext {
    $script:UpdateContext.IsBusy = $false
    $script:UpdateContext.Manual = $false
    $script:UpdateContext.Phase = 'Idle'
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
        $script:UpdateContext.ReleaseTask = $Client.GetStringAsync(
            $script:UpdateApiUri
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
        $Client = $null
    )

    try {
        if (-not $Client) {
            $Client = Get-UpdateHttpClient
        }
        $script:UpdateContext.IsBusy = $true
        $script:UpdateContext.Manual = $true
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
        Stop-UpdateOperation `
            -AlwaysShow `
            -Message ("无法开始下载安装程序。`n`n$($_.Exception.Message)")
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
        [string]$Version
    )

    if ($script:UpdateDiagnosticMode) {
        $script:UpdateDiagnosticInstallerPath = $InstallerPath
        $script:UpdateDiagnosticInstallerVersion = $Version
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

function Show-UpdateAvailable {
    param(
        $Release,
        [switch]$Manual
    )

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
        try {
            $releaseJson = $task.GetAwaiter().GetResult()
            $release = ConvertFrom-GitHubRelease -Release (
                $releaseJson | ConvertFrom-Json
            )
            $manual = $script:UpdateContext.Manual
            Reset-UpdateContext
            if (Test-RmfUpdateAvailable `
                -CurrentVersion $script:AppVersion `
                -LatestVersion $release.Version) {
                Show-UpdateAvailable -Release $release -Manual:$manual
            }
            elseif ($manual) {
                Show-UpdateMessage -Message (
                    "当前已是最新版本 v$($script:AppVersion)。"
                )
            }
        }
        catch {
            Stop-UpdateOperation -Message (
                "检查更新失败。`n`n$($_.Exception.Message)"
            )
        }
        return
    }

    if ($script:UpdateContext.Phase -eq 'Download') {
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
        try {
            $release = $script:UpdateContext.Release
            $installerPath = Save-VerifiedUpdateInstaller `
                -Release $release `
                -InstallerBytes $installerTask.GetAwaiter().GetResult() `
                -ChecksumBytes $checksumTask.GetAwaiter().GetResult()
            Reset-UpdateContext
            Start-VerifiedUpdateInstaller `
                -InstallerPath $installerPath `
                -Version $release.Version
        }
        catch {
            Stop-UpdateOperation `
                -AlwaysShow `
                -Message ("下载更新失败。`n`n$($_.Exception.Message)")
        }
    }
}

function Invoke-UpdateTimerTick {
    Complete-UpdateOperation
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
        $StringTask = $null,
        [object[]]$ByteTasks = @()
    )

    $client = [pscustomobject]@{
        StringTask = $StringTask
        ByteTasks = @($ByteTasks)
        ByteTaskIndex = 0
    }
    $client | Add-Member -MemberType ScriptMethod -Name GetStringAsync -Value {
        param([string]$Url)
        return $this.StringTask
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
    $downloadStateStarted = $false
    $partialDownloadFailureReset = $false
    $successfulDownloadCompleted = $false
    $cancelledReleaseReset = $false
    $originalContext = $script:UpdateContext
    $originalTrayUpdateItem = $script:TrayUpdateItem
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
    $diagnosticUpdatesRoot = Join-Path (
        [IO.Path]::GetTempPath()
    ) ('rmf-update-diagnostic-' + [Guid]::NewGuid().ToString('N'))
    try {
        $script:UpdateDiagnosticMode = $true
        $script:UpdateDiagnosticMessages = @()
        $script:UpdateDiagnosticUpdatesRoot = $diagnosticUpdatesRoot
        $script:UpdateDiagnosticInstallerPath = $null
        $script:UpdateDiagnosticInstallerVersion = $null
        $script:UpdateDiagnosticFileVersionInfo = [pscustomobject]@{
            FileVersion = '1.8.0.0'
            ProductVersion = '1.8.0'
        }
        $script:TrayUpdateItem = [pscustomobject]@{
            Enabled = $true
            Text = '检查更新…'
        }

        $releaseCompletion = New-Object (
            'Threading.Tasks.TaskCompletionSource[string]'
        )
        $releaseCompletion.SetResult(($release | ConvertTo-Json -Depth 6))
        $releaseClient = New-UpdateDiagnosticClient `
            -StringTask $releaseCompletion.Task
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
            'Threading.Tasks.TaskCompletionSource[string]'
        )
        $cancelledRelease.SetCanceled()
        $cancelledClient = New-UpdateDiagnosticClient `
            -StringTask $cancelledRelease.Task
        Start-UpdateCheck -Client $cancelledClient
        Complete-UpdateOperation
        $cancelledReleaseReset = (
            -not $script:UpdateContext.IsBusy -and
            $script:UpdateContext.Phase -eq 'Idle'
        )
    }
    finally {
        $script:UpdateContext = $originalContext
        $script:TrayUpdateItem = $originalTrayUpdateItem
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
        DownloadStateStarted = $downloadStateStarted
        PartialDownloadFailureReset = $partialDownloadFailureReset
        SuccessfulDownloadCompleted = $successfulDownloadCompleted
        CancelledReleaseReset = $cancelledReleaseReset
        Version = $parsed.Version
    }
}

if ($CheckUpdates) {
    Invoke-UpdateDiagnostic | ConvertTo-Json
    $script:RmfStopLoading = $true
    return
}
