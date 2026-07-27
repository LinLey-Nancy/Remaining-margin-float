Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$appScript = Join-Path $projectRoot 'src\CodexMarginFloat.ps1'

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $appScript,
    [ref]$tokens,
    [ref]$errors
)
if ($errors.Count -gt 0) {
    throw "PowerShell parse check failed: $($errors[0].Message)"
}

$json = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $appScript -CheckData | Out-String
if ($LASTEXITCODE -ne 0) {
    throw 'Data check process failed.'
}
$snapshot = $json | ConvertFrom-Json

$required = @(
    'Available',
    'RemainingPercent',
    'WindowLabel',
    'ResetDate',
    'ResetCount',
    'Plan',
    'TodayTokens',
    'LastTurnTokens',
    'SampledAt',
    'Source'
)
foreach ($property in $required) {
    if (-not $snapshot.PSObject.Properties[$property]) {
        throw "Missing snapshot property: $property"
    }
}

if ($snapshot.RemainingPercent -lt 0 -or $snapshot.RemainingPercent -gt 100) {
    throw "RemainingPercent is outside 0..100: $($snapshot.RemainingPercent)"
}
if ($snapshot.TodayTokens -lt 0 -or $snapshot.LastTurnTokens -lt 0) {
    throw 'Token counts must not be negative.'
}

$placementJson = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $appScript -CheckPlacement | Out-String
if ($LASTEXITCODE -ne 0) {
    throw 'Placement check process failed.'
}
$placement = $placementJson | ConvertFrom-Json
if ($placement.Expanded.Left -ne 1550 -or $placement.Expanded.Top -ne 580) {
    throw "Expanded placement was not fitted to the work area: $placementJson"
}
if ($placement.Restored.Left -ne $placement.Anchor.Left -or $placement.Restored.Top -ne $placement.Anchor.Top) {
    throw 'Compact anchor was not preserved for restoration.'
}

$transitionJson = & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $appScript -CheckTransitions | Out-String
if ($LASTEXITCODE -ne 0) {
    throw 'Transition check process failed.'
}
$transition = $transitionJson | ConvertFrom-Json
if (-not $transition.TaskViewHidden) {
    throw "The floating window is still eligible for Win+Tab/Alt+Tab: $transitionJson"
}
if ($transition.TrayIconWidth -ne 32 -or $transition.TrayIconHeight -ne 32) {
    throw "The notification area icon was not generated at 32x32: $transitionJson"
}
if (
    $transition.UpperClampedRemaining -ne 100 -or
    $transition.UpperClampedUsed -ne 0 -or
    $transition.LowerClampedRemaining -ne 0 -or
    $transition.LowerClampedUsed -ne 100
) {
    throw "Progress segments are not clamped to 0..100: $transitionJson"
}
if ($transition.RemainingProgressStar -ne 82 -or $transition.UsedProgressStar -ne 18) {
    throw "Progress segments do not reflect remaining versus used quota: $transitionJson"
}
if ($transition.ExpandedWidth -ne 370 -or $transition.ExpandedHeight -ne 500 -or $transition.ExpandedVisibility -ne 'Visible') {
    throw "Normal expansion did not settle to the detail size: $transitionJson"
}
if ($transition.ReopenedWidth -ne 370 -or $transition.ReopenedHeight -ne 500 -or $transition.ReopenedVisibility -ne 'Visible') {
    throw "Reopening during collapse left a partial window: $transitionJson"
}
if ($transition.Width -ne 108 -or $transition.Height -ne 100) {
    throw "Rapid collapse did not restore compact dimensions: $transitionJson"
}
if ($transition.DetailsVisibility -ne 'Collapsed') {
    throw "Rapid collapse left the details panel visible: $transitionJson"
}
if ($transition.RestoredLeft -ne $transition.AnchorLeft -or $transition.RestoredTop -ne $transition.AnchorTop) {
    throw "Rapid collapse did not restore the compact anchor: $transitionJson"
}

Write-Output 'Smoke test passed.'
