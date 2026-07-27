param(
    [switch]$CheckData,
    [switch]$CheckDeepSeekData,
    [switch]$CheckDeepSeekUsage,
    [switch]$CheckCodexRateLimitSelection,
    [switch]$CheckPlacement,
    [switch]$CheckTransitions,
    [switch]$CaptureVisuals,
    [string]$CaptureDirectory = '',
    [switch]$Demo,
    [ValidateSet('codex', 'deepseek')]
    [string]$DemoProvider = 'codex'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$isDiagnosticRun = (
    $CheckData -or
    $CheckDeepSeekData -or
    $CheckDeepSeekUsage -or
    $CheckCodexRateLimitSelection -or
    $CheckPlacement -or
    $CheckTransitions -or
    $CaptureVisuals -or
    $Demo
)
$script:ActivationEvent = $null
$script:AppMutex = $null
if (-not $isDiagnosticRun) {
    $script:ActivationEvent = New-Object System.Threading.EventWaitHandle(
        $false,
        [System.Threading.EventResetMode]::AutoReset,
        'Local\RemainingMarginFloat.Activate'
    )
    $createdNew = $false
    $script:AppMutex = New-Object System.Threading.Mutex(
        $true,
        'Local\RemainingMarginFloat.Singleton',
        [ref]$createdNew
    )
    if (-not $createdNew) {
        [void]$script:ActivationEvent.Set()
        $script:ActivationEvent.Dispose()
        $script:AppMutex.Dispose()
        exit 0
    }
}

Add-Type -AssemblyName System.Security
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text.RegularExpressions;

public sealed class DeepSeekUsageEventData
{
    public string MessageId { get; set; }
    public DateTimeOffset Timestamp { get; set; }
    public string Model { get; set; }
    public double InputTokens { get; set; }
    public double OutputTokens { get; set; }
    public double CachedTokens { get; set; }
    public double CacheWriteTokens { get; set; }
    public double TotalTokens
    {
        get { return InputTokens + OutputTokens + CachedTokens + CacheWriteTokens; }
    }
}

public static class DeepSeekLogScanner
{
    private static readonly Regex Model = Create("\"model\"\\s*:\\s*\"(?<value>[^\"]+)\"");
    private static readonly Regex MessageId = Create("\"message\"\\s*:\\s*\\{\\s*\"id\"\\s*:\\s*\"(?<value>[^\"]*)\"");
    private static readonly Regex Uuid = Create("\"uuid\"\\s*:\\s*\"(?<value>[^\"]+)\"");
    private static readonly Regex Timestamp = Create("\"timestamp\"\\s*:\\s*\"(?<value>[^\"]+)\"");
    private static readonly Regex Input = Create("\"input_tokens\"\\s*:\\s*(?<value>\\d+(?:\\.\\d+)?)");
    private static readonly Regex Output = Create("\"output_tokens\"\\s*:\\s*(?<value>\\d+(?:\\.\\d+)?)");
    private static readonly Regex CacheRead = Create("\"cache_read_input_tokens\"\\s*:\\s*(?<value>\\d+(?:\\.\\d+)?)");
    private static readonly Regex CacheWrite = Create("\"cache_creation_input_tokens\"\\s*:\\s*(?<value>\\d+(?:\\.\\d+)?)");

    private static Regex Create(string pattern)
    {
        return new Regex(pattern, RegexOptions.Compiled | RegexOptions.CultureInvariant);
    }

    private static string Capture(Regex regex, string line)
    {
        Match match = regex.Match(line);
        return match.Success ? match.Groups["value"].Value : String.Empty;
    }

    private static double CaptureNumber(Regex regex, string line)
    {
        double value;
        return Double.TryParse(
            Capture(regex, line),
            NumberStyles.Float,
            CultureInfo.InvariantCulture,
            out value
        ) ? value : 0.0;
    }

    public static DeepSeekUsageEventData ParseLine(string line)
    {
        if (
            String.IsNullOrEmpty(line) ||
            line.IndexOf("\"usage\"", StringComparison.OrdinalIgnoreCase) < 0 ||
            line.IndexOf("deepseek", StringComparison.OrdinalIgnoreCase) < 0
        ) {
            return null;
        }

        string model = Capture(Model, line);
        if (model.IndexOf("deepseek", StringComparison.OrdinalIgnoreCase) < 0) {
            return null;
        }
        string timestampText = Capture(Timestamp, line);
        DateTimeOffset timestamp;
        if (!DateTimeOffset.TryParse(
            timestampText,
            CultureInfo.InvariantCulture,
            DateTimeStyles.RoundtripKind,
            out timestamp
        )) {
            return null;
        }

        string messageId = Capture(MessageId, line);
        if (String.IsNullOrWhiteSpace(messageId)) {
            messageId = Capture(Uuid, line);
        }
        return new DeepSeekUsageEventData {
            MessageId = messageId,
            Timestamp = timestamp,
            Model = model,
            InputTokens = CaptureNumber(Input, line),
            OutputTokens = CaptureNumber(Output, line),
            CachedTokens = CaptureNumber(CacheRead, line),
            CacheWriteTokens = CaptureNumber(CacheWrite, line)
        };
    }

    public static DeepSeekUsageEventData[] ReadFile(string path)
    {
        Dictionary<string, DeepSeekUsageEventData> events =
            new Dictionary<string, DeepSeekUsageEventData>(StringComparer.Ordinal);
        int anonymousIndex = 0;
        using (FileStream stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete
        ))
        using (StreamReader reader = new StreamReader(stream))
        {
            string line;
            while ((line = reader.ReadLine()) != null)
            {
                DeepSeekUsageEventData item = ParseLine(line);
                if (item == null) {
                    continue;
                }
                string eventKey = String.IsNullOrWhiteSpace(item.MessageId)
                    ? "__anonymous_" + (++anonymousIndex).ToString(CultureInfo.InvariantCulture)
                    : item.MessageId;

                DeepSeekUsageEventData existing;
                if (!events.TryGetValue(eventKey, out existing) || item.Timestamp > existing.Timestamp) {
                    events[eventKey] = item;
                }
            }
        }

        DeepSeekUsageEventData[] result = new DeepSeekUsageEventData[events.Count];
        events.Values.CopyTo(result, 0);
        return result;
    }
}
'@

$script:CompactWidth = 96.0
$script:CompactHeight = 88.0
$script:ExpandedWidth = 370.0
$script:ExpandedHeight = 500.0
$script:RefreshIntervalSeconds = 60
$script:SessionCache = @{}
$script:LastSnapshot = $null
$script:CompactAnchorLeft = $null
$script:CompactAnchorTop = $null
$script:TrayNotifyIcon = $null
$script:TrayAppIcon = $null
$script:TrayMenu = $null
$script:TrayTopmostItem = $null
$script:IsClosing = $false
$script:ActiveProvider = 'Codex'
$script:DeepSeekUsageCache = @{}
$script:DeepSeekLatestUsageCache = @{}
$script:DeepSeekHttpClient = $null
$script:DeepSeekRequest = $null
$script:DeepSeekRequestTask = $null
$script:LastDeepSeekSnapshot = $null
$script:CodexSourceMenuItem = $null
$script:DeepSeekSourceMenuItem = $null
$script:TrayCodexSourceItem = $null
$script:TrayDeepSeekSourceItem = $null
$script:DeepSeekSettingsMenuItem = $null
$script:TrayDeepSeekSettingsItem = $null
$script:IsPointerOverSurface = $false
$script:CurrentHoverBorderColor = '#C4D0C6'
$script:CurrentSurfaceBorderColor = '#E1E3DE'

function Get-FittedPlacement {
    param(
        [double]$AnchorLeft,
        [double]$AnchorTop,
        [double]$TargetWidth,
        [double]$TargetHeight,
        [double]$WorkLeft,
        [double]$WorkTop,
        [double]$WorkRight,
        [double]$WorkBottom
    )

    $targetLeft = [Math]::Min($AnchorLeft, $WorkRight - $TargetWidth)
    $targetTop = [Math]::Min($AnchorTop, $WorkBottom - $TargetHeight)
    return [pscustomobject]@{
        Left = [Math]::Max($WorkLeft, $targetLeft)
        Top = [Math]::Max($WorkTop, $targetTop)
    }
}

function ConvertFrom-JwtPayload {
    param([string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }
    try {
        $parts = $Token.Split('.')
        if ($parts.Count -lt 2) { return $null }
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        while (($payload.Length % 4) -ne 0) { $payload += '=' }
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        return $json | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-SafeAccountInfo {
    $result = [ordered]@{
        DisplayName = '本地 Codex'
        Email = '未找到账号信息'
    }

    $authPath = Join-Path $env:USERPROFILE '.codex\auth.json'
    if (-not (Test-Path -LiteralPath $authPath)) { return [pscustomobject]$result }

    try {
        $auth = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json
        $claims = ConvertFrom-JwtPayload -Token $auth.tokens.id_token
        if ($claims) {
            $emailProperty = $claims.PSObject.Properties['email']
            $nameProperty = $claims.PSObject.Properties['name']
            if ($emailProperty -and $emailProperty.Value) {
                $result.Email = [string]$emailProperty.Value
            }
            if ($nameProperty -and $nameProperty.Value) {
                $result.DisplayName = [string]$nameProperty.Value
            }
        }
    }
    catch {
        $result.Email = '账号信息暂不可用'
    }

    return [pscustomobject]$result
}

function Get-CodexRateLimitWindow {
    param($Payload)

    if (-not $Payload) { return $null }
    $rateLimitsProperty = $Payload.PSObject.Properties['rate_limits']
    if (-not $rateLimitsProperty -or -not $rateLimitsProperty.Value) { return $null }

    foreach ($name in @('primary', 'secondary')) {
        $windowProperty = $rateLimitsProperty.Value.PSObject.Properties[$name]
        if (-not $windowProperty -or -not $windowProperty.Value) { continue }

        $usedProperty = $windowProperty.Value.PSObject.Properties['used_percent']
        $minutesProperty = $windowProperty.Value.PSObject.Properties['window_minutes']
        $resetProperty = $windowProperty.Value.PSObject.Properties['resets_at']
        if (
            -not $usedProperty -or $null -eq $usedProperty.Value -or
            -not $minutesProperty -or [double]$minutesProperty.Value -le 0 -or
            -not $resetProperty -or [long]$resetProperty.Value -le 0
        ) {
            continue
        }
        return $windowProperty.Value
    }
    return $null
}

function Get-CodexEventObservedAt {
    param(
        $Event,
        [datetime]$Fallback
    )

    $observedAt = [DateTimeOffset]$Fallback
    $timestampProperty = $Event.PSObject.Properties['timestamp']
    if ($timestampProperty -and $timestampProperty.Value) {
        $parsed = [DateTimeOffset]::MinValue
        if (
            [DateTimeOffset]::TryParse(
                [string]$timestampProperty.Value,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$parsed
            )
        ) {
            $observedAt = $parsed
        }
    }
    return $observedAt
}

function Select-CodexRateLimitSnapshot {
    param([object[]]$Snapshots)

    return $Snapshots | Where-Object {
        $_ -and $_.RateLimitPayload -and (Get-CodexRateLimitWindow -Payload $_.RateLimitPayload)
    } | Sort-Object RateLimitObservedAt -Descending | Select-Object -First 1
}

function Read-SessionSnapshot {
    param([System.IO.FileInfo]$File)

    $cacheKey = '{0}:{1}' -f $File.LastWriteTimeUtc.Ticks, $File.Length
    if ($script:SessionCache.ContainsKey($File.FullName)) {
        $cached = $script:SessionCache[$File.FullName]
        if ($cached.Key -eq $cacheKey) { return $cached.Value }
    }

    $lastPayload = $null
    $lastObservedAt = [DateTimeOffset]$File.LastWriteTime
    $lastRateLimitPayload = $null
    $lastRateLimitObservedAt = [DateTimeOffset]::MinValue
    try {
        $stream = [System.IO.File]::Open(
            $File.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        try {
            # Token counters are append-only and normally appear near the end.
            # Reading a bounded tail keeps the one-minute refresh responsive
            # even when an active session log grows to tens of megabytes.
            $tailLimit = 512KB
            $startOffset = [Math]::Max(0L, $stream.Length - $tailLimit)
            [void]$stream.Seek($startOffset, [System.IO.SeekOrigin]::Begin)
            $byteCount = [int]($stream.Length - $startOffset)
            $buffer = New-Object byte[] $byteCount
            $totalRead = 0
            while ($totalRead -lt $byteCount) {
                $read = $stream.Read($buffer, $totalRead, $byteCount - $totalRead)
                if ($read -le 0) { break }
                $totalRead += $read
            }

            $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $totalRead)
            if ($startOffset -gt 0) {
                $firstLineBreak = $text.IndexOf("`n", [StringComparison]::Ordinal)
                if ($firstLineBreak -ge 0) {
                    $text = $text.Substring($firstLineBreak + 1)
                }
                else {
                    $text = ''
                }
            }

            foreach ($line in ($text -split "`r?`n")) {
                if ($line.IndexOf('"type":"token_count"', [StringComparison]::Ordinal) -lt 0) {
                    continue
                }
                try {
                    $event = $line | ConvertFrom-Json
                    if ($event.type -eq 'event_msg' -and $event.payload.type -eq 'token_count') {
                        $lastPayload = $event.payload
                        $lastObservedAt = Get-CodexEventObservedAt -Event $event -Fallback $File.LastWriteTime
                        if (Get-CodexRateLimitWindow -Payload $event.payload) {
                            $lastRateLimitPayload = $event.payload
                            $lastRateLimitObservedAt = $lastObservedAt
                        }
                    }
                }
                catch {
                    continue
                }
            }

            if (
                ($null -eq $lastPayload -or $null -eq $lastRateLimitPayload) -and
                $startOffset -gt 0
            ) {
                [void]$stream.Seek(0, [System.IO.SeekOrigin]::Begin)
                $reader = New-Object System.IO.StreamReader($stream)
                try {
                    while (($line = $reader.ReadLine()) -ne $null) {
                        if ($line.IndexOf('"type":"token_count"', [StringComparison]::Ordinal) -lt 0) {
                            continue
                        }
                        try {
                            $event = $line | ConvertFrom-Json
                            if ($event.type -eq 'event_msg' -and $event.payload.type -eq 'token_count') {
                                $lastPayload = $event.payload
                                $lastObservedAt = Get-CodexEventObservedAt -Event $event -Fallback $File.LastWriteTime
                                if (Get-CodexRateLimitWindow -Payload $event.payload) {
                                    $lastRateLimitPayload = $event.payload
                                    $lastRateLimitObservedAt = $lastObservedAt
                                }
                            }
                        }
                        catch {
                            continue
                        }
                    }
                }
                finally {
                    $reader.Dispose()
                }
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        $lastPayload = $null
        $lastRateLimitPayload = $null
    }

    $value = [pscustomobject]@{
        File = $File
        Payload = $lastPayload
        ObservedAt = $lastObservedAt
        RateLimitPayload = $lastRateLimitPayload
        RateLimitObservedAt = $lastRateLimitObservedAt
    }
    $script:SessionCache[$File.FullName] = [pscustomobject]@{ Key = $cacheKey; Value = $value }
    return $value
}

function Get-PlanLabel {
    param([string]$PlanType)

    if ([string]::IsNullOrWhiteSpace($PlanType)) { return 'Codex' }
    $labels = @{
        'free' = 'Free'
        'plus' = 'Plus'
        'pro' = 'Pro'
        'prolite' = 'Pro Lite'
        'team' = 'Team'
        'business' = 'Business'
        'enterprise' = 'Enterprise'
    }
    $key = $PlanType.ToLowerInvariant()
    if ($labels.ContainsKey($key)) { return $labels[$key] }
    return (Get-Culture).TextInfo.ToTitleCase($PlanType.Replace('_', ' '))
}

function Format-CompactNumber {
    param([double]$Value)

    if ($Value -ge 1000000) { return ('{0:0.0}M' -f ($Value / 1000000)) }
    if ($Value -ge 1000) { return ('{0:0.0}K' -f ($Value / 1000)) }
    return ('{0:N0}' -f $Value)
}

function Get-AppDataDirectory {
    $directory = Join-Path $env:LOCALAPPDATA 'RemainingMarginFloat'
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    # Preserve existing settings and DPAPI-encrypted credentials when upgrading
    # from the previous application name. The legacy directory remains intact.
    $legacyDirectory = Join-Path $env:LOCALAPPDATA 'CodexMarginFloat'
    if (Test-Path -LiteralPath $legacyDirectory) {
        foreach ($fileName in @('deepseek.json', 'settings.json')) {
            $legacyPath = Join-Path $legacyDirectory $fileName
            $newPath = Join-Path $directory $fileName
            if (
                (Test-Path -LiteralPath $legacyPath) -and
                -not (Test-Path -LiteralPath $newPath)
            ) {
                try {
                    Copy-Item -LiteralPath $legacyPath -Destination $newPath
                }
                catch {
                    # Migration is best-effort; the app can recreate either file.
                }
            }
        }
    }
    return $directory
}

function Get-DeepSeekConfigPath {
    return Join-Path (Get-AppDataDirectory) 'deepseek.json'
}

function Protect-LocalSecret {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $plainBytes = [Text.Encoding]::UTF8.GetBytes($Value)
    try {
        $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
            $plainBytes,
            $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [Convert]::ToBase64String($protectedBytes)
    }
    finally {
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
}

function Unprotect-LocalSecret {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    try {
        $protectedBytes = [Convert]::FromBase64String($Value)
        $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
            $protectedBytes,
            $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        try {
            return [Text.Encoding]::UTF8.GetString($plainBytes)
        }
        finally {
            [Array]::Clear($plainBytes, 0, $plainBytes.Length)
        }
    }
    catch {
        return ''
    }
}

function Get-DeepSeekConfiguration {
    $result = [ordered]@{
        EncryptedApiKey = ''
        KeyHint = ''
        Budget = 0.0
    }
    try {
        $path = Get-DeepSeekConfigPath
        if (Test-Path -LiteralPath $path) {
            $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($saved.PSObject.Properties['EncryptedApiKey']) {
                $result.EncryptedApiKey = [string]$saved.EncryptedApiKey
            }
            if ($saved.PSObject.Properties['KeyHint']) {
                $result.KeyHint = [string]$saved.KeyHint
            }
            if ($saved.PSObject.Properties['Budget']) {
                $result.Budget = [Math]::Max(0, [double]$saved.Budget)
            }
        }
    }
    catch {
        # A damaged optional configuration must not prevent the widget starting.
    }
    return [pscustomobject]$result
}

function Save-DeepSeekConfiguration {
    param(
        [AllowEmptyString()]
        [string]$ApiKey,
        [double]$Budget,
        [switch]$RemoveKey
    )

    $current = Get-DeepSeekConfiguration
    $encryptedApiKey = $current.EncryptedApiKey
    $keyHint = $current.KeyHint
    if ($RemoveKey) {
        $encryptedApiKey = ''
        $keyHint = ''
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
        $trimmedKey = $ApiKey.Trim()
        $encryptedApiKey = Protect-LocalSecret -Value $trimmedKey
        $keyHint = if ($trimmedKey.Length -gt 4) {
            $trimmedKey.Substring($trimmedKey.Length - 4)
        } else {
            $trimmedKey
        }
    }

    [ordered]@{
        EncryptedApiKey = $encryptedApiKey
        KeyHint = $keyHint
        Budget = [Math]::Max(0, $Budget)
    } | ConvertTo-Json | Set-Content -LiteralPath (Get-DeepSeekConfigPath) -Encoding UTF8
}

function Get-DeepSeekCredential {
    if (-not [string]::IsNullOrWhiteSpace($env:DEEPSEEK_API_KEY)) {
        $environmentKey = $env:DEEPSEEK_API_KEY.Trim()
        $hint = if ($environmentKey.Length -gt 4) {
            $environmentKey.Substring($environmentKey.Length - 4)
        } else {
            $environmentKey
        }
        return [pscustomobject]@{
            ApiKey = $environmentKey
            Hint = $hint
            Source = '环境变量'
        }
    }

    $configuration = Get-DeepSeekConfiguration
    $savedKey = Unprotect-LocalSecret -Value $configuration.EncryptedApiKey
    return [pscustomobject]@{
        ApiKey = $savedKey
        Hint = $configuration.KeyHint
        Source = if ($savedKey) { 'DPAPI 加密存储' } else { '未配置' }
    }
}

function Get-ObjectPropertyValue {
    param(
        $Object,
        [string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function ConvertFrom-DeepSeekUsageLine {
    param([string]$Line)

    try {
        return [DeepSeekLogScanner]::ParseLine($Line)
    }
    catch {
        return $null
    }
}

function Read-DeepSeekUsageFile {
    param([System.IO.FileInfo]$File)

    $cacheKey = '{0}:{1}' -f $File.LastWriteTimeUtc.Ticks, $File.Length
    if ($script:DeepSeekUsageCache.ContainsKey($File.FullName)) {
        $cached = $script:DeepSeekUsageCache[$File.FullName]
        if ($cached.Key -eq $cacheKey) { return $cached.Value }
    }

    $latest = $null
    $messageEvents = @()
    try {
        $messageEvents = @([DeepSeekLogScanner]::ReadFile($File.FullName))
        foreach ($event in $messageEvents) {
            if (-not $latest -or $event.Timestamp -gt $latest.Timestamp) {
                $latest = $event
            }
        }
    }
    catch {
        $messageEvents = @()
        $latest = $null
    }

    $value = [pscustomobject]@{
        Events = $messageEvents
        Latest = $latest
    }
    $script:DeepSeekUsageCache[$File.FullName] = [pscustomobject]@{
        Key = $cacheKey
        Value = $value
    }
    return $value
}

function Read-DeepSeekLatestUsageFile {
    param([System.IO.FileInfo]$File)

    $cacheKey = '{0}:{1}' -f $File.LastWriteTimeUtc.Ticks, $File.Length
    if ($script:DeepSeekLatestUsageCache.ContainsKey($File.FullName)) {
        $cached = $script:DeepSeekLatestUsageCache[$File.FullName]
        if ($cached.Key -eq $cacheKey) { return $cached.Value }
    }

    $latest = $null
    try {
        $stream = [IO.File]::Open(
            $File.FullName,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite
        )
        try {
            $tailLimit = 512KB
            $startOffset = [Math]::Max(0L, $stream.Length - $tailLimit)
            [void]$stream.Seek($startOffset, [IO.SeekOrigin]::Begin)
            $buffer = New-Object byte[] ([int]($stream.Length - $startOffset))
            $read = $stream.Read($buffer, 0, $buffer.Length)
            $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
            if ($startOffset -gt 0) {
                $firstLineBreak = $text.IndexOf("`n", [StringComparison]::Ordinal)
                $text = if ($firstLineBreak -ge 0) {
                    $text.Substring($firstLineBreak + 1)
                } else { '' }
            }

            foreach ($line in ($text -split "`r?`n")) {
                $event = ConvertFrom-DeepSeekUsageLine -Line $line
                if (-not $event) { continue }
                if (-not $latest -or $event.Timestamp -gt $latest.Timestamp) {
                    $latest = $event
                }
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        $latest = $null
    }

    if (-not $latest -and $File.Length -gt 512KB) {
        $latest = (Read-DeepSeekUsageFile -File $File).Latest
    }
    $script:DeepSeekLatestUsageCache[$File.FullName] = [pscustomobject]@{
        Key = $cacheKey
        Value = $latest
    }
    return $latest
}

function Get-DeepSeekEstimatedEventCostCny {
    param($Event)

    $isPro = [string]$Event.Model -match '(?i)(v4-pro|opus)'
    $cacheHitPrice = if ($isPro) { 0.025 } else { 0.02 }
    $cacheMissPrice = if ($isPro) { 3.0 } else { 1.0 }
    $outputPrice = if ($isPro) { 6.0 } else { 2.0 }
    $cacheMissTokens = $Event.InputTokens + $Event.CacheWriteTokens

    return (
        ($Event.CachedTokens * $cacheHitPrice) +
        ($cacheMissTokens * $cacheMissPrice) +
        ($Event.OutputTokens * $outputPrice)
    ) / 1000000
}

function Measure-DeepSeekUsageEvents {
    param(
        [object[]]$Events,
        [datetime]$StartDate = (Get-Date).Date,
        [Nullable[datetime]]$EndDate = $null
    )

    $rangeStart = $StartDate.Date
    $rangeEnd = if ($null -ne $EndDate) { [datetime]$EndDate } else { $rangeStart.AddDays(1) }
    $uniqueEvents = @{}
    $anonymousIndex = 0
    foreach ($event in $Events) {
        if (-not $event) { continue }
        $eventTime = $event.Timestamp.LocalDateTime
        if ($eventTime -lt $rangeStart -or $eventTime -ge $rangeEnd) { continue }
        $eventKey = if ($event.MessageId) {
            $event.MessageId
        } else {
            $anonymousIndex++
            '__anonymous_{0}' -f $anonymousIndex
        }
        if (
            -not $uniqueEvents.ContainsKey($eventKey) -or
            $event.Timestamp -gt $uniqueEvents[$eventKey].Timestamp
        ) {
            $uniqueEvents[$eventKey] = $event
        }
    }

    $aggregate = [ordered]@{
        TotalTokens = 0.0
        InputTokens = 0.0
        OutputTokens = 0.0
        CachedTokens = 0.0
        CacheWriteTokens = 0.0
        EstimatedCostCny = 0.0
        UniqueMessages = $uniqueEvents.Count
    }
    foreach ($event in $uniqueEvents.Values) {
        $aggregate.TotalTokens += $event.TotalTokens
        $aggregate.InputTokens += $event.InputTokens
        $aggregate.OutputTokens += $event.OutputTokens
        $aggregate.CachedTokens += $event.CachedTokens
        $aggregate.CacheWriteTokens += $event.CacheWriteTokens
        $aggregate.EstimatedCostCny += Get-DeepSeekEstimatedEventCostCny -Event $event
    }
    return [pscustomobject]$aggregate
}

function Get-DeepSeekLocalUsage {
    $result = [ordered]@{
        TodayTokens = 0.0
        TodayInputTokens = 0.0
        TodayOutputTokens = 0.0
        TodayCachedTokens = 0.0
        MonthlyTokens = 0.0
        MonthlyEstimatedCostCny = 0.0
        LastTurnTokens = 0.0
        LastInputTokens = 0.0
        LastOutputTokens = 0.0
        LastCachedTokens = 0.0
        CacheHitPercent = 0.0
        Model = '暂无本地记录'
        SampledAt = Get-Date
    }

    $projectsRoot = Join-Path $env:USERPROFILE '.claude\projects'
    if (-not (Test-Path -LiteralPath $projectsRoot)) {
        return [pscustomobject]$result
    }

    $files = @(Get-ChildItem -LiteralPath $projectsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    $todayDate = (Get-Date).Date
    $monthStart = Get-Date -Day 1 -Hour 0 -Minute 0 -Second 0 -Millisecond 0
    $nextMonth = $monthStart.AddMonths(1)
    $latest = $null
    $monthEvents = New-Object System.Collections.ArrayList
    $monthFiles = @($files | Where-Object { $_.LastWriteTime -ge $monthStart })
    foreach ($file in $monthFiles) {
        $summary = Read-DeepSeekUsageFile -File $file
        foreach ($event in $summary.Events) {
            [void]$monthEvents.Add($event)
        }
        if ($summary.Latest -and (-not $latest -or $summary.Latest.Timestamp -gt $latest.Timestamp)) {
            $latest = $summary.Latest
        }
    }

    $todayUsage = Measure-DeepSeekUsageEvents -Events @($monthEvents) -StartDate $todayDate
    $monthlyUsage = Measure-DeepSeekUsageEvents `
        -Events @($monthEvents) `
        -StartDate $monthStart `
        -EndDate $nextMonth
    $result.TodayTokens = $todayUsage.TotalTokens
    $result.TodayInputTokens = $todayUsage.InputTokens
    $result.TodayOutputTokens = $todayUsage.OutputTokens
    $result.TodayCachedTokens = $todayUsage.CachedTokens
    $result.MonthlyTokens = $monthlyUsage.TotalTokens
    $result.MonthlyEstimatedCostCny = [Math]::Round($monthlyUsage.EstimatedCostCny, 4)

    if (-not $latest) {
        foreach ($file in ($files | Where-Object {
            $_.LastWriteTime -lt $monthStart
        } | Select-Object -First 16)) {
            $candidate = Read-DeepSeekLatestUsageFile -File $file
            if ($candidate) {
                $latest = $candidate
                break
            }
        }
    }

    if ($latest) {
        $result.LastTurnTokens = $latest.TotalTokens
        $result.LastInputTokens = $latest.InputTokens + $latest.CachedTokens + $latest.CacheWriteTokens
        $result.LastOutputTokens = $latest.OutputTokens
        $result.LastCachedTokens = $latest.CachedTokens
        $cacheBase = $latest.InputTokens + $latest.CachedTokens + $latest.CacheWriteTokens
        $result.CacheHitPercent = if ($cacheBase -gt 0) {
            [Math]::Round(($latest.CachedTokens / $cacheBase) * 100, 1)
        } else { 0 }
        $result.Model = $latest.Model
        $result.SampledAt = $latest.Timestamp.LocalDateTime
    }
    return [pscustomobject]$result
}

function Format-CurrencyAmount {
    param(
        [double]$Amount,
        [string]$Currency
    )

    $symbol = if ($Currency -eq 'USD') { '$' } else { '¥' }
    return '{0}{1:N2}' -f $symbol, $Amount
}

function ConvertTo-DeepSeekSnapshot {
    param(
        $BalancePayload,
        $LocalUsage,
        [double]$Budget,
        [string]$KeyHint,
        [string]$CredentialSource,
        [datetime]$SampledAt = (Get-Date)
    )

    $balanceInfos = @(Get-ObjectPropertyValue -Object $BalancePayload -Name 'balance_infos' -Default @())
    $selectedBalance = $balanceInfos | Where-Object {
        [string](Get-ObjectPropertyValue -Object $_ -Name 'currency' -Default '') -eq 'CNY'
    } | Select-Object -First 1
    if (-not $selectedBalance) { $selectedBalance = $balanceInfos | Select-Object -First 1 }
    if (-not $selectedBalance) { throw 'DeepSeek 返回中没有可用的余额字段。' }

    $currency = [string](Get-ObjectPropertyValue -Object $selectedBalance -Name 'currency' -Default 'CNY')
    $totalBalance = [double]::Parse(
        [string](Get-ObjectPropertyValue -Object $selectedBalance -Name 'total_balance' -Default '0'),
        [Globalization.CultureInfo]::InvariantCulture
    )
    $grantedBalance = [double]::Parse(
        [string](Get-ObjectPropertyValue -Object $selectedBalance -Name 'granted_balance' -Default '0'),
        [Globalization.CultureInfo]::InvariantCulture
    )
    $toppedUpBalance = [double]::Parse(
        [string](Get-ObjectPropertyValue -Object $selectedBalance -Name 'topped_up_balance' -Default '0'),
        [Globalization.CultureInfo]::InvariantCulture
    )
    $isAvailable = [bool](Get-ObjectPropertyValue -Object $BalancePayload -Name 'is_available' -Default $false)
    $budgetPercent = if ($Budget -gt 0) {
        [Math]::Round([Math]::Max(0, [Math]::Min(100, ($totalBalance / $Budget) * 100)))
    } else { $null }

    return [pscustomobject]@{
        ProviderId = 'DeepSeek'
        Available = $isAvailable
        RemainingPercent = if ($null -ne $budgetPercent) { $budgetPercent } else { 0 }
        HasProgress = $null -ne $budgetPercent
        WindowLabel = if ($null -ne $budgetPercent) { '预算余量' } else { '余额' }
        ResetDate = Format-CurrencyAmount -Amount $totalBalance -Currency $currency
        ResetCountdown = if ($isAvailable) { '当前可用于 API 调用' } else { '余额当前不可用' }
        ResetCount = if ($Budget -gt 0) {
            Format-CurrencyAmount -Amount $Budget -Currency $currency
        } else { '未设置' }
        Plan = '按量计费'
        AccountName = 'DeepSeek API'
        AccountEmail = if ($KeyHint) {
            '密钥 ••••{0} · {1}' -f $KeyHint, $CredentialSource
        } else { '尚未配置 API Key' }
        TodayTokens = $LocalUsage.TodayTokens
        MonthlyTokens = $LocalUsage.MonthlyTokens
        MonthlyEstimatedCostCny = $LocalUsage.MonthlyEstimatedCostCny
        LastTurnTokens = $LocalUsage.LastTurnTokens
        InputTokens = $LocalUsage.LastInputTokens
        OutputTokens = $LocalUsage.LastOutputTokens
        CachedTokens = $LocalUsage.LastCachedTokens
        CacheHitPercent = $LocalUsage.CacheHitPercent
        ContextPercent = 0
        SampledAt = $SampledAt
        UsageSampledAt = $LocalUsage.SampledAt
        Status = if (-not $isAvailable) { '余额不可用' }
            elseif ($Budget -gt 0 -and $budgetPercent -le 20) { '建议留意' }
            else { '状态舒适' }
        Source = 'DeepSeek 官方余额 · Claude Code 本地日志'
        Currency = $currency
        TotalBalance = $totalBalance
        GrantedBalance = $grantedBalance
        ToppedUpBalance = $toppedUpBalance
        Budget = $Budget
        BudgetPercent = $budgetPercent
        Model = $LocalUsage.Model
    }
}

function Get-DeepSeekUnavailableSnapshot {
    param([string]$Reason = '请通过右键菜单配置 DeepSeek')

    return [pscustomobject]@{
        ProviderId = 'DeepSeek'
        Available = $false
        RemainingPercent = 0
        HasProgress = $false
        WindowLabel = '余额'
        ResetDate = '暂无'
        ResetCountdown = $Reason
        ResetCount = '未设置'
        Plan = '按量计费'
        AccountName = 'DeepSeek API'
        AccountEmail = '尚未配置 API Key'
        TodayTokens = 0
        MonthlyTokens = 0
        MonthlyEstimatedCostCny = 0
        LastTurnTokens = 0
        InputTokens = 0
        OutputTokens = 0
        CachedTokens = 0
        CacheHitPercent = 0
        ContextPercent = 0
        SampledAt = Get-Date
        UsageSampledAt = Get-Date
        Status = '等待配置'
        Source = $Reason
        Currency = 'CNY'
        TotalBalance = 0
        GrantedBalance = 0
        ToppedUpBalance = 0
        Budget = 0
        BudgetPercent = $null
        Model = '暂无本地记录'
    }
}

function Get-DeepSeekDemoSnapshot {
    $configuration = [pscustomobject]@{ Budget = 120.0 }
    $usage = [pscustomobject]@{
        TodayTokens = 382640
        MonthlyTokens = 2846520
        MonthlyEstimatedCostCny = 2.36
        LastTurnTokens = 174201
        LastInputTokens = 173880
        LastOutputTokens = 321
        LastCachedTokens = 173440
        CacheHitPercent = 99.7
        Model = 'deepseek-v4-pro'
        SampledAt = Get-Date
    }
    $payload = [pscustomobject]@{
        is_available = $true
        balance_infos = @(
            [pscustomobject]@{
                currency = 'CNY'
                total_balance = '86.40'
                granted_balance = '10.00'
                topped_up_balance = '76.40'
            }
        )
    }
    return ConvertTo-DeepSeekSnapshot `
        -BalancePayload $payload `
        -LocalUsage $usage `
        -Budget $configuration.Budget `
        -KeyHint '7K9D' `
        -CredentialSource '演示配置'
}

function Get-ResetText {
    param($UnixSeconds)

    if ($null -eq $UnixSeconds -or [long]$UnixSeconds -le 0) {
        return [pscustomobject]@{ Date = '暂无'; Countdown = '等待 Codex 提供' }
    }

    $reset = [DateTimeOffset]::FromUnixTimeSeconds([long]$UnixSeconds).LocalDateTime
    $remaining = $reset - (Get-Date)
    if ($remaining.TotalSeconds -le 0) {
        $countdown = '即将刷新'
    }
    elseif ($remaining.TotalDays -ge 1) {
        $countdown = '{0} 天 {1} 小时后' -f [Math]::Floor($remaining.TotalDays), $remaining.Hours
    }
    elseif ($remaining.TotalHours -ge 1) {
        $countdown = '{0} 小时 {1} 分后' -f [Math]::Floor($remaining.TotalHours), $remaining.Minutes
    }
    else {
        $countdown = '{0} 分钟后' -f [Math]::Max(1, [Math]::Ceiling($remaining.TotalMinutes))
    }

    return [pscustomobject]@{
        Date = $reset.ToString('M月d日 HH:mm')
        Countdown = $countdown
    }
}

function Get-CodexUsageSnapshot {
    if ($Demo) {
        return [pscustomobject]@{
            ProviderId = 'Codex'
            Available = $true
            RemainingPercent = 82
            HasProgress = $true
            WindowLabel = '本周余量'
            ResetDate = '8月2日 18:32'
            ResetCountdown = '5 天 7 小时后'
            ResetCount = '未提供'
            Plan = 'Pro'
            AccountName = 'YJ'
            AccountEmail = 'you@example.com'
            TodayTokens = 128420
            TodayInputTokens = 127530
            TodayOutputTokens = 890
            TodayCachedTokens = 118240
            TodayCacheHitPercent = 92.7
            LastTurnTokens = 49238
            InputTokens = 48891
            OutputTokens = 347
            CachedTokens = 46848
            CacheHitPercent = 95.8
            ContextPercent = 19.1
            SampledAt = Get-Date
            Status = '状态舒适'
            Source = '演示数据'
        }
    }

    $account = Get-SafeAccountInfo
    $sessionsRoot = Join-Path $env:USERPROFILE '.codex\sessions'
    $files = @()
    if (Test-Path -LiteralPath $sessionsRoot) {
        $files = @(Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
    }

    # File modification time is not the observation time: a parallel task can
    # keep appending unrelated events to an older session. Select quota and
    # token snapshots by their token_count timestamps instead.
    $recentSnapshots = @($files | Select-Object -First 48 | ForEach-Object {
        Read-SessionSnapshot -File $_
    })
    $latestRateLimitSnapshot = Select-CodexRateLimitSnapshot -Snapshots $recentSnapshots
    $latestSnapshot = $recentSnapshots | Where-Object { $_.Payload } |
        Sort-Object ObservedAt -Descending | Select-Object -First 1

    if (-not $latestRateLimitSnapshot) {
        return [pscustomobject]@{
            ProviderId = 'Codex'
            Available = $false
            RemainingPercent = 0
            HasProgress = $true
            WindowLabel = 'Codex 余量'
            ResetDate = '暂无'
            ResetCountdown = '启动一次 Codex 任务后更新'
            ResetCount = '未提供'
            Plan = 'Codex'
            AccountName = $account.DisplayName
            AccountEmail = $account.Email
            TodayTokens = 0
            TodayInputTokens = 0
            TodayOutputTokens = 0
            TodayCachedTokens = 0
            TodayCacheHitPercent = 0
            LastTurnTokens = 0
            InputTokens = 0
            OutputTokens = 0
            CachedTokens = 0
            CacheHitPercent = 0
            ContextPercent = 0
            SampledAt = Get-Date
            Status = '等待数据'
            Source = '本地暂无用量快照'
        }
    }

    if (-not $latestSnapshot) { $latestSnapshot = $latestRateLimitSnapshot }
    $payload = $latestSnapshot.Payload
    $rateLimitPayload = $latestRateLimitSnapshot.RateLimitPayload
    $limits = Get-ObjectPropertyValue -Object $rateLimitPayload -Name 'rate_limits'
    $primary = Get-CodexRateLimitWindow -Payload $rateLimitPayload

    $usedPercent = [Math]::Max(
        0,
        [Math]::Min(
            100,
            [double](Get-ObjectPropertyValue -Object $primary -Name 'used_percent' -Default 0)
        )
    )
    $remainingPercent = [Math]::Round(100 - $usedPercent)
    $windowMinutes = [int](Get-ObjectPropertyValue `
        -Object $primary `
        -Name 'window_minutes' `
        -Default 0)
    $windowLabel = if ($windowMinutes -ge 10080) { '本周余量' }
        elseif ($windowMinutes -ge 1440) { '周期余量' }
        elseif ($windowMinutes -gt 0) { '{0} 小时余量' -f [Math]::Round($windowMinutes / 60) }
        else { 'Codex 余量' }

    $resetTimestamp = $null
    $resetTimestamp = [long](Get-ObjectPropertyValue `
        -Object $primary `
        -Name 'resets_at' `
        -Default 0)
    $resetText = Get-ResetText -UnixSeconds $resetTimestamp

    $info = Get-ObjectPropertyValue -Object $payload -Name 'info'
    $lastUsage = Get-ObjectPropertyValue -Object $info -Name 'last_token_usage'
    $inputTokens = [double](Get-ObjectPropertyValue -Object $lastUsage -Name 'input_tokens' -Default 0)
    $cachedTokens = [double](Get-ObjectPropertyValue -Object $lastUsage -Name 'cached_input_tokens' -Default 0)
    $outputTokens = [double](Get-ObjectPropertyValue -Object $lastUsage -Name 'output_tokens' -Default 0)
    $lastTurnTokens = [double](Get-ObjectPropertyValue -Object $lastUsage -Name 'total_tokens' -Default 0)
    $contextWindow = [double](Get-ObjectPropertyValue -Object $info -Name 'model_context_window' -Default 0)
    $cacheHit = if ($inputTokens -gt 0) { [Math]::Round(($cachedTokens / $inputTokens) * 100, 1) } else { 0 }
    $contextPercent = if ($contextWindow -gt 0) {
        [Math]::Round([Math]::Min(100, ($lastTurnTokens / $contextWindow) * 100), 1)
    } else { 0 }

    $today = (Get-Date).Date
    $todayTokens = 0.0
    $todayInputTokens = 0.0
    $todayOutputTokens = 0.0
    $todayCachedTokens = 0.0
    foreach ($file in ($files | Where-Object { $_.LastWriteTime.Date -eq $today })) {
        $daySnapshot = Read-SessionSnapshot -File $file
        $dayInfo = Get-ObjectPropertyValue -Object $daySnapshot.Payload -Name 'info'
        $dayUsage = Get-ObjectPropertyValue -Object $dayInfo -Name 'total_token_usage'
        if ($dayUsage) {
            $todayTokens += [double](Get-ObjectPropertyValue -Object $dayUsage -Name 'total_tokens' -Default 0)
            $todayInputTokens += [double](Get-ObjectPropertyValue -Object $dayUsage -Name 'input_tokens' -Default 0)
            $todayOutputTokens += [double](Get-ObjectPropertyValue -Object $dayUsage -Name 'output_tokens' -Default 0)
            $todayCachedTokens += [double](Get-ObjectPropertyValue -Object $dayUsage -Name 'cached_input_tokens' -Default 0)
        }
    }
    $todayCacheHit = if ($todayInputTokens -gt 0) {
        [Math]::Round(($todayCachedTokens / $todayInputTokens) * 100, 1)
    } else { 0 }

    $status = if ($remainingPercent -ge 60) { '状态舒适' }
        elseif ($remainingPercent -ge 30) { '余量平稳' }
        elseif ($remainingPercent -gt 0) { '建议留意' }
        else { '等待重置' }

    return [pscustomobject]@{
        ProviderId = 'Codex'
        Available = $true
        RemainingPercent = $remainingPercent
        HasProgress = $true
        WindowLabel = $windowLabel
        ResetDate = $resetText.Date
        ResetCountdown = $resetText.Countdown
        ResetCount = '未提供'
        Plan = Get-PlanLabel -PlanType ([string](Get-ObjectPropertyValue `
            -Object $limits `
            -Name 'plan_type' `
            -Default ''))
        AccountName = $account.DisplayName
        AccountEmail = $account.Email
        TodayTokens = $todayTokens
        TodayInputTokens = $todayInputTokens
        TodayOutputTokens = $todayOutputTokens
        TodayCachedTokens = $todayCachedTokens
        TodayCacheHitPercent = $todayCacheHit
        LastTurnTokens = $lastTurnTokens
        InputTokens = $inputTokens
        OutputTokens = $outputTokens
        CachedTokens = $cachedTokens
        CacheHitPercent = $cacheHit
        ContextPercent = $contextPercent
        SampledAt = $latestRateLimitSnapshot.RateLimitObservedAt.LocalDateTime
        Status = $status
        Source = 'Codex 本地会话快照'
    }
}

if ($CheckCodexRateLimitSelection) {
    $stalePayload = [pscustomobject]@{
        rate_limits = [pscustomobject]@{
            primary = [pscustomobject]@{
                used_percent = 0.0
                window_minutes = 10080
                resets_at = 1893456000
            }
            plan_type = 'pro'
        }
    }
    $freshPayload = [pscustomobject]@{
        rate_limits = [pscustomobject]@{
            primary = [pscustomobject]@{
                used_percent = 22.0
                window_minutes = 10080
                resets_at = 1893459600
            }
            plan_type = 'pro'
        }
    }
    $incompletePayload = [pscustomobject]@{
        rate_limits = [pscustomobject]@{
            primary = [pscustomobject]@{
                window_minutes = 10080
                resets_at = 1893463200
            }
            plan_type = 'pro'
        }
    }
    $selectionCandidates = @(
        [pscustomobject]@{
            RateLimitPayload = $stalePayload
            RateLimitObservedAt = [DateTimeOffset]'2029-12-31T23:50:00Z'
            FileModifiedAt = [DateTimeOffset]'2030-01-01T00:10:00Z'
        },
        [pscustomobject]@{
            RateLimitPayload = $freshPayload
            RateLimitObservedAt = [DateTimeOffset]'2030-01-01T00:00:00Z'
            FileModifiedAt = [DateTimeOffset]'2030-01-01T00:05:00Z'
        },
        [pscustomobject]@{
            RateLimitPayload = $incompletePayload
            RateLimitObservedAt = [DateTimeOffset]'2030-01-01T00:01:00Z'
            FileModifiedAt = [DateTimeOffset]'2030-01-01T00:11:00Z'
        }
    )
    $selected = Select-CodexRateLimitSnapshot -Snapshots $selectionCandidates
    $emptySelection = Select-CodexRateLimitSnapshot -Snapshots @(
        [pscustomobject]@{
            RateLimitPayload = $incompletePayload
            RateLimitObservedAt = [DateTimeOffset]'2030-01-01T00:01:00Z'
        }
    )
    $selectedWindow = Get-CodexRateLimitWindow -Payload $selected.RateLimitPayload
    [pscustomobject]@{
        SelectedUsedPercent = [double]$selectedWindow.used_percent
        SelectedResetAt = [long]$selectedWindow.resets_at
        SelectedObservedAt = $selected.RateLimitObservedAt
        NewestFileWasStale = $selectionCandidates[0].FileModifiedAt -gt $selectionCandidates[1].FileModifiedAt
        IncompleteNewestWasIgnored = $selected.RateLimitPayload -eq $freshPayload
        EmptySelectionHandled = $null -eq $emptySelection
    } | ConvertTo-Json
    exit 0
}

if ($CheckDeepSeekData) {
    $checkSnapshot = Get-DeepSeekDemoSnapshot
    $testSecret = 'deepseek-test-key-1234'
    $protectedSecret = Protect-LocalSecret -Value $testSecret
    $roundTripSecret = Unprotect-LocalSecret -Value $protectedSecret
    $testTimestamp = [DateTimeOffset]::Now
    $duplicateEvents = @(
        [pscustomobject]@{
            MessageId = 'duplicate-message'
            Timestamp = $testTimestamp.AddSeconds(-1)
            Model = 'deepseek-v4-pro'
            InputTokens = 10
            OutputTokens = 2
            CachedTokens = 20
            CacheWriteTokens = 0
            TotalTokens = 32
        },
        [pscustomobject]@{
            MessageId = 'duplicate-message'
            Timestamp = $testTimestamp
            Model = 'deepseek-v4-pro'
            InputTokens = 12
            OutputTokens = 3
            CachedTokens = 25
            CacheWriteTokens = 0
            TotalTokens = 40
        }
    )
    $dedupedUsage = Measure-DeepSeekUsageEvents -Events $duplicateEvents
    $parserEvent = ConvertFrom-DeepSeekUsageLine -Line (
        '{"message":{"id":"parser-message","model":"deepseek-v4-pro","usage":' +
        '{"input_tokens":100,"cache_creation_input_tokens":20,' +
        '"cache_read_input_tokens":300,"output_tokens":4}},' +
        '"uuid":"parser-uuid","timestamp":"' +
        $testTimestamp.ToString('o', [Globalization.CultureInfo]::InvariantCulture) +
        '"}'
    )
    $pricingUsage = Measure-DeepSeekUsageEvents -Events @(
        [pscustomobject]@{
            MessageId = 'pricing-message'
            Timestamp = $testTimestamp
            Model = 'deepseek-v4-pro'
            InputTokens = 1000000
            OutputTokens = 1000000
            CachedTokens = 1000000
            CacheWriteTokens = 0
            TotalTokens = 3000000
        }
    )
    $checkSnapshot | Add-Member -NotePropertyName SecureStorageRoundTrip -NotePropertyValue (
        $roundTripSecret -eq $testSecret -and $protectedSecret -notmatch [regex]::Escape($testSecret)
    )
    $checkSnapshot | Add-Member -NotePropertyName DedupedUsageTokens -NotePropertyValue $dedupedUsage.TotalTokens
    $checkSnapshot | Add-Member -NotePropertyName DedupedUsageMessages -NotePropertyValue $dedupedUsage.UniqueMessages
    $checkSnapshot | Add-Member -NotePropertyName ParserUsageTokens -NotePropertyValue $parserEvent.TotalTokens
    $checkSnapshot | Add-Member -NotePropertyName ParserUsageModel -NotePropertyValue $parserEvent.Model
    $checkSnapshot | Add-Member -NotePropertyName PricingUsageTokens -NotePropertyValue $pricingUsage.TotalTokens
    $checkSnapshot | Add-Member -NotePropertyName PricingUsageCostCny -NotePropertyValue $pricingUsage.EstimatedCostCny
    $checkSnapshot | ConvertTo-Json -Depth 5
    exit 0
}

if ($CheckDeepSeekUsage) {
    Get-DeepSeekLocalUsage | ConvertTo-Json -Depth 5
    exit 0
}

if ($CheckData) {
    Get-CodexUsageSnapshot | ConvertTo-Json -Depth 5
    exit 0
}

if ($CheckPlacement) {
    $anchor = [pscustomobject]@{ Left = 1812.0; Top = 980.0 }
    $expanded = Get-FittedPlacement `
        -AnchorLeft $anchor.Left `
        -AnchorTop $anchor.Top `
        -TargetWidth $script:ExpandedWidth `
        -TargetHeight $script:ExpandedHeight `
        -WorkLeft 0 `
        -WorkTop 0 `
        -WorkRight 1920 `
        -WorkBottom 1080
    [pscustomobject]@{
        Anchor = $anchor
        Expanded = $expanded
        Restored = $anchor
    } | ConvertTo-Json -Depth 3
    exit 0
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class RemainingMarginNativeWindow
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
'@
$script:ReducedMotion = -not [System.Windows.SystemParameters]::ClientAreaAnimation

[xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Remaining Margin Float"
    Width="96"
    Height="88"
    MinWidth="96"
    MaxWidth="370"
    MinHeight="88"
    MaxHeight="500"
    WindowStyle="None"
    ResizeMode="NoResize"
    AllowsTransparency="True"
    Background="Transparent"
    Topmost="True"
    ShowInTaskbar="False"
    SnapsToDevicePixels="True"
    UseLayoutRounding="True">
    <Window.Resources>
        <SolidColorBrush x:Key="TextPrimary" Color="#292D2A"/>
        <SolidColorBrush x:Key="TextSecondary" Color="#626A65"/>
        <SolidColorBrush x:Key="TextMuted" Color="#8A918C"/>
        <SolidColorBrush x:Key="Sage" Color="#718478"/>
        <SolidColorBrush x:Key="SageSoft" Color="#EEF1ED"/>
        <SolidColorBrush x:Key="StatusStrong" Color="#46564C"/>
        <SolidColorBrush x:Key="StatusBorder" Color="#DCE3DD"/>
        <SolidColorBrush x:Key="Champagne" Color="#8A7658"/>
        <SolidColorBrush x:Key="Surface" Color="#FAFAF7"/>
        <SolidColorBrush x:Key="SurfaceSubtle" Color="#F4F5F1"/>
        <SolidColorBrush x:Key="Border" Color="#E1E3DE"/>
        <SolidColorBrush x:Key="Divider" Color="#E7E8E3"/>

        <Style x:Key="SoftButton" TargetType="Button">
            <Setter Property="Height" Value="34"/>
            <Setter Property="Padding" Value="12,0"/>
            <Setter Property="Background" Value="#F1F3EF"/>
            <Setter Property="Foreground" Value="{StaticResource TextSecondary}"/>
            <Setter Property="BorderBrush" Value="#E0E3DD"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonBorder"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="9">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="#E9EEE9"/>
                                <Setter TargetName="ButtonBorder" Property="BorderBrush" Value="#C9D2CA"/>
                                <Setter Property="Foreground" Value="#46544A"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.72"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="ButtonBorder" Property="BorderBrush" Value="#718478"/>
                                <Setter TargetName="ButtonBorder" Property="BorderThickness" Value="2"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="CompactHitStyle" TargetType="Border">
            <Setter Property="Background" Value="#01FFFFFF"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="14"/>
            <Style.Triggers>
                <Trigger Property="IsKeyboardFocusWithin" Value="True">
                    <Setter Property="BorderBrush" Value="#718478"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="MetricTitleText" TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
            <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
            <Setter Property="FontSize" Value="9.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>

        <Style x:Key="MetricValueText" TargetType="TextBlock">
            <Setter Property="Margin" Value="0,4,0,0"/>
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
            <Setter Property="FontFamily" Value="Segoe UI Variable Display"/>
            <Setter Property="FontSize" Value="21"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Typography.NumeralAlignment" Value="Tabular"/>
        </Style>

        <Style x:Key="MetricHintText" TargetType="TextBlock">
            <Setter Property="Margin" Value="0,2,0,0"/>
            <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
            <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
            <Setter Property="FontSize" Value="9"/>
        </Style>
    </Window.Resources>

    <Grid x:Name="WindowRoot" Margin="5">
        <Border x:Name="HoverHalo"
                Margin="-1"
                CornerRadius="17"
                BorderThickness="1"
                BorderBrush="{DynamicResource Sage}"
                Background="Transparent"
                Opacity="0"/>

        <Border x:Name="Surface"
                Background="{StaticResource Surface}"
                BorderBrush="{StaticResource Border}"
                BorderThickness="1"
                CornerRadius="16"
                ClipToBounds="True">
            <Border.Effect>
                <DropShadowEffect x:Name="SurfaceShadow"
                                  Color="#58635B"
                                  BlurRadius="8"
                                  ShadowDepth="2"
                                  Direction="270"
                                  Opacity="0.07"/>
            </Border.Effect>

            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="77"/>
                    <RowDefinition Height="1"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <Border x:Name="CompactHit"
                        Grid.Row="0"
                        Style="{StaticResource CompactHitStyle}"
                        Padding="9,7,9,7"
                        Cursor="Hand"
                        ToolTip="拖动移动 · 单击查看详情"
                        Focusable="True">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="*"/>
                            <RowDefinition x:Name="CompactProgressRow" Height="14"/>
                        </Grid.RowDefinitions>

                        <StackPanel Grid.Row="0" HorizontalAlignment="Center" VerticalAlignment="Center">
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,1,0,0">
                                <TextBlock x:Name="CompactPrefix"
                                           Text=""
                                           Margin="0,0,1,4"
                                           VerticalAlignment="Bottom"
                                           Foreground="{DynamicResource Sage}"
                                           FontFamily="Segoe UI Variable Text"
                                           FontSize="9.5"
                                           FontWeight="SemiBold"/>
                                <TextBlock x:Name="RemainingValue"
                                           Text="--"
                                           Foreground="{DynamicResource StatusStrong}"
                                           FontFamily="Segoe UI Variable Display"
                                           FontSize="26"
                                           FontWeight="SemiBold"
                                           FontStretch="SemiCondensed"
                                           LineHeight="29"
                                           Typography.NumeralAlignment="Tabular"/>
                                <TextBlock x:Name="CompactSuffix"
                                           Text="%"
                                           Margin="1,0,0,4"
                                           VerticalAlignment="Bottom"
                                           Foreground="{DynamicResource Sage}"
                                           FontFamily="Segoe UI Variable Text"
                                           FontSize="9.5"
                                           FontWeight="SemiBold"/>
                            </StackPanel>
                            <TextBlock x:Name="WindowLabel"
                                       Margin="0,0,0,0"
                                       HorizontalAlignment="Center"
                                       Text="Codex 余量"
                                       Foreground="{StaticResource TextSecondary}"
                                       FontFamily="Microsoft YaHei UI"
                                       FontSize="9.5"/>
                        </StackPanel>

                        <Grid Grid.Row="1" VerticalAlignment="Stretch">
                            <TextBlock x:Name="ExpandedWindowLabel"
                                       HorizontalAlignment="Left"
                                       VerticalAlignment="Top"
                                       Visibility="Collapsed"
                                       Text="Codex 余量"
                                       Foreground="{StaticResource TextMuted}"
                                       FontFamily="Microsoft YaHei UI"
                                       FontSize="8.5"
                                       FontWeight="SemiBold"/>
                            <StackPanel x:Name="ResetSummaryPanel"
                                        Orientation="Horizontal"
                                        HorizontalAlignment="Right"
                                        VerticalAlignment="Top"
                                        Visibility="Collapsed">
                                <TextBlock Text="下次重置 "
                                           Foreground="{StaticResource TextMuted}"
                                           FontFamily="Microsoft YaHei UI"
                                           FontSize="8.5"/>
                                <TextBlock x:Name="DetailsResetDate"
                                           Text="--"
                                           Foreground="{StaticResource TextSecondary}"
                                           FontFamily="Microsoft YaHei UI"
                                           FontSize="8.5"
                                           FontWeight="SemiBold"/>
                                <TextBlock Text=" · "
                                           Foreground="{StaticResource TextMuted}"
                                           FontFamily="Microsoft YaHei UI"
                                           FontSize="8.5"/>
                                <TextBlock x:Name="DetailsResetCountdown"
                                           Text="--"
                                           Foreground="{StaticResource TextMuted}"
                                           FontFamily="Microsoft YaHei UI"
                                           FontSize="8.5"/>
                            </StackPanel>
                            <Border x:Name="ProgressTrack"
                                    Height="3"
                                    VerticalAlignment="Bottom"
                                    CornerRadius="1.5"
                                    Background="#DCDDD8"
                                    ClipToBounds="True"
                                    ToolTip="剩余 -- · 已使用 --">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition x:Name="RemainingProgressColumn" Width="0*"/>
                                        <ColumnDefinition x:Name="UsedProgressColumn" Width="100*"/>
                                    </Grid.ColumnDefinitions>
                                    <Border Grid.Column="0" Background="{DynamicResource Sage}"/>
                                    <Border Grid.Column="1" Background="#DCDDD8"/>
                                </Grid>
                            </Border>
                        </Grid>
                    </Grid>
                </Border>

                <Border Grid.Row="1" Background="{StaticResource Divider}" Margin="16,0"/>

                <Grid x:Name="DetailsPanel"
                      Grid.Row="2"
                      Margin="18,15,18,15"
                      Visibility="Collapsed"
                      Opacity="0">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="52"/>
                        <RowDefinition Height="10"/>
                        <RowDefinition Height="154"/>
                        <RowDefinition Height="68"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="36"/>
                    </Grid.RowDefinitions>

                    <Grid Grid.Row="0">
                        <StackPanel VerticalAlignment="Center">
                            <StackPanel Orientation="Horizontal">
                                <TextBlock x:Name="AccountName"
                                           Text="本地 Codex"
                                           Foreground="{StaticResource TextPrimary}"
                                           FontFamily="Microsoft YaHei UI"
                                           FontSize="15"
                                           FontWeight="SemiBold"/>
                                <Border Margin="9,1,0,0"
                                        Padding="7,2"
                                        VerticalAlignment="Center"
                                        Background="#F1EFEA"
                                        BorderBrush="#E1DDD3"
                                        BorderThickness="1"
                                        CornerRadius="5">
                                    <TextBlock x:Name="PlanBadge"
                                               Text="Codex"
                                               Foreground="#796B53"
                                               FontFamily="Segoe UI Variable Text"
                                               FontSize="9"
                                               FontWeight="SemiBold"/>
                                </Border>
                            </StackPanel>
                            <TextBlock x:Name="AccountEmail"
                                       Margin="0,5,0,0"
                                       Text="未找到账号信息"
                                       Foreground="{StaticResource TextSecondary}"
                                       FontFamily="Segoe UI Variable Text"
                                       FontSize="10.5"
                                       TextTrimming="CharacterEllipsis"
                                       ToolTip="{Binding RelativeSource={RelativeSource Self}, Path=Text}"/>
                        </StackPanel>

                        <Button x:Name="CloseButton"
                                HorizontalAlignment="Right"
                                VerticalAlignment="Center"
                                Width="34"
                                Height="34"
                                Style="{StaticResource SoftButton}"
                                Padding="0"
                                ToolTip="收起详情"
                                AutomationProperties.Name="收起详情">
                            <TextBlock Text="&#xE70E;"
                                       Foreground="#69716C"
                                       FontFamily="Segoe Fluent Icons"
                                       FontSize="11"/>
                        </Button>
                    </Grid>

                    <Grid Grid.Row="2">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="8"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>

                        <Border Grid.Row="0"
                                Background="{DynamicResource SageSoft}"
                                BorderBrush="{DynamicResource StatusBorder}"
                                BorderThickness="1"
                                CornerRadius="11"
                                Padding="13,8">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="18"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel Grid.Column="0" VerticalAlignment="Center">
                                    <TextBlock x:Name="MetricOneTitle" Text="已用额度" Style="{StaticResource MetricTitleText}"/>
                                    <TextBlock x:Name="PrimaryMetricValue"
                                               Text="--"
                                               Style="{StaticResource MetricValueText}"
                                               Foreground="{DynamicResource StatusStrong}"/>
                                    <TextBlock x:Name="PrimaryMetricHint"
                                               Text="剩余 --"
                                               Style="{StaticResource MetricHintText}"
                                               TextTrimming="CharacterEllipsis"/>
                                </StackPanel>

                                <StackPanel Grid.Column="2" VerticalAlignment="Center">
                                    <TextBlock x:Name="MetricTwoTitle" Text="今日 TOKEN" Style="{StaticResource MetricTitleText}"/>
                                    <TextBlock x:Name="TodayTokens" Text="--" Style="{StaticResource MetricValueText}"/>
                                    <TextBlock x:Name="MetricTwoHint"
                                               Text="本机任务累计"
                                               Style="{StaticResource MetricHintText}"
                                               TextTrimming="CharacterEllipsis"/>
                                </StackPanel>
                            </Grid>
                        </Border>

                        <Border Grid.Row="2"
                                Background="{DynamicResource SageSoft}"
                                BorderBrush="{DynamicResource StatusBorder}"
                                BorderThickness="1"
                                CornerRadius="11"
                                Padding="13,8">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="18"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel Grid.Column="0" VerticalAlignment="Center">
                                    <TextBlock x:Name="MetricThreeTitle" Text="今日输入" Style="{StaticResource MetricTitleText}"/>
                                    <TextBlock x:Name="LastTurnTokens" Text="--" Style="{StaticResource MetricValueText}"/>
                                    <TextBlock x:Name="ContextText"
                                               Text="所有本机任务"
                                               Style="{StaticResource MetricHintText}"
                                               TextTrimming="CharacterEllipsis"
                                               ToolTip="{Binding RelativeSource={RelativeSource Self}, Path=Text}"/>
                                </StackPanel>

                                <StackPanel Grid.Column="2" VerticalAlignment="Center">
                                    <TextBlock x:Name="MetricFourTitle" Text="今日输出" Style="{StaticResource MetricTitleText}"/>
                                    <TextBlock x:Name="CacheHit" Text="--" Style="{StaticResource MetricValueText}"/>
                                    <TextBlock x:Name="CacheTokenText"
                                               Text="所有本机任务"
                                               Style="{StaticResource MetricHintText}"
                                               TextTrimming="CharacterEllipsis"
                                               ToolTip="{Binding RelativeSource={RelativeSource Self}, Path=Text}"/>
                                </StackPanel>
                            </Grid>
                        </Border>
                    </Grid>

                    <Border Grid.Row="3"
                            Margin="0,8,0,0"
                            Background="{StaticResource SurfaceSubtle}"
                            BorderBrush="#E5E7E2"
                            BorderThickness="1"
                            CornerRadius="10"
                            Padding="12,8">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel>
                                <TextBlock x:Name="BreakdownTitle" Text="今日缓存" Style="{StaticResource MetricTitleText}"/>
                                <TextBlock x:Name="TokenBreakdown"
                                           Margin="0,4,0,0"
                                           Text="-- cached  ·  命中 --"
                                           Foreground="{StaticResource TextPrimary}"
                                           FontFamily="Microsoft YaHei UI"
                                           FontSize="10.5"
                                           FontWeight="SemiBold"/>
                            </StackPanel>
                            <StackPanel Grid.Column="1" HorizontalAlignment="Right">
                                <TextBlock x:Name="SecondaryMetricTitle"
                                           Text="额度状态"
                                           HorizontalAlignment="Right"
                                           Style="{StaticResource MetricTitleText}"/>
                                <TextBlock x:Name="ResetCount"
                                           Margin="0,4,0,0"
                                           Text="等待数据"
                                           HorizontalAlignment="Right"
                                           Foreground="{StaticResource TextPrimary}"
                                           FontFamily="Microsoft YaHei UI"
                                           FontSize="10.5"
                                           FontWeight="SemiBold"/>
                            </StackPanel>
                        </Grid>
                    </Border>

                    <StackPanel Grid.Row="4" Margin="1,11,1,0" VerticalAlignment="Top">
                        <TextBlock x:Name="SourceText"
                                   Text="Codex 本地会话快照"
                                   Foreground="{StaticResource TextSecondary}"
                                   FontFamily="Microsoft YaHei UI"
                                   FontSize="9.5"/>
                        <TextBlock x:Name="SampleTime"
                                   Margin="0,4,0,0"
                                   Text="采样于 --"
                                   Foreground="{StaticResource TextMuted}"
                                   FontFamily="Microsoft YaHei UI"
                                   FontSize="9.5"/>
                    </StackPanel>

                    <Grid Grid.Row="5">
                        <TextBlock x:Name="AutoRefreshText"
                                   VerticalAlignment="Center"
                                   Text="60 秒后自动刷新"
                                   Foreground="{StaticResource TextMuted}"
                                   FontFamily="Microsoft YaHei UI"
                                   FontSize="9.5"/>
                        <Button x:Name="RefreshButton"
                                HorizontalAlignment="Right"
                                Width="88"
                                Style="{StaticResource SoftButton}"
                                Content="立即刷新"
                                ToolTip="重新读取当前数据源"
                                AutomationProperties.Name="立即刷新"/>
                    </Grid>
                </Grid>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
if ($Demo) {
    # Make visual QA builds discoverable to Windows automation tools.
    $window.ShowInTaskbar = $true
}

function Get-WindowExtendedStyle {
    $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
    if ($helper.Handle -eq [IntPtr]::Zero) { return 0 }
    return [RemainingMarginNativeWindow]::GetWindowLong($helper.Handle, -20)
}

function Hide-WindowFromTaskSwitcher {
    $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
    if ($helper.Handle -eq [IntPtr]::Zero) { return $false }

    $toolWindow = 0x00000080
    $appWindow = 0x00040000
    $style = [RemainingMarginNativeWindow]::GetWindowLong($helper.Handle, -20)
    $style = ($style -bor $toolWindow) -band (-bnot $appWindow)
    [void][RemainingMarginNativeWindow]::SetWindowLong($helper.Handle, -20, $style)
    return (($style -band $toolWindow) -ne 0 -and ($style -band $appWindow) -eq 0)
}

function New-TrayAppIcon {
    $bitmap = New-Object Drawing.Bitmap(
        32,
        32,
        [Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $sageBrush = New-Object Drawing.SolidBrush(
        [Drawing.ColorTranslator]::FromHtml('#7E9584')
    )
    $ivoryBrush = New-Object Drawing.SolidBrush(
        [Drawing.ColorTranslator]::FromHtml('#FCFBF8')
    )
    $champagnePen = New-Object Drawing.Pen(
        [Drawing.ColorTranslator]::FromHtml('#BEA374'),
        1.5
    )
    $font = New-Object Drawing.Font(
        'Segoe UI',
        17,
        [Drawing.FontStyle]::Bold,
        [Drawing.GraphicsUnit]::Pixel
    )
    $format = New-Object Drawing.StringFormat
    $format.Alignment = [Drawing.StringAlignment]::Center
    $format.LineAlignment = [Drawing.StringAlignment]::Center

    try {
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $graphics.Clear([Drawing.Color]::Transparent)
        $graphics.FillEllipse($sageBrush, 1, 1, 30, 30)
        $graphics.DrawEllipse($champagnePen, 1.5, 1.5, 29, 29)
        $graphics.DrawString(
            'R',
            $font,
            $ivoryBrush,
            (New-Object Drawing.RectangleF(0, 0, 32, 31)),
            $format
        )

        $iconHandle = $bitmap.GetHicon()
        try {
            return ([Drawing.Icon]::FromHandle($iconHandle).Clone())
        }
        finally {
            [void][RemainingMarginNativeWindow]::DestroyIcon($iconHandle)
        }
    }
    finally {
        $format.Dispose()
        $font.Dispose()
        $champagnePen.Dispose()
        $ivoryBrush.Dispose()
        $sageBrush.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

if (-not $Demo) {
    $window.Add_SourceInitialized({
        [void](Hide-WindowFromTaskSwitcher)
    })
}

$names = @(
    'WindowRoot', 'HoverHalo', 'Surface', 'SurfaceShadow', 'CompactHit',
    'CompactPrefix', 'RemainingValue', 'CompactSuffix', 'WindowLabel',
    'CompactProgressRow', 'ExpandedWindowLabel', 'ResetSummaryPanel',
    'ProgressTrack', 'RemainingProgressColumn',
    'UsedProgressColumn', 'DetailsPanel', 'AccountName',
    'PlanBadge', 'AccountEmail', 'CloseButton', 'DetailsResetDate',
    'DetailsResetCountdown', 'MetricOneTitle', 'PrimaryMetricValue',
    'PrimaryMetricHint', 'MetricTwoTitle', 'MetricTwoHint',
    'TodayTokens', 'MetricThreeTitle', 'LastTurnTokens', 'ContextText',
    'MetricFourTitle', 'CacheHit', 'BreakdownTitle', 'SecondaryMetricTitle',
    'CacheTokenText', 'ResetCount', 'TokenBreakdown', 'SourceText', 'SampleTime',
    'AutoRefreshText', 'RefreshButton'
)
foreach ($name in $names) {
    Set-Variable -Name $name -Value $window.FindName($name) -Scope Script
}

function New-DoubleAnimation {
    param(
        [double]$To,
        [int]$Milliseconds = 220,
        [switch]$EaseOut
    )
    $animation = New-Object Windows.Media.Animation.DoubleAnimation
    $animation.To = $To
    $effectiveMilliseconds = if ($script:ReducedMotion) { 1 } else { $Milliseconds }
    $animation.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds($effectiveMilliseconds))
    if ($EaseOut) {
        $easing = New-Object Windows.Media.Animation.CubicEase
        $easing.EasingMode = [Windows.Media.Animation.EasingMode]::EaseOut
        $animation.EasingFunction = $easing
    }
    return $animation
}

function Save-VisualPng {
    param(
        [Windows.FrameworkElement]$Element,
        [string]$Path
    )

    $Element.UpdateLayout()
    $dpi = [Windows.Media.VisualTreeHelper]::GetDpi($Element)
    $pixelWidth = [Math]::Max(1, [int][Math]::Ceiling($Element.ActualWidth * $dpi.DpiScaleX))
    $pixelHeight = [Math]::Max(1, [int][Math]::Ceiling($Element.ActualHeight * $dpi.DpiScaleY))
    $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap(
        $pixelWidth,
        $pixelHeight,
        $dpi.PixelsPerInchX,
        $dpi.PixelsPerInchY,
        [Windows.Media.PixelFormats]::Pbgra32
    )
    $bitmap.Render($Element)

    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write)
    try {
        $encoder.Save($stream)
    }
    finally {
        $stream.Dispose()
    }
}

function Get-SettingsPath {
    return Join-Path (Get-AppDataDirectory) 'settings.json'
}

function Save-Settings {
    if ($isDiagnosticRun) { return }

    try {
        $saveLeft = if ($null -ne $script:CompactAnchorLeft) {
            $script:CompactAnchorLeft
        } else {
            $window.Left
        }
        $saveTop = if ($null -ne $script:CompactAnchorTop) {
            $script:CompactAnchorTop
        } else {
            $window.Top
        }
        [ordered]@{
            Left = $saveLeft
            Top = $saveTop
            Expanded = $false
            Topmost = $window.Topmost
            Provider = $script:ActiveProvider
        } | ConvertTo-Json | Set-Content -LiteralPath (Get-SettingsPath) -Encoding UTF8
    }
    catch {
        # Settings persistence is optional; the widget remains functional without it.
    }
}

function Restore-Settings {
    $workArea = [System.Windows.SystemParameters]::WorkArea
    $window.Width = $script:CompactWidth
    $window.Height = $script:CompactHeight
    $window.Left = $workArea.Right - $script:CompactWidth - 24
    $window.Top = $workArea.Bottom - $script:CompactHeight - 28
    $script:IsExpanded = $false

    try {
        $path = Get-SettingsPath
        if (Test-Path -LiteralPath $path) {
            $settings = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($null -ne $settings.Left -and $null -ne $settings.Top) {
                # Preserve coordinates from secondary monitors. Once the HWND
                # exists, Ensure-WindowVisible clamps them to that monitor.
                $window.Left = [double]$settings.Left
                $window.Top = [double]$settings.Top
            }
            if ($null -ne $settings.Topmost) { $window.Topmost = [bool]$settings.Topmost }
            if (
                $settings.PSObject.Properties['Provider'] -and
                [string]$settings.Provider -in @('Codex', 'DeepSeek')
            ) {
                $script:ActiveProvider = [string]$settings.Provider
            }
        }
    }
    catch {
        $script:IsExpanded = $false
    }

    if ($Demo) {
        $script:ActiveProvider = if ($DemoProvider -eq 'deepseek') { 'DeepSeek' } else { 'Codex' }
    }
}

function Get-WindowWorkArea {
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        if ($helper.Handle -ne [IntPtr]::Zero) {
            $pixelArea = [System.Windows.Forms.Screen]::FromHandle($helper.Handle).WorkingArea
            $source = [System.Windows.PresentationSource]::FromVisual($window)
            if ($source -and $source.CompositionTarget) {
                $transform = $source.CompositionTarget.TransformFromDevice
                $topLeft = $transform.Transform((New-Object Windows.Point($pixelArea.Left, $pixelArea.Top)))
                $bottomRight = $transform.Transform((New-Object Windows.Point($pixelArea.Right, $pixelArea.Bottom)))
                return New-Object Windows.Rect(
                    $topLeft.X,
                    $topLeft.Y,
                    $bottomRight.X - $topLeft.X,
                    $bottomRight.Y - $topLeft.Y
                )
            }
        }
    }
    catch {
        # Fall back to the primary work area if per-monitor lookup is unavailable.
    }
    return [System.Windows.SystemParameters]::WorkArea
}

function Ensure-WindowVisible {
    $workArea = Get-WindowWorkArea
    $fitted = Get-FittedPlacement `
        -AnchorLeft $window.Left `
        -AnchorTop $window.Top `
        -TargetWidth $window.Width `
        -TargetHeight $window.Height `
        -WorkLeft $workArea.Left `
        -WorkTop $workArea.Top `
        -WorkRight $workArea.Right `
        -WorkBottom $workArea.Bottom
    $window.Left = $fitted.Left
    $window.Top = $fitted.Top
}

function Show-ExistingWindow {
    Ensure-WindowVisible
    if ($window.WindowState -ne [Windows.WindowState]::Normal) {
        $window.WindowState = [Windows.WindowState]::Normal
    }

    # Briefly promote the existing instance to the foreground, then restore
    # the user's persisted topmost preference.
    $keepTopmost = $window.Topmost
    $window.Topmost = $true
    $window.Show()
    [void]$window.Activate()
    $window.Topmost = $keepTopmost
}

function Get-ExpandedPlacement {
    $workArea = Get-WindowWorkArea
    $anchorLeft = if ($null -ne $script:CompactAnchorLeft) { $script:CompactAnchorLeft } else { $window.Left }
    $anchorTop = if ($null -ne $script:CompactAnchorTop) { $script:CompactAnchorTop } else { $window.Top }
    return Get-FittedPlacement `
        -AnchorLeft $anchorLeft `
        -AnchorTop $anchorTop `
        -TargetWidth $script:ExpandedWidth `
        -TargetHeight $script:ExpandedHeight `
        -WorkLeft $workArea.Left `
        -WorkTop $workArea.Top `
        -WorkRight $workArea.Right `
        -WorkBottom $workArea.Bottom
}

function Set-ExpandedState {
    param(
        [bool]$Expanded,
        [switch]$Immediate
    )

    if ($Expanded -and -not $script:IsExpanded) {
        $script:CompactAnchorLeft = $window.Left
        $script:CompactAnchorTop = $window.Top
    }
    $script:IsExpanded = $Expanded
    $targetWidth = if ($Expanded) { $script:ExpandedWidth } else { $script:CompactWidth }
    $targetHeight = if ($Expanded) { $script:ExpandedHeight } else { $script:CompactHeight }

    # Width and height are one logical state. Keeping them out of independent
    # WPF animations prevents rapid toggles from settling at 370x88 or 96x500.
    $window.BeginAnimation([Windows.FrameworkElement]::WidthProperty, $null)
    $window.BeginAnimation([Windows.FrameworkElement]::HeightProperty, $null)

    if ($Expanded) {
        $placement = Get-ExpandedPlacement
        $window.Left = $placement.Left
        $window.Top = $placement.Top
        $window.Width = $targetWidth
        $window.Height = $targetHeight
        $DetailsPanel.Visibility = 'Visible'
        $ResetSummaryPanel.Visibility = if (
            $script:LastSnapshot -and
            $script:LastSnapshot.ProviderId -eq 'Codex'
        ) { 'Visible' } else { 'Collapsed' }
        $ExpandedWindowLabel.Visibility = $ResetSummaryPanel.Visibility
        $WindowLabel.Visibility = if ($ResetSummaryPanel.Visibility -eq 'Visible') {
            'Collapsed'
        } else { 'Visible' }
        if ($ResetSummaryPanel.Visibility -eq 'Visible') {
            $CompactHit.Padding = New-Object Windows.Thickness(9, 7, 9, 2)
            $CompactProgressRow.Height = New-Object Windows.GridLength(19)
        }
        if ($Immediate) {
            $DetailsPanel.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
            $DetailsPanel.Opacity = 1
        }
        else {
            $DetailsPanel.Opacity = 0
            $DetailsPanel.BeginAnimation(
                [Windows.UIElement]::OpacityProperty,
                (New-DoubleAnimation -To 1 -Milliseconds 190 -EaseOut)
            )
        }
    }
    else {
        # Remove fixed-height detail content before resizing so layout constraints
        # cannot leave a tall, narrow strip behind.
        $DetailsPanel.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
        $DetailsPanel.Opacity = 0
        $DetailsPanel.Visibility = 'Collapsed'
        $ResetSummaryPanel.Visibility = 'Collapsed'
        $ExpandedWindowLabel.Visibility = 'Collapsed'
        $WindowLabel.Visibility = 'Visible'
        $CompactHit.Padding = New-Object Windows.Thickness(9, 7, 9, 7)
        $CompactProgressRow.Height = New-Object Windows.GridLength(14)
        $window.Width = $targetWidth
        $window.Height = $targetHeight
        if ($null -ne $script:CompactAnchorLeft) {
            $window.Left = $script:CompactAnchorLeft
            $window.Top = $script:CompactAnchorTop
            $script:CompactAnchorLeft = $null
            $script:CompactAnchorTop = $null
        }
    }

    Save-Settings
}

function Collapse-DetailsIfInactive {
    param([switch]$Force)

    if ($script:IsClosing -or -not $script:IsExpanded) { return }

    # A WPF ContextMenu owns a separate popup window and can briefly deactivate
    # its owner. Keep the detail surface open while that menu is being used.
    $surfaceMenu = $Surface.ContextMenu
    if ($surfaceMenu -and $surfaceMenu.IsOpen) { return }
    if (-not $Force -and $window.IsActive) { return }

    Set-ExpandedState -Expanded $false
}

function Request-InactiveDetailsCollapse {
    $window.Dispatcher.BeginInvoke(
        [Windows.Threading.DispatcherPriority]::ContextIdle,
        [Action]{ Collapse-DetailsIfInactive }
    ) | Out-Null
}

function Set-HoverState {
    param([bool]$Hovering)

    $script:IsPointerOverSurface = $Hovering
    $HoverHalo.BeginAnimation(
        [Windows.UIElement]::OpacityProperty,
        (New-DoubleAnimation -To $(if ($Hovering) { 0.46 } else { 0 }) -Milliseconds $(if ($Hovering) { 190 } else { 150 }) -EaseOut)
    )
    $SurfaceShadow.BeginAnimation(
        [Windows.Media.Effects.DropShadowEffect]::OpacityProperty,
        (New-DoubleAnimation -To $(if ($Hovering) { 0.11 } else { 0.07 }) -Milliseconds 180 -EaseOut)
    )
    $Surface.BorderBrush = New-Object Windows.Media.SolidColorBrush(
        [Windows.Media.ColorConverter]::ConvertFromString($(if ($Hovering) {
            $script:CurrentHoverBorderColor
        } else {
            $script:CurrentSurfaceBorderColor
        }))
    )
}

function Get-BlendedColor {
    param(
        [string]$From,
        [string]$To,
        [double]$Amount
    )

    $start = [Windows.Media.ColorConverter]::ConvertFromString($From)
    $end = [Windows.Media.ColorConverter]::ConvertFromString($To)
    $mix = [Math]::Max(0, [Math]::Min(1, $Amount))
    return [Windows.Media.Color]::FromRgb(
        [byte][Math]::Round($start.R + (($end.R - $start.R) * $mix)),
        [byte][Math]::Round($start.G + (($end.G - $start.G) * $mix)),
        [byte][Math]::Round($start.B + (($end.B - $start.B) * $mix))
    )
}

function Get-UsageStatusPalette {
    param(
        [double]$Percent,
        [bool]$Available
    )

    if (-not $Available) {
        return [pscustomobject]@{
            Accent = [Windows.Media.ColorConverter]::ConvertFromString('#89908C')
            Strong = [Windows.Media.ColorConverter]::ConvertFromString('#5B625E')
            Soft = [Windows.Media.ColorConverter]::ConvertFromString('#F1F2EF')
            Border = [Windows.Media.ColorConverter]::ConvertFromString('#E0E3DE')
            HoverBorder = '#CED2CE'
        }
    }

    $remaining = [Math]::Max(0, [Math]::Min(100, $Percent))
    if ($remaining -le 50) {
        $amount = $remaining / 50
        $from = @{
            Accent = '#A4736F'
            Strong = '#704E4C'
            Soft = '#F4ECEB'
            Border = '#E5D6D4'
            HoverBorder = '#D4B8B5'
        }
        $to = @{
            Accent = '#9A8968'
            Strong = '#655B47'
            Soft = '#F3F0E9'
            Border = '#E3DDCF'
            HoverBorder = '#D1C6AE'
        }
    }
    else {
        $amount = ($remaining - 50) / 50
        $from = @{
            Accent = '#9A8968'
            Strong = '#655B47'
            Soft = '#F3F0E9'
            Border = '#E3DDCF'
            HoverBorder = '#D1C6AE'
        }
        $to = @{
            Accent = '#718478'
            Strong = '#46564C'
            Soft = '#EEF1ED'
            Border = '#DCE3DD'
            HoverBorder = '#C4D0C6'
        }
    }

    return [pscustomobject]@{
        Accent = Get-BlendedColor -From $from.Accent -To $to.Accent -Amount $amount
        Strong = Get-BlendedColor -From $from.Strong -To $to.Strong -Amount $amount
        Soft = Get-BlendedColor -From $from.Soft -To $to.Soft -Amount $amount
        Border = Get-BlendedColor -From $from.Border -To $to.Border -Amount $amount
        HoverBorder = (Get-BlendedColor -From $from.HoverBorder -To $to.HoverBorder -Amount $amount).ToString()
    }
}

function Set-UsageStatusPalette {
    param(
        [double]$Percent,
        [bool]$Available
    )

    $palette = Get-UsageStatusPalette -Percent $Percent -Available $Available
    ([Windows.Media.SolidColorBrush]$window.Resources['Sage']).Color = $palette.Accent
    ([Windows.Media.SolidColorBrush]$window.Resources['StatusStrong']).Color = $palette.Strong
    ([Windows.Media.SolidColorBrush]$window.Resources['SageSoft']).Color = $palette.Soft
    ([Windows.Media.SolidColorBrush]$window.Resources['StatusBorder']).Color = $palette.Border
    $script:CurrentHoverBorderColor = $palette.HoverBorder

    if ($script:IsPointerOverSurface) {
        $Surface.BorderBrush = New-Object Windows.Media.SolidColorBrush(
            [Windows.Media.ColorConverter]::ConvertFromString($script:CurrentHoverBorderColor)
        )
    }
}

function Set-Progress {
    param(
        [double]$Percent,
        [bool]$Available = $true
    )

    $remaining = if ($Available) {
        [Math]::Max(0, [Math]::Min(100, $Percent))
    } else { 0 }
    $used = 100 - $remaining
    $RemainingProgressColumn.Width = New-Object Windows.GridLength(
        $remaining,
        [Windows.GridUnitType]::Star
    )
    $UsedProgressColumn.Width = New-Object Windows.GridLength(
        $used,
        [Windows.GridUnitType]::Star
    )
    $ProgressTrack.ToolTip = if ($Available) {
        '剩余 {0:0}% · 已使用 {1:0}%' -f $remaining, $used
    } else {
        '设置预算基准后显示百分比进度'
    }
    Set-UsageStatusPalette -Percent $remaining -Available $Available
}

function Format-CompactBalance {
    param([double]$Amount)

    if ($Amount -ge 1000000) { return '{0:0.0}M' -f ($Amount / 1000000) }
    if ($Amount -ge 1000) { return '{0:0.0}K' -f ($Amount / 1000) }
    if ($Amount -ge 100) { return '{0:0}' -f $Amount }
    return '{0:0.0}' -f $Amount
}

function Update-UsageView {
    param($Snapshot)

    $script:LastSnapshot = $Snapshot
    $WindowLabel.Text = $Snapshot.WindowLabel
    $ExpandedWindowLabel.Text = $Snapshot.WindowLabel
    $DetailsResetDate.Text = $Snapshot.ResetDate
    $DetailsResetCountdown.Text = $Snapshot.ResetCountdown
    $AccountName.Text = $Snapshot.AccountName
    $PlanBadge.Text = $Snapshot.Plan
    $AccountEmail.Text = $Snapshot.AccountEmail
    $SourceText.Text = $Snapshot.Source
    $SampleTime.Text = '采样于 {0}' -f $Snapshot.SampledAt.ToString('M月d日 HH:mm:ss')
    $ResetSummaryPanel.Visibility = if (
        $script:IsExpanded -and $Snapshot.ProviderId -eq 'Codex'
    ) { 'Visible' } else { 'Collapsed' }
    $ExpandedWindowLabel.Visibility = $ResetSummaryPanel.Visibility
    $WindowLabel.Visibility = if ($ResetSummaryPanel.Visibility -eq 'Visible') {
        'Collapsed'
    } else { 'Visible' }
    if ($ResetSummaryPanel.Visibility -eq 'Visible') {
        $CompactHit.Padding = New-Object Windows.Thickness(9, 7, 9, 2)
        $CompactProgressRow.Height = New-Object Windows.GridLength(19)
    }
    else {
        $CompactHit.Padding = New-Object Windows.Thickness(9, 7, 9, 7)
        $CompactProgressRow.Height = New-Object Windows.GridLength(14)
    }

    if ($Snapshot.ProviderId -eq 'DeepSeek') {
        if ($Snapshot.HasProgress) {
            $CompactPrefix.Text = ''
            $RemainingValue.Text = [string][int]$Snapshot.RemainingPercent
            $CompactSuffix.Text = '%'
        }
        elseif ($Snapshot.Available) {
            $CompactPrefix.Text = if ($Snapshot.Currency -eq 'USD') { '$' } else { '¥' }
            $RemainingValue.Text = Format-CompactBalance -Amount $Snapshot.TotalBalance
            $CompactSuffix.Text = ''
        }
        else {
            $CompactPrefix.Text = ''
            $RemainingValue.Text = '--'
            $CompactSuffix.Text = ''
        }

        $MetricOneTitle.Text = '当前余额'
        $PrimaryMetricValue.Text = $Snapshot.ResetDate
        $PrimaryMetricHint.Text = $Snapshot.ResetCountdown
        $MetricTwoTitle.Text = '本月累计花费'
        $TodayTokens.Text = Format-CurrencyAmount `
            -Amount $Snapshot.MonthlyEstimatedCostCny `
            -Currency 'CNY'
        $MetricTwoHint.Text = '本机日志估算'
        $MetricThreeTitle.Text = '今日 TOKEN'
        $LastTurnTokens.Text = Format-CompactNumber $Snapshot.TodayTokens
        $ContextText.Text = 'Claude Code 本机累计'
        $MetricFourTitle.Text = '本月累计 TOKEN'
        $CacheHit.Text = Format-CompactNumber $Snapshot.MonthlyTokens
        $CacheTokenText.Text = '当月本机去重累计'
        $BreakdownTitle.Text = '余额构成'
        $SecondaryMetricTitle.Text = '预算基准'
        $ResetCount.Text = $Snapshot.ResetCount
        $TokenBreakdown.Text = '赠金 {0}  ·  充值 {1}' -f `
            (Format-CurrencyAmount -Amount $Snapshot.GrantedBalance -Currency $Snapshot.Currency), `
            (Format-CurrencyAmount -Amount $Snapshot.ToppedUpBalance -Currency $Snapshot.Currency)
        Set-Progress -Percent $Snapshot.RemainingPercent -Available $Snapshot.HasProgress
    }
    else {
        $CompactPrefix.Text = ''
        $RemainingValue.Text = [string][int]$Snapshot.RemainingPercent
        $CompactSuffix.Text = '%'
        $MetricOneTitle.Text = '已用额度'
        $PrimaryMetricValue.Text = '{0:0}%' -f (100 - $Snapshot.RemainingPercent)
        $PrimaryMetricHint.Text = '剩余 {0:0}%' -f $Snapshot.RemainingPercent
        $MetricTwoTitle.Text = '今日 TOKEN'
        $TodayTokens.Text = Format-CompactNumber $Snapshot.TodayTokens
        $MetricTwoHint.Text = '本机任务累计'
        $MetricThreeTitle.Text = '今日缓存'
        $LastTurnTokens.Text = Format-CompactNumber $Snapshot.TodayCachedTokens
        $ContextText.Text = '命中 {0:0.0}%' -f $Snapshot.TodayCacheHitPercent
        $MetricFourTitle.Text = '今日输出'
        $CacheHit.Text = Format-CompactNumber $Snapshot.TodayOutputTokens
        $CacheTokenText.Text = '所有本机任务'
        $BreakdownTitle.Text = '统计口径'
        $TokenBreakdown.Text = '本机今日全部任务'
        $SecondaryMetricTitle.Text = '额度状态'
        $ResetCount.Text = $Snapshot.Status
        Set-Progress -Percent $Snapshot.RemainingPercent
    }

    if ($script:TrayNotifyIcon) {
        $script:TrayNotifyIcon.Text = if ($Snapshot.ProviderId -eq 'DeepSeek') {
            if ($Snapshot.Available) {
                'DeepSeek 余额 {0} · 单击打开详情' -f $Snapshot.ResetDate
            } else {
                'DeepSeek 等待配置 · 单击打开详情'
            }
        } else {
            'Codex 余量 {0}% · 单击打开详情' -f [int]$Snapshot.RemainingPercent
        }
    }

    $script:RefreshRemaining = $script:RefreshIntervalSeconds
}

function Set-RefreshBusy {
    param([bool]$Busy)

    $script:IsRefreshing = $Busy
    $RefreshButton.IsEnabled = -not $Busy
    $RefreshButton.Content = if ($Busy) { '读取中…' } else { '立即刷新' }
}

function Get-DeepSeekHttpClient {
    if (-not $script:DeepSeekHttpClient) {
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(8)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('RemainingMarginFloat/1.1.2')
        $script:DeepSeekHttpClient = $client
    }
    return $script:DeepSeekHttpClient
}

function Cancel-DeepSeekRefresh {
    if ($script:DeepSeekRequestTask -and -not $script:DeepSeekRequestTask.IsCompleted) {
        if ($script:DeepSeekHttpClient) {
            $script:DeepSeekHttpClient.CancelPendingRequests()
        }
    }
    elseif (
        $script:DeepSeekRequestTask -and
        -not $script:DeepSeekRequestTask.IsCanceled -and
        -not $script:DeepSeekRequestTask.IsFaulted
    ) {
        $abandonedResponse = $script:DeepSeekRequestTask.GetAwaiter().GetResult()
        if ($abandonedResponse) { $abandonedResponse.Dispose() }
    }
    if ($script:DeepSeekRequest) {
        $script:DeepSeekRequest.Dispose()
    }
    $script:DeepSeekRequest = $null
    $script:DeepSeekRequestTask = $null
    Set-RefreshBusy -Busy $false
}

function Start-DeepSeekRefresh {
    if ($Demo) {
        $snapshot = Get-DeepSeekDemoSnapshot
        $script:LastDeepSeekSnapshot = $snapshot
        Update-UsageView -Snapshot $snapshot
        Set-RefreshBusy -Busy $false
        return
    }

    $credential = Get-DeepSeekCredential
    if ([string]::IsNullOrWhiteSpace($credential.ApiKey)) {
        Update-UsageView -Snapshot (Get-DeepSeekUnavailableSnapshot)
        Set-RefreshBusy -Busy $false
        return
    }

    $request = $null
    try {
        $request = New-Object System.Net.Http.HttpRequestMessage(
            [System.Net.Http.HttpMethod]::Get,
            'https://api.deepseek.com/user/balance'
        )
        $request.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue(
            'Bearer',
            $credential.ApiKey
        )
        $script:DeepSeekRequest = $request
        $script:DeepSeekRequestTask = (Get-DeepSeekHttpClient).SendAsync($request)
    }
    catch {
        if ($request) { $request.Dispose() }
        $script:DeepSeekRequest = $null
        $script:DeepSeekRequestTask = $null
        Set-RefreshBusy -Busy $false
        $SourceText.Text = 'DeepSeek 请求未能启动：' + $_.Exception.Message
    }
}

function Complete-DeepSeekRefresh {
    if (-not $script:DeepSeekRequestTask -or -not $script:DeepSeekRequestTask.IsCompleted) {
        return
    }

    $task = $script:DeepSeekRequestTask
    $request = $script:DeepSeekRequest
    $script:DeepSeekRequestTask = $null
    $script:DeepSeekRequest = $null
    $response = $null
    try {
        if ($task.IsCanceled) { throw 'DeepSeek 请求超时，请稍后重试。' }
        if ($task.IsFaulted) {
            throw ($task.Exception.GetBaseException().Message)
        }

        $response = $task.GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            $message = switch ([int]$response.StatusCode) {
                401 { 'API Key 无效或已失效，请重新配置。' }
                402 { 'DeepSeek 余额不足，请充值后重试。' }
                429 { '请求过于频繁，稍后会自动重试。' }
                500 { 'DeepSeek 服务暂时异常，稍后会自动重试。' }
                503 { 'DeepSeek 服务繁忙，稍后会自动重试。' }
                default { 'DeepSeek 返回 HTTP {0}。' -f [int]$response.StatusCode }
            }
            throw $message
        }

        $payload = $body | ConvertFrom-Json
        $configuration = Get-DeepSeekConfiguration
        $credential = Get-DeepSeekCredential
        $snapshot = ConvertTo-DeepSeekSnapshot `
            -BalancePayload $payload `
            -LocalUsage (Get-DeepSeekLocalUsage) `
            -Budget $configuration.Budget `
            -KeyHint $credential.Hint `
            -CredentialSource $credential.Source
        $script:LastDeepSeekSnapshot = $snapshot
        if ($script:ActiveProvider -eq 'DeepSeek') {
            Update-UsageView -Snapshot $snapshot
        }
    }
    catch {
        if ($script:LastDeepSeekSnapshot -and $script:ActiveProvider -eq 'DeepSeek') {
            Update-UsageView -Snapshot $script:LastDeepSeekSnapshot
            $SourceText.Text = '刷新失败，显示上次数据 · ' + $_.Exception.Message
        }
        elseif ($script:ActiveProvider -eq 'DeepSeek') {
            Update-UsageView -Snapshot (Get-DeepSeekUnavailableSnapshot -Reason $_.Exception.Message)
        }
    }
    finally {
        if ($response) { $response.Dispose() }
        if ($request) { $request.Dispose() }
        Set-RefreshBusy -Busy $false
        $script:RefreshRemaining = $script:RefreshIntervalSeconds
    }
}

function Sync-ProviderMenuState {
    if ($script:CodexSourceMenuItem) {
        $script:CodexSourceMenuItem.IsChecked = $script:ActiveProvider -eq 'Codex'
    }
    if ($script:DeepSeekSourceMenuItem) {
        $script:DeepSeekSourceMenuItem.IsChecked = $script:ActiveProvider -eq 'DeepSeek'
    }
    if ($script:TrayCodexSourceItem) {
        $script:TrayCodexSourceItem.Checked = $script:ActiveProvider -eq 'Codex'
    }
    if ($script:TrayDeepSeekSourceItem) {
        $script:TrayDeepSeekSourceItem.Checked = $script:ActiveProvider -eq 'DeepSeek'
    }
    if ($script:DeepSeekSettingsMenuItem) {
        $script:DeepSeekSettingsMenuItem.Visibility = if (
            $script:ActiveProvider -eq 'DeepSeek'
        ) { 'Visible' } else { 'Collapsed' }
    }
    if ($script:TrayDeepSeekSettingsItem) {
        $script:TrayDeepSeekSettingsItem.Visible = $script:ActiveProvider -eq 'DeepSeek'
    }
}

function Set-ActiveProvider {
    param(
        [ValidateSet('Codex', 'DeepSeek')]
        [string]$Provider,
        [switch]$Refresh
    )

    if ($script:ActiveProvider -ne $Provider -and $script:DeepSeekRequestTask) {
        Cancel-DeepSeekRefresh
    }
    $script:ActiveProvider = $Provider
    Sync-ProviderMenuState
    Save-Settings
    if ($Refresh) { Invoke-Refresh }
}

function Show-DeepSeekSettings {
    $configuration = Get-DeepSeekConfiguration
    $credential = Get-DeepSeekCredential
    [xml]$dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DeepSeek 设置"
        Width="430"
        Height="350"
        ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner"
        ShowInTaskbar="False"
        Background="#FCFBF8"
        FontFamily="Microsoft YaHei UI">
    <Grid x:Name="SettingsRoot" Background="#FCFBF8">
      <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="22"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="18"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="38"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="连接 DeepSeek 官方余额" FontSize="18" FontWeight="SemiBold" Foreground="#343A35"/>
        <StackPanel Grid.Row="2">
            <TextBlock Text="API Key" FontSize="12" FontWeight="SemiBold" Foreground="#4E5750"/>
            <PasswordBox x:Name="ApiKeyBox" Height="34" Margin="0,7,0,0" Padding="9,6"
                         BorderBrush="#D8DDD7" Background="White"
                         AutomationProperties.Name="DeepSeek API Key"/>
            <TextBlock x:Name="KeyHelp" Margin="0,6,0,0" FontSize="10" Foreground="#7B847D" TextWrapping="Wrap"/>
            <CheckBox x:Name="RemoveKeyBox" Margin="0,8,0,0" Content="清除已保存的 API Key"
                      Foreground="#6B746D" FontSize="11"/>
        </StackPanel>
        <StackPanel Grid.Row="5">
            <TextBlock Text="预算基准（可选）" FontSize="12" FontWeight="SemiBold" Foreground="#4E5750"/>
            <TextBox x:Name="BudgetBox" Height="34" Margin="0,7,0,0" Padding="9,6"
                     BorderBrush="#D8DDD7" Background="White"
                     AutomationProperties.Name="预算基准"/>
            <TextBlock Margin="0,6,0,0" FontSize="10" Foreground="#7B847D"
                       Text="设置后，小窗显示当前余额相对该金额的百分比；留空则直接显示余额。"/>
        </StackPanel>
        <TextBlock x:Name="ErrorText" Grid.Row="7" Margin="0,8,0,0"
                   Foreground="#A65B52" FontSize="11" TextWrapping="Wrap"/>
        <Grid Grid.Row="8">
            <Button x:Name="CancelButton" Width="82" Height="34" HorizontalAlignment="Right"
                    Margin="0,0,92,0" Content="取消" IsCancel="True"/>
            <Button x:Name="SaveButton" Width="82" Height="34" HorizontalAlignment="Right"
                    Content="保存" IsDefault="True" Background="#E9F0EA"
                    BorderBrush="#BFCDBF" Foreground="#344A3B"/>
        </Grid>
      </Grid>
    </Grid>
</Window>
'@
    $dialogReader = New-Object System.Xml.XmlNodeReader $dialogXaml
    $dialog = [Windows.Markup.XamlReader]::Load($dialogReader)
    $dialog.Owner = $window
    $apiKeyBox = $dialog.FindName('ApiKeyBox')
    $keyHelp = $dialog.FindName('KeyHelp')
    $removeKeyBox = $dialog.FindName('RemoveKeyBox')
    $budgetBox = $dialog.FindName('BudgetBox')
    $errorText = $dialog.FindName('ErrorText')
    $saveButton = $dialog.FindName('SaveButton')

    if ($configuration.Budget -gt 0) {
        $budgetBox.Text = $configuration.Budget.ToString('0.##', [Globalization.CultureInfo]::CurrentCulture)
    }
    if ($credential.Source -eq '环境变量') {
        $keyHelp.Text = '当前由 DEEPSEEK_API_KEY 环境变量提供（••••{0}），环境变量优先。' -f $credential.Hint
        $apiKeyBox.IsEnabled = $false
        $removeKeyBox.IsEnabled = $false
    }
    elseif ($credential.ApiKey) {
        $keyHelp.Text = '已通过 Windows DPAPI 安全保存（••••{0}）。留空会保留原密钥。' -f $credential.Hint
    }
    else {
        $keyHelp.Text = '密钥仅加密保存在当前 Windows 用户下，不会写入日志或仓库。'
        $removeKeyBox.IsEnabled = $false
    }

    $saveButton.Add_Click({
        $errorText.Text = ''
        $budget = 0.0
        $budgetText = $budgetBox.Text.Trim()
        if ($budgetText) {
            $parsed = [double]::TryParse(
                $budgetText,
                [Globalization.NumberStyles]::Number,
                [Globalization.CultureInfo]::CurrentCulture,
                [ref]$budget
            )
            if (-not $parsed) {
                $parsed = [double]::TryParse(
                    $budgetText,
                    [Globalization.NumberStyles]::Number,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [ref]$budget
                )
            }
            if (-not $parsed -or $budget -le 0) {
                $errorText.Text = '预算基准需要是大于 0 的数字，或留空不设置。'
                $budgetBox.Focus() | Out-Null
                return
            }
        }

        $newKey = $apiKeyBox.Password.Trim()
        if (
            $credential.Source -ne '环境变量' -and
            -not $removeKeyBox.IsChecked -and
            -not $credential.ApiKey -and
            [string]::IsNullOrWhiteSpace($newKey)
        ) {
            $errorText.Text = '请输入 DeepSeek API Key。'
            $apiKeyBox.Focus() | Out-Null
            return
        }
        if ($newKey -and $newKey.Length -lt 10) {
            $errorText.Text = 'API Key 长度看起来不正确，请检查后重试。'
            $apiKeyBox.Focus() | Out-Null
            return
        }

        try {
            Save-DeepSeekConfiguration `
                -ApiKey $newKey `
                -Budget $budget `
                -RemoveKey:$removeKeyBox.IsChecked
            $dialog.DialogResult = $true
        }
        catch {
            $errorText.Text = '保存失败：' + $_.Exception.Message
        }
    })

    $saved = $dialog.ShowDialog()
    if ($saved) {
        $script:LastDeepSeekSnapshot = $null
        Set-ActiveProvider -Provider 'DeepSeek' -Refresh
        return $true
    }
    return $false
}

function Invoke-Refresh {
    if ($script:IsRefreshing) { return }
    Set-RefreshBusy -Busy $true
    if ($script:ActiveProvider -eq 'DeepSeek') {
        Start-DeepSeekRefresh
        return
    }

    try {
        Update-UsageView -Snapshot (Get-CodexUsageSnapshot)
    }
    catch {
        $WindowLabel.Text = '读取失败'
        $SourceText.Text = '无法读取本地用量：' + $_.Exception.Message
    }
    finally {
        Set-RefreshBusy -Busy $false
    }
}

Restore-Settings
Set-ExpandedState -Expanded $script:IsExpanded -Immediate

$script:RefreshRemaining = $script:RefreshIntervalSeconds
$script:IsRefreshing = $false
$script:InitialRefreshQueued = $false
$script:MouseDownPoint = $null
$script:Dragging = $false

if (-not $CheckTransitions) {
    $window.Add_Loaded({
        Ensure-WindowVisible
        $window.Activate() | Out-Null
    })
    $window.Add_ContentRendered({
        if (-not $script:InitialRefreshQueued) {
            $script:InitialRefreshQueued = $true
            $window.Dispatcher.BeginInvoke(
                [Windows.Threading.DispatcherPriority]::Background,
                [Action]{ Invoke-Refresh }
            ) | Out-Null
        }
    })
}

$window.Add_MouseEnter({ Set-HoverState -Hovering $true })
$window.Add_MouseLeave({ Set-HoverState -Hovering $false })

$CompactHit.Add_PreviewMouseLeftButtonDown({
    param($sender, $eventArgs)
    $script:MouseDownPoint = $eventArgs.GetPosition($window)
    $script:Dragging = $false
    $CompactHit.CaptureMouse() | Out-Null
})

$CompactHit.Add_PreviewMouseMove({
    param($sender, $eventArgs)
    if (-not $script:IsExpanded -and $script:MouseDownPoint -and $eventArgs.LeftButton -eq [Windows.Input.MouseButtonState]::Pressed) {
        $point = $eventArgs.GetPosition($window)
        $distance = [Math]::Abs($point.X - $script:MouseDownPoint.X) + [Math]::Abs($point.Y - $script:MouseDownPoint.Y)
        if ($distance -gt 5) {
            $script:Dragging = $true
            $CompactHit.ReleaseMouseCapture()
            try { $window.DragMove() } catch {}
            Save-Settings
            $script:MouseDownPoint = $null
        }
    }
})

$CompactHit.Add_PreviewMouseLeftButtonUp({
    $CompactHit.ReleaseMouseCapture()
    if (-not $script:Dragging -and $script:MouseDownPoint) {
        Set-ExpandedState -Expanded (-not $script:IsExpanded)
    }
    $script:MouseDownPoint = $null
    $script:Dragging = $false
})

$CompactHit.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [Windows.Input.Key]::Enter -or $eventArgs.Key -eq [Windows.Input.Key]::Space) {
        Set-ExpandedState -Expanded (-not $script:IsExpanded)
        $eventArgs.Handled = $true
    }
})

$window.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [Windows.Input.Key]::Escape -and $script:IsExpanded) {
        Set-ExpandedState -Expanded $false
        $eventArgs.Handled = $true
    }
    elseif (
        $eventArgs.Key -eq [Windows.Input.Key]::R -and
        ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control)
    ) {
        Invoke-Refresh
        $eventArgs.Handled = $true
    }
})

$RefreshButton.Add_Click({ Invoke-Refresh })
$CloseButton.Add_Click({ Set-ExpandedState -Expanded $false })

$contextMenu = New-Object Windows.Controls.ContextMenu
$refreshMenu = New-Object Windows.Controls.MenuItem
$refreshMenu.Header = '立即刷新'
$refreshMenu.Add_Click({ Invoke-Refresh })
$sourceMenu = New-Object Windows.Controls.MenuItem
$sourceMenu.Header = '数据源'
$script:CodexSourceMenuItem = New-Object Windows.Controls.MenuItem
$script:CodexSourceMenuItem.Header = 'Codex'
$script:CodexSourceMenuItem.IsCheckable = $true
$script:CodexSourceMenuItem.Add_Click({
    Set-ActiveProvider -Provider 'Codex' -Refresh
})
$script:DeepSeekSourceMenuItem = New-Object Windows.Controls.MenuItem
$script:DeepSeekSourceMenuItem.Header = 'DeepSeek'
$script:DeepSeekSourceMenuItem.IsCheckable = $true
$script:DeepSeekSourceMenuItem.Add_Click({
    Set-ActiveProvider -Provider 'DeepSeek'
    $credential = Get-DeepSeekCredential
    if ($credential.ApiKey) {
        Invoke-Refresh
    }
    else {
        $saved = Show-DeepSeekSettings
        if (-not $saved) { Invoke-Refresh }
        Sync-ProviderMenuState
    }
})
[void]$sourceMenu.Items.Add($script:CodexSourceMenuItem)
[void]$sourceMenu.Items.Add($script:DeepSeekSourceMenuItem)
$script:DeepSeekSettingsMenuItem = New-Object Windows.Controls.MenuItem
$script:DeepSeekSettingsMenuItem.Header = 'DeepSeek 设置…'
$script:DeepSeekSettingsMenuItem.Add_Click({ [void](Show-DeepSeekSettings) })
$topmostMenu = New-Object Windows.Controls.MenuItem
$topmostMenu.Header = '始终置顶'
$topmostMenu.IsCheckable = $true
$topmostMenu.IsChecked = $window.Topmost
$topmostMenu.Add_Click({
    $window.Topmost = $topmostMenu.IsChecked
    if ($script:TrayTopmostItem) {
        $script:TrayTopmostItem.Checked = $window.Topmost
    }
    Save-Settings
})
$resetPositionMenu = New-Object Windows.Controls.MenuItem
$resetPositionMenu.Header = '重置位置'
$resetPositionMenu.Add_Click({
    $workArea = Get-WindowWorkArea
    $resetLeft = $workArea.Right - $script:CompactWidth - 24
    $resetTop = $workArea.Bottom - $script:CompactHeight - 28
    if ($script:IsExpanded) {
        $script:CompactAnchorLeft = $resetLeft
        $script:CompactAnchorTop = $resetTop
        $placement = Get-ExpandedPlacement
        $window.Left = $placement.Left
        $window.Top = $placement.Top
    }
    else {
        $window.Left = $resetLeft
        $window.Top = $resetTop
    }
    Save-Settings
})
$separator = New-Object Windows.Controls.Separator
$exitMenu = New-Object Windows.Controls.MenuItem
$exitMenu.Header = '退出'
$exitMenu.Add_Click({ Save-Settings; $window.Close() })
[void]$contextMenu.Items.Add($refreshMenu)
[void]$contextMenu.Items.Add($sourceMenu)
[void]$contextMenu.Items.Add($script:DeepSeekSettingsMenuItem)
[void]$contextMenu.Items.Add($topmostMenu)
[void]$contextMenu.Items.Add($resetPositionMenu)
[void]$contextMenu.Items.Add($separator)
[void]$contextMenu.Items.Add($exitMenu)
$Surface.ContextMenu = $contextMenu
$contextMenu.Add_Closed({ Request-InactiveDetailsCollapse })

$window.Add_Deactivated({
    # Wait until popup/focus routing has settled. This distinguishes a real
    # click-away from the transient deactivation caused by the context menu.
    Request-InactiveDetailsCollapse
})

if ($CaptureVisuals) {
    if ([string]::IsNullOrWhiteSpace($CaptureDirectory)) {
        throw 'CaptureDirectory is required when CaptureVisuals is enabled.'
    }

    function Wait-ForCaptureUi {
        param([int]$Milliseconds)

        $frame = New-Object Windows.Threading.DispatcherFrame
        $captureTimer = New-Object Windows.Threading.DispatcherTimer
        $captureTimer.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
        $captureTimer.Add_Tick({
            $captureTimer.Stop()
            $frame.Continue = $false
        })
        $captureTimer.Start()
        [Windows.Threading.Dispatcher]::PushFrame($frame)
    }

    $captureRoot = [IO.Path]::GetFullPath($CaptureDirectory)
    [void][IO.Directory]::CreateDirectory($captureRoot)
    $window.ShowInTaskbar = $false
    $window.Left = 24
    $window.Top = 24
    $window.Show()
    Wait-ForCaptureUi -Milliseconds 80

    $previewSnapshot = Get-DeepSeekDemoSnapshot
    Update-UsageView -Snapshot $previewSnapshot
    Set-ExpandedState -Expanded $false -Immediate

    $captureFiles = [ordered]@{}
    foreach ($state in @(
        [pscustomobject]@{ Name = 'compact-high'; Percent = 82 },
        [pscustomobject]@{ Name = 'compact-mid'; Percent = 50 },
        [pscustomobject]@{ Name = 'compact-low'; Percent = 18 }
    )) {
        $RemainingValue.Text = [string]$state.Percent
        $CompactPrefix.Text = ''
        $CompactSuffix.Text = '%'
        Set-Progress -Percent $state.Percent
        Wait-ForCaptureUi -Milliseconds 40
        $capturePath = Join-Path $captureRoot ($state.Name + '.png')
        Save-VisualPng -Element $window -Path $capturePath
        $captureFiles[$state.Name] = $capturePath
    }

    $balancePreviewSnapshot = Get-DeepSeekDemoSnapshot
    $balancePreviewSnapshot.HasProgress = $false
    $balancePreviewSnapshot.WindowLabel = '余额'
    Update-UsageView -Snapshot $balancePreviewSnapshot
    Set-ExpandedState -Expanded $false -Immediate
    Wait-ForCaptureUi -Milliseconds 40
    $compactBalancePath = Join-Path $captureRoot 'compact-balance.png'
    Save-VisualPng -Element $window -Path $compactBalancePath
    $captureFiles['compact-balance'] = $compactBalancePath

    Update-UsageView -Snapshot $previewSnapshot
    Set-ExpandedState -Expanded $true -Immediate
    Wait-ForCaptureUi -Milliseconds 60
    $expandedPath = Join-Path $captureRoot 'expanded-high.png'
    Save-VisualPng -Element $window -Path $expandedPath
    $captureFiles['expanded-high'] = $expandedPath

    $RemainingValue.Text = '18'
    $PrimaryMetricValue.Text = '82%'
    $PrimaryMetricHint.Text = '剩余 18%'
    Set-Progress -Percent 18
    Wait-ForCaptureUi -Milliseconds 40
    $expandedLowPath = Join-Path $captureRoot 'expanded-low.png'
    Save-VisualPng -Element $window -Path $expandedLowPath
    $captureFiles['expanded-low'] = $expandedLowPath

    $codexPreviewSnapshot = [pscustomobject]@{
        ProviderId = 'Codex'
        RemainingPercent = 68
        WindowLabel = '本周余量'
        ResetDate = '8月1日 08:00'
        ResetCountdown = '4 天 15 小时后'
        ResetCount = '状态正常'
        Plan = 'Plus'
        AccountName = '本地 Codex'
        AccountEmail = '本机账户信息'
        TodayTokens = 382640
        TodayInputTokens = 301280
        TodayOutputTokens = 81360
        TodayCachedTokens = 245800
        TodayCacheHitPercent = 64.2
        SampledAt = Get-Date
        Status = '额度充足'
        Source = 'Codex 本地会话快照'
    }
    Update-UsageView -Snapshot $codexPreviewSnapshot
    Set-ExpandedState -Expanded $true -Immediate
    Wait-ForCaptureUi -Milliseconds 40
    $expandedCodexPath = Join-Path $captureRoot 'expanded-codex.png'
    Save-VisualPng -Element $window -Path $expandedCodexPath
    $captureFiles['expanded-codex'] = $expandedCodexPath

    $window.Close()
    [pscustomobject]$captureFiles | ConvertTo-Json
    exit 0
}

if ($CheckTransitions) {
    function Wait-ForUi {
        param([int]$Milliseconds)

        $frame = New-Object Windows.Threading.DispatcherFrame
        $transitionTimer = New-Object Windows.Threading.DispatcherTimer
        $transitionTimer.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
        $transitionTimer.Add_Tick({
            $transitionTimer.Stop()
            $frame.Continue = $false
        })
        $transitionTimer.Start()
        [Windows.Threading.Dispatcher]::PushFrame($frame)
    }

    $window.Opacity = 0
    $window.Left = 1812
    $window.Top = 980
    $window.Show()
    Wait-ForUi -Milliseconds 50
    $extendedStyle = Get-WindowExtendedStyle
    $taskViewHidden = (
        ($extendedStyle -band 0x00000080) -ne 0 -and
        ($extendedStyle -band 0x00040000) -eq 0
    )
    $testTrayIcon = New-TrayAppIcon
    $trayIconWidth = $testTrayIcon.Width
    $trayIconHeight = $testTrayIcon.Height
    $testTrayIcon.Dispose()
    Set-Progress -Percent 140
    $upperClampedRemaining = $RemainingProgressColumn.Width.Value
    $upperClampedUsed = $UsedProgressColumn.Width.Value
    Set-Progress -Percent -20
    $lowerClampedRemaining = $RemainingProgressColumn.Width.Value
    $lowerClampedUsed = $UsedProgressColumn.Width.Value
    $script:ActiveProvider = 'Codex'
    Sync-ProviderMenuState
    $codexSettingsVisibility = [string]$script:DeepSeekSettingsMenuItem.Visibility
    $script:ActiveProvider = 'DeepSeek'
    Sync-ProviderMenuState
    $deepSeekSettingsVisibility = [string]$script:DeepSeekSettingsMenuItem.Visibility
    $deepSeekCheckSnapshot = Get-DeepSeekDemoSnapshot
    Update-UsageView -Snapshot $deepSeekCheckSnapshot
    $deepSeekCompactValue = $RemainingValue.Text
    $deepSeekCompactSuffix = $CompactSuffix.Text
    $deepSeekLabel = $WindowLabel.Text
    $deepSeekBalanceText = $PrimaryMetricValue.Text
    $deepSeekMetricTitle = $MetricOneTitle.Text
    $deepSeekMonthlyCostValue = $TodayTokens.Text
    $deepSeekTodayTokenValue = $LastTurnTokens.Text
    $deepSeekMonthlyTokenValue = $CacheHit.Text
    $deepSeekProgressRemaining = $RemainingProgressColumn.Width.Value
    $deepSeekProgressUsed = $UsedProgressColumn.Width.Value
    $deepSeekCheckSnapshot.HasProgress = $false
    $deepSeekCheckSnapshot.WindowLabel = '余额'
    Update-UsageView -Snapshot $deepSeekCheckSnapshot
    $deepSeekBalanceCompactValue = $RemainingValue.Text
    $deepSeekBalanceCompactSuffix = $CompactSuffix.Text
    $deepSeekBalanceCompactLabel = $WindowLabel.Text
    $deepSeekNoBudgetProgressRemaining = $RemainingProgressColumn.Width.Value
    $deepSeekNoBudgetProgressUsed = $UsedProgressColumn.Width.Value
    $metricValueFontFamilies = @(
        $PrimaryMetricValue.FontFamily.Source
        $TodayTokens.FontFamily.Source
        $LastTurnTokens.FontFamily.Source
        $CacheHit.FontFamily.Source
    )
    $metricValueFontSizes = @(
        $PrimaryMetricValue.FontSize
        $TodayTokens.FontSize
        $LastTurnTokens.FontSize
        $CacheHit.FontSize
    )
    $metricValueFontWeights = @(
        $PrimaryMetricValue.FontWeight.ToString()
        $TodayTokens.FontWeight.ToString()
        $LastTurnTokens.FontWeight.ToString()
        $CacheHit.FontWeight.ToString()
    )
    Set-Progress -Percent 82
    Set-ExpandedState -Expanded $false -Immediate
    $anchorLeft = $window.Left
    $anchorTop = $window.Top

    Set-ExpandedState -Expanded $true
    Wait-ForUi -Milliseconds 300
    $expandedWidth = $window.ActualWidth
    $expandedHeight = $window.ActualHeight
    $expandedVisibility = [string]$DetailsPanel.Visibility

    # Reopen while collapse is still animating. A stale collapse callback must
    # never force the expanded window back to compact height.
    Set-ExpandedState -Expanded $false
    Set-ExpandedState -Expanded $true
    Wait-ForUi -Milliseconds 350
    $reopenedWidth = $window.ActualWidth
    $reopenedHeight = $window.ActualHeight
    $reopenedVisibility = [string]$DetailsPanel.Visibility

    Collapse-DetailsIfInactive -Force
    Wait-ForUi -Milliseconds 100
    $inactiveWidth = $window.ActualWidth
    $inactiveHeight = $window.ActualHeight
    $inactiveVisibility = [string]$DetailsPanel.Visibility
    $inactiveLeft = $window.Left
    $inactiveTop = $window.Top

    $result = [pscustomobject]@{
        ExpandedWidth = $expandedWidth
        ExpandedHeight = $expandedHeight
        ExpandedVisibility = $expandedVisibility
        TaskViewHidden = $taskViewHidden
        TrayIconWidth = $trayIconWidth
        TrayIconHeight = $trayIconHeight
        UpperClampedRemaining = $upperClampedRemaining
        UpperClampedUsed = $upperClampedUsed
        LowerClampedRemaining = $lowerClampedRemaining
        LowerClampedUsed = $lowerClampedUsed
        CodexSettingsVisibility = $codexSettingsVisibility
        DeepSeekSettingsVisibility = $deepSeekSettingsVisibility
        DeepSeekCompactValue = $deepSeekCompactValue
        DeepSeekCompactSuffix = $deepSeekCompactSuffix
        DeepSeekLabel = $deepSeekLabel
        DeepSeekBalanceText = $deepSeekBalanceText
        DeepSeekMetricTitle = $deepSeekMetricTitle
        DeepSeekMonthlyCostValue = $deepSeekMonthlyCostValue
        DeepSeekTodayTokenValue = $deepSeekTodayTokenValue
        DeepSeekMonthlyTokenValue = $deepSeekMonthlyTokenValue
        DeepSeekProgressRemaining = $deepSeekProgressRemaining
        DeepSeekProgressUsed = $deepSeekProgressUsed
        DeepSeekBalanceCompactValue = $deepSeekBalanceCompactValue
        DeepSeekBalanceCompactSuffix = $deepSeekBalanceCompactSuffix
        DeepSeekBalanceCompactLabel = $deepSeekBalanceCompactLabel
        DeepSeekNoBudgetProgressRemaining = $deepSeekNoBudgetProgressRemaining
        DeepSeekNoBudgetProgressUsed = $deepSeekNoBudgetProgressUsed
        MetricValueFontFamilies = $metricValueFontFamilies
        MetricValueFontSizes = $metricValueFontSizes
        MetricValueFontWeights = $metricValueFontWeights
        RemainingProgressStar = $RemainingProgressColumn.Width.Value
        UsedProgressStar = $UsedProgressColumn.Width.Value
        ReopenedWidth = $reopenedWidth
        ReopenedHeight = $reopenedHeight
        ReopenedVisibility = $reopenedVisibility
        InactiveWidth = $inactiveWidth
        InactiveHeight = $inactiveHeight
        InactiveVisibility = $inactiveVisibility
        InactiveLeft = $inactiveLeft
        InactiveTop = $inactiveTop
        Width = $window.Width
        Height = $window.Height
        DetailsVisibility = [string]$DetailsPanel.Visibility
        RestoredLeft = $window.Left
        RestoredTop = $window.Top
        AnchorLeft = $anchorLeft
        AnchorTop = $anchorTop
    }
    $window.Close()
    $result | ConvertTo-Json
    exit 0
}

$script:TrayAppIcon = New-TrayAppIcon
$script:TrayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayOpenItem = New-Object System.Windows.Forms.ToolStripMenuItem
$trayOpenItem.Text = '打开详情'
$trayOpenItem.Add_Click({
    Show-ExistingWindow
    Set-ExpandedState -Expanded $true
})
$trayRefreshItem = New-Object System.Windows.Forms.ToolStripMenuItem
$trayRefreshItem.Text = '立即刷新'
$trayRefreshItem.Add_Click({
    Show-ExistingWindow
    Invoke-Refresh
})
$traySourceItem = New-Object System.Windows.Forms.ToolStripMenuItem
$traySourceItem.Text = '数据源'
$script:TrayCodexSourceItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:TrayCodexSourceItem.Text = 'Codex'
$script:TrayCodexSourceItem.Add_Click({
    Set-ActiveProvider -Provider 'Codex' -Refresh
})
$script:TrayDeepSeekSourceItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:TrayDeepSeekSourceItem.Text = 'DeepSeek'
$script:TrayDeepSeekSourceItem.Add_Click({
    Set-ActiveProvider -Provider 'DeepSeek'
    $credential = Get-DeepSeekCredential
    if ($credential.ApiKey) {
        Invoke-Refresh
    }
    else {
        Show-ExistingWindow
        $saved = Show-DeepSeekSettings
        if (-not $saved) { Invoke-Refresh }
        Sync-ProviderMenuState
    }
})
[void]$traySourceItem.DropDownItems.Add($script:TrayCodexSourceItem)
[void]$traySourceItem.DropDownItems.Add($script:TrayDeepSeekSourceItem)
$script:TrayDeepSeekSettingsItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:TrayDeepSeekSettingsItem.Text = 'DeepSeek 设置…'
$script:TrayDeepSeekSettingsItem.Add_Click({
    Show-ExistingWindow
    [void](Show-DeepSeekSettings)
})
$script:TrayTopmostItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:TrayTopmostItem.Text = '始终置顶'
$script:TrayTopmostItem.CheckOnClick = $true
$script:TrayTopmostItem.Checked = $window.Topmost
$script:TrayTopmostItem.Add_Click({
    $window.Topmost = $script:TrayTopmostItem.Checked
    $topmostMenu.IsChecked = $window.Topmost
    Save-Settings
})
$traySeparator = New-Object System.Windows.Forms.ToolStripSeparator
$trayExitItem = New-Object System.Windows.Forms.ToolStripMenuItem
$trayExitItem.Text = '退出'
$trayExitItem.Add_Click({
    Save-Settings
    $window.Close()
})
[void]$script:TrayMenu.Items.Add($trayOpenItem)
[void]$script:TrayMenu.Items.Add($trayRefreshItem)
[void]$script:TrayMenu.Items.Add($traySourceItem)
[void]$script:TrayMenu.Items.Add($script:TrayDeepSeekSettingsItem)
[void]$script:TrayMenu.Items.Add($script:TrayTopmostItem)
[void]$script:TrayMenu.Items.Add($traySeparator)
[void]$script:TrayMenu.Items.Add($trayExitItem)

$script:TrayNotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:TrayNotifyIcon.Icon = $script:TrayAppIcon
$script:TrayNotifyIcon.Text = 'Remaining Margin Float · 单击打开详情'
$script:TrayNotifyIcon.ContextMenuStrip = $script:TrayMenu
$script:TrayNotifyIcon.Add_MouseClick({
    param($sender, $eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Show-ExistingWindow
        Set-ExpandedState -Expanded $true
    }
})
$script:TrayNotifyIcon.Visible = $true
Sync-ProviderMenuState

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    Complete-DeepSeekRefresh
    if (-not $script:IsRefreshing) {
        $script:RefreshRemaining--
        if ($script:RefreshRemaining -le 0) {
            Invoke-Refresh
        }
    }
    $AutoRefreshText.Text = '{0} 秒后自动刷新' -f [Math]::Max(0, $script:RefreshRemaining)
})
$timer.Start()

$activationTimer = New-Object Windows.Threading.DispatcherTimer
$activationTimer.Interval = [TimeSpan]::FromMilliseconds(180)
$activationTimer.Add_Tick({
    if ($script:ActivationEvent -and $script:ActivationEvent.WaitOne(0)) {
        Show-ExistingWindow
    }
})
$activationTimer.Start()

$window.Add_Closing({
    $script:IsClosing = $true
    $timer.Stop()
    $activationTimer.Stop()
    if ($script:DeepSeekHttpClient) {
        $script:DeepSeekHttpClient.CancelPendingRequests()
        $script:DeepSeekHttpClient.Dispose()
        $script:DeepSeekHttpClient = $null
    }
    if ($script:DeepSeekRequest) {
        $script:DeepSeekRequest.Dispose()
        $script:DeepSeekRequest = $null
    }
    Save-Settings
    if ($script:TrayNotifyIcon) {
        $script:TrayNotifyIcon.Visible = $false
        $script:TrayNotifyIcon.Dispose()
        $script:TrayNotifyIcon = $null
    }
    if ($script:TrayMenu) {
        $script:TrayMenu.Dispose()
        $script:TrayMenu = $null
    }
    if ($script:TrayAppIcon) {
        $script:TrayAppIcon.Dispose()
        $script:TrayAppIcon = $null
    }
    if ($script:ActivationEvent) {
        $script:ActivationEvent.Dispose()
    }
    if ($script:AppMutex) {
        try { $script:AppMutex.ReleaseMutex() } catch {}
        $script:AppMutex.Dispose()
    }
})

[void]$window.ShowDialog()
