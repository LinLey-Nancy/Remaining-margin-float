$script:RuntimeDiagnosticState = [ordered]@{}
foreach ($area in @('Codex', 'DeepSeek', 'History', 'Refresh')) {
    $script:RuntimeDiagnosticState[$area] = [pscustomobject]@{
        Status = 'Unknown'
        Message = '尚未检查'
        LastCheckedAt = $null
        LastSuccessAt = $null
        LastFailureAt = $null
    }
}

function Protect-RuntimeDiagnosticText {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $safe = $Text
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $safe = [regex]::Replace(
            $safe,
            [regex]::Escape($env:USERPROFILE),
            '%USERPROFILE%',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $safe = [regex]::Replace(
            $safe,
            [regex]::Escape($env:LOCALAPPDATA),
            '%LOCALAPPDATA%',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }
    $safe = [regex]::Replace(
        $safe,
        '(?i)\b(?:api[_\s-]?key|access[_\s-]?token|refresh[_\s-]?token|authorization)\b\s*[:=]\s*(?:bearer\s+)?["'']?[^\s,;"'']+',
        '[已隐藏凭据]'
    )
    $safe = [regex]::Replace(
        $safe,
        '(?i)\bbearer\s+[A-Za-z0-9._~+/-]{8,}=*',
        '[已隐藏凭据]'
    )
    $safe = [regex]::Replace(
        $safe,
        '(?i)\b(?:bearer\s+)?(?:sk-[A-Za-z0-9_-]{8,}|[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})\b',
        '[已隐藏凭据]'
    )
    $safe = [regex]::Replace(
        $safe,
        '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b',
        '[已隐藏邮箱]'
    )
    if ($safe.Length -gt 300) {
        $safe = $safe.Substring(0, 300) + '…'
    }
    return $safe.Trim()
}

function Set-RuntimeDiagnosticStatus {
    param(
        [ValidateSet('Codex', 'DeepSeek', 'History', 'Refresh')]
        [string]$Area,
        [ValidateSet('Unknown', 'Running', 'Healthy', 'Degraded', 'Error')]
        [string]$Status,
        [AllowEmptyString()]
        [string]$Message = '',
        [DateTimeOffset]$ObservedAt = [DateTimeOffset]::Now
    )

    $state = $script:RuntimeDiagnosticState[$Area]
    $state.Status = $Status
    $state.Message = Protect-RuntimeDiagnosticText -Text $Message
    $state.LastCheckedAt = $ObservedAt
    if ($Status -eq 'Healthy') {
        $state.LastSuccessAt = $ObservedAt
    }
    elseif ($Status -in @('Degraded', 'Error')) {
        $state.LastFailureAt = $ObservedAt
    }
}

function Get-RuntimeDiagnosticSnapshot {
    $history = $null
    try {
        $history = Get-UsageHistorySummary
    }
    catch {
        Set-RuntimeDiagnosticStatus `
            -Area 'History' `
            -Status 'Error' `
            -Message $_.Exception.Message
    }

    $areas = [ordered]@{}
    foreach ($area in $script:RuntimeDiagnosticState.Keys) {
        $state = $script:RuntimeDiagnosticState[$area]
        $areas[$area] = [ordered]@{
            Status = [string]$state.Status
            Message = [string]$state.Message
            LastCheckedAt = $state.LastCheckedAt
            LastSuccessAt = $state.LastSuccessAt
            LastFailureAt = $state.LastFailureAt
        }
    }

    return [ordered]@{
        SchemaVersion = 1
        GeneratedAt = [DateTimeOffset]::Now
        Product = 'Remaining Margin Float'
        Version = [string]$script:AppVersion
        Environment = [ordered]@{
            OperatingSystem = [Environment]::OSVersion.VersionString
            PowerShell = [string]$PSVersionTable.PSVersion
            TimeZoneId = [TimeZoneInfo]::Local.Id
            Culture = [Globalization.CultureInfo]::CurrentCulture.Name
            ActiveProvider = [string]$script:ActiveProvider
            CodexOfficialAccessEnabled =
                [bool]$script:CodexOfficialAccessEnabled
            DeepSeekEnvironmentKeyPresent =
                -not [string]::IsNullOrWhiteSpace($env:DEEPSEEK_API_KEY)
        }
        History = if ($history) {
            [ordered]@{
                Exists = [bool]$history.Exists
                SampleCount = [int]$history.SampleCount
                FirstLocalDate = [string]$history.FirstLocalDate
                LastLocalDate = [string]$history.LastLocalDate
                TimeZoneId = [string]$history.TimeZoneId
                Providers = @($history.Providers)
                Path = Protect-RuntimeDiagnosticText -Text $history.Path
            }
        } else { $null }
        Health = $areas
    }
}

function ConvertTo-RuntimeDiagnosticText {
    param($Snapshot = (Get-RuntimeDiagnosticSnapshot))

    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('Remaining Margin Float 诊断报告')
    $lines.Add(('版本：{0}' -f $Snapshot.Version))
    $lines.Add(('生成时间：{0}' -f $Snapshot.GeneratedAt.ToString('o')))
    $lines.Add(('系统：{0}' -f $Snapshot.Environment.OperatingSystem))
    $lines.Add(('PowerShell：{0}' -f $Snapshot.Environment.PowerShell))
    $lines.Add(('时区：{0}' -f $Snapshot.Environment.TimeZoneId))
    $lines.Add(('当前数据源：{0}' -f $Snapshot.Environment.ActiveProvider))
    $lines.Add('')
    foreach ($area in @('Codex', 'DeepSeek', 'History', 'Refresh')) {
        $health = $Snapshot.Health[$area]
        $lines.Add((
            '{0}：{1} · {2}' -f
            $area,
            $health.Status,
            $health.Message
        ))
        if ($health.LastSuccessAt) {
            $lines.Add(('  最近成功：{0}' -f $health.LastSuccessAt))
        }
        if ($health.LastFailureAt) {
            $lines.Add(('  最近失败：{0}' -f $health.LastFailureAt))
        }
    }
    $lines.Add('')
    if ($Snapshot.History) {
        $lines.Add(('历史样本：{0}' -f $Snapshot.History.SampleCount))
        $lines.Add((
            '历史日期：{0} 至 {1}' -f
            $Snapshot.History.FirstLocalDate,
            $Snapshot.History.LastLocalDate
        ))
        $lines.Add(('历史路径：{0}' -f $Snapshot.History.Path))
    }
    $lines.Add('')
    $lines.Add('报告不包含访问令牌、API Key、账户名称、邮箱或原始日志。')
    return $lines -join [Environment]::NewLine
}

function Save-RuntimeDiagnosticReport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $text = ConvertTo-RuntimeDiagnosticText
    [IO.File]::WriteAllText(
        [IO.Path]::GetFullPath($Path),
        $text,
        (New-Object Text.UTF8Encoding($true))
    )
}

function Show-UsageHistoryExportDialog {
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Title = '导出使用记录'
    $dialog.Filter = '使用记录 (*.jsonl)|*.jsonl'
    $dialog.FileName = 'Remaining-Margin-Float-usage-history-{0}.jsonl' -f (
        Get-Date -Format 'yyyyMMdd'
    )
    if (-not $dialog.ShowDialog($window)) { return }

    try {
        $result = Export-UsageHistory -Path $dialog.FileName
        [Windows.MessageBox]::Show(
            "已导出 $($result.SampleCount) 条脱敏使用记录。",
            '导出完成',
            [Windows.MessageBoxButton]::OK,
            [Windows.MessageBoxImage]::Information
        ) | Out-Null
    }
    catch {
        [Windows.MessageBox]::Show(
            '导出失败：' + (Protect-RuntimeDiagnosticText $_.Exception.Message),
            '导出使用记录',
            [Windows.MessageBoxButton]::OK,
            [Windows.MessageBoxImage]::Error
        ) | Out-Null
    }
}

function Show-UsageHistoryImportDialog {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title = '导入使用记录'
    $dialog.Filter = '使用记录 (*.jsonl)|*.jsonl'
    if (-not $dialog.ShowDialog($window)) { return }

    try {
        $result = Import-UsageHistory -Path $dialog.FileName
        if ($script:LastSnapshot) {
            Update-UsageView -Snapshot $script:LastSnapshot
        }
        [Windows.MessageBox]::Show(
            "已读取 $($result.ImportedCount) 条记录，合并后保留 $($result.TotalCount) 条。",
            '导入完成',
            [Windows.MessageBoxButton]::OK,
            [Windows.MessageBoxImage]::Information
        ) | Out-Null
    }
    catch {
        [Windows.MessageBox]::Show(
            '导入失败：' + (Protect-RuntimeDiagnosticText $_.Exception.Message),
            '导入使用记录',
            [Windows.MessageBoxButton]::OK,
            [Windows.MessageBoxImage]::Error
        ) | Out-Null
    }
}

function Show-RuntimeDiagnostics {
    $dialog = New-Object Windows.Window
    $dialog.Title = '数据与诊断'
    $dialog.Width = 620
    $dialog.Height = 500
    $dialog.ResizeMode = 'CanResize'
    $dialog.WindowStartupLocation = 'CenterOwner'
    $dialog.ShowInTaskbar = $false
    $dialog.Owner = $window
    $dialog.Background = [Windows.Media.Brushes]::White

    $root = New-Object Windows.Controls.DockPanel
    $root.Margin = New-Object Windows.Thickness(18)
    $buttons = New-Object Windows.Controls.StackPanel
    $buttons.Orientation = 'Horizontal'
    $buttons.HorizontalAlignment = 'Right'
    [Windows.Controls.DockPanel]::SetDock($buttons, 'Bottom')

    $copyButton = New-Object Windows.Controls.Button
    $copyButton.Content = '复制报告'
    $copyButton.Width = 88
    $copyButton.Height = 32
    $copyButton.Margin = New-Object Windows.Thickness(0, 12, 8, 0)
    $exportButton = New-Object Windows.Controls.Button
    $exportButton.Content = '导出报告…'
    $exportButton.Width = 92
    $exportButton.Height = 32
    $exportButton.Margin = New-Object Windows.Thickness(0, 12, 8, 0)
    $closeButton = New-Object Windows.Controls.Button
    $closeButton.Content = '关闭'
    $closeButton.Width = 76
    $closeButton.Height = 32
    $closeButton.Margin = New-Object Windows.Thickness(0, 12, 0, 0)
    $closeButton.IsDefault = $true
    [void]$buttons.Children.Add($copyButton)
    [void]$buttons.Children.Add($exportButton)
    [void]$buttons.Children.Add($closeButton)

    $reportBox = New-Object Windows.Controls.TextBox
    $reportBox.Text = ConvertTo-RuntimeDiagnosticText
    $reportBox.IsReadOnly = $true
    $reportBox.AcceptsReturn = $true
    $reportBox.TextWrapping = 'Wrap'
    $reportBox.VerticalScrollBarVisibility = 'Auto'
    $reportBox.FontFamily = 'Microsoft YaHei UI'
    $reportBox.FontSize = 12
    $reportBox.Padding = New-Object Windows.Thickness(12)

    $copyButton.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
        [Windows.Clipboard]::SetText($reportBox.Text)
        $copyButton.Content = '已复制'
    }))
    $exportButton.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
        $saveDialog = New-Object Microsoft.Win32.SaveFileDialog
        $saveDialog.Title = '导出脱敏诊断报告'
        $saveDialog.Filter = '文本文件 (*.txt)|*.txt'
        $saveDialog.FileName = 'Remaining-Margin-Float-diagnostics-{0}.txt' -f (
            Get-Date -Format 'yyyyMMdd-HHmmss'
        )
        if ($saveDialog.ShowDialog($dialog)) {
            try {
                Save-RuntimeDiagnosticReport -Path $saveDialog.FileName
                [Windows.MessageBox]::Show(
                    '脱敏诊断报告已导出。',
                    '导出完成',
                    [Windows.MessageBoxButton]::OK,
                    [Windows.MessageBoxImage]::Information
                ) | Out-Null
            }
            catch {
                [Windows.MessageBox]::Show(
                    '导出失败：' +
                        (Protect-RuntimeDiagnosticText $_.Exception.Message),
                    '导出诊断报告',
                    [Windows.MessageBoxButton]::OK,
                    [Windows.MessageBoxImage]::Error
                ) | Out-Null
            }
        }
    }))
    $closeButton.Add_Click((New-RmfEventHandler -Kind Routed -Callback {
        $dialog.Close()
    }))

    [void]$root.Children.Add($buttons)
    [void]$root.Children.Add($reportBox)
    $dialog.Content = $root
    [void]$dialog.ShowDialog()
}
