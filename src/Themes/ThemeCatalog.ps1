# Theme files are data, never executable XAML or PowerShell.
$script:RmfThemes = [ordered]@{}
$script:ActiveThemeId = 'classic'
$script:RmfActiveTheme = $null
$script:RmfThemeMenu = $null
$script:RmfTrayThemeMenu = $null
$script:RmfThemePercent = 0.0
$script:RmfThemeProgressAvailable = $false
$script:RmfThemeDialogOpen = $false
$script:RmfThemeMonitorRapid = $false
$script:RmfThemeDisplaySnapshot = $null

function Get-RmfThemeDirectory {
    return Join-Path (Get-AppDataDirectory) 'themes'
}

function Assert-RmfThemeKeys {
    param($Value, [string[]]$Required, [string[]]$Optional = @(), [string]$Section)
    if ($null -eq $Value -or $Value -isnot [pscustomobject]) {
        throw "主题 $Section 必须是 JSON 对象。"
    }
    $names = @($Value.PSObject.Properties.Name)
    foreach ($key in $Required) {
        if ($names -cnotcontains $key) { throw "主题缺少 $Section.$key。" }
    }
    foreach ($key in $names) {
        if ($Required -cnotcontains $key -and $Optional -cnotcontains $key) {
            throw "主题包含不支持的字段 $Section.$key。"
        }
    }
}

function Assert-RmfThemeNumber {
    param($Value, [double]$Minimum, [double]$Maximum, [string]$Name)
    if ($Value -is [string] -or $Value -is [bool] -or $null -eq $Value -or
        $Value -is [array] -or $Value -is [pscustomobject]) {
        throw "主题 $Name 必须是数字。"
    }
    $number = [double]$Value
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or
        $number -lt $Minimum -or $number -gt $Maximum) {
        throw "主题 $Name 必须在 $Minimum 到 $Maximum 之间。"
    }
}

function Assert-RmfThemeDefinition {
    param($Theme, [switch]$Imported)
    Assert-RmfThemeKeys -Value $Theme -Section 'root' -Required @(
        'schemaVersion', 'id', 'name', 'description', 'layout', 'colors',
        'typography', 'shape', 'quotaColors'
    ) -Optional @('$schema')
    Assert-RmfThemeNumber $Theme.schemaVersion 1 1 'schemaVersion'
    if ($Theme.PSObject.Properties['$schema'] -and
        ($Theme.'$schema' -isnot [string] -or $Theme.'$schema'.Length -gt 200)) {
        throw '主题 $schema 必须是长度不超过 200 的字符串。'
    }
    if ($Theme.id -isnot [string] -or $Theme.id -cnotmatch '^[a-z][a-z0-9-]{2,47}$') {
        throw '主题 id 须为 3 到 48 个小写字母、数字或连字符，以字母开头。'
    }
    if ($Imported -and $Theme.id -in @('classic', 'native', 'instrument', 'paper')) {
        throw '此 id 为内置主题保留，请为自制主题更换 id。'
    }
    foreach ($entry in @(@('name', 40), @('description', 200))) {
        $value = $Theme.($entry[0])
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value) -or
            $value.Length -gt $entry[1] -or $value -match '[\x00-\x1F]') {
            throw "主题 $($entry[0]) 为空、过长或包含控制字符。"
        }
    }
    Assert-RmfThemeKeys $Theme.layout @('base', 'quotaStyle', 'heroAlignment') @() 'layout'
    if ($Theme.layout.base -cnotin @('classic', 'native', 'instrument', 'paper') -or
        $Theme.layout.quotaStyle -cnotin @('bar', 'ring', 'rail') -or
        $Theme.layout.heroAlignment -cnotin @('Left', 'Right')) {
        throw '主题 layout 的布局类型、进度类型或对齐方式不受支持。'
    }
    if ($Theme.layout.base -eq 'classic' -and
        ($Theme.layout.quotaStyle -ne 'bar' -or $Theme.layout.heroAlignment -ne 'Left')) {
        throw '经典布局仅支持横向进度条与左对齐，请选择其他布局骨架以自定义。'
    }
    $colorKeys = @('TextPrimary', 'TextSecondary', 'TextMuted', 'Surface',
        'SurfaceSubtle', 'Border', 'Divider', 'Track', 'SummarySurface',
        'SummaryBorder', 'ButtonSurface', 'ButtonHover', 'ButtonBorder',
        'BadgeSurface', 'BadgeBorder', 'BadgeText', 'Unknown')
    Assert-RmfThemeKeys $Theme.colors $colorKeys @() 'colors'
    foreach ($key in $colorKeys) {
        if ($Theme.colors.$key -isnot [string] -or $Theme.colors.$key -notmatch '^#[0-9A-Fa-f]{6}$') {
            throw "主题 colors.$key 必须为 #RRGGBB。"
        }
    }
    Assert-RmfThemeKeys $Theme.typography @('textFamily', 'numberFamily',
        'compactNumberSize', 'detailsNumberSize') @() 'typography'
    foreach ($key in @('textFamily', 'numberFamily')) {
        $font = $Theme.typography.$key
        if ($font -isnot [string] -or [string]::IsNullOrWhiteSpace($font) -or
            $font.Length -gt 80 -or $font -match '[\x00-\x1F:/\\#]') {
            throw "主题字体 $key 必须是本机字体名称，不能引用文件或网址。"
        }
    }
    Assert-RmfThemeNumber $Theme.typography.compactNumberSize 20 28 'compactNumberSize'
    Assert-RmfThemeNumber $Theme.typography.detailsNumberSize 32 52 'detailsNumberSize'
    Assert-RmfThemeKeys $Theme.shape @('windowRadius', 'cardRadius', 'progressThickness') @() 'shape'
    Assert-RmfThemeNumber $Theme.shape.windowRadius 6 18 'windowRadius'
    Assert-RmfThemeNumber $Theme.shape.cardRadius 0 12 'cardRadius'
    Assert-RmfThemeNumber $Theme.shape.progressThickness 2 6 'progressThickness'
    if ($Theme.quotaColors -isnot [array] -or $Theme.quotaColors.Count -lt 2 -or
        $Theme.quotaColors.Count -gt 12) { throw 'quotaColors 需要 2 到 12 个色阶。' }
    $previous = -1.0
    foreach ($stop in $Theme.quotaColors) {
        Assert-RmfThemeKeys $stop @('percent', 'color') @() 'quotaColors[]'
        Assert-RmfThemeNumber $stop.percent 0 100 'quotaColors[].percent'
        if ([double]$stop.percent -le $previous -or $stop.color -isnot [string] -or
            $stop.color -notmatch '^#[0-9A-Fa-f]{6}$') {
            throw '色阶须按百分比严格递增，颜色格式为 #RRGGBB。'
        }
        $previous = [double]$stop.percent
    }
    if ($Theme.quotaColors[0].percent -ne 0 -or $previous -ne 100) {
        throw '余量色阶须从 0 开始，以 100 结束。'
    }
    return $Theme
}

function Read-RmfThemeFile {
    param([string]$Path, [switch]$Imported)
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Extension -ne '.json' -or $file.Length -gt 131072) {
        throw '请选择不超过 128 KB 的 JSON 主题文件。'
    }
    try {
        $json = [IO.File]::ReadAllText($file.FullName, (New-Object Text.UTF8Encoding($false, $true)))
        $definition = ConvertFrom-Json $json -ErrorAction Stop
    } catch { throw '主题文件必须是有效的 UTF-8 JSON。' }
    return Assert-RmfThemeDefinition -Theme $definition -Imported:$Imported
}

function Initialize-RmfThemes {
    $script:RmfThemes = [ordered]@{}
    $bundled = Get-Variable -Name RmfBundledThemes -Scope Script -ErrorAction SilentlyContinue
    $builtinThemes = if ($bundled -and $bundled.Value) {
        @(ConvertFrom-Json $bundled.Value)
    } else {
        foreach ($id in @('classic', 'native', 'instrument', 'paper')) {
            Read-RmfThemeFile -Path (Join-Path $script:RmfSourceRoot "Themes\Builtin\$id.json")
        }
    }
    foreach ($theme in $builtinThemes) {
        $validated = Assert-RmfThemeDefinition -Theme $theme
        $script:RmfThemes[$validated.id] = $validated
    }
    $folder = Get-RmfThemeDirectory
    if (Test-Path -LiteralPath $folder) {
        foreach ($file in @(Get-ChildItem -LiteralPath $folder -Filter '*.json' -File | Select-Object -First 100)) {
            try {
                $theme = Read-RmfThemeFile -Path $file.FullName -Imported
                if (-not $script:RmfThemes.Contains($theme.id)) { $script:RmfThemes[$theme.id] = $theme }
            }
            catch {
                Write-RuntimeLog -Level Warning -Event 'Theme.LoadRejected' -Message $_.Exception.Message
            }
        }
    }
    $script:RmfActiveTheme = $script:RmfThemes['classic']
}

function Import-RmfTheme {
    param([string]$Path)
    $theme = Read-RmfThemeFile -Path $Path -Imported
    if ($script:RmfThemes.Contains($theme.id)) { throw '已存在相同 id 的主题，请修改 id 后重新导入。' }
    if ($script:RmfThemes.Count -ge 104) { throw '自制主题数量已达 100 个，请先整理主题目录。' }
    $folder = Get-RmfThemeDirectory
    [void][IO.Directory]::CreateDirectory($folder)
    $destination = Join-Path $folder ($theme.id + '.json')
    $json = $theme | ConvertTo-Json -Depth 8
    # CreateNew prevents a concurrent import or differently named duplicate from being overwritten.
    $stream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally { $stream.Dispose() }
    $script:RmfThemes[$theme.id] = $theme
    return $theme
}

function Get-RmfThemeQuotaColor {
    param([double]$Percent, [bool]$Available = $true, $Theme = $script:RmfActiveTheme)
    if (-not $Available) { return [Windows.Media.ColorConverter]::ConvertFromString($Theme.colors.Unknown) }
    $value = [Math]::Max(0.0, [Math]::Min(100.0, $Percent))
    $stops = @($Theme.quotaColors)
    for ($index = 1; $index -lt $stops.Count; $index++) {
        if ($value -le [double]$stops[$index].percent) {
            $from = $stops[$index - 1]
            $to = $stops[$index]
            $amount = ($value - [double]$from.percent) / ([double]$to.percent - [double]$from.percent)
            return Get-BlendedColor -From $from.color -To $to.color -Amount $amount
        }
    }
    return [Windows.Media.ColorConverter]::ConvertFromString($stops[-1].color)
}
