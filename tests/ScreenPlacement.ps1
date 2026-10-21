function Get-RmfTestScreenPlacement {
    # The responsiveness probe and the release GUI check start a real, visible
    # application window. Point it at the monitor that hosts the terminal
    # running the checks so the primary monitor, where the user works, stays
    # untouched. When no terminal window can be located (CI, headless runs)
    # the primary work area is the fallback, which is the historical behavior.
    #
    # The returned coordinates are device independent pixels, the unit the
    # application uses for Window.Left and Window.Top. They are derived the
    # same way the application itself converts a monitor work area, so the
    # window really lands on the intended monitor.
    param(
        [double]$Margin = 24,
        [ValidateSet('TopLeft', 'BottomRight')]
        [string]$Corner = 'TopLeft',
        [double]$WindowWidth = 80,
        [double]$WindowHeight = 80
    )

    if (-not ('RmfTestScreenProbe' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class RmfTestScreenProbe
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }

    [DllImport("user32.dll")]
    public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);

    [DllImport("user32.dll")]
    public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

    [DllImport("shcore.dll")]
    public static extern int GetDpiForMonitor(
        IntPtr hMonitor,
        int dpiType,
        out uint dpiX,
        out uint dpiY);

    public static RECT GetWorkArea(IntPtr hwnd)
    {
        IntPtr monitor = MonitorFromWindow(hwnd, 2);
        MONITORINFO info = new MONITORINFO();
        info.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
        if (monitor == IntPtr.Zero || !GetMonitorInfo(monitor, ref info))
        {
            return new RECT();
        }
        return info.rcWork;
    }

    public static double GetScale(IntPtr hwnd)
    {
        IntPtr monitor = MonitorFromWindow(hwnd, 2);
        if (monitor == IntPtr.Zero)
        {
            return 1.0;
        }
        uint dpiX = 0;
        uint dpiY = 0;
        // MDT_EFFECTIVE_DPI is the DPI Windows actually renders the monitor
        // with. The raw panel DPI is not: a 1440x900 panel that reports 121
        // raw DPI still runs at 96 effective DPI, and the application maps its
        // coordinates with the effective value.
        if (GetDpiForMonitor(monitor, 0, out dpiX, out dpiY) != 0 || dpiX == 0)
        {
            return 1.0;
        }
        return dpiX / 96.0;
    }
}
'@
    }

    $hostWindow = [IntPtr]::Zero
    $currentPid = [int]$PID
    for ($level = 0; $level -lt 12; $level++) {
        $candidate = Get-Process -Id $currentPid -ErrorAction SilentlyContinue
        if ($candidate -and $candidate.MainWindowHandle -ne [IntPtr]::Zero) {
            $hostWindow = $candidate.MainWindowHandle
            break
        }
        $parentPid = 0
        try {
            $process = Get-CimInstance Win32_Process `
                -Filter ('ProcessId = {0}' -f $currentPid) `
                -ErrorAction Stop
            $parentPid = [int]$process.ParentProcessId
        }
        catch {
            break
        }
        if ($parentPid -le 4 -or $parentPid -eq $currentPid) { break }
        $currentPid = $parentPid
    }

    $left = 0.0
    $top = 0.0
    $width = 0.0
    $height = 0.0
    if ($hostWindow -ne [IntPtr]::Zero) {
        $rect = [RmfTestScreenProbe]::GetWorkArea($hostWindow)
        if ($rect.Right -gt $rect.Left -and $rect.Bottom -gt $rect.Top) {
            $scale = [RmfTestScreenProbe]::GetScale($hostWindow)
            if ($scale -le 0) { $scale = 1.0 }
            $left = $rect.Left / $scale
            $top = $rect.Top / $scale
            $width = ($rect.Right - $rect.Left) / $scale
            $height = ($rect.Bottom - $rect.Top) / $scale
        }
    }
    if ($width -le 0 -or $height -le 0) {
        Add-Type -AssemblyName System.Windows.Forms
        $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $left = $area.Left
        $top = $area.Top
        $width = $area.Width
        $height = $area.Height
    }

    if ($Corner -eq 'BottomRight') {
        return [pscustomobject]@{
            Left = [Math]::Round($left + $width - $WindowWidth - $Margin, 2)
            Top = [Math]::Round($top + $height - $WindowHeight - $Margin, 2)
        }
    }
    return [pscustomobject]@{
        Left = [Math]::Round($left + $Margin, 2)
        Top = [Math]::Round($top + $Margin, 2)
    }
}
