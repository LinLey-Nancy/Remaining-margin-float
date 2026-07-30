param(
    [switch]$CheckData,
    [switch]$CheckDeepSeekData,
    [switch]$CheckDeepSeekUsage,
    [switch]$CheckUsageHistory,
    [switch]$CheckProviderContracts,
    [switch]$CheckRefreshPerformance,
    [switch]$CheckCodexRateLimitSelection,
    [switch]$CheckPlacement,
    [switch]$CheckEdgeDocking,
    [switch]$CheckStartup,
    [switch]$CheckTransitions,
    [switch]$CheckRefreshCoordinator,
    [switch]$CaptureVisuals,
    [string]$CaptureDirectory = '',
    [switch]$Demo,
    [ValidateSet('codex', 'deepseek')]
    [string]$DemoProvider = 'codex'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$releaseGuiCheck = (
    [Environment]::GetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_GUI_CHECK',
        [EnvironmentVariableTarget]::Process
    ) -eq '1'
)
$isDiagnosticRun = (
    $CheckData -or
    $CheckDeepSeekData -or
    $CheckDeepSeekUsage -or
    $CheckUsageHistory -or
    $CheckProviderContracts -or
    $CheckRefreshPerformance -or
    $CheckCodexRateLimitSelection -or
    $CheckPlacement -or
    $CheckEdgeDocking -or
    $CheckStartup -or
    $CheckTransitions -or
    $CheckRefreshCoordinator -or
    $CaptureVisuals -or
    $Demo -or
    $releaseGuiCheck
)

$runtimeScriptPath = [Environment]::GetEnvironmentVariable(
    'REMAINING_MARGIN_FLOAT_SCRIPT',
    [EnvironmentVariableTarget]::Process
)
if ([string]::IsNullOrWhiteSpace($runtimeScriptPath)) {
    $runtimeScriptPath = $PSCommandPath
}
if ([string]::IsNullOrWhiteSpace($runtimeScriptPath)) {
    throw 'Unable to determine the application entry script path.'
}
$script:RmfEntryScriptPath = [IO.Path]::GetFullPath($runtimeScriptPath)
$script:RmfSourceRoot = [IO.Path]::GetDirectoryName($script:RmfEntryScriptPath)
$script:RmfBundledXaml = $null
$script:RmfStopLoading = $false
$script:RmfGuiCheckPassed = $false
$script:RmfRefreshTimerProbePassed = $false
$script:RmfRefreshDataProbePassed = $false
$script:RmfRefreshDataProbeDetails = ''
$script:RmfActivatedExistingInstance = $false

# RMF_BUNDLE_HEADER_END

$componentManifestPath = Join-Path $script:RmfSourceRoot 'Components.psd1'
if (-not (Test-Path -LiteralPath $componentManifestPath -PathType Leaf)) {
    throw "Application component manifest is missing: $componentManifestPath"
}

$componentManifest = Import-PowerShellDataFile -LiteralPath $componentManifestPath
foreach ($relativeComponentPath in @($componentManifest.Components)) {
    $componentPath = [IO.Path]::GetFullPath(
        (Join-Path $script:RmfSourceRoot $relativeComponentPath)
    )
    if (-not $componentPath.StartsWith(
        $script:RmfSourceRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Application component escapes the source directory: $relativeComponentPath"
    }
    if (-not (Test-Path -LiteralPath $componentPath -PathType Leaf)) {
        throw "Application component is missing: $componentPath"
    }
    . $componentPath
    if ($script:RmfStopLoading) {
        exit 0
    }
}
