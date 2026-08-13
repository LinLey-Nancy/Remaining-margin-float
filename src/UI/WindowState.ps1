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
    $visualPoint = if ($script:EdgeDockSide -eq 'Left') {
        $edgeElement.PointToScreen((New-Object Windows.Point(0, 0)))
    }
    else {
        $edgeElement.PointToScreen(
            (New-Object Windows.Point($edgeElement.ActualWidth, 0))
        )
    }
    $screenEdge = if ($script:EdgeDockSide -eq 'Left') {
        [double]$screenArea.Left
    }
    else {
        [double]$screenArea.Right
    }
    $pixelCorrection = [int][Math]::Round(
        $screenEdge - $visualPoint.X,
        [MidpointRounding]::AwayFromZero
    )

    if ($pixelCorrection -ne 0) {
        $windowRect = New-Object RemainingMarginNativeWindow+RECT
        if (-not [RemainingMarginNativeWindow]::GetWindowRect(
            $helper.Handle,
            [ref]$windowRect
        )) {
            return $null
        }
        $positionOnly = 0x0001 -bor 0x0004 -bor 0x0010 -bor 0x0200
        if (-not [RemainingMarginNativeWindow]::SetWindowPos(
            $helper.Handle,
            [IntPtr]::Zero,
            $windowRect.Left + $pixelCorrection,
            $windowRect.Top,
            0,
            0,
            $positionOnly
        )) {
            return $null
        }
        $window.UpdateLayout()
    }

    $alignedPoint = if ($script:EdgeDockSide -eq 'Left') {
        $edgeElement.PointToScreen((New-Object Windows.Point(0, 0))).X
    }
    else {
        $edgeElement.PointToScreen(
            (New-Object Windows.Point($edgeElement.ActualWidth, 0))
        ).X
    }
    return [pscustomobject]@{
        Side = $script:EdgeDockSide
        Revealed = $script:IsEdgeRevealed
        ScreenEdge = $screenEdge
        VisualEdge = $alignedPoint
        GapPixels = [Math]::Abs($screenEdge - $alignedPoint)
        CorrectionPixels = $pixelCorrection
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
        $leftAnimation = New-DoubleAnimation `
            -To $targetLeft `
            -Milliseconds $duration `
            -EaseOut:$Revealed `
            -EaseIn:(-not $Revealed)
        $leftAnimation.From = $currentLeft
        $leftAnimation.FillBehavior = [Windows.Media.Animation.FillBehavior]::Stop
        $leftAnimation.Add_Completed((New-RmfEventHandler -Kind Event -Callback {
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
        [switch]$Immediate,
        [switch]$DeferEdgeDock
    )

    if ($Expanded -and -not $script:IsExpanded) {
        if ($script:EdgeDockSide -and -not $DeferEdgeDock) {
            Set-EdgeDockReveal -Revealed $true -Immediate
        }
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
        $RemainingSummaryPanel.HorizontalAlignment =
            [Windows.HorizontalAlignment]::Left
        $RemainingNumberPanel.HorizontalAlignment =
            [Windows.HorizontalAlignment]::Left
        $RemainingValue.FontSize = 28
        $RemainingValue.LineHeight = 31
        $CompactPrefix.FontSize = 10
        $CompactSuffix.FontSize = 10
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

function Set-TrendChart {
    param(
        $Canvas,
        $Polyline,
        $Area,
        $StartMarker,
        $EndMarker,
        [object[]]$Samples,
        [double]$Hours,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    $Polyline.Points.Clear()
    $Area.Points.Clear()
    $StartMarker.Visibility = 'Collapsed'
    $EndMarker.Visibility = 'Collapsed'
    $displaySamples = @(
        Select-TrendDisplaySamples -Samples $Samples -MaximumPoints 48
    )
    if ($displaySamples.Count -lt 2) { return }

    $values = @($displaySamples | ForEach-Object {
        [double]$_.RemainingValue
    })
    $minimum = ($values | Measure-Object -Minimum).Minimum
    $maximum = ($values | Measure-Object -Maximum).Maximum
    $range = [double]$maximum - [double]$minimum
    $minimumRange = if ($displaySamples[0].MetricType -eq 'Percent') {
        10.0
    } else {
        [Math]::Max(0.01, [double]$maximum * 0.05)
    }
    if ($range -lt $minimumRange) {
        $center = ([double]$minimum + [double]$maximum) / 2
        $minimum = $center - ($minimumRange / 2)
        $maximum = $center + ($minimumRange / 2)
        if ($displaySamples[0].MetricType -eq 'Percent') {
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
    $cutoff = $Now.ToUniversalTime().AddHours(-$Hours)
    $totalSeconds = [Math]::Max(1, $Hours * 3600)
    $points = New-Object Collections.Generic.List[Windows.Point]
    for ($index = 0; $index -lt $displaySamples.Count; $index++) {
        $elapsedSeconds = (
            ([DateTimeOffset]$displaySamples[$index].ObservedAtUtc) - $cutoff
        ).TotalSeconds
        $x = [Math]::Max(
            0.0,
            [Math]::Min($width, ($elapsedSeconds / $totalSeconds) * $width)
        )
        $y = 2 + (
            $plotHeight - (
                (
                    [double]$displaySamples[$index].RemainingValue -
                    [double]$minimum
                ) / $range * $plotHeight
            )
        )
        $point = New-Object Windows.Point($x, $y)
        $points.Add($point)
        $Polyline.Points.Add($point)
    }

    $Area.Points.Add((New-Object Windows.Point($points[0].X, $height)))
    foreach ($point in $points) { $Area.Points.Add($point) }
    $Area.Points.Add((New-Object Windows.Point($points[-1].X, $height)))

    $StartMarker.Visibility = 'Visible'
    $EndMarker.Visibility = 'Visible'
    [Windows.Controls.Canvas]::SetLeft(
        $StartMarker,
        $points[0].X - ($StartMarker.Width / 2)
    )
    [Windows.Controls.Canvas]::SetTop(
        $StartMarker,
        $points[0].Y - ($StartMarker.Height / 2)
    )
    [Windows.Controls.Canvas]::SetLeft(
        $EndMarker,
        $points[-1].X - ($EndMarker.Width / 2)
    )
    [Windows.Controls.Canvas]::SetTop(
        $EndMarker,
        $points[-1].Y - ($EndMarker.Height / 2)
    )
}

function Update-UsageInsightView {
    param($Insights)

    if (-not $Insights -or -not $Insights.CurrentSample) {
        $Trend24Text.Text = '暂无数据'
        $Trend7Text.Text = '暂无数据'
        $Trend24MetaText.Text = '等待更多样本'
        $Trend7MetaText.Text = '等待更多样本'
        $PredictionText.Text = '积累 30 分钟后预测'
        $Trend24Line.Points.Clear()
        $Trend7Line.Points.Clear()
        $Trend24Area.Points.Clear()
        $Trend7Area.Points.Clear()
        $Trend24StartMarker.Visibility = 'Collapsed'
        $Trend24EndMarker.Visibility = 'Collapsed'
        $Trend7StartMarker.Visibility = 'Collapsed'
        $Trend7EndMarker.Visibility = 'Collapsed'
        $RapidDropText.Text = if ($script:RapidDropAlertsEnabled) {
            '快速下降监控 · 正在积累样本'
        } else {
            '1 小时内下降 · 正在积累样本'
        }
        return
    }

    $Trend24Text.Text = Format-UsageTrendChange `
        -Trend $Insights.Trend24Hours `
        -CurrentSample $Insights.CurrentSample
    $Trend7Text.Text = Format-UsageTrendChange `
        -Trend $Insights.Trend7Days `
        -CurrentSample $Insights.CurrentSample
    $Trend24MetaText.Text = if ($Insights.Trend24Hours.ComparisonAvailable) {
        '{0} 个样本 · {1} → {2}' -f
            $Insights.Trend24Hours.SampleCount,
            (Format-UsageTrendValue `
                -Value $Insights.Trend24Hours.StartValue `
                -CurrentSample $Insights.CurrentSample),
            (Format-UsageTrendValue `
                -Value $Insights.Trend24Hours.EndValue `
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
        -Canvas $Trend24Canvas `
        -Polyline $Trend24Line `
        -Area $Trend24Area `
        -StartMarker $Trend24StartMarker `
        -EndMarker $Trend24EndMarker `
        -Samples $Insights.Trend24Hours.Samples `
        -Hours 24
    Set-TrendChart `
        -Canvas $Trend7Canvas `
        -Polyline $Trend7Line `
        -Area $Trend7Area `
        -StartMarker $Trend7StartMarker `
        -EndMarker $Trend7EndMarker `
        -Samples $Insights.Trend7Days.Samples `
        -Hours (24 * 7)

    $rapidDrop = $Insights.RapidDrop
    if (-not $script:RapidDropAlertsEnabled) {
        $RapidDropStatusDot.Fill = New-Object Windows.Media.SolidColorBrush(
            [Windows.Media.ColorConverter]::ConvertFromString('#9AA09B')
        )
        $RapidDropText.Text = if ($rapidDrop -and $rapidDrop.Available) {
            $rapidDrop.Summary
        }
        else {
            '1 小时内下降 · ' + $(if ($rapidDrop) {
                $rapidDrop.Summary
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
            $rapidDrop.Summary
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
        $RapidDropText.Text = '检测到快速下降 · ' + $rapidDrop.Summary
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
            $rapidDrop.Summary,
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
        if ($channel -ne 'CodexOfficialCache') {
            $summaryOverride = '等待官方同步，本地快照不计入快速下降'
        }
    }
    elseif ($channel -eq 'CodexOfficialCache') {
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

    $rapidDrop = Measure-RapidUsageDrop `
        -Samples @($script:UsageSyncSession.RapidSamples) `
        -Snapshot $Snapshot `
        -WindowMinutes (Get-RapidDropDisplayWindowMinutes) `
        -CodexPercent $script:CodexRapidDropPercent `
        -DeepSeekMode $script:DeepSeekRapidDropMode `
        -DeepSeekPercent $script:DeepSeekRapidDropPercent `
        -DeepSeekAmount $script:DeepSeekRapidDropAmount `
        -Now $ObservedAt
    if ($excludeCurrentSample) {
        $rapidDrop.Available = $false
        $rapidDrop.IsRapid = $false
    }
    if (-not [string]::IsNullOrWhiteSpace($summaryOverride)) {
        $rapidDrop.Summary = $summaryOverride
    }
    $Insights.RapidDrop = $rapidDrop
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
    $remainingText = if ($Snapshot -and [bool]$Snapshot.HasProgress) {
        '余量 {0:0.#}%' -f [double]$Snapshot.RemainingPercent
    }
    else {
        '余量未知'
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
        $title = 'Codex 本地余量快照'
    }
    else {
        if ($script:UsageSyncSession.OfficialNotificationShown) { return $false }
        $script:UsageSyncSession.OfficialNotificationShown = $true
        $title = 'Codex 官方余量已同步'
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

function Get-LowRemainingAlertMenuText {
    return '低余量提醒（≤{0:0}%）' -f $script:LowRemainingThreshold
}

function Get-UsageAlertSettingsMenuText {
    return '提醒设置（快降 {0} 分钟）…' -f $script:RapidDropWindowMinutes
}

function Sync-LowAlertMenuState {
    $menuText = Get-LowRemainingAlertMenuText
    if ($script:LowAlertsMenuItem) {
        $script:LowAlertsMenuItem.IsChecked = $script:LowRemainingAlertsEnabled
        $script:LowAlertsMenuItem.Header = $menuText
    }
    if ($script:TrayLowAlertsItem) {
        $script:TrayLowAlertsItem.Checked = $script:LowRemainingAlertsEnabled
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

    $script:LowRemainingAlertsEnabled = $Enabled
    if (-not $Enabled) {
        $script:LowAlertActive = @{}
    }
    Sync-LowAlertMenuState
    Save-Settings
}

function Refresh-RapidDropStatusView {
    if (-not $script:LastSnapshot -or -not $script:LastUsageInsights) {
        return
    }

    $script:LastUsageInsights.RapidDrop = Measure-RapidUsageDrop `
        -Samples @($script:UsageSyncSession.RapidSamples) `
        -Snapshot $script:LastSnapshot `
        -WindowMinutes (Get-RapidDropDisplayWindowMinutes) `
        -CodexPercent $script:CodexRapidDropPercent `
        -DeepSeekMode $script:DeepSeekRapidDropMode `
        -DeepSeekPercent $script:DeepSeekRapidDropPercent `
        -DeepSeekAmount $script:DeepSeekRapidDropAmount
    Update-UsageInsightView -Insights $script:LastUsageInsights
}

function Set-UsageAlertSettings {
    param(
        [bool]$LowAlertsEnabled,
        $LowThreshold,
        [bool]$RapidAlertsEnabled,
        $WindowMinutes,
        $CodexPercent,
        [ValidateSet('Percent', 'Amount')]
        [string]$DeepSeekMode,
        $DeepSeekPercent,
        $DeepSeekAmount
    )

    $validatedLowThreshold = ConvertTo-LowRemainingThreshold `
        -Value $LowThreshold `
        -Strict
    $validatedWindow = ConvertTo-RapidDropWindowMinutes `
        -Value $WindowMinutes `
        -Strict
    $validatedCodexPercent = ConvertTo-RapidDropPercent `
        -Value $CodexPercent `
        -Strict
    $validatedDeepSeekPercent = ConvertTo-RapidDropPercent `
        -Value $DeepSeekPercent `
        -Strict
    $validatedDeepSeekAmount = ConvertTo-RapidDropAmount `
        -Value $DeepSeekAmount `
        -Strict

    $previousSettings = [pscustomobject]@{
        LowRemainingAlertsEnabled = $script:LowRemainingAlertsEnabled
        LowRemainingThreshold = $script:LowRemainingThreshold
        RapidDropAlertsEnabled = $script:RapidDropAlertsEnabled
        RapidDropWindowMinutes = $script:RapidDropWindowMinutes
        CodexRapidDropPercent = $script:CodexRapidDropPercent
        DeepSeekRapidDropMode = $script:DeepSeekRapidDropMode
        DeepSeekRapidDropPercent = $script:DeepSeekRapidDropPercent
        DeepSeekRapidDropAmount = $script:DeepSeekRapidDropAmount
    }
    $script:LowRemainingAlertsEnabled = $LowAlertsEnabled
    $script:LowRemainingThreshold = $validatedLowThreshold
    $script:RapidDropAlertsEnabled = $RapidAlertsEnabled
    $script:RapidDropWindowMinutes = $validatedWindow
    $script:CodexRapidDropPercent = $validatedCodexPercent
    $script:DeepSeekRapidDropMode = $DeepSeekMode
    $script:DeepSeekRapidDropPercent = $validatedDeepSeekPercent
    $script:DeepSeekRapidDropAmount = $validatedDeepSeekAmount
    Sync-LowAlertMenuState
    try {
        Save-Settings -ThrowOnError
    }
    catch {
        $script:LowRemainingAlertsEnabled =
            $previousSettings.LowRemainingAlertsEnabled
        $script:LowRemainingThreshold =
            $previousSettings.LowRemainingThreshold
        $script:RapidDropAlertsEnabled =
            $previousSettings.RapidDropAlertsEnabled
        $script:RapidDropWindowMinutes =
            $previousSettings.RapidDropWindowMinutes
        $script:CodexRapidDropPercent =
            $previousSettings.CodexRapidDropPercent
        $script:DeepSeekRapidDropMode =
            $previousSettings.DeepSeekRapidDropMode
        $script:DeepSeekRapidDropPercent =
            $previousSettings.DeepSeekRapidDropPercent
        $script:DeepSeekRapidDropAmount =
            $previousSettings.DeepSeekRapidDropAmount
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
        Height="540"
        ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner"
        ShowInTaskbar="False"
        Background="#FCFBF8"
        FontFamily="Microsoft YaHei UI">
    <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="20"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="12"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="20"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="12"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="12"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="12"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="38"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0">
            <TextBlock Text="使用提醒"
                       FontSize="19" FontWeight="SemiBold" Foreground="#343A35"/>
            <TextBlock Margin="0,5,0,0"
                       Text="低余量和短时间快速下降分别判断，触发后通过 Windows 通知提醒。"
                       FontSize="10.5" Foreground="#667069"/>
        </StackPanel>

        <CheckBox x:Name="LowAlertsEnabledBox"
                  Grid.Row="2"
                  Content="启用低余量提醒"
                  FontSize="12"
                  FontWeight="SemiBold"
                  Foreground="#3B433E"/>
        <Grid Grid.Row="4">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="150"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="45"/>
            </Grid.ColumnDefinitions>
            <TextBlock Text="余量低于"
                       VerticalAlignment="Center"
                       FontSize="11"
                       Foreground="#59635C"/>
            <TextBox x:Name="ThresholdBox" Grid.Column="1" Height="34"
                      Padding="9,6" BorderBrush="#D8DDD7" Background="White"
                      AutomationProperties.Name="低余量提醒阈值"/>
            <TextBlock Grid.Column="2" Text="%" Margin="10,7,0,0"
                       FontSize="12" Foreground="#4E5750"/>
        </Grid>

        <Border Grid.Row="5"
                Height="1"
                VerticalAlignment="Center"
                Background="#E2E5E0"/>

        <CheckBox x:Name="RapidAlertsEnabledBox"
                  Grid.Row="6"
                  Content="启用快速下降提醒"
                  FontSize="12"
                  FontWeight="SemiBold"
                  Foreground="#3B433E"/>

        <Grid Grid.Row="8">
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

        <Grid Grid.Row="10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="150"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="45"/>
            </Grid.ColumnDefinitions>
            <TextBlock Text="Codex 下降"
                       VerticalAlignment="Center"
                       FontSize="11"
                       Foreground="#59635C"/>
            <TextBox x:Name="CodexDropBox" Grid.Column="1" Height="34"
                     Padding="9,6" BorderBrush="#D8DDD7" Background="White"
                     AutomationProperties.Name="Codex 快速下降阈值"/>
            <TextBlock Grid.Column="2" Text="百分点" Margin="10,7,0,0"
                       FontSize="10" Foreground="#4E5750"/>
        </Grid>

        <Grid Grid.Row="12">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="150"/>
                <ColumnDefinition Width="112"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="45"/>
            </Grid.ColumnDefinitions>
            <TextBlock Text="DeepSeek 下降"
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

        <StackPanel Grid.Row="13" Margin="0,10,0,0">
            <TextBlock FontSize="9.5"
                       Foreground="#7B847D"
                       TextWrapping="Wrap"
                       Text="时间范围可设置 5–1440 分钟。DeepSeek 百分比模式需要先设置预算基准；金额模式直接比较账户余额。"/>
            <TextBlock x:Name="ErrorText" Margin="0,8,0,0"
                    Foreground="#A65B52" FontSize="11" TextWrapping="Wrap"/>
        </StackPanel>

        <Grid Grid.Row="14">
            <Button Width="82" Height="34" HorizontalAlignment="Right"
                    Margin="0,0,92,0" Content="取消" IsCancel="True"/>
            <Button x:Name="SaveButton" Width="82" Height="34"
                    HorizontalAlignment="Right" Content="保存" IsDefault="True"
                    Background="#E9F0EA" BorderBrush="#BFCDBF"
                    Foreground="#344A3B"/>
        </Grid>
    </Grid>
</Window>
'@
    $dialogReader = New-Object System.Xml.XmlNodeReader $dialogXaml
    $dialog = [Windows.Markup.XamlReader]::Load($dialogReader)
    return $dialog
}

function Show-LowRemainingAlertSettings {
    $dialog = New-LowRemainingAlertSettingsDialog
    $dialog.Owner = $window
    $lowEnabledBox = $dialog.FindName('LowAlertsEnabledBox')
    $thresholdBox = $dialog.FindName('ThresholdBox')
    $rapidEnabledBox = $dialog.FindName('RapidAlertsEnabledBox')
    $windowBox = $dialog.FindName('WindowBox')
    $codexDropBox = $dialog.FindName('CodexDropBox')
    $deepSeekModeBox = $dialog.FindName('DeepSeekModeBox')
    $deepSeekDropBox = $dialog.FindName('DeepSeekDropBox')
    $deepSeekUnitText = $dialog.FindName('DeepSeekUnitText')
    $errorText = $dialog.FindName('ErrorText')
    $saveButton = $dialog.FindName('SaveButton')
    $lowEnabledBox.IsChecked = $script:LowRemainingAlertsEnabled
    $thresholdBox.Text = $script:LowRemainingThreshold.ToString(
        '0',
        [Globalization.CultureInfo]::CurrentCulture
    )
    $rapidEnabledBox.IsChecked = $script:RapidDropAlertsEnabled
    $windowBox.Text = [string]$script:RapidDropWindowMinutes
    $codexDropBox.Text = $script:CodexRapidDropPercent.ToString(
        '0.#',
        [Globalization.CultureInfo]::CurrentCulture
    )
    $deepSeekModeBox.SelectedIndex = if (
        $script:DeepSeekRapidDropMode -eq 'Amount'
    ) { 1 } else { 0 }
    $deepSeekDropBox.Text = if ($script:DeepSeekRapidDropMode -eq 'Amount') {
        $script:DeepSeekRapidDropAmount.ToString(
            '0.##',
            [Globalization.CultureInfo]::CurrentCulture
        )
    } else {
        $script:DeepSeekRapidDropPercent.ToString(
            '0.#',
            [Globalization.CultureInfo]::CurrentCulture
        )
    }
    $deepSeekUnitText.Text = if ($script:DeepSeekRapidDropMode -eq 'Amount') {
        '金额'
    } else {
        '百分点'
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
            $deepSeekMode = [string]$deepSeekModeBox.SelectedItem.Tag
            $deepSeekPercent = if ($deepSeekMode -eq 'Percent') {
                $deepSeekDropBox.Text
            } else {
                $script:DeepSeekRapidDropPercent
            }
            $deepSeekAmount = if ($deepSeekMode -eq 'Amount') {
                $deepSeekDropBox.Text
            } else {
                $script:DeepSeekRapidDropAmount
            }
            [void](Set-UsageAlertSettings `
                -LowAlertsEnabled ([bool]$lowEnabledBox.IsChecked) `
                -LowThreshold $thresholdBox.Text `
                -RapidAlertsEnabled ([bool]$rapidEnabledBox.IsChecked) `
                -WindowMinutes $windowBox.Text `
                -CodexPercent $codexDropBox.Text `
                -DeepSeekMode $deepSeekMode `
                -DeepSeekPercent $deepSeekPercent `
                -DeepSeekAmount $deepSeekAmount)
            $dialog.DialogResult = $true
        }
        catch {
            $errorText.Text = $_.Exception.Message
        }
    }))

    return [bool]($dialog.ShowDialog())
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
        -not $Snapshot.Available -or
        -not $Snapshot.HasProgress
    ) {
        return $false
    }

    $providerId = [string]$Snapshot.ProviderId
    $remaining = [double]$Snapshot.RemainingPercent
    if ($remaining -gt $script:LowRemainingThreshold) {
        $script:LowAlertActive[$providerId] = $false
        return $false
    }

    if (
        $script:LowAlertActive.ContainsKey($providerId) -and
        [bool]$script:LowAlertActive[$providerId]
    ) {
        return $false
    }

    $shouldNotify = Test-LowRemainingAlertCondition `
        -Snapshot $Snapshot `
        -PreviousSample $(if ($Insights) { $Insights.PreviousSample } else { $null }) `
        -Threshold $script:LowRemainingThreshold
    if (-not $shouldNotify) {
        $script:LowAlertActive[$providerId] = $true
        return $false
    }

    $title = if ($providerId -eq 'DeepSeek') {
        'DeepSeek 预算余量偏低'
    } else {
        'Codex 余量偏低'
    }
    $message = '当前剩余 {0:0}% · {1}' -f $remaining, $Insights.Forecast.Text
    try {
        $script:TrayNotifyIcon.ShowBalloonTip(
            8000,
            $title,
            $message,
            [System.Windows.Forms.ToolTipIcon]::Warning
        )
        $script:LowAlertActive[$providerId] = $true
        return $true
    }
    catch {
        # Notifications are best-effort and may be disabled by Windows.
        $script:LowAlertActive[$providerId] = $false
        return $false
    }
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
        -not $Insights -or
        -not $Insights.RapidDrop
    ) {
        return $false
    }

    $rapidDrop = $Insights.RapidDrop
    $alertKey = '{0}|{1}|{2}' -f
        $rapidDrop.ProviderId,
        $rapidDrop.MetricType,
        $rapidDrop.Unit
    if (-not $rapidDrop.Available -or -not $rapidDrop.IsRapid) {
        $script:RapidDropAlertActive[$alertKey] = $false
        return $false
    }
    if (
        $script:RapidDropAlertActive.ContainsKey($alertKey) -and
        [bool]$script:RapidDropAlertActive[$alertKey]
    ) {
        return $false
    }
    $title = '{0} 余量快速下降' -f $rapidDrop.ProviderId
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
        return $true
    }
    catch {
        $script:RapidDropAlertActive[$alertKey] = $false
        return $false
    }
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

    Assert-UsageSnapshotContract -Snapshot $Snapshot
    if (-not $DisplayOnly) {
        $script:LastSnapshot = $Snapshot
        if ([bool]$Snapshot.Available) {
            try {
                [void](Save-UsageStateSnapshot `
                    -Snapshot $Snapshot `
                    -Reason $ObservationContext)
                if (Get-Command Set-RuntimeDiagnosticStatus -ErrorAction SilentlyContinue) {
                    Set-RuntimeDiagnosticStatus `
                        -Area 'StateHistory' `
                        -Status 'Healthy' `
                        -Message '完整状态已保存'
                }
            }
            catch {
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
    $WindowLabel.Text = $Snapshot.WindowLabel
    $ExpandedWindowLabel.Text = $Snapshot.WindowLabel
    $DetailsResetDate.Text = $Snapshot.ResetDate
    $DetailsResetCountdown.Text = $Snapshot.ResetCountdown
    $AccountName.Text = $Snapshot.AccountName
    $PlanBadge.Text = $Snapshot.Plan
    $AccountEmail.Text = $Snapshot.AccountEmail
    [void](Set-UsageSnapshotProvenance -Snapshot $Snapshot)
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
        $CompactHit.Padding = New-Object Windows.Thickness(7, 5, 7, 5)
        $CompactProgressRow.Height = New-Object Windows.GridLength(12)
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
        $RemainingValue.Text = if ($Snapshot.HasProgress) {
            [string][int]$Snapshot.RemainingPercent
        } else { '--' }
        $CompactSuffix.Text = if ($Snapshot.HasProgress) { '%' } else { '' }
        $MetricOneTitle.Text = '已用额度'
        $PrimaryMetricValue.Text = if ($Snapshot.HasProgress) {
            '{0:0}%' -f (100 - $Snapshot.RemainingPercent)
        } else { '--' }
        $PrimaryMetricHint.Text = if ($Snapshot.HasProgress) {
            '剩余 {0:0}%' -f $Snapshot.RemainingPercent
        } else { '暂无可用余量快照' }
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
        Set-Progress `
            -Percent $Snapshot.RemainingPercent `
            -Available $Snapshot.HasProgress
    }

    if ($script:TrayNotifyIcon) {
        $script:TrayNotifyIcon.Text = if ($Snapshot.ProviderId -eq 'DeepSeek') {
            if ($Snapshot.Available) {
                'DeepSeek 余额 {0} · 单击打开详情' -f $Snapshot.ResetDate
            } else {
                'DeepSeek 等待配置 · 单击打开详情'
            }
        } else {
            if ($Snapshot.HasProgress) {
                'Codex 余量 {0}% · 单击打开详情' -f [int]$Snapshot.RemainingPercent
            } else {
                'Codex 余量暂不可用 · 单击打开详情'
            }
        }
    }

    if ($DisplayOnly) {
        if ($script:LastUsageInsights) {
            Update-UsageInsightView -Insights $script:LastUsageInsights
        }
        return
    }

    try {
        $skipUsageHistoryPersistence = (
            $ObservationContext -eq 'LocalPreview' -or
            (
                $ObservationContext -eq 'StartupLocal' -and
                $script:CodexOfficialAccessEnabled
            )
        )
        $insights = Update-UsageHistory `
            -Snapshot $Snapshot `
            -RapidDropWindowMinutes $script:RapidDropWindowMinutes `
            -CodexRapidDropPercent $script:CodexRapidDropPercent `
            -DeepSeekRapidDropMode $script:DeepSeekRapidDropMode `
            -DeepSeekRapidDropPercent $script:DeepSeekRapidDropPercent `
            -DeepSeekRapidDropAmount $script:DeepSeekRapidDropAmount `
            -SkipPersistence:$skipUsageHistoryPersistence
        $insights = Set-SessionRapidDropInsight `
            -Snapshot $Snapshot `
            -Insights $insights `
            -ObservationContext $ObservationContext
        $script:LastUsageInsights = $insights
        Update-UsageInsightView -Insights $insights
        if ($ObservationContext -in @('StartupLocal', 'StartupOfficial')) {
            [void](Invoke-StartupUsageSnapshotNotification `
                -Snapshot $Snapshot `
                -ObservationContext $ObservationContext)
        }
        elseif ($ObservationContext -eq 'Normal') {
            $lowAlertShown = Invoke-LowRemainingAlert `
                -Snapshot $Snapshot `
                -Insights $insights
            if (-not $lowAlertShown) {
                [void](Invoke-RapidDropAlert `
                    -Snapshot $Snapshot `
                    -Insights $insights)
            }
        }
    }
    catch {
        $script:LastUsageHistoryError = $_.Exception.Message
        if (Get-Command Set-RuntimeDiagnosticStatus -ErrorAction SilentlyContinue) {
            Set-RuntimeDiagnosticStatus `
                -Area 'History' `
                -Status 'Error' `
                -Message $_.Exception.Message
        }
        $Trend24Text.Text = '24 小时：暂不可用'
        $Trend7Text.Text = '7 天：暂不可用'
        $Trend24MetaText.Text = '历史记录读取失败'
        $Trend7MetaText.Text = '历史记录读取失败'
        $Trend24Line.Points.Clear()
        $Trend24Area.Points.Clear()
        $Trend7Line.Points.Clear()
        $Trend7Area.Points.Clear()
        $Trend24StartMarker.Visibility = 'Collapsed'
        $Trend24EndMarker.Visibility = 'Collapsed'
        $Trend7StartMarker.Visibility = 'Collapsed'
        $Trend7EndMarker.Visibility = 'Collapsed'
        $PredictionText.Text = '趋势暂不可用'
        $RapidDropStatusDot.Fill = New-Object Windows.Media.SolidColorBrush(
            [Windows.Media.ColorConverter]::ConvertFromString('#9A765E')
        )
        $RapidDropText.Text = '快速下降监控 · 历史记录暂不可用'
    }
    Reset-RefreshCountdown
}
