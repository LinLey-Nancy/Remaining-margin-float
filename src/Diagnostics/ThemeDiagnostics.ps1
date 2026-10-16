if ($CheckThemes) {
    $checks = New-Object Collections.Generic.List[string]
    function Assert-ThemeCheck {
        param([bool]$Condition, [string]$Name)
        if (-not $Condition) { throw "Theme diagnostic failed: $Name" }
        $checks.Add($Name)
    }
    function Wait-ThemeLayout {
        $window.UpdateLayout()
        $frame = New-Object Windows.Threading.DispatcherFrame
        $pulse = New-Object Windows.Threading.DispatcherTimer
        $pulse.Interval = [TimeSpan]::FromMilliseconds(35)
        $pulse.Add_Tick({ $pulse.Stop(); $frame.Continue = $false })
        $pulse.Start()
        [Windows.Threading.Dispatcher]::PushFrame($frame)
    }
    function Assert-ThemeRejected {
        param($Candidate, [string]$Name)
        $rejected = $false
        try { [void](Assert-RmfThemeDefinition -Theme $Candidate -Imported) }
        catch { $rejected = $true }
        Assert-ThemeCheck $rejected $Name
    }
    function Set-ThemeDiagnosticHistory {
        param($Snapshot, [double]$Percent)
        $history = New-Object Collections.Generic.List[object]
        $hours = @(168,120,72,48,24,4,2,0)
        $extra = @(83,70,55,40,30,20,10,0)
        for ($index = 0; $index -lt $hours.Count; $index++) {
            $copy = $Snapshot.PSObject.Copy()
            $value = [Math]::Min(100, $Percent + $extra[$index])
            $copy.RemainingPercent = $value
            if ($copy.ProviderId -in @('Codex','Kimi')) {
                $copy.FiveHourRemainingPercent = $value
                $copy.FiveHourUsedPercent = 100 - $value
            }
            foreach ($sample in @(ConvertTo-UsageHistorySamples -Snapshot $copy -ObservedAt ([DateTimeOffset]::Now.AddHours(-$hours[$index])))) {
                $history.Add($sample)
            }
        }
        $script:UsageHistoryCache = $history.ToArray()
    }
    Assert-ThemeCheck ($script:RmfThemes.Count -eq 4) 'Four built-in themes'
    Assert-ThemeCheck ($script:ActiveThemeId -eq 'classic') 'Classic is default'
    $window.Left = 24
    $window.Top = 24
    $window.Show()
    $screenshots = New-Object Collections.Generic.List[string]
    if ($CaptureDirectory) { [void][IO.Directory]::CreateDirectory($CaptureDirectory) }
    foreach ($id in @('classic','native','instrument','paper')) {
        Set-RmfTheme -Id $id -SkipSave
        foreach ($provider in @('Codex','Kimi','DeepSeek')) {
            $script:ActiveProvider = $provider
            $snapshot = if ($provider -eq 'DeepSeek') { Get-DeepSeekDemoSnapshot } else { Get-KimiDemoSnapshot }
            if ($provider -eq 'Codex') {
                $snapshot.ProviderId = 'Codex'
                $snapshot.PlanType = 'plus'
                $snapshot.Plan = 'Plus'
                $snapshot.AccountName = '本地 Codex'
                $snapshot.AccountEmail = '本机账户信息'
                $snapshot.TodayTokens = 382640
                $snapshot.TodayOutputTokens = 81360
                $snapshot.TodayCachedTokens = 245800
                $snapshot.TodayCacheHitPercent = 64.2
            }
            foreach ($percent in @(82,8)) {
                if ($provider -ne 'DeepSeek') {
                    $snapshot.FiveHourRemainingPercent = $percent
                    $snapshot.FiveHourUsedPercent = 100 - $percent
                    $snapshot.WeeklyRemainingPercent = 24
                    $snapshot.WeeklyUsedPercent = 76
                } else {
                    $snapshot.HasProgress = $true
                    $snapshot.RemainingPercent = $percent
                }
                Set-ThemeDiagnosticHistory -Snapshot $snapshot -Percent $percent
                Update-UsageView -Snapshot $snapshot
                foreach ($expanded in @($false,$true)) {
                    Set-ExpandedState -Expanded $expanded -Immediate
                    Wait-ThemeLayout
                    $label = "$id-$provider-$percent-$expanded"
                    Assert-ThemeCheck ($TokenSummaryCard.Visibility -eq 'Visible' -and $AppVersionText.Parent -eq $FooterStatusText) "$label content restored"
                    Assert-ThemeCheck ($window.ActualWidth -eq $(if ($expanded) {400} else {80})) "$label width"
                    Assert-ThemeCheck ($window.ActualHeight -eq $(if ($expanded) {
                        Get-ExpandedHeightForSnapshot $snapshot
                    } else {80})) "$label height"
                    Assert-ThemeCheck ([Math]::Abs($script:RmfThemePercent - $percent) -lt 0.01) "$label primary quota"
                    if ($id -ne 'classic') {
                        Assert-ThemeCheck (($ThemeToolbar.Visibility -eq 'Visible') -eq $expanded) "$label toolbar"
                        Assert-ThemeCheck ([string]$ThemeRing.Visibility -eq $(if ($id -eq 'instrument') {'Visible'} else {'Collapsed'})) "$label ring"
                        Assert-ThemeCheck ([string]$ThemeRail.Visibility -eq $(if ($id -eq 'paper') {'Visible'} else {'Collapsed'})) "$label rail"
                        if ($provider -ne 'DeepSeek') {
                            $expected = Get-RmfThemeQuotaColor -Percent 24
                            Assert-ThemeCheck ($ThemeWeeklyFill.Background.Color -eq $expected) "$label weekly independent color"
                        }
                    }
                    if ($CaptureDirectory) {
                        $capturePath = Join-Path $CaptureDirectory ($label + '.png')
                        Save-VisualPng -Element $window -Path $capturePath
                        $screenshots.Add($capturePath)
                    }
                }
            }
        }
        $pro = Get-KimiDemoSnapshot
        $pro.ProviderId = 'Codex'
        $pro.PlanType = 'pro'
        $pro.Plan = 'Pro'
        $pro.PrimaryQuotaPeriod = 'Weekly'
        $pro.WeeklyRemainingPercent = 78
        $pro.WeeklyUsedPercent = 22
        $script:ActiveProvider = 'Codex'
        Update-UsageView -Snapshot $pro
        Set-ExpandedState -Expanded $true -Immediate
        Wait-ThemeLayout
        Assert-ThemeCheck ($window.ActualHeight -eq 474 -and $script:RmfThemePercent -eq 78 -and
            $CodexQuotaPanel.Visibility -eq 'Collapsed') "$id Pro weekly layout"
        $pro.PrimaryQuotaPeriod = 'FiveHour'
        $pro.PlanType = 'plus'
        $pro.Plan = 'Plus'
        $pro.FiveHourRemainingPercent = 100
        $pro.FiveHourUsedPercent = 0
        $pro.WeeklyRemainingPercent = 0
        $pro.WeeklyUsedPercent = 100
        Update-UsageView -Snapshot $pro
        Assert-ThemeCheck ($script:RmfThemePercent -eq 0 -and $WindowLabel.Text -eq '每周余量') "$id weekly exhaustion overrides fresh five-hour quota"
        $pro.WeeklyRemainingPercent = 78
        $pro.WeeklyUsedPercent = 22
        $pro.FiveHourAvailable = $false
        Update-UsageView -Snapshot $pro
        Assert-ThemeCheck (-not $script:RmfThemeProgressAvailable -and $RemainingValue.Text -eq '未知') "$id unknown five-hour quota remains unknown"
        $longName = Get-KimiDemoSnapshot
        $longName.AccountName = 'Kimi Code · 团队共享开发配置与长期项目配置'
        $longName.AccountEmail = '密钥 ••••a1b2 · 本机读取的演示配置与备注'
        $script:ActiveProvider = 'Kimi'
        Update-UsageView -Snapshot $longName
        Set-ExpandedState -Expanded $true -Immediate
        Wait-ThemeLayout
        if ($id -ne 'classic') {
            $accountBounds = $ThemeAccountText.TransformToVisual($window).TransformBounds(
                (New-Object Windows.Rect(0,0,$ThemeAccountText.ActualWidth,$ThemeAccountText.ActualHeight)))
            $closeBounds = $CloseButton.TransformToVisual($window).TransformBounds(
                (New-Object Windows.Rect(0,0,$CloseButton.ActualWidth,$CloseButton.ActualHeight)))
            Assert-ThemeCheck (-not $accountBounds.IntersectsWith($closeBounds)) "$id account never overlaps collapse control"
        }
        # Unknown data must never turn into a red zero or a full gauge.
        Set-Progress -Percent 0 -Available $false
        $unknown = Get-UsageStatusPalette -Percent 0 -Available $false
        Assert-ThemeCheck ($unknown.Accent -eq [Windows.Media.ColorConverter]::ConvertFromString(
            $(if ($id -eq 'classic') {'#89908C'} else {$script:RmfActiveTheme.colors.Unknown}))) "$id unknown color"
        Assert-ThemeCheck ($null -eq $ThemeRingArc.Data -and $ThemeRailFill.Height -eq 0) "$id unknown gauge"
        # No-budget DeepSeek keeps the amount, not an invented percent.
        $balance = Get-DeepSeekDemoSnapshot
        $balance.HasProgress = $false
        Update-UsageView -Snapshot $balance
        Assert-ThemeCheck (-not $script:RmfThemeProgressAvailable -and $CompactSuffix.Text -eq '') "$id balance without budget"
        Set-ExpandedState -Expanded $false -Immediate
        Wait-ThemeLayout
        if ($CaptureDirectory) { Save-VisualPng -Element $window -Path (Join-Path $CaptureDirectory ($id + '-balance-compact.png')) }
        $savedSnapshot = $script:LastSnapshot
        Set-RmfTheme -Id $id -SkipSave
        Assert-ThemeCheck ([object]::ReferenceEquals($savedSnapshot, $script:LastSnapshot)) "$id switch preserves snapshot"
        if ($id -ne 'classic') {
            foreach ($stop in $script:RmfActiveTheme.quotaColors) {
                Assert-ThemeCheck ((Get-RmfThemeQuotaColor -Percent $stop.percent) -eq
                    [Windows.Media.ColorConverter]::ConvertFromString($stop.color)) "$id anchor $($stop.percent)"
            }
            foreach ($boundary in @(15,30,60)) {
                $left = Get-RmfThemeQuotaColor ($boundary - 0.01)
                $right = Get-RmfThemeQuotaColor ($boundary + 0.01)
                Assert-ThemeCheck (([Math]::Abs([int]$left.R - [int]$right.R) +
                    [Math]::Abs([int]$left.G - [int]$right.G) +
                    [Math]::Abs([int]$left.B - [int]$right.B)) -le 3) "$id smooth $boundary"
            }
        }
        Clear-UsageView -Message '请选择数据源'
        Set-ExpandedState -Expanded $true -Immediate
        Wait-ThemeLayout
        Assert-ThemeCheck ($ThemeToolbar.Visibility -eq 'Collapsed' -and $ThemeRail.Visibility -eq 'Collapsed' -and
            $ThemeRing.Visibility -eq 'Collapsed') "$id empty layout"
    }
    # Import/export and every rejection case run against the isolated profile supplied by Test-Themes.ps1.
    $kitRoot = Join-Path (Get-AppDataDirectory) 'theme-test-kit'
    Set-RmfTheme -Id 'classic' -SkipSave
    [void](Export-RmfThemeKit -Directory $kitRoot)
    $examplePath = Join-Path $kitRoot 'my-theme.json'
    $example = Get-Content -LiteralPath $examplePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $example.typography.compactNumberSize = 24
    $example.typography.detailsNumberSize = 40
    [IO.File]::WriteAllText($examplePath, ($example | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    $custom = Import-RmfTheme -Path $examplePath
    Set-RmfTheme -Id $custom.id -SkipSave
    Assert-ThemeCheck ($script:ActiveThemeId -eq 'my-custom-theme') 'Exported example imports'
    $script:ActiveProvider = 'Kimi'
    Update-UsageView -Snapshot (Get-KimiDemoSnapshot)
    Set-ExpandedState -Expanded $false -Immediate
    Assert-ThemeCheck ($RemainingValue.FontSize -eq 24) 'Custom classic compact font applies'
    Set-ExpandedState -Expanded $true -Immediate
    Wait-ThemeLayout
    Assert-ThemeCheck ($RemainingValue.FontSize -eq 40 -and $ThemeHeaderRow.Height.Value -gt 69) 'Custom classic detail font fits header'

    $duplicateRejected = $false
    try { [void](Import-RmfTheme -Path (Join-Path $kitRoot 'my-theme.json')) } catch { $duplicateRejected = $true }
    Assert-ThemeCheck $duplicateRejected 'Duplicate import rejected'
    foreach ($fault in @('schemaVersion','id','colors','font','range','stops','unknownField','script','xaml')) {
        $candidate = $custom | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        switch ($fault) {
            schemaVersion { $candidate.schemaVersion = 2 }
            id { $candidate.id = '../escape' }
            colors { $candidate.colors.Surface = 'url(https://example.invalid)' }
            font { $candidate.typography.textFamily = 'https://example.invalid/font' }
            range { $candidate.shape.windowRadius = 10000 }
            stops { $candidate.quotaColors[1].percent = 0 }
            unknownField { $candidate | Add-Member -NotePropertyName surprise -NotePropertyValue 'unused' }
            script { $candidate | Add-Member -NotePropertyName script -NotePropertyValue 'Start-Process calc' }
            xaml { $candidate | Add-Member -NotePropertyName xaml -NotePropertyValue '<ObjectDataProvider />' }
        }
        Assert-ThemeRejected $candidate "Reject $fault"
    }
    $reserved = $custom | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $reserved.id = 'classic'
    Assert-ThemeRejected $reserved 'Reserved id rejected'
    $oversizePath = Join-Path $kitRoot 'oversized.json'
    [IO.File]::WriteAllText($oversizePath, (' ' * 131073))
    $oversizeRejected = $false
    try { [void](Read-RmfThemeFile $oversizePath -Imported) } catch { $oversizeRejected = $true }
    Assert-ThemeCheck $oversizeRejected 'Oversized import rejected'
    $script:ActiveProvider = 'Kimi'
    Update-UsageView -Snapshot (Get-KimiDemoSnapshot)
    Set-RmfTheme -Id 'instrument' -SkipSave
    # A rapid drop at healthy remaining quota must still retain warning colors.
    $savedRapidEnabled = $script:RapidDropAlertsEnabled
    $savedMonitorRapid = $script:RmfThemeMonitorRapid
    $script:RapidDropAlertsEnabled = $true
    $script:RmfThemeMonitorRapid = $true
    Set-Progress -Percent 70 -Available $true
    $rapidWarning = Get-RmfThemeQuotaColor -Percent 0
    Assert-ThemeCheck ($RapidDropText.Foreground.Color -eq $rapidWarning -and
        $RapidDropStatusDot.Fill.Color -eq $rapidWarning) 'Healthy quota rapid drop remains a warning'
    $script:RapidDropAlertsEnabled = $false
    Set-Progress -Percent 70 -Available $true
    Assert-ThemeCheck ($RapidDropText.Foreground.Color -eq [Windows.Media.ColorConverter]::ConvertFromString(
        $script:RmfActiveTheme.colors.Unknown)) 'Disabled monitoring remains neutral'
    $script:RapidDropAlertsEnabled = $true
    $script:RmfThemeMonitorRapid = $true
    Update-UsageInsightView -Insights $null
    Assert-ThemeCheck (-not $script:RmfThemeMonitorRapid -and
        $RapidDropText.Foreground.Color -ne $rapidWarning) 'Missing history clears old rapid warning'
    $script:RapidDropAlertsEnabled = $savedRapidEnabled
    $script:RmfThemeMonitorRapid = $savedMonitorRapid
    function Resolve-ThemeTestColor {
        param($Value)
        if ($Value -is [Windows.DynamicResourceExtension]) { return $window.Resources[$Value.ResourceKey].Color }
        if ($Value -is [Windows.Media.SolidColorBrush]) { return $Value.Color }
        throw ('Unsupported hover brush: ' + $Value.GetType().FullName)
    }
    function Get-ThemeTestLuminance {
        param($Color)
        $channels = @($Color.R, $Color.G, $Color.B)
        $weights = @(0.2126,0.7152,0.0722)
        $result = 0.0
        for ($index = 0; $index -lt 3; $index++) {
            $value = [double]$channels[$index] / 255.0
            $linear = if ($value -le 0.04045) { $value / 12.92 } else { [Math]::Pow(($value + 0.055) / 1.055, 2.4) }
            $result += $linear * $weights[$index]
        }
        return $result
    }
    $buttonTemplate = ($window.Resources['SoftButton'].Setters | Where-Object { $_.Property.Name -eq 'Template' }).Value
    $hover = $buttonTemplate.Triggers | Where-Object { $_.Property.Name -eq 'IsMouseOver' }
    $hoverBackground = Resolve-ThemeTestColor ($hover.Setters | Where-Object { $_.Property.Name -eq 'Background' }).Value
    $hoverForeground = Resolve-ThemeTestColor ($hover.Setters | Where-Object { $_.Property.Name -eq 'Foreground' }).Value
    $lumaBackground = Get-ThemeTestLuminance $hoverBackground
    $lumaForeground = Get-ThemeTestLuminance $hoverForeground
    $hoverContrast = ([Math]::Max($lumaBackground,$lumaForeground) + 0.05) /
        ([Math]::Min($lumaBackground,$lumaForeground) + 0.05)
    Assert-ThemeCheck ($hoverContrast -ge 4.5) 'Dark theme hover text contrast'
    $script:HighContrast = $true
    Apply-RmfThemeDefinition
    Set-Progress -Percent 8 -Available $true
    Assert-ThemeCheck ($window.Resources['TextPrimary'].Color -eq [Windows.SystemColors]::WindowTextColor) 'High contrast overrides theme'
    $contrastSamples = @(
        [pscustomobject]@{ MetricType='Percent'; RemainingValue=80; ObservedAtUtc=[DateTimeOffset]::Now.AddHours(-1) },
        [pscustomobject]@{ MetricType='Percent'; RemainingValue=8; ObservedAtUtc=[DateTimeOffset]::Now }
    )
    Set-TrendChart -Canvas $Trend5HCanvas -Polyline $Trend5HLine -Area $Trend5HArea `
        -StartMarker $Trend5HStartMarker -EndMarker $Trend5HEndMarker -Samples $contrastSamples -Hours 5 -ConnectSegments
    Assert-ThemeCheck ($Trend5HLine.Stroke -is [Windows.Media.SolidColorBrush] -and
        $Trend5HLine.Stroke.Color -eq [Windows.SystemColors]::WindowTextColor) 'High contrast trend keeps system color'

    $script:HighContrast = $false
    Set-RmfTheme -Id 'classic' -SkipSave
    Assert-ThemeCheck ($window.Resources['Surface'].Color.ToString() -eq '#FFFAFAF7') 'Classic restored after dark mode'
    Assert-ThemeCheck ($ThemeToolbarRow.Height.Value -eq 0) 'Classic geometry restored'
    foreach ($id in @('native','instrument','paper','my-custom-theme','classic')) {
        Set-RmfTheme -Id $id -SkipSave
        $isDiagnosticRun = $false
        try {
            Save-Settings -ThrowOnError
            $payload = Get-Content -LiteralPath (Get-SettingsPath) -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-ThemeCheck ($payload.ThemeId -eq $id) "$id persisted"
            $script:ActiveThemeId = 'classic'
            if ($id -eq 'my-custom-theme') {
                Initialize-RmfThemes
                Assert-ThemeCheck ($script:RmfThemes.Contains('my-custom-theme')) 'Custom theme loads from disk after restart'
            }
            Restore-Settings
            Assert-ThemeCheck ($script:ActiveThemeId -eq $id) "$id restored"
        } finally { $isDiagnosticRun = $true }
    }
    Rebuild-RmfThemeMenus
    Assert-ThemeCheck ($script:RmfThemeMenu.Items.Count -eq 9) 'Theme menu exposes builtins custom and authoring'
    $script:RmfTrayThemeMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    Add-RmfThemeMenuItems -Menu $script:RmfTrayThemeMenu -Tray
    Sync-RmfThemeMenus
    Assert-ThemeCheck ($script:RmfTrayThemeMenu.DropDownItems.Count -eq 9) 'Tray theme menu matches'
    Assert-ThemeCheck (Test-Path -LiteralPath (Join-Path $kitRoot 'theme.schema.json')) 'Schema exported'
    $exportedSchema = Get-Content -LiteralPath (Join-Path $kitRoot 'theme.schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-ThemeCheck ($exportedSchema.properties.quotaColors.maxItems -eq 12) 'Schema color-stop limit'
    $contract = Get-Content -LiteralPath (Join-Path $kitRoot 'display-contract.json') -Raw -Encoding UTF8
    Assert-ThemeCheck ($contract -notmatch 'AccountEmail|credentials|access_token|api_key') 'Authoring kit excludes account credentials'
    if ($CaptureDirectory) {
        Set-ExpandedState -Expanded $true -Immediate
        $Surface.ContextMenu.IsOpen = $true
        $script:RmfThemeMenu.IsSubmenuOpen = $true
        Wait-ThemeLayout
    }
    if ($CaptureDirectory) {
        [void](Export-RmfThemeKit -Directory (Join-Path $CaptureDirectory 'theme-kit'))
    }
    $window.Close()
    [pscustomobject]@{ Passed = $true; Count = $checks.Count; Checks = $checks.ToArray(); Captures = $screenshots.ToArray() } |
        ConvertTo-Json -Depth 5
    $script:RmfStopLoading = $true
    return
}
