function Get-AppDataDirectory {
    $directory = Join-Path $env:LOCALAPPDATA 'RemainingMarginFloat'
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    # Preserve existing settings and DPAPI-encrypted credentials when upgrading
    # from the previous application name. The legacy directory remains intact.
    $legacyDirectory = Join-Path $env:LOCALAPPDATA 'CodexMarginFloat'
    if (Test-Path -LiteralPath $legacyDirectory) {
        foreach ($fileName in @(
            'deepseek.json'
            'kimi.json'
            'settings.json'
            'usage-history.jsonl'
        )) {
            $legacyPath = Join-Path $legacyDirectory $fileName
            $newPath = Join-Path $directory $fileName
            if (
                (Test-Path -LiteralPath $legacyPath) -and
                -not (Test-Path -LiteralPath $newPath)
            ) {
                try {
                    Copy-Item -LiteralPath $legacyPath -Destination $newPath -Force
                    if (Get-Command Write-RuntimeLog -ErrorAction SilentlyContinue) {
                        Write-RuntimeLog `
                            -Level 'Info' `
                            -Event 'App.Migration.LegacyFileCopied' `
                            -Message "迁移旧配置文件：$fileName" `
                            -Data @{ From = $legacyPath; To = $newPath }
                    }
                }
                catch {
                    # Migration is best-effort; the app can recreate either file.
                    if (Get-Command Write-RuntimeLog -ErrorAction SilentlyContinue) {
                        Write-RuntimeLog `
                            -Level 'Warning' `
                            -Event 'App.Migration.LegacyFileFailed' `
                            -Message "迁移旧配置文件失败：$fileName" `
                            -Data @{ Error = $_.Exception.Message }
                    }
                }
            }
        }
    }
    return $directory
}

function Get-DeepSeekConfigPath {
    return Join-Path (Get-AppDataDirectory) 'deepseek.json'
}

function Get-KimiConfigPath {
    return Join-Path (Get-AppDataDirectory) 'kimi.json'
}

function Protect-LocalSecret {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $plainBytes = [Text.Encoding]::UTF8.GetBytes($Value)
    try {
        $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
            $plainBytes,
            $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [Convert]::ToBase64String($protectedBytes)
    }
    finally {
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
}

function Unprotect-LocalSecret {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    try {
        $protectedBytes = [Convert]::FromBase64String($Value)
        $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
            $protectedBytes,
            $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        try {
            return [Text.Encoding]::UTF8.GetString($plainBytes)
        }
        finally {
            [Array]::Clear($plainBytes, 0, $plainBytes.Length)
        }
    }
    catch {
        return ''
    }
}

function Get-ProviderKeyConfiguration {
    param(
        [string]$Path,
        [switch]$IncludeBudget
    )

    $result = [ordered]@{
        EncryptedApiKey = ''
        KeyHint = ''
    }
    if ($IncludeBudget) {
        $result.Budget = 0.0
    }
    try {
        if ($Path -and (Test-Path -LiteralPath $Path)) {
            $saved = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($saved.PSObject.Properties['EncryptedApiKey']) {
                $result.EncryptedApiKey = [string]$saved.EncryptedApiKey
            }
            if ($saved.PSObject.Properties['KeyHint']) {
                $result.KeyHint = [string]$saved.KeyHint
            }
            if ($IncludeBudget -and $saved.PSObject.Properties['Budget']) {
                $result.Budget = [Math]::Max(0.0, [double]$saved.Budget)
            }
        }
    }
    catch {
        # A damaged optional configuration must not prevent the widget starting.
    }
    return [pscustomobject]$result
}

function Save-ProviderKeyConfiguration {
    param(
        [string]$Path,
        [AllowEmptyString()]
        [string]$ApiKey,
        [double]$Budget,
        [switch]$IncludeBudget,
        [switch]$RemoveKey
    )

    $current = Get-ProviderKeyConfiguration -Path $Path -IncludeBudget:$IncludeBudget
    $encryptedApiKey = $current.EncryptedApiKey
    $keyHint = $current.KeyHint
    if ($RemoveKey) {
        $encryptedApiKey = ''
        $keyHint = ''
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
        $trimmedKey = $ApiKey.Trim()
        $encryptedApiKey = Protect-LocalSecret -Value $trimmedKey
        $keyHint = if ($trimmedKey.Length -gt 4) {
            $trimmedKey.Substring($trimmedKey.Length - 4)
        } else {
            $trimmedKey
        }
    }

    $content = [ordered]@{
        EncryptedApiKey = $encryptedApiKey
        KeyHint = $keyHint
    }
    if ($IncludeBudget) {
        $content.Budget = [Math]::Max(0.0, $Budget)
    }
    $content | ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-DeepSeekConfiguration {
    $path = try { Get-DeepSeekConfigPath } catch { $null }
    return Get-ProviderKeyConfiguration -Path $path -IncludeBudget
}

function Save-DeepSeekConfiguration {
    param(
        [AllowEmptyString()]
        [string]$ApiKey,
        [double]$Budget,
        [switch]$RemoveKey
    )

    Save-ProviderKeyConfiguration `
        -Path (Get-DeepSeekConfigPath) `
        -ApiKey $ApiKey `
        -Budget $Budget `
        -IncludeBudget `
        -RemoveKey:$RemoveKey
}

function Get-KimiConfiguration {
    $path = try { Get-KimiConfigPath } catch { $null }
    return Get-ProviderKeyConfiguration -Path $path
}

function Save-KimiConfiguration {
    param(
        [AllowEmptyString()]
        [string]$ApiKey,
        [switch]$RemoveKey
    )

    Save-ProviderKeyConfiguration `
        -Path (Get-KimiConfigPath) `
        -ApiKey $ApiKey `
        -RemoveKey:$RemoveKey
}
