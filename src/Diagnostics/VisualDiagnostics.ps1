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

    $script:EdgeDockSide = 'Right'
    $script:EdgeDockWorkArea = $null
    Set-EdgeDockReveal -Revealed $false -Immediate
    $window.UpdateLayout()
    $hiddenTrackX = $UltraProgressTrack.TranslatePoint(
        (New-Object Windows.Point(0, 0)),
        $WindowRoot
    ).X
    $hiddenRailHitTest = $UltraCompactPanel.IsHitTestVisible
    $hiddenRailAlpha = ([Windows.Media.SolidColorBrush]$UltraCompactPanel.Background).Color.A
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
    $energyContainedByOutline = (
        [Math]::Abs($energyFillOrigin.X - 1) -lt 0.01 -and
        [Math]::Abs($energyFillOrigin.Y - 1) -lt 0.01 -and
        [Math]::Abs($energyFillRightInset - 1) -lt 0.01 -and
        [Math]::Abs($energyFillBottomInset - 1) -lt 0.01 -and
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
    [void](Set-LowRemainingThreshold -Threshold 35)
    $lowAlertThresholdMenuText = [string]$script:LowAlertsMenuItem.Header
    $lowAlertSettingsSnapshot = Get-AppSettingsSnapshot
    $lowAlertThresholdDialog = New-LowRemainingAlertSettingsDialog
    $lowAlertThresholdDialogReady = (
        $null -ne $lowAlertThresholdDialog.FindName('ThresholdBox') -and
        $null -ne $lowAlertThresholdDialog.FindName('SaveButton') -and
        $null -ne $lowAlertThresholdDialog.FindName('ErrorText')
    )
    $lowAlertThresholdDialog.Close()

    $result = [pscustomobject]@{
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
        Trend7Text = $Trend7Text.Text
        PredictionText = $PredictionText.Text
        LowAlertMenuChecked = [bool]$script:LowAlertsMenuItem.IsChecked
        LowAlertThresholdMenuText = $lowAlertThresholdMenuText
        LowAlertThresholdPersisted = (
            [double]$lowAlertSettingsSnapshot.LowRemainingThreshold -eq 35
        )
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
