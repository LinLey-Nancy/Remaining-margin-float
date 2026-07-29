function Get-AppDataDirectory {
    $directory = Join-Path $env:LOCALAPPDATA 'RemainingMarginFloat'
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    # Preserve existing settings and DPAPI-encrypted credentials when upgrading
    # from the previous application name. The legacy directory remains intact.
    $legacyDirectory = Join-Path $env:LOCALAPPDATA 'CodexMarginFloat'
    if (Test-Path -LiteralPath $legacyDirectory) {
        foreach ($fileName in @('deepseek.json', 'settings.json')) {
            $legacyPath = Join-Path $legacyDirectory $fileName
            $newPath = Join-Path $directory $fileName
            if (
                (Test-Path -LiteralPath $legacyPath) -and
                -not (Test-Path -LiteralPath $newPath)
            ) {
                try {
                    Copy-Item -LiteralPath $legacyPath -Destination $newPath
                }
                catch {
                    # Migration is best-effort; the app can recreate either file.
                }
            }
        }
    }
    return $directory
}

function Get-DeepSeekConfigPath {
    return Join-Path (Get-AppDataDirectory) 'deepseek.json'
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

function Get-DeepSeekConfiguration {
    $result = [ordered]@{
        EncryptedApiKey = ''
        KeyHint = ''
        Budget = 0.0
    }
    try {
        $path = Get-DeepSeekConfigPath
        if (Test-Path -LiteralPath $path) {
            $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($saved.PSObject.Properties['EncryptedApiKey']) {
                $result.EncryptedApiKey = [string]$saved.EncryptedApiKey
            }
            if ($saved.PSObject.Properties['KeyHint']) {
                $result.KeyHint = [string]$saved.KeyHint
            }
            if ($saved.PSObject.Properties['Budget']) {
                $result.Budget = [Math]::Max(0, [double]$saved.Budget)
            }
        }
    }
    catch {
        # A damaged optional configuration must not prevent the widget starting.
    }
    return [pscustomobject]$result
}

function Save-DeepSeekConfiguration {
    param(
        [AllowEmptyString()]
        [string]$ApiKey,
        [double]$Budget,
        [switch]$RemoveKey
    )

    $current = Get-DeepSeekConfiguration
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

    [ordered]@{
        EncryptedApiKey = $encryptedApiKey
        KeyHint = $keyHint
        Budget = [Math]::Max(0, $Budget)
    } | ConvertTo-Json | Set-Content -LiteralPath (Get-DeepSeekConfigPath) -Encoding UTF8
}
