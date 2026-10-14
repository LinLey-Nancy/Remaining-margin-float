# Dialogs for the saved-configuration profiles, the budget baseline and the
# first-run guide. They live in their own component because the profile menu is
# rebuilt from disk every time it opens, and the dialogs are the only writers of
# configs.json outside the diagnostics.

function Get-ConfigProfileDialogText {
    param(
        [string]$Provider,
        [switch]$Add
    )

    $name = if ($Provider -eq 'Kimi') { 'Kimi Code' } else { 'DeepSeek' }
    if ($Add) { return ('添加 {0} 配置' -f $name) }
    return ('{0} 配置' -f $name)
}

function Invoke-ConfigProfileConnectionTest {
    # A real request, so a typo is caught before the profile is stored instead
    # of turning into a silent "quota unknown" later.
    param(
        [string]$Provider,
        [string]$BaseUrl,
        [string]$ApiKey
    )

    try {
        if ($Provider -eq 'Kimi') {
            $token = $ApiKey.Trim()
            if ($token.Length -lt 10) { return 'API Key 长度看起来不正确。' }
            $url = Resolve-KimiUsageUrl -BaseUrl $BaseUrl
            $request = New-Object System.Net.Http.HttpRequestMessage(
                [System.Net.Http.HttpMethod]::Get, $url
            )
            $request.Headers.Authorization =
                New-Object System.Net.Http.Headers.AuthenticationHeaderValue(
                    'Bearer', $token
                )
            $response = (Get-KimiHttpClient).SendAsync($request).GetAwaiter().GetResult()
            try {
                if ([int]$response.StatusCode -eq 401) {
                    return 'API Key 无效或已失效。'
                }
                if ([int]$response.StatusCode -eq 403) {
                    return '当前 Key 无权访问该用量接口。'
                }
                if (-not $response.IsSuccessStatusCode) {
                    return ('接口返回 HTTP {0}。' -f [int]$response.StatusCode)
                }
                $payload = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() |
                    ConvertFrom-Json
                $usage = ConvertTo-KimiOfficialUsage `
                    -Payload $payload `
                    -SampledAt ([DateTimeOffset]::Now)
                if (-not $usage) { return '地址可访问，但响应里没有可识别的额度数据。' }
                return '连接正常，已读取到该账号的额度数据。'
            }
            finally {
                $response.Dispose()
                $request.Dispose()
            }
        }

        if ($ApiKey.Trim().Length -lt 10) { return 'API Key 长度看起来不正确。' }
        $balanceUrl = Get-DeepSeekBalanceUrl -BaseUrl $BaseUrl
        $request = New-Object System.Net.Http.HttpRequestMessage(
            [System.Net.Http.HttpMethod]::Get, $balanceUrl
        )
        $request.Headers.Authorization =
            New-Object System.Net.Http.Headers.AuthenticationHeaderValue(
                'Bearer', $ApiKey.Trim()
            )
        $response = (Get-DeepSeekHttpClient).
            SendAsync($request).GetAwaiter().GetResult()
        try {
            $statusCode = [int]$response.StatusCode
            if ($statusCode -eq 401) { return 'API Key 无效或已失效。' }
            if ($statusCode -eq 404) {
                return '该地址不提供余额接口，可保存但只能显示本机用量。'
            }
            if (-not $response.IsSuccessStatusCode) {
                return ('接口返回 HTTP {0}。' -f $statusCode)
            }
            $payload = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() |
                ConvertFrom-Json
            $infos = @(
                Get-ObjectPropertyValue -Object $payload -Name 'balance_infos' -Default @()
            )
            if ($infos.Count -eq 0) { return '连接正常，但响应里没有余额数据。' }
            return '连接正常，已读取到该账号的余额。'
        }
        finally {
            $response.Dispose()
            $request.Dispose()
        }
    }
    catch {
        return ('连接失败：' + $_.Exception.Message)
    }
}

function Show-ConfigProfileDialog {
    param(
        [ValidateSet('Kimi', 'DeepSeek')]
        [string]$Provider,
        [ValidateSet('Add', 'Edit')]
        [string]$Mode = 'Add',
        [string]$ConfigId = ''
    )

    $existing = $null
    if ($Mode -eq 'Edit') {
        $existing = Get-ConfigProfile -Provider $Provider -ConfigId $ConfigId -Refresh
        if (-not $existing) {
            $Mode = 'Add'
            $existing = $null
        }
    }
    $isAuto = ($existing -and [string]$existing.Kind -eq 'Auto')
    $isEdit = ($existing -and -not $isAuto)
    $suggestedLabel = if ($isEdit) {
        [string]$existing.Label
    } else {
        ('配置 {0}' -f (@(Get-ConfigProfileEntries -Provider $Provider).Count))
    }

    [xml]$dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="配置"
        Width="460"
        Height="560"
        ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner"
        ShowInTaskbar="False"
        Background="#FCFBF8"
        FontFamily="Microsoft YaHei UI">
    <Grid x:Name="SettingsRoot" Background="#FCFBF8">
      <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="10"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="38"/>
        </Grid.RowDefinitions>
        <TextBlock x:Name="DialogTitle" Grid.Row="0" FontSize="18" FontWeight="SemiBold" Foreground="#343A35"/>
        <TextBlock x:Name="AutoNotice" Grid.Row="1" Margin="0,0,0,10" FontSize="11" Foreground="#7B847D" TextWrapping="Wrap"/>
        <StackPanel Grid.Row="2">
            <TextBlock Text="配置名称" FontSize="12" FontWeight="SemiBold" Foreground="#4E5750"/>
            <TextBox x:Name="LabelBox" Height="34" Margin="0,7,0,0" Padding="9,6"
                     BorderBrush="#D8DDD7" Background="White"
                     AutomationProperties.Name="配置名称"/>
        </StackPanel>
        <StackPanel Grid.Row="3" Margin="0,14,0,0">
            <TextBlock Text="接口地址（Base URL）" FontSize="12" FontWeight="SemiBold" Foreground="#4E5750"/>
            <TextBox x:Name="BaseUrlBox" Height="34" Margin="0,7,0,0" Padding="9,6"
                     BorderBrush="#D8DDD7" Background="White"
                     AutomationProperties.Name="接口地址"/>
            <TextBlock x:Name="BaseUrlHelp" Margin="0,6,0,0" FontSize="10" Foreground="#7B847D" TextWrapping="Wrap"/>
        </StackPanel>
        <StackPanel Grid.Row="4" Margin="0,14,0,0">
            <TextBlock Text="API Key" FontSize="12" FontWeight="SemiBold" Foreground="#4E5750"/>
            <PasswordBox x:Name="ApiKeyBox" Height="34" Margin="0,7,0,0" Padding="9,6"
                         BorderBrush="#D8DDD7" Background="White"
                         AutomationProperties.Name="API Key"/>
            <TextBlock x:Name="KeyHelp" Margin="0,6,0,0" FontSize="10" Foreground="#7B847D" TextWrapping="Wrap"/>
        </StackPanel>
        <StackPanel Grid.Row="5" Margin="0,14,0,0">
            <Button x:Name="DetectButton" Height="32" HorizontalAlignment="Left" Padding="12,0"
                    Content="检测本机已有配置"/>
            <ComboBox x:Name="DetectCombo" Height="32" Margin="0,8,0,0" Padding="6,4"
                      Visibility="Collapsed" AutomationProperties.Name="检测结果"/>
            <TextBlock x:Name="TestResult" Margin="0,8,0,0" FontSize="11" Foreground="#4E5750" TextWrapping="Wrap"/>
        </StackPanel>
        <TextBlock x:Name="ErrorText" Grid.Row="7" Margin="0,8,0,0"
                   Foreground="#A65B52" FontSize="11" TextWrapping="Wrap"/>
        <Grid Grid.Row="9">
            <Button x:Name="DeleteButton" Width="82" Height="34" HorizontalAlignment="Left"
                    Content="删除" Visibility="Collapsed"/>
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
    $dialogTitle = $dialog.FindName('DialogTitle')
    $autoNotice = $dialog.FindName('AutoNotice')
    $labelBox = $dialog.FindName('LabelBox')
    $baseUrlBox = $dialog.FindName('BaseUrlBox')
    $baseUrlHelp = $dialog.FindName('BaseUrlHelp')
    $apiKeyBox = $dialog.FindName('ApiKeyBox')
    $keyHelp = $dialog.FindName('KeyHelp')
    $detectButton = $dialog.FindName('DetectButton')
    $detectCombo = $dialog.FindName('DetectCombo')
    $testResult = $dialog.FindName('TestResult')
    $errorText = $dialog.FindName('ErrorText')
    $deleteButton = $dialog.FindName('DeleteButton')
    $saveButton = $dialog.FindName('SaveButton')

    $dialogTitle.Text = Get-ConfigProfileDialogText -Provider $Provider -Add:($Mode -eq 'Add')
    $baseUrlBox.Text = Get-ConfigProfileDefaultBaseUrl -Provider $Provider
    $baseUrlHelp.Text = '留空则使用默认地址。只支持 http / https。'
    $labelBox.Text = $suggestedLabel

    if ($isEdit) {
        $baseUrlBox.Text = [string]$existing.BaseUrl
        $keyHelp.Text = if ($existing.KeyHint) {
            '已保存密钥（••••{0}，Windows DPAPI 加密）。留空表示不修改。' -f $existing.KeyHint
        } else {
            '密钥仅加密保存在当前 Windows 用户下，不会写入日志或仓库。'
        }
    }
    else {
        $keyHelp.Text = '密钥仅加密保存在当前 Windows 用户下，不会写入日志或仓库。'
    }

    if ($isAuto) {
        $autoNotice.Text = '来自本机自动检测内容，无法在此处修改，请尝试切换配置'
        $autoNotice.Visibility = 'Visible'
        $labelBox.IsEnabled = $false
        $baseUrlBox.IsEnabled = $false
        $apiKeyBox.IsEnabled = $false
        $detectButton.IsEnabled = $false
        $deleteButton.Visibility = 'Collapsed'
        $saveButton.Visibility = 'Collapsed'
    }
    else {
        $autoNotice.Visibility = 'Collapsed'
        if ($isEdit) {
            $deleteButton.Visibility = 'Visible'
            $deleteButton.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
                $decision = [Windows.MessageBox]::Show(
                    ('确定要删除「{0}」吗？`n`n删除后会切回本机读取配置。' -f $existing.Label),
                    '删除配置',
                    [Windows.MessageBoxButton]::YesNo,
                    [Windows.MessageBoxImage]::Warning
                )
                if ($decision -ne [Windows.MessageBoxResult]::Yes) { return }
                try {
                    $removedProvider = Remove-ConfigProfile -Id $existing.Id
                    Set-ActiveConfigProfileId -Provider $removedProvider -ConfigId ''
                    Save-Settings
                    Sync-ProviderMenuState
                    if ($script:ActiveProvider -eq $removedProvider) {
                        Invoke-Refresh
                    }
                    $dialog.DialogResult = $true
                }
                catch {
                    $errorText.Text = '删除失败：' + $_.Exception.Message
                }
            }))
        }
    }

    $detectedCandidates = @()
    $detectButton.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
        $errorText.Text = ''
        $testResult.Text = '正在检测…'
        $detectedCandidates = @(Get-DetectedConfigCandidate -Provider $Provider)
        if ($detectedCandidates.Count -eq 0) {
            $testResult.Text = '本机没有检测到可用的地址与密钥。'
            $detectCombo.Visibility = 'Collapsed'
            return
        }
        $detectCombo.Items.Clear()
        foreach ($candidate in $detectedCandidates) {
            [void]$detectCombo.Items.Add(
                ('{0} · 来源 {1}' -f $candidate.Label, $candidate.SourceLabel)
            )
        }
        $detectCombo.SelectedIndex = 0
        $detectCombo.Visibility = 'Visible'
        $testResult.Text = '检测到 {0} 条，选中后可一键填入。' -f $detectedCandidates.Count
    }))

    $detectCombo.Add_SelectionChanged((New-RmfEventHandler -Kind Routed -Callback {
        $index = $detectCombo.SelectedIndex
        if ($index -lt 0 -or $index -ge $detectedCandidates.Count) { return }
        $candidate = $detectedCandidates[$index]
        if ($candidate.BaseUrl) { $baseUrlBox.Text = $candidate.BaseUrl }
        $apiKeyBox.Password = [string]$candidate.ApiKey
        if ([string]::IsNullOrWhiteSpace($labelBox.Text) -or
            $labelBox.Text -eq $suggestedLabel) {
            $labelBox.Text = $candidate.Label
        }
        $testResult.Text = '已填入：{0}' -f $candidate.SourceLabel
    }))

    $saveButton.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
        $errorText.Text = ''
        $label = $labelBox.Text.Trim()
        $baseUrl = $baseUrlBox.Text
        $apiKey = $apiKeyBox.Password.Trim()
        try {
            if ($isEdit) {
                $updated = Update-ConfigProfile `
                    -Id $existing.Id `
                    -Label $label `
                    -BaseUrl $baseUrl `
                    -ApiKey $apiKey
            }
            else {
                $updated = Add-ConfigProfile `
                    -Provider $Provider `
                    -Label $label `
                    -BaseUrl $baseUrl `
                    -ApiKey $apiKey
            }
            # Touch the profile so the list orders the one just used first.
            $entries = @(Get-StoredConfigProfileEntries -Refresh)
            $replaced = @(
                foreach ($entry in $entries) {
                    if ($entry.Id -eq $updated.Id) {
                        $entry.LastUsedAtUtc = [DateTimeOffset]::Now.ToString(
                            'o', [Globalization.CultureInfo]::InvariantCulture
                        )
                        $entry
                    } else { $entry }
                }
            )
            [void](Save-ConfigProfileDocument -Entries $replaced)
            [void](Set-ActiveConfigProfile `
                -Provider $Provider `
                -ConfigId $updated.Id `
                -Refresh)
            $dialog.DialogResult = $true
        }
        catch {
            $errorText.Text = $_.Exception.Message
        }
    }))

    $saved = $dialog.ShowDialog()
    return [bool]$saved
}

function Sync-ConfigProfileMenu {
    # Rebuilt on every open: the set of saved profiles can change while the
    # menu object itself lives for the whole session.
    $menuItem = $script:ConfigProfileMenuItem
    $trayItem = $script:TrayConfigProfileItem

    $provider = [string]$script:ActiveProvider
    if ($provider -notin (Get-ConfigProfileProviders)) {
        if ($menuItem) { $menuItem.Visibility = 'Collapsed' }
        if ($trayItem) { $trayItem.Visible = $false }
        if ($menuItem) { $menuItem.Items.Clear() }
        if ($trayItem) { $trayItem.DropDownItems.Clear() }
        return
    }
    if ($menuItem) { $menuItem.Visibility = 'Visible' }
    if ($trayItem) { $trayItem.Visible = $true }
    if ($menuItem) { $menuItem.Items.Clear() }
    if ($trayItem) { $trayItem.DropDownItems.Clear() }

    $entries = @(Get-ConfigProfileEntries -Provider $provider -Refresh)
    $activeId = Get-ActiveConfigProfileId -Provider $provider
    if ([string]::IsNullOrWhiteSpace($activeId)) {
        $activeId = Get-ConfigProfileAutoId -Provider $provider
    }
    $activeEntry = $entries | Where-Object { $_.Id -eq $activeId } | Select-Object -First 1
    $activeIsBroken = (
        $null -ne $activeEntry -and
        [string]$activeEntry.Kind -eq 'Manual' -and
        $null -eq (Get-ConfigProfileSecret -Profile $activeEntry)
    )
    $header = if ($activeIsBroken) {
        # Stored but undecryptable: name it so the user knows which one to fix.
        '当前配置：{0} · 密钥无法解密' -f $activeEntry.Label
    }
    elseif ($activeEntry -and $activeEntry.Available) {
        '当前配置：{0}' -f (Get-ConfigProfileDisplayText -Profile $activeEntry)
    }
    else {
        '当前配置：空'
    }
    if ($menuItem) { $menuItem.Header = $header }
    if ($trayItem) { $trayItem.Text = $header }

    foreach ($entry in $entries) {
        $capturedId = [string]$entry.Id
        $capturedProvider = $provider
        $display = Get-ConfigProfileDisplayText -Profile $entry
        $tip = if ([string]$entry.Kind -eq 'Auto') {
            '自动读取本机已保存的配置，无法在此处修改'
        } else {
            '点击切换到该配置'
        }

        if ($menuItem) {
            $item = New-Object Windows.Controls.MenuItem
            $item.Header = $display
            $item.IsCheckable = $true
            $item.IsChecked = ($capturedId -eq $activeId)
            $item.ToolTip = $tip
            $item.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
                [void](Set-ActiveConfigProfile `
                        -Provider $capturedProvider `
                        -ConfigId $capturedId `
                        -Refresh)
            }))
            [void]$menuItem.Items.Add($item)
        }
        if ($trayItem) {
            $trayEntry = New-Object System.Windows.Forms.ToolStripMenuItem
            $trayEntry.Text = $display
            $trayEntry.CheckOnClick = $false
            $trayEntry.Checked = ($capturedId -eq $activeId)
            $trayEntry.ToolTipText = $tip
            $trayEntry.Add_Click((New-RmfEventHandler -Kind Event -Callback {
                Show-ExistingWindow
                [void](Set-ActiveConfigProfile `
                        -Provider $capturedProvider `
                        -ConfigId $capturedId `
                        -Refresh)
            }))
            [void]$trayItem.DropDownItems.Add($trayEntry)
        }
    }

    $canEdit = ($null -ne $activeEntry -and [string]$activeEntry.Kind -ne 'Auto')
    if ($menuItem) {
        [void]$menuItem.Items.Add((New-Object Windows.Controls.Separator))
    }
    if ($trayItem) {
        [void]$trayItem.DropDownItems.Add(
            (New-Object System.Windows.Forms.ToolStripSeparator)
        )
    }

    $addItem = New-Object Windows.Controls.MenuItem
    $addItem.Header = '添加配置…'
    $addItem.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
        if (Show-ConfigProfileDialog -Provider $provider -Mode 'Add') {
            Sync-ProviderMenuState
        }
    }))
    if ($menuItem) { [void]$menuItem.Items.Add($addItem) }

    $trayAdd = New-Object System.Windows.Forms.ToolStripMenuItem
    $trayAdd.Text = '添加配置…'
    $trayAdd.Add_Click((New-RmfEventHandler -Kind Event -Callback {
        Show-ExistingWindow
        if (Show-ConfigProfileDialog -Provider $provider -Mode 'Add') {
            Sync-ProviderMenuState
        }
    }))
    if ($trayItem) { [void]$trayItem.DropDownItems.Add($trayAdd) }

    $editItem = New-Object Windows.Controls.MenuItem
    $editItem.Header = '编辑当前配置…'
    $editItem.IsEnabled = $canEdit
    $trayEdit = New-Object System.Windows.Forms.ToolStripMenuItem
    $trayEdit.Text = '编辑当前配置…'
    $trayEdit.Enabled = $canEdit
    if ($canEdit) {
        $editTargetId = [string]$activeEntry.Id
        $editItem.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
            if (Show-ConfigProfileDialog `
                    -Provider $provider `
                    -Mode 'Edit' `
                    -ConfigId $editTargetId) {
                Sync-ProviderMenuState
            }
        }))
        $trayEdit.Add_Click((New-RmfEventHandler -Kind Event -Callback {
            Show-ExistingWindow
            if (Show-ConfigProfileDialog `
                    -Provider $provider `
                    -Mode 'Edit' `
                    -ConfigId $editTargetId) {
                Sync-ProviderMenuState
            }
        }))
    }
    if ($menuItem) { [void]$menuItem.Items.Add($editItem) }
    if ($trayItem) { [void]$trayItem.DropDownItems.Add($trayEdit) }
}

function Show-BudgetBaselineDialog {
    $provider = [string]$script:ActiveProvider
    if ($provider -notin (Get-UsageAlertProviderIds)) {
        $provider = 'Codex'
    }
    $settings = Get-UsageAlertSettings -ProviderId $provider

    $fiveHourRow = ''
    $weeklyRow = ''
    if ($provider -eq 'DeepSeek') {
        $fiveHourRow = @'
        <StackPanel Grid.Row="2" Margin="0,14,0,0">
            <TextBlock Text="预算基准（元）" FontSize="12" FontWeight="SemiBold" Foreground="#4E5750"/>
            <TextBox x:Name="BudgetAmountBox" Height="34" Margin="0,7,0,0" Padding="9,6"
                     BorderBrush="#D8DDD7" Background="White"
                     AutomationProperties.Name="预算基准"/>
            <TextBlock Margin="0,6,0,0" FontSize="10" Foreground="#7B847D" TextWrapping="Wrap"
                       Text="本月实际花费超过该金额时提醒。留空表示不按预算提醒。"/>
        </StackPanel>
'@
    }
    else {
        $fiveHourRow = @'
        <StackPanel Grid.Row="2" Margin="0,14,0,0">
            <TextBlock Text="5 小时预算（%）" FontSize="12" FontWeight="SemiBold" Foreground="#4E5750"/>
            <TextBox x:Name="FiveHourBox" Height="34" Margin="0,7,0,0" Padding="9,6"
                     BorderBrush="#D8DDD7" Background="White"
                     AutomationProperties.Name="5 小时预算"/>
        </StackPanel>
        <StackPanel Grid.Row="3" Margin="0,14,0,0">
            <TextBlock Text="每周预算（%）" FontSize="12" FontWeight="SemiBold" Foreground="#4E5750"/>
            <TextBox x:Name="WeeklyBox" Height="34" Margin="0,7,0,0" Padding="9,6"
                     BorderBrush="#D8DDD7" Background="White"
                     AutomationProperties.Name="每周预算"/>
        </StackPanel>
'@
    }

    [xml]$dialogXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="预算基准"
        Width="430"
        Height="420"
        ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner"
        ShowInTaskbar="False"
        Background="#FCFBF8"
        FontFamily="Microsoft YaHei UI">
    <Grid x:Name="SettingsRoot" Background="#FCFBF8">
      <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="38"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="预算基准" FontSize="18" FontWeight="SemiBold" Foreground="#343A35"/>
        <TextBlock x:Name="ProviderText" Grid.Row="1" Margin="0,8,0,0"
                   FontSize="11" Foreground="#5C665E" TextWrapping="Wrap"/>
$fiveHourRow
$weeklyRow
        <TextBlock x:Name="ErrorText" Grid.Row="4" Margin="0,10,0,0"
                   Foreground="#A65B52" FontSize="11" TextWrapping="Wrap"/>
        <Grid Grid.Row="5">
            <Button x:Name="CancelButton" Width="82" Height="34" HorizontalAlignment="Right"
                    Margin="0,0,92,0" Content="取消" IsCancel="True"/>
            <Button x:Name="SaveButton" Width="82" Height="34" HorizontalAlignment="Right"
                    Content="保存" IsDefault="True" Background="#E9F0EA"
                    BorderBrush="#BFCDBF" Foreground="#344A3B"/>
        </Grid>
      </Grid>
    </Grid>
</Window>
"@
    $dialogReader = New-Object System.Xml.XmlNodeReader $dialogXaml
    $dialog = [Windows.Markup.XamlReader]::Load($dialogReader)
    $dialog.Owner = $window
    $providerText = $dialog.FindName('ProviderText')
    $errorText = $dialog.FindName('ErrorText')
    $saveButton = $dialog.FindName('SaveButton')
    $providerText.Text = '当前数据源：{0}。超出预算时提醒一次，窗口重置后可再次提醒。' -f $provider

    if ($provider -eq 'DeepSeek') {
        $amountBox = $dialog.FindName('BudgetAmountBox')
        if ([double]$settings.BudgetAmount -gt 0) {
            $amountBox.Text = ([double]$settings.BudgetAmount).ToString('0.##')
        }
    }
    else {
        $fiveHourBox = $dialog.FindName('FiveHourBox')
        $weeklyBox = $dialog.FindName('WeeklyBox')
        if ([double]$settings.BudgetPercentFiveHour -gt 0) {
            $fiveHourBox.Text = ([double]$settings.BudgetPercentFiveHour).ToString('0.##')
        }
        if ([double]$settings.BudgetPercentWeekly -gt 0) {
            $weeklyBox.Text = ([double]$settings.BudgetPercentWeekly).ToString('0.##')
        }
    }

    $saveButton.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
        $errorText.Text = ''
        try {
            if ($provider -eq 'DeepSeek') {
                $amount = 0.0
                $text = $amountBox.Text.Trim()
                if (-not [string]::IsNullOrWhiteSpace($text)) {
                    $parsed = [double]::TryParse(
                        $text,
                        [Globalization.NumberStyles]::Number,
                        [Globalization.CultureInfo]::InvariantCulture,
                        [ref]$amount
                    )
                    if (-not $parsed -or $amount -le 0) {
                        throw '预算基准需要是大于 0 的金额，或留空不设置。'
                    }
                }
                [void](Set-UsageAlertSettings `
                        -ProviderId 'DeepSeek' `
                        -BudgetAmount $amount)
            }
            else {
                $fiveHour = 0.0
                $weekly = 0.0
                $fiveHourText = $fiveHourBox.Text.Trim()
                if (-not [string]::IsNullOrWhiteSpace($fiveHourText)) {
                    $parsed = [double]::TryParse(
                        $fiveHourText,
                        [Globalization.NumberStyles]::Number,
                        [Globalization.CultureInfo]::InvariantCulture,
                        [ref]$fiveHour
                    )
                    if (-not $parsed -or $fiveHour -le 0 -or $fiveHour -gt 100) {
                        throw '5 小时预算需要是 1–100 之间的数字，或留空不设置。'
                    }
                }
                $weeklyText = $weeklyBox.Text.Trim()
                if (-not [string]::IsNullOrWhiteSpace($weeklyText)) {
                    $parsed = [double]::TryParse(
                        $weeklyText,
                        [Globalization.NumberStyles]::Number,
                        [Globalization.CultureInfo]::InvariantCulture,
                        [ref]$weekly
                    )
                    if (-not $parsed -or $weekly -le 0 -or $weekly -gt 100) {
                        throw '每周预算需要是 1–100 之间的数字，或留空不设置。'
                    }
                }
                [void](Set-UsageAlertSettings `
                        -ProviderId $provider `
                        -BudgetPercentFiveHour $fiveHour `
                        -BudgetPercentWeekly $weekly)
            }
            $dialog.DialogResult = $true
        }
        catch {
            $errorText.Text = $_.Exception.Message
        }
    }))

    return [bool]$dialog.ShowDialog()
}

function Show-OnboardingDialog {
    # First run only: explains that nothing is preselected and where to go next,
    # instead of leaving a blank window with no hint.
    [xml]$dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="欢迎使用"
        Width="470"
        Height="300"
        ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen"
        ShowInTaskbar="False"
        Background="#FCFBF8"
        FontFamily="Microsoft YaHei UI">
    <Grid x:Name="OnboardingRoot" Background="#FCFBF8">
      <Grid Margin="26">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="38"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="欢迎使用余量悬浮窗" FontSize="18" FontWeight="SemiBold" Foreground="#343A35"/>
        <TextBlock Grid.Row="1" Margin="0,14,0,0" FontSize="12" Foreground="#4E5750" TextWrapping="Wrap"
                   Text="1. 默认不会预选数据源，请从「数据源」中选择要监控的对象。"/>
        <TextBlock Grid.Row="2" Margin="0,10,0,0" FontSize="12" Foreground="#4E5750" TextWrapping="Wrap"
                   Text="2. DeepSeek 与 Kimi Code 可以从「当前配置 ▾ → 添加配置…」自填接口地址与密钥。"/>
        <TextBlock Grid.Row="3" Margin="0,10,0,0" FontSize="12" Foreground="#4E5750" TextWrapping="Wrap"
                   Text="3. 也可用「更多 ▾ → 检测本机已有配置」自动读取本机已保存的地址与密钥。"/>
        <TextBlock Grid.Row="4" Margin="0,14,0,0" FontSize="11" Foreground="#7B847D" TextWrapping="Wrap"
                   Text="本对话框只会出现一次。"/>
        <Button Grid.Row="5" Width="82" Height="34" HorizontalAlignment="Right"
                Content="知道了" IsDefault="True" Background="#E9F0EA"
                BorderBrush="#BFCDBF" Foreground="#344A3B"
                x:Name="ConfirmButton"/>
      </Grid>
    </Grid>
</Window>
'@
    $dialogReader = New-Object System.Xml.XmlNodeReader $dialogXaml
    $dialog = [Windows.Markup.XamlReader]::Load($dialogReader)
    $confirmButton = $dialog.FindName('ConfirmButton')
    $confirmButton.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
        $dialog.DialogResult = $true
    }))
    [void]$dialog.ShowDialog()
}