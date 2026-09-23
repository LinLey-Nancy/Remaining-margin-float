param(
    [Parameter(Mandatory = $true)]
    [string]$TargetPath,
    [string]$ImageName = 'RemainingMarginFloat'
)

$ErrorActionPreference = 'SilentlyContinue'

function Get-RemainingInstances {
    return @(
        Get-CimInstance Win32_Process `
            -Filter "Name = '$ImageName.exe'" |
            Where-Object { $_.ExecutablePath -eq $TargetPath }
    )
}

$graceDeadline = (Get-Date).AddSeconds(8)
$forceDeadline = (Get-Date).AddSeconds(30)

# Hidden background helper instances have no window for the Restart
# Manager to close, so terminate them before the graceful phase.
foreach ($instance in @(Get-RemainingInstances)) {
    if ($instance.CommandLine -match '--repair-usage-history') {
        Stop-Process -Id $instance.ProcessId -Force
    }
}

while ((Get-Date) -lt $forceDeadline) {
    $instances = @(Get-RemainingInstances)
    if ($instances.Count -eq 0) { break }
    foreach ($instance in $instances) {
        $process = Get-Process -Id $instance.ProcessId
        if ($null -eq $process) { continue }
        $closed = $false
        if ((Get-Date) -lt $graceDeadline) {
            if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
                $closed = $process.CloseMainWindow()
            }
        }
        if (-not $closed -and (Get-Date) -ge $graceDeadline) {
            Stop-Process -Id $instance.ProcessId -Force
        }
    }
    Start-Sleep -Milliseconds 500
}
