unit ureader;
{$mode objfpc}{$H+}
interface
uses
  Classes, SysUtils, utail, uconfig, ucommon, uqueue, ulevel, utime, RegExpr;

{ Dedicated reader thread: tails matched files, parses timestamp + level, and
  enqueues into the shared queue. It never touches the network, so a slow or
  unreachable Loki cannot stall file reading. }
type
  TReaderThread = class(TThread)
  private
    FQueue: TLogQueue;
    FTailer: TTailer;
    FConfig: TConfig;
    FRe: TRegExpr;
    FTerm: PBoolean;
  public
    constructor Create(cfg: TConfig; q: TLogQueue; tail: TTailer; re: TRegExpr; term: PBoolean);
    procedure Execute; override;
  end;

implementation

constructor TReaderThread.Create(cfg: TConfig; q: TLogQueue; tail: TTailer; re: TRegExpr; term: PBoolean);
begin
  { Set fields before starting to avoid a race on first Execute. }
  FConfig := cfg;
  FQueue := q;
  FTailer := tail;
  FRe := re;
  FTerm := term;
  inherited Create(False);
end;

procedure TReaderThread.Execute;
var
  rawList: TList;
  k: Integer;
  ts: Int64;
  pl: PLogLine;
begin
  rawList := TList.Create;
  try
    while not FTerm^ do
    begin
      try
        { Backpressure: only read when the in-memory queue is below its cap. The
          file offsets are NOT advanced while we skip, so nothing is lost. }
        if FQueue.Count < FConfig.BufferMaxLines then
          FTailer.Poll(rawList, FConfig.BufferMaxLines - FQueue.Count);
        for k := 0 to rawList.Count - 1 do
        begin
          pl := PLogLine(rawList[k]);
          { Ownership leaves the list here. On an exception FreeBuffer() can
            safely dispose the remaining entries without double-freeing ones
            already handed to the queue. }
          rawList[k] := nil;
          if ParseLogTimestamp(pl^.Text, FConfig.TimeFormats, ts, FConfig.TimeZone = 'utc') then
            pl^.TsNs := ts
          else
            pl^.TsNs := NowNs;
          pl^.Level := ParseLevel(pl^.Text, FRe);
          if not FQueue.TryEnqueue(pl) then
          begin
            LogWarn('queue full (buffer_max_lines=' + IntToStr(FConfig.BufferMaxLines) +
                    '), dropping line to protect memory');
            Dispose(pl);
          end;
        end;
        rawList.Clear;
      except
        on E: Exception do
          LogError('reader loop error, retrying next tick: ' + E.Message);
      end;
      { Outside the try: an exception must not turn the loop into a busy spin. }
      Sleep(FConfig.PollIntervalMS);
    end;
  finally
    FreeBuffer(rawList);
    rawList.Free;
  end;
end;

end.
