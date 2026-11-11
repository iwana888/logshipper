unit utail;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, StrUtils, upositions, ucommon
  {$IFDEF UNIX}, BaseUnix{$ENDIF}
  {$IFDEF WINDOWS}, Windows{$ENDIF};

type
  PLogLine = ^TLogLine;
  TLogLine = record
    Text: string;     { raw line content (already truncated if needed) }
    TsNs: Int64;      { resolved timestamp in nanoseconds (0 = use read-time at parse) }
    Level: string;    { parsed level label, '' if none }
    Instance: string; { Loki instance label, from the owning path's config }
    FilePath: string; { source file (for debugging) }
  end;

  TTailFile = class
  public
    Path: string;
    Inode: QWord;
    Offset: Int64;
    f: TFileStream;
    Opened: Boolean;
    Leftover: string;
    LastOpenWarn: QWord;
    constructor Create(const aPath: string);
    destructor Destroy; override;
    { Open read-only with FULL sharing (fmShareDenyNone). Log files are usually
      held open by a writer; on Windows, Reset()/fmShareDenyWrite is refused with
      "Access denied" when the writer still has the file open. Returns False and
      leaves Opened=False on failure so the reader can retry next poll instead of
      dying on an uncaught exception. }
    function OpenAt(o: Int64): Boolean;
    procedure Release;
    procedure SeekTo(o: Int64);
  end;

  TTailer = class
  private
    FPaths: TStringList;
    FInstances: TStringList;  { 1:1 with FPaths; Loki instance per pattern }
    FMaxLine: Integer;
    FPos: TPositions;
    FFiles: TStringList;  { path -> TTailFile }
    FLock: TRTLCriticalSection;
    FExclude: string;      { agent's own log file must never be tailed }
    FLastPath: string;     { round-robin cursor: resume after this file next poll }
    FWarnTicks: array of QWord;  { per-pattern throttle for "no match" warnings }
    function GetFile(const path: string): TTailFile;
    function StatFile(const path: string; out size: Int64; out inode: QWord): Boolean;
    procedure WarnNoMatch(idx: Integer; const pattern, detail: string);
    procedure ReadSome(tf: TTailFile; outLines: TList; maxLines: Integer;
      const curInstance: string);
    procedure EnsureOpened(tf: TTailFile; curSize: Int64; curInode: QWord;
      statOk: Boolean; outLines: TList; maxLines: Integer; const curInstance: string);
  public
    constructor Create(const paths, instances: TStringList; maxLine: Integer;
      pos: TPositions; const exclude: string = '');
    destructor Destroy; override;
    { Discover files by glob and read available complete lines into outLines.
      Every file gets a fair per-poll slice of the budget and the scan resumes
      after the last file visited, so one busy directory cannot starve the
      others. Total output still stays within maxLines (backpressure). }
    procedure Poll(outLines: TList; maxLines: Integer);
    { Copy current per-file offsets/inodes into the positions store. }
    procedure SyncPositions(pos: TPositions);
  end;

{ Free a list of PLogLine (used by both the reader and the sender thread). }
procedure FreeBuffer(b: TList);

implementation

procedure FreeBuffer(b: TList);
var
  i: Integer;
begin
  for i := 0 to b.Count - 1 do
    if Assigned(b[i]) then Dispose(PLogLine(b[i]));
  b.Clear;
end;

{ TTailFile }

constructor TTailFile.Create(const aPath: string);
begin
  Path := aPath;
  Inode := 0;
  Offset := 0;
  f := nil;
  Opened := False;
  Leftover := '';
  LastOpenWarn := 0;
end;

destructor TTailFile.Destroy;
begin
  Release;
  inherited Destroy;
end;

function TTailFile.OpenAt(o: Int64): Boolean;
begin
  Result := False;
  Release;
  try
    { fmShareDenyNone is essential on Windows: the writer holds the log open,
      and any deny-write/exclusive share mode fails with "Access denied". }
    f := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    if o > f.Size then o := f.Size;
    if o < 0 then o := 0;
    f.Position := o;
    Offset := o;
    Opened := True;
    Result := True;
  except
    on E: Exception do
    begin
      FreeAndNil(f);
      Opened := False;
      { Throttle to one warning / 10s, otherwise a locked/missing file floods
        the console at every 200ms poll. }
      if GetTickCount64 - LastOpenWarn > 10000 then
      begin
        LogWarn('cannot open ' + Path + ': ' + E.Message + ' (will retry)');
        LastOpenWarn := GetTickCount64;
      end;
    end;
  end;
end;

procedure TTailFile.Release;
begin
  FreeAndNil(f);
  Opened := False;
  Leftover := '';
end;

procedure TTailFile.SeekTo(o: Int64);
begin
  if Opened and Assigned(f) then f.Position := o;
  Offset := o;
  Leftover := '';  { bytes buffered from the old position are no longer valid }
end;

{ TTailer }

function TTailer.GetFile(const path: string): TTailFile;
var
  idx: Integer;
  p: PFilePos;
begin
  idx := FFiles.IndexOf(path);
  if idx >= 0 then Exit(TTailFile(FFiles.Objects[idx]));
  Result := TTailFile.Create(path);
  if Assigned(FPos) then
  begin
    p := FPos.Find(path);
    if Assigned(p) then
    begin
      Result.Inode := p^.Inode;
      Result.Offset := p^.Offset;
    end;
  end;
  FFiles.AddObject(path, Result);
end;

{ A glob that matches nothing (missing directory, instance not deployed yet,
  typo) is easy to miss. Warn at most once per 30s per pattern. }
procedure TTailer.WarnNoMatch(idx: Integer; const pattern, detail: string);
var
  tick: QWord;
  msg: string;
begin
  if (idx < 0) or (idx >= Length(FWarnTicks)) then Exit;
  tick := GetTickCount64;
  if (FWarnTicks[idx] <> 0) and (tick - FWarnTicks[idx] < 30000) then Exit;
  FWarnTicks[idx] := tick;
  msg := 'no files match "' + pattern + '"';
  if detail <> '' then
    msg := msg + ' (' + detail + ')'
  else if (ExtractFilePath(pattern) <> '') and
          (not DirectoryExists(ExtractFilePath(pattern))) then
    msg := msg + ' (directory does not exist)';
  LogWarn(msg + '; will keep retrying');
end;

constructor TTailer.Create(const paths, instances: TStringList; maxLine: Integer; pos: TPositions; const exclude: string);
var
  i: Integer;
begin
  FPaths := paths;
  FInstances := instances;
  FMaxLine := maxLine;
  FPos := pos;
  FFiles := TStringList.Create;
  InitCriticalSection(FLock);
  FExclude := '';
  if exclude <> '' then FExclude := ExpandFileName(exclude);
  FLastPath := '';
  SetLength(FWarnTicks, FPaths.Count);
  for i := 0 to High(FWarnTicks) do FWarnTicks[i] := 0;
end;

destructor TTailer.Destroy;
var
  i: Integer;
begin
  for i := 0 to FFiles.Count - 1 do
    TTailFile(FFiles.Objects[i]).Free;
  FFiles.Free;
  DoneCriticalSection(FLock);
  inherited;
end;

{$IFDEF UNIX}
function TTailer.StatFile(const path: string; out size: Int64; out inode: QWord): Boolean;
var
  st: TStat;
begin
  Result := fpStat(path, st) = 0;
  if Result then
  begin
    size := st.st_size;
    inode := st.st_ino;
  end;
end;
{$ENDIF}

{$IFDEF WINDOWS}
function TTailer.StatFile(const path: string; out size: Int64; out inode: QWord): Boolean;
var
  h: THandle;
  info: BY_HANDLE_FILE_INFORMATION;
begin
  Result := False;
  h := CreateFile(PChar(path), 0,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
    nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if h = INVALID_HANDLE_VALUE then Exit;
  try
    if GetFileInformationByHandle(h, info) then
    begin
      size := (Int64(info.nFileSizeHigh) shl 32) or Int64(info.nFileSizeLow);
      inode := (Int64(info.nFileIndexHigh) shl 32) or Int64(info.nFileIndexLow);
      Result := True;
    end;
  finally
    CloseHandle(h);
  end;
end;
{$ENDIF}

{ maxLines is an ABSOLUTE outLines.Count ceiling for this file, not a number
  of lines to append: Poll hands every file its own slice of the poll budget. }
procedure TTailer.ReadSome(tf: TTailFile; outLines: TList; maxLines: Integer;
  const curInstance: string);
var
  buf: array[0..65535] of Byte;
  rd, start, nlPos: Integer;
  acc, line: string;
  pl: PLogLine;

  procedure EmitLine(const s: string);
  begin
    New(pl);
    pl^.Text := s;
    pl^.FilePath := tf.Path;
    pl^.TsNs := 0;
    pl^.Level := '';
    pl^.Instance := curInstance;
    outLines.Add(pl);
  end;

  { Parse all complete lines currently in acc. Every byte removed from acc is
    added to tf.Offset, so (Offset + Length(acc)) always equals the stream
    position. This invariant is what makes resuming safe. }
  procedure DrainLines;
  begin
    start := 1;
    while outLines.Count < maxLines do
    begin
      nlPos := PosEx(#10, acc, start);
      if nlPos = 0 then Break;
      line := Copy(acc, start, nlPos - start);
      if (Length(line) > 0) and (line[Length(line)] = #13) then
        line := Copy(line, 1, Length(line) - 1);
      if Length(line) > FMaxLine then
      begin
        line := Copy(line, 1, FMaxLine) + '...[truncated]';
        LogWarn('line truncated (> ' + IntToStr(FMaxLine) + ' bytes) in ' + tf.Path);
      end;
      EmitLine(line);
      tf.Offset := tf.Offset + (nlPos - start + 1);
      start := nlPos + 1;
    end;
    acc := Copy(acc, start);
  end;

begin
  if (outLines.Count >= maxLines) or (not tf.Opened) or (tf.f = nil) then Exit;
  acc := tf.Leftover;
  { Leftover bytes were already read from the stream but are NOT yet counted in
    Offset. Resume AFTER them. Rewinding to Offset reads them twice, which
    double-counts Offset, makes it exceed the file size, fires 'truncate
    detected' (SeekTo(0)) and re-pushes the whole file. }
  if tf.Offset + Length(acc) > tf.f.Size then
  begin
    { File shrank under us; drop stale buffered bytes and let EnsureOpened's
      truncate detection take over on the next poll. }
    acc := '';
    tf.f.Position := tf.Offset;
  end
  else
    tf.f.Position := tf.Offset + Length(acc);

  while outLines.Count < maxLines do
  begin
    { Drain buffered lines FIRST: when maxLines stops us mid-chunk the rest of
      the chunk stays in Leftover, and it must be emitted even if no new bytes
      arrive (otherwise those lines stall forever). }
    DrainLines;
    if outLines.Count >= maxLines then Break;

    { Defensive: a single line with no newline that keeps growing would make
      acc grow without bound. Emit it truncated and mark ALL accumulated bytes
      as consumed. }
    if (Length(acc) > FMaxLine) and (Pos(#10, acc) = 0) then
    begin
      EmitLine(Copy(acc, 1, FMaxLine) + '...[truncated]');
      tf.Offset := tf.Offset + Length(acc);
      acc := '';
      LogWarn('oversized line (no newline) truncated in ' + tf.Path);
      if outLines.Count >= maxLines then Break;
    end;

    rd := tf.f.Read(buf, SizeOf(buf));
    if rd <= 0 then Break;
    SetLength(line, rd);
    if rd > 0 then Move(buf[0], line[1], rd);
    acc := acc + line;
  end;
  tf.Leftover := acc;
end;

procedure TTailer.EnsureOpened(tf: TTailFile; curSize: Int64; curInode: QWord;
  statOk: Boolean; outLines: TList; maxLines: Integer; const curInstance: string);
begin
  if not statOk then
  begin
    if tf.Opened then
    begin
      ReadSome(tf, outLines, maxLines, curInstance);
      tf.Release;
    end;
    Exit;
  end;

  if not tf.Opened then
  begin
    { First open (startup or after the file was missing). }
    if (tf.Inode <> 0) and (tf.Inode <> curInode) then
    begin
      LogInfo('file rotated while down, restart from 0: ' + tf.Path);
      tf.Offset := 0;
    end
    else if curSize < tf.Offset then
    begin
      LogWarn('file truncated while down, restart from 0: ' + tf.Path);
      tf.Offset := 0;
    end;
    tf.Inode := curInode;
    tf.Leftover := '';
    if not tf.OpenAt(tf.Offset) then Exit;
  end
  else
  begin
    if curInode <> tf.Inode then
    begin
      { Rotation (rename + new file): drain remaining bytes from the OLD fd,
        then open the new file at offset 0. }
      LogInfo('rotation detected (inode changed): ' + tf.Path);
      ReadSome(tf, outLines, maxLines, curInstance);
      tf.Release;
      tf.Inode := curInode;
      tf.Offset := 0;
      tf.Leftover := '';
      tf.OpenAt(0);   { failure is fine: next poll retries the first-open branch }
    end
    else if curSize < tf.Offset then
    begin
      { Truncation (copytruncate): size shrank below our offset. }
      LogWarn('truncate detected (size < offset): ' + tf.Path);
      tf.SeekTo(0);
    end;
  end;
end;

procedure TTailer.Poll(outLines: TList; maxLines: Integer);
var
  p, i, n, idx, startIdx, visited: Integer;
  quota, extra, budget, limit: Integer;
  pattern, full, inst: string;
  sr: TSearchRec;
  files, instances: TStringList;
  tf: TTailFile;
  statOk: Boolean;
  curSize: Int64;
  curInode: QWord;
begin
  if maxLines <= 0 then Exit;
  files := TStringList.Create;
  instances := TStringList.Create;
  EnterCriticalSection(FLock);
  try
    { Phase 1: expand every glob into a de-duplicated (path, instance) list.
      A path matched by more than one pattern is tailed once, owned by the
      first pattern that produced it. }
    for p := 0 to FPaths.Count - 1 do
    begin
      pattern := FPaths[p];
      inst := '';
      if (FInstances <> nil) and (p < FInstances.Count) then
        inst := FInstances[p];
      try
        if FindFirst(pattern, faAnyFile, sr) <> 0 then
        begin
          WarnNoMatch(p, pattern, '');
          Continue;
        end;
      except
        on E: Exception do
        begin
          WarnNoMatch(p, pattern, E.Message);
          Continue;
        end;
      end;
      try
        repeat
          if (sr.Name = '.') or (sr.Name = '..') then Continue;
          if (sr.Attr and faDirectory) <> 0 then Continue;
          full := IncludeTrailingPathDelimiter(ExtractFilePath(pattern)) + sr.Name;
          { Never tail our own status log (would create a feedback loop). }
          if (FExclude <> '') and (ExpandFileName(full) = FExclude) then Continue;
          if files.IndexOf(full) >= 0 then Continue;
          files.Add(full);
          instances.Add(inst);
        until FindNext(sr) <> 0;
      finally
        SysUtils.FindClose(sr);
      end;
    end;

    { Phase 2: round-robin with a reserved per-file slice. maxLines stays the
      hard ceiling (queue backpressure); a busy file can never consume another
      file's slice, and FLastPath moves the starting point on every poll. }
    n := files.Count;
    if n = 0 then Exit;
    budget := maxLines - outLines.Count;
    if budget <= 0 then Exit;
    quota := budget div n;
    if quota < 1 then quota := 1;
    extra := budget - quota * n;

    startIdx := 0;
    if FLastPath <> '' then
    begin
      idx := files.IndexOf(FLastPath);
      if idx >= 0 then startIdx := (idx + 1) mod n;
    end;

    visited := 0;
    while (visited < n) and (outLines.Count < maxLines) do
    begin
      i := (startIdx + visited) mod n;
      full := files[i];
      inst := instances[i];
      FLastPath := full;
      Inc(visited);

      { Absolute outLines.Count ceiling for THIS file: each file may append at
        most its own slice, so idle files cannot be starved by a backfill. }
      limit := outLines.Count + quota;
      if visited <= extra then Inc(limit);
      if limit > maxLines then limit := maxLines;

      tf := nil;
      try
        tf := GetFile(full);
        statOk := StatFile(full, curSize, curInode);
        EnsureOpened(tf, curSize, curInode, statOk, outLines, limit, inst);
        if tf.Opened then ReadSome(tf, outLines, limit, inst);
      except
        on E: Exception do
        begin
          { A per-file failure (locked file, vanished during rotation, I/O
            error) must never kill the reader thread. Log once and retry on
            the next poll. }
          LogWarn('poll error on ' + full + ': ' + E.Message + ' (will retry)');
          if Assigned(tf) then tf.Release;
        end;
      end;
    end;
  finally
    LeaveCriticalSection(FLock);
    instances.Free;
    files.Free;
  end;
end;

procedure TTailer.SyncPositions(pos: TPositions);
var
  i: Integer;
  p: PFilePos;
  tf: TTailFile;
begin
  EnterCriticalSection(FLock);
  try
    for i := 0 to FFiles.Count - 1 do
    begin
      tf := TTailFile(FFiles.Objects[i]);
      p := pos.GetOrCreate(tf.Path, tf.Inode);
      p^.Inode := tf.Inode;
      p^.Offset := tf.Offset;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

end.
