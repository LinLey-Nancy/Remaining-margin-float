Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

public sealed class RemainingMarginRunspaceEventBridge
{
    private sealed class PendingCallback
    {
        public readonly ScriptBlock Callback;
        public readonly object[] Arguments;

        public PendingCallback(ScriptBlock callback, object[] arguments)
        {
            Callback = callback;
            Arguments = arguments;
        }
    }

    private readonly Runspace runspace;
    private readonly Dispatcher dispatcher;
    private readonly Queue<PendingCallback> pendingCallbacks =
        new Queue<PendingCallback>();
    private PowerShell activePowerShell;
    private bool invoking;
    private bool drainScheduled;
    private bool acceptingCallbacks = true;
    private int failedCallbackCount;
    private string lastCallbackError = String.Empty;

    public RemainingMarginRunspaceEventBridge(Runspace runspace)
    {
        this.runspace = runspace;
        this.dispatcher = Dispatcher.CurrentDispatcher;
    }

    private void Invoke(ScriptBlock callback, params object[] arguments)
    {
        if (!acceptingCallbacks || callback == null)
        {
            return;
        }
        if (!dispatcher.CheckAccess())
        {
            try
            {
                dispatcher.BeginInvoke(
                    DispatcherPriority.Normal,
                    new Action(delegate { Invoke(callback, arguments); })
                );
            }
            catch (Exception exception)
            {
                RecordFailure(exception);
            }
            return;
        }

        try
        {
            if (runspace.RunspaceStateInfo.State != RunspaceState.Opened)
            {
                Shutdown();
                return;
            }
            if (invoking)
            {
                if (activePowerShell != null)
                {
                    InvokeNested(callback, arguments);
                    return;
                }
                pendingCallbacks.Enqueue(
                    new PendingCallback(callback, arguments)
                );
                ScheduleDrain();
                return;
            }
            if (runspace.RunspaceAvailability != RunspaceAvailability.Available)
            {
                pendingCallbacks.Enqueue(
                    new PendingCallback(callback, arguments)
                );
                ScheduleDrain();
                return;
            }

            InvokeNow(callback, arguments);
        }
        catch (Exception exception)
        {
            RecordFailure(exception);
        }
    }

    private void RecordFailure(Exception exception)
    {
        failedCallbackCount++;
        lastCallbackError = exception == null
            ? "Unknown UI callback error."
            : exception.GetBaseException().Message;
    }

    private static void ConfigureCallback(
        PowerShell callbackPowerShell,
        ScriptBlock callback,
        object[] arguments
    )
    {
        callbackPowerShell
            .AddCommand("Microsoft.PowerShell.Core\\Invoke-Command")
            .AddParameter("ScriptBlock", callback);
        if (arguments != null && arguments.Length > 0)
        {
            callbackPowerShell.AddParameter("ArgumentList", arguments);
        }
    }

    private static void AssertCallbackSucceeded(PowerShell callbackPowerShell)
    {
        if (!callbackPowerShell.HadErrors)
        {
            return;
        }
        Exception inner = callbackPowerShell.Streams.Error.Count > 0
            ? callbackPowerShell.Streams.Error[0].Exception
            : null;
        throw new InvalidOperationException(
            "A UI event callback failed.",
            inner
        );
    }

    private void InvokeNested(ScriptBlock callback, object[] arguments)
    {
        PowerShell parentPowerShell = activePowerShell;
        using (
            PowerShell nestedPowerShell =
                parentPowerShell.CreateNestedPowerShell()
        )
        {
            activePowerShell = nestedPowerShell;
            try
            {
                ConfigureCallback(nestedPowerShell, callback, arguments);
                nestedPowerShell.Invoke();
                AssertCallbackSucceeded(nestedPowerShell);
            }
            finally
            {
                activePowerShell = parentPowerShell;
            }
        }
    }

    private void InvokeNow(ScriptBlock callback, object[] arguments)
    {
        invoking = true;
        try
        {
            using (PowerShell callbackPowerShell = PowerShell.Create())
            {
                callbackPowerShell.Runspace = runspace;
                activePowerShell = callbackPowerShell;
                try
                {
                    ConfigureCallback(
                        callbackPowerShell,
                        callback,
                        arguments
                    );
                    callbackPowerShell.Invoke();
                    AssertCallbackSucceeded(callbackPowerShell);
                }
                finally
                {
                    activePowerShell = null;
                }
            }
        }
        finally
        {
            invoking = false;
            ScheduleDrain();
        }
    }

    private void ScheduleDrain()
    {
        if (
            !acceptingCallbacks ||
            drainScheduled ||
            pendingCallbacks.Count == 0
        )
        {
            return;
        }

        drainScheduled = true;
        dispatcher.BeginInvoke(
            DispatcherPriority.ContextIdle,
            new Action(Drain)
        );
    }

    private void Drain()
    {
        try
        {
            DrainCore();
        }
        catch (Exception exception)
        {
            RecordFailure(exception);
            Shutdown();
        }
    }

    private void DrainCore()
    {
        drainScheduled = false;
        if (!acceptingCallbacks)
        {
            pendingCallbacks.Clear();
            return;
        }
        if (runspace.RunspaceStateInfo.State != RunspaceState.Opened)
        {
            Shutdown();
            return;
        }
        if (invoking || pendingCallbacks.Count == 0)
        {
            ScheduleDrain();
            return;
        }
        if (runspace.RunspaceAvailability != RunspaceAvailability.Available)
        {
            ScheduleDrain();
            return;
        }

        PendingCallback pending = pendingCallbacks.Dequeue();
        try
        {
            InvokeNow(pending.Callback, pending.Arguments);
        }
        catch (Exception exception)
        {
            RecordFailure(exception);
        }
    }

    public int FailedCallbackCount
    {
        get { return failedCallbackCount; }
    }

    public string LastCallbackError
    {
        get { return lastCallbackError; }
    }

    public void Shutdown()
    {
        acceptingCallbacks = false;
        pendingCallbacks.Clear();
    }

    public EventHandler Event(ScriptBlock callback)
    {
        return delegate(object sender, EventArgs e) {
            Invoke(callback, sender, e);
        };
    }

    public RoutedEventHandler Routed(ScriptBlock callback)
    {
        return delegate(object sender, RoutedEventArgs e) {
            Invoke(callback, sender, e);
        };
    }

    public MouseEventHandler Mouse(ScriptBlock callback)
    {
        return delegate(object sender, MouseEventArgs e) {
            Invoke(callback, sender, e);
        };
    }

    public MouseButtonEventHandler MouseButton(ScriptBlock callback)
    {
        return delegate(object sender, MouseButtonEventArgs e) {
            Invoke(callback, sender, e);
        };
    }

    public KeyEventHandler Key(ScriptBlock callback)
    {
        return delegate(object sender, KeyEventArgs e) {
            Invoke(callback, sender, e);
        };
    }

    public CancelEventHandler Cancel(ScriptBlock callback)
    {
        return delegate(object sender, CancelEventArgs e) {
            Invoke(callback, sender, e);
        };
    }

    public Forms.MouseEventHandler FormsMouse(ScriptBlock callback)
    {
        return delegate(object sender, Forms.MouseEventArgs e) {
            Invoke(callback, sender, e);
        };
    }

    public Action Action(ScriptBlock callback)
    {
        return delegate { Invoke(callback); };
    }
}
'@ -ReferencedAssemblies @(
    [Management.Automation.PowerShell].Assembly.Location
    [Windows.Threading.Dispatcher].Assembly.Location
    [Windows.UIElement].Assembly.Location
    [Windows.Forms.NotifyIcon].Assembly.Location
    [ComponentModel.CancelEventHandler].Assembly.Location
)
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class RemainingMarginNativeWindow
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetWindowPos(
        IntPtr hWnd,
        IntPtr hWndInsertAfter,
        int X,
        int Y,
        int cx,
        int cy,
        uint uFlags);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
'@
$script:ReducedMotion = -not [System.Windows.SystemParameters]::ClientAreaAnimation
$script:HighContrast = [System.Windows.SystemParameters]::HighContrast

if ([string]::IsNullOrWhiteSpace([string]$script:RmfBundledXaml)) {
    $xamlPath = Join-Path $script:RmfSourceRoot 'UI\MainWindow.xaml'
    if (-not (Test-Path -LiteralPath $xamlPath -PathType Leaf)) {
        throw "Main window XAML is missing: $xamlPath"
    }
    [xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
}
else {
    [xml]$xaml = $script:RmfBundledXaml
}

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$script:RunspaceEventBridge = $null
$embeddedHostRunspace = Get-Variable `
    -Name 'RmfHostRunspace' `
    -ErrorAction SilentlyContinue
$embeddedHostOwnsMessageLoop = Get-Variable `
    -Name 'RmfHostOwnsMessageLoop' `
    -ErrorAction SilentlyContinue
if (
    $embeddedHostRunspace -and
    $embeddedHostRunspace.Value -is
        [Management.Automation.Runspaces.Runspace] -and
    $embeddedHostOwnsMessageLoop -and
    [bool]$embeddedHostOwnsMessageLoop.Value
) {
    $script:RunspaceEventBridge =
        [RemainingMarginRunspaceEventBridge]::new(
            $embeddedHostRunspace.Value
        )
}

function New-RmfEventHandler {
    param(
        [ValidateSet(
            'Event',
            'Routed',
            'Mouse',
            'MouseButton',
            'Key',
            'Cancel',
            'FormsMouse'
        )]
        [string]$Kind,
        [scriptblock]$Callback
    )

    if (-not $script:RunspaceEventBridge) {
        return $Callback
    }
    switch ($Kind) {
        'Event' { return $script:RunspaceEventBridge.Event($Callback) }
        'Routed' { return $script:RunspaceEventBridge.Routed($Callback) }
        'Mouse' { return $script:RunspaceEventBridge.Mouse($Callback) }
        'MouseButton' {
            return $script:RunspaceEventBridge.MouseButton($Callback)
        }
        'Key' { return $script:RunspaceEventBridge.Key($Callback) }
        'Cancel' { return $script:RunspaceEventBridge.Cancel($Callback) }
        'FormsMouse' {
            return $script:RunspaceEventBridge.FormsMouse($Callback)
        }
    }
}

function New-RmfAction {
    param([scriptblock]$Callback)

    if ($script:RunspaceEventBridge) {
        return $script:RunspaceEventBridge.Action($Callback)
    }
    return [Action]$Callback
}

function Stop-RmfEventBridge {
    if ($script:RunspaceEventBridge) {
        $script:RunspaceEventBridge.Shutdown()
    }
}

function Get-RmfEventBridgeFailureCount {
    if (-not $script:RunspaceEventBridge) { return 0 }
    return [int]$script:RunspaceEventBridge.FailedCallbackCount
}
if ($Demo) {
    # Make visual QA builds discoverable to Windows automation tools.
    $window.ShowInTaskbar = $true
}

function Get-WindowExtendedStyle {
    $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
    if ($helper.Handle -eq [IntPtr]::Zero) { return 0 }
    return [RemainingMarginNativeWindow]::GetWindowLong($helper.Handle, -20)
}

function Hide-WindowFromTaskSwitcher {
    $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
    if ($helper.Handle -eq [IntPtr]::Zero) { return $false }

    $toolWindow = 0x00000080
    $appWindow = 0x00040000
    $style = [RemainingMarginNativeWindow]::GetWindowLong($helper.Handle, -20)
    $style = ($style -bor $toolWindow) -band (-bnot $appWindow)
    [void][RemainingMarginNativeWindow]::SetWindowLong($helper.Handle, -20, $style)
    return (($style -band $toolWindow) -ne 0 -and ($style -band $appWindow) -eq 0)
}

function New-TrayAppIcon {
    $bitmap = New-Object Drawing.Bitmap(
        32,
        32,
        [Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $sageBrush = New-Object Drawing.SolidBrush(
        [Drawing.ColorTranslator]::FromHtml('#7E9584')
    )
    $ivoryBrush = New-Object Drawing.SolidBrush(
        [Drawing.ColorTranslator]::FromHtml('#FCFBF8')
    )
    $champagnePen = New-Object Drawing.Pen(
        [Drawing.ColorTranslator]::FromHtml('#BEA374'),
        1.5
    )
    $font = New-Object Drawing.Font(
        'Segoe UI',
        17,
        [Drawing.FontStyle]::Bold,
        [Drawing.GraphicsUnit]::Pixel
    )
    $format = New-Object Drawing.StringFormat
    $format.Alignment = [Drawing.StringAlignment]::Center
    $format.LineAlignment = [Drawing.StringAlignment]::Center

    try {
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $graphics.Clear([Drawing.Color]::Transparent)
        $graphics.FillEllipse($sageBrush, 1, 1, 30, 30)
        $graphics.DrawEllipse($champagnePen, 1.5, 1.5, 29, 29)
        $graphics.DrawString(
            'R',
            $font,
            $ivoryBrush,
            (New-Object Drawing.RectangleF(0, 0, 32, 31)),
            $format
        )

        $iconHandle = $bitmap.GetHicon()
        try {
            return ([Drawing.Icon]::FromHandle($iconHandle).Clone())
        }
        finally {
            [void][RemainingMarginNativeWindow]::DestroyIcon($iconHandle)
        }
    }
    finally {
        $format.Dispose()
        $font.Dispose()
        $champagnePen.Dispose()
        $ivoryBrush.Dispose()
        $sageBrush.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

if (-not $Demo) {
    $window.Add_SourceInitialized((New-RmfEventHandler -Kind Event -Callback {
        [void](Hide-WindowFromTaskSwitcher)
    }))
}

$names = @(
    'WindowRoot', 'HoverHalo', 'Surface', 'SurfaceShadow', 'CompactHit',
    'CompactDivider',
    'UltraCompactPanel', 'UltraProgressTrack', 'UltraProgressFill',
    'UltraProgressOutline', 'UltraDepletedMask', 'UltraLevelMarker',
    'UltraEmptyProgressRow', 'UltraRemainingProgressRow',
    'CompactPrefix', 'RemainingValue', 'CompactSuffix', 'WindowLabel',
    'CompactProgressRow', 'ExpandedWindowLabel', 'ResetSummaryPanel',
    'ProgressTrack', 'RemainingProgressColumn',
    'UsedProgressColumn', 'DetailsPanel', 'AccountName',
    'PlanBadge', 'AccountEmail', 'CloseButton', 'DetailsResetDate',
    'DetailsResetCountdown', 'MetricOneTitle', 'PrimaryMetricValue',
    'PrimaryMetricHint', 'MetricTwoTitle', 'MetricTwoHint',
    'TodayTokens', 'MetricThreeTitle', 'LastTurnTokens', 'ContextText',
    'MetricFourTitle', 'CacheHit', 'BreakdownTitle', 'SecondaryMetricTitle',
    'CacheTokenText', 'ResetCount', 'TokenBreakdown', 'SourceText', 'SampleTime',
    'Trend24Text', 'Trend24Line', 'Trend7Text', 'Trend7Line', 'PredictionText',
    'AutoRefreshText', 'RefreshButton'
)
foreach ($name in $names) {
    Set-Variable -Name $name -Value $window.FindName($name) -Scope Script
}

function Apply-SystemAccessibilityTheme {
    if (-not $script:HighContrast) { return }

    $colorMap = @{
        TextPrimary = [Windows.SystemColors]::WindowTextColor
        TextSecondary = [Windows.SystemColors]::WindowTextColor
        TextMuted = [Windows.SystemColors]::GrayTextColor
        Surface = [Windows.SystemColors]::WindowColor
        SurfaceSubtle = [Windows.SystemColors]::WindowColor
        Border = [Windows.SystemColors]::ActiveBorderColor
        Divider = [Windows.SystemColors]::ActiveBorderColor
        Sage = [Windows.SystemColors]::HighlightColor
        SageSoft = [Windows.SystemColors]::WindowColor
        StatusStrong = [Windows.SystemColors]::WindowTextColor
        StatusBorder = [Windows.SystemColors]::ActiveBorderColor
        Champagne = [Windows.SystemColors]::HighlightColor
    }
    foreach ($resourceName in $colorMap.Keys) {
        $brush = $window.Resources[$resourceName]
        if ($brush -is [Windows.Media.SolidColorBrush]) {
            $brush.Color = $colorMap[$resourceName]
        }
    }
    $Surface.Background = [Windows.SystemColors]::WindowBrush
    $Surface.BorderBrush = [Windows.SystemColors]::ActiveBorderBrush
    $UltraProgressTrack.Background = [Windows.SystemColors]::WindowBrush
    $UltraProgressOutline.BorderBrush = [Windows.SystemColors]::ActiveBorderBrush
}

Apply-SystemAccessibilityTheme

function New-DoubleAnimation {
    param(
        [double]$To,
        [int]$Milliseconds = 220,
        [switch]$EaseOut,
        [switch]$EaseIn
    )
    $animation = New-Object Windows.Media.Animation.DoubleAnimation
    $animation.To = $To
    $effectiveMilliseconds = if ($script:ReducedMotion) { 1 } else { $Milliseconds }
    $animation.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds($effectiveMilliseconds))
    if ($EaseOut -or $EaseIn) {
        $easing = New-Object Windows.Media.Animation.CubicEase
        $easing.EasingMode = if ($EaseIn) {
            [Windows.Media.Animation.EasingMode]::EaseIn
        } else {
            [Windows.Media.Animation.EasingMode]::EaseOut
        }
        $animation.EasingFunction = $easing
    }
    return $animation
}

function Save-VisualPng {
    param(
        [Windows.FrameworkElement]$Element,
        [string]$Path
    )

    $Element.UpdateLayout()
    $dpi = [Windows.Media.VisualTreeHelper]::GetDpi($Element)
    $pixelWidth = [Math]::Max(1, [int][Math]::Ceiling($Element.ActualWidth * $dpi.DpiScaleX))
    $pixelHeight = [Math]::Max(1, [int][Math]::Ceiling($Element.ActualHeight * $dpi.DpiScaleY))
    $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap(
        $pixelWidth,
        $pixelHeight,
        $dpi.PixelsPerInchX,
        $dpi.PixelsPerInchY,
        [Windows.Media.PixelFormats]::Pbgra32
    )
    $bitmap.Render($Element)

    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write)
    try {
        $encoder.Save($stream)
    }
    finally {
        $stream.Dispose()
    }
}

function Get-SettingsPath {
    return Join-Path (Get-AppDataDirectory) 'settings.json'
}
