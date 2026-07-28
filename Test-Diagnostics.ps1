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
    [bool]$transitions.ActivationRevealedEdgeDock -and
    [bool]$transitions.EdgeRailHitTest -and
    $transitions.EdgeRailAlpha -ge 8 -and
    $transitions.EdgeRevealHitWidth -eq 14 -and
    [bool]$transitions.EdgeSpacingStable -and
    [bool]$transitions.EdgeGapStableAcrossCycles -and
    [bool]$transitions.EdgeDockAnchorStable -and
    $transitions.HiddenSurfaceAlpha -eq 0
) -Message 'Edge transition behavior'

[pscustomobject]@{
    CodexRateLimitSelection = 'Passed'
    DeepSeekData = 'Passed'
    Placement = 'Passed'
    EdgeDocking = 'Passed'
    Startup = 'Passed'
    Transitions = 'Passed'
}
