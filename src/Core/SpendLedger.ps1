# Spend ledger: a long-lived per-day record of money actually consumed, derived
# from real provider balance movements. The trend history only keeps seven days,
# so it cannot answer "how much did I spend this month"; this component keeps its
# own two-month window of day buckets instead.

function Get-SpendLedgerPath {
    param([string]$RootPath = '')

    if (-not [string]::IsNullOrWhiteSpace($RootPath)) {
        return [IO.Path]::GetFullPath($RootPath)
    }
    return Join-Path (Get-AppDataDirectory) 'spend-ledger.json'
}

function Get-SpendLedgerProperty {
    # Deliberately local: Core must not reach into the provider components, and
    # every deserialized ledger field is read through here so a missing property
    # can never trip StrictMode.
    param(
        $Object,
        [string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function Get-SpendLedgerGapThresholdMinutes {
    # Twenty refresh cycles (the refresh interval is 60 seconds). A normal
    # refresh or a short provider outage never trips this; a suspended or closed
    # application does.
    return 20
}

function Get-SpendLedgerAmountEpsilon {
    return 0.0001
}

function Get-SpendLedgerMaxDayCount {
    return 62
}

function Format-SpendLedgerTimestamp {
    param($Value)

    if ($null -eq $Value) { return $null }
    try {
        return ([DateTimeOffset]$Value).
            ToUniversalTime().
            ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        return $null
    }
}

function Get-SpendLedgerTimestamp {
    param($Value)

    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try {
        return [DateTimeOffset]::Parse(
            $text,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
    }
    catch {
        return $null
    }
}

function Get-SpendLedgerAmount {
    param(
        $Value,
        [double]$Default = 0.0
    )

    if ($null -eq $Value) { return $Default }
    try {
        $amount = [double]::Parse(
            [string]$Value,
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    catch {
        return $Default
    }
    if ([double]::IsNaN($amount) -or [double]::IsInfinity($amount)) {
        return $Default
    }
    return $amount
}

function Format-SpendLedgerDateLabel {
    param([string]$Date)

    # Coverage start shown on the month card, e.g. "2026-09-09" -> "9/9".
    if ($Date -notmatch '^(\d{4})-(\d{2})-(\d{2})$') { return [string]$Date }
    return '{0}/{1}' -f [int]$matches[2], [int]$matches[3]
}

function New-SpendLedgerDay {
    param([string]$Date)

    # Spent is what could be pinned to this local day. GapDrop is a drop that
    # happened while nothing was observing and crossed a local midnight: it is
    # still this month's money, but guessing which of the two days it belongs to
    # would be wrong, so it stays out of the day figure. UnattributedDrop crossed
    # a month boundary and belongs to no month at all.
    return [pscustomobject]@{
        Date = $Date
        Spent = 0.0
        Credit = 0.0
        Samples = 0
        MaxGapMinutes = 0.0
        GapDrop = 0.0
        UnattributedDrop = 0.0
    }
}

function New-SpendLedgerProvider {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProviderId,
        [string]$Unit = 'CNY'
    )

    return [pscustomobject]@{
        ProviderId = $ProviderId
        Unit = $Unit
        LastBalance = $null
        LastObservedAtUtc = $null
        SeededAtUtc = $null
        SeedSampleCount = 0
        GapDropCount = 0
        Days = @()
    }
}

function Get-EmptySpendLedger {
    return [pscustomobject]@{
        Version = 1
        UpdatedAtUtc = $null
        Providers = @()
    }
}

function ConvertFrom-SpendLedgerDocument {
    param($Saved)

    if (-not $Saved) { throw '花费台账内容为空。' }
    if (
        [int](Get-SpendLedgerProperty -Object $Saved -Name 'Version' -Default 0) -ne 1
    ) {
        throw '花费台账版本不受支持。'
    }

    $ledger = Get-EmptySpendLedger
    $ledger.UpdatedAtUtc = Get-SpendLedgerTimestamp `
        -Value (Get-SpendLedgerProperty -Object $Saved -Name 'UpdatedAtUtc')

    $maxDays = Get-SpendLedgerMaxDayCount
    $providers = New-Object Collections.Generic.List[object]
    foreach ($savedProvider in @(
        Get-SpendLedgerProperty -Object $Saved -Name 'Providers' -Default @()
    )) {
        if ($providers.Count -ge 8) { break }
        $providerId = [string](
            Get-SpendLedgerProperty -Object $savedProvider -Name 'ProviderId' -Default ''
        )
        if ([string]::IsNullOrWhiteSpace($providerId)) { continue }

        $unit = [string](
            Get-SpendLedgerProperty -Object $savedProvider -Name 'Unit' -Default ''
        )
        $provider = New-SpendLedgerProvider `
            -ProviderId $providerId `
            -Unit $(if ([string]::IsNullOrWhiteSpace($unit)) { 'CNY' } else { $unit })
        $lastBalance = Get-SpendLedgerProperty `
            -Object $savedProvider `
            -Name 'LastBalance'
        if ($null -ne $lastBalance) {
            $provider.LastBalance = Get-SpendLedgerAmount -Value $lastBalance
        }
        $provider.LastObservedAtUtc = Get-SpendLedgerTimestamp `
            -Value (Get-SpendLedgerProperty -Object $savedProvider -Name 'LastObservedAtUtc')
        $provider.SeededAtUtc = Get-SpendLedgerTimestamp `
            -Value (Get-SpendLedgerProperty -Object $savedProvider -Name 'SeededAtUtc')
        $provider.SeedSampleCount = [int](
            Get-SpendLedgerAmount `
                -Value (Get-SpendLedgerProperty -Object $savedProvider -Name 'SeedSampleCount')
        )
        $provider.GapDropCount = [int](
            Get-SpendLedgerAmount `
                -Value (Get-SpendLedgerProperty -Object $savedProvider -Name 'GapDropCount')
        )

        $days = New-Object Collections.Generic.List[object]
        foreach ($savedDay in @(
            Get-SpendLedgerProperty -Object $savedProvider -Name 'Days' -Default @()
        )) {
            if ($days.Count -ge $maxDays) { break }
            $date = [string](
                Get-SpendLedgerProperty -Object $savedDay -Name 'Date' -Default ''
            )
            if ($date -notmatch '^\d{4}-\d{2}-\d{2}$') { continue }
            $day = New-SpendLedgerDay -Date $date
            $day.Spent = Get-SpendLedgerAmount `
                -Value (Get-SpendLedgerProperty -Object $savedDay -Name 'Spent')
            $day.Credit = Get-SpendLedgerAmount `
                -Value (Get-SpendLedgerProperty -Object $savedDay -Name 'Credit')
            $day.Samples = [int](
                Get-SpendLedgerAmount `
                    -Value (Get-SpendLedgerProperty -Object $savedDay -Name 'Samples')
            )
            $day.MaxGapMinutes = Get-SpendLedgerAmount `
                -Value (Get-SpendLedgerProperty -Object $savedDay -Name 'MaxGapMinutes')
            $day.GapDrop = Get-SpendLedgerAmount `
                -Value (Get-SpendLedgerProperty -Object $savedDay -Name 'GapDrop')
            $day.UnattributedDrop = Get-SpendLedgerAmount `
                -Value (Get-SpendLedgerProperty -Object $savedDay -Name 'UnattributedDrop')
            $days.Add($day)
        }
        $provider.Days = $days.ToArray()
        $providers.Add($provider)
    }
    $ledger.Providers = $providers.ToArray()
    return $ledger
}

function ConvertTo-SpendLedgerDocument {
    param($Ledger)

    $providers = New-Object Collections.Generic.List[object]
    foreach ($provider in @($Ledger.Providers)) {
        if (-not $provider) { continue }
        $days = New-Object Collections.Generic.List[object]
        foreach ($day in @($provider.Days)) {
            if (-not $day) { continue }
            $days.Add([ordered]@{
                Date = [string]$day.Date
                Spent = [Math]::Round([double]$day.Spent, 4)
                Credit = [Math]::Round([double]$day.Credit, 4)
                Samples = [int]$day.Samples
                MaxGapMinutes = [Math]::Round([double]$day.MaxGapMinutes, 1)
                GapDrop = [Math]::Round([double]$day.GapDrop, 4)
                UnattributedDrop = [Math]::Round([double]$day.UnattributedDrop, 4)
            })
        }
        $providers.Add([ordered]@{
            ProviderId = [string]$provider.ProviderId
            Unit = [string]$provider.Unit
            LastBalance = if ($null -eq $provider.LastBalance) {
                $null
            } else {
                [Math]::Round([double]$provider.LastBalance, 4)
            }
            LastObservedAtUtc = Format-SpendLedgerTimestamp `
                -Value $provider.LastObservedAtUtc
            SeededAtUtc = Format-SpendLedgerTimestamp -Value $provider.SeededAtUtc
            SeedSampleCount = [int]$provider.SeedSampleCount
            GapDropCount = [int]$provider.GapDropCount
            Days = $days.ToArray()
        })
    }
    return [ordered]@{
        Version = 1
        UpdatedAtUtc = Format-SpendLedgerTimestamp -Value $Ledger.UpdatedAtUtc
        Providers = $providers.ToArray()
    }
}

function Read-SpendLedger {
    param(
        [string]$Path = '',
        [switch]$BypassCache
    )

    $usesDefaultPath = [string]::IsNullOrWhiteSpace($Path)
    if (
        $usesDefaultPath -and
        -not $BypassCache -and
        $script:SpendLedgerLoaded -and
        $null -ne $script:SpendLedgerCache
    ) {
        return $script:SpendLedgerCache
    }

    $ledger = Get-EmptySpendLedger
    $errorMessage = ''
    try {
        $targetPath = Get-SpendLedgerPath -RootPath $Path
        if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
            $file = Get-Item -LiteralPath $targetPath
            if ($file.Length -gt 512KB) {
                throw '花费台账文件超过 512 KB 安全上限。'
            }
            $saved = Get-Content -LiteralPath $targetPath -Raw -Encoding UTF8 |
                ConvertFrom-Json
            $ledger = ConvertFrom-SpendLedgerDocument -Saved $saved
        }
    }
    catch {
        # A damaged ledger must never block startup or refresh; fall back to an
        # empty one and keep the reason for diagnostics.
        $ledger = Get-EmptySpendLedger
        $errorMessage = $_.Exception.Message
        if (Get-Command Write-RuntimeLog -ErrorAction SilentlyContinue) {
            Write-RuntimeLog `
                -Level 'Warning' `
                -Event 'SpendLedger.ReadFailed' `
                -Message $errorMessage
        }
    }

    if ($usesDefaultPath) {
        $script:LastSpendLedgerError = $errorMessage
        $script:SpendLedgerCache = $ledger
        $script:SpendLedgerLoaded = $true
    }
    return $ledger
}

function Enter-SpendLedgerWriteLock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [int]$TimeoutMilliseconds = 10000
    )

    return Enter-FileWriteLock `
        -Path $Path `
        -LockName 'SpendLedger' `
        -TimeoutErrorMessage '等待花费台账写入锁超时。' `
        -TimeoutMilliseconds $TimeoutMilliseconds
}

function Exit-SpendLedgerWriteLock {
    param($Mutex)

    Exit-FileWriteLock -Mutex $Mutex
}

function Save-SpendLedger {
    param(
        $Ledger,
        [string]$Path = '',
        [switch]$AllowDiagnosticWrite,
        [switch]$SkipWriteLock
    )

    if ($isDiagnosticRun -and -not $AllowDiagnosticWrite) { return $false }

    $usesDefaultPath = [string]::IsNullOrWhiteSpace($Path)
    $Ledger.UpdatedAtUtc = [DateTimeOffset]::Now
    $document = ConvertTo-SpendLedgerDocument -Ledger $Ledger |
        ConvertTo-Json -Depth 6
    $writeLock = $null
    try {
        $targetPath = Get-SpendLedgerPath -RootPath $Path
        if (-not $SkipWriteLock) {
            $writeLock = Enter-SpendLedgerWriteLock -Path $targetPath
        }
        Write-UsageStateAtomicText -Path $targetPath -Text $document
        if ($usesDefaultPath) {
            $script:LastSpendLedgerError = ''
            $script:SpendLedgerCache = $Ledger
            $script:SpendLedgerLoaded = $true
        }
        return $true
    }
    catch {
        if ($usesDefaultPath) {
            $script:LastSpendLedgerError = $_.Exception.Message
        }
        if (Get-Command Write-RuntimeLog -ErrorAction SilentlyContinue) {
            Write-RuntimeLog `
                -Level 'Warning' `
                -Event 'SpendLedger.WriteFailed' `
                -Message $_.Exception.Message
        }
        return $false
    }
    finally {
        if ($writeLock) { Exit-SpendLedgerWriteLock -Mutex $writeLock }
    }
}

function Get-SpendLedgerProvider {
    param(
        $Ledger,
        [Parameter(Mandatory = $true)]
        [string]$ProviderId,
        [string]$Unit = 'CNY'
    )

    foreach ($provider in @($Ledger.Providers)) {
        if (-not $provider) { continue }
        if ([string]$provider.ProviderId -eq $ProviderId) {
            if (-not [string]::IsNullOrWhiteSpace($Unit)) {
                $provider.Unit = $Unit
            }
            return $provider
        }
    }

    $created = New-SpendLedgerProvider -ProviderId $ProviderId -Unit $Unit
    $Ledger.Providers = @($Ledger.Providers) + $created
    return $created
}

function Get-SpendLedgerDay {
    param(
        $Provider,
        [Parameter(Mandatory = $true)]
        [string]$Date
    )

    foreach ($day in @($Provider.Days)) {
        if (-not $day) { continue }
        if ([string]$day.Date -eq $Date) { return $day }
    }

    $created = New-SpendLedgerDay -Date $Date
    $Provider.Days = @($Provider.Days) + $created
    return $created
}

function Add-SpendLedgerObservation {
    param(
        $Ledger,
        [Parameter(Mandatory = $true)]
        [string]$ProviderId,
        [string]$Unit = 'CNY',
        [double]$Balance,
        [DateTimeOffset]$ObservedAt = [DateTimeOffset]::Now,
        [string]$LocalDate = '',
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local,
        [int]$GapThresholdMinutes = 0
    )

    if ($GapThresholdMinutes -le 0) {
        $GapThresholdMinutes = Get-SpendLedgerGapThresholdMinutes
    }
    if ([string]::IsNullOrWhiteSpace($LocalDate)) {
        $LocalDate = (Get-UsageHistoryCalendarMetadata `
            -ObservedAt $ObservedAt `
            -TimeZone $TimeZone).LocalDate
    }
    $epsilon = Get-SpendLedgerAmountEpsilon

    $provider = Get-SpendLedgerProvider `
        -Ledger $Ledger `
        -ProviderId $ProviderId `
        -Unit $Unit
    $day = Get-SpendLedgerDay -Provider $provider -Date $LocalDate
    $day.Samples = [int]$day.Samples + 1

    $previousBalance = $provider.LastBalance
    $previousAt = $provider.LastObservedAtUtc
    if ($null -eq $previousBalance) {
        # First observation only establishes the baseline.
        $provider.LastBalance = $Balance
        $provider.LastObservedAtUtc = $ObservedAt.ToUniversalTime()
        return $true
    }

    $gapMinutes = 0.0
    if ($null -ne $previousAt) {
        $gapMinutes = [Math]::Max(
            0.0,
            ($ObservedAt.ToUniversalTime() -
                ([DateTimeOffset]$previousAt).ToUniversalTime()).TotalMinutes
        )
    }
    if ($gapMinutes -gt [double]$day.MaxGapMinutes) {
        $day.MaxGapMinutes = $gapMinutes
    }

    $delta = [double]$previousBalance - $Balance
    if ([Math]::Abs($delta) -le $epsilon) {
        # Nothing moved. Keep the observation time fresh so a later drop is not
        # mistaken for an outage, but skip the disk write.
        $provider.LastObservedAtUtc = $ObservedAt.ToUniversalTime()
        return $false
    }

    $provider.LastBalance = $Balance
    $provider.LastObservedAtUtc = $ObservedAt.ToUniversalTime()

    if ($delta -lt 0) {
        # A top-up or a grant. It raises the baseline but never cancels spend.
        $day.Credit = [double]$day.Credit + [Math]::Abs($delta)
        return $true
    }

    $previousLocalDate = $LocalDate
    if ($null -ne $previousAt) {
        $previousLocalDate = (Get-UsageHistoryCalendarMetadata `
            -ObservedAt ([DateTimeOffset]$previousAt) `
            -TimeZone $TimeZone).LocalDate
    }
    $crossedDay = (
        $gapMinutes -gt [double]$GapThresholdMinutes -and
        $previousLocalDate -ne $LocalDate
    )
    if (-not $crossedDay) {
        $day.Spent = [double]$day.Spent + $delta
        return $true
    }

    # The drop happened while nothing was observing and spanned a local
    # midnight, so it cannot be pinned to one of the two days. It still belongs
    # to this month unless the gap itself crossed a month boundary, in which case
    # no month can claim it.
    $provider.GapDropCount = [int]$provider.GapDropCount + 1
    if ($previousLocalDate.Substring(0, 7) -eq $LocalDate.Substring(0, 7)) {
        $day.GapDrop = [double]$day.GapDrop + $delta
    }
    else {
        $day.UnattributedDrop = [double]$day.UnattributedDrop + $delta
    }
    return $true
}

function Initialize-SpendLedgerFromHistory {
    param(
        $Ledger,
        [DateTimeOffset]$Before = [DateTimeOffset]::MaxValue,
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local,
        [object[]]$HistorySamples = $null
    )

    # The trend history keeps seven days, so a brand new ledger can be primed
    # with them. The guard is one-shot: replaying again would count twice.
    $records = @()
    if ($null -ne $HistorySamples) {
        $source = $HistorySamples
    }
    else {
        try {
            $source = Read-UsageHistory -BypassCache -TimeZone $TimeZone
        }
        catch {
            if (Get-Command Write-RuntimeLog -ErrorAction SilentlyContinue) {
                Write-RuntimeLog `
                    -Level 'Warning' `
                    -Event 'SpendLedger.SeedFailed' `
                    -Message $_.Exception.Message
            }
            return 0
        }
    }
    $records = @(
        $source | Where-Object {
            $_ -and
            [string]$_.MetricType -eq 'Balance' -and
            ([DateTimeOffset]$_.ObservedAtUtc).ToUniversalTime() -lt
                $Before.ToUniversalTime()
        } | Sort-Object ObservedAtUtc
    )
    if ($records.Count -eq 0) { return 0 }

    $seeded = 0
    foreach ($group in @($records | Group-Object ProviderId)) {
        $providerId = [string]$group.Name
        if ([string]::IsNullOrWhiteSpace($providerId)) { continue }
        $groupRecords = @($group.Group | Sort-Object ObservedAtUtc)
        $unit = [string](
            Get-SpendLedgerProperty -Object $groupRecords[0] -Name 'Unit' -Default 'CNY'
        )
        $provider = Get-SpendLedgerProvider `
            -Ledger $Ledger `
            -ProviderId $providerId `
            -Unit $unit
        if ($null -ne $provider.SeededAtUtc) { continue }

        foreach ($record in $groupRecords) {
            [void](Add-SpendLedgerObservation `
                -Ledger $Ledger `
                -ProviderId $providerId `
                -Unit $unit `
                -Balance (Get-SpendLedgerAmount -Value $record.RemainingValue) `
                -ObservedAt ([DateTimeOffset]$record.ObservedAtUtc) `
                -TimeZone $TimeZone)
        }
        $provider.SeededAtUtc = [DateTimeOffset]::Now.ToUniversalTime()
        $provider.SeedSampleCount = $groupRecords.Count
        $seeded += $groupRecords.Count
    }
    return $seeded
}

function Select-SpendLedgerRetentionWindow {
    param(
        [object[]]$Days,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now,
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local
    )

    # Keep the current and the previous local month: enough for "this month" and
    # for a figure that stays comparable right after a month rolls over.
    $localNow = [TimeZoneInfo]::ConvertTime($Now.ToUniversalTime(), $TimeZone)
    $currentMonthStart = New-Object DateTime($localNow.Year, $localNow.Month, 1)
    $earliestDate = $currentMonthStart.
        AddMonths(-1).
        ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $latestDate = $currentMonthStart.
        AddMonths(1).
        AddDays(-1).
        ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)

    return @(
        $Days | Where-Object {
            $_ -and
            [string]$_.Date -match '^\d{4}-\d{2}-\d{2}$' -and
            [string]$_.Date -ge $earliestDate -and
            [string]$_.Date -le $latestDate
        } | Sort-Object { [string]$_.Date }
    )
}

function Prune-SpendLedger {
    param(
        $Ledger,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now,
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local
    )

    foreach ($provider in @($Ledger.Providers)) {
        if (-not $provider) { continue }
        $provider.Days = @(
            Select-SpendLedgerRetentionWindow `
                -Days @($provider.Days) `
                -Now $Now `
                -TimeZone $TimeZone
        )
    }
}

function Get-SpendSummary {
    param(
        $Ledger,
        [Parameter(Mandatory = $true)]
        [string]$ProviderId,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now,
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local
    )

    $today = (Get-UsageHistoryCalendarMetadata `
        -ObservedAt $Now `
        -TimeZone $TimeZone).LocalDate
    $summary = [pscustomobject]@{
        ProviderId = $ProviderId
        Unit = 'CNY'
        HasData = $false
        HasToday = $false
        TodaySpent = 0.0
        TodayComplete = $true
        MonthSpent = 0.0
        MonthCredit = 0.0
        MonthGapDrop = 0.0
        MonthKey = $today.Substring(0, 7)
        TodayDate = $today
        CoverageStartDate = ''
        CoverageDays = 0
        CoverageComplete = $false
        MonthComplete = $true
        SampleCount = 0
        GapDropCount = 0
        LastBalance = 0.0
        LastObservedAtUtc = $null
    }

    try {
        if (-not $Ledger) { return $summary }
        $provider = $null
        foreach ($candidate in @($Ledger.Providers)) {
            if (-not $candidate) { continue }
            if ([string]$candidate.ProviderId -ne $ProviderId) { continue }
            $provider = $candidate
            break
        }
        if (-not $provider) { return $summary }

        $unit = [string]$provider.Unit
        if (-not [string]::IsNullOrWhiteSpace($unit)) { $summary.Unit = $unit }
        $summary.GapDropCount = [int]$provider.GapDropCount
        if ($null -ne $provider.LastBalance) {
            $summary.LastBalance = [double]$provider.LastBalance
        }
        $summary.LastObservedAtUtc = $provider.LastObservedAtUtc

        $days = @($provider.Days | Where-Object { $_ -and $_.Date })
        $summary.HasData = ($days.Count -gt 0)

        $monthKey = $summary.MonthKey
        $monthStart = $monthKey + '-01'
        $monthDays = @(
            $days | Where-Object {
                ([string]$_.Date).StartsWith(
                    $monthKey,
                    [StringComparison]::Ordinal
                )
            }
        )

        $epsilon = Get-SpendLedgerAmountEpsilon
        $todaySpent = 0.0
        $todayComplete = $true
        $hasToday = $false
        $monthSpent = 0.0
        $monthCredit = 0.0
        $sampleCount = 0
        $monthComplete = $true
        $monthGapDrop = 0.0
        $monthDates = New-Object Collections.Generic.List[string]
        foreach ($day in $monthDays) {
            # GapDrop belongs to the month even though it belongs to no day.
            $monthSpent += ([double]$day.Spent + [double]$day.GapDrop)
            $monthCredit += [double]$day.Credit
            $sampleCount += [int]$day.Samples
            $monthDates.Add([string]$day.Date)
            $gapDrop = [double]$day.GapDrop
            $unattributed = [double]$day.UnattributedDrop
            $monthGapDrop += $gapDrop
            # Only a drop that crossed a month boundary can leave the month
            # figure short.
            if ($unattributed -gt $epsilon) { $monthComplete = $false }
            if ([string]$day.Date -ne $today) { continue }
            $hasToday = $true
            $todaySpent += [double]$day.Spent
            if (($gapDrop + $unattributed) -gt $epsilon) {
                $todayComplete = $false
            }
        }

        $summary.HasToday = $hasToday
        $summary.TodaySpent = [Math]::Round($todaySpent, 2)
        $summary.TodayComplete = $todayComplete
        $summary.MonthSpent = [Math]::Round($monthSpent, 2)
        $summary.MonthCredit = [Math]::Round($monthCredit, 2)
        $summary.MonthGapDrop = [Math]::Round($monthGapDrop, 2)
        $summary.MonthComplete = $monthComplete
        $summary.SampleCount = $sampleCount
        if ($monthDates.Count -gt 0) {
            $sortedDates = @($monthDates | Sort-Object)
            $summary.CoverageStartDate = [string]$sortedDates[0]
            $summary.CoverageDays = $sortedDates.Count
            $summary.CoverageComplete = (
                [string]$sortedDates[0] -le $monthStart
            )
        }
    }
    catch {
        # Rendering must never fail because of statistics.
    }
    return $summary
}

function Update-SpendLedger {
    param(
        [object[]]$Samples,
        [DateTimeOffset]$ObservedAt = [DateTimeOffset]::Now,
        [switch]$SkipPersistence,
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Local
    )

    if ($isDiagnosticRun) { return $false }

    # Only normalized balance samples may feed the ledger: a snapshot that is
    # unavailable reports a zero balance, and the full sample list is the whole
    # history replayed on every refresh.
    $balanceSamples = @(
        $Samples | Where-Object {
            $_ -and
            [string]$_.MetricType -eq 'Balance' -and
            $_.PSObject.Properties['RemainingValue'] -and
            $_.PSObject.Properties['ObservedAtUtc']
        } | Sort-Object ObservedAtUtc
    )
    if ($balanceSamples.Count -eq 0) { return $false }

    try {
        $ledger = Read-SpendLedger
        $changed = $false
        $seeded = Initialize-SpendLedgerFromHistory `
            -Ledger $ledger `
            -Before $ObservedAt `
            -TimeZone $TimeZone
        if ($seeded -gt 0) {
            $changed = $true
            if (Get-Command Write-RuntimeLog -ErrorAction SilentlyContinue) {
                Write-RuntimeLog `
                    -Event 'SpendLedger.Seeded' `
                    -Message '已用趋势历史回填花费台账' `
                    -Data @{ Samples = $seeded }
            }
        }

        foreach ($sample in $balanceSamples) {
            $unit = [string](
                Get-SpendLedgerProperty -Object $sample -Name 'Unit' -Default 'CNY'
            )
            $applied = Add-SpendLedgerObservation `
                -Ledger $ledger `
                -ProviderId ([string]$sample.ProviderId) `
                -Unit $unit `
                -Balance (Get-SpendLedgerAmount -Value $sample.RemainingValue) `
                -ObservedAt ([DateTimeOffset]$sample.ObservedAtUtc) `
                -TimeZone $TimeZone
            if ($applied) { $changed = $true }
        }
        if (-not $changed) { return $false }

        Prune-SpendLedger -Ledger $ledger -Now $ObservedAt -TimeZone $TimeZone
        if ($SkipPersistence) { return $true }
        [void](Save-SpendLedger -Ledger $ledger)
        return $true
    }
    catch {
        if (Get-Command Write-RuntimeLog -ErrorAction SilentlyContinue) {
            Write-RuntimeLog `
                -Level 'Warning' `
                -Event 'SpendLedger.UpdateFailed' `
                -Message $_.Exception.Message
        }
        return $false
    }
}
