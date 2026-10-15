# Configuration profiles: the saved credentials behind one data source. A user
# can hold several accounts for the same provider (Kimi Code, DeepSeek) and
# switch between them without retyping an address or a key.
#
# The "本机读取" (Auto) profile is virtual: it is derived at read time from the
# locally installed CLI or environment variable and is never stored on disk, so
# it can neither be deleted nor go stale in the file. Only manual entries are
# persisted, which keeps the on-disk document minimal and makes the migration
# from the old single-slot kimi.json/deepseek.json files idempotent.

function Get-ConfigProfileProviders {
    # Codex is deliberately absent: its quota endpoint is the ChatGPT OAuth
    # backend, so there is no address and key for a user to supply.
    return @('Kimi', 'DeepSeek')
}

function Get-ConfigProfileAutoId {
    param([string]$Provider)

    return 'auto-' + ([string]$Provider).ToLowerInvariant()
}

function Get-ConfigProfileDefaultBaseUrl {
    param([string]$Provider)

    if ($Provider -eq 'Kimi') { return 'https://api.kimi.com/coding/v1' }
    return 'https://api.deepseek.com'
}

function Resolve-ConfigProfileBaseUrl {
    param(
        [string]$Provider,
        [AllowEmptyString()]
        [string]$BaseUrl
    )

    $raw = ([string]$BaseUrl).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return Get-ConfigProfileDefaultBaseUrl -Provider $Provider
    }
    if ($raw -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') {
        $raw = 'https://' + $raw
    }
    if ($raw -notmatch '^(?i)https?://') {
        throw '接口地址只支持 http 或 https。'
    }

    # Trim the query/fragment before touching the path segments.
    $raw = ($raw -split '[?#]', 2)[0]
    $raw = $raw.TrimEnd('/')

    if ($Provider -eq 'Kimi') {
        if ($raw -notmatch '/v1$') { $raw = $raw + '/v1' }
        return $raw
    }

    # DeepSeek balance lives on the OpenAI-compatible root, while Claude Code
    # stores the Anthropic-compatible endpoint (…/anthropic). Both the /v1 and
    # /anthropic suffixes must go or the balance request answers 404.
    foreach ($suffix in @('/anthropic', '/v1')) {
        if ($raw -match ("(?i)" + [regex]::Escape($suffix) + '$')) {
            $raw = $raw.Substring(0, $raw.Length - $suffix.Length)
            break
        }
    }
    return $raw.TrimEnd('/')
}

function Get-ConfigProfileHost {
    param(
        [string]$Provider,
        [AllowEmptyString()]
        [string]$BaseUrl
    )

    try {
        $normalized = Resolve-ConfigProfileBaseUrl -Provider $Provider -BaseUrl $BaseUrl
        return ([Uri]$normalized).Host
    }
    catch {
        return ''
    }
}

function Get-ConfigProfileKeyHint {
    param([AllowEmptyString()][string]$ApiKey)

    $trimmed = ([string]$ApiKey).Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return '' }
    if ($trimmed.Length -gt 4) { return $trimmed.Substring($trimmed.Length - 4) }
    return $trimmed
}

function Get-ConfigProfilesPath {
    param([string]$RootPath = '')

    if (-not [string]::IsNullOrWhiteSpace($RootPath)) {
        return [IO.Path]::GetFullPath($RootPath)
    }
    return Join-Path (Get-AppDataDirectory) 'configs.json'
}

function Test-ConfigProfileAutoAvailable {
    param([string]$Provider)

    # Deliberately reads the raw sources instead of calling Get-KimiCredential /
    # Get-DeepSeekCredential: those resolve the *active* profile, and the active
    # profile comes from Get-ConfigProfileEntries, so going through them here
    # would recurse forever.
    try {
        if ($Provider -eq 'Kimi') {
            $dataRoot = Get-KimiCodeDataRoot
            if ([string]::IsNullOrWhiteSpace($dataRoot)) { return $false }
            $credentialsRoot = Join-Path $dataRoot 'credentials'
            if (
                (Test-Path -LiteralPath $credentialsRoot -PathType Container) -and
                @(Get-ChildItem -LiteralPath $credentialsRoot -Filter '*.json' -File `
                        -ErrorAction SilentlyContinue).Count -gt 0
            ) {
                return $true
            }
            foreach ($provider in @(Read-KimiConfigProviders -DataRoot $dataRoot)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$provider.ApiKey)) {
                    return $true
                }
            }
            return $false
        }
        return -not [string]::IsNullOrWhiteSpace([string]$env:DEEPSEEK_API_KEY)
    }
    catch {
        # An unreadable CLI location simply looks like "no local configuration";
        # it must never break the menu or the startup path.
        return $false
    }
}

function New-ConfigProfileAutoEntry {
    param([string]$Provider)

    $label = if ($Provider -eq 'Kimi') {
        'Kimi Code CLI（本机读取）'
    }
    else {
        'DeepSeek（环境变量）'
    }

    return [pscustomobject][ordered]@{
        Id = Get-ConfigProfileAutoId -Provider $Provider
        Provider = $Provider
        Kind = 'Auto'
        Label = $label
        BaseUrl = ''
        EncryptedApiKey = ''
        KeyHint = ''
        CreatedAtUtc = ''
        LastUsedAtUtc = ''
        Available = Test-ConfigProfileAutoAvailable -Provider $Provider
        Detail = ''
    }
}

function ConvertTo-ConfigProfileEntry {
    param($Saved)

    if (-not $Saved) { return $null }
    $provider = [string](Get-ObjectPropertyValue -Object $Saved -Name 'Provider' -Default '')
    if ($provider -notin (Get-ConfigProfileProviders)) { return $null }
    $id = [string](Get-ObjectPropertyValue -Object $Saved -Name 'Id' -Default '')
    if ([string]::IsNullOrWhiteSpace($id)) { return $null }
    $label = [string](Get-ObjectPropertyValue -Object $Saved -Name 'Label' -Default '')
    if ([string]::IsNullOrWhiteSpace($label)) { $label = $id }

    return [pscustomobject][ordered]@{
        Id = $id
        Provider = $provider
        Kind = 'Manual'
        Label = $label
        BaseUrl = [string](Get-ObjectPropertyValue -Object $Saved -Name 'BaseUrl' -Default '')
        EncryptedApiKey = [string](Get-ObjectPropertyValue -Object $Saved -Name 'EncryptedApiKey' -Default '')
        KeyHint = [string](Get-ObjectPropertyValue -Object $Saved -Name 'KeyHint' -Default '')
        CreatedAtUtc = [string](Get-ObjectPropertyValue -Object $Saved -Name 'CreatedAtUtc' -Default '')
        LastUsedAtUtc = [string](Get-ObjectPropertyValue -Object $Saved -Name 'LastUsedAtUtc' -Default '')
        Available = $true
        Detail = ''
    }
}

function Read-ConfigProfileDocument {
    param([string]$RootPath = '')

    $result = [ordered]@{
        Entries = @()
        Corrupted = $false
    }
    try {
        $path = Get-ConfigProfilesPath -RootPath $RootPath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $result }
        $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $entries = @(
            Get-ObjectPropertyValue -Object $saved -Name 'Entries' -Default @() |
                ForEach-Object { ConvertTo-ConfigProfileEntry -Saved $_ }
        )
        $result.Entries = @($entries | Where-Object { $_ })
    }
    catch {
        # A damaged optional configuration must not prevent the widget starting;
        # the caller falls back to the virtual Auto profile.
        $result.Corrupted = $true
        if (Get-Command Write-RuntimeLog -ErrorAction SilentlyContinue) {
            Write-RuntimeLog `
                -Level 'Warning' `
                -Event 'ConfigProfiles.ReadFailed' `
                -Message $_.Exception.Message
        }
    }
    return [pscustomobject]$result
}

function Get-StoredConfigProfileEntries {
    # Every manual entry across all data sources. Reads go through here so a
    # write for one provider can never drop the other provider's entries.
    param([switch]$Refresh)

    if ($Refresh -or -not $script:ConfigProfileEntries) {
        $script:ConfigProfileEntries = @(
            (Read-ConfigProfileDocument).Entries
        )
    }
    return @($script:ConfigProfileEntries)
}

function Get-ConfigProfileEntries {
    param(
        [string]$Provider,
        [switch]$Refresh
    )

    if ($Provider -notin (Get-ConfigProfileProviders)) { return @() }
    $manual = @(
        Get-StoredConfigProfileEntries -Refresh:$Refresh | Where-Object {
            $_.Provider -eq $Provider
        }
    )
    $manual = @($manual | Sort-Object `
        @{ Expression = { if ($_.LastUsedAtUtc) { $_.LastUsedAtUtc } else { '0000' } }; Descending = $true }, `
        @{ Expression = { $_.Label } })
    return @((New-ConfigProfileAutoEntry -Provider $Provider)) + @($manual)
}

function Save-ConfigProfileDocument {
    param(
        $Entries,
        [string]$RootPath = '',
        [switch]$AllowDiagnosticWrite
    )

    $usesDefaultPath = [string]::IsNullOrWhiteSpace($RootPath)
    if ($isDiagnosticRun -and $usesDefaultPath -and -not $AllowDiagnosticWrite) {
        return $false
    }

    $saved = @(
        @($Entries) | Where-Object { $_ -and $_.Kind -ne 'Auto' } | ForEach-Object {
            [pscustomobject][ordered]@{
                Id = $_.Id
                Provider = $_.Provider
                Kind = 'Manual'
                Label = $_.Label
                BaseUrl = $_.BaseUrl
                EncryptedApiKey = $_.EncryptedApiKey
                KeyHint = $_.KeyHint
                CreatedAtUtc = $_.CreatedAtUtc
                LastUsedAtUtc = $_.LastUsedAtUtc
            }
        }
    )
    $document = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Entries = $saved
    } | ConvertTo-Json -Depth 5

    $writeLock = $null
    try {
        $targetPath = Get-ConfigProfilesPath -RootPath $RootPath
        $writeLock = Enter-SpendLedgerWriteLock -Path $targetPath
        Write-UsageStateAtomicText -Path $targetPath -Text $document
        if ($usesDefaultPath) {
            $script:ConfigProfileEntries = $saved | ForEach-Object {
                ConvertTo-ConfigProfileEntry -Saved $_
            }
        }
        return $true
    }
    catch {
        if (Get-Command Write-RuntimeLog -ErrorAction SilentlyContinue) {
            Write-RuntimeLog `
                -Level 'Warning' `
                -Event 'ConfigProfiles.WriteFailed' `
                -Message $_.Exception.Message
        }
        throw
    }
    finally {
        if ($writeLock) { Exit-SpendLedgerWriteLock -Mutex $writeLock }
    }
}

function New-ConfigProfileId {
    param($ExistingIds)

    $taken = @($ExistingIds)
    for ($attempt = 0; $attempt -lt 8; $attempt++) {
        $candidate = [Guid]::NewGuid().ToString('N').Substring(0, 8)
        if ($taken -notcontains $candidate) { return $candidate }
    }
    return [Guid]::NewGuid().ToString('N')
}

function Test-ConfigProfileLabelInUse {
    param(
        [string]$Provider,
        [string]$Label,
        [string]$ExceptId = ''
    )

    $needle = ([string]$Label).Trim()
    foreach ($entry in @(Get-ConfigProfileEntries -Provider $Provider)) {
        if ($entry.Id -eq $ExceptId) { continue }
        if ($entry.Label.Trim() -eq $needle) { return $true }
    }
    return $false
}

function Add-ConfigProfile {
    param(
        [string]$Provider,
        [string]$Label,
        [AllowEmptyString()][string]$BaseUrl,
        [AllowEmptyString()][string]$ApiKey,
        [switch]$AllowDiagnosticWrite
    )

    if ($Provider -notin (Get-ConfigProfileProviders)) {
        throw '该数据源不支持添加配置。'
    }
    $trimmedLabel = ([string]$Label).Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedLabel)) {
        throw '请输入配置名称。'
    }
    if (Test-ConfigProfileLabelInUse -Provider $Provider -Label $trimmedLabel) {
        throw ('「{0}」配置已存在' -f $trimmedLabel)
    }
    $trimmedKey = ([string]$ApiKey).Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedKey)) {
        throw '请输入 API Key。'
    }
    if ($trimmedKey.Length -lt 10) {
        throw 'API Key 长度看起来不正确，请检查后重试。'
    }

    $entries = @(Get-StoredConfigProfileEntries -Refresh)
    $created = [pscustomobject][ordered]@{
        Id = New-ConfigProfileId -ExistingIds @($entries | ForEach-Object { $_.Id })
        Provider = $Provider
        Kind = 'Manual'
        Label = $trimmedLabel
        BaseUrl = Resolve-ConfigProfileBaseUrl -Provider $Provider -BaseUrl $BaseUrl
        EncryptedApiKey = Protect-LocalSecret -Value $trimmedKey
        KeyHint = Get-ConfigProfileKeyHint -ApiKey $trimmedKey
        CreatedAtUtc = [DateTimeOffset]::Now.ToString(
            'o', [Globalization.CultureInfo]::InvariantCulture
        )
        LastUsedAtUtc = ''
        Available = $true
        Detail = ''
    }
    [void](Save-ConfigProfileDocument `
            -Entries (@($entries) + @($created)) `
            -AllowDiagnosticWrite:$AllowDiagnosticWrite)
    return $created
}

function Update-ConfigProfile {
    param(
        [string]$Id,
        [string]$Label,
        [AllowEmptyString()][string]$BaseUrl,
        [AllowEmptyString()][string]$ApiKey,
        [switch]$AllowDiagnosticWrite
    )

    $entries = @(Get-StoredConfigProfileEntries -Refresh)
    $target = $entries | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $target -or $target.Kind -eq 'Auto') {
        throw '该配置来自本机自动检测内容，无法在此处修改，请尝试切换配置。'
    }
    $trimmedLabel = ([string]$Label).Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedLabel)) {
        throw '请输入配置名称。'
    }
    if (Test-ConfigProfileLabelInUse `
            -Provider $target.Provider `
            -Label $trimmedLabel `
            -ExceptId $Id) {
        throw ('「{0}」配置已存在' -f $trimmedLabel)
    }

    $updated = [pscustomobject][ordered]@{
        Id = $target.Id
        Provider = $target.Provider
        Kind = 'Manual'
        Label = $trimmedLabel
        BaseUrl = Resolve-ConfigProfileBaseUrl -Provider $target.Provider -BaseUrl $BaseUrl
        EncryptedApiKey = $target.EncryptedApiKey
        KeyHint = $target.KeyHint
        CreatedAtUtc = $target.CreatedAtUtc
        LastUsedAtUtc = $target.LastUsedAtUtc
        Available = $true
        Detail = ''
    }

    # A blank key keeps the stored one; the dialog only sends the field when the
    # user actually retyped it.
    $trimmedKey = ([string]$ApiKey).Trim()
    if (-not [string]::IsNullOrWhiteSpace($trimmedKey)) {
        if ($trimmedKey.Length -lt 10) {
            throw 'API Key 长度看起来不正确，请检查后重试。'
        }
        $updated.EncryptedApiKey = Protect-LocalSecret -Value $trimmedKey
        $updated.KeyHint = Get-ConfigProfileKeyHint -ApiKey $trimmedKey
    }

    $replaced = @(
        foreach ($entry in $entries) {
            if ($entry.Id -eq $Id) { $updated } else { $entry }
        }
    )
    [void](Save-ConfigProfileDocument `
            -Entries $replaced `
            -AllowDiagnosticWrite:$AllowDiagnosticWrite)
    return $updated
}

function Remove-ConfigProfile {
    param(
        [string]$Id,
        [switch]$AllowDiagnosticWrite
    )

    $entries = @(Get-StoredConfigProfileEntries -Refresh)
    $target = $entries | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $target -or $target.Kind -eq 'Auto') {
        throw '该配置来自本机自动检测内容，无法在此处删除。'
    }
    $remaining = @($entries | Where-Object { $_.Id -ne $Id })
    [void](Save-ConfigProfileDocument `
            -Entries $remaining `
            -AllowDiagnosticWrite:$AllowDiagnosticWrite)
    return $target.Provider
}

function Get-ConfigProfile {
    param(
        [string]$Provider,
        [string]$ConfigId,
        [switch]$Refresh
    )

    $entries = @(Get-ConfigProfileEntries -Provider $Provider -Refresh)
    if ([string]::IsNullOrWhiteSpace($ConfigId)) { return $null }
    return $entries | Where-Object { $_.Id -eq $ConfigId } | Select-Object -First 1
}

function Get-ConfigProfileDisplayText {
    param($Profile)

    if (-not $Profile) { return '' }
    $label = [string]$Profile.Label
    if ([string]$Profile.Kind -eq 'Auto') { return $label }
    $parts = @($label)
    if ($Profile.KeyHint) { $parts += ('••••{0}' -f $Profile.KeyHint) }
    # $host is a reserved automatic variable; assigning it throws.
    $endpointHost = Get-ConfigProfileHost `
        -Provider $Profile.Provider `
        -BaseUrl $Profile.BaseUrl
    if ($endpointHost) { $parts += $endpointHost }
    return ($parts -join ' · ')
}

function ConvertTo-LegacyProviderConfigPath {
    param([string]$Provider)

    if ($Provider -eq 'Kimi') { return Get-KimiConfigPath }
    if ($Provider -eq 'DeepSeek') { return Get-DeepSeekConfigPath }
    return ''
}

function Invoke-ConfigProfileMigration {
    param(
        [string]$RootPath = '',
        [switch]$AllowDiagnosticWrite
    )

    $document = Read-ConfigProfileDocument -RootPath $RootPath
    $existing = @($document.Entries)
    $changes = @()
    foreach ($provider in (Get-ConfigProfileProviders)) {
        $legacyPath = ConvertTo-LegacyProviderConfigPath -Provider $provider
        if ([string]::IsNullOrWhiteSpace($legacyPath)) { continue }
        if (-not (Test-Path -LiteralPath $legacyPath -PathType Leaf)) { continue }
        if (@($existing | Where-Object { $_.Provider -eq $provider }).Count -gt 0) {
            continue
        }

        $encrypted = ''
        $keyHint = ''
        $legacyBaseUrl = ''
        try {
            $saved = Get-Content -LiteralPath $legacyPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $encrypted = [string](Get-ObjectPropertyValue -Object $saved -Name 'EncryptedApiKey' -Default '')
            $keyHint = [string](Get-ObjectPropertyValue -Object $saved -Name 'KeyHint' -Default '')
        }
        catch {
            # An unreadable legacy file simply produces no migrated entry.
            $encrypted = ''
        }
        if ([string]::IsNullOrWhiteSpace($encrypted)) { continue }

        # Keep the address the user was actually on: the old single-slot file
        # never stored one, it was resolved from the local CLI each time.
        if ($provider -eq 'Kimi') {
            try {
                $credential = Get-KimiCredential
                if ($credential.BaseUrl) { $legacyBaseUrl = $credential.BaseUrl }
            }
            catch {
                $legacyBaseUrl = ''
            }
        }

        $existing += [pscustomobject][ordered]@{
            Id = New-ConfigProfileId -ExistingIds @($existing | ForEach-Object { $_.Id })
            Provider = $provider
            Kind = 'Manual'
            Label = '配置 1'
            BaseUrl = Resolve-ConfigProfileBaseUrl -Provider $provider -BaseUrl $legacyBaseUrl
            EncryptedApiKey = $encrypted
            KeyHint = $keyHint
            CreatedAtUtc = [DateTimeOffset]::Now.ToString(
                'o', [Globalization.CultureInfo]::InvariantCulture
            )
            LastUsedAtUtc = ''
            Available = $true
            Detail = ''
        }
        $changes += $provider
    }

    if ($changes.Count -eq 0) { return @() }
    [void](Save-ConfigProfileDocument `
            -Entries $existing `
            -RootPath $RootPath `
            -AllowDiagnosticWrite:$AllowDiagnosticWrite)
    if (Get-Command Write-RuntimeLog -ErrorAction SilentlyContinue) {
        Write-RuntimeLog `
            -Event 'ConfigProfiles.Migrated' `
            -Message '已把旧版单槽密钥迁移为独立配置' `
            -Data @{ Providers = ($changes -join ',') }
    }
    return $changes
}

function Clear-ConfigProfileCache {
    $script:ConfigProfileEntries = $null
}

function Get-ActiveConfigProfileId {
    param([string]$Provider)

    if (-not $script:ActiveConfigIds) { return '' }
    $stored = $script:ActiveConfigIds[$Provider]
    if ([string]::IsNullOrWhiteSpace([string]$stored)) { return '' }
    return [string]$stored
}

function Set-ActiveConfigProfileId {
    param(
        [string]$Provider,
        [AllowEmptyString()][string]$ConfigId
    )

    if (-not $script:ActiveConfigIds) {
        $script:ActiveConfigIds = [ordered]@{}
    }
    $script:ActiveConfigIds[$Provider] = [string]$ConfigId
}

function Get-ResolvedConfigProfile {
    # The profile the provider should actually use right now: the remembered one
    # when it still exists, and the virtual "本机读取" profile otherwise. Never
    # returns $null for a supported provider, so callers cannot forget the
    # fallback and end up silently unauthenticated.
    param(
        [string]$Provider,
        [switch]$Refresh
    )

    $entries = @(Get-ConfigProfileEntries -Provider $Provider -Refresh:$Refresh)
    if ($entries.Count -eq 0) { return $null }
    $autoId = Get-ConfigProfileAutoId -Provider $Provider

    $activeId = Get-ActiveConfigProfileId -Provider $Provider
    if ($activeId -and $activeId -ne $autoId) {
        $match = $entries | Where-Object { $_.Id -eq $activeId } | Select-Object -First 1
        if ($match) { return $match }
        # The remembered profile was deleted or the file was replaced; fall back
        # to the local read instead of staying on a profile that no longer exists.
    }
    return $entries | Where-Object { $_.Id -eq $autoId } | Select-Object -First 1
}

function Get-EffectiveConfigProfileId {
    # The id of the profile that actually authorizes a request right now. This is
    # what an in-flight request must be tagged with and compared against: the
    # remembered id alone is empty while the default 本机读取 profile is in use,
    # and comparing an auto profile id against that empty value would make every
    # default-install response look like it belonged to a profile the user left.
    param(
        [string]$Provider,
        [switch]$Refresh
    )

    $profile = Get-ResolvedConfigProfile -Provider $Provider -Refresh:$Refresh
    if ($profile) {
        $id = [string]$profile.Id
        if (-not [string]::IsNullOrWhiteSpace($id)) { return $id }
    }
    return Get-ConfigProfileAutoId -Provider $Provider
}

function Get-ConfigProfileSecret {
    # Returns the decrypted key, or $null when the stored blob exists but cannot
    # be decrypted (roaming profile, damaged key). The distinction matters: a
    # missing key is a normal empty state, an unreadable one is a fault.
    param($Profile)

    if (-not $Profile) { return '' }
    $encrypted = [string]$Profile.EncryptedApiKey
    if ([string]::IsNullOrWhiteSpace($encrypted)) { return '' }
    $plain = Unprotect-LocalSecret -Value $encrypted
    if ([string]::IsNullOrWhiteSpace($plain)) { return $null }
    return $plain
}

function Get-DetectedConfigCandidate {
    param([string]$Provider)

    $candidates = @()
    if ($Provider -eq 'Kimi') {
        foreach ($detectedProvider in @(Read-KimiConfigProviders)) {
            $apiKey = ([string](Get-ObjectPropertyValue `
                        -Object $detectedProvider `
                        -Name 'ApiKey' `
                        -Default '')).Trim()
            if ([string]::IsNullOrWhiteSpace($apiKey)) { continue }
            $candidates += [pscustomobject]@{
                Label = ('Kimi CLI · {0}' -f (Get-ObjectPropertyValue `
                        -Object $detectedProvider `
                        -Name 'Name' `
                        -Default ''))
                BaseUrl = [string](Get-ObjectPropertyValue `
                    -Object $detectedProvider `
                    -Name 'BaseUrl' `
                    -Default '')
                ApiKey = $apiKey
                SourceLabel = 'Kimi Code CLI config.toml'
            }
        }
        return @($candidates)
    }

    if ($Provider -ne 'DeepSeek') { return @() }

    # Claude Code stores the DeepSeek endpoint and token in its settings file.
    $claudeSettings = Join-Path $env:USERPROFILE '.claude\settings.json'
    if (Test-Path -LiteralPath $claudeSettings -PathType Leaf) {
        try {
            $settings = Get-Content -LiteralPath $claudeSettings -Raw -Encoding UTF8 |
                ConvertFrom-Json
            $environment = Get-ObjectPropertyValue -Object $settings -Name 'env'
            $token = [string](Get-ObjectPropertyValue -Object $environment -Name 'ANTHROPIC_AUTH_TOKEN' -Default '')
            $baseUrl = [string](Get-ObjectPropertyValue -Object $environment -Name 'ANTHROPIC_BASE_URL' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($token)) {
                $candidates += [pscustomobject]@{
                    Label = 'Claude Code · DeepSeek'
                    BaseUrl = $baseUrl
                    ApiKey = $token.Trim()
                    SourceLabel = 'Claude Code settings.json'
                }
            }
        }
        catch {
            # A malformed optional file only costs one candidate.
        }
    }

    $environmentKey = [string]$env:DEEPSEEK_API_KEY
    if (-not [string]::IsNullOrWhiteSpace($environmentKey)) {
        $candidates += [pscustomobject]@{
            Label = '环境变量 DEEPSEEK_API_KEY'
            BaseUrl = ''
            ApiKey = $environmentKey.Trim()
            SourceLabel = '环境变量'
        }
    }
    return @($candidates)
}