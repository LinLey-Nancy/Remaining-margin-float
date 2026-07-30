param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'src\RemainingMarginFloat.ps1')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$resolvedScriptPath = [IO.Path]::GetFullPath($ScriptPath)
if (-not (Test-Path -LiteralPath $resolvedScriptPath -PathType Leaf)) {
    throw "Application script is missing: $resolvedScriptPath"
}

function Invoke-JsonDiagnostic {
    param([string]$Name)

    $output = @(
        & powershell.exe -NoProfile -NonInteractive -STA `
            -File $resolvedScriptPath "-$Name" 2>&1
    )
    if ($LASTEXITCODE -ne 0) {
        throw "Diagnostic $Name failed:`n$($output -join [Environment]::NewLine)"
    }
    try {
        return ($output -join [Environment]::NewLine) | ConvertFrom-Json
    }
    catch {
        throw "Diagnostic $Name did not return valid JSON: $($_.Exception.Message)"
    }
}

function Assert-Diagnostic {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "Diagnostic assertion failed: $Message"
    }
}

function Invoke-EmptyProfilePerformanceDiagnostic {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $profileRoot = [IO.Path]::GetFullPath(
        (Join-Path $tempRoot (
            'RemainingMarginFloat.EmptyProfile.{0}.{1}' -f
                $PID,
                [Guid]::NewGuid().ToString('N')
        ))
    )
    if (-not $profileRoot.StartsWith(
        $tempRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Empty-profile diagnostic escaped the temporary directory.'
    }

    $previousUserProfile = $env:USERPROFILE
    try {
        [void](New-Item `
            -ItemType Directory `
            -Path (Join-Path $profileRoot '.codex\sessions') `
            -Force)
        [void](New-Item `
            -ItemType Directory `
            -Path (Join-Path $profileRoot '.claude\projects') `
            -Force)
        $env:USERPROFILE = $profileRoot
        return Invoke-JsonDiagnostic -Name 'CheckRefreshPerformance'
    }
    finally {
        $env:USERPROFILE = $previousUserProfile
        if (
            (Test-Path -LiteralPath $profileRoot) -and
            $profileRoot.StartsWith(
                $tempRoot,
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            Remove-Item -LiteralPath $profileRoot -Recurse -Force
        }
    }
}

$codex = Invoke-JsonDiagnostic -Name 'CheckCodexRateLimitSelection'
foreach ($property in $codex.PSObject.Properties) {
    if ($property.Value -is [bool]) {
        Assert-Diagnostic -Condition $property.Value -Message (
            "CheckCodexRateLimitSelection.$($property.Name)"
        )
    }
}
Assert-Diagnostic -Condition ($codex.SelectedUsedPercent -eq 22) `
    -Message 'Codex selected used percent'
Assert-Diagnostic -Condition ($codex.SelectedResetAt -eq 1893459600) `
    -Message 'Codex selected reset timestamp'

$contracts = Invoke-JsonDiagnostic -Name 'CheckProviderContracts'
Assert-Diagnostic -Condition (
    [Math]::Abs([double]$contracts.CodexUsedPercent - 37) -lt 0.0001 -and
    $contracts.CodexWindowMinutes -eq 10080 -and
    $contracts.CodexPlan -eq 'prolite'
) -Message 'Codex official response contract fixture'
Assert-Diagnostic -Condition (
    $contracts.DeepSeekEventCount -eq 2 -and
    $contracts.DeepSeekPrimaryTokens -eq 3000000 -and
    [Math]::Abs([double]$contracts.DeepSeekPrimaryCostCny - 9.025) -lt 0.0001
) -Message 'DeepSeek log and pricing contract fixture'
Assert-Diagnostic -Condition (
    [bool]$contracts.DeepSeekAvailable -and
    [Math]::Abs([double]$contracts.DeepSeekBalance - 86.4) -lt 0.0001 -and
    $contracts.DeepSeekBudgetPercent -eq 72
) -Message 'DeepSeek balance response contract fixture'
Assert-Diagnostic -Condition (
    $contracts.PricingSchemaVersion -eq 1 -and
    $contracts.PricingCurrency -eq 'CNY'
) -Message 'DeepSeek versioned pricing catalog'

$performance = Invoke-JsonDiagnostic -Name 'CheckRefreshPerformance'
Assert-Diagnostic -Condition (
    $performance.MeasurementCount -eq 3 -and
    [double]$performance.ColdReadMs -ge 0 -and
    [double]$performance.WarmReadMs -ge 0
) -Message 'Codex local refresh performance baseline'
Assert-Diagnostic -Condition (
    $performance.DeepSeekMeasurementCount -eq 3 -and
    [double]$performance.DeepSeekColdReadMs -ge 0 -and
    [double]$performance.DeepSeekWarmReadMs -ge 0
) -Message 'DeepSeek local refresh performance baseline'
Assert-Diagnostic -Condition (
    $performance.TailSyntheticFileBytes -eq 8MB -and
    $performance.HeadSyntheticFileBytes -eq 8MB -and
    [bool]$performance.TailOnlyPayloadSelected -and
    [bool]$performance.HeadOnlyPayloadIgnored -and
    [bool]$performance.HeadOnlyRateLimitIgnored
) -Message 'Codex bounded session tail regression'
Assert-Diagnostic -Condition (
    [bool]$performance.DeepSeekAggregateCacheHit -and
    [bool]$performance.DeepSeekAggregateCacheInvalidated
) -Message 'DeepSeek aggregate cache invalidation'

$emptyProfilePerformance = Invoke-EmptyProfilePerformanceDiagnostic
Assert-Diagnostic -Condition (
    $emptyProfilePerformance.SessionFileCount -eq 0 -and
    $emptyProfilePerformance.SessionBytes -eq 0 -and
    $emptyProfilePerformance.DeepSeekFileCount -eq 0 -and
    $emptyProfilePerformance.DeepSeekBytes -eq 0 -and
    $emptyProfilePerformance.TailSyntheticFileBytes -eq 8MB -and
    $emptyProfilePerformance.HeadSyntheticFileBytes -eq 8MB -and
    [bool]$emptyProfilePerformance.TailOnlyPayloadSelected -and
    [bool]$emptyProfilePerformance.HeadOnlyPayloadIgnored -and
    [bool]$emptyProfilePerformance.HeadOnlyRateLimitIgnored
) -Message 'Empty-profile refresh performance regression'

$deepSeek = Invoke-JsonDiagnostic -Name 'CheckDeepSeekData'
Assert-Diagnostic -Condition ([bool]$deepSeek.Available) -Message 'DeepSeek availability'
Assert-Diagnostic -Condition ([bool]$deepSeek.SecureStorageRoundTrip) `
    -Message 'DeepSeek DPAPI round trip'
Assert-Diagnostic -Condition ($deepSeek.DedupedUsageTokens -eq 40) `
    -Message 'DeepSeek duplicate token handling'
Assert-Diagnostic -Condition ($deepSeek.DedupedUsageMessages -eq 1) `
    -Message 'DeepSeek duplicate message handling'
Assert-Diagnostic -Condition ($deepSeek.ParserUsageTokens -eq 424) `
    -Message 'DeepSeek usage parser'
Assert-Diagnostic -Condition (
    [Math]::Abs([double]$deepSeek.PricingUsageCostCny - 9.025) -lt 0.0001
) -Message 'DeepSeek price calculation'

$history = Invoke-JsonDiagnostic -Name 'CheckUsageHistory'
Assert-Diagnostic -Condition ($history.Trend24Change -eq -20) `
    -Message '24-hour history trend'
Assert-Diagnostic -Condition ($history.Trend7Change -eq -20) `
    -Message '7-day history trend'
Assert-Diagnostic -Condition (
    $history.DepletionStatus -eq 'Depleting' -and
    [Math]::Abs([double]$history.DepletionHours - 6) -lt 0.01
) -Message 'Depletion forecast'
Assert-Diagnostic -Condition ([bool]$history.ResetBoundaryRespected) `
    -Message 'Forecast reset boundary'
Assert-Diagnostic -Condition ([bool]$history.ResetJumpStartsNewSegment) `
    -Message 'Forecast reset segment'
Assert-Diagnostic -Condition ([bool]$history.StableUsageDetected) `
    -Message 'Stable usage forecast'
Assert-Diagnostic -Condition ([bool]$history.LowThresholdCrossingDetected) `
    -Message 'Low threshold crossing'
Assert-Diagnostic -Condition ([bool]$history.RepeatedLowAlertSuppressed) `
    -Message 'Repeated low alert suppression'
Assert-Diagnostic -Condition (
    [bool]$history.CustomLowThresholdCrossingDetected
) -Message 'Custom low alert threshold crossing'
Assert-Diagnostic -Condition ([bool]$history.PersistenceRoundTrip) `
    -Message 'History persistence round trip'
Assert-Diagnostic -Condition ([bool]$history.HistorySampleContainsNoAccountData) `
    -Message 'History privacy fields'

$placement = Invoke-JsonDiagnostic -Name 'CheckPlacement'
Assert-Diagnostic -Condition (
    $placement.Expanded.Left -eq 1550 -and
    $placement.Expanded.Top -eq 580 -and
    $placement.Restored.Left -eq $placement.Anchor.Left -and
    $placement.Restored.Top -eq $placement.Anchor.Top
) -Message 'Window placement and restoration'

$edge = Invoke-JsonDiagnostic -Name 'CheckEdgeDocking'
Assert-Diagnostic -Condition (
    $edge.LeftDetected -eq 'Left' -and
    $edge.RightDetected -eq 'Right' -and
    $null -eq $edge.CenterDetected -and
    $edge.LeftHidden -eq -82 -and
    $edge.RightHidden -eq 1906
) -Message 'Edge docking geometry'

$startup = Invoke-JsonDiagnostic -Name 'CheckStartup'
Assert-Diagnostic -Condition ($startup.Source -eq 'PowerShell') `
    -Message 'Source startup path'
Assert-Diagnostic -Condition (
    $startup.CommandLine -notmatch 'ExecutionPolicy\s+Bypass' -and
    $startup.CommandLine -notmatch 'WindowStyle\s+Hidden'
) -Message 'Source startup command policy'

$transitions = Invoke-JsonDiagnostic -Name 'CheckTransitions'
Assert-Diagnostic -Condition ([bool]$transitions.SingleInstanceUserScoped) `
    -Message 'Per-user single-instance object names'
Assert-Diagnostic -Condition ([bool]$transitions.DeactivationCallbackObserved) `
    -Message 'Window deactivation callback'
Assert-Diagnostic -Condition ([bool]$transitions.ReentrantCallbackObserved) `
    -Message 'Reentrant event callback'
Assert-Diagnostic -Condition ([bool]$transitions.TaskViewHidden) `
    -Message 'Task view visibility'
Assert-Diagnostic -Condition (
    $transitions.ExpandedWidth -eq 370 -and
    $transitions.ExpandedHeight -eq 500 -and
    $transitions.ExpandedVisibility -eq 'Visible' -and
    $transitions.ReopenedVisibility -eq 'Visible' -and
    $transitions.InactiveVisibility -eq 'Collapsed'
) -Message 'Window transition states'
Assert-Diagnostic -Condition (
    $transitions.UpperClampedRemaining -eq 100 -and
    $transitions.UpperClampedUsed -eq 0 -and
    $transitions.LowerClampedRemaining -eq 0 -and
    $transitions.LowerClampedUsed -eq 100
) -Message 'Progress clamping'
Assert-Diagnostic -Condition (
    $transitions.CodexSettingsVisibility -eq 'Collapsed' -and
    $transitions.DeepSeekSettingsVisibility -eq 'Visible'
) -Message 'Provider settings visibility'
Assert-Diagnostic -Condition (
    $transitions.DeepSeekCompactValue -eq '72' -and
    $transitions.DeepSeekCompactSuffix -eq '%' -and
    -not [string]::IsNullOrWhiteSpace([string]$transitions.DeepSeekLabel) -and
    [string]$transitions.DeepSeekBalanceText -match '86\.40$' -and
    -not [string]::IsNullOrWhiteSpace([string]$transitions.DeepSeekMetricTitle) -and
    [string]$transitions.DeepSeekMonthlyCostValue -match '2\.36$' -and
    $transitions.DeepSeekTodayTokenValue -eq '382.6K' -and
    $transitions.DeepSeekMonthlyTokenValue -eq '2.8M' -and
    $transitions.DeepSeekProgressRemaining -eq 72 -and
    $transitions.DeepSeekProgressUsed -eq 28
) -Message 'DeepSeek budget UI'
Assert-Diagnostic -Condition (
    $transitions.DeepSeekBalanceCompactValue -eq '86.4' -and
    $transitions.DeepSeekBalanceCompactSuffix -eq '' -and
    -not [string]::IsNullOrWhiteSpace(
        [string]$transitions.DeepSeekBalanceCompactLabel
    ) -and
    $transitions.DeepSeekNoBudgetProgressRemaining -eq 0 -and
    $transitions.DeepSeekNoBudgetProgressUsed -eq 100
) -Message 'DeepSeek balance-only UI'
Assert-Diagnostic -Condition (
    @($transitions.MetricValueFontFamilies).Count -eq 4 -and
    @($transitions.MetricValueFontFamilies | Where-Object {
        $_ -ne 'Segoe UI Variable Display'
    }).Count -eq 0 -and
    @($transitions.MetricValueFontSizes | Where-Object {
        [double]$_ -ne 21
    }).Count -eq 0 -and
    @($transitions.MetricValueFontWeights | Where-Object {
        $_ -ne 'SemiBold'
    }).Count -eq 0
) -Message 'Metric typography'
Assert-Diagnostic -Condition (
    [bool]$transitions.ActivationRevealedEdgeDock -and
    [bool]$transitions.EdgeRailHitTest -and
    $transitions.EdgeRailAlpha -ge 8 -and
    $transitions.EdgeRevealHitWidth -eq 14 -and
    $transitions.EdgeTrackWidth -eq 12 -and
    [bool]$transitions.EdgeTrackFlush -and
    [bool]$transitions.EdgeEnergyContainedByOutline -and
    @($transitions.EdgeEnergyInsets | Where-Object { $_ -ne 1 }).Count -eq 0 -and
    @($transitions.EdgeOutlineThickness | Where-Object { $_ -ne 1 }).Count -eq 0 -and
    @($transitions.EdgeOutlineCorners | Where-Object { $_ -ne 2 }).Count -eq 0 -and
    [bool]$transitions.EdgePixelAlignedAcrossCycles -and
    [bool]$transitions.AnimatedEdgePixelAligned -and
    [bool]$transitions.AnimatedRevealPixelAligned -and
    [bool]$transitions.HoverTimerRevealedEdgeDock -and
    [bool]$transitions.HoverRevealPixelAligned -and
    $transitions.MaximumEdgePixelGap -eq 0 -and
    [bool]$transitions.EdgeSpacingStable -and
    [bool]$transitions.EdgeGapStableAcrossCycles -and
    [bool]$transitions.EdgeDockAnchorStable -and
    $transitions.HiddenSurfaceAlpha -eq 0
) -Message 'Edge transition behavior'
Assert-Diagnostic `
    -Condition ([string]$transitions.Trend24Text -match '^24H') `
    -Message '24-hour trend UI'
Assert-Diagnostic `
    -Condition ([string]$transitions.Trend7Text -match '^7D') `
    -Message '7-day trend UI'
Assert-Diagnostic `
    -Condition (-not [string]::IsNullOrWhiteSpace([string]$transitions.PredictionText)) `
    -Message 'Depletion forecast UI'
Assert-Diagnostic `
    -Condition ([bool]$transitions.LowAlertMenuChecked) `
    -Message 'Low-alert menu UI'
Assert-Diagnostic -Condition (
    [string]$transitions.LowAlertThresholdMenuText -match '35%'
) -Message 'Custom low-alert threshold menu UI'
Assert-Diagnostic -Condition (
    [bool]$transitions.LowAlertThresholdPersisted -and
    [bool]$transitions.LowAlertThresholdInvalidFallback -and
    [bool]$transitions.LowAlertThresholdDialogReady
) -Message 'Custom low-alert threshold persistence'

$refresh = Invoke-JsonDiagnostic -Name 'CheckRefreshCoordinator'
Assert-Diagnostic -Condition ([bool]$refresh.ManualRefreshSucceeded) `
    -Message 'Manual Codex refresh'
Assert-Diagnostic -Condition ([bool]$refresh.AutomaticRefreshSucceeded) `
    -Message 'Automatic Codex refresh at zero seconds'
Assert-Diagnostic -Condition ([bool]$refresh.ZeroSecondStateRecovered) `
    -Message 'Zero-second countdown recovery'
Assert-Diagnostic -Condition ([bool]$refresh.CountdownAdvanced) `
    -Message 'Absolute refresh countdown advancement'

[pscustomobject]@{
    CodexRateLimitSelection = 'Passed'
    ProviderContracts = 'Passed'
    RefreshPerformance = (
        'Passed - Codex {0}/{1} ms - DeepSeek {2}/{3} ms' -f
            $performance.ColdReadMs,
            $performance.WarmReadMs,
            $performance.DeepSeekColdReadMs,
            $performance.DeepSeekWarmReadMs
    )
    EmptyProfilePerformance = 'Passed'
    DeepSeekData = 'Passed'
    UsageHistory = 'Passed'
    Placement = 'Passed'
    EdgeDocking = 'Passed'
    Startup = 'Passed'
    Transitions = 'Passed'
    RefreshCoordinator = 'Passed'
}
