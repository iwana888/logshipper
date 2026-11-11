unit ucommon;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes;

{ Simple structured logging to stderr (collected by systemd / redirected to file). }
procedure Log(const lvl, msg: string);
procedure LogInfo(const msg: string);
procedure LogWarn(const msg: string);
procedure LogError(const msg: string);
{ Persist operational logs to a file (in addition to stderr). Pass path='' to disable.
  level = 'error' (default, file gets only ERROR) | 'warn' | 'info' (all).
  The console/stderr always keeps every line regardless of this setting. }
procedure InitFileLogger(const path: string; maxBytes, maxFiles: Int64; const level: string);
procedure CloseFileLogger;

{ Read an entire file into a string (binary-safe). Returns '' if missing. }
function ReadFileToStringSafe(const fn: string): string;

{ Ensure the directory containing fn exists. }
function ForceDir(const fn: string): Boolean;

implementation

var
  LogLock: TRTLCriticalSection;
  GLogFile: TFileStream = nil;
  GLogFileActive: Boolean = False;
  GLogFilePath: string = '';
  GLogFileMaxBytes: Int64 = 0;
  GLogFileMaxFiles: Int64 = 0;
  GLogFileMinLevel: Integer = 2;   { 0=info 1=warn 2=error; default error-only }

procedure RotateLogFile; forward;

{ Numeric severity of a log line. Unknown levels are treated as INFO. }
function LevelNum(const lvl: string): Integer;
begin
  if lvl = 'ERROR' then Result := 2
  else if lvl = 'WARN' then Result := 1
  else Result := 0;
end;

{ Map the config string to a threshold; anything unrecognised falls back to
  'error' so the file stays quiet by default. }
function ParseLevelThreshold(const level: string): Integer;
var
  s: string;
begin
  s := LowerCase(Trim(level));
  if s = 'info' then Result := 0
  else if s = 'warn' then Result := 1
  else Result := 2;
end;

procedure Log(const lvl, msg: string);
var
  s, errs: string;
begin
  s := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + ' [' + lvl + '] ' + msg + #10;
  EnterCriticalSection(LogLock);
  try
    { Single atomic write per line so concurrent threads never interleave.
      The console is always full; only the file is level-filtered. }
    FileWrite(StdErrorHandle, s[1], Length(s));
    if GLogFileActive and Assigned(GLogFile) and (LevelNum(lvl) >= GLogFileMinLevel) then
    begin
      try
        GLogFile.WriteBuffer(s[1], Length(s));
        if (GLogFileMaxBytes > 0) and (GLogFile.Size >= GLogFileMaxBytes) then
          RotateLogFile;
      except
        on E: Exception do
        begin
          { Avoid recursion: write straight to stderr, do not call Log(). }
          GLogFileActive := False;
          errs := '[ERROR] log file write failed, disabling file log: ' + E.Message + #10;
          FileWrite(StdErrorHandle, errs[1], Length(errs));
        end;
      end;
    end;
  finally
    LeaveCriticalSection(LogLock);
  end;
end;

procedure RotateLogFile;
var
  i: Integer;
  src, dst, errs: string;
begin
  FreeAndNil(GLogFile);
  for i := GLogFileMaxFiles - 1 downto 1 do
  begin
    src := GLogFilePath + '.' + IntToStr(i);
    dst := GLogFilePath + '.' + IntToStr(i + 1);
    if FileExists(src) then RenameFile(src, dst);
  end;
  if FileExists(GLogFilePath) then RenameFile(GLogFilePath, GLogFilePath + '.1');
  try
    GLogFile := TFileStream.Create(GLogFilePath, fmCreate or fmShareDenyNone);
  except
    on E: Exception do
    begin
      GLogFileActive := False;
      errs := '[ERROR] log rotation failed: ' + E.Message + #10;
      FileWrite(StdErrorHandle, errs[1], Length(errs));
    end;
  end;
end;

procedure InitFileLogger(const path: string; maxBytes, maxFiles: Int64; const level: string);
begin
  GLogFileMinLevel := ParseLevelThreshold(level);
  if path = '' then Exit;
  if not ForceDir(path) then
  begin
    LogWarn('log file directory unavailable: ' + path);
    Exit;
  end;
  GLogFilePath := path;
  GLogFileMaxBytes := maxBytes;
  GLogFileMaxFiles := maxFiles;
  try
    if FileExists(path) then
      GLogFile := TFileStream.Create(path, fmOpenReadWrite or fmShareDenyNone)
    else
      GLogFile := TFileStream.Create(path, fmCreate or fmShareDenyNone);
    GLogFile.Seek(0, soEnd);
    GLogFileActive := True;
  except
    on E: Exception do
    begin
      LogWarn('cannot open log file: ' + E.Message);
      GLogFile := nil;
    end;
  end;
end;

procedure CloseFileLogger;
begin
  EnterCriticalSection(LogLock);
  try
    if Assigned(GLogFile) then
    begin
      GLogFile.Free;
      GLogFile := nil;
    end;
    GLogFileActive := False;
  finally
    LeaveCriticalSection(LogLock);
  end;
end;

procedure LogInfo(const msg: string); begin Log('INFO', msg); end;
procedure LogWarn(const msg: string); begin Log('WARN', msg); end;
procedure LogError(const msg: string); begin Log('ERROR', msg); end;

function ReadFileToStringSafe(const fn: string): string;
var
  fs: TFileStream;
  n: Int64;
begin
  Result := '';
  if not FileExists(fn) then Exit;
  fs := TFileStream.Create(fn, fmOpenRead or fmShareDenyNone);
  try
    n := fs.Size;
    if n > 0 then
    begin
      SetLength(Result, n);
      fs.ReadBuffer(Result[1], n);
    end;
  finally
    fs.Free;
  end;
end;

function ForceDir(const fn: string): Boolean;
var
  d: string;
begin
  d := ExtractFilePath(fn);
  if d = '' then Exit(True);
  Result := ForceDirectories(d);
end;

initialization
  InitCriticalSection(LogLock);
finalization
  DoneCriticalSection(LogLock);
end.
