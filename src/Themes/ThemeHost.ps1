$script:RmfOriginalBrushes = @{}
foreach ($key in @($window.Resources.Keys)) {
    if ($window.Resources[$key] -is [Windows.Media.SolidColorBrush]) {
        $script:RmfOriginalBrushes[$key] = $window.Resources[$key].Color.ToString()
    }
}
$script:RmfOriginalFonts = New-Object Collections.Generic.List[object]
function Register-RmfThemeFonts {
    param([Windows.DependencyObject]$Element)
    if ($Element -is [Windows.Controls.TextBlock] -or $Element -is [Windows.Controls.Control]) {
        $script:RmfOriginalFonts.Add([pscustomobject]@{ Element = $Element; Font = $Element.FontFamily })
    }
    foreach ($child in [Windows.LogicalTreeHelper]::GetChildren($Element)) {
        if ($child -is [Windows.DependencyObject]) { Register-RmfThemeFonts -Element $child }
    }
}
Register-RmfThemeFonts -Element $window

function Set-RmfThemeBrush {
    param([string]$Key, [string]$Color)
    $brush = $window.Resources[$Key]
    if ($brush -is [Windows.Media.SolidColorBrush] -and -not $brush.IsFrozen) {
        $brush.Color = [Windows.Media.ColorConverter]::ConvertFromString($Color)
    } else {
        $replacement = New-Object Windows.Media.SolidColorBrush(
            [Windows.Media.ColorConverter]::ConvertFromString($Color))
        # ResourceDictionary stores object values without unwrapping PSObject.
        $window.Resources[$Key] = $replacement.PSObject.BaseObject
    }
}

function Apply-RmfThemeDefinition {
    $theme = $script:RmfActiveTheme
    foreach ($key in $script:RmfOriginalBrushes.Keys) {
        Set-RmfThemeBrush -Key $key -Color $script:RmfOriginalBrushes[$key]
    }
    foreach ($property in $theme.colors.PSObject.Properties) {
        if ($window.Resources.Contains($property.Name)) {
            Set-RmfThemeBrush -Key $property.Name -Color $property.Value
        }
    }
    $fixedRoles = @{
        FixedDCDDD8 = 'Track'; FixedDCE1DC = 'Track'; FixedDCE2DC = 'Divider'
        FixedDDE2DC = 'Divider'; FixedE0E5DF = 'Divider'; FixedE1DDD3 = 'BadgeBorder'
        FixedE5E8E3 = 'SummaryBorder'; FixedEEF2ED = 'SurfaceSubtle'
        FixedF1EFEA = 'BadgeSurface'; FixedF5F6F2 = 'SummarySurface'
        Fixed69716C = 'TextSecondary'; Fixed796B53 = 'BadgeText'; FixedFFFFFF = 'Surface'
        FixedF1F3EF = 'ButtonSurface'; FixedE0E3DD = 'ButtonBorder'
        FixedE9EEE9 = 'ButtonHover'; FixedC9D2CA = 'Border'; Fixed46544A = 'TextPrimary'
        Fixed718478 = 'BadgeText'; Fixed96A39A = 'Unknown'; Fixed626965 = 'Track'
    }
    if ($theme.id -ne 'classic') {
        foreach ($key in $fixedRoles.Keys) {
            if ($window.Resources.Contains($key)) {
                Set-RmfThemeBrush -Key $key -Color $theme.colors.($fixedRoles[$key])
            }
        }
        Set-RmfThemeBrush -Key Champagne -Color $theme.colors.BadgeText
        Set-RmfThemeBrush -Key Fixed244F6B58 -Color ('#24' + $theme.colors.BadgeText.Substring(1))
    }
    foreach ($entry in $script:RmfOriginalFonts) {
        $entry.Element.FontFamily = if ($theme.id -eq 'classic' -or $entry.Font.Source -match 'Icons|MDL2') { $entry.Font } else {
            New-Object Windows.Media.FontFamily($theme.typography.textFamily)
        }
    }
    if ($theme.id -ne 'classic') {
        foreach ($element in @($RemainingValue, $ThemeRingNumber, $WeeklyRemainingValue,
            $FiveHourRemainingValue, $PrimaryMetricValue, $TodayTokens, $LastTurnTokens, $CacheHit,
            $ThemeTokenTotal, $ThemeTokenCached)) {
            $element.FontFamily = New-Object Windows.Media.FontFamily($theme.typography.numberFamily)
        }
    }
    foreach ($line in @($Trend5HLine, $Trend7Line)) {
        $line.SetResourceReference([Windows.Shapes.Shape]::StrokeProperty, 'StatusStrong')
    }
    $Surface.CornerRadius = New-Object Windows.CornerRadius($theme.shape.windowRadius)
    $HoverHalo.CornerRadius = New-Object Windows.CornerRadius($theme.shape.windowRadius + 1)
    foreach ($element in @($Trend5HCard, $Trend7Card, $TokenSummaryCard)) {
        $element.CornerRadius = New-Object Windows.CornerRadius($theme.shape.cardRadius)
    }
    foreach ($card in @($Trend5HCard, $Trend7Card)) {
        $card.BorderThickness = New-Object Windows.Thickness(0)
        if ($theme.layout.base -eq 'classic') {
            $card.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'SageSoft')
        } elseif ($theme.layout.base -eq 'paper') {
            $card.Background = [Windows.Media.Brushes]::Transparent
        } else {
            $card.Background = $window.Resources[$(if ($theme.layout.base -eq 'native') { 'Surface' } else { 'SurfaceSubtle' })]
            $card.BorderBrush = $window.Resources['Border']
            $card.BorderThickness = New-Object Windows.Thickness(1)
        }
    }
    $TokenSummaryCard.BorderThickness = New-Object Windows.Thickness($(if ($theme.layout.base -in @('paper','instrument')) {0} else {1}))
    $TokenSummaryCard.Background = if ($theme.layout.base -in @('paper','instrument')) {
        [Windows.Media.Brushes]::Transparent
    } else { $window.Resources['FixedF5F6F2'] }
    $ThemeQuotaCard.CornerRadius = New-Object Windows.CornerRadius($(if ($theme.id -eq 'classic') {12} else {$theme.shape.cardRadius + 3}))
    if ($theme.id -eq 'classic') {
        $ThemeQuotaCard.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'SageSoft')
        $ThemeNotice.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'FixedEEF2ED')
        foreach ($area in @($Trend5HArea, $Trend7Area)) {
            $area.SetResourceReference([Windows.Shapes.Shape]::FillProperty, 'Fixed244F6B58')
        }
        $ThemeWeeklyFill.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'Fixed96A39A')
        $WeeklyRemainingValue.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'TextPrimary')
        $ThemeFiveHourFill.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'Sage')
        $FiveHourRemainingValue.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'StatusStrong')
    }
    $script:CurrentSurfaceBorderColor = $theme.colors.Border
    $Surface.Background = $window.Resources['Surface']
    $Surface.BorderBrush = $window.Resources['Border']
    if ($script:HighContrast) {
        Apply-SystemAccessibilityTheme
        foreach ($key in $fixedRoles.Keys) {
            if ($window.Resources.Contains($key)) {
                $role = $fixedRoles[$key]
                $color = if ($role -match 'Text') { [Windows.SystemColors]::WindowTextColor } else {
                    [Windows.SystemColors]::WindowColor
                }
                Set-RmfThemeBrush -Key $key -Color $color.ToString()
            }
        }
        Set-RmfThemeBrush -Key Fixed244F6B58 -Color '#00000000'
        foreach ($element in @($WeeklyRemainingValue, $FiveHourRemainingValue)) {
            $element.Foreground = [Windows.SystemColors]::WindowTextBrush
        }
        foreach ($element in @($ThemeWeeklyFill, $ThemeFiveHourFill)) {
            $element.Background = [Windows.SystemColors]::HighlightBrush
        }
    }
}

function Update-RmfThemeGauge {
    $remaining = if ($script:RmfThemeProgressAvailable) {
        [Math]::Max(0.0, [Math]::Min(100.0, $script:RmfThemePercent))
    } else { 0.0 }
    $ThemeRailFill.Height = $ThemeRail.Height * $remaining / 100.0
    $ThemeRingNumber.Text = $CompactPrefix.Text + $RemainingValue.Text + $CompactSuffix.Text
    $size = $ThemeRing.Width
    $center = $size / 2.0
    $radius = $center - 3
    $endAngle = $remaining / 100.0 * 2 * [Math]::PI
    $x = $center + $radius * [Math]::Sin($endAngle)
    $y = $center - $radius * [Math]::Cos($endAngle)
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    $data = if ($remaining -le 0) { '' } elseif ($remaining -ge 100) {
        [string]::Format($invariant, 'M {0},3 A {1},{1} 0 1 1 {0},{2} A {1},{1} 0 1 1 {0},3',
            $center, $radius, $size - 3)
    } else {
        [string]::Format($invariant, 'M {0},3 A {1},{1} 0 {2} 1 {3},{4}',
            $center, $radius, [int]($remaining -gt 50), $x, $y)
    }
    $ThemeRingArc.Data = if ($data) { [Windows.Media.Geometry]::Parse($data) } else { $null }
}

function Update-RmfThemeLayout {
    if (-not $script:RmfActiveTheme) { return }
    $theme = $script:RmfActiveTheme
    $expanded = $script:IsExpanded
    $active = $theme.layout.base -ne 'classic' -and -not [string]::IsNullOrWhiteSpace($AccountName.Text)
    $model = Get-RmfThemeViewModel
    $providerId = [string]$model.provider
    $tokenLayout = $active -and $providerId -in @('Codex','Kimi')
    foreach ($child in $TokenSummaryCard.Child.Children) {
        $child.Visibility = if (($child -eq $ThemeTokenGrid) -eq $tokenLayout) { 'Visible' } else { 'Collapsed' }
    }
    $DetailsPanel.RowDefinitions[3].Height = New-Object Windows.GridLength($(if ($tokenLayout) {70} else {52}))
    $ThemeTokenTotal.Text = $model.tokens.total
    $ThemeTokenOutput.Text = '输出 ' + $model.tokens.output
    $ThemeTokenCached.Text = $model.tokens.cached
    $ThemeTokenHit.Text = '命中率 ' + $model.tokens.hitRate
    $ThemeToolbarRow.Height = New-Object Windows.GridLength(0)
    $ThemeHeaderRow.Height = New-Object Windows.GridLength(69)
    $ThemeAccountRow.Height = New-Object Windows.GridLength(46)
    $ThemeToolbar.Visibility = 'Collapsed'
    $ThemeRing.Visibility = 'Collapsed'
    $ThemeRail.Visibility = 'Collapsed'
    $ThemeCompactProvider.Visibility = 'Collapsed'
    $ThemeCompactPeriod.Visibility = 'Collapsed'
    $ThemeHeroLabel.Visibility = 'Collapsed'
    $ThemeHeroReset.Visibility = 'Collapsed'
    $RemainingSummaryPanel.Visibility = 'Visible'
    $RemainingNumberPanel.Visibility = 'Visible'
    $RemainingSummaryPanel.Margin = New-Object Windows.Thickness(0)
    $RemainingNumberPanel.Margin = New-Object Windows.Thickness(0, 1, 0, 0)
    $RemainingSummaryPanel.HorizontalAlignment = if ($expanded) { 'Left' } else { 'Center' }
    $RemainingNumberPanel.HorizontalAlignment = if ($expanded) { 'Left' } else { 'Center' }
    $WindowLabel.HorizontalAlignment = if ($expanded) { 'Left' } else { 'Center' }
    $RemainingValue.FontSize = if ($expanded) { 34 } else { 23 }
    $RemainingValue.LineHeight = if ($expanded) { 37 } else { 26 }
    $CompactPrefix.FontSize = if ($expanded) { 12 } else { 9 }
    $CompactSuffix.FontSize = if ($expanded) { 12 } else { 9 }
    $CompactHit.Padding = if ($expanded) { New-Object Windows.Thickness(9,7,9,2) } else {
        New-Object Windows.Thickness(7,5,7,5)
    }
    $CompactProgressRow.Height = New-Object Windows.GridLength($(if ($expanded) { 23 } else { 12 }))
    $ProgressTrack.Visibility = 'Visible'
    $ProgressTrack.Height = $theme.shape.progressThickness
    $ExpandedWindowLabel.Visibility = if ($expanded) { 'Visible' } else { 'Collapsed' }
    $ResetSummaryPanel.Visibility = if ($expanded -and $providerId -in @('Codex','Kimi')) {
        'Visible'
    } else { 'Collapsed' }
    [Windows.Controls.Grid]::SetRow($CloseButton, $(if ($active -and $expanded) { 0 } else { 1 }))
    if ($theme.id -ne 'classic' -and $theme.layout.base -eq 'classic') {
        $RemainingValue.FontSize = if ($expanded) { $theme.typography.detailsNumberSize } else {
            $theme.typography.compactNumberSize
        }
        $RemainingValue.LineHeight = $RemainingValue.FontSize + 3
        if ($expanded) {
            $extraHeader = [Math]::Ceiling([Math]::Max(0, $RemainingValue.FontSize - 34) * 1.5)
            $ThemeHeaderRow.Height = New-Object Windows.GridLength(69 + $extraHeader)
        }
    }
    if (-not $active) { Update-RmfThemeGauge; return }
    $providerName = switch ($providerId) {
        'Kimi' { 'Kimi Code' }; 'DeepSeek' { 'DeepSeek' }; default { 'Codex' }
    }
    $ThemeProviderButton.Content = $providerName + ' ▾'
    $ThemeCompactProvider.Text = $providerName
    $ThemeCompactProvider.ToolTip = $providerName
    $ThemeCompactPeriod.Text = $WindowLabel.Text
    $ThemeAccountText.Text = $AccountName.Text
    $ThemeAccountText.ToolTip = $AccountName.Text
    $ThemeAccountHint.Text = $AccountEmail.Text
    $ThemeAccountHint.ToolTip = $AccountEmail.Text
    $ThemePlanText.Text = $PlanBadge.Text
    $ThemePlanText.Parent.Visibility = $PlanBadgeContainer.Visibility
    $RemainingValue.FontSize = if ($expanded) { $theme.typography.detailsNumberSize } else {
        $theme.typography.compactNumberSize
    }
    $RemainingValue.LineHeight = $RemainingValue.FontSize + 4
    if ($expanded) {
        $CompactSuffix.FontSize = 20
        $CompactPrefix.FontSize = 20
    }
    if ($expanded) {
        $ThemeToolbar.Visibility = 'Visible'
        $ThemeToolbarRow.Height = New-Object Windows.GridLength(49)
        $ThemeAccountRow.Height = New-Object Windows.GridLength(0)
        $ThemeHeaderRow.Height = New-Object Windows.GridLength(96)
        $ExpandedWindowLabel.Visibility = 'Collapsed'
        $ResetSummaryPanel.Visibility = 'Collapsed'
        $ThemeHeroLabel.Visibility = 'Visible'
        $ThemeHeroLabel.Text = $WindowLabel.Text
        $ThemeHeroLabel.Margin = New-Object Windows.Thickness(112, 10, 10, 0)
        $ThemeHeroReset.Visibility = if ($DetailsResetDate.Text -and $providerId -ne 'DeepSeek') {
            'Visible'
        } else { 'Collapsed' }
        $ThemeHeroReset.Text = $DetailsResetDate.Text + ' · ' + $DetailsResetCountdown.Text
        $ThemeHeroReset.ToolTip = $ThemeHeroReset.Text
        $ThemeHeroReset.Margin = New-Object Windows.Thickness(112, 34, 5, 0)
        $RemainingSummaryPanel.VerticalAlignment = 'Center'
        $RemainingSummaryPanel.Margin = New-Object Windows.Thickness(3,0,0,0)
    } else {
        $CompactHit.Padding = New-Object Windows.Thickness(4,2,4,2)
        $ThemeCompactProvider.Visibility = 'Visible'
        $ThemeCompactProvider.HorizontalAlignment = 'Left'
        $ThemeCompactProvider.Margin = New-Object Windows.Thickness(0)
        $RemainingSummaryPanel.Margin = New-Object Windows.Thickness(0,9,0,0)
    }
    switch ($theme.layout.quotaStyle) {
        'ring' {
            $ProgressTrack.Visibility = 'Collapsed'
            $ThemeRing.Visibility = 'Visible'
            $ThemeRing.Width = if ($expanded) { 76 } else { 44 }
            $ThemeRing.Height = $ThemeRing.Width
            $ThemeRing.HorizontalAlignment = if ($expanded) { 'Left' } else { 'Center' }
            $ThemeRing.Margin = if ($expanded) { New-Object Windows.Thickness(0) } else {
                New-Object Windows.Thickness(0,0,0,1)
            }
            $ThemeRingNumber.FontSize = if ($expanded) { 26 } else { 17 }
            $ThemeRingTrack.StrokeThickness = if ($expanded) { 5 } else { 3 }
            $ThemeRingArc.StrokeThickness = $ThemeRingTrack.StrokeThickness
            $RemainingSummaryPanel.Visibility = 'Collapsed'
            if (-not $expanded) {
                $CompactProgressRow.Height = New-Object Windows.GridLength(0)
                $ThemeCompactProvider.HorizontalAlignment = 'Center'
                $ThemeCompactPeriod.Visibility = 'Visible'
                $ThemeCompactPeriod.FontSize = if ($WindowLabel.Text.Length -gt 6) { 7 } else { 8 }
            }
        }
        'rail' {
            $ProgressTrack.Visibility = 'Collapsed'
            $ThemeRail.Visibility = 'Visible'
            $ThemeRail.Height = if ($expanded) { 66 } else { 52 }
            $ThemeRail.Width = if ($expanded) { 7 } else { 5 }
            if ($expanded) {
                $ThemeHeroLabel.Margin = New-Object Windows.Thickness(22,10,110,0)
                $ThemeHeroReset.Margin = New-Object Windows.Thickness(22,34,110,0)
            } else {
                $RemainingSummaryPanel.Margin = New-Object Windows.Thickness(8,9,0,0)
                $ThemeCompactProvider.Margin = New-Object Windows.Thickness(10,0,0,0)
            }
        }
    }
    if ($expanded -and $theme.layout.heroAlignment -eq 'Right') {
        $RemainingSummaryPanel.HorizontalAlignment = 'Right'
        $RemainingNumberPanel.HorizontalAlignment = 'Right'
        $RemainingSummaryPanel.Margin = New-Object Windows.Thickness(0,0,2,0)
        if ($theme.layout.quotaStyle -eq 'bar') {
            $ThemeHeroLabel.Margin = New-Object Windows.Thickness(3,10,110,0)
            $ThemeHeroReset.Margin = New-Object Windows.Thickness(3,34,110,0)
        }
    }
    Update-RmfThemeGauge
}

function Get-RmfThemeStatusPalette {
    param([double]$Percent, [bool]$Available)
    $theme = $script:RmfActiveTheme
    $accent = (Get-RmfThemeQuotaColor -Percent $Percent -Available $Available).ToString()
    return [pscustomobject]@{
        Accent = [Windows.Media.ColorConverter]::ConvertFromString($accent)
        Strong = [Windows.Media.ColorConverter]::ConvertFromString($accent)
        Soft = Get-BlendedColor -From $theme.colors.Surface -To $accent -Amount 0.08
        Border = Get-BlendedColor -From $theme.colors.Border -To $accent -Amount 0.18
        HoverBorder = (Get-BlendedColor -From $theme.colors.Border -To $accent -Amount 0.45).ToString()
    }
}

function Update-RmfThemeStatus {
    if (-not $script:RmfActiveTheme) { return }
    if ($script:ActiveThemeId -eq 'classic') { Update-RmfThemeGauge; return }
    if (-not $script:HighContrast) {
        # Each quota window is colored from its own value, including weekly exhaustion.
        foreach ($item in @(@($WeeklyRemainingColumn, $ThemeWeeklyFill, $WeeklyRemainingValue),
            @($FiveHourRemainingColumn, $ThemeFiveHourFill, $FiveHourRemainingValue))) {
            $value = $item[0].Width.Value
            $available = $item[2].Text -notin @('未知', '', '--')
            $color = Get-RmfThemeQuotaColor -Percent $value -Available $available
            $brush = New-Object Windows.Media.SolidColorBrush($color)
            $item[1].Background = $brush
            $item[2].Foreground = $brush
        }
        $status = Get-RmfThemeStatusPalette $script:RmfThemePercent $script:RmfThemeProgressAvailable
        $secondary = Get-RmfThemeQuotaColor -Percent $WeeklyRemainingColumn.Width.Value -Available ($WeeklyRemainingValue.Text -notin @('未知','','--'))
        $ThemeQuotaCard.Background = New-Object Windows.Media.SolidColorBrush(
            (Get-BlendedColor -From $script:RmfActiveTheme.colors.Surface -To $secondary.ToString() -Amount 0.07))
        $ThemeNotice.Background = New-Object Windows.Media.SolidColorBrush($status.Soft)
        $RapidDropText.Foreground = $window.Resources['TextSecondary']
        $RapidDropStatusDot.Fill = $window.Resources['Sage']
        if (-not $script:RapidDropAlertsEnabled) {
            $disabledBrush = New-Object Windows.Media.SolidColorBrush(
                [Windows.Media.ColorConverter]::ConvertFromString($script:RmfActiveTheme.colors.Unknown))
            $RapidDropText.Foreground = $disabledBrush
            $RapidDropStatusDot.Fill = $disabledBrush
        } elseif ($script:RmfThemeMonitorRapid) {
            $warningColor = Get-RmfThemeQuotaColor -Percent 0
            $warningBrush = New-Object Windows.Media.SolidColorBrush($warningColor)
            $RapidDropText.Foreground = $warningBrush
            $RapidDropStatusDot.Fill = $warningBrush
            $ThemeNotice.Background = New-Object Windows.Media.SolidColorBrush(
                (Get-BlendedColor -From $script:RmfActiveTheme.colors.Surface -To $warningColor.ToString() -Amount 0.08))
        } elseif ($script:RmfThemeProgressAvailable -and $script:RmfThemePercent -le 20) {
            $RapidDropText.Foreground = New-Object Windows.Media.SolidColorBrush($status.Strong)
        }
        $fillColor = $status.Accent
        $fillColor.A = 36
        foreach ($area in @($Trend5HArea, $Trend7Area)) {
            $area.Fill = New-Object Windows.Media.SolidColorBrush($fillColor)
        }
    }
    Update-RmfThemeLayout
}

function Get-RmfThemeTrendBrush {
    param([object[]]$Samples)
    if ($Samples.Count -lt 2) { return $window.Resources['StatusStrong'] }
    $ordered = @($Samples | Sort-Object ObservedAtUtc)
    $start = [DateTimeOffset]$ordered[0].ObservedAtUtc
    $seconds = ([DateTimeOffset]$ordered[-1].ObservedAtUtc - $start).TotalSeconds
    if ($seconds -le 0) { return $window.Resources['StatusStrong'] }
    $brush = New-Object Windows.Media.LinearGradientBrush
    $brush.StartPoint = New-Object Windows.Point(0,0)
    $brush.EndPoint = New-Object Windows.Point(1,0)
    foreach ($sample in $ordered) {
        $offset = (([DateTimeOffset]$sample.ObservedAtUtc - $start).TotalSeconds / $seconds)
        $color = Get-RmfThemeQuotaColor -Percent $sample.RemainingValue
        $brush.GradientStops.Add((New-Object Windows.Media.GradientStop($color,$offset)))
    }
    return $brush
}

function Set-RmfTheme {
    param([string]$Id, [switch]$SkipSave)
    if (-not $script:RmfThemes.Contains($Id)) { throw '所选主题不存在。' }
    $previous = $script:ActiveThemeId
    try {
        $script:ActiveThemeId = $Id
        $script:RmfActiveTheme = $script:RmfThemes[$Id]
        Apply-RmfThemeDefinition
        if ($script:LastSnapshot) { Update-UsageView -Snapshot $script:LastSnapshot -DisplayOnly }
        Set-Progress -Percent $script:RmfThemePercent -Available $script:RmfThemeProgressAvailable
        Update-RmfThemeLayout
        if (-not $SkipSave) { Save-Settings -ThrowOnError }
    }
    catch {
        $script:ActiveThemeId = $previous
        $script:RmfActiveTheme = $script:RmfThemes[$previous]
        Apply-RmfThemeDefinition
        Set-Progress -Percent $script:RmfThemePercent -Available $script:RmfThemeProgressAvailable
        Update-RmfThemeLayout
        Sync-RmfThemeMenus
        throw
    }
    Sync-RmfThemeMenus
}
