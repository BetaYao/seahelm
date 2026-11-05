; Inno Setup script for the GPUI client on Windows: one setup.exe that puts
; seahelm-gpui.exe and the daemons it starts (seahelmd, seahelm-core,
; seahelm-gateway, seahelm, seahelm-hook) in one folder, where the client
; looks for them beside itself.
;
; Per user, no administrator rights: %LOCALAPPDATA%\Programs\Seahelm GPUI.
;
;   iscc /DSourceDir=<folder with the .exe files> /DAppVersion=2.0.81 ^
;        /DOutputDir=<dist> /DOutputBaseName=seahelm-gpui-windows-x86_64-setup seahelm-gpui.iss

#ifndef SourceDir
  #error SourceDir is required
#endif
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif
#ifndef OutputBaseName
  #define OutputBaseName "seahelm-gpui-setup"
#endif

[Setup]
; Fixed for every version, so a new setup upgrades the installed copy.
AppId={{6B0E7C1A-3F4D-4E2B-9C51-5A2D8E7F4B10}
AppName=Seahelm GPUI
AppVersion={#AppVersion}
AppPublisher=Seahelm
AppPublisherURL=https://seahelm.dev
AppSupportURL=https://github.com/BetaYao/seahelm/issues
DefaultDirName={localappdata}\Programs\Seahelm GPUI
DefaultGroupName=Seahelm GPUI
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseName}
SetupIconFile=seahelm.ico
UninstallDisplayIcon={app}\seahelm.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Upgrading over a running copy: let Restart Manager close it, do not reopen.
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\seahelm-gpui.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\seahelmd.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\seahelm-core.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\seahelm-gateway.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\seahelm.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\seahelm-hook.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "seahelm.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Seahelm GPUI"; Filename: "{app}\seahelm-gpui.exe"; IconFilename: "{app}\seahelm.ico"
Name: "{group}\{cm:UninstallProgram,Seahelm GPUI}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Seahelm GPUI"; Filename: "{app}\seahelm-gpui.exe"; IconFilename: "{app}\seahelm.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\seahelm-gpui.exe"; Description: "{cm:LaunchProgram,Seahelm GPUI}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; The services keep running after the window closes; a running .exe cannot be
; removed. Stopping seahelmd ends its terminal sessions, which is what
; uninstalling means.
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM seahelm-gateway.exe"; Flags: runhidden; RunOnceId: "StopGateway"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM seahelm-core.exe"; Flags: runhidden; RunOnceId: "StopCore"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM seahelmd.exe"; Flags: runhidden; RunOnceId: "StopDaemon"

[Code]
// Upgrading: seahelm-core and seahelm-gateway are background services the
// client restarts on its next launch, so stop them rather than fail on their
// files being in use. seahelmd is left to Restart Manager's prompt: stopping
// it ends the user's terminal sessions.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM seahelm-gateway.exe', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM seahelm-core.exe', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Result := '';
end;
