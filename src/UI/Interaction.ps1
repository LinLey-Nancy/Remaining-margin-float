if ($CheckStartup) {
    $launchSpec = Get-StartupLaunchSpec
    [pscustomobject]@{
        Mode = Get-StartupMode
        FilePath = $launchSpec.FilePath
        Arguments = $launchSpec.Arguments
        Source = $launchSpec.Source
        CommandLine = ConvertTo-StartupCommandLine -LaunchSpec $launchSpec
    } | ConvertTo-Json
    $window.Close()
    $script:RmfStopLoading = $true
    return
}

$script:IsRestoringSettings = $true
Restore-Settings
if (-not $isDiagnosticRun) {
    Sync-PackagedStartupLauncher
}
$script:StartupMode = Get-StartupMode
Set-ExpandedState -Expanded $script:IsExpanded -Immediate -DeferEdgeDock
$script:IsRestoringSettings = $false
[void](Restore-LatestUsageState)

$script:AppContext.Refresh.IsBusy = $false
Reset-RefreshCountdown
$script:InitialRefreshQueued = $false
$script:MouseDownPoint = $null
$script:Dragging = $false
$script:DragOriginEdgeSide = $null
$script:DragStartScreenPoint = $null
$script:EdgeHideTimer = New-Object Windows.Threading.DispatcherTimer
$script:EdgeHideTimer.Interval = [TimeSpan]::FromMilliseconds(140)
$script:EdgeHideTimer.Add_Tick((New-RmfEventHandler -Kind Event -Callback {
    $script:EdgeHideTimer.Stop()
    Hide-EdgeDockIfPointerAway
}))
$script:EdgeRevealTimer = New-Object Windows.Threading.DispatcherTimer
$script:EdgeRevealTimer.Interval = [TimeSpan]::FromMilliseconds(70)
$script:EdgeRevealTimer.Add_Tick((New-RmfEventHandler -Kind Event -Callback {
    $script:EdgeRevealTimer.Stop()
    if (
        (
            $window.IsMouseOver -or
            $UltraCompactPanel.IsMouseOver -or
            $script:IsPointerOverSurface
        ) -and
        $script:EdgeDockSide -and
        -not $script:IsExpanded -and
        -not $script:IsEdgeRevealed
    ) {
        Set-HoverState -Hovering $true
        Set-EdgeDockReveal -Revealed $true
    }
}))

function Complete-WindowDrag {
    param(
        [string]$OriginEdgeSide,
        $StartScreenPoint
    )

    $endScreenPoint = [System.Windows.Forms.Cursor]::Position
    $draggedInward = if (-not $OriginEdgeSide -or -not $StartScreenPoint) {
        $false
    }
    elseif ($OriginEdgeSide -eq 'Left') {
        ($endScreenPoint.X - $StartScreenPoint.X) -ge 4
    }
    else {
        ($StartScreenPoint.X - $endScreenPoint.X) -ge 4
    }

    if ($draggedInward) {
        Save-Settings
        return
    }
    if (-not (Try-DockWindowAfterMove)) {
        Save-Settings
    }
}

if (-not $CheckTransitions -and -not $releaseGuiCheck) {
    $window.Add_Loaded((New-RmfEventHandler -Kind Routed -Callback {
        Ensure-WindowVisible
        $window.Activate() | Out-Null
    }))
    $window.Add_ContentRendered((New-RmfEventHandler -Kind Event -Callback {
        if (-not $script:InitialRefreshQueued) {
            $script:InitialRefreshQueued = $true
            $window.Dispatcher.BeginInvoke(
                [Windows.Threading.DispatcherPriority]::Background,
                (New-RmfAction -Callback { Invoke-Refresh })
            ) | Out-Null
        }
    }))
}

$window.Add_LocationChanged((New-RmfEventHandler -Kind Event -Callback {
    if (
        $script:EdgeDockSide -and
        -not $script:IsExpanded -and
        -not $script:Dragging
    ) {
        [void](Sync-EdgeDockEnvironment)
    }
}))

$window.Add_MouseEnter((New-RmfEventHandler -Kind Mouse -Callback {
    $script:EdgeHideTimer.Stop()
    $script:IsPointerOverSurface = $true
    if (
        $script:EdgeDockSide -and
        -not $script:IsExpanded -and
        -not $script:IsEdgeRevealed
    ) {
        $script:EdgeRevealTimer.Stop()
        $script:EdgeRevealTimer.Start()
    }
    else {
        Set-HoverState -Hovering $true
    }
}))
$window.Add_MouseLeave((New-RmfEventHandler -Kind Mouse -Callback {
    $script:EdgeRevealTimer.Stop()
    Set-HoverState -Hovering $false
    Request-EdgeDockHide
}))
$UltraCompactPanel.Add_MouseEnter((New-RmfEventHandler -Kind Mouse -Callback {
    $script:EdgeHideTimer.Stop()
    $script:IsPointerOverSurface = $true
    if (
        $script:EdgeDockSide -and
        -not $script:IsExpanded -and
        -not $script:IsEdgeRevealed
    ) {
        $script:EdgeRevealTimer.Stop()
        $script:EdgeRevealTimer.Start()
    }
}))

$UltraCompactPanel.Add_PreviewMouseLeftButtonDown((New-RmfEventHandler -Kind MouseButton -Callback {
    param($sender, $eventArgs)
    if (-not $script:EdgeDockSide -or $script:IsExpanded) { return }

    $originEdgeSide = $script:EdgeDockSide
    $startScreenPoint = [System.Windows.Forms.Cursor]::Position
    $script:EdgeRevealTimer.Stop()
    $script:EdgeHideTimer.Stop()
    $script:Dragging = $true
    Clear-EdgeDock
    try {
        $window.DragMove()
    }
    catch {}
    Complete-WindowDrag `
        -OriginEdgeSide $originEdgeSide `
        -StartScreenPoint $startScreenPoint
    $script:Dragging = $false
    $script:MouseDownPoint = $null
    $eventArgs.Handled = $true
}))

$CompactHit.Add_PreviewMouseLeftButtonDown((New-RmfEventHandler -Kind MouseButton -Callback {
    param($sender, $eventArgs)
    $script:MouseDownPoint = $eventArgs.GetPosition($window)
    $script:DragOriginEdgeSide = $script:EdgeDockSide
    $script:DragStartScreenPoint = [System.Windows.Forms.Cursor]::Position
    $script:Dragging = $false
    $CompactHit.CaptureMouse() | Out-Null
}))

$CompactHit.Add_PreviewMouseMove((New-RmfEventHandler -Kind Mouse -Callback {
    param($sender, $eventArgs)
    if (-not $script:IsExpanded -and $script:MouseDownPoint -and $eventArgs.LeftButton -eq [Windows.Input.MouseButtonState]::Pressed) {
        $point = $eventArgs.GetPosition($window)
        $distance = [Math]::Abs($point.X - $script:MouseDownPoint.X) + [Math]::Abs($point.Y - $script:MouseDownPoint.Y)
        if ($distance -gt 5) {
            $script:Dragging = $true
            $CompactHit.ReleaseMouseCapture()
            Clear-EdgeDock
            try { $window.DragMove() } catch {}
            Complete-WindowDrag `
                -OriginEdgeSide $script:DragOriginEdgeSide `
                -StartScreenPoint $script:DragStartScreenPoint
            $script:MouseDownPoint = $null
            $script:DragOriginEdgeSide = $null
            $script:DragStartScreenPoint = $null
        }
    }
}))

$CompactHit.Add_PreviewMouseLeftButtonUp((New-RmfEventHandler -Kind MouseButton -Callback {
    $CompactHit.ReleaseMouseCapture()
    if (-not $script:Dragging -and $script:MouseDownPoint) {
        Set-ExpandedState -Expanded (-not $script:IsExpanded)
    }
    $script:MouseDownPoint = $null
    $script:DragOriginEdgeSide = $null
    $script:DragStartScreenPoint = $null
    $script:Dragging = $false
}))

$CompactHit.Add_KeyDown((New-RmfEventHandler -Kind Key -Callback {
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [Windows.Input.Key]::Enter -or $eventArgs.Key -eq [Windows.Input.Key]::Space) {
        Set-ExpandedState -Expanded (-not $script:IsExpanded)
        $eventArgs.Handled = $true
    }
}))

$window.Add_KeyDown((New-RmfEventHandler -Kind Key -Callback {
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [Windows.Input.Key]::Escape -and $script:IsExpanded) {
        Set-ExpandedState -Expanded $false
        $eventArgs.Handled = $true
    }
    elseif (
        $eventArgs.Key -eq [Windows.Input.Key]::R -and
        ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control)
    ) {
        Invoke-Refresh
        $eventArgs.Handled = $true
    }
}))

$RefreshButton.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
    Invoke-Refresh
}))
$CloseButton.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
    Set-ExpandedState -Expanded $false
}))

$contextMenu = New-Object Windows.Controls.ContextMenu
$refreshMenu = New-Object Windows.Controls.MenuItem
$refreshMenu.Header = '立即刷新'
$refreshMenu.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
    Invoke-Refresh
}))
$sourceMenu = New-Object Windows.Controls.MenuItem
$sourceMenu.Header = '数据源'
$script:CodexSourceMenuItem = New-Object Windows.Controls.MenuItem
$script:CodexSourceMenuItem.Header = 'Codex'
$script:CodexSourceMenuItem.IsCheckable = $true
$script:CodexSourceMenuItem.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
    Set-ActiveProvider -Provider 'Codex' -Refresh
}))
$script:DeepSeekSourceMenuItem = New-Object Windows.Controls.MenuItem
$script:DeepSeekSourceMenuItem.Header = 'DeepSeek'
$script:DeepSeekSourceMenuItem.IsCheckable = $true
$script:DeepSeekSourceMenuItem.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
    Set-ActiveProvider -Provider 'DeepSeek'
    $credential = Get-DeepSeekCredential
    if ($credential.ApiKey) {
        Invoke-Refresh
    }
    else {
        $saved = Show-DeepSeekSettings
        if (-not $saved) { Invoke-Refresh }
        Sync-ProviderMenuState
    }
}))
[void]$sourceMenu.Items.Add($script:CodexSourceMenuItem)
[void]$sourceMenu.Items.Add($script:DeepSeekSourceMenuItem)
$script:CodexOfficialAccessMenuItem = New-Object Windows.Controls.MenuItem
$script:CodexOfficialAccessMenuItem.Header = 'Codex 官方接口（读取登录凭据）'
$script:CodexOfficialAccessMenuItem.IsCheckable = $true
$script:CodexOfficialAccessMenuItem.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
    $enabled = [bool]$script:CodexOfficialAccessMenuItem.IsChecked
    [void](Set-CodexOfficialAccess -Enabled $enabled -Confirm:$enabled)
}))
$script:DeepSeekSettingsMenuItem = New-Object Windows.Controls.MenuItem
$script:DeepSeekSettingsMenuItem.Header = 'DeepSeek 设置…'
$script:DeepSeekSettingsMenuItem.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
    [void](Show-DeepSeekSettings)
}))
$topmostMenu = New-Object Windows.Controls.MenuItem
$topmostMenu.Header = '始终置顶'
$topmostMenu.IsCheckable = $true
$topmostMenu.IsChecked = $window.Topmost
$topmostMenu.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
    $window.Topmost = $topmostMenu.IsChecked
    if ($script:TrayTopmostItem) {
        $script:TrayTopmostItem.Checked = $window.Topmost
    }
    Save-Settings
}))
$script:LowAlertsMenuItem = New-Object Windows.Controls.MenuItem
$script:LowAlertsMenuItem.Header = Get-LowRemainingAlertMenuText
$script:LowAlertsMenuItem.IsCheckable = $true
$script:LowAlertsMenuItem.IsChecked = $script:LowRemainingAlertsEnabled
$script:LowAlertsMenuItem.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
    Set-LowRemainingAlertsEnabled -Enabled $script:LowAlertsMenuItem.IsChecked
}))
$script:LowAlertThresholdMenuItem = New-Object Windows.Controls.MenuItem
$script:LowAlertThresholdMenuItem.Header = Get-UsageAlertSettingsMenuText
$script:LowAlertThresholdMenuItem.Add_Click((
    New-RmfEventHandler -Kind Routed -Callback {
        [void](Show-LowRemainingAlertSettings)
    }
))
$script:EdgeDockMenuItem = New-Object Windows.Controls.MenuItem
$script:EdgeDockMenuItem.Header = '贴边隐藏'
$script:EdgeDockMenuItem.IsCheckable = $true
$script:EdgeDockMenuItem.IsChecked = $script:EdgeDockEnabled
$script:EdgeDockMenuItem.ToolTip = '拖到屏幕左侧或右侧后，自动收为竖向能量条'
$script:EdgeDockMenuItem.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
    Set-EdgeDockEnabled -Enabled $script:EdgeDockMenuItem.IsChecked
}))
$dataMenu = New-Object Windows.Controls.MenuItem
$dataMenu.Header = '数据与诊断'
$diagnosticsMenuItem = New-Object Windows.Controls.MenuItem
$diagnosticsMenuItem.Header = '查看脱敏诊断…'
$diagnosticsMenuItem.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
    Show-RuntimeDiagnostics
}))
$exportHistoryMenuItem = New-Object Windows.Controls.MenuItem
$exportHistoryMenuItem.Header = '导出使用记录…'
$exportHistoryMenuItem.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
    Show-UsageHistoryExportDialog
}))
$importHistoryMenuItem = New-Object Windows.Controls.MenuItem
$importHistoryMenuItem.Header = '导入使用记录…'
$importHistoryMenuItem.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
    Show-UsageHistoryImportDialog
}))
[void]$dataMenu.Items.Add($diagnosticsMenuItem)
[void]$dataMenu.Items.Add((New-Object Windows.Controls.Separator))
[void]$dataMenu.Items.Add($exportHistoryMenuItem)
[void]$dataMenu.Items.Add($importHistoryMenuItem)
$updateMenu = New-Object Windows.Controls.MenuItem
$updateMenu.Header = '软件更新'
$script:UpdateMenuItem = New-Object Windows.Controls.MenuItem
$script:UpdateMenuItem.Header = '检查更新…'
$script:UpdateMenuItem.Add_Click((
    New-RmfEventHandler -Kind Routed -Callback {
        Start-UpdateCheck -Manual
    }
))
$script:AutoUpdateMenuItem = New-Object Windows.Controls.MenuItem
$script:AutoUpdateMenuItem.Header = '自动更新并重启（仅合适网络）'
$script:AutoUpdateMenuItem.IsCheckable = $true
$script:AutoUpdateMenuItem.IsChecked = $script:AutoUpdateEnabled
$script:AutoUpdateMenuItem.ToolTip = (
    '仅在 Windows 判定为非按流量计费、非漫游且未受流量限制时执行'
)
$script:AutoUpdateMenuItem.Add_Click((
    New-RmfEventHandler -Kind Routed -Callback {
        $enabled = [bool]$script:AutoUpdateMenuItem.IsChecked
        [void](Set-AutoUpdateEnabled -Enabled $enabled -Confirm:$enabled)
    }
))
[void]$updateMenu.Items.Add($script:UpdateMenuItem)
[void]$updateMenu.Items.Add((New-Object Windows.Controls.Separator))
[void]$updateMenu.Items.Add($script:AutoUpdateMenuItem)
$startupMenu = New-Object Windows.Controls.MenuItem
$startupMenu.Header = '设置开机启动'
$startupClickHandler = {
    param($sender, $eventArgs)
    [void](Set-StartupMode -Mode ([string]$sender.Tag))
}
foreach ($startupOption in @(
    [pscustomobject]@{ Mode = 'Off'; Header = '关闭' },
    [pscustomobject]@{ Mode = 'Task'; Header = '计划任务（推荐）' },
    [pscustomobject]@{ Mode = 'Registry'; Header = '注册表（兼容）' },
    [pscustomobject]@{ Mode = 'StartupFolder'; Header = '启动文件夹（备用）' }
)) {
    $startupItem = New-Object Windows.Controls.MenuItem
    $startupItem.Header = $startupOption.Header
    $startupItem.Tag = $startupOption.Mode
    $startupItem.IsCheckable = $true
    $startupItem.Add_Click((
        New-RmfEventHandler -Kind Routed -Callback $startupClickHandler
    ))
    $script:StartupMenuItems[$startupOption.Mode] = $startupItem
    [void]$startupMenu.Items.Add($startupItem)
}
$startupServiceItem = New-Object Windows.Controls.MenuItem
$startupServiceItem.Header = 'Windows 服务（不适用于桌面窗口）'
$startupServiceItem.IsEnabled = $false
$startupServiceItem.ToolTip = '服务运行在隔离会话中，无法显示悬浮窗'
[void]$startupMenu.Items.Add((New-Object Windows.Controls.Separator))
[void]$startupMenu.Items.Add($startupServiceItem)
Sync-StartupMenuState
$resetPositionMenu = New-Object Windows.Controls.MenuItem
$resetPositionMenu.Header = '重置位置'
$resetPositionMenu.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
    Clear-EdgeDock
    $workArea = Get-WindowWorkArea
    $resetLeft = $workArea.Right - $script:CompactWidth - 24
    $resetTop = $workArea.Bottom - $script:CompactHeight - 28
    if ($script:IsExpanded) {
        $script:CompactAnchorLeft = $resetLeft
        $script:CompactAnchorTop = $resetTop
        $placement = Get-ExpandedPlacement
        $window.Left = $placement.Left
        $window.Top = $placement.Top
    }
    else {
        $window.Left = $resetLeft
        $window.Top = $resetTop
    }
    Save-Settings
}))
$separator = New-Object Windows.Controls.Separator
$exitMenu = New-Object Windows.Controls.MenuItem
$exitMenu.Header = '退出'
$exitMenu.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
    Save-Settings
    $window.Close()
}))
[void]$contextMenu.Items.Add($refreshMenu)
[void]$contextMenu.Items.Add($sourceMenu)
[void]$contextMenu.Items.Add($script:CodexOfficialAccessMenuItem)
[void]$contextMenu.Items.Add($script:DeepSeekSettingsMenuItem)
[void]$contextMenu.Items.Add($topmostMenu)
[void]$contextMenu.Items.Add($script:LowAlertsMenuItem)
[void]$contextMenu.Items.Add($script:LowAlertThresholdMenuItem)
[void]$contextMenu.Items.Add($script:EdgeDockMenuItem)
[void]$contextMenu.Items.Add($dataMenu)
[void]$contextMenu.Items.Add($updateMenu)
[void]$contextMenu.Items.Add($startupMenu)
[void]$contextMenu.Items.Add($resetPositionMenu)
[void]$contextMenu.Items.Add($separator)
[void]$contextMenu.Items.Add($exitMenu)
$Surface.ContextMenu = $contextMenu
$contextMenu.Add_Closed((New-RmfEventHandler -Kind Routed -Callback {
    Request-InactiveDetailsCollapse
    Request-EdgeDockHide
}))

$script:DeactivationCallbackObserved = $false
$window.Add_Deactivated((New-RmfEventHandler -Kind Event -Callback {
    $script:DeactivationCallbackObserved = $true
    # Wait until popup/focus routing has settled. This distinguishes a real
    # click-away from the transient deactivation caused by the context menu.
    Request-InactiveDetailsCollapse
}))
