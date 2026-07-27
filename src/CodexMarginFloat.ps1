param(
    [switch]$CheckData,
    [switch]$CheckPlacement,
    [switch]$CheckTransitions,
    [switch]$Demo,
    [ValidateSet('', 'compact', 'expanded')]
    [string]$RenderPreview = '',
    [string]$PreviewPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:CompactWidth = 108.0
$script:CompactHeight = 100.0
$script:ExpandedWidth = 370.0
$script:ExpandedHeight = 500.0
$script:RefreshIntervalSeconds = 60
$script:SessionCache = @{}
$script:LastSnapshot = $null
$script:CompactAnchorLeft = $null
$script:CompactAnchorTop = $null

function Get-FittedPlacement {
    param(
        [double]$AnchorLeft,
        [double]$AnchorTop,
        [double]$TargetWidth,
        [double]$TargetHeight,
        [double]$WorkLeft,
        [double]$WorkTop,
        [double]$WorkRight,
        [double]$WorkBottom
    )

    $targetLeft = [Math]::Min($AnchorLeft, $WorkRight - $TargetWidth)
    $targetTop = [Math]::Min($AnchorTop, $WorkBottom - $TargetHeight)
    return [pscustomobject]@{
        Left = [Math]::Max($WorkLeft, $targetLeft)
        Top = [Math]::Max($WorkTop, $targetTop)
    }
}

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

function Read-SessionSnapshot {
    param([System.IO.FileInfo]$File)

    $cacheKey = '{0}:{1}' -f $File.LastWriteTimeUtc.Ticks, $File.Length
    if ($script:SessionCache.ContainsKey($File.FullName)) {
        $cached = $script:SessionCache[$File.FullName]
        if ($cached.Key -eq $cacheKey) { return $cached.Value }
    }

    $lastPayload = $null
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
            $tailLimit = 512KB
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
                    }
                }
                catch {
                    continue
                }
            }

            if ($null -eq $lastPayload -and $startOffset -gt 0) {
                [void]$stream.Seek(0, [System.IO.SeekOrigin]::Begin)
                $reader = New-Object System.IO.StreamReader($stream)
                try {
                    while (($line = $reader.ReadLine()) -ne $null) {
                        if ($line.IndexOf('"type":"token_count"', [StringComparison]::Ordinal) -lt 0) {
                            continue
                        }
                        try {
                            $event = $line | ConvertFrom-Json
                            if ($event.type -eq 'event_msg' -and $event.payload.type -eq 'token_count') {
                                $lastPayload = $event.payload
                            }
                        }
                        catch {
                            continue
                        }
                    }
                }
                finally {
                    $reader.Dispose()
                }
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        $lastPayload = $null
    }

    $value = [pscustomobject]@{
        File = $File
        Payload = $lastPayload
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
    if ($Demo) {
        return [pscustomobject]@{
            Available = $true
            RemainingPercent = 82
            WindowLabel = '本周余量'
            ResetDate = '8月2日 18:32'
            ResetCountdown = '5 天 7 小时后'
            ResetCount = '未提供'
            Plan = 'Pro'
            AccountName = 'YJ'
            AccountEmail = 'you@example.com'
            TodayTokens = 128420
            LastTurnTokens = 49238
            InputTokens = 48891
            OutputTokens = 347
            CachedTokens = 46848
            CacheHitPercent = 95.8
            ContextPercent = 19.1
            SampledAt = Get-Date
            Status = '状态舒适'
            Source = '演示数据'
        }
    }

    $account = Get-SafeAccountInfo
    $sessionsRoot = Join-Path $env:USERPROFILE '.codex\sessions'
    $files = @()
    if (Test-Path -LiteralPath $sessionsRoot) {
        $files = @(Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
    }

    $latestSnapshot = $null
    foreach ($file in ($files | Select-Object -First 24)) {
        $candidate = Read-SessionSnapshot -File $file
        if ($candidate.Payload -and $candidate.Payload.rate_limits) {
            $latestSnapshot = $candidate
            break
        }
    }

    if (-not $latestSnapshot) {
        return [pscustomobject]@{
            Available = $false
            RemainingPercent = 0
            WindowLabel = 'Codex 余量'
            ResetDate = '暂无'
            ResetCountdown = '启动一次 Codex 任务后更新'
            ResetCount = '未提供'
            Plan = 'Codex'
            AccountName = $account.DisplayName
            AccountEmail = $account.Email
            TodayTokens = 0
            LastTurnTokens = 0
            InputTokens = 0
            OutputTokens = 0
            CachedTokens = 0
            CacheHitPercent = 0
            ContextPercent = 0
            SampledAt = Get-Date
            Status = '等待数据'
            Source = '本地暂无用量快照'
        }
    }

    $payload = $latestSnapshot.Payload
    $limits = $payload.rate_limits
    $primary = $limits.primary
    if (-not $primary -and $limits.secondary) { $primary = $limits.secondary }

    $usedPercent = if ($primary -and $null -ne $primary.used_percent) {
        [Math]::Max(0, [Math]::Min(100, [double]$primary.used_percent))
    } else { 0 }
    $remainingPercent = [Math]::Round(100 - $usedPercent)
    $windowMinutes = if ($primary -and $primary.window_minutes) { [int]$primary.window_minutes } else { 0 }
    $windowLabel = if ($windowMinutes -ge 10080) { '本周余量' }
        elseif ($windowMinutes -ge 1440) { '周期余量' }
        elseif ($windowMinutes -gt 0) { '{0} 小时余量' -f [Math]::Round($windowMinutes / 60) }
        else { 'Codex 余量' }

    $resetTimestamp = $null
    if ($primary -and $primary.resets_at) { $resetTimestamp = [long]$primary.resets_at }
    $resetText = Get-ResetText -UnixSeconds $resetTimestamp

    $info = $payload.info
    $lastUsage = if ($info -and $info.last_token_usage) { $info.last_token_usage } else { $null }
    $inputTokens = if ($lastUsage) { [double]$lastUsage.input_tokens } else { 0 }
    $cachedTokens = if ($lastUsage) { [double]$lastUsage.cached_input_tokens } else { 0 }
    $outputTokens = if ($lastUsage) { [double]$lastUsage.output_tokens } else { 0 }
    $lastTurnTokens = if ($lastUsage) { [double]$lastUsage.total_tokens } else { 0 }
    $contextWindow = if ($info -and $info.model_context_window) { [double]$info.model_context_window } else { 0 }
    $cacheHit = if ($inputTokens -gt 0) { [Math]::Round(($cachedTokens / $inputTokens) * 100, 1) } else { 0 }
    $contextPercent = if ($contextWindow -gt 0) {
        [Math]::Round([Math]::Min(100, ($lastTurnTokens / $contextWindow) * 100), 1)
    } else { 0 }

    $today = (Get-Date).Date
    $todayTokens = 0.0
    foreach ($file in ($files | Where-Object { $_.LastWriteTime.Date -eq $today })) {
        $daySnapshot = Read-SessionSnapshot -File $file
        if ($daySnapshot.Payload -and $daySnapshot.Payload.info -and $daySnapshot.Payload.info.total_token_usage) {
            $todayTokens += [double]$daySnapshot.Payload.info.total_token_usage.total_tokens
        }
    }

    $status = if ($remainingPercent -ge 60) { '状态舒适' }
        elseif ($remainingPercent -ge 30) { '余量平稳' }
        elseif ($remainingPercent -gt 0) { '建议留意' }
        else { '等待重置' }

    return [pscustomobject]@{
        Available = $true
        RemainingPercent = $remainingPercent
        WindowLabel = $windowLabel
        ResetDate = $resetText.Date
        ResetCountdown = $resetText.Countdown
        ResetCount = '未提供'
        Plan = Get-PlanLabel -PlanType ([string]$limits.plan_type)
        AccountName = $account.DisplayName
        AccountEmail = $account.Email
        TodayTokens = $todayTokens
        LastTurnTokens = $lastTurnTokens
        InputTokens = $inputTokens
        OutputTokens = $outputTokens
        CachedTokens = $cachedTokens
        CacheHitPercent = $cacheHit
        ContextPercent = $contextPercent
        SampledAt = $latestSnapshot.File.LastWriteTime
        Status = $status
        Source = 'Codex 本地会话快照'
    }
}

if ($CheckData) {
    Get-CodexUsageSnapshot | ConvertTo-Json -Depth 5
    exit 0
}

if ($CheckPlacement) {
    $anchor = [pscustomobject]@{ Left = 1812.0; Top = 980.0 }
    $expanded = Get-FittedPlacement `
        -AnchorLeft $anchor.Left `
        -AnchorTop $anchor.Top `
        -TargetWidth $script:ExpandedWidth `
        -TargetHeight $script:ExpandedHeight `
        -WorkLeft 0 `
        -WorkTop 0 `
        -WorkRight 1920 `
        -WorkBottom 1080
    [pscustomobject]@{
        Anchor = $anchor
        Expanded = $expanded
        Restored = $anchor
    } | ConvertTo-Json -Depth 3
    exit 0
}

if (-not $RenderPreview -and -not $CheckTransitions) {
    $script:ActivationEvent = New-Object System.Threading.EventWaitHandle(
        $false,
        [System.Threading.EventResetMode]::AutoReset,
        'Local\CodexMarginFloat.Activate'
    )
    $createdNew = $false
    $script:AppMutex = New-Object System.Threading.Mutex(
        $true,
        'Local\CodexMarginFloat.Singleton',
        [ref]$createdNew
    )
    if (-not $createdNew) {
        [void]$script:ActivationEvent.Set()
        $script:ActivationEvent.Dispose()
        $script:AppMutex.Dispose()
        exit 0
    }
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
$script:ReducedMotion = -not [System.Windows.SystemParameters]::ClientAreaAnimation

[xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Codex Margin Float"
    Width="108"
    Height="100"
    MinWidth="108"
    MaxWidth="370"
    MinHeight="100"
    MaxHeight="500"
    WindowStyle="None"
    ResizeMode="NoResize"
    AllowsTransparency="True"
    Background="Transparent"
    Topmost="True"
    ShowInTaskbar="False"
    SnapsToDevicePixels="True"
    UseLayoutRounding="True">
    <Window.Resources>
        <SolidColorBrush x:Key="TextPrimary" Color="#343A35"/>
        <SolidColorBrush x:Key="TextSecondary" Color="#6B746D"/>
        <SolidColorBrush x:Key="TextMuted" Color="#8D958F"/>
        <SolidColorBrush x:Key="Sage" Color="#7E9584"/>
        <SolidColorBrush x:Key="SageSoft" Color="#E9F0EA"/>
        <SolidColorBrush x:Key="Champagne" Color="#BEA374"/>
        <SolidColorBrush x:Key="Surface" Color="#FCFBF8"/>
        <SolidColorBrush x:Key="Border" Color="#E8E4DC"/>

        <Style x:Key="SoftButton" TargetType="Button">
            <Setter Property="Height" Value="36"/>
            <Setter Property="Padding" Value="13,0"/>
            <Setter Property="Background" Value="#F2F3EF"/>
            <Setter Property="Foreground" Value="{StaticResource TextSecondary}"/>
            <Setter Property="BorderBrush" Value="#E5E7E1"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonBorder"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="10">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="#E9EEE9"/>
                                <Setter TargetName="ButtonBorder" Property="BorderBrush" Value="#CDD8CF"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.76"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="ButtonBorder" Property="BorderBrush" Value="#7E9584"/>
                                <Setter TargetName="ButtonBorder" Property="BorderThickness" Value="2"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="MetricCard" TargetType="Border">
            <Setter Property="Background" Value="#F5F4F0"/>
            <Setter Property="BorderBrush" Value="#EBE8E1"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="13"/>
            <Setter Property="Padding" Value="12,10"/>
        </Style>
    </Window.Resources>

    <Grid x:Name="WindowRoot" Margin="10">
        <Border x:Name="HoverHalo"
                Margin="-2"
                CornerRadius="24"
                BorderThickness="1"
                BorderBrush="#67AAB7A7"
                Background="#01FFFFFF"
                Opacity="0">
            <Border.Effect>
                <DropShadowEffect Color="#8EAF9A"
                                  BlurRadius="18"
                                  ShadowDepth="0"
                                  Opacity="0.16"/>
            </Border.Effect>
        </Border>

        <Border x:Name="Surface"
                Background="{StaticResource Surface}"
                BorderBrush="{StaticResource Border}"
                BorderThickness="1"
                CornerRadius="22"
                ClipToBounds="True">
            <Border.Effect>
                <DropShadowEffect x:Name="SurfaceShadow"
                                  Color="#8D8A82"
                                  BlurRadius="14"
                                  ShadowDepth="2"
                                  Direction="270"
                                  Opacity="0.10"/>
            </Border.Effect>

            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="79"/>
                    <RowDefinition Height="1"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <Border x:Name="CompactHit"
                        Grid.Row="0"
                        Background="#01FFFFFF"
                        Padding="11,9,11,9"
                        Cursor="Hand"
                        ToolTip="拖动移动 · 单击查看详情"
                        Focusable="True">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="15"/>
                        </Grid.RowDefinitions>

                        <StackPanel Grid.Row="0" HorizontalAlignment="Center" VerticalAlignment="Center">
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                                <TextBlock x:Name="RemainingValue"
                                           Text="--"
                                           Foreground="{StaticResource TextPrimary}"
                                           FontFamily="Segoe UI Variable Display"
                                           FontSize="27"
                                           FontWeight="SemiBold"
                                           FontStretch="SemiCondensed"
                                           LineHeight="30"/>
                                <TextBlock Text="%"
                                           Margin="1,0,0,3"
                                           VerticalAlignment="Bottom"
                                           Foreground="{StaticResource Champagne}"
                                           FontFamily="Segoe UI"
                                           FontSize="10"
                                           FontWeight="SemiBold"/>
                            </StackPanel>
                            <TextBlock x:Name="WindowLabel"
                                       Margin="0,1,0,0"
                                       HorizontalAlignment="Center"
                                       Text="Codex 余量"
                                       Foreground="{StaticResource TextSecondary}"
                                       FontFamily="Microsoft YaHei UI"
                                       FontSize="9"/>
                        </StackPanel>

                        <Grid Grid.Row="1" VerticalAlignment="Bottom">
                            <Border x:Name="ProgressTrack"
                                    Height="4"
                                    CornerRadius="2"
                                    Background="#DDD6CB"
                                    ClipToBounds="True"
                                    ToolTip="剩余 -- · 已使用 --">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition x:Name="RemainingProgressColumn" Width="0*"/>
                                        <ColumnDefinition x:Name="UsedProgressColumn" Width="100*"/>
                                    </Grid.ColumnDefinitions>
                                    <Border Grid.Column="0" Background="#90A593"/>
                                    <Border Grid.Column="1" Background="#DDD6CB"/>
                                </Grid>
                            </Border>
                        </Grid>
                    </Grid>
                </Border>

                <Border Grid.Row="1" Background="#ECE9E2" Margin="18,0"/>

                <Grid x:Name="DetailsPanel"
                      Grid.Row="2"
                      Margin="18,14,18,14"
                      Visibility="Collapsed"
                      Opacity="0">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="55"/>
                        <RowDefinition Height="8"/>
                        <RowDefinition Height="162"/>
                        <RowDefinition Height="76"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="38"/>
                    </Grid.RowDefinitions>

                    <Grid Grid.Row="0">
                        <StackPanel VerticalAlignment="Center">
                            <StackPanel Orientation="Horizontal">
                                <TextBlock x:Name="AccountName"
                                           Text="本地 Codex"
                                           Foreground="{StaticResource TextPrimary}"
                                           FontFamily="Microsoft YaHei UI"
                                           FontSize="14"
                                           FontWeight="SemiBold"/>
                                <Border Margin="8,0,0,0" Padding="7,2" Background="#EEEAE1" CornerRadius="7">
                                    <TextBlock x:Name="PlanBadge"
                                               Text="Codex"
                                               Foreground="#796B53"
                                               FontFamily="Segoe UI"
                                               FontSize="9"
                                               FontWeight="SemiBold"/>
                                </Border>
                            </StackPanel>
                            <TextBlock x:Name="AccountEmail"
                                       Margin="0,5,0,0"
                                       Text="未找到账号信息"
                                       Foreground="{StaticResource TextSecondary}"
                                       FontFamily="Segoe UI"
                                       FontSize="11"
                                       TextTrimming="CharacterEllipsis"
                                       ToolTip="{Binding RelativeSource={RelativeSource Self}, Path=Text}"/>
                        </StackPanel>

                        <Button x:Name="CloseButton"
                                HorizontalAlignment="Right"
                                VerticalAlignment="Center"
                                Width="36"
                                Height="36"
                                Style="{StaticResource SoftButton}"
                                Padding="0"
                                ToolTip="收起详情"
                                AutomationProperties.Name="收起详情">
                            <Path Width="10"
                                  Height="10"
                                  Stretch="Fill"
                                  Stroke="#707871"
                                  StrokeThickness="1.5"
                                  StrokeStartLineCap="Round"
                                  StrokeEndLineCap="Round"
                                  Data="M 0,7 L 5,2 L 10,7"/>
                        </Button>
                    </Grid>

                    <Grid Grid.Row="2">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="77"/>
                            <RowDefinition Height="8"/>
                            <RowDefinition Height="77"/>
                        </Grid.RowDefinitions>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="8"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>

                        <Border Grid.Row="0" Grid.Column="0" Style="{StaticResource MetricCard}">
                            <StackPanel>
                                <TextBlock Text="下次重置" Foreground="{StaticResource TextMuted}" FontFamily="Microsoft YaHei UI" FontSize="9"/>
                                <TextBlock x:Name="DetailsResetDate" Margin="0,5,0,0" Text="--" Foreground="{StaticResource TextPrimary}" FontFamily="Microsoft YaHei UI" FontSize="17" FontWeight="SemiBold"/>
                                <TextBlock x:Name="DetailsResetCountdown" Text="--" Foreground="{StaticResource TextMuted}" FontFamily="Microsoft YaHei UI" FontSize="9"/>
                            </StackPanel>
                        </Border>

                        <Border Grid.Row="0" Grid.Column="2" Style="{StaticResource MetricCard}">
                            <StackPanel>
                                <TextBlock Text="今日 TOKEN" Foreground="{StaticResource TextMuted}" FontFamily="Segoe UI" FontSize="9" FontWeight="SemiBold"/>
                                <TextBlock x:Name="TodayTokens" Margin="0,5,0,0" Text="--" Foreground="{StaticResource TextPrimary}" FontFamily="Segoe UI Variable Display" FontSize="20" FontWeight="SemiBold"/>
                                <TextBlock Text="本机任务累计" Foreground="{StaticResource TextMuted}" FontFamily="Microsoft YaHei UI" FontSize="9"/>
                            </StackPanel>
                        </Border>

                        <Border Grid.Row="2" Grid.Column="0" Style="{StaticResource MetricCard}">
                            <StackPanel>
                                <TextBlock Text="本轮 TOKEN" Foreground="{StaticResource TextMuted}" FontFamily="Segoe UI" FontSize="9" FontWeight="SemiBold"/>
                                <TextBlock x:Name="LastTurnTokens" Margin="0,5,0,0" Text="--" Foreground="{StaticResource TextPrimary}" FontFamily="Segoe UI Variable Display" FontSize="20" FontWeight="SemiBold"/>
                                <TextBlock x:Name="ContextText" Text="上下文 --" Foreground="{StaticResource TextMuted}" FontFamily="Microsoft YaHei UI" FontSize="9"/>
                            </StackPanel>
                        </Border>

                        <Border Grid.Row="2" Grid.Column="2" Style="{StaticResource MetricCard}">
                            <StackPanel>
                                <TextBlock Text="缓存命中" Foreground="{StaticResource TextMuted}" FontFamily="Microsoft YaHei UI" FontSize="9"/>
                                <TextBlock x:Name="CacheHit" Margin="0,5,0,0" Text="--" Foreground="{StaticResource TextPrimary}" FontFamily="Segoe UI Variable Display" FontSize="20" FontWeight="SemiBold"/>
                                <TextBlock x:Name="CacheTokenText" Text="-- cached" Foreground="{StaticResource TextMuted}" FontFamily="Segoe UI" FontSize="9"/>
                            </StackPanel>
                        </Border>
                    </Grid>

                    <Border Grid.Row="3"
                            Margin="0,9,0,0"
                            Background="#EFF3EE"
                            BorderBrush="#DFE7E0"
                            BorderThickness="1"
                            CornerRadius="13"
                            Padding="12,9">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel>
                                <TextBlock Text="本轮构成" Foreground="{StaticResource TextSecondary}" FontFamily="Microsoft YaHei UI" FontSize="10"/>
                                <TextBlock x:Name="TokenBreakdown"
                                           Margin="0,5,0,0"
                                           Text="输入 --  ·  输出 --"
                                           Foreground="{StaticResource TextPrimary}"
                                           FontFamily="Microsoft YaHei UI"
                                           FontSize="11"
                                           FontWeight="SemiBold"/>
                            </StackPanel>
                            <StackPanel Grid.Column="1" HorizontalAlignment="Right">
                                <TextBlock Text="可重置次数" HorizontalAlignment="Right" Foreground="{StaticResource TextSecondary}" FontFamily="Microsoft YaHei UI" FontSize="10"/>
                                <TextBlock x:Name="ResetCount" Margin="0,5,0,0" Text="未提供" HorizontalAlignment="Right" Foreground="{StaticResource TextPrimary}" FontFamily="Microsoft YaHei UI" FontSize="11" FontWeight="SemiBold"/>
                            </StackPanel>
                        </Grid>
                    </Border>

                    <StackPanel Grid.Row="4" Margin="1,14,1,0">
                        <TextBlock x:Name="SourceText"
                                   Text="Codex 本地会话快照"
                                   Foreground="{StaticResource TextSecondary}"
                                   FontFamily="Microsoft YaHei UI"
                                   FontSize="10"/>
                        <TextBlock x:Name="SampleTime"
                                   Margin="0,5,0,0"
                                   Text="采样于 --"
                                   Foreground="{StaticResource TextMuted}"
                                   FontFamily="Microsoft YaHei UI"
                                   FontSize="10"/>
                    </StackPanel>

                    <Grid Grid.Row="5">
                        <TextBlock x:Name="AutoRefreshText"
                                   VerticalAlignment="Center"
                                   Text="60 秒后自动刷新"
                                   Foreground="{StaticResource TextMuted}"
                                   FontFamily="Microsoft YaHei UI"
                                   FontSize="10"/>
                        <Button x:Name="RefreshButton"
                                HorizontalAlignment="Right"
                                Width="92"
                                Style="{StaticResource SoftButton}"
                                Content="立即刷新"
                                ToolTip="重新读取 Codex 本地用量"
                                AutomationProperties.Name="立即刷新"/>
                    </Grid>
                </Grid>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
if ($Demo) {
    # Make visual QA builds discoverable to Windows automation tools.
    $window.ShowInTaskbar = $true
}

$names = @(
    'WindowRoot', 'HoverHalo', 'Surface', 'SurfaceShadow', 'CompactHit',
    'RemainingValue', 'WindowLabel', 'ProgressTrack', 'RemainingProgressColumn',
    'UsedProgressColumn', 'DetailsPanel', 'AccountName',
    'PlanBadge', 'AccountEmail', 'CloseButton', 'DetailsResetDate',
    'DetailsResetCountdown', 'TodayTokens', 'LastTurnTokens', 'ContextText', 'CacheHit',
    'CacheTokenText', 'ResetCount', 'TokenBreakdown', 'SourceText', 'SampleTime',
    'AutoRefreshText', 'RefreshButton'
)
foreach ($name in $names) {
    Set-Variable -Name $name -Value $window.FindName($name) -Scope Script
}

function New-DoubleAnimation {
    param(
        [double]$To,
        [int]$Milliseconds = 220,
        [switch]$EaseOut
    )
    $animation = New-Object Windows.Media.Animation.DoubleAnimation
    $animation.To = $To
    $effectiveMilliseconds = if ($script:ReducedMotion) { 1 } else { $Milliseconds }
    $animation.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds($effectiveMilliseconds))
    if ($EaseOut) {
        $easing = New-Object Windows.Media.Animation.CubicEase
        $easing.EasingMode = [Windows.Media.Animation.EasingMode]::EaseOut
        $animation.EasingFunction = $easing
    }
    return $animation
}

function Get-SettingsPath {
    $directory = Join-Path $env:LOCALAPPDATA 'CodexMarginFloat'
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }
    return Join-Path $directory 'settings.json'
}

function Save-Settings {
    try {
        $saveLeft = if ($null -ne $script:CompactAnchorLeft) {
            $script:CompactAnchorLeft
        } else {
            $window.Left
        }
        $saveTop = if ($null -ne $script:CompactAnchorTop) {
            $script:CompactAnchorTop
        } else {
            $window.Top
        }
        [ordered]@{
            Left = $saveLeft
            Top = $saveTop
            Expanded = $false
            Topmost = $window.Topmost
        } | ConvertTo-Json | Set-Content -LiteralPath (Get-SettingsPath) -Encoding UTF8
    }
    catch {
        # Settings persistence is optional; the widget remains functional without it.
    }
}

function Restore-Settings {
    $workArea = [System.Windows.SystemParameters]::WorkArea
    $window.Width = $script:CompactWidth
    $window.Height = $script:CompactHeight
    $window.Left = $workArea.Right - $script:CompactWidth - 24
    $window.Top = $workArea.Bottom - $script:CompactHeight - 28
    $script:IsExpanded = $false

    try {
        $path = Get-SettingsPath
        if (Test-Path -LiteralPath $path) {
            $settings = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($null -ne $settings.Left -and $null -ne $settings.Top) {
                # Preserve coordinates from secondary monitors. Once the HWND
                # exists, Ensure-WindowVisible clamps them to that monitor.
                $window.Left = [double]$settings.Left
                $window.Top = [double]$settings.Top
            }
            if ($null -ne $settings.Topmost) { $window.Topmost = [bool]$settings.Topmost }
        }
    }
    catch {
        $script:IsExpanded = $false
    }
}

function Get-WindowWorkArea {
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        if ($helper.Handle -ne [IntPtr]::Zero) {
            $pixelArea = [System.Windows.Forms.Screen]::FromHandle($helper.Handle).WorkingArea
            $source = [System.Windows.PresentationSource]::FromVisual($window)
            if ($source -and $source.CompositionTarget) {
                $transform = $source.CompositionTarget.TransformFromDevice
                $topLeft = $transform.Transform((New-Object Windows.Point($pixelArea.Left, $pixelArea.Top)))
                $bottomRight = $transform.Transform((New-Object Windows.Point($pixelArea.Right, $pixelArea.Bottom)))
                return New-Object Windows.Rect(
                    $topLeft.X,
                    $topLeft.Y,
                    $bottomRight.X - $topLeft.X,
                    $bottomRight.Y - $topLeft.Y
                )
            }
        }
    }
    catch {
        # Fall back to the primary work area if per-monitor lookup is unavailable.
    }
    return [System.Windows.SystemParameters]::WorkArea
}

function Ensure-WindowVisible {
    $workArea = Get-WindowWorkArea
    $fitted = Get-FittedPlacement `
        -AnchorLeft $window.Left `
        -AnchorTop $window.Top `
        -TargetWidth $window.Width `
        -TargetHeight $window.Height `
        -WorkLeft $workArea.Left `
        -WorkTop $workArea.Top `
        -WorkRight $workArea.Right `
        -WorkBottom $workArea.Bottom
    $window.Left = $fitted.Left
    $window.Top = $fitted.Top
}

function Show-ExistingWindow {
    Ensure-WindowVisible
    if ($window.WindowState -ne [Windows.WindowState]::Normal) {
        $window.WindowState = [Windows.WindowState]::Normal
    }

    # Briefly promote the existing instance to the foreground, then restore
    # the user's persisted topmost preference.
    $keepTopmost = $window.Topmost
    $window.Topmost = $true
    $window.Show()
    [void]$window.Activate()
    $window.Topmost = $keepTopmost
}

function Get-ExpandedPlacement {
    $workArea = Get-WindowWorkArea
    $anchorLeft = if ($null -ne $script:CompactAnchorLeft) { $script:CompactAnchorLeft } else { $window.Left }
    $anchorTop = if ($null -ne $script:CompactAnchorTop) { $script:CompactAnchorTop } else { $window.Top }
    return Get-FittedPlacement `
        -AnchorLeft $anchorLeft `
        -AnchorTop $anchorTop `
        -TargetWidth $script:ExpandedWidth `
        -TargetHeight $script:ExpandedHeight `
        -WorkLeft $workArea.Left `
        -WorkTop $workArea.Top `
        -WorkRight $workArea.Right `
        -WorkBottom $workArea.Bottom
}

function Set-ExpandedState {
    param(
        [bool]$Expanded,
        [switch]$Immediate
    )

    if ($Expanded -and -not $script:IsExpanded) {
        $script:CompactAnchorLeft = $window.Left
        $script:CompactAnchorTop = $window.Top
    }
    $script:IsExpanded = $Expanded
    $targetWidth = if ($Expanded) { $script:ExpandedWidth } else { $script:CompactWidth }
    $targetHeight = if ($Expanded) { $script:ExpandedHeight } else { $script:CompactHeight }

    # Width and height are one logical state. Keeping them out of independent
    # WPF animations prevents rapid toggles from settling at 370x100 or 108x500.
    $window.BeginAnimation([Windows.FrameworkElement]::WidthProperty, $null)
    $window.BeginAnimation([Windows.FrameworkElement]::HeightProperty, $null)

    if ($Expanded) {
        $placement = Get-ExpandedPlacement
        $window.Left = $placement.Left
        $window.Top = $placement.Top
        $window.Width = $targetWidth
        $window.Height = $targetHeight
        $DetailsPanel.Visibility = 'Visible'
        if ($Immediate) {
            $DetailsPanel.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
            $DetailsPanel.Opacity = 1
        }
        else {
            $DetailsPanel.Opacity = 0
            $DetailsPanel.BeginAnimation(
                [Windows.UIElement]::OpacityProperty,
                (New-DoubleAnimation -To 1 -Milliseconds 190 -EaseOut)
            )
        }
    }
    else {
        # Remove fixed-height detail content before resizing so layout constraints
        # cannot leave a tall, narrow strip behind.
        $DetailsPanel.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
        $DetailsPanel.Opacity = 0
        $DetailsPanel.Visibility = 'Collapsed'
        $window.Width = $targetWidth
        $window.Height = $targetHeight
        if ($null -ne $script:CompactAnchorLeft) {
            $window.Left = $script:CompactAnchorLeft
            $window.Top = $script:CompactAnchorTop
            $script:CompactAnchorLeft = $null
            $script:CompactAnchorTop = $null
        }
    }

    Save-Settings
}

function Set-HoverState {
    param([bool]$Hovering)

    $HoverHalo.BeginAnimation(
        [Windows.UIElement]::OpacityProperty,
        (New-DoubleAnimation -To $(if ($Hovering) { 0.58 } else { 0 }) -Milliseconds $(if ($Hovering) { 210 } else { 160 }) -EaseOut)
    )
    $SurfaceShadow.BeginAnimation(
        [Windows.Media.Effects.DropShadowEffect]::OpacityProperty,
        (New-DoubleAnimation -To $(if ($Hovering) { 0.15 } else { 0.10 }) -Milliseconds 200 -EaseOut)
    )
    $Surface.BorderBrush = New-Object Windows.Media.SolidColorBrush(
        [Windows.Media.ColorConverter]::ConvertFromString($(if ($Hovering) { '#D7DED5' } else { '#E8E4DC' }))
    )
}

function Set-Progress {
    param([double]$Percent)

    $remaining = [Math]::Max(0, [Math]::Min(100, $Percent))
    $used = 100 - $remaining
    $RemainingProgressColumn.Width = New-Object Windows.GridLength(
        $remaining,
        [Windows.GridUnitType]::Star
    )
    $UsedProgressColumn.Width = New-Object Windows.GridLength(
        $used,
        [Windows.GridUnitType]::Star
    )
    $ProgressTrack.ToolTip = '剩余 {0:0}% · 已使用 {1:0}%' -f $remaining, $used
}

function Update-UsageView {
    param($Snapshot)

    $script:LastSnapshot = $Snapshot
    $RemainingValue.Text = [string][int]$Snapshot.RemainingPercent
    $WindowLabel.Text = $Snapshot.WindowLabel
    $DetailsResetDate.Text = $Snapshot.ResetDate
    $DetailsResetCountdown.Text = $Snapshot.ResetCountdown
    $AccountName.Text = $Snapshot.AccountName
    $PlanBadge.Text = $Snapshot.Plan
    $AccountEmail.Text = $Snapshot.AccountEmail
    $TodayTokens.Text = Format-CompactNumber $Snapshot.TodayTokens
    $LastTurnTokens.Text = Format-CompactNumber $Snapshot.LastTurnTokens
    $ContextText.Text = '上下文 {0:0.0}%' -f $Snapshot.ContextPercent
    $CacheHit.Text = '{0:0.0}%' -f $Snapshot.CacheHitPercent
    $CacheTokenText.Text = '{0} cached' -f (Format-CompactNumber $Snapshot.CachedTokens)
    $ResetCount.Text = $Snapshot.ResetCount
    $TokenBreakdown.Text = '输入 {0}  ·  输出 {1}' -f (Format-CompactNumber $Snapshot.InputTokens), (Format-CompactNumber $Snapshot.OutputTokens)
    $SourceText.Text = $Snapshot.Source
    $SampleTime.Text = '采样于 {0}' -f $Snapshot.SampledAt.ToString('M月d日 HH:mm:ss')
    Set-Progress -Percent $Snapshot.RemainingPercent

    $script:RefreshRemaining = $script:RefreshIntervalSeconds
}

function Invoke-Refresh {
    if ($script:IsRefreshing) { return }
    $script:IsRefreshing = $true
    $RefreshButton.IsEnabled = $false
    $RefreshButton.Content = '读取中…'
    try {
        Update-UsageView -Snapshot (Get-CodexUsageSnapshot)
    }
    catch {
        $WindowLabel.Text = '读取失败'
        $SourceText.Text = '无法读取本地用量：' + $_.Exception.Message
    }
    finally {
        $RefreshButton.Content = '立即刷新'
        $RefreshButton.IsEnabled = $true
        $script:IsRefreshing = $false
    }
}

Restore-Settings
Set-ExpandedState -Expanded $script:IsExpanded -Immediate

$script:RefreshRemaining = $script:RefreshIntervalSeconds
$script:IsRefreshing = $false
$script:InitialRefreshQueued = $false
$script:MouseDownPoint = $null
$script:Dragging = $false

if (-not $CheckTransitions) {
    $window.Add_Loaded({
        Ensure-WindowVisible
        $window.Activate() | Out-Null
    })
    $window.Add_ContentRendered({
        if (-not $script:InitialRefreshQueued) {
            $script:InitialRefreshQueued = $true
            $window.Dispatcher.BeginInvoke(
                [Windows.Threading.DispatcherPriority]::Background,
                [Action]{ Invoke-Refresh }
            ) | Out-Null
        }
    })
}

$window.Add_MouseEnter({ Set-HoverState -Hovering $true })
$window.Add_MouseLeave({ Set-HoverState -Hovering $false })

$CompactHit.Add_PreviewMouseLeftButtonDown({
    param($sender, $eventArgs)
    $script:MouseDownPoint = $eventArgs.GetPosition($window)
    $script:Dragging = $false
    $CompactHit.CaptureMouse() | Out-Null
})

$CompactHit.Add_PreviewMouseMove({
    param($sender, $eventArgs)
    if (-not $script:IsExpanded -and $script:MouseDownPoint -and $eventArgs.LeftButton -eq [Windows.Input.MouseButtonState]::Pressed) {
        $point = $eventArgs.GetPosition($window)
        $distance = [Math]::Abs($point.X - $script:MouseDownPoint.X) + [Math]::Abs($point.Y - $script:MouseDownPoint.Y)
        if ($distance -gt 5) {
            $script:Dragging = $true
            $CompactHit.ReleaseMouseCapture()
            try { $window.DragMove() } catch {}
            Save-Settings
            $script:MouseDownPoint = $null
        }
    }
})

$CompactHit.Add_PreviewMouseLeftButtonUp({
    $CompactHit.ReleaseMouseCapture()
    if (-not $script:Dragging -and $script:MouseDownPoint) {
        Set-ExpandedState -Expanded (-not $script:IsExpanded)
    }
    $script:MouseDownPoint = $null
    $script:Dragging = $false
})

$CompactHit.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [Windows.Input.Key]::Enter -or $eventArgs.Key -eq [Windows.Input.Key]::Space) {
        Set-ExpandedState -Expanded (-not $script:IsExpanded)
        $eventArgs.Handled = $true
    }
})

$window.Add_KeyDown({
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
})

$RefreshButton.Add_Click({ Invoke-Refresh })
$CloseButton.Add_Click({ Set-ExpandedState -Expanded $false })

$contextMenu = New-Object Windows.Controls.ContextMenu
$refreshMenu = New-Object Windows.Controls.MenuItem
$refreshMenu.Header = '立即刷新'
$refreshMenu.Add_Click({ Invoke-Refresh })
$topmostMenu = New-Object Windows.Controls.MenuItem
$topmostMenu.Header = '始终置顶'
$topmostMenu.IsCheckable = $true
$topmostMenu.IsChecked = $window.Topmost
$topmostMenu.Add_Click({
    $window.Topmost = $topmostMenu.IsChecked
    Save-Settings
})
$resetPositionMenu = New-Object Windows.Controls.MenuItem
$resetPositionMenu.Header = '重置位置'
$resetPositionMenu.Add_Click({
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
})
$separator = New-Object Windows.Controls.Separator
$exitMenu = New-Object Windows.Controls.MenuItem
$exitMenu.Header = '退出'
$exitMenu.Add_Click({ Save-Settings; $window.Close() })
[void]$contextMenu.Items.Add($refreshMenu)
[void]$contextMenu.Items.Add($topmostMenu)
[void]$contextMenu.Items.Add($resetPositionMenu)
[void]$contextMenu.Items.Add($separator)
[void]$contextMenu.Items.Add($exitMenu)
$Surface.ContextMenu = $contextMenu

if ($CheckTransitions) {
    function Wait-ForUi {
        param([int]$Milliseconds)

        $frame = New-Object Windows.Threading.DispatcherFrame
        $transitionTimer = New-Object Windows.Threading.DispatcherTimer
        $transitionTimer.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
        $transitionTimer.Add_Tick({
            $transitionTimer.Stop()
            $frame.Continue = $false
        })
        $transitionTimer.Start()
        [Windows.Threading.Dispatcher]::PushFrame($frame)
    }

    $window.Opacity = 0
    $window.Left = 1812
    $window.Top = 980
    $window.Show()
    Wait-ForUi -Milliseconds 50
    Set-Progress -Percent 140
    $upperClampedRemaining = $RemainingProgressColumn.Width.Value
    $upperClampedUsed = $UsedProgressColumn.Width.Value
    Set-Progress -Percent -20
    $lowerClampedRemaining = $RemainingProgressColumn.Width.Value
    $lowerClampedUsed = $UsedProgressColumn.Width.Value
    Set-Progress -Percent 82
    Set-ExpandedState -Expanded $false -Immediate
    $anchorLeft = $window.Left
    $anchorTop = $window.Top

    Set-ExpandedState -Expanded $true
    Wait-ForUi -Milliseconds 300
    $expandedWidth = $window.ActualWidth
    $expandedHeight = $window.ActualHeight
    $expandedVisibility = [string]$DetailsPanel.Visibility

    # Reopen while collapse is still animating. A stale collapse callback must
    # never force the expanded window back to compact height.
    Set-ExpandedState -Expanded $false
    Set-ExpandedState -Expanded $true
    Wait-ForUi -Milliseconds 350
    $reopenedWidth = $window.ActualWidth
    $reopenedHeight = $window.ActualHeight
    $reopenedVisibility = [string]$DetailsPanel.Visibility

    Set-ExpandedState -Expanded $false
    Wait-ForUi -Milliseconds 250

    $result = [pscustomobject]@{
        ExpandedWidth = $expandedWidth
        ExpandedHeight = $expandedHeight
        ExpandedVisibility = $expandedVisibility
        UpperClampedRemaining = $upperClampedRemaining
        UpperClampedUsed = $upperClampedUsed
        LowerClampedRemaining = $lowerClampedRemaining
        LowerClampedUsed = $lowerClampedUsed
        RemainingProgressStar = $RemainingProgressColumn.Width.Value
        UsedProgressStar = $UsedProgressColumn.Width.Value
        ReopenedWidth = $reopenedWidth
        ReopenedHeight = $reopenedHeight
        ReopenedVisibility = $reopenedVisibility
        Width = $window.Width
        Height = $window.Height
        DetailsVisibility = [string]$DetailsPanel.Visibility
        RestoredLeft = $window.Left
        RestoredTop = $window.Top
        AnchorLeft = $anchorLeft
        AnchorTop = $anchorTop
    }
    $window.Close()
    $result | ConvertTo-Json
    exit 0
}

if ($RenderPreview) {
    if ([string]::IsNullOrWhiteSpace($PreviewPath)) {
        $PreviewPath = Join-Path (Get-Location) ('preview-{0}.png' -f $RenderPreview)
    }
    $previewExpanded = $RenderPreview -eq 'expanded'
    Set-ExpandedState -Expanded $previewExpanded -Immediate
    Invoke-Refresh

    $previewHeight = if ($previewExpanded) { $script:ExpandedHeight } else { $script:CompactHeight }
    $previewSize = New-Object Windows.Size($window.Width, $previewHeight)
    $WindowRoot.Measure($previewSize)
    $WindowRoot.Arrange((New-Object Windows.Rect(0, 0, $window.Width, $previewHeight)))
    $WindowRoot.UpdateLayout()

    $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap(
        [int]$window.Width,
        [int]$previewHeight,
        96,
        96,
        [Windows.Media.PixelFormats]::Pbgra32
    )
    $bitmap.Render($WindowRoot)
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $outputDirectory = Split-Path -Parent $PreviewPath
    if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
        New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
    }
    $fileStream = [System.IO.File]::Open($PreviewPath, [System.IO.FileMode]::Create)
    try {
        $encoder.Save($fileStream)
    }
    finally {
        $fileStream.Dispose()
    }
    Write-Output ([System.IO.Path]::GetFullPath($PreviewPath))
    exit 0
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    $script:RefreshRemaining--
    if ($script:RefreshRemaining -le 0) {
        Invoke-Refresh
    }
    $AutoRefreshText.Text = '{0} 秒后自动刷新' -f [Math]::Max(0, $script:RefreshRemaining)
})
$timer.Start()

$activationTimer = New-Object Windows.Threading.DispatcherTimer
$activationTimer.Interval = [TimeSpan]::FromMilliseconds(180)
$activationTimer.Add_Tick({
    if ($script:ActivationEvent -and $script:ActivationEvent.WaitOne(0)) {
        Show-ExistingWindow
    }
})
$activationTimer.Start()

$window.Add_Closing({
    $timer.Stop()
    $activationTimer.Stop()
    Save-Settings
    if ($script:ActivationEvent) {
        $script:ActivationEvent.Dispose()
    }
    if ($script:AppMutex) {
        try { $script:AppMutex.ReleaseMutex() } catch {}
        $script:AppMutex.Dispose()
    }
})

[void]$window.ShowDialog()
