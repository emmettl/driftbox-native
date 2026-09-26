; Driftbox for Windows' installer, built with Inno Setup 6 by scripts/windows-installer.mjs from the
; folder scripts/windows-package.mjs makes. It installs for the person running it, with no
; administrator needed, unless they choose everyone; makes .driftbox songs open in Driftbox, as
; `Driftbox.exe --register` does, if they want that; and gives it all back when uninstalled.
;
; The release workflow has it signed, and the program in it, through SignPath; one built here is not
; signed, and Windows says so before it runs. Its uninstaller is not signed either way: Inno Setup
; signs that only as it compiles, with a certificate on this machine, and SignPath's never is.

#ifndef AppVersion
  #define AppVersion "0.1"
#endif
#ifndef Source
  #define Source "..\dist\Driftbox"
#endif
#ifndef Output
  #define Output "..\dist"
#endif

[Setup]
; What Windows knows this program by from one version to the next: never change it.
AppId={{0E45785D-A395-4AA7-9421-D69C298477C8}
AppName=Driftbox
AppVersion={#AppVersion}
AppVerName=Driftbox {#AppVersion}
AppPublisher=Driftbox
VersionInfoVersion={#AppVersion}
; What the installer says it is, as the programs in it do, and as signing checks.
VersionInfoProductName=Driftbox
VersionInfoProductVersion={#AppVersion}
VersionInfoProductTextVersion={#AppVersion}
VersionInfoDescription=Driftbox Setup
DefaultDirName={autopf}\Driftbox
DefaultGroupName=Driftbox
DisableProgramGroupPage=yes
; For the person installing, in their own Programs folder, unless they choose everyone.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
; 64-bit Windows 10 1703 or later, for the per-monitor DPI the window asks for
; (SetProcessDpiAwarenessContext, per-monitor v2), which the program cannot start without.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.15063
OutputDir={#Output}
OutputBaseFilename=Driftbox-{#AppVersion}-setup-x64
SetupIconFile=Driftbox.ico
UninstallDisplayIcon={app}\Driftbox.exe
UninstallDisplayName=Driftbox
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Explorer is told when the songs' type is made Driftbox's, and when it is given back.
ChangesAssociations=yes

[Tasks]
Name: "songs"; Description: "Open .driftbox songs in Driftbox"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#Source}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Driftbox"; Filename: "{app}\Driftbox.exe"
Name: "{autodesktop}\Driftbox"; Filename: "{app}\Driftbox.exe"; Tasks: desktopicon

[Registry]
; The keys `Driftbox.exe --register` writes, under Software\Classes for whoever the program was
; installed for: the ending names the type, and the type has the program's icon and opens the
; song in it. Taken away again on uninstalling.
Root: HKA; Subkey: "Software\Classes\.driftbox"; ValueType: string; ValueName: ""; ValueData: "Driftbox.Song"; Flags: uninsdeletevalue uninsdeletekeyifempty; Tasks: songs
Root: HKA; Subkey: "Software\Classes\.driftbox\OpenWithProgids"; ValueType: string; ValueName: "Driftbox.Song"; ValueData: ""; Flags: uninsdeletevalue uninsdeletekeyifempty; Tasks: songs
Root: HKA; Subkey: "Software\Classes\Driftbox.Song"; ValueType: string; ValueName: ""; ValueData: "Driftbox Song"; Flags: uninsdeletekey; Tasks: songs
Root: HKA; Subkey: "Software\Classes\Driftbox.Song\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\Driftbox.exe"",0"; Tasks: songs
Root: HKA; Subkey: "Software\Classes\Driftbox.Song\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Driftbox.exe"" ""%1"""; Tasks: songs

[Run]
Filename: "{app}\Driftbox.exe"; Description: "{cm:LaunchProgram,Driftbox}"; Flags: nowait postinstall skipifsilent
