function ConvertFrom-JwtPayload {
    param([string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }
    try {
        $parts = $Token.Split('.')
        if ($parts.Count -lt 2) { return $null }
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        while (($payload.Length % 4) -ne 0) { $payload += '=' }
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        return $json | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-SafeAccountInfo {
    $result = [ordered]@{
        DisplayName = '本地 Codex'
        Email = '未找到账号信息'
    }

    if (-not $script:CodexOfficialAccessEnabled) {
        $result.Email = '官方接口访问未启用'
        return [pscustomobject]$result
    }

    $authPath = Join-Path $env:USERPROFILE '.codex\auth.json'
    if (-not (Test-Path -LiteralPath $authPath)) { return [pscustomobject]$result }

    try {
        $auth = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json
        $claims = ConvertFrom-JwtPayload -Token $auth.tokens.id_token
        if ($claims) {
            $emailProperty = $claims.PSObject.Properties['email']
            $nameProperty = $claims.PSObject.Properties['name']
            if ($emailProperty -and $emailProperty.Value) {
                $result.Email = [string]$emailProperty.Value
            }
            if ($nameProperty -and $nameProperty.Value) {
                $result.DisplayName = [string]$nameProperty.Value
            }
        }
    }
    catch {
        $result.Email = '账号信息暂不可用'
    }

    return [pscustomobject]$result
}

function ConvertTo-CodexOfficialUsage {
    param(
        $Payload,
        [DateTimeOffset]$SampledAt = [DateTimeOffset]::Now
    )

    if (-not $Payload) { return $null }
    $rateLimit = Get-ObjectPropertyValue -Object $Payload -Name 'rate_limit'
    $primary = Get-ObjectPropertyValue -Object $rateLimit -Name 'primary_window'
    if (-not $primary) { return $null }

    $usedValue = Get-ObjectPropertyValue -Object $primary -Name 'used_percent'
    $windowSecondsValue = Get-ObjectPropertyValue `
        -Object $primary `
        -Name 'limit_window_seconds'
    $resetValue = Get-ObjectPropertyValue -Object $primary -Name 'reset_at'
    if (
        $null -eq $usedValue -or
        $null -eq $windowSecondsValue -or [double]$windowSecondsValue -le 0 -or
        $null -eq $resetValue -or [long]$resetValue -le 0
    ) {
        return $null
    }

    return [pscustomobject]@{
        UsedPercent = [Math]::Max(
            0.0,
            [Math]::Min(100.0, [double]$usedValue)
        )
        WindowMinutes = [int][Math]::Round([double]$windowSecondsValue / 60)
        ResetsAt = [long]$resetValue
        PlanType = [string](Get-ObjectPropertyValue `
            -Object $Payload `
            -Name 'plan_type' `
            -Default '')
        SampledAt = $SampledAt
        IsCached = $false
    }
}

function Get-CodexHttpClient {
    if (-not $script:CodexHttpClient) {
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(12)
        $script:CodexHttpClient = $client
    }
    return $script:CodexHttpClient
}

function New-CodexOfficialUsageRequest {
    if (-not $script:CodexOfficialAccessEnabled) {
        throw 'Codex 官方接口访问未启用。'
    }

    $authPath = Join-Path $env:USERPROFILE '.codex\auth.json'
    if (-not (Test-Path -LiteralPath $authPath)) {
        throw '未找到 Codex 登录信息。'
    }

    $auth = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json
    $tokens = Get-ObjectPropertyValue -Object $auth -Name 'tokens'
    $accessToken = [string](Get-ObjectPropertyValue `
        -Object $tokens `
        -Name 'access_token' `
        -Default '')
    $accountId = [string](Get-ObjectPropertyValue `
        -Object $tokens `
        -Name 'account_id' `
        -Default '')
    if (
        [string]::IsNullOrWhiteSpace($accessToken) -or
        [string]::IsNullOrWhiteSpace($accountId)
    ) {
        throw 'Codex 登录信息不完整。'
    }

    $request = New-Object System.Net.Http.HttpRequestMessage(
        [System.Net.Http.HttpMethod]::Get,
        'https://chatgpt.com/backend-api/wham/usage'
    )
    try {
        $request.Headers.Authorization =
            New-Object System.Net.Http.Headers.AuthenticationHeaderValue(
                'Bearer',
                $accessToken
            )
        [void]$request.Headers.TryAddWithoutValidation('ChatGPT-Account-Id', $accountId)
        [void]$request.Headers.TryAddWithoutValidation('originator', 'codex_cli_rs')
        [void]$request.Headers.TryAddWithoutValidation(
            'User-Agent',
            'remaining-margin-float/1.8.8'
        )
        [void]$request.Headers.TryAddWithoutValidation('Accept', 'application/json')
        return $request
    }
    catch {
        $request.Dispose()
        throw
    }
}

function Get-CodexOfficialUsage {
    $now = [DateTimeOffset]::Now
    $currentOfficialUsage = Get-CodexCurrentUsageOverride -Now $now
    if (
        $currentOfficialUsage -and
        ($now - $currentOfficialUsage.SampledAt).TotalSeconds -lt 15
    ) {
        return $currentOfficialUsage
    }

    try {
        $request = New-CodexOfficialUsageRequest
        try {
            $response = (Get-CodexHttpClient).SendAsync($request).GetAwaiter().GetResult()
            try {
                if (-not $response.IsSuccessStatusCode) {
                    throw ('Codex usage request failed with HTTP {0}.' -f
                        [int]$response.StatusCode)
                }
                $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                $payload = $content | ConvertFrom-Json
            }
            finally {
                $response.Dispose()
            }
        }
        finally {
            $request.Dispose()
        }

        $usage = ConvertTo-CodexOfficialUsage -Payload $payload -SampledAt $now
        if (-not $usage) { throw 'Codex usage response did not contain a primary window.' }
        $script:CodexOfficialUsageCache = $usage
        return $usage
    }
    catch {
        $currentOfficialUsage = Get-CodexCurrentUsageOverride -Now $now
        if (
            $currentOfficialUsage -and
            ($now - $currentOfficialUsage.SampledAt).TotalMinutes -lt 10
        ) {
            return $currentOfficialUsage
        }
        return $null
    }
}

function Get-CodexRateLimitWindow {
    param($Payload)

    if (-not $Payload) { return $null }
    $rateLimitsProperty = $Payload.PSObject.Properties['rate_limits']
    if (-not $rateLimitsProperty -or -not $rateLimitsProperty.Value) { return $null }

    foreach ($name in @('primary', 'secondary')) {
        $windowProperty = $rateLimitsProperty.Value.PSObject.Properties[$name]
        if (-not $windowProperty -or -not $windowProperty.Value) { continue }

        $usedProperty = $windowProperty.Value.PSObject.Properties['used_percent']
        $minutesProperty = $windowProperty.Value.PSObject.Properties['window_minutes']
        $resetProperty = $windowProperty.Value.PSObject.Properties['resets_at']
        if (
            -not $usedProperty -or $null -eq $usedProperty.Value -or
            -not $minutesProperty -or [double]$minutesProperty.Value -le 0 -or
            -not $resetProperty -or [long]$resetProperty.Value -le 0
        ) {
            continue
        }
        return $windowProperty.Value
    }
    return $null
}

function Get-CodexEventObservedAt {
    param(
        $Event,
        [datetime]$Fallback
    )

    $observedAt = [DateTimeOffset]$Fallback
    $timestampProperty = $Event.PSObject.Properties['timestamp']
    if ($timestampProperty -and $timestampProperty.Value) {
        $parsed = [DateTimeOffset]::MinValue
        if (
            [DateTimeOffset]::TryParse(
                [string]$timestampProperty.Value,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$parsed
            )
        ) {
            $observedAt = $parsed
        }
    }
    return $observedAt
}

function Add-CodexRateLimitSample {
    param(
        [hashtable]$Candidates,
        $Payload,
        [DateTimeOffset]$ObservedAt
    )

    $window = Get-CodexRateLimitWindow -Payload $Payload
    if (-not $window) { return }

    # A real quota cycle keeps the same reset timestamp across successive
    # events. Local workers can also emit synthetic 0% samples whose reset
    # timestamp slides on every event; each of those forms a one-off cycle.
    $key = '{0}:{1}' -f [long]$window.window_minutes, [long]$window.resets_at
    if ($Candidates.ContainsKey($key)) {
        $candidate = $Candidates[$key]
        $candidate.Count++
        if ($ObservedAt -lt $candidate.FirstObservedAt) {
            $candidate.FirstObservedAt = $ObservedAt
        }
        if ($ObservedAt -gt $candidate.ObservedAt) {
            $candidate.Payload = $Payload
            $candidate.ObservedAt = $ObservedAt
            $candidate.UsedPercent = [double]$window.used_percent
        }
        return
    }

    $Candidates[$key] = [pscustomobject]@{
        Count = 1
        FirstObservedAt = $ObservedAt
        Payload = $Payload
        ObservedAt = $ObservedAt
        UsedPercent = [double]$window.used_percent
    }
}

function Select-CodexStableRateLimitSample {
    param(
        [hashtable]$Candidates,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    # A reported non-zero cycle remains authoritative until its own reset
    # timestamp. Synthetic local 0% samples can keep sliding their reset time
    # forward and must not replace a cycle that Codex says is still active.
    $nowEpoch = $Now.ToUnixTimeSeconds()
    $activePositive = $Candidates.Values | Where-Object {
        $window = Get-CodexRateLimitWindow -Payload $_.Payload
        $_.UsedPercent -gt 0 -and
        $window -and
        [long]$window.resets_at -gt $nowEpoch
    } | Sort-Object ObservedAt -Descending | Select-Object -First 1
    if ($activePositive) { return $activePositive }

    $latestObservedAt = $Candidates.Values |
        Sort-Object ObservedAt -Descending |
        Select-Object -First 1 -ExpandProperty ObservedAt
    return $Candidates.Values | Where-Object {
        $_.UsedPercent -gt 0 -or (
            $_.Count -ge 2 -and
            ($_.ObservedAt - $_.FirstObservedAt).TotalSeconds -ge 120
        ) -or (
            $_.ObservedAt -eq $latestObservedAt -and
            ($Now - $_.ObservedAt).TotalSeconds -ge 120
        )
    } | Sort-Object ObservedAt -Descending | Select-Object -First 1
}

function Select-CodexRateLimitSnapshot {
    param(
        [object[]]$Snapshots,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    $validSnapshots = @($Snapshots | Where-Object {
        $_ -and $_.RateLimitPayload -and (Get-CodexRateLimitWindow -Payload $_.RateLimitPayload)
    })
    $nowEpoch = $Now.ToUnixTimeSeconds()
    $activePositive = $validSnapshots | Where-Object {
        $window = Get-CodexRateLimitWindow -Payload $_.RateLimitPayload
        [double]$window.used_percent -gt 0 -and
        [long]$window.resets_at -gt $nowEpoch
    } | Sort-Object RateLimitObservedAt -Descending | Select-Object -First 1
    if ($activePositive) { return $activePositive }

    return $validSnapshots |
        Sort-Object RateLimitObservedAt -Descending |
        Select-Object -First 1
}

function Resolve-CodexQuotaUsage {
    param(
        $OfficialUsage,
        [object[]]$SessionSnapshots = @(),
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    if ($OfficialUsage) {
        $isCached = [bool](Get-ObjectPropertyValue `
            -Object $OfficialUsage `
            -Name 'IsCached' `
            -Default $false)
        return [pscustomobject]@{
            Channel = if ($isCached) { 'OfficialCache' } else { 'Official' }
            UsedPercent = [Math]::Max(
                0,
                [Math]::Min(100.0, [double]$OfficialUsage.UsedPercent)
            )
            WindowMinutes = [int]$OfficialUsage.WindowMinutes
            ResetsAt = [long]$OfficialUsage.ResetsAt
            PlanType = [string]$OfficialUsage.PlanType
            SampledAt = [DateTimeOffset]$OfficialUsage.SampledAt
            SessionSnapshot = $null
        }
    }

    $localSnapshot = Select-CodexRateLimitSnapshot `
        -Snapshots $SessionSnapshots `
        -Now $Now
    if (-not $localSnapshot) { return $null }

    $rateLimitPayload = $localSnapshot.RateLimitPayload
    $window = Get-CodexRateLimitWindow -Payload $rateLimitPayload
    if (-not $window) { return $null }

    $limits = Get-ObjectPropertyValue -Object $rateLimitPayload -Name 'rate_limits'
    return [pscustomobject]@{
        Channel = 'Local'
        UsedPercent = [Math]::Max(
            0,
            [Math]::Min(
                100,
                [double](Get-ObjectPropertyValue `
                    -Object $window `
                    -Name 'used_percent' `
                    -Default 0)
            )
        )
        WindowMinutes = [int](Get-ObjectPropertyValue `
            -Object $window `
            -Name 'window_minutes' `
            -Default 0)
        ResetsAt = [long](Get-ObjectPropertyValue `
            -Object $window `
            -Name 'resets_at' `
            -Default 0)
        PlanType = [string](Get-ObjectPropertyValue `
            -Object $limits `
            -Name 'plan_type' `
            -Default '')
        SampledAt = [DateTimeOffset]$localSnapshot.RateLimitObservedAt
        SessionSnapshot = $localSnapshot
    }
}

function Test-CodexRootSessionMetadata {
    param($Payload)

    if (-not $Payload) { return $true }
    $sourceProperty = $Payload.PSObject.Properties['source']
    if (-not $sourceProperty -or -not $sourceProperty.Value) { return $true }
    return -not $sourceProperty.Value.PSObject.Properties['subagent']
}

function Test-CodexRootSessionFile {
    param([System.IO.FileInfo]$File)

    if ($script:SessionMetadataCache.ContainsKey($File.FullName)) {
        return $script:SessionMetadataCache[$File.FullName]
    }

    $isRootSession = $true
    try {
        $stream = [System.IO.File]::Open(
            $File.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        try {
            $reader = New-Object System.IO.StreamReader($stream)
            try {
                $firstLine = $reader.ReadLine()
                if (-not [string]::IsNullOrWhiteSpace($firstLine)) {
                    $metadata = $firstLine | ConvertFrom-Json
                    if ($metadata.type -eq 'session_meta') {
                        $isRootSession = Test-CodexRootSessionMetadata `
                            -Payload $metadata.payload
                    }
                }
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        # Unknown/legacy files remain readable rather than being dropped.
        $isRootSession = $true
    }

    $script:SessionMetadataCache[$File.FullName] = $isRootSession
    return $isRootSession
}

function Read-SessionSnapshot {
    param([System.IO.FileInfo]$File)

    $cacheKey = '{0}:{1}' -f $File.LastWriteTimeUtc.Ticks, $File.Length
    $previousSnapshot = $null
    if ($script:SessionCache.ContainsKey($File.FullName)) {
        $cached = $script:SessionCache[$File.FullName]
        $previousSnapshot = $cached.Value
        if ($cached.Key -eq $cacheKey) { return $cached.Value }
    }

    $lastPayload = $null
    $lastObservedAt = [DateTimeOffset]$File.LastWriteTime
    $lastRateLimitPayload = $null
    $lastRateLimitObservedAt = [DateTimeOffset]::MinValue
    $rateLimitCandidates = @{}
    if (
        $previousSnapshot -and
        $previousSnapshot.RateLimitPayload
    ) {
        Add-CodexRateLimitSample `
            -Candidates $rateLimitCandidates `
            -Payload $previousSnapshot.RateLimitPayload `
            -ObservedAt $previousSnapshot.RateLimitObservedAt
    }
    try {
        $stream = [System.IO.File]::Open(
            $File.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        try {
            # Token counters are append-only and normally appear near the end.
            # Reading a bounded tail keeps the one-minute refresh responsive
            # even when an active session log grows to tens of megabytes.
            $tailLimit = 64KB
            $startOffset = [Math]::Max(0L, $stream.Length - $tailLimit)
            [void]$stream.Seek($startOffset, [System.IO.SeekOrigin]::Begin)
            $byteCount = [int]($stream.Length - $startOffset)
            $buffer = New-Object byte[] $byteCount
            $totalRead = 0
            while ($totalRead -lt $byteCount) {
                $read = $stream.Read($buffer, $totalRead, $byteCount - $totalRead)
                if ($read -le 0) { break }
                $totalRead += $read
            }

            $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $totalRead)
            if ($startOffset -gt 0) {
                $firstLineBreak = $text.IndexOf("`n", [StringComparison]::Ordinal)
                if ($firstLineBreak -ge 0) {
                    $text = $text.Substring($firstLineBreak + 1)
                }
                else {
                    $text = ''
                }
            }

            foreach ($line in ($text -split "`r?`n")) {
                if ($line.IndexOf('"type":"token_count"', [StringComparison]::Ordinal) -lt 0) {
                    continue
                }
                try {
                    $event = $line | ConvertFrom-Json
                    if ($event.type -eq 'event_msg' -and $event.payload.type -eq 'token_count') {
                        $lastPayload = $event.payload
                        $lastObservedAt = Get-CodexEventObservedAt -Event $event -Fallback $File.LastWriteTime
                        Add-CodexRateLimitSample `
                            -Candidates $rateLimitCandidates `
                            -Payload $event.payload `
                            -ObservedAt $lastObservedAt
                    }
                }
                catch {
                    continue
                }
            }

            $stableRateLimit = Select-CodexStableRateLimitSample `
                -Candidates $rateLimitCandidates
            if (
                -not $stableRateLimit -and
                $previousSnapshot -and
                $previousSnapshot.RateLimitPayload
            ) {
                $lastRateLimitPayload = $previousSnapshot.RateLimitPayload
                $lastRateLimitObservedAt = $previousSnapshot.RateLimitObservedAt
            }
            # Never fall back to scanning the entire log when the bounded tail
            # has no token_count event. Older session files can be tens of
            # megabytes, and a full scan would block the WPF refresh timer.
            if ($stableRateLimit) {
                $lastRateLimitPayload = $stableRateLimit.Payload
                $lastRateLimitObservedAt = $stableRateLimit.ObservedAt
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        $lastPayload = $null
        $lastRateLimitPayload = $null
    }

    $value = [pscustomobject]@{
        File = $File
        Payload = $lastPayload
        ObservedAt = $lastObservedAt
        RateLimitPayload = $lastRateLimitPayload
        RateLimitObservedAt = $lastRateLimitObservedAt
    }
    $script:SessionCache[$File.FullName] = [pscustomobject]@{ Key = $cacheKey; Value = $value }
    return $value
}

function Get-PlanLabel {
    param([string]$PlanType)

    if ([string]::IsNullOrWhiteSpace($PlanType)) { return 'Codex' }
    $labels = @{
        'free' = 'Free'
        'plus' = 'Plus'
        'pro' = 'Pro'
        'prolite' = 'Pro Lite'
        'team' = 'Team'
        'business' = 'Business'
        'enterprise' = 'Enterprise'
    }
    $key = $PlanType.ToLowerInvariant()
    if ($labels.ContainsKey($key)) { return $labels[$key] }
    return (Get-Culture).TextInfo.ToTitleCase($PlanType.Replace('_', ' '))
}

function Format-CompactNumber {
    param([double]$Value)

    if ($Value -ge 1000000) { return ('{0:0.0}M' -f ($Value / 1000000)) }
    if ($Value -ge 1000) { return ('{0:0.0}K' -f ($Value / 1000)) }
    return ('{0:N0}' -f $Value)
}

function Get-ResetText {
    param($UnixSeconds)

    if ($null -eq $UnixSeconds -or [long]$UnixSeconds -le 0) {
        return [pscustomobject]@{ Date = '暂无'; Countdown = '等待 Codex 提供' }
    }

    $reset = [DateTimeOffset]::FromUnixTimeSeconds([long]$UnixSeconds).LocalDateTime
    $remaining = $reset - (Get-Date)
    if ($remaining.TotalSeconds -le 0) {
        $countdown = '即将刷新'
    }
    elseif ($remaining.TotalDays -ge 1) {
        $countdown = '{0} 天 {1} 小时后' -f [Math]::Floor($remaining.TotalDays), $remaining.Hours
    }
    elseif ($remaining.TotalHours -ge 1) {
        $countdown = '{0} 小时 {1} 分后' -f [Math]::Floor($remaining.TotalHours), $remaining.Minutes
    }
    else {
        $countdown = '{0} 分钟后' -f [Math]::Max(1, [Math]::Ceiling($remaining.TotalMinutes))
    }

    return [pscustomobject]@{
        Date = $reset.ToString('M月d日 HH:mm')
        Countdown = $countdown
    }
}

function Get-CodexUsageSnapshot {
    param(
        $OfficialUsageOverride = $null,
        [switch]$SkipOfficialRequest
    )

    if ($Demo) {
        return [pscustomobject]@{
            ProviderId = 'Codex'
            Available = $true
            RemainingPercent = 82
            HasProgress = $true
            WindowLabel = '本周余量'
            ResetDate = '8月2日 18:32'
            ResetCountdown = '5 天 7 小时后'
            ResetCount = '未提供'
            Plan = 'Pro'
            AccountName = 'YJ'
            AccountEmail = 'you@example.com'
            TodayTokens = 128420
            TodayInputTokens = 127530
            TodayOutputTokens = 890
            TodayCachedTokens = 118240
            TodayCacheHitPercent = 92.7
            LastTurnTokens = 49238
            InputTokens = 48891
            OutputTokens = 347
            CachedTokens = 46848
            CacheHitPercent = 95.8
            ContextPercent = 19.1
            SampledAt = Get-Date
            ResetAt = [DateTimeOffset]::Now.AddDays(5)
            Status = '状态舒适'
            Source = '演示数据'
        }
    }

    $account = Get-SafeAccountInfo
    $officialUsage = if ($SkipOfficialRequest) {
        $OfficialUsageOverride
    } else {
        Get-CodexOfficialUsage
    }
    $sessionsRoot = Join-Path $env:USERPROFILE '.codex\sessions'
    $files = @()
    if (Test-Path -LiteralPath $sessionsRoot) {
        $files = @(Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
    }
    # Quota selection only needs the newest sessions. Checking root/subagent
    # metadata for the entire archive makes the first UI refresh scale with
    # years of historical files.
    $quotaCandidateFiles = @($files | Select-Object -First 32)
    $rootSessionFiles = @($quotaCandidateFiles | Where-Object {
        Test-CodexRootSessionFile -File $_
    })

    # File modification time is not the observation time: a parallel task can
    # keep appending unrelated events to an older session. Select token
    # snapshots by their token_count timestamps instead.
    $recentSnapshots = @($rootSessionFiles | Select-Object -First 12 | ForEach-Object {
        Read-SessionSnapshot -File $_
    })
    $quotaUsage = Resolve-CodexQuotaUsage `
        -OfficialUsage $officialUsage `
        -SessionSnapshots $recentSnapshots
    $latestSnapshot = $recentSnapshots | Where-Object { $_.Payload } |
        Sort-Object ObservedAt -Descending | Select-Object -First 1

    if (-not $quotaUsage) {
        return [pscustomobject]@{
            ProviderId = 'Codex'
            Available = $false
            RemainingPercent = 0
            HasProgress = $false
            WindowLabel = '余量未知'
            ResetDate = '暂无'
            ResetCountdown = '等待官方接口或本地会话数据'
            ResetCount = '未提供'
            Plan = '--'
            AccountName = $account.DisplayName
            AccountEmail = $account.Email
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
            SampledAt = Get-Date
            ResetAt = $null
            Status = '等待数据'
            Source = '官方接口与本地会话均无可用余量数据'
        }
    }

    if (-not $latestSnapshot -and $quotaUsage.SessionSnapshot) {
        $latestSnapshot = $quotaUsage.SessionSnapshot
    }
    $payload = if ($latestSnapshot) { $latestSnapshot.Payload } else { $null }
    $usedPercent = [double]$quotaUsage.UsedPercent
    $windowMinutes = [int]$quotaUsage.WindowMinutes
    $resetTimestamp = [long]$quotaUsage.ResetsAt
    $planType = [string]$quotaUsage.PlanType
    $quotaSampledAt = ([DateTimeOffset]$quotaUsage.SampledAt).LocalDateTime
    $source = switch ($quotaUsage.Channel) {
        'Official' { '官方用量接口 · 本地令牌汇总' }
        'OfficialCache' { '官方用量缓存 · 本地令牌汇总' }
        default { '本地会话余量快照' }
    }

    $remainingPercent = [Math]::Round(100 - $usedPercent)
    $windowLabel = if ($windowMinutes -ge 10080) { '本周余量' }
        elseif ($windowMinutes -ge 1440) { '周期余量' }
        elseif ($windowMinutes -gt 0) { '{0} 小时余量' -f [Math]::Round($windowMinutes / 60) }
        else { 'Codex 余量' }

    $resetText = Get-ResetText -UnixSeconds $resetTimestamp

    $info = Get-ObjectPropertyValue -Object $payload -Name 'info'
    $lastUsage = Get-ObjectPropertyValue -Object $info -Name 'last_token_usage'
    $inputTokens = [double](Get-ObjectPropertyValue -Object $lastUsage -Name 'input_tokens' -Default 0)
    $cachedTokens = [double](Get-ObjectPropertyValue -Object $lastUsage -Name 'cached_input_tokens' -Default 0)
    $outputTokens = [double](Get-ObjectPropertyValue -Object $lastUsage -Name 'output_tokens' -Default 0)
    $lastTurnTokens = [double](Get-ObjectPropertyValue -Object $lastUsage -Name 'total_tokens' -Default 0)
    $contextWindow = [double](Get-ObjectPropertyValue -Object $info -Name 'model_context_window' -Default 0)
    $cacheHit = if ($inputTokens -gt 0) { [Math]::Round(($cachedTokens / $inputTokens) * 100, 1) } else { 0 }
    $contextPercent = if ($contextWindow -gt 0) {
        [Math]::Round(
            [Math]::Min(100.0, ($lastTurnTokens / $contextWindow) * 100),
            1
        )
    } else { 0 }

    $today = (Get-Date).Date
    $todayTokens = 0.0
    $todayInputTokens = 0.0
    $todayOutputTokens = 0.0
    $todayCachedTokens = 0.0
    foreach ($file in ($files | Where-Object { $_.LastWriteTime.Date -eq $today })) {
        $daySnapshot = Read-SessionSnapshot -File $file
        $dayInfo = Get-ObjectPropertyValue -Object $daySnapshot.Payload -Name 'info'
        $dayUsage = Get-ObjectPropertyValue -Object $dayInfo -Name 'total_token_usage'
        if ($dayUsage) {
            $todayTokens += [double](Get-ObjectPropertyValue -Object $dayUsage -Name 'total_tokens' -Default 0)
            $todayInputTokens += [double](Get-ObjectPropertyValue -Object $dayUsage -Name 'input_tokens' -Default 0)
            $todayOutputTokens += [double](Get-ObjectPropertyValue -Object $dayUsage -Name 'output_tokens' -Default 0)
            $todayCachedTokens += [double](Get-ObjectPropertyValue -Object $dayUsage -Name 'cached_input_tokens' -Default 0)
        }
    }
    $todayCacheHit = if ($todayInputTokens -gt 0) {
        [Math]::Round(($todayCachedTokens / $todayInputTokens) * 100, 1)
    } else { 0 }

    $status = if ($remainingPercent -ge 60) { '状态舒适' }
        elseif ($remainingPercent -ge 30) { '余量平稳' }
        elseif ($remainingPercent -gt 0) { '建议留意' }
        else { '等待重置' }

    return [pscustomobject]@{
        ProviderId = 'Codex'
        Available = $true
        RemainingPercent = $remainingPercent
        HasProgress = $true
        WindowLabel = $windowLabel
        ResetDate = $resetText.Date
        ResetCountdown = $resetText.Countdown
        ResetCount = '未提供'
        Plan = Get-PlanLabel -PlanType $planType
        AccountName = $account.DisplayName
        AccountEmail = $account.Email
        TodayTokens = $todayTokens
        TodayInputTokens = $todayInputTokens
        TodayOutputTokens = $todayOutputTokens
        TodayCachedTokens = $todayCachedTokens
        TodayCacheHitPercent = $todayCacheHit
        LastTurnTokens = $lastTurnTokens
        InputTokens = $inputTokens
        OutputTokens = $outputTokens
        CachedTokens = $cachedTokens
        CacheHitPercent = $cacheHit
        ContextPercent = $contextPercent
        SampledAt = $quotaSampledAt
        ResetAt = [DateTimeOffset]::FromUnixTimeSeconds($resetTimestamp)
        Status = $status
        Source = $source
    }
}
