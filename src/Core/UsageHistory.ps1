function Get-UsageHistoryPath {
    return Join-Path (Get-AppDataDirectory) 'usage-history.jsonl'
}

function ConvertTo-UsageHistorySample {
    param(
        $Snapshot,
        [DateTimeOffset]$ObservedAt = [DateTimeOffset]::Now
    )

    if (-not $Snapshot -or -not [bool]$Snapshot.Available) {
        return $null
    }

    $metricType = ''
    $remainingValue = 0.0
    $unit = ''
    if ([bool]$Snapshot.HasProgress) {
        $metricType = 'Percent'
        $remainingValue = [Math]::Max(
            0,
            [Math]::Min(100, [double]$Snapshot.RemainingPercent)
        )
        $unit = '%'
    }
    elseif (
        [string]$Snapshot.ProviderId -eq 'DeepSeek' -and
        $Snapshot.PSObject.Properties['TotalBalance']
    ) {
        $metricType = 'Balance'
        $remainingValue = [Math]::Max(0, [double]$Snapshot.TotalBalance)
        $unit = if ($Snapshot.PSObject.Properties['Currency']) {
            [string]$Snapshot.Currency
        } else {
            'CNY'
        }
    }
    else {
        return $null
    }

    $resetAtUtc = ''
    if (
        $Snapshot.PSObject.Properties['ResetAt'] -and
        $null -ne $Snapshot.ResetAt
    ) {
        try {
            $resetAtUtc = ([DateTimeOffset]$Snapshot.ResetAt).
                ToUniversalTime().
                ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        }
        catch {
            $resetAtUtc = ''
        }
    }

    return [pscustomobject]@{
        Version = 1
        ProviderId = [string]$Snapshot.ProviderId
        ObservedAtUtc = $ObservedAt.ToUniversalTime()
        MetricType = $metricType
        RemainingValue = [Math]::Round($remainingValue, 4)
        Unit = $unit
        ResetAtUtc = $resetAtUtc
    }
}

function Read-UsageHistory {
    if ($null -ne $script:UsageHistoryCache) {
        return @($script:UsageHistoryCache)
    }

    $items = New-Object Collections.Generic.List[object]
    $path = Get-UsageHistoryPath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        foreach ($line in (Get-Content -LiteralPath $path -Encoding UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $saved = $line | ConvertFrom-Json
                $providerId = [string]$saved.ProviderId
                $metricType = [string]$saved.MetricType
                $observedAt = [DateTimeOffset]::Parse(
                    [string]$saved.ObservedAtUtc,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind
                )
                if (
                    $providerId -notin @('Codex', 'DeepSeek') -or
                    $metricType -notin @('Percent', 'Balance')
                ) {
                    continue
                }
                $items.Add([pscustomobject]@{
                    Version = 1
                    ProviderId = $providerId
                    ObservedAtUtc = $observedAt.ToUniversalTime()
                    MetricType = $metricType
                    RemainingValue = [double]$saved.RemainingValue
                    Unit = [string]$saved.Unit
                    ResetAtUtc = if ($saved.PSObject.Properties['ResetAtUtc']) {
                        [string]$saved.ResetAtUtc
                    } else {
                        ''
                    }
                })
            }
            catch {
                # A damaged history line is ignored without discarding valid samples.
            }
        }
    }

    $cutoff = [DateTimeOffset]::UtcNow.AddDays(-8)
    $script:UsageHistoryCache = @(
        $items |
            Where-Object { $_.ObservedAtUtc -ge $cutoff } |
            Sort-Object ObservedAtUtc
    )
    return @($script:UsageHistoryCache)
}

function Save-UsageHistory {
    param(
        [object[]]$Samples,
        [string]$Path = '',
        [switch]$AllowDiagnosticWrite
    )

    if ($isDiagnosticRun -and -not $AllowDiagnosticWrite) { return }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Get-UsageHistoryPath
    }
    $path = [IO.Path]::GetFullPath($Path)
    $temporaryPath = '{0}.tmp.{1}.{2}' -f
        $path,
        $PID,
        [Guid]::NewGuid().ToString('N')
    $backupPath = '{0}.bak.{1}.{2}' -f
        $path,
        $PID,
        [Guid]::NewGuid().ToString('N')
    $lines = @(
        $Samples | Sort-Object ObservedAtUtc | ForEach-Object {
            [ordered]@{
                v = 1
                ProviderId = [string]$_.ProviderId
                ObservedAtUtc = ([DateTimeOffset]$_.ObservedAtUtc).
                    ToUniversalTime().
                    ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                MetricType = [string]$_.MetricType
                RemainingValue = [Math]::Round([double]$_.RemainingValue, 4)
                Unit = [string]$_.Unit
                ResetAtUtc = [string]$_.ResetAtUtc
            } | ConvertTo-Json -Compress
        }
    )

    try {
        [IO.File]::WriteAllLines(
            $temporaryPath,
            $lines,
            (New-Object Text.UTF8Encoding($false))
        )
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            [IO.File]::Replace($temporaryPath, $path, $backupPath, $true)
        }
        else {
            Move-Item -LiteralPath $temporaryPath -Destination $path
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force
        }
    }
}

function Add-UsageHistorySample {
    param(
        $Snapshot,
        [DateTimeOffset]$ObservedAt = [DateTimeOffset]::Now
    )

    $currentSample = ConvertTo-UsageHistorySample `
        -Snapshot $Snapshot `
        -ObservedAt $ObservedAt
    $history = @(Read-UsageHistory)
    if (-not $currentSample) {
        return [pscustomobject]@{
            Samples = $history
            CurrentSample = $null
            PreviousSample = $null
            Changed = $false
        }
    }

    $matchingSamples = @(
        $history | Where-Object {
            $_.ProviderId -eq $currentSample.ProviderId -and
            $_.MetricType -eq $currentSample.MetricType -and
            $_.Unit -eq $currentSample.Unit
        } | Sort-Object ObservedAtUtc
    )
    $previousSample = $matchingSamples | Select-Object -Last 1
    if ($isDiagnosticRun) {
        return [pscustomobject]@{
            Samples = @($history + $currentSample)
            CurrentSample = $currentSample
            PreviousSample = $previousSample
            Changed = $false
        }
    }

    $changed = $true
    if ($previousSample) {
        $elapsed = $currentSample.ObservedAtUtc - $previousSample.ObservedAtUtc
        if ($elapsed.TotalMinutes -lt 2) {
            $replaced = $false
            $updatedHistory = New-Object Collections.Generic.List[object]
            foreach ($item in $history) {
                if (-not $replaced -and [object]::ReferenceEquals($item, $previousSample)) {
                    $updatedHistory.Add($currentSample)
                    $replaced = $true
                }
                else {
                    $updatedHistory.Add($item)
                }
            }
            $history = @($updatedHistory)
        }
        elseif (
            $elapsed.TotalMinutes -lt 5 -and
            [Math]::Abs(
                [double]$currentSample.RemainingValue -
                [double]$previousSample.RemainingValue
            ) -lt 0.0001
        ) {
            $changed = $false
        }
        else {
            $history = @($history + $currentSample)
        }
    }
    else {
        $history = @($history + $currentSample)
    }

    if ($changed) {
        $cutoff = $ObservedAt.ToUniversalTime().AddDays(-8)
        $history = @(
            $history |
                Where-Object { $_.ObservedAtUtc -ge $cutoff } |
                Sort-Object ObservedAtUtc
        )
        $script:UsageHistoryCache = $history
        try {
            Save-UsageHistory -Samples $history
        }
        catch {
            # Trend persistence is optional and must not break a refresh.
        }
    }

    return [pscustomobject]@{
        Samples = $history
        CurrentSample = $currentSample
        PreviousSample = $previousSample
        Changed = $changed
    }
}

function Get-UsageTrend {
    param(
        [object[]]$Samples,
        $CurrentSample,
        [double]$Hours,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    if (-not $CurrentSample) {
        return [pscustomobject]@{
            Hours = $Hours
            Samples = @()
            Change = 0.0
            Summary = '暂无数据'
        }
    }

    $cutoff = $Now.ToUniversalTime().AddHours(-$Hours)
    $series = @(
        $Samples | Where-Object {
            $_.ProviderId -eq $CurrentSample.ProviderId -and
            $_.MetricType -eq $CurrentSample.MetricType -and
            $_.Unit -eq $CurrentSample.Unit -and
            $_.ObservedAtUtc -ge $cutoff
        } | Sort-Object ObservedAtUtc
    )
    if ($series.Count -lt 2) {
        return [pscustomobject]@{
            Hours = $Hours
            Samples = $series
            Change = 0.0
            Summary = '积累中'
        }
    }

    $change = [double]$series[-1].RemainingValue - [double]$series[0].RemainingValue
    $absoluteChange = [Math]::Abs($change)
    if ($absoluteChange -lt 0.05) {
        $summary = '基本持平'
    }
    elseif ($CurrentSample.MetricType -eq 'Percent') {
        $summary = if ($change -lt 0) {
            '下降 {0:0.#}pp' -f $absoluteChange
        } else {
            '上升 {0:0.#}pp' -f $absoluteChange
        }
    }
    else {
        $formattedAmount = Format-CurrencyAmount `
            -Amount $absoluteChange `
            -Currency $CurrentSample.Unit
        $summary = if ($change -lt 0) {
            "减少 $formattedAmount"
        } else {
            "增加 $formattedAmount"
        }
    }

    return [pscustomobject]@{
        Hours = $Hours
        Samples = $series
        Change = $change
        Summary = $summary
    }
}

function Get-DepletionForecast {
    param(
        [object[]]$Samples,
        $CurrentSample,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    $insufficient = [pscustomobject]@{
        Status = 'Insufficient'
        HoursToEmpty = $null
        RatePerHour = 0.0
        Text = '积累 30 分钟后预测'
    }
    if (-not $CurrentSample) { return $insufficient }

    $matching = @(
        $Samples | Where-Object {
            $_.ProviderId -eq $CurrentSample.ProviderId -and
            $_.MetricType -eq $CurrentSample.MetricType -and
            $_.Unit -eq $CurrentSample.Unit -and
            $_.ObservedAtUtc -ge $Now.ToUniversalTime().AddDays(-7)
        } | Sort-Object ObservedAtUtc
    )
    $recent = @(
        $matching | Where-Object {
            $_.ObservedAtUtc -ge $Now.ToUniversalTime().AddHours(-24)
        }
    )
    if ($recent.Count -ge 3) {
        $matching = $recent
    }

    if ($matching.Count -lt 3) { return $insufficient }

    $resetIncrease = if ($CurrentSample.MetricType -eq 'Percent') {
        5.0
    } else {
        [Math]::Max(0.01, [double]$CurrentSample.RemainingValue * 0.01)
    }
    $segmentStart = 0
    for ($index = 1; $index -lt $matching.Count; $index++) {
        $increase = (
            [double]$matching[$index].RemainingValue -
            [double]$matching[$index - 1].RemainingValue
        )
        if ($increase -gt $resetIncrease) {
            $segmentStart = $index
        }
    }
    $segment = @($matching[$segmentStart..($matching.Count - 1)])
    if ($segment.Count -lt 3) { return $insufficient }

    $origin = [DateTimeOffset]$segment[0].ObservedAtUtc
    $spanHours = (
        ([DateTimeOffset]$segment[-1].ObservedAtUtc) - $origin
    ).TotalHours
    if ($spanHours -lt 0.5) { return $insufficient }

    $points = @(
        $segment | ForEach-Object {
            [pscustomobject]@{
                X = (([DateTimeOffset]$_.ObservedAtUtc) - $origin).TotalHours
                Y = [double]$_.RemainingValue
            }
        }
    )
    $meanX = ($points | Measure-Object X -Average).Average
    $meanY = ($points | Measure-Object Y -Average).Average
    $numerator = 0.0
    $denominator = 0.0
    foreach ($point in $points) {
        $xDistance = [double]$point.X - [double]$meanX
        $numerator += $xDistance * ([double]$point.Y - [double]$meanY)
        $denominator += $xDistance * $xDistance
    }
    if ($denominator -le 0) { return $insufficient }

    $slope = $numerator / $denominator
    $minimumRate = if ($CurrentSample.MetricType -eq 'Percent') { 0.05 } else { 0.001 }
    if ($slope -ge -$minimumRate) {
        return [pscustomobject]@{
            Status = 'Stable'
            HoursToEmpty = $null
            RatePerHour = $slope
            Text = '当前消耗较慢'
        }
    }

    $currentValue = [Math]::Max(0, [double]$CurrentSample.RemainingValue)
    $hoursToEmpty = $currentValue / (-$slope)
    if ($hoursToEmpty -gt (24 * 30)) {
        return [pscustomobject]@{
            Status = 'Stable'
            HoursToEmpty = $hoursToEmpty
            RatePerHour = $slope
            Text = '按当前速度可用 30 天以上'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$CurrentSample.ResetAtUtc)) {
        try {
            $resetAt = [DateTimeOffset]::Parse(
                [string]$CurrentSample.ResetAtUtc,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind
            )
            $hoursToReset = ($resetAt - $Now.ToUniversalTime()).TotalHours
            if ($hoursToReset -gt 0 -and $hoursToEmpty -ge $hoursToReset) {
                return [pscustomobject]@{
                    Status = 'BeyondReset'
                    HoursToEmpty = $hoursToEmpty
                    RatePerHour = $slope
                    Text = '预计重置前不会耗尽'
                }
            }
        }
        catch {
            # Invalid optional reset metadata does not block a forecast.
        }
    }

    $durationText = if ($hoursToEmpty -lt 1) {
        '{0} 分钟' -f [Math]::Max(1, [Math]::Round($hoursToEmpty * 60))
    }
    elseif ($hoursToEmpty -lt 24) {
        '{0:0.#} 小时' -f $hoursToEmpty
    }
    else {
        '{0:0.#} 天' -f ($hoursToEmpty / 24)
    }
    return [pscustomobject]@{
        Status = 'Depleting'
        HoursToEmpty = $hoursToEmpty
        RatePerHour = $slope
        Text = "按当前速度预计 $durationText 后耗尽"
    }
}

function Measure-UsageInsights {
    param(
        [object[]]$Samples,
        $CurrentSample,
        $PreviousSample,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    return [pscustomobject]@{
        CurrentSample = $CurrentSample
        PreviousSample = $PreviousSample
        Trend24Hours = Get-UsageTrend `
            -Samples $Samples `
            -CurrentSample $CurrentSample `
            -Hours 24 `
            -Now $Now
        Trend7Days = Get-UsageTrend `
            -Samples $Samples `
            -CurrentSample $CurrentSample `
            -Hours (24 * 7) `
            -Now $Now
        Forecast = Get-DepletionForecast `
            -Samples $Samples `
            -CurrentSample $CurrentSample `
            -Now $Now
    }
}

function Test-LowRemainingAlertCondition {
    param(
        $Snapshot,
        $PreviousSample,
        [double]$Threshold = 20.0
    )

    if (
        -not $Snapshot -or
        -not [bool]$Snapshot.Available -or
        -not [bool]$Snapshot.HasProgress -or
        [double]$Snapshot.RemainingPercent -gt $Threshold
    ) {
        return $false
    }
    if (
        $PreviousSample -and
        $PreviousSample.MetricType -eq 'Percent' -and
        [double]$PreviousSample.RemainingValue -le $Threshold
    ) {
        return $false
    }
    return $true
}

function Update-UsageHistory {
    param(
        $Snapshot,
        [DateTimeOffset]$ObservedAt = [DateTimeOffset]::Now
    )

    $record = Add-UsageHistorySample `
        -Snapshot $Snapshot `
        -ObservedAt $ObservedAt
    return Measure-UsageInsights `
        -Samples $record.Samples `
        -CurrentSample $record.CurrentSample `
        -PreviousSample $record.PreviousSample `
        -Now $ObservedAt
}
