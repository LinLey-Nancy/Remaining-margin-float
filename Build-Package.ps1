param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist')
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
$executablePath = Join-Path $outputRoot "$productName.exe"
$checksumPath = "$executablePath.sha256"
$legacyArchivePath = Join-Path $outputRoot "$productName.zip"
$legacyArchiveChecksumPath = "$legacyArchivePath.sha256"
$buildRoot = Join-Path $outputRoot ".codex-margin-float-build-$PID"
$iconPath = Join-Path $buildRoot 'RemainingMarginFloat.ico'

New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

foreach ($oldOutput in @(
    $executablePath
    $checksumPath
    $legacyArchivePath
    $legacyArchiveChecksumPath
    $buildRoot
)) {
    if (Test-Path -LiteralPath $oldOutput) {
        Remove-Item -LiteralPath $oldOutput -Recurse -Force
    }
}

New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null

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

    $scriptBytes = [IO.File]::ReadAllBytes($appScript)
    $scriptBase64 = [Convert]::ToBase64String($scriptBytes)
    $scriptHash = (Get-FileHash -LiteralPath $appScript -Algorithm SHA256).Hash.ToLowerInvariant()
    $assemblyVersion = "$version.0"

    $launcherSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
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
    private const string Version = "__VERSION__";
    private const string ScriptSha256 = "__SCRIPT_SHA256__";
    private const string EmbeddedScript = "__SCRIPT_BASE64__";
    private const string AppMutexName = @"Local\RemainingMarginFloat.Singleton";
    private const string ActivationEventName = @"Local\RemainingMarginFloat.Activate";
    private const string ExtractMutexName = @"Local\RemainingMarginFloat.LauncherExtract";

    [STAThread]
    private static int Main()
    {
        try
        {
            if (TryActivateExistingInstance())
            {
                return 0;
            }

            string scriptPath = ExtractScript();
            string powerShellPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe"
            );

            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = powerShellPath;
            startInfo.Arguments =
                "-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -File " +
                QuoteArgument(scriptPath);
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.WindowStyle = ProcessWindowStyle.Hidden;
            startInfo.WorkingDirectory = Path.GetDirectoryName(scriptPath);

            Process process = Process.Start(startInfo);
            if (process == null)
            {
                throw new InvalidOperationException("Windows PowerShell could not be started.");
            }
            process.Dispose();
            return 0;
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                "Remaining Margin Float failed to start.\r\n\r\n" + exception.Message,
                "Remaining Margin Float",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error
            );
            return 1;
        }
    }

    private static bool TryActivateExistingInstance()
    {
        try
        {
            using (Mutex.OpenExisting(AppMutexName))
            {
                try
                {
                    using (EventWaitHandle activationEvent =
                        EventWaitHandle.OpenExisting(ActivationEventName))
                    {
                        activationEvent.Set();
                    }
                }
                catch (WaitHandleCannotBeOpenedException)
                {
                    // The application owns the singleton mutex but is still starting.
                }
                return true;
            }
        }
        catch (WaitHandleCannotBeOpenedException)
        {
            return false;
        }
    }

    private static string ExtractScript()
    {
        string applicationRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "RemainingMarginFloat",
            "app",
            Version
        );
        string scriptPath = Path.Combine(applicationRoot, "RemainingMarginFloat.ps1");
        byte[] expectedBytes = Convert.FromBase64String(EmbeddedScript);

        using (Mutex extractMutex = new Mutex(false, ExtractMutexName))
        {
            bool acquired = false;
            try
            {
                try
                {
                    acquired = extractMutex.WaitOne(TimeSpan.FromSeconds(10));
                }
                catch (AbandonedMutexException)
                {
                    acquired = true;
                }

                if (!acquired)
                {
                    throw new TimeoutException("Timed out while preparing application files.");
                }

                Directory.CreateDirectory(applicationRoot);
                if (!File.Exists(scriptPath) ||
                    !String.Equals(
                        ComputeSha256(scriptPath),
                        ScriptSha256,
                        StringComparison.OrdinalIgnoreCase))
                {
                    string temporaryPath =
                        scriptPath + "." + Process.GetCurrentProcess().Id + ".tmp";
                    File.WriteAllBytes(temporaryPath, expectedBytes);
                    try
                    {
                        File.Copy(temporaryPath, scriptPath, true);
                    }
                    finally
                    {
                        if (File.Exists(temporaryPath))
                        {
                            File.Delete(temporaryPath);
                        }
                    }
                }
            }
            finally
            {
                if (acquired)
                {
                    extractMutex.ReleaseMutex();
                }
            }
        }

        return scriptPath;
    }

    private static string ComputeSha256(string path)
    {
        using (SHA256 sha256 = SHA256.Create())
        using (FileStream stream = File.OpenRead(path))
        {
            byte[] hash = sha256.ComputeHash(stream);
            return BitConverter.ToString(hash).Replace("-", "").ToLowerInvariant();
        }
    }

    private static string QuoteArgument(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }
}
'@

    $launcherSource = $launcherSource.
        Replace('__VERSION__', $version).
        Replace('__ASSEMBLY_VERSION__', $assemblyVersion).
        Replace('__SCRIPT_SHA256__', $scriptHash).
        Replace('__SCRIPT_BASE64__', $scriptBase64)

    Add-Type -AssemblyName Microsoft.CSharp
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
}
finally {
    if (Test-Path -LiteralPath $buildRoot) {
        Remove-Item -LiteralPath $buildRoot -Recurse -Force
    }
}

$hash = (Get-FileHash -LiteralPath $executablePath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content `
    -LiteralPath $checksumPath `
    -Value "$hash  $([IO.Path]::GetFileName($executablePath))" `
    -Encoding ASCII

$fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($executablePath)
[pscustomobject]@{
    Version = $version
    Executable = $executablePath
    FileVersion = $fileVersion.FileVersion
    Sha256 = $hash
    SizeBytes = (Get-Item -LiteralPath $executablePath).Length
}
