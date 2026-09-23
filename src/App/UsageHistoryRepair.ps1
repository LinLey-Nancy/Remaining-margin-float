if ($RepairUsageHistory) {
    try {
        $repairResult = Invoke-UsageHistoryStateBackfill -AllowDiagnosticWrite
        Invoke-UsageStateLightweightMaintenance `
            -MaxObjectDeletes 256 `
            -AllowDiagnosticWrite
        $repairResult | ConvertTo-Json -Compress
        $script:RmfStopLoading = $true
        return
    }
    catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        throw
    }
}

function Test-UsageHistoryRepairRunning {
    if (-not $global:RmfUsageHistoryRepairProcess) { return $false }
    try {
        $candidate = [Diagnostics.Process]::GetProcessById(
            $global:RmfUsageHistoryRepairProcess.Id
        )
        try {
            return $candidate.StartTime -eq
                $global:RmfUsageHistoryRepairProcess.StartTime
        }
        finally {
            $candidate.Dispose()
        }
    }
    catch {
        return $false
    }
}

function Complete-UsageHistoryRepair {
    if (-not $global:RmfUsageHistoryRepairProcess) { return $false }
    if (Test-UsageHistoryRepairRunning) { return $false }

    $exitCode = -1
    try {
        $global:RmfUsageHistoryRepairProcess.WaitForExit()
        $exitCode = $global:RmfUsageHistoryRepairProcess.ExitCode
        $global:RmfUsageHistoryRepairProcess.Dispose()
    }
    catch {
        # The repair process may fail while shutting down; cleanup must continue.
    }
    $global:RmfUsageHistoryRepairProcess = $null
    Write-RuntimeLog `
        -Level $(if ($exitCode -eq 0) { 'Info' } else { 'Warning' }) `
        -Event 'History.Repair.Completed' `
        -Message $(if ($exitCode -eq 0) {
            'Background usage history repair completed'
        } else {
            "Background usage history repair exited with code $exitCode"
        })
    return $true
}

function Start-UsageHistoryRepair {
    if (
        $isDiagnosticRun -or
        $global:RmfUsageHistoryRepairStarted -or
        $global:RmfUsageHistoryRepairProcess
    ) { return }
    $global:RmfUsageHistoryRepairStarted = $true
    $stateRoot = Get-UsageStateHistoryDirectory
    if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) { return }
    $hasState = (
        (Test-Path -LiteralPath (Get-UsageStateCurrentPath) -PathType Leaf) -or
        (Test-Path -LiteralPath (Get-UsageStateManifestPath) -PathType Leaf) -or
        (Test-Path -LiteralPath (Get-UsageStateEntriesDirectory) -PathType Container)
    )
    if (-not $hasState) { return }
    try {
        $trustedLauncherPath = [Environment]::GetEnvironmentVariable(
            'REMAINING_MARGIN_FLOAT_LAUNCHER',
            [EnvironmentVariableTarget]::Process
        )
        if (
            [string]::IsNullOrWhiteSpace($trustedLauncherPath) -or
            -not (Test-Path -LiteralPath $trustedLauncherPath -PathType Leaf)
        ) {
            throw 'Background repair requires the validated packaged host.'
        }
        $repairEnvironmentName =
            'REMAINING_MARGIN_FLOAT_REPAIR_USAGE_HISTORY'
        $previousRepairEnvironment = [Environment]::GetEnvironmentVariable(
            $repairEnvironmentName,
            [EnvironmentVariableTarget]::Process
        )
        $repairParentEnvironmentName =
            'REMAINING_MARGIN_FLOAT_REPAIR_PARENT_PID'
        $previousRepairParentEnvironment = [Environment]::GetEnvironmentVariable(
            $repairParentEnvironmentName,
            [EnvironmentVariableTarget]::Process
        )
        try {
            [Environment]::SetEnvironmentVariable(
                $repairEnvironmentName,
                '1',
                [EnvironmentVariableTarget]::Process
            )
            [Environment]::SetEnvironmentVariable(
                $repairParentEnvironmentName,
                [string]$PID,
                [EnvironmentVariableTarget]::Process
            )
            $global:RmfUsageHistoryRepairProcess = Start-Process `
                -FilePath $trustedLauncherPath `
                -ArgumentList '--repair-usage-history' `
                -WindowStyle Hidden `
                -PassThru
        }
        finally {
            [Environment]::SetEnvironmentVariable(
                $repairEnvironmentName,
                $previousRepairEnvironment,
                [EnvironmentVariableTarget]::Process
            )
            [Environment]::SetEnvironmentVariable(
                $repairParentEnvironmentName,
                $previousRepairParentEnvironment,
                [EnvironmentVariableTarget]::Process
            )
        }
        Write-RuntimeLog `
            -Event 'History.Repair.Started' `
            -Message 'Usage history repair started in the validated background host' `
            -Data @{ ProcessId = $global:RmfUsageHistoryRepairProcess.Id }
    }
    catch {
        $global:RmfUsageHistoryRepairProcess = $null
        Write-RuntimeLog `
            -Level 'Warning' `
            -Event 'History.Repair.StartFailed' `
            -Message $_.Exception.Message
    }
}

function Stop-UsageHistoryRepair {
    param([int]$GraceMilliseconds = 250)

    if (-not $global:RmfUsageHistoryRepairProcess) { return $false }
    $process = $global:RmfUsageHistoryRepairProcess
    $stopped = $false
    try {
        $process.Refresh()
        if (-not $process.HasExited) {
            $stopped = $process.WaitForExit($GraceMilliseconds)
        } else {
            $stopped = $true
        }
        if (-not $stopped) {
            $process.Kill()
            $stopped = $process.WaitForExit(1000)
        }
        Write-RuntimeLog `
            -Level $(if ($stopped) { 'Info' } else { 'Warning' }) `
            -Event 'History.Repair.Stopped' `
            -Message $(if ($stopped) {
                'Background usage history repair stopped before exit'
            } else {
                'Background usage history repair did not stop before the exit deadline'
            })
    }
    catch {
        Write-RuntimeLog `
            -Level 'Warning' `
            -Event 'History.Repair.StopFailed' `
            -Message $_.Exception.Message
    }
    finally {
        try { $process.Dispose() } catch {
            # Stopping is best-effort; a failed dispose must not propagate.
        }
        $global:RmfUsageHistoryRepairProcess = $null
    }
    return $stopped
}
