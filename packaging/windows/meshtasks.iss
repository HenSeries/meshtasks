; Inno Setup script for the Windows installer.
; Build after `flutter build windows --release`:
;   iscc /DAppVersion=0.1.0 packaging\windows\meshtasks.iss
; Output: dist\MeshTasks-Setup-<version>.exe

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#define Bundle "..\..\build\windows\x64\runner\Release"

[Setup]
AppId={{6E3B1C2A-4D7F-4B8E-9A51-3C2D8F0E7A11}
AppName=MeshTasks
AppVersion={#AppVersion}
AppPublisher=Jorge Restrepo
DefaultDirName={autopf}\MeshTasks
DefaultGroupName=MeshTasks
DisableProgramGroupPage=yes
OutputDir=..\..\dist
OutputBaseFilename=MeshTasks-Setup-{#AppVersion}
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\meshtasks.exe
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Admin is needed to add the firewall rules other devices use to reach this one.
PrivilegesRequired=admin
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#Bundle}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\MeshTasks"; Filename: "{app}\meshtasks.exe"
Name: "{autodesktop}\MeshTasks"; Filename: "{app}\meshtasks.exe"; Tasks: desktopicon

[Run]
; Let teammates' devices reach this one on private networks (sync TCP, discovery UDP).
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""MeshTasks sync"" dir=in action=allow program=""{app}\meshtasks.exe"" enable=yes profile=private,domain"; Flags: runhidden
Filename: "{app}\meshtasks.exe"; Description: "{cm:LaunchProgram,MeshTasks}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""MeshTasks sync"""; Flags: runhidden; RunOnceId: "DelFirewall"
