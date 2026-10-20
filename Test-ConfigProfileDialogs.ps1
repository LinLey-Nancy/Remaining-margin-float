param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'src\RemainingMarginFloat.ps1')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Regression: configuration dialogs must work through the packaged event bridge.
# Direct data diagnostics do not exercise delegate conversion or callback scope.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

public sealed class ConfigDialogResult
{
    public bool Opened, FirstFilled, SecondFilled, FirstRefilled, Redetected, Saved;
    public string Error = "";
}

public static class ConfigDialogDriver
{
    public static void Click(object entry)
    {
        var menu = entry as MenuItem;
        if (menu != null) menu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent, menu));
        else ((System.Windows.Forms.ToolStripMenuItem)entry).PerformClick();
    }

    public static ConfigDialogResult Run(Window owner, object entry, bool edit, string secondHost)
    {
        var result = new ConfigDialogResult();
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
        var started = DateTime.UtcNow;
        int phase = 0;
        Window lastDialog = null;
        timer.Tick += delegate {
            Window dialog = owner.OwnedWindows.Count > 0 ? owner.OwnedWindows[0] : null;
            if (dialog == null) return;
            lastDialog = dialog;
            if ((DateTime.UtcNow - started).TotalSeconds > 15) {
                result.Error = "Dialog operation timed out";
                timer.Stop(); dialog.Close(); return;
            }
            result.Opened = true;
            try {
                var url = (TextBox)dialog.FindName("BaseUrlBox");
                var key = (PasswordBox)dialog.FindName("ApiKeyBox");
                var label = (TextBox)dialog.FindName("LabelBox");
                var combo = (ComboBox)dialog.FindName("DetectCombo");
                var detect = (Button)dialog.FindName("DetectButton");
                if (phase == 5) return;
                if (edit) {
                    label.Text = "QA edited";
                    key.Password = "";
                } else if (phase == 0) {
                    detect.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                    result.FirstFilled = combo.Items.Count == 2 && url.Text.Contains("first.example.test") && key.Password == "synthetic-first-11111";
                    phase++; return;
                } else if (phase == 1) {
                    combo.SelectedIndex = 1;
                    result.SecondFilled = url.Text.Contains(secondHost) && key.Password == "synthetic-second-22222";
                    phase++; return;
                } else if (phase == 2) {
                    combo.SelectedIndex = 0;
                    result.FirstRefilled = url.Text.Contains("first.example.test") && key.Password == "synthetic-first-11111";
                    phase++; return;
                } else if (phase == 3) {
                    detect.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                    combo.SelectedIndex = 1;
                    result.Redetected = combo.Items.Count == 2 && url.Text.Contains(secondHost) && key.Password == "synthetic-second-22222";
                    phase++; return;
                }
                if (!edit) label.Text = "QA saved";
                phase = 5;
                ((Button)dialog.FindName("SaveButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                result.Error = ((TextBlock)dialog.FindName("ErrorText")).Text;
                if (result.Error.Length > 0) { timer.Stop(); dialog.Close(); }
            } catch (Exception ex) {
                result.Error = ex.GetBaseException().Message;
                timer.Stop(); dialog.Close();
            }
        };
        owner.Show();
        timer.Start();
        try { Click(entry); }
        finally { timer.Stop(); }
        result.Saved = phase == 5 && lastDialog != null && !lastDialog.IsVisible && result.Error.Length == 0;
        return result;
    }
}
'@ -ReferencedAssemblies @(
    [Windows.Window].Assembly.Location,
    [Windows.Controls.Button].Assembly.Location,
    [Windows.Threading.Dispatcher].Assembly.Location,
    [Windows.Media.Visual].Assembly.Location,
    'System.Xaml',
    [Windows.Forms.ToolStripMenuItem].Assembly.Location
)

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('RmfConfigDialogTest-' + [Guid]::NewGuid().ToString('N'))
$environmentBefore = @{}
foreach ($name in @('LOCALAPPDATA', 'APPDATA', 'USERPROFILE', 'KIMI_CODE_HOME', 'DEEPSEEK_API_KEY')) {
    $environmentBefore[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$runspace = $null
$pipeline = $null
$ownerWindow = $null
try {
    $env:LOCALAPPDATA = Join-Path $temporaryRoot 'local'
    $env:USERPROFILE = Join-Path $temporaryRoot 'home'
    $env:APPDATA = Join-Path $env:USERPROFILE 'AppData\Roaming'
    $env:KIMI_CODE_HOME = Join-Path $env:USERPROFILE '.kimi-code'
    $env:DEEPSEEK_API_KEY = 'synthetic-second-22222'
    [void][IO.Directory]::CreateDirectory($env:KIMI_CODE_HOME)
    [void][IO.Directory]::CreateDirectory((Join-Path $env:USERPROFILE '.claude'))
    [void][IO.Directory]::CreateDirectory((Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'))
    @'
[providers.first]
base_url = "https://first.example.test/coding/v1"
api_key = "synthetic-first-11111"
[providers.second]
base_url = "https://second.example.test/coding/v1"
api_key = "synthetic-second-22222"
'@ | Set-Content -LiteralPath (Join-Path $env:KIMI_CODE_HOME 'config.toml') -Encoding UTF8
    '{"env":{"ANTHROPIC_BASE_URL":"https://first.example.test","ANTHROPIC_AUTH_TOKEN":"synthetic-first-11111"}}' |
        Set-Content -LiteralPath (Join-Path $env:USERPROFILE '.claude\settings.json') -Encoding UTF8

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.ThreadOptions = 'UseCurrentThread'
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('RmfHostRunspace', $runspace)
    $runspace.SessionStateProxy.SetVariable('RmfHostOwnsMessageLoop', $true)
    $runspace.SessionStateProxy.SetVariable('DialogTestScriptPath', [IO.Path]::GetFullPath($ScriptPath))
    $pipeline = [Management.Automation.PowerShell]::Create()
    $pipeline.Runspace = $runspace

    function Invoke-DialogTestScript {
        param([string]$Text)
        $pipeline.Commands.Clear()
        $pipeline.Streams.Error.Clear()
        [void]$pipeline.AddScript($Text, $false)
        $output = @($pipeline.Invoke())
        if ($pipeline.HadErrors) { throw ($pipeline.Streams.Error | Out-String) }
        return $output
    }

    [void](Invoke-DialogTestScript @'
. $DialogTestScriptPath -Demo
$timer.Stop()
$activationTimer.Stop()
$script:TrayNotifyIcon.Visible = $false
$script:KimiUseWsl = $false
$script:isDiagnosticRun = $false
$script:OnboardingCompleted = $true
$script:InitialRefreshQueued = $true
'@)
    $ownerWindow = $runspace.SessionStateProxy.GetVariable('window')
    $bridge = $runspace.SessionStateProxy.GetVariable('RunspaceEventBridge')
    foreach ($provider in @('Kimi', 'DeepSeek')) {
        $runspace.SessionStateProxy.SetVariable('DialogTestProvider', $provider)
        [void](Invoke-DialogTestScript @'
Set-ActiveProvider -Provider $DialogTestProvider
Sync-ProviderMenuState
# A disabled parent disables its entire drop-down, so the "当前配置" header must
# stay enabled or no saved profile can be selected.
$script:DialogTestMenuEnabled = (
    [bool]$script:ConfigProfileMenuItem.IsEnabled -and
    [bool]$script:TrayConfigProfileItem.Enabled -and
    @($script:ConfigProfileMenuItem.Items | Where-Object {
        $_ -is [Windows.Controls.MenuItem] -and $_.IsEnabled
    }).Count -gt 0 -and
    @($script:TrayConfigProfileItem.DropDownItems | Where-Object {
        $_ -is [Windows.Forms.ToolStripMenuItem] -and $_.Enabled
    }).Count -gt 0
)
# The real menu entry must retain its provider after Sync returns.
$script:DialogTestEntry = $script:ConfigProfileMenuItem.Items[$script:ConfigProfileMenuItem.Items.Count - 2]
if ($DialogTestProvider -eq 'DeepSeek') {
    $script:DialogTestEntry = $script:TrayConfigProfileItem.DropDownItems[$script:TrayConfigProfileItem.DropDownItems.Count - 2]
}
'@)
        if (-not $runspace.SessionStateProxy.GetVariable('DialogTestMenuEnabled')) {
            throw "$provider configuration menu is disabled as a whole; saved profiles cannot be switched."
        }
        $entry = $runspace.SessionStateProxy.GetVariable('DialogTestEntry')
        $secondHost = if ($provider -eq 'Kimi') { 'second.example.test' } else { 'api.deepseek.com' }
        $added = [ConfigDialogDriver]::Run($ownerWindow, $entry, $false, $secondHost)
        if (-not ($added.Opened -and $added.FirstFilled -and $added.SecondFilled -and
                $added.FirstRefilled -and $added.Redetected -and $added.Saved) -or
                $bridge.FailedCallbackCount -ne 0) {
            $storedOnFailure = Invoke-DialogTestScript '@(Get-StoredConfigProfileEntries -Refresh) | Select-Object Label,BaseUrl'
            throw ('{0} add dialog failed: {1}; bridge: {2}; stored: {3}' -f $provider,
                ($added | ConvertTo-Json -Compress), $bridge.LastCallbackError, ($storedOnFailure | ConvertTo-Json -Compress))
        }
        $saved = @(Invoke-DialogTestScript @'
$profile = Get-ResolvedConfigProfile -Provider $DialogTestProvider -Refresh
[pscustomobject]@{
    Label = $profile.Label
    SecretMatches = (Get-ConfigProfileSecret -Profile $profile) -eq 'synthetic-second-22222'
    UrlMatches = $profile.BaseUrl -eq (Resolve-ConfigProfileBaseUrl -Provider $DialogTestProvider -BaseUrl (@(Get-DetectedConfigCandidate -Provider $DialogTestProvider)[1].BaseUrl))
    ActiveMatches = (Get-ActiveConfigProfileId -Provider $DialogTestProvider) -eq $profile.Id
}
'@)[0]
        if ($saved.Label -ne 'QA saved' -or -not ($saved.SecretMatches -and $saved.UrlMatches -and $saved.ActiveMatches)) {
            throw "$provider saved the wrong detected profile."
        }
        [void](Invoke-DialogTestScript @'
Sync-ProviderMenuState
$script:DialogTestEntry = $script:ConfigProfileMenuItem.Items[$script:ConfigProfileMenuItem.Items.Count - 1]
if ($DialogTestProvider -eq 'Kimi') {
    $script:DialogTestEntry = $script:TrayConfigProfileItem.DropDownItems[$script:TrayConfigProfileItem.DropDownItems.Count - 1]
}
'@)
        $entry = $runspace.SessionStateProxy.GetVariable('DialogTestEntry')
        $edited = [ConfigDialogDriver]::Run($ownerWindow, $entry, $true, $secondHost)
        $editValid = @(Invoke-DialogTestScript @'
$profile = Get-ResolvedConfigProfile -Provider $DialogTestProvider -Refresh
($profile.Label -eq 'QA edited' -and (Get-ConfigProfileSecret -Profile $profile) -eq 'synthetic-second-22222')
'@)[0]
        if (-not ($edited.Opened -and $edited.Saved -and $editValid) -or $bridge.FailedCallbackCount -ne 0) {
            throw ('{0} edit dialog failed: {1}; bridge: {2}' -f $provider,
                ($edited | ConvertTo-Json -Compress), $bridge.LastCallbackError)
        }
        [void](Invoke-DialogTestScript @'
$script:DialogTestFirstId = (Get-ResolvedConfigProfile -Provider $DialogTestProvider).Id
$other = Add-ConfigProfile -Provider $DialogTestProvider -Label 'QA other' -BaseUrl 'http://127.0.0.1:9' -ApiKey 'synthetic-other-33333'
$script:DialogTestSecondId = $other.Id
[void](Set-ActiveConfigProfile -Provider $DialogTestProvider -ConfigId $script:DialogTestSecondId)
Sync-ProviderMenuState
$script:DialogTestSwitch = @($script:ConfigProfileMenuItem.Items | Where-Object {
    $_ -is [Windows.Controls.MenuItem] -and $_.Tag -and $_.Tag.PSObject.Properties['ConfigId'] -and $_.Tag.ConfigId -eq $script:DialogTestFirstId
})[0]
'@)
        [ConfigDialogDriver]::Click($runspace.SessionStateProxy.GetVariable('DialogTestSwitch'))
        $firstSelected = @(Invoke-DialogTestScript '(Get-ActiveConfigProfileId -Provider $DialogTestProvider) -eq $script:DialogTestFirstId')[0]
        [void](Invoke-DialogTestScript @'
$script:DialogTestSwitch = @($script:TrayConfigProfileItem.DropDownItems | Where-Object {
    $_ -is [Windows.Forms.ToolStripMenuItem] -and $_.Tag -and $_.Tag.PSObject.Properties['ConfigId'] -and $_.Tag.ConfigId -eq $script:DialogTestSecondId
})[0]
'@)
        [ConfigDialogDriver]::Click($runspace.SessionStateProxy.GetVariable('DialogTestSwitch'))
        $secondSelected = @(Invoke-DialogTestScript '(Get-ActiveConfigProfileId -Provider $DialogTestProvider) -eq $script:DialogTestSecondId')[0]
        if (-not ($firstSelected -and $secondSelected) -or $bridge.FailedCallbackCount -ne 0) {
            throw "$provider configuration menu selected the wrong profile."
        }
        Write-Output "$provider dialog checks passed: add, switch detected profiles, re-detect, save, edit with unchanged key."
    }
    # Run the real early-exit worker, rather than calling backfill after every
    # provider module has loaded (which masks missing shared dependencies).
    [void](Invoke-DialogTestScript @'
$seedTime = [DateTimeOffset]::Now.AddMinutes(-30)
$seed = Get-DeepSeekDemoSnapshot
$seed.SampledAt = $seedTime
$seed.TotalBalance = 123.45
[void](Save-UsageStateSnapshot -Snapshot $seed -ObservedAt $seedTime -Reason 'Manual')
'@)
    $repairOutput = @(& powershell.exe -NoProfile -NonInteractive -STA -File ([IO.Path]::GetFullPath($ScriptPath)) -RepairUsageHistory)
    if ($LASTEXITCODE -ne 0) { throw 'Headless history repair process failed.' }
    $repair = ($repairOutput -join [Environment]::NewLine) | ConvertFrom-Json
    $repaired = @(Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'RemainingMarginFloat\usage-history.jsonl') -Encoding UTF8 |
        ForEach-Object { $_ | ConvertFrom-Json } | Where-Object {
            $_.ProviderId -eq 'DeepSeek' -and [Math]::Abs([double]$_.RemainingValue - 123.45) -lt 0.0001
        })
    if ($repair.FailedEntries -ne 0 -or $repair.AddedSamples -lt 1 -or $repaired.Count -lt 1) {
        throw ('Headless history repair did not restore its seeded sample: ' + ($repair | ConvertTo-Json -Compress))
    }
    Write-Output 'Headless history repair checks passed: seeded balance sample restored by the real worker.'
}
finally {
    if ($ownerWindow) { $ownerWindow.Close() }
    if ($pipeline) { $pipeline.Dispose() }
    if ($runspace) { $runspace.Dispose() }
    foreach ($name in $environmentBefore.Keys) {
        [Environment]::SetEnvironmentVariable($name, $environmentBefore[$name], 'Process')
    }
    $resolvedRoot = [IO.Path]::GetFullPath($temporaryRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedRoot) -match '^RmfConfigDialogTest-[a-f0-9]{32}$' -and
        (Test-Path -LiteralPath $resolvedRoot)) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
