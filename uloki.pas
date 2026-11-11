unit uloki;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, fphttpclient, zstream, zlib, uconfig, ucommon,
  { Registers the SSL socket handler. Without it TFPHTTPClient rejects https://
    URLs with "No SSL Socket support compiled in". openssl lets us point FPC at
    the OpenSSL DLL names actually deployed on this host. }
  opensslsockets, openssl;

type
  TPushResult = (prSuccess, prDrop, prInterrupted);

  { Thin wrapper around fphttpclient for the Loki push endpoint, including
    gzip compression and the retry/backoff policy. }
  TLOKIPusher = class
  private
    FHTTP: TFPHTTPClient;
    FTerm: PBoolean;
    FURL: string;
    FUseGzip: Boolean;
  public
    constructor Create(const cfg: TConfig; term: PBoolean);
    destructor Destroy; override;
    { Single attempt. Returns HTTP status code, or -1 on network/transport error.
      respBody receives the response body (for diagnostics on 4xx). }
    function HTTPPostOnce(const json: string; out respBody: string): Integer;
    { Retries on 429 / 5xx / network errors with exponential backoff (1s..30s).
      Drops permanently on other 4xx. Honors termination via FTerm. }
    function PushBatch(const json: string; out info: string): TPushResult;
  end;

{ Produce a gzip-compressed copy of s (RFC 1952), since FPC's zstream only
  offers a zlib-format stream. We wrap raw DEFLATE (from TCompressionStream,
  header/trailer stripped) with a gzip header + CRC32/ISIZE trailer. }
function GZipString(const s: string): string;
function SleepTerm(ms: Integer; term: PBoolean): Boolean;

implementation

function GZipString(const s: string): string;
var
  cmp: TMemoryStream;
  zs: TCompressionStream;
  rawDeflate: string;
  hdr: array[0..9] of Byte;
  trailer: array[0..7] of Byte;
  crc: LongWord;
  isize: LongWord;
  rawLen: Int64;
begin
  if s = '' then begin Result := ''; Exit; end;
  cmp := TMemoryStream.Create;
  try
    zs := TCompressionStream.Create(clDefault, cmp);
    try
      zs.Write(s[1], Length(s));
    finally
      zs.Free;
    end;
    { cmp holds a zlib stream: [2-byte header][raw deflate][4-byte adler32]. }
    rawLen := cmp.Size - 6;
    if rawLen < 0 then rawLen := 0;
    SetLength(rawDeflate, rawLen);
    if rawLen > 0 then
      Move(PByte(cmp.Memory)[2], rawDeflate[1], rawLen);
  finally
    cmp.Free;
  end;

  hdr[0] := $1f; hdr[1] := $8b; hdr[2] := 8; hdr[3] := 0;
  hdr[4] := 0;  hdr[5] := 0;  hdr[6] := 0; hdr[7] := 0;
  hdr[8] := 0;  hdr[9] := $ff; { OS = unknown }

  crc := crc32(0, pBytef(@s[1]), Length(s));
  isize := LongWord(Length(s) mod 4294967296);

  trailer[0] := crc and $ff;          trailer[1] := (crc shr 8) and $ff;
  trailer[2] := (crc shr 16) and $ff; trailer[3] := (crc shr 24) and $ff;
  trailer[4] := isize and $ff;         trailer[5] := (isize shr 8) and $ff;
  trailer[6] := (isize shr 16) and $ff; trailer[7] := (isize shr 24) and $ff;

  SetLength(Result, 10 + Length(rawDeflate) + 8);
  Move(hdr, Result[1], 10);
  if Length(rawDeflate) > 0 then
    Move(rawDeflate[1], Result[11], Length(rawDeflate));
  Move(trailer, Result[11 + Length(rawDeflate)], 8);
end;

function SleepTerm(ms: Integer; term: PBoolean): Boolean;
var
  elapsed: Integer;
begin
  elapsed := 0;
  while elapsed < ms do
  begin
    if Assigned(term) and term^ then begin Result := True; Exit; end;
    Sleep(100);
    Inc(elapsed, 100);
  end;
  Result := False;
end;

constructor TLOKIPusher.Create(const cfg: TConfig; term: PBoolean);
begin
  FTerm := term;
  FURL := cfg.LokiURL;
  FUseGzip := cfg.Gzip;
  FHTTP := TFPHTTPClient.Create(nil);
  FHTTP.IOTimeout := cfg.TimeoutMS;
  FHTTP.ConnectTimeout := cfg.TimeoutMS;
  FHTTP.AddHeader('Content-Type', 'application/json');
  if FUseGzip then FHTTP.AddHeader('Content-Encoding', 'gzip');
  if cfg.LokiToken <> '' then FHTTP.AddHeader('Authorization', 'Bearer ' + cfg.LokiToken);
end;

destructor TLOKIPusher.Destroy;
begin
  FHTTP.Free;
  inherited;
end;

function TLOKIPusher.HTTPPostOnce(const json: string; out respBody: string): Integer;
var
  req, resp: TMemoryStream;
  gz: string;
begin
  Result := -1;
  respBody := '';
  req := TMemoryStream.Create;
  resp := TMemoryStream.Create;
  try
    if FUseGzip then
    begin
      gz := GZipString(json);
      if gz <> '' then req.WriteBuffer(gz[1], Length(gz))
      else req.WriteBuffer(json[1], Length(json));
    end
    else
      req.WriteBuffer(json[1], Length(json));
    req.Position := 0;
    { fphttpclient sends RequestBody as the request body. }
    FHTTP.RequestBody := req;
    try
      FHTTP.Post(FURL, resp);
      Result := FHTTP.ResponseStatusCode;
      if resp.Size > 0 then
        SetString(respBody, PChar(resp.Memory), resp.Size);
    except
      on E: Exception do
      begin
        LogWarn('HTTP post error: ' + E.Message);
        Result := -1;
      end;
    end;
    FHTTP.RequestBody := nil;
  finally
    req.Free;
    resp.Free;
  end;
end;

function TLOKIPusher.PushBatch(const json: string; out info: string): TPushResult;
var
  backoff, code: Integer;
  body: string;
begin
  backoff := 1000;
  info := '';
  while True do
  begin
    if Assigned(FTerm) and FTerm^ then begin Result := prInterrupted; Exit; end;
    code := HTTPPostOnce(json, body);
    if (code = 200) or (code = 204) then begin Result := prSuccess; Exit; end;
    if (code = -1) or (code = 429) or (code >= 500) then
    begin
      LogWarn('push failed (code=' + IntToStr(code) + '), retry in ' + IntToStr(backoff) + 'ms');
      if SleepTerm(backoff, FTerm) then begin Result := prInterrupted; Exit; end;
      if backoff < 30000 then backoff := backoff * 2;
      if backoff > 30000 then backoff := 30000;
      Continue;
    end;
    { Any other 4xx (400 etc.) is a permanent error: drop the batch so we
      don't stall on a bug/config mistake. offset still advances. }
    info := 'HTTP ' + IntToStr(code) + ' (non-retryable) body=' + body;
    Result := prDrop;
    Exit;
  end;
end;

{$IFDEF WINDOWS}
{ FPC 3.2.2 on Windows only knows OpenSSL 1.0/1.1 DLL names. OpenSSL 3 ships
  as libssl-3.dll / libcrypto-3.dll (MSVC, e.g. Python) or libssl-3-x64.dll /
  libcrypto-3-x64.dll (mingw, e.g. Git). Keep the ORIGINAL names: renaming the
  files breaks the DLL's own import table (libssl-3.dll imports libcrypto-3.dll).
  Point FPC's first-choice names at whichever pair is deployed next to the exe. }
procedure ConfigureWindowsOpenSSL;
const
  Pairs: array[0..2, 0..1] of string = (
    ('libssl-1_1-x64.dll', 'libcrypto-1_1-x64.dll'),
    ('libssl-3.dll',       'libcrypto-3.dll'),
    ('libssl-3-x64.dll',   'libcrypto-3-x64.dll')
  );
var
  dir: string;
  i: Integer;
begin
  dir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  for i := 0 to High(Pairs) do
    if FileExists(dir + Pairs[i, 0]) and FileExists(dir + Pairs[i, 1]) then
    begin
      DLLSSLName := Pairs[i, 0];
      DLLUtilName := Pairs[i, 1];
      Exit;
    end;
  { Nothing found: leave FPC's defaults (1.0/1.1) in place. }
end;
{$ENDIF}

{$IFDEF UNIX}
{ FPC 3.2.2's DLLVersions stops at .so.1.1, so a host with only OpenSSL 3
  (libssl.so.3 / libcrypto.so.3) would fail. Insert '.3' after the unversioned
  name so both 1.1 and 3 are discovered. }
procedure ConfigureUnixOpenSSL;
var
  i: Integer;
begin
  for i := High(DLLVersions) downto 3 do
    DLLVersions[i] := DLLVersions[i - 1];
  DLLVersions[2] := '.3';
end;
{$ENDIF}

initialization
  {$IFDEF WINDOWS} ConfigureWindowsOpenSSL; {$ENDIF}
  {$IFDEF UNIX} ConfigureUnixOpenSSL; {$ENDIF}

end.
