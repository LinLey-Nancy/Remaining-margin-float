#ifndef AppVersion
  #error AppVersion must be provided by Build-Installer.ps1
#endif
#ifndef PackageDirectory
  #error PackageDirectory must be provided by Build-Installer.ps1
#endif
#ifndef OutputDirectory
  #error OutputDirectory must be provided by Build-Installer.ps1
#endif

[Setup]
AppId={{62A9B547-A78D-4BCA-94AC-C6022AC592D2}
AppName=Remaining Margin Float
AppVersion={#AppVersion}
AppVerName=Remaining Margin Float v{#AppVersion}
AppPublisher=LinLey-Nancy
AppPublisherURL=https://github.com/LinLey-Nancy/Remaining-margin-float
AppSupportURL=https://github.com/LinLey-Nancy/Remaining-margin-float/issues
AppUpdatesURL=https://github.com/LinLey-Nancy/Remaining-margin-float/releases
DefaultDirName={localappdata}\Programs\Remaining Margin Float
DefaultGroupName=Remaining Margin Float
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
OutputDir={#OutputDirectory}
OutputBaseFilename=Remaining-Margin-Float-v{#AppVersion}-Setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
SetupLogging=yes
Uninstallable=yes
UninstallDisplayIcon={app}\RemainingMarginFloat.exe
VersionInfoVersion={#AppVersion}.0
VersionInfoProductVersion={#AppVersion}
VersionInfoCompany=LinLey-Nancy
VersionInfoDescription=Remaining Margin Float installer
VersionInfoProductName=Remaining Margin Float
LicenseFile={#PackageDirectory}\LICENSE
InfoBeforeFile={#PackageDirectory}\PRIVACY.md

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#PackageDirectory}\RemainingMarginFloat.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDirectory}\RemainingMarginFloat.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDirectory}\README.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDirectory}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDirectory}\PRIVACY.md"; DestDir: "{app}"; Flags: ignoreversion

[Registry]
Root: HKCU; Subkey: "Software\RemainingMarginFloat"; ValueType: string; ValueName: "InstallLocation"; ValueData: "{app}"; Flags: uninsdeletevalue uninsdeletekeyifempty

[Icons]
Name: "{group}\Remaining Margin Float"; Filename: "{app}\RemainingMarginFloat.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Remaining Margin Float"; Filename: "{app}\RemainingMarginFloat.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\RemainingMarginFloat.exe"; WorkingDir: "{app}"; Flags: nowait; Check: ShouldRestartAfterAutomaticUpdate
Filename: "{app}\RemainingMarginFloat.exe"; Description: "{cm:LaunchProgram,Remaining Margin Float}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ""Remaining Margin Float"" /F"; Flags: runhidden; RunOnceId: "RemoveStartupTask"
Filename: "{sys}\reg.exe"; Parameters: "DELETE ""HKCU\Software\Microsoft\Windows\CurrentVersion\Run"" /v RemainingMarginFloat /f"; Flags: runhidden; RunOnceId: "RemoveStartupRegistry"

[UninstallDelete]
Type: files; Name: "{userstartup}\Remaining Margin Float.lnk"

[Code]
function ShouldRestartAfterAutomaticUpdate: Boolean;
var
  Index: Integer;
begin
  Result := False;
  for Index := 1 to ParamCount do
  begin
    if CompareText(ParamStr(Index), '/RMFAUTORESTART=1') = 0 then
    begin
      Result := True;
      Exit;
    end;
  end;
end;
