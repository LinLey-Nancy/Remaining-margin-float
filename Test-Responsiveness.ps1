param(
    [string]$ExecutablePath = (
        Join-Path $PSScriptRoot (
            ('dist\Remaining-Margin-Float-v{0}\RemainingMarginFloat.exe' -f
                ((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()))
        )
    ),
    [ValidateRange(10, 180)]
    [int]$DurationSeconds = 75
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$resolvedExecutable = [IO.Path]::GetFullPath($ExecutablePath)
if (-not (Test-Path -LiteralPath $resolvedExecutable -PathType Leaf)) {
    throw "Executable is missing: $resolvedExecutable"
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$probeRoot = [IO.Path]::GetFullPath((Join-Path $tempRoot (
    'RemainingMarginFloat.UiProbe.{0}' -f [Guid]::NewGuid().ToString('N')
)))
if (-not $probeRoot.StartsWith(
    $tempRoot,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw 'Probe path escaped the temporary directory.'
}
$probeAppData = Join-Path $probeRoot 'RemainingMarginFloat'
[void](New-Item -ItemType Directory -Path $probeAppData -Force)

# Seed a recent legacy full-state snapshot so the packaged application must
# exercise its trusted background repair path on every machine, including CI.
$savedDiagnosticMode = Get-Variable -Name isDiagnosticRun -ErrorAction SilentlyContinue
$savedAppVersion = Get-Variable -Name AppVersion -Scope Script -ErrorAction SilentlyContinue
try {
    $isDiagnosticRun = $true
    $script:AppVersion = (
        Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw
    ).Trim()
    Add-Type -AssemblyName System.Security
    . (Join-Path $PSScriptRoot 'src\Infrastructure\LocalStorage.ps1')
    . (Join-Path $PSScriptRoot 'src\Core\UsageSnapshot.ps1')
    . (Join-Path $PSScriptRoot 'src\Core\StateHistory.ps1')
    $seedObservedAt = [DateTimeOffset]::Now.AddMinutes(-10)
    $seedSnapshot = [pscustomobject][ordered]@{
        ProviderId = 'Codex'
        Available = $true
        HasProgress = $true
        PrimaryQuotaPeriod = 'Weekly'
        WeeklyAvailable = $true
        FiveHourAvailable = $false
        RemainingPercent = 41.5
        WindowLabel = 'Weekly quota'
        ResetDate = $seedObservedAt.AddDays(4).ToString('MM-dd HH:mm')
        ResetCountdown = '4 days'
        FiveHourUsedPercent = 0
        FiveHourRemainingPercent = 0
        FiveHourResetDate = ''
        FiveHourResetCountdown = ''
        FiveHourResetAt = $null
        WeeklyUsedPercent = 58.5
        WeeklyRemainingPercent = 41.5
        WeeklyResetDate = $seedObservedAt.AddDays(4).ToString('MM-dd HH:mm')
        WeeklyResetCountdown = '4 days'
        WeeklyResetAt = $seedObservedAt.AddDays(4)
        ResetCount = 'not provided'
        PlanType = 'pro'
        Plan = 'Pro'
        AccountName = 'Responsiveness Probe'
        AccountEmail = ''
        TodayTokens = 0
        TodayInputTokens = 0
        TodayOutputTokens = 0
        TodayCachedTokens = 0
        TodayCacheHitPercent = 0
        LastTurnTokens = 0
        InputTokens = 0
        OutputTokens = 0
        CachedTokens = 0
        CacheHitPercent = 0
        ContextPercent = 0
        SampledAt = $seedObservedAt
        ResetAt = $seedObservedAt.AddDays(4)
        Status = 'Healthy'
        Source = 'Responsiveness probe'
    }
    $stateHistoryRoot = Join-Path $probeAppData 'state-history'
    [void](Save-UsageStateSnapshot `
        -Snapshot $seedSnapshot `
        -ObservedAt $seedObservedAt `
        -Reason 'Manual' `
        -RootPath $stateHistoryRoot `
        -AllowDiagnosticWrite)
    $backfillMarkerPath = Join-Path `
        $stateHistoryRoot `
        'usage-history-backfill.json'
    if (Test-Path -LiteralPath $backfillMarkerPath) {
        Remove-Item -LiteralPath $backfillMarkerPath -Force
    }
    [IO.File]::WriteAllText(
        (Join-Path $probeAppData 'settings.json'),
        '{"Provider":"Codex","CodexOfficialAccessEnabled":true,"AutoUpdateEnabled":false}',
        (New-Object Text.UTF8Encoding($false))
    )
}
finally {
    if ($savedDiagnosticMode) {
        Set-Variable `
            -Name isDiagnosticRun `
            -Value $savedDiagnosticMode.Value
    } else {
        Remove-Variable -Name isDiagnosticRun -ErrorAction SilentlyContinue
    }
    if ($savedAppVersion) {
        $script:AppVersion = $savedAppVersion.Value
    } else {
        Remove-Variable -Name AppVersion -Scope Script -ErrorAction SilentlyContinue
    }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class RmfUiProbeNative
{
    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point
    {
        public int X;
        public int Y;
    }

    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr value);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool GetClientRect(IntPtr hwnd, out Rect rect);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SendMessageTimeout(
        IntPtr hwnd,
        uint message,
        IntPtr wParam,
        IntPtr lParam,
        uint flags,
        uint timeout,
        out IntPtr result
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostMessage(
        IntPtr hwnd,
        uint message,
        IntPtr wParam,
        IntPtr lParam
    );

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out Point point);

    [DllImport("user32.dll")]
    private static extern void mouse_event(
        uint flags,
        uint dx,
        uint dy,
        uint data,
        UIntPtr extraInfo
    );

    public static IntPtr FindWindow(int processId)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hwnd, IntPtr value) {
            uint candidateProcessId;
            GetWindowThreadProcessId(hwnd, out candidateProcessId);
            if (candidateProcessId == (uint)processId && IsWindowVisible(hwnd)) {
                found = hwnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static bool Probe(IntPtr hwnd, int timeoutMilliseconds)
    {
        IntPtr result;
        return SendMessageTimeout(
            hwnd,
            0,
            IntPtr.Zero,
            IntPtr.Zero,
            2,
            (uint)timeoutMilliseconds,
            out result
        ) != IntPtr.Zero;
    }

    public static bool Close(IntPtr hwnd)
    {
        return PostMessage(hwnd, 0x0010, IntPtr.Zero, IntPtr.Zero);
    }

    public static int GetWindowWidth(IntPtr hwnd)
    {
        Rect rect;
        return GetWindowRect(hwnd, out rect) ? rect.Right - rect.Left : 0;
    }

    public static bool CollapseDetails(IntPtr hwnd)
    {
        SetForegroundWindow(hwnd);
        bool down = PostMessage(hwnd, 0x0100, new IntPtr(0x1B), IntPtr.Zero);
        bool up = PostMessage(hwnd, 0x0101, new IntPtr(0x1B), IntPtr.Zero);
        return down && up;
    }

    public static bool ClickCenter(IntPtr hwnd)
    {
        Rect rect;
        Point previous;
        if (!GetWindowRect(hwnd, out rect) || !GetCursorPos(out previous)) {
            return false;
        }
        int x = rect.Left + Math.Max(1, (rect.Right - rect.Left) / 2);
        int y = rect.Top + Math.Max(1, (rect.Bottom - rect.Top) / 2);
        SetForegroundWindow(hwnd);
        if (!SetCursorPos(x, y)) {
            return false;
        }
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(40);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(40);
        SetCursorPos(previous.X, previous.Y);
        return true;
    }
}
'@

$previousLocalAppData = $env:LOCALAPPDATA
$previousScope = $env:REMAINING_MARGIN_FLOAT_INSTANCE_SCOPE
$process = $null
try {
    $env:LOCALAPPDATA = $probeRoot
    $env:REMAINING_MARGIN_FLOAT_INSTANCE_SCOPE =
        'ui-probe-' + [Guid]::NewGuid().ToString('N')
    $process = Start-Process -FilePath $resolvedExecutable -PassThru
    $env:LOCALAPPDATA = $previousLocalAppData
    $env:REMAINING_MARGIN_FLOAT_INSTANCE_SCOPE = $previousScope

    $deadline = [DateTimeOffset]::Now.AddSeconds(20)
    $windowHandle = [IntPtr]::Zero
    while (
        [DateTimeOffset]::Now -lt $deadline -and
        $windowHandle -eq [IntPtr]::Zero
    ) {
        Start-Sleep -Milliseconds 100
        $process.Refresh()
        if ($process.HasExited) {
            throw "Probe application exited early: $($process.ExitCode)"
        }
        $windowHandle = [RmfUiProbeNative]::FindWindow($process.Id)
    }
    if ($windowHandle -eq [IntPtr]::Zero) {
        throw 'Probe application window was not found.'
    }

    $samples = 0
    $timeouts = 0
    $slowSamples = 0
    $hangClusters = 0
    $hangClusterDetails = New-Object Collections.Generic.List[object]
    $hangClusterStartedAt = 0.0
    $maxProbeMilliseconds = 0L
    $inHangCluster = $false
    $expandActionSent = $false
    $expandedStateObserved = $false
    $collapseActionSent = $false
    $collapsedStateObserved = $false
    $lastExpandAttemptAt = -1.0
    $lastCollapseAttemptAt = -1.0
    $monitor = [Diagnostics.Stopwatch]::StartNew()
    while ($monitor.Elapsed.TotalSeconds -lt $DurationSeconds) {
        $windowWidth = [RmfUiProbeNative]::GetWindowWidth($windowHandle)
        if ($windowWidth -ge 200) {
            $expandedStateObserved = $true
        }
        elseif ($expandedStateObserved -and $windowWidth -gt 0 -and $windowWidth -lt 150) {
            $collapsedStateObserved = $true
        }
        if (
            -not $expandedStateObserved -and
            $monitor.Elapsed.TotalSeconds -ge 10 -and
            ($lastExpandAttemptAt -lt 0 -or
                $monitor.Elapsed.TotalSeconds - $lastExpandAttemptAt -ge 1)
        ) {
            $lastExpandAttemptAt = $monitor.Elapsed.TotalSeconds
            $expandActionSent = (
                [RmfUiProbeNative]::ClickCenter($windowHandle) -or
                $expandActionSent
            )
        }
        if (
            $expandedStateObserved -and
            -not $collapsedStateObserved -and
            $monitor.Elapsed.TotalSeconds -ge 15 -and
            ($lastCollapseAttemptAt -lt 0 -or
                $monitor.Elapsed.TotalSeconds - $lastCollapseAttemptAt -ge 1)
        ) {
            $lastCollapseAttemptAt = $monitor.Elapsed.TotalSeconds
            $collapseActionSent = (
                [RmfUiProbeNative]::CollapseDetails($windowHandle) -or
                $collapseActionSent
            )
        }
        $probeTimer = [Diagnostics.Stopwatch]::StartNew()
        $responsive = [RmfUiProbeNative]::Probe($windowHandle, 250)
        $probeTimer.Stop()
        $samples++
        if (-not $responsive) {
            $timeouts++
            if (-not $inHangCluster) {
                $hangClusters++
                $inHangCluster = $true
                $hangClusterStartedAt = $monitor.Elapsed.TotalSeconds
            }
        }
        else {
            if ($inHangCluster) {
                [void]$hangClusterDetails.Add([pscustomobject]@{
                    StartedAtSeconds = [Math]::Round($hangClusterStartedAt, 2)
                    EndedAtSeconds = [Math]::Round($monitor.Elapsed.TotalSeconds, 2)
                    DurationSeconds = [Math]::Round(
                        $monitor.Elapsed.TotalSeconds - $hangClusterStartedAt,
                        2
                    )
                })
            }
            $inHangCluster = $false
            if ($probeTimer.ElapsedMilliseconds -ge 100) {
                $slowSamples++
            }
        }
        if ($probeTimer.ElapsedMilliseconds -gt $maxProbeMilliseconds) {
            $maxProbeMilliseconds = $probeTimer.ElapsedMilliseconds
        }
        Start-Sleep -Milliseconds 50
    }
    if ($inHangCluster) {
        [void]$hangClusterDetails.Add([pscustomobject]@{
            StartedAtSeconds = [Math]::Round($hangClusterStartedAt, 2)
            EndedAtSeconds = [Math]::Round($monitor.Elapsed.TotalSeconds, 2)
            DurationSeconds = [Math]::Round(
                $monitor.Elapsed.TotalSeconds - $hangClusterStartedAt,
                2
            )
        })
    }

    $closeTimer = [Diagnostics.Stopwatch]::StartNew()
    [void][RmfUiProbeNative]::Close($windowHandle)
    $windowDeadline = [DateTimeOffset]::Now.AddSeconds(10)
    while (
        [DateTimeOffset]::Now -lt $windowDeadline -and
        [RmfUiProbeNative]::FindWindow($process.Id) -ne [IntPtr]::Zero
    ) {
        Start-Sleep -Milliseconds 10
    }
    $windowCloseMilliseconds = $closeTimer.ElapsedMilliseconds
    if (-not $process.WaitForExit(10000)) {
        throw 'Probe application did not close within 10 seconds.'
    }
    $closeTimer.Stop()

    $logPath = Join-Path $probeAppData 'logs\runtime.log'
    $logEvents = @()
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        $logEvents = @(
            Get-Content -LiteralPath $logPath -Encoding UTF8 |
                ForEach-Object {
                    try { $_ | ConvertFrom-Json } catch { $null }
                } |
                Where-Object { $null -ne $_ } |
                Select-Object ts, event, level, elapsedMs, message, data
        )
    }
    $longestHangSeconds = if ($hangClusterDetails.Count -gt 0) {
        [double](($hangClusterDetails | Measure-Object `
            -Property DurationSeconds `
            -Maximum).Maximum)
    }
    else { 0.0 }
    $expandedStateEvents = @(
        $logEvents | Where-Object {
            $_.event -eq 'Window.ExpandedStateChanged'
        }
    )
    $expandEventLogged = @(
        $expandedStateEvents | Where-Object {
            $_.data -and [bool]$_.data.Expanded
        }
    ).Count -gt 0
    $collapseEvent = $expandedStateEvents | Where-Object {
        $_.data -and -not [bool]$_.data.Expanded
    } | Select-Object -First 1
    $unexpectedReexpandCount = if ($collapseEvent) {
        @($expandedStateEvents | Where-Object {
            $_.data -and
            [bool]$_.data.Expanded -and
            [DateTimeOffset]$_.ts -gt [DateTimeOffset]$collapseEvent.ts
        }).Count
    } else { -1 }
    $repairStarted = @(
        $logEvents | Where-Object { $_.event -eq 'History.Repair.Started' }
    ).Count -gt 0
    $repairCompleted = @(
        $logEvents | Where-Object { $_.event -eq 'History.Repair.Completed' }
    ).Count -gt 0
    $refreshEvents = @(
        $logEvents | Where-Object { $_.event -eq 'Refresh.Completed' }
    )
    $repairCompletion = $logEvents | Where-Object {
        $_.event -eq 'History.Repair.Completed'
    } | Select-Object -Last 1
    $refreshResumedAfterRepair = if ($repairCompletion) {
        @($refreshEvents | Where-Object {
            [DateTimeOffset]$_.ts -gt [DateTimeOffset]$repairCompletion.ts
        }).Count -gt 0
    } else { $false }
    $errorEventCount = @(
        $logEvents | Where-Object { $_.level -eq 'Error' }
    ).Count
    $localPreviewSuppressedCount = @(
        $logEvents | Where-Object {
            $_.event -eq 'Refresh.LocalPreviewSuppressed'
        }
    ).Count
    $localPreviewStateWriteCount = @(
        $logEvents | Where-Object {
            $_.event -eq 'StateHistory.Saved' -and
            $_.data -and
            $_.data.Reason -eq 'LocalPreview'
        }
    ).Count
    $closingEvent = $logEvents | Where-Object {
        $_.event -eq 'App.Closing.Completed'
    } | Select-Object -Last 1
    $pendingHistoryUpdates = if (
        $closingEvent -and
        $closingEvent.data -and
        $null -ne $closingEvent.data.PendingHistoryUpdates
    ) {
        [int]$closingEvent.data.PendingHistoryUpdates
    } else { -1 }
    $historyPath = Join-Path $probeAppData 'usage-history.jsonl'
    $weeklyRepairSamplePresent = $false
    if (Test-Path -LiteralPath $historyPath -PathType Leaf) {
        $weeklyRepairSamplePresent = @(
            Get-Content -LiteralPath $historyPath -Encoding UTF8 | ForEach-Object {
                try { $_ | ConvertFrom-Json } catch { $null }
            } | Where-Object {
                $_ -and
                $_.ProviderId -eq 'Codex' -and
                $_.QuotaPeriod -eq 'Weekly' -and
                [Math]::Abs([double]$_.RemainingValue - 41.5) -lt 0.0001
            }
        ).Count -gt 0
    }
    [pscustomobject]@{
        Passed = (
            $longestHangSeconds -lt 3 -and
            $windowCloseMilliseconds -lt 1500 -and
            $process.ExitCode -eq 0 -and
            $expandActionSent -and
            $expandedStateObserved -and
            $collapsedStateObserved -and
            $expandEventLogged -and
            $collapseEvent -and
            $unexpectedReexpandCount -eq 0 -and
            $repairStarted -and
            $repairCompleted -and
            $refreshEvents.Count -ge 2 -and
            $refreshResumedAfterRepair -and
            $weeklyRepairSamplePresent -and
            $pendingHistoryUpdates -eq 0 -and
            $localPreviewSuppressedCount -ge 1 -and
            $localPreviewStateWriteCount -eq 0 -and
            $errorEventCount -eq 0
        )
        ProcessId = $process.Id
        Samples = $samples
        Timeouts = $timeouts
        SlowSamples = $slowSamples
        HangClusters = $hangClusters
        LongestHangSeconds = $longestHangSeconds
        HangClusterDetails = $hangClusterDetails.ToArray()
        MaxProbeMilliseconds = $maxProbeMilliseconds
        ExpandActionSent = $expandActionSent
        ExpandedStateObserved = $expandedStateObserved
        CollapseActionSent = $collapseActionSent
        CollapsedStateObserved = $collapsedStateObserved
        ExpandEventLogged = $expandEventLogged
        CollapseEventLogged = [bool]$collapseEvent
        UnexpectedReexpandCount = $unexpectedReexpandCount
        RepairStarted = $repairStarted
        RepairCompleted = $repairCompleted
        RefreshCompletedCount = $refreshEvents.Count
        RefreshResumedAfterRepair = $refreshResumedAfterRepair
        WeeklyRepairSamplePresent = $weeklyRepairSamplePresent
        PendingHistoryUpdates = $pendingHistoryUpdates
        LocalPreviewSuppressedCount = $localPreviewSuppressedCount
        LocalPreviewStateWriteCount = $localPreviewStateWriteCount
        ErrorEventCount = $errorEventCount
        WindowCloseMilliseconds = $windowCloseMilliseconds
        CloseMilliseconds = $closeTimer.ElapsedMilliseconds
        ExitCode = $process.ExitCode
        RuntimeLogEvents = $logEvents
    } | ConvertTo-Json -Depth 6
}
finally {
    $env:LOCALAPPDATA = $previousLocalAppData
    $env:REMAINING_MARGIN_FLOAT_INSTANCE_SCOPE = $previousScope
    if ($process) {
        try {
            $process.Refresh()
            if (-not $process.HasExited) {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            }
        }
        catch {
            # The process may already have exited on its own; killing is best-effort.
        }
        $process.Dispose()
    }
    if (
        (Test-Path -LiteralPath $probeRoot) -and
        $probeRoot.StartsWith(
            $tempRoot,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        Remove-Item -LiteralPath $probeRoot -Recurse -Force
    }
}
