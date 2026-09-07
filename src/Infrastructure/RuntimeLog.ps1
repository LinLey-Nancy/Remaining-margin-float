$script:RuntimeLogPath = $null
$script:RuntimeLogSessionId = [Guid]::NewGuid().ToString('N')
$script:RuntimeLogMaxBytes = 2MB
$script:RuntimeLogBackupCount = 4

function Get-RuntimeLogDirectory {
    param([string]$RootPath = '')

    if (-not [string]::IsNullOrWhiteSpace($RootPath)) {
        return [IO.Path]::GetFullPath($RootPath)
    }
    return Join-Path (Get-AppDataDirectory) 'logs'
}

function Get-RuntimeLogPath {
    param([string]$RootPath = '')

    return Join-Path (Get-RuntimeLogDirectory -RootPath $RootPath) 'runtime.log'
}

function Protect-RuntimeLogText {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $safe = $Text
    foreach ($path in @($env:USERPROFILE, $env:LOCALAPPDATA)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $replacement = if ($path -eq $env:USERPROFILE) {
            '%USERPROFILE%'
        } else {
            '%LOCALAPPDATA%'
        }
        $safe = [regex]::Replace(
            $safe,
            [regex]::Escape($path),
            $replacement,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }
    $safe = [regex]::Replace(
        $safe,
        '(?i)\b(?:api[_\s-]?key|access[_\s-]?token|refresh[_\s-]?token|authorization|password)\b\s*[:=]\s*(?:bearer\s+)?["'']?[^\s,;"'']+',
        '[redacted-credential]'
    )
    $safe = [regex]::Replace(
        $safe,
        '(?i)\bbearer\s+[A-Za-z0-9._~+/-]{8,}=*',
        '[redacted-credential]'
    )
    $safe = [regex]::Replace(
        $safe,
        '(?i)\b(?:sk-[A-Za-z0-9_-]{8,}|[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})\b',
        '[redacted-credential]'
    )
    $safe = [regex]::Replace(
        $safe,
        '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b',
        '[redacted-email]'
    )
    if ($safe.Length -gt 500) {
        $safe = $safe.Substring(0, 500) + '...'
    }
    return $safe.Trim()
}

function Move-RuntimeLogFiles {
    param([Parameter(Mandatory = $true)][string]$Path)

    for ($index = $script:RuntimeLogBackupCount; $index -ge 1; $index--) {
        $source = if ($index -eq 1) { $Path } else { "$Path.$($index - 1)" }
        $destination = "$Path.$index"
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            Remove-Item -LiteralPath $destination -Force
        }
        Move-Item -LiteralPath $source -Destination $destination
    }
}

function Initialize-RuntimeLog {
    param(
        [string]$RootPath = '',
        [long]$MaxBytes = 2MB,
        [ValidateRange(1, 10)]
        [int]$BackupCount = 4,
        [switch]$SkipStartEntry
    )

    try {
        $directory = Get-RuntimeLogDirectory -RootPath $RootPath
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            [void](New-Item -Path $directory -ItemType Directory -Force)
        }
        $script:RuntimeLogPath = Get-RuntimeLogPath -RootPath $directory
        $script:RuntimeLogMaxBytes = [Math]::Max(1024, $MaxBytes)
        $script:RuntimeLogBackupCount = $BackupCount
        if (
            (Test-Path -LiteralPath $script:RuntimeLogPath -PathType Leaf) -and
            (Get-Item -LiteralPath $script:RuntimeLogPath).Length -ge
                $script:RuntimeLogMaxBytes
        ) {
            Move-RuntimeLogFiles -Path $script:RuntimeLogPath
        }
        if (-not $SkipStartEntry) {
            Write-RuntimeLog `
                -Event 'App.SessionStarted' `
                -Message 'Runtime logging initialized'
        }
        return $script:RuntimeLogPath
    }
    catch {
        $script:RuntimeLogPath = $null
        return $null
    }
}

function Write-RuntimeLog {
    param(
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Level = 'Info',
        [Parameter(Mandatory = $true)]
        [string]$Event,
        [AllowEmptyString()]
        [string]$Message = '',
        [long]$ElapsedMilliseconds = -1,
        [Collections.IDictionary]$Data
    )

    try {
        if ([string]::IsNullOrWhiteSpace($script:RuntimeLogPath)) {
            if ($isDiagnosticRun) { return }
            [void](Initialize-RuntimeLog -SkipStartEntry)
        }
        if ([string]::IsNullOrWhiteSpace($script:RuntimeLogPath)) { return }

        $safeData = [ordered]@{}
        if ($Data) {
            foreach ($key in @($Data.Keys | Sort-Object { [string]$_ })) {
                $value = $Data[$key]
                $safeData[[string]$key] = if ($null -eq $value) {
                    $null
                }
                elseif (
                    $value -is [bool] -or
                    $value -is [byte] -or
                    $value -is [int16] -or
                    $value -is [int32] -or
                    $value -is [int64] -or
                    $value -is [single] -or
                    $value -is [double] -or
                    $value -is [decimal]
                ) {
                    $value
                }
                else {
                    Protect-RuntimeLogText -Text ([string]$value)
                }
            }
        }
        $record = [ordered]@{
            ts = [DateTimeOffset]::Now.ToUniversalTime().ToString(
                'o',
                [Globalization.CultureInfo]::InvariantCulture
            )
            level = $Level
            event = Protect-RuntimeLogText -Text $Event
            message = Protect-RuntimeLogText -Text $Message
            session = $script:RuntimeLogSessionId
            pid = $PID
            version = [string]$script:AppVersion
        }
        if ($ElapsedMilliseconds -ge 0) {
            $record.elapsedMs = $ElapsedMilliseconds
        }
        if ($safeData.Count -gt 0) {
            $record.data = $safeData
        }
        $line = ($record | ConvertTo-Json -Depth 4 -Compress) +
            [Environment]::NewLine
        $encoding = New-Object Text.UTF8Encoding($false)
        $lineBytes = $encoding.GetByteCount($line)
        if (
            (Test-Path -LiteralPath $script:RuntimeLogPath -PathType Leaf) -and
            ((Get-Item -LiteralPath $script:RuntimeLogPath).Length + $lineBytes) -gt
                $script:RuntimeLogMaxBytes
        ) {
            Move-RuntimeLogFiles -Path $script:RuntimeLogPath
        }
        [IO.File]::AppendAllText($script:RuntimeLogPath, $line, $encoding)
    }
    catch {
        # Logging must never prevent the application from starting or closing.
    }
}

function Get-RuntimeLogTail {
    param(
        [ValidateRange(1, 1000)]
        [int]$MaxLines = 200,
        [string]$Path = ''
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = $script:RuntimeLogPath
    }
    if (
        [string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)
    ) {
        return @()
    }
    return @(
        Get-Content -LiteralPath $Path -Encoding UTF8 -Tail $MaxLines |
            ForEach-Object { Protect-RuntimeLogText -Text $_ }
    )
}

function Open-RuntimeLogDirectory {
    $directory = Get-RuntimeLogDirectory
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -Path $directory -ItemType Directory -Force)
    }
    Start-Process -FilePath 'explorer.exe' -ArgumentList @($directory)
}

function Invoke-RuntimeLogDiagnostic {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $diagnosticRoot = [IO.Path]::GetFullPath((Join-Path $tempRoot (
        'RemainingMarginFloat.RuntimeLog.{0}.{1}' -f
            $PID,
            [Guid]::NewGuid().ToString('N')
    )))
    if (-not $diagnosticRoot.StartsWith(
        $tempRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Runtime log diagnostic escaped the temporary directory.'
    }

    $previousPath = $script:RuntimeLogPath
    $previousMaxBytes = $script:RuntimeLogMaxBytes
    $previousBackupCount = $script:RuntimeLogBackupCount
    $result = [ordered]@{
        WritesJsonLines = $false
        RotationBounded = $false
        CredentialsRedacted = $false
        PersonalDataRedacted = $false
        TailReadable = $false
        TemporaryFilesCleaned = $false
    }
    try {
        [void](Initialize-RuntimeLog `
            -RootPath $diagnosticRoot `
            -MaxBytes 1024 `
            -BackupCount 2 `
            -SkipStartEntry)
        $credential = 'rmf-diagnostic-secret-123456789'
        $bareCredential = 'sk-rmfdiagnostic123456789'
        $email = 'diagnostic@example.com'
        for ($index = 0; $index -lt 24; $index++) {
            Write-RuntimeLog `
                -Level $(if ($index % 7 -eq 0) { 'Warning' } else { 'Info' }) `
                -Event 'Diagnostic.RuntimeLog' `
                -Message (
                    'authorization=Bearer {0} token={1} email={2} path={3} item={4} {5}' -f
                        $credential,
                        $bareCredential,
                        $email,
                        $env:USERPROFILE,
                        $index,
                        ('x' * 90)
                ) `
                -ElapsedMilliseconds $index `
                -Data @{ Index = $index; Owner = $email }
        }

        $files = @(Get-ChildItem -LiteralPath $diagnosticRoot -File |
            Where-Object { $_.Name -match '^runtime\.log(?:\.\d+)?$' })
        $allLines = @($files | ForEach-Object {
            Get-Content -LiteralPath $_.FullName -Encoding UTF8
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $jsonLines = @($allLines | ForEach-Object {
            try { $_ | ConvertFrom-Json } catch { $null }
        } | Where-Object { $null -ne $_ })
        $combined = $allLines -join [Environment]::NewLine
        $tail = @(Get-RuntimeLogTail -MaxLines 5)
        $result.WritesJsonLines = (
            $allLines.Count -gt 0 -and
            $jsonLines.Count -eq $allLines.Count
        )
        $result.RotationBounded = (
            $files.Count -ge 2 -and
            $files.Count -le 3 -and
            @($files | Where-Object { $_.Name -eq 'runtime.log.3' }).Count -eq 0
        )
        $result.CredentialsRedacted = (
            $combined -notmatch [regex]::Escape($credential) -and
            $combined -notmatch [regex]::Escape($bareCredential) -and
            $combined -match '\[redacted-credential\]'
        )
        $result.PersonalDataRedacted = (
            $combined -notmatch [regex]::Escape($email) -and
            $combined -notmatch [regex]::Escape($env:USERPROFILE) -and
            $combined -match '\[redacted-email\]'
        )
        $result.TailReadable = $tail.Count -gt 0
    }
    finally {
        $script:RuntimeLogPath = $previousPath
        $script:RuntimeLogMaxBytes = $previousMaxBytes
        $script:RuntimeLogBackupCount = $previousBackupCount
        if (
            (Test-Path -LiteralPath $diagnosticRoot) -and
            $diagnosticRoot.StartsWith(
                $tempRoot,
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            Remove-Item -LiteralPath $diagnosticRoot -Recurse -Force
        }
        $result.TemporaryFilesCleaned = -not (
            Test-Path -LiteralPath $diagnosticRoot
        )
    }
    return [pscustomobject]$result
}

if (-not $isDiagnosticRun) {
    [void](Initialize-RuntimeLog)
    Write-RuntimeLog `
        -Event 'App.Bootstrap.Completed' `
        -Message 'Core runtime initialized' `
        -ElapsedMilliseconds $script:RmfStartupStopwatch.ElapsedMilliseconds
}
