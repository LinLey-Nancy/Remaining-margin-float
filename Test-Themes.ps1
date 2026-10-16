param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'src\RemainingMarginFloat.ps1'),
    [string]$CaptureDirectory = ''
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$profileDirectory = Join-Path ([IO.Path]::GetTempPath()) ('RmfThemeTest-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($profileDirectory)
$previousLocalAppData = $env:LOCALAPPDATA
try {
    $env:LOCALAPPDATA = $profileDirectory
    $arguments = @('-NoProfile','-NonInteractive','-STA','-File', $ScriptPath, '-CheckThemes')
    if ($CaptureDirectory) { $arguments += @('-CaptureDirectory', [IO.Path]::GetFullPath($CaptureDirectory)) }
    $ErrorActionPreference = 'Continue'
    $output = @(& powershell.exe @arguments 2>&1)
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -ne 0) { throw ($output -join [Environment]::NewLine) }
    $result = ($output -join [Environment]::NewLine) | ConvertFrom-Json
    if (-not $result.Passed) { throw 'Theme diagnostics did not pass.' }
    Write-Output ('Theme checks passed: {0}' -f $result.Count)
    if ($CaptureDirectory) { Write-Output ('Screenshots: {0}' -f $result.Captures.Count) }
}
finally {
    $env:LOCALAPPDATA = $previousLocalAppData
    # Only the explicitly created test directory may be removed.
    $resolvedProfile = [IO.Path]::GetFullPath($profileDirectory)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedProfile.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedProfile) -match '^RmfThemeTest-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolvedProfile -Recurse -Force -ErrorAction SilentlyContinue
    }
}
