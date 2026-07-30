function Get-DeepSeekCredential {
    if (-not [string]::IsNullOrWhiteSpace($env:DEEPSEEK_API_KEY)) {
        $environmentKey = $env:DEEPSEEK_API_KEY.Trim()
        $hint = if ($environmentKey.Length -gt 4) {
            $environmentKey.Substring($environmentKey.Length - 4)
        } else {
            $environmentKey
        }
        return [pscustomobject]@{
            ApiKey = $environmentKey
            Hint = $hint
            Source = '环境变量'
        }
    }

    $configuration = Get-DeepSeekConfiguration
    $savedKey = Unprotect-LocalSecret -Value $configuration.EncryptedApiKey
    return [pscustomobject]@{
        ApiKey = $savedKey
        Hint = $configuration.KeyHint
        Source = if ($savedKey) { 'DPAPI 加密存储' } else { '未配置' }
    }
}

function Get-ObjectPropertyValue {
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

function ConvertFrom-DeepSeekUsageLine {
    param([string]$Line)

    try {
        return [DeepSeekLogScanner]::ParseLine($Line)
    }
    catch {
        return $null
    }
}

function Read-DeepSeekUsageFile {
    param([System.IO.FileInfo]$File)

    $cacheKey = '{0}:{1}' -f $File.LastWriteTimeUtc.Ticks, $File.Length
    if ($script:DeepSeekUsageCache.ContainsKey($File.FullName)) {
        $cached = $script:DeepSeekUsageCache[$File.FullName]
        if ($cached.Key -eq $cacheKey) { return $cached.Value }
    }

    $latest = $null
    $messageEvents = @()
    try {
        $messageEvents = @([DeepSeekLogScanner]::ReadFile($File.FullName))
        foreach ($event in $messageEvents) {
            if (-not $latest -or $event.Timestamp -gt $latest.Timestamp) {
                $latest = $event
            }
        }
    }
    catch {
        $messageEvents = @()
        $latest = $null
    }

    $value = [pscustomobject]@{
        Events = $messageEvents
        Latest = $latest
    }
    $script:DeepSeekUsageCache[$File.FullName] = [pscustomobject]@{
        Key = $cacheKey
        Value = $value
    }
    return $value
}

function Read-DeepSeekLatestUsageFile {
    param([System.IO.FileInfo]$File)

    $cacheKey = '{0}:{1}' -f $File.LastWriteTimeUtc.Ticks, $File.Length
    if ($script:DeepSeekLatestUsageCache.ContainsKey($File.FullName)) {
        $cached = $script:DeepSeekLatestUsageCache[$File.FullName]
        if ($cached.Key -eq $cacheKey) { return $cached.Value }
    }

    $latest = $null
    try {
        $stream = [IO.File]::Open(
            $File.FullName,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite
        )
        try {
            $tailLimit = 512KB
            $startOffset = [Math]::Max(0L, $stream.Length - $tailLimit)
            [void]$stream.Seek($startOffset, [IO.SeekOrigin]::Begin)
            $buffer = New-Object byte[] ([int]($stream.Length - $startOffset))
            $read = $stream.Read($buffer, 0, $buffer.Length)
            $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
            if ($startOffset -gt 0) {
                $firstLineBreak = $text.IndexOf("`n", [StringComparison]::Ordinal)
                $text = if ($firstLineBreak -ge 0) {
                    $text.Substring($firstLineBreak + 1)
                } else { '' }
            }

            foreach ($line in ($text -split "`r?`n")) {
                $event = ConvertFrom-DeepSeekUsageLine -Line $line
                if (-not $event) { continue }
                if (-not $latest -or $event.Timestamp -gt $latest.Timestamp) {
                    $latest = $event
                }
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        $latest = $null
    }

    if (-not $latest -and $File.Length -gt 512KB) {
        $latest = (Read-DeepSeekUsageFile -File $File).Latest
    }
    $script:DeepSeekLatestUsageCache[$File.FullName] = [pscustomobject]@{
        Key = $cacheKey
        Value = $latest
    }
    return $latest
}

function Get-DeepSeekEstimatedEventCostCny {
    param($Event)

    $catalog = Get-DeepSeekPricingCatalog
    $pricing = Get-DeepSeekPricingTier `
        -Model ([string]$Event.Model) `
        -Catalog $catalog
    $cacheMissTokens = $Event.InputTokens + $Event.CacheWriteTokens

    return (
        ($Event.CachedTokens * $pricing.CacheHit) +
        ($cacheMissTokens * $pricing.CacheMiss) +
        ($Event.OutputTokens * $pricing.Output)
    ) / $catalog.TokensPerUnit
}

function Measure-DeepSeekUsageEvents {
    param(
        [object[]]$Events,
        [datetime]$StartDate = (Get-Date).Date,
        [Nullable[datetime]]$EndDate = $null
    )

    $rangeStart = $StartDate.Date
    $rangeEnd = if ($null -ne $EndDate) { [datetime]$EndDate } else { $rangeStart.AddDays(1) }
    $uniqueEvents = @{}
    $anonymousIndex = 0
    foreach ($event in $Events) {
        if (-not $event) { continue }
        $eventTime = $event.Timestamp.LocalDateTime
        if ($eventTime -lt $rangeStart -or $eventTime -ge $rangeEnd) { continue }
        $eventKey = if ($event.MessageId) {
            $event.MessageId
        } else {
            $anonymousIndex++
            '__anonymous_{0}' -f $anonymousIndex
        }
        if (
            -not $uniqueEvents.ContainsKey($eventKey) -or
            $event.Timestamp -gt $uniqueEvents[$eventKey].Timestamp
        ) {
            $uniqueEvents[$eventKey] = $event
        }
    }

    $aggregate = [ordered]@{
        TotalTokens = 0.0
        InputTokens = 0.0
        OutputTokens = 0.0
        CachedTokens = 0.0
        CacheWriteTokens = 0.0
        EstimatedCostCny = 0.0
        UniqueMessages = $uniqueEvents.Count
    }
    foreach ($event in $uniqueEvents.Values) {
        $aggregate.TotalTokens += $event.TotalTokens
        $aggregate.InputTokens += $event.InputTokens
        $aggregate.OutputTokens += $event.OutputTokens
        $aggregate.CachedTokens += $event.CachedTokens
        $aggregate.CacheWriteTokens += $event.CacheWriteTokens
        $aggregate.EstimatedCostCny += Get-DeepSeekEstimatedEventCostCny -Event $event
    }
    return [pscustomobject]$aggregate
}

function Get-DeepSeekLocalUsage {
    $result = [ordered]@{
        TodayTokens = 0.0
        TodayInputTokens = 0.0
        TodayOutputTokens = 0.0
        TodayCachedTokens = 0.0
        MonthlyTokens = 0.0
        MonthlyEstimatedCostCny = 0.0
        LastTurnTokens = 0.0
        LastInputTokens = 0.0
        LastOutputTokens = 0.0
        LastCachedTokens = 0.0
        CacheHitPercent = 0.0
        Model = '暂无本地记录'
        SampledAt = Get-Date
    }

    $projectsRoot = Join-Path $env:USERPROFILE '.claude\projects'
    if (-not (Test-Path -LiteralPath $projectsRoot)) {
        return [pscustomobject]$result
    }

    $files = @(Get-ChildItem -LiteralPath $projectsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    $todayDate = (Get-Date).Date
    $monthStart = Get-Date -Day 1 -Hour 0 -Minute 0 -Second 0 -Millisecond 0
    $nextMonth = $monthStart.AddMonths(1)
    $latest = $null
    $monthEvents = New-Object System.Collections.ArrayList
    $monthFiles = @($files | Where-Object { $_.LastWriteTime -ge $monthStart })
    foreach ($file in $monthFiles) {
        $summary = Read-DeepSeekUsageFile -File $file
        foreach ($event in $summary.Events) {
            [void]$monthEvents.Add($event)
        }
        if ($summary.Latest -and (-not $latest -or $summary.Latest.Timestamp -gt $latest.Timestamp)) {
            $latest = $summary.Latest
        }
    }

    $todayUsage = Measure-DeepSeekUsageEvents -Events @($monthEvents) -StartDate $todayDate
    $monthlyUsage = Measure-DeepSeekUsageEvents `
        -Events @($monthEvents) `
        -StartDate $monthStart `
        -EndDate $nextMonth
    $result.TodayTokens = $todayUsage.TotalTokens
    $result.TodayInputTokens = $todayUsage.InputTokens
    $result.TodayOutputTokens = $todayUsage.OutputTokens
    $result.TodayCachedTokens = $todayUsage.CachedTokens
    $result.MonthlyTokens = $monthlyUsage.TotalTokens
    $result.MonthlyEstimatedCostCny = [Math]::Round($monthlyUsage.EstimatedCostCny, 4)

    if (-not $latest) {
        foreach ($file in ($files | Where-Object {
            $_.LastWriteTime -lt $monthStart
        } | Select-Object -First 16)) {
            $candidate = Read-DeepSeekLatestUsageFile -File $file
            if ($candidate) {
                $latest = $candidate
                break
            }
        }
    }

    if ($latest) {
        $result.LastTurnTokens = $latest.TotalTokens
        $result.LastInputTokens = $latest.InputTokens + $latest.CachedTokens + $latest.CacheWriteTokens
        $result.LastOutputTokens = $latest.OutputTokens
        $result.LastCachedTokens = $latest.CachedTokens
        $cacheBase = $latest.InputTokens + $latest.CachedTokens + $latest.CacheWriteTokens
        $result.CacheHitPercent = if ($cacheBase -gt 0) {
            [Math]::Round(($latest.CachedTokens / $cacheBase) * 100, 1)
        } else { 0 }
        $result.Model = $latest.Model
        $result.SampledAt = $latest.Timestamp.LocalDateTime
    }
    return [pscustomobject]$result
}

function Format-CurrencyAmount {
    param(
        [double]$Amount,
        [string]$Currency
    )

    $symbol = if ($Currency -eq 'USD') { '$' } else { '¥' }
    return '{0}{1:N2}' -f $symbol, $Amount
}

function ConvertTo-DeepSeekSnapshot {
    param(
        $BalancePayload,
        $LocalUsage,
        [double]$Budget,
        [string]$KeyHint,
        [string]$CredentialSource,
        [datetime]$SampledAt = (Get-Date)
    )

    $balanceInfos = @(Get-ObjectPropertyValue -Object $BalancePayload -Name 'balance_infos' -Default @())
    $selectedBalance = $balanceInfos | Where-Object {
        [string](Get-ObjectPropertyValue -Object $_ -Name 'currency' -Default '') -eq 'CNY'
    } | Select-Object -First 1
    if (-not $selectedBalance) { $selectedBalance = $balanceInfos | Select-Object -First 1 }
    if (-not $selectedBalance) { throw 'DeepSeek 返回中没有可用的余额字段。' }

    $currency = [string](Get-ObjectPropertyValue -Object $selectedBalance -Name 'currency' -Default 'CNY')
    $totalBalance = [double]::Parse(
        [string](Get-ObjectPropertyValue -Object $selectedBalance -Name 'total_balance' -Default '0'),
        [Globalization.CultureInfo]::InvariantCulture
    )
    $grantedBalance = [double]::Parse(
        [string](Get-ObjectPropertyValue -Object $selectedBalance -Name 'granted_balance' -Default '0'),
        [Globalization.CultureInfo]::InvariantCulture
    )
    $toppedUpBalance = [double]::Parse(
        [string](Get-ObjectPropertyValue -Object $selectedBalance -Name 'topped_up_balance' -Default '0'),
        [Globalization.CultureInfo]::InvariantCulture
    )
    $isAvailable = [bool](Get-ObjectPropertyValue -Object $BalancePayload -Name 'is_available' -Default $false)
    $budgetPercent = if ($Budget -gt 0) {
        [Math]::Round([Math]::Max(0, [Math]::Min(100, ($totalBalance / $Budget) * 100)))
    } else { $null }

    return [pscustomobject]@{
        ProviderId = 'DeepSeek'
        Available = $isAvailable
        RemainingPercent = if ($null -ne $budgetPercent) { $budgetPercent } else { 0 }
        HasProgress = $null -ne $budgetPercent
        WindowLabel = if ($null -ne $budgetPercent) { '预算余量' } else { '余额' }
        ResetDate = Format-CurrencyAmount -Amount $totalBalance -Currency $currency
        ResetCountdown = if ($isAvailable) { '当前可用于 API 调用' } else { '余额当前不可用' }
        ResetCount = if ($Budget -gt 0) {
            Format-CurrencyAmount -Amount $Budget -Currency $currency
        } else { '未设置' }
        Plan = '按量计费'
        AccountName = 'DeepSeek API'
        AccountEmail = if ($KeyHint) {
            '密钥 ••••{0} · {1}' -f $KeyHint, $CredentialSource
        } else { '尚未配置 API Key' }
        TodayTokens = $LocalUsage.TodayTokens
        MonthlyTokens = $LocalUsage.MonthlyTokens
        MonthlyEstimatedCostCny = $LocalUsage.MonthlyEstimatedCostCny
        LastTurnTokens = $LocalUsage.LastTurnTokens
        InputTokens = $LocalUsage.LastInputTokens
        OutputTokens = $LocalUsage.LastOutputTokens
        CachedTokens = $LocalUsage.LastCachedTokens
        CacheHitPercent = $LocalUsage.CacheHitPercent
        ContextPercent = 0
        SampledAt = $SampledAt
        UsageSampledAt = $LocalUsage.SampledAt
        ResetAt = $null
        Status = if (-not $isAvailable) { '余额不可用' }
            elseif ($Budget -gt 0 -and $budgetPercent -le 20) { '建议留意' }
            else { '状态舒适' }
        Source = 'DeepSeek 官方余额 · Claude Code 本地日志'
        Currency = $currency
        TotalBalance = $totalBalance
        GrantedBalance = $grantedBalance
        ToppedUpBalance = $toppedUpBalance
        Budget = $Budget
        BudgetPercent = $budgetPercent
        Model = $LocalUsage.Model
    }
}

function Get-DeepSeekUnavailableSnapshot {
    param([string]$Reason = '请通过右键菜单配置 DeepSeek')

    return [pscustomobject]@{
        ProviderId = 'DeepSeek'
        Available = $false
        RemainingPercent = 0
        HasProgress = $false
        WindowLabel = '余额'
        ResetDate = '暂无'
        ResetCountdown = $Reason
        ResetCount = '未设置'
        Plan = '按量计费'
        AccountName = 'DeepSeek API'
        AccountEmail = '尚未配置 API Key'
        TodayTokens = 0
        MonthlyTokens = 0
        MonthlyEstimatedCostCny = 0
        LastTurnTokens = 0
        InputTokens = 0
        OutputTokens = 0
        CachedTokens = 0
        CacheHitPercent = 0
        ContextPercent = 0
        SampledAt = Get-Date
        UsageSampledAt = Get-Date
        ResetAt = $null
        Status = '等待配置'
        Source = $Reason
        Currency = 'CNY'
        TotalBalance = 0
        GrantedBalance = 0
        ToppedUpBalance = 0
        Budget = 0
        BudgetPercent = $null
        Model = '暂无本地记录'
    }
}

function Get-DeepSeekDemoSnapshot {
    $configuration = [pscustomobject]@{ Budget = 120.0 }
    $usage = [pscustomobject]@{
        TodayTokens = 382640
        MonthlyTokens = 2846520
        MonthlyEstimatedCostCny = 2.36
        LastTurnTokens = 174201
        LastInputTokens = 173880
        LastOutputTokens = 321
        LastCachedTokens = 173440
        CacheHitPercent = 99.7
        Model = 'deepseek-v4-pro'
        SampledAt = Get-Date
    }
    $payload = [pscustomobject]@{
        is_available = $true
        balance_infos = @(
            [pscustomobject]@{
                currency = 'CNY'
                total_balance = '86.40'
                granted_balance = '10.00'
                topped_up_balance = '76.40'
            }
        )
    }
    return ConvertTo-DeepSeekSnapshot `
        -BalancePayload $payload `
        -LocalUsage $usage `
        -Budget $configuration.Budget `
        -KeyHint '7K9D' `
        -CredentialSource '演示配置'
}
