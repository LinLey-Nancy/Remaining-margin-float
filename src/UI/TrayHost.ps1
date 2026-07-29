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
$script:TrayLowAlertsItem.Text = '低余量提醒（≤20%）'
$script:TrayLowAlertsItem.CheckOnClick = $true
$script:TrayLowAlertsItem.Checked = $script:LowRemainingAlertsEnabled
$script:TrayLowAlertsItem.Add_Click((New-RmfEventHandler -Kind Event -Callback {
    Set-LowRemainingAlertsEnabled -Enabled $script:TrayLowAlertsItem.Checked
}))
$script:TrayEdgeDockItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:TrayEdgeDockItem.Text = '贴边隐藏'
$script:TrayEdgeDockItem.CheckOnClick = $true
$script:TrayEdgeDockItem.Checked = $script:EdgeDockEnabled
$script:TrayEdgeDockItem.ToolTipText = '拖到屏幕左侧或右侧后，自动收为温度计进度条'
$script:TrayEdgeDockItem.Add_Click((New-RmfEventHandler -Kind Event -Callback {
    Set-EdgeDockEnabled -Enabled $script:TrayEdgeDockItem.Checked
}))
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
[void]$script:TrayMenu.Items.Add($script:TrayEdgeDockItem)
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
    Complete-CodexRefresh
    Complete-DeepSeekRefresh
    if (-not $script:IsRefreshing) {
        $script:RefreshRemaining--
        if ($script:RefreshRemaining -le 0) {
            Invoke-Refresh
        }
    }
    $AutoRefreshText.Text = '{0} 秒后自动刷新' -f [Math]::Max(0, $script:RefreshRemaining)
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
            $script:RmfGuiCheckPassed = $true
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
    if ($script:CodexRequestTask) {
        Cancel-CodexRefresh
    }
    if ($script:CodexHttpClient) {
        $script:CodexHttpClient.CancelPendingRequests()
        $script:CodexHttpClient.Dispose()
        $script:CodexHttpClient = $null
    }
    if ($script:DeepSeekRequest) {
        $script:DeepSeekRequest.Dispose()
        $script:DeepSeekRequest = $null
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
