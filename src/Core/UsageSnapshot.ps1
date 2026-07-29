function Assert-UsageSnapshotContract {
    param($Snapshot)

    if (-not $Snapshot) {
        throw 'Usage provider returned an empty snapshot.'
    }

    $requiredProperties = @(
        'ProviderId',
        'Available',
        'HasProgress',
        'RemainingPercent',
        'WindowLabel',
        'Plan',
        'AccountName',
        'AccountEmail',
        'SampledAt',
        'Status',
        'Source'
    )
    $missingProperties = @(
        $requiredProperties | Where-Object {
            -not $Snapshot.PSObject.Properties[$_]
        }
    )
    if ($missingProperties.Count -gt 0) {
        throw (
            'Usage provider snapshot is missing required properties: ' +
            ($missingProperties -join ', ')
        )
    }
}
