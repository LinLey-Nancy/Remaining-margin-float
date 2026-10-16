function Get-RmfThemeViewModel {
    # Public display contract: formatted values only. No credentials or provider responses.
    $snapshot = $script:RmfThemeDisplaySnapshot
    $tokensAvailable = $snapshot -and [bool]$snapshot.Available
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        provider = if ($snapshot) { [string]$snapshot.ProviderId } else { [string]$script:ActiveProvider }
        plan = [string]$PlanBadge.Text
        main = [pscustomobject]@{
            value = [string]$RemainingValue.Text
            prefix = [string]$CompactPrefix.Text
            suffix = [string]$CompactSuffix.Text
            label = [string]$WindowLabel.Text
            percent = $script:RmfThemePercent
            progressAvailable = $script:RmfThemeProgressAvailable
            resetDate = [string]$DetailsResetDate.Text
            resetCountdown = [string]$DetailsResetCountdown.Text
        }
        weekly = [pscustomobject]@{
            value = [string]$WeeklyRemainingValue.Text
            percent = $WeeklyRemainingColumn.Width.Value
            resetCountdown = [string]$WeeklyResetText.Text
            visible = ([string]$WeeklyQuotaBand.Visibility -eq 'Visible' -and
                [string]$CodexQuotaPanel.Visibility -eq 'Visible')
        }
        metrics = [pscustomobject]@{
            primaryVisible = [string]$ProviderMetricPanel.Visibility -eq 'Visible'
            summaryVisible = [string]$TokenSummaryCard.Visibility -eq 'Visible'
            firstTitle = [string]$MetricOneTitle.Text
            firstValue = [string]$PrimaryMetricValue.Text
            secondTitle = [string]$MetricTwoTitle.Text
            secondValue = [string]$TodayTokens.Text
            thirdTitle = [string]$MetricThreeTitle.Text
            thirdValue = [string]$LastTurnTokens.Text
            fourthTitle = [string]$MetricFourTitle.Text
            fourthValue = [string]$CacheHit.Text
            summaryTitle = [string]$BreakdownTitle.Text
            summaryValue = [string]$TokenBreakdown.Text
            secondarySummaryTitle = [string]$SecondaryMetricTitle.Text
            secondarySummaryValue = [string]$ResetCount.Text
        }
        tokens = [pscustomobject]@{
            available = [bool]$tokensAvailable
            total = if ($tokensAvailable) { Format-CompactNumber (Get-ObjectPropertyValue $snapshot 'TodayTokens' 0) } else { '--' }
            output = if ($tokensAvailable) { Format-CompactNumber (Get-ObjectPropertyValue $snapshot 'TodayOutputTokens' 0) } else { '--' }
            cached = if ($tokensAvailable) { Format-CompactNumber (Get-ObjectPropertyValue $snapshot 'TodayCachedTokens' 0) } else { '--' }
            hitRate = if ($tokensAvailable) { '{0:0.0}%' -f [double](Get-ObjectPropertyValue $snapshot 'TodayCacheHitPercent' 0) } else { '--' }
        }
        trends = [pscustomobject]@{
            title = [string]$UsageTrendTitle.Text
            fiveHourSummary = [string]$Trend5HText.Text
            weeklySummary = [string]$Trend7Text.Text
            prediction = [string]$PredictionText.Text
            monitoring = [string]$RapidDropText.Text
        }
        source = [string]$SourceText.Text
        sampleTime = [string]$SampleTime.Text
        version = [string]$script:AppVersion
        expanded = [bool]$script:IsExpanded
    }
}

function Get-RmfThemeAuthoringGuide {
    return @'
# Remaining Margin Float 自制主题接口 v1

把本说明、my-theme.json 和 display-contract.json 一起交给 AI，描述想要的外观，要求只生成一份 UTF-8 JSON。应用右键或托盘 → 主题 → 导入主题，选择文件即可使用。主题保存在本机数据目录的 themes 子目录，选择会跨重启保存。

my-theme.json 是可直接导入的完整示例，builtins 是四个内置主题的参考定义。请更改 id（小写字母开头，3–48 个小写字母、数字或连字符）与 name。classic/native/instrument/paper 是保留 id。重复 id 不会覆盖原文件。schemaVersion 当前必须为 1，未知字段会明确拒绝。

layout.base 决定布局：classic 保留原界面；native、instrument、paper 使用顶部数据源工具栏和独立额度区。layout.quotaStyle 可以是 bar（横条）、ring（圆环）、rail（竖条）；heroAlignment 可以是 Left 或 Right，作用于展开态数字。ring 的数字固定居中。紧凑窗保持 80×80，详情宽 400，自动展开收起、显示器边界避让由程序负责。经典骨架仅支持 bar + Left，其他骨架可自由组合布局与配色；自制经典骨架同样支持自定义字号。v1 不支持任意 XAML、脚本、网络资源或自定义数据请求。

colors：所有颜色必须为 #RRGGBB。TextPrimary/Secondary/Muted 是三级文字；Surface/SurfaceSubtle 是主次背景；Border/Divider 是边框与分隔线；Track 是已使用进度底色；SummarySurface/SummaryBorder 是统计带；ButtonSurface/ButtonHover/ButtonBorder 是按钮状态；BadgeSurface/BadgeBorder/BadgeText 是套餐标签；Unknown 是无数据的中性状态。

typography：textFamily/numberFamily 只能填写本机字体名称，缺失字体由 Windows 回退。compactNumberSize 为 20–28，detailsNumberSize 为 32–52；圆环使用适配小窗口的固定字号。shape：windowRadius 为 6–18，cardRadius 为 0–12，progressThickness 为 2–6。

quotaColors 是 2–12 个 {percent,color}，percent 必须严格递增，以 0 开始、100 结束。按数值逐段连续插值。主额度与每周额度独立着色，未知状态使用 Unknown；高对比度下系统颜色优先。经典主题保留原来的连续配色和贴边能量条。

display-contract.json 描述渲染接口与演示值，并非真实账户数据。主题不需要重新计算额度或 Token。main 表示当前实际显示的配额窗口，包括 Plus/Pro 主周期、每周耗尽时的切换；无预算的 DeepSeek 显示金额，此时 progressAvailable=false，不能伪装成 0%。metrics 四组字段按数据源展示今日/本月花费或 Token 与缓存。trends 是应用计算后的摘要，图表采样、断档与周期隔离仍由宿主负责。

不得把密钥、凭据、Cookie、账户邮箱或真实接口响应写入主题。主题文件仅定义表现，宿主绑定已经校验、格式化的数据。请保持未知、离线、长账户名、低额度、空状态可读。

给 AI 的提示：请依据本接口修改 my-theme.json，只返回完整 JSON，不添加未定义字段，不输出代码块。保留字段名和 schemaVersion，修改 id、名称、配色、字体、形状与布局组合；保证文字与背景对比清楚，余量由高到低连续过渡，保留不可用状态。先确保能导入，再按 80×80 紧凑态与 400 宽详情态检查长文本和深浅背景。
'@
}

function Get-RmfThemeJsonSchema {
    $colorProperties = [ordered]@{}
    foreach ($property in $script:RmfThemes['classic'].colors.PSObject.Properties) {
        $colorProperties[$property.Name] = @{ type = 'string'; pattern = '^#[0-9A-Fa-f]{6}$' }
    }
    return [ordered]@{
        '$schema' = 'https://json-schema.org/draft/2020-12/schema'
        title = 'Remaining Margin Float Theme v1'
        type = 'object'; additionalProperties = $false
        allOf = @(@{
            'if' = @{ properties = @{ layout = @{ properties = @{ base = @{ const = 'classic' } } } } }
            then = @{ properties = @{ layout = @{ properties = @{ quotaStyle = @{ const = 'bar' }; heroAlignment = @{ const = 'Left' } } } } }
        })
        required = @('schemaVersion','id','name','description','layout','colors','typography','shape','quotaColors')
        properties = [ordered]@{
            '$schema' = @{ type = 'string'; maxLength = 200 }
            schemaVersion = @{ type = 'integer'; const = 1 }
            id = @{ type = 'string'; pattern = '^[a-z][a-z0-9-]{2,47}$'; not = @{ enum = @('classic','native','instrument','paper') } }
            name = @{ type = 'string'; minLength = 1; maxLength = 40; pattern = '^[^\u0000-\u001f]+$' }
            description = @{ type = 'string'; minLength = 1; maxLength = 200; pattern = '^[^\u0000-\u001f]+$' }
            layout = @{
                type = 'object'; additionalProperties = $false; required = @('base','quotaStyle','heroAlignment')
                properties = @{
                    base = @{ enum = @('classic','native','instrument','paper') }
                    quotaStyle = @{ enum = @('bar','ring','rail') }
                    heroAlignment = @{ enum = @('Left','Right') }
                }
            }
            colors = @{ type = 'object'; additionalProperties = $false; required = @($colorProperties.Keys); properties = $colorProperties }
            typography = @{
                type = 'object'; additionalProperties = $false
                required = @('textFamily','numberFamily','compactNumberSize','detailsNumberSize')
                properties = @{
                    textFamily = @{ type = 'string'; minLength = 1; maxLength = 80; pattern = '^[^\u0000-\u001f:/\\#]+$' }
                    numberFamily = @{ type = 'string'; minLength = 1; maxLength = 80; pattern = '^[^\u0000-\u001f:/\\#]+$' }
                    compactNumberSize = @{ type = 'number'; minimum = 20; maximum = 28 }
                    detailsNumberSize = @{ type = 'number'; minimum = 32; maximum = 52 }
                }
            }
            shape = @{
                type = 'object'; additionalProperties = $false; required = @('windowRadius','cardRadius','progressThickness')
                properties = @{
                    windowRadius = @{ type = 'number'; minimum = 6; maximum = 18 }
                    cardRadius = @{ type = 'number'; minimum = 0; maximum = 12 }
                    progressThickness = @{ type = 'number'; minimum = 2; maximum = 6 }
                }
            }
            quotaColors = @{
                type = 'array'; minItems = 2; maxItems = 12
                items = @{
                    type = 'object'; additionalProperties = $false; required = @('percent','color')
                    properties = @{
                        percent = @{ type = 'number'; minimum = 0; maximum = 100 }
                        color = @{ type = 'string'; pattern = '^#[0-9A-Fa-f]{6}$' }
                    }
                }
                description = '宿主额外校验：百分比严格递增，首项为 0、末项为 100。'
            }
        }
    }
}

function Export-RmfThemeKit {
    param([string]$Directory)
    [void][IO.Directory]::CreateDirectory($Directory)
    $example = $script:RmfActiveTheme | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $example.id = 'my-custom-theme'
    $example.name = '我的自制主题'
    $example.description = '根据接口定制的独立主题'
    $encoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $Directory 'my-theme.json'),
        ($example | ConvertTo-Json -Depth 8), $encoding)
    [IO.File]::WriteAllText((Join-Path $Directory 'README.md'), (Get-RmfThemeAuthoringGuide), $encoding)
    [IO.File]::WriteAllText((Join-Path $Directory 'theme.schema.json'),
        ((Get-RmfThemeJsonSchema) | ConvertTo-Json -Depth 12), $encoding)
    $contract = [ordered]@{
        schemaVersion = 1
        note = '下方为演示数据，与真实账户无关；字段由宿主统一绑定。'
        providers = @('Codex', 'Kimi', 'DeepSeek')
        sample = [ordered]@{
            provider = 'Codex'; plan = 'Plus'
            main = @{ value = '8'; prefix = ''; suffix = '%'; label = '5 小时余量'; percent = 8;
                progressAvailable = $true; resetDate = '16:20'; resetCountdown = '3 小时 8 分钟后' }
            weekly = @{ value = '24%'; percent = 24; resetCountdown = '6 天后'; visible = $true }
            metrics = @{ primaryVisible = $false; summaryVisible = $true; firstTitle = '今日 Token'; firstValue = '382.6K'; secondTitle = '输出';
                secondValue = '81.4K'; thirdTitle = '缓存'; thirdValue = '245.8K';
                fourthTitle = '命中率'; fourthValue = '64.2%'; summaryTitle = '今日 Token'; summaryValue = '382.6K · 输出 81.4K';
                secondarySummaryTitle = '今日缓存'; secondarySummaryValue = '245.8K · 命中 64.2%' }
            tokens = @{ available = $true; total = '382.6K'; output = '81.4K'; cached = '245.8K'; hitRate = '64.2%' }
            trends = @{ title = '5 小时额度趋势'; fiveHourSummary = '下降 10pp'; weeklySummary = '下降 23pp';
                prediction = '预计约 45 分钟后耗尽'; monitoring = '快速下降监控已开启' }
            source = '演示数据'; sampleTime = '刚刚'; version = $script:AppVersion; expanded = $true
        }
        bindings = @{ main = '主数字、进度、周期与重置'; weekly = '补充配额窗口';
            metrics = '统计与缓存区域'; trends = '趋势与预测区域'; source = '数据来源'; sampleTime = '采样时间' }
    }
    [IO.File]::WriteAllText((Join-Path $Directory 'display-contract.json'),
        ($contract | ConvertTo-Json -Depth 8), $encoding)
    $builtinsDirectory = Join-Path $Directory 'builtins'
    [void][IO.Directory]::CreateDirectory($builtinsDirectory)
    foreach ($id in @('classic','native','instrument','paper')) {
        [IO.File]::WriteAllText((Join-Path $builtinsDirectory ($id + '.json')),
            ($script:RmfThemes[$id] | ConvertTo-Json -Depth 8), $encoding)
    }
    return $Directory
}

function Invoke-RmfThemeMenuAction {
    param([string]$Action)
    $script:RmfThemeDialogOpen = $true
    try {
        switch ($Action) {
            'import' {
                $dialog = New-Object Microsoft.Win32.OpenFileDialog
                $dialog.Title = '导入自制主题'
                $dialog.Filter = 'JSON 主题 (*.json)|*.json'
                if ($dialog.ShowDialog($window)) {
                    $theme = Import-RmfTheme -Path $dialog.FileName
                    Rebuild-RmfThemeMenus
                    Set-RmfTheme -Id $theme.id
                }
            }
            'export' {
                $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
                $dialog.Description = '选择主题制作套件的保存目录'
                try {
                    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                        $destination = Join-Path $dialog.SelectedPath ('RemainingMarginFloat-ThemeKit-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmssfff'))
                        [void](Export-RmfThemeKit -Directory $destination)
                        Start-Process -FilePath explorer.exe -ArgumentList ('"' + $destination + '"')
                    }
                } finally { $dialog.Dispose() }
            }
            'folder' {
                $folder = Get-RmfThemeDirectory
                [void][IO.Directory]::CreateDirectory($folder)
                Start-Process -FilePath explorer.exe -ArgumentList ('"' + $folder + '"')
            }
        }
    }
    catch {
        [void][Windows.MessageBox]::Show($window, $_.Exception.Message, '主题', 'OK', 'Warning')
    }
    finally { $script:RmfThemeDialogOpen = $false }
}

function Add-RmfThemeMenuItems {
    param($Menu, [switch]$Tray)
    $items = $null
    if ($Tray) { $items = $Menu.DropDownItems } else { $items = $Menu.Items }
    $items.Clear()
    foreach ($theme in $script:RmfThemes.Values) {
        $item = if ($Tray) { New-Object System.Windows.Forms.ToolStripMenuItem } else {
            New-Object Windows.Controls.MenuItem
        }
        if ($Tray) { $item.Text = $theme.name } else { $item.Header = $theme.name; $item.IsCheckable = $true }
        $item.Tag = $theme.id
        $kind = if ($Tray) { 'Event' } else { 'Routed' }
        $item.Add_Click((New-RmfEventHandler -Kind $kind -Callback {
            param($sender, $eventArgs)
            try { Set-RmfTheme -Id ([string]$sender.Tag) }
            catch { [void][Windows.MessageBox]::Show($window, $_.Exception.Message, '主题', 'OK', 'Warning') }
        }))
        [void]$items.Add($item)
    }
    $separator = if ($Tray) { New-Object System.Windows.Forms.ToolStripSeparator } else {
        New-Object Windows.Controls.Separator
    }
    [void]$items.Add($separator)
    foreach ($action in @(@('import','导入主题…'), @('export','导出 AI 主题制作套件…'), @('folder','打开自制主题目录'))) {
        $item = if ($Tray) { New-Object System.Windows.Forms.ToolStripMenuItem } else { New-Object Windows.Controls.MenuItem }
        if ($Tray) { $item.Text = $action[1] } else { $item.Header = $action[1] }
        $item.Tag = $action[0]
        $kind = if ($Tray) { 'Event' } else { 'Routed' }
        $item.Add_Click((New-RmfEventHandler -Kind $kind -Callback {
            param($sender, $eventArgs)
            Invoke-RmfThemeMenuAction -Action ([string]$sender.Tag)
        }))
        [void]$items.Add($item)
    }
}

function Sync-RmfThemeMenus {
    foreach ($menu in @($script:RmfThemeMenu, $script:RmfTrayThemeMenu)) {
        if (-not $menu) { continue }
        $tray = $menu -is [System.Windows.Forms.ToolStripMenuItem]
        $items = $null
        if ($tray) { $items = $menu.DropDownItems } else { $items = $menu.Items }
        foreach ($item in $items) {
            if ($null -ne $item.Tag -and $script:RmfThemes.Contains([string]$item.Tag)) {
                if ($tray) { $item.Checked = [string]$item.Tag -eq $script:ActiveThemeId } else {
                    $item.IsChecked = [string]$item.Tag -eq $script:ActiveThemeId
                }
            }
        }
    }
}

function Rebuild-RmfThemeMenus {
    if ($script:RmfThemeMenu) { Add-RmfThemeMenuItems -Menu $script:RmfThemeMenu }
    if ($script:RmfTrayThemeMenu) { Add-RmfThemeMenuItems -Menu $script:RmfTrayThemeMenu -Tray }
    Sync-RmfThemeMenus
}

Initialize-RmfThemes
Apply-RmfThemeDefinition
