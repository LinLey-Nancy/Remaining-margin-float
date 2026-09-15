function Get-UsageHistoryPath {
    return Join-Path (Get-AppDataDirectory) 'usage-history.jsonl'
}

function Enter-UsageHistoryWriteLock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [int]$TimeoutMilliseconds = 10000
    )

    $normalizedPath = [IO.Path]::GetFullPath($Path).ToLowerInvariant()
    $pathBytes = [Text.Encoding]::UTF8.GetBytes($normalizedPath)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $pathHash = ([BitConverter]::ToString(
            $algorithm.ComputeHash($pathBytes)
        )).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
        [Array]::Clear($pathBytes, 0, $pathBytes.Length)
    }
    $mutex = New-Object Threading.Mutex(
        $false,
        "Local\RemainingMarginFloat.UsageHistory.$pathHash"
    )
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne($TimeoutMilliseconds)
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw '等待使用历史写入锁超时。'
        }
        return $mutex
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-UsageHistoryWriteLock {
    param($Mutex)

    if (-not $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch {}
    $Mutex.Dispose()
}

function Get-UsageQuotaPeriod {
    param($Value)

    if ($Value -and $Value.PSObject.Properties['QuotaPeriod']) {
        return [string]$Value.QuotaPeriod
    }
    return ''
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
    $recordVersion = if ($Saved.PSObject.Properties['v']) {
        try { [int]$Saved.v } catch { 0 }
    } else { 0 }
    $hasQuotaPeriod = $null -ne $Saved.PSObject.Properties['QuotaPeriod']
    $quotaPeriod = if ($hasQuotaPeriod) {
        [string]$Saved.QuotaPeriod
    } else { '' }
    if (
        $providerId -notin @('Codex', 'DeepSeek', 'Kimi') -or
        $metricType -notin @('Percent', 'Balance')
    ) {
        return $null
    }
    if ($providerId -eq 'Codex' -and $metricType -eq 'Percent') {
        if (
            -not $hasQuotaPeriod -and
            $recordVersion -ge 1 -and
            $recordVersion -le 2
        ) {
            # Before v1.9.0, Codex percent history always represented the
            # weekly allowance. Tag it during schema migration so Pro keeps
            # its trend while Plus still isolates the new five-hour period.
            $quotaPeriod = 'Weekly'
        }
        elseif ($quotaPeriod -notin @('FiveHour', 'Weekly')) {
            return $null
        }
    }
    if (
        $providerId -eq 'Kimi' -and
        $metricType -eq 'Percent' -and
        $quotaPeriod -notin @('FiveHour', 'Weekly')
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
        Version = 3
        ProviderId = $providerId
        ObservedAtUtc = $observedAt
        LocalDate = $calendar.LocalDate
        TimeZoneId = $calendar.TimeZoneId
        UtcOffsetMinutes = $calendar.UtcOffsetMinutes
        MetricType = $metricType
        QuotaPeriod = $quotaPeriod
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
            Version = 3
            ProviderId = [string]$sample.ProviderId
            ObservedAtUtc = $observedAt
            LocalDate = $calendar.LocalDate
            TimeZoneId = $calendar.TimeZoneId
            UtcOffsetMinutes = $calendar.UtcOffsetMinutes
            MetricType = [string]$sample.MetricType
            QuotaPeriod = if ($sample.PSObject.Properties['QuotaPeriod']) {
                [string]$sample.QuotaPeriod
            } else { '' }
            RemainingValue = [Math]::Round(
                [double]$sample.RemainingValue,
                4
            )
            Unit = [string]$sample.Unit
            ResetAtUtc = [string]$sample.ResetAtUtc
        }
        $key = '{0}|{1}|{2}|{3}|{4}' -f
            $normalized.ProviderId,
            $normalized.MetricType,
            $normalized.QuotaPeriod,
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
    $codexQuotaPeriod = if (
        [string]$Snapshot.ProviderId -in @('Codex', 'Kimi') -and
        $Snapshot.PSObject.Properties['PrimaryQuotaPeriod'] -and
        [string]$Snapshot.PrimaryQuotaPeriod -eq 'Weekly'
    ) { 'Weekly' } else { 'FiveHour' }
    if ([string]$Snapshot.ProviderId -in @('Codex', 'Kimi')) {
        $availabilityProperty = "${codexQuotaPeriod}Available"
        if (
            -not $Snapshot.PSObject.Properties[$availabilityProperty] -or
            -not [bool]$Snapshot.$availabilityProperty
        ) {
            return $null
        }
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
        Version = 3
        ProviderId = [string]$Snapshot.ProviderId
        ObservedAtUtc = $ObservedAt.ToUniversalTime()
        LocalDate = $calendar.LocalDate
        TimeZoneId = $calendar.TimeZoneId
        UtcOffsetMinutes = $calendar.UtcOffsetMinutes
        MetricType = $metricType
        QuotaPeriod = if ([string]$Snapshot.ProviderId -in @('Codex', 'Kimi')) {
            $codexQuotaPeriod
        } else { '' }
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
                Version = 3
                ProviderId = 'DeepSeek'
                ObservedAtUtc = $ObservedAt.ToUniversalTime()
                LocalDate = $calendar.LocalDate
                TimeZoneId = $calendar.TimeZoneId
                UtcOffsetMinutes = $calendar.UtcOffsetMinutes
                MetricType = 'Balance'
                QuotaPeriod = ''
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
        [switch]$BypassCache,
        [switch]$ForAnalysis
    )

    $usesDefaultPath = [string]::IsNullOrWhiteSpace($Path)
    if (
        $usesDefaultPath -and
        $ForAnalysis -and
        -not $BypassCache -and
        $null -ne $script:UsageHistoryCache
    ) {
        return @($script:UsageHistoryCache)
    }

    if ($usesDefaultPath) {
        $Path = Get-UsageHistoryPath
    }
    $path = [IO.Path]::GetFullPath($Path)
    $history = @()
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $historyFile = Get-Item -LiteralPath $path
        if ($historyFile.Length -gt 16MB) {
            throw '使用记录文件超过 16 MB 安全上限。'
        }
        $history = @(
            [UsageHistoryLogScanner]::ReadFile($path, $Now, $TimeZone)
        )
        if ($ForAnalysis) {
            $history = @(
                [UsageHistoryLogScanner]::SelectForAnalysis(
                    [UsageHistoryRecordData[]]$history,
                    $Now
                )
            )
        }
    }
    if ($usesDefaultPath -and $ForAnalysis) {
        $script:UsageHistoryCache = $history
    }
    return $history
}

function Save-UsageHistory {
    param(
        [object[]]$Samples,
        [string]$Path = '',
        [switch]$AllowDiagnosticWrite,
        [switch]$SkipWriteLock,
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
                v = 3
                ProviderId = [string]$_.ProviderId
                ObservedAtUtc = ([DateTimeOffset]$_.ObservedAtUtc).
                    ToUniversalTime().
                    ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                LocalDate = $calendar.LocalDate
                TimeZoneId = $calendar.TimeZoneId
                UtcOffsetMinutes = $calendar.UtcOffsetMinutes
                MetricType = [string]$_.MetricType
                QuotaPeriod = if ($_.PSObject.Properties['QuotaPeriod']) {
                    [string]$_.QuotaPeriod
                } else { '' }
                RemainingValue = [Math]::Round([double]$_.RemainingValue, 4)
                Unit = [string]$_.Unit
                ResetAtUtc = [string]$_.ResetAtUtc
            } | ConvertTo-Json -Compress
        }
    )

    $writeLock = if ($SkipWriteLock) {
        $null
    } else {
        Enter-UsageHistoryWriteLock -Path $path
    }
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
        Exit-UsageHistoryWriteLock -Mutex $writeLock
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
                v = 3
                ProviderId = [string]$_.ProviderId
                ObservedAtUtc = ([DateTimeOffset]$_.ObservedAtUtc).
                    ToUniversalTime().
                    ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                LocalDate = $calendar.LocalDate
                TimeZoneId = $calendar.TimeZoneId
                UtcOffsetMinutes = $calendar.UtcOffsetMinutes
                MetricType = [string]$_.MetricType
                QuotaPeriod = if ($_.PSObject.Properties['QuotaPeriod']) {
                    [string]$_.QuotaPeriod
                } else { '' }
                RemainingValue = [Math]::Round([double]$_.RemainingValue, 4)
                Unit = [string]$_.Unit
                ResetAtUtc = [string]$_.ResetAtUtc
            } | ConvertTo-Json -Compress
        }
    )
    $writeLock = Enter-UsageHistoryWriteLock -Path $path
    try {
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
    finally {
        Exit-UsageHistoryWriteLock -Mutex $writeLock
    }
}

function Get-UsageHistoryTimeBucket {
    param([DateTimeOffset]$ObservedAt)

    $ticksPerBucket = [TimeSpan]::TicksPerSecond
    return [long][Math]::Floor(
        $ObservedAt.ToUniversalTime().UtcDateTime.Ticks / $ticksPerBucket
    )
}

function Get-UsageHistoryBackfillMarkerPath {
    param([string]$StateRootPath = '')

    return Join-Path (
        Get-UsageStateHistoryDirectory -RootPath $StateRootPath
    ) 'usage-history-backfill.json'
}

function Get-UsageHistoryCoverageFingerprint {
    param(
        [object[]]$Samples,
        [DateTimeOffset]$CompletedThroughUtc
    )

    $lines = New-Object Collections.Generic.List[string]
    foreach ($sample in @($Samples | Sort-Object ObservedAtUtc)) {
        $observedAt = ([DateTimeOffset]$sample.ObservedAtUtc).ToUniversalTime()
        if ($observedAt -gt $CompletedThroughUtc.ToUniversalTime()) { continue }
        [void]$lines.Add((
            [ordered]@{
                ProviderId = [string]$sample.ProviderId
                ObservedAtUtc = $observedAt.ToString(
                    'o',
                    [Globalization.CultureInfo]::InvariantCulture
                )
                MetricType = [string]$sample.MetricType
                QuotaPeriod = if ($sample.PSObject.Properties['QuotaPeriod']) {
                    [string]$sample.QuotaPeriod
                } else { '' }
                RemainingValue = [Math]::Round(
                    [double]$sample.RemainingValue,
                    4
                )
                Unit = [string]$sample.Unit
                ResetAtUtc = [string]$sample.ResetAtUtc
            } | ConvertTo-Json -Compress
        ))
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = -join (
            $algorithm.ComputeHash($bytes) |
                ForEach-Object { $_.ToString('x2') }
        )
    }
    finally {
        $algorithm.Dispose()
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
    return [pscustomobject]@{
        SampleCount = $lines.Count
        Sha256 = $hash
    }
}

function Add-UsageHistoryBackfillIndexSample {
    param(
        [hashtable]$Index,
        $Sample,
        [switch]$ProviderOnly
    )

    if (-not $Sample) { return }
    $providerId = [string]$Sample.ProviderId
    $bucket = Get-UsageHistoryTimeBucket `
        -ObservedAt ([DateTimeOffset]$Sample.ObservedAtUtc)
    $key = if ($ProviderOnly) {
        '{0}|{1}' -f $providerId, $bucket
    } else {
        '{0}|{1}|{2}|{3}' -f
            $providerId,
            [string]$Sample.MetricType,
            [string]$Sample.Unit,
            $bucket
    }
    if (-not $Index.ContainsKey($key)) {
        $Index[$key] = New-Object Collections.Generic.List[object]
    }
    [void]$Index[$key].Add($Sample)
}

function Test-UsageHistoryBackfillIndexMatch {
    param(
        [hashtable]$Index,
        [string]$ProviderId,
        [DateTimeOffset]$ObservedAt,
        [string]$MetricType = '',
        [string]$Unit = '',
        [switch]$ProviderOnly
    )

    $bucket = Get-UsageHistoryTimeBucket -ObservedAt $ObservedAt
    foreach ($offset in @(-1L, 0L, 1L)) {
        $candidateBucket = $bucket + $offset
        $key = if ($ProviderOnly) {
            '{0}|{1}' -f $ProviderId, $candidateBucket
        } else {
            '{0}|{1}|{2}|{3}' -f
                $ProviderId,
                $MetricType,
                $Unit,
                $candidateBucket
        }
        if (-not $Index.ContainsKey($key)) { continue }
        foreach ($candidate in $Index[$key]) {
            $distance = [Math]::Abs((
                ([DateTimeOffset]$candidate.ObservedAtUtc).ToUniversalTime() -
                $ObservedAt.ToUniversalTime()
            ).TotalSeconds)
            if ($distance -le 1.0) { return $true }
        }
    }
    return $false
}

function Invoke-UsageHistoryStateBackfill {
    param(
        [string]$HistoryPath = '',
        [string]$StateRootPath = '',
        [DateTimeOffset]$Now = [DateTimeOffset]::Now,
        [switch]$AllowDiagnosticWrite
    )

    if ($isDiagnosticRun -and -not $AllowDiagnosticWrite) {
        return [pscustomobject]@{
            ExaminedEntries = 0
            AddedSamples = 0
            FailedEntries = 0
            Changed = $false
        }
    }

    $usesDefaultHistoryPath = [string]::IsNullOrWhiteSpace($HistoryPath)
    if ($usesDefaultHistoryPath) {
        $HistoryPath = Get-UsageHistoryPath
    }
    $stateRoot = Get-UsageStateHistoryDirectory -RootPath $StateRootPath
    if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        return [pscustomobject]@{
            ExaminedEntries = 0
            AddedSamples = 0
            FailedEntries = 0
            Changed = $false
        }
    }

    $history = @(
        Read-UsageHistory `
            -Path $HistoryPath `
            -Now $Now `
            -BypassCache
    )
    $scanFromUtc = $Now.ToUniversalTime().AddHours(-168)
    $markerPath = Get-UsageHistoryBackfillMarkerPath -StateRootPath $stateRoot
    if (
        (Test-Path -LiteralPath $HistoryPath -PathType Leaf) -and
        (Test-Path -LiteralPath $markerPath -PathType Leaf) -and
        (Get-Item -LiteralPath $markerPath).Length -le 65536
    ) {
        try {
            $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 |
                ConvertFrom-Json
            if ([int]$marker.v -eq 2) {
                $completedThrough = [DateTimeOffset]::Parse(
                    [string]$marker.CompletedThroughUtc,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind
                ).ToUniversalTime()
                $coverage = Get-UsageHistoryCoverageFingerprint `
                    -Samples $history `
                    -CompletedThroughUtc $completedThrough
                $coverageMatches = (
                    [int]$marker.CoverageSampleCount -eq $coverage.SampleCount -and
                    [string]$marker.CoverageSha256 -match '^[0-9a-f]{64}$' -and
                    [string]$marker.CoverageSha256 -eq $coverage.Sha256
                )
                if ($coverageMatches -and $completedThrough -gt $scanFromUtc) {
                    $scanFromUtc = $completedThrough.AddSeconds(-30)
                }
            }
        }
        catch {
            $scanFromUtc = $Now.ToUniversalTime().AddHours(-168)
        }
    }
    $providerIndex = @{}
    $metricIndex = @{}
    foreach ($sample in $history) {
        Add-UsageHistoryBackfillIndexSample `
            -Index $providerIndex `
            -Sample $sample `
            -ProviderOnly
        Add-UsageHistoryBackfillIndexSample `
            -Index $metricIndex `
            -Sample $sample
    }

    $eligibleReasons = @(
        'Normal',
        'StartupOfficial',
        'Manual',
        'Automatic',
        'Refresh'
    )
    $entries = @(
        Get-UsageStateHistory -RootPath $stateRoot -Now $Now | Where-Object {
            $_.Reason -in $eligibleReasons -and
            $_.ObservedAtUtc -ge $scanFromUtc
        } | Sort-Object ObservedAtUtc
    )
    $added = New-Object Collections.Generic.List[object]
    $payloadCache = @{}
    $failedEntries = 0
    $protectedDataUnavailable = $false
    foreach ($entry in $entries) {
        $observedAt = ([DateTimeOffset]$entry.ObservedAtUtc).ToUniversalTime()
        if (
            $entry.ProviderId -eq 'Codex' -and
            (Test-UsageHistoryBackfillIndexMatch `
                -Index $providerIndex `
                -ProviderId $entry.ProviderId `
                -ObservedAt $observedAt `
                -ProviderOnly)
        ) {
            continue
        }

        try {
            $payloadHash = [string]$entry.PayloadHash
            if ($payloadCache.ContainsKey($payloadHash)) {
                $snapshot = $payloadCache[$payloadHash]
            } else {
                $snapshot = Read-UsageStatePayload `
                    -Entry $entry `
                    -RootPath $stateRoot
                if (-not $snapshot) {
                    throw 'Full-state history object is missing.'
                }
                $payloadCache[$payloadHash] = $snapshot
            }
            foreach ($sample in @(
                ConvertTo-UsageHistorySamples `
                    -Snapshot $snapshot `
                    -ObservedAt $observedAt
            )) {
                if (Test-UsageHistoryBackfillIndexMatch `
                    -Index $metricIndex `
                    -ProviderId $sample.ProviderId `
                    -ObservedAt $sample.ObservedAtUtc `
                    -MetricType $sample.MetricType `
                    -Unit $sample.Unit) {
                    continue
                }
                [void]$added.Add($sample)
                Add-UsageHistoryBackfillIndexSample `
                    -Index $providerIndex `
                    -Sample $sample `
                    -ProviderOnly
                Add-UsageHistoryBackfillIndexSample `
                    -Index $metricIndex `
                    -Sample $sample
            }
        }
        catch {
            $failedEntries++
            if ($_.Exception.Message -eq '当前 Windows 用户无法解密全量状态。') {
                $protectedDataUnavailable = $true
                break
            }
        }
    }

    if ($added.Count -gt 0) {
        $addedSamples = $added.ToArray()
        $writeLock = Enter-UsageHistoryWriteLock -Path $HistoryPath
        try {
            $latestHistory = @(
                Read-UsageHistory `
                    -Path $HistoryPath `
                    -Now $Now `
                    -BypassCache
            )
            $history = @(
                Select-UsageHistoryRetentionWindow `
                    -Samples @($latestHistory + $addedSamples) `
                    -Now $Now
            )
            Save-UsageHistory `
                -Samples $history `
                -Path $HistoryPath `
                -Now $Now `
                -AllowDiagnosticWrite:$AllowDiagnosticWrite `
                -SkipWriteLock
        }
        finally {
            Exit-UsageHistoryWriteLock -Mutex $writeLock
        }
        if ($usesDefaultHistoryPath) {
            $script:UsageHistoryCache = $null
        }
    }

    if (
        -not $protectedDataUnavailable -and
        $failedEntries -eq 0 -and
        $entries.Count -gt 0 -and
        (Test-Path -LiteralPath $HistoryPath -PathType Leaf)
    ) {
        $completedThrough = (
            [DateTimeOffset]$entries[-1].ObservedAtUtc
        ).ToUniversalTime()
        $coverage = Get-UsageHistoryCoverageFingerprint `
            -Samples $history `
            -CompletedThroughUtc $completedThrough
        $markerDocument = [ordered]@{
            v = 2
            CompletedThroughUtc = $completedThrough.ToString(
                'o',
                [Globalization.CultureInfo]::InvariantCulture
            )
            CoverageSampleCount = $coverage.SampleCount
            CoverageSha256 = $coverage.Sha256
        } | ConvertTo-Json -Compress
        Write-UsageStateAtomicText -Path $markerPath -Text $markerDocument
    }

    return [pscustomobject]@{
        ExaminedEntries = $entries.Count
        AddedSamples = $added.Count
        FailedEntries = $failedEntries
        ProtectedDataUnavailable = $protectedDataUnavailable
        Changed = $added.Count -gt 0
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
    $destinationStoragePath = if ($usesDefaultDestination) {
        Get-UsageHistoryPath
    } else {
        [IO.Path]::GetFullPath($DestinationPath)
    }
    $writeLock = Enter-UsageHistoryWriteLock -Path $destinationStoragePath
    try {
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
            -AllowDiagnosticWrite:$AllowDiagnosticWrite `
            -SkipWriteLock
        if ($usesDefaultDestination) {
            $script:UsageHistoryCache = $null
        }
        return [pscustomobject]@{
            ImportedCount = $imported.Count
            PreviousCount = $existing.Count
            TotalCount = $merged.Count
        }
    }
    finally {
        Exit-UsageHistoryWriteLock -Mutex $writeLock
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

    $currentQuotaPeriod = Get-UsageQuotaPeriod -Value $CurrentSample
    for ($index = $Samples.Count - 1; $index -ge 0; $index--) {
        $candidate = $Samples[$index]
        if (
            $candidate.ProviderId -eq $CurrentSample.ProviderId -and
            $candidate.MetricType -eq $CurrentSample.MetricType -and
            (Get-UsageQuotaPeriod -Value $candidate) -eq $currentQuotaPeriod -and
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
                -BypassCache:(-not $usesDefaultPath) `
                -ForAnalysis:$usesDefaultPath
        )
    })
    if (-not $currentSample) {
        return [pscustomobject]@{
            Samples = $history
            CurrentSamples = $currentSamples
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
            CurrentSamples = $currentSamples
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

    if ($usesDefaultPath -and $history.Count -gt 4320) {
        $history = @(
            Select-UsageHistoryAnalysisSamples `
                -Samples $history `
                -CurrentSample $currentSample `
                -Now $ObservedAt
        )
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
                $writeLock = Enter-UsageHistoryWriteLock -Path $storagePath
                try {
                    $fullHistory = @(
                        Read-UsageHistory `
                            -Path $storagePath `
                            -Now $ObservedAt `
                            -BypassCache
                    )
                    $retainedHistory = @(
                        Select-UsageHistoryRetentionWindow `
                            -Samples @($fullHistory + $currentSamples) `
                            -Now $ObservedAt
                    )
                    Save-UsageHistory `
                        -Samples $retainedHistory `
                        -Path $Path `
                        -Now $ObservedAt `
                        -AllowDiagnosticWrite:$AllowDiagnosticWrite `
                        -SkipWriteLock
                }
                finally {
                    Exit-UsageHistoryWriteLock -Mutex $writeLock
                }
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
        CurrentSamples = $currentSamples
        CurrentSample = $currentSample
        PreviousSample = $previousSample
        Changed = $changed
    }
}

function Split-UsageTrendSeries {
    param([object[]]$Samples)

    $segments = New-Object Collections.Generic.List[object]
    $current = New-Object Collections.Generic.List[object]
    $previous = $null
    foreach ($sample in @($Samples | Sort-Object ObservedAtUtc)) {
        if ($previous) {
            $increase = (
                [double]$sample.RemainingValue -
                [double]$previous.RemainingValue
            )
            if ($increase -gt 0.0001 -and $current.Count -gt 0) {
                [void]$segments.Add([pscustomobject]@{
                    Samples = @($current.ToArray())
                })
                $current = New-Object Collections.Generic.List[object]
            }
        }
        [void]$current.Add($sample)
        $previous = $sample
    }
    if ($current.Count -gt 0) {
        [void]$segments.Add([pscustomobject]@{
            Samples = @($current.ToArray())
        })
    }
    return $segments.ToArray()
}
function Get-UsageTrend {
    param(
        [object[]]$Samples,
        $CurrentSample,
        [double]$Hours,
        [switch]$StretchToFit,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    if (-not $CurrentSample) {
        return [pscustomobject]@{
            Hours = $Hours
            Samples = @()
            Segments = @()
            ComparisonSamples = @()
            SampleCount = 0
            ComparisonAvailable = $false
            Change = 0.0
            StartValue = $null
            EndValue = $null
            AxisStartUtc = $null
            AxisEndUtc = $null
            Summary = '暂无数据'
        }
    }

    $nowUtc = $Now.ToUniversalTime()
    $cutoff = $nowUtc.AddHours(-$Hours)
    $currentQuotaPeriod = Get-UsageQuotaPeriod -Value $CurrentSample
    $matching = @(
        $Samples | Where-Object {
            $_.ProviderId -eq $CurrentSample.ProviderId -and
            $_.MetricType -eq $CurrentSample.MetricType -and
            (Get-UsageQuotaPeriod -Value $_) -eq $currentQuotaPeriod -and
            $_.Unit -eq $CurrentSample.Unit -and
            $_.ObservedAtUtc -le $nowUtc.AddMinutes(5)
        } | Sort-Object ObservedAtUtc
    )
    $windowSamples = @($matching | Where-Object { $_.ObservedAtUtc -ge $cutoff })
    if ($StretchToFit) {
        $series = @(if ($windowSamples.Count -gt 0) {
            $windowSamples
        } elseif ($matching.Count -gt 0) {
            @($matching[-1])
        } else {
            @()
        })
        $sampleCount = $windowSamples.Count
        if (
            $series.Count -gt 0 -and
            ($nowUtc - ([DateTimeOffset]$series[-1].ObservedAtUtc)).TotalSeconds -gt 60
        ) {
            $nowPoint = [pscustomobject]@{
                Version = $series[-1].Version
                ProviderId = $CurrentSample.ProviderId
                ObservedAtUtc = $nowUtc
                MetricType = $CurrentSample.MetricType
                RemainingValue = [double]$CurrentSample.RemainingValue
                Unit = $CurrentSample.Unit
                ResetAtUtc = ''
            }
            $series = @($series) + @($nowPoint)
        }
        $previousSample = $null
        $currentObservedAt = (
            [DateTimeOffset]$CurrentSample.ObservedAtUtc
        ).ToUniversalTime()
        foreach ($candidate in $series) {
            if ([object]::ReferenceEquals($candidate, $CurrentSample)) { continue }
            if (
                ([DateTimeOffset]$candidate.ObservedAtUtc).ToUniversalTime() -ge
                $currentObservedAt
            ) { continue }
            $previousSample = $candidate
        }
        $resetAcrossGap = (
            $null -ne $previousSample -and
            (
                $nowUtc -
                ([DateTimeOffset]$previousSample.ObservedAtUtc).ToUniversalTime()
            ).TotalMinutes -gt 10 -and
            (
                [double]$CurrentSample.RemainingValue -
                [double]$previousSample.RemainingValue
            ) -gt 0.0001
        )
        if ($resetAcrossGap) {
            # The app was offline long enough that a quota reset happened in
            # the gap. The pre-reset points belong to an exhausted window, so
            # restart the stretched chart at the current value instead of
            # anchoring its left edge on the stale pre-reset reading.
            $anchorAtUtc = (
                [DateTimeOffset]$previousSample.ObservedAtUtc
            ).ToUniversalTime()
            if ($anchorAtUtc -lt $cutoff) { $anchorAtUtc = $cutoff }
            $anchorPoint = [pscustomobject]@{
                Version = 3
                ProviderId = $CurrentSample.ProviderId
                ObservedAtUtc = $anchorAtUtc
                MetricType = $CurrentSample.MetricType
                RemainingValue = [double]$CurrentSample.RemainingValue
                Unit = $CurrentSample.Unit
                ResetAtUtc = ''
            }
            $series = @($anchorPoint) + @($series[-1])
            $sampleCount = 1
        }
        $axisStartUtc = if ($series.Count -gt 0) {
            [DateTimeOffset]$series[0].ObservedAtUtc
        } else { $null }
        $axisEndUtc = if ($series.Count -gt 0) { $nowUtc } else { $null }
    } else {
        $boundarySample = $matching |
            Where-Object { $_.ObservedAtUtc -lt $cutoff } |
            Select-Object -Last 1
        $series = @(if ($boundarySample) {
            @($boundarySample) + $windowSamples
        } else {
            $windowSamples
        })
        $sampleCount = @(
            $series | Where-Object { $_.ObservedAtUtc -ge $cutoff }
        ).Count
        $axisStartUtc = $null
        $axisEndUtc = $null
    }

    $segments = @(Split-UsageTrendSeries -Samples $series)
    $comparisonSeries = @(if ($segments.Count -gt 0) {
        $segments[-1].Samples
    })
    $comparisonAvailable = $comparisonSeries.Count -ge 2
    if (-not $comparisonAvailable) {
        return [pscustomobject]@{
            Hours = $Hours
            Samples = $series
            Segments = $segments
            ComparisonSamples = $comparisonSeries
            SampleCount = $sampleCount
            ComparisonAvailable = $false
            Change = 0.0
            StartValue = if ($comparisonSeries.Count -eq 1) {
                [double]$comparisonSeries[0].RemainingValue
            } else { $null }
            EndValue = if ($comparisonSeries.Count -eq 1) {
                [double]$comparisonSeries[0].RemainingValue
            } else { $null }
            AxisStartUtc = $axisStartUtc
            AxisEndUtc = $axisEndUtc
            Summary = '积累中'
        }
    }

    $change = (
        [double]$comparisonSeries[-1].RemainingValue -
        [double]$comparisonSeries[0].RemainingValue
    )
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
        Segments = $segments
        ComparisonSamples = $comparisonSeries
        SampleCount = $sampleCount
        ComparisonAvailable = $true
        Change = $change
        StartValue = [double]$comparisonSeries[0].RemainingValue
        EndValue = [double]$comparisonSeries[-1].RemainingValue
        AxisStartUtc = $axisStartUtc
        AxisEndUtc = $axisEndUtc
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

    $currentQuotaPeriod = Get-UsageQuotaPeriod -Value $CurrentSample
    $matching = @(
        $Samples | Where-Object {
            $_.ProviderId -eq $CurrentSample.ProviderId -and
            $_.MetricType -eq $CurrentSample.MetricType -and
            (Get-UsageQuotaPeriod -Value $_) -eq $currentQuotaPeriod -and
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
    if ($providerId -in @('Codex', 'Kimi')) {
        $providerDisplayName = if ($providerId -eq 'Kimi') { 'Kimi Code' } else { 'Codex' }
        $metricType = 'Percent'
        $threshold = $CodexPercent
        $unit = '%'
        $quotaPeriod = if (
            $Snapshot.PSObject.Properties['PrimaryQuotaPeriod'] -and
            [string]$Snapshot.PrimaryQuotaPeriod -eq 'Weekly'
        ) { 'Weekly' } else { 'FiveHour' }
        $quotaLabel = if ($quotaPeriod -eq 'Weekly') { '每周' } else { '5 小时' }
        if (-not [bool]$Snapshot.HasProgress) {
            return & $emptyResult $providerId $metricType $threshold $unit `
                "等待 $providerDisplayName $quotaLabel 余量数据"
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

    if ($providerId -notin @('Codex', 'Kimi')) { $quotaPeriod = '' }

    $cutoff = $Now.ToUniversalTime().AddMinutes(-$WindowMinutes)
    $series = @(
        $Samples | Where-Object {
            $_.ProviderId -eq $providerId -and
            $_.MetricType -eq $metricType -and
            (Get-UsageQuotaPeriod -Value $_) -eq $quotaPeriod -and
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

function Select-UsageHistoryAnalysisSamples {
    param(
        [object[]]$Samples,
        $CurrentSample,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    if (-not $CurrentSample) { return @() }
    $quotaPeriod = Get-UsageQuotaPeriod -Value $CurrentSample
    $futureLimit = $Now.ToUniversalTime().AddMinutes(5)
    $matching = @(
        $Samples | Where-Object {
            $_.ProviderId -eq $CurrentSample.ProviderId -and
            $_.MetricType -eq $CurrentSample.MetricType -and
            (Get-UsageQuotaPeriod -Value $_) -eq $quotaPeriod -and
            $_.Unit -eq $CurrentSample.Unit -and
            $_.ObservedAtUtc -le $futureLimit
        } | Sort-Object ObservedAtUtc
    )
    if ($matching.Count -le 2880) { return $matching }

    $selected = New-Object Collections.Generic.List[object]
    $previous = $null
    $bucketFirst = $null
    $bucketLast = $null
    $bucketKey = [long]::MinValue
    $recentCutoffTicks = $Now.ToUniversalTime().AddHours(-26).Ticks
    $ticksPerRecentBucket = [TimeSpan]::FromMinutes(5).Ticks
    $ticksPerOlderBucket = [TimeSpan]::FromMinutes(30).Ticks
    foreach ($sample in $matching) {
        $observedAt = ([DateTimeOffset]$sample.ObservedAtUtc).ToUniversalTime()
        $ticksPerBucket = if ($observedAt.Ticks -ge $recentCutoffTicks) {
            $ticksPerRecentBucket
        } else {
            $ticksPerOlderBucket
        }
        $sampleBucket = [long][Math]::Floor($observedAt.UtcDateTime.Ticks / $ticksPerBucket)
        if ($sampleBucket -ne $bucketKey) {
            if ($bucketFirst) { [void]$selected.Add($bucketFirst) }
            if (
                $bucketLast -and
                -not [object]::ReferenceEquals($bucketLast, $bucketFirst)
            ) {
                [void]$selected.Add($bucketLast)
            }
            $bucketKey = $sampleBucket
            $bucketFirst = $sample
            $bucketLast = $sample
        }
        else {
            $bucketLast = $sample
        }

        if (
            $previous -and
            [Math]::Abs(
                [double]$sample.RemainingValue -
                [double]$previous.RemainingValue
            ) -gt 0.0001
        ) {
            if (-not $selected.Contains($previous)) {
                [void]$selected.Add($previous)
            }
            if (-not $selected.Contains($sample)) {
                [void]$selected.Add($sample)
            }
        }
        $previous = $sample
    }
    if ($bucketFirst -and -not $selected.Contains($bucketFirst)) {
        [void]$selected.Add($bucketFirst)
    }
    if ($bucketLast -and -not $selected.Contains($bucketLast)) {
        [void]$selected.Add($bucketLast)
    }
    return @($selected.ToArray() | Sort-Object ObservedAtUtc -Unique)
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

    $analysisSamples = @(
        Select-UsageHistoryAnalysisSamples `
            -Samples $Samples `
            -CurrentSample $CurrentSample `
            -Now $Now
    )
    return [pscustomobject]@{
        CurrentSample = $CurrentSample
        PreviousSample = $PreviousSample
        Trend5Hours = Get-UsageTrend `
            -Samples $analysisSamples `
            -CurrentSample $CurrentSample `
            -Hours 5 `
            -StretchToFit `
            -Now $Now
        Trend7Days = Get-UsageTrend `
            -Samples $analysisSamples `
            -CurrentSample $CurrentSample `
            -Hours (24 * 7) `
            -Now $Now
        Forecast = Get-DepletionForecast `
            -Samples $analysisSamples `
            -CurrentSample $CurrentSample `
            -Now $Now
        RapidDrop = Measure-RapidUsageDrop `
            -Samples $analysisSamples `
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
    if (
        -not $SkipPersistence -and
        (Get-Command Update-SpendLedger -ErrorAction SilentlyContinue)
    ) {
        [void](Update-SpendLedger `
            -Samples @($record.CurrentSamples) `
            -ObservedAt $ObservedAt)
    }
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
