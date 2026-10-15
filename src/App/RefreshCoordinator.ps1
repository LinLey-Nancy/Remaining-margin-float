function Reset-RefreshCountdown {
    param([DateTimeOffset]$Now = [DateTimeOffset]::Now)

    $script:AppContext.Refresh.RemainingSeconds = $script:RefreshIntervalSeconds
    $script:AppContext.Refresh.NextAt =
        $Now.AddSeconds($script:RefreshIntervalSeconds)
}

function Set-RefreshBusy {
    param([bool]$Busy)

    if ($Busy -and -not $script:AppContext.Refresh.IsBusy) {
        $script:AppContext.Refresh.StartedAt = [DateTimeOffset]::Now
        if (Get-Command Write-RuntimeLog -ErrorAction SilentlyContinue) {
            Write-RuntimeLog `
                -Event 'Refresh.Started' `
                -Message '开始刷新用量' `
                -Data @{ Provider = $script:ActiveProvider }
        }
    }
    elseif (-not $Busy -and $script:AppContext.Refresh.IsBusy) {
        $elapsedMilliseconds = if ($script:AppContext.Refresh.StartedAt) {
            [long]([DateTimeOffset]::Now -
                $script:AppContext.Refresh.StartedAt).TotalMilliseconds
        } else { 0L }
        if (Get-Command Write-RuntimeLog -ErrorAction SilentlyContinue) {
            Write-RuntimeLog `
                -Level $(if ($elapsedMilliseconds -ge 2000) {
                    'Warning'
                } else {
                    'Info'
                }) `
                -Event 'Refresh.Completed' `
                -Message '用量刷新结束' `
                -ElapsedMilliseconds $elapsedMilliseconds `
                -Data @{ Provider = $script:ActiveProvider }
        }
        $script:AppContext.Refresh.StartedAt = $null
    }
    elseif (-not $Busy) {
        $script:AppContext.Refresh.StartedAt = $null
    }
    $script:AppContext.Refresh.IsBusy = $Busy
    $RefreshButton.IsEnabled = -not $Busy
    $RefreshButton.Content = if ($Busy) { '读取中…' } else { '立即刷新' }
}

function Stop-ProviderRefreshTask {
    param(
        $State,
        $Client
    )

    if ($State.RequestTask -and -not $State.RequestTask.IsCompleted) {
        if ($Client) {
            $Client.CancelPendingRequests()
        }
    }
    elseif (
        $State.RequestTask -and
        -not $State.RequestTask.IsCanceled -and
        -not $State.RequestTask.IsFaulted
    ) {
        $abandonedResponse = $State.RequestTask.GetAwaiter().GetResult()
        if ($abandonedResponse) { $abandonedResponse.Dispose() }
    }
    if ($State.Request) {
        $State.Request.Dispose()
    }
    $State.Request = $null
    $State.RequestTask = $null
    $State.Attempt = 0
    $State.RetryAfter = $null
    # The tag dies with the request: leaving it behind would let a later
    # completion look like a fresh answer for the current configuration.
    if ($State.PSObject.Properties['AccountId']) { $State.AccountId = '' }
    Set-RefreshBusy -Busy $false
}

function Resolve-RefreshRetryDecision {
    param(
        $State,
        $Response
    )

    $serverDelaySeconds = 0.0
    if (
        $Response -and
        $Response.Headers.RetryAfter -and
        $Response.Headers.RetryAfter.Delta
    ) {
        $serverDelaySeconds =
            $Response.Headers.RetryAfter.Delta.Value.TotalSeconds
    }
    $retryDelaySeconds = Get-RefreshRetryDelaySeconds `
        -Attempt $State.Attempt `
        -ServerDelaySeconds $serverDelaySeconds
    $State.RetryAfter =
        [DateTimeOffset]::Now.AddSeconds($retryDelaySeconds)
    return $retryDelaySeconds
}

function Complete-RefreshTaskCleanup {
    param(
        $State,
        $Response,
        $Request,
        [bool]$RetryStarted
    )

    if ($Response) { $Response.Dispose() }
    if ($Request) { $Request.Dispose() }
    if (-not $RetryStarted) {
        $State.Attempt = 0
        $State.RetryAfter = $null
        Set-RefreshBusy -Busy $false
        Reset-RefreshCountdown
    }
}

function Cancel-CodexRefresh {
    Stop-ProviderRefreshTask `
        -State $script:AppContext.Refresh.Codex `
        -Client $script:CodexHttpClient
}

function Start-CodexOfficialRequest {
    $request = $null
    $codex = $script:AppContext.Refresh.Codex
    try {
        $request = New-CodexOfficialUsageRequest
        $codex.Attempt++
        $codex.RetryAfter = $null
        $codex.Request = $request
        $codex.RequestTask = (Get-CodexHttpClient).SendAsync($request)
        return $true
    }
    catch {
        if ($request) { $request.Dispose() }
        $codex.Request = $null
        $codex.RequestTask = $null
        Set-RuntimeDiagnosticStatus `
            -Area 'Codex' `
            -Status 'Degraded' `
            -Message $_.Exception.Message
        Set-RuntimeDiagnosticStatus `
            -Area 'Refresh' `
            -Status 'Degraded' `
            -Message $_.Exception.Message
        if ($script:ActiveProvider -eq 'Codex') {
            if ($script:LastSnapshot) {
                $fallback = New-UsageFallbackSnapshot `
                    -Snapshot $script:LastSnapshot `
                    -Reason ('官方接口请求未能启动 · ' + $_.Exception.Message)
                Update-UsageView -Snapshot $fallback -DisplayOnly
            }
            else {
                $SourceText.Text = '官方接口请求未能启动 · ' +
                    $_.Exception.Message
            }
        }
        return $false
    }
}

function Start-CodexRefresh {
    if ($Demo) {
        Update-UsageView -Snapshot (
            Get-CodexUsageSnapshot -SkipOfficialRequest
        )
        Set-RefreshBusy -Busy $false
        return
    }

    if (-not $script:CodexOfficialAccessEnabled) {
        Set-RefreshBusy -Busy $false
        return
    }

    $now = [DateTimeOffset]::Now
    $currentOfficialUsage = Get-CodexCurrentUsageOverride -Now $now
    if (
        $currentOfficialUsage -and
        ($now - $currentOfficialUsage.SampledAt).TotalSeconds -lt 15
    ) {
        $observationContext = if (
            $script:UsageSyncSession.AwaitingInitialOfficial
        ) { 'StartupOfficial' } else { 'Normal' }
        Update-UsageView -Snapshot (
            Get-CodexUsageSnapshot `
                -OfficialUsageOverride $currentOfficialUsage `
                -SkipOfficialRequest
        ) -ObservationContext $observationContext
        if ($observationContext -eq 'StartupOfficial') {
            $script:UsageSyncSession.AwaitingInitialOfficial = $false
        }
        Set-RefreshBusy -Busy $false
        return
    }

    $script:AppContext.Refresh.Codex.Attempt = 0
    if (-not (Start-CodexOfficialRequest)) {
        Set-RefreshBusy -Busy $false
    }
}

function Complete-CodexRefresh {
    $codex = $script:AppContext.Refresh.Codex
    if (-not $codex.RequestTask) {
        if (
            $codex.RetryAfter -and
            [DateTimeOffset]::Now -ge $codex.RetryAfter
        ) {
            $codex.RetryAfter = $null
            if (-not (Start-CodexOfficialRequest)) {
                $codex.Attempt = 0
                Set-RefreshBusy -Busy $false
                Reset-RefreshCountdown
            }
        }
        return
    }
    if (-not $codex.RequestTask.IsCompleted) {
        return
    }

    $task = $codex.RequestTask
    $request = $codex.Request
    $codex.RequestTask = $null
    $codex.Request = $null
    $response = $null
    $statusCode = 0
    $retryStarted = $false
    $failureMessage = ''
    try {
        if ($task.IsCanceled) { throw '官方用量请求超时。' }
        if ($task.IsFaulted) {
            throw ($task.Exception.GetBaseException().Message)
        }

        $response = $task.GetAwaiter().GetResult()
        $statusCode = [int]$response.StatusCode
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw ('官方用量接口返回状态码 {0}。' -f $statusCode)
        }

        $payload = $body | ConvertFrom-Json
        $usage = ConvertTo-CodexOfficialUsage `
            -Payload $payload `
            -SampledAt ([DateTimeOffset]::Now)
        if (-not $usage) { throw '官方用量响应缺少有效限额周期。' }

        $script:CodexOfficialUsageCache = $usage
        if ($script:ActiveProvider -eq 'Codex') {
            $observationContext = if (
                $script:UsageSyncSession.AwaitingInitialOfficial
            ) { 'StartupOfficial' } else { 'Normal' }
            Update-UsageView -Snapshot (
                Get-CodexUsageSnapshot `
                    -OfficialUsageOverride $usage `
                    -SkipOfficialRequest
            ) -ObservationContext $observationContext
            if ($observationContext -eq 'StartupOfficial') {
                $script:UsageSyncSession.AwaitingInitialOfficial = $false
            }
        }
        Set-RuntimeDiagnosticStatus `
            -Area 'Refresh' `
            -Status 'Healthy' `
            -Message 'Codex 官方用量刷新成功'
    }
    catch {
        $failureMessage = $_.Exception.Message
        Set-RuntimeDiagnosticStatus `
            -Area 'Codex' `
            -Status 'Degraded' `
            -Message $failureMessage
        Set-RuntimeDiagnosticStatus `
            -Area 'Refresh' `
            -Status 'Degraded' `
            -Message $failureMessage
        $transientFailure = (
            $task.IsCanceled -or
            $task.IsFaulted -or
            (Test-TransientRefreshFailure -StatusCode $statusCode)
        )
        if (
            $transientFailure -and
            $codex.Attempt -lt $codex.MaxAttempts -and
            $script:CodexOfficialAccessEnabled -and
            $script:ActiveProvider -eq 'Codex' -and
            -not $script:IsClosing
        ) {
            $retryDelaySeconds = Resolve-RefreshRetryDecision `
                -State $codex `
                -Response $response
            $retryStarted = $true
        }
        if (
            $retryStarted -and
            $script:LastSnapshot -and
            $script:ActiveProvider -eq 'Codex'
        ) {
            $fallback = New-UsageFallbackSnapshot `
                -Snapshot $script:LastSnapshot `
                -Reason (
                    '官方接口暂时不可用，{0:0} 秒后重试 · {1}' -f
                    $retryDelaySeconds,
                    $failureMessage
                )
            Update-UsageView -Snapshot $fallback -DisplayOnly
        }
        $cachedUsage = Get-CodexCurrentUsageOverride
        if (
            -not $retryStarted -and
            $cachedUsage -and
            ([DateTimeOffset]::Now - $cachedUsage.SampledAt).TotalMinutes -lt 10 -and
            $script:ActiveProvider -eq 'Codex'
        ) {
            $cachedSnapshot = (
                Get-CodexUsageSnapshot `
                    -OfficialUsageOverride $cachedUsage `
                    -SkipOfficialRequest
            )
            $fallback = New-UsageFallbackSnapshot `
                -Snapshot $cachedSnapshot `
                -Reason ('官方接口刷新失败 · ' + $failureMessage)
            Update-UsageView -Snapshot $fallback -DisplayOnly
        }
        elseif (-not $retryStarted -and $script:ActiveProvider -eq 'Codex') {
            if ($script:LastSnapshot) {
                $fallback = New-UsageFallbackSnapshot `
                    -Snapshot $script:LastSnapshot `
                    -Reason ('官方接口刷新失败 · ' + $failureMessage)
                Update-UsageView -Snapshot $fallback -DisplayOnly
            }
            else {
                $SourceText.Text = '官方接口刷新失败 · ' + $failureMessage
            }
        }
    }
    finally {
        Complete-RefreshTaskCleanup `
            -State $codex `
            -Response $response `
            -Request $request `
            -RetryStarted:$retryStarted
    }
}

function Get-DeepSeekHttpClient {
    if (-not $script:DeepSeekHttpClient) {
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(8)
        [void]$client.DefaultRequestHeaders.TryAddWithoutValidation(
            'User-Agent',
            "RemainingMarginFloat/$($script:AppVersion)"
        )
        $script:DeepSeekHttpClient = $client
    }
    return $script:DeepSeekHttpClient
}

function Cancel-DeepSeekRefresh {
    Stop-ProviderRefreshTask `
        -State $script:AppContext.Refresh.DeepSeek `
        -Client $script:DeepSeekHttpClient
}

function Start-DeepSeekRefresh {
    if ($Demo) {
        $snapshot = Get-DeepSeekDemoSnapshot
        $script:LastDeepSeekSnapshot = $snapshot
        Update-UsageView -Snapshot $snapshot
        Set-RefreshBusy -Busy $false
        return $false
    }

    $credential = Get-DeepSeekCredential
    if ([string]::IsNullOrWhiteSpace($credential.ApiKey)) {
        $script:AppContext.Refresh.DeepSeek.Attempt = 0
        $script:AppContext.Refresh.DeepSeek.RetryAfter = $null
        Update-UsageView -Snapshot (Get-DeepSeekUnavailableSnapshot -Credential $credential)
        Set-RefreshBusy -Busy $false
        return $false
    }

    $request = $null
    $requestAccountId = Get-EffectiveConfigProfileId -Provider 'DeepSeek'
    try {
        $request = New-Object System.Net.Http.HttpRequestMessage(
            [System.Net.Http.HttpMethod]::Get,
            $credential.BalanceUrl
        )
        $request.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue(
            'Bearer',
            $credential.ApiKey
        )
        $script:AppContext.Refresh.DeepSeek.Attempt++
        $script:AppContext.Refresh.DeepSeek.RetryAfter = $null
        $script:AppContext.Refresh.DeepSeek.Request = $request
        $script:AppContext.Refresh.DeepSeek.AccountId = $requestAccountId
        $script:AppContext.Refresh.DeepSeek.RequestTask =
            (Get-DeepSeekHttpClient).SendAsync($request)
        return $true
    }
    catch {
        if ($request) { $request.Dispose() }
        $script:AppContext.Refresh.DeepSeek.Request = $null
        $script:AppContext.Refresh.DeepSeek.RequestTask = $null
        $script:AppContext.Refresh.DeepSeek.Attempt = 0
        $script:AppContext.Refresh.DeepSeek.RetryAfter = $null
        Set-RuntimeDiagnosticStatus `
            -Area 'DeepSeek' `
            -Status 'Error' `
            -Message $_.Exception.Message
        Set-RuntimeDiagnosticStatus `
            -Area 'Refresh' `
            -Status 'Error' `
            -Message $_.Exception.Message
        Set-RefreshBusy -Busy $false
        if ($script:LastDeepSeekSnapshot) {
            $fallback = New-UsageFallbackSnapshot `
                -Snapshot $script:LastDeepSeekSnapshot `
                -Reason ('DeepSeek 请求未能启动 · ' + $_.Exception.Message)
            Update-UsageView -Snapshot $fallback -DisplayOnly
        }
        else {
            $SourceText.Text = 'DeepSeek 请求未能启动：' +
                $_.Exception.Message
        }
        return $false
    }
}

function Complete-DeepSeekRefresh {
    $deepSeek = $script:AppContext.Refresh.DeepSeek
    if (-not $deepSeek.RequestTask) {
        if (
            $deepSeek.RetryAfter -and
            [DateTimeOffset]::Now -ge $deepSeek.RetryAfter
        ) {
            $deepSeek.RetryAfter = $null
            if (-not (Start-DeepSeekRefresh)) {
                $deepSeek.Attempt = 0
                Set-RefreshBusy -Busy $false
                Reset-RefreshCountdown
            }
        }
        return
    }
    if (-not $deepSeek.RequestTask.IsCompleted) {
        return
    }

    $task = $deepSeek.RequestTask
    $request = $deepSeek.Request
    $requestAccountId = [string]$deepSeek.AccountId
    $deepSeek.RequestTask = $null
    $deepSeek.Request = $null
    # The profile may have changed while this request was in flight; its answer
    # belongs to the old account and must never reach the new account's view.
    if (
        $requestAccountId -ne (Get-EffectiveConfigProfileId -Provider 'DeepSeek')
    ) {
        $deepSeek.Attempt = 0
        $deepSeek.RetryAfter = $null
        Set-RefreshBusy -Busy $false
        Reset-RefreshCountdown
        Write-RuntimeLog `
            -Event 'Refresh.AccountStaleResultDropped' `
            -Message '已丢弃切换配置后才返回的 DeepSeek 结果' `
            -Data @{ RequestAccountId = $requestAccountId }
        return
    }
    $response = $null
    $statusCode = 0
    $retryStarted = $false
    $failureMessage = ''
    try {
        if ($task.IsCanceled) { throw 'DeepSeek 请求超时，请稍后重试。' }
        if ($task.IsFaulted) {
            throw ($task.Exception.GetBaseException().Message)
        }

        $response = $task.GetAwaiter().GetResult()
        $statusCode = [int]$response.StatusCode
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            if ($statusCode -eq 404) {
                # A relay that does not implement the balance endpoint. Keep the
                # local statistics rather than showing a hard failure.
                $localOnly = Get-DeepSeekLocalOnlySnapshot `
                    -Credential (Get-DeepSeekCredential)
                $script:LastDeepSeekSnapshot = $localOnly
                if ($script:ActiveProvider -eq 'DeepSeek') {
                    Update-UsageView -Snapshot $localOnly
                }
                Set-RuntimeDiagnosticStatus `
                    -Area 'DeepSeek' `
                    -Status 'Degraded' `
                    -Message $localOnly.Source
                Set-RuntimeDiagnosticStatus `
                    -Area 'Refresh' `
                    -Status 'Degraded' `
                    -Message $localOnly.Source
                return
            }
            $message = switch ($statusCode) {
                401 { 'API Key 无效或已失效，请重新配置。' }
                402 { 'DeepSeek 余额不足，请充值后重试。' }
                429 { '请求过于频繁，稍后会自动重试。' }
                500 { 'DeepSeek 服务暂时异常，稍后会自动重试。' }
                503 { 'DeepSeek 服务繁忙，稍后会自动重试。' }
                default { 'DeepSeek 返回 HTTP {0}。' -f $statusCode }
            }
            throw $message
        }

        $payload = $body | ConvertFrom-Json
        # The budget baseline moved into the per-source alert settings so all
        # three data sources are configured in one dialog; the legacy
        # deepseek.json value is only used to seed it once.
        $budgetSettings = Get-UsageAlertSettings -ProviderId 'DeepSeek'
        $budgetAmount = [double]$budgetSettings.BudgetAmount
        if ($budgetAmount -le 0) {
            $budgetAmount = [double](Get-DeepSeekConfiguration).Budget
        }
        $credential = Get-DeepSeekCredential
        $snapshot = ConvertTo-DeepSeekSnapshot `
            -BalancePayload $payload `
            -LocalUsage (Get-DeepSeekLocalUsage) `
            -Budget $budgetAmount `
            -KeyHint $credential.Hint `
            -SourceLabel $credential.Source `
            -AccountLabel $credential.ProfileLabel
        $script:LastDeepSeekSnapshot = $snapshot
        if ($script:ActiveProvider -eq 'DeepSeek') {
            Update-UsageView -Snapshot $snapshot
        }
        Set-RuntimeDiagnosticStatus `
            -Area 'Refresh' `
            -Status 'Healthy' `
            -Message 'DeepSeek 余额刷新成功'
    }
    catch {
        $failureMessage = $_.Exception.Message
        Set-RuntimeDiagnosticStatus `
            -Area 'DeepSeek' `
            -Status 'Degraded' `
            -Message $failureMessage
        Set-RuntimeDiagnosticStatus `
            -Area 'Refresh' `
            -Status 'Degraded' `
            -Message $failureMessage
        $transientFailure = (
            $task.IsCanceled -or
            $task.IsFaulted -or
            (Test-TransientRefreshFailure -StatusCode $statusCode)
        )
        if (
            $transientFailure -and
            $deepSeek.Attempt -lt $deepSeek.MaxAttempts -and
            $script:ActiveProvider -eq 'DeepSeek' -and
            -not $script:IsClosing
        ) {
            $retryDelaySeconds = Resolve-RefreshRetryDecision `
                -State $deepSeek `
                -Response $response
            $retryStarted = $true
        }
        if (
            $script:LastDeepSeekSnapshot -and
            $script:ActiveProvider -eq 'DeepSeek'
        ) {
            $reason = if ($retryStarted) {
                'DeepSeek 暂时不可用，{0:0} 秒后重试 · {1}' -f
                    $retryDelaySeconds,
                    $failureMessage
            }
            else {
                'DeepSeek 刷新失败 · ' + $failureMessage
            }
            $fallback = New-UsageFallbackSnapshot `
                -Snapshot $script:LastDeepSeekSnapshot `
                -Reason $reason
            Update-UsageView -Snapshot $fallback -DisplayOnly
        }
        elseif ($script:ActiveProvider -eq 'DeepSeek') {
            Update-UsageView -Snapshot (
                Get-DeepSeekUnavailableSnapshot -Reason $failureMessage
            )
        }
    }
    finally {
        Complete-RefreshTaskCleanup `
            -State $deepSeek `
            -Response $response `
            -Request $request `
            -RetryStarted:$retryStarted
    }
}

function Cancel-KimiRefresh {
    Stop-ProviderRefreshTask `
        -State $script:AppContext.Refresh.Kimi `
        -Client $script:KimiHttpClient
}

function Start-KimiOfficialRequest {
    $request = $null
    $kimi = $script:AppContext.Refresh.Kimi
    try {
        $request = New-KimiUsageRequest
        $kimi.Attempt++
        $kimi.RetryAfter = $null
        $kimi.Request = $request
        # Tag the request with the configuration that authorized it so a late
        # response for the previous profile can be dropped.
        $kimi.AccountId = Get-EffectiveConfigProfileId -Provider 'Kimi'
        $kimi.RequestTask = (Get-KimiHttpClient).SendAsync($request)
        return $true
    }
    catch {
        if ($request) { $request.Dispose() }
        $kimi.Request = $null
        $kimi.RequestTask = $null
        Set-RuntimeDiagnosticStatus `
            -Area 'Kimi' `
            -Status 'Degraded' `
            -Message $_.Exception.Message
        Set-RuntimeDiagnosticStatus `
            -Area 'Refresh' `
            -Status 'Degraded' `
            -Message $_.Exception.Message
        if ($script:ActiveProvider -eq 'Kimi') {
            if ($script:LastKimiSnapshot) {
                $fallback = New-UsageFallbackSnapshot `
                    -Snapshot $script:LastKimiSnapshot `
                    -Reason ('官方接口请求未能启动 · ' + $_.Exception.Message)
                Update-UsageView -Snapshot $fallback -DisplayOnly
            }
            else {
                Update-UsageView -Snapshot (
                    Get-KimiUnavailableSnapshot -Reason $_.Exception.Message
                )
            }
        }
        return $false
    }
}

function Start-KimiRefresh {
    if ($Demo) {
        $snapshot = Get-KimiDemoSnapshot
        $script:LastKimiSnapshot = $snapshot
        Update-UsageView -Snapshot $snapshot
        Set-RefreshBusy -Busy $false
        return
    }

    $credential = Get-KimiCredential
    if ([string]::IsNullOrWhiteSpace($credential.Token)) {
        $script:AppContext.Refresh.Kimi.Attempt = 0
        $script:AppContext.Refresh.Kimi.RetryAfter = $null
        Update-UsageView -Snapshot (Get-KimiUsageSnapshot -SkipOfficialRequest)
        Set-RefreshBusy -Busy $false
        return
    }

    $now = [DateTimeOffset]::Now
    $currentOfficialUsage = Get-KimiCurrentUsageOverride -Now $now
    if (
        $currentOfficialUsage -and
        ($now - $currentOfficialUsage.SampledAt).TotalSeconds -lt 15
    ) {
        $snapshot = Get-KimiUsageSnapshot `
            -OfficialUsageOverride $currentOfficialUsage `
            -SkipOfficialRequest
        $script:LastKimiSnapshot = $snapshot
        Update-UsageView -Snapshot $snapshot
        Set-RefreshBusy -Busy $false
        return
    }

    $script:AppContext.Refresh.Kimi.Attempt = 0
    if (-not (Start-KimiOfficialRequest)) {
        Set-RefreshBusy -Busy $false
    }
}

function Complete-KimiRefresh {
    $kimi = $script:AppContext.Refresh.Kimi
    if (-not $kimi.RequestTask) {
        if (
            $kimi.RetryAfter -and
            [DateTimeOffset]::Now -ge $kimi.RetryAfter
        ) {
            $kimi.RetryAfter = $null
            if (-not (Start-KimiOfficialRequest)) {
                $kimi.Attempt = 0
                Set-RefreshBusy -Busy $false
                Reset-RefreshCountdown
            }
        }
        return
    }
    if (-not $kimi.RequestTask.IsCompleted) {
        return
    }

    $task = $kimi.RequestTask
    $request = $kimi.Request
    $requestAccountId = [string]$kimi.AccountId
    $kimi.RequestTask = $null
    $kimi.Request = $null
    # Drop an answer that belongs to a configuration the user already left.
    if (
        $requestAccountId -ne (Get-EffectiveConfigProfileId -Provider 'Kimi')
    ) {
        $kimi.Attempt = 0
        $kimi.RetryAfter = $null
        Set-RefreshBusy -Busy $false
        Reset-RefreshCountdown
        Write-RuntimeLog `
            -Event 'Refresh.AccountStaleResultDropped' `
            -Message '已丢弃切换配置后才返回的 Kimi 结果' `
            -Data @{ RequestAccountId = $requestAccountId }
        return
    }
    $response = $null
    $statusCode = 0
    $retryStarted = $false
    $failureMessage = ''
    try {
        if ($task.IsCanceled) { throw '官方用量请求超时。' }
        if ($task.IsFaulted) {
            throw ($task.Exception.GetBaseException().Message)
        }

        $response = $task.GetAwaiter().GetResult()
        $statusCode = [int]$response.StatusCode
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            if ($statusCode -eq 401 -and (Test-KimiManualCredentialFallback)) {
                # 自动凭证失效但存在手动 Key：进程内标记拒绝并立即用手动 Key 重试。
                $script:KimiAutoCredentialRejected = $true
                $retryStarted = $true
                [void](Start-KimiOfficialRequest)
            }
            else {
                $message = switch ($statusCode) {
                    401 { '登录信息无效或已过期，请在 Kimi Code 中重新登录。' }
                    403 { '当前账号无权访问 Kimi Code 用量接口。' }
                    429 { '请求过于频繁，稍后会自动重试。' }
                    default { 'Kimi 返回 HTTP {0}。' -f $statusCode }
                }
                throw $message
            }
        }

        $payload = $body | ConvertFrom-Json
        $usage = ConvertTo-KimiOfficialUsage `
            -Payload $payload `
            -SampledAt ([DateTimeOffset]::Now)
        if (-not $usage) { throw '官方用量响应缺少有效限额周期。' }

        $script:KimiOfficialUsageCache = $usage
        if ($script:ActiveProvider -eq 'Kimi') {
            $snapshot = Get-KimiUsageSnapshot `
                -OfficialUsageOverride $usage `
                -SkipOfficialRequest
            $script:LastKimiSnapshot = $snapshot
            Update-UsageView -Snapshot $snapshot
        }
        Set-RuntimeDiagnosticStatus `
            -Area 'Kimi' `
            -Status 'Healthy' `
            -Message 'Kimi 官方用量刷新成功'
        Set-RuntimeDiagnosticStatus `
            -Area 'Refresh' `
            -Status 'Healthy' `
            -Message 'Kimi 官方用量刷新成功'
    }
    catch {
        $failureMessage = $_.Exception.Message
        Set-RuntimeDiagnosticStatus `
            -Area 'Kimi' `
            -Status 'Degraded' `
            -Message $failureMessage
        Set-RuntimeDiagnosticStatus `
            -Area 'Refresh' `
            -Status 'Degraded' `
            -Message $failureMessage
        $transientFailure = (
            $task.IsCanceled -or
            $task.IsFaulted -or
            (Test-TransientRefreshFailure -StatusCode $statusCode)
        )
        if (
            $transientFailure -and
            $kimi.Attempt -lt $kimi.MaxAttempts -and
            $script:ActiveProvider -eq 'Kimi' -and
            -not $script:IsClosing
        ) {
            $retryDelaySeconds = Resolve-RefreshRetryDecision `
                -State $kimi `
                -Response $response
            $retryStarted = $true
        }
        if (
            $retryStarted -and
            $script:LastKimiSnapshot -and
            $script:ActiveProvider -eq 'Kimi'
        ) {
            $fallback = New-UsageFallbackSnapshot `
                -Snapshot $script:LastKimiSnapshot `
                -Reason (
                    '官方接口暂时不可用，{0:0} 秒后重试 · {1}' -f
                    $retryDelaySeconds,
                    $failureMessage
                )
            Update-UsageView -Snapshot $fallback -DisplayOnly
        }
        $cachedUsage = Get-KimiCurrentUsageOverride
        if (
            -not $retryStarted -and
            $cachedUsage -and
            ([DateTimeOffset]::Now - $cachedUsage.SampledAt).TotalMinutes -lt 10 -and
            $script:ActiveProvider -eq 'Kimi'
        ) {
            $cachedSnapshot = Get-KimiUsageSnapshot `
                -OfficialUsageOverride $cachedUsage `
                -SkipOfficialRequest
            $fallback = New-UsageFallbackSnapshot `
                -Snapshot $cachedSnapshot `
                -Reason ('官方接口刷新失败 · ' + $failureMessage)
            Update-UsageView -Snapshot $fallback -DisplayOnly
        }
        elseif (-not $retryStarted -and $script:ActiveProvider -eq 'Kimi') {
            if ($script:LastKimiSnapshot) {
                $fallback = New-UsageFallbackSnapshot `
                    -Snapshot $script:LastKimiSnapshot `
                    -Reason ('官方接口刷新失败 · ' + $failureMessage)
                Update-UsageView -Snapshot $fallback -DisplayOnly
            }
            else {
                Update-UsageView -Snapshot (
                    Get-KimiUnavailableSnapshot -Reason $failureMessage
                )
            }
        }
    }
    finally {
        Complete-RefreshTaskCleanup `
            -State $kimi `
            -Response $response `
            -Request $request `
            -RetryStarted:$retryStarted
    }
}

function Sync-ProviderMenuState {
    $activeProvider = [string]$script:ActiveProvider
    if ($script:CodexSourceMenuItem) {
        $script:CodexSourceMenuItem.IsChecked = $activeProvider -eq 'Codex'
    }
    if ($script:DeepSeekSourceMenuItem) {
        $script:DeepSeekSourceMenuItem.IsChecked = $activeProvider -eq 'DeepSeek'
    }
    if ($script:TrayCodexSourceItem) {
        $script:TrayCodexSourceItem.Checked = $activeProvider -eq 'Codex'
    }
    if ($script:TrayDeepSeekSourceItem) {
        $script:TrayDeepSeekSourceItem.Checked = $activeProvider -eq 'DeepSeek'
    }
    if ($script:KimiSourceMenuItem) {
        $script:KimiSourceMenuItem.IsChecked = $activeProvider -eq 'Kimi'
    }
    if ($script:TrayKimiSourceItem) {
        $script:TrayKimiSourceItem.Checked = $activeProvider -eq 'Kimi'
    }
    if ($script:CodexOfficialAccessMenuItem) {
        $script:CodexOfficialAccessMenuItem.Visibility = if (
            $activeProvider -eq 'Codex'
        ) { 'Visible' } else { 'Collapsed' }
        $script:CodexOfficialAccessMenuItem.IsChecked =
            $script:CodexOfficialAccessEnabled
    }
    if ($script:TrayCodexOfficialAccessItem) {
        $script:TrayCodexOfficialAccessItem.Visible =
            $activeProvider -eq 'Codex'
        $script:TrayCodexOfficialAccessItem.Checked =
            $script:CodexOfficialAccessEnabled
    }
    # The WSL switch is always visible: it decides where the local CLI files are
    # read from, which the user may want to set before switching data source.
    if ($script:KimiWslMenuItem) {
        $script:KimiWslMenuItem.Visibility = 'Visible'
        $script:KimiWslMenuItem.IsChecked = $script:KimiUseWsl
    }
    if ($script:TrayKimiWslItem) {
        $script:TrayKimiWslItem.Visible = $true
        $script:TrayKimiWslItem.Checked = $script:KimiUseWsl
    }
    if ($script:BudgetBaselineMenuItem) {
        $script:BudgetBaselineMenuItem.Visibility = if (
            $activeProvider -in (Get-UsageAlertProviderIds)
        ) { 'Visible' } else { 'Collapsed' }
    }
    Sync-ConfigProfileMenu
}

function Set-ActiveProvider {
    param(
        [ValidateSet('Codex', 'DeepSeek', 'Kimi', '')]
        [string]$Provider,
        [switch]$Refresh
    )

    if ($script:ActiveProvider -ne $Provider) {
        Reset-ProviderRapidDropSession -ProviderId $Provider
        if (
            $script:AppContext.Refresh.DeepSeek.RequestTask -or
            $script:AppContext.Refresh.DeepSeek.RetryAfter
        ) {
            Cancel-DeepSeekRefresh
        }
        if (
            $script:AppContext.Refresh.Codex.RequestTask -or
            $script:AppContext.Refresh.Codex.RetryAfter
        ) {
            Cancel-CodexRefresh
        }
        if (
            $script:AppContext.Refresh.Kimi.RequestTask -or
            $script:AppContext.Refresh.Kimi.RetryAfter
        ) {
            Cancel-KimiRefresh
        }
    }
    $script:ActiveProvider = $Provider
    if ([string]::IsNullOrWhiteSpace($Provider)) {
        Clear-UsageView
    }
    Sync-ActiveAlertSettings
    Sync-LowAlertMenuState
    Sync-ProviderMenuState
    Save-Settings
    if ($Refresh) { Invoke-Refresh }
}

function Set-CodexOfficialAccess {
    param(
        [bool]$Enabled,
        [switch]$Confirm
    )

    if ($Enabled -and $Confirm) {
        $decision = [Windows.MessageBox]::Show(
            "启用后，应用会在内存中读取：`n" +
            "• %USERPROFILE%\.codex\auth.json 中的访问令牌和账户标识`n" +
            "• ID Token 中的显示名称与邮箱`n`n" +
            "这些信息仅用于请求：`n" +
            "https://chatgpt.com/backend-api/wham/usage`n`n" +
            "令牌不会写入设置、日志或界面。是否启用？",
            '启用 Codex 官方接口',
            [Windows.MessageBoxButton]::YesNo,
            [Windows.MessageBoxImage]::Information
        )
        if ($decision -ne [Windows.MessageBoxResult]::Yes) {
            Sync-ProviderMenuState
            return $false
        }
    }

    if (
        -not $Enabled -and
        (
            $script:AppContext.Refresh.Codex.RequestTask -or
            $script:AppContext.Refresh.Codex.RetryAfter
        )
    ) {
        Cancel-CodexRefresh
    }
    $script:CodexOfficialAccessEnabled = $Enabled
    if (-not $Enabled) {
        $script:CodexOfficialUsageCache = $null
        $script:UsageSyncSession.AwaitingInitialOfficial = $false
    }
    elseif (-not $script:UsageSyncSession.OfficialNotificationShown) {
        $script:UsageSyncSession.AwaitingInitialOfficial = $true
    }
    Sync-ProviderMenuState
    Save-Settings
    if ($script:ActiveProvider -eq 'Codex') {
        Invoke-Refresh
    }
    return $true
}

function Set-KimiUseWsl {
    param([bool]$Enabled)

    if (
        $script:AppContext.Refresh.Kimi.RequestTask -or
        $script:AppContext.Refresh.Kimi.RetryAfter
    ) {
        Cancel-KimiRefresh
    }
    $script:KimiUseWsl = $Enabled
    # 数据根与官方用量都可能来自另一侧环境，切换后全部重新解析。
    # Reset-ProviderAccountCaches clears the cached official usage too, and the
    # 401 marker goes with it so the local read is retried from scratch.
    Reset-ProviderAccountCaches -Provider 'Kimi'
    $script:KimiAutoCredentialRejected = $false
    $script:KimiWslDataRootCache = $null
    $script:KimiWslDataRootResolved = $false
    Sync-ProviderMenuState
    Save-Settings
    if ($script:ActiveProvider -eq 'Kimi') {
        Invoke-Refresh
    }
}

function Reset-ProviderAccountCaches {
    # Every cached value below was produced by a credential the user has just
    # moved away from; keeping it would show the previous account's numbers.
    param([string]$Provider)

    if ($Provider -eq 'Kimi') {
        $script:LastKimiSnapshot = $null
        $script:KimiOfficialUsageCache = $null
    }
    elseif ($Provider -eq 'DeepSeek') {
        $script:LastDeepSeekSnapshot = $null
    }
}

function Set-ActiveConfigProfile {
    param(
        [string]$Provider,
        [string]$ConfigId,
        [switch]$Refresh
    )

    $existing = Get-ActiveConfigProfileId -Provider $Provider
    if ($existing -eq $ConfigId) {
        # Re-selecting the same configuration must not blank the screen or fire
        # another request.
        return $false
    }
    Set-ActiveConfigProfileId -Provider $Provider -ConfigId $ConfigId
    if ($script:AppContext.Refresh.Kimi.RequestTask -or $script:AppContext.Refresh.Kimi.RetryAfter) {
        Cancel-KimiRefresh
    }
    if (
        $script:AppContext.Refresh.DeepSeek.RequestTask -or
        $script:AppContext.Refresh.DeepSeek.RetryAfter
    ) {
        Cancel-DeepSeekRefresh
    }
    Reset-ProviderAccountCaches -Provider $Provider
    # The 401 marker belongs to the credential we just left as well.
    if ($Provider -eq 'Kimi') { $script:KimiAutoCredentialRejected = $false }
    Reset-ProviderRapidDropSession -ProviderId $Provider
    Save-Settings
    Sync-ProviderMenuState
    if ($Refresh -or $script:ActiveProvider -eq $Provider) { Invoke-Refresh }
    return $true
}


function Test-ShouldPresentCodexLocalSnapshot {
    if (-not $script:CodexOfficialAccessEnabled) { return $true }
    return (
        -not $script:LastSnapshot -or
        -not [bool]$script:LastSnapshot.Available
    )
}

function Test-ShouldPersistCodexLocalSnapshot {
    return -not [bool]$script:CodexOfficialAccessEnabled
}

function Complete-CodexLocalRefresh {
    # Process the latest queued local snapshot; earlier ones are merged/discarded
    $pending = $script:PendingCodexLocalRefresh
    $script:PendingCodexLocalRefresh = $null
    if (-not $pending -or $script:IsClosing) { return }
    try {
        # Use the most recent snapshot (last in queue)
        $snapshotToPresent = $pending[-1]
        if (Test-ShouldPresentCodexLocalSnapshot) {
            $persistLocalSnapshot = Test-ShouldPersistCodexLocalSnapshot
            Update-UsageView `
                -Snapshot $snapshotToPresent.Snapshot `
                -ObservationContext $snapshotToPresent.ObservationContext `
                -DisplayOnly:(-not $persistLocalSnapshot)
            if (-not $persistLocalSnapshot) {
                Write-RuntimeLog `
                    -Level 'Debug' `
                    -Event 'Refresh.LocalPreviewPresented' `
                    -Message 'Presented a display-only local preview while waiting for official usage' `
                    -Data @{ DisplayOnly = $true; QueueDepth = $pending.Count }
            }
        }
        else {
            Write-RuntimeLog `
                -Level 'Debug' `
                -Event 'Refresh.LocalPreviewSuppressed' `
                -Message '保留当前官方结果，本地读取仅作为刷新候选' `
                -Data @{ QueueDepth = $pending.Count }
        }
        Set-RuntimeDiagnosticStatus `
            -Area 'Refresh' `
            -Status 'Healthy' `
            -Message $(if ($script:CodexOfficialAccessEnabled) {
                '本地读取完成，等待 Codex 官方接口'
            } else {
                '本地用量读取成功'
            })
        Start-CodexRefresh
    }
    catch {
        Write-RuntimeLog `
            -Level 'Error' `
            -Event 'Refresh.LocalCompletionFailed' `
            -Message $_.Exception.Message
        Reset-FailedRefreshOperation -Message $_.Exception.Message
    }
}

function Invoke-Refresh {
    if ($script:AppContext.Refresh.IsBusy) { return }
    # The empty state must not fall through to the Codex branch below: with no
    # data source selected there is nothing to request, and quietly reading
    # Codex would both surprise the user and defeat the blank window.
    if ([string]::IsNullOrWhiteSpace([string]$script:ActiveProvider)) {
        Set-RuntimeDiagnosticStatus `
            -Area 'Refresh' `
            -Status 'Healthy' `
            -Message '尚未选择数据源'
        Set-RefreshBusy -Busy $false
        Clear-UsageView
        Reset-RefreshCountdown
        return
    }
    try {
        Set-RuntimeDiagnosticStatus `
            -Area 'Refresh' `
            -Status 'Running' `
            -Message '正在刷新'
        Set-RefreshBusy -Busy $true
        if ($script:ActiveProvider -eq 'DeepSeek') {
            $script:UsageSyncSession.InitialRefreshStarted = $true
            Start-DeepSeekRefresh
            return
        }
        if ($script:ActiveProvider -eq 'Kimi') {
            $script:UsageSyncSession.InitialRefreshStarted = $true
            Start-KimiRefresh
            return
        }

        $observationContext = 'Normal'
        if (-not $script:UsageSyncSession.InitialRefreshStarted) {
            $script:UsageSyncSession.InitialRefreshStarted = $true
            $script:UsageSyncSession.AwaitingInitialOfficial =
                [bool]$script:CodexOfficialAccessEnabled
            $observationContext = 'StartupLocal'
        }
        elseif ($script:CodexOfficialAccessEnabled) {
            $observationContext = 'LocalPreview'
        }
        $currentOfficialUsage = Get-CodexCurrentUsageOverride
        $localSnapshot = (
            Get-CodexUsageSnapshot `
                -OfficialUsageOverride $currentOfficialUsage `
                -SkipOfficialRequest
        )
        if ($isDiagnosticRun) {
            Update-UsageView `
                -Snapshot $localSnapshot `
                -ObservationContext $observationContext
            Set-RuntimeDiagnosticStatus `
                -Area 'Refresh' `
                -Status 'Healthy' `
                -Message '本地用量读取成功'
            Start-CodexRefresh
        }
        else {
            # Queue local snapshots; Complete-CodexLocalRefresh will present the latest
            if (-not $script:PendingCodexLocalRefresh) {
                $script:PendingCodexLocalRefresh = @()
            }
            $script:PendingCodexLocalRefresh += [pscustomobject]@{
                Snapshot = $localSnapshot
                ObservationContext = $observationContext
            }
            $window.Dispatcher.BeginInvoke(
                [Windows.Threading.DispatcherPriority]::Background,
                (New-RmfAction -Callback { Complete-CodexLocalRefresh })
            ) | Out-Null
        }
    }
    catch {
        if (Get-Command Write-RuntimeLog -ErrorAction SilentlyContinue) {
            Write-RuntimeLog `
                -Level 'Error' `
                -Event 'Refresh.Failed' `
                -Message $_.Exception.Message `
                -Data @{ Provider = $script:ActiveProvider }
        }
        Set-RuntimeDiagnosticStatus `
            -Area 'Refresh' `
            -Status 'Error' `
            -Message $_.Exception.Message
        if (-not $script:LastSnapshot) {
            $WindowLabel.Text = '读取失败'
            $ExpandedWindowLabel.Text = '读取失败'
            $RemainingValue.Text = '--'
            $CompactSuffix.Text = ''
        }
        $SourceText.Text = '无法读取本地用量：' + $_.Exception.Message
        Set-RefreshBusy -Busy $false
        Reset-RefreshCountdown
    }
}

function Reset-ProviderRefreshState {
    param($State)

    if ($State.Request) {
        try { $State.Request.Dispose() } catch {
            # Cancelling mid-flight can invalidate the request; disposal is best-effort.
        }
    }
    $State.Request = $null
    $State.RequestTask = $null
    $State.Attempt = 0
    $State.RetryAfter = $null
}

function Reset-FailedRefreshOperation {
    param([string]$Message)

    Reset-ProviderRefreshState -State $script:AppContext.Refresh.Codex
    Reset-ProviderRefreshState -State $script:AppContext.Refresh.DeepSeek
    Reset-ProviderRefreshState -State $script:AppContext.Refresh.Kimi

    try {
        Set-RefreshBusy -Busy $false
    }
    catch {
        $script:AppContext.Refresh.IsBusy = $false
        $script:AppContext.Refresh.StartedAt = $null
    }
    Reset-RefreshCountdown
    Set-RuntimeDiagnosticStatus `
        -Area 'Refresh' `
        -Status 'Error' `
        -Message $Message
    if ($SourceText) {
        $SourceText.Text = '刷新异常，已保留上次数据 · ' + $Message
    }
}

function Set-AutoRefreshStatusText {
    if ($script:AppContext.Refresh.IsBusy) {
        $elapsedSeconds = if ($script:AppContext.Refresh.StartedAt) {
            [Math]::Max(
                0,
                [Math]::Floor(
                    (
                        [DateTimeOffset]::Now -
                        $script:AppContext.Refresh.StartedAt
                    ).TotalSeconds
                )
            )
        }
        else { 0 }
        $newText = '正在刷新 · 已等待 {0} 秒' -f $elapsedSeconds
        if ($AutoRefreshText.Text -ne $newText) {
            $AutoRefreshText.Text = $newText
        }
        if ($releaseGuiCheck -and $elapsedSeconds -ge 1) {
            $script:RmfRefreshTimerProbePassed = $true
        }
        return
    }

    $newText = '{0} 秒后自动刷新' -f [Math]::Max(
        0,
        $script:AppContext.Refresh.RemainingSeconds
    )
    if ($AutoRefreshText.Text -ne $newText) {
        $AutoRefreshText.Text = $newText
    }
}

function Invoke-RefreshTimerTick {
    [void](Complete-UsageHistoryRepair)
    try {
        [void](Sync-EdgeDockEnvironment)
        [void](Repair-WindowPlacementIfOffScreen)
    }
    catch {
        Set-RuntimeDiagnosticStatus `
            -Area 'Window' `
            -Status 'Degraded' `
            -Message $_.Exception.Message
    }

    try {
        Complete-CodexRefresh
        Complete-DeepSeekRefresh
        Complete-KimiRefresh
    }
    catch {
        Reset-FailedRefreshOperation -Message $_.Exception.Message
    }

    if ($script:AppContext.Refresh.IsBusy) {
        Set-AutoRefreshStatusText
        return
    }

    $now = [DateTimeOffset]::Now
    if (-not $script:AppContext.Refresh.NextAt) {
        Reset-RefreshCountdown -Now $now
    }
    $script:AppContext.Refresh.RemainingSeconds = [Math]::Max(
        0,
        [Math]::Ceiling(
            ($script:AppContext.Refresh.NextAt - $now).TotalSeconds
        )
    )
    if ($script:AppContext.Refresh.RemainingSeconds -le 0) {
        Invoke-Refresh
        if (
            -not $script:AppContext.Refresh.IsBusy -and
            (
                -not $script:AppContext.Refresh.NextAt -or
                $script:AppContext.Refresh.NextAt -le [DateTimeOffset]::Now
            )
        ) {
            Reset-RefreshCountdown
        }
    }
    Set-AutoRefreshStatusText
}
