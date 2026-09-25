function Get-WindowWorkArea {
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        if ($helper.Handle -ne [IntPtr]::Zero) {
            $pixelArea = [System.Windows.Forms.Screen]::FromHandle($helper.Handle).WorkingArea
            $dpi = [Windows.Media.VisualTreeHelper]::GetDpi($window)
            if ($dpi.DpiScaleX -gt 0 -and $dpi.DpiScaleY -gt 0) {
                $logicalArea = ConvertTo-LogicalWorkArea `
                    -PixelLeft $pixelArea.Left `
                    -PixelTop $pixelArea.Top `
                    -PixelRight $pixelArea.Right `
                    -PixelBottom $pixelArea.Bottom `
                    -DpiScaleX $dpi.DpiScaleX `
                    -DpiScaleY $dpi.DpiScaleY
                return New-Object Windows.Rect(
                    $logicalArea.Left,
                    $logicalArea.Top,
                    $logicalArea.Width,
                    $logicalArea.Height
                )
            }
        }
    }
    catch {
        # Fall back to the primary work area if per-monitor lookup is unavailable.
    }
    return [System.Windows.SystemParameters]::WorkArea
}

$script:UsageSyncSession = [pscustomobject]@{
    InitialRefreshStarted = $false
    AwaitingInitialOfficial = $false
    LocalNotificationShown = $false
    OfficialNotificationShown = $false
    RapidSamples = @()
    RapidChannels = @{}
}

function Get-EdgeDockWorkArea {
    if ($null -eq $script:EdgeDockWorkArea) {
        $workArea = Get-WindowWorkArea
        $script:EdgeDockWorkArea = New-Object Windows.Rect(
            $workArea.Left,
            $workArea.Top,
            $workArea.Width,
            $workArea.Height
        )
    }
    return $script:EdgeDockWorkArea
}

function Sync-EdgeDockEnvironment {
    param([switch]$Force)

    if (
        -not $script:EdgeDockSide -or
        $script:IsExpanded -or
        $script:IsSyncingEdgeDockEnvironment
    ) {
        return $false
    }

    $currentWorkArea = Get-WindowWorkArea
    if (
        -not $Force -and
        (Test-WorkAreaEquivalent `
            -First $script:EdgeDockWorkArea `
            -Second $currentWorkArea)
    ) {
        return $false
    }

    $script:IsSyncingEdgeDockEnvironment = $true
    try {
        $script:EdgeDockWorkArea = New-Object Windows.Rect(
            $currentWorkArea.Left,
            $currentWorkArea.Top,
            $currentWorkArea.Width,
            $currentWorkArea.Height
        )
        Set-EdgeDockReveal `
            -Revealed $script:IsEdgeRevealed `
            -Immediate
        return $true
    }
    finally {
        $script:IsSyncingEdgeDockEnvironment = $false
    }
}

function Align-EdgeDockToPhysicalScreenEdge {
    if (-not $script:EdgeDockSide -or $script:IsExpanded) { return $null }
    # Never sample mid-animation: a reveal/hide that is still sliding makes
    # PointToScreen return a transient edge, and applying that "correction"
    # can throw the window far off the work area. The completion of the
    # latest animation always schedules a fresh align.
    if ($script:EdgeDockAnimating) { return $null }

    $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
    if ($helper.Handle -eq [IntPtr]::Zero) { return $null }

    $window.UpdateLayout()
    $screenArea = [System.Windows.Forms.Screen]::FromHandle($helper.Handle).WorkingArea
    $edgeElement = if ($script:IsEdgeRevealed) {
        $Surface
    }
    else {
        $UltraProgressTrack
    }

    # Capture values for the deferred callback (avoids closure over loop variables)
    $capturedScreenArea = $screenArea
    $capturedHelper = $helper
    $capturedEdgeElement = $edgeElement
    $capturedSide = $script:EdgeDockSide

    # Lightweight double-sample to avoid transient animation state:
    # take two readings 16ms apart; if they differ, defer to next animation completion
    $sampleVisualPoint = {
        if ($capturedSide -eq 'Left') {
            $capturedEdgeElement.PointToScreen((New-Object Windows.Point(0, 0)))
        }
        else {
            $capturedEdgeElement.PointToScreen(
                (New-Object Windows.Point($capturedEdgeElement.ActualWidth, 0))
            )
        }
    }
    $visualPoint1 = & $sampleVisualPoint
    # The deferred callback runs through the runspace event bridge, which
    # cannot see function locals, so the captured state travels in script
    # scope and is dequeued by the callback itself.
    $script:PendingEdgeAlignmentSamples.Enqueue([pscustomobject]@{
        ScreenArea = $capturedScreenArea
        Helper = $capturedHelper
        EdgeElement = $capturedEdgeElement
        Side = $capturedSide
        FirstPoint = $visualPoint1
    })
    $window.Dispatcher.BeginInvoke(
        [Windows.Threading.DispatcherPriority]::Render,
        (New-RmfAction -Callback {
            if ($script:PendingEdgeAlignmentSamples.Count -eq 0) { return }
            $sampleState = $script:PendingEdgeAlignmentSamples.Dequeue()
            if ($script:EdgeDockAnimating -or -not $script:EdgeDockSide -or $script:IsExpanded) { return }
            $visualPoint2 = if ($sampleState.Side -eq 'Left') {
                $sampleState.EdgeElement.PointToScreen((New-Object Windows.Point(0, 0)))
            }
            else {
                $sampleState.EdgeElement.PointToScreen(
                    (New-Object Windows.Point($sampleState.EdgeElement.ActualWidth, 0))
                )
            }
            if ([Math]::Abs($visualPoint2.X - $sampleState.FirstPoint.X) -gt 1) {
                # Still animating; skip this alignment, next animation completion will retry
                return
            }
            # Proceed with alignment using the stable second sample
            $screenEdge = if ($sampleState.Side -eq 'Left') {
                [double]$sampleState.ScreenArea.Left
            }
            else {
                [double]$sampleState.ScreenArea.Right
            }
            $pixelCorrection = [int][Math]::Round(
                $screenEdge - $visualPoint2.X,
                [MidpointRounding]::AwayFromZero
            )
            Invoke-EdgeAlignmentCorrection -PixelCorrection $pixelCorrection -ScreenEdge $screenEdge -VisualEdge $visualPoint2.X -Helper $sampleState.Helper -EdgeElement $sampleState.EdgeElement
        })
    ) | Out-Null
    return $null
}

function Invoke-EdgeAlignmentCorrection {
    param(
        [int]$PixelCorrection,
        [double]$ScreenEdge,
        [double]$VisualEdge,
        [System.Windows.Interop.WindowInteropHelper]$Helper,
        [Windows.FrameworkElement]$EdgeElement
    )

    if (
        -not (Test-EdgeAlignCorrectionValid `
            -PixelCorrection $PixelCorrection `
            -MaxCorrectionPixels $script:EdgeAlignMaxCorrectionPixels)
    ) {
        Write-RuntimeLog `
            -Level Warning `
            -Event 'Window.EdgeDock.AlignSkipped' `
            -Message '屏幕边缘校准采样失真，已放弃本次校准' `
            -Data ([ordered]@{
                Side = $script:EdgeDockSide
                Revealed = $script:IsEdgeRevealed
                ScreenEdge = $ScreenEdge
                VisualEdge = $VisualEdge
                CorrectionPixels = $PixelCorrection
            })
        return
    }

    if ($PixelCorrection -ne 0) {
        $windowRect = New-Object RemainingMarginNativeWindow+RECT
        if (-not [RemainingMarginNativeWindow]::GetWindowRect(
            $Helper.Handle,
            [ref]$windowRect
        )) {
            Write-RuntimeLog `
                -Level Warning `
                -Event 'Window.EdgeDock.AlignFailed' `
                -Message 'GetWindowRect 失败，本次屏幕边缘校准未执行' `
                -Data ([ordered]@{
                    Side = $script:EdgeDockSide
                    Stage = 'GetWindowRect'
                    CorrectionPixels = $PixelCorrection
                })
            return
        }
        $positionOnly = 0x0001 -bor 0x0004 -bor 0x0010 -bor 0x0200
        if (-not [RemainingMarginNativeWindow]::SetWindowPos(
            $Helper.Handle,
            [IntPtr]::Zero,
            $windowRect.Left + $PixelCorrection,
            $windowRect.Top,
            0,
            0,
            $positionOnly
        )) {
            Write-RuntimeLog `
                -Level Warning `
                -Event 'Window.EdgeDock.AlignFailed' `
                -Message 'SetWindowPos 失败，本次屏幕边缘校准未执行' `
                -Data ([ordered]@{
                    Side = $script:EdgeDockSide
                    Stage = 'SetWindowPos'
                    CorrectionPixels = $PixelCorrection
                })
            return
        }
        $window.UpdateLayout()
    }

    $alignedPoint = if ($script:EdgeDockSide -eq 'Left') {
        $EdgeElement.PointToScreen((New-Object Windows.Point(0, 0))).X
    }
    else {
        $EdgeElement.PointToScreen(
            (New-Object Windows.Point($EdgeElement.ActualWidth, 0))
        ).X
    }
    return [pscustomobject]@{
        Side = $script:EdgeDockSide
        Revealed = $script:IsEdgeRevealed
        ScreenEdge = $ScreenEdge
        VisualEdge = $alignedPoint
        GapPixels = [Math]::Abs($ScreenEdge - $alignedPoint)
        CorrectionPixels = $PixelCorrection
    }
}

function Set-EdgeDockChrome {
    param([bool]$Revealed)

    if (-not $script:EdgeDockSide) { return }
    # Keep the edge rail in a full-window overlay so its screen-relative
    # spacing and hit target never change when the card chrome appears.
    $WindowRoot.Margin = New-Object Windows.Thickness(0)
    $UltraCompactPanel.Margin = New-Object Windows.Thickness(0)
    if (-not $Revealed) {
        $Surface.Margin = New-Object Windows.Thickness(0)
        $HoverHalo.Margin = New-Object Windows.Thickness(0)
    }
    elseif ($script:EdgeDockSide -eq 'Left') {
        $Surface.Margin = New-Object Windows.Thickness(0, 5, 5, 5)
        $HoverHalo.Margin = New-Object Windows.Thickness(-1, 4, 4, 4)
    }
    else {
        $Surface.Margin = New-Object Windows.Thickness(5, 5, 0, 5)
        $HoverHalo.Margin = New-Object Windows.Thickness(4, 4, -1, 4)
    }

    # Docking must not reshape the card. Only the hidden-state chrome becomes
    # transparent so the energy rail reads as a focused edge affordance.
    $Surface.CornerRadius = New-Object Windows.CornerRadius(16)
    $HoverHalo.CornerRadius = New-Object Windows.CornerRadius(17)

    $SurfaceShadow.BeginAnimation(
        [Windows.Media.Effects.DropShadowEffect]::OpacityProperty,
        $null
    )
    $HoverHalo.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
    if (-not $Revealed) {
        $Surface.Background = [Windows.Media.Brushes]::Transparent
        $Surface.BorderBrush = [Windows.Media.Brushes]::Transparent
        $SurfaceShadow.Opacity = 0
        $HoverHalo.Opacity = 0
    }
    else {
        $Surface.Background = if ($script:HighContrast) {
            [Windows.SystemColors]::WindowBrush
        } else {
            $window.Resources['Surface']
        }
        $Surface.BorderBrush = if ($script:HighContrast) {
            [Windows.SystemColors]::ActiveBorderBrush
        } else {
            New-Object Windows.Media.SolidColorBrush(
                [Windows.Media.ColorConverter]::ConvertFromString($(if ($script:IsPointerOverSurface) {
                    $script:CurrentHoverBorderColor
                } else {
                    $script:CurrentSurfaceBorderColor
                }))
            )
        }
        $SurfaceShadow.Opacity = if ($script:IsPointerOverSurface) { 0.11 } else { 0.07 }
        $HoverHalo.Opacity = if ($script:IsPointerOverSurface) { 0.46 } else { 0 }
    }
}

function Set-EdgeDockVisualState {
    param(
        [bool]$Revealed,
        [switch]$Immediate
    )

    $compactTarget = if ($Revealed) { 1.0 } else { 0.0 }
    $ultraTarget = if ($Revealed) { 0.0 } else { 1.0 }
    $ultraFrom = $UltraCompactPanel.Opacity
    $surfaceFrom = $Surface.Opacity
    if ($Revealed -or $Immediate -or $script:ReducedMotion) {
        Set-EdgeDockChrome -Revealed $Revealed
    }

    $CompactHit.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
    $CompactDivider.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
    $Surface.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
    $UltraCompactPanel.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
    $CompactHit.Opacity = $compactTarget
    $CompactDivider.Opacity = $compactTarget
    $Surface.Opacity = $compactTarget
    $UltraCompactPanel.Opacity = $ultraTarget
    $UltraCompactPanel.IsHitTestVisible = (-not $Revealed)

    if (-not $Immediate -and -not $script:ReducedMotion) {
        $surfaceDuration = if ($Revealed) { 160 } else { 105 }
        $surfaceDelay = if ($Revealed) { 20 } else { 0 }
        $surfaceAnimation = New-DoubleAnimation `
            -To $compactTarget `
            -Milliseconds $surfaceDuration `
            -EaseOut:$Revealed `
            -EaseIn:(-not $Revealed)
        $surfaceAnimation.From = $surfaceFrom
        $surfaceAnimation.BeginTime = [TimeSpan]::FromMilliseconds($surfaceDelay)
        $surfaceAnimation.FillBehavior = [Windows.Media.Animation.FillBehavior]::Stop
        if (-not $Revealed) {
            $surfaceAnimation.Add_Completed((New-RmfEventHandler -Kind Event -Callback {
                if ($script:EdgeDockSide -and -not $script:IsEdgeRevealed) {
                    Set-EdgeDockChrome -Revealed $false
                }
            }))
        }
        $Surface.BeginAnimation(
            [Windows.UIElement]::OpacityProperty,
            $surfaceAnimation
        )

        $ultraDuration = if ($Revealed) { 85 } else { 120 }
        $ultraDelay = if ($Revealed) { 0 } else { 25 }
        $ultraAnimation = New-DoubleAnimation `
            -To $ultraTarget `
            -Milliseconds $ultraDuration `
            -EaseOut:$Revealed `
            -EaseIn:(-not $Revealed)
        $ultraAnimation.From = $ultraFrom
        $ultraAnimation.BeginTime = [TimeSpan]::FromMilliseconds($ultraDelay)
        $ultraAnimation.FillBehavior = [Windows.Media.Animation.FillBehavior]::Stop
        $UltraCompactPanel.BeginAnimation(
            [Windows.UIElement]::OpacityProperty,
            $ultraAnimation
        )
    }
}

function Set-EdgeDockReveal {
    param(
        [bool]$Revealed,
        [switch]$Immediate
    )

    if (-not $script:EdgeDockSide -or $script:IsExpanded) { return }
    if (-not $Immediate -and $script:IsEdgeRevealed -eq $Revealed) { return }

    $script:IsEdgeRevealed = $Revealed

    $workArea = Get-EdgeDockWorkArea
    $window.Top = [Math]::Max(
        $workArea.Top,
        [Math]::Min($window.Top, $workArea.Bottom - $script:CompactHeight)
    )
    if ($script:EdgeDockSide -eq 'Left') {
        $UltraCompactPanel.HorizontalAlignment = [Windows.HorizontalAlignment]::Right
        $UltraProgressTrack.HorizontalAlignment = [Windows.HorizontalAlignment]::Left
    }
    else {
        $UltraCompactPanel.HorizontalAlignment = [Windows.HorizontalAlignment]::Left
        $UltraProgressTrack.HorizontalAlignment = [Windows.HorizontalAlignment]::Right
    }

    $targetLeft = Get-EdgeDockPlacement `
        -Side $script:EdgeDockSide `
        -Revealed $Revealed `
        -WindowWidth $script:CompactWidth `
        -VisibleWidth $script:EdgeVisibleWidth `
        -WorkLeft $workArea.Left `
        -WorkRight $workArea.Right
    $currentLeft = $window.Left
    $window.BeginAnimation([Windows.Window]::LeftProperty, $null)
    $window.Left = $targetLeft

    if (-not $Immediate -and -not $script:ReducedMotion) {
        $duration = if ($Revealed) {
            $script:EdgeRevealDurationMs
        } else {
            $script:EdgeHideDurationMs
        }
        $script:EdgeDockAnimating = $true
        $leftAnimation = New-DoubleAnimation `
            -To $targetLeft `
            -Milliseconds $duration `
            -EaseOut:$Revealed `
            -EaseIn:(-not $Revealed)
        $leftAnimation.From = $currentLeft
        $leftAnimation.FillBehavior = [Windows.Media.Animation.FillBehavior]::Stop
        $leftAnimation.Add_Completed((New-RmfEventHandler -Kind Event -Callback {
            $script:EdgeDockAnimating = $false
            if ($script:EdgeDockSide -and -not $script:IsExpanded) {
                $window.Dispatcher.BeginInvoke(
                    [Windows.Threading.DispatcherPriority]::ContextIdle,
                    (New-RmfAction -Callback {
                        if ($script:EdgeDockSide -and -not $script:IsExpanded) {
                            [void](Align-EdgeDockToPhysicalScreenEdge)
                        }
                    })
                ) | Out-Null
            }
        }))
        $window.BeginAnimation([Windows.Window]::LeftProperty, $leftAnimation)
    }

    Set-EdgeDockVisualState -Revealed $Revealed -Immediate:$Immediate
    if ($Immediate -or $script:ReducedMotion) {
        $script:EdgeDockAnimating = $false
        [void](Align-EdgeDockToPhysicalScreenEdge)
    }
    $CompactHit.ToolTip = if ($Revealed) {
        '拖动移动 · 单击查看详情'
    } else {
        '悬停展开 · 拖动移动 · 单击查看详情'
    }
}

function Clear-EdgeDock {
    if (-not $script:EdgeDockSide) { return }
    Set-EdgeDockReveal -Revealed $true -Immediate
    $script:EdgeDockSide = $null
    $script:EdgeDockWorkArea = $null
    $script:IsEdgeRevealed = $false
    $WindowRoot.Margin = New-Object Windows.Thickness(5)
    $UltraCompactPanel.Margin = New-Object Windows.Thickness(0)
    $Surface.Margin = New-Object Windows.Thickness(0)
    $HoverHalo.Margin = New-Object Windows.Thickness(-1)
    $Surface.CornerRadius = New-Object Windows.CornerRadius(16)
    $HoverHalo.CornerRadius = New-Object Windows.CornerRadius(17)
    $Surface.Background = if ($script:HighContrast) {
        [Windows.SystemColors]::WindowBrush
    } else {
        $window.Resources['Surface']
    }
    Set-EdgeDockVisualState -Revealed $true -Immediate
}

function Try-DockWindowAfterMove {
    if (-not $script:EdgeDockEnabled -or $script:IsExpanded) { return $false }

    $workArea = Get-WindowWorkArea
    $side = Get-EdgeDockSideForPosition `
        -Left $window.Left `
        -Width $script:CompactWidth `
        -WorkLeft $workArea.Left `
        -WorkRight $workArea.Right `
        -SnapDistance $script:EdgeSnapDistance
    if (-not $side) {
        Clear-EdgeDock
        return $false
    }

    $script:EdgeDockSide = $side
    $script:EdgeDockWorkArea = New-Object Windows.Rect(
        $workArea.Left,
        $workArea.Top,
        $workArea.Width,
        $workArea.Height
    )
    $script:IsEdgeRevealed = $true
    Set-EdgeDockReveal -Revealed $false
    Save-Settings
    return $true
}

function Sync-EdgeDockMenuState {
    if ($script:EdgeDockMenuItem) {
        $script:EdgeDockMenuItem.IsChecked = $script:EdgeDockEnabled
    }
    if ($script:TrayEdgeDockItem) {
        $script:TrayEdgeDockItem.Checked = $script:EdgeDockEnabled
    }
}

function Set-EdgeDockEnabled {
    param([bool]$Enabled)

    $script:EdgeDockEnabled = $Enabled
    if (-not $Enabled) {
        Clear-EdgeDock
    }
    elseif (-not $script:IsExpanded) {
        [void](Try-DockWindowAfterMove)
    }
    Sync-EdgeDockMenuState
    Save-Settings
}

function Ensure-WindowVisible {
    if ($script:EdgeDockSide -and -not $script:IsExpanded) {
        [void](Sync-EdgeDockEnvironment -Force)
        return
    }
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

function Repair-WindowPlacementIfOffScreen {
    param([switch]$Force)

    if ($script:IsExpanded) { return $false }

    $now = [DateTimeOffset]::Now
    if (
        -not $Force -and
        $script:LastWindowPlacementWatchdogAt -and
        ($now - $script:LastWindowPlacementWatchdogAt).TotalSeconds -lt
            $script:WindowPlacementWatchdogSeconds
    ) {
        return $false
    }
    $script:LastWindowPlacementWatchdogAt = $now

    $workArea = Get-WindowWorkArea
    $outside = Test-PlacementOutsideWorkArea `
        -Left $window.Left `
        -Top $window.Top `
        -Width $window.Width `
        -Height $window.Height `
        -WorkLeft $workArea.Left `
        -WorkTop $workArea.Top `
        -WorkRight $workArea.Right `
        -WorkBottom $workArea.Bottom
    if (-not $outside) { return $false }

    if ($script:EdgeDockSide) {
        Write-RuntimeLog `
            -Level Warning `
            -Event 'Window.EdgeDock.Reanchored' `
            -Message '检测到贴边窗口完全移出工作区，已自动重锚' `
            -Data ([ordered]@{
                Side = $script:EdgeDockSide
                Revealed = $script:IsEdgeRevealed
                Left = [Math]::Round($window.Left, 2)
                Top = [Math]::Round($window.Top, 2)
                WorkLeft = $workArea.Left
                WorkRight = $workArea.Right
            })
        [void](Sync-EdgeDockEnvironment -Force)
    }
    else {
        Write-RuntimeLog `
            -Level Warning `
            -Event 'Window.Placement.Restored' `
            -Message '检测到悬浮窗完全移出工作区，已自动移回可见区域' `
            -Data ([ordered]@{
                Left = [Math]::Round($window.Left, 2)
                Top = [Math]::Round($window.Top, 2)
                WorkLeft = $workArea.Left
                WorkRight = $workArea.Right
            })
        Ensure-WindowVisible
    }
    return $true
}

function Show-ExistingWindow {
    if ($script:EdgeDockSide -and -not $script:IsExpanded) {
        Set-EdgeDockReveal -Revealed $true -Immediate
    }
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

function Get-ExpandedHeightForSnapshot {
    param([AllowNull()][object]$Snapshot)

    if ($Snapshot -and [string]$Snapshot.ProviderId -eq 'Codex') {
        if ((Get-CodexQuotaPresentation -Snapshot $Snapshot).Period -eq 'Weekly') {
            return $script:CodexProExpandedHeight
        }
        return $script:CodexPlusExpandedHeight
    }
    if ($Snapshot -and [string]$Snapshot.ProviderId -eq 'Kimi') {
        return $script:CodexPlusExpandedHeight
    }

    return $script:ExpandedHeight
}

function Get-ExpandedPlacement {
    param([double]$TargetHeight = $script:ExpandedHeight)

    $workArea = Get-WindowWorkArea
    $anchorLeft = if ($null -ne $script:CompactAnchorLeft) { $script:CompactAnchorLeft } else { $window.Left }
    $anchorTop = if ($null -ne $script:CompactAnchorTop) { $script:CompactAnchorTop } else { $window.Top }
    return Get-FittedPlacement `
        -AnchorLeft $anchorLeft `
        -AnchorTop $anchorTop `
        -TargetWidth $script:ExpandedWidth `
        -TargetHeight $TargetHeight `
        -WorkLeft $workArea.Left `
        -WorkTop $workArea.Top `
        -WorkRight $workArea.Right `
        -WorkBottom $workArea.Bottom
}

function Set-ExpandedState {
    param(
        [bool]$Expanded,
        [switch]$Immediate,
        [switch]$DeferEdgeDock
    )

    $transitionTimer = [Diagnostics.Stopwatch]::StartNew()
    if ($Expanded -and -not $script:IsExpanded) {
        if ($script:EdgeDockSide -and -not $DeferEdgeDock) {
            Set-EdgeDockReveal -Revealed $true -Immediate
        }
        $script:CompactAnchorLeft = $window.Left
        $script:CompactAnchorTop = $window.Top
    }
    $script:IsExpanded = $Expanded
    $targetWidth = if ($Expanded) { $script:ExpandedWidth } else { $script:CompactWidth }
    $targetHeight = if ($Expanded) {
        Get-ExpandedHeightForSnapshot -Snapshot $script:LastSnapshot
    } else { $script:CompactHeight }

    # Width and height are one logical state. Keeping them out of independent
    # WPF animations prevents rapid toggles from settling at 370x88 or 96x500.
    $window.BeginAnimation([Windows.FrameworkElement]::WidthProperty, $null)
    $window.BeginAnimation([Windows.FrameworkElement]::HeightProperty, $null)

    if ($Expanded) {
        $placement = Get-ExpandedPlacement -TargetHeight $targetHeight
        $window.Left = $placement.Left
        $window.Top = $placement.Top
        $window.Width = $targetWidth
        $window.Height = $targetHeight
        $DetailsPanel.Visibility = 'Visible'
        $ResetSummaryPanel.Visibility = if (
            $script:LastSnapshot -and
            [string]$script:LastSnapshot.ProviderId -in @('Codex', 'Kimi')
        ) { 'Visible' } else { 'Collapsed' }
        # The expanded header always moves the window label into the bottom
        # row next to the progress track; keeping the compact label under the
        # 34px number clipped it for non-quota providers like DeepSeek.
        $ExpandedWindowLabel.Visibility = 'Visible'
        $WindowLabel.Visibility = 'Collapsed'
        $CompactHit.Padding = New-Object Windows.Thickness(9, 7, 9, 2)
        $CompactProgressRow.Height = New-Object Windows.GridLength(23)
        $RemainingSummaryPanel.HorizontalAlignment =
            [Windows.HorizontalAlignment]::Left
        $RemainingNumberPanel.HorizontalAlignment =
            [Windows.HorizontalAlignment]::Left
        $RemainingValue.FontSize = 34
        $RemainingValue.LineHeight = 37
        $CompactPrefix.FontSize = 12
        $CompactSuffix.FontSize = 12
        $WindowLabel.HorizontalAlignment = [Windows.HorizontalAlignment]::Left
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
        $CompactHit.Padding = New-Object Windows.Thickness(7, 5, 7, 5)
        $CompactProgressRow.Height = New-Object Windows.GridLength(12)
        $RemainingSummaryPanel.HorizontalAlignment =
            [Windows.HorizontalAlignment]::Center
        $RemainingNumberPanel.HorizontalAlignment =
            [Windows.HorizontalAlignment]::Center
        $RemainingValue.FontSize = 23
        $RemainingValue.LineHeight = 26
        $CompactPrefix.FontSize = 9
        $CompactSuffix.FontSize = 9
        $WindowLabel.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
        $window.Width = $targetWidth
        $window.Height = $targetHeight
        if ($null -ne $script:CompactAnchorLeft) {
            $window.Left = $script:CompactAnchorLeft
            $window.Top = $script:CompactAnchorTop
            $script:CompactAnchorLeft = $null
            $script:CompactAnchorTop = $null
        }
        if ($script:EdgeDockSide) {
            $keepRevealed = (
                $script:IsPointerOverSurface -or
                ($Surface.ContextMenu -and $Surface.ContextMenu.IsOpen)
            )
            Set-EdgeDockReveal -Revealed $keepRevealed -Immediate:$Immediate
        }
    }

    Save-Settings
    $transitionTimer.Stop()
    if (
        -not $script:IsRestoringSettings -and
        (Get-Command Write-RuntimeLog -ErrorAction SilentlyContinue)
    ) {
        Write-RuntimeLog `
            -Level $(if ($transitionTimer.ElapsedMilliseconds -ge 250) {
                'Warning'
            } else {
                'Info'
            }) `
            -Event 'Window.ExpandedStateChanged' `
            -Message $(if ($Expanded) { '已展开详情' } else { '已收起详情' }) `
            -ElapsedMilliseconds $transitionTimer.ElapsedMilliseconds `
            -Data @{ Expanded = $Expanded }
    }
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
        (New-RmfAction -Callback { Collapse-DetailsIfInactive })
    ) | Out-Null
}

function Hide-EdgeDockIfPointerAway {
    if (
        $script:EdgeDockSide -and
        -not $script:IsExpanded -and
        -not $script:IsPointerOverSurface -and
        -not ($Surface.ContextMenu -and $Surface.ContextMenu.IsOpen)
    ) {
        Set-EdgeDockReveal -Revealed $false
    }
}

function Request-EdgeDockHide {
    if (-not $script:EdgeHideTimer) {
        Hide-EdgeDockIfPointerAway
        return
    }
    $script:EdgeHideTimer.Stop()
    $script:EdgeHideTimer.Start()
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
    $mix = [Math]::Max(0.0, [Math]::Min(1.0, $Amount))
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

    if ($script:HighContrast) {
        return [pscustomobject]@{
            Accent = [Windows.SystemColors]::HighlightColor
            Strong = [Windows.SystemColors]::WindowTextColor
            Soft = [Windows.SystemColors]::WindowColor
            Border = [Windows.SystemColors]::ActiveBorderColor
            HoverBorder = [Windows.SystemColors]::HighlightColor.ToString()
        }
    }

    if (-not $Available) {
        return [pscustomobject]@{
            Accent = [Windows.Media.ColorConverter]::ConvertFromString('#89908C')
            Strong = [Windows.Media.ColorConverter]::ConvertFromString('#5B625E')
            Soft = [Windows.Media.ColorConverter]::ConvertFromString('#F1F2EF')
            Border = [Windows.Media.ColorConverter]::ConvertFromString('#E0E3DE')
            HoverBorder = '#CED2CE'
        }
    }

    $remaining = [Math]::Max(0.0, [Math]::Min(100.0, $Percent))
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
    $energyBrush = New-Object Windows.Media.LinearGradientBrush
    $energyBrush.StartPoint = New-Object Windows.Point(0, 0)
    $energyBrush.EndPoint = New-Object Windows.Point(0, 1)
    if ($script:HighContrast) {
        $energyBrush.GradientStops.Add(
            (New-Object Windows.Media.GradientStop([Windows.SystemColors]::HighlightColor, 0.0))
        )
        $energyBrush.GradientStops.Add(
            (New-Object Windows.Media.GradientStop([Windows.SystemColors]::HighlightColor, 1.0))
        )
        $UltraDepletedMask.Background = [Windows.SystemColors]::GrayTextBrush
    }
    elseif ($Available) {
        foreach ($stop in @(
            [pscustomobject]@{ Color = '#25D982'; Offset = 0.0 },
            [pscustomobject]@{ Color = '#76D955'; Offset = 0.42 },
            [pscustomobject]@{ Color = '#FFD447'; Offset = 0.60 },
            [pscustomobject]@{ Color = '#FF8A3D'; Offset = 0.80 },
            [pscustomobject]@{ Color = '#F34F60'; Offset = 1.0 }
        )) {
            $energyBrush.GradientStops.Add(
                (New-Object Windows.Media.GradientStop(
                    [Windows.Media.ColorConverter]::ConvertFromString($stop.Color),
                    $stop.Offset
                ))
            )
        }
        $UltraDepletedMask.Background = New-Object Windows.Media.SolidColorBrush(
            [Windows.Media.ColorConverter]::ConvertFromString('#626965')
        )
    }
    else {
        $energyBrush.GradientStops.Add(
            (New-Object Windows.Media.GradientStop(
                [Windows.Media.ColorConverter]::ConvertFromString('#9AA19C'),
                0.0
            ))
        )
        $energyBrush.GradientStops.Add(
            (New-Object Windows.Media.GradientStop(
                [Windows.Media.ColorConverter]::ConvertFromString('#747B77'),
                1.0
            ))
        )
        $UltraDepletedMask.Background = New-Object Windows.Media.SolidColorBrush(
            [Windows.Media.ColorConverter]::ConvertFromString('#747B77')
        )
    }
    $UltraProgressFill.Background = $energyBrush
    $UltraProgressOutline.BorderBrush = if ($script:HighContrast) {
        [Windows.SystemColors]::ActiveBorderBrush
    }
    elseif ($Available) {
        New-Object Windows.Media.SolidColorBrush(
            [Windows.Media.ColorConverter]::ConvertFromString('#E52B3831')
        )
    }
    else {
        New-Object Windows.Media.SolidColorBrush(
            [Windows.Media.ColorConverter]::ConvertFromString('#C84E5651')
        )
    }
    $UltraLevelMarker.Background = if ($script:HighContrast) {
        [Windows.SystemColors]::WindowTextBrush
    }
    else {
        New-Object Windows.Media.SolidColorBrush(
            [Windows.Media.ColorConverter]::ConvertFromString('#F2FFFFFF')
        )
    }
    $UltraLevelMarker.Visibility = if ($Available) { 'Visible' } else { 'Collapsed' }

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
        [Math]::Max(0.0, [Math]::Min(100.0, $Percent))
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
    $UltraEmptyProgressRow.Height = New-Object Windows.GridLength(
        $used,
        [Windows.GridUnitType]::Star
    )
    $UltraRemainingProgressRow.Height = New-Object Windows.GridLength(
        $remaining,
        [Windows.GridUnitType]::Star
    )
    $ProgressTrack.ToolTip = if ($Available) {
        '剩余 {0:0}% · 已使用 {1:0}%' -f $remaining, $used
    } else {
        '设置预算基准后显示百分比进度'
    }
    $UltraProgressTrack.ToolTip = if ($Available) {
        '剩余 {0:0}%' -f $remaining
    } else {
        '暂无可用百分比'
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

function Select-TrendDisplaySamples {
    param(
        [object[]]$Samples,
        [int]$MaximumPoints = 48
    )

    $series = @($Samples | Sort-Object ObservedAtUtc)
    if ($series.Count -le $MaximumPoints) { return $series }

    $displaySamples = New-Object Collections.Generic.List[object]
    $displaySamples.Add($series[0])
    $bucketCount = [Math]::Max(1, [int][Math]::Floor(($MaximumPoints - 2) / 2))
    $interiorCount = $series.Count - 2
    for ($bucketIndex = 0; $bucketIndex -lt $bucketCount; $bucketIndex++) {
        $start = 1 + [int][Math]::Floor(
            $bucketIndex * $interiorCount / $bucketCount
        )
        $end = 1 + [int][Math]::Floor(
            ($bucketIndex + 1) * $interiorCount / $bucketCount
        ) - 1
        if ($end -lt $start) { continue }
        $bucket = @($series[$start..$end])
        $minimumSample = $bucket |
            Sort-Object RemainingValue, ObservedAtUtc |
            Select-Object -First 1
        $maximumSample = $bucket |
            Sort-Object RemainingValue -Descending |
            Select-Object -First 1
        foreach ($sample in @($minimumSample, $maximumSample) |
            Sort-Object ObservedAtUtc) {
            if (
                -not [object]::ReferenceEquals(
                    $displaySamples[$displaySamples.Count - 1],
                    $sample
                )
            ) {
                $displaySamples.Add($sample)
            }
        }
    }
    $displaySamples.Add($series[-1])
    return $displaySamples.ToArray()
}

function Format-UsageTrendValue {
    param(
        [double]$Value,
        $CurrentSample
    )

    if ($CurrentSample.MetricType -eq 'Percent') {
        return '{0:0.#}%' -f $Value
    }
    return Format-CurrencyAmount -Amount $Value -Currency $CurrentSample.Unit
}

function Format-UsageTrendChange {
    param(
        $Trend,
        $CurrentSample
    )

    if (-not $Trend -or -not [bool]$Trend.ComparisonAvailable) {
        return '积累中'
    }
    $change = [double]$Trend.Change
    if ([Math]::Abs($change) -lt 0.05) { return '— 持平' }
    $arrow = if ($change -lt 0) { '↓' } else { '↑' }
    if ($CurrentSample.MetricType -eq 'Percent') {
        return '{0} {1:0.#}pp' -f $arrow, [Math]::Abs($change)
    }
    return '{0} {1}' -f $arrow, (
        Format-CurrencyAmount `
            -Amount ([Math]::Abs($change)) `
            -Currency $CurrentSample.Unit
    )
}

function Clear-TrendChartVisuals {
    param(
        $Canvas,
        $Polyline,
        $Area,
        $StartMarker,
        $EndMarker
    )

    foreach ($child in @($Canvas.Children | Where-Object {
        [string]$_.Tag -like 'UsageTrendDynamic*'
    })) {
        [void]$Canvas.Children.Remove($child)
    }
    $Polyline.Points.Clear()
    $Area.Points.Clear()
    $StartMarker.Visibility = 'Collapsed'
    $EndMarker.Visibility = 'Collapsed'
}

function ConvertTo-SmoothTrendPoints {
    param(
        [object[]]$Points,
        [int]$Subdivisions = 6
    )

    $series = @($Points)
    if ($series.Count -lt 2) { return $series }

    $steps = [Math]::Max(2, $Subdivisions)
    $smoothed = New-Object Collections.Generic.List[Windows.Point]
    [void]$smoothed.Add($series[0])
    for ($index = 0; $index -lt ($series.Count - 1); $index++) {
        $start = $series[$index]
        $end = $series[$index + 1]
        for ($step = 1; $step -le $steps; $step++) {
            $progress = [double]$step / $steps
            # Smoothstep keeps every interpolation between its two real samples,
            # avoiding the overshoot that a free-form spline can introduce.
            $eased = $progress * $progress * (3.0 - (2.0 * $progress))
            [void]$smoothed.Add((New-Object Windows.Point(
                ([double]$start.X + (([double]$end.X - [double]$start.X) * $progress)),
                ([double]$start.Y + (([double]$end.Y - [double]$start.Y) * $eased))
            )))
        }
    }
    return $smoothed.ToArray()
}

function Set-TrendChart {
    param(
        $Canvas,
        $Polyline,
        $Area,
        $StartMarker,
        $EndMarker,
        [object[]]$Samples,
        [object[]]$Segments = @(),
        [switch]$ConnectSegments,
        [switch]$Smooth,
        [double]$Hours,
        [Nullable[DateTimeOffset]]$AxisStartUtc,
        [Nullable[DateTimeOffset]]$AxisEndUtc,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    Clear-TrendChartVisuals `
        -Canvas $Canvas `
        -Polyline $Polyline `
        -Area $Area `
        -StartMarker $StartMarker `
        -EndMarker $EndMarker

    $sourceSegments = if ($ConnectSegments) {
        @([pscustomobject]@{
            Samples = @($Samples | Sort-Object ObservedAtUtc)
        })
    } elseif ($Segments.Count -gt 0) {
        @($Segments)
    } else {
        @(Split-UsageTrendSeries -Samples $Samples)
    }
    $displaySegments = New-Object Collections.Generic.List[object]
    $allDisplaySamples = New-Object Collections.Generic.List[object]
    foreach ($segment in $sourceSegments) {
        $segmentSamples = @($segment.Samples)
        $selected = @(
            Select-TrendDisplaySamples `
                -Samples $segmentSamples `
                -MaximumPoints 48
        )
        if ($selected.Count -eq 0) { continue }
        [void]$displaySegments.Add([pscustomobject]@{
            Samples = $selected
        })
        foreach ($sample in $selected) {
            [void]$allDisplaySamples.Add($sample)
        }
    }
    if ($allDisplaySamples.Count -lt 2) { return }

    $values = @($allDisplaySamples | ForEach-Object {
        [double]$_.RemainingValue
    })
    $minimum = ($values | Measure-Object -Minimum).Minimum
    $maximum = ($values | Measure-Object -Maximum).Maximum
    $range = [double]$maximum - [double]$minimum
    $minimumRange = if ($allDisplaySamples[0].MetricType -eq 'Percent') {
        10.0
    } else {
        [Math]::Max(0.01, [double]$maximum * 0.05)
    }
    if ($range -lt $minimumRange) {
        $center = ([double]$minimum + [double]$maximum) / 2
        $minimum = $center - ($minimumRange / 2)
        $maximum = $center + ($minimumRange / 2)
        if ($allDisplaySamples[0].MetricType -eq 'Percent') {
            if ($minimum -lt 0.0) {
                $maximum = [Math]::Min(100.0, $maximum - $minimum)
                $minimum = 0.0
            }
            elseif ($maximum -gt 100.0) {
                $minimum = [Math]::Max(
                    0.0,
                    $minimum - ($maximum - 100.0)
                )
                $maximum = 100.0
            }
        }
        $range = [Math]::Max(0.0001, [double]$maximum - [double]$minimum)
    }
    else {
        $padding = $range * 0.12
        $minimum -= $padding
        $maximum += $padding
        $range = [double]$maximum - [double]$minimum
    }

    $width = if ($Canvas.ActualWidth -gt 10) {
        [double]$Canvas.ActualWidth
    } else {
        [double]$Canvas.Width
    }
    $height = if ($Canvas.ActualHeight -gt 10) {
        [double]$Canvas.ActualHeight
    } else {
        [double]$Canvas.Height
    }
    $plotHeight = [Math]::Max(1.0, $height - 5.0)
    $useExplicitAxis = $AxisStartUtc -and $AxisEndUtc
    if ($useExplicitAxis) {
        $axisStart = ([DateTimeOffset]$AxisStartUtc).ToUniversalTime()
        $totalSeconds = [Math]::Max(
            1.0,
            (([DateTimeOffset]$AxisEndUtc).ToUniversalTime() - $axisStart).TotalSeconds
        )
    } else {
        $axisStart = $Now.ToUniversalTime().AddHours(-$Hours)
        $totalSeconds = [Math]::Max(1, $Hours * 3600)
    }
    $allPoints = New-Object Collections.Generic.List[Windows.Point]
    for ($segmentIndex = 0; $segmentIndex -lt $displaySegments.Count; $segmentIndex++) {
        $segmentPoints = New-Object Collections.Generic.List[Windows.Point]
        foreach ($sample in @($displaySegments[$segmentIndex].Samples)) {
            $elapsedSeconds = (
                ([DateTimeOffset]$sample.ObservedAtUtc) - $axisStart
            ).TotalSeconds
            $x = [Math]::Max(
                0.0,
                [Math]::Min($width, ($elapsedSeconds / $totalSeconds) * $width)
            )
            $y = 2 + (
                $plotHeight - (
                    (
                        [double]$sample.RemainingValue -
                        [double]$minimum
                    ) / $range * $plotHeight
                )
            )
            $point = New-Object Windows.Point($x, $y)
            [void]$segmentPoints.Add($point)
        }

        $renderPoints = @(if ($Smooth) {
            ConvertTo-SmoothTrendPoints -Points $segmentPoints.ToArray()
        } else {
            $segmentPoints.ToArray()
        })
        foreach ($point in $renderPoints) {
            [void]$allPoints.Add($point)
        }

        if ($segmentIndex -eq 0) {
            $segmentLine = $Polyline
            $segmentArea = $Area
        } else {
            $segmentArea = New-Object Windows.Shapes.Polygon
            $segmentArea.Fill = $Area.Fill
            $segmentArea.Tag = 'UsageTrendDynamicArea'
            [Windows.Controls.Panel]::SetZIndex($segmentArea, 0)
            [void]$Canvas.Children.Add($segmentArea)

            $segmentLine = New-Object Windows.Shapes.Polyline
            $segmentLine.Stroke = $Polyline.Stroke
            $segmentLine.StrokeThickness = $Polyline.StrokeThickness
            $segmentLine.StrokeLineJoin = $Polyline.StrokeLineJoin
            $segmentLine.Tag = 'UsageTrendDynamicLine'
            [Windows.Controls.Panel]::SetZIndex($segmentLine, 1)
            [void]$Canvas.Children.Add($segmentLine)
        }
        foreach ($point in $renderPoints) {
            $segmentLine.Points.Add($point)
        }
        if ($renderPoints.Count -ge 2) {
            $segmentArea.Points.Add((New-Object Windows.Point(
                $renderPoints[0].X,
                $height
            )))
            foreach ($point in $renderPoints) {
                $segmentArea.Points.Add($point)
            }
            $segmentArea.Points.Add((New-Object Windows.Point(
                $renderPoints[-1].X,
                $height
            )))
        }
    }

    [Windows.Controls.Panel]::SetZIndex($Polyline, 1)
    [Windows.Controls.Panel]::SetZIndex($StartMarker, 2)
    [Windows.Controls.Panel]::SetZIndex($EndMarker, 2)
    $StartMarker.Visibility = 'Visible'
    $EndMarker.Visibility = 'Visible'
    [Windows.Controls.Canvas]::SetLeft(
        $StartMarker,
        $allPoints[0].X - ($StartMarker.Width / 2)
    )
    [Windows.Controls.Canvas]::SetTop(
        $StartMarker,
        $allPoints[0].Y - ($StartMarker.Height / 2)
    )
    [Windows.Controls.Canvas]::SetLeft(
        $EndMarker,
        $allPoints[-1].X - ($EndMarker.Width / 2)
    )
    [Windows.Controls.Canvas]::SetTop(
        $EndMarker,
        $allPoints[-1].Y - ($EndMarker.Height / 2)
    )
}
function Format-RapidDropDisplaySummary {
    param(
        $Insights,
        $RapidDrop
    )

    if (-not $RapidDrop) { return '' }
    $summary = [string]$RapidDrop.Summary
    # Only disambiguate when the source actually reports two quota windows.
    if (
        -not [string]::IsNullOrWhiteSpace([string]$RapidDrop.QuotaPeriod) -and
        $Insights -and
        $Insights.PSObject.Properties['RapidDrops'] -and
        @($Insights.RapidDrops).Count -gt 1
    ) {
        $label = if ($RapidDrop.QuotaPeriod -eq 'Weekly') {
            '每周'
        } else {
            '5 小时'
        }
        return '{0} {1}' -f $label, $summary
    }
    return $summary
}

function Update-UsageInsightView {
    param($Insights)

    if (-not $Insights -or -not $Insights.CurrentSample) {
        $Trend5HText.Text = '暂无数据'
        $Trend7Text.Text = '暂无数据'
        $Trend5HMetaText.Text = '等待更多样本'
        $Trend7MetaText.Text = '等待更多样本'
        $PredictionText.Text = '积累 30 分钟后预测'
        Clear-TrendChartVisuals `
            -Canvas $Trend5HCanvas `
            -Polyline $Trend5HLine `
            -Area $Trend5HArea `
            -StartMarker $Trend5HStartMarker `
            -EndMarker $Trend5HEndMarker
        Clear-TrendChartVisuals `
            -Canvas $Trend7Canvas `
            -Polyline $Trend7Line `
            -Area $Trend7Area `
            -StartMarker $Trend7StartMarker `
            -EndMarker $Trend7EndMarker
        $RapidDropText.Text = if ($script:RapidDropAlertsEnabled) {
            '快速下降监控 · 正在积累样本'
        } else {
            '1 小时内下降 · 正在积累样本'
        }
        return
    }

    $Trend5HText.Text = Format-UsageTrendChange `
        -Trend $Insights.Trend5Hours `
        -CurrentSample $Insights.CurrentSample
    $Trend7Text.Text = Format-UsageTrendChange `
        -Trend $Insights.Trend7Days `
        -CurrentSample $Insights.CurrentSample
    $Trend5HMetaText.Text = if ($Insights.Trend5Hours.ComparisonAvailable) {
        '{0} 个样本 · {1} → {2}' -f
            $Insights.Trend5Hours.SampleCount,
            (Format-UsageTrendValue `
                -Value $Insights.Trend5Hours.StartValue `
                -CurrentSample $Insights.CurrentSample),
            (Format-UsageTrendValue `
                -Value $Insights.Trend5Hours.EndValue `
                -CurrentSample $Insights.CurrentSample)
    } else {
        '等待更多样本'
    }
    $Trend7MetaText.Text = if ($Insights.Trend7Days.ComparisonAvailable) {
        '{0} 个样本 · {1} → {2}' -f
            $Insights.Trend7Days.SampleCount,
            (Format-UsageTrendValue `
                -Value $Insights.Trend7Days.StartValue `
                -CurrentSample $Insights.CurrentSample),
            (Format-UsageTrendValue `
                -Value $Insights.Trend7Days.EndValue `
                -CurrentSample $Insights.CurrentSample)
    } else {
        '等待更多样本'
    }
    $PredictionText.Text = $Insights.Forecast.Text
    $PredictionText.ToolTip = (
        '当前消耗速度 {0:0.###} {1}/小时' -f
        [Math]::Abs([double]$Insights.Forecast.RatePerHour),
        $Insights.CurrentSample.Unit
    )
    Set-TrendChart `
        -Canvas $Trend5HCanvas `
        -Polyline $Trend5HLine `
        -Area $Trend5HArea `
        -StartMarker $Trend5HStartMarker `
        -EndMarker $Trend5HEndMarker `
        -Samples $Insights.Trend5Hours.Samples `
        -Segments $Insights.Trend5Hours.Segments `
        -Smooth `
        -AxisStartUtc $Insights.Trend5Hours.AxisStartUtc `
        -AxisEndUtc $Insights.Trend5Hours.AxisEndUtc `
        -Hours 5
    Set-TrendChart `
        -Canvas $Trend7Canvas `
        -Polyline $Trend7Line `
        -Area $Trend7Area `
        -StartMarker $Trend7StartMarker `
        -EndMarker $Trend7EndMarker `
        -Samples $Insights.Trend7Days.Samples `
        -Segments $Insights.Trend7Days.Segments `
        -ConnectSegments `
        -Smooth `
        -Hours (24 * 7)

    $rapidDrop = $Insights.RapidDrop
    $rapidDropSummary = Format-RapidDropDisplaySummary `
        -Insights $Insights `
        -RapidDrop $rapidDrop
    if (-not $script:RapidDropAlertsEnabled) {
        $RapidDropStatusDot.Fill = New-Object Windows.Media.SolidColorBrush(
            [Windows.Media.ColorConverter]::ConvertFromString('#9AA09B')
        )
        $RapidDropText.Text = if ($rapidDrop -and $rapidDrop.Available) {
            $rapidDropSummary
        }
        else {
            '1 小时内下降 · ' + $(if ($rapidDrop) {
                $rapidDropSummary
            } else {
                '正在积累样本'
            })
        }
        $RapidDropText.Foreground = $window.FindResource('TextMuted')
        $RapidDropText.FontWeight = 'Normal'
    }
    elseif (-not $rapidDrop -or -not $rapidDrop.Available) {
        $RapidDropStatusDot.Fill = $window.FindResource('Sage')
        $RapidDropText.Text = '快速下降监控 · ' + $(if ($rapidDrop) {
            $rapidDropSummary
        } else {
            '正在积累样本'
        })
        $RapidDropText.Foreground = $window.FindResource('TextSecondary')
        $RapidDropText.FontWeight = 'Normal'
    }
    elseif ($rapidDrop.IsRapid) {
        $RapidDropStatusDot.Fill = New-Object Windows.Media.SolidColorBrush(
            [Windows.Media.ColorConverter]::ConvertFromString('#B75B52')
        )
        $RapidDropText.Text = '检测到快速下降 · ' + $rapidDropSummary
        $RapidDropText.Foreground = New-Object Windows.Media.SolidColorBrush(
            [Windows.Media.ColorConverter]::ConvertFromString('#984B44')
        )
        $RapidDropText.FontWeight = 'SemiBold'
    }
    else {
        $RapidDropStatusDot.Fill = $window.FindResource('Sage')
        $thresholdText = if ($rapidDrop.MetricType -eq 'Percent') {
            '{0:0.#}pp' -f $rapidDrop.Threshold
        } else {
            Format-CurrencyAmount `
                -Amount $rapidDrop.Threshold `
                -Currency $rapidDrop.Unit
        }
        $RapidDropText.Text = '{0} · 阈值 {1}' -f
            $rapidDropSummary,
            $thresholdText
        $RapidDropText.Foreground = $window.FindResource('TextSecondary')
        $RapidDropText.FontWeight = 'Normal'
    }
}

function Get-UsageSnapshotChannel {
    param($Snapshot)

    if (-not $Snapshot) { return '' }
    if ([string]$Snapshot.ProviderId -eq 'DeepSeek') {
        return 'DeepSeekOfficial'
    }
    if ([string]$Snapshot.ProviderId -eq 'Kimi') {
        $kimiSource = [string]$Snapshot.Source
        if ($kimiSource.StartsWith('Kimi 官方用量缓存', [StringComparison]::Ordinal)) {
            return 'KimiOfficialCache'
        }
        return 'KimiOfficial'
    }

    $source = [string]$Snapshot.Source
    if ($source.StartsWith('官方用量接口', [StringComparison]::Ordinal)) {
        return 'CodexOfficial'
    }
    if ($source.StartsWith('官方用量缓存', [StringComparison]::Ordinal)) {
        return 'CodexOfficialCache'
    }
    return 'CodexLocal'
}

function Reset-ProviderRapidDropSession {
    param(
        [string]$ProviderId,
        [string]$Channel = ''
    )

    $script:UsageSyncSession.RapidSamples = @(
        $script:UsageSyncSession.RapidSamples | Where-Object {
            [string]$_.ProviderId -ne $ProviderId
        }
    )
    if ([string]::IsNullOrWhiteSpace($Channel)) {
        [void]$script:UsageSyncSession.RapidChannels.Remove($ProviderId)
    }
    else {
        $script:UsageSyncSession.RapidChannels[$ProviderId] = $Channel
    }
}

function Get-RapidDropDisplayWindowMinutes {
    if ($script:RapidDropAlertsEnabled) {
        return $script:RapidDropWindowMinutes
    }
    return 60
}

function Set-RapidDropInsightValues {
    param(
        $Snapshot,
        $Insights,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    # One measurement per quota window: the thresholds are configured per
    # window and the sample series is already isolated by quota period.
    $settings = Get-UsageAlertSettings -ProviderId ([string]$Snapshot.ProviderId)
    $deepSeekSettings = Get-UsageAlertSettings -ProviderId 'DeepSeek'
    $windowMinutes = if ([bool]$settings.RapidAlertsEnabled) {
        [int]$settings.RapidWindowMinutes
    } else {
        60
    }
    $rapidDrops = New-Object Collections.Generic.List[object]
    foreach ($rapidWindow in (Get-RapidDropQuotaWindows -Snapshot $Snapshot)) {
        $rapidDrops.Add((Measure-RapidUsageDrop `
            -Samples @($script:UsageSyncSession.RapidSamples) `
            -Snapshot $Snapshot `
            -QuotaPeriod $rapidWindow.Period `
            -WindowMinutes $windowMinutes `
            -CodexPercent $rapidWindow.Threshold `
            -DeepSeekMode ([string]$deepSeekSettings.RapidMode) `
            -DeepSeekPercent ([double]$deepSeekSettings.RapidPercent) `
            -DeepSeekAmount ([double]$deepSeekSettings.RapidAmount) `
            -Now $Now))
    }
    # The single-line status shows whichever window is closer to trouble.
    $displayDrop = $null
    foreach ($candidate in $rapidDrops) {
        if (-not $displayDrop) {
            $displayDrop = $candidate
            continue
        }
        $candidateRank = [int][bool]$candidate.IsRapid
        $displayRank = [int][bool]$displayDrop.IsRapid
        if (
            $candidateRank -gt $displayRank -or
            (
                $candidateRank -eq $displayRank -and
                [double]$candidate.Drop -gt [double]$displayDrop.Drop
            )
        ) {
            $displayDrop = $candidate
        }
    }
    # StrictMode 2.0 rejects assigning a property that does not exist yet, so
    # the per-window list has to be attached with Add-Member. The value must be
    # a plain array: Add-Member rejects an array subexpression here.
    $Insights | Add-Member `
        -NotePropertyName RapidDrops `
        -NotePropertyValue $rapidDrops.ToArray() `
        -Force
    $Insights.RapidDrop = $displayDrop
    return $Insights
}

function Set-SessionRapidDropInsight {
    param(
        $Snapshot,
        $Insights,
        [ValidateSet(
            'Normal',
            'LocalPreview',
            'StartupLocal',
            'StartupOfficial'
        )]
        [string]$ObservationContext = 'Normal',
        [DateTimeOffset]$ObservedAt = [DateTimeOffset]::Now
    )

    if (-not $Insights -or -not $Snapshot) { return $Insights }

    $providerId = [string]$Snapshot.ProviderId
    $channel = Get-UsageSnapshotChannel -Snapshot $Snapshot
    $existingChannel = if (
        $script:UsageSyncSession.RapidChannels.ContainsKey($providerId)
    ) {
        [string]$script:UsageSyncSession.RapidChannels[$providerId]
    }
    else { '' }

    $summaryOverride = ''
    $excludeCurrentSample = $false
    if ($ObservationContext -eq 'StartupLocal') {
        Reset-ProviderRapidDropSession -ProviderId $providerId
        $excludeCurrentSample = $true
        $summaryOverride = '启动同步中，本地快照不计入快速下降'
    }
    elseif ($ObservationContext -eq 'LocalPreview') {
        $excludeCurrentSample = $true
        if ($channel -notin @('CodexOfficialCache', 'KimiOfficialCache')) {
            $summaryOverride = '等待官方同步，本地快照不计入快速下降'
        }
    }
    elseif ($channel -in @('CodexOfficialCache', 'KimiOfficialCache')) {
        $excludeCurrentSample = $true
    }
    elseif (
        $ObservationContext -eq 'StartupOfficial' -or
        (
            -not [string]::IsNullOrWhiteSpace($existingChannel) -and
            $existingChannel -ne $channel
        )
    ) {
        Reset-ProviderRapidDropSession `
            -ProviderId $providerId `
            -Channel $channel
        $summaryOverride = if ($ObservationContext -eq 'StartupOfficial') {
            '已同步官方数据，正在建立连续使用基线'
        }
        else {
            '数据通道已切换，正在建立连续使用基线'
        }
    }
    elseif ([string]::IsNullOrWhiteSpace($existingChannel)) {
        $script:UsageSyncSession.RapidChannels[$providerId] = $channel
        $summaryOverride = '正在建立连续使用基线'
    }

    if (
        -not $excludeCurrentSample -and
        $ObservationContext -eq 'Normal' -and
        $existingChannel -eq $channel
    ) {
        $lastSessionSample = @(
            $script:UsageSyncSession.RapidSamples | Where-Object {
                [string]$_.ProviderId -eq $providerId
            } | Sort-Object ObservedAtUtc
        ) | Select-Object -Last 1
        $continuityLimitSeconds = [Math]::Max(
            180,
            $script:RefreshIntervalSeconds * 3
        )
        if (
            $lastSessionSample -and
            (
                $ObservedAt.ToUniversalTime() -
                $lastSessionSample.ObservedAtUtc
            ).TotalSeconds -gt $continuityLimitSeconds
        ) {
            Reset-ProviderRapidDropSession `
                -ProviderId $providerId `
                -Channel $channel
            $summaryOverride = '监控间隔中断，正在重新建立连续使用基线'
        }
    }

    if (-not $excludeCurrentSample) {
        $newSamples = @(
            ConvertTo-UsageHistorySamples `
                -Snapshot $Snapshot `
                -ObservedAt $ObservedAt
        )
        $retentionWindowMinutes = [Math]::Max(
            60,
            [Math]::Max(5, $script:RapidDropWindowMinutes)
        )
        $cutoff = $ObservedAt.ToUniversalTime().AddMinutes(
            -1 * ($retentionWindowMinutes + 5)
        )
        $script:UsageSyncSession.RapidSamples = @(
            @($script:UsageSyncSession.RapidSamples + $newSamples) |
                Where-Object {
                    $_.ObservedAtUtc -ge $cutoff
                }
        )
    }

    $Insights = Set-RapidDropInsightValues `
        -Snapshot $Snapshot `
        -Insights $Insights `
        -Now $ObservedAt
    foreach ($rapidDrop in @($Insights.RapidDrops)) {
        if ($excludeCurrentSample) {
            $rapidDrop.Available = $false
            $rapidDrop.IsRapid = $false
        }
        if (-not [string]::IsNullOrWhiteSpace($summaryOverride)) {
            $rapidDrop.Summary = $summaryOverride
        }
    }
    return $Insights
}

function Format-StartupUsageSnapshotMessage {
    param(
        $Snapshot,
        [ValidateSet('StartupLocal', 'StartupOfficial')]
        [string]$ObservationContext
    )

    $sourceLabel = if ($ObservationContext -eq 'StartupOfficial') {
        '官方接口'
    }
    else {
        '本地快照'
    }
    $quotaLabel = if ($Snapshot) {
        (Get-CodexQuotaPresentation -Snapshot $Snapshot).Label
    } else { '5 小时' }
    $remainingText = if ($Snapshot -and [bool]$Snapshot.HasProgress) {
        '{0}余量 {1:0.#}%' -f $quotaLabel, [double]$Snapshot.RemainingPercent
    }
    else {
        "${quotaLabel}余量未知"
    }
    $sampledAt = if ($Snapshot -and $Snapshot.SampledAt) {
        ([DateTimeOffset]$Snapshot.SampledAt).ToLocalTime()
    }
    else {
        [DateTimeOffset]::Now
    }
    return '{0} · {1} · {2}' -f
        $sourceLabel,
        $remainingText,
        $sampledAt.ToString('M月d日 HH:mm:ss')
}

function Invoke-StartupUsageSnapshotNotification {
    param(
        $Snapshot,
        [ValidateSet('StartupLocal', 'StartupOfficial')]
        [string]$ObservationContext
    )

    if (-not $Snapshot -or [string]$Snapshot.ProviderId -ne 'Codex') {
        return $false
    }
    if ($ObservationContext -eq 'StartupLocal') {
        if ($script:UsageSyncSession.LocalNotificationShown) { return $false }
        $script:UsageSyncSession.LocalNotificationShown = $true
        $title = 'Codex 本地额度快照'
    }
    else {
        if ($script:UsageSyncSession.OfficialNotificationShown) { return $false }
        $script:UsageSyncSession.OfficialNotificationShown = $true
        $title = 'Codex 官方额度已同步'
    }

    if ($isDiagnosticRun -or $Demo -or -not $script:TrayNotifyIcon) {
        return $false
    }
    try {
        $script:TrayNotifyIcon.ShowBalloonTip(
            8000,
            $title,
            (Format-StartupUsageSnapshotMessage `
                -Snapshot $Snapshot `
                -ObservationContext $ObservationContext),
            [System.Windows.Forms.ToolTipIcon]::Info
        )
        return $true
    }
    catch {
        return $false
    }
}

function Get-DeepSeekDisplayCurrency {
    if (
        $script:LastSnapshot -and
        [string]$script:LastSnapshot.ProviderId -eq 'DeepSeek' -and
        $script:LastSnapshot.PSObject.Properties['Currency']
    ) {
        return [string]$script:LastSnapshot.Currency
    }
    return 'CNY'
}

function Get-LowRemainingAlertMenuText {
    $settings = Get-UsageAlertSettings -ProviderId $script:ActiveProvider
    if ([string]$settings.ProviderId -eq 'DeepSeek') {
        return '低余量提醒（≤{0:0}% 或 ≤{1}）' -f `
            [double]$settings.LowPercentThreshold,
            (Format-CurrencyAmount `
                -Amount $settings.LowAmountThreshold `
                -Currency (Get-DeepSeekDisplayCurrency))
    }
    return '低余量提醒（5 小时 ≤{0:0}% · 每周 ≤{1:0}%）' -f `
        [double]$settings.LowFiveHourThreshold,
        [double]$settings.LowWeeklyThreshold
}

function Get-UsageAlertSettingsMenuText {
    return '提醒设置（快降 {0} 分钟）…' -f $script:RapidDropWindowMinutes
}

function Sync-LowAlertMenuState {
    $menuText = Get-LowRemainingAlertMenuText
    $lowEnabled = [bool](
        Get-UsageAlertSettings -ProviderId $script:ActiveProvider
    ).LowAlertsEnabled
    if ($script:LowAlertsMenuItem) {
        $script:LowAlertsMenuItem.IsChecked = $lowEnabled
        $script:LowAlertsMenuItem.Header = $menuText
    }
    if ($script:TrayLowAlertsItem) {
        $script:TrayLowAlertsItem.Checked = $lowEnabled
        $script:TrayLowAlertsItem.Text = $menuText
    }
    $settingsMenuText = Get-UsageAlertSettingsMenuText
    if ($script:LowAlertThresholdMenuItem) {
        $script:LowAlertThresholdMenuItem.Header = $settingsMenuText
    }
    if ($script:TrayLowAlertThresholdItem) {
        $script:TrayLowAlertThresholdItem.Text = $settingsMenuText
    }
}

function Set-LowRemainingAlertsEnabled {
    param([bool]$Enabled)

    try {
        [void](Set-UsageAlertSettings -LowAlertsEnabled $Enabled)
    }
    catch {
        # A failed write must not break the menu: Set-UsageAlertSettings has
        # already rolled the value back, so just re-render from stored state.
        Sync-LowAlertMenuState
    }
}

function Refresh-RapidDropStatusView {
    if (-not $script:LastSnapshot -or -not $script:LastUsageInsights) {
        return
    }

    $script:LastUsageInsights = Set-RapidDropInsightValues `
        -Snapshot $script:LastSnapshot `
        -Insights $script:LastUsageInsights
    Update-UsageInsightView -Insights $script:LastUsageInsights
}

function Set-UsageAlertSettings {
    param(
        [string]$ProviderId = '',
        $LowAlertsEnabled,
        $RapidAlertsEnabled,
        $WindowMinutes,
        $LowFiveHourThreshold,
        $LowWeeklyThreshold,
        $LowPercentThreshold,
        $LowAmountThreshold,
        $RapidFiveHourPercent,
        $RapidWeeklyPercent,
        [ValidateSet('', 'Percent', 'Amount')]
        [string]$RapidMode = '',
        $RapidPercent,
        $RapidAmount
    )

    # Only the values the caller actually passes are replaced; everything else
    # keeps the stored value so a dialog that edits one metric cannot reset the
    # others.
    $provider = if ([string]::IsNullOrWhiteSpace($ProviderId)) {
        [string]$script:ActiveProvider
    } else { [string]$ProviderId }
    if ($provider -notin (Get-UsageAlertProviderIds)) { $provider = 'Codex' }
    if (-not $script:AlertSettings) { $script:AlertSettings = [ordered]@{} }

    $previous = Get-UsageAlertSettings -ProviderId $provider
    $candidate = [ordered]@{}
    foreach ($property in $previous.PSObject.Properties) {
        $candidate[$property.Name] = $property.Value
    }
    $provided = @{
        LowAlertsEnabled = $LowAlertsEnabled
        RapidAlertsEnabled = $RapidAlertsEnabled
        RapidWindowMinutes = $WindowMinutes
        LowFiveHourThreshold = $LowFiveHourThreshold
        LowWeeklyThreshold = $LowWeeklyThreshold
        LowPercentThreshold = $LowPercentThreshold
        LowAmountThreshold = $LowAmountThreshold
        RapidFiveHourPercent = $RapidFiveHourPercent
        RapidWeeklyPercent = $RapidWeeklyPercent
        RapidMode = $RapidMode
        RapidPercent = $RapidPercent
        RapidAmount = $RapidAmount
    }
    foreach ($name in @($provided.Keys)) {
        $value = $provided[$name]
        if ($null -eq $value) { continue }
        if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) {
            continue
        }
        $candidate[$name] = $value
    }

    $validated = ConvertTo-UsageAlertSettings `
        -ProviderId $provider `
        -Value ([pscustomobject]$candidate) `
        -Strict
    $script:AlertSettings[$provider] = $validated
    Sync-ActiveAlertSettings
    Sync-LowAlertMenuState
    try {
        Save-Settings -ThrowOnError
    }
    catch {
        $script:AlertSettings[$provider] = $previous
        Sync-ActiveAlertSettings
        Sync-LowAlertMenuState
        throw
    }
    $script:LowAlertActive = @{}
    $script:RapidDropAlertActive = @{}
    Refresh-RapidDropStatusView
    return Get-AppSettingsSnapshot
}

function New-LowRemainingAlertSettingsDialog {
    [xml]$dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="使用提醒设置"
        Width="480"
        SizeToContent="Height"
        ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner"
        ShowInTaskbar="False"
        Background="#FCFBF8"
        FontFamily="Microsoft YaHei UI">
    <StackPanel Margin="24">
        <TextBlock Text="使用提醒"
                   FontSize="19" FontWeight="SemiBold" Foreground="#343A35"/>
        <TextBlock x:Name="CodexAlertSummary" Margin="0,5,0,0"
                   Text="当前数据源：Codex；低余量和快速下降分别判断。"
                   FontSize="10.5" Foreground="#667069" TextWrapping="Wrap"/>

        <CheckBox x:Name="LowAlertsEnabledBox"
                  Margin="0,18,0,0"
                  Content="启用低余量提醒"
                  FontSize="12"
                  FontWeight="SemiBold"
                  Foreground="#3B433E"/>
        <Grid Margin="0,10,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="150"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="45"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="ThresholdLabel"
                       Text="5 小时余量低于"
                       VerticalAlignment="Center"
                       FontSize="11"
                       Foreground="#59635C"/>
            <TextBox x:Name="ThresholdBox" Grid.Column="1" Height="34"
                      Padding="9,6" BorderBrush="#D8DDD7" Background="White"
                      AutomationProperties.Name="低余量提醒阈值"/>
            <TextBlock x:Name="ThresholdUnitText" Grid.Column="2" Text="%"
                       Margin="10,7,0,0"
                       FontSize="12" Foreground="#4E5750"/>
        </Grid>
        <Grid Margin="0,8,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="150"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="45"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="SecondaryThresholdLabel"
                       Text="每周余量低于"
                       VerticalAlignment="Center"
                       FontSize="11"
                       Foreground="#59635C"/>
            <TextBox x:Name="SecondaryThresholdBox" Grid.Column="1" Height="34"
                      Padding="9,6" BorderBrush="#D8DDD7" Background="White"
                      AutomationProperties.Name="每周低余量提醒阈值"/>
            <TextBlock x:Name="SecondaryThresholdUnitText" Grid.Column="2"
                       Text="%" Margin="10,7,0,0"
                       FontSize="12" Foreground="#4E5750"/>
        </Grid>

        <Border Margin="0,18,0,0"
                Height="1"
                VerticalAlignment="Center"
                Background="#E2E5E0"/>

        <CheckBox x:Name="RapidAlertsEnabledBox"
                  Margin="0,18,0,0"
                  Content="启用快速下降提醒"
                  FontSize="12"
                  FontWeight="SemiBold"
                  Foreground="#3B433E"/>

        <Grid Margin="0,10,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="150"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="45"/>
            </Grid.ColumnDefinitions>
            <TextBlock Text="判断时间范围"
                       VerticalAlignment="Center"
                       FontSize="11"
                       Foreground="#59635C"/>
            <TextBox x:Name="WindowBox" Grid.Column="1" Height="34"
                     Padding="9,6" BorderBrush="#D8DDD7" Background="White"
                     AutomationProperties.Name="快速下降时间范围"/>
            <TextBlock Grid.Column="2" Text="分钟" Margin="10,7,0,0"
                       FontSize="11" Foreground="#4E5750"/>
        </Grid>

        <StackPanel x:Name="QuotaRapidPanel">
            <Grid Margin="0,8,0,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="150"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="45"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="CodexDropLabel" Text="5 小时下降"
                           VerticalAlignment="Center"
                           FontSize="11"
                           Foreground="#59635C"/>
                <TextBox x:Name="CodexDropBox" Grid.Column="1" Height="34"
                         Padding="9,6" BorderBrush="#D8DDD7" Background="White"
                         AutomationProperties.Name="5 小时额度快速下降阈值"/>
                <TextBlock Grid.Column="2" Text="百分点" Margin="10,7,0,0"
                           FontSize="10" Foreground="#4E5750"/>
            </Grid>
            <Grid Margin="0,8,0,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="150"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="45"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="SecondaryDropLabel" Text="每周下降"
                           VerticalAlignment="Center"
                           FontSize="11"
                           Foreground="#59635C"/>
                <TextBox x:Name="SecondaryDropBox" Grid.Column="1" Height="34"
                         Padding="9,6" BorderBrush="#D8DDD7" Background="White"
                         AutomationProperties.Name="每周额度快速下降阈值"/>
                <TextBlock Grid.Column="2" Text="百分点" Margin="10,7,0,0"
                           FontSize="10" Foreground="#4E5750"/>
            </Grid>
        </StackPanel>

        <Grid x:Name="BalanceRapidPanel" Margin="0,8,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="150"/>
                <ColumnDefinition Width="112"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="45"/>
            </Grid.ColumnDefinitions>
            <TextBlock Text="账户余额下降"
                       VerticalAlignment="Center"
                       FontSize="11"
                       Foreground="#59635C"/>
            <ComboBox x:Name="DeepSeekModeBox"
                      Grid.Column="1"
                      Height="34"
                      Padding="7,5"
                      BorderBrush="#D8DDD7"
                      Background="White"
                      AutomationProperties.Name="DeepSeek 快速下降类型">
                <ComboBoxItem Content="百分比" Tag="Percent"/>
                <ComboBoxItem Content="具体金额" Tag="Amount"/>
            </ComboBox>
            <TextBox x:Name="DeepSeekDropBox"
                     Grid.Column="2"
                     Height="34"
                     Margin="8,0,0,0"
                     Padding="9,6"
                     BorderBrush="#D8DDD7"
                     Background="White"
                     AutomationProperties.Name="DeepSeek 快速下降阈值"/>
            <TextBlock x:Name="DeepSeekUnitText"
                       Grid.Column="3"
                       Text="百分点"
                       Margin="10,7,0,0"
                       FontSize="10"
                       Foreground="#4E5750"/>
        </Grid>

        <StackPanel Margin="0,14,0,0">
            <TextBlock FontSize="9.5"
                       Foreground="#7B847D"
                       TextWrapping="Wrap"
                       Text="时间范围可设置 5–1440 分钟；低余量阈值需为 1–99 的整数。DeepSeek 百分比模式需要先设置预算基准，金额阈值直接比较账户余额。"/>
            <TextBlock x:Name="ErrorText" Margin="0,8,0,0"
                    Foreground="#A65B52" FontSize="11" TextWrapping="Wrap"/>
        </StackPanel>

        <Grid Margin="0,18,0,0" Height="34">
            <Button Width="82" Height="34" HorizontalAlignment="Right"
                    Margin="0,0,92,0" Content="取消" IsCancel="True"/>
            <Button x:Name="SaveButton" Width="82" Height="34"
                    HorizontalAlignment="Right" Content="保存" IsDefault="True"
                    Background="#E9F0EA" BorderBrush="#BFCDBF"
                    Foreground="#344A3B"/>
        </Grid>
    </StackPanel>
</Window>
'@
    $dialogReader = New-Object System.Xml.XmlNodeReader $dialogXaml
    $dialog = [Windows.Markup.XamlReader]::Load($dialogReader)
    return $dialog
}

function Show-LowRemainingAlertSettings {
    # The dialog always edits the data source the window currently shows.
    $providerId = [string]$script:ActiveProvider
    if ($providerId -notin (Get-UsageAlertProviderIds)) { $providerId = 'Codex' }
    $settings = Get-UsageAlertSettings -ProviderId $providerId
    $isBalanceSource = [string]$settings.ProviderId -eq 'DeepSeek'
    $currency = Get-DeepSeekDisplayCurrency
    $providerDisplayName = if ($providerId -eq 'Kimi') {
        'Kimi Code'
    } else { $providerId }
    $currencySymbol = if ($currency -eq 'USD') { '$' } else { '¥' }

    $dialog = New-LowRemainingAlertSettingsDialog
    $dialog.Owner = $window
    $codexAlertSummary = $dialog.FindName('CodexAlertSummary')
    $thresholdLabel = $dialog.FindName('ThresholdLabel')
    $thresholdUnitText = $dialog.FindName('ThresholdUnitText')
    $secondaryThresholdLabel = $dialog.FindName('SecondaryThresholdLabel')
    $secondaryThresholdUnitText =
        $dialog.FindName('SecondaryThresholdUnitText')
    $lowEnabledBox = $dialog.FindName('LowAlertsEnabledBox')
    $thresholdBox = $dialog.FindName('ThresholdBox')
    $secondaryThresholdBox = $dialog.FindName('SecondaryThresholdBox')
    $rapidEnabledBox = $dialog.FindName('RapidAlertsEnabledBox')
    $windowBox = $dialog.FindName('WindowBox')
    $quotaRapidPanel = $dialog.FindName('QuotaRapidPanel')
    $balanceRapidPanel = $dialog.FindName('BalanceRapidPanel')
    $codexDropLabel = $dialog.FindName('CodexDropLabel')
    $codexDropBox = $dialog.FindName('CodexDropBox')
    $secondaryDropLabel = $dialog.FindName('SecondaryDropLabel')
    $secondaryDropBox = $dialog.FindName('SecondaryDropBox')
    $deepSeekModeBox = $dialog.FindName('DeepSeekModeBox')
    $deepSeekDropBox = $dialog.FindName('DeepSeekDropBox')
    $deepSeekUnitText = $dialog.FindName('DeepSeekUnitText')
    $errorText = $dialog.FindName('ErrorText')
    $saveButton = $dialog.FindName('SaveButton')

    if ($isBalanceSource) {
        $codexAlertSummary.Text = (
            "当前数据源：$providerDisplayName；预算百分比与账户余额分别判断。"
        )
        $thresholdLabel.Text = '预算余量低于'
        $secondaryThresholdLabel.Text = "账户余额低于（$currencySymbol）"
        $thresholdUnitText.Text = '%'
        $secondaryThresholdUnitText.Text = ''
        $quotaRapidPanel.Visibility = 'Collapsed'
        $balanceRapidPanel.Visibility = 'Visible'
    }
    else {
        $codexAlertSummary.Text = (
            "当前数据源：$providerDisplayName；5 小时与每周额度、低余量与快速下降分别判断。"
        )
        $thresholdLabel.Text = '5 小时余量低于'
        $secondaryThresholdLabel.Text = '每周余量低于'
        $thresholdUnitText.Text = '%'
        $secondaryThresholdUnitText.Text = '%'
        $quotaRapidPanel.Visibility = 'Visible'
        $balanceRapidPanel.Visibility = 'Collapsed'
        $codexDropLabel.Text = '5 小时下降'
        $secondaryDropLabel.Text = '每周下降'
        [Windows.Automation.AutomationProperties]::SetName(
            $codexDropBox,
            '5 小时额度快速下降阈值'
        )
        [Windows.Automation.AutomationProperties]::SetName(
            $secondaryDropBox,
            '每周额度快速下降阈值'
        )
    }

    $lowEnabledBox.IsChecked = [bool]$settings.LowAlertsEnabled
    $rapidEnabledBox.IsChecked = [bool]$settings.RapidAlertsEnabled
    $windowBox.Text = [string]$settings.RapidWindowMinutes
    if ($isBalanceSource) {
        $thresholdBox.Text = ([double]$settings.LowPercentThreshold).ToString(
            '0',
            [Globalization.CultureInfo]::CurrentCulture
        )
        $secondaryThresholdBox.Text =
            ([double]$settings.LowAmountThreshold).ToString(
                '0.##',
                [Globalization.CultureInfo]::CurrentCulture
            )
        $deepSeekModeBox.SelectedIndex = if (
            [string]$settings.RapidMode -eq 'Amount'
        ) { 1 } else { 0 }
        $deepSeekDropBox.Text = if ([string]$settings.RapidMode -eq 'Amount') {
            ([double]$settings.RapidAmount).ToString(
                '0.##',
                [Globalization.CultureInfo]::CurrentCulture
            )
        } else {
            ([double]$settings.RapidPercent).ToString(
                '0.#',
                [Globalization.CultureInfo]::CurrentCulture
            )
        }
        $deepSeekUnitText.Text = if (
            [string]$settings.RapidMode -eq 'Amount'
        ) { '金额' } else { '百分点' }
    }
    else {
        $thresholdBox.Text = ([double]$settings.LowFiveHourThreshold).ToString(
            '0',
            [Globalization.CultureInfo]::CurrentCulture
        )
        $secondaryThresholdBox.Text =
            ([double]$settings.LowWeeklyThreshold).ToString(
                '0',
                [Globalization.CultureInfo]::CurrentCulture
            )
        $codexDropBox.Text = ([double]$settings.RapidFiveHourPercent).ToString(
            '0.#',
            [Globalization.CultureInfo]::CurrentCulture
        )
        $secondaryDropBox.Text =
            ([double]$settings.RapidWeeklyPercent).ToString(
                '0.#',
                [Globalization.CultureInfo]::CurrentCulture
            )
    }

    $deepSeekModeBox.Add_SelectionChanged((
        New-RmfEventHandler -Kind SelectionChanged -Callback {
            $mode = [string]$deepSeekModeBox.SelectedItem.Tag
            if ($mode -eq 'Amount') {
                $deepSeekDropBox.Text = $script:DeepSeekRapidDropAmount.ToString(
                    '0.##',
                    [Globalization.CultureInfo]::CurrentCulture
                )
                $deepSeekUnitText.Text = '金额'
            }
            else {
                $deepSeekDropBox.Text = $script:DeepSeekRapidDropPercent.ToString(
                    '0.#',
                    [Globalization.CultureInfo]::CurrentCulture
                )
                $deepSeekUnitText.Text = '百分点'
            }
        }
    ))

    $saveButton.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
        $errorText.Text = ''
        try {
            if ($isBalanceSource) {
                $deepSeekMode = [string]$deepSeekModeBox.SelectedItem.Tag
                $rapidPercent = if ($deepSeekMode -eq 'Percent') {
                    $deepSeekDropBox.Text
                } else { $null }
                $rapidAmount = if ($deepSeekMode -eq 'Amount') {
                    $deepSeekDropBox.Text
                } else { $null }
                [void](Set-UsageAlertSettings `
                    -ProviderId $providerId `
                    -LowAlertsEnabled ([bool]$lowEnabledBox.IsChecked) `
                    -LowPercentThreshold $thresholdBox.Text `
                    -LowAmountThreshold $secondaryThresholdBox.Text `
                    -RapidAlertsEnabled ([bool]$rapidEnabledBox.IsChecked) `
                    -WindowMinutes $windowBox.Text `
                    -RapidMode $deepSeekMode `
                    -RapidPercent $rapidPercent `
                    -RapidAmount $rapidAmount)
            }
            else {
                [void](Set-UsageAlertSettings `
                    -ProviderId $providerId `
                    -LowAlertsEnabled ([bool]$lowEnabledBox.IsChecked) `
                    -LowFiveHourThreshold $thresholdBox.Text `
                    -LowWeeklyThreshold $secondaryThresholdBox.Text `
                    -RapidAlertsEnabled ([bool]$rapidEnabledBox.IsChecked) `
                    -WindowMinutes $windowBox.Text `
                    -RapidFiveHourPercent $codexDropBox.Text `
                    -RapidWeeklyPercent $secondaryDropBox.Text)
            }
            $dialog.DialogResult = $true
        }
        catch {
            $errorText.Text = $_.Exception.Message
        }
    }))

    return [bool]($dialog.ShowDialog())
}

function Get-UsageAlertScopeKey {
    param(
        $Snapshot,
        [ValidateSet('', 'FiveHour', 'Weekly')]
        [string]$QuotaPeriod = ''
    )

    $providerId = [string]$Snapshot.ProviderId
    if ($providerId -in @('Codex', 'Kimi')) {
        $period = if ($QuotaPeriod -in @('FiveHour', 'Weekly')) {
            $QuotaPeriod
        } else {
            (Get-CodexQuotaPresentation -Snapshot $Snapshot).Period
        }
        return "${providerId}|${period}"
    }
    return $providerId
}

function Get-UsageAlertLowChecks {
    param(
        $Snapshot,
        $Insights
    )

    # One independent check per metric: a quota window that still has room must
    # never hide an exhausted one, which is exactly what a single threshold on
    # the primary window used to do.
    $checks = New-Object Collections.Generic.List[object]
    $providerId = [string]$Snapshot.ProviderId
    # Always read the thresholds of the source the snapshot came from rather
    # than the active one: monitoring must not follow a stale data source.
    $settings = Get-UsageAlertSettings -ProviderId $providerId
    $providerDisplayName = if ($providerId -eq 'Kimi') {
        'Kimi Code'
    } else { $providerId }
    $previousPercentValue = if (
        $Insights -and
        $Insights.PreviousSample -and
        [string]$Insights.PreviousSample.MetricType -eq 'Percent'
    ) { $Insights.PreviousSample.RemainingValue } else { $null }

    if ($providerId -in @('Codex', 'Kimi')) {
        $primaryPeriod = (Get-CodexQuotaPresentation -Snapshot $Snapshot).Period
        foreach ($period in @('FiveHour', 'Weekly')) {
            $availableProperty = "${period}Available"
            $label = if ($period -eq 'Weekly') { '每周' } else { '5 小时' }
            $threshold = if ($period -eq 'Weekly') {
                $settings.LowWeeklyThreshold
            } else {
                $settings.LowFiveHourThreshold
            }
            $checks.Add([pscustomobject]@{
                Key = "${providerId}|${period}|Low"
                Title = "$providerDisplayName ${label}余量偏低"
                Available = (
                    $Snapshot.PSObject.Properties[$availableProperty] -and
                    [bool]$Snapshot.$availableProperty
                )
                Value = [double](Get-ObjectPropertyValue `
                    -Object $Snapshot `
                    -Name "${period}RemainingPercent" `
                    -Default 0)
                Threshold = [double]$threshold
                PreviousValue = if ($period -eq $primaryPeriod) {
                    $previousPercentValue
                } else { $null }
                IncludeForecast = $period -eq $primaryPeriod
                IsAmount = $false
            })
        }
        return $checks
    }

    $checks.Add([pscustomobject]@{
        Key = "${providerId}|Percent|Low"
        Title = "$providerDisplayName 预算余量偏低"
        Available = [bool]$Snapshot.HasProgress
        Value = [double]$Snapshot.RemainingPercent
        Threshold = [double]$settings.LowPercentThreshold
        PreviousValue = $previousPercentValue
        IncludeForecast = $true
        IsAmount = $false
    })
    if (
        $providerId -eq 'DeepSeek' -and
        $Snapshot.PSObject.Properties['TotalBalance']
    ) {
        # The balance check works without a budget baseline, which the
        # percentage check cannot: that is the gap this closes.
        $checks.Add([pscustomobject]@{
            Key = "${providerId}|Amount|Low"
            Title = "$providerDisplayName 余额偏低"
            Available = $true
            Value = [double]$Snapshot.TotalBalance
            Threshold = [double]$settings.LowAmountThreshold
            PreviousValue = $null
            IncludeForecast = $false
            IsAmount = $true
        })
    }
    return $checks
}

function Invoke-LowRemainingAlert {
    param(
        $Snapshot,
        $Insights
    )

    if (
        $isDiagnosticRun -or
        $Demo -or
        -not $script:LowRemainingAlertsEnabled -or
        -not $script:TrayNotifyIcon -or
        -not $Snapshot.Available
    ) {
        return $false
    }

    $providerId = [string]$Snapshot.ProviderId
    $currency = if ($providerId -eq 'DeepSeek') {
        Get-DeepSeekDisplayCurrency
    } else { '' }
    $forecastText = if ($Insights -and $Insights.Forecast) {
        [string]$Insights.Forecast.Text
    } else { '' }
    $shown = $false
    foreach ($check in @(
        Get-UsageAlertLowChecks -Snapshot $Snapshot -Insights $Insights
    )) {
        if (-not $check.Available) { continue }
        if ([double]$check.Value -gt [double]$check.Threshold) {
            $script:LowAlertActive[$check.Key] = $false
            continue
        }
        if (
            $script:LowAlertActive.ContainsKey($check.Key) -and
            [bool]$script:LowAlertActive[$check.Key]
        ) {
            continue
        }
        if (
            -not (Test-UsageAlertThresholdCrossed `
                -Available $check.Available `
                -Value ([double]$check.Value) `
                -Threshold ([double]$check.Threshold) `
                -PreviousValue $check.PreviousValue)
        ) {
            $script:LowAlertActive[$check.Key] = $true
            continue
        }
        $valueText = if ($check.IsAmount) {
            '当前余额 {0}' -f (
                Format-CurrencyAmount `
                    -Amount $check.Value `
                    -Currency $currency
            )
        } else {
            '当前剩余 {0:0}%' -f $check.Value
        }
        $message = if (
            $check.IncludeForecast -and
            -not [string]::IsNullOrWhiteSpace($forecastText)
        ) {
            '{0} · {1}' -f $valueText, $forecastText
        } else { $valueText }
        try {
            $script:TrayNotifyIcon.ShowBalloonTip(
                8000,
                $check.Title,
                $message,
                [System.Windows.Forms.ToolTipIcon]::Warning
            )
            $script:LowAlertActive[$check.Key] = $true
            $shown = $true
        }
        catch {
            # Notifications are best-effort and may be disabled by Windows.
            $script:LowAlertActive[$check.Key] = $false
        }
    }
    return $shown
}

function Invoke-RapidDropAlert {
    param(
        $Snapshot,
        $Insights
    )

    if (
        $isDiagnosticRun -or
        $Demo -or
        -not $script:RapidDropAlertsEnabled -or
        -not $script:TrayNotifyIcon -or
        -not $Snapshot.Available -or
        -not $Insights
    ) {
        return $false
    }

    $providerId = [string]$Snapshot.ProviderId
    $providerDisplayName = if ($providerId -eq 'Kimi') {
        'Kimi Code'
    } else { $providerId }
    $rapidDrops = if (
        $Insights.PSObject.Properties['RapidDrops'] -and
        $Insights.RapidDrops
    ) {
        @($Insights.RapidDrops)
    }
    elseif ($Insights.RapidDrop) {
        @($Insights.RapidDrop)
    }
    else { @() }

    $shown = $false
    foreach ($rapidDrop in $rapidDrops) {
        $alertKey = '{0}|{1}|{2}' -f
            (Get-UsageAlertScopeKey `
                -Snapshot $Snapshot `
                -QuotaPeriod ([string]$rapidDrop.QuotaPeriod)),
            $rapidDrop.MetricType,
            $rapidDrop.Unit
        if (-not $rapidDrop.Available -or -not $rapidDrop.IsRapid) {
            $script:RapidDropAlertActive[$alertKey] = $false
            continue
        }
        if (
            $script:RapidDropAlertActive.ContainsKey($alertKey) -and
            [bool]$script:RapidDropAlertActive[$alertKey]
        ) {
            continue
        }
        $title = if ($providerId -in @('Codex', 'Kimi')) {
            $quotaLabel = if ($rapidDrop.QuotaPeriod -eq 'Weekly') {
                '每周'
            } else {
                '5 小时'
            }
            "$providerDisplayName ${quotaLabel}余量快速下降"
        } else {
            '{0} 余量快速下降' -f $providerDisplayName
        }
        $currentText = if ($rapidDrop.MetricType -eq 'Percent') {
            '当前剩余 {0:0.#}%' -f $rapidDrop.CurrentValue
        } else {
            '当前余额 {0}' -f (
                Format-CurrencyAmount `
                    -Amount $rapidDrop.CurrentValue `
                    -Currency $rapidDrop.Unit
            )
        }
        $message = '{0} · {1}' -f $rapidDrop.Summary, $currentText
        try {
            $script:TrayNotifyIcon.ShowBalloonTip(
                8000,
                $title,
                $message,
                [System.Windows.Forms.ToolTipIcon]::Warning
            )
            $script:RapidDropAlertActive[$alertKey] = $true
            $shown = $true
        }
        catch {
            $script:RapidDropAlertActive[$alertKey] = $false
        }
    }
    return $shown
}

function Set-UsageSnapshotProvenance {
    param($Snapshot)

    $freshness = Get-UsageSnapshotFreshness -Snapshot $Snapshot
    $isFallback = (
        $Snapshot.PSObject.Properties['IsFallback'] -and
        [bool]$Snapshot.IsFallback
    )
    $fallbackReason = if (
        $Snapshot.PSObject.Properties['FallbackReason']
    ) {
        [string]$Snapshot.FallbackReason
    }
    else {
        ''
    }
    $SourceText.Text = if ($isFallback) {
        '显示上次数据（{0}）{1}' -f
            $freshness.AgeText,
            $(if ([string]::IsNullOrWhiteSpace($fallbackReason)) {
                ''
            } else {
                ' · ' + $fallbackReason
            })
    }
    elseif ($freshness.State -eq 'Stale') {
        '{0} · 数据可能已过期（{1}）' -f
            $Snapshot.Source,
            $freshness.AgeText
    }
    elseif ($freshness.State -eq 'Delayed') {
        '{0} · {1}' -f $Snapshot.Source, $freshness.AgeText
    }
    else {
        [string]$Snapshot.Source
    }

    $SampleTime.Text = '采样于 {0}' -f
        $Snapshot.SampledAt.ToString('M月d日 HH:mm:ss')
    if ($freshness.State -in @('Delayed', 'Stale')) {
        $SampleTime.Text += ' · ' + $freshness.AgeText
    }
    return $freshness
}

function Set-CodexQuotaBand {
    param(
        [bool]$Available,
        [double]$UsedPercent,
        [double]$RemainingPercent,
        [string]$ResetDate,
        [string]$ResetCountdown,
        [string]$UnknownText,
        [string]$Label,
        $Band,
        $ResetText,
        $UsedValue,
        $RemainingValue,
        $RemainingColumn,
        $UsedColumn
    )

    $remaining = if ($Available) {
        [Math]::Max(0.0, [Math]::Min(100.0, $RemainingPercent))
    } else { 0.0 }
    $used = if ($Available) {
        [Math]::Max(0.0, [Math]::Min(100.0, $UsedPercent))
    } else { 100.0 }
    $UsedValue.Text = if ($Available) { '{0:0}%' -f $used } else { '未知' }
    $RemainingValue.Text = if ($Available) { '{0:0}%' -f $remaining } else { '未知' }
    $ResetText.Text = if ($Available) { $ResetCountdown } else { $UnknownText }
    $ResetText.ToolTip = if ($Available) {
        '{0} · {1}' -f $ResetDate, $ResetCountdown
    } else {
        $UnknownText
    }
    if ($Band) {
        $bandDescription = if ($Available) {
            '{0}额度，剩余 {1:0}%，已用 {2:0}%，{3}' -f `
                $Label, $remaining, $used, $ResetCountdown
        } else {
            '{0}额度，{1}' -f $Label, $UnknownText
        }
        [Windows.Automation.AutomationProperties]::SetName(
            $Band,
            $bandDescription
        )
        $Band.ToolTip = $bandDescription
    }
    $RemainingColumn.Width = New-Object Windows.GridLength(
        $remaining,
        [Windows.GridUnitType]::Star
    )
    $UsedColumn.Width = New-Object Windows.GridLength(
        $used,
        [Windows.GridUnitType]::Star
    )
}

function Get-CodexQuotaPresentation {
    param($Snapshot)

    $period = if (
        $Snapshot -and
        $Snapshot.PSObject.Properties['PrimaryQuotaPeriod'] -and
        [string]$Snapshot.PrimaryQuotaPeriod -in @('FiveHour', 'Weekly')
    ) {
        [string]$Snapshot.PrimaryQuotaPeriod
    }
    else {
        $planType = if ($Snapshot -and $Snapshot.PSObject.Properties['PlanType']) {
            [string]$Snapshot.PlanType
        } elseif ($Snapshot -and $Snapshot.PSObject.Properties['Plan']) {
            [string]$Snapshot.Plan
        } else { '' }
        if (Get-Command Get-CodexPrimaryQuotaPeriod -ErrorAction SilentlyContinue) {
            Get-CodexPrimaryQuotaPeriod -PlanType $planType
        } elseif ($planType.Trim() -match '^Pro(?:\s|$)') {
            'Weekly'
        } else {
            'FiveHour'
        }
    }
    $prefix = if ($period -eq 'Weekly') { 'Weekly' } else { 'FiveHour' }
    $label = if ($period -eq 'Weekly') { '每周' } else { '5 小时' }
    $availableProperty = "${prefix}Available"
    $available = (
        $Snapshot -and
        $Snapshot.PSObject.Properties[$availableProperty] -and
        [bool]$Snapshot.$availableProperty
    )
    return [pscustomobject]@{
        Period = $period
        Label = $label
        Available = $available
        UsedPercent = if ($available) {
            [double](Get-ObjectPropertyValue `
                -Object $Snapshot `
                -Name "${prefix}UsedPercent" `
                -Default 0)
        } else { 0.0 }
        RemainingPercent = if ($available) {
            [double](Get-ObjectPropertyValue `
                -Object $Snapshot `
                -Name "${prefix}RemainingPercent" `
                -Default 0)
        } else { 0.0 }
        ResetDate = if ($available) {
            [string](Get-ObjectPropertyValue `
                -Object $Snapshot `
                -Name "${prefix}ResetDate" `
                -Default '暂无')
        } else { '暂无' }
        ResetCountdown = if ($available) {
            [string](Get-ObjectPropertyValue `
                -Object $Snapshot `
                -Name "${prefix}ResetCountdown" `
                -Default "等待$label 额度数据")
        } else { "等待$label 额度数据" }
        ResetAt = if ($available) {
            Get-ObjectPropertyValue `
                -Object $Snapshot `
                -Name "${prefix}ResetAt"
        } else { $null }
    }
}

function Get-CodexQuotaBinding {
    param(
        $Snapshot,
        $PrimaryQuota
    )

    # A depleted weekly window blocks the account even when the five-hour
    # window has just rolled over to 100%, so the header has to show the
    # weekly quota instead of the freshly refilled five-hour one. Only the raw
    # window fields are read here: Snapshot.RemainingPercent / HasProgress are
    # rewritten from the plan's primary window by Update-UsageView and equal 0
    # whenever a window is merely unavailable, which must stay "unknown".
    $weeklyAvailable = (
        $Snapshot -and
        $Snapshot.PSObject.Properties['WeeklyAvailable'] -and
        [bool]$Snapshot.WeeklyAvailable
    )
    $weeklyRemaining = if ($weeklyAvailable) {
        [double](Get-ObjectPropertyValue `
            -Object $Snapshot `
            -Name 'WeeklyRemainingPercent' `
            -Default 0)
    } else { 0.0 }
    if (
        -not $weeklyAvailable -or
        $weeklyRemaining -gt 0 -or
        [string]$PrimaryQuota.Period -eq 'Weekly'
    ) {
        return [pscustomobject]@{
            IsWeeklyExhausted = $false
            Period = $PrimaryQuota.Period
            Label = $PrimaryQuota.Label
            Available = $PrimaryQuota.Available
            RemainingPercent = $PrimaryQuota.RemainingPercent
            UsedPercent = $PrimaryQuota.UsedPercent
            ResetDate = $PrimaryQuota.ResetDate
            ResetCountdown = $PrimaryQuota.ResetCountdown
            ResetAt = $PrimaryQuota.ResetAt
        }
    }

    return [pscustomobject]@{
        IsWeeklyExhausted = $true
        Period = 'Weekly'
        Label = '每周'
        Available = $true
        RemainingPercent = $weeklyRemaining
        UsedPercent = [double](Get-ObjectPropertyValue `
            -Object $Snapshot `
            -Name 'WeeklyUsedPercent' `
            -Default 0)
        ResetDate = [string](Get-ObjectPropertyValue `
            -Object $Snapshot `
            -Name 'WeeklyResetDate' `
            -Default '暂无')
        ResetCountdown = [string](Get-ObjectPropertyValue `
            -Object $Snapshot `
            -Name 'WeeklyResetCountdown' `
            -Default '等待每周额度数据')
        ResetAt = Get-ObjectPropertyValue `
            -Object $Snapshot `
            -Name 'WeeklyResetAt'
    }
}

function Invoke-PendingUsageHistoryUpdate {
    if (
        $script:IsClosing -or
        $script:PendingUsageHistoryUpdates.Count -eq 0
    ) { return }
    $pending = $script:PendingUsageHistoryUpdates.Dequeue()
    $snapshot = $pending.Snapshot
    $observedAt = [DateTimeOffset]$pending.ObservedAt
    $observationContext = [string]$pending.ObservationContext
    try {
        $historyUpdateTimer = [Diagnostics.Stopwatch]::StartNew()
        $skipUsageHistoryPersistence = (
            $observationContext -eq 'LocalPreview' -or
            (
                $observationContext -eq 'StartupLocal' -and
                $script:CodexOfficialAccessEnabled
            )
        )
        $insights = Update-UsageHistory `
            -Snapshot $snapshot `
            -ObservedAt $observedAt `
            -RapidDropWindowMinutes $script:RapidDropWindowMinutes `
            -CodexRapidDropPercent $script:CodexRapidDropPercent `
            -DeepSeekRapidDropMode $script:DeepSeekRapidDropMode `
            -DeepSeekRapidDropPercent $script:DeepSeekRapidDropPercent `
            -DeepSeekRapidDropAmount $script:DeepSeekRapidDropAmount `
            -SkipPersistence:$skipUsageHistoryPersistence
        $insights = Set-SessionRapidDropInsight `
            -Snapshot $snapshot `
            -Insights $insights `
            -ObservationContext $observationContext `
            -ObservedAt $observedAt
        $script:LastUsageInsights = $insights
        Update-UsageInsightView -Insights $insights
        $historyUpdateTimer.Stop()
        $script:UsageHistoryUpdateCount++
        $script:UsageHistoryUpdateLastMilliseconds =
            $historyUpdateTimer.ElapsedMilliseconds
        $script:UsageHistoryUpdateLastError = ''
        Write-RuntimeLog `
            -Level $(if ($historyUpdateTimer.ElapsedMilliseconds -ge 500) {
                'Warning'
            } else {
                'Debug'
            }) `
            -Event 'History.Updated' `
            -Message '历史趋势已更新' `
            -ElapsedMilliseconds $historyUpdateTimer.ElapsedMilliseconds
        if ($observationContext -in @('StartupLocal', 'StartupOfficial')) {
            [void](Invoke-StartupUsageSnapshotNotification `
                -Snapshot $snapshot `
                -ObservationContext $observationContext)
        }
        elseif ($observationContext -eq 'Normal') {
            $lowAlertShown = Invoke-LowRemainingAlert `
                -Snapshot $snapshot `
                -Insights $insights
            if (-not $lowAlertShown) {
                [void](Invoke-RapidDropAlert `
                    -Snapshot $snapshot `
                    -Insights $insights)
            }
        }
    }
    catch {
        $script:LastUsageHistoryError = $_.Exception.Message
        $script:UsageHistoryUpdateLastError = $_.Exception.Message
        Write-RuntimeLog `
            -Level 'Error' `
            -Event 'History.UpdateFailed' `
            -Message $_.Exception.Message
        if (Get-Command Set-RuntimeDiagnosticStatus -ErrorAction SilentlyContinue) {
            Set-RuntimeDiagnosticStatus `
                -Area 'History' `
                -Status 'Error' `
                -Message $_.Exception.Message
        }
        $Trend5HText.Text = '近 5 小时：暂不可用'
        $Trend7Text.Text = '7 天：暂不可用'
        $Trend5HMetaText.Text = '历史记录读取失败'
        $Trend7MetaText.Text = '历史记录读取失败'
        $Trend5HLine.Points.Clear()
        $Trend5HArea.Points.Clear()
        $Trend7Line.Points.Clear()
        $Trend7Area.Points.Clear()
        $Trend5HStartMarker.Visibility = 'Collapsed'
        $Trend5HEndMarker.Visibility = 'Collapsed'
        $Trend7StartMarker.Visibility = 'Collapsed'
        $Trend7EndMarker.Visibility = 'Collapsed'
        $PredictionText.Text = '趋势暂不可用'
        $RapidDropStatusDot.Fill = New-Object Windows.Media.SolidColorBrush(
            [Windows.Media.ColorConverter]::ConvertFromString('#9A765E')
        )
        $RapidDropText.Text = '快速下降监控 · 历史记录暂不可用'
    }
    if (
        $script:PendingUsageHistoryUpdates.Count -eq 0 -and
        -not $script:AppContext.Refresh.IsBusy -and
        (Get-Command Start-UsageHistoryRepair -ErrorAction SilentlyContinue)
    ) {
        Start-UsageHistoryRepair
    }
}

function Queue-UsageHistoryUpdate {
    param(
        $Snapshot,
        [DateTimeOffset]$ObservedAt,
        [string]$ObservationContext
    )

    [void]$script:PendingUsageHistoryUpdates.Enqueue([pscustomobject]@{
        Snapshot = $Snapshot
        ObservedAt = $ObservedAt
        ObservationContext = $ObservationContext
    })
    $window.Dispatcher.BeginInvoke(
        [Windows.Threading.DispatcherPriority]::Background,
        (New-RmfAction -Callback { Invoke-PendingUsageHistoryUpdate })
    ) | Out-Null
}

function Update-UsageView {
    param(
        $Snapshot,
        [ValidateSet(
            'Normal',
            'LocalPreview',
            'StartupLocal',
            'StartupOfficial'
        )]
        [string]$ObservationContext = 'Normal',
        [switch]$DisplayOnly
    )

    $codexPrimaryQuota = $null
    $codexQuotaBinding = $null
    $isQuotaLayout = [string]$Snapshot.ProviderId -in @('Codex', 'Kimi')
    if ($isQuotaLayout) {
        $codexPrimaryQuota = Get-CodexQuotaPresentation -Snapshot $Snapshot
        $codexQuotaBinding = Get-CodexQuotaBinding `
            -Snapshot $Snapshot `
            -PrimaryQuota $codexPrimaryQuota
        $Snapshot | Add-Member `
            -NotePropertyName PrimaryQuotaPeriod `
            -NotePropertyValue $codexPrimaryQuota.Period `
            -Force
        $Snapshot.HasProgress = [bool]$codexPrimaryQuota.Available
        $Snapshot.RemainingPercent = [double]$codexPrimaryQuota.RemainingPercent
        $Snapshot.WindowLabel = if ($codexQuotaBinding.Available) {
            "$($codexQuotaBinding.Label)余量"
        } else {
            "$($codexQuotaBinding.Label)余量未知"
        }
        if ($Snapshot.PSObject.Properties['ResetDate']) {
            $Snapshot.ResetDate = $codexPrimaryQuota.ResetDate
        }
        if ($Snapshot.PSObject.Properties['ResetCountdown']) {
            $Snapshot.ResetCountdown = $codexPrimaryQuota.ResetCountdown
        }
        if ($Snapshot.PSObject.Properties['ResetAt']) {
            $Snapshot.ResetAt = $codexPrimaryQuota.ResetAt
        }
    }
    Assert-UsageSnapshotContract -Snapshot $Snapshot
    $observedAt = [DateTimeOffset]::Now
    if (-not $DisplayOnly) {
        $script:LastSnapshot = $Snapshot
        if ([bool]$Snapshot.Available) {
            try {
                $stateSaveTimer = [Diagnostics.Stopwatch]::StartNew()
                [void](Save-UsageStateSnapshot `
                    -Snapshot $Snapshot `
                    -ObservedAt $observedAt `
                    -Reason $ObservationContext)
                $stateSaveTimer.Stop()
                if (Get-Command Write-RuntimeLog -ErrorAction SilentlyContinue) {
                    Write-RuntimeLog `
                        -Level $(if ($stateSaveTimer.ElapsedMilliseconds -ge 250) {
                            'Warning'
                        } else {
                            'Debug'
                        }) `
                        -Event 'StateHistory.Saved' `
                        -Message '完整状态已增量保存' `
                        -ElapsedMilliseconds $stateSaveTimer.ElapsedMilliseconds `
                        -Data @{
                            Provider = [string]$Snapshot.ProviderId
                            Reason = $ObservationContext
                        }
                }
                if (Get-Command Set-RuntimeDiagnosticStatus -ErrorAction SilentlyContinue) {
                    Set-RuntimeDiagnosticStatus `
                        -Area 'StateHistory' `
                        -Status 'Healthy' `
                        -Message '完整状态已保存'
                }
            }
            catch {
                if (Get-Command Write-RuntimeLog -ErrorAction SilentlyContinue) {
                    Write-RuntimeLog `
                        -Level 'Error' `
                        -Event 'StateHistory.SaveFailed' `
                        -Message $_.Exception.Message `
                        -Data @{
                            Provider = [string]$Snapshot.ProviderId
                            Reason = $ObservationContext
                        }
                }
                if (Get-Command Set-RuntimeDiagnosticStatus -ErrorAction SilentlyContinue) {
                    Set-RuntimeDiagnosticStatus `
                        -Area 'StateHistory' `
                        -Status 'Error' `
                        -Message $_.Exception.Message
                }
            }
        }
    }
    $freshness = Get-UsageSnapshotFreshness -Snapshot $Snapshot
    $isFallback = (
        $Snapshot.PSObject.Properties['IsFallback'] -and
        [bool]$Snapshot.IsFallback
    )
    $fallbackReason = if (
        $Snapshot.PSObject.Properties['FallbackReason']
    ) {
        [string]$Snapshot.FallbackReason
    }
    else {
        ''
    }
    if (Get-Command Set-RuntimeDiagnosticStatus -ErrorAction SilentlyContinue) {
        Set-RuntimeDiagnosticStatus `
            -Area ([string]$Snapshot.ProviderId) `
            -Status $(if (-not [bool]$Snapshot.Available) {
                'Error'
            } elseif ($isFallback -or $freshness.IsStale) {
                'Degraded'
            } else {
                'Healthy'
            }) `
            -Message $(if ([bool]$Snapshot.Available) {
                if ($isFallback) {
                    $fallbackReason
                } elseif ($freshness.IsStale) {
                    '数据可能已过期 · ' + $freshness.AgeText
                } else {
                    [string]$Snapshot.Source
                }
            } else {
                [string]$Snapshot.Status
            }) `
            -ObservedAt ([DateTimeOffset]$Snapshot.SampledAt)
    }
    $codexFiveHourAvailable = (
        $isQuotaLayout -and
        $Snapshot.PSObject.Properties['FiveHourAvailable'] -and
        [bool]$Snapshot.FiveHourAvailable
    )
    $codexFiveHourRemaining = if ($codexFiveHourAvailable) {
        [double](Get-ObjectPropertyValue `
            -Object $Snapshot `
            -Name 'FiveHourRemainingPercent' `
            -Default 0)
    } else { 0.0 }
    $codexPrimaryQuota = if ($isQuotaLayout) {
        Get-CodexQuotaPresentation -Snapshot $Snapshot
    } else { $null }
    $codexQuotaBinding = if ($isQuotaLayout) {
        Get-CodexQuotaBinding `
            -Snapshot $Snapshot `
            -PrimaryQuota $codexPrimaryQuota
    } else { $null }
    $displayWindowLabel = [string]$Snapshot.WindowLabel
    $WindowLabel.Text = $displayWindowLabel
    $ExpandedWindowLabel.Text = $displayWindowLabel
    # 紧凑态标签可用宽度约 66 DIP：超过 6 个字符（如“5 小时余量未知”）
    # 会溢出并被窗口两缘裁切，缩到 8pt 保证完整显示。
    $WindowLabel.FontSize = if (
        -not $script:IsExpanded -and $displayWindowLabel.Length -gt 6
    ) { 8 } else { 9 }
    # The reset row follows whatever the header displays, so a depleted weekly
    # window reports when quota actually returns rather than when the
    # five-hour window rolls over.
    $DetailsResetDate.Text = if ($isQuotaLayout) {
        $codexQuotaBinding.ResetDate
    } else { [string]$Snapshot.ResetDate }
    $DetailsResetCountdown.Text = if ($isQuotaLayout) {
        $codexQuotaBinding.ResetCountdown
    } else { [string]$Snapshot.ResetCountdown }
    $AccountName.Text = $Snapshot.AccountName
    $PlanBadge.Text = $Snapshot.Plan
    $AccountEmail.Text = $Snapshot.AccountEmail
    [void](Set-UsageSnapshotProvenance -Snapshot $Snapshot)
    $ResetSummaryPanel.Visibility = if (
        $script:IsExpanded -and
        [string]$Snapshot.ProviderId -in @('Codex', 'Kimi')
    ) { 'Visible' } else { 'Collapsed' }
    $ExpandedWindowLabel.Visibility = if ($script:IsExpanded) {
        'Visible'
    } else { 'Collapsed' }
    $WindowLabel.Visibility = if ($script:IsExpanded) {
        'Collapsed'
    } else { 'Visible' }
    if ($script:IsExpanded) {
        $CompactHit.Padding = New-Object Windows.Thickness(9, 7, 9, 2)
        $CompactProgressRow.Height = New-Object Windows.GridLength(23)
    }
    else {
        $CompactHit.Padding = New-Object Windows.Thickness(7, 5, 7, 5)
        $CompactProgressRow.Height = New-Object Windows.GridLength(12)
    }

    if ($Snapshot.ProviderId -eq 'DeepSeek') {
        $QuotaMetricRow.Height = New-Object Windows.GridLength(132)
        $CodexQuotaPanel.Visibility = 'Collapsed'
        $ProviderMetricPanel.Visibility = 'Visible'
        if ($script:IsExpanded) {
            $targetExpandedHeight = Get-ExpandedHeightForSnapshot -Snapshot $Snapshot
            if ([Math]::Abs($window.Height - $targetExpandedHeight) -gt 0.01) {
                $placement = Get-ExpandedPlacement -TargetHeight $targetExpandedHeight
                $window.Left = $placement.Left
                $window.Top = $placement.Top
                $window.Height = $targetExpandedHeight
            }
        }
        $UsageTrendTitle.Text = '使用趋势'
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

        # The top two cards report money actually consumed, derived from real
        # balance movements in Core\SpendLedger.ps1, instead of the local-log
        # estimate. Element names below are historical: PrimaryMetricValue holds
        # today's spend and TodayTokens holds this month's.
        $spendSummary = Get-SpendSummary `
            -Ledger (Read-SpendLedger) `
            -ProviderId 'DeepSeek' `
            -Now $observedAt
        $spendCurrency = $spendSummary.Unit
        $todaySpendText = '--'
        $todaySpendHint = '等待余额采样'
        if ($spendSummary.HasToday) {
            $todaySpendText = Format-CurrencyAmount `
                -Amount $spendSummary.TodaySpent `
                -Currency $spendCurrency
            $todaySpendHint = if ($spendSummary.TodayComplete) {
                '按余额变化统计'
            } else { '按余额变化 · 含断档' }
        }
        $monthSpendText = '--'
        $monthSpendHint = '等待余额采样'
        if ($spendSummary.CoverageDays -gt 0) {
            $monthSpendText = Format-CurrencyAmount `
                -Amount $spendSummary.MonthSpent `
                -Currency $spendCurrency
            $coverageText = if ($spendSummary.CoverageComplete) {
                '本月 1 日以来'
            } else {
                '自 {0} 起统计' -f (
                    Format-SpendLedgerDateLabel `
                        -Date $spendSummary.CoverageStartDate
                )
            }
            $monthSpendHint = if ($spendSummary.MonthComplete) {
                $coverageText
            } else { '{0} · 含断档' -f $coverageText }
        }

        $MetricOneTitle.Text = '今日花费'
        $PrimaryMetricValue.Text = $todaySpendText
        $PrimaryMetricHint.Text = $todaySpendHint
        $MetricTwoTitle.Text = '本月花费'
        $TodayTokens.Text = $monthSpendText
        $MetricTwoHint.Text = $monthSpendHint
        $MetricThreeTitle.Text = '今日 TOKEN'
        $LastTurnTokens.Text = Format-CompactNumber $Snapshot.TodayTokens
        $ContextText.Text = 'Claude Code 本机累计'
        $MetricFourTitle.Text = '本月累计 TOKEN'
        $CacheHit.Text = Format-CompactNumber $Snapshot.MonthlyTokens
        $CacheTokenText.Text = '当月本机去重累计'
        # The exact balance used to live in the first card; keep it visible here
        # rather than losing it, since the header only shows one decimal.
        $BreakdownTitle.Text = if ($Snapshot.Available) {
            '余额 {0}' -f $Snapshot.ResetDate
        } else { '余额构成' }
        $SecondaryMetricTitle.Text = '预算基准'
        $ResetCount.Text = $Snapshot.ResetCount
        $TokenBreakdown.Text = '赠金 {0}  ·  充值 {1}' -f `
            (Format-CurrencyAmount -Amount $Snapshot.GrantedBalance -Currency $Snapshot.Currency), `
            (Format-CurrencyAmount -Amount $Snapshot.ToppedUpBalance -Currency $Snapshot.Currency)
        Set-Progress -Percent $Snapshot.RemainingPercent -Available $Snapshot.HasProgress
    }
    else {
        $ProviderMetricPanel.Visibility = 'Collapsed'
        $isWeeklyOnlyPlan = $codexPrimaryQuota.Period -eq 'Weekly'
        $CodexQuotaPanel.Visibility = if ($isWeeklyOnlyPlan) {
            'Collapsed'
        } else { 'Visible' }
        $QuotaMetricRow.Height = New-Object Windows.GridLength(
            $(if ($isWeeklyOnlyPlan) { 0 } else { 48 })
        )
        # The header already renders the plan's primary quota and progress.
        # Plus keeps only the supplemental weekly quota here; Pro needs no
        # secondary quota card because weekly is already its primary quota.
        $FiveHourQuotaBand.Visibility = 'Collapsed'
        $QuotaDivider.Visibility = 'Collapsed'
        $WeeklyQuotaBand.VerticalAlignment = 'Stretch'
        $WeeklyQuotaBand.Height = [double]::NaN
        $FiveHourQuotaRow.Height = New-Object Windows.GridLength(0)
        $QuotaDividerRow.Height = New-Object Windows.GridLength(0)
        $WeeklyQuotaRow.Height = New-Object Windows.GridLength(
            1,
            [Windows.GridUnitType]::Star
        )
        if ($script:IsExpanded) {
            $targetExpandedHeight = Get-ExpandedHeightForSnapshot -Snapshot $Snapshot
            if ([Math]::Abs($window.Height - $targetExpandedHeight) -gt 0.01) {
                $placement = Get-ExpandedPlacement -TargetHeight $targetExpandedHeight
                $window.Left = $placement.Left
                $window.Top = $placement.Top
                $window.Height = $targetExpandedHeight
            }
        }
        $UsageTrendTitle.Text = "$($codexPrimaryQuota.Label)额度趋势"
        $weeklyAvailable = (
            $Snapshot.PSObject.Properties['WeeklyAvailable'] -and
            [bool]$Snapshot.WeeklyAvailable
        )
        Set-CodexQuotaBand `
            -Available $codexFiveHourAvailable `
            -UsedPercent ([double](Get-ObjectPropertyValue `
                -Object $Snapshot `
                -Name 'FiveHourUsedPercent' `
                -Default 0)) `
            -RemainingPercent $codexFiveHourRemaining `
            -ResetDate ([string](Get-ObjectPropertyValue `
                -Object $Snapshot `
                -Name 'FiveHourResetDate' `
                -Default '暂无')) `
            -ResetCountdown ([string](Get-ObjectPropertyValue `
                -Object $Snapshot `
                -Name 'FiveHourResetCountdown' `
                -Default '等待 5 小时额度数据')) `
            -UnknownText '等待 5 小时额度数据' `
            -Label '5 小时' `
            -Band $FiveHourQuotaBand `
            -ResetText $FiveHourResetText `
            -UsedValue $FiveHourUsedValue `
            -RemainingValue $FiveHourRemainingValue `
            -RemainingColumn $FiveHourRemainingColumn `
            -UsedColumn $FiveHourUsedColumn
        Set-CodexQuotaBand `
            -Available $weeklyAvailable `
            -UsedPercent ([double](Get-ObjectPropertyValue `
                -Object $Snapshot `
                -Name 'WeeklyUsedPercent' `
                -Default 0)) `
            -RemainingPercent ([double](Get-ObjectPropertyValue `
                -Object $Snapshot `
                -Name 'WeeklyRemainingPercent' `
                -Default 0)) `
            -ResetDate ([string](Get-ObjectPropertyValue `
                -Object $Snapshot `
                -Name 'WeeklyResetDate' `
                -Default '暂无')) `
            -ResetCountdown ([string](Get-ObjectPropertyValue `
                -Object $Snapshot `
                -Name 'WeeklyResetCountdown' `
                -Default '等待每周额度数据')) `
            -UnknownText '等待每周额度数据' `
            -Label '每周' `
            -Band $WeeklyQuotaBand `
            -ResetText $WeeklyResetText `
            -UsedValue $WeeklyUsedValue `
            -RemainingValue $WeeklyRemainingValue `
            -RemainingColumn $WeeklyRemainingColumn `
            -UsedColumn $WeeklyUsedColumn
        $CompactPrefix.Text = ''
        $RemainingValue.Text = if ($codexQuotaBinding.Available) {
            [string][int]$codexQuotaBinding.RemainingPercent
        } else { '未知' }
        $CompactSuffix.Text = if ($codexQuotaBinding.Available) { '%' } else { '' }
        $BreakdownTitle.Text = '今日 TOKEN'
        $TokenBreakdown.Text = '{0} · 输出 {1}' -f `
            (Format-CompactNumber $Snapshot.TodayTokens), `
            (Format-CompactNumber $Snapshot.TodayOutputTokens)
        $SecondaryMetricTitle.Text = '今日缓存'
        $ResetCount.Text = '{0} · 命中 {1:0.0}%' -f `
            (Format-CompactNumber $Snapshot.TodayCachedTokens), `
            [double]$Snapshot.TodayCacheHitPercent
        Set-Progress `
            -Percent $codexQuotaBinding.RemainingPercent `
            -Available $codexQuotaBinding.Available
        $primaryQuotaToolTip = if ($codexQuotaBinding.Available) {
            '{0}余额 {1:0}% · 已使用 {2:0}%' -f `
                $codexQuotaBinding.Label,
                $codexQuotaBinding.RemainingPercent,
                $codexQuotaBinding.UsedPercent
        } else { "$($codexQuotaBinding.Label)额度未知" }
        if ($codexQuotaBinding.IsWeeklyExhausted -and $codexFiveHourAvailable) {
            # Keep the five-hour figure reachable: it is still the number the
            # rest of the panel reports, it just no longer gates usage.
            $primaryQuotaToolTip += ' · 5 小时窗口仍余 {0:0}%' -f `
                $codexFiveHourRemaining
        }
        $ProgressTrack.ToolTip = $primaryQuotaToolTip
        $UltraProgressTrack.ToolTip = $primaryQuotaToolTip
    }

    if ($script:TrayNotifyIcon) {
        $script:TrayNotifyIcon.Text = if ($Snapshot.ProviderId -eq 'DeepSeek') {
            if ($Snapshot.Available) {
                'DeepSeek 余额 {0} · 单击打开详情' -f $Snapshot.ResetDate
            } else {
                'DeepSeek 等待配置 · 单击打开详情'
            }
        } else {
            $providerDisplayName = if ($Snapshot.ProviderId -eq 'Kimi') {
                'Kimi Code'
            } else { 'Codex' }
            if ($codexQuotaBinding.Available) {
                '{0} {1}余量 {2}% · 单击打开详情' -f `
                    $providerDisplayName,
                    $codexQuotaBinding.Label,
                    [int]$codexQuotaBinding.RemainingPercent
            } else {
                "$providerDisplayName $($codexQuotaBinding.Label)余量未知 · 单击打开详情"
            }
        }
    }

    if ($DisplayOnly) {
        if ($script:LastUsageInsights) {
            Update-UsageInsightView -Insights $script:LastUsageInsights
        }
        return
    }

    if ($isDiagnosticRun) {
        [void]$script:PendingUsageHistoryUpdates.Enqueue([pscustomobject]@{
            Snapshot = $Snapshot
            ObservedAt = $observedAt
            ObservationContext = $ObservationContext
        })
        Invoke-PendingUsageHistoryUpdate
    }
    else {
        Queue-UsageHistoryUpdate `
            -Snapshot $Snapshot `
            -ObservedAt $observedAt `
            -ObservationContext $ObservationContext
    }
    Reset-RefreshCountdown
}
