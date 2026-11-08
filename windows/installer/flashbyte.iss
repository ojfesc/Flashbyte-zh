#ifndef MyAppVersion
  #define MyAppVersion "0.1.0"
#endif

#define MyAppName "Flashbyte"
#define MyAppExeName "flashbyte.exe"
#define MyAppPublisher "Flashbyte"

[Setup]
AppId={{1A2B3C4D-5E6F-7890-ABCD-EF1234567890}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\Flashbyte
DefaultGroupName=Flashbyte
DisableProgramGroupPage=yes
OutputDir=..\..\build\installer
OutputBaseFilename=flashbyte-windows-setup-x64
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\flashbyte.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
VersionInfoVersion={#MyAppVersion}
VersionInfoDescription={#MyAppName} installer
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppVersion}
VersionInfoCompany={#MyAppPublisher}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[CustomMessages]
english.AppDisplayName=Flashbyte
english.CreateDesktopIcon=Create a &desktop shortcut
english.AdditionalIcons=Additional shortcuts:
chinesesimplified.AppDisplayName=Flashbyte
chinesesimplified.CreateDesktopIcon=创建桌面快捷方式(&D)
chinesesimplified.AdditionalIcons=附加快捷方式：

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{cm:AppDisplayName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{cm:AppDisplayName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
