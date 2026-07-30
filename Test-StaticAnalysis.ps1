param(
    [string]$RequiredVersion = '1.25.0'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module PSScriptAnalyzer -RequiredVersion $RequiredVersion

$failures = New-Object System.Collections.ArrayList
$paths = @(git ls-files '*.ps1')
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to enumerate tracked PowerShell scripts.'
}

foreach ($path in $paths) {
    $fullPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $path))
    $definition = [IO.File]::ReadAllText(
        $fullPath,
        [Text.Encoding]::UTF8
    )
    foreach ($finding in @(
        Invoke-ScriptAnalyzer `
            -ScriptDefinition $definition `
            -Severity Error
    )) {
        [void]$failures.Add(
            '{0}:{1}:{2}: [{3}] {4}' -f
                $path,
                $finding.Line,
                $finding.Column,
                $finding.RuleName,
                $finding.Message
        )
    }
}

if ($failures.Count -gt 0) {
    throw ($failures -join [Environment]::NewLine)
}

[pscustomobject]@{
    AnalyzerVersion = $RequiredVersion
    ScriptCount = $paths.Count
    ErrorCount = 0
}
