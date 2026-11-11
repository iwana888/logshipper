unit usender;
{$mode objfpc}{$H+}
interface
uses
  Classes, SysUtils, utail, upositions, uloki, ubuild, uconfig, ucommon, uqueue;

{ A single sender worker: drains the queue and pushes to Loki. All blocking
  network I/O and retry/backoff happen here, so the reader thread is never
  blocked by Loki. Each worker owns its own TLOKIPusher (and thus its own
  TFPHTTPClient), because that HTTP client is not safe to share across threads. }
type
  TSenderThread = class(TThread)
  private
    FQueue: TLogQueue;
    FPositions: TPositions;
    FTailer: TTailer;
    FPusher: TLOKIPusher;
    FConfig: TConfig;
    FTerm: PBoolean;
    FOwnsPusher: Boolean;
  public
    constructor Create(cfg: TConfig; q: TLogQueue; pos: TPositions; tail: TTailer;
      push: TLOKIPusher; term: PBoolean; ownPusher: Boolean = True);
    destructor Destroy; override;
    procedure Execute; override;
  end;

{ Pool of sender workers sharing one queue/tailer/positions. Spinning up more
  than one lets multiple batches push to Loki concurrently, raising throughput
  past what a single HTTP connection can sustain. }
  TSenderPool = class
  private
    FThreads: array of TSenderThread;
    FQueue: TLogQueue;
  public
    constructor Create(cfg: TConfig; q: TLogQueue; pos: TPositions; tail: TTailer;
      term: PBoolean; count: Integer);
    destructor Destroy; override;
    procedure Stop;      { wake all workers; they drain then exit on Terminated }
    procedure WaitForAll;
  end;

implementation

constructor TSenderThread.Create(cfg: TConfig; q: TLogQueue; pos: TPositions; tail: TTailer; push: TLOKIPusher; term: PBoolean; ownPusher: Boolean = True);
begin
  FConfig := cfg;
  FQueue := q;
  FPositions := pos;
  FTailer := tail;
  FPusher := push;
  FTerm := term;
  FOwnsPusher := ownPusher;
  inherited Create(False);
end;

destructor TSenderThread.Destroy;
begin
  if FOwnsPusher then FPusher.Free;
  inherited Destroy;
end;

procedure TSenderThread.Execute;
var
  batch: TList;
  json: string;
  res: TPushResult;
  info: string;
  mono: Boolean;
  t0, el: QWord;
begin
  while True do
  begin
    { Stop once termination is requested and nothing is left to send. }
    if FTerm^ and (FQueue.Count = 0) then Break;
    if FQueue.Count = 0 then
    begin
      if FTerm^ then Break;
      FQueue.WaitForData(FConfig.BatchMaxDelayMS);
      if FTerm^ and (FQueue.Count = 0) then Break;
      if FQueue.Count = 0 then Continue;
    end;

    FQueue.DequeueBatch(FConfig.BatchMaxLines, FConfig.BatchMaxBytes, batch);
    if batch.Count = 0 then Continue;

    json := BuildPushBody(batch, FConfig, mono);
    if mono then LogWarn('timestamp monotonic correction applied in batch');
    t0 := GetTickCount64;
    res := FPusher.PushBatch(json, info);
    el := GetTickCount64 - t0;

    if res = prSuccess then
    begin
      LogInfo('pushed ' + IntToStr(batch.Count) + ' lines in ' + IntToStr(el) + ' ms');
      FTailer.SyncPositions(FPositions);
      FPositions.Save;
    end
    else if res = prDrop then
    begin
      LogError('dropping batch (non-retryable): ' + info + '; advancing offset to avoid stall');
      FTailer.SyncPositions(FPositions);
      FPositions.Save;
    end
    else if res = prInterrupted then
    begin
      LogWarn('push interrupted by termination');
      FreeBuffer(batch);
      Break;
    end;
    FreeBuffer(batch);
  end;
end;

constructor TSenderPool.Create(cfg: TConfig; q: TLogQueue; pos: TPositions; tail: TTailer; term: PBoolean; count: Integer);
var
  i: Integer;
  p: TLOKIPusher;
begin
  FQueue := q;
  SetLength(FThreads, count);
  for i := 0 to count - 1 do
  begin
    p := TLOKIPusher.Create(cfg, term);
    FThreads[i] := TSenderThread.Create(cfg, q, pos, tail, p, term, True);
  end;
end;

destructor TSenderPool.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FThreads) do FThreads[i].Free;
  inherited Destroy;
end;

procedure TSenderPool.Stop;
begin
  { Wake every worker so it observes Terminated and drains the remaining queue. }
  FQueue.Signal;
end;

procedure TSenderPool.WaitForAll;
var
  i: Integer;
begin
  for i := 0 to High(FThreads) do
    FThreads[i].WaitFor;
end;

end.
