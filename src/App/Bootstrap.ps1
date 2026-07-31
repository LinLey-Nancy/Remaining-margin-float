function Get-SingleInstanceObjectNames {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sid = if ($identity.User) { $identity.User.Value } else { $identity.Name }
    if ([string]::IsNullOrWhiteSpace($sid)) {
        throw '无法确定当前 Windows 用户，不能创建单实例对象。'
    }
    $scope = $sid -replace '[^0-9A-Za-z._-]', '_'
    $testScope = [Environment]::GetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_INSTANCE_SCOPE',
        [EnvironmentVariableTarget]::Process
    )
    if (-not [string]::IsNullOrWhiteSpace($testScope)) {
        $scope = $testScope -replace '[^0-9A-Za-z._-]', '_'
    }
    return [pscustomobject]@{
        Scope = $scope
        ActivationEvent = "Local\RemainingMarginFloat.Activate.$scope"
        Mutex = "Local\RemainingMarginFloat.Singleton.$scope"
    }
}

$script:SingleInstanceObjectNames = Get-SingleInstanceObjectNames
$script:ActivationEvent = $null
$script:AppMutex = $null
if (-not $isDiagnosticRun) {
    $script:ActivationEvent = New-Object System.Threading.EventWaitHandle(
        $false,
        [System.Threading.EventResetMode]::AutoReset,
        $script:SingleInstanceObjectNames.ActivationEvent
    )
    $createdNew = $false
    $script:AppMutex = New-Object System.Threading.Mutex(
        $true,
        $script:SingleInstanceObjectNames.Mutex,
        [ref]$createdNew
    )
    if (-not $createdNew) {
        [void]$script:ActivationEvent.Set()
        $script:ActivationEvent.Dispose()
        $script:AppMutex.Dispose()
        $script:RmfActivatedExistingInstance = $true
        $script:RmfStopLoading = $true
        return
    }
}

Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName PresentationFramework
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

$script:AppVersion = '1.8.1'
$script:CompactWidth = 80.0
$script:CompactHeight = 80.0
$script:EdgeVisibleWidth = 14.0
$script:EdgeSnapDistance = 20.0
$script:EdgeRevealDurationMs = 190
$script:EdgeHideDurationMs = 150
$script:ExpandedWidth = 400.0
$script:ExpandedHeight = 560.0
$script:RefreshIntervalSeconds = 60
$script:SessionCache = @{}
$script:SessionMetadataCache = @{}
$script:LastSnapshot = $null
$script:CompactAnchorLeft = $null
$script:CompactAnchorTop = $null
$script:TrayNotifyIcon = $null
$script:TrayAppIcon = $null
$script:TrayMenu = $null
$script:TrayTopmostItem = $null
$script:TrayEdgeDockItem = $null
$script:TrayStartupItems = @{}
$script:IsClosing = $false
$script:ActiveProvider = 'Codex'
$script:DeepSeekUsageCache = @{}
$script:DeepSeekLatestUsageCache = @{}
$script:DeepSeekAggregateUsageCache = $null
$script:DeepSeekAggregateCacheHits = 0
$script:DeepSeekAggregateCacheMisses = 0
$script:CodexHttpClient = $null
$script:CodexOfficialUsageCache = $null
$script:DeepSeekHttpClient = $null
$script:UpdateHttpClient = $null
$script:TrayUpdateItem = $null
$script:NextAutomaticUpdateCheckAt = $null
$script:PromptedUpdateVersions = @{}
$script:UpdateDiagnosticMode = $false
$script:UpdateDiagnosticMessages = @()
$script:UpdateDiagnosticUpdatesRoot = $null
$script:UpdateDiagnosticInstallerPath = $null
$script:UpdateDiagnosticInstallerVersion = $null
$script:UpdateDiagnosticFileVersionInfo = $null
$script:UpdateTrustedSignerThumbprints = @()
$script:UpdateContext = [pscustomobject]@{
    IsBusy = $false
    Manual = $false
    Phase = 'Idle'
    ReleaseTask = $null
    InstallerTask = $null
    ChecksumTask = $null
    Release = $null
}
$script:LastDeepSeekSnapshot = $null
$script:UsageHistoryCache = $null
$script:LastUsageHistoryError = ''
$script:LowRemainingThreshold = 20.0
$script:LowRemainingAlertsEnabled = $true
$script:LowAlertActive = @{}
$script:RapidDropAlertsEnabled = $true
$script:RapidDropWindowMinutes = 30
$script:CodexRapidDropPercent = 10.0
$script:DeepSeekRapidDropMode = 'Percent'
$script:DeepSeekRapidDropPercent = 10.0
$script:DeepSeekRapidDropAmount = 10.0
$script:RapidDropAlertActive = @{}
$script:CodexSourceMenuItem = $null
$script:DeepSeekSourceMenuItem = $null
$script:TrayCodexSourceItem = $null
$script:TrayDeepSeekSourceItem = $null
$script:CodexOfficialAccessMenuItem = $null
$script:TrayCodexOfficialAccessItem = $null
$script:CodexOfficialAccessEnabled = $false
$script:DeepSeekSettingsMenuItem = $null
$script:TrayDeepSeekSettingsItem = $null
$script:LowAlertsMenuItem = $null
$script:TrayLowAlertsItem = $null
$script:LowAlertThresholdMenuItem = $null
$script:TrayLowAlertThresholdItem = $null
$script:EdgeDockMenuItem = $null
$script:EdgeDockEnabled = $true
$script:EdgeDockSide = $null
$script:EdgeDockWorkArea = $null
$script:IsEdgeRevealed = $false
$script:StartupMode = 'Off'
$script:StartupMenuItems = @{}
$script:IsPointerOverSurface = $false
$script:EdgeHideTimer = $null
$script:EdgeRevealTimer = $null
$script:CurrentHoverBorderColor = '#C4D0C6'
$script:CurrentSurfaceBorderColor = '#E1E3DE'
$script:IsRestoringSettings = $false
$script:AppContext = [pscustomobject]@{
    Refresh = [pscustomobject]@{
        IsBusy = $false
        StartedAt = $null
        RemainingSeconds = $script:RefreshIntervalSeconds
        NextAt = $null
        Codex = [pscustomobject]@{
            Request = $null
            RequestTask = $null
            Attempt = 0
            MaxAttempts = 2
            RetryAfter = $null
        }
        DeepSeek = [pscustomobject]@{
            Request = $null
            RequestTask = $null
        }
    }
}
