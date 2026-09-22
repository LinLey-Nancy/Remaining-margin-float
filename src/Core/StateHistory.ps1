function Get-UsageStateHistoryDirectory {
    param([string]$RootPath = '')

    if (-not [string]::IsNullOrWhiteSpace($RootPath)) {
        return [IO.Path]::GetFullPath($RootPath)
    }
    return Join-Path (Get-AppDataDirectory) 'state-history'
}

function Get-UsageStateManifestPath {
    param([string]$RootPath = '')

    return Join-Path (Get-UsageStateHistoryDirectory -RootPath $RootPath) `
        'manifest.json'
}

function Get-UsageStateCurrentPath {
    param([string]$RootPath = '')

    return Join-Path (Get-UsageStateHistoryDirectory -RootPath $RootPath) `
        'current.json'
}

function Get-UsageStateObjectsDirectory {
    param([string]$RootPath = '')

    return Join-Path (Get-UsageStateHistoryDirectory -RootPath $RootPath) `
        'objects'
}

function Get-UsageStateEntriesDirectory {
    param([string]$RootPath = '')

    return Join-Path (Get-UsageStateHistoryDirectory -RootPath $RootPath) `
        'entries'
}

function Get-UsageStateJournalPath {
    param(
        [DateTimeOffset]$ObservedAt,
        [string]$RootPath = ''
    )

    $fileName = $ObservedAt.ToUniversalTime().ToString(
        'yyyyMMdd',
        [Globalization.CultureInfo]::InvariantCulture
    ) + '.jsonl'
    return Join-Path (Get-UsageStateEntriesDirectory -RootPath $RootPath) `
        $fileName
}

function ConvertTo-UsageStatePayloadValue {
    param(
        $Value,
        [switch]$Root
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) {
        return $Value.ToUniversalTime().ToString(
            'o',
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    if ($Value -is [DateTime]) {
        return ([DateTimeOffset]$Value).ToUniversalTime().ToString(
            'o',
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    if (
        $Value -is [string] -or
        $Value -is [char] -or
        $Value -is [bool] -or
        $Value -is [byte] -or
        $Value -is [sbyte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64] -or
        $Value -is [single] -or
        $Value -is [double] -or
        $Value -is [decimal]
    ) {
        return $Value
    }

    if ($Value -is [Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object { [string]$_ })) {
            $result[[string]$key] = ConvertTo-UsageStatePayloadValue `
                -Value $Value[$key]
        }
        return $result
    }

    if ($Value -is [Collections.IEnumerable]) {
        $items = New-Object Collections.Generic.List[object]
        foreach ($item in $Value) {
            $items.Add((ConvertTo-UsageStatePayloadValue -Value $item))
        }
        return ,$items.ToArray()
    }

    $properties = @(
        $Value.PSObject.Properties | Where-Object {
            $_.MemberType -in @('NoteProperty', 'Property')
        } | Sort-Object Name
    )
    if ($properties.Count -eq 0) {
        return [string]$Value
    }

    $safeProperties = [ordered]@{}
    foreach ($property in $properties) {
        if ($Root -and $property.Name -eq 'SampledAt') { continue }
        if ($property.Name -match '(?i)(ApiKey|AccessToken|RefreshToken|Authorization|Credential|Password)') {
            continue
        }
        $safeProperties[$property.Name] = ConvertTo-UsageStatePayloadValue `
            -Value $property.Value
    }
    return $safeProperties
}

function Get-UsageStatePayloadHash {
    param([Parameter(Mandatory = $true)][string]$PayloadJson)

    $bytes = [Text.Encoding]::UTF8.GetBytes($PayloadJson)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $algorithm.ComputeHash($bytes)
        return -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $algorithm.Dispose()
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Write-UsageStateAtomicText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void](New-Item -Path $parent -ItemType Directory -Force)
    }
    $temporaryPath = '{0}.tmp.{1}.{2}' -f
        $Path,
        $PID,
        [Guid]::NewGuid().ToString('N')
    $backupPath = '{0}.bak.{1}.{2}' -f
        $Path,
        $PID,
        [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporaryPath,
            $Text,
            (New-Object Text.UTF8Encoding($false))
        )
        # Retry atomic replace on IOException (e.g., AV scanning the file)
        $maxRetries = 3
        $retryDelayMs = 50
        for ($attempt = 0; $attempt -le $maxRetries; $attempt++) {
            try {
                if (Test-Path -LiteralPath $Path -PathType Leaf) {
                    [IO.File]::Replace($temporaryPath, $Path, $backupPath, $true)
                }
                else {
                    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
                }
                break
            }
            catch [System.IO.IOException] {
                if ($attempt -ge $maxRetries) { throw }
                Start-Sleep -Milliseconds $retryDelayMs
                $retryDelayMs *= 2
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function ConvertFrom-UsageStateEntry {
    param($Saved)

    if (-not $Saved) { return $null }
    $providerId = [string]$Saved.ProviderId
    $payloadHash = [string]$Saved.PayloadHash
    if (
        $providerId -notin @('Codex', 'DeepSeek', 'Kimi') -or
        $payloadHash -notmatch '^[0-9a-f]{64}$'
    ) {
        return $null
    }
    try {
        $observedAt = [DateTimeOffset]::Parse(
            [string]$Saved.ObservedAtUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
        $sampledAt = [DateTimeOffset]::Parse(
            [string]$Saved.SampledAtUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
    }
    catch {
        return $null
    }

    return [pscustomobject]@{
        Version = 1
        EntryId = [string]$Saved.EntryId
        ProviderId = $providerId
        ObservedAtUtc = $observedAt
        SampledAtUtc = $sampledAt
        PayloadHash = $payloadHash
        Reason = if ($Saved.PSObject.Properties['Reason']) {
            [string]$Saved.Reason
        } else { 'Refresh' }
        AppVersion = if ($Saved.PSObject.Properties['AppVersion']) {
            [string]$Saved.AppVersion
        } else { '' }
    }
}

function Select-UsageStateRetentionWindow {
    param(
        [object[]]$Entries,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    $cutoff = $Now.ToUniversalTime().AddHours(-168)
    $futureLimit = $Now.ToUniversalTime().AddMinutes(5)
    return @(
        $Entries | Where-Object {
            $_ -and
            ([DateTimeOffset]$_.ObservedAtUtc).ToUniversalTime() -ge $cutoff -and
            ([DateTimeOffset]$_.ObservedAtUtc).ToUniversalTime() -le $futureLimit
        } | Sort-Object ObservedAtUtc
    )
}

function Read-UsageStateCurrentEntries {
    param(
        [string]$RootPath = '',
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    $path = Get-UsageStateCurrentPath -RootPath $RootPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    try {
        $file = Get-Item -LiteralPath $path
        if ($file.Length -gt 1MB) { return @() }
        $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 |
            ConvertFrom-Json
        if (-not $saved -or [int]$saved.v -ne 1) { return @() }

        $entries = New-Object Collections.Generic.List[object]
        foreach ($savedEntry in @($saved.Latest)) {
            $entry = ConvertFrom-UsageStateEntry -Saved $savedEntry
            if ($entry) { $entries.Add($entry) }
        }
        return @(
            Select-UsageStateRetentionWindow -Entries $entries -Now $Now
        )
    }
    catch {
        return @()
    }
}

function Read-LegacyUsageStateEntries {
    param(
        [string]$RootPath = '',
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    $path = Get-UsageStateManifestPath -RootPath $RootPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @()
    }
    try {
        $file = Get-Item -LiteralPath $path
        if ($file.LastWriteTimeUtc -lt $Now.ToUniversalTime().AddHours(-168).UtcDateTime) {
            return @()
        }
        if ($file.Length -gt 64MB) {
            throw '全量状态索引超过 64 MB 安全上限。'
        }
        $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 |
            ConvertFrom-Json
        if (-not $saved -or [int]$saved.v -ne 1) {
            throw '全量状态索引格式不受支持。'
        }

        $entries = New-Object Collections.Generic.List[object]
        foreach ($savedEntry in @($saved.Entries)) {
            $entry = ConvertFrom-UsageStateEntry -Saved $savedEntry
            if ($entry) { $entries.Add($entry) }
        }
        return @(
            Select-UsageStateRetentionWindow -Entries $entries -Now $Now
        )
    }
    catch {
        return @()
    }
}

function Read-JournalUsageStateEntries {
    param(
        [string]$RootPath = '',
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    $directory = Get-UsageStateEntriesDirectory -RootPath $RootPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        return @()
    }
    $cutoffDate = $Now.ToUniversalTime().AddHours(-168).Date
    $items = New-Object Collections.Generic.List[object]
    foreach ($file in @(
        Get-ChildItem -LiteralPath $directory -File -Filter '*.jsonl' |
            Sort-Object Name
    )) {
        if ($file.Name -notmatch '^(?<date>\d{8})\.jsonl$') { continue }
        $fileDate = [DateTime]::MinValue
        if (-not [DateTime]::TryParseExact(
            $matches.date,
            'yyyyMMdd',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$fileDate
        )) {
            continue
        }
        if ($fileDate.Date -lt $cutoffDate) { continue }
        if ($file.Length -gt 16MB) {
            throw "全量状态分片超过 16 MB 安全上限：$($file.Name)"
        }
        foreach ($line in Get-Content -LiteralPath $file.FullName -Encoding UTF8) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line.Length -gt 65536) { continue }
            try {
                $entry = ConvertFrom-UsageStateEntry `
                    -Saved ($line | ConvertFrom-Json)
                if ($entry) { $items.Add($entry) }
            }
            catch {
                # A damaged journal line does not invalidate the other entries.
            }
        }
    }
    return @(
        Select-UsageStateRetentionWindow -Entries $items -Now $Now
    )
}

function Read-UsageStateEntries {
    param(
        [string]$RootPath = '',
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    $deduplicated = @{}
    foreach ($entry in @(
        @(Read-LegacyUsageStateEntries -RootPath $RootPath -Now $Now) +
        @(Read-JournalUsageStateEntries -RootPath $RootPath -Now $Now)
    )) {
        if (-not $entry) { continue }
        $key = if (-not [string]::IsNullOrWhiteSpace([string]$entry.EntryId)) {
            [string]$entry.EntryId
        }
        else {
            '{0}|{1}|{2}|{3}' -f
                $entry.ProviderId,
                $entry.ObservedAtUtc,
                $entry.PayloadHash,
                $entry.Reason
        }
        $deduplicated[$key] = $entry
    }
    if ($deduplicated.Count -eq 0) {
        return @(
            Read-UsageStateCurrentEntries -RootPath $RootPath -Now $Now
        )
    }
    return @(
        Select-UsageStateRetentionWindow `
            -Entries @($deduplicated.Values) `
            -Now $Now
    )
}

function ConvertTo-UsageStateEntryDocument {
    param($Entry)

    return [ordered]@{
        v = 1
        EntryId = [string]$Entry.EntryId
        ProviderId = [string]$Entry.ProviderId
        ObservedAtUtc = ([DateTimeOffset]$Entry.ObservedAtUtc).
            ToUniversalTime().ToString(
                'o',
                [Globalization.CultureInfo]::InvariantCulture
            )
        SampledAtUtc = ([DateTimeOffset]$Entry.SampledAtUtc).
            ToUniversalTime().ToString(
                'o',
                [Globalization.CultureInfo]::InvariantCulture
            )
        PayloadHash = [string]$Entry.PayloadHash
        Reason = [string]$Entry.Reason
        AppVersion = [string]$Entry.AppVersion
    }
}

function Write-UsageStateCurrentIndex {
    param(
        [object[]]$Entries,
        [string]$RootPath = '',
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    $retained = @(Select-UsageStateRetentionWindow -Entries $Entries -Now $Now)
    $latest = New-Object Collections.Generic.List[object]
    foreach ($providerId in @('Codex', 'DeepSeek', 'Kimi')) {
        $entry = @(
            $retained | Where-Object { $_.ProviderId -eq $providerId }
        ) | Select-Object -Last 1
        if ($entry) {
            $latest.Add((ConvertTo-UsageStateEntryDocument -Entry $entry))
        }
    }
    $current = [ordered]@{
        v = 1
        UpdatedAtUtc = $Now.ToUniversalTime().ToString(
            'o',
            [Globalization.CultureInfo]::InvariantCulture
        )
        Latest = $latest.ToArray()
    } | ConvertTo-Json -Depth 5
    Write-UsageStateAtomicText `
        -Path (Get-UsageStateCurrentPath -RootPath $RootPath) `
        -Text $current
    return $latest.ToArray()
}

function Add-UsageStateJournalEntry {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [string]$RootPath = ''
    )

    $path = Get-UsageStateJournalPath `
        -ObservedAt ([DateTimeOffset]$Entry.ObservedAtUtc) `
        -RootPath $RootPath
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void](New-Item -Path $parent -ItemType Directory -Force)
    }
    $line = (ConvertTo-UsageStateEntryDocument -Entry $Entry) |
        ConvertTo-Json -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($line) -gt 65536) {
        throw '全量状态索引记录超过 64 KB 安全上限。'
    }
    [IO.File]::AppendAllText(
        $path,
        $line + [Environment]::NewLine,
        (New-Object Text.UTF8Encoding($false))
    )
}

function Write-UsageStateIndexes {
    param(
        [object[]]$Entries,
        [string]$RootPath = '',
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    $retained = @(Select-UsageStateRetentionWindow -Entries $Entries -Now $Now)
    $directory = Get-UsageStateEntriesDirectory -RootPath $RootPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -Path $directory -ItemType Directory -Force)
    }
    $expectedPaths = @{}
    foreach ($group in @(
        $retained | Group-Object {
            ([DateTimeOffset]$_.ObservedAtUtc).ToUniversalTime().ToString(
                'yyyyMMdd',
                [Globalization.CultureInfo]::InvariantCulture
            )
        }
    )) {
        $path = Join-Path $directory ($group.Name + '.jsonl')
        $expectedPaths[[IO.Path]::GetFullPath($path)] = $true
        $lines = @(
            $group.Group | Sort-Object ObservedAtUtc | ForEach-Object {
                (ConvertTo-UsageStateEntryDocument -Entry $_) |
                    ConvertTo-Json -Compress
            }
        )
        Write-UsageStateAtomicText `
            -Path $path `
            -Text (($lines -join [Environment]::NewLine) +
                $(if ($lines.Count -gt 0) { [Environment]::NewLine } else { '' }))
    }
    foreach ($file in @(
        Get-ChildItem -LiteralPath $directory -File -Filter '*.jsonl'
    )) {
        if (
            $file.Name -match '^\d{8}\.jsonl$' -and
            -not $expectedPaths.ContainsKey([IO.Path]::GetFullPath($file.FullName))
        ) {
            Remove-Item -LiteralPath $file.FullName -Force
        }
    }
    [void](Write-UsageStateCurrentIndex `
        -Entries $retained `
        -RootPath $RootPath `
        -Now $Now)
    return $retained
}

function Remove-UnreferencedUsageStatePayloads {
    param(
        [object[]]$Entries,
        [string]$RootPath = ''
    )

    $objectsDirectory = Get-UsageStateObjectsDirectory -RootPath $RootPath
    if (-not (Test-Path -LiteralPath $objectsDirectory -PathType Container)) {
        return
    }
    $referenced = @{}
    foreach ($entry in $Entries) {
        $referenced[[string]$entry.PayloadHash] = $true
    }
    foreach ($file in @(
        Get-ChildItem -LiteralPath $objectsDirectory -File -Filter '*.json'
    )) {
        $hash = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        if ($hash -match '^[0-9a-f]{64}$' -and -not $referenced.ContainsKey($hash)) {
            Remove-Item -LiteralPath $file.FullName -Force
        }
    }
}

function Invoke-UsageStateLightweightMaintenance {
    param(
        [string]$RootPath = '',
        [DateTimeOffset]$Now = [DateTimeOffset]::Now,
        [ValidateRange(1, 256)]
        [int]$MaxObjectDeletes = 24,
        [switch]$AllowDiagnosticWrite
    )

    if ($isDiagnosticRun -and -not $AllowDiagnosticWrite) { return }
    $root = Get-UsageStateHistoryDirectory -RootPath $RootPath
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return }
    if (-not (Get-Variable `
        -Name 'UsageStateMaintenanceDueByRoot' `
        -Scope Script `
        -ErrorAction SilentlyContinue)) {
        $script:UsageStateMaintenanceDueByRoot = @{}
    }
    $key = $root.ToLowerInvariant()
    if (
        $script:UsageStateMaintenanceDueByRoot.ContainsKey($key) -and
        $Now -lt $script:UsageStateMaintenanceDueByRoot[$key]
    ) {
        return
    }
    $script:UsageStateMaintenanceDueByRoot[$key] = $Now.AddHours(1)

    $cutoffUtc = $Now.ToUniversalTime().AddHours(-168)
    $removedJournals = 0
    $entriesDirectory = Get-UsageStateEntriesDirectory -RootPath $root
    if (Test-Path -LiteralPath $entriesDirectory -PathType Container) {
        foreach ($file in @(
            Get-ChildItem -LiteralPath $entriesDirectory -File -Filter '*.jsonl'
        )) {
            if ($file.Name -notmatch '^(?<date>\d{8})\.jsonl$') { continue }
            $fileDate = [DateTime]::MinValue
            if (
                [DateTime]::TryParseExact(
                    $matches.date,
                    'yyyyMMdd',
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::AssumeUniversal,
                    [ref]$fileDate
                ) -and
                $fileDate.Date -lt $cutoffUtc.Date
            ) {
                Remove-Item -LiteralPath $file.FullName -Force
                $removedJournals++
            }
        }
    }

    $legacyPath = Get-UsageStateManifestPath -RootPath $root
    if (Test-Path -LiteralPath $legacyPath -PathType Leaf) {
        $legacy = Get-Item -LiteralPath $legacyPath
        if ($legacy.LastWriteTimeUtc -lt $cutoffUtc.UtcDateTime) {
            Remove-Item -LiteralPath $legacyPath -Force
        }
    }

    $removedObjects = 0
    $objectsDirectory = Get-UsageStateObjectsDirectory -RootPath $root
    if (Test-Path -LiteralPath $objectsDirectory -PathType Container) {
        foreach ($path in [IO.Directory]::EnumerateFiles(
            $objectsDirectory,
            '*.json',
            [IO.SearchOption]::TopDirectoryOnly
        )) {
            if ($removedObjects -ge $MaxObjectDeletes) { break }
            $file = New-Object IO.FileInfo($path)
            if (
                $file.BaseName -match '^[0-9a-f]{64}$' -and
                $file.LastWriteTimeUtc -lt $cutoffUtc.UtcDateTime
            ) {
                Remove-Item -LiteralPath $file.FullName -Force
                $removedObjects++
            }
        }
    }
    if (
        ($removedJournals -gt 0 -or $removedObjects -gt 0) -and
        (Get-Command Write-RuntimeLog -ErrorAction SilentlyContinue)
    ) {
        Write-RuntimeLog `
            -Event 'StateHistory.Maintenance' `
            -Message '已清理过期状态历史' `
            -Data @{
                Journals = $removedJournals
                Objects = $removedObjects
            }
    }
}

function Save-UsageStateSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [DateTimeOffset]$ObservedAt = [DateTimeOffset]::Now,
        [string]$Reason = 'Refresh',
        [string]$RootPath = '',
        [switch]$AllowDiagnosticWrite
    )

    if ($isDiagnosticRun -and -not $AllowDiagnosticWrite) {
        $script:UsageStateDiagnosticCaptureCount++
        return $null
    }
    Assert-UsageSnapshotContract -Snapshot $Snapshot
    if (-not [bool]$Snapshot.Available) { return $null }

    $providerId = [string]$Snapshot.ProviderId
    if ($providerId -notin @('Codex', 'DeepSeek', 'Kimi')) {
        throw '无法保存未知数据源的全量状态。'
    }
    $sampledAt = ([DateTimeOffset]$Snapshot.SampledAt).ToUniversalTime()
    $payload = ConvertTo-UsageStatePayloadValue -Value $Snapshot -Root
    $payloadJson = $payload | ConvertTo-Json -Depth 12 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($payloadJson) -gt 2MB) {
        throw '单个全量状态快照超过 2 MB 安全上限。'
    }
    $payloadHash = Get-UsageStatePayloadHash -PayloadJson $payloadJson

    $root = Get-UsageStateHistoryDirectory -RootPath $RootPath
    $objectsDirectory = Get-UsageStateObjectsDirectory -RootPath $root
    if (-not (Test-Path -LiteralPath $objectsDirectory -PathType Container)) {
        [void](New-Item -Path $objectsDirectory -ItemType Directory -Force)
    }
    $objectPath = Join-Path $objectsDirectory ($payloadHash + '.json')
    if (Test-Path -LiteralPath $objectPath -PathType Leaf) {
        [IO.File]::SetLastWriteTimeUtc($objectPath, $ObservedAt.UtcDateTime)
    }
    else {
        $protectedPayload = Protect-LocalSecret -Value $payloadJson
        $encryptionFailed = $false
        if ([string]::IsNullOrWhiteSpace($protectedPayload)) {
            # DPAPI unavailable (e.g., roaming profile, corrupted key); fall back to unencrypted
            # with explicit marker so we know not to attempt decryption on read
            $encryptionFailed = $true
            $protectedPayload = $payloadJson
            Write-RuntimeLog `
                -Level 'Warning' `
                -Event 'StateHistory.DPAPIFallback' `
                -Message 'DPAPI 加密不可用，回退到明文存储（仅限当前会话）' `
                -Data @{ ProviderId = $providerId; PayloadHash = $payloadHash }
        }
        $objectDocument = [ordered]@{
            v = 1
            Encoding = if ($encryptionFailed) { 'plaintext-fallback' } else { 'dpapi-current-user' }
            PayloadHash = $payloadHash
            ProtectedPayload = $protectedPayload
        } | ConvertTo-Json -Compress
        Write-UsageStateAtomicText -Path $objectPath -Text $objectDocument
        [IO.File]::SetLastWriteTimeUtc($objectPath, $ObservedAt.UtcDateTime)
    }

    $entry = [pscustomobject]@{
        Version = 1
        EntryId = [Guid]::NewGuid().ToString('N')
        ProviderId = $providerId
        ObservedAtUtc = $ObservedAt.ToUniversalTime()
        SampledAtUtc = $sampledAt
        PayloadHash = $payloadHash
        Reason = if ([string]::IsNullOrWhiteSpace($Reason)) {
            'Refresh'
        } else { $Reason }
        AppVersion = [string]$script:AppVersion
    }
    Add-UsageStateJournalEntry -Entry $entry -RootPath $root
    $currentEntries = @(
        Read-UsageStateCurrentEntries -RootPath $root -Now $ObservedAt |
            Where-Object { $_.ProviderId -ne $providerId }
    )
    [void](Write-UsageStateCurrentIndex `
        -Entries @($currentEntries + $entry) `
        -RootPath $root `
        -Now $ObservedAt)
    return $entry
}

function Read-UsageStatePayload {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [string]$RootPath = ''
    )

    $objectsDirectory = Get-UsageStateObjectsDirectory -RootPath $RootPath
    $path = Join-Path $objectsDirectory ([string]$Entry.PayloadHash + '.json')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $file = Get-Item -LiteralPath $path
    if ($file.Length -gt 4MB) {
        throw '加密全量状态文件超过 4 MB 安全上限。'
    }
    $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 |
        ConvertFrom-Json
    if (
        -not $saved -or
        [int]$saved.v -ne 1 -or
        [string]$saved.PayloadHash -ne [string]$Entry.PayloadHash
    ) {
        throw '全量状态文件格式无效。'
    }
    $encoding = [string]$saved.Encoding
    if ($encoding -eq 'plaintext-fallback') {
        $payloadJson = [string]$saved.ProtectedPayload
    }
    elseif ($encoding -eq 'dpapi-current-user') {
        $payloadJson = Unprotect-LocalSecret -Value ([string]$saved.ProtectedPayload)
        if ([string]::IsNullOrWhiteSpace($payloadJson)) {
            throw '当前 Windows 用户无法解密全量状态。'
        }
    }
    else {
        throw "不支持的全量状态编码：$encoding"
    }
    if ((Get-UsageStatePayloadHash -PayloadJson $payloadJson) -ne $Entry.PayloadHash) {
        throw '全量状态内容哈希校验失败。'
    }

    $snapshot = $payloadJson | ConvertFrom-Json
    $snapshot | Add-Member `
        -NotePropertyName SampledAt `
        -NotePropertyValue ([DateTimeOffset]$Entry.SampledAtUtc) `
        -Force
    foreach ($propertyName in @('UsageSampledAt', 'ResetAt')) {
        if (
            $snapshot.PSObject.Properties[$propertyName] -and
            $null -ne $snapshot.$propertyName -and
            -not [string]::IsNullOrWhiteSpace([string]$snapshot.$propertyName)
        ) {
            try {
                $snapshot.$propertyName = [DateTimeOffset]::Parse(
                    [string]$snapshot.$propertyName,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind
                )
            }
            catch {
                $snapshot.$propertyName = $null
            }
        }
    }
    Assert-UsageSnapshotContract -Snapshot $snapshot
    return $snapshot
}

function Get-UsageStateHistory {
    param(
        [ValidateSet('', 'Codex', 'DeepSeek', 'Kimi')]
        [string]$ProviderId = '',
        [DateTimeOffset]$From = [DateTimeOffset]::MinValue,
        [DateTimeOffset]$To = [DateTimeOffset]::MaxValue,
        [switch]$IncludeSnapshots,
        [string]$RootPath = '',
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    $root = Get-UsageStateHistoryDirectory -RootPath $RootPath
    $entries = @(
        Read-UsageStateEntries -RootPath $root -Now $Now | Where-Object {
            ([string]::IsNullOrWhiteSpace($ProviderId) -or
                $_.ProviderId -eq $ProviderId) -and
            $_.ObservedAtUtc -ge $From.ToUniversalTime() -and
            $_.ObservedAtUtc -le $To.ToUniversalTime()
        }
    )
    if (-not $IncludeSnapshots) { return $entries }
    return @(
        foreach ($entry in $entries) {
            [pscustomobject]@{
                Entry = $entry
                Snapshot = Read-UsageStatePayload `
                    -Entry $entry `
                    -RootPath $root
            }
        }
    )
}

function Get-LatestUsageStateSnapshot {
    param(
        [ValidateSet('Codex', 'DeepSeek', 'Kimi')]
        [string]$ProviderId,
        [string]$RootPath = '',
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    $root = Get-UsageStateHistoryDirectory -RootPath $RootPath
    $attempted = @{}
    $currentEntries = @(
        Read-UsageStateCurrentEntries -RootPath $root -Now $Now |
            Where-Object { $_.ProviderId -eq $ProviderId } |
            Sort-Object ObservedAtUtc -Descending
    )
    foreach ($entry in $currentEntries) {
        try {
            $attempted[[string]$entry.EntryId] = $true
            $snapshot = Read-UsageStatePayload -Entry $entry -RootPath $root
            if ($snapshot) { return $snapshot }
        }
        catch {
            # Fall back to the next valid retained snapshot.
        }
    }
    $entries = @(Read-UsageStateEntries -RootPath $root -Now $Now)
    foreach ($entry in @(
        $entries | Where-Object {
            $_.ProviderId -eq $ProviderId -and
            -not $attempted.ContainsKey([string]$_.EntryId)
        } | Sort-Object ObservedAtUtc -Descending
    )) {
        try {
            $snapshot = Read-UsageStatePayload -Entry $entry -RootPath $root
            if ($snapshot) { return $snapshot }
        }
        catch {
            # Keep walking backward if a payload is missing or damaged.
        }
    }
    return $null
}

function Invoke-UsageStateMaintenance {
    param(
        [string]$RootPath = '',
        [DateTimeOffset]$Now = [DateTimeOffset]::Now,
        [switch]$AllowDiagnosticWrite
    )

    if ($isDiagnosticRun -and -not $AllowDiagnosticWrite) { return @() }
    $root = Get-UsageStateHistoryDirectory -RootPath $RootPath
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return @()
    }
    $entries = @(Read-UsageStateEntries -RootPath $root -Now $Now)
    $retained = @(
        Write-UsageStateIndexes -Entries $entries -RootPath $root -Now $Now
    )
    Remove-UnreferencedUsageStatePayloads -Entries $retained -RootPath $root
    return $retained
}

function Restore-LatestUsageState {
    if ($isDiagnosticRun) { return $false }
    try {
        $snapshot = Get-LatestUsageStateSnapshot `
            -ProviderId $script:ActiveProvider
        if (-not $snapshot) { return $false }

        $script:LastSnapshot = $snapshot
        if ($snapshot.ProviderId -eq 'DeepSeek') {
            $script:LastDeepSeekSnapshot = $snapshot
        }
        if ($snapshot.ProviderId -eq 'Kimi') {
            $script:LastKimiSnapshot = $snapshot
        }
        Update-UsageView -Snapshot $snapshot -DisplayOnly
        Set-RuntimeDiagnosticStatus `
            -Area 'StateHistory' `
            -Status 'Healthy' `
            -Message '已恢复上次完整状态'
        return $true
    }
    catch {
        Set-RuntimeDiagnosticStatus `
            -Area 'StateHistory' `
            -Status 'Degraded' `
            -Message $_.Exception.Message
        return $false
    }
}
