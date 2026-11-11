unit uhttp;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, StrUtils, fphttpserver, httpdefs, httpprotocol, fphttpclient,
  opensslsockets, ucommon;

type
  { TFPHTTPServer does not re-publish the 'Address' property, so expose it via a
    thin subclass to bind to 127.0.0.1 instead of all interfaces. }
  TMyHTTPServer = class(TFPHTTPServer)
  published
    property Address;
  end;

  { Built-in, same-origin web viewer + Loki reverse proxy, so the operator does
    not need to run a separate Python service. One background thread serves the
    page and forwards /loki/* to the configured Loki endpoint (reusing the same
    Loki URL already set for pushing). }

  TLokiViewer = class
  private
    FServer: TMyHTTPServer;
    FThread: TThread;
    FLokiURL: string;
    FListen: string;
    FIndexBytes: TBytes;
    procedure HandleRequest(Sender: TObject;
      var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
    procedure SendText(var AResponse: TFPHTTPConnectionResponse;
      const s, ctype: string; code: Integer);
    function LoadIndexFile: TBytes;
  public
    constructor Create(const lokiURL, listen: string);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
  end;

implementation

type
  TServerThread = class(TThread)
  private
    FServer: TMyHTTPServer;
  public
    constructor Create(srv: TMyHTTPServer);
    procedure Execute; override;
  end;

const
  FALLBACK_HTML =
    '<!doctype html><html lang="zh"><head><meta charset="utf-8">' +
    '<title>logshipper viewer</title>' +
    '<style>body{font-family:monospace}h3{margin:.4em 0}' +
    'input{font-family:monospace}#r{white-space:pre-wrap;background:#111;' +
    'color:#0f0;padding:8px;margin-top:8px;max-height:70vh;overflow:auto}' +
    '</style></head><body>' +
    '<h3>logshipper &mdash; Loki query</h3>' +
    '<label>LogQL <input id="q" size="60" value="{job=&quot;myapp&quot;}"></label> ' +
    '<label>limit <input id="lim" value="100" size="5"></label> ' +
    '<button onclick="run()">Query</button> <span id="st"></span>' +
    '<div id="r"></div>' +
    '<script>' +
    'async function run(){' +
    'var q=document.getElementById("q").value,' +
    'lim=document.getElementById("lim").value,' +
    'end=Date.now()+"000000",start=(Date.now()-3600000)+"000000",' +
    'u="/loki/api/v1/query_range?query="+encodeURIComponent(q)+' +
    '"&start="+start+"&end="+end+"&limit="+lim;' +
    'document.getElementById("st").textContent="...";' +
    'try{var r=await fetch(u),j=await r.json();' +
    'document.getElementById("r").textContent=JSON.stringify(j,null,2);' +
    'document.getElementById("st").textContent=r.status;}' +
    'catch(e){document.getElementById("r").textContent="ERR "+e.message;}}' +
    '</script></body></html>';

function SplitHostPort(const s: string; out host: string; out port: Integer): Boolean;
var
  p: Integer;
begin
  Result := False;
  p := LastDelimiter(':', s);
  if (p <= 0) or (p = Length(s)) then Exit;
  host := Copy(s, 1, p - 1);
  port := StrToIntDef(Copy(s, p + 1, MaxInt), 0);
  Result := port > 0;
end;

{ Return only the scheme://host[:port] authority of a URL, dropping any path.
  The configured [loki].url is the full push endpoint (.../loki/api/v1/push);
  for the reverse proxy we forward to the Loki *base* and let the browser
  supply the /loki/api/v1/... path, mirroring web/serve.py (LOKI_BASE). }
function BaseOfURL(const url: string): string;
var
  i, j: Integer;
begin
  Result := url;
  i := Pos('://', Result);
  if i > 0 then
    j := PosEx('/', Result, i + 3)
  else
    j := Pos('/', Result);
  if j > 0 then
    Result := Copy(Result, 1, j - 1);
end;

function EscapeJson(const s: string): string;
begin
  Result := StringReplace(s, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
end;

{ TServerThread }

constructor TServerThread.Create(srv: TMyHTTPServer);
begin
  inherited Create(False);
  FServer := srv;
  FreeOnTerminate := False;
end;

procedure TServerThread.Execute;
begin
  { Active := True enters the accept loop and blocks this thread until the
    server is deactivated from another thread (Stop). }
  try
    FServer.Active := True;
  except
    on E: Exception do LogError('http server loop error: ' + E.Message);
  end;
end;

{ TLokiViewer }

constructor TLokiViewer.Create(const lokiURL, listen: string);
var
  h: string;
  p: Integer;
begin
  FLokiURL := Trim(lokiURL);
  FListen := listen;
  FIndexBytes := LoadIndexFile;
  if not SplitHostPort(listen, h, p) then
    raise Exception.Create('invalid [http].listen: ' + listen);
  FServer := TMyHTTPServer.Create(nil);
  FServer.Address := h;
  FServer.Port := p;
  FServer.OnRequest := @HandleRequest;
end;

destructor TLokiViewer.Destroy;
begin
  if Assigned(FServer) then
  begin
    try FServer.Active := False; except end;
    FServer.Free;
  end;
  inherited Destroy;
end;

procedure TLokiViewer.Start;
begin
  FThread := TServerThread.Create(FServer);
end;

procedure TLokiViewer.Stop;
begin
  try FServer.Active := False; except end;
  if Assigned(FThread) then
  begin
    FThread.WaitFor;
    FThread.Free;
    FThread := nil;
  end;
end;

function TLokiViewer.LoadIndexFile: TBytes;
var
  fn: string;
  fs: TFileStream;
begin
  SetLength(Result, 0);
  fn := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'web' +
        PathDelim + 'index.html';
  if FileExists(fn) then
  begin
    fs := TFileStream.Create(fn, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(Result, fs.Size);
      if fs.Size > 0 then fs.ReadBuffer(Result[0], fs.Size);
    finally
      fs.Free;
    end;
  end;
end;

procedure TLokiViewer.SendText(var AResponse: TFPHTTPConnectionResponse;
  const s, ctype: string; code: Integer);
var
  ms: TStringStream;
begin
  { The server frees ContentStream after the response is sent. }
  ms := TStringStream.Create(s, TEncoding.UTF8);
  AResponse.ContentStream := ms;
  AResponse.ContentType := ctype + '; charset=utf-8';
  AResponse.Code := code;
end;

procedure TLokiViewer.HandleRequest(Sender: TObject;
  var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  uri, path, query: string;
  p: Integer;
  method, rest, target, respBody: string;
  cli: TFPHTTPClient;
  SS, MS: TStream;
  code: Integer;
begin
  uri := ARequest.URI;
  p := Pos('?', uri);
  if p > 0 then
  begin
    path := Copy(uri, 1, p - 1);
    query := Copy(uri, p + 1, MaxInt);
  end
  else
  begin
    path := uri;
    query := '';
  end;
  method := UpperCase(ARequest.Method);

  if (path = '/') or (path = '/index.html') then
  begin
    if Length(FIndexBytes) > 0 then
    begin
      MS := TMemoryStream.Create;
      MS.WriteBuffer(FIndexBytes[0], Length(FIndexBytes));
      MS.Position := 0;
      AResponse.ContentStream := MS;   { server frees it }
      AResponse.ContentType := 'text/html; charset=utf-8';
      AResponse.Code := 200;
    end
    else
      SendText(AResponse, FALLBACK_HTML, 'text/html', 200);
    Exit;
  end;

  if path = '/api/info' then
  begin
    SendText(AResponse, '{"loki":"' + EscapeJson(BaseOfURL(FLokiURL)) + '"}', 'application/json', 200);
    Exit;
  end;

  if Copy(path, 1, 6) = '/loki/' then
  begin
    if FLokiURL = '' then
    begin
      SendText(AResponse, '{"error":"no Loki URL configured"}', 'application/json', 502);
      Exit;
    end;
    rest := Copy(path, 2, MaxInt);          { 'loki/api/v1/...' }
    target := BaseOfURL(FLokiURL);           { scheme://host[:port] }
    if target[Length(target)] <> '/' then target := target + '/';
    target := target + rest;
    if query <> '' then target := target + '?' + query;

    cli := TFPHTTPClient.Create(nil);
    try
      cli.IOTimeout := 30000;
      cli.ConnectTimeout := 30000;
      MS := TMemoryStream.Create;
      SS := nil;
      try
        try
          { HTTPMethod with [] accepts ANY status code (empty allowed set), so a
            non-200 from Loki (400/404/422/...) is forwarded as-is instead of
            being raised as "Loki unreachable". Only real transport failures
            (connection refused, timeout) hit the except block below. }
          if method = 'POST' then
          begin
            SS := TStringStream.Create(ARequest.Content, TEncoding.UTF8);
            cli.RequestBody := SS;
            cli.HTTPMethod('POST', target, MS, []);
          end
          else
            cli.HTTPMethod('GET', target, MS, []);
          code := cli.ResponseStatusCode;
          if code <= 0 then code := 502;   { unset on some FPC builds }
          MS.Position := 0;
          AResponse.ContentStream := MS;  { server frees it }
          if cli.ResponseHeaders.Values['content-type'] <> '' then
            AResponse.ContentType := cli.ResponseHeaders.Values['content-type']
          else
            AResponse.ContentType := 'application/json';
          AResponse.Code := code;
        except
          on E: Exception do
          begin
            MS.Free;
            respBody := '{"error":"Loki unreachable: ' + EscapeJson(E.Message) + '"}';
            SendText(AResponse, respBody, 'application/json', 502);
          end;
        end;
      finally
        SS.Free;   { nil-safe; RequestBody only references it }
      end;
    finally
      cli.Free;
    end;
    Exit;
  end;

  SendText(AResponse, '{"error":"not found"}', 'application/json', 404);
end;

end.
