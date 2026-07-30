$script:TrayAppIcon = New-TrayAppIcon
$script:TrayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayOpenItem = New-Object System.Windows.Forms.ToolStripMenuItem
$trayOpenItem.Text = '打开详情'
$trayOpenItem.Add_Click((New-RmfEventHandler -Kind Event -Callback {
    Show-ExistingWindow
    Set-ExpandedState -Expanded $true
}))
$trayRefreshItem = New-Object System.Windows.Forms.ToolStripMenuItem
$trayRefreshItem.Text = '立即刷新'
$trayRefreshItem.Add_Click((New-RmfEventHandler -Kind Event -Callback {
    Show-ExistingWindow
    Invoke-Refresh
}))
$traySourceItem = New-Object System.Windows.Forms.ToolStripMenuItem
$traySourceItem.Text = '数据源'
$script:TrayCodexSourceItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:TrayCodexSourceItem.Text = 'Codex'
$script:TrayCodexSourceItem.Add_Click((New-RmfEventHandler -Kind Event -Callback {
    Set-ActiveProvider -Provider 'Codex' -Refresh
}))
$script:TrayDeepSeekSourceItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:TrayDeepSeekSourceItem.Text = 'DeepSeek'
$script:TrayDeepSeekSourceItem.Add_Click((New-RmfEventHandler -Kind Event -Callback {
    Set-ActiveProvider -Provider 'DeepSeek'
    $credential = Get-DeepSeekCredential
    if ($credential.ApiKey) {
        Invoke-Refresh
    }
    else {
        Show-ExistingWindow
        $saved = Show-DeepSeekSettings
        if (-not $saved) { Invoke-Refresh }
        Sync-ProviderMenuState
    }
}))
[void]$traySourceItem.DropDownItems.Add($script:TrayCodexSourceItem)
[void]$traySourceItem.DropDownItems.Add($script:TrayDeepSeekSourceItem)
$script:TrayCodexOfficialAccessItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:TrayCodexOfficialAccessItem.Text = 'Codex 官方接口（读取登录凭据）'
$script:TrayCodexOfficialAccessItem.CheckOnClick = $true
$script:TrayCodexOfficialAccessItem.Add_Click((New-RmfEventHandler -Kind Event -Callback {
    $enabled = [bool]$script:TrayCodexOfficialAccessItem.Checked
    [void](Set-CodexOfficialAccess -Enabled $enabled -Confirm:$enabled)
}))
$script:TrayDeepSeekSettingsItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:TrayDeepSeekSettingsItem.Text = 'DeepSeek 设置…'
$script:TrayDeepSeekSettingsItem.Add_Click((New-RmfEventHandler -Kind Event -Callback {
    Show-ExistingWindow
    [void](Show-DeepSeekSettings)
}))
$script:TrayTopmostItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:TrayTopmostItem.Text = '始终置顶'
$script:TrayTopmostItem.CheckOnClick = $true
$script:TrayTopmostItem.Checked = $window.Topmost
$script:TrayTopmostItem.Add_Click((New-RmfEventHandler -Kind Event -Callback {
    $window.Topmost = $script:TrayTopmostItem.Checked
    $topmostMenu.IsChecked = $window.Topmost
    Save-Settings
}))
$script:TrayLowAlertsItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:TrayLowAlertsItem.Text = Get-LowRemainingAlertMenuText
$script:TrayLowAlertsItem.CheckOnClick = $true
$script:TrayLowAlertsItem.Checked = $script:LowRemainingAlertsEnabled
$script:TrayLowAlertsItem.Add_Click((New-RmfEventHandler -Kind Event -Callback {
    Set-LowRemainingAlertsEnabled -Enabled $script:TrayLowAlertsItem.Checked
}))
$script:TrayLowAlertThresholdItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:TrayLowAlertThresholdItem.Text = Get-UsageAlertSettingsMenuText
$script:TrayLowAlertThresholdItem.Add_Click((
    New-RmfEventHandler -Kind Event -Callback {
        Show-ExistingWindow
        [void](Show-LowRemainingAlertSettings)
    }
))
$script:TrayEdgeDockItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:TrayEdgeDockItem.Text = '贴边隐藏'
$script:TrayEdgeDockItem.CheckOnClick = $true
$script:TrayEdgeDockItem.Checked = $script:EdgeDockEnabled
$script:TrayEdgeDockItem.ToolTipText = '拖到屏幕左侧或右侧后，自动收为竖向能量条'
$script:TrayEdgeDockItem.Add_Click((New-RmfEventHandler -Kind Event -Callback {
    Set-EdgeDockEnabled -Enabled $script:TrayEdgeDockItem.Checked
}))
$trayDataItem = New-Object System.Windows.Forms.ToolStripMenuItem
$trayDataItem.Text = '数据与诊断'
$trayDiagnosticsItem = New-Object System.Windows.Forms.ToolStripMenuItem
$trayDiagnosticsItem.Text = '查看脱敏诊断…'
$trayDiagnosticsItem.Add_Click((New-RmfEventHandler -Kind Event -Callback {
    Show-ExistingWindow
    Show-RuntimeDiagnostics
}))
$trayExportHistoryItem = New-Object System.Windows.Forms.ToolStripMenuItem
$trayExportHistoryItem.Text = '导出使用记录…'
$trayExportHistoryItem.Add_Click((New-RmfEventHandler -Kind Event -Callback {
    Show-ExistingWindow
    Show-UsageHistoryExportDialog
}))
$trayImportHistoryItem = New-Object System.Windows.Forms.ToolStripMenuItem
$trayImportHistoryItem.Text = '导入使用记录…'
$trayImportHistoryItem.Add_Click((New-RmfEventHandler -Kind Event -Callback {
    Show-ExistingWindow
    Show-UsageHistoryImportDialog
}))
[void]$trayDataItem.DropDownItems.Add($trayDiagnosticsItem)
[void]$trayDataItem.DropDownItems.Add(
    (New-Object System.Windows.Forms.ToolStripSeparator)
)
[void]$trayDataItem.DropDownItems.Add($trayExportHistoryItem)
[void]$trayDataItem.DropDownItems.Add($trayImportHistoryItem)
$trayStartupItem = New-Object System.Windows.Forms.ToolStripMenuItem
$trayStartupItem.Text = '设置开机启动'
$trayStartupClickHandler = {
    param($sender, $eventArgs)
    [void](Set-StartupMode -Mode ([string]$sender.Tag))
}
foreach ($startupOption in @(
    [pscustomobject]@{ Mode = 'Off'; Header = '关闭' },
    [pscustomobject]@{ Mode = 'Task'; Header = '计划任务（推荐）' },
    [pscustomobject]@{ Mode = 'Registry'; Header = '注册表（兼容）' },
    [pscustomobject]@{ Mode = 'StartupFolder'; Header = '启动文件夹（备用）' }
)) {
    $trayStartupOption = New-Object System.Windows.Forms.ToolStripMenuItem
    $trayStartupOption.Text = $startupOption.Header
    $trayStartupOption.Tag = $startupOption.Mode
    $trayStartupOption.Add_Click((
        New-RmfEventHandler -Kind Event -Callback $trayStartupClickHandler
    ))
    $script:TrayStartupItems[$startupOption.Mode] = $trayStartupOption
    [void]$trayStartupItem.DropDownItems.Add($trayStartupOption)
}
$trayStartupServiceItem = New-Object System.Windows.Forms.ToolStripMenuItem
$trayStartupServiceItem.Text = 'Windows 服务（不适用于桌面窗口）'
$trayStartupServiceItem.Enabled = $false
$trayStartupServiceItem.ToolTipText = '服务运行在隔离会话中，无法显示悬浮窗'
[void]$trayStartupItem.DropDownItems.Add(
    (New-Object System.Windows.Forms.ToolStripSeparator)
)
[void]$trayStartupItem.DropDownItems.Add($trayStartupServiceItem)
$traySeparator = New-Object System.Windows.Forms.ToolStripSeparator
$trayExitItem = New-Object System.Windows.Forms.ToolStripMenuItem
$trayExitItem.Text = '退出'
$trayExitItem.Add_Click((New-RmfEventHandler -Kind Event -Callback {
    Save-Settings
    $window.Close()
}))
[void]$script:TrayMenu.Items.Add($trayOpenItem)
[void]$script:TrayMenu.Items.Add($trayRefreshItem)
[void]$script:TrayMenu.Items.Add($traySourceItem)
[void]$script:TrayMenu.Items.Add($script:TrayCodexOfficialAccessItem)
[void]$script:TrayMenu.Items.Add($script:TrayDeepSeekSettingsItem)
[void]$script:TrayMenu.Items.Add($script:TrayTopmostItem)
[void]$script:TrayMenu.Items.Add($script:TrayLowAlertsItem)
[void]$script:TrayMenu.Items.Add($script:TrayLowAlertThresholdItem)
[void]$script:TrayMenu.Items.Add($script:TrayEdgeDockItem)
[void]$script:TrayMenu.Items.Add($trayDataItem)
[void]$script:TrayMenu.Items.Add($trayStartupItem)
[void]$script:TrayMenu.Items.Add($traySeparator)
[void]$script:TrayMenu.Items.Add($trayExitItem)

$script:TrayNotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:TrayNotifyIcon.Icon = $script:TrayAppIcon
$script:TrayNotifyIcon.Text = 'Remaining Margin Float · 单击打开详情'
$script:TrayNotifyIcon.ContextMenuStrip = $script:TrayMenu
$script:TrayNotifyIcon.Add_MouseClick((New-RmfEventHandler -Kind FormsMouse -Callback {
    param($sender, $eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Show-ExistingWindow
        Set-ExpandedState -Expanded $true
    }
}))
$script:TrayNotifyIcon.Visible = $true
Sync-ProviderMenuState
Sync-EdgeDockMenuState
Sync-StartupMenuState
Sync-LowAlertMenuState

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick((New-RmfEventHandler -Kind Event -Callback {
    Invoke-RefreshTimerTick
}))
$timer.Start()

$activationTimer = New-Object Windows.Threading.DispatcherTimer
$activationTimer.Interval = [TimeSpan]::FromMilliseconds(180)
$activationTimer.Add_Tick((New-RmfEventHandler -Kind Event -Callback {
    if ($script:ActivationEvent -and $script:ActivationEvent.WaitOne(0)) {
        Show-ExistingWindow
    }
}))
$activationTimer.Start()

if ($releaseGuiCheck) {
    $script:RmfGuiCheckInnerHandler = New-RmfEventHandler `
        -Kind Event `
        -Callback {
            $script:RmfGuiCheckPassed = (
                $null -ne $script:LowAlertThresholdMenuItem -and
                $null -ne $script:TrayLowAlertThresholdItem -and
                [string]$script:TrayLowAlertsItem.Text -eq
                    (Get-LowRemainingAlertMenuText)
            )
            $savedOfficialAccess = $script:CodexOfficialAccessEnabled
            try {
                $script:CodexOfficialAccessEnabled = $false
                Invoke-Refresh
                $script:RmfRefreshDataProbePassed = (
                    $script:LastSnapshot -and
                    [string]$WindowLabel.Text -ne '读取失败'
                )
                $script:RmfRefreshDataProbeDetails = (
                    'label={0}; source={1}; bridgeFailures={2}' -f
                    [string]$WindowLabel.Text,
                    [string]$SourceText.Text,
                    (Get-RmfEventBridgeFailureCount)
                )
            }
            finally {
                $script:CodexOfficialAccessEnabled = $savedOfficialAccess
            }
            Set-RefreshBusy -Busy $true
        }
    $window.Dispatcher.BeginInvoke(
        [Windows.Threading.DispatcherPriority]::Background,
        (New-RmfAction -Callback {
            $script:RmfGuiCheckInnerHandler.Invoke(
                $null,
                [EventArgs]::Empty
            )
        })
    ) | Out-Null
}

if ($CheckRefreshCoordinator) {
    $savedOfficialAccess = $script:CodexOfficialAccessEnabled
    try {
        $script:ActiveProvider = 'Codex'
        $script:CodexOfficialAccessEnabled = $false
        $script:AppContext.Refresh.IsBusy = $false

        $manualStopwatch = [Diagnostics.Stopwatch]::StartNew()
        Invoke-Refresh
        $manualStopwatch.Stop()
        $manualLabel = [string]$WindowLabel.Text
        $manualSource = [string]$SourceText.Text
        $manualRemaining = [int]$script:AppContext.Refresh.RemainingSeconds

        $script:AppContext.Refresh.NextAt =
            [DateTimeOffset]::Now.AddSeconds(-1)
        $script:AppContext.Refresh.RemainingSeconds = 0
        Invoke-RefreshTimerTick
        $automaticLabel = [string]$WindowLabel.Text
        $automaticRemaining =
            [int]$script:AppContext.Refresh.RemainingSeconds
        $automaticText = [string]$AutoRefreshText.Text

        $script:AppContext.Refresh.NextAt =
            [DateTimeOffset]::Now.AddSeconds(3)
        Invoke-RefreshTimerTick
        $countdownBefore =
            [int]$script:AppContext.Refresh.RemainingSeconds
        Start-Sleep -Milliseconds 1100
        Invoke-RefreshTimerTick
        $countdownAfter =
            [int]$script:AppContext.Refresh.RemainingSeconds

        [pscustomobject]@{
            ManualRefreshSucceeded = (
                $script:LastSnapshot -and
                $manualLabel -ne '读取失败'
            )
            AutomaticRefreshSucceeded = (
                $script:LastSnapshot -and
                $automaticLabel -ne '读取失败'
            )
            ZeroSecondStateRecovered = (
                $automaticRemaining -gt 0 -and
                $automaticText -notlike '0 秒*'
            )
            CountdownAdvanced = $countdownAfter -lt $countdownBefore
            ManualLabel = $manualLabel
            ManualSource = $manualSource
            ManualRemaining = $manualRemaining
            ManualElapsedMs = $manualStopwatch.ElapsedMilliseconds
            AutomaticLabel = $automaticLabel
            AutomaticRemaining = $automaticRemaining
            AutomaticText = $automaticText
            CountdownBefore = $countdownBefore
            CountdownAfter = $countdownAfter
        } | ConvertTo-Json
    }
    finally {
        $script:CodexOfficialAccessEnabled = $savedOfficialAccess
        $timer.Stop()
        $activationTimer.Stop()
        $window.Close()
    }
    $script:RmfStopLoading = $true
    return
}

$window.Add_Closing((New-RmfEventHandler -Kind Cancel -Callback {
    $script:IsClosing = $true
    if ($script:EdgeRevealTimer) { $script:EdgeRevealTimer.Stop() }
    if ($script:EdgeHideTimer) { $script:EdgeHideTimer.Stop() }
    $timer.Stop()
    $activationTimer.Stop()
    if ($script:DeepSeekHttpClient) {
        $script:DeepSeekHttpClient.CancelPendingRequests()
        $script:DeepSeekHttpClient.Dispose()
        $script:DeepSeekHttpClient = $null
    }
    if (
        $script:AppContext.Refresh.Codex.RequestTask -or
        $script:AppContext.Refresh.Codex.RetryAfter
    ) {
        Cancel-CodexRefresh
    }
    if ($script:CodexHttpClient) {
        $script:CodexHttpClient.CancelPendingRequests()
        $script:CodexHttpClient.Dispose()
        $script:CodexHttpClient = $null
    }
    if ($script:AppContext.Refresh.DeepSeek.Request) {
        $script:AppContext.Refresh.DeepSeek.Request.Dispose()
        $script:AppContext.Refresh.DeepSeek.Request = $null
    }
    Save-Settings
    if ($script:TrayNotifyIcon) {
        $script:TrayNotifyIcon.Visible = $false
        $script:TrayNotifyIcon.Dispose()
        $script:TrayNotifyIcon = $null
    }
    if ($script:TrayMenu) {
        $script:TrayMenu.Dispose()
        $script:TrayMenu = $null
    }
    if ($script:TrayAppIcon) {
        $script:TrayAppIcon.Dispose()
        $script:TrayAppIcon = $null
    }
    if ($script:ActivationEvent) {
        $script:ActivationEvent.Dispose()
    }
    if ($script:AppMutex) {
        try { $script:AppMutex.ReleaseMutex() } catch {}
        $script:AppMutex.Dispose()
    }
    Stop-RmfEventBridge
}))

$embeddedHostOwnsMessageLoop = Get-Variable `
    -Name 'RmfHostOwnsMessageLoop' `
    -ErrorAction SilentlyContinue
if (
    -not $embeddedHostOwnsMessageLoop -or
    -not [bool]$embeddedHostOwnsMessageLoop.Value
) {
    [void]$window.ShowDialog()
}
