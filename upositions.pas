unit upositions;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, fpjson, jsonparser, ucommon;

type
  PFilePos = ^TFilePos;
  TFilePos = record
    Path: string;
    Inode: QWord;
    Offset: Int64;
  end;

  { Persists per-file read positions as (path, inode, offset).
    Written atomically via temp-file + rename so a crash mid-write cannot
    corrupt the positions file. }
  TPositions = class
  private
    FList: TList;
    FFile: string;
    FLock: TRTLCriticalSection;
    function ReadAll: string;
  public
    constructor Create(const fname: string);
    destructor Destroy; override;
    function Find(const path: string): PFilePos;
    function GetOrCreate(const path: string; inode: QWord): PFilePos;
    procedure Load;
    procedure Save;
  end;

implementation

function TPositions.ReadAll: string;
var
  fs: TFileStream;
  n: Int64;
begin
  Result := '';
  if not FileExists(FFile) then Exit;
  fs := TFileStream.Create(FFile, fmOpenRead or fmShareDenyNone);
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

constructor TPositions.Create(const fname: string);
begin
  FFile := fname;
  FList := TList.Create;
  InitCriticalSection(FLock);
end;

destructor TPositions.Destroy;
var
  i: Integer;
begin
  for i := 0 to FList.Count - 1 do Dispose(PFilePos(FList[i]));
  FList.Free;
  DoneCriticalSection(FLock);
  inherited;
end;

function TPositions.Find(const path: string): PFilePos;
var
  i: Integer;
  p: PFilePos;
begin
  Result := nil;
  EnterCriticalSection(FLock);
  try
    for i := 0 to FList.Count - 1 do
    begin
      p := PFilePos(FList[i]);
      if p^.Path = path then begin Result := p; Exit; end;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TPositions.GetOrCreate(const path: string; inode: QWord): PFilePos;
begin
  Result := Find(path);
  if Result = nil then
  begin
    EnterCriticalSection(FLock);
    try
      { Re-check under lock: another thread may have inserted it. }
      Result := Find(path);
      if Result = nil then
      begin
        New(Result);
        Result^.Path := path;
        Result^.Inode := inode;
        Result^.Offset := 0;
        FList.Add(Result);
      end;
    finally
      LeaveCriticalSection(FLock);
    end;
  end;
end;

procedure TPositions.Load;
var
  s: string;
  data, jv: TJSONData;
  arr: TJSONArray;
  i: Integer;
  obj: TJSONObject;
  p: PFilePos;

  function GetInt64(o: TJSONObject; const name: string; def: Int64): Int64;
  var
    jv: TJSONData;
  begin
    Result := def;
    jv := o.Find(name);
    if jv <> nil then Result := jv.AsInt64;
  end;

begin
  s := ReadAll;
  if s = '' then Exit;
  EnterCriticalSection(FLock);
  try
  try
    data := GetJSON(s);
  except
    on E: Exception do begin LogWarn('positions file corrupt, ignoring: ' + E.Message); Exit; end;
  end;
  try
    if data is TJSONObject then
    begin
      jv := TJSONObject(data).Find('files');
      if (jv <> nil) and (jv is TJSONArray) then
      begin
        arr := TJSONArray(jv);
        for i := 0 to arr.Count - 1 do
          if arr[i] is TJSONObject then
          begin
            obj := TJSONObject(arr[i]);
            p := New(PFilePos);
            p^.Path := obj.Get('path', '');
            p^.Inode := GetInt64(obj, 'inode', 0);
            p^.Offset := GetInt64(obj, 'offset', 0);
            FList.Add(p);
          end;
      end;
    end;
  finally
    data.Free;
  end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TPositions.Save;
var
  root, obj: TJSONObject;
  arr: TJSONArray;
  i: Integer;
  p: PFilePos;
  s, tmp: string;
  sl: TStringList;
begin
  { Hold the lock for the whole save so concurrent pushes (thread pool) serialize
    their position writes instead of racing on the temp file. }
  EnterCriticalSection(FLock);
  try
    root := TJSONObject.Create;
    arr := TJSONArray.Create;
    root.Add('files', arr);
    for i := 0 to FList.Count - 1 do
    begin
      p := PFilePos(FList[i]);
      obj := TJSONObject.Create;
      obj.Add('path', p^.Path);
      obj.Add('inode', Int64(p^.Inode));
      obj.Add('offset', p^.Offset);
      arr.Add(obj);
    end;
    s := root.AsJSON;
    root.Free;
  except
    on E: Exception do begin LogError('positions build failed: ' + E.Message); LeaveCriticalSection(FLock); Exit; end;
  end;

  try
    ForceDir(FFile);
    tmp := FFile + '.tmp';
    sl := TStringList.Create;
    try
      sl.Text := s;
      sl.SaveToFile(tmp);
    finally
      sl.Free;
    end;
    if FileExists(FFile) then
    begin
      if not RenameFile(tmp, FFile) then
      begin
        DeleteFile(FFile);
        RenameFile(tmp, FFile);
      end;
    end
    else
      RenameFile(tmp, FFile);
  except
    on E: Exception do LogError('positions save failed (disk full?): ' + E.Message);
  end;
  LeaveCriticalSection(FLock);
end;

end.
