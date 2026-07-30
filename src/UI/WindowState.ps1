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
        Set-EdgeDockReveal -Revealed $script:IsEdgeRevealed -Immediate
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
        $UltraDepletedMask.Background = [Windows.SystemColors]::WindowBrush
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
            [Windows.Media.ColorConverter]::ConvertFromString('#BCEFEFEA')
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
            [Windows.Media.ColorConverter]::ConvertFromString('#A6F1F2EF')
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

function Set-TrendPolyline {
    param(
        $Polyline,
        [object[]]$Samples
    )

    $Polyline.Points.Clear()
    $series = @($Samples | Sort-Object ObservedAtUtc)
    if ($series.Count -lt 2) { return }

    $maximumPoints = 36
    $step = [Math]::Max(1, [int][Math]::Ceiling($series.Count / $maximumPoints))
    $displaySamples = @()
    for ($index = 0; $index -lt $series.Count; $index += $step) {
        $displaySamples += $series[$index]
    }
    if ($displaySamples[-1] -ne $series[-1]) {
        $displaySamples += $series[-1]
    }

    $values = @($displaySamples | ForEach-Object { [double]$_.RemainingValue })
    $minimum = ($values | Measure-Object -Minimum).Minimum
    $maximum = ($values | Measure-Object -Maximum).Maximum
    $range = [double]$maximum - [double]$minimum
    $width = 110.0
    $height = 9.0
    $firstObservedAt = [DateTimeOffset]$displaySamples[0].ObservedAtUtc
    $lastObservedAt = [DateTimeOffset]$displaySamples[-1].ObservedAtUtc
    $totalSeconds = ($lastObservedAt - $firstObservedAt).TotalSeconds
    for ($index = 0; $index -lt $displaySamples.Count; $index++) {
        $x = if ($totalSeconds -le 0) {
            0.0
        } else {
            (
                (
                    ([DateTimeOffset]$displaySamples[$index].ObservedAtUtc) -
                    $firstObservedAt
                ).TotalSeconds / $totalSeconds
            ) * $width
        }
        $y = if ($range -lt 0.0001) {
            $height / 2
        } else {
            $height - (
                (
                    [double]$displaySamples[$index].RemainingValue -
                    [double]$minimum
                ) / $range * $height
            )
        }
        $Polyline.Points.Add((New-Object Windows.Point($x, $y)))
    }
}

function Update-UsageInsightView {
    param($Insights)

    if (-not $Insights -or -not $Insights.CurrentSample) {
        $Trend24Text.Text = '24H · 暂无数据'
        $Trend7Text.Text = '7D · 暂无数据'
        $PredictionText.Text = '积累 30 分钟后预测'
        $Trend24Line.Points.Clear()
        $Trend7Line.Points.Clear()
        return
    }

    $Trend24Text.Text = '24H · ' + $Insights.Trend24Hours.Summary
    $Trend7Text.Text = '7D · ' + $Insights.Trend7Days.Summary
    $PredictionText.Text = $Insights.Forecast.Text
    $PredictionText.ToolTip = (
        '当前消耗速度 {0:0.###} {1}/小时' -f
        [Math]::Abs([double]$Insights.Forecast.RatePerHour),
        $Insights.CurrentSample.Unit
    )
    Set-TrendPolyline `
        -Polyline $Trend24Line `
        -Samples $Insights.Trend24Hours.Samples
    Set-TrendPolyline `
        -Polyline $Trend7Line `
        -Samples $Insights.Trend7Days.Samples
}

function Get-LowRemainingAlertMenuText {
    return '低余量提醒（≤{0:0}%）' -f $script:LowRemainingThreshold
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

function Set-LowRemainingThreshold {
    param($Threshold)

    $validatedThreshold = ConvertTo-LowRemainingThreshold `
        -Value $Threshold `
        -Strict
    $script:LowRemainingThreshold = $validatedThreshold
    $script:LowAlertActive = @{}
    Sync-LowAlertMenuState
    Save-Settings
    return $validatedThreshold
}

function New-LowRemainingAlertSettingsDialog {
    [xml]$dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="低余量提醒阈值"
        Width="390"
        Height="245"
        ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner"
        ShowInTaskbar="False"
        Background="#FCFBF8"
        FontFamily="Microsoft YaHei UI">
    <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="18"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="38"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="余量降至多少时提醒"
                   FontSize="18" FontWeight="SemiBold" Foreground="#343A35"/>
        <Grid Grid.Row="2">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="34"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="ThresholdBox" Grid.Column="0" Height="34"
                     Padding="9,6" BorderBrush="#D8DDD7" Background="White"
                     AutomationProperties.Name="低余量提醒阈值"/>
            <TextBlock Grid.Column="1" Text="%" Margin="10,7,0,0"
                       FontSize="13" Foreground="#4E5750"/>
        </Grid>
        <TextBlock Grid.Row="3" Margin="0,7,0,0" FontSize="10"
                   Foreground="#7B847D" TextWrapping="Wrap"
                   Text="可设置 1–99 的整数；Codex 与 DeepSeek 共用此阈值。"/>
        <TextBlock x:Name="ErrorText" Grid.Row="4" Margin="0,8,0,0"
                   Foreground="#A65B52" FontSize="11" TextWrapping="Wrap"/>
        <Grid Grid.Row="5">
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
    $thresholdBox = $dialog.FindName('ThresholdBox')
    $errorText = $dialog.FindName('ErrorText')
    $saveButton = $dialog.FindName('SaveButton')
    $thresholdBox.Text = $script:LowRemainingThreshold.ToString(
        '0',
        [Globalization.CultureInfo]::CurrentCulture
    )
    $thresholdBox.SelectAll()

    $saveButton.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
        $errorText.Text = ''
        try {
            [void](Set-LowRemainingThreshold -Threshold $thresholdBox.Text)
            $dialog.DialogResult = $true
        }
        catch {
            $errorText.Text = $_.Exception.Message
            $thresholdBox.Focus() | Out-Null
            $thresholdBox.SelectAll()
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
        return
    }

    $providerId = [string]$Snapshot.ProviderId
    $remaining = [double]$Snapshot.RemainingPercent
    if ($remaining -gt $script:LowRemainingThreshold) {
        $script:LowAlertActive[$providerId] = $false
        return
    }

    if (
        $script:LowAlertActive.ContainsKey($providerId) -and
        [bool]$script:LowAlertActive[$providerId]
    ) {
        return
    }

    $shouldNotify = Test-LowRemainingAlertCondition `
        -Snapshot $Snapshot `
        -PreviousSample $(if ($Insights) { $Insights.PreviousSample } else { $null }) `
        -Threshold $script:LowRemainingThreshold
    $script:LowAlertActive[$providerId] = $true
    if (-not $shouldNotify) { return }

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
    }
    catch {
        # Notifications are best-effort and may be disabled by Windows.
    }
}

function Update-UsageView {
    param($Snapshot)

    Assert-UsageSnapshotContract -Snapshot $Snapshot
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

    try {
        $insights = Update-UsageHistory -Snapshot $Snapshot
        Update-UsageInsightView -Insights $insights
        Invoke-LowRemainingAlert -Snapshot $Snapshot -Insights $insights
    }
    catch {
        $Trend24Text.Text = '24 小时：暂不可用'
        $Trend7Text.Text = '7 天：暂不可用'
        $PredictionText.Text = '趋势暂不可用'
    }
    Reset-RefreshCountdown
}
