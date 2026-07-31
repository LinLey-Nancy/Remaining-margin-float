$script:StartupTaskName = 'Remaining Margin Float'
$script:StartupRegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:StartupRegistryName = 'RemainingMarginFloat'

function Get-StartupShortcutPath {
    $startupDirectory = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::Startup
    )
    return Join-Path $startupDirectory 'Remaining Margin Float.lnk'
}

function Get-InstalledApplicationRoot {
    try {
        $installed = Get-ItemProperty `
            -LiteralPath 'HKCU:\Software\RemainingMarginFloat' `
            -Name InstallLocation `
            -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace([string]$installed.InstallLocation)) {
            return ''
        }
        return [IO.Path]::GetFullPath([string]$installed.InstallLocation).
            TrimEnd([IO.Path]::DirectorySeparatorChar)
    }
    catch {
        return ''
    }
}

function Test-InstalledApplicationFiles {
    param(
        [string]$LauncherPath,
        [string]$ScriptPath
    )

    $installedRoot = Get-InstalledApplicationRoot
    if ([string]::IsNullOrWhiteSpace($installedRoot)) {
        return $false
    }
    $expectedLauncher = Join-Path $installedRoot 'RemainingMarginFloat.exe'
    $expectedScript = Join-Path $installedRoot 'RemainingMarginFloat.ps1'
    return (
        (Test-Path -LiteralPath $expectedLauncher -PathType Leaf) -and
        (Test-Path -LiteralPath $expectedScript -PathType Leaf) -and
        [IO.Path]::GetFullPath($LauncherPath).Equals(
            [IO.Path]::GetFullPath($expectedLauncher),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        [IO.Path]::GetFullPath($ScriptPath).Equals(
            [IO.Path]::GetFullPath($expectedScript),
            [StringComparison]::OrdinalIgnoreCase
        )
    )
}

function Get-StartupLaunchSpec {
    param([switch]$PrepareLauncher)

    $launcherPath = [Environment]::GetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_LAUNCHER',
        [EnvironmentVariableTarget]::Process
    )
    $packagedScriptPath = [Environment]::GetEnvironmentVariable(
        'REMAINING_MARGIN_FLOAT_SCRIPT',
        [EnvironmentVariableTarget]::Process
    )
    if (
        -not [string]::IsNullOrWhiteSpace($launcherPath) -and
        (Test-Path -LiteralPath $launcherPath -PathType Leaf) -and
        -not [string]::IsNullOrWhiteSpace($packagedScriptPath) -and
        (Test-Path -LiteralPath $packagedScriptPath -PathType Leaf)
    ) {
        if (Test-InstalledApplicationFiles `
            -LauncherPath $launcherPath `
            -ScriptPath $packagedScriptPath) {
            return [pscustomobject]@{
                FilePath = [IO.Path]::GetFullPath($launcherPath)
                Arguments = ''
                WorkingDirectory = Split-Path -Parent $launcherPath
                Source = 'InstalledExe'
            }
        }
        $launcherHash = (Get-FileHash -LiteralPath $launcherPath -Algorithm SHA256).
            Hash.ToLowerInvariant()
        $scriptHash = (Get-FileHash -LiteralPath $packagedScriptPath -Algorithm SHA256).
            Hash.ToLowerInvariant()
        $fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($launcherPath).FileVersion
        if ([string]::IsNullOrWhiteSpace($fileVersion)) {
            $fileVersion = 'unversioned'
        }
        $releaseId = '{0}-{1}-{2}' -f `
            ($fileVersion -replace '[^0-9A-Za-z._-]', '_'), `
            $launcherHash.Substring(0, 12), `
            $scriptHash.Substring(0, 12)
        $managedRoot = Join-Path (Get-AppDataDirectory) 'app'
        $managedDirectory = Join-Path $managedRoot $releaseId
        $managedLauncher = Join-Path $managedDirectory 'RemainingMarginFloat.exe'
        $managedScript = Join-Path $managedDirectory 'RemainingMarginFloat.ps1'
        if ($PrepareLauncher) {
            $managedMatches = (
                (Test-Path -LiteralPath $managedLauncher -PathType Leaf) -and
                (Test-Path -LiteralPath $managedScript -PathType Leaf) -and
                (Get-FileHash -LiteralPath $managedLauncher -Algorithm SHA256).
                    Hash.Equals($launcherHash, [StringComparison]::OrdinalIgnoreCase) -and
                (Get-FileHash -LiteralPath $managedScript -Algorithm SHA256).
                    Hash.Equals($scriptHash, [StringComparison]::OrdinalIgnoreCase)
            )
            if (-not $managedMatches) {
                if (Test-Path -LiteralPath $managedDirectory) {
                    throw "托管启动目录内容与当前版本不一致：$managedDirectory"
                }
                New-Item -Path $managedRoot -ItemType Directory -Force | Out-Null
                $stagingDirectory = Join-Path $managedRoot (
                    '.staging-{0}-{1}' -f $releaseId, [Guid]::NewGuid().ToString('N')
                )
                try {
                    New-Item -Path $stagingDirectory -ItemType Directory | Out-Null
                    $stagedLauncher = Join-Path $stagingDirectory 'RemainingMarginFloat.exe'
                    $stagedScript = Join-Path $stagingDirectory 'RemainingMarginFloat.ps1'
                    Copy-Item -LiteralPath $launcherPath -Destination $stagedLauncher
                    Copy-Item -LiteralPath $packagedScriptPath -Destination $stagedScript
                    if (
                        -not (Get-FileHash -LiteralPath $stagedLauncher -Algorithm SHA256).
                            Hash.Equals($launcherHash, [StringComparison]::OrdinalIgnoreCase) -or
                        -not (Get-FileHash -LiteralPath $stagedScript -Algorithm SHA256).
                            Hash.Equals($scriptHash, [StringComparison]::OrdinalIgnoreCase)
                    ) {
                        throw '托管启动文件复制后校验失败。'
                    }
                    Move-Item -LiteralPath $stagingDirectory -Destination $managedDirectory
                }
                finally {
                    if (Test-Path -LiteralPath $stagingDirectory) {
                        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
                    }
                }
            }
        }
        return [pscustomobject]@{
            FilePath = $managedLauncher
            Arguments = ''
            WorkingDirectory = Split-Path -Parent $managedLauncher
            Source = 'PackagedExe'
        }
    }

    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath = if (-not [string]::IsNullOrWhiteSpace($packagedScriptPath)) {
        [IO.Path]::GetFullPath($packagedScriptPath)
    } else {
        $script:RmfEntryScriptPath
    }
    return [pscustomobject]@{
        FilePath = $powershellPath
        Arguments = '-NoProfile -NonInteractive -STA -File "{0}"' -f (
            $scriptPath.Replace('"', '\"')
        )
        WorkingDirectory = Split-Path -Parent $scriptPath
        Source = 'PowerShell'
    }
}

function ConvertTo-StartupCommandLine {
    param($LaunchSpec)

    $commandLine = '"{0}"' -f ([string]$LaunchSpec.FilePath).Replace('"', '\"')
    if (-not [string]::IsNullOrWhiteSpace([string]$LaunchSpec.Arguments)) {
        $commandLine += ' ' + [string]$LaunchSpec.Arguments
    }
    return $commandLine
}

function Test-StartupNotFoundError {
    param([Exception]$Exception)

    return $Exception.HResult -in @(
        -2147024894, # 0x80070002: file not found
        -2147024893, # 0x80070003: path not found
        -2147216625  # 0x8004130F: scheduled task not found
    )
}

function Test-StartupPathEqual {
    param(
        [string]$Left,
        [string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }
    try {
        $leftFullPath = [IO.Path]::GetFullPath($Left.Trim('"'))
        $rightFullPath = [IO.Path]::GetFullPath($Right.Trim('"'))
        return [string]::Equals(
            $leftFullPath,
            $rightFullPath,
            [StringComparison]::OrdinalIgnoreCase
        )
    }
    catch {
        return $false
    }
}

function Release-ComReference {
    param($Value)

    if ($null -ne $Value -and [Runtime.InteropServices.Marshal]::IsComObject($Value)) {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($Value)
    }
}

function Test-StartupScheduledTask {
    param(
        $LaunchSpec,
        [switch]$PresenceOnly
    )

    $service = $null
    $root = $null
    $task = $null
    $action = $null
    try {
        $service = New-Object -ComObject 'Schedule.Service'
        $service.Connect()
        $root = $service.GetFolder('\')
        $task = $root.GetTask($script:StartupTaskName)
        if ($PresenceOnly) { return $true }
        if (-not $LaunchSpec -or -not $task.Enabled -or $task.Definition.Actions.Count -lt 1) {
            return $false
        }
        $action = $task.Definition.Actions.Item(1)
        return (
            (Test-StartupPathEqual -Left $action.Path -Right $LaunchSpec.FilePath) -and
            ([string]$action.Arguments).Trim() -eq ([string]$LaunchSpec.Arguments).Trim() -and
            (Test-Path -LiteralPath $LaunchSpec.FilePath -PathType Leaf)
        )
    }
    catch {
        if (Test-StartupNotFoundError -Exception $_.Exception) { return $false }
        throw
    }
    finally {
        Release-ComReference $action
        Release-ComReference $task
        Release-ComReference $root
        Release-ComReference $service
    }
}

function Test-StartupRegistry {
    param(
        $LaunchSpec,
        [switch]$PresenceOnly
    )

    $runKey = Get-ItemProperty `
        -LiteralPath $script:StartupRegistryPath `
        -Name $script:StartupRegistryName `
        -ErrorAction SilentlyContinue
    if (-not $runKey -or -not $runKey.PSObject.Properties[$script:StartupRegistryName]) {
        return $false
    }
    if ($PresenceOnly) { return $true }
    return (
        $LaunchSpec -and
        [string]::Equals(
            [string]$runKey.PSObject.Properties[$script:StartupRegistryName].Value,
            (ConvertTo-StartupCommandLine -LaunchSpec $LaunchSpec),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        (Test-Path -LiteralPath $LaunchSpec.FilePath -PathType Leaf)
    )
}

function Test-StartupShortcut {
    param(
        $LaunchSpec,
        [switch]$PresenceOnly
    )

    $shortcutPath = Get-StartupShortcutPath
    if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
        return $false
    }
    if ($PresenceOnly) { return $true }

    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject 'WScript.Shell'
        $shortcut = $shell.CreateShortcut($shortcutPath)
        return (
            $LaunchSpec -and
            (Test-StartupPathEqual -Left $shortcut.TargetPath -Right $LaunchSpec.FilePath) -and
            ([string]$shortcut.Arguments).Trim() -eq ([string]$LaunchSpec.Arguments).Trim() -and
            (Test-Path -LiteralPath $LaunchSpec.FilePath -PathType Leaf)
        )
    }
    finally {
        Release-ComReference $shortcut
        Release-ComReference $shell
    }
}

function Get-StartupMode {
    $launchSpec = Get-StartupLaunchSpec
    if (Test-StartupScheduledTask -LaunchSpec $launchSpec) { return 'Task' }
    if (Test-StartupRegistry -LaunchSpec $launchSpec) { return 'Registry' }
    if (Test-StartupShortcut -LaunchSpec $launchSpec) { return 'StartupFolder' }
    return 'Off'
}

function Remove-StartupRegistrations {
    param(
        [ValidateSet('None', 'Task', 'Registry', 'StartupFolder')]
        [string]$Except = 'None'
    )

    if ($Except -ne 'Task' -and (Test-StartupScheduledTask -PresenceOnly)) {
        $service = $null
        $root = $null
        try {
            $service = New-Object -ComObject 'Schedule.Service'
            $service.Connect()
            $root = $service.GetFolder('\')
            $root.DeleteTask($script:StartupTaskName, 0)
        }
        finally {
            Release-ComReference $root
            Release-ComReference $service
        }
    }

    if ($Except -ne 'Registry' -and (Test-StartupRegistry -PresenceOnly)) {
        Remove-ItemProperty `
            -LiteralPath $script:StartupRegistryPath `
            -Name $script:StartupRegistryName `
            -ErrorAction Stop
    }

    $shortcutPath = Get-StartupShortcutPath
    if (
        $Except -ne 'StartupFolder' -and
        (Test-Path -LiteralPath $shortcutPath -PathType Leaf)
    ) {
        Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction Stop
    }
}

function Register-StartupScheduledTask {
    param($LaunchSpec)

    $service = $null
    $root = $null
    $definition = $null
    $trigger = $null
    $action = $null
    try {
        $service = New-Object -ComObject 'Schedule.Service'
        $service.Connect()
        $root = $service.GetFolder('\')
        $definition = $service.NewTask(0)
        $definition.RegistrationInfo.Description = '登录 Windows 后启动 Remaining Margin Float'
        $definition.Settings.Enabled = $true
        $definition.Settings.StartWhenAvailable = $true
        $definition.Settings.DisallowStartIfOnBatteries = $false
        $definition.Settings.StopIfGoingOnBatteries = $false
        $definition.Settings.ExecutionTimeLimit = 'PT0S'
        $definition.Settings.MultipleInstances = 2

        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $definition.Principal.UserId = $identity
        $definition.Principal.LogonType = 3
        $definition.Principal.RunLevel = 0

        $trigger = $definition.Triggers.Create(9)
        $trigger.Enabled = $true
        $trigger.UserId = $identity
        $action = $definition.Actions.Create(0)
        $action.Path = $LaunchSpec.FilePath
        $action.Arguments = $LaunchSpec.Arguments
        $action.WorkingDirectory = $LaunchSpec.WorkingDirectory

        [void]$root.RegisterTaskDefinition(
            $script:StartupTaskName,
            $definition,
            6,
            $identity,
            $null,
            3,
            $null
        )
    }
    finally {
        Release-ComReference $action
        Release-ComReference $trigger
        Release-ComReference $definition
        Release-ComReference $root
        Release-ComReference $service
    }
}

function Register-StartupRegistry {
    param($LaunchSpec)

    if (-not (Test-Path -LiteralPath $script:StartupRegistryPath)) {
        [void](New-Item -Path $script:StartupRegistryPath -Force)
    }
    [void](New-ItemProperty `
        -LiteralPath $script:StartupRegistryPath `
        -Name $script:StartupRegistryName `
        -Value (ConvertTo-StartupCommandLine -LaunchSpec $LaunchSpec) `
        -PropertyType String `
        -Force)
}

function Register-StartupShortcut {
    param($LaunchSpec)

    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject 'WScript.Shell'
        $shortcut = $shell.CreateShortcut((Get-StartupShortcutPath))
        $shortcut.TargetPath = $LaunchSpec.FilePath
        $shortcut.Arguments = $LaunchSpec.Arguments
        $shortcut.WorkingDirectory = $LaunchSpec.WorkingDirectory
        $shortcut.Description = '启动 Remaining Margin Float'
        $shortcut.Save()
    }
    finally {
        Release-ComReference $shortcut
        Release-ComReference $shell
    }
}

function Get-StartupRegistrationPresence {
    return [ordered]@{
        Task = Test-StartupScheduledTask -PresenceOnly
        Registry = Test-StartupRegistry -PresenceOnly
        StartupFolder = Test-StartupShortcut -PresenceOnly
    }
}

function Sync-PackagedStartupLauncher {
    try {
        $launcherPath = [Environment]::GetEnvironmentVariable(
            'REMAINING_MARGIN_FLOAT_LAUNCHER',
            [EnvironmentVariableTarget]::Process
        )
        if ([string]::IsNullOrWhiteSpace($launcherPath)) { return }

        $presence = Get-StartupRegistrationPresence
        if ($presence.Task -or $presence.Registry -or $presence.StartupFolder) {
            $launchSpec = Get-StartupLaunchSpec -PrepareLauncher
            $existingMode = if ($presence.Task) {
                'Task'
            }
            elseif ($presence.Registry) {
                'Registry'
            }
            else {
                'StartupFolder'
            }
            switch ($existingMode) {
                'Task' { Register-StartupScheduledTask -LaunchSpec $launchSpec }
                'Registry' { Register-StartupRegistry -LaunchSpec $launchSpec }
                'StartupFolder' { Register-StartupShortcut -LaunchSpec $launchSpec }
            }
            Remove-StartupRegistrations -Except $existingMode
            Assert-StartupMode -Mode $existingMode -LaunchSpec $launchSpec
        }
    }
    catch {
        # Startup remains usable from its last known-good managed launcher.
    }
}

function Assert-StartupMode {
    param(
        [ValidateSet('Off', 'Task', 'Registry', 'StartupFolder')]
        [string]$Mode,
        $LaunchSpec
    )

    $presence = Get-StartupRegistrationPresence
    foreach ($candidate in @('Task', 'Registry', 'StartupFolder')) {
        $shouldExist = ($Mode -eq $candidate)
        if ([bool]$presence[$candidate] -ne $shouldExist) {
            throw "开机启动设置未达到唯一模式：$Mode。"
        }
    }
    if ($Mode -ne 'Off') {
        $isValid = switch ($Mode) {
            'Task' { Test-StartupScheduledTask -LaunchSpec $LaunchSpec }
            'Registry' { Test-StartupRegistry -LaunchSpec $LaunchSpec }
            'StartupFolder' { Test-StartupShortcut -LaunchSpec $LaunchSpec }
        }
        if (-not $isValid) {
            throw "开机启动入口已创建，但目标或参数校验失败：$Mode。"
        }
    }
}

function Sync-StartupMenuState {
    foreach ($mode in @('Off', 'Task', 'Registry', 'StartupFolder')) {
        if ($script:StartupMenuItems.ContainsKey($mode)) {
            $script:StartupMenuItems[$mode].IsChecked = ($script:StartupMode -eq $mode)
        }
        if ($script:TrayStartupItems.ContainsKey($mode)) {
            $script:TrayStartupItems[$mode].Checked = ($script:StartupMode -eq $mode)
        }
    }
}

function Set-StartupMode {
    param(
        [ValidateSet('Off', 'Task', 'Registry', 'StartupFolder')]
        [string]$Mode,
        [switch]$Silent
    )

    $previousMode = Get-StartupMode
    try {
        $launchSpec = if ($Mode -eq 'Off') {
            $null
        } else {
            Get-StartupLaunchSpec -PrepareLauncher
        }
        switch ($Mode) {
            'Task' { Register-StartupScheduledTask -LaunchSpec $launchSpec }
            'Registry' { Register-StartupRegistry -LaunchSpec $launchSpec }
            'StartupFolder' { Register-StartupShortcut -LaunchSpec $launchSpec }
        }
        Remove-StartupRegistrations -Except $(if ($Mode -eq 'Off') { 'None' } else { $Mode })
        Assert-StartupMode -Mode $Mode -LaunchSpec $launchSpec
        $script:StartupMode = $Mode
        Sync-StartupMenuState
        return $true
    }
    catch {
        $originalError = $_.Exception.Message
        try {
            if ($previousMode -eq 'Off') {
                Remove-StartupRegistrations
            }
            else {
                $rollbackSpec = Get-StartupLaunchSpec -PrepareLauncher
                switch ($previousMode) {
                    'Task' { Register-StartupScheduledTask -LaunchSpec $rollbackSpec }
                    'Registry' { Register-StartupRegistry -LaunchSpec $rollbackSpec }
                    'StartupFolder' { Register-StartupShortcut -LaunchSpec $rollbackSpec }
                }
                Remove-StartupRegistrations -Except $previousMode
                Assert-StartupMode -Mode $previousMode -LaunchSpec $rollbackSpec
            }
        }
        catch {
            $originalError += "`n回滚旧设置也失败：$($_.Exception.Message)"
        }
        $script:StartupMode = Get-StartupMode
        Sync-StartupMenuState
        if (-not $Silent) {
            [void][Windows.MessageBox]::Show(
                "无法更新开机启动设置。`n`n$originalError",
                'Remaining Margin Float',
                [Windows.MessageBoxButton]::OK,
                [Windows.MessageBoxImage]::Warning
            )
        }
        return $false
    }
}

function Get-AppSettingsSnapshot {
    $saveLeft = if ($script:EdgeDockSide) {
        $workArea = Get-EdgeDockWorkArea
        Get-EdgeDockPlacement `
            -Side $script:EdgeDockSide `
            -Revealed $true `
            -WindowWidth $script:CompactWidth `
            -VisibleWidth $script:EdgeVisibleWidth `
            -WorkLeft $workArea.Left `
            -WorkRight $workArea.Right
    }
    elseif ($null -ne $script:CompactAnchorLeft) {
        $script:CompactAnchorLeft
    } else {
        $window.Left
    }
    $saveTop = if ($null -ne $script:CompactAnchorTop) {
        $script:CompactAnchorTop
    } else {
        $window.Top
    }
    return [pscustomobject][ordered]@{
        Left = $saveLeft
        Top = $saveTop
        Expanded = $false
        Topmost = $window.Topmost
        Provider = $script:ActiveProvider
        CodexOfficialAccessEnabled = $script:CodexOfficialAccessEnabled
        AutoUpdateEnabled = $script:AutoUpdateEnabled
        LowRemainingAlertsEnabled = $script:LowRemainingAlertsEnabled
        LowRemainingThreshold = $script:LowRemainingThreshold
        RapidDropAlertsEnabled = $script:RapidDropAlertsEnabled
        RapidDropWindowMinutes = $script:RapidDropWindowMinutes
        CodexRapidDropPercent = $script:CodexRapidDropPercent
        DeepSeekRapidDropMode = $script:DeepSeekRapidDropMode
        DeepSeekRapidDropPercent = $script:DeepSeekRapidDropPercent
        DeepSeekRapidDropAmount = $script:DeepSeekRapidDropAmount
        EdgeDockEnabled = $script:EdgeDockEnabled
        EdgeDockSide = $script:EdgeDockSide
    }
}

function Save-Settings {
    param([switch]$ThrowOnError)

    if ($isDiagnosticRun -or $script:IsRestoringSettings) { return }

    try {
        Get-AppSettingsSnapshot |
            ConvertTo-Json |
            Set-Content -LiteralPath (Get-SettingsPath) -Encoding UTF8
    }
    catch {
        if ($ThrowOnError) { throw }
        # 设置持久化失败时不影响悬浮窗继续运行。
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
            if ($settings.PSObject.Properties['EdgeDockEnabled']) {
                $script:EdgeDockEnabled = [bool]$settings.EdgeDockEnabled
            }
            if (
                $script:EdgeDockEnabled -and
                $settings.PSObject.Properties['EdgeDockSide'] -and
                [string]$settings.EdgeDockSide -in @('Left', 'Right')
            ) {
                $script:EdgeDockSide = [string]$settings.EdgeDockSide
            }
            if (
                $settings.PSObject.Properties['Provider'] -and
                [string]$settings.Provider -in @('Codex', 'DeepSeek')
            ) {
                $script:ActiveProvider = [string]$settings.Provider
            }
            if ($settings.PSObject.Properties['CodexOfficialAccessEnabled']) {
                $script:CodexOfficialAccessEnabled =
                    [bool]$settings.CodexOfficialAccessEnabled
            }
            if ($settings.PSObject.Properties['AutoUpdateEnabled']) {
                $script:AutoUpdateEnabled =
                    [bool]$settings.AutoUpdateEnabled
            }
            if ($settings.PSObject.Properties['LowRemainingAlertsEnabled']) {
                $script:LowRemainingAlertsEnabled =
                    [bool]$settings.LowRemainingAlertsEnabled
            }
            if ($settings.PSObject.Properties['LowRemainingThreshold']) {
                $script:LowRemainingThreshold = ConvertTo-LowRemainingThreshold `
                    -Value $settings.LowRemainingThreshold `
                    -Fallback $script:LowRemainingThreshold
            }
            if ($settings.PSObject.Properties['RapidDropAlertsEnabled']) {
                $script:RapidDropAlertsEnabled =
                    [bool]$settings.RapidDropAlertsEnabled
            }
            if ($settings.PSObject.Properties['RapidDropWindowMinutes']) {
                $script:RapidDropWindowMinutes =
                    ConvertTo-RapidDropWindowMinutes `
                        -Value $settings.RapidDropWindowMinutes `
                        -Fallback $script:RapidDropWindowMinutes
            }
            if ($settings.PSObject.Properties['CodexRapidDropPercent']) {
                $script:CodexRapidDropPercent =
                    ConvertTo-RapidDropPercent `
                        -Value $settings.CodexRapidDropPercent `
                        -Fallback $script:CodexRapidDropPercent
            }
            if (
                $settings.PSObject.Properties['DeepSeekRapidDropMode'] -and
                [string]$settings.DeepSeekRapidDropMode -in @('Percent', 'Amount')
            ) {
                $script:DeepSeekRapidDropMode =
                    [string]$settings.DeepSeekRapidDropMode
            }
            if ($settings.PSObject.Properties['DeepSeekRapidDropPercent']) {
                $script:DeepSeekRapidDropPercent =
                    ConvertTo-RapidDropPercent `
                        -Value $settings.DeepSeekRapidDropPercent `
                        -Fallback $script:DeepSeekRapidDropPercent
            }
            if ($settings.PSObject.Properties['DeepSeekRapidDropAmount']) {
                $script:DeepSeekRapidDropAmount =
                    ConvertTo-RapidDropAmount `
                        -Value $settings.DeepSeekRapidDropAmount `
                        -Fallback $script:DeepSeekRapidDropAmount
            }
        }
    }
    catch {
        $script:IsExpanded = $false
    }

    if (
        $script:AutoUpdateEnabled -and
        -not (Test-AutoUpdateInstalledMode)
    ) {
        $script:AutoUpdateEnabled = $false
    }

    if ($Demo) {
        $script:ActiveProvider = if ($DemoProvider -eq 'deepseek') { 'DeepSeek' } else { 'Codex' }
    }
}
