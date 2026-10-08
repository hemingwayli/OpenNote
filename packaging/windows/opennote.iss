#ifndef ReleaseDir
  #error ReleaseDir is required
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif
#define AppVersion "0.1.0"
#ifdef Candidate
  #define ProductId "OpenNote-EPUB-PDF-Candidate"
  #define ProductName "OpenNote EPUB／PDF 候选版"
  #define ProductFolder "OpenNote-EPUB-PDF-Candidate"
#else
  #define ProductId "{{E7A94626-9D1F-46A1-87CF-0395DAE6A205}"
  #define ProductName "OpenNote"
  #define ProductFolder "OpenNote"
#endif

[Setup]
AppId={#ProductId}
AppName={#ProductName}
AppVersion={#AppVersion}
AppPublisher=OpenNote contributors
DefaultDirName={localappdata}\Programs\{#ProductFolder}
DefaultGroupName={#ProductName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
MinVersion=10.0.22000
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=OpenNote-0.1.0-Windows-x64-Setup
Compression=lzma2/fast
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\opennote.exe
CloseApplications=yes
RestartApplications=no
LicenseFile=..\..\LICENSE

[Languages]
Name: "chinesesimp"; MessagesFile: "ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.pdb,onnxruntime.dll,native_assets.json"

[Icons]
Name: "{group}\{#ProductName}"; Filename: "{app}\opennote.exe"
Name: "{autodesktop}\{#ProductName}"; Filename: "{app}\opennote.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; Flags: unchecked

[Run]
Filename: "{app}\opennote.exe"; Description: "启动 OpenNote"; Flags: nowait postinstall skipifsilent
