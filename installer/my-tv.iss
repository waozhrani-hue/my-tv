; Inno Setup script for My TV.
;
; The Windows build is a folder, not a single file: MyTV.exe needs
; libmpv-2.dll, flutter_windows.dll and the data/ directory beside it. This
; packages the whole Release folder into one setup.exe so the app can be
; handed to someone as a single download.
;
; Build with:
;   flutter build windows --release
;   ISCC.exe installer\my-tv.iss

#define AppName       "My TV"
#define AppVersion    "1.4.5"
#define AppPublisher  "My TV"
#define AppExe        "MyTV.exe"
#define SourceDir     "..\build\windows\x64\runner\Release"

[Setup]
AppId={{8E4F2A16-9C3D-4B7E-A5F1-2D6C8B0E7A94}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExe}
OutputDir=..\build\installer
OutputBaseFilename=MyTV-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
VersionInfoVersion={#AppVersion}
VersionInfoProductVersion={#AppVersion}
VersionInfoCompany={#AppPublisher}
VersionInfoDescription={#AppName} Setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Per-user installs need no administrator rights, which matters when the
; installer is simply emailed to someone.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
; libmpv ships x64 only.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableProgramGroupPage=yes
DisableDirPage=no
ShowLanguageDialog=auto

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "arabic"; MessagesFile: "compiler:Languages\Arabic.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; The whole build output, recursively: executable, plugin DLLs, libmpv and
; the Flutter asset bundle.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Playlists, favourites and the catalog cache live here. Removed only on
; uninstall, so an upgrade keeps them.
Type: filesandordirs; Name: "{userappdata}\com.mytv\{#AppName}"
