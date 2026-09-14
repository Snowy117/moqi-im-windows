; Moqi IM for Windows — Inno Setup 6 wizard (x64 + ARM64).
; Build: install Inno Setup 6.3+ (ARM64 support), then run build-installer.ps1
; -StageDir <stage root>. When the stage contains the ARM64 payload, the
; builder passes /DMOQI_ARM64 and this script ships the ARM64 files too.
; AppId / IME CLSID: keep stable across releases (ARP upgrade path).

#define MyAppName "墨奇输入法"
#define MyAppPublisher "Moqi"
#define MyAppURL "https://github.com/gaboolic/moqi-im-windows"
#define MyAppId "{{C7A6A2D5-16C7-4BE4-8F52-E96D6D6A9E42}"
; ImeClsid is used inside [Code] Pascal strings, where ISPP substitutes the
; literal text: the value must be the plain single-brace CLSID form that
; regsvr32 writes (StringFromCLSID), or the registry checks/deletes below
; never match.
#define ImeClsid "{8F204C91-2D7A-4B3E-9E1F-6A5C0D8B2E7F}"

#ifndef StageDir
  #define StageDir "..\stage"
#endif

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion=1.0.0
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf32}\MoqiIM
DisableProgramGroupPage=yes
PrivilegesRequired=admin
#ifdef MOQI_ARM64
ArchitecturesAllowed=x64 arm64
ArchitecturesInstallIn64BitMode=x64 arm64
#else
; Without the ARM64 payload the installer cannot register a native TSF DLL,
; so refuse to run on ARM64 hosts.
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
#endif
CloseApplications=yes
RestartApplications=no
WizardStyle=modern
OutputDir=dist
OutputBaseFilename=moqi-im-windows-setup
Compression=lzma2/max
SolidCompression=yes
WizardSizePercent=110,100
DisableWelcomePage=no

[Languages]
; Use the vendored translation file so packaging does not depend on local Inno Setup language packs.
Name: "chinesesimplified"; MessagesFile: ".\Inno-Setup-Chinese-Simplified-Translation\ChineseSimplified.isl"

[Files]
; arm64\ and the architecture-split server are released by their own entries
; below, so keep them out of the catch-all payload copy.
Source: "{#StageDir}\win32\MoqiIM\*"; DestDir: "{app}"; Excludes: "arm64\*"; Flags: ignoreversion recursesubdirs createallsubdirs
#ifdef MOQI_ARM64
; x64/x86 machines get the amd64 backend; ARM64 machines get the arm64 one.
Source: "{#StageDir}\server-amd64.exe"; DestDir: "{app}\moqi-ime"; DestName: "server.exe"; Check: NotArm64Host; Flags: ignoreversion
Source: "{#StageDir}\server-arm64.exe"; DestDir: "{app}\moqi-ime"; DestName: "server.exe"; Check: IsArm64Host; Flags: ignoreversion
; ARM64X forwarder + ARM64 native TSF DLL, deployed by SetupHelper into System32.
Source: "{#StageDir}\win32\MoqiIM\arm64\MoqiTextService.dll"; DestDir: "{app}\arm64"; Check: IsArm64Host; Flags: ignoreversion
Source: "{#StageDir}\win32\MoqiIM\arm64\MoqiTextServiceARM64X.dll"; DestDir: "{app}\arm64"; Check: IsArm64Host; Flags: ignoreversion
#endif

[Icons]
Name: "{autoprograms}\{#MyAppName}\Uninstall"; Filename: "{uninstallexe}"
Name: "{autoprograms}\{#MyAppName}\Logs"; Filename: "{win}\explorer.exe"; Parameters: """{localappdata}\MoqiIM\Log"""

[Run]
Filename: "{app}\MoqiLauncher.exe"; Flags: nowait; Check: ShouldLaunchLauncher

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
  ValueType: string; ValueName: "MoqiLauncher"; \
  ValueData: """{app}\MoqiLauncher.exe"""; \
  Flags: uninsdeletevalue

[InstallDelete]
Type: filesandordirs; Name: "{app}\moqi-ime"
Type: filesandordirs; Name: "{app}\x64"
Type: filesandordirs; Name: "{app}\arm64"

[Code]
const
  SetupHelperExitSuccess = 0;
  SetupHelperExitRestartRequired = 2;

var
  HelperInstallSucceeded: Boolean;
  HelperInstallNeedsRestart: Boolean;
  HelperUninstallNeedsRestart: Boolean;
  HadExistingInstall: Boolean;

function IsArm64Host(): Boolean;
begin
  Result := IsARM64;
end;

function NotArm64Host(): Boolean;
begin
  Result := not IsARM64;
end;

function ExistingImeInstallationPresent: Boolean;
begin
  Result :=
    FileExists(ExpandConstant('{app}\MoqiLauncher.exe')) or
    FileExists(ExpandConstant('{syswow64}\MoqiTextService.dll')) or
    FileExists(ExpandConstant('{sys}\MoqiTextService.dll')) or
    RegKeyExists(HKEY_LOCAL_MACHINE, 'SOFTWARE\Microsoft\CTF\TIP\{#ImeClsid}') or
    RegKeyExists(HKEY_CURRENT_USER, 'Software\Microsoft\CTF\TIP\{#ImeClsid}') or
    RegKeyExists(HKEY_CLASSES_ROOT, 'CLSID\{#ImeClsid}') or
    RegKeyExists(HKEY_CURRENT_USER, 'Software\Classes\CLSID\{#ImeClsid}');
end;

procedure RegPurgeMoqiResiduals;
var
  ClsidKey: String;
  TipKey: String;
begin
  ClsidKey := 'CLSID\{#ImeClsid}';
  TipKey := 'SOFTWARE\Microsoft\CTF\TIP\{#ImeClsid}';
  if RegKeyExists(HKEY_CLASSES_ROOT, ClsidKey) then
    RegDeleteKeyIncludingSubkeys(HKEY_CLASSES_ROOT, ClsidKey);
  if RegKeyExists(HKEY_LOCAL_MACHINE, TipKey) then
    RegDeleteKeyIncludingSubkeys(HKEY_LOCAL_MACHINE, TipKey);
  if RegKeyExists(HKEY_CURRENT_USER, 'Software\Microsoft\CTF\TIP\{#ImeClsid}') then
    RegDeleteKeyIncludingSubkeys(HKEY_CURRENT_USER, 'Software\Microsoft\CTF\TIP\{#ImeClsid}');
  if RegKeyExists(HKEY_CURRENT_USER, 'Software\Classes\CLSID\{#ImeClsid}') then
    RegDeleteKeyIncludingSubkeys(HKEY_CURRENT_USER, 'Software\Classes\CLSID\{#ImeClsid}');
end;

procedure TryKillProcessImage(const ImageName: String);
var
  R: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /T /IM "' + ImageName + '"',
    '', SW_HIDE, ewWaitUntilTerminated, R);
end;

procedure StopMoqiProcesses;
begin
  TryKillProcessImage('MoqiLauncher.exe');
end;

function GetSetupHelperPath: string;
begin
  Result := ExpandConstant('{app}\SetupHelper.exe');
end;

procedure EnsureSetupHelperExists;
begin
  if not FileExists(GetSetupHelperPath) then
    RaiseException('SetupHelper.exe not found: ' + GetSetupHelperPath);
end;

function RunSetupHelper(const Parameters: string; var ResultCode: Integer): Boolean;
begin
  EnsureSetupHelperExists;
  Result := Exec(GetSetupHelperPath, Parameters, ExpandConstant('{app}'),
    SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if not Result then
    ResultCode := -1;
end;

function BuildInstallSetupHelperParameters(const Action: string): string;
begin
  Result := Action;
  if WizardSilent() then
    Result := Result + ' /s';
  Result := Result + ' --appdir "' + ExpandConstant('{app}') + '"';
end;

function BuildUninstallSetupHelperParameters(const Action: string): string;
begin
  Result := Action;
  if UninstallSilent() then
    Result := Result + ' /s';
  Result := Result + ' --appdir "' + ExpandConstant('{app}') + '"';
end;

procedure HandleSetupHelperResult(const Operation: string; const ResultCode: Integer);
begin
  RaiseException(Operation + ' failed (exit code ' + IntToStr(ResultCode) + ').');
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if CurStep = ssInstall then
  begin
    HadExistingInstall := ExistingImeInstallationPresent;
    StopMoqiProcesses;
  end;

  if CurStep = ssPostInstall then
  begin
    if not RunSetupHelper(BuildInstallSetupHelperParameters('/i'), ResultCode) then
      HandleSetupHelperResult('SetupHelper install', ResultCode);

    if ResultCode = SetupHelperExitSuccess then
    begin
      HelperInstallSucceeded := True;
      if HadExistingInstall then
        SuppressibleMsgBox(
          '检测到这是一次覆盖安装。若当前会话里仍有旧的 TSF 实例，墨奇可能要在注销或重启 Windows 后才能立即恢复正常输入。',
          mbInformation, MB_OK, IDOK);
    end
    else if ResultCode = SetupHelperExitRestartRequired then
    begin
      HelperInstallSucceeded := True;
      HelperInstallNeedsRestart := True;
      SuppressibleMsgBox(
        '安装程序已更新应用文件，但 TSF DLL 当前仍被系统占用。' + #13#10#13#10 +
        '请在安装完成后尽快重启 Windows。安装器已安排在系统重启后自动完成 TSF 注册。',
        mbInformation, MB_OK, IDOK);
    end;
    if (ResultCode <> SetupHelperExitSuccess) and
       (ResultCode <> SetupHelperExitRestartRequired) then
      HandleSetupHelperResult('SetupHelper install', ResultCode);
  end;
end;

function NeedRestart(): Boolean;
begin
  Result := HelperInstallNeedsRestart;
end;

function ShouldLaunchLauncher(): Boolean;
begin
  Result := HelperInstallSucceeded and (not HelperInstallNeedsRestart);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    StopMoqiProcesses;
    if not RunSetupHelper(BuildUninstallSetupHelperParameters('/u'), ResultCode) then
      HandleSetupHelperResult('SetupHelper uninstall', ResultCode);
    if ResultCode = SetupHelperExitRestartRequired then
      HelperUninstallNeedsRestart := True
    else if ResultCode <> SetupHelperExitSuccess then
      HandleSetupHelperResult('SetupHelper uninstall', ResultCode);
  end;
  if CurUninstallStep = usPostUninstall then
  begin
    RegPurgeMoqiResiduals;
    if HelperUninstallNeedsRestart then
      SuppressibleMsgBox(
        '部分 TSF DLL 已安排在系统重启后删除。请尽快重启 Windows，以完成卸载清理。',
        mbInformation, MB_OK, IDOK);
  end;
end;
