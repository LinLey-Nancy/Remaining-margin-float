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
            0.0,
            [Math]::Min(100.0, [double]$Snapshot.RemainingPercent)
        )
        $unit = '%'
    }
    elseif (
        [string]$Snapshot.ProviderId -eq 'DeepSeek' -and
        $Snapshot.PSObject.Properties['TotalBalance']
    ) {
        $metricType = 'Balance'
        $remainingValue = [Math]::Max(0.0, [double]$Snapshot.TotalBalance)
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

function ConvertTo-UsageHistorySamples {
    param(
        $Snapshot,
        [DateTimeOffset]$ObservedAt = [DateTimeOffset]::Now,
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local
    )

    $samples = New-Object Collections.Generic.List[object]
    $primarySample = ConvertTo-UsageHistorySample `
        -Snapshot $Snapshot `
        -ObservedAt $ObservedAt `
        -TimeZone $TimeZone
    if ($primarySample) {
        $samples.Add($primarySample)
    }

    if (
        $primarySample -and
        [string]$Snapshot.ProviderId -eq 'DeepSeek' -and
        $primarySample.MetricType -ne 'Balance' -and
        $Snapshot.PSObject.Properties['TotalBalance']
    ) {
        $balance = [double]$Snapshot.TotalBalance
        if (
            -not [double]::IsNaN($balance) -and
            -not [double]::IsInfinity($balance) -and
            $balance -ge 0
        ) {
            $calendar = Get-UsageHistoryCalendarMetadata `
                -ObservedAt $ObservedAt `
                -TimeZone $TimeZone
            $currency = if ($Snapshot.PSObject.Properties['Currency']) {
                [string]$Snapshot.Currency
            } else {
                'CNY'
            }
            $samples.Add([pscustomobject]@{
                Version = 2
                ProviderId = 'DeepSeek'
                ObservedAtUtc = $ObservedAt.ToUniversalTime()
                LocalDate = $calendar.LocalDate
                TimeZoneId = $calendar.TimeZoneId
                UtcOffsetMinutes = $calendar.UtcOffsetMinutes
                MetricType = 'Balance'
                RemainingValue = [Math]::Round($balance, 4)
                Unit = $currency
                ResetAtUtc = ''
            })
        }
    }
    return $samples.ToArray()
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

function Add-UsageHistoryLines {
    param(
        [object[]]$Samples,
        [string]$Path = '',
        [switch]$AllowDiagnosticWrite,
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local
    )

    if ($isDiagnosticRun -and -not $AllowDiagnosticWrite) { return }
    if ($Samples.Count -eq 0) { return }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Get-UsageHistoryPath
    }
    $path = [IO.Path]::GetFullPath($Path)
    $parentDirectory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parentDirectory -PathType Container)) {
        New-Item -Path $parentDirectory -ItemType Directory -Force | Out-Null
    }
    $lines = @(
        $Samples | Sort-Object ObservedAtUtc | ForEach-Object {
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
    $encoding = New-Object Text.UTF8Encoding($false)
    $newBytes = 0L
    foreach ($line in $lines) {
        $newBytes += $encoding.GetByteCount($line + [Environment]::NewLine)
    }
    $existingBytes = if (Test-Path -LiteralPath $path -PathType Leaf) {
        (Get-Item -LiteralPath $path).Length
    } else { 0L }
    if (($existingBytes + $newBytes) -gt 16MB) {
        throw 'History file exceeds the 16 MB safety limit.'
    }
    $writer = New-Object IO.StreamWriter($path, $true, $encoding)
    try {
        foreach ($line in $lines) {
            $writer.WriteLine($line)
        }
    }
    finally {
        $writer.Dispose()
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

function Get-PreviousUsageHistorySample {
    param(
        [object[]]$Samples,
        $CurrentSample
    )

    for ($index = $Samples.Count - 1; $index -ge 0; $index--) {
        $candidate = $Samples[$index]
        if (
            $candidate.ProviderId -eq $CurrentSample.ProviderId -and
            $candidate.MetricType -eq $CurrentSample.MetricType -and
            $candidate.Unit -eq $CurrentSample.Unit -and
            $candidate.ObservedAtUtc -le $CurrentSample.ObservedAtUtc
        ) {
            return $candidate
        }
    }
    return $null
}

function Add-UsageHistorySample {
    param(
        $Snapshot,
        [DateTimeOffset]$ObservedAt = [DateTimeOffset]::Now,
        [string]$Path = '',
        [switch]$AllowDiagnosticWrite,
        [switch]$SkipPersistence
    )

    $currentSamples = @(
        ConvertTo-UsageHistorySamples `
        -Snapshot $Snapshot `
        -ObservedAt $ObservedAt
    )
    $currentSample = $currentSamples | Select-Object -First 1
    $usesDefaultPath = [string]::IsNullOrWhiteSpace($Path)
    $history = @(if (
        $isDiagnosticRun -and
        -not $AllowDiagnosticWrite -and
        $null -eq $script:UsageHistoryCache
    ) {
        @()
    } else {
        @(
            Read-UsageHistory `
                -Path $Path `
                -Now $ObservedAt `
                -BypassCache:(-not $usesDefaultPath)
        )
    })
    if (-not $currentSample) {
        return [pscustomobject]@{
            Samples = $history
            CurrentSample = $null
            PreviousSample = $null
            Changed = $false
        }
    }

    $previousSample = Get-PreviousUsageHistorySample `
        -Samples $history `
        -CurrentSample $currentSample
    if ($SkipPersistence -or ($isDiagnosticRun -and -not $AllowDiagnosticWrite)) {
        return [pscustomobject]@{
            Samples = @($history + $currentSamples)
            CurrentSample = $currentSample
            PreviousSample = $previousSample
            Changed = $false
        }
    }

    $changed = $false
    foreach ($sample in $currentSamples) {
        $previousForMetric = Get-PreviousUsageHistorySample `
            -Samples $history `
            -CurrentSample $sample
        if ([object]::ReferenceEquals($sample, $currentSample)) {
            $previousSample = $previousForMetric
        }

        $history = @($history + $sample)
        $changed = $true
    }

    if ($changed) {
        try {
            $storagePath = if ($usesDefaultPath) {
                Get-UsageHistoryPath
            } else {
                [IO.Path]::GetFullPath($Path)
            }
            $localObservedAt = [TimeZoneInfo]::ConvertTime(
                $ObservedAt.ToUniversalTime(),
                [TimeZoneInfo]::Local
            )
            $requiresCompaction = if (
                Test-Path -LiteralPath $storagePath -PathType Leaf
            ) {
                $historyFile = Get-Item -LiteralPath $storagePath
                $historyFile.LastWriteTime.Date -ne $localObservedAt.Date -or
                    $historyFile.Length -gt 15MB
            } else { $false }
            if ($requiresCompaction) {
                $history = @(
                    Select-UsageHistoryRetentionWindow `
                        -Samples $history `
                        -Now $ObservedAt
                )
                Save-UsageHistory `
                    -Samples $history `
                    -Path $Path `
                    -Now $ObservedAt `
                    -AllowDiagnosticWrite:$AllowDiagnosticWrite
            }
            else {
                Add-UsageHistoryLines `
                    -Samples $currentSamples `
                    -Path $Path `
                    -AllowDiagnosticWrite:$AllowDiagnosticWrite
            }
            if ($usesDefaultPath) {
                $script:UsageHistoryCache = $history
            }
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
            SampleCount = 0
            ComparisonAvailable = $false
            Change = 0.0
            StartValue = $null
            EndValue = $null
            Summary = '暂无数据'
        }
    }

    $nowUtc = $Now.ToUniversalTime()
    $cutoff = $nowUtc.AddHours(-$Hours)
    $matching = @(
        $Samples | Where-Object {
            $_.ProviderId -eq $CurrentSample.ProviderId -and
            $_.MetricType -eq $CurrentSample.MetricType -and
            $_.Unit -eq $CurrentSample.Unit -and
            $_.ObservedAtUtc -le $nowUtc.AddMinutes(5)
        } | Sort-Object ObservedAtUtc
    )
    $windowSamples = @($matching | Where-Object { $_.ObservedAtUtc -ge $cutoff })
    $boundarySample = $matching |
        Where-Object { $_.ObservedAtUtc -lt $cutoff } |
        Select-Object -Last 1
    $series = @(if ($boundarySample) {
        @($boundarySample) + $windowSamples
    } else {
        $windowSamples
    })

    $segmentStart = 0
    for ($index = 1; $index -lt $series.Count; $index++) {
        $increase = (
            [double]$series[$index].RemainingValue -
            [double]$series[$index - 1].RemainingValue
        )
        if ($increase -gt 0.0001) {
            $segmentStart = $index
        }
    }
    if ($series.Count -gt 0 -and $segmentStart -gt 0) {
        $series = @($series[$segmentStart..($series.Count - 1)])
    }
    $sampleCount = @(
        $series | Where-Object { $_.ObservedAtUtc -ge $cutoff }
    ).Count
    $comparisonAvailable = $series.Count -ge 2
    if (-not $comparisonAvailable) {
        return [pscustomobject]@{
            Hours = $Hours
            Samples = $series
            SampleCount = $sampleCount
            ComparisonAvailable = $false
            Change = 0.0
            StartValue = if ($series.Count -eq 1) {
                [double]$series[0].RemainingValue
            } else { $null }
            EndValue = if ($series.Count -eq 1) {
                [double]$series[0].RemainingValue
            } else { $null }
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
        SampleCount = $sampleCount
        ComparisonAvailable = $true
        Change = $change
        StartValue = [double]$series[0].RemainingValue
        EndValue = [double]$series[-1].RemainingValue
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

    $currentValue = [Math]::Max(0.0, [double]$CurrentSample.RemainingValue)
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
        Text = "按当前速度预计 ${durationText}后耗尽"
    }
}

function ConvertTo-RapidDropWindowMinutes {
    param(
        $Value,
        [int]$Fallback = 30,
        [switch]$Strict
    )

    $parsedValue = 0
    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    $isValid = (
        [int]::TryParse($text.Trim(), [ref]$parsedValue) -and
        $parsedValue -ge 5 -and
        $parsedValue -le 1440
    )
    if ($isValid) { return $parsedValue }
    if ($Strict) {
        throw '快速下降时间范围需要是 5 到 1440 分钟之间的整数。'
    }
    return $Fallback
}

function ConvertTo-RapidDropPercent {
    param(
        $Value,
        [double]$Fallback = 10.0,
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
        $parsedValue -ge 0.1 -and
        $parsedValue -le 100
    )
    if ($isValid) { return [Math]::Round($parsedValue, 1) }
    if ($Strict) {
        throw '快速下降百分比需要在 0.1 到 100 个百分点之间。'
    }
    return $Fallback
}

function ConvertTo-RapidDropAmount {
    param(
        $Value,
        [double]$Fallback = 10.0,
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
        $parsedValue -ge 0.01 -and
        $parsedValue -le 1000000000
    )
    if ($isValid) { return [Math]::Round($parsedValue, 2) }
    if ($Strict) {
        throw '快速下降金额需要在 0.01 到 1,000,000,000 之间。'
    }
    return $Fallback
}

function Measure-RapidUsageDrop {
    param(
        [object[]]$Samples,
        $Snapshot,
        [int]$WindowMinutes = 30,
        [double]$CodexPercent = 10.0,
        [ValidateSet('Percent', 'Amount')]
        [string]$DeepSeekMode = 'Percent',
        [double]$DeepSeekPercent = 10.0,
        [double]$DeepSeekAmount = 10.0,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    $emptyResult = {
        param(
            [string]$ProviderId,
            [string]$MetricType,
            [double]$Threshold,
            [string]$Unit,
            [string]$Summary
        )
        return [pscustomobject]@{
            Available = $false
            IsRapid = $false
            ProviderId = $ProviderId
            MetricType = $MetricType
            WindowMinutes = $WindowMinutes
            Threshold = $Threshold
            Drop = 0.0
            Unit = $Unit
            BaselineValue = $null
            CurrentValue = $null
            BaselineAtUtc = $null
            CurrentAtUtc = $null
            SampleCount = 0
            Summary = $Summary
        }
    }

    if (-not $Snapshot -or -not [bool]$Snapshot.Available) {
        return & $emptyResult '' '' 0.0 '' '当前数据不可用'
    }
    $providerId = [string]$Snapshot.ProviderId
    if ($providerId -eq 'Codex') {
        $metricType = 'Percent'
        $threshold = $CodexPercent
        $unit = '%'
        if (-not [bool]$Snapshot.HasProgress) {
            return & $emptyResult $providerId $metricType $threshold $unit `
                '等待 Codex 余量数据'
        }
    }
    elseif ($providerId -eq 'DeepSeek') {
        $metricType = if ($DeepSeekMode -eq 'Amount') {
            'Balance'
        } else {
            'Percent'
        }
        $threshold = if ($DeepSeekMode -eq 'Amount') {
            $DeepSeekAmount
        } else {
            $DeepSeekPercent
        }
        $unit = if ($DeepSeekMode -eq 'Amount') {
            if ($Snapshot.PSObject.Properties['Currency']) {
                [string]$Snapshot.Currency
            } else {
                'CNY'
            }
        } else {
            '%'
        }
        if ($metricType -eq 'Percent' -and -not [bool]$Snapshot.HasProgress) {
            return & $emptyResult $providerId $metricType $threshold $unit `
                '设置预算基准后监控百分比'
        }
    }
    else {
        return & $emptyResult $providerId '' 0.0 '' '暂不支持此数据源'
    }

    $cutoff = $Now.ToUniversalTime().AddMinutes(-$WindowMinutes)
    $series = @(
        $Samples | Where-Object {
            $_.ProviderId -eq $providerId -and
            $_.MetricType -eq $metricType -and
            $_.Unit -eq $unit -and
            $_.ObservedAtUtc -ge $cutoff -and
            $_.ObservedAtUtc -le $Now.ToUniversalTime().AddMinutes(5)
        } | Sort-Object ObservedAtUtc
    )
    if ($series.Count -lt 2) {
        return & $emptyResult $providerId $metricType $threshold $unit `
            '正在积累快速下降样本'
    }

    $currentSample = $series[-1]
    $baselineSample = $series[0]
    $drop = [Math]::Max(
        0.0,
        [double]$baselineSample.RemainingValue -
            [double]$currentSample.RemainingValue
    )
    $windowText = if ($WindowMinutes -eq 60) {
        '1 小时'
    }
    else {
        '{0} 分钟' -f $WindowMinutes
    }
    $summary = if ($metricType -eq 'Percent') {
        '{0}内下降 {1:0.#}pp' -f $windowText, $drop
    } else {
        '{0}内减少 {1}' -f
            $windowText,
            (Format-CurrencyAmount -Amount $drop -Currency $unit)
    }
    return [pscustomobject]@{
        Available = $true
        IsRapid = $drop -ge $threshold
        ProviderId = $providerId
        MetricType = $metricType
        WindowMinutes = $WindowMinutes
        Threshold = $threshold
        Drop = $drop
        Unit = $unit
        BaselineValue = [double]$baselineSample.RemainingValue
        CurrentValue = [double]$currentSample.RemainingValue
        BaselineAtUtc = $baselineSample.ObservedAtUtc
        CurrentAtUtc = $currentSample.ObservedAtUtc
        SampleCount = $series.Count
        Summary = $summary
    }
}

function Measure-UsageInsights {
    param(
        [object[]]$Samples,
        $CurrentSample,
        $PreviousSample,
        $Snapshot = $null,
        [int]$RapidDropWindowMinutes = 30,
        [double]$CodexRapidDropPercent = 10.0,
        [ValidateSet('Percent', 'Amount')]
        [string]$DeepSeekRapidDropMode = 'Percent',
        [double]$DeepSeekRapidDropPercent = 10.0,
        [double]$DeepSeekRapidDropAmount = 10.0,
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
        RapidDrop = Measure-RapidUsageDrop `
            -Samples $Samples `
            -Snapshot $Snapshot `
            -WindowMinutes $RapidDropWindowMinutes `
            -CodexPercent $CodexRapidDropPercent `
            -DeepSeekMode $DeepSeekRapidDropMode `
            -DeepSeekPercent $DeepSeekRapidDropPercent `
            -DeepSeekAmount $DeepSeekRapidDropAmount `
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
        [DateTimeOffset]$ObservedAt = [DateTimeOffset]::Now,
        [int]$RapidDropWindowMinutes = 30,
        [double]$CodexRapidDropPercent = 10.0,
        [ValidateSet('Percent', 'Amount')]
        [string]$DeepSeekRapidDropMode = 'Percent',
        [double]$DeepSeekRapidDropPercent = 10.0,
        [double]$DeepSeekRapidDropAmount = 10.0,
        [switch]$SkipPersistence
    )

    $record = Add-UsageHistorySample `
        -Snapshot $Snapshot `
        -ObservedAt $ObservedAt `
        -SkipPersistence:$SkipPersistence
    return Measure-UsageInsights `
        -Samples $record.Samples `
        -CurrentSample $record.CurrentSample `
        -PreviousSample $record.PreviousSample `
        -Snapshot $Snapshot `
        -RapidDropWindowMinutes $RapidDropWindowMinutes `
        -CodexRapidDropPercent $CodexRapidDropPercent `
        -DeepSeekRapidDropMode $DeepSeekRapidDropMode `
        -DeepSeekRapidDropPercent $DeepSeekRapidDropPercent `
        -DeepSeekRapidDropAmount $DeepSeekRapidDropAmount `
        -Now $ObservedAt
}
