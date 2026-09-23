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

public static class LocalJsonlFileScanner
{
    public static FileInfo[] GetFilesNewestFirst(string root)
    {
        if (String.IsNullOrWhiteSpace(root) || !Directory.Exists(root)) {
            return new FileInfo[0];
        }
        List<FileInfo> files = new List<FileInfo>();
        Stack<DirectoryInfo> pending = new Stack<DirectoryInfo>();
        pending.Push(new DirectoryInfo(root));
        while (pending.Count > 0)
        {
            DirectoryInfo directory = pending.Pop();
            try
            {
                foreach (FileInfo file in directory.GetFiles("*.jsonl")) {
                    files.Add(file);
                }
                foreach (DirectoryInfo child in directory.GetDirectories())
                {
                    if ((child.Attributes & FileAttributes.ReparsePoint) == 0) {
                        pending.Push(child);
                    }
                }
            }
            catch (UnauthorizedAccessException) {}
            catch (IOException) {}
        }
        files.Sort(delegate(FileInfo left, FileInfo right) {
            int modified = right.LastWriteTimeUtc.CompareTo(left.LastWriteTimeUtc);
            return modified != 0
                ? modified
                : StringComparer.OrdinalIgnoreCase.Compare(right.FullName, left.FullName);
        });
        return files.ToArray();
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

public sealed class UsageHistoryRecordData
{
    public int Version { get; set; }
    public string ProviderId { get; set; }
    public DateTimeOffset ObservedAtUtc { get; set; }
    public string LocalDate { get; set; }
    public string TimeZoneId { get; set; }
    public int UtcOffsetMinutes { get; set; }
    public string MetricType { get; set; }
    public string QuotaPeriod { get; set; }
    public double RemainingValue { get; set; }
    public string Unit { get; set; }
    public string ResetAtUtc { get; set; }
}

public static class UsageHistoryLogScanner
{
    private static readonly Regex Version = Create("\\\"v\\\"\\s*:\\s*(?<value>-?\\d+)");
    private static readonly Regex Provider = Create("\\\"ProviderId\\\"\\s*:\\s*\\\"(?<value>[^\\\"]*)\\\"");
    private static readonly Regex Observed = Create("\\\"ObservedAtUtc\\\"\\s*:\\s*\\\"(?<value>[^\\\"]*)\\\"");
    private static readonly Regex Metric = Create("\\\"MetricType\\\"\\s*:\\s*\\\"(?<value>[^\\\"]*)\\\"");
    private static readonly Regex Period = Create("\\\"QuotaPeriod\\\"\\s*:\\s*\\\"(?<value>[^\\\"]*)\\\"");
    private static readonly Regex Remaining = Create("\\\"RemainingValue\\\"\\s*:\\s*(?<value>[-+]?(?:\\d+(?:\\.\\d*)?|\\.\\d+)(?:[eE][-+]?\\d+)?)");
    private static readonly Regex Unit = Create("\\\"Unit\\\"\\s*:\\s*\\\"(?<value>[^\\\"]*)\\\"");
    private static readonly Regex Reset = Create("\\\"ResetAtUtc\\\"\\s*:\\s*\\\"(?<value>[^\\\"]*)\\\"");

    private static Regex Create(string pattern)
    {
        return new Regex(pattern, RegexOptions.Compiled | RegexOptions.CultureInvariant);
    }

    private static string Capture(Regex regex, string line)
    {
        Match match = regex.Match(line);
        return match.Success ? match.Groups["value"].Value : String.Empty;
    }

    private static UsageHistoryRecordData ParseLine(
        string line,
        TimeZoneInfo timeZone,
        DateTime earliestLocalDate
    ) {
        if (String.IsNullOrWhiteSpace(line) || line.Length > 65536) {
            return null;
        }
        string provider = Capture(Provider, line);
        string metric = Capture(Metric, line);
        if (
            (provider != "Codex" && provider != "DeepSeek" && provider != "Kimi") ||
            (metric != "Percent" && metric != "Balance")
        ) {
            return null;
        }

        int version;
        if (!Int32.TryParse(
            Capture(Version, line),
            NumberStyles.Integer,
            CultureInfo.InvariantCulture,
            out version
        )) {
            version = 0;
        }
        string quotaPeriod = Capture(Period, line);
        bool hasQuotaPeriod = Period.IsMatch(line);
        if (provider == "Codex" && metric == "Percent") {
            if (!hasQuotaPeriod && version >= 1 && version <= 2) {
                quotaPeriod = "Weekly";
            }
            else if (quotaPeriod != "FiveHour" && quotaPeriod != "Weekly") {
                return null;
            }
        }
        else if (
            provider == "Kimi" &&
            metric == "Percent" &&
            quotaPeriod != "FiveHour" &&
            quotaPeriod != "Weekly"
        ) {
            return null;
        }

        DateTimeOffset observedAt;
        if (!DateTimeOffset.TryParse(
            Capture(Observed, line),
            CultureInfo.InvariantCulture,
            DateTimeStyles.RoundtripKind,
            out observedAt
        )) {
            return null;
        }
        observedAt = observedAt.ToUniversalTime();
        DateTimeOffset localObservedAt = TimeZoneInfo.ConvertTime(observedAt, timeZone);
        if (localObservedAt.Date < earliestLocalDate) {
            return null;
        }

        double remainingValue;
        if (!Double.TryParse(
            Capture(Remaining, line),
            NumberStyles.Float,
            CultureInfo.InvariantCulture,
            out remainingValue
        ) || Double.IsNaN(remainingValue) || Double.IsInfinity(remainingValue) ||
            remainingValue < 0 || (metric == "Percent" && remainingValue > 100)
        ) {
            return null;
        }

        string resetAtUtc = String.Empty;
        string resetText = Capture(Reset, line);
        DateTimeOffset resetAt;
        if (!String.IsNullOrWhiteSpace(resetText) && DateTimeOffset.TryParse(
            resetText,
            CultureInfo.InvariantCulture,
            DateTimeStyles.RoundtripKind,
            out resetAt
        )) {
            resetAtUtc = resetAt.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture);
        }

        return new UsageHistoryRecordData {
            Version = 3,
            ProviderId = provider,
            ObservedAtUtc = observedAt,
            LocalDate = localObservedAt.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            TimeZoneId = timeZone.Id,
            UtcOffsetMinutes = (int)Math.Round(localObservedAt.Offset.TotalMinutes),
            MetricType = metric,
            QuotaPeriod = quotaPeriod,
            RemainingValue = Math.Round(remainingValue, 4),
            Unit = Capture(Unit, line),
            ResetAtUtc = resetAtUtc
        };
    }

    public static UsageHistoryRecordData[] ReadFile(
        string path,
        DateTimeOffset now,
        TimeZoneInfo timeZone
    ) {
        DateTime earliestLocalDate = TimeZoneInfo.ConvertTime(
            now.ToUniversalTime(),
            timeZone
        ).Date.AddDays(-7);
        Dictionary<string, UsageHistoryRecordData> samples =
            new Dictionary<string, UsageHistoryRecordData>(StringComparer.Ordinal);
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
                UsageHistoryRecordData sample = ParseLine(
                    line,
                    timeZone,
                    earliestLocalDate
                );
                if (sample == null) {
                    continue;
                }
                string key = String.Join("|", new string[] {
                    sample.ProviderId,
                    sample.MetricType,
                    sample.QuotaPeriod,
                    sample.Unit,
                    sample.ObservedAtUtc.ToString("o", CultureInfo.InvariantCulture)
                });
                samples[key] = sample;
            }
        }
        List<UsageHistoryRecordData> result =
            new List<UsageHistoryRecordData>(samples.Values);
        result.Sort(delegate(UsageHistoryRecordData left, UsageHistoryRecordData right) {
            return left.ObservedAtUtc.CompareTo(right.ObservedAtUtc);
        });
        return result.ToArray();
    }

    public static UsageHistoryRecordData[] SelectForAnalysis(
        UsageHistoryRecordData[] samples,
        DateTimeOffset now
    ) {
        if (samples == null || samples.Length <= 720) {
            return samples ?? new UsageHistoryRecordData[0];
        }
        Dictionary<string, List<UsageHistoryRecordData>> series =
            new Dictionary<string, List<UsageHistoryRecordData>>(StringComparer.Ordinal);
        foreach (UsageHistoryRecordData sample in samples)
        {
            string key = String.Join("|", new string[] {
                sample.ProviderId,
                sample.MetricType,
                sample.QuotaPeriod,
                sample.Unit
            });
            List<UsageHistoryRecordData> group;
            if (!series.TryGetValue(key, out group)) {
                group = new List<UsageHistoryRecordData>();
                series[key] = group;
            }
            group.Add(sample);
        }

        HashSet<UsageHistoryRecordData> selected =
            new HashSet<UsageHistoryRecordData>();
        long recentCutoffTicks = now.ToUniversalTime().AddHours(-26).Ticks;
        long ticksPerRecentBucket = TimeSpan.FromMinutes(5).Ticks;
        long ticksPerOlderBucket = TimeSpan.FromMinutes(30).Ticks;
        foreach (List<UsageHistoryRecordData> group in series.Values)
        {
            UsageHistoryRecordData previous = null;
            UsageHistoryRecordData bucketLast = null;
            long bucket = Int64.MinValue;
            foreach (UsageHistoryRecordData sample in group)
            {
                long sampleTicks = sample.ObservedAtUtc.UtcDateTime.Ticks;
                long ticksPerBucket = sampleTicks >= recentCutoffTicks
                    ? ticksPerRecentBucket
                    : ticksPerOlderBucket;
                long sampleBucket = sampleTicks / ticksPerBucket;
                if (sampleBucket != bucket) {
                    if (bucketLast != null) {
                        selected.Add(bucketLast);
                    }
                    bucket = sampleBucket;
                }
                if (previous != null && Math.Abs(
                    sample.RemainingValue - previous.RemainingValue
                ) > 0.0001) {
                    selected.Add(previous);
                    selected.Add(sample);
                }
                if (previous == null) {
                    selected.Add(sample);
                }
                previous = sample;
                bucketLast = sample;
            }
            if (bucketLast != null) {
                selected.Add(bucketLast);
            }
        }
        List<UsageHistoryRecordData> result =
            new List<UsageHistoryRecordData>(selected);
        result.Sort(delegate(UsageHistoryRecordData left, UsageHistoryRecordData right) {
            return left.ObservedAtUtc.CompareTo(right.ObservedAtUtc);
        });
        return result.ToArray();
    }
}
'@

$script:AppVersion = '1.12.0'
$script:CompactWidth = 80.0
$script:CompactHeight = 80.0
$script:EdgeVisibleWidth = 14.0
$script:EdgeSnapDistance = 20.0
$script:EdgeRevealDurationMs = 190
$script:EdgeHideDurationMs = 150
$script:EdgeAlignMaxCorrectionPixels = 240
$script:EdgeDockAnimating = $false
$script:PendingEdgeAlignmentSamples = New-Object System.Collections.Queue
$script:WindowPlacementWatchdogSeconds = 5
$script:LastWindowPlacementWatchdogAt = $null
$script:ExpandedWidth = 400.0
$script:ExpandedHeight = 560.0
$script:CodexPlusExpandedHeight = 522.0
$script:CodexProExpandedHeight = 474.0
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
$script:KimiUsageCache = @{}
$script:DeepSeekUsageCache = @{}
$script:DeepSeekLatestUsageCache = @{}
$script:DeepSeekAggregateUsageCache = $null
$script:DeepSeekAggregateCacheHits = 0
$script:DeepSeekAggregateCacheMisses = 0
$script:CodexHttpClient = $null
$script:CodexOfficialUsageCache = $null
$script:KimiHttpClient = $null
$script:KimiOfficialUsageCache = $null
$script:DeepSeekHttpClient = $null
$script:UpdateHttpClient = $null
$script:UpdateMenuItem = $null
$script:TrayUpdateItem = $null
$script:AutoUpdateMenuItem = $null
$script:TrayAutoUpdateItem = $null
$script:AutoUpdateEnabled = $false
$script:NextAutomaticUpdateCheckAt = $null
$script:NextAutoUpdateNetworkRetryAt = $null
$script:DeferredAutoUpdateRelease = $null
$script:DeferredAutoUpdateInstaller = $null
$script:AutoUpdateDeferredNotifications = @{}
$script:PromptedUpdateVersions = @{}
$script:UpdateDiagnosticMode = $false
$script:UpdateDiagnosticMessages = @()
$script:UpdateDiagnosticUpdatesRoot = $null
$script:UpdateDiagnosticInstallerPath = $null
$script:UpdateDiagnosticInstallerVersion = $null
$script:UpdateDiagnosticFileVersionInfo = $null
$script:UpdateDiagnosticNetworkState = $null
$script:UpdateDiagnosticInstalledMode = $null
$script:UpdateDiagnosticInstallerArguments = ''
$script:UpdateDiagnosticAutomaticInstall = $false
$script:UpdateDiagnosticWindowCloseRequested = $false
$script:UpdateTrustedSignerThumbprints = @()
$script:UpdateContext = [pscustomobject]@{
    IsBusy = $false
    Manual = $false
    AutomaticInstall = $false
    Phase = 'Idle'
    Client = $null
    ReleaseTask = $null
    InstallerTask = $null
    ChecksumTask = $null
    Release = $null
}
$script:LastDeepSeekSnapshot = $null
$script:LastKimiSnapshot = $null
$script:UsageHistoryCache = $null
$script:SpendLedgerCache = $null
$script:SpendLedgerLoaded = $false
$script:LastSpendLedgerError = ''
$global:RmfUsageHistoryRepairProcess = $null
$global:RmfUsageHistoryRepairStarted = $false
$script:UsageStateMaintenanceDueByRoot = @{}
$script:PendingCodexLocalRefresh = $null
$script:PendingUsageHistoryUpdates = New-Object 'Collections.Generic.Queue[object]'
$script:UsageHistoryUpdateCount = 0
$script:UsageHistoryUpdateLastMilliseconds = -1L
$script:UsageHistoryUpdateLastError = ''
$script:LastUsageInsights = $null
$script:LastUsageHistoryError = ''
$script:UsageStateDiagnosticCaptureCount = 0
# Alert settings are stored per data source; the flat $script: values below
# mirror the active source and are refreshed by Sync-ActiveAlertSettings.
$script:AlertSettings = [ordered]@{}
$script:LowRemainingThreshold = 20.0
$script:LowFiveHourThreshold = 20.0
$script:LowWeeklyThreshold = 20.0
$script:LowAmountThreshold = 10.0
$script:LowRemainingAlertsEnabled = $true
$script:LowAlertActive = @{}
$script:RapidDropAlertsEnabled = $true
$script:RapidDropWindowMinutes = 30
$script:CodexRapidDropPercent = 10.0
$script:RapidFiveHourPercent = 10.0
$script:RapidWeeklyPercent = 10.0
$script:DeepSeekRapidDropMode = 'Percent'
$script:DeepSeekRapidDropPercent = 10.0
$script:DeepSeekRapidDropAmount = 10.0
$script:RapidDropAlertActive = @{}
$script:CodexSourceMenuItem = $null
$script:DeepSeekSourceMenuItem = $null
$script:KimiSourceMenuItem = $null
$script:TrayCodexSourceItem = $null
$script:TrayDeepSeekSourceItem = $null
$script:TrayKimiSourceItem = $null
$script:CodexOfficialAccessMenuItem = $null
$script:TrayCodexOfficialAccessItem = $null
$script:CodexOfficialAccessEnabled = $false
$script:DeepSeekSettingsMenuItem = $null
$script:TrayDeepSeekSettingsItem = $null
$script:KimiSettingsMenuItem = $null
$script:TrayKimiSettingsItem = $null
$script:KimiWslMenuItem = $null
$script:TrayKimiWslItem = $null
$script:KimiUseWsl = $false
$script:KimiWslDataRootCache = $null
$script:KimiWslDataRootResolved = $false
$script:LowAlertsMenuItem = $null
$script:TrayLowAlertsItem = $null
$script:LowAlertThresholdMenuItem = $null
$script:TrayLowAlertThresholdItem = $null
$script:EdgeDockMenuItem = $null
$script:EdgeDockEnabled = $true
$script:EdgeDockSide = $null
$script:EdgeDockWorkArea = $null
$script:IsSyncingEdgeDockEnvironment = $false
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
            Attempt = 0
            MaxAttempts = 2
            RetryAfter = $null
        }
        Kimi = [pscustomobject]@{
            Request = $null
            RequestTask = $null
            Attempt = 0
            MaxAttempts = 2
            RetryAfter = $null
        }
    }
}
