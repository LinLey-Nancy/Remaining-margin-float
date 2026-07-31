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

function ConvertTo-LogicalWorkArea {
    param(
        [double]$PixelLeft,
        [double]$PixelTop,
        [double]$PixelRight,
        [double]$PixelBottom,
        [double]$DpiScaleX = 1.0,
        [double]$DpiScaleY = 1.0
    )

    if ($DpiScaleX -le 0 -or $DpiScaleY -le 0) {
        throw 'DPI scale must be greater than zero.'
    }
    return [pscustomobject]@{
        Left = $PixelLeft / $DpiScaleX
        Top = $PixelTop / $DpiScaleY
        Right = $PixelRight / $DpiScaleX
        Bottom = $PixelBottom / $DpiScaleY
        Width = ($PixelRight - $PixelLeft) / $DpiScaleX
        Height = ($PixelBottom - $PixelTop) / $DpiScaleY
    }
}

function Test-WorkAreaEquivalent {
    param(
        $First,
        $Second,
        [double]$Tolerance = 0.1
    )

    if ($null -eq $First -or $null -eq $Second) { return $false }
    return (
        [Math]::Abs([double]$First.Left - [double]$Second.Left) -lt
            $Tolerance -and
        [Math]::Abs([double]$First.Top - [double]$Second.Top) -lt
            $Tolerance -and
        [Math]::Abs([double]$First.Right - [double]$Second.Right) -lt
            $Tolerance -and
        [Math]::Abs([double]$First.Bottom - [double]$Second.Bottom) -lt
            $Tolerance
    )
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
