function Assert-UsageSnapshotContract {
    param($Snapshot)

    if (-not $Snapshot) {
        throw 'Usage provider returned an empty snapshot.'
    }

    $requiredProperties = @(
        'ProviderId',
        'Available',
        'HasProgress',
        'RemainingPercent',
        'WindowLabel',
        'Plan',
        'AccountName',
        'AccountEmail',
        'SampledAt',
        'Status',
        'Source'
    )
    $missingProperties = @(
        $requiredProperties | Where-Object {
            -not $Snapshot.PSObject.Properties[$_]
        }
    )
    if ($missingProperties.Count -gt 0) {
        throw (
            'Usage provider snapshot is missing required properties: ' +
            ($missingProperties -join ', ')
        )
    }
}

function Format-UsageSnapshotAge {
    param([double]$AgeSeconds)

    $seconds = [Math]::Max(0, $AgeSeconds)
    if ($seconds -lt 90) { return '刚刚' }
    if ($seconds -lt 3600) {
        return '{0} 分钟前' -f [Math]::Max(
            1,
            [Math]::Floor($seconds / 60)
        )
    }
    if ($seconds -lt 86400) {
        return '{0} 小时前' -f [Math]::Max(
            1,
            [Math]::Floor($seconds / 3600)
        )
    }
    return '{0} 天前' -f [Math]::Max(
        1,
        [Math]::Floor($seconds / 86400)
    )
}

function Get-UsageSnapshotFreshness {
    param(
        $Snapshot,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now,
        [int]$DelayedAfterSeconds = 120,
        [int]$StaleAfterSeconds = 600
    )

    if (-not $Snapshot -or -not $Snapshot.PSObject.Properties['SampledAt']) {
        return [pscustomobject]@{
            State = 'Unknown'
            AgeSeconds = $null
            AgeText = '时间未知'
            IsStale = $false
        }
    }
    $sampledAt = [DateTimeOffset]$Snapshot.SampledAt
    $ageSeconds = [Math]::Max(
        0,
        ($Now.ToUniversalTime() - $sampledAt.ToUniversalTime()).TotalSeconds
    )
    $state = if (-not [bool]$Snapshot.Available) {
        'Unavailable'
    }
    elseif ($ageSeconds -gt $StaleAfterSeconds) {
        'Stale'
    }
    elseif ($ageSeconds -gt $DelayedAfterSeconds) {
        'Delayed'
    }
    else {
        'Fresh'
    }
    return [pscustomobject]@{
        State = $state
        AgeSeconds = [Math]::Round($ageSeconds, 1)
        AgeText = Format-UsageSnapshotAge -AgeSeconds $ageSeconds
        IsStale = $state -eq 'Stale'
    }
}

function Get-CodexCurrentUsageOverride {
    param(
        $OfficialUsage = $script:CodexOfficialUsageCache,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    if (-not $OfficialUsage) { return $null }
    $resetsAt = [long](Get-ObjectPropertyValue `
        -Object $OfficialUsage `
        -Name 'ResetsAt' `
        -Default 0)
    if ($resetsAt -gt 0 -and $resetsAt -le $Now.ToUnixTimeSeconds()) {
        return $null
    }

    return [pscustomobject]@{
        UsedPercent = [double]$OfficialUsage.UsedPercent
        WindowMinutes = [int]$OfficialUsage.WindowMinutes
        ResetsAt = $resetsAt
        PlanType = [string]$OfficialUsage.PlanType
        SampledAt = [DateTimeOffset]$OfficialUsage.SampledAt
        IsCached = $true
    }
}

function New-UsageFallbackSnapshot {
    param(
        $Snapshot,
        [string]$Reason
    )

    if (-not $Snapshot) { return $null }
    $fallback = $Snapshot.PSObject.Copy()
    $fallback | Add-Member `
        -NotePropertyName IsFallback `
        -NotePropertyValue $true `
        -Force
    $fallback | Add-Member `
        -NotePropertyName FallbackReason `
        -NotePropertyValue $Reason `
        -Force
    return $fallback
}

function Test-TransientRefreshFailure {
    param([int]$StatusCode)

    return (
        $StatusCode -eq 0 -or
        $StatusCode -in @(408, 425, 429, 500, 502, 503, 504)
    )
}

function Get-RefreshRetryDelaySeconds {
    param(
        [int]$Attempt,
        [double]$ServerDelaySeconds = 0,
        [double]$MaximumSeconds = 30
    )

    $exponentialDelay = [Math]::Pow(
        2,
        [Math]::Max(0, $Attempt - 1)
    )
    return [Math]::Min(
        $MaximumSeconds,
        [Math]::Max(1, [Math]::Max($exponentialDelay, $ServerDelaySeconds))
    )
}
