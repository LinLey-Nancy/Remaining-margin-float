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
    $selected = Select-CodexRateLimitSnapshot `
        -Snapshots $selectionCandidates `
        -Now ([DateTimeOffset]'2030-01-01T00:05:00Z')
    $emptySelection = Select-CodexRateLimitSnapshot -Snapshots @(
        [pscustomobject]@{
            RateLimitPayload = $incompletePayload
            RateLimitObservedAt = [DateTimeOffset]'2030-01-01T00:01:00Z'
        }
    )
    $replayedRateLimits = @{}
    Add-CodexRateLimitSample `
        -Candidates $replayedRateLimits `
        -Payload $freshPayload `
        -ObservedAt ([DateTimeOffset]'2030-01-01T00:00:00Z')
    foreach ($resetAt in (1894060920..1894061120 | Where-Object { ($_ % 10) -eq 0 })) {
        $slidingResetPayload = [pscustomobject]@{
            rate_limits = [pscustomobject]@{
                primary = [pscustomobject]@{
                    used_percent = 0.0
                    window_minutes = 10080
                    resets_at = $resetAt
                }
                plan_type = 'pro'
            }
        }
        Add-CodexRateLimitSample `
            -Candidates $replayedRateLimits `
            -Payload $slidingResetPayload `
            -ObservedAt ([DateTimeOffset]'2030-01-01T00:02:00Z')
    }
    $replayedSelection = Select-CodexStableRateLimitSample `
        -Candidates $replayedRateLimits `
        -Now ([DateTimeOffset]'2030-01-01T00:05:00Z')
    $crossFileSelection = Select-CodexRateLimitSnapshot `
        -Snapshots @(
            [pscustomobject]@{
                RateLimitPayload = $freshPayload
                RateLimitObservedAt = [DateTimeOffset]'2030-01-01T00:00:00Z'
            },
            [pscustomobject]@{
                RateLimitPayload = $slidingResetPayload
                RateLimitObservedAt = [DateTimeOffset]'2030-01-01T00:02:00Z'
            }
        ) `
        -Now ([DateTimeOffset]'2030-01-01T00:05:00Z')
    $stableZeroRateLimits = @{}
    Add-CodexRateLimitSample `
        -Candidates $stableZeroRateLimits `
        -Payload $stalePayload `
        -ObservedAt ([DateTimeOffset]'2029-12-31T23:45:00Z')
    Add-CodexRateLimitSample `
        -Candidates $stableZeroRateLimits `
        -Payload $stalePayload `
        -ObservedAt ([DateTimeOffset]'2029-12-31T23:50:00Z')
    $stableZeroSelection = Select-CodexStableRateLimitSample `
        -Candidates $stableZeroRateLimits
    $singleZeroRateLimits = @{}
    Add-CodexRateLimitSample `
        -Candidates $singleZeroRateLimits `
        -Payload $stalePayload `
        -ObservedAt ([DateTimeOffset]'2029-12-31T23:50:00Z')
    $singleZeroSelection = Select-CodexStableRateLimitSample `
        -Candidates $singleZeroRateLimits `
        -Now ([DateTimeOffset]'2029-12-31T23:53:00Z')
    $expiredPositiveCandidates = @{}
    Add-CodexRateLimitSample `
        -Candidates $expiredPositiveCandidates `
        -Payload $freshPayload `
        -ObservedAt ([DateTimeOffset]'2030-01-01T00:00:00Z')
    Add-CodexRateLimitSample `
        -Candidates $expiredPositiveCandidates `
        -Payload $slidingResetPayload `
        -ObservedAt ([DateTimeOffset]'2030-01-01T01:55:00Z')
    $expiredPositiveSelection = Select-CodexStableRateLimitSample `
        -Candidates $expiredPositiveCandidates `
        -Now ([DateTimeOffset]'2030-01-01T02:00:00Z')
    $rootSessionMetadata = [pscustomobject]@{ source = 'vscode' }
    $subagentSessionMetadata = [pscustomobject]@{
        source = [pscustomobject]@{
            subagent = [pscustomobject]@{ parent_thread_id = 'parent-session' }
        }
    }
    $officialPayload = [pscustomobject]@{
        plan_type = 'prolite'
        rate_limit = [pscustomobject]@{
            primary_window = [pscustomobject]@{
                used_percent = 40.0
                limit_window_seconds = 604800
                reset_at = 1894060800
            }
        }
        additional_rate_limits = @(
            [pscustomobject]@{
                limit_name = 'GPT-5.3-Codex-Spark'
                rate_limit = [pscustomobject]@{
                    primary_window = [pscustomobject]@{
                        used_percent = 0.0
                        limit_window_seconds = 604800
                        reset_at = 1894665600
                    }
                }
            }
        )
    }
    $officialUsage = ConvertTo-CodexOfficialUsage `
        -Payload $officialPayload `
        -SampledAt ([DateTimeOffset]'2030-01-01T00:05:00Z')
    $officialQuotaUsage = Resolve-CodexQuotaUsage `
        -OfficialUsage $officialUsage `
        -SessionSnapshots $selectionCandidates `
        -Now ([DateTimeOffset]'2030-01-01T00:05:00Z')
    $localQuotaUsage = Resolve-CodexQuotaUsage `
        -OfficialUsage $null `
        -SessionSnapshots $selectionCandidates `
        -Now ([DateTimeOffset]'2030-01-01T00:05:00Z')
    $missingQuotaUsage = Resolve-CodexQuotaUsage `
        -OfficialUsage $null `
        -SessionSnapshots @()
    $selectedWindow = Get-CodexRateLimitWindow -Payload $selected.RateLimitPayload
    [pscustomobject]@{
        SelectedUsedPercent = [double]$selectedWindow.used_percent
        SelectedResetAt = [long]$selectedWindow.resets_at
        SelectedObservedAt = $selected.RateLimitObservedAt
        NewestFileWasStale = $selectionCandidates[0].FileModifiedAt -gt $selectionCandidates[1].FileModifiedAt
        IncompleteNewestWasIgnored = $selected.RateLimitPayload -eq $freshPayload
        SlidingResetPlaceholdersIgnored = $replayedSelection.Payload -eq $freshPayload
        ActivePositiveCycleProtectedAcrossFiles = (
            $crossFileSelection.RateLimitPayload -eq $freshPayload
        )
        StableZeroSampleAccepted = $stableZeroSelection.Payload -eq $stalePayload
        SingleZeroEventuallyAccepted = $singleZeroSelection.Payload -eq $stalePayload
        ExpiredPositiveCanYieldToZero = (
            $expiredPositiveSelection.Payload -eq $slidingResetPayload
        )
        RootSessionAccepted = Test-CodexRootSessionMetadata -Payload $rootSessionMetadata
        SubagentSessionIgnored = -not (
            Test-CodexRootSessionMetadata -Payload $subagentSessionMetadata
        )
        EmptySelectionHandled = $null -eq $emptySelection
        OfficialPrimaryUsageSelected = (
            $officialUsage.UsedPercent -eq 40 -and
            $officialUsage.WindowMinutes -eq 10080 -and
            $officialUsage.PlanType -eq 'prolite'
        )
        AdditionalModelLimitIgnored = $officialUsage.UsedPercent -ne 0
        OfficialChannelPreferred = (
            $officialQuotaUsage.Channel -eq 'Official' -and
            $officialQuotaUsage.UsedPercent -eq 40
        )
        LocalChannelFallbackSelected = (
            $localQuotaUsage.Channel -eq 'Local' -and
            $localQuotaUsage.UsedPercent -eq 22 -and
            $localQuotaUsage.PlanType -eq 'pro'
        )
        MissingChannelsRemainUnknown = $null -eq $missingQuotaUsage
    } | ConvertTo-Json
    $script:RmfStopLoading = $true
    return
}

if ($CheckProviderContracts) {
    $fixtureRoot = [Environment]::GetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_FIXTURE_ROOT',
        [EnvironmentVariableTarget]::Process
    )
    if ([string]::IsNullOrWhiteSpace($fixtureRoot)) {
        $fixtureRoot = [IO.Path]::GetFullPath(
            (Join-Path $script:RmfSourceRoot '..\tests\fixtures')
        )
    }

    $codexFixturePath = Join-Path $fixtureRoot 'codex-official-usage.json'
    $deepSeekBalanceFixturePath = Join-Path $fixtureRoot 'deepseek-balance.json'
    $deepSeekUsageFixturePath = Join-Path $fixtureRoot 'deepseek-usage.jsonl'
    foreach ($fixturePath in @(
        $codexFixturePath
        $deepSeekBalanceFixturePath
        $deepSeekUsageFixturePath
    )) {
        if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
            throw "缺少 Provider 契约样例：$fixturePath"
        }
    }

    $codexPayload = Get-Content -LiteralPath $codexFixturePath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $codexUsage = ConvertTo-CodexOfficialUsage `
        -Payload $codexPayload `
        -SampledAt ([DateTimeOffset]'2030-01-01T12:00:00Z')

    $deepSeekEvents = @([DeepSeekLogScanner]::ReadFile($deepSeekUsageFixturePath))
    $deepSeekPrimaryEvent = $deepSeekEvents |
        Where-Object { $_.MessageId -eq 'fixture-message' } |
        Select-Object -First 1
    $deepSeekPrimaryCost = Get-DeepSeekEstimatedEventCostCny `
        -Event $deepSeekPrimaryEvent
    $deepSeekAggregate = Measure-DeepSeekUsageEvents `
        -Events $deepSeekEvents `
        -StartDate ([datetime]'2030-01-01') `
        -EndDate ([datetime]'2030-01-02')
    $deepSeekBalance = Get-Content `
        -LiteralPath $deepSeekBalanceFixturePath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
    $fixtureLocalUsage = [pscustomobject]@{
        TodayTokens = $deepSeekAggregate.TotalTokens
        MonthlyTokens = $deepSeekAggregate.TotalTokens
        MonthlyEstimatedCostCny = $deepSeekAggregate.EstimatedCostCny
        LastTurnTokens = $deepSeekPrimaryEvent.TotalTokens
        LastInputTokens = (
            $deepSeekPrimaryEvent.InputTokens +
            $deepSeekPrimaryEvent.CachedTokens +
            $deepSeekPrimaryEvent.CacheWriteTokens
        )
        LastOutputTokens = $deepSeekPrimaryEvent.OutputTokens
        LastCachedTokens = $deepSeekPrimaryEvent.CachedTokens
        CacheHitPercent = 50.0
        Model = $deepSeekPrimaryEvent.Model
        SampledAt = $deepSeekPrimaryEvent.Timestamp.LocalDateTime
    }
    $deepSeekSnapshot = ConvertTo-DeepSeekSnapshot `
        -BalancePayload $deepSeekBalance `
        -LocalUsage $fixtureLocalUsage `
        -Budget 120 `
        -KeyHint '1234' `
        -CredentialSource '契约样例' `
        -SampledAt ([datetime]'2030-01-01T12:00:00')
    Assert-UsageSnapshotContract -Snapshot $deepSeekSnapshot
    $pricingCatalog = Get-DeepSeekPricingCatalog
    $freshSnapshot = $deepSeekSnapshot.PSObject.Copy()
    $freshSnapshot.SampledAt = [DateTimeOffset]'2030-01-01T12:00:00+08:00'
    $freshnessFresh = Get-UsageSnapshotFreshness `
        -Snapshot $freshSnapshot `
        -Now ([DateTimeOffset]'2030-01-01T12:01:00+08:00')
    $freshnessDelayed = Get-UsageSnapshotFreshness `
        -Snapshot $freshSnapshot `
        -Now ([DateTimeOffset]'2030-01-01T12:05:00+08:00')
    $freshnessStale = Get-UsageSnapshotFreshness `
        -Snapshot $freshSnapshot `
        -Now ([DateTimeOffset]'2030-01-01T12:20:00+08:00')
    $fallbackSnapshot = New-UsageFallbackSnapshot `
        -Snapshot $freshSnapshot `
        -Reason 'diagnostic fallback'

    [pscustomobject]@{
        CodexUsedPercent = $codexUsage.UsedPercent
        CodexWindowMinutes = $codexUsage.WindowMinutes
        CodexPlan = $codexUsage.PlanType
        DeepSeekEventCount = $deepSeekEvents.Count
        DeepSeekPrimaryTokens = $deepSeekPrimaryEvent.TotalTokens
        DeepSeekPrimaryCostCny = $deepSeekPrimaryCost
        DeepSeekAvailable = $deepSeekSnapshot.Available
        DeepSeekBalance = $deepSeekSnapshot.TotalBalance
        DeepSeekBudgetPercent = $deepSeekSnapshot.BudgetPercent
        PricingSchemaVersion = $pricingCatalog.SchemaVersion
        PricingCurrency = $pricingCatalog.Currency
        FreshnessStatesClassified = (
            $freshnessFresh.State -eq 'Fresh' -and
            $freshnessDelayed.State -eq 'Delayed' -and
            $freshnessStale.State -eq 'Stale' -and
            [bool]$freshnessStale.IsStale
        )
        FallbackSnapshotPreservesSample = (
            [bool]$fallbackSnapshot.IsFallback -and
            $fallbackSnapshot.FallbackReason -eq 'diagnostic fallback' -and
            $fallbackSnapshot.SampledAt -eq $freshSnapshot.SampledAt
        )
        TransientRefreshFailuresClassified = (
            (Test-TransientRefreshFailure -StatusCode 0) -and
            (Test-TransientRefreshFailure -StatusCode 429) -and
            (Test-TransientRefreshFailure -StatusCode 503) -and
            -not (Test-TransientRefreshFailure -StatusCode 401)
        )
        RefreshRetryBackoffBounded = (
            (Get-RefreshRetryDelaySeconds -Attempt 1) -eq 1 -and
            (Get-RefreshRetryDelaySeconds -Attempt 2) -eq 2 -and
            (
                Get-RefreshRetryDelaySeconds `
                    -Attempt 2 `
                    -ServerDelaySeconds 60
            ) -eq 30
        )
    } | ConvertTo-Json
    $script:RmfStopLoading = $true
    return
}

if ($CheckRefreshPerformance) {
    $refreshMeasurements = New-Object System.Collections.ArrayList
    for ($measurementIndex = 0; $measurementIndex -lt 3; $measurementIndex++) {
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        [void](Get-CodexUsageSnapshot -SkipOfficialRequest)
        $stopwatch.Stop()
        [void]$refreshMeasurements.Add(
            [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 2)
        )
    }

    $coldReadMs = [double]$refreshMeasurements[0]
    $warmReadMs = [Math]::Round(
        (
            [double]$refreshMeasurements[1] +
            [double]$refreshMeasurements[2]
        ) / 2,
        2
    )
    $sessionsRoot = Join-Path $env:USERPROFILE '.codex\sessions'
    $sessionFiles = @(
        if (Test-Path -LiteralPath $sessionsRoot) {
            Get-ChildItem `
                -LiteralPath $sessionsRoot `
                -Recurse `
                -File `
                -Filter '*.jsonl' `
                -ErrorAction SilentlyContinue
        }
    )
    $sessionBytes = if ($sessionFiles.Count -gt 0) {
        [double]((
            $sessionFiles | Measure-Object -Property Length -Sum
        ).Sum)
    }
    else {
        0.0
    }

    $deepSeekMeasurements = New-Object System.Collections.ArrayList
    for ($measurementIndex = 0; $measurementIndex -lt 3; $measurementIndex++) {
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        [void](Get-DeepSeekLocalUsage)
        $stopwatch.Stop()
        [void]$deepSeekMeasurements.Add(
            [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 2)
        )
    }
    $deepSeekColdReadMs = [double]$deepSeekMeasurements[0]
    $deepSeekWarmReadMs = [Math]::Round(
        (
            [double]$deepSeekMeasurements[1] +
            [double]$deepSeekMeasurements[2]
        ) / 2,
        2
    )
    $deepSeekProjectsRoot = Join-Path $env:USERPROFILE '.claude\projects'
    $deepSeekFiles = @(
        if (Test-Path -LiteralPath $deepSeekProjectsRoot) {
            Get-ChildItem `
                -LiteralPath $deepSeekProjectsRoot `
                -Recurse `
                -File `
                -Filter '*.jsonl' `
                -ErrorAction SilentlyContinue
        }
    )
    $deepSeekBytes = if ($deepSeekFiles.Count -gt 0) {
        [double]((
            $deepSeekFiles | Measure-Object -Property Length -Sum
        ).Sum)
    }
    else {
        0.0
    }

    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $syntheticRoot = [IO.Path]::GetFullPath(
        (Join-Path $tempRoot (
            'RemainingMarginFloat.PerformanceDiagnostic.{0}.{1}' -f
                $PID,
                [Guid]::NewGuid().ToString('N')
        ))
    )
    if (-not $syntheticRoot.StartsWith(
        $tempRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw '性能诊断临时目录超出了系统临时目录。'
    }

    $syntheticFileBytes = 8MB
    $tailSessionPath = Join-Path $syntheticRoot 'tail-event.jsonl'
    $headSessionPath = Join-Path $syntheticRoot 'head-only-event.jsonl'
    $headLine = (
        '{"timestamp":"2030-01-01T00:00:00Z","type":"event_msg",' +
        '"payload":{"type":"token_count","info":{"total_token_usage":' +
        '{"total_tokens":111}},"rate_limits":{"primary":' +
        '{"used_percent":11,"window_minutes":10080,' +
        '"resets_at":1893456000},"plan_type":"pro"}}}'
    )
    $tailLine = (
        '{"timestamp":"2030-01-01T00:05:00Z","type":"event_msg",' +
        '"payload":{"type":"token_count","info":{"total_token_usage":' +
        '{"total_tokens":222}},"rate_limits":{"primary":' +
        '{"used_percent":22,"window_minutes":10080,' +
        '"resets_at":1893459600},"plan_type":"pro"}}}'
    )
    $utf8 = New-Object Text.UTF8Encoding($false)

    function New-SyntheticCodexSessionFile {
        param(
            [string]$Path,
            [bool]$IncludeTailEvent
        )

        $headBytes = $utf8.GetBytes($headLine + "`n")
        $tailBytes = $utf8.GetBytes($tailLine)
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        try {
            $stream.Write($headBytes, 0, $headBytes.Length)
            if ($IncludeTailEvent) {
                $tailOffset =
                    $syntheticFileBytes - $tailBytes.Length - 1
                $stream.SetLength($tailOffset)
                $stream.Position = $tailOffset
                $stream.WriteByte(10)
                $stream.Write($tailBytes, 0, $tailBytes.Length)
            }
            else {
                $stream.SetLength($syntheticFileBytes)
            }
        }
        finally {
            $stream.Dispose()
        }
    }

    $tailOnlyPayloadSelected = $false
    $headOnlyPayloadIgnored = $false
    $headOnlyRateLimitIgnored = $false
    $tailSyntheticFileBytes = 0
    $headSyntheticFileBytes = 0
    $syntheticReadMs = 0.0
    $deepSeekAggregateCacheHit = $false
    $deepSeekAggregateCacheInvalidated = $false
    $previousUserProfile = $env:USERPROFILE
    $previousDeepSeekUsageCache = $script:DeepSeekUsageCache
    $previousDeepSeekLatestUsageCache = $script:DeepSeekLatestUsageCache
    $previousDeepSeekAggregateUsageCache = $script:DeepSeekAggregateUsageCache
    $previousDeepSeekAggregateCacheHits = $script:DeepSeekAggregateCacheHits
    $previousDeepSeekAggregateCacheMisses = $script:DeepSeekAggregateCacheMisses
    try {
        [void](New-Item -ItemType Directory -Path $syntheticRoot)
        New-SyntheticCodexSessionFile `
            -Path $tailSessionPath `
            -IncludeTailEvent $true
        New-SyntheticCodexSessionFile `
            -Path $headSessionPath `
            -IncludeTailEvent $false

        $tailSessionFile = Get-Item -LiteralPath $tailSessionPath
        $headSessionFile = Get-Item -LiteralPath $headSessionPath
        $tailSyntheticFileBytes = $tailSessionFile.Length
        $headSyntheticFileBytes = $headSessionFile.Length

        $syntheticStopwatch = [Diagnostics.Stopwatch]::StartNew()
        $tailSnapshot = Read-SessionSnapshot `
            -File $tailSessionFile
        $headSnapshot = Read-SessionSnapshot `
            -File $headSessionFile
        $syntheticStopwatch.Stop()
        $syntheticReadMs = [Math]::Round(
            $syntheticStopwatch.Elapsed.TotalMilliseconds,
            2
        )
        $tailUsage = Get-ObjectPropertyValue `
            -Object (Get-ObjectPropertyValue `
                -Object $tailSnapshot.Payload `
                -Name 'info') `
            -Name 'total_token_usage'
        $tailOnlyPayloadSelected = (
            [double](Get-ObjectPropertyValue `
                -Object $tailUsage `
                -Name 'total_tokens' `
                -Default 0) -eq 222
        )
        $headOnlyPayloadIgnored = $null -eq $headSnapshot.Payload
        $headOnlyRateLimitIgnored = (
            $null -eq $headSnapshot.RateLimitPayload
        )

        $deepSeekProjectsRoot = Join-Path $syntheticRoot '.claude\projects\cache-test'
        [void](New-Item -ItemType Directory -Path $deepSeekProjectsRoot -Force)
        $deepSeekLogPath = Join-Path $deepSeekProjectsRoot 'usage.jsonl'
        $firstTimestamp = [DateTimeOffset]::Now.Date.AddHours(10)
        $firstLine = [ordered]@{
            message = [ordered]@{
                id = 'cache-first'
                model = 'deepseek-v4-pro'
                usage = [ordered]@{
                    input_tokens = 100
                    cache_creation_input_tokens = 0
                    cache_read_input_tokens = 50
                    output_tokens = 10
                }
            }
            uuid = 'cache-first-uuid'
            timestamp = $firstTimestamp.ToString('o')
        } | ConvertTo-Json -Depth 6 -Compress
        [IO.File]::WriteAllText($deepSeekLogPath, $firstLine, $utf8)

        $env:USERPROFILE = $syntheticRoot
        $script:DeepSeekUsageCache = @{}
        $script:DeepSeekLatestUsageCache = @{}
        $script:DeepSeekAggregateUsageCache = $null
        $script:DeepSeekAggregateCacheHits = 0
        $script:DeepSeekAggregateCacheMisses = 0
        $firstDeepSeekUsage = Get-DeepSeekLocalUsage
        $secondDeepSeekUsage = Get-DeepSeekLocalUsage
        $deepSeekAggregateCacheHit = (
            $script:DeepSeekAggregateCacheHits -eq 1 -and
            $script:DeepSeekAggregateCacheMisses -eq 1 -and
            $firstDeepSeekUsage.TodayTokens -eq
                $secondDeepSeekUsage.TodayTokens
        )

        $secondTimestamp = $firstTimestamp.AddMinutes(1)
        $secondLine = [ordered]@{
            message = [ordered]@{
                id = 'cache-second'
                model = 'deepseek-v4-pro'
                usage = [ordered]@{
                    input_tokens = 200
                    cache_creation_input_tokens = 0
                    cache_read_input_tokens = 80
                    output_tokens = 20
                }
            }
            uuid = 'cache-second-uuid'
            timestamp = $secondTimestamp.ToString('o')
        } | ConvertTo-Json -Depth 6 -Compress
        [IO.File]::AppendAllText(
            $deepSeekLogPath,
            [Environment]::NewLine + $secondLine,
            $utf8
        )
        [IO.File]::SetLastWriteTimeUtc(
            $deepSeekLogPath,
            [DateTime]::UtcNow.AddSeconds(1)
        )
        $updatedDeepSeekUsage = Get-DeepSeekLocalUsage
        [void](Get-DeepSeekLocalUsage)
        $deepSeekAggregateCacheInvalidated = (
            $script:DeepSeekAggregateCacheHits -eq 2 -and
            $script:DeepSeekAggregateCacheMisses -eq 2 -and
            $updatedDeepSeekUsage.TodayTokens -gt
                $firstDeepSeekUsage.TodayTokens
        )
    }
    finally {
        $env:USERPROFILE = $previousUserProfile
        $script:DeepSeekUsageCache = $previousDeepSeekUsageCache
        $script:DeepSeekLatestUsageCache = $previousDeepSeekLatestUsageCache
        $script:DeepSeekAggregateUsageCache =
            $previousDeepSeekAggregateUsageCache
        $script:DeepSeekAggregateCacheHits =
            $previousDeepSeekAggregateCacheHits
        $script:DeepSeekAggregateCacheMisses =
            $previousDeepSeekAggregateCacheMisses
        if (
            (Test-Path -LiteralPath $syntheticRoot) -and
            $syntheticRoot.StartsWith(
                $tempRoot,
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            Remove-Item -LiteralPath $syntheticRoot -Recurse -Force
        }
    }

    [pscustomobject]@{
        MeasurementCount = $refreshMeasurements.Count
        ColdReadMs = $coldReadMs
        WarmReadMs = $warmReadMs
        WarmImprovementPercent = if ($coldReadMs -gt 0) {
            [Math]::Round(
                (($coldReadMs - $warmReadMs) / $coldReadMs) * 100,
                1
            )
        }
        else {
            0
        }
        SessionFileCount = $sessionFiles.Count
        SessionBytes = $sessionBytes
        DeepSeekMeasurementCount = $deepSeekMeasurements.Count
        DeepSeekColdReadMs = $deepSeekColdReadMs
        DeepSeekWarmReadMs = $deepSeekWarmReadMs
        DeepSeekWarmImprovementPercent = if ($deepSeekColdReadMs -gt 0) {
            [Math]::Round(
                (
                    ($deepSeekColdReadMs - $deepSeekWarmReadMs) /
                    $deepSeekColdReadMs
                ) * 100,
                1
            )
        }
        else {
            0
        }
        DeepSeekFileCount = $deepSeekFiles.Count
        DeepSeekBytes = $deepSeekBytes
        SyntheticFileBytes = $tailSyntheticFileBytes
        TailSyntheticFileBytes = $tailSyntheticFileBytes
        HeadSyntheticFileBytes = $headSyntheticFileBytes
        SyntheticReadMs = $syntheticReadMs
        TailOnlyPayloadSelected = $tailOnlyPayloadSelected
        HeadOnlyPayloadIgnored = $headOnlyPayloadIgnored
        HeadOnlyRateLimitIgnored = $headOnlyRateLimitIgnored
        DeepSeekAggregateCacheHit = $deepSeekAggregateCacheHit
        DeepSeekAggregateCacheInvalidated =
            $deepSeekAggregateCacheInvalidated
    } | ConvertTo-Json
    $script:RmfStopLoading = $true
    return
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
    $script:RmfStopLoading = $true
    return
}

if ($CheckUsageHistory) {
    $now = [DateTimeOffset]'2030-01-01T12:00:00Z'
    function New-HistoryCheckSample {
        param(
            [double]$HoursAgo,
            [double]$Value,
            [string]$ProviderId = 'Codex',
            [string]$MetricType = 'Percent',
            [string]$Unit = '%',
            [string]$ResetAtUtc = ''
        )

        return [pscustomobject]@{
            Version = 1
            ProviderId = $ProviderId
            ObservedAtUtc = $now.AddHours(-$HoursAgo)
            MetricType = $MetricType
            RemainingValue = $Value
            Unit = $Unit
            ResetAtUtc = $ResetAtUtc
        }
    }

    $resetAt = $now.AddHours(12).ToString('o')
    $depletingSamples = @(
        (New-HistoryCheckSample -HoursAgo 2 -Value 80 -ResetAtUtc $resetAt),
        (New-HistoryCheckSample -HoursAgo 1 -Value 70 -ResetAtUtc $resetAt),
        (New-HistoryCheckSample -HoursAgo 0 -Value 60 -ResetAtUtc $resetAt)
    )
    $depletingInsights = Measure-UsageInsights `
        -Samples $depletingSamples `
        -CurrentSample $depletingSamples[-1] `
        -PreviousSample $depletingSamples[-2] `
        -Now $now

    $beforeResetSamples = @(
        (New-HistoryCheckSample -HoursAgo 2 -Value 80 -ResetAtUtc $now.AddHours(4).ToString('o')),
        (New-HistoryCheckSample -HoursAgo 1 -Value 70 -ResetAtUtc $now.AddHours(4).ToString('o')),
        (New-HistoryCheckSample -HoursAgo 0 -Value 60 -ResetAtUtc $now.AddHours(4).ToString('o'))
    )
    $beforeResetForecast = Get-DepletionForecast `
        -Samples $beforeResetSamples `
        -CurrentSample $beforeResetSamples[-1] `
        -Now $now

    $resetSamples = @(
        (New-HistoryCheckSample -HoursAgo 3 -Value 10),
        (New-HistoryCheckSample -HoursAgo 2 -Value 90),
        (New-HistoryCheckSample -HoursAgo 1 -Value 80),
        (New-HistoryCheckSample -HoursAgo 0 -Value 70)
    )
    $resetForecast = Get-DepletionForecast `
        -Samples $resetSamples `
        -CurrentSample $resetSamples[-1] `
        -Now $now

    $stableSamples = @(
        (New-HistoryCheckSample -HoursAgo 2 -Value 60),
        (New-HistoryCheckSample -HoursAgo 1 -Value 60),
        (New-HistoryCheckSample -HoursAgo 0 -Value 60)
    )
    $stableForecast = Get-DepletionForecast `
        -Samples $stableSamples `
        -CurrentSample $stableSamples[-1] `
        -Now $now

    $lowSnapshot = [pscustomobject]@{
        Available = $true
        HasProgress = $true
        RemainingPercent = 18
    }
    $highPreviousSample = New-HistoryCheckSample -HoursAgo 1 -Value 26
    $lowPreviousSample = New-HistoryCheckSample -HoursAgo 1 -Value 19
    $customThresholdSnapshot = [pscustomobject]@{
        Available = $true
        HasProgress = $true
        RemainingPercent = 34
    }
    $customThresholdPreviousSample =
        New-HistoryCheckSample -HoursAgo 1 -Value 36

    $codexRapidSnapshot = [pscustomobject]@{
        ProviderId = 'Codex'
        Available = $true
        HasProgress = $true
        RemainingPercent = 65
    }
    $codexRapidSamples = @(
        (New-HistoryCheckSample -HoursAgo 0.5 -Value 80),
        (New-HistoryCheckSample -HoursAgo 0 -Value 65)
    )
    $codexRapidDrop = Measure-RapidUsageDrop `
        -Samples $codexRapidSamples `
        -Snapshot $codexRapidSnapshot `
        -WindowMinutes 30 `
        -CodexPercent 10 `
        -Now $now
    $codexRapidDropBelowThreshold = Measure-RapidUsageDrop `
        -Samples $codexRapidSamples `
        -Snapshot $codexRapidSnapshot `
        -WindowMinutes 30 `
        -CodexPercent 20 `
        -Now $now
    $codexWithoutProgress = $codexRapidSnapshot.PSObject.Copy()
    $codexWithoutProgress.HasProgress = $false
    $codexWithoutProgressRapidDrop = Measure-RapidUsageDrop `
        -Samples $codexRapidSamples `
        -Snapshot $codexWithoutProgress `
        -Now $now
    $codexWindowSamples = @(
        (New-HistoryCheckSample -HoursAgo 0.75 -Value 90),
        (New-HistoryCheckSample -HoursAgo 0 -Value 65)
    )
    $codexShortWindowDrop = Measure-RapidUsageDrop `
        -Samples $codexWindowSamples `
        -Snapshot $codexRapidSnapshot `
        -WindowMinutes 30 `
        -Now $now
    $codexLongWindowDrop = Measure-RapidUsageDrop `
        -Samples $codexWindowSamples `
        -Snapshot $codexRapidSnapshot `
        -WindowMinutes 60 `
        -Now $now

    $deepSeekRapidSnapshot = [pscustomobject]@{
        ProviderId = 'DeepSeek'
        Available = $true
        HasProgress = $true
        RemainingPercent = 72
        TotalBalance = 86.4
        Currency = 'CNY'
    }
    $deepSeekBalanceSamples = @(
        (New-HistoryCheckSample `
            -ProviderId 'DeepSeek' `
            -HoursAgo 0.5 `
            -Value 100 `
            -MetricType 'Balance' `
            -Unit 'CNY'),
        (New-HistoryCheckSample `
            -ProviderId 'DeepSeek' `
            -HoursAgo 0 `
            -Value 86.4 `
            -MetricType 'Balance' `
            -Unit 'CNY')
    )
    $deepSeekAmountRapidDrop = Measure-RapidUsageDrop `
        -Samples $deepSeekBalanceSamples `
        -Snapshot $deepSeekRapidSnapshot `
        -WindowMinutes 30 `
        -DeepSeekMode 'Amount' `
        -DeepSeekAmount 10 `
        -Now $now
    $deepSeekPercentSamples = @(
        (New-HistoryCheckSample `
            -ProviderId 'DeepSeek' `
            -HoursAgo 0.5 `
            -Value 80),
        (New-HistoryCheckSample `
            -ProviderId 'DeepSeek' `
            -HoursAgo 0 `
            -Value 68)
    )
    $deepSeekPercentRapidDrop = Measure-RapidUsageDrop `
        -Samples $deepSeekPercentSamples `
        -Snapshot $deepSeekRapidSnapshot `
        -WindowMinutes 30 `
        -DeepSeekMode 'Percent' `
        -DeepSeekPercent 10 `
        -Now $now
    $deepSeekWithoutBudget = [pscustomobject]@{
        ProviderId = 'DeepSeek'
        Available = $true
        HasProgress = $false
        TotalBalance = 86.4
        Currency = 'CNY'
    }
    $deepSeekPercentUnavailable = Measure-RapidUsageDrop `
        -Samples @() `
        -Snapshot $deepSeekWithoutBudget `
        -DeepSeekMode 'Percent' `
        -Now $now
    $deepSeekHistorySamples = @(
        ConvertTo-UsageHistorySamples `
            -Snapshot $deepSeekRapidSnapshot `
            -ObservedAt $now
    )
    $fractionalPercentSnapshot = $codexRapidSnapshot.PSObject.Copy()
    $fractionalPercentSnapshot.RemainingPercent = 72.4
    $fractionalPercentSample = ConvertTo-UsageHistorySample `
        -Snapshot $fractionalPercentSnapshot `
        -ObservedAt $now
    $fractionalBalanceSnapshot = $deepSeekWithoutBudget.PSObject.Copy()
    $fractionalBalanceSample = ConvertTo-UsageHistorySample `
        -Snapshot $fractionalBalanceSnapshot `
        -ObservedAt $now

    $historyTestPath = Join-Path ([IO.Path]::GetTempPath()) (
        'RemainingMarginFloat.HistoryDiagnostic.{0}.jsonl' -f $PID
    )
    $historyImportPath = Join-Path ([IO.Path]::GetTempPath()) (
        'RemainingMarginFloat.HistoryImportDiagnostic.{0}.jsonl' -f $PID
    )
    $legacyHistoryPath = Join-Path ([IO.Path]::GetTempPath()) (
        'RemainingMarginFloat.HistoryLegacyDiagnostic.{0}.jsonl' -f $PID
    )
    $invalidHistoryPath = Join-Path ([IO.Path]::GetTempPath()) (
        'RemainingMarginFloat.HistoryInvalidDiagnostic.{0}.jsonl' -f $PID
    )
    $oversizedHistoryPath = Join-Path ([IO.Path]::GetTempPath()) (
        'RemainingMarginFloat.HistoryOversizedDiagnostic.{0}.jsonl' -f $PID
    )
    $calendarTimeZone = [TimeZoneInfo]::CreateCustomTimeZone(
        'RMF Diagnostic UTC+08',
        [TimeSpan]::FromHours(8),
        'RMF Diagnostic UTC+08',
        'RMF Diagnostic UTC+08'
    )
    $persistenceRoundTrip = $false
    $restartReloadRoundTrip = $false
    $legacyMigration = $false
    $calendarDateAligned = $false
    $importMergeRoundTrip = $false
    $invalidImportRejected = $false
    $oversizedImportRejected = $false
    $futureSampleExcluded = $false
    $diagnosticRedaction = $false
    try {
        Save-UsageHistory `
            -Samples $depletingSamples `
            -Path $historyTestPath `
            -Now $now `
            -TimeZone $calendarTimeZone `
            -AllowDiagnosticWrite
        # The second save exercises atomic replacement of an existing file.
        Save-UsageHistory `
            -Samples $depletingSamples `
            -Path $historyTestPath `
            -Now $now `
            -TimeZone $calendarTimeZone `
            -AllowDiagnosticWrite
        $savedLines = @(Get-Content -LiteralPath $historyTestPath -Encoding UTF8)
        $savedSample = $savedLines[0] | ConvertFrom-Json
        $persistenceRoundTrip = (
            $savedLines.Count -eq 3 -and
            $savedSample.v -eq 2 -and
            $savedSample.ProviderId -eq 'Codex' -and
            $savedSample.MetricType -eq 'Percent' -and
            $savedSample.PSObject.Properties.Name -contains 'LocalDate' -and
            $savedSample.TimeZoneId -eq $calendarTimeZone.Id -and
            $savedSample.PSObject.Properties.Name -notcontains 'AccountName' -and
            $savedSample.PSObject.Properties.Name -notcontains 'ApiKey'
        )

        $script:UsageHistoryCache = $null
        $reloaded = @(
            Read-UsageHistory `
                -Path $historyTestPath `
                -Now $now `
                -TimeZone $calendarTimeZone `
                -BypassCache
        )
        $restartReloadRoundTrip = (
            $reloaded.Count -eq 3 -and
            $reloaded[0].Version -eq 2 -and
            $reloaded[-1].RemainingValue -eq 60
        )

        $calendarRecord = [ordered]@{
            v = 1
            ProviderId = 'Codex'
            ObservedAtUtc = '2029-12-31T16:30:00.0000000+00:00'
            MetricType = 'Percent'
            RemainingValue = 50
            Unit = '%'
            ResetAtUtc = ''
        } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText(
            $legacyHistoryPath,
            $calendarRecord,
            (New-Object Text.UTF8Encoding($false))
        )
        $legacyReloaded = @(
            Read-UsageHistory `
                -Path $legacyHistoryPath `
                -Now $now `
                -TimeZone $calendarTimeZone `
                -BypassCache
        )
        $legacyMigration = (
            $legacyReloaded.Count -eq 1 -and
            $legacyReloaded[0].Version -eq 2
        )
        $calendarDateAligned = (
            $legacyReloaded.Count -eq 1 -and
            $legacyReloaded[0].LocalDate -eq '2030-01-01' -and
            $legacyReloaded[0].UtcOffsetMinutes -eq 480
        )

        $importResult = Import-UsageHistory `
            -Path $historyTestPath `
            -DestinationPath $historyImportPath `
            -Now $now `
            -AllowDiagnosticWrite
        $importedReload = @(
            Read-UsageHistory `
                -Path $historyImportPath `
                -Now $now `
                -BypassCache
        )
        $importMergeRoundTrip = (
            $importResult.ImportedCount -eq 3 -and
            $importResult.TotalCount -eq 3 -and
            $importedReload.Count -eq 3
        )

        [IO.File]::WriteAllText(
            $invalidHistoryPath,
            '{"not":"a usage sample"}',
            (New-Object Text.UTF8Encoding($false))
        )
        try {
            Import-UsageHistory `
                -Path $invalidHistoryPath `
                -DestinationPath $historyImportPath `
                -Now $now `
                -AllowDiagnosticWrite | Out-Null
        }
        catch {
            $invalidImportRejected = $true
        }

        $oversizedStream = [IO.File]::OpenWrite($oversizedHistoryPath)
        try {
            $oversizedStream.SetLength(16MB + 1)
        }
        finally {
            $oversizedStream.Dispose()
        }
        try {
            Import-UsageHistory `
                -Path $oversizedHistoryPath `
                -DestinationPath $historyImportPath `
                -Now $now `
                -AllowDiagnosticWrite | Out-Null
        }
        catch {
            $oversizedImportRejected = $true
        }

        $futureSample = New-HistoryCheckSample -HoursAgo -24 -Value 1
        $futureTrend = Get-UsageTrend `
            -Samples @($depletingSamples + $futureSample) `
            -CurrentSample $depletingSamples[-1] `
            -Hours (24 * 7) `
            -Now $now
        $futureSampleExcluded = (
            $futureTrend.Change -eq -20 -and
            $futureTrend.Samples.Count -eq 3
        )

        $sensitiveDiagnosticText = (
            '{0}\private user@example.com sk-1234567890abcdef ' +
            'api_key=diagnostic-secret Bearer abcdefghijklmnop ' +
            'Authorization: Bearer authorization-secret'
        ) -f $env:USERPROFILE
        $redactedDiagnosticText =
            Protect-RuntimeDiagnosticText -Text $sensitiveDiagnosticText
        $diagnosticRedaction = (
            $redactedDiagnosticText -notmatch [regex]::Escape($env:USERPROFILE) -and
            $redactedDiagnosticText -notmatch 'user@example.com' -and
            $redactedDiagnosticText -notmatch 'sk-1234567890abcdef' -and
            $redactedDiagnosticText -notmatch 'diagnostic-secret' -and
            $redactedDiagnosticText -notmatch 'abcdefghijklmnop' -and
            $redactedDiagnosticText -notmatch 'authorization-secret'
        )
    }
    finally {
        foreach ($testPath in @(
            $historyTestPath
            $historyImportPath
            $legacyHistoryPath
            $invalidHistoryPath
            $oversizedHistoryPath
        )) {
            if (Test-Path -LiteralPath $testPath) {
                Remove-Item -LiteralPath $testPath -Force
            }
        }
    }

    [pscustomobject]@{
        Trend24Change = $depletingInsights.Trend24Hours.Change
        Trend7Change = $depletingInsights.Trend7Days.Change
        DepletionStatus = $depletingInsights.Forecast.Status
        DepletionHours = [Math]::Round(
            [double]$depletingInsights.Forecast.HoursToEmpty,
            2
        )
        ResetBoundaryRespected = $beforeResetForecast.Status -eq 'BeyondReset'
        ResetJumpStartsNewSegment = (
            $resetForecast.Status -eq 'Depleting' -and
            [Math]::Abs([double]$resetForecast.HoursToEmpty - 7) -lt 0.01
        )
        StableUsageDetected = $stableForecast.Status -eq 'Stable'
        LowThresholdCrossingDetected = Test-LowRemainingAlertCondition `
            -Snapshot $lowSnapshot `
            -PreviousSample $highPreviousSample
        RepeatedLowAlertSuppressed = -not (
            Test-LowRemainingAlertCondition `
                -Snapshot $lowSnapshot `
                -PreviousSample $lowPreviousSample
        )
        CustomLowThresholdCrossingDetected =
            Test-LowRemainingAlertCondition `
                -Snapshot $customThresholdSnapshot `
                -PreviousSample $customThresholdPreviousSample `
                -Threshold 35
        CodexRapidDropDetected = (
            [bool]$codexRapidDrop.Available -and
            [bool]$codexRapidDrop.IsRapid -and
            [Math]::Abs([double]$codexRapidDrop.Drop - 15) -lt 0.0001
        )
        CodexRapidDropThresholdRespected = -not (
            [bool]$codexRapidDropBelowThreshold.IsRapid
        )
        CodexRapidDropRequiresProgress = -not (
            [bool]$codexWithoutProgressRapidDrop.Available
        )
        RapidDropTimeWindowRespected = (
            -not [bool]$codexShortWindowDrop.Available -and
            [bool]$codexLongWindowDrop.Available -and
            [bool]$codexLongWindowDrop.IsRapid -and
            [Math]::Abs([double]$codexLongWindowDrop.Drop - 25) -lt 0.0001
        )
        DeepSeekAmountRapidDropDetected = (
            [bool]$deepSeekAmountRapidDrop.Available -and
            [bool]$deepSeekAmountRapidDrop.IsRapid -and
            $deepSeekAmountRapidDrop.MetricType -eq 'Balance' -and
            [Math]::Abs(
                [double]$deepSeekAmountRapidDrop.Drop - 13.6
            ) -lt 0.0001
        )
        DeepSeekPercentRapidDropDetected = (
            [bool]$deepSeekPercentRapidDrop.Available -and
            [bool]$deepSeekPercentRapidDrop.IsRapid -and
            [Math]::Abs(
                [double]$deepSeekPercentRapidDrop.Drop - 12
            ) -lt 0.0001
        )
        DeepSeekPercentRequiresBudget = (
            -not [bool]$deepSeekPercentUnavailable.Available
        )
        DeepSeekDualMetricHistory = (
            $deepSeekHistorySamples.Count -eq 2 -and
            @($deepSeekHistorySamples.MetricType) -contains 'Percent' -and
            @($deepSeekHistorySamples.MetricType) -contains 'Balance'
        )
        FractionalHistoryPrecision = (
            [Math]::Abs(
                [double]$fractionalPercentSample.RemainingValue - 72.4
            ) -lt 0.0001 -and
            [Math]::Abs(
                [double]$fractionalBalanceSample.RemainingValue - 86.4
            ) -lt 0.0001
        )
        RapidDropWindowValidation = (
            (ConvertTo-RapidDropWindowMinutes `
                -Value 45 `
                -Fallback 30) -eq 45 -and
            (ConvertTo-RapidDropWindowMinutes `
                -Value 'invalid' `
                -Fallback 30) -eq 30
        )
        RapidDropThresholdValidation = (
            (ConvertTo-RapidDropPercent `
                -Value 12.5 `
                -Fallback 10) -eq 12.5 -and
            (ConvertTo-RapidDropAmount `
                -Value 8.5 `
                -Fallback 10) -eq 8.5
        )
        PersistenceRoundTrip = $persistenceRoundTrip
        RestartReloadRoundTrip = $restartReloadRoundTrip
        LegacyHistoryMigration = $legacyMigration
        CalendarDateAligned = $calendarDateAligned
        ImportMergeRoundTrip = $importMergeRoundTrip
        InvalidImportRejected = $invalidImportRejected
        OversizedImportRejected = $oversizedImportRejected
        FutureSampleExcluded = $futureSampleExcluded
        DiagnosticRedaction = $diagnosticRedaction
        HistorySampleContainsNoAccountData = (
            $depletingSamples[-1].PSObject.Properties.Name -notcontains 'AccountName' -and
            $depletingSamples[-1].PSObject.Properties.Name -notcontains 'AccountEmail' -and
            $depletingSamples[-1].PSObject.Properties.Name -notcontains 'ApiKey'
        )
    } | ConvertTo-Json
    $script:RmfStopLoading = $true
    return
}

if ($CheckDeepSeekUsage) {
    Get-DeepSeekLocalUsage | ConvertTo-Json -Depth 5
    $script:RmfStopLoading = $true
    return
}

if ($CheckData) {
    Get-CodexUsageSnapshot | ConvertTo-Json -Depth 5
    $script:RmfStopLoading = $true
    return
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
    $script:RmfStopLoading = $true
    return
}

if ($CheckEdgeDocking) {
    $scaledTaskbarArea = ConvertTo-LogicalWorkArea `
        -PixelLeft 0 `
        -PixelTop 60 `
        -PixelRight 1920 `
        -PixelBottom 1080 `
        -DpiScaleX 1.5 `
        -DpiScaleY 1.5
    $negativeMonitorArea = ConvertTo-LogicalWorkArea `
        -PixelLeft -2560 `
        -PixelTop 0 `
        -PixelRight 0 `
        -PixelBottom 1440 `
        -DpiScaleX 1.25 `
        -DpiScaleY 1.25
    [pscustomobject]@{
        LeftDetected = Get-EdgeDockSideForPosition `
            -Left 8 `
            -Width $script:CompactWidth `
            -WorkLeft 0 `
            -WorkRight 1920 `
            -SnapDistance $script:EdgeSnapDistance
        RightDetected = Get-EdgeDockSideForPosition `
            -Left (1920 - $script:CompactWidth - 9) `
            -Width $script:CompactWidth `
            -WorkLeft 0 `
            -WorkRight 1920 `
            -SnapDistance $script:EdgeSnapDistance
        CenterDetected = Get-EdgeDockSideForPosition `
            -Left 900 `
            -Width $script:CompactWidth `
            -WorkLeft 0 `
            -WorkRight 1920 `
            -SnapDistance $script:EdgeSnapDistance
        LeftHidden = Get-EdgeDockPlacement `
            -Side Left `
            -Revealed $false `
            -WindowWidth $script:CompactWidth `
            -VisibleWidth $script:EdgeVisibleWidth `
            -WorkLeft 0 `
            -WorkRight 1920
        RightHidden = Get-EdgeDockPlacement `
            -Side Right `
            -Revealed $false `
            -WindowWidth $script:CompactWidth `
            -VisibleWidth $script:EdgeVisibleWidth `
            -WorkLeft 0 `
            -WorkRight 1920
        MultiDpiWorkAreaConverted = (
            [Math]::Abs($scaledTaskbarArea.Width - 1280) -lt 0.001 -and
            [Math]::Abs($scaledTaskbarArea.Height - 680) -lt 0.001
        )
        TaskbarWorkAreaPreserved = (
            [Math]::Abs($scaledTaskbarArea.Top - 40) -lt 0.001 -and
            [Math]::Abs($scaledTaskbarArea.Bottom - 720) -lt 0.001
        )
        NegativeMonitorCoordinatesPreserved = (
            [Math]::Abs($negativeMonitorArea.Left - (-2048)) -lt 0.001 -and
            [Math]::Abs($negativeMonitorArea.Width - 2048) -lt 0.001
        )
        WorkAreaChangeDetected = (
            -not (Test-WorkAreaEquivalent `
                -First $scaledTaskbarArea `
                -Second $negativeMonitorArea)
        )
    } | ConvertTo-Json
    $script:RmfStopLoading = $true
    return
}
