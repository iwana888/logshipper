unit uqueue;
{$mode objfpc}{$H+}
interface
uses
  Classes, SysUtils, utail;

{ Bounded, thread-safe queue of parsed log lines. One or more reader threads
  enqueue; a pool of sender threads dequeues and pushes. When full, TryEnqueue
  returns False so the reader can drop the line (backpressure against memory).

  Synchronization uses RTLEvent (a manual-reset style event): every enqueue
  broadcasts (SetEvent) so all idle senders wake, and a waiter resets the event
  after each wait so the pool does not busy-spin when the queue is empty. }
type
  TLogQueue = class
  private
    FLock: TRTLCriticalSection;
    FEvent: PRTLEvent;
    FItems: TList;
    FMaxLines: Integer;
  public
    constructor Create(maxLines: Integer);
    destructor Destroy; override;
    { Enqueue one line; returns False if the queue is at capacity. }
    function TryEnqueue(pl: PLogLine): Boolean;
    { Remove up to maxLines / maxBytes items from the front into batch. }
    procedure DequeueBatch(maxLines: Integer; maxBytes: UInt64; out batch: TList);
    function Count: Integer;
    procedure WaitForData(timeoutMs: Integer);
    procedure Signal;
  end;

implementation

uses ucommon;

constructor TLogQueue.Create(maxLines: Integer);
begin
  FMaxLines := maxLines;
  FItems := TList.Create;
  InitCriticalSection(FLock);
  FEvent := RTLEventCreate;
end;

destructor TLogQueue.Destroy;
var
  i: Integer;
begin
  for i := 0 to FItems.Count - 1 do Dispose(PLogLine(FItems[i]));
  FItems.Free;
  DoneCriticalSection(FLock);
  RTLEventDestroy(FEvent);
  inherited Destroy;
end;

function TLogQueue.TryEnqueue(pl: PLogLine): Boolean;
begin
  EnterCriticalSection(FLock);
  try
    if FItems.Count >= FMaxLines then Exit(False);
    FItems.Add(pl);
    Result := True;
  finally
    LeaveCriticalSection(FLock);
  end;
  RTLEventSetEvent(FEvent);
end;

procedure TLogQueue.DequeueBatch(maxLines: Integer; maxBytes: UInt64; out batch: TList);
var
  i, moveCount: Integer;
  b: UInt64;
  pl: PLogLine;
begin
  batch := TList.Create;
  EnterCriticalSection(FLock);
  try
    i := 0;
    b := 0;
    while (i < FItems.Count) and (i < maxLines) and (b < maxBytes) do
    begin
      pl := PLogLine(FItems[i]);
      Inc(b, UInt64(Length(pl^.Text) + 1));
      Inc(i);
    end;
    moveCount := i;
    while moveCount > 0 do
    begin
      batch.Add(FItems[0]);
      FItems.Delete(0);
      Dec(moveCount);
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TLogQueue.Count: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Result := FItems.Count;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TLogQueue.WaitForData(timeoutMs: Integer);
begin
  { Wait for a broadcast, then clear it so the next idle wait actually blocks
    (prevents busy-spin when the queue is empty). }
  RTLEventWaitFor(FEvent, timeoutMs);
  RTLEventResetEvent(FEvent);
end;

procedure TLogQueue.Signal;
begin
  RTLEventSetEvent(FEvent);
end;

end.
