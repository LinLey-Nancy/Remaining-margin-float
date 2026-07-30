function Get-UsageHistoryPath {
    return Join-Path (Get-AppDataDirectory) 'usage-history.jsonl'
}

function Get-UsageHistoryCalendarMetadata {
    param(
        [DateTimeOffset]$ObservedAt,
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local
    )

    $localObservedAt = [TimeZoneInfo]::ConvertTime(
        $ObservedAt.ToUniversalTime(),
        $TimeZone
    )
    return [pscustomobject]@{
        LocalDate = $localObservedAt.ToString(
            'yyyy-MM-dd',
            [Globalization.CultureInfo]::InvariantCulture
        )
        TimeZoneId = $TimeZone.Id
        UtcOffsetMinutes = [int][Math]::Round(
            $localObservedAt.Offset.TotalMinutes
        )
    }
}

function ConvertFrom-UsageHistoryRecord {
    param(
        $Saved,
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local
    )

    if (-not $Saved) { return $null }
    $providerId = [string]$Saved.ProviderId
    $metricType = [string]$Saved.MetricType
    if (
        $providerId -notin @('Codex', 'DeepSeek') -or
        $metricType -notin @('Percent', 'Balance')
    ) {
        return $null
    }

    $observedAt = [DateTimeOffset]::Parse(
        [string]$Saved.ObservedAtUtc,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    ).ToUniversalTime()
    $remainingValue = [double]$Saved.RemainingValue
    if (
        [double]::IsNaN($remainingValue) -or
        [double]::IsInfinity($remainingValue) -or
        $remainingValue -lt 0 -or
        ($metricType -eq 'Percent' -and $remainingValue -gt 100)
    ) {
        return $null
    }

    $resetAtUtc = ''
    if (
        $Saved.PSObject.Properties['ResetAtUtc'] -and
        -not [string]::IsNullOrWhiteSpace([string]$Saved.ResetAtUtc)
    ) {
        try {
            $resetAtUtc = [DateTimeOffset]::Parse(
                [string]$Saved.ResetAtUtc,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind
            ).ToUniversalTime().ToString(
                'o',
                [Globalization.CultureInfo]::InvariantCulture
            )
        }
        catch {
            $resetAtUtc = ''
        }
    }

    $calendar = Get-UsageHistoryCalendarMetadata `
        -ObservedAt $observedAt `
        -TimeZone $TimeZone
    return [pscustomobject]@{
        Version = 2
        ProviderId = $providerId
        ObservedAtUtc = $observedAt
        LocalDate = $calendar.LocalDate
        TimeZoneId = $calendar.TimeZoneId
        UtcOffsetMinutes = $calendar.UtcOffsetMinutes
        MetricType = $metricType
        RemainingValue = [Math]::Round($remainingValue, 4)
        Unit = [string]$Saved.Unit
        ResetAtUtc = $resetAtUtc
    }
}

function Select-UsageHistoryRetentionWindow {
    param(
        [object[]]$Samples,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now,
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local
    )

    $localNow = [TimeZoneInfo]::ConvertTime(
        $Now.ToUniversalTime(),
        $TimeZone
    )
    $earliestLocalDate = $localNow.Date.AddDays(-7)
    $deduplicated = @{}
    foreach ($sample in @($Samples | Sort-Object ObservedAtUtc)) {
        if (-not $sample) { continue }
        $observedAt = ([DateTimeOffset]$sample.ObservedAtUtc).ToUniversalTime()
        $localObservedAt = [TimeZoneInfo]::ConvertTime($observedAt, $TimeZone)
        if ($localObservedAt.Date -lt $earliestLocalDate) { continue }

        $calendar = Get-UsageHistoryCalendarMetadata `
            -ObservedAt $observedAt `
            -TimeZone $TimeZone
        $normalized = [pscustomobject]@{
            Version = 2
            ProviderId = [string]$sample.ProviderId
            ObservedAtUtc = $observedAt
            LocalDate = $calendar.LocalDate
            TimeZoneId = $calendar.TimeZoneId
            UtcOffsetMinutes = $calendar.UtcOffsetMinutes
            MetricType = [string]$sample.MetricType
            RemainingValue = [Math]::Round(
                [double]$sample.RemainingValue,
                4
            )
            Unit = [string]$sample.Unit
            ResetAtUtc = [string]$sample.ResetAtUtc
        }
        $key = '{0}|{1}|{2}|{3}' -f
            $normalized.ProviderId,
            $normalized.MetricType,
            $normalized.Unit,
            $normalized.ObservedAtUtc.ToString(
                'o',
                [Globalization.CultureInfo]::InvariantCulture
            )
        $deduplicated[$key] = $normalized
    }
    return @($deduplicated.Values | Sort-Object ObservedAtUtc)
}

function ConvertTo-UsageHistorySample {
    param(
        $Snapshot,
        [DateTimeOffset]$ObservedAt = [DateTimeOffset]::Now,
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local
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

    $calendar = Get-UsageHistoryCalendarMetadata `
        -ObservedAt $ObservedAt `
        -TimeZone $TimeZone
    return [pscustomobject]@{
        Version = 2
        ProviderId = [string]$Snapshot.ProviderId
        ObservedAtUtc = $ObservedAt.ToUniversalTime()
        LocalDate = $calendar.LocalDate
        TimeZoneId = $calendar.TimeZoneId
        UtcOffsetMinutes = $calendar.UtcOffsetMinutes
        MetricType = $metricType
        RemainingValue = [Math]::Round($remainingValue, 4)
        Unit = $unit
        ResetAtUtc = $resetAtUtc
    }
}

function Read-UsageHistory {
    param(
        [string]$Path = '',
        [DateTimeOffset]$Now = [DateTimeOffset]::Now,
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local,
        [switch]$BypassCache
    )

    $usesDefaultPath = [string]::IsNullOrWhiteSpace($Path)
    if (
        $usesDefaultPath -and
        -not $BypassCache -and
        $null -ne $script:UsageHistoryCache
    ) {
        return @($script:UsageHistoryCache)
    }

    $items = New-Object Collections.Generic.List[object]
    if ($usesDefaultPath) {
        $Path = Get-UsageHistoryPath
    }
    $path = [IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $historyFile = Get-Item -LiteralPath $path
        if ($historyFile.Length -gt 16MB) {
            throw '使用记录文件超过 16 MB 安全上限。'
        }
        foreach ($line in (Get-Content -LiteralPath $path -Encoding UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line.Length -gt 65536) {
                throw '使用记录包含超过 64 KB 的异常记录。'
            }
            try {
                $saved = $line | ConvertFrom-Json
                $sample = ConvertFrom-UsageHistoryRecord `
                    -Saved $saved `
                    -TimeZone $TimeZone
                if ($sample) { $items.Add($sample) }
            }
            catch {
                # A damaged history line is ignored without discarding valid samples.
            }
        }
    }

    $history = @(
        Select-UsageHistoryRetentionWindow `
            -Samples $items `
            -Now $Now `
            -TimeZone $TimeZone
    )
    if ($usesDefaultPath) {
        $script:UsageHistoryCache = $history
    }
    return $history
}

function Save-UsageHistory {
    param(
        [object[]]$Samples,
        [string]$Path = '',
        [switch]$AllowDiagnosticWrite,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now,
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local
    )

    if ($isDiagnosticRun -and -not $AllowDiagnosticWrite) { return }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Get-UsageHistoryPath
    }
    $path = [IO.Path]::GetFullPath($Path)
    $parentDirectory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parentDirectory -PathType Container)) {
        New-Item -Path $parentDirectory -ItemType Directory -Force | Out-Null
    }
    $retainedSamples = @(
        Select-UsageHistoryRetentionWindow `
            -Samples $Samples `
            -Now $Now `
            -TimeZone $TimeZone
    )
    $temporaryPath = '{0}.tmp.{1}.{2}' -f
        $path,
        $PID,
        [Guid]::NewGuid().ToString('N')
    $backupPath = '{0}.bak.{1}.{2}' -f
        $path,
        $PID,
        [Guid]::NewGuid().ToString('N')
    $lines = @(
        $retainedSamples | Sort-Object ObservedAtUtc | ForEach-Object {
            $calendar = Get-UsageHistoryCalendarMetadata `
                -ObservedAt ([DateTimeOffset]$_.ObservedAtUtc) `
                -TimeZone $TimeZone
            [ordered]@{
                v = 2
                ProviderId = [string]$_.ProviderId
                ObservedAtUtc = ([DateTimeOffset]$_.ObservedAtUtc).
                    ToUniversalTime().
                    ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                LocalDate = $calendar.LocalDate
                TimeZoneId = $calendar.TimeZoneId
                UtcOffsetMinutes = $calendar.UtcOffsetMinutes
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

function Export-UsageHistory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    $samples = @(Read-UsageHistory -Now $Now)
    Save-UsageHistory `
        -Samples $samples `
        -Path $Path `
        -Now $Now `
        -AllowDiagnosticWrite
    return [pscustomobject]@{
        Path = [IO.Path]::GetFullPath($Path)
        SampleCount = $samples.Count
        FirstObservedAtUtc = if ($samples.Count -gt 0) {
            $samples[0].ObservedAtUtc
        } else { $null }
        LastObservedAtUtc = if ($samples.Count -gt 0) {
            $samples[-1].ObservedAtUtc
        } else { $null }
    }
}

function Import-UsageHistory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now,
        [string]$DestinationPath = '',
        [switch]$AllowDiagnosticWrite
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw '找不到要导入的使用记录文件。'
    }
    $imported = @(
        Read-UsageHistory `
            -Path $Path `
            -Now $Now `
            -BypassCache
    )
    if ($imported.Count -eq 0) {
        throw '导入文件中没有近 7 日内的有效使用记录。'
    }
    $usesDefaultDestination =
        [string]::IsNullOrWhiteSpace($DestinationPath)
    $existing = @(
        if ($usesDefaultDestination) {
            Read-UsageHistory -Now $Now
        } else {
            Read-UsageHistory `
                -Path $DestinationPath `
                -Now $Now `
                -BypassCache
        }
    )
    $merged = @(
        Select-UsageHistoryRetentionWindow `
            -Samples @($existing + $imported) `
            -Now $Now
    )
    Save-UsageHistory `
        -Samples $merged `
        -Path $DestinationPath `
        -Now $Now `
        -AllowDiagnosticWrite:$AllowDiagnosticWrite
    if ($usesDefaultDestination) {
        $script:UsageHistoryCache = $merged
    }
    return [pscustomobject]@{
        ImportedCount = $imported.Count
        PreviousCount = $existing.Count
        TotalCount = $merged.Count
    }
}

function Get-UsageHistorySummary {
    param([DateTimeOffset]$Now = [DateTimeOffset]::Now)

    $path = Get-UsageHistoryPath
    $samples = @(Read-UsageHistory -Now $Now)
    return [pscustomobject]@{
        Path = $path
        Exists = Test-Path -LiteralPath $path -PathType Leaf
        SampleCount = $samples.Count
        FirstLocalDate = if ($samples.Count -gt 0) {
            [string]$samples[0].LocalDate
        } else { '' }
        LastLocalDate = if ($samples.Count -gt 0) {
            [string]$samples[-1].LocalDate
        } else { '' }
        TimeZoneId = [TimeZoneInfo]::Local.Id
        Providers = @($samples.ProviderId | Sort-Object -Unique)
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
    $history = if ($isDiagnosticRun -and $null -eq $script:UsageHistoryCache) {
        @()
    } else {
        @(Read-UsageHistory)
    }
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
            $_.Unit -eq $currentSample.Unit -and
            $_.ObservedAtUtc -le $currentSample.ObservedAtUtc.AddMinutes(5)
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
        $history = @(
            Select-UsageHistoryRetentionWindow `
                -Samples $history `
                -Now $ObservedAt
        )
        try {
            Save-UsageHistory -Samples $history -Now $ObservedAt
            $script:UsageHistoryCache = $history
            $script:LastUsageHistoryError = ''
            if (Get-Command Set-RuntimeDiagnosticStatus -ErrorAction SilentlyContinue) {
                Set-RuntimeDiagnosticStatus `
                    -Area 'History' `
                    -Status 'Healthy' `
                    -Message '使用历史已保存'
            }
        }
        catch {
            $script:LastUsageHistoryError = $_.Exception.Message
            if (Get-Command Set-RuntimeDiagnosticStatus -ErrorAction SilentlyContinue) {
                Set-RuntimeDiagnosticStatus `
                    -Area 'History' `
                    -Status 'Error' `
                    -Message $_.Exception.Message
            }
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
            $_.ObservedAtUtc -ge $cutoff -and
            $_.ObservedAtUtc -le $Now.ToUniversalTime().AddMinutes(5)
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
            $_.ObservedAtUtc -ge $Now.ToUniversalTime().AddDays(-7) -and
            $_.ObservedAtUtc -le $Now.ToUniversalTime().AddMinutes(5)
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

function ConvertTo-LowRemainingThreshold {
    param(
        $Value,
        [double]$Fallback = 20.0,
        [switch]$Strict
    )

    $parsedValue = 0.0
    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    $parsed = [double]::TryParse(
        $text.Trim(),
        [Globalization.NumberStyles]::Number,
        [Globalization.CultureInfo]::CurrentCulture,
        [ref]$parsedValue
    )
    if (-not $parsed) {
        $parsed = [double]::TryParse(
            $text.Trim(),
            [Globalization.NumberStyles]::Number,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsedValue
        )
    }

    $isValid = (
        $parsed -and
        -not [double]::IsNaN($parsedValue) -and
        -not [double]::IsInfinity($parsedValue) -and
        $parsedValue -ge 1 -and
        $parsedValue -le 99 -and
        $parsedValue -eq [Math]::Round($parsedValue)
    )
    if ($isValid) {
        return [double][Math]::Round($parsedValue)
    }
    if ($Strict) {
        throw '提醒阈值需要是 1 到 99 之间的整数。'
    }
    return $Fallback
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
