param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist'),
    [switch]$SkipArchive
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$versionFile = Join-Path $projectRoot 'VERSION'
$appScript = Join-Path $projectRoot 'src\RemainingMarginFloat.ps1'
$componentManifestPath = Join-Path $projectRoot 'src\Components.psd1'
$mainWindowXamlPath = Join-Path $projectRoot 'src\UI\MainWindow.xaml'
$licensePath = Join-Path $projectRoot 'LICENSE'
$privacyPath = Join-Path $projectRoot 'PRIVACY.md'
$version = (Get-Content -LiteralPath $versionFile -Raw).Trim()

if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw "VERSION must use semantic versioning (for example, 1.2.3): $version"
}
foreach ($requiredSourcePath in @(
    $appScript
    $componentManifestPath
    $mainWindowXamlPath
    $licensePath
    $privacyPath
)) {
    if (-not (Test-Path -LiteralPath $requiredSourcePath -PathType Leaf)) {
        throw "Application source is missing: $requiredSourcePath"
    }
}

function Get-BundledApplicationScript {
    $sourceRoot = Join-Path $projectRoot 'src'
    $entryLines = [IO.File]::ReadAllLines($appScript, [Text.Encoding]::UTF8)
    $headerEnd = [Array]::IndexOf($entryLines, '# RMF_BUNDLE_HEADER_END')
    if ($headerEnd -lt 0) {
        throw 'Application entry script does not contain the bundle header marker.'
    }

    $manifest = Import-PowerShellDataFile -LiteralPath $componentManifestPath
    $componentPaths = @($manifest.Components)
    if ($componentPaths.Count -eq 0) {
        throw 'Application component manifest is empty.'
    }

    $bundle = New-Object Text.StringBuilder
    for ($lineIndex = 0; $lineIndex -le $headerEnd; $lineIndex++) {
        [void]$bundle.AppendLine($entryLines[$lineIndex])
    }

    $xaml = [IO.File]::ReadAllText($mainWindowXamlPath, [Text.Encoding]::UTF8)
    if ($xaml -match "(?m)^'@$") {
        throw 'Main window XAML cannot be embedded safely because it contains a here-string terminator.'
    }
    [void]$bundle.AppendLine()
    [void]$bundle.AppendLine('$script:RmfBundledXaml = @''')
    [void]$bundle.Append($xaml.TrimEnd("`r", "`n"))
    [void]$bundle.AppendLine()
    [void]$bundle.AppendLine("'@")

    foreach ($relativeComponentPath in $componentPaths) {
        $componentPath = [IO.Path]::GetFullPath(
            (Join-Path $sourceRoot $relativeComponentPath)
        )
        if (-not $componentPath.StartsWith(
            $sourceRoot + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Application component escapes the source directory: $relativeComponentPath"
        }
        if (-not (Test-Path -LiteralPath $componentPath -PathType Leaf)) {
            throw "Application component is missing: $componentPath"
        }

        [void]$bundle.AppendLine()
        [void]$bundle.AppendLine("# component: $relativeComponentPath")
        [void]$bundle.Append(
            [IO.File]::ReadAllText($componentPath, [Text.Encoding]::UTF8).
                TrimEnd("`r", "`n")
        )
        [void]$bundle.AppendLine()
    }

    return $bundle.ToString()
}

$productName = "Remaining-Margin-Float-v$version"
$packageRoot = Join-Path $outputRoot $productName
$executablePath = Join-Path $packageRoot 'RemainingMarginFloat.exe'
$packagedScriptPath = Join-Path $packageRoot 'RemainingMarginFloat.ps1'
$packageReadmePath = Join-Path $packageRoot 'README.txt'
$packageLicensePath = Join-Path $packageRoot 'LICENSE'
$packagePrivacyPath = Join-Path $packageRoot 'PRIVACY.md'
$archivePath = Join-Path $outputRoot "$productName.zip"
$archiveChecksumPath = "$archivePath.sha256"
$buildRoot = Join-Path $outputRoot ".codex-margin-float-build-$PID"
$iconPath = Join-Path $buildRoot 'RemainingMarginFloat.ico'

New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

foreach ($oldOutput in @(
    $packageRoot
    $archivePath
    $archiveChecksumPath
    (Join-Path $outputRoot "$productName.exe")
    (Join-Path $outputRoot "$productName.exe.sha256")
    $buildRoot
)) {
    if (Test-Path -LiteralPath $oldOutput) {
        Remove-Item -LiteralPath $oldOutput -Recurse -Force
    }
}

New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

try {
    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object Drawing.Bitmap 32, 32
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([Drawing.Color]::Transparent)
    $circleBrush = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 144, 165, 147))
    $textBrush = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 250, 249, 246))
    $font = New-Object Drawing.Font 'Segoe UI', 17, ([Drawing.FontStyle]::Bold), ([Drawing.GraphicsUnit]::Pixel)
    $textFormat = New-Object Drawing.StringFormat
    $textFormat.Alignment = [Drawing.StringAlignment]::Center
    $textFormat.LineAlignment = [Drawing.StringAlignment]::Center

    try {
        $graphics.FillEllipse($circleBrush, 1, 1, 30, 30)
        $iconRectangle = New-Object Drawing.RectangleF 1, 0, 30, 31
        $graphics.DrawString('R', $font, $textBrush, $iconRectangle, $textFormat)
        $iconHandle = $bitmap.GetHicon()
        $icon = [Drawing.Icon]::FromHandle($iconHandle)
        $iconStream = [IO.File]::Create($iconPath)
        try {
            $icon.Save($iconStream)
        }
        finally {
            $iconStream.Dispose()
            $icon.Dispose()
        }
    }
    finally {
        $textFormat.Dispose()
        $font.Dispose()
        $textBrush.Dispose()
        $circleBrush.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }

    $bundledApplicationScript = Get-BundledApplicationScript
    [IO.File]::WriteAllText(
        $packagedScriptPath,
        $bundledApplicationScript,
        (New-Object Text.UTF8Encoding($true))
    )
    $scriptHash = (Get-FileHash -LiteralPath $packagedScriptPath -Algorithm SHA256).
        Hash.ToLowerInvariant()
    $assemblyVersion = "$version.0"

    $launcherSource = @'
using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows;
using System.Windows.Forms;

[assembly: AssemblyTitle("Remaining Margin Float")]
[assembly: AssemblyDescription("Lightweight Codex and DeepSeek usage widget")]
[assembly: AssemblyProduct("Remaining Margin Float")]
[assembly: AssemblyCompany("LinLey-Nancy")]
[assembly: AssemblyCopyright("Copyright (c) 2026")]
[assembly: AssemblyVersion("__ASSEMBLY_VERSION__")]
[assembly: AssemblyFileVersion("__ASSEMBLY_VERSION__")]
[assembly: AssemblyInformationalVersion("__VERSION__")]

internal static class Launcher
{
    private const string ScriptFileName = "RemainingMarginFloat.ps1";
    private const string ScriptSha256 = "__SCRIPT_SHA256__";

    private static void StopEventBridge(Runspace runspace)
    {
        try
        {
            object bridge =
                runspace.SessionStateProxy.GetVariable("RunspaceEventBridge");
            if (bridge == null)
            {
                return;
            }
            MethodInfo shutdown = bridge.GetType().GetMethod("Shutdown");
            if (shutdown != null)
            {
                shutdown.Invoke(bridge, null);
            }
        }
        catch
        {
            // The window is already closed; shutdown must remain best effort.
        }
    }

    [STAThread]
    private static int Main()
    {
        bool launcherCheck = String.Equals(
            Environment.GetEnvironmentVariable(
                "REMAINING_MARGIN_FLOAT_LAUNCHER_CHECK",
                EnvironmentVariableTarget.Process
            ),
            "1",
            StringComparison.Ordinal
        );
        bool guiCheck = String.Equals(
            Environment.GetEnvironmentVariable(
                "REMAINING_MARGIN_FLOAT_GUI_CHECK",
                EnvironmentVariableTarget.Process
            ),
            "1",
            StringComparison.Ordinal
        );
        try
        {
            string executablePath = Assembly.GetExecutingAssembly().Location;
            string applicationRoot = Path.GetDirectoryName(executablePath);
            string scriptPath = Path.Combine(applicationRoot, ScriptFileName);
            byte[] scriptBytes = ReadVerifiedScript(scriptPath);
            string scriptText = DecodeScript(scriptBytes);

            Environment.SetEnvironmentVariable(
                "REMAINING_MARGIN_FLOAT_LAUNCHER",
                executablePath,
                EnvironmentVariableTarget.Process
            );
            Environment.SetEnvironmentVariable(
                "REMAINING_MARGIN_FLOAT_SCRIPT",
                scriptPath,
                EnvironmentVariableTarget.Process
            );

            InitialSessionState initialState = InitialSessionState.CreateDefault();
            using (Runspace runspace = RunspaceFactory.CreateRunspace(initialState))
            {
                runspace.ApartmentState = ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();
                runspace.SessionStateProxy.Path.SetLocation(applicationRoot);
                runspace.SessionStateProxy.SetVariable("RmfHostRunspace", runspace);
                runspace.SessionStateProxy.SetVariable(
                    "RmfHostOwnsMessageLoop",
                    !launcherCheck
                );

                using (PowerShell powerShell = PowerShell.Create())
                {
                    powerShell.Runspace = runspace;
                    powerShell.AddScript(scriptText, false);
                    if (launcherCheck)
                    {
                        powerShell.AddParameter("CheckTransitions", true);
                    }
                    powerShell.Invoke();
                    if (powerShell.HadErrors)
                    {
                        string message = "The application script reported an error.";
                        if (powerShell.Streams.Error.Count > 0)
                        {
                            message += Environment.NewLine + Environment.NewLine +
                                powerShell.Streams.Error[0].Exception.Message;
                        }
                        throw new InvalidOperationException(message);
                    }
                }

                object existingInstanceResult =
                    runspace.SessionStateProxy.GetVariable(
                        "RmfActivatedExistingInstance"
                    );
                bool activatedExistingInstance =
                    existingInstanceResult is bool &&
                    (bool)existingInstanceResult;

                if (!launcherCheck && !activatedExistingInstance)
                {
                    Window applicationWindow =
                        runspace.SessionStateProxy.GetVariable("window") as Window;
                    if (applicationWindow == null)
                    {
                        throw new InvalidOperationException(
                            "The application script did not create its main window."
                        );
                    }
                    if (guiCheck)
                    {
                        bool guiCallbackObserved = false;
                        bool refreshTimerObserved = false;
                        bool refreshDataObserved = false;
                        string refreshDataDetails = String.Empty;
                        System.Windows.Threading.DispatcherTimer guiCheckTimer =
                            new System.Windows.Threading.DispatcherTimer();
                        guiCheckTimer.Interval = TimeSpan.FromSeconds(7);
                        guiCheckTimer.Tick += delegate(object sender, EventArgs e)
                        {
                            guiCheckTimer.Stop();
                            object callbackResult =
                                runspace.SessionStateProxy.GetVariable(
                                    "RmfGuiCheckPassed"
                                );
                            guiCallbackObserved =
                                callbackResult is bool &&
                                (bool)callbackResult;
                            object refreshTimerResult =
                                runspace.SessionStateProxy.GetVariable(
                                    "RmfRefreshTimerProbePassed"
                                );
                            refreshTimerObserved =
                                refreshTimerResult is bool &&
                                (bool)refreshTimerResult;
                            object refreshDataResult =
                                runspace.SessionStateProxy.GetVariable(
                                    "RmfRefreshDataProbePassed"
                                );
                            refreshDataObserved =
                                refreshDataResult is bool &&
                                (bool)refreshDataResult;
                            object refreshDetailsResult =
                                runspace.SessionStateProxy.GetVariable(
                                    "RmfRefreshDataProbeDetails"
                                );
                            refreshDataDetails = refreshDetailsResult == null
                                ? String.Empty
                                : refreshDetailsResult.ToString();
                            object bridgeResult =
                                runspace.SessionStateProxy.GetVariable(
                                    "RunspaceEventBridge"
                                );
                            string bridgeDetails = String.Empty;
                            if (bridgeResult != null)
                            {
                                PropertyInfo failedCountProperty =
                                    bridgeResult.GetType().GetProperty(
                                        "FailedCallbackCount"
                                    );
                                PropertyInfo lastErrorProperty =
                                    bridgeResult.GetType().GetProperty(
                                        "LastCallbackError"
                                    );
                                bridgeDetails = String.Format(
                                    "bridgeFailures={0}; bridgeError={1}",
                                    failedCountProperty == null
                                        ? "unknown"
                                        : failedCountProperty.GetValue(
                                            bridgeResult,
                                            null
                                        ),
                                    lastErrorProperty == null
                                        ? String.Empty
                                        : lastErrorProperty.GetValue(
                                            bridgeResult,
                                            null
                                        )
                                );
                            }
                            object autoRefreshResult =
                                runspace.SessionStateProxy.GetVariable(
                                    "AutoRefreshText"
                                );
                            string autoRefreshDetails = String.Empty;
                            if (autoRefreshResult != null)
                            {
                                PropertyInfo textProperty =
                                    autoRefreshResult.GetType().GetProperty(
                                        "Text"
                                    );
                                autoRefreshDetails = textProperty == null
                                    ? String.Empty
                                    : Convert.ToString(
                                        textProperty.GetValue(
                                            autoRefreshResult,
                                            null
                                        )
                                    );
                            }
                            string guiResultPath =
                                Environment.GetEnvironmentVariable(
                                    "REMAINING_MARGIN_FLOAT_GUI_CHECK_RESULT",
                                    EnvironmentVariableTarget.Process
                                );
                            if (!String.IsNullOrWhiteSpace(guiResultPath))
                            {
                                File.WriteAllText(
                                    guiResultPath,
                                    String.Format(
                                        "callback={0}; timer={1}; data={2}; autoText={3}; {4}; {5}",
                                        guiCallbackObserved,
                                        refreshTimerObserved,
                                        refreshDataObserved,
                                        autoRefreshDetails,
                                        bridgeDetails,
                                        refreshDataDetails
                                    )
                                );
                            }
                            applicationWindow.Close();
                            StopEventBridge(runspace);
                        };
                        guiCheckTimer.Start();
                        applicationWindow.ShowDialog();
                        if (
                            !guiCallbackObserved ||
                            !refreshTimerObserved ||
                            !refreshDataObserved
                        )
                        {
                            throw new InvalidOperationException(
                                "The packaged GUI callback, local refresh, or timer probe did not run. " +
                                refreshDataDetails
                            );
                        }
                    }
                    else
                    {
                        applicationWindow.ShowDialog();
                    }
                    StopEventBridge(runspace);
                }
            }

            Array.Clear(scriptBytes, 0, scriptBytes.Length);
            return 0;
        }
        catch (Exception exception)
        {
            if (launcherCheck || guiCheck)
            {
                return 1;
            }
            System.Windows.Forms.MessageBox.Show(
                "Remaining Margin Float failed to start.\r\n\r\n" + exception.Message,
                "Remaining Margin Float",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error
            );
            return 1;
        }
    }

    private static string DecodeScript(byte[] scriptBytes)
    {
        string scriptText = new UTF8Encoding(false, true).GetString(scriptBytes);
        if (scriptText.Length > 0 && scriptText[0] == '\uFEFF')
        {
            scriptText = scriptText.Substring(1);
        }
        return scriptText;
    }

    private static byte[] ReadVerifiedScript(string scriptPath)
    {
        if (!File.Exists(scriptPath))
        {
            throw new FileNotFoundException(
                "The application script must remain beside RemainingMarginFloat.exe.",
                scriptPath
            );
        }

        byte[] scriptBytes = File.ReadAllBytes(scriptPath);
        string actualHash;
        using (SHA256 sha256 = SHA256.Create())
        {
            actualHash = BitConverter.ToString(
                sha256.ComputeHash(scriptBytes)
            ).Replace("-", "").ToLowerInvariant();
        }

        if (!String.Equals(
            actualHash,
            ScriptSha256,
            StringComparison.OrdinalIgnoreCase))
        {
            Array.Clear(scriptBytes, 0, scriptBytes.Length);
            throw new InvalidDataException(
                "RemainingMarginFloat.ps1 does not match this launcher. " +
                "Download the official package again."
            );
        }
        return scriptBytes;
    }
}
'@

    $launcherSource = $launcherSource.
        Replace('__VERSION__', $version).
        Replace('__ASSEMBLY_VERSION__', $assemblyVersion).
        Replace('__SCRIPT_SHA256__', $scriptHash)

    Add-Type -AssemblyName Microsoft.CSharp
    Add-Type -AssemblyName System.Management.Automation
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName System.Xaml
    $automationAssembly = [Management.Automation.PowerShell].Assembly.Location
    $windowsBaseAssembly = [Windows.Threading.Dispatcher].Assembly.Location
    $presentationCoreAssembly = [Windows.UIElement].Assembly.Location
    $presentationFrameworkAssembly = [Windows.Window].Assembly.Location
    $systemXamlAssembly = [System.Xaml.XamlReader].Assembly.Location
    $provider = New-Object Microsoft.CSharp.CSharpCodeProvider
    $compilerParameters = New-Object System.CodeDom.Compiler.CompilerParameters
    $compilerParameters.GenerateExecutable = $true
    $compilerParameters.GenerateInMemory = $false
    $compilerParameters.IncludeDebugInformation = $false
    $compilerParameters.TreatWarningsAsErrors = $true
    $compilerParameters.OutputAssembly = $executablePath
    $compilerParameters.CompilerOptions = (
        '/target:winexe /platform:anycpu /optimize+ /win32icon:"{0}"' -f $iconPath
    )
    [void]$compilerParameters.ReferencedAssemblies.Add('System.dll')
    [void]$compilerParameters.ReferencedAssemblies.Add('System.Core.dll')
    [void]$compilerParameters.ReferencedAssemblies.Add($windowsBaseAssembly)
    [void]$compilerParameters.ReferencedAssemblies.Add($presentationCoreAssembly)
    [void]$compilerParameters.ReferencedAssemblies.Add($presentationFrameworkAssembly)
    [void]$compilerParameters.ReferencedAssemblies.Add($systemXamlAssembly)
    [void]$compilerParameters.ReferencedAssemblies.Add('System.Windows.Forms.dll')
    [void]$compilerParameters.ReferencedAssemblies.Add($automationAssembly)

    try {
        $compilerResult = $provider.CompileAssemblyFromSource(
            $compilerParameters,
            $launcherSource
        )
    }
    finally {
        $provider.Dispose()
    }

    if ($compilerResult.Errors.HasErrors) {
        $messages = @($compilerResult.Errors | ForEach-Object {
            '{0}({1},{2}): {3} {4}' -f `
                $_.FileName, $_.Line, $_.Column, $_.ErrorNumber, $_.ErrorText
        })
        throw "EXE compilation failed:`r`n$($messages -join [Environment]::NewLine)"
    }

    @"
Remaining Margin Float $version

1. Keep RemainingMarginFloat.exe and RemainingMarginFloat.ps1 in the same directory.
2. Run RemainingMarginFloat.exe.
3. The launcher verifies the script SHA-256 before running it in-process.
4. No PowerShell child process is created and no execution-policy bypass is used.
5. LICENSE contains the MIT license; PRIVACY.md describes local data handling.

Official releases:
https://github.com/LinLey-Nancy/Remaining-margin-float/releases
"@ | Set-Content -LiteralPath $packageReadmePath -Encoding UTF8
    Copy-Item -LiteralPath $licensePath -Destination $packageLicensePath
    Copy-Item -LiteralPath $privacyPath -Destination $packagePrivacyPath
}
finally {
    if (Test-Path -LiteralPath $buildRoot) {
        Remove-Item -LiteralPath $buildRoot -Recurse -Force
    }
}

$archiveResult = $null
if (-not $SkipArchive) {
    $archiveResult = & (Join-Path $projectRoot 'Finalize-Package.ps1') `
        -OutputDirectory $outputRoot `
        -Version $version
}

$fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($executablePath)
[pscustomobject]@{
    Version = $version
    PackageDirectory = $packageRoot
    Executable = $executablePath
    Script = $packagedScriptPath
    FileVersion = $fileVersion.FileVersion
    ScriptSha256 = $scriptHash
    Archive = if ($SkipArchive) { $null } else { $archivePath }
    ArchiveSha256 = if ($archiveResult) { $archiveResult.Sha256 } else { $null }
}
