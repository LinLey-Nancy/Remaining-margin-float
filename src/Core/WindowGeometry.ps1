function Get-FittedPlacement {
    param(
        [double]$AnchorLeft,
        [double]$AnchorTop,
        [double]$TargetWidth,
        [double]$TargetHeight,
        [double]$WorkLeft,
        [double]$WorkTop,
        [double]$WorkRight,
        [double]$WorkBottom
    )

    $targetLeft = [Math]::Min($AnchorLeft, $WorkRight - $TargetWidth)
    $targetTop = [Math]::Min($AnchorTop, $WorkBottom - $TargetHeight)
    return [pscustomobject]@{
        Left = [Math]::Max($WorkLeft, $targetLeft)
        Top = [Math]::Max($WorkTop, $targetTop)
    }
}

function Get-EdgeDockSideForPosition {
    param(
        [double]$Left,
        [double]$Width,
        [double]$WorkLeft,
        [double]$WorkRight,
        [double]$SnapDistance
    )

    $right = $Left + $Width
    $leftDistance = [Math]::Abs($Left - $WorkLeft)
    $rightDistance = [Math]::Abs($right - $WorkRight)
    $touchesLeft = (
        $Left -le ($WorkLeft + $SnapDistance) -and
        $right -gt $WorkLeft
    )
    $touchesRight = (
        $right -ge ($WorkRight - $SnapDistance) -and
        $Left -lt $WorkRight
    )
    if ($touchesLeft -and (-not $touchesRight -or $leftDistance -le $rightDistance)) {
        return 'Left'
    }
    if ($touchesRight) {
        return 'Right'
    }
    return $null
}

function Get-EdgeDockPlacement {
    param(
        [ValidateSet('Left', 'Right')]
        [string]$Side,
        [bool]$Revealed,
        [double]$WindowWidth,
        [double]$VisibleWidth,
        [double]$WorkLeft,
        [double]$WorkRight
    )

    if ($Side -eq 'Left') {
        if ($Revealed) { return $WorkLeft }
        return $WorkLeft - $WindowWidth + $VisibleWidth
    }
    if ($Revealed) { return $WorkRight - $WindowWidth }
    return $WorkRight - $VisibleWidth
}
