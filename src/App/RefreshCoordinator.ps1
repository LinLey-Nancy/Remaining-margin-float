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
    }
    elseif (-not $Busy) {
        $script:AppContext.Refresh.StartedAt = $null
    }
    $script:AppContext.Refresh.IsBusy = $Busy
    $RefreshButton.IsEnabled = -not $Busy
    $RefreshButton.Content = if ($Busy) { '读取中…' } else { '立即刷新' }
}

function Cancel-CodexRefresh {
    $codex = $script:AppContext.Refresh.Codex
    if ($codex.RequestTask -and -not $codex.RequestTask.IsCompleted) {
        if ($script:CodexHttpClient) {
            $script:CodexHttpClient.CancelPendingRequests()
        }
    }
    elseif (
        $codex.RequestTask -and
        -not $codex.RequestTask.IsCanceled -and
        -not $codex.RequestTask.IsFaulted
    ) {
        $abandonedResponse = $codex.RequestTask.GetAwaiter().GetResult()
        if ($abandonedResponse) { $abandonedResponse.Dispose() }
    }
    if ($codex.Request) {
        $codex.Request.Dispose()
    }
    $codex.Request = $null
    $codex.RequestTask = $null
    $codex.Attempt = 0
    $codex.RetryAfter = $null
    Set-RefreshBusy -Busy $false
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
            $SourceText.Text = '官方接口请求未能启动，已保留本地数据 · ' +
                $_.Exception.Message
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
    if (
        $script:CodexOfficialUsageCache -and
        ($now - $script:CodexOfficialUsageCache.SampledAt).TotalSeconds -lt 15
    ) {
        Update-UsageView -Snapshot (
            Get-CodexUsageSnapshot `
                -OfficialUsageOverride $script:CodexOfficialUsageCache `
                -SkipOfficialRequest
        )
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
            Update-UsageView -Snapshot (
                Get-CodexUsageSnapshot `
                    -OfficialUsageOverride $usage `
                    -SkipOfficialRequest
            )
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
            $statusCode -in @(408, 425, 429, 500, 502, 503, 504)
        )
        if (
            $transientFailure -and
            $codex.Attempt -lt $codex.MaxAttempts -and
            $script:CodexOfficialAccessEnabled -and
            $script:ActiveProvider -eq 'Codex' -and
            -not $script:IsClosing
        ) {
            $retryDelaySeconds = 1.0
            if (
                $response -and
                $response.Headers.RetryAfter -and
                $response.Headers.RetryAfter.Delta
            ) {
                $retryDelaySeconds = [Math]::Min(
                    30,
                    [Math]::Max(
                        1,
                        $response.Headers.RetryAfter.Delta.Value.TotalSeconds
                    )
                )
            }
            $codex.RetryAfter =
                [DateTimeOffset]::Now.AddSeconds($retryDelaySeconds)
            $retryStarted = $true
        }
        if (
            -not $retryStarted -and
            $script:CodexOfficialUsageCache -and
            ([DateTimeOffset]::Now - $script:CodexOfficialUsageCache.SampledAt).TotalMinutes -lt 10 -and
            $script:ActiveProvider -eq 'Codex'
        ) {
            $cached = $script:CodexOfficialUsageCache
            $cachedUsage = [pscustomobject]@{
                UsedPercent = $cached.UsedPercent
                WindowMinutes = $cached.WindowMinutes
                ResetsAt = $cached.ResetsAt
                PlanType = $cached.PlanType
                SampledAt = $cached.SampledAt
                IsCached = $true
            }
            Update-UsageView -Snapshot (
                Get-CodexUsageSnapshot `
                    -OfficialUsageOverride $cachedUsage `
                    -SkipOfficialRequest
            )
        }
        elseif (-not $retryStarted -and $script:ActiveProvider -eq 'Codex') {
            $SourceText.Text = '官方接口刷新失败，已保留本地数据 · ' +
                $failureMessage
        }
    }
    finally {
        if ($response) { $response.Dispose() }
        if ($request) { $request.Dispose() }
        if (-not $retryStarted) {
            $codex.Attempt = 0
            $codex.RetryAfter = $null
            Set-RefreshBusy -Busy $false
            Reset-RefreshCountdown
        }
    }
}

function Get-DeepSeekHttpClient {
    if (-not $script:DeepSeekHttpClient) {
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(8)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('RemainingMarginFloat/1.8.0')
        $script:DeepSeekHttpClient = $client
    }
    return $script:DeepSeekHttpClient
}

function Cancel-DeepSeekRefresh {
    $deepSeek = $script:AppContext.Refresh.DeepSeek
    if ($deepSeek.RequestTask -and -not $deepSeek.RequestTask.IsCompleted) {
        if ($script:DeepSeekHttpClient) {
            $script:DeepSeekHttpClient.CancelPendingRequests()
        }
    }
    elseif (
        $deepSeek.RequestTask -and
        -not $deepSeek.RequestTask.IsCanceled -and
        -not $deepSeek.RequestTask.IsFaulted
    ) {
        $abandonedResponse = $deepSeek.RequestTask.GetAwaiter().GetResult()
        if ($abandonedResponse) { $abandonedResponse.Dispose() }
    }
    if ($deepSeek.Request) {
        $deepSeek.Request.Dispose()
    }
    $deepSeek.Request = $null
    $deepSeek.RequestTask = $null
    Set-RefreshBusy -Busy $false
}

function Start-DeepSeekRefresh {
    if ($Demo) {
        $snapshot = Get-DeepSeekDemoSnapshot
        $script:LastDeepSeekSnapshot = $snapshot
        Update-UsageView -Snapshot $snapshot
        Set-RefreshBusy -Busy $false
        return
    }

    $credential = Get-DeepSeekCredential
    if ([string]::IsNullOrWhiteSpace($credential.ApiKey)) {
        Update-UsageView -Snapshot (Get-DeepSeekUnavailableSnapshot)
        Set-RefreshBusy -Busy $false
        return
    }

    $request = $null
    try {
        $request = New-Object System.Net.Http.HttpRequestMessage(
            [System.Net.Http.HttpMethod]::Get,
            'https://api.deepseek.com/user/balance'
        )
        $request.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue(
            'Bearer',
            $credential.ApiKey
        )
        $script:AppContext.Refresh.DeepSeek.Request = $request
        $script:AppContext.Refresh.DeepSeek.RequestTask =
            (Get-DeepSeekHttpClient).SendAsync($request)
    }
    catch {
        if ($request) { $request.Dispose() }
        $script:AppContext.Refresh.DeepSeek.Request = $null
        $script:AppContext.Refresh.DeepSeek.RequestTask = $null
        Set-RuntimeDiagnosticStatus `
            -Area 'DeepSeek' `
            -Status 'Error' `
            -Message $_.Exception.Message
        Set-RuntimeDiagnosticStatus `
            -Area 'Refresh' `
            -Status 'Error' `
            -Message $_.Exception.Message
        Set-RefreshBusy -Busy $false
        $SourceText.Text = 'DeepSeek 请求未能启动：' + $_.Exception.Message
    }
}

function Complete-DeepSeekRefresh {
    $deepSeek = $script:AppContext.Refresh.DeepSeek
    if (-not $deepSeek.RequestTask -or -not $deepSeek.RequestTask.IsCompleted) {
        return
    }

    $task = $deepSeek.RequestTask
    $request = $deepSeek.Request
    $deepSeek.RequestTask = $null
    $deepSeek.Request = $null
    $response = $null
    try {
        if ($task.IsCanceled) { throw 'DeepSeek 请求超时，请稍后重试。' }
        if ($task.IsFaulted) {
            throw ($task.Exception.GetBaseException().Message)
        }

        $response = $task.GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            $message = switch ([int]$response.StatusCode) {
                401 { 'API Key 无效或已失效，请重新配置。' }
                402 { 'DeepSeek 余额不足，请充值后重试。' }
                429 { '请求过于频繁，稍后会自动重试。' }
                500 { 'DeepSeek 服务暂时异常，稍后会自动重试。' }
                503 { 'DeepSeek 服务繁忙，稍后会自动重试。' }
                default { 'DeepSeek 返回 HTTP {0}。' -f [int]$response.StatusCode }
            }
            throw $message
        }

        $payload = $body | ConvertFrom-Json
        $configuration = Get-DeepSeekConfiguration
        $credential = Get-DeepSeekCredential
        $snapshot = ConvertTo-DeepSeekSnapshot `
            -BalancePayload $payload `
            -LocalUsage (Get-DeepSeekLocalUsage) `
            -Budget $configuration.Budget `
            -KeyHint $credential.Hint `
            -CredentialSource $credential.Source
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
        Set-RuntimeDiagnosticStatus `
            -Area 'DeepSeek' `
            -Status 'Degraded' `
            -Message $_.Exception.Message
        Set-RuntimeDiagnosticStatus `
            -Area 'Refresh' `
            -Status 'Degraded' `
            -Message $_.Exception.Message
        if ($script:LastDeepSeekSnapshot -and $script:ActiveProvider -eq 'DeepSeek') {
            Update-UsageView -Snapshot $script:LastDeepSeekSnapshot
            $SourceText.Text = '刷新失败，显示上次数据 · ' + $_.Exception.Message
        }
        elseif ($script:ActiveProvider -eq 'DeepSeek') {
            Update-UsageView -Snapshot (Get-DeepSeekUnavailableSnapshot -Reason $_.Exception.Message)
        }
    }
    finally {
        if ($response) { $response.Dispose() }
        if ($request) { $request.Dispose() }
        Set-RefreshBusy -Busy $false
        Reset-RefreshCountdown
    }
}

function Sync-ProviderMenuState {
    if ($script:CodexSourceMenuItem) {
        $script:CodexSourceMenuItem.IsChecked = $script:ActiveProvider -eq 'Codex'
    }
    if ($script:DeepSeekSourceMenuItem) {
        $script:DeepSeekSourceMenuItem.IsChecked = $script:ActiveProvider -eq 'DeepSeek'
    }
    if ($script:TrayCodexSourceItem) {
        $script:TrayCodexSourceItem.Checked = $script:ActiveProvider -eq 'Codex'
    }
    if ($script:TrayDeepSeekSourceItem) {
        $script:TrayDeepSeekSourceItem.Checked = $script:ActiveProvider -eq 'DeepSeek'
    }
    if ($script:CodexOfficialAccessMenuItem) {
        $script:CodexOfficialAccessMenuItem.Visibility = if (
            $script:ActiveProvider -eq 'Codex'
        ) { 'Visible' } else { 'Collapsed' }
        $script:CodexOfficialAccessMenuItem.IsChecked =
            $script:CodexOfficialAccessEnabled
    }
    if ($script:TrayCodexOfficialAccessItem) {
        $script:TrayCodexOfficialAccessItem.Visible =
            $script:ActiveProvider -eq 'Codex'
        $script:TrayCodexOfficialAccessItem.Checked =
            $script:CodexOfficialAccessEnabled
    }
    if ($script:DeepSeekSettingsMenuItem) {
        $script:DeepSeekSettingsMenuItem.Visibility = if (
            $script:ActiveProvider -eq 'DeepSeek'
        ) { 'Visible' } else { 'Collapsed' }
    }
    if ($script:TrayDeepSeekSettingsItem) {
        $script:TrayDeepSeekSettingsItem.Visible = $script:ActiveProvider -eq 'DeepSeek'
    }
}

function Set-ActiveProvider {
    param(
        [ValidateSet('Codex', 'DeepSeek')]
        [string]$Provider,
        [switch]$Refresh
    )

    if ($script:ActiveProvider -ne $Provider) {
        if ($script:AppContext.Refresh.DeepSeek.RequestTask) {
            Cancel-DeepSeekRefresh
        }
        if (
            $script:AppContext.Refresh.Codex.RequestTask -or
            $script:AppContext.Refresh.Codex.RetryAfter
        ) {
            Cancel-CodexRefresh
        }
    }
    $script:ActiveProvider = $Provider
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
    }
    Sync-ProviderMenuState
    Save-Settings
    if ($script:ActiveProvider -eq 'Codex') {
        Invoke-Refresh
    }
    return $true
}

function Show-DeepSeekSettings {
    $configuration = Get-DeepSeekConfiguration
    $credential = Get-DeepSeekCredential
    [xml]$dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DeepSeek 设置"
        Width="430"
        Height="350"
        ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner"
        ShowInTaskbar="False"
        Background="#FCFBF8"
        FontFamily="Microsoft YaHei UI">
    <Grid x:Name="SettingsRoot" Background="#FCFBF8">
      <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="22"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="18"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="38"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="连接 DeepSeek 官方余额" FontSize="18" FontWeight="SemiBold" Foreground="#343A35"/>
        <StackPanel Grid.Row="2">
            <TextBlock Text="API Key" FontSize="12" FontWeight="SemiBold" Foreground="#4E5750"/>
            <PasswordBox x:Name="ApiKeyBox" Height="34" Margin="0,7,0,0" Padding="9,6"
                         BorderBrush="#D8DDD7" Background="White"
                         AutomationProperties.Name="DeepSeek API Key"/>
            <TextBlock x:Name="KeyHelp" Margin="0,6,0,0" FontSize="10" Foreground="#7B847D" TextWrapping="Wrap"/>
            <CheckBox x:Name="RemoveKeyBox" Margin="0,8,0,0" Content="清除已保存的 API Key"
                      Foreground="#6B746D" FontSize="11"/>
        </StackPanel>
        <StackPanel Grid.Row="5">
            <TextBlock Text="预算基准（可选）" FontSize="12" FontWeight="SemiBold" Foreground="#4E5750"/>
            <TextBox x:Name="BudgetBox" Height="34" Margin="0,7,0,0" Padding="9,6"
                     BorderBrush="#D8DDD7" Background="White"
                     AutomationProperties.Name="预算基准"/>
            <TextBlock Margin="0,6,0,0" FontSize="10" Foreground="#7B847D"
                       Text="设置后，小窗显示当前余额相对该金额的百分比；留空则直接显示余额。"/>
        </StackPanel>
        <TextBlock x:Name="ErrorText" Grid.Row="7" Margin="0,8,0,0"
                   Foreground="#A65B52" FontSize="11" TextWrapping="Wrap"/>
        <Grid Grid.Row="8">
            <Button x:Name="CancelButton" Width="82" Height="34" HorizontalAlignment="Right"
                    Margin="0,0,92,0" Content="取消" IsCancel="True"/>
            <Button x:Name="SaveButton" Width="82" Height="34" HorizontalAlignment="Right"
                    Content="保存" IsDefault="True" Background="#E9F0EA"
                    BorderBrush="#BFCDBF" Foreground="#344A3B"/>
        </Grid>
      </Grid>
    </Grid>
</Window>
'@
    $dialogReader = New-Object System.Xml.XmlNodeReader $dialogXaml
    $dialog = [Windows.Markup.XamlReader]::Load($dialogReader)
    $dialog.Owner = $window
    $apiKeyBox = $dialog.FindName('ApiKeyBox')
    $keyHelp = $dialog.FindName('KeyHelp')
    $removeKeyBox = $dialog.FindName('RemoveKeyBox')
    $budgetBox = $dialog.FindName('BudgetBox')
    $errorText = $dialog.FindName('ErrorText')
    $saveButton = $dialog.FindName('SaveButton')

    if ($configuration.Budget -gt 0) {
        $budgetBox.Text = $configuration.Budget.ToString('0.##', [Globalization.CultureInfo]::CurrentCulture)
    }
    if ($credential.Source -eq '环境变量') {
        $keyHelp.Text = '当前由 DEEPSEEK_API_KEY 环境变量提供（••••{0}），环境变量优先。' -f $credential.Hint
        $apiKeyBox.IsEnabled = $false
        $removeKeyBox.IsEnabled = $false
    }
    elseif ($credential.ApiKey) {
        $keyHelp.Text = '已通过 Windows DPAPI 安全保存（••••{0}）。留空会保留原密钥。' -f $credential.Hint
    }
    else {
        $keyHelp.Text = '密钥仅加密保存在当前 Windows 用户下，不会写入日志或仓库。'
        $removeKeyBox.IsEnabled = $false
    }

    $saveButton.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
        $errorText.Text = ''
        $budget = 0.0
        $budgetText = $budgetBox.Text.Trim()
        if ($budgetText) {
            $parsed = [double]::TryParse(
                $budgetText,
                [Globalization.NumberStyles]::Number,
                [Globalization.CultureInfo]::CurrentCulture,
                [ref]$budget
            )
            if (-not $parsed) {
                $parsed = [double]::TryParse(
                    $budgetText,
                    [Globalization.NumberStyles]::Number,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [ref]$budget
                )
            }
            if (-not $parsed -or $budget -le 0) {
                $errorText.Text = '预算基准需要是大于 0 的数字，或留空不设置。'
                $budgetBox.Focus() | Out-Null
                return
            }
        }

        $newKey = $apiKeyBox.Password.Trim()
        if (
            $credential.Source -ne '环境变量' -and
            -not $removeKeyBox.IsChecked -and
            -not $credential.ApiKey -and
            [string]::IsNullOrWhiteSpace($newKey)
        ) {
            $errorText.Text = '请输入 DeepSeek API Key。'
            $apiKeyBox.Focus() | Out-Null
            return
        }
        if ($newKey -and $newKey.Length -lt 10) {
            $errorText.Text = 'API Key 长度看起来不正确，请检查后重试。'
            $apiKeyBox.Focus() | Out-Null
            return
        }

        try {
            Save-DeepSeekConfiguration `
                -ApiKey $newKey `
                -Budget $budget `
                -RemoveKey:$removeKeyBox.IsChecked
            $dialog.DialogResult = $true
        }
        catch {
            $errorText.Text = '保存失败：' + $_.Exception.Message
        }
    }))

    $saved = $dialog.ShowDialog()
    if ($saved) {
        $script:LastDeepSeekSnapshot = $null
        Set-ActiveProvider -Provider 'DeepSeek' -Refresh
        return $true
    }
    return $false
}

function Invoke-Refresh {
    if ($script:AppContext.Refresh.IsBusy) { return }
    try {
        Set-RuntimeDiagnosticStatus `
            -Area 'Refresh' `
            -Status 'Running' `
            -Message '正在刷新'
        Set-RefreshBusy -Busy $true
        if ($script:ActiveProvider -eq 'DeepSeek') {
            Start-DeepSeekRefresh
            return
        }

        Update-UsageView -Snapshot (
            Get-CodexUsageSnapshot `
                -OfficialUsageOverride $null `
                -SkipOfficialRequest
        )
        Set-RuntimeDiagnosticStatus `
            -Area 'Refresh' `
            -Status 'Healthy' `
            -Message '本地用量读取成功'
        Start-CodexRefresh
    }
    catch {
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

function Reset-FailedRefreshOperation {
    param([string]$Message)

    $codex = $script:AppContext.Refresh.Codex
    $deepSeek = $script:AppContext.Refresh.DeepSeek
    if ($codex.Request) {
        try { $codex.Request.Dispose() } catch {}
    }
    $codex.Request = $null
    $codex.RequestTask = $null
    $codex.RetryAfter = $null
    $codex.Attempt = 0

    if ($deepSeek.Request) {
        try { $deepSeek.Request.Dispose() } catch {}
    }
    $deepSeek.Request = $null
    $deepSeek.RequestTask = $null

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
        $AutoRefreshText.Text = '正在刷新 · 已等待 {0} 秒' -f $elapsedSeconds
        if ($releaseGuiCheck -and $elapsedSeconds -ge 1) {
            $script:RmfRefreshTimerProbePassed = $true
        }
        return
    }

    $AutoRefreshText.Text = '{0} 秒后自动刷新' -f [Math]::Max(
        0,
        $script:AppContext.Refresh.RemainingSeconds
    )
}

function Invoke-RefreshTimerTick {
    try {
        Complete-CodexRefresh
        Complete-DeepSeekRefresh
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
