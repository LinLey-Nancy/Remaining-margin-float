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
            secondary_window = [pscustomobject]@{
                used_percent = 18.0
                limit_window_seconds = 18000
                reset_at = 1893474000
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
    $localDualPayloads = @(
        [pscustomobject]@{
            rate_limits = [pscustomobject]@{
                primary = [pscustomobject]@{
                    used_percent = 40.0
                    window_minutes = 10080
                    resets_at = 1894060800
                }
                secondary = [pscustomobject]@{
                    used_percent = 18.0
                    window_minutes = 300
                    resets_at = 1893474000
                }
                plan_type = 'pro'
            }
        },
        [pscustomobject]@{
            rate_limits = [pscustomobject]@{
                primary = [pscustomobject]@{
                    used_percent = 18.0
                    window_minutes = 300
                    resets_at = 1893474000
                }
                secondary = [pscustomobject]@{
                    used_percent = 40.0
                    window_minutes = 10080
                    resets_at = 1894060800
                }
                plan_type = 'pro'
            }
        }
    )
    $localDualUsages = @(
        for ($index = 0; $index -lt $localDualPayloads.Count; $index++) {
            Resolve-CodexQuotaUsage `
                -OfficialUsage $null `
                -SessionSnapshots @(
                    [pscustomobject]@{
                        RateLimitPayload = $localDualPayloads[$index]
                        RateLimitObservedAt = (
                            [DateTimeOffset]'2030-01-01T00:00:00Z'
                        ).AddMinutes($index)
                    }
                ) `
                -Now ([DateTimeOffset]'2030-01-01T00:05:00Z')
        }
    )
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
            $officialUsage.UsedPercent -eq 18 -and
            $officialUsage.WindowMinutes -eq 300 -and
            $officialUsage.FiveHourWindow.UsedPercent -eq 18 -and
            $officialUsage.WeeklyWindow.UsedPercent -eq 40 -and
            $officialUsage.PlanType -eq 'prolite'
        )
        AdditionalModelLimitIgnored = $officialUsage.UsedPercent -ne 0
        OfficialChannelPreferred = (
            $officialQuotaUsage.Channel -eq 'Official' -and
            $officialQuotaUsage.UsedPercent -eq 18 -and
            $officialQuotaUsage.WeeklyWindow.UsedPercent -eq 40
        )
        LocalChannelFallbackSelected = (
            $localQuotaUsage.Channel -eq 'Local' -and
            $localQuotaUsage.UsedPercent -eq 0 -and
            $null -eq $localQuotaUsage.FiveHourWindow -and
            $localQuotaUsage.WeeklyWindow.UsedPercent -eq 22 -and
            $localQuotaUsage.PlanType -eq 'pro'
        )
        LocalDualWindowsOrderIndependent = (
            $localDualUsages.Count -eq 2 -and
            @($localDualUsages | Where-Object {
                $_.Channel -eq 'Local' -and
                $_.UsedPercent -eq 18 -and
                $_.FiveHourWindow.UsedPercent -eq 18 -and
                $_.FiveHourWindow.WindowMinutes -eq 300 -and
                $_.WeeklyWindow.UsedPercent -eq 40 -and
                $_.WeeklyWindow.WindowMinutes -eq 10080
            }).Count -eq 2
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
    $kimiUsageFixturePath = Join-Path $fixtureRoot 'kimi-usages.json'
    $kimiWireFixturePath = Join-Path $fixtureRoot 'kimi-usage.jsonl'
    foreach ($fixturePath in @(
        $codexFixturePath
        $deepSeekBalanceFixturePath
        $deepSeekUsageFixturePath
        $kimiUsageFixturePath
        $kimiWireFixturePath
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
    $codexSnapshot = Get-CodexUsageSnapshot `
        -OfficialUsageOverride $codexUsage `
        -SkipOfficialRequest
    $proWithoutWeeklyUsage = $codexUsage.PSObject.Copy()
    $proWithoutWeeklyUsage.WeeklyWindow = $null
    $proWithoutWeeklySnapshot = Get-CodexUsageSnapshot `
        -OfficialUsageOverride $proWithoutWeeklyUsage `
        -SkipOfficialRequest

    $deepSeekEvents = @([DeepSeekLogScanner]::ReadFile($deepSeekUsageFixturePath))
    $deepSeekPrimaryEvent = $deepSeekEvents |
        Where-Object { $_.MessageId -eq 'fixture-message' } |
        Select-Object -First 1
    $deepSeekPrimaryCost = Get-DeepSeekEstimatedEventCostCny `
        -UsageEvent $deepSeekPrimaryEvent
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
        -SourceLabel '契约样例' `
        -SampledAt ([datetime]'2030-01-01T12:00:00')
    Assert-UsageSnapshotContract -Snapshot $deepSeekSnapshot

    $kimiPayload = Get-Content -LiteralPath $kimiUsageFixturePath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $kimiUsage = ConvertTo-KimiOfficialUsage `
        -Payload $kimiPayload `
        -SampledAt ([DateTimeOffset]'2030-01-01T12:00:00Z')
    $kimiSnapshot = Get-KimiUsageSnapshot `
        -OfficialUsageOverride $kimiUsage `
        -SkipOfficialRequest
    Assert-UsageSnapshotContract -Snapshot $kimiSnapshot
    $kimiExpiredUsage = $kimiUsage.PSObject.Copy()
    $kimiExpiredFiveHour = $kimiUsage.FiveHourWindow.PSObject.Copy()
    $kimiExpiredFiveHour.ResetsAt = (
        [DateTimeOffset]'2030-01-01T11:59:00Z'
    ).ToUnixTimeSeconds()
    $kimiExpiredUsage.FiveHourWindow = $kimiExpiredFiveHour
    $kimiCurrentUsage = Get-KimiCurrentUsageOverride `
        -OfficialUsage $kimiUsage `
        -Now ([DateTimeOffset]'2030-01-01T12:00:00Z')
    $kimiExpiredCurrentUsage = Get-KimiCurrentUsageOverride `
        -OfficialUsage $kimiExpiredUsage `
        -Now ([DateTimeOffset]'2030-01-09T12:00:00Z')
    $kimiWireEvents = @(
        Get-Content -LiteralPath $kimiWireFixturePath -Encoding UTF8 |
            ForEach-Object { ConvertFrom-KimiWireUsageLine -Line $_ } |
            Where-Object { $_ }
    )
    $kimiWireLatest = $kimiWireEvents |
        Sort-Object Timestamp -Descending |
        Select-Object -First 1
    $kimiUsagesOnlyPayload = [pscustomobject]@{
        usage = [pscustomobject]@{
            limit = '100'
            used = '2'
            remaining = '98'
            resetTime = '2030-01-08T12:00:00.000000Z'
        }
        limits = @()
        usages = [pscustomobject]@{
            limit_5h = [pscustomobject]@{
                used_ratio = 0.25
                reset_time = '2030-01-01T17:00:00.000000Z'
            }
        }
    }
    $kimiUsagesFallbackUsage = ConvertTo-KimiOfficialUsage `
        -Payload $kimiUsagesOnlyPayload `
        -SampledAt ([DateTimeOffset]'2030-01-01T12:00:00Z')
    $kimiUsagesFallbackSnapshot = Get-KimiUsageSnapshot `
        -OfficialUsageOverride $kimiUsagesFallbackUsage `
        -SkipOfficialRequest
    $kimiUsagesWeeklyOnlyPayload = [pscustomobject]@{
        usages = [pscustomobject]@{
            limit_7d = [pscustomobject]@{
                used_ratio = 0.4
                reset_time = '2030-01-08T12:00:00.000000Z'
            }
        }
    }
    $kimiUsagesWeeklyFallbackUsage = ConvertTo-KimiOfficialUsage `
        -Payload $kimiUsagesWeeklyOnlyPayload `
        -SampledAt ([DateTimeOffset]'2030-01-01T12:00:00Z')
    $kimiLimitsPrecedencePayload = [pscustomobject]@{
        limits = @(
            [pscustomobject]@{
                window = [pscustomobject]@{
                    duration = 300
                    timeUnit = 'TIME_UNIT_MINUTE'
                }
                detail = [pscustomobject]@{
                    limit = '100'
                    used = '10'
                    remaining = '90'
                    resetTime = '2030-01-01T17:00:00.000000Z'
                }
            }
        )
        usages = [pscustomobject]@{
            limit_5h = [pscustomobject]@{
                used_ratio = 0.5
                reset_time = '2030-01-01T16:00:00.000000Z'
            }
        }
    }
    $kimiLimitsPrecedenceUsage = ConvertTo-KimiOfficialUsage `
        -Payload $kimiLimitsPrecedencePayload `
        -SampledAt ([DateTimeOffset]'2030-01-01T12:00:00Z')
    $kimiMalformedUsagesPayload = [pscustomobject]@{
        usages = [pscustomobject]@{
            limit_5h = [pscustomobject]@{
                used_ratio = 'NaN'
                reset_time = '2030-01-01T17:00:00.000000Z'
            }
            limit_7d = [pscustomobject]@{
                used_ratio = 0.4
                reset_time = 'not-a-time'
            }
        }
    }
    $kimiMalformedUsagesUsage = ConvertTo-KimiOfficialUsage `
        -Payload $kimiMalformedUsagesPayload `
        -SampledAt ([DateTimeOffset]'2030-01-01T12:00:00Z')
    # 桌面端登录会写入 [providers."managed:..."] 托管条目（key 可能已过期），
    # 显式配置的 provider 应优先；仅有托管条目时仍使用它。
    $kimiDesktopProviders = @(
        [pscustomobject]@{
            Name = '"managed:kimi-code"'
            BaseUrl = 'https://api.kimi.com/coding/v1'
            ApiKey = 'sk-kimi-managed-stale'
        }
        [pscustomobject]@{
            Name = 'kimi-for-coding'
            BaseUrl = 'https://api.kimi.com/coding'
            ApiKey = 'sk-kimi-explicit-key'
        }
    )
    $kimiDesktopSelectedProvider = Select-KimiConfigProvider `
        -Providers $kimiDesktopProviders
    $kimiManagedOnlyProvider = Select-KimiConfigProvider `
        -Providers @($kimiDesktopProviders[0])
    $kimiEmptyProviderSelection = Select-KimiConfigProvider -Providers @()
    $currentOfficialUsage = Get-CodexCurrentUsageOverride `
        -OfficialUsage $codexUsage `
        -Now ([DateTimeOffset]'2030-01-01T12:00:00Z')
    $expiredOfficialUsage = $codexUsage.PSObject.Copy()
    $expiredOfficialUsage.PlanType = 'plus'
    $expiredFiveHourWindow = $codexUsage.FiveHourWindow.PSObject.Copy()
    $expiredFiveHourWindow.ResetsAt = (
        [DateTimeOffset]'2030-01-01T11:59:00Z'
    ).ToUnixTimeSeconds()
    $expiredOfficialUsage.FiveHourWindow = $expiredFiveHourWindow
    $expiredCurrentUsage = Get-CodexCurrentUsageOverride `
        -OfficialUsage $expiredOfficialUsage `
        -Now ([DateTimeOffset]'2030-01-01T12:00:00Z')
    $proUsageWithExpiredFiveHour = $codexUsage.PSObject.Copy()
    $proUsageWithExpiredFiveHour.FiveHourWindow = $expiredFiveHourWindow
    $currentProWeeklyUsage = Get-CodexCurrentUsageOverride `
        -OfficialUsage $proUsageWithExpiredFiveHour `
        -Now ([DateTimeOffset]'2030-01-01T12:00:00Z')
    $fixtureLocalRateLimitPayload = [pscustomobject]@{
        rate_limits = [pscustomobject]@{
            primary = [pscustomobject]@{
                used_percent = 22.0
                window_minutes = 10080
                resets_at = 1894060800
            }
            plan_type = 'pro'
        }
    }
    $expiredFallbackUsage = Resolve-CodexQuotaUsage `
        -OfficialUsage $expiredCurrentUsage `
        -SessionSnapshots @(
            [pscustomobject]@{
                RateLimitPayload = $fixtureLocalRateLimitPayload
                RateLimitObservedAt = [DateTimeOffset]'2030-01-01T11:58:00Z'
            }
        ) `
        -Now ([DateTimeOffset]'2030-01-01T12:00:00Z')
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
        CodexFiveHourUsedPercent = $codexUsage.FiveHourWindow.UsedPercent
        CodexWeeklyUsedPercent = $codexUsage.WeeklyWindow.UsedPercent
        CodexPlan = $codexUsage.PlanType
        CodexPlusPrimaryPeriod = Get-CodexPrimaryQuotaPeriod -PlanType 'plus'
        CodexProPrimaryPeriod = Get-CodexPrimaryQuotaPeriod -PlanType 'pro'
        CodexProLitePrimaryPeriod = Get-CodexPrimaryQuotaPeriod -PlanType 'prolite'
        CodexProAliasPeriods = @(
            Get-CodexPrimaryQuotaPeriod -PlanType 'pro-lite'
            Get-CodexPrimaryQuotaPeriod -PlanType 'Pro Lite'
            Get-CodexPrimaryQuotaPeriod -PlanType 'pro_lite'
        )
        CodexSnapshotPrimaryPeriod = $codexSnapshot.PrimaryQuotaPeriod
        CodexSnapshotRemainingPercent = $codexSnapshot.RemainingPercent
        CodexSnapshotFiveHourUsedPercent = $codexSnapshot.FiveHourUsedPercent
        CodexSnapshotFiveHourRemainingPercent = $codexSnapshot.FiveHourRemainingPercent
        CodexSnapshotWeeklyUsedPercent = $codexSnapshot.WeeklyUsedPercent
        CodexSnapshotWeeklyRemainingPercent = $codexSnapshot.WeeklyRemainingPercent
        CodexProWithoutWeeklyRemainsUnknown = (
            $proWithoutWeeklySnapshot.PrimaryQuotaPeriod -eq 'Weekly' -and
            -not [bool]$proWithoutWeeklySnapshot.HasProgress -and
            $proWithoutWeeklySnapshot.WindowLabel -eq '每周余量未知' -and
            [bool]$proWithoutWeeklySnapshot.FiveHourAvailable -and
            -not [bool]$proWithoutWeeklySnapshot.WeeklyAvailable
        )
        CodexNonFiniteQuotaValuesRejected = (
            $null -eq (ConvertTo-CodexQuotaWindow `
                -Window ([pscustomobject]@{
                    used_percent = 'NaN'
                    limit_window_seconds = 18000
                    reset_at = 1893459600
                }) `
                -Format 'Official') -and
            $null -eq (ConvertTo-CodexQuotaWindow `
                -Window ([pscustomobject]@{
                    used_percent = 18
                    limit_window_seconds = 'Infinity'
                    reset_at = 1893459600
                }) `
                -Format 'Official') -and
            $null -eq (ConvertTo-CodexQuotaWindow `
                -Window ([pscustomobject]@{
                    used_percent = 18
                    limit_window_seconds = 1e300
                    reset_at = 1893459600
                }) `
                -Format 'Official')
        )
        DeepSeekEventCount = $deepSeekEvents.Count
        DeepSeekPrimaryTokens = $deepSeekPrimaryEvent.TotalTokens
        DeepSeekPrimaryCostCny = $deepSeekPrimaryCost
        DeepSeekAvailable = $deepSeekSnapshot.Available
        DeepSeekBalance = $deepSeekSnapshot.TotalBalance
        DeepSeekBudgetPercent = $deepSeekSnapshot.BudgetPercent
        KimiFiveHourUsedPercent = $kimiUsage.FiveHourWindow.UsedPercent
        KimiWeeklyUsedPercent = $kimiUsage.WeeklyWindow.UsedPercent
        KimiPlan = $kimiUsage.PlanType
        KimiSnapshotPrimaryPeriod = $kimiSnapshot.PrimaryQuotaPeriod
        KimiSnapshotRemainingPercent = $kimiSnapshot.RemainingPercent
        KimiSnapshotFiveHourRemainingPercent = $kimiSnapshot.FiveHourRemainingPercent
        KimiSnapshotWeeklyRemainingPercent = $kimiSnapshot.WeeklyRemainingPercent
        KimiPlanLabel = Get-KimiPlanLabel -PlanType 'LEVEL_ADVANCED'
        KimiNonFiniteQuotaValuesRejected = (
            $null -eq (ConvertTo-KimiQuotaWindow `
                -Detail ([pscustomobject]@{
                    used = 'NaN'
                    resetTime = '2030-01-01T17:00:00Z'
                }) `
                -WindowMinutes 300) -and
            $null -eq (ConvertTo-KimiQuotaWindow `
                -Detail ([pscustomobject]@{
                    used = '18'
                    resetTime = 'not-a-time'
                }) `
                -WindowMinutes 300) -and
            $null -eq (ConvertTo-KimiOfficialUsage -Payload ([pscustomobject]@{}))
        )
        KimiCacheDropsExpiredWindows = (
            $null -eq $kimiExpiredCurrentUsage -and
            $null -ne $kimiCurrentUsage -and
            $kimiCurrentUsage.FiveHourWindow.UsedPercent -eq 10 -and
            $kimiCurrentUsage.WeeklyWindow.UsedPercent -eq 2 -and
            [bool]$kimiCurrentUsage.IsCached
        )
        KimiUsagesSummaryFallback = (
            $null -ne $kimiUsagesFallbackUsage -and
            [Math]::Abs(
                [double]$kimiUsagesFallbackUsage.FiveHourWindow.UsedPercent - 25
            ) -lt 0.0001 -and
            [Math]::Abs(
                [double]$kimiUsagesFallbackUsage.WeeklyWindow.UsedPercent - 2
            ) -lt 0.0001 -and
            $kimiUsagesFallbackSnapshot.PrimaryQuotaPeriod -eq 'FiveHour' -and
            $kimiUsagesFallbackSnapshot.FiveHourRemainingPercent -eq 75 -and
            [bool]$kimiUsagesFallbackSnapshot.FiveHourAvailable
        )
        KimiUsagesWeeklyFallback = (
            $null -ne $kimiUsagesWeeklyFallbackUsage -and
            $null -eq $kimiUsagesWeeklyFallbackUsage.FiveHourWindow -and
            [Math]::Abs(
                [double]$kimiUsagesWeeklyFallbackUsage.WeeklyWindow.UsedPercent - 40
            ) -lt 0.0001
        )
        KimiLimitsPreferredOverUsagesSummary = (
            $null -ne $kimiLimitsPrecedenceUsage -and
            [Math]::Abs(
                [double]$kimiLimitsPrecedenceUsage.FiveHourWindow.UsedPercent - 10
            ) -lt 0.0001 -and
            $kimiLimitsPrecedenceUsage.FiveHourWindow.ResetsAt -eq (
                [DateTimeOffset]'2030-01-01T17:00:00Z'
            ).ToUnixTimeSeconds()
        )
        KimiMalformedUsagesSummaryRejected = (
            $null -eq $kimiMalformedUsagesUsage
        )
        KimiConfigPrefersExplicitProviderOverManaged = (
            $null -ne $kimiDesktopSelectedProvider -and
            $kimiDesktopSelectedProvider.Name -eq 'kimi-for-coding'
        )
        KimiConfigManagedProviderUsedWhenOnlyOption = (
            $null -ne $kimiManagedOnlyProvider -and
            $kimiManagedOnlyProvider.ApiKey -eq 'sk-kimi-managed-stale'
        )
        KimiConfigEmptySelectionReturnsNull = (
            $null -eq $kimiEmptyProviderSelection
        )
        KimiWireEventCount = $kimiWireEvents.Count
        KimiWireLatestTokens = (
            $kimiWireLatest.InputTokens +
            $kimiWireLatest.OutputTokens +
            $kimiWireLatest.CachedTokens +
            $kimiWireLatest.CacheWriteTokens
        )
        KimiWireLatestModel = $kimiWireLatest.Model
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
        CurrentOfficialUsagePreferred = (
            $currentOfficialUsage.UsedPercent -eq 37 -and
            $currentOfficialUsage.WindowMinutes -eq 10080 -and
            $currentOfficialUsage.SampledAt -eq $codexUsage.SampledAt -and
            $currentOfficialUsage.FiveHourWindow.UsedPercent -eq 18 -and
            $currentOfficialUsage.WeeklyWindow.UsedPercent -eq 37 -and
            [bool]$currentOfficialUsage.IsCached
        )
        ProCacheIgnoresExpiredFiveHourWindow = (
            $currentProWeeklyUsage.UsedPercent -eq 37 -and
            $currentProWeeklyUsage.WindowMinutes -eq 10080 -and
            $null -eq $currentProWeeklyUsage.FiveHourWindow -and
            $currentProWeeklyUsage.WeeklyWindow.UsedPercent -eq 37
        )
        ExpiredOfficialUsageFallsBackToLocal = (
            $null -eq $expiredCurrentUsage -and
            $expiredFallbackUsage.Channel -eq 'Local' -and
            $expiredFallbackUsage.UsedPercent -eq 0 -and
            $null -eq $expiredFallbackUsage.FiveHourWindow -and
            $expiredFallbackUsage.WeeklyWindow.UsedPercent -eq 22
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

if ($CheckStateHistory) {
    $now = [DateTimeOffset]'2030-01-08T12:00:00Z'
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $stateRoot = [IO.Path]::GetFullPath(
        (Join-Path $tempRoot (
            'RemainingMarginFloat.StateDiagnostic.{0}.{1}' -f
                $PID,
                [Guid]::NewGuid().ToString('N')
        ))
    )
    if (-not $stateRoot.StartsWith(
        $tempRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'State history diagnostic escaped the temporary directory.'
    }

    $snapshot = [pscustomobject][ordered]@{
        ProviderId = 'Codex'
        Available = $true
        HasProgress = $true
        FiveHourAvailable = $true
        FiveHourRemainingPercent = 72.5
        RemainingPercent = 72.5
        WindowLabel = 'Five-hour quota'
        ResetDate = 'January 12'
        ResetCountdown = '4 days'
        ResetCount = 'Unavailable'
        Plan = 'Pro'
        AccountName = 'Diagnostic User'
        AccountEmail = 'diagnostic@example.com'
        TodayTokens = 12345
        TodayInputTokens = 12000
        TodayOutputTokens = 345
        TodayCachedTokens = 10000
        TodayCacheHitPercent = 83.3
        LastTurnTokens = 456
        InputTokens = 400
        OutputTokens = 56
        CachedTokens = 300
        CacheHitPercent = 75
        ContextPercent = 18
        SampledAt = $now.AddMinutes(-1)
        UsageSampledAt = $now.AddMinutes(-2)
        ResetAt = $now.AddDays(4)
        Status = 'Healthy'
        Source = 'Diagnostic source'
        ApiKey = 'must-never-be-persisted'
        CustomNested = [ordered]@{
            Label = 'preserved'
            Values = @(1, 2, 3)
        }
    }

    $roundTrip = $false
    $contentDeduplicated = $false
    $retentionApplied = $false
    $encryptedAtRest = $false
    $currentIndexWritten = $false
    $corruptLatestFallback = $false
    $corruptManifestFallback = $false
    $temporaryFilesCleaned = $false
    $emptyBackfillHandled = $false
    $corruptBackfillMarkerFallback = $false
    $closeRefreshSamplesPreserved = $false
    $historyReplacementRecovered = $false
    $missingPayloadBlocksCursor = $false
    $largeLegacyRestoreFast = $false
    $largeLegacyIncrementalSaveFast = $false
    $legacyManifestUntouched = $false
    $largeLegacyRestoreMs = -1
    $largeLegacySaveMs = -1
    try {
        $emptyBackfill = Invoke-UsageHistoryStateBackfill `
            -HistoryPath (Join-Path $stateRoot 'usage-empty.jsonl') `
            -StateRootPath $stateRoot `
            -Now $now `
            -AllowDiagnosticWrite
        $emptyBackfillHandled = (
            $emptyBackfill.ExaminedEntries -eq 0 -and
            $emptyBackfill.AddedSamples -eq 0 -and
            $emptyBackfill.FailedEntries -eq 0 -and
            -not [bool]$emptyBackfill.Changed
        )
        if (-not $emptyBackfillHandled) {
            throw 'Missing state history did not return an empty backfill result.'
        }
        [void](New-Item -Path $stateRoot -ItemType Directory -Force)
        [void](Save-UsageStateSnapshot `
            -Snapshot $snapshot `
            -ObservedAt $now.AddHours(-169) `
            -Reason 'Old' `
            -RootPath $stateRoot `
            -AllowDiagnosticWrite)
        [void](Save-UsageStateSnapshot `
            -Snapshot $snapshot `
            -ObservedAt $now.AddMinutes(-10) `
            -Reason 'Manual' `
            -RootPath $stateRoot `
            -AllowDiagnosticWrite)
        [void](Save-UsageStateSnapshot `
            -Snapshot $snapshot `
            -ObservedAt $now.AddMinutes(-5) `
            -Reason 'Automatic' `
            -RootPath $stateRoot `
            -AllowDiagnosticWrite)
        $changedSnapshot = $snapshot.PSObject.Copy()
        $changedSnapshot.RemainingPercent = 60.25
        $changedSnapshot.SampledAt = $now
        [void](Save-UsageStateSnapshot `
            -Snapshot $changedSnapshot `
            -ObservedAt $now `
            -Reason 'Manual' `
            -RootPath $stateRoot `
            -AllowDiagnosticWrite)

        $entries = @(
            Get-UsageStateHistory `
                -RootPath $stateRoot `
                -Now $now
        )
        $objects = @(
            Get-ChildItem `
                -LiteralPath (Get-UsageStateObjectsDirectory -RootPath $stateRoot) `
                -File `
                -Filter '*.json'
        )
        $restored = Get-LatestUsageStateSnapshot `
            -ProviderId 'Codex' `
            -RootPath $stateRoot `
            -Now $now
        $roundTrip = (
            $restored -and
            [Math]::Abs([double]$restored.RemainingPercent - 60.25) -lt 0.0001 -and
            [string]$restored.AccountEmail -eq 'diagnostic@example.com' -and
            [string]$restored.CustomNested.Label -eq 'preserved' -and
            $restored.PSObject.Properties.Name -notcontains 'ApiKey' -and
            $restored.SampledAt -is [DateTimeOffset] -and
            $restored.ResetAt -is [DateTimeOffset]
        )
        $contentDeduplicated = (
            $entries.Count -eq 3 -and
            $objects.Count -eq 2 -and
            $entries[0].PayloadHash -eq $entries[1].PayloadHash -and
            $entries[1].PayloadHash -ne $entries[2].PayloadHash
        )
        $backfillHistoryPath = Join-Path $stateRoot 'usage-backfill.jsonl'
        $firstBackfill = Invoke-UsageHistoryStateBackfill `
            -HistoryPath $backfillHistoryPath `
            -StateRootPath $stateRoot `
            -Now $now `
            -AllowDiagnosticWrite
        $firstBackfillSamples = @(
            Read-UsageHistory `
                -Path $backfillHistoryPath `
                -Now $now `
                -BypassCache
        )
        $backfillMarkerPath = Get-UsageHistoryBackfillMarkerPath `
            -StateRootPath $stateRoot
        [IO.File]::WriteAllText(
            $backfillMarkerPath,
            '{"damaged":true}',
            (New-Object Text.UTF8Encoding($false))
        )
        $secondBackfill = Invoke-UsageHistoryStateBackfill `
            -HistoryPath $backfillHistoryPath `
            -StateRootPath $stateRoot `
            -Now $now `
            -AllowDiagnosticWrite
        $secondBackfillSamples = @(
            Read-UsageHistory `
                -Path $backfillHistoryPath `
                -Now $now `
                -BypassCache
        )
        $stateBackfillRecovered = (
            $firstBackfill.AddedSamples -eq 3 -and
            $firstBackfillSamples.Count -eq 3 -and
            $secondBackfill.AddedSamples -eq 0 -and
            -not [bool]$secondBackfill.Changed -and
            $secondBackfillSamples.Count -eq 3 -and
            [Math]::Abs(
                [double]$secondBackfillSamples[0].RemainingValue - 72.5
            ) -lt 0.0001 -and
            [Math]::Abs(
                [double]$secondBackfillSamples[-1].RemainingValue - 60.25
            ) -lt 0.0001
        )
        $repairedBackfillMarker = Get-Content `
            -LiteralPath $backfillMarkerPath `
            -Raw `
            -Encoding UTF8 |
            ConvertFrom-Json
        $corruptBackfillMarkerFallback = (
            $repairedBackfillMarker.v -eq 2 -and
            -not [string]::IsNullOrWhiteSpace(
                [string]$repairedBackfillMarker.CompletedThroughUtc
            ) -and
            [int]$repairedBackfillMarker.CoverageSampleCount -eq 3 -and
            [string]$repairedBackfillMarker.CoverageSha256 -match
                '^[0-9a-f]{64}$'
        )
        if (-not $stateBackfillRecovered) {
            throw 'Full-state history did not backfill usage history idempotently.'
        }
        if (-not $corruptBackfillMarkerFallback) {
            throw 'Corrupt usage-history backfill marker was not repaired.'
        }

        Save-UsageHistory `
            -Samples @($secondBackfillSamples | Select-Object -Skip 1) `
            -Path $backfillHistoryPath `
            -Now $now `
            -AllowDiagnosticWrite
        $replacementBackfill = Invoke-UsageHistoryStateBackfill `
            -HistoryPath $backfillHistoryPath `
            -StateRootPath $stateRoot `
            -Now $now `
            -AllowDiagnosticWrite
        $replacementSamples = @(
            Read-UsageHistory `
                -Path $backfillHistoryPath `
                -Now $now `
                -BypassCache
        )
        $historyReplacementRecovered = (
            $replacementBackfill.AddedSamples -eq 1 -and
            $replacementSamples.Count -eq 3 -and
            [Math]::Abs(
                [double]$replacementSamples[0].RemainingValue - 72.5
            ) -lt 0.0001
        )
        if (-not $historyReplacementRecovered) {
            throw 'Replaced usage history did not invalidate the backfill cursor.'
        }

        $closeStateRoot = Join-Path $stateRoot 'close-refresh'
        [void](Save-UsageStateSnapshot `
            -Snapshot $snapshot `
            -ObservedAt $now.AddSeconds(-40) `
            -Reason 'Automatic' `
            -RootPath $closeStateRoot `
            -AllowDiagnosticWrite)
        [void](Save-UsageStateSnapshot `
            -Snapshot $snapshot `
            -ObservedAt $now.AddSeconds(-20) `
            -Reason 'Manual' `
            -RootPath $closeStateRoot `
            -AllowDiagnosticWrite)
        $closeHistoryPath = Join-Path $closeStateRoot 'usage.jsonl'
        $closeBackfill = Invoke-UsageHistoryStateBackfill `
            -HistoryPath $closeHistoryPath `
            -StateRootPath $closeStateRoot `
            -Now $now `
            -AllowDiagnosticWrite
        $closeSamples = @(
            Read-UsageHistory `
                -Path $closeHistoryPath `
                -Now $now `
                -BypassCache
        )
        $closeRefreshSamplesPreserved = (
            $closeBackfill.AddedSamples -eq 2 -and
            $closeSamples.Count -eq 2 -and
            (
                $closeSamples[1].ObservedAtUtc -
                $closeSamples[0].ObservedAtUtc
            ).TotalSeconds -eq 20
        )
        if (-not $closeRefreshSamplesPreserved) {
            throw 'Closely spaced automatic and manual refreshes were merged.'
        }

        $missingStateRoot = Join-Path $stateRoot 'missing-payload'
        [void](Save-UsageStateSnapshot `
            -Snapshot $snapshot `
            -ObservedAt $now.AddMinutes(-2) `
            -Reason 'Automatic' `
            -RootPath $missingStateRoot `
            -AllowDiagnosticWrite)
        [void](Save-UsageStateSnapshot `
            -Snapshot $changedSnapshot `
            -ObservedAt $now.AddMinutes(-1) `
            -Reason 'Manual' `
            -RootPath $missingStateRoot `
            -AllowDiagnosticWrite)
        $missingEntries = @(
            Get-UsageStateHistory `
                -RootPath $missingStateRoot `
                -Now $now
        )
        $missingObjectPath = Join-Path (
            Get-UsageStateObjectsDirectory -RootPath $missingStateRoot
        ) ($missingEntries[0].PayloadHash + '.json')
        Remove-Item -LiteralPath $missingObjectPath -Force
        $missingHistoryPath = Join-Path $missingStateRoot 'usage.jsonl'
        $missingBackfill = Invoke-UsageHistoryStateBackfill `
            -HistoryPath $missingHistoryPath `
            -StateRootPath $missingStateRoot `
            -Now $now `
            -AllowDiagnosticWrite
        $missingMarkerPath = Get-UsageHistoryBackfillMarkerPath `
            -StateRootPath $missingStateRoot
        $missingPayloadBlocksCursor = (
            $missingBackfill.ExaminedEntries -eq 2 -and
            $missingBackfill.AddedSamples -eq 1 -and
            $missingBackfill.FailedEntries -eq 1 -and
            -not (Test-Path -LiteralPath $missingMarkerPath -PathType Leaf)
        )
        if (-not $missingPayloadBlocksCursor) {
            throw 'Missing state payload did not block the backfill cursor.'
        }

        $retentionApplied = @(
            $entries | Where-Object {
                $_.ObservedAtUtc -lt $now.AddHours(-168)
            }
        ).Count -eq 0
        $diskText = @($objects | ForEach-Object {
            Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
        }) -join ''
        $encryptedAtRest = (
            $diskText -notmatch 'diagnostic@example.com' -and
            $diskText -notmatch 'Diagnostic User' -and
            $diskText -notmatch 'must-never-be-persisted'
        )
        $currentIndexWritten = (
            (Test-Path -LiteralPath (
                Get-UsageStateCurrentPath -RootPath $stateRoot
            ) -PathType Leaf) -and
            @(Get-ChildItem -LiteralPath $stateRoot -File -Filter '*.tmp.*').Count -eq 0
        )

        $largeStateRoot = Join-Path $stateRoot 'large-legacy'
        [void](Save-UsageStateSnapshot `
            -Snapshot $snapshot `
            -ObservedAt $now.AddMinutes(-1) `
            -Reason 'Automatic' `
            -RootPath $largeStateRoot `
            -AllowDiagnosticWrite)
        $largeBaseEntry = @(
            Read-UsageStateCurrentEntries `
                -RootPath $largeStateRoot `
                -Now $now
        )[0]
        $legacyDocuments = New-Object Collections.Generic.List[object]
        for ($index = 0; $index -lt 5000; $index++) {
            $observedAt = $now.AddMinutes(-$index)
            [void]$legacyDocuments.Add([ordered]@{
                v = 1
                EntryId = 'legacy-{0:d5}' -f $index
                ProviderId = 'Codex'
                ObservedAtUtc = $observedAt.ToString('o')
                SampledAtUtc = $observedAt.ToString('o')
                PayloadHash = [string]$largeBaseEntry.PayloadHash
                Reason = 'Automatic'
                AppVersion = [string]$script:AppVersion
            })
        }
        $largeManifestPath = Get-UsageStateManifestPath `
            -RootPath $largeStateRoot
        $largeManifest = [ordered]@{
            v = 1
            UpdatedAtUtc = $now.ToString('o')
            RetentionHours = 168
            Entries = $legacyDocuments.ToArray()
        } | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText(
            $largeManifestPath,
            $largeManifest,
            (New-Object Text.UTF8Encoding($false))
        )
        [IO.File]::SetLastWriteTimeUtc(
            $largeManifestPath,
            $now.UtcDateTime
        )
        $largeManifestHashBefore = (
            Get-FileHash -LiteralPath $largeManifestPath -Algorithm SHA256
        ).Hash
        $largeManifestWriteTimeBefore = (
            Get-Item -LiteralPath $largeManifestPath
        ).LastWriteTimeUtc

        $largeRestoreTimer = [Diagnostics.Stopwatch]::StartNew()
        $largeRestored = Get-LatestUsageStateSnapshot `
            -ProviderId 'Codex' `
            -RootPath $largeStateRoot `
            -Now $now
        $largeRestoreTimer.Stop()
        $largeLegacyRestoreMs = $largeRestoreTimer.ElapsedMilliseconds
        $largeLegacyRestoreFast = (
            $largeRestored -and
            $largeLegacyRestoreMs -lt 1500
        )

        $largeChangedSnapshot = $snapshot.PSObject.Copy()
        $largeChangedSnapshot.RemainingPercent = 61.5
        $largeSaveTimer = [Diagnostics.Stopwatch]::StartNew()
        [void](Save-UsageStateSnapshot `
            -Snapshot $largeChangedSnapshot `
            -ObservedAt $now `
            -Reason 'Manual' `
            -RootPath $largeStateRoot `
            -AllowDiagnosticWrite)
        $largeSaveTimer.Stop()
        $largeLegacySaveMs = $largeSaveTimer.ElapsedMilliseconds
        $largeLegacyIncrementalSaveFast = $largeLegacySaveMs -lt 1500
        $largeManifestAfter = Get-Item -LiteralPath $largeManifestPath
        $legacyManifestUntouched = (
            (Get-FileHash `
                -LiteralPath $largeManifestPath `
                -Algorithm SHA256).Hash -eq $largeManifestHashBefore -and
            $largeManifestAfter.LastWriteTimeUtc -eq
                $largeManifestWriteTimeBefore -and
            (Test-Path -LiteralPath (
                Get-UsageStateJournalPath `
                    -ObservedAt $now `
                    -RootPath $largeStateRoot
            ) -PathType Leaf)
        )

        $manifestPath = Get-UsageStateManifestPath -RootPath $stateRoot
        [IO.File]::WriteAllText(
            $manifestPath,
            '{"damaged":true}',
            (New-Object Text.UTF8Encoding($false))
        )
        $manifestFallback = Get-LatestUsageStateSnapshot `
            -ProviderId 'Codex' `
            -RootPath $stateRoot `
            -Now $now
        $corruptManifestFallback = (
            $manifestFallback -and
            [Math]::Abs(
                [double]$manifestFallback.RemainingPercent - 60.25
            ) -lt 0.0001
        )
        [void](Write-UsageStateIndexes `
            -Entries $entries `
            -RootPath $stateRoot `
            -Now $now)

        $latestEntry = $entries[-1]
        $latestPath = Join-Path (
            Get-UsageStateObjectsDirectory -RootPath $stateRoot
        ) ($latestEntry.PayloadHash + '.json')
        [IO.File]::WriteAllText(
            $latestPath,
            '{"damaged":true}',
            (New-Object Text.UTF8Encoding($false))
        )
        $fallback = Get-LatestUsageStateSnapshot `
            -ProviderId 'Codex' `
            -RootPath $stateRoot `
            -Now $now
        $corruptLatestFallback = (
            $fallback -and
            [Math]::Abs([double]$fallback.RemainingPercent - 72.5) -lt 0.0001
        )
    }
    finally {
        if (
            (Test-Path -LiteralPath $stateRoot) -and
            $stateRoot.StartsWith(
                $tempRoot,
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            Remove-Item -LiteralPath $stateRoot -Recurse -Force
        }
        $temporaryFilesCleaned = -not (Test-Path -LiteralPath $stateRoot)
    }

    [pscustomobject]@{
        RoundTrip = $roundTrip
        ContentDeduplicated = $contentDeduplicated
        RollingRetentionApplied = $retentionApplied
        EncryptedAtRest = $encryptedAtRest
        CurrentIndexWritten = $currentIndexWritten
        CorruptLatestFallback = $corruptLatestFallback
        CorruptManifestFallback = $corruptManifestFallback
        EmptyBackfillHandled = $emptyBackfillHandled
        CorruptBackfillMarkerFallback = $corruptBackfillMarkerFallback
        CloseRefreshSamplesPreserved = $closeRefreshSamplesPreserved
        HistoryReplacementRecovered = $historyReplacementRecovered
        MissingPayloadBlocksCursor = $missingPayloadBlocksCursor
        LargeLegacyRestoreFast = $largeLegacyRestoreFast
        LargeLegacyIncrementalSaveFast = $largeLegacyIncrementalSaveFast
        LegacyManifestUntouched = $legacyManifestUntouched
        LargeLegacyRestoreMs = $largeLegacyRestoreMs
        LargeLegacySaveMs = $largeLegacySaveMs
        TemporaryFilesCleaned = $temporaryFilesCleaned
    } | ConvertTo-Json
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
            [string]$ResetAtUtc = '',
            [string]$QuotaPeriod = ''
        )

        return [pscustomobject]@{
            Version = 3
            ProviderId = $ProviderId
            ObservedAtUtc = $now.AddHours(-$HoursAgo)
            MetricType = $MetricType
            QuotaPeriod = if (
                $ProviderId -eq 'Codex' -and $MetricType -eq 'Percent'
            ) {
                if ([string]::IsNullOrWhiteSpace($QuotaPeriod)) {
                    'FiveHour'
                } else { $QuotaPeriod }
            } else { '' }
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

    $acceleratedSamples = @(
        (New-HistoryCheckSample -HoursAgo 3 -Value 100),
        (New-HistoryCheckSample -HoursAgo 1 -Value 100),
        (New-HistoryCheckSample -HoursAgo (25.0 / 60) -Value 100),
        (New-HistoryCheckSample -HoursAgo (15.0 / 60) -Value 97),
        (New-HistoryCheckSample -HoursAgo (5.0 / 60) -Value 94),
        (New-HistoryCheckSample -HoursAgo 0 -Value 91)
    )
    $acceleratedForecast = Get-DepletionForecast `
        -Samples $acceleratedSamples `
        -CurrentSample $acceleratedSamples[-1] `
        -Now $now

    $noiseOnlyRecentSamples = @(
        (New-HistoryCheckSample -HoursAgo 3 -Value 80),
        (New-HistoryCheckSample -HoursAgo 1 -Value 70),
        (New-HistoryCheckSample -HoursAgo 0.5 -Value 60),
        (New-HistoryCheckSample -HoursAgo 0.25 -Value 59.8),
        (New-HistoryCheckSample -HoursAgo 0 -Value 59.5)
    )
    $noiseOnlyRecentForecast = Get-DepletionForecast `
        -Samples $noiseOnlyRecentSamples `
        -CurrentSample $noiseOnlyRecentSamples[-1] `
        -Now $now

    $trendResetSamples = @(
        (New-HistoryCheckSample -HoursAgo 23 -Value 37),
        (New-HistoryCheckSample -HoursAgo 2 -Value 36),
        (New-HistoryCheckSample -HoursAgo 0 -Value 98)
    )
    $trendAfterReset = Get-UsageTrend `
        -Samples $trendResetSamples `
        -CurrentSample $trendResetSamples[-1] `
        -Hours 24 `
        -Now $now
    $rollingWindowSamples = @(
        (New-HistoryCheckSample -HoursAgo 24.25 -Value 80),
        (New-HistoryCheckSample -HoursAgo 23 -Value 75),
        (New-HistoryCheckSample -HoursAgo 0 -Value 70)
    )
    $rollingWindowTrend = Get-UsageTrend `
        -Samples $rollingWindowSamples `
        -CurrentSample $rollingWindowSamples[-1] `
        -Hours 24 `
        -Now $now
    $multipleResetSamples = @(
        (New-HistoryCheckSample -HoursAgo 5 -Value 40),
        (New-HistoryCheckSample -HoursAgo 4 -Value 80),
        (New-HistoryCheckSample -HoursAgo 3 -Value 70),
        (New-HistoryCheckSample -HoursAgo 2 -Value 90),
        (New-HistoryCheckSample -HoursAgo 1 -Value 85),
        (New-HistoryCheckSample -HoursAgo 0 -Value 80)
    )
    $multipleResetTrend = Get-UsageTrend `
        -Samples $multipleResetSamples `
        -CurrentSample $multipleResetSamples[-1] `
        -Hours 24 `
        -Now $now
    $noiseSamples = @(
        (New-HistoryCheckSample -HoursAgo 2 -Value 50),
        (New-HistoryCheckSample -HoursAgo 1 -Value 50.00005),
        (New-HistoryCheckSample -HoursAgo 0 -Value 49)
    )
    $noiseTrend = Get-UsageTrend `
        -Samples $noiseSamples `
        -CurrentSample $noiseSamples[-1] `
        -Hours 24 `
        -Now $now

    $gapResetSamples = @(
        (New-HistoryCheckSample -HoursAgo 3 -Value 30),
        (New-HistoryCheckSample -HoursAgo 0 -Value 95)
    )
    $gapResetTrend = Get-UsageTrend `
        -Samples $gapResetSamples `
        -CurrentSample $gapResetSamples[-1] `
        -Hours 5 `
        -StretchToFit `
        -Now $now
    $gapNoResetSamples = @(
        (New-HistoryCheckSample -HoursAgo 3 -Value 30),
        (New-HistoryCheckSample -HoursAgo 2 -Value 28),
        (New-HistoryCheckSample -HoursAgo 0 -Value 27)
    )
    $gapNoResetTrend = Get-UsageTrend `
        -Samples $gapNoResetSamples `
        -CurrentSample $gapNoResetSamples[-1] `
        -Hours 5 `
        -StretchToFit `
        -Now $now
    $recentResetSamples = @(
        (New-HistoryCheckSample -HoursAgo 0.0833 -Value 30),
        (New-HistoryCheckSample -HoursAgo 0 -Value 95)
    )
    $recentResetTrend = Get-UsageTrend `
        -Samples $recentResetSamples `
        -CurrentSample $recentResetSamples[-1] `
        -Hours 5 `
        -StretchToFit `
        -Now $now

    $gapResetRestartsAtCurrentValue = (
        [bool]$gapResetTrend.ComparisonAvailable -and
        $gapResetTrend.Samples.Count -eq 2 -and
        $gapResetTrend.Segments.Count -eq 1 -and
        $gapResetTrend.SampleCount -eq 1 -and
        $gapResetTrend.StartValue -eq 95 -and
        $gapResetTrend.EndValue -eq 95 -and
        $gapResetTrend.Change -eq 0 -and
        [Math]::Abs((
            $now.AddHours(-3).ToUniversalTime() -
            ([DateTimeOffset]$gapResetTrend.AxisStartUtc).ToUniversalTime()
        ).TotalMinutes) -lt 1
    )
    $gapWithoutResetKeepsHistory = (
        [bool]$gapNoResetTrend.ComparisonAvailable -and
        $gapNoResetTrend.Samples.Count -eq 3 -and
        $gapNoResetTrend.SampleCount -eq 3 -and
        $gapNoResetTrend.StartValue -eq 30 -and
        $gapNoResetTrend.EndValue -eq 27
    )
    $recentResetKeepsSplitSegments = (
        -not [bool]$recentResetTrend.ComparisonAvailable -and
        $recentResetTrend.Samples.Count -eq 2 -and
        $recentResetTrend.Segments.Count -eq 2 -and
        $recentResetTrend.StartValue -eq 95 -and
        $recentResetTrend.EndValue -eq 95
    )
    if (-not $gapResetRestartsAtCurrentValue) {
        throw 'Stretched trend did not restart at the current value after a gap reset.'
    }
    if (-not $gapWithoutResetKeepsHistory) {
        throw 'Stretched trend dropped in-window history without a gap reset.'
    }
    if (-not $recentResetKeepsSplitSegments) {
        throw 'In-session reset no longer splits the stretched trend segments.'
    }


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
        FiveHourAvailable = $true
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
    $weeklyHistorySnapshot = [pscustomobject]@{
        ProviderId = 'Codex'
        Available = $true
        HasProgress = $true
        PrimaryQuotaPeriod = 'Weekly'
        WeeklyAvailable = $true
        RemainingPercent = 91
        ResetAt = $now.AddDays(6)
    }
    $weeklyHistorySample = ConvertTo-UsageHistorySample `
        -Snapshot $weeklyHistorySnapshot `
        -ObservedAt $now
    $mixedPeriodSamples = @(
        (New-HistoryCheckSample `
            -HoursAgo 2 `
            -Value 10 `
            -QuotaPeriod 'FiveHour'),
        (New-HistoryCheckSample `
            -HoursAgo 1 `
            -Value 96 `
            -QuotaPeriod 'Weekly'),
        (New-HistoryCheckSample `
            -HoursAgo 0 `
            -Value 91 `
            -QuotaPeriod 'Weekly')
    )
    $weeklyPeriodTrend = Get-UsageTrend `
        -Samples $mixedPeriodSamples `
        -CurrentSample $mixedPeriodSamples[-1] `
        -Hours 24 `
        -Now $now
    $codexNetDropSamples = @(
        (New-HistoryCheckSample -HoursAgo 0.5 -Value 68.2),
        (New-HistoryCheckSample -HoursAgo (1 / 3) -Value 69),
        (New-HistoryCheckSample -HoursAgo 0 -Value 68)
    )
    $codexNetDrop = Measure-RapidUsageDrop `
        -Samples $codexNetDropSamples `
        -Snapshot $codexRapidSnapshot `
        -WindowMinutes 30 `
        -CodexPercent 15 `
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
    $legacyCodexHistoryPath = Join-Path ([IO.Path]::GetTempPath()) (
        'RemainingMarginFloat.HistoryLegacyCodexDiagnostic.{0}.jsonl' -f $PID
    )
    $invalidHistoryPath = Join-Path ([IO.Path]::GetTempPath()) (
        'RemainingMarginFloat.HistoryInvalidDiagnostic.{0}.jsonl' -f $PID
    )
    $oversizedHistoryPath = Join-Path ([IO.Path]::GetTempPath()) (
        'RemainingMarginFloat.HistoryOversizedDiagnostic.{0}.jsonl' -f $PID
    )
    $minuteHistoryPath = Join-Path ([IO.Path]::GetTempPath()) (
        'RemainingMarginFloat.MinuteHistoryDiagnostic.{0}.jsonl' -f $PID
    )
    $largeHistoryPath = Join-Path ([IO.Path]::GetTempPath()) (
        'RemainingMarginFloat.LargeHistoryDiagnostic.{0}.jsonl' -f $PID
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
    $legacyWeeklyCodexMigrated = $false
    $calendarDateAligned = $false
    $importMergeRoundTrip = $false
    $invalidImportRejected = $false
    $oversizedImportRejected = $false
    $futureSampleExcluded = $false
    $diagnosticRedaction = $false
    $minuteSamplesRetained = $false
    $manualRefreshSampleRetained = $false
    $largeHistoryReadFast = $false
    $largeHistoryReadMs = -1
    $largeHistorySampleCount = 0
    $largeHistoryInsightsFast = $false
    $largeHistoryInsightsMs = -1
    $largeHistoryAnalysisSampleCount = 0
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
            $savedSample.v -eq 3 -and
            $savedSample.ProviderId -eq 'Codex' -and
            $savedSample.MetricType -eq 'Percent' -and
            $savedSample.QuotaPeriod -eq 'FiveHour' -and
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
            $reloaded[0].Version -eq 3 -and
            $reloaded[0].QuotaPeriod -eq 'FiveHour' -and
            $reloaded[-1].RemainingValue -eq 60
        )

        $calendarRecord = [ordered]@{
            v = 1
            ProviderId = 'DeepSeek'
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
            $legacyReloaded[0].Version -eq 3
        )
        $calendarDateAligned = (
            $legacyReloaded.Count -eq 1 -and
            $legacyReloaded[0].LocalDate -eq '2030-01-01' -and
            $legacyReloaded[0].UtcOffsetMinutes -eq 480
        )

        $legacyCodexV1Record = [ordered]@{
            v = 1
            ProviderId = 'Codex'
            ObservedAtUtc = '2030-01-01T10:59:00.0000000+00:00'
            MetricType = 'Percent'
            RemainingValue = 98
            Unit = '%'
            ResetAtUtc = '2030-01-08T00:00:00.0000000+00:00'
        } | ConvertTo-Json -Compress
        $legacyCodexV2Record = [ordered]@{
            v = 2
            ProviderId = 'Codex'
            ObservedAtUtc = '2030-01-01T11:00:00.0000000+00:00'
            MetricType = 'Percent'
            RemainingValue = 97
            Unit = '%'
            ResetAtUtc = '2030-01-08T00:00:00.0000000+00:00'
        } | ConvertTo-Json -Compress
        $invalidCurrentCodexRecord = [ordered]@{
            v = 3
            ProviderId = 'Codex'
            ObservedAtUtc = '2030-01-01T11:01:00.0000000+00:00'
            MetricType = 'Percent'
            RemainingValue = 96
            Unit = '%'
            ResetAtUtc = '2030-01-08T00:00:00.0000000+00:00'
        } | ConvertTo-Json -Compress
        [IO.File]::WriteAllLines(
            $legacyCodexHistoryPath,
            @(
                $legacyCodexV1Record,
                $legacyCodexV2Record,
                $invalidCurrentCodexRecord
            ),
            (New-Object Text.UTF8Encoding($false))
        )
        $legacyCodexReloaded = @(
            Read-UsageHistory `
                -Path $legacyCodexHistoryPath `
                -Now $now `
                -BypassCache
        )
        $legacyWeeklyCodexMigrated = (
            $legacyCodexReloaded.Count -eq 2 -and
            @($legacyCodexReloaded | Where-Object {
                $_.Version -eq 3 -and $_.QuotaPeriod -eq 'Weekly'
            }).Count -eq 2 -and
            $legacyCodexReloaded[0].RemainingValue -eq 98 -and
            $legacyCodexReloaded[1].RemainingValue -eq 97
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

        $minuteSnapshot = [pscustomobject]@{
            ProviderId = 'Codex'
            Available = $true
            HasProgress = $true
            FiveHourAvailable = $true
            RemainingPercent = 75
        }
        for ($minute = 59; $minute -ge 0; $minute--) {
            Add-UsageHistorySample `
                -Snapshot $minuteSnapshot `
                -ObservedAt $now.AddMinutes(-$minute) `
                -Path $minuteHistoryPath `
                -AllowDiagnosticWrite | Out-Null
        }
        $minuteReload = @(
            Read-UsageHistory `
                -Path $minuteHistoryPath `
                -Now $now `
                -BypassCache
        )
        $minuteSamplesRetained = $minuteReload.Count -eq 60
        Add-UsageHistorySample `
            -Snapshot $minuteSnapshot `
            -ObservedAt $now.AddSeconds(30) `
            -Path $minuteHistoryPath `
            -AllowDiagnosticWrite | Out-Null
        $manualReload = @(
            Read-UsageHistory `
                -Path $minuteHistoryPath `
                -Now $now.AddSeconds(30) `
                -BypassCache
        )
        $manualRefreshSampleRetained = $manualReload.Count -eq 61

        $largeHistoryLines = New-Object 'string[]' 7200
        for ($index = 0; $index -lt $largeHistoryLines.Length; $index++) {
            $observedAt = $now.AddMinutes(-$index).ToString(
                'o',
                [Globalization.CultureInfo]::InvariantCulture
            )
            $largeHistoryLines[$index] = (
                '{"v":3,"ProviderId":"Codex","ObservedAtUtc":"' +
                $observedAt +
                '","MetricType":"Percent","QuotaPeriod":"FiveHour",' +
                '"RemainingValue":72.5,"Unit":"%","ResetAtUtc":""}'
            )
        }
        [IO.File]::WriteAllLines(
            $largeHistoryPath,
            $largeHistoryLines,
            (New-Object Text.UTF8Encoding($false))
        )
        $largeHistoryTimer = [Diagnostics.Stopwatch]::StartNew()
        $largeHistoryReload = @(
            Read-UsageHistory `
                -Path $largeHistoryPath `
                -Now $now `
                -BypassCache
        )
        $largeHistoryTimer.Stop()
        $largeHistoryReadMs = $largeHistoryTimer.ElapsedMilliseconds
        $largeHistorySampleCount = $largeHistoryReload.Count
        $largeHistoryReadFast = (
            $largeHistorySampleCount -eq 7200 -and
            $largeHistoryReadMs -lt 1500
        )
        $largeInsightsTimer = [Diagnostics.Stopwatch]::StartNew()
        $largeAnalysisHistory = @(
            Read-UsageHistory `
                -Path $largeHistoryPath `
                -Now $now `
                -BypassCache `
                -ForAnalysis
        )
        $largeHistoryInsights = Measure-UsageInsights `
            -Samples $largeAnalysisHistory `
            -CurrentSample $largeAnalysisHistory[-1] `
            -PreviousSample $largeAnalysisHistory[-2] `
            -Snapshot $codexRapidSnapshot `
            -Now $now
        $largeInsightsTimer.Stop()
        $largeHistoryInsightsMs = $largeInsightsTimer.ElapsedMilliseconds
        $largeHistoryAnalysisSampleCount = $largeAnalysisHistory.Count
        $largeHistoryInsightsFast = (
            $largeHistoryInsights.Trend7Days.SampleCount -gt 0 -and
            $largeHistoryAnalysisSampleCount -ge 400 -and
            $largeHistoryAnalysisSampleCount -le 800 -and
            $largeHistoryInsightsMs -lt 1500
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
            $legacyCodexHistoryPath
            $invalidHistoryPath
            $oversizedHistoryPath
            $minuteHistoryPath
            $largeHistoryPath
        )) {
            if (Test-Path -LiteralPath $testPath) {
                Remove-Item -LiteralPath $testPath -Force
            }
        }
    }

    $trendResetStartsNewBaseline = (
        -not [bool]$trendAfterReset.ComparisonAvailable -and
        $trendAfterReset.SampleCount -eq 3 -and
        $trendAfterReset.Samples.Count -eq 3 -and
        $trendAfterReset.Segments.Count -eq 2 -and
        $trendAfterReset.Segments[0].Samples.Count -eq 2 -and
        $trendAfterReset.ComparisonSamples.Count -eq 1 -and
        $trendAfterReset.Change -eq 0 -and
        $trendAfterReset.StartValue -eq 98 -and
        $trendAfterReset.EndValue -eq 98
    )
    $rollingWindowCarriesBoundary = (
        [bool]$rollingWindowTrend.ComparisonAvailable -and
        $rollingWindowTrend.SampleCount -eq 2 -and
        $rollingWindowTrend.Samples.Count -eq 3 -and
        $rollingWindowTrend.Change -eq -10 -and
        $rollingWindowTrend.StartValue -eq 80 -and
        $rollingWindowTrend.EndValue -eq 70
    )
    $multipleResetUsesLatestBaseline = (
        [bool]$multipleResetTrend.ComparisonAvailable -and
        $multipleResetTrend.SampleCount -eq 6 -and
        $multipleResetTrend.Samples.Count -eq 6 -and
        $multipleResetTrend.Segments.Count -eq 3 -and
        $multipleResetTrend.ComparisonSamples.Count -eq 3 -and
        $multipleResetTrend.StartValue -eq 90 -and
        $multipleResetTrend.EndValue -eq 80 -and
        $multipleResetTrend.Change -eq -10
    )
    $subThresholdNoiseIgnored = (
        [bool]$noiseTrend.ComparisonAvailable -and
        $noiseTrend.SampleCount -eq 3 -and
        [Math]::Abs([double]$noiseTrend.Change + 1) -lt 0.0001
    )
    if (-not $trendResetStartsNewBaseline) {
        throw 'Trend reset did not establish a new baseline.'
    }
    if (-not $rollingWindowCarriesBoundary) {
        throw 'Rolling trend did not carry the pre-window boundary sample.'
    }
    if (-not $multipleResetUsesLatestBaseline) {
        throw 'Trend did not use the latest reset as its baseline.'
    }
    if (-not $subThresholdNoiseIgnored) {
        throw 'Sub-threshold measurement noise started a new trend segment.'
    }
    if (-not $minuteSamplesRetained) {
        throw 'One-minute history samples were compressed or replaced.'
    }
    if (-not $manualRefreshSampleRetained) {
        throw 'Manual refresh sample was not appended.'
    }

    # Spend ledger: money consumed is derived from real balance movements, so the
    # attribution rules below are asserted with a fixed UTC+8 time zone to stay
    # independent of the machine's own zone.
    $spendLedgerTimeZone = [TimeZoneInfo]::CreateCustomTimeZone(
        'RMF Diagnostic Ledger UTC+08',
        [TimeSpan]::FromHours(8),
        'RMF Diagnostic Ledger UTC+08',
        'RMF Diagnostic Ledger UTC+08'
    )
    function New-SpendLedgerCheckSample {
        param(
            [double]$MinutesAgo,
            [double]$Balance,
            [string]$Unit = 'CNY'
        )

        return [pscustomobject]@{
            ProviderId = 'DeepSeek'
            ObservedAtUtc = $now.AddMinutes(-$MinutesAgo)
            MetricType = 'Balance'
            RemainingValue = $Balance
            Unit = $Unit
        }
    }
    function Add-SpendLedgerCheckObservation {
        param($Ledger, [double]$MinutesAgo, [double]$Balance)

        return Add-SpendLedgerObservation `
            -Ledger $Ledger `
            -ProviderId 'DeepSeek' `
            -Unit 'CNY' `
            -Balance $Balance `
            -ObservedAt $now.AddMinutes(-$MinutesAgo) `
            -TimeZone $spendLedgerTimeZone
    }

    $ledgerSpendLedger = Get-EmptySpendLedger
    [void](Add-SpendLedgerCheckObservation -Ledger $ledgerSpendLedger -MinutesAgo 30 -Balance 100.0)
    [void](Add-SpendLedgerCheckObservation -Ledger $ledgerSpendLedger -MinutesAgo 20 -Balance 98.5)
    [void](Add-SpendLedgerCheckObservation -Ledger $ledgerSpendLedger -MinutesAgo 10 -Balance 97.0)
    # A top-up raises the baseline but must not cancel what was already spent.
    [void](Add-SpendLedgerCheckObservation -Ledger $ledgerSpendLedger -MinutesAgo 5 -Balance 197.0)
    $spendSummaryAfterTopUp = Get-SpendSummary `
        -Ledger $ledgerSpendLedger `
        -ProviderId 'DeepSeek' `
        -Now $now `
        -TimeZone $spendLedgerTimeZone

    # A long outage inside one local day is still that day's spend.
    $ledgerSameDayGap = Get-EmptySpendLedger
    [void](Add-SpendLedgerCheckObservation -Ledger $ledgerSameDayGap -MinutesAgo 360 -Balance 100.0)
    [void](Add-SpendLedgerCheckObservation -Ledger $ledgerSameDayGap -MinutesAgo 60 -Balance 90.0)
    $spendSummarySameDayGap = Get-SpendSummary `
        -Ledger $ledgerSameDayGap `
        -ProviderId 'DeepSeek' `
        -Now $now `
        -TimeZone $spendLedgerTimeZone

    # An outage that crossed a local midnight cannot be pinned to a day. With the
    # zone fixed at UTC+8 the first sample below lands on the previous local day,
    # and because that day is in the previous month the drop belongs to no month
    # either.
    $ledgerCrossMonthGap = Get-EmptySpendLedger
    [void](Add-SpendLedgerCheckObservation -Ledger $ledgerCrossMonthGap -MinutesAgo 1500 -Balance 100.0)
    [void](Add-SpendLedgerCheckObservation -Ledger $ledgerCrossMonthGap -MinutesAgo 60 -Balance 80.0)
    $spendSummaryCrossMonthGap = Get-SpendSummary `
        -Ledger $ledgerCrossMonthGap `
        -ProviderId 'DeepSeek' `
        -Now $now `
        -TimeZone $spendLedgerTimeZone

    # The same outage inside one month still leaves the month figure complete: it
    # is that month's money even though no single day can claim it.
    $ledgerSameMonthGap = Get-EmptySpendLedger
    [void](Add-SpendLedgerObservation `
        -Ledger $ledgerSameMonthGap `
        -ProviderId 'DeepSeek' `
        -Unit 'CNY' `
        -Balance 200.0 `
        -ObservedAt ([DateTimeOffset]'2030-01-04T04:00:00Z') `
        -TimeZone $spendLedgerTimeZone)
    [void](Add-SpendLedgerObservation `
        -Ledger $ledgerSameMonthGap `
        -ProviderId 'DeepSeek' `
        -Unit 'CNY' `
        -Balance 170.0 `
        -ObservedAt ([DateTimeOffset]'2030-01-05T04:00:00Z') `
        -TimeZone $spendLedgerTimeZone)
    $spendSummarySameMonthGap = Get-SpendSummary `
        -Ledger $ledgerSameMonthGap `
        -ProviderId 'DeepSeek' `
        -Now ([DateTimeOffset]'2030-01-05T12:00:00Z') `
        -TimeZone $spendLedgerTimeZone

    $ledgerRetention = Get-EmptySpendLedger
    [void](Add-SpendLedgerObservation `
        -Ledger $ledgerRetention `
        -ProviderId 'DeepSeek' `
        -Unit 'CNY' `
        -Balance 10.0 `
        -ObservedAt $now.AddDays(-30) `
        -LocalDate '2029-11-20' `
        -TimeZone $spendLedgerTimeZone)
    [void](Add-SpendLedgerObservation `
        -Ledger $ledgerRetention `
        -ProviderId 'DeepSeek' `
        -Unit 'CNY' `
        -Balance 10.0 `
        -ObservedAt $now.AddDays(-10) `
        -LocalDate '2029-12-20' `
        -TimeZone $spendLedgerTimeZone)
    [void](Add-SpendLedgerObservation `
        -Ledger $ledgerRetention `
        -ProviderId 'DeepSeek' `
        -Unit 'CNY' `
        -Balance 10.0 `
        -ObservedAt $now.AddDays(4) `
        -LocalDate '2030-01-05' `
        -TimeZone $spendLedgerTimeZone)
    Prune-SpendLedger `
        -Ledger $ledgerRetention `
        -Now $now `
        -TimeZone $spendLedgerTimeZone
    $ledgerRetentionDates = @(
        $ledgerRetention.Providers[0].Days | ForEach-Object { [string]$_.Date }
    )

    $seedHistorySamples = @(
        (New-SpendLedgerCheckSample -MinutesAgo 360 -Balance 120.0),
        (New-SpendLedgerCheckSample -MinutesAgo 30 -Balance 118.0)
    )
    $ledgerSeeded = Get-EmptySpendLedger
    $seedFirstCount = Initialize-SpendLedgerFromHistory `
        -Ledger $ledgerSeeded `
        -TimeZone $spendLedgerTimeZone `
        -HistorySamples $seedHistorySamples
    $seedSummary = Get-SpendSummary `
        -Ledger $ledgerSeeded `
        -ProviderId 'DeepSeek' `
        -Now $now `
        -TimeZone $spendLedgerTimeZone
    $seedSecondCount = Initialize-SpendLedgerFromHistory `
        -Ledger $ledgerSeeded `
        -TimeZone $spendLedgerTimeZone `
        -HistorySamples $seedHistorySamples
    $seedResummary = Get-SpendSummary `
        -Ledger $ledgerSeeded `
        -ProviderId 'DeepSeek' `
        -Now $now `
        -TimeZone $spendLedgerTimeZone

    $spendLedgerTestPath = Join-Path ([IO.Path]::GetTempPath()) (
        'RemainingMarginFloat.SpendLedgerDiagnostic.{0}.json' -f $PID
    )
    $corruptSpendLedgerPath = Join-Path ([IO.Path]::GetTempPath()) (
        'RemainingMarginFloat.SpendLedgerCorruptDiagnostic.{0}.json' -f $PID
    )
    $spendLedgerSaved = Save-SpendLedger `
        -Ledger $ledgerSpendLedger `
        -Path $spendLedgerTestPath `
        -AllowDiagnosticWrite
    $reloadedSpendLedger = Read-SpendLedger `
        -Path $spendLedgerTestPath `
        -BypassCache
    $reloadedSpendSummary = Get-SpendSummary `
        -Ledger $reloadedSpendLedger `
        -ProviderId 'DeepSeek' `
        -Now $now `
        -TimeZone $spendLedgerTimeZone
    $reloadedSpendDocument = Get-Content `
        -LiteralPath $spendLedgerTestPath `
        -Raw `
        -Encoding UTF8
    Set-Content `
        -LiteralPath $corruptSpendLedgerPath `
        -Value '{ not a ledger' `
        -Encoding UTF8
    $corruptSpendLedger = Read-SpendLedger `
        -Path $corruptSpendLedgerPath `
        -BypassCache

    [pscustomobject]@{
        Trend5HChange = $depletingInsights.Trend5Hours.Change
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
        RecentAccelerationDetected = (
            $acceleratedForecast.Status -eq 'Depleting' -and
            [Math]::Abs(
                [double]$acceleratedForecast.HoursToEmpty - 4.39
            ) -lt 0.05 -and
            [double]$acceleratedForecast.RatePerHour -lt -15
        )
        RecentNoiseIgnored = (
            $noiseOnlyRecentForecast.Status -eq 'Depleting' -and
            [double]$noiseOnlyRecentForecast.HoursToEmpty -lt 12
        )
        TrendResetStartsNewBaseline = $trendResetStartsNewBaseline
        RollingWindowCarriesBoundary = $rollingWindowCarriesBoundary
        MultipleResetUsesLatestBaseline = $multipleResetUsesLatestBaseline
        SubThresholdNoiseIgnored = $subThresholdNoiseIgnored
        GapResetRestartsAtCurrentValue = $gapResetRestartsAtCurrentValue
        GapWithoutResetKeepsHistory = $gapWithoutResetKeepsHistory
        RecentResetKeepsSplitSegments = $recentResetKeepsSplitSegments
        MinuteSamplesRetained = $minuteSamplesRetained
        ManualRefreshSampleRetained = $manualRefreshSampleRetained
        LargeHistoryReadFast = $largeHistoryReadFast
        LargeHistoryReadMs = $largeHistoryReadMs
        LargeHistorySampleCount = $largeHistorySampleCount
        LargeHistoryInsightsFast = $largeHistoryInsightsFast
        LargeHistoryInsightsMs = $largeHistoryInsightsMs
        LargeHistoryAnalysisSampleCount = $largeHistoryAnalysisSampleCount
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
        RapidDropUsesWindowStartSample = (
            [bool]$codexNetDrop.Available -and
            -not [bool]$codexNetDrop.IsRapid -and
            [Math]::Abs([double]$codexNetDrop.Drop - 0.2) -lt 0.0001 -and
            [Math]::Abs(
                [double]$codexNetDrop.BaselineValue - 68.2
            ) -lt 0.0001
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
        LegacyWeeklyCodexMigrated = $legacyWeeklyCodexMigrated
        WeeklyQuotaHistoryIsolated = (
            $weeklyHistorySample.QuotaPeriod -eq 'Weekly' -and
            $weeklyHistorySample.RemainingValue -eq 91 -and
            $weeklyPeriodTrend.SampleCount -eq 2 -and
            $weeklyPeriodTrend.Change -eq -5
        )
        CalendarDateAligned = $calendarDateAligned
        ImportMergeRoundTrip = $importMergeRoundTrip
        InvalidImportRejected = $invalidImportRejected
        OversizedImportRejected = $oversizedImportRejected
        FutureSampleExcluded = $futureSampleExcluded
        DiagnosticRedaction = $diagnosticRedaction
        LedgerDropAttributed = (
            [bool]$spendSummaryAfterTopUp.HasToday -and
            [Math]::Abs(
                [double]$spendSummaryAfterTopUp.TodaySpent - 3.0
            ) -lt 0.0001 -and
            [bool]$spendSummaryAfterTopUp.TodayComplete
        )
        LedgerTopUpDoesNotReduceSpend = (
            [Math]::Abs(
                [double]$spendSummaryAfterTopUp.MonthCredit - 100.0
            ) -lt 0.0001 -and
            [Math]::Abs(
                [double]$spendSummaryAfterTopUp.TodaySpent - 3.0
            ) -lt 0.0001
        )
        LedgerSameDayGapAttributed = (
            [Math]::Abs(
                [double]$spendSummarySameDayGap.TodaySpent - 10.0
            ) -lt 0.0001 -and
            [bool]$spendSummarySameDayGap.TodayComplete
        )
        LedgerCrossDayGapExcludedFromDay = (
            [Math]::Abs(
                [double]$spendSummarySameMonthGap.TodaySpent
            ) -lt 0.0001 -and
            -not [bool]$spendSummarySameMonthGap.TodayComplete
        )
        LedgerCrossDayGapCountsInMonth = (
            [Math]::Abs(
                [double]$spendSummarySameMonthGap.MonthSpent - 30.0
            ) -lt 0.0001 -and
            [Math]::Abs(
                [double]$spendSummarySameMonthGap.MonthGapDrop - 30.0
            ) -lt 0.0001 -and
            [bool]$spendSummarySameMonthGap.MonthComplete
        )
        LedgerCrossMonthGapUnattributed = (
            [Math]::Abs(
                [double]$spendSummaryCrossMonthGap.TodaySpent
            ) -lt 0.0001 -and
            -not [bool]$spendSummaryCrossMonthGap.TodayComplete -and
            [Math]::Abs(
                [double]$spendSummaryCrossMonthGap.MonthSpent
            ) -lt 0.0001 -and
            -not [bool]$spendSummaryCrossMonthGap.MonthComplete -and
            [int]$spendSummaryCrossMonthGap.GapDropCount -eq 1
        )
        LedgerPruneKeepsTwoMonths = (
            $ledgerRetentionDates.Count -eq 2 -and
            $ledgerRetentionDates -contains '2029-12-20' -and
            $ledgerRetentionDates -contains '2030-01-05'
        )
        LedgerRoundTrip = (
            [bool]$spendLedgerSaved -and
            [Math]::Abs(
                [double]$reloadedSpendSummary.MonthSpent - 3.0
            ) -lt 0.0001 -and
            [Math]::Abs(
                [double]$reloadedSpendSummary.MonthCredit - 100.0
            ) -lt 0.0001 -and
            $reloadedSpendDocument -notmatch '(?i)(ApiKey|AccessToken|AccountEmail)'
        )
        LedgerCorruptFileFallsBackEmpty = (
            @($corruptSpendLedger.Providers).Count -eq 0
        )
        LedgerSeedIsOneShot = (
            $seedFirstCount -eq 2 -and
            $seedSecondCount -eq 0 -and
            [Math]::Abs([double]$seedSummary.TodaySpent - 2.0) -lt 0.0001 -and
            [Math]::Abs(
                [double]$seedResummary.TodaySpent - 2.0
            ) -lt 0.0001
        )
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
