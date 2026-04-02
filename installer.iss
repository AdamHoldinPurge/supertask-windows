; Inno Setup Script for SuperTask™
; Bundles the PyInstaller onedir output into a Windows installer.
; Build with: iscc installer.iss

[Setup]
AppId={{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}
AppName=SuperTask
AppVersion=1.0.0
AppVerName=SuperTask 1.0.0
AppPublisher=SuperTask
AppPublisherURL=https://github.com/adamholdin/supertask-windows
AppSupportURL=https://github.com/adamholdin/supertask-windows/issues
DefaultDirName={autopf}\SuperTask
DefaultGroupName=SuperTask
AllowNoIcons=yes
OutputDir=output
OutputBaseFilename=SuperTask-Setup-1.0.0
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
SetupIconFile=supertask\icon.ico
UninstallDisplayIcon={app}\SuperTask.exe
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; Bundle the entire PyInstaller onedir output
Source: "dist\SuperTask\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\SuperTask"; Filename: "{app}\SuperTask.exe"
Name: "{group}\{cm:UninstallProgram,SuperTask}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\SuperTask"; Filename: "{app}\SuperTask.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\SuperTask.exe"; Description: "{cm:LaunchProgram,SuperTask}"; Flags: nowait postinstall skipifsilent

[Code]
function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
begin
  Result := True;

  // Check if Node.js is installed (required for claude CLI)
  if not Exec('cmd.exe', '/c node --version', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    if MsgBox('SuperTask requires Node.js and the Claude Code CLI to function.' + #13#10 + #13#10 +
              'Node.js was not detected on this system.' + #13#10 + #13#10 +
              'You can install Node.js from https://nodejs.org' + #13#10 +
              'Then run: npm install -g @anthropic-ai/claude-code' + #13#10 + #13#10 +
              'Continue with installation anyway?',
              mbConfirmation, MB_YESNO) = IDNO then
    begin
      Result := False;
    end;
  end
  else if ResultCode <> 0 then
  begin
    if MsgBox('SuperTask requires Node.js and the Claude Code CLI to function.' + #13#10 + #13#10 +
              'Node.js was not detected on this system.' + #13#10 + #13#10 +
              'You can install Node.js from https://nodejs.org' + #13#10 +
              'Then run: npm install -g @anthropic-ai/claude-code' + #13#10 + #13#10 +
              'Continue with installation anyway?',
              mbConfirmation, MB_YESNO) = IDNO then
    begin
      Result := False;
    end;
  end;
end;
