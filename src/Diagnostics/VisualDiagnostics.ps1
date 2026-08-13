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

    function Set-CaptureUsageHistory {
        param(
            $Snapshot,
            [double[]]$Values
        )

        $hoursAgo = @(168, 120, 72, 48, 24, 12, 4, 0)
        $now = [DateTimeOffset]::Now
        $history = New-Object Collections.Generic.List[object]
        for ($index = 0; $index -lt $hoursAgo.Count; $index++) {
            $sampleSnapshot = $Snapshot.PSObject.Copy()
            if ([bool]$sampleSnapshot.HasProgress) {
                $sampleSnapshot.RemainingPercent = $Values[$index]
            }
            if (
                [string]$sampleSnapshot.ProviderId -eq 'DeepSeek' -and
                $sampleSnapshot.PSObject.Properties['TotalBalance']
            ) {
                $sampleSnapshot.TotalBalance = [Math]::Round(
                    120 * ($Values[$index] / 100),
                    2
                )
            }
            foreach ($sample in @(
                ConvertTo-UsageHistorySamples `
                    -Snapshot $sampleSnapshot `
                    -ObservedAt $now.AddHours(-$hoursAgo[$index])
            )) {
                $history.Add($sample)
            }
        }
        $script:UsageHistoryCache = $history.ToArray()
    }

    $captureRoot = [IO.Path]::GetFullPath($CaptureDirectory)
    [void][IO.Directory]::CreateDirectory($captureRoot)
    $window.ShowInTaskbar = $false
    $window.Left = 24
    $window.Top = 24
    $window.Show()
    Wait-ForCaptureUi -Milliseconds 80
    Set-RefreshBusy -Busy $false

    $previewSnapshot = Get-DeepSeekDemoSnapshot
    Set-CaptureUsageHistory `
        -Snapshot $previewSnapshot `
        -Values @(96, 93, 90, 86, 82, 78, 74, 72)
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

    $script:EdgeDockSide = 'Left'
    $window.Top = 24
    Set-Progress -Percent 82
    Set-EdgeDockReveal -Revealed $false -Immediate
    Wait-ForCaptureUi -Milliseconds 40
    $edgeLeftPath = Join-Path $captureRoot 'edge-energy-left.png'
    Save-VisualPng -Element $window -Path $edgeLeftPath
    $captureFiles['edge-energy-left'] = $edgeLeftPath
    $script:EdgeDockSide = 'Right'
    Set-EdgeDockReveal -Revealed $false -Immediate
    Wait-ForCaptureUi -Milliseconds 40
    $edgeRightPath = Join-Path $captureRoot 'edge-energy-right.png'
    Save-VisualPng -Element $window -Path $edgeRightPath
    $captureFiles['edge-energy-right'] = $edgeRightPath
    Clear-EdgeDock
    $window.Left = 24

    $balancePreviewSnapshot = Get-DeepSeekDemoSnapshot
    $balancePreviewSnapshot.HasProgress = $false
    $balancePreviewSnapshot.WindowLabel = '余额'
    Update-UsageView -Snapshot $balancePreviewSnapshot
    Set-ExpandedState -Expanded $false -Immediate
    Wait-ForCaptureUi -Milliseconds 40
    $compactBalancePath = Join-Path $captureRoot 'compact-balance.png'
    Save-VisualPng -Element $window -Path $compactBalancePath
    $captureFiles['compact-balance'] = $compactBalancePath

    Set-CaptureUsageHistory `
        -Snapshot $previewSnapshot `
        -Values @(96, 93, 90, 86, 82, 78, 74, 72)
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
        Available = $true
        HasProgress = $true
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
        ResetAt = [DateTimeOffset]::Now.AddDays(4)
        Status = '额度充足'
        Source = 'Codex 本地会话快照'
    }
    Set-CaptureUsageHistory `
        -Snapshot $codexPreviewSnapshot `
        -Values @(91, 88, 85, 82, 78, 74, 71, 68)
    Update-UsageView -Snapshot $codexPreviewSnapshot
    Set-ExpandedState -Expanded $true -Immediate
    Wait-ForCaptureUi -Milliseconds 40
    $expandedCodexPath = Join-Path $captureRoot 'expanded-codex.png'
    Save-VisualPng -Element $window -Path $expandedCodexPath
    $captureFiles['expanded-codex'] = $expandedCodexPath

    $window.Close()
    [pscustomobject]$captureFiles | ConvertTo-Json
    $script:RmfStopLoading = $true
    return
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

    $singleInstanceScoped = (
        $script:SingleInstanceObjectNames.Mutex.EndsWith(
            '.' + $script:SingleInstanceObjectNames.Scope,
            [StringComparison]::Ordinal
        ) -and
        $script:SingleInstanceObjectNames.ActivationEvent.EndsWith(
            '.' + $script:SingleInstanceObjectNames.Scope,
            [StringComparison]::Ordinal
        ) -and
        $script:SingleInstanceObjectNames.Mutex -ne
            'Local\RemainingMarginFloat.Singleton' -and
        $script:SingleInstanceObjectNames.ActivationEvent -ne
            'Local\RemainingMarginFloat.Activate'
    )
    if (-not $singleInstanceScoped) {
        throw 'Single-instance objects are not scoped to the current Windows user.'
    }

    $window.Opacity = 0
    $window.Left = 1812
    $window.Top = 980
    $window.Show()
    Wait-ForUi -Milliseconds 50
    [void]$window.Activate()
    $deactivationProbe = New-Object Windows.Window
    $deactivationProbe.Width = 1
    $deactivationProbe.Height = 1
    $deactivationProbe.Left = -10000
    $deactivationProbe.Top = -10000
    $deactivationProbe.ShowInTaskbar = $false
    $deactivationProbe.WindowStyle = [Windows.WindowStyle]::None
    $deactivationProbe.Topmost = $true
    try {
        $deactivationProbe.Show()
        [void]$deactivationProbe.Activate()
        Wait-ForUi -Milliseconds 50
    }
    finally {
        $deactivationProbe.Close()
    }
    [void]$window.Activate()
    Wait-ForUi -Milliseconds 50
    if (-not $script:DeactivationCallbackObserved) {
        throw 'Window deactivation callback was not observed.'
    }
    $script:ReentrantCallbackObserved = $false
    $script:ReentrantInnerHandler = New-RmfEventHandler `
        -Kind Event `
        -Callback {
            $script:ReentrantCallbackObserved = $true
        }
    $reentrantOuterHandler = New-RmfEventHandler `
        -Kind Event `
        -Callback {
            $script:ReentrantInnerHandler.Invoke(
                $null,
                [EventArgs]::Empty
            )
        }
    $reentrantOuterHandler.Invoke($null, [EventArgs]::Empty)
    Wait-ForUi -Milliseconds 50
    if (-not $script:ReentrantCallbackObserved) {
        throw 'Reentrant event callback was not observed.'
    }
    $script:ReentrantInnerHandler = $null
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
    Set-Progress -Percent 72.4
    $fractionalProgressRemaining = $RemainingProgressColumn.Width.Value
    $fractionalProgressUsed = $UsedProgressColumn.Width.Value
    $fractionalBlend = Get-BlendedColor `
        -From '#000000' `
        -To '#FFFFFF' `
        -Amount 0.5
    $script:ActiveProvider = 'Codex'
    Sync-ProviderMenuState
    $codexSettingsVisibility = [string]$script:DeepSeekSettingsMenuItem.Visibility
    $script:ActiveProvider = 'DeepSeek'
    Sync-ProviderMenuState
    $deepSeekSettingsVisibility = [string]$script:DeepSeekSettingsMenuItem.Visibility
    $diagnosticNow = [DateTimeOffset]::Now
    $script:UsageHistoryCache = @(
        foreach ($item in @(
            @{ Hours = 21; Percent = 91; Balance = 109.2 },
            @{ Hours = 15; Percent = 86; Balance = 103.2 },
            @{ Hours = 9; Percent = 80; Balance = 96.0 },
            @{ Hours = 4; Percent = 76; Balance = 91.2 },
            @{ Hours = 1; Percent = 73; Balance = 87.6 }
        )) {
            foreach ($metric in @(
                @{ Type = 'Percent'; Value = $item.Percent; Unit = '%' },
                @{ Type = 'Balance'; Value = $item.Balance; Unit = 'CNY' }
            )) {
                [pscustomobject]@{
                    Version = 2
                    ProviderId = 'DeepSeek'
                    ObservedAtUtc = $diagnosticNow.AddHours(-$item.Hours)
                    LocalDate = $diagnosticNow.AddHours(-$item.Hours).ToString('yyyy-MM-dd')
                    TimeZoneId = [TimeZoneInfo]::Local.Id
                    UtcOffsetMinutes = 0
                    MetricType = $metric.Type
                    RemainingValue = $metric.Value
                    Unit = $metric.Unit
                    ResetAtUtc = ''
                }
            }
        }
    )
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
    $trend24PointCount = $Trend24Line.Points.Count
    $trend7PointCount = $Trend7Line.Points.Count
    $trend24MetaTextValue = $Trend24MetaText.Text
    $trend7MetaTextValue = $Trend7MetaText.Text
    $rapidDropStatusTextValue = $RapidDropText.Text

    $timeAxisSamples = @(
        [pscustomobject]@{
            ObservedAtUtc = $diagnosticNow.AddHours(-24)
            RemainingValue = 90
            MetricType = 'Percent'
        },
        [pscustomobject]@{
            ObservedAtUtc = $diagnosticNow.AddHours(-18)
            RemainingValue = 80
            MetricType = 'Percent'
        },
        [pscustomobject]@{
            ObservedAtUtc = $diagnosticNow
            RemainingValue = 70
            MetricType = 'Percent'
        }
    )
    Set-TrendChart `
        -Canvas $Trend24Canvas `
        -Polyline $Trend24Line `
        -Area $Trend24Area `
        -StartMarker $Trend24StartMarker `
        -EndMarker $Trend24EndMarker `
        -Samples $timeAxisSamples `
        -Hours 24 `
        -Now $diagnosticNow
    $timeAxisWidth = if ($Trend24Canvas.ActualWidth -gt 10) {
        [double]$Trend24Canvas.ActualWidth
    } else { [double]$Trend24Canvas.Width }
    $trendTimeAxisAligned = (
        $Trend24Line.Points.Count -eq 3 -and
        [Math]::Abs([double]$Trend24Line.Points[0].X) -lt 0.1 -and
        [Math]::Abs(
            [double]$Trend24Line.Points[1].X - ($timeAxisWidth * 0.25)
        ) -lt 0.5 -and
        [Math]::Abs(
            [double]$Trend24Line.Points[2].X - $timeAxisWidth
        ) -lt 0.5
    )

    $resetUiSamples = @(
        [pscustomobject]@{ Version = 2; ProviderId = 'Codex'; ObservedAtUtc = $diagnosticNow.AddHours(-1); MetricType = 'Percent'; RemainingValue = 37; Unit = '%'; ResetAtUtc = '' },
        [pscustomobject]@{ Version = 2; ProviderId = 'Codex'; ObservedAtUtc = $diagnosticNow; MetricType = 'Percent'; RemainingValue = 98; Unit = '%'; ResetAtUtc = '' }
    )
    $resetUiInsights = Measure-UsageInsights `
        -Samples $resetUiSamples `
        -CurrentSample $resetUiSamples[-1] `
        -PreviousSample $resetUiSamples[-2] `
        -Now $diagnosticNow
    Update-UsageInsightView -Insights $resetUiInsights
    $resetTrendUiStartsAccumulating = (
        $Trend24Text.Text -eq ([string]([char]0x79EF) + [char]0x7D2F + [char]0x4E2D) -and
        $Trend7Text.Text -eq ([string]([char]0x79EF) + [char]0x7D2F + [char]0x4E2D) -and
        $Trend24MetaText.Text -notmatch ([string][char]0x2192) -and
        $Trend7MetaText.Text -notmatch ([string][char]0x2192) -and
        $Trend24Text.Text -notmatch ([string][char]0x2191) -and
        $Trend7Text.Text -notmatch ([string][char]0x2191)
    )

    Set-UsageStatusPalette -Percent 90 -Available $true
    $trendHealthyPaletteColor = (
        [Windows.Media.SolidColorBrush]$window.Resources['SageSoft']
    ).Color.ToString()
    $trendHealthyBackgroundColor = (
        [Windows.Media.SolidColorBrush]$Trend24Card.Background
    ).Color.ToString()
    $trendHealthyBackgroundsMatch = (
        $trendHealthyBackgroundColor -eq $trendHealthyPaletteColor -and
        ([Windows.Media.SolidColorBrush]$Trend7Card.Background).Color.ToString() -eq
            $trendHealthyPaletteColor
    )

    Set-UsageStatusPalette -Percent 10 -Available $true
    $trendLowPaletteColor = (
        [Windows.Media.SolidColorBrush]$window.Resources['SageSoft']
    ).Color.ToString()
    $trendLowBackgroundColor = (
        [Windows.Media.SolidColorBrush]$Trend24Card.Background
    ).Color.ToString()
    $trendLowBackgroundsMatch = (
        $trendLowBackgroundColor -eq $trendLowPaletteColor -and
        ([Windows.Media.SolidColorBrush]$Trend7Card.Background).Color.ToString() -eq
            $trendLowPaletteColor
    )
    $trendCardsFollowQuotaPalette = (
        $trendHealthyBackgroundsMatch -and
        $trendLowBackgroundsMatch -and
        (
            $script:HighContrast -or
            $trendHealthyBackgroundColor -ne $trendLowBackgroundColor
        )
    )
    Set-UsageStatusPalette -Percent 0 -Available $false

    $script:RapidDropAlertsEnabled = $true
    $script:UsageSyncSession.RapidSamples = @()
    $script:UsageSyncSession.RapidChannels = @{}
    $startupLocalSnapshot = $deepSeekCheckSnapshot.PSObject.Copy()
    $startupLocalSnapshot.ProviderId = 'Codex'
    $startupLocalSnapshot.HasProgress = $true
    $startupLocalSnapshot.RemainingPercent = 87
    $startupLocalSnapshot | Add-Member `
        -NotePropertyName TodayCachedTokens `
        -NotePropertyValue 640000 `
        -Force
    $startupLocalSnapshot | Add-Member `
        -NotePropertyName TodayOutputTokens `
        -NotePropertyValue 120000 `
        -Force
    $startupLocalSnapshot | Add-Member `
        -NotePropertyName TodayCacheHitPercent `
        -NotePropertyValue 64.0 `
        -Force
    $startupLocalSnapshot.WindowLabel = '本周余量'
    $startupLocalSnapshot.Plan = 'Pro'
    $startupLocalSnapshot.Source = '本地会话余量快照'
    $startupLocalSnapshot.SampledAt = $diagnosticNow.AddHours(-8)
    Update-UsageView `
        -Snapshot $startupLocalSnapshot `
        -ObservationContext 'StartupLocal'
    $startupLocalRapidSuppressed = (
        [string]$RapidDropText.Text -match '本地快照不计入快速下降'
    )
    $startupLocalMessage = Format-StartupUsageSnapshotMessage `
        -Snapshot $startupLocalSnapshot `
        -ObservationContext 'StartupLocal'

    $startupOfficialSnapshot = $startupLocalSnapshot.PSObject.Copy()
    $startupOfficialSnapshot.RemainingPercent = 56
    $startupOfficialSnapshot.Source = '官方用量接口 · 本地令牌汇总'
    $startupOfficialSnapshot.SampledAt = $diagnosticNow
    Update-UsageView `
        -Snapshot $startupOfficialSnapshot `
        -ObservationContext 'StartupOfficial'
    $startupOfficialRapidSuppressed = (
        [string]$RapidDropText.Text -match '正在建立连续使用基线'
    )
    $startupOfficialMessage = Format-StartupUsageSnapshotMessage `
        -Snapshot $startupOfficialSnapshot `
        -ObservationContext 'StartupOfficial'

    $localPreviewSnapshot = $startupOfficialSnapshot.PSObject.Copy()
    $localPreviewSnapshot.RemainingPercent = 20
    $localPreviewSnapshot.Source = '本地会话余量快照'
    Update-UsageView `
        -Snapshot $localPreviewSnapshot `
        -ObservationContext 'LocalPreview'
    $localPreviewRapidSuppressed = (
        [string]$RapidDropText.Text -match '本地快照不计入快速下降'
    )

    $continuousOfficialSnapshot = $startupOfficialSnapshot.PSObject.Copy()
    $continuousOfficialSnapshot.RemainingPercent = 39
    $continuousOfficialSnapshot.SampledAt = $diagnosticNow.AddMinutes(1)
    Update-UsageView -Snapshot $continuousOfficialSnapshot
    $continuousRapidDropDetected = (
        [string]$RapidDropText.Text -match '检测到快速下降' -and
        [string]$RapidDropText.Text -match '下降 17pp'
    )
    $gapSnapshot = $continuousOfficialSnapshot.PSObject.Copy()
    $gapSnapshot.RemainingPercent = 20
    $gapInsights = [pscustomobject]@{ RapidDrop = $null }
    $gapInsights = Set-SessionRapidDropInsight `
        -Snapshot $gapSnapshot `
        -Insights $gapInsights `
        -ObservedAt ([DateTimeOffset]::Now.AddSeconds(
            ($script:RefreshIntervalSeconds * 3) + 1
        ))
    $continuityGapReset = (
        -not [bool]$gapInsights.RapidDrop.IsRapid -and
        [string]$gapInsights.RapidDrop.Summary -match '监控间隔中断'
    )
    $startupSnapshotMessagesReady = (
        $startupLocalMessage -match '本地快照.*余量 87%.*\d{2}:\d{2}:\d{2}' -and
        $startupOfficialMessage -match '官方接口.*余量 56%.*\d{2}:\d{2}:\d{2}'
    )
    if (
        -not $startupLocalRapidSuppressed -or
        -not $startupOfficialRapidSuppressed -or
        -not $localPreviewRapidSuppressed -or
        -not $continuousRapidDropDetected -or
        -not $continuityGapReset -or
        -not $startupSnapshotMessagesReady
    ) {
        throw (
            'Startup synchronization alert policy failed: local={0}, ' +
            'official={1}, preview={2}, continuous={3}, gap={4}, messages={5}, ' +
            'text={6}.'
        ) -f
            $startupLocalRapidSuppressed,
            $startupOfficialRapidSuppressed,
            $localPreviewRapidSuppressed,
            $continuousRapidDropDetected,
            $continuityGapReset,
            $startupSnapshotMessagesReady,
            [string]$RapidDropText.Text
    }

    Set-Progress -Percent 82
    Set-ExpandedState -Expanded $false -Immediate
    $compactHeaderRestored = (
        [string]$RemainingSummaryPanel.HorizontalAlignment -eq 'Center' -and
        [string]$RemainingNumberPanel.HorizontalAlignment -eq 'Center' -and
        [double]$RemainingValue.FontSize -eq 23 -and
        [double]$RemainingValue.LineHeight -eq 26 -and
        [string]$WindowLabel.HorizontalAlignment -eq 'Center'
    )
    $anchorLeft = $window.Left
    $anchorTop = $window.Top

    Set-ExpandedState -Expanded $true
    Wait-ForUi -Milliseconds 300
    $expandedWidth = $window.ActualWidth
    $expandedHeight = $window.ActualHeight
    $expandedVisibility = [string]$DetailsPanel.Visibility
    $window.UpdateLayout()
    $expandedHeaderHierarchy = (
        [string]$RemainingSummaryPanel.HorizontalAlignment -eq 'Left' -and
        [string]$RemainingNumberPanel.HorizontalAlignment -eq 'Left' -and
        [double]$RemainingValue.FontSize -eq 28 -and
        [double]$RemainingValue.LineHeight -eq 31 -and
        [double]$CompactPrefix.FontSize -eq 10 -and
        [double]$CompactSuffix.FontSize -eq 10 -and
        [string]$WindowLabel.HorizontalAlignment -eq 'Left' -and
        [string]$ResetSummaryPanel.HorizontalAlignment -eq 'Right' -and
        [double]$DetailsResetPrefix.FontSize -eq 10.5 -and
        [double]$DetailsResetDate.FontSize -eq 10.5 -and
        [double]$DetailsResetSeparator.FontSize -eq 10.5 -and
        [double]$DetailsResetCountdown.FontSize -eq 10.5 -and
        [double]$DetailsResetDate.FontSize -lt 23 -and
        [double]$DetailsResetDate.FontSize -lt
            [double]$RemainingValue.FontSize
    )
    $footerTextRuns = @(
        $VersionLabelText,
        $AppVersionText,
        $VersionSeparatorText,
        $AutoRefreshText
    )
    $footerTextAligned = (
        [double]$FooterStatusText.LineHeight -eq 14 -and
        [string]$VersionLabelText.FontFamily.Source -eq
            'Microsoft YaHei UI' -and
        [string]$AppVersionText.FontFamily.Source -eq
            'Segoe UI Variable Text' -and
        [string]$AutoRefreshText.FontFamily.Source -eq
            'Microsoft YaHei UI' -and
        @(
            $footerTextRuns | Where-Object {
                [string]$_.BaselineAlignment -ne 'Baseline' -or
                -not [object]::ReferenceEquals(
                    $_.Parent,
                    $FooterStatusText
                )
            }
        ).Count -eq 0
    )
    $trendContentBottom = (
        @(
            $Trend24Canvas.TranslatePoint(
                (New-Object Windows.Point(0, $Trend24Canvas.ActualHeight)),
                $DetailsPanel
            ).Y,
            $Trend7Canvas.TranslatePoint(
                (New-Object Windows.Point(0, $Trend7Canvas.ActualHeight)),
                $DetailsPanel
            ).Y,
            $Trend24MetaText.TranslatePoint(
                (New-Object Windows.Point(0, $Trend24MetaText.ActualHeight)),
                $DetailsPanel
            ).Y,
            $Trend7MetaText.TranslatePoint(
                (New-Object Windows.Point(0, $Trend7MetaText.ActualHeight)),
                $DetailsPanel
            ).Y
        ) | Measure-Object -Maximum
    ).Maximum
    $rapidDropTextTop = $RapidDropText.TranslatePoint(
        (New-Object Windows.Point(0, 0)),
        $DetailsPanel
    ).Y
    $trendRapidDropGap = $rapidDropTextTop - $trendContentBottom
    if ($trendRapidDropGap -lt 6) {
        throw (
            'Trend content overlaps rapid-drop status: gap={0:0.##}.' -f
                $trendRapidDropGap
        )
    }

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

    $script:EdgeDockSide = 'Right'
    $script:EdgeDockWorkArea = $null
    Set-EdgeDockReveal -Revealed $false -Immediate
    $window.UpdateLayout()
    $actualEdgeWorkArea = [Windows.Rect](@(Get-WindowWorkArea)[-1])
    $shiftedEdgeLeft = [double]$actualEdgeWorkArea.Left + 24
    $script:EdgeDockWorkArea = New-Object Windows.Rect(
        $shiftedEdgeLeft,
        $actualEdgeWorkArea.Top,
        $actualEdgeWorkArea.Width,
        $actualEdgeWorkArea.Height
    )
    $edgeEnvironmentResynced = Sync-EdgeDockEnvironment
    $window.UpdateLayout()
    $hiddenTrackX = $UltraProgressTrack.TranslatePoint(
        (New-Object Windows.Point(0, 0)),
        $WindowRoot
    ).X
    $hiddenRailHitTest = $UltraCompactPanel.IsHitTestVisible
    $hiddenRailAlpha = ([Windows.Media.SolidColorBrush]$UltraCompactPanel.Background).Color.A
    $depletedMaskColor = (
        [Windows.Media.SolidColorBrush]$UltraDepletedMask.Background
    ).Color
    $depletedMaskOpaque = $depletedMaskColor.A -eq 255
    $depletedMaskNeutralGray = (
        (
            @(
                $depletedMaskColor.R,
                $depletedMaskColor.G,
                $depletedMaskColor.B
            ) | Measure-Object -Maximum
        ).Maximum -
        (
            @(
                $depletedMaskColor.R,
                $depletedMaskColor.G,
                $depletedMaskColor.B
            ) | Measure-Object -Minimum
        ).Minimum -le 12 -and
        (
            $depletedMaskColor.R +
            $depletedMaskColor.G +
            $depletedMaskColor.B
        ) / 3 -lt 140
    )
    $edgeTrackInset = $UltraProgressTrack.TranslatePoint(
        (New-Object Windows.Point(0, 0)),
        $UltraCompactPanel
    ).X
    $edgeTrackTrailingInset = (
        $UltraCompactPanel.ActualWidth -
        $edgeTrackInset -
        $UltraProgressTrack.ActualWidth
    )
    $edgeRevealHitWidth = $UltraCompactPanel.ActualWidth
    $edgeDockAnchorRight = $script:EdgeDockWorkArea.Right
    $energyFillOrigin = $UltraProgressFill.TranslatePoint(
        (New-Object Windows.Point(0, 0)),
        $UltraProgressTrack
    )
    $energyFillRightInset = (
        $UltraProgressTrack.ActualWidth -
        $energyFillOrigin.X -
        $UltraProgressFill.ActualWidth
    )
    $energyFillBottomInset = (
        $UltraProgressTrack.ActualHeight -
        $energyFillOrigin.Y -
        $UltraProgressFill.ActualHeight
    )
    $outlineThickness = $UltraProgressOutline.BorderThickness
    $outlineCorners = $UltraProgressOutline.CornerRadius
    $horizontalEnergyInset = $energyFillOrigin.X + $energyFillRightInset
    $verticalEnergyInset = $energyFillOrigin.Y + $energyFillBottomInset
    $energyContainedByOutline = (
        $energyFillOrigin.X -gt 0 -and
        $energyFillOrigin.Y -gt 0 -and
        $energyFillRightInset -gt 0 -and
        $energyFillBottomInset -gt 0 -and
        [Math]::Abs($horizontalEnergyInset - 2) -lt 0.01 -and
        [Math]::Abs($verticalEnergyInset - 2) -lt 0.01 -and
        $outlineThickness.Left -eq 1 -and
        $outlineThickness.Top -eq 1 -and
        $outlineThickness.Right -eq 1 -and
        $outlineThickness.Bottom -eq 1 -and
        $outlineCorners.TopLeft -eq 2 -and
        $outlineCorners.TopRight -eq 2 -and
        $outlineCorners.BottomRight -eq 2 -and
        $outlineCorners.BottomLeft -eq 2
    )
    $expectedEdgeGap = 0
    $edgeTrackFlushInPanel = (
        [Math]::Abs([Math]::Min($edgeTrackInset, $edgeTrackTrailingInset)) -lt 0.01 -and
        [Math]::Abs(
            [Math]::Max($edgeTrackInset, $edgeTrackTrailingInset) -
            ($script:EdgeVisibleWidth - $UltraProgressTrack.ActualWidth)
        ) -lt 0.01
    )
    $edgeGapSamples = @()
    $edgePixelGapSamples = @()
    function Get-CurrentEdgePixelGap {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        $screenArea = [System.Windows.Forms.Screen]::FromHandle($helper.Handle).WorkingArea
        $edgeElement = if ($script:IsEdgeRevealed) {
            $Surface
        }
        else {
            $UltraProgressTrack
        }
        $visualEdge = if ($script:EdgeDockSide -eq 'Left') {
            $edgeElement.PointToScreen(
                (New-Object Windows.Point(0, 0))
            ).X
        }
        else {
            $edgeElement.PointToScreen(
                (New-Object Windows.Point($edgeElement.ActualWidth, 0))
            ).X
        }
        $screenEdge = if ($script:EdgeDockSide -eq 'Left') {
            [double]$screenArea.Left
        }
        else {
            [double]$screenArea.Right
        }
        return [Math]::Abs($screenEdge - $visualEdge)
    }
    foreach ($side in @('Right', 'Left')) {
        $script:EdgeDockSide = $side
        foreach ($cycle in 1..8) {
            Set-EdgeDockReveal -Revealed $true -Immediate
            Set-EdgeDockReveal -Revealed $false -Immediate
            $window.UpdateLayout()
            $trackX = $UltraProgressTrack.TranslatePoint(
                (New-Object Windows.Point(0, 0)),
                $window
            ).X
            $trackScreenLeft = $window.Left + $trackX
            $edgeGapSamples += if ($side -eq 'Right') {
                $script:EdgeDockWorkArea.Right - (
                    $trackScreenLeft + $UltraProgressTrack.ActualWidth
                )
            } else {
                $trackScreenLeft - $script:EdgeDockWorkArea.Left
            }
            $edgePixelGapSamples += Get-CurrentEdgePixelGap
        }
    }
    $edgeGapStableAcrossCycles = @(
        $edgeGapSamples | Where-Object {
            [Math]::Abs($_ - $expectedEdgeGap) -ge 0.01
        }
    ).Count -eq 0
    $edgeDockAnchorStable = (
        [Math]::Abs(
            $script:EdgeDockWorkArea.Right - $edgeDockAnchorRight
        ) -lt 0.01
    )
    $edgePixelAlignedAcrossCycles = @(
        $edgePixelGapSamples | Where-Object { $_ -ge 0.01 }
    ).Count -eq 0
    $animatedEdgePixelGapSamples = @()
    $animatedRevealPixelGapSamples = @()
    foreach ($side in @('Right', 'Left')) {
        $script:EdgeDockSide = $side
        foreach ($cycle in 1..6) {
            Set-EdgeDockReveal -Revealed $false -Immediate
            Set-EdgeDockReveal -Revealed $true
            Wait-ForUi -Milliseconds ($script:EdgeRevealDurationMs + 45)
            $window.UpdateLayout()
            $animatedRevealPixelGapSamples += Get-CurrentEdgePixelGap
            Set-EdgeDockReveal -Revealed $false
            Wait-ForUi -Milliseconds ($script:EdgeHideDurationMs + 45)
            $window.UpdateLayout()
            $animatedEdgePixelGapSamples += Get-CurrentEdgePixelGap
        }
    }
    $animatedEdgePixelAligned = @(
        $animatedEdgePixelGapSamples | Where-Object { $_ -ge 0.01 }
    ).Count -eq 0
    $animatedRevealPixelAligned = @(
        $animatedRevealPixelGapSamples | Where-Object { $_ -ge 0.01 }
    ).Count -eq 0
    $script:EdgeDockSide = 'Right'
    $script:IsPointerOverSurface = $true
    Set-EdgeDockReveal -Revealed $false -Immediate
    $script:EdgeRevealTimer.Stop()
    $script:EdgeRevealTimer.Start()
    Wait-ForUi -Milliseconds (
        70 + $script:EdgeRevealDurationMs + 70
    )
    $window.UpdateLayout()
    $hoverTimerRevealedEdgeDock = $script:IsEdgeRevealed
    $hoverRevealPixelAligned = (
        $hoverTimerRevealedEdgeDock -and
        (Get-CurrentEdgePixelGap) -lt 0.01
    )
    $script:IsPointerOverSurface = $false
    $script:EdgeDockSide = 'Right'
    Set-EdgeDockReveal -Revealed $false -Immediate
    Set-EdgeDockReveal -Revealed $true -Immediate
    $window.UpdateLayout()
    $revealedTrackX = $UltraProgressTrack.TranslatePoint(
        (New-Object Windows.Point(0, 0)),
        $WindowRoot
    ).X
    $edgeSpacingStable = [Math]::Abs($hiddenTrackX - $revealedTrackX) -lt 0.01
    if (
        -not $hiddenRailHitTest -or
        $hiddenRailAlpha -lt 8 -or
        -not $depletedMaskOpaque -or
        -not $depletedMaskNeutralGray -or
        -not $edgeEnvironmentResynced -or
        [Math]::Abs($edgeRevealHitWidth - $script:EdgeVisibleWidth) -ge 0.01 -or
        -not $edgeTrackFlushInPanel -or
        -not $edgeSpacingStable -or
        -not $edgeGapStableAcrossCycles -or
        -not $edgeDockAnchorStable -or
        -not $energyContainedByOutline -or
        -not $edgePixelAlignedAcrossCycles -or
        -not $animatedEdgePixelAligned -or
        -not $animatedRevealPixelAligned -or
        -not $hoverRevealPixelAligned
    ) {
        throw (
            (
                'Edge rail unstable: hit={0}, alpha={1}, width={2}, ' +
                'insets={3}/{4}, spacing={5}, cycles={6}, anchor={7}, ' +
                'pixels={8}, animated={9}, reveal={10}, hover={11}, ' +
                'outline={12}.'
            ) -f
            $hiddenRailHitTest,
            $hiddenRailAlpha,
            $edgeRevealHitWidth,
            $edgeTrackInset,
            $edgeTrackTrailingInset,
            $edgeSpacingStable,
            $edgeGapStableAcrossCycles,
            $edgeDockAnchorStable,
            $edgePixelAlignedAcrossCycles,
            $animatedEdgePixelAligned,
            $animatedRevealPixelAligned,
            $hoverRevealPixelAligned,
            $energyContainedByOutline
        )
    }
    Set-EdgeDockReveal -Revealed $false
    Wait-ForUi -Milliseconds ($script:EdgeHideDurationMs + 60)
    $hiddenSurfaceAlpha = ([Windows.Media.SolidColorBrush]$Surface.Background).Color.A
    if ($hiddenSurfaceAlpha -ne 0) {
        throw 'Compact surface remained visible after the edge-hide animation.'
    }
    Show-ExistingWindow
    $activationRevealedEdgeDock = $script:IsEdgeRevealed
    if (-not $activationRevealedEdgeDock) {
        throw 'Existing-instance activation did not reveal the edge-docked window.'
    }
    Clear-EdgeDock
    $script:RapidDropWindowMinutes = 30
    $script:CodexRapidDropPercent = 10.0
    $settingsHourlyBaselineSnapshot = $startupOfficialSnapshot.PSObject.Copy()
    $settingsHourlyBaselineSnapshot.RemainingPercent = 60
    $settingsBaselineSnapshot = $startupOfficialSnapshot.PSObject.Copy()
    $settingsBaselineSnapshot.RemainingPercent = 56
    $settingsCurrentSnapshot = $startupOfficialSnapshot.PSObject.Copy()
    $settingsCurrentSnapshot.RemainingPercent = 55
    $script:UsageSyncSession.RapidSamples = @(
        ConvertTo-UsageHistorySamples `
            -Snapshot $settingsHourlyBaselineSnapshot `
            -ObservedAt ([DateTimeOffset]::Now.AddMinutes(-50))
        ConvertTo-UsageHistorySamples `
            -Snapshot $settingsBaselineSnapshot `
            -ObservedAt ([DateTimeOffset]::Now.AddMinutes(-1))
    )
    $script:UsageSyncSession.RapidChannels = @{
        Codex = 'CodexOfficial'
    }
    Update-UsageView -Snapshot $settingsCurrentSnapshot
    $rapidDropStatusBeforeSettings = [string]$RapidDropText.Text
    [void](Set-UsageAlertSettings `
        -LowAlertsEnabled $true `
        -LowThreshold 35 `
        -RapidAlertsEnabled $true `
        -WindowMinutes 45 `
        -CodexPercent 12.5 `
        -DeepSeekMode 'Amount' `
        -DeepSeekPercent 11.5 `
        -DeepSeekAmount 8.5)
    $rapidDropStatusAfterSettings = [string]$RapidDropText.Text
    $script:RapidDropAlertsEnabled = $false
    Refresh-RapidDropStatusView
    $rapidDropStatusWhenDisabled = [string]$RapidDropText.Text
    $script:RapidDropAlertsEnabled = $true
    Refresh-RapidDropStatusView
    $rapidDropStatusWhenReenabled = [string]$RapidDropText.Text
    $lowAlertThresholdMenuText = [string]$script:LowAlertsMenuItem.Header
    $usageAlertSettingsMenuText =
        [string]$script:LowAlertThresholdMenuItem.Header
    $lowAlertSettingsSnapshot = Get-AppSettingsSnapshot
    $lowAlertThresholdDialog = New-LowRemainingAlertSettingsDialog
    $lowAlertThresholdDialogReady = (
        $null -ne $lowAlertThresholdDialog.FindName('LowAlertsEnabledBox') -and
        $null -ne $lowAlertThresholdDialog.FindName('ThresholdBox') -and
        $null -ne $lowAlertThresholdDialog.FindName('RapidAlertsEnabledBox') -and
        $null -ne $lowAlertThresholdDialog.FindName('WindowBox') -and
        $null -ne $lowAlertThresholdDialog.FindName('CodexDropBox') -and
        $null -ne $lowAlertThresholdDialog.FindName('DeepSeekModeBox') -and
        $null -ne $lowAlertThresholdDialog.FindName('DeepSeekDropBox') -and
        $null -ne $lowAlertThresholdDialog.FindName('SaveButton') -and
        $null -ne $lowAlertThresholdDialog.FindName('ErrorText')
    )
    $lowAlertThresholdDialog.Close()
    $lastSnapshotBeforeFallback = $script:LastSnapshot
    $historyCountBeforeFallback = @($script:UsageHistoryCache).Count
    $staleFallbackSnapshot = New-UsageFallbackSnapshot `
        -Snapshot $script:LastSnapshot `
        -Reason '官方接口暂时不可用'
    $staleFallbackSnapshot.SampledAt = [DateTimeOffset]::Now.AddMinutes(-15)
    Update-UsageView -Snapshot $staleFallbackSnapshot -DisplayOnly
    $fallbackProvenanceDisplayed = (
        [string]$SourceText.Text -match
            '显示上次数据（15 分钟前）.*官方接口暂时不可用' -and
        [string]$SampleTime.Text -match '15 分钟前'
    )
    $displayOnlyPreservedHistory = (
        [object]::ReferenceEquals(
            $lastSnapshotBeforeFallback,
            $script:LastSnapshot
        ) -and
        @($script:UsageHistoryCache).Count -eq $historyCountBeforeFallback
    )

    $result = [pscustomobject]@{
        VersionText = [string]$AppVersionText.Text
        FooterTextAligned = $footerTextAligned
        ExpandedWidth = $expandedWidth
        ExpandedHeight = $expandedHeight
        ExpandedVisibility = $expandedVisibility
        SingleInstanceUserScoped = $singleInstanceScoped
        DeactivationCallbackObserved = $script:DeactivationCallbackObserved
        ReentrantCallbackObserved = $script:ReentrantCallbackObserved
        TaskViewHidden = $taskViewHidden
        TrayIconWidth = $trayIconWidth
        TrayIconHeight = $trayIconHeight
        UpperClampedRemaining = $upperClampedRemaining
        UpperClampedUsed = $upperClampedUsed
        LowerClampedRemaining = $lowerClampedRemaining
        LowerClampedUsed = $lowerClampedUsed
        FractionalProgressRemaining = $fractionalProgressRemaining
        FractionalProgressUsed = $fractionalProgressUsed
        FractionalBlendRed = $fractionalBlend.R
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
        ActivationRevealedEdgeDock = $activationRevealedEdgeDock
        EdgeRailHitTest = $hiddenRailHitTest
        EdgeRailAlpha = $hiddenRailAlpha
        EdgeDepletedMaskOpaque = $depletedMaskOpaque
        EdgeDepletedMaskNeutralGray = $depletedMaskNeutralGray
        EdgeEnvironmentResynced = $edgeEnvironmentResynced
        EdgeTrackInset = $edgeTrackInset
        EdgeTrackTrailingInset = $edgeTrackTrailingInset
        EdgeTrackWidth = $UltraProgressTrack.ActualWidth
        EdgeTrackFlush = ($edgeTrackFlushInPanel -and $edgeGapStableAcrossCycles)
        EdgeEnergyContainedByOutline = $energyContainedByOutline
        EdgeEnergyInsets = @(
            $energyFillOrigin.X,
            $energyFillOrigin.Y,
            $energyFillRightInset,
            $energyFillBottomInset
        )
        EdgeOutlineThickness = @(
            $outlineThickness.Left,
            $outlineThickness.Top,
            $outlineThickness.Right,
            $outlineThickness.Bottom
        )
        EdgeOutlineCorners = @(
            $outlineCorners.TopLeft,
            $outlineCorners.TopRight,
            $outlineCorners.BottomRight,
            $outlineCorners.BottomLeft
        )
        EdgePixelAlignedAcrossCycles = $edgePixelAlignedAcrossCycles
        AnimatedEdgePixelAligned = $animatedEdgePixelAligned
        AnimatedRevealPixelAligned = $animatedRevealPixelAligned
        HoverTimerRevealedEdgeDock = $hoverTimerRevealedEdgeDock
        HoverRevealPixelAligned = $hoverRevealPixelAligned
        MaximumEdgePixelGap = (
            @(
                $edgePixelGapSamples +
                $animatedEdgePixelGapSamples +
                $animatedRevealPixelGapSamples
            ) |
                Measure-Object -Maximum
        ).Maximum
        EdgeRevealHitWidth = $edgeRevealHitWidth
        EdgeSpacingStable = $edgeSpacingStable
        EdgeGapStableAcrossCycles = $edgeGapStableAcrossCycles
        EdgeDockAnchorStable = $edgeDockAnchorStable
        HiddenSurfaceAlpha = $hiddenSurfaceAlpha
        Trend24Text = $Trend24Text.Text
        CompactHeaderRestored = $compactHeaderRestored
        ExpandedHeaderHierarchy = $expandedHeaderHierarchy
        Trend7Text = $Trend7Text.Text
        Trend24PointCount = $trend24PointCount
        Trend7PointCount = $trend7PointCount
        Trend24MetaText = $trend24MetaTextValue
        Trend7MetaText = $trend7MetaTextValue
        TrendTimeAxisAligned = $trendTimeAxisAligned
        ResetTrendUiStartsAccumulating = $resetTrendUiStartsAccumulating
        TrendCardsFollowQuotaPalette = $trendCardsFollowQuotaPalette
        TrendHealthyBackgroundColor = $trendHealthyBackgroundColor
        TrendHealthyPaletteColor = $trendHealthyPaletteColor
        TrendLowBackgroundColor = $trendLowBackgroundColor
        TrendLowPaletteColor = $trendLowPaletteColor
        PredictionText = $PredictionText.Text
        RapidDropStatusText = $rapidDropStatusTextValue
        StartupLocalRapidSuppressed = $startupLocalRapidSuppressed
        StartupOfficialRapidSuppressed = $startupOfficialRapidSuppressed
        LocalPreviewRapidSuppressed = $localPreviewRapidSuppressed
        ContinuousRapidDropDetected = $continuousRapidDropDetected
        ContinuityGapReset = $continuityGapReset
        StartupSnapshotMessagesReady = $startupSnapshotMessagesReady
        TrendRapidDropGap = $trendRapidDropGap
        UsageHistoryError = $script:LastUsageHistoryError
        LowAlertMenuChecked = [bool]$script:LowAlertsMenuItem.IsChecked
        LowAlertThresholdMenuText = $lowAlertThresholdMenuText
        UsageAlertSettingsMenuText = $usageAlertSettingsMenuText
        LowAlertThresholdPersisted = (
            [double]$lowAlertSettingsSnapshot.LowRemainingThreshold -eq 35
        )
        AutoUpdateSettingPersisted = (
            $null -ne $lowAlertSettingsSnapshot.PSObject.Properties[
                'AutoUpdateEnabled'
            ] -and
            [bool]$lowAlertSettingsSnapshot.AutoUpdateEnabled -eq
                [bool]$script:AutoUpdateEnabled
        )
        RapidDropSettingsPersisted = (
            [bool]$lowAlertSettingsSnapshot.RapidDropAlertsEnabled -and
            [int]$lowAlertSettingsSnapshot.RapidDropWindowMinutes -eq 45 -and
            [double]$lowAlertSettingsSnapshot.CodexRapidDropPercent -eq 12.5 -and
            [string]$lowAlertSettingsSnapshot.DeepSeekRapidDropMode -eq 'Amount' -and
            [double]$lowAlertSettingsSnapshot.DeepSeekRapidDropPercent -eq 11.5 -and
            [double]$lowAlertSettingsSnapshot.DeepSeekRapidDropAmount -eq 8.5
        )
        RapidDropStatusBeforeSettings = $rapidDropStatusBeforeSettings
        RapidDropStatusAfterSettings = $rapidDropStatusAfterSettings
        RapidDropStatusWhenDisabled = $rapidDropStatusWhenDisabled
        RapidDropStatusWhenReenabled = $rapidDropStatusWhenReenabled
        RapidDropStatusUpdatedImmediately = (
            [string]::Equals(
                $rapidDropStatusBeforeSettings,
                '30 分钟内下降 1pp · 阈值 10pp',
                [StringComparison]::Ordinal
            ) -and
            [string]::Equals(
                $rapidDropStatusAfterSettings,
                '45 分钟内下降 1pp · 阈值 12.5pp',
                [StringComparison]::Ordinal
            )
        )
        RapidDropDisabledShowsHourlyChange = [string]::Equals(
            $rapidDropStatusWhenDisabled,
            '1 小时内下降 5pp',
            [StringComparison]::Ordinal
        )
        RapidDropReenabledRestoresConfiguredWindow = [string]::Equals(
            $rapidDropStatusWhenReenabled,
            '45 分钟内下降 1pp · 阈值 12.5pp',
            [StringComparison]::Ordinal
        )
        FallbackProvenanceDisplayed = $fallbackProvenanceDisplayed
        DisplayOnlyPreservedHistory = $displayOnlyPreservedHistory
        LowAlertThresholdInvalidFallback = (
            (ConvertTo-LowRemainingThreshold `
                -Value 'invalid' `
                -Fallback 20) -eq 20
        )
        LowAlertThresholdDialogReady = $lowAlertThresholdDialogReady
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
    $script:RmfStopLoading = $true
    return
}
