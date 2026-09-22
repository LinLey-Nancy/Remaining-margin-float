function Get-KimiCodeDataRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:KIMI_CODE_HOME)) {
        return $env:KIMI_CODE_HOME
    }
    return Join-Path $env:USERPROFILE '.kimi-code'
}

function Read-KimiConfigProviders {
    param([string]$DataRoot = (Get-KimiCodeDataRoot))

    $configPath = Join-Path $DataRoot 'config.toml'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return @() }

    $providers = @()
    $current = $null
    foreach ($line in (Get-Content -LiteralPath $configPath)) {
        if ($line -match '^\s*\[providers\.(?<name>[^.\]]+)\]\s*$') {
            if ($current) { $providers += [pscustomobject]$current }
            $current = [ordered]@{
                Name = $Matches['name']
                BaseUrl = ''
                ApiKey = ''
            }
            continue
        }
        if ($line -match '^\s*\[') {
            if ($current) {
                $providers += [pscustomobject]$current
                $current = $null
            }
            continue
        }
        if (-not $current) { continue }
        if ($line -match '^\s*base_url\s*=\s*"(?<value>[^"]+)"') {
            $current.BaseUrl = $Matches['value']
        }
        elseif ($line -match '^\s*api_key\s*=\s*"(?<value>[^"]+)"') {
            $current.ApiKey = $Matches['value']
        }
    }
    if ($current) { $providers += [pscustomobject]$current }
    return @($providers)
}

function Get-KimiDefaultModel {
    param([string]$DataRoot = (Get-KimiCodeDataRoot))

    $configPath = Join-Path $DataRoot 'config.toml'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return '' }
    foreach ($line in (Get-Content -LiteralPath $configPath)) {
        if ($line -match '^\s*\[') { break }
        if ($line -match '^\s*default_model\s*=\s*"(?<value>[^"]+)"') {
            return $Matches['value']
        }
    }
    return ''
}

function Resolve-KimiUsageUrl {
    param([string]$BaseUrl)

    $base = if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        'https://api.kimi.com/coding/v1'
    } else {
        $BaseUrl.Trim().TrimEnd('/')
    }
    if ($base -notmatch '/v1$') { $base = $base + '/v1' }
    return $base + '/usages'
}

function Get-KimiCredential {
    $result = [ordered]@{
        Token = ''
        Hint = ''
        Source = '未配置'
        BaseUrl = ''
        UsageUrl = ''
        AuthMethod = ''
        AutoSource = ''
        AutoHint = ''
        ManualHint = ''
    }

    $dataRoot = Get-KimiCodeDataRoot
    $credentialsRoot = Join-Path $dataRoot 'credentials'
    if (Test-Path -LiteralPath $credentialsRoot) {
        $credentialFile = Get-ChildItem -LiteralPath $credentialsRoot `
            -Filter '*.json' -File |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1
        if ($credentialFile) {
            try {
                $payload = Get-Content -LiteralPath $credentialFile.FullName -Raw |
                    ConvertFrom-Json
                $accessToken = [string](Get-ObjectPropertyValue `
                    -Object $payload `
                    -Name 'access_token' `
                    -Default '')
                if (-not [string]::IsNullOrWhiteSpace($accessToken)) {
                    $result.Token = $accessToken
                    $result.Source = 'Kimi Code CLI（OAuth 登录）'
                    $result.AuthMethod = 'OAuth'
                    $result.AutoSource = 'OAuth 登录'
                    $result.Hint = ''
                }
            }
            catch {
                $result.Token = ''
            }
        }
    }

    $configProvider = $null
    $providers = @(Read-KimiConfigProviders -DataRoot $dataRoot)
    $configProvider = $providers | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.ApiKey) -and
        $_.BaseUrl -match 'coding'
    } | Select-Object -First 1
    if (-not $configProvider) {
        $configProvider = $providers | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.ApiKey)
        } | Select-Object -First 1
    }
    if ($configProvider) {
        $result.BaseUrl = $configProvider.BaseUrl
        $autoKey = $configProvider.ApiKey.Trim()
        $result.AutoSource = 'config.toml API Key'
        $result.AutoHint = if ($autoKey.Length -gt 4) {
            $autoKey.Substring($autoKey.Length - 4)
        } else { $autoKey }
    }
    if (-not $result.Token -and $configProvider) {
        $result.Token = $configProvider.ApiKey.Trim()
        $result.Source = 'Kimi Code CLI（config.toml）'
        $result.AuthMethod = 'ApiKey'
        $result.Hint = $result.AutoHint
    }

    # 自动读取不可用时，回退到用户手动配置并加密保存的 API Key。
    $manualConfiguration = Get-KimiConfiguration
    $manualKey = Unprotect-LocalSecret -Value $manualConfiguration.EncryptedApiKey
    if ($manualKey) {
        $result.ManualHint = $manualConfiguration.KeyHint
    }
    if (-not $result.Token -and $manualKey) {
        $result.Token = $manualKey
        $result.Source = '手动配置'
        $result.AuthMethod = 'ApiKey'
        $result.Hint = $manualConfiguration.KeyHint
    }
    $result.UsageUrl = Resolve-KimiUsageUrl -BaseUrl $result.BaseUrl
    return [pscustomobject]$result
}

function Get-KimiHttpClient {
    if (-not $script:KimiHttpClient) {
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(12)
        $script:KimiHttpClient = $client
    }
    return $script:KimiHttpClient
}

function New-KimiUsageRequest {
    param($AuthProfile = (Get-KimiCredential))

    if ([string]::IsNullOrWhiteSpace($AuthProfile.Token)) {
        throw '未找到 Kimi Code 登录信息。'
    }

    $request = New-Object System.Net.Http.HttpRequestMessage(
        [System.Net.Http.HttpMethod]::Get,
        $AuthProfile.UsageUrl
    )
    try {
        $request.Headers.Authorization =
            New-Object System.Net.Http.Headers.AuthenticationHeaderValue(
                'Bearer',
                $AuthProfile.Token
            )
        [void]$request.Headers.TryAddWithoutValidation(
            'User-Agent',
            ('remaining-margin-float/{0}' -f $script:AppVersion)
        )
        [void]$request.Headers.TryAddWithoutValidation('Accept', 'application/json')
        return $request
    }
    catch {
        $request.Dispose()
        throw
    }
}

function ConvertTo-KimiWindowMinutes {
    param(
        [double]$Duration,
        [string]$TimeUnit
    )

    if ($Duration -le 0) { return 0 }
    $minutes = switch -Regex ($TimeUnit) {
        'SECOND' { $Duration / 60; break }
        'HOUR' { $Duration * 60; break }
        'DAY' { $Duration * 1440; break }
        default { $Duration }
    }
    if ($minutes -gt [int]::MaxValue) { return 0 }
    return [int][Math]::Round($minutes)
}

function ConvertTo-KimiQuotaWindow {
    param(
        $Detail,
        [int]$WindowMinutes
    )

    if (-not $Detail -or $WindowMinutes -le 0) { return $null }
    $usedText = [string](Get-ObjectPropertyValue -Object $Detail -Name 'used' -Default '')
    $resetText = [string](Get-ObjectPropertyValue -Object $Detail -Name 'resetTime' -Default '')
    if ([string]::IsNullOrWhiteSpace($usedText) -or
        [string]::IsNullOrWhiteSpace($resetText)) {
        return $null
    }

    $usedPercent = 0.0
    if (-not [double]::TryParse(
        $usedText,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$usedPercent
    )) {
        return $null
    }
    $resetAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
        $resetText,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$resetAt
    )) {
        return $null
    }
    if (
        [double]::IsNaN($usedPercent) -or
        [double]::IsInfinity($usedPercent) -or
        $resetAt -le [DateTimeOffset]::MinValue
    ) {
        return $null
    }

    return [pscustomobject]@{
        UsedPercent = [Math]::Max(0.0, [Math]::Min(100.0, $usedPercent))
        WindowMinutes = $WindowMinutes
        ResetsAt = $resetAt.ToUnixTimeSeconds()
    }
}

function ConvertTo-KimiUsagesQuotaWindow {
    param(
        $Payload,
        [string]$Name,
        [int]$WindowMinutes
    )

    $usages = Get-ObjectPropertyValue -Object $Payload -Name 'usages'
    $entry = Get-ObjectPropertyValue -Object $usages -Name $Name
    if (-not $entry -or $WindowMinutes -le 0) { return $null }

    $ratioValue = Get-ObjectPropertyValue -Object $entry -Name 'used_ratio'
    $resetText = [string](Get-ObjectPropertyValue `
        -Object $entry `
        -Name 'reset_time' `
        -Default '')
    if ($null -eq $ratioValue -or [string]::IsNullOrWhiteSpace($resetText)) {
        return $null
    }

    $usedRatio = 0.0
    if ($ratioValue -is [string]) {
        if (-not [double]::TryParse(
            $ratioValue,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$usedRatio
        )) {
            return $null
        }
    }
    else {
        try { $usedRatio = [double]$ratioValue } catch { return $null }
    }
    $resetAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
        $resetText,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$resetAt
    )) {
        return $null
    }
    if (
        [double]::IsNaN($usedRatio) -or
        [double]::IsInfinity($usedRatio) -or
        $usedRatio -lt 0 -or
        $resetAt -le [DateTimeOffset]::MinValue
    ) {
        return $null
    }

    return [pscustomobject]@{
        UsedPercent = [Math]::Max(0.0, [Math]::Min(100.0, $usedRatio * 100))
        WindowMinutes = $WindowMinutes
        ResetsAt = $resetAt.ToUnixTimeSeconds()
    }
}

function ConvertTo-KimiOfficialUsage {
    param(
        $Payload,
        [DateTimeOffset]$SampledAt = [DateTimeOffset]::Now
    )

    if (-not $Payload) { return $null }

    $fiveHourWindow = $null
    $limits = @(Get-ObjectPropertyValue -Object $Payload -Name 'limits' -Default @())
    foreach ($entry in $limits) {
        $window = Get-ObjectPropertyValue -Object $entry -Name 'window'
        $detail = Get-ObjectPropertyValue -Object $entry -Name 'detail'
        $windowMinutes = ConvertTo-KimiWindowMinutes `
            -Duration ([double](Get-ObjectPropertyValue -Object $window -Name 'duration' -Default 0)) `
            -TimeUnit [string](Get-ObjectPropertyValue -Object $window -Name 'timeUnit' -Default '')
        if ([Math]::Abs($windowMinutes - 300) -le 1) {
            $fiveHourWindow = ConvertTo-KimiQuotaWindow `
                -Detail $detail `
                -WindowMinutes 300
        }
    }
    if (-not $fiveHourWindow) {
        # limits[] only appears while a five-hour window has active usage;
        # the summary usages.limit_5h entry stays present across idle gaps
        # and resets, so fall back to it before giving up on the window.
        $fiveHourWindow = ConvertTo-KimiUsagesQuotaWindow `
            -Payload $Payload `
            -Name 'limit_5h' `
            -WindowMinutes 300
    }

    $weeklyWindow = $null
    $usageDetail = Get-ObjectPropertyValue -Object $Payload -Name 'usage'
    if ($usageDetail) {
        $weeklyWindow = ConvertTo-KimiQuotaWindow `
            -Detail $usageDetail `
            -WindowMinutes 10080
    }
    if (-not $weeklyWindow) {
        $weeklyWindow = ConvertTo-KimiUsagesQuotaWindow `
            -Payload $Payload `
            -Name 'limit_7d' `
            -WindowMinutes 10080
    }
    if (-not $fiveHourWindow -and -not $weeklyWindow) { return $null }

    $user = Get-ObjectPropertyValue -Object $Payload -Name 'user'
    $membership = Get-ObjectPropertyValue -Object $user -Name 'membership'
    return [pscustomobject]@{
        FiveHourWindow = $fiveHourWindow
        WeeklyWindow = $weeklyWindow
        PlanType = [string](Get-ObjectPropertyValue `
            -Object $membership `
            -Name 'level' `
            -Default '')
        UserId = [string](Get-ObjectPropertyValue `
            -Object $user `
            -Name 'userId' `
            -Default '')
        SampledAt = $SampledAt
        IsCached = $false
    }
}

function Get-KimiCurrentUsageOverride {
    param(
        $OfficialUsage = $script:KimiOfficialUsageCache,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    if (-not $OfficialUsage) { return $null }
    $nowUnixSeconds = $Now.ToUnixTimeSeconds()
    $fiveHourWindow = $OfficialUsage.FiveHourWindow
    $weeklyWindow = $OfficialUsage.WeeklyWindow
    if ($fiveHourWindow -and [long]$fiveHourWindow.ResetsAt -le $nowUnixSeconds) {
        $fiveHourWindow = $null
    }
    if ($weeklyWindow -and [long]$weeklyWindow.ResetsAt -le $nowUnixSeconds) {
        $weeklyWindow = $null
    }
    if (-not $fiveHourWindow -and -not $weeklyWindow) { return $null }

    return [pscustomobject]@{
        FiveHourWindow = $fiveHourWindow
        WeeklyWindow = $weeklyWindow
        PlanType = [string]$OfficialUsage.PlanType
        UserId = [string]$OfficialUsage.UserId
        SampledAt = [DateTimeOffset]$OfficialUsage.SampledAt
        IsCached = $true
    }
}

function Get-KimiOfficialUsage {
    $now = [DateTimeOffset]::Now
    $currentOfficialUsage = Get-KimiCurrentUsageOverride -Now $now
    if (
        $currentOfficialUsage -and
        ($now - $currentOfficialUsage.SampledAt).TotalSeconds -lt 15
    ) {
        return $currentOfficialUsage
    }

    try {
        $request = New-KimiUsageRequest
        try {
            $response = (Get-KimiHttpClient).SendAsync($request).GetAwaiter().GetResult()
            try {
                if (-not $response.IsSuccessStatusCode) {
                    throw ('Kimi usage request failed with HTTP {0}.' -f
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

        $usage = ConvertTo-KimiOfficialUsage -Payload $payload -SampledAt $now
        if (-not $usage) { throw 'Kimi usage response did not contain a quota window.' }
        $script:KimiOfficialUsageCache = $usage
        return $usage
    }
    catch {
        $currentOfficialUsage = Get-KimiCurrentUsageOverride -Now $now
        if (
            $currentOfficialUsage -and
            ($now - $currentOfficialUsage.SampledAt).TotalMinutes -lt 10
        ) {
            return $currentOfficialUsage
        }
        return $null
    }
}

function ConvertFrom-KimiWireUsageLine {
    param([string]$Line)

    if (
        [string]::IsNullOrEmpty($Line) -or
        $Line.IndexOf('"usage.record"', [StringComparison]::Ordinal) -lt 0
    ) {
        return $null
    }

    $usageMatch = [regex]::Match(
        $Line,
        '"usage"\s*:\s*\{[^}]*\}',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    $timeMatch = [regex]::Match(
        $Line,
        '"time"\s*:\s*(?<value>\d+)',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    if (-not $usageMatch.Success -or -not $timeMatch.Success) { return $null }

    $timeMilliseconds = 0L
    if (-not [long]::TryParse($timeMatch.Groups['value'].Value, [ref]$timeMilliseconds)) {
        return $null
    }
    try {
        $usage = $usageMatch.Value.Substring($usageMatch.Value.IndexOf('{')) |
            ConvertFrom-Json
    }
    catch {
        return $null
    }
    $model = ''
    $modelMatch = [regex]::Match(
        $Line,
        '"model"\s*:\s*"(?<value>[^"]+)"',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    if ($modelMatch.Success) { $model = $modelMatch.Groups['value'].Value }

    return [pscustomobject]@{
        Timestamp = [DateTimeOffset]::FromUnixTimeMilliseconds($timeMilliseconds)
        Model = $model
        InputTokens = [double](Get-ObjectPropertyValue -Object $usage -Name 'inputOther' -Default 0)
        OutputTokens = [double](Get-ObjectPropertyValue -Object $usage -Name 'output' -Default 0)
        CachedTokens = [double](Get-ObjectPropertyValue -Object $usage -Name 'inputCacheRead' -Default 0)
        CacheWriteTokens = [double](Get-ObjectPropertyValue -Object $usage -Name 'inputCacheCreation' -Default 0)
    }
}

function Read-KimiSessionUsageEvents {
    param([System.IO.FileInfo]$File)

    $cacheKey = '{0}:{1}' -f $File.LastWriteTimeUtc.Ticks, $File.Length
    if ($script:KimiUsageCache.ContainsKey($File.FullName)) {
        $cached = $script:KimiUsageCache[$File.FullName]
        if ($cached.Key -eq $cacheKey) { return $cached.Value }
    }

    $events = @()
    try {
        $stream = [System.IO.File]::Open(
            $File.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        try {
            # Usage records are append-only and normally appear near the end.
            $tailLimit = 256KB
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
                $usageEvent = ConvertFrom-KimiWireUsageLine -Line $line
                if ($usageEvent) { $events += $usageEvent }
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        $events = @()
    }

    $value = [pscustomobject]@{ Events = $events }
    $script:KimiUsageCache[$File.FullName] = [pscustomobject]@{
        Key = $cacheKey
        Value = $value
    }
    return $value
}

function Get-KimiLocalUsage {
    $result = [ordered]@{
        TodayTokens = 0.0
        TodayInputTokens = 0.0
        TodayOutputTokens = 0.0
        TodayCachedTokens = 0.0
        LastTurnTokens = 0.0
        LastInputTokens = 0.0
        LastOutputTokens = 0.0
        LastCachedTokens = 0.0
        CacheHitPercent = 0.0
        Model = '暂无本地记录'
        SampledAt = Get-Date
    }

    $dataRoot = Get-KimiCodeDataRoot
    $sessionsRoot = Join-Path $dataRoot 'sessions'
    if (Test-Path -LiteralPath $sessionsRoot) {
        $files = @(
            [LocalJsonlFileScanner]::GetFilesNewestFirst($sessionsRoot) |
                Where-Object {
                    $_.FullName -replace '/', '\' -match '\\agents\\main\\wire\.jsonl$'
                }
        )
        $todayDate = (Get-Date).Date
        $latest = $null
        foreach ($file in $files) {
            # A file untouched today can still hold the latest turn when no
            # session ran today; only files written today feed the daily sum.
            $summary = Read-KimiSessionUsageEvents -File $file
            foreach ($usageEvent in $summary.Events) {
                if ($usageEvent.Timestamp.LocalDateTime.Date -ne $todayDate) { continue }
                $result.TodayTokens += (
                    $usageEvent.InputTokens +
                    $usageEvent.OutputTokens +
                    $usageEvent.CachedTokens +
                    $usageEvent.CacheWriteTokens
                )
                $result.TodayInputTokens += $usageEvent.InputTokens +
                    $usageEvent.CachedTokens + $usageEvent.CacheWriteTokens
                $result.TodayOutputTokens += $usageEvent.OutputTokens
                $result.TodayCachedTokens += $usageEvent.CachedTokens
            }
            if ($file.LastWriteTime.Date -ne $todayDate -and $latest) { continue }
            $fileLatest = $summary.Events |
                Sort-Object Timestamp -Descending |
                Select-Object -First 1
            if ($fileLatest -and (-not $latest -or $fileLatest.Timestamp -gt $latest.Timestamp)) {
                $latest = $fileLatest
            }
        }

        if ($latest) {
            $result.LastTurnTokens = $latest.InputTokens + $latest.OutputTokens +
                $latest.CachedTokens + $latest.CacheWriteTokens
            $result.LastInputTokens = $latest.InputTokens +
                $latest.CachedTokens + $latest.CacheWriteTokens
            $result.LastOutputTokens = $latest.OutputTokens
            $result.LastCachedTokens = $latest.CachedTokens
            $cacheBase = $latest.InputTokens + $latest.CachedTokens + $latest.CacheWriteTokens
            $result.CacheHitPercent = if ($cacheBase -gt 0) {
                [Math]::Round(($latest.CachedTokens / $cacheBase) * 100, 1)
            } else { 0 }
            $result.Model = if ($latest.Model) { $latest.Model } else { '未知模型' }
            $result.SampledAt = $latest.Timestamp.LocalDateTime
        }
    }
    return [pscustomobject]$result
}

function Get-KimiPlanLabel {
    param([string]$PlanType)

    if ([string]::IsNullOrWhiteSpace($PlanType)) { return 'Kimi Code' }
    $labels = @{
        'free' = 'Free'
        'basic' = 'Basic'
        'advanced' = 'Advanced'
        'professional' = 'Professional'
        'enterprise' = 'Enterprise'
    }
    $key = $PlanType.ToLowerInvariant() -replace '^level_', ''
    if ($labels.ContainsKey($key)) { return $labels[$key] }
    return (Get-Culture).TextInfo.ToTitleCase($key.Replace('_', ' '))
}

function Get-KimiUsageSnapshot {
    param(
        $OfficialUsageOverride = $null,
        [switch]$SkipOfficialRequest
    )

    if ($Demo) {
        return Get-KimiDemoSnapshot
    }

    $credential = Get-KimiCredential
    $officialUsage = if ($SkipOfficialRequest) {
        $OfficialUsageOverride
    } else {
        Get-KimiOfficialUsage
    }
    $localUsage = Get-KimiLocalUsage

    $accountName = '本地 Kimi Code'
    $accountEmail = switch ($credential.AuthMethod) {
        'OAuth' { 'OAuth 登录 · Kimi Code CLI' }
        'ApiKey' {
            if ($credential.Hint) {
                '密钥 ••••{0} · {1}' -f $credential.Hint, $credential.Source
            } else { [string]$credential.Source }
        }
        default { '未找到登录信息' }
    }

    if (-not $officialUsage) {
        return [pscustomobject]@{
            ProviderId = 'Kimi'
            Available = $false
            RemainingPercent = 0
            HasProgress = $false
            WindowLabel = '5 小时余量未知'
            ResetDate = '暂无'
            ResetCountdown = '等待 5 小时额度数据'
            FiveHourAvailable = $false
            FiveHourUsedPercent = 0
            FiveHourRemainingPercent = 0
            FiveHourResetDate = '暂无'
            FiveHourResetCountdown = '等待 5 小时额度数据'
            FiveHourResetAt = $null
            WeeklyAvailable = $false
            WeeklyUsedPercent = 0
            WeeklyRemainingPercent = 0
            WeeklyResetDate = '暂无'
            WeeklyResetCountdown = '等待每周额度数据'
            WeeklyResetAt = $null
            ResetCount = '未提供'
            PlanType = ''
            Plan = '--'
            PrimaryQuotaPeriod = 'FiveHour'
            AccountName = $accountName
            AccountEmail = $accountEmail
            TodayTokens = $localUsage.TodayTokens
            TodayInputTokens = $localUsage.TodayInputTokens
            TodayOutputTokens = $localUsage.TodayOutputTokens
            TodayCachedTokens = $localUsage.TodayCachedTokens
            TodayCacheHitPercent = 0
            LastTurnTokens = $localUsage.LastTurnTokens
            InputTokens = $localUsage.LastInputTokens
            OutputTokens = $localUsage.LastOutputTokens
            CachedTokens = $localUsage.LastCachedTokens
            CacheHitPercent = $localUsage.CacheHitPercent
            ContextPercent = 0
            SampledAt = Get-Date
            ResetAt = $null
            Status = '等待数据'
            Source = 'Kimi 官方接口暂无可用余量数据'
            Model = $localUsage.Model
        }
    }

    $fiveHourWindow = $officialUsage.FiveHourWindow
    $weeklyWindow = $officialUsage.WeeklyWindow
    $hasFiveHour = $null -ne $fiveHourWindow
    $hasWeekly = $null -ne $weeklyWindow
    $planType = [string]$officialUsage.PlanType
    $primaryWindow = if ($hasFiveHour) { $fiveHourWindow } else { $weeklyWindow }
    $primaryQuotaPeriod = if ($hasFiveHour) { 'FiveHour' } else { 'Weekly' }
    $hasPrimaryQuota = $null -ne $primaryWindow
    $usedPercent = if ($hasPrimaryQuota) { [double]$primaryWindow.UsedPercent } else { 0.0 }
    $resetTimestamp = if ($hasPrimaryQuota) { [long]$primaryWindow.ResetsAt } else { 0L }
    $isCached = [bool](Get-ObjectPropertyValue `
        -Object $officialUsage `
        -Name 'IsCached' `
        -Default $false)
    $source = if ($isCached) {
        'Kimi 官方用量缓存 · 本地会话令牌汇总'
    } else {
        'Kimi 官方用量接口 · 本地会话令牌汇总'
    }

    $remainingPercent = if ($hasPrimaryQuota) {
        [Math]::Round(100 - $usedPercent)
    } else { 0 }
    $periodLabel = if ($primaryQuotaPeriod -eq 'Weekly') { '每周' } else { '5 小时' }
    $windowLabel = if ($hasPrimaryQuota) {
        "${periodLabel}余量"
    } else {
        "${periodLabel}余量未知"
    }
    $resetText = if ($hasPrimaryQuota) {
        Get-ResetText -UnixSeconds $resetTimestamp
    } else {
        [pscustomobject]@{ Date = '暂无'; Countdown = "等待$periodLabel 额度数据" }
    }
    $fiveHourResetText = if ($hasFiveHour) {
        Get-ResetText -UnixSeconds ([long]$fiveHourWindow.ResetsAt)
    } else {
        [pscustomobject]@{ Date = '暂无'; Countdown = '等待 5 小时额度数据' }
    }
    $weeklyResetText = if ($hasWeekly) {
        Get-ResetText -UnixSeconds ([long]$weeklyWindow.ResetsAt)
    } else {
        [pscustomobject]@{ Date = '暂无'; Countdown = '等待每周额度数据' }
    }
    $fiveHourUsedPercent = if ($hasFiveHour) {
        [double]$fiveHourWindow.UsedPercent
    } else { 0.0 }
    $weeklyUsedPercent = if ($hasWeekly) {
        [double]$weeklyWindow.UsedPercent
    } else { 0.0 }

    $status = if (-not $hasPrimaryQuota) { "${periodLabel}余量未知" }
        elseif ($remainingPercent -ge 60) { '状态舒适' }
        elseif ($remainingPercent -ge 30) { '余量平稳' }
        elseif ($remainingPercent -gt 0) { '建议留意' }
        else { '等待重置' }

    return [pscustomobject]@{
        ProviderId = 'Kimi'
        Available = $true
        RemainingPercent = $remainingPercent
        HasProgress = $hasPrimaryQuota
        WindowLabel = $windowLabel
        ResetDate = $resetText.Date
        ResetCountdown = $resetText.Countdown
        FiveHourAvailable = $hasFiveHour
        FiveHourUsedPercent = [Math]::Round($fiveHourUsedPercent)
        FiveHourRemainingPercent = if ($hasFiveHour) {
            [Math]::Round(100 - $fiveHourUsedPercent)
        } else { 0 }
        FiveHourResetDate = $fiveHourResetText.Date
        FiveHourResetCountdown = $fiveHourResetText.Countdown
        FiveHourResetAt = if ($hasFiveHour) {
            [DateTimeOffset]::FromUnixTimeSeconds([long]$fiveHourWindow.ResetsAt)
        } else { $null }
        WeeklyAvailable = $hasWeekly
        WeeklyUsedPercent = [Math]::Round($weeklyUsedPercent)
        WeeklyRemainingPercent = if ($hasWeekly) {
            [Math]::Round(100 - $weeklyUsedPercent)
        } else { 0 }
        WeeklyResetDate = $weeklyResetText.Date
        WeeklyResetCountdown = $weeklyResetText.Countdown
        WeeklyResetAt = if ($hasWeekly) {
            [DateTimeOffset]::FromUnixTimeSeconds([long]$weeklyWindow.ResetsAt)
        } else { $null }
        ResetCount = '未提供'
        PlanType = $planType
        Plan = Get-KimiPlanLabel -PlanType $planType
        PrimaryQuotaPeriod = $primaryQuotaPeriod
        AccountName = $accountName
        AccountEmail = $accountEmail
        TodayTokens = $localUsage.TodayTokens
        TodayInputTokens = $localUsage.TodayInputTokens
        TodayOutputTokens = $localUsage.TodayOutputTokens
        TodayCachedTokens = $localUsage.TodayCachedTokens
        TodayCacheHitPercent = if ($localUsage.TodayInputTokens -gt 0) {
            [Math]::Round(
                ($localUsage.TodayCachedTokens / $localUsage.TodayInputTokens) * 100,
                1
            )
        } else { 0 }
        LastTurnTokens = $localUsage.LastTurnTokens
        InputTokens = $localUsage.LastInputTokens
        OutputTokens = $localUsage.LastOutputTokens
        CachedTokens = $localUsage.LastCachedTokens
        CacheHitPercent = $localUsage.CacheHitPercent
        ContextPercent = 0
        SampledAt = ([DateTimeOffset]$officialUsage.SampledAt).LocalDateTime
        ResetAt = if ($hasPrimaryQuota) {
            [DateTimeOffset]::FromUnixTimeSeconds($resetTimestamp)
        } else { $null }
        Status = $status
        Source = $source
        Model = $localUsage.Model
    }
}

function Get-KimiUnavailableSnapshot {
    param([string]$Reason = '请先在 Kimi Code CLI 中登录')

    return [pscustomobject]@{
        ProviderId = 'Kimi'
        Available = $false
        RemainingPercent = 0
        HasProgress = $false
        WindowLabel = '5 小时余量未知'
        ResetDate = '暂无'
        ResetCountdown = $Reason
        FiveHourAvailable = $false
        FiveHourUsedPercent = 0
        FiveHourRemainingPercent = 0
        FiveHourResetDate = '暂无'
        FiveHourResetCountdown = '等待 5 小时额度数据'
        FiveHourResetAt = $null
        WeeklyAvailable = $false
        WeeklyUsedPercent = 0
        WeeklyRemainingPercent = 0
        WeeklyResetDate = '暂无'
        WeeklyResetCountdown = '等待每周额度数据'
        WeeklyResetAt = $null
        ResetCount = '未提供'
        PlanType = ''
        Plan = '--'
        PrimaryQuotaPeriod = 'FiveHour'
        AccountName = '本地 Kimi Code'
        AccountEmail = '未找到登录信息'
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
        Status = '等待登录'
        Source = $Reason
        Model = '暂无本地记录'
    }
}

function Get-KimiDemoSnapshot {
    return [pscustomobject]@{
        ProviderId = 'Kimi'
        Available = $true
        RemainingPercent = 90
        HasProgress = $true
        WindowLabel = '5 小时余量'
        ResetDate = '9月8日 18:04'
        ResetCountdown = '2 小时 36 分钟后'
        FiveHourAvailable = $true
        FiveHourUsedPercent = 10
        FiveHourRemainingPercent = 90
        FiveHourResetDate = '9月8日 18:04'
        FiveHourResetCountdown = '2 小时 36 分钟后'
        FiveHourResetAt = [DateTimeOffset]::Now.AddHours(2)
        WeeklyAvailable = $true
        WeeklyUsedPercent = 2
        WeeklyRemainingPercent = 98
        WeeklyResetDate = '9月15日 21:04'
        WeeklyResetCountdown = '6 天 11 小时后'
        WeeklyResetAt = [DateTimeOffset]::Now.AddDays(6)
        ResetCount = '未提供'
        PlanType = 'LEVEL_ADVANCED'
        Plan = 'Advanced'
        PrimaryQuotaPeriod = 'FiveHour'
        AccountName = '本地 Kimi Code'
        AccountEmail = '密钥 ••••a1b2 · 演示配置'
        TodayTokens = 96420
        TodayInputTokens = 95180
        TodayOutputTokens = 1240
        TodayCachedTokens = 88260
        TodayCacheHitPercent = 92.7
        LastTurnTokens = 21381
        InputTokens = 21100
        OutputTokens = 102
        CachedTokens = 18176
        CacheHitPercent = 86.1
        ContextPercent = 0
        SampledAt = Get-Date
        ResetAt = [DateTimeOffset]::Now.AddHours(2)
        Status = '状态舒适'
        Source = '演示数据'
        Model = 'kimi-for-coding/k3'
    }
}
