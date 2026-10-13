; The Windows installer of Immuch360 Desktop, for Inno Setup 6. It installs the folder that
; .github/desktop/windows_bundle.py makes for the ZIP, so that the installer and the ZIP carry the same files, and is
; compiled by .github/desktop/desktop_installers.py windows, which gives these defines:
;
;   SourceDir     that folder: immuch360.exe, the DLLs, data, licenses and BUILD-INFO.txt
;   AppLabel      the version label of desktop_version.py (3.3.0-rc.0-desktop.5)
;   FileVersion   the four numbers of the file version of immuch360.exe (3.3.0.23)
;   Associations  the [Registry] entries made from .github/desktop/file-associations.json: "Open with" and the
;                 Default apps settings offer the app for those photos and videos; it never becomes their default
;
; One installer for both ways: for every user of the PC in Program Files (administrator rights), or for the current
; user only in %LOCALAPPDATA%\Programs (no rights needed, the default). A dialog asks; /ALLUSERS and /CURRENTUSER
; answer on the command line. The language of the installer is that of Windows, and the first dialog lists every
; language Inno Setup ships (/LANG= on the command line). Uninstalling removes the program, its shortcuts and its
; registry entries; the sign in, folders and settings of each user stay in their profile, as with the ZIP.

#ifndef SourceDir
  #error Give the folder made by windows_bundle.py: iscc /DSourceDir=<folder> (see desktop_installers.py)
#endif
#ifndef AppLabel
  #error Give the version label: iscc /DAppLabel=<label>
#endif
#ifndef FileVersion
  #error Give the file version of immuch360.exe: iscc /DFileVersion=<A.B.C.D>
#endif
#ifndef Associations
  #error Give the registry entries made by desktop_installers.py inno: iscc /DAssociations=<file>
#endif

#define AppName "Immuch360 Desktop"
#define AppExe "immuch360.exe"
#define RepoRoot AddBackslash(SourcePath) + "..\..\..\.."

[Setup]
; Never change the AppId: Windows finds the installed copy by it, to update or uninstall it
AppId={{B692BB40-CAF9-4A1A-9058-4D2629A0E79A}
AppName={#AppName}
AppVersion={#AppLabel}
AppVerName={#AppName} {#AppLabel}
AppPublisher=Immuch360
AppPublisherURL=https://github.com/freeKC/Immuch360
AppSupportURL=https://github.com/freeKC/Immuch360/issues
AppUpdatesURL=https://github.com/freeKC/Immuch360/releases
AppCopyright=Copyright (C) 2026 the Immuch360 and Immich contributors. AGPL-3.0.
VersionInfoVersion={#FileVersion}
VersionInfoProductName={#AppName}
VersionInfoProductVersion={#FileVersion}
VersionInfoProductTextVersion={#AppLabel}
VersionInfoDescription={#AppName} Setup
DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
WizardStyle=modern
SetupIconFile={#RepoRoot}\mobile\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
; The single instance mutex of the app (mobile/windows/runner/app_identity.h): Setup asks to close a running copy
AppMutex=Immuch360Desktop.SingleInstance
ChangesAssociations=yes
ShowLanguageDialog=yes
LanguageDetectionMethod=uilanguage
Compression=lzma2/max
SolidCompression=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
; Every translation in the Languages folder of the compiler: the list follows the Inno Setup that compiles
#define FindHandle
#define FindResult
#sub AddLanguage
  #define public LanguageFile FindGetFileName(FindHandle)
Name: "{#LowerCase(RemoveFileExt(LanguageFile))}"; MessagesFile: "compiler:Languages\{#LanguageFile}"
#endsub
#for {FindHandle = FindResult = FindFirst(AddBackslash(CompilerPath) + "Languages\*.isl", 0); FindResult; FindResult = FindNext(FindHandle)} AddLanguage
#if FindHandle
  #expr FindClose(FindHandle)
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Registry]
#include Associations

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
