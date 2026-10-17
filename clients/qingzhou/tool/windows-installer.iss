#ifndef AppVersion
  #error AppVersion is required
#endif

[Setup]
AppId=QingzhouProxy.Windows.Preview
AppName=轻舟代理
AppVersion={#AppVersion}
AppPublisher=Qingzhou
DefaultDirName={localappdata}\Programs\QingzhouProxy
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir=..\..\..\outputs
OutputBaseFilename=qingzhou-{#AppVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\qingzhou.exe
CloseApplications=yes
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\轻舟代理"; Filename: "{app}\qingzhou.exe"; WorkingDir: "{app}"
Name: "{userdesktop}\轻舟代理"; Filename: "{app}\qingzhou.exe"; WorkingDir: "{app}"

[Run]
Filename: "{app}\qingzhou.exe"; Description: "Launch Qingzhou Proxy"; Flags: nowait postinstall skipifsilent

[Code]
procedure ConfigureService(Uninstalling: Boolean);
var
  Arguments: String;
  ExitCode: Integer;
begin
  Arguments := '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\install-windows.ps1') + '" -ServiceOnly';
  if Uninstalling then Arguments := Arguments + ' -Uninstall';
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Arguments,
      ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ExitCode) then
    RaiseException('Unable to start network service setup.');
  if ExitCode <> 0 then
    RaiseException('Network service setup failed. Installation log: %LOCALAPPDATA%\QingzhouProxy\install.log');
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  // 普通用户安装界面，仅由服务安装脚本请求管理员授权。
  if CurStep = ssPostInstall then ConfigureService(False);
end;

function InitializeUninstall(): Boolean;
begin
  Result := False;
  try
    // 网络恢复或服务删除失败时保留程序及恢复记录。
    ConfigureService(True);
    Result := True;
  except
    MsgBox(GetExceptionMessage, mbError, MB_OK);
  end;
end;
