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
$version = (Get-Content -LiteralPath $versionFile -Raw).Trim()

if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw "VERSION must use semantic versioning (for example, 1.2.3): $version"
}
if (-not (Test-Path -LiteralPath $appScript -PathType Leaf)) {
    throw "Application script is missing: $appScript"
}

$productName = "Remaining-Margin-Float-v$version"
$packageRoot = Join-Path $outputRoot $productName
$executablePath = Join-Path $packageRoot 'RemainingMarginFloat.exe'
$packagedScriptPath = Join-Path $packageRoot 'RemainingMarginFloat.ps1'
$packageReadmePath = Join-Path $packageRoot 'README.txt'
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

    Copy-Item -LiteralPath $appScript -Destination $packagedScriptPath
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
            }

            Array.Clear(scriptBytes, 0, scriptBytes.Length);
            return 0;
        }
        catch (Exception exception)
        {
            if (launcherCheck)
            {
                return 1;
            }
            MessageBox.Show(
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
    $automationAssembly = [Management.Automation.PowerShell].Assembly.Location
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

Official releases:
https://github.com/LinLey-Nancy/Remaining-margin-float/releases
"@ | Set-Content -LiteralPath $packageReadmePath -Encoding UTF8
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
