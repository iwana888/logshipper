program logshipper;
{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cmem, cthreads, {$ENDIF}
  SysUtils, Classes,
  {$IFDEF UNIX} BaseUnix, ctypes, {$ENDIF}
  {$IFDEF WINDOWS} Windows, {$ENDIF}
  utime, uconfig, upositions, utail,
  uloki, ubuild, ulevel, ucommon,
  uqueue, usender, ureader, uhttp,
  RegExpr;

var
  Terminated: Boolean = False;

{$IFDEF UNIX}
procedure SigHandler(sig: cint); cdecl;
begin
  Terminated := True;
end;
{$ENDIF}

{$IFDEF WINDOWS}
function CtrlHandler(dwCtrlType: DWORD): WINBOOL; stdcall;
begin
  if (dwCtrlType = CTRL_C_EVENT) or (dwCtrlType = CTRL_CLOSE_EVENT) or
     (dwCtrlType = CTRL_BREAK_EVENT) or (dwCtrlType = CTRL_SHUTDOWN_EVENT) then
  begin
    Terminated := True;
    Result := True;
  end
  else
    Result := False;
end;
{$ENDIF}

var
  Config: TConfig;
  Positions: TPositions;
  Tailer: TTailer;
  Queue: TLogQueue;
  Reader: TReaderThread;
  Pool: TSenderPool;
  Re: TRegExpr;
  ConfigFile: string;
  i: Integer;
  Viewer: TLokiViewer;
begin
  ConfigFile := 'logshipper.ini';
  if ParamCount >= 1 then ConfigFile := ParamStr(1);
  if not FileExists(ConfigFile) then
  begin
    LogError('config not found: ' + ConfigFile);
    Halt(1);
  end;

  Config := LoadConfig(ConfigFile);
  InitFileLogger(Config.LogFile, Config.LogFileMaxBytes, Config.LogFileMaxFiles, Config.LogFileLevel);
  if Config.Paths.Count = 0 then
  begin
    LogError('no [files].paths configured');
    Halt(1);
  end;
  if Config.Instances.Count <> Config.Paths.Count then
  begin
    LogError('[files].instances must have one entry per [files].paths entry (' +
             IntToStr(Config.Paths.Count) + ' paths, ' +
             IntToStr(Config.Instances.Count) + ' instances)');
    Halt(1);
  end;
  LogInfo('logshipper starting; loki=' + Config.LokiURL + ' job=' + Config.Job +
          ' instance=' + Config.Instance + ' files=' + IntToStr(Config.Paths.Count) +
          ' senders=' + IntToStr(Config.SenderThreads));
  for i := 0 to Config.Paths.Count - 1 do
    LogInfo('target[' + IntToStr(i + 1) + '] ' + Config.Paths[i] +
            ' -> instance=' + Config.Instances[i]);

  { Level regex (optional). Used only by the reader thread. }
  Re := nil;
  if Config.LevelRegex <> '' then
  begin
    Re := TRegExpr.Create;
    try
      Re.Expression := Config.LevelRegex;
    except
      on E: Exception do begin LogWarn('invalid level_regex, disabled: ' + E.Message); FreeAndNil(Re); end;
    end;
  end;

  ForceDir(Config.PositionsFile);
  Positions := TPositions.Create(Config.PositionsFile);
  Positions.Load;

  Tailer := TTailer.Create(Config.Paths, Config.Instances, Config.MaxLineBytes, Positions, Config.LogFile);
  Queue := TLogQueue.Create(Config.BufferMaxLines);

  { Reader runs in its own thread; the sender pool runs in N threads. The main
    thread below is only a scheduler that waits for them to finish. }
  Reader := TReaderThread.Create(Config, Queue, Tailer, Re, @Terminated);
  Pool := TSenderPool.Create(Config, Queue, Positions, Tailer, @Terminated, Config.SenderThreads);

  {$IFDEF UNIX}
  fpSignal(SIGINT, @SigHandler);
  fpSignal(SIGTERM, @SigHandler);
  {$ENDIF}
  {$IFDEF WINDOWS}
  SetConsoleCtrlHandler(@CtrlHandler, True);
  {$ENDIF}

  if Config.HttpListen <> '' then
  begin
    Viewer := TLokiViewer.Create(Config.LokiURL, Config.HttpListen);
    try
      Viewer.Start;
      LogInfo('http viewer listening on ' + Config.HttpListen);
    except
      on E: Exception do
      begin
        LogWarn('http viewer failed to start (' + Config.HttpListen + '): ' + E.Message);
        FreeAndNil(Viewer);
      end;
    end;
  end;

  LogInfo('started');
  { Wait for the reader to stop (signal sets Terminated), then stop + drain the
    sender pool. The main thread does nothing else. }
  Reader.WaitFor;
  Pool.Stop;
  Pool.WaitForAll;

  LogInfo('shutting down');
  if Assigned(Viewer) then
  begin
    Viewer.Stop;
    Viewer.Free;
  end;
  Reader.Free;
  Pool.Free;
  Re.Free;
  Queue.Free;
  Tailer.Free;
  Positions.Free;
  FreeConfig(Config);
  LogInfo('exit');
  CloseFileLogger;
end.
