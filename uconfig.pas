unit uconfig;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, IniFiles;

type
  TConfig = record
    { [loki] }
    LokiURL: string;
    LokiToken: string;
    Gzip: Boolean;
    TimeoutMS: Integer;
    { [agent] }
    Job: string;
    Instance: string;
    PollIntervalMS: Integer;
    SenderThreads: Integer;
    BatchMaxLines: Integer;
    BatchMaxBytes: Integer;
    BatchMaxDelayMS: Integer;
    BufferMaxLines: Integer;
    { [agent] operational log file (own status, mirrored to stderr) }
    LogFile: string;
    LogFileMaxBytes: Int64;
    LogFileMaxFiles: Integer;
    LogFileLevel: string;   { error (default) | warn | info — file only }
    { [files] }
    Paths: TStringList;
    Instances: TStringList;  { optional per-path instance; 1:1 with Paths }
    PositionsFile: string;
    MaxLineBytes: Integer;
    { [timestamp] }
    TimeFormats: TStringList;
    LevelRegex: string;
    TimeZone: string;   { 'local' (default) or 'utc' }
    TimeMaxAgeHours: Integer;  { lines older than this (or >1h future) are reset to now }
    HttpListen: string;        { built-in viewer / Loki proxy; '' disables it }
  end;

function LoadConfig(const fname: string): TConfig;
procedure FreeConfig(var c: TConfig);

implementation

procedure SplitSemi(const s: string; list: TStringList);
var
  i, start: Integer;
  cur: string;
begin
  list.Clear;
  i := 1;
  start := 1;
  while i <= Length(s) do
  begin
    if s[i] = ';' then
    begin
      cur := Trim(Copy(s, start, i - start));
      if cur <> '' then list.Add(cur);
      start := i + 1;
    end;
    Inc(i);
  end;
  cur := Trim(Copy(s, start, Length(s) - start + 1));
  if cur <> '' then list.Add(cur);
end;

function LoadConfig(const fname: string): TConfig;
var
  ini: TIniFile;
  s: string;
begin
  ini := TIniFile.Create(fname);
  try
    Result.Paths := TStringList.Create;
    Result.Instances := TStringList.Create;
    Result.TimeFormats := TStringList.Create;

    Result.LokiURL := ini.ReadString('loki', 'url', 'http://localhost:3100/loki/api/v1/push');
    Result.LokiToken := ini.ReadString('loki', 'token', '');
    Result.Gzip := ini.ReadBool('loki', 'gzip', True);
    Result.TimeoutMS := ini.ReadInteger('loki', 'timeout_ms', 5000);

    Result.Job := ini.ReadString('agent', 'job', 'myapp');
    Result.Instance := ini.ReadString('agent', 'instance', 'app-1');
    Result.PollIntervalMS := ini.ReadInteger('agent', 'poll_interval_ms', 200);
    Result.SenderThreads := ini.ReadInteger('agent', 'sender_threads', 2);
    if Result.SenderThreads < 1 then Result.SenderThreads := 1;
    if Result.SenderThreads > 16 then Result.SenderThreads := 16;
    Result.BatchMaxLines := ini.ReadInteger('agent', 'batch_max_lines', 100);
    Result.BatchMaxBytes := ini.ReadInteger('agent', 'batch_max_bytes', 262144);
    Result.BatchMaxDelayMS := ini.ReadInteger('agent', 'batch_max_delay_ms', 2000);
    Result.BufferMaxLines := ini.ReadInteger('agent', 'buffer_max_lines', 10000);

    Result.LogFile := ini.ReadString('agent', 'log_file', '');
    Result.LogFileMaxBytes := ini.ReadInteger('agent', 'log_file_max_bytes', 10 * 1024 * 1024);
    Result.LogFileMaxFiles := ini.ReadInteger('agent', 'log_file_max_files', 5);
    Result.LogFileLevel := ini.ReadString('agent', 'log_file_level', 'error');
    if Result.LogFileMaxBytes < 0 then Result.LogFileMaxBytes := 0;
    if Result.LogFileMaxFiles < 1 then Result.LogFileMaxFiles := 1;

    SplitSemi(ini.ReadString('files', 'paths', ''), Result.Paths);
    SplitSemi(ini.ReadString('files', 'instances', ''), Result.Instances);
    { Omitted => one [agent].instance for every path. A non-empty list must be
      1:1 with paths; logshipper.lpr refuses to start if the counts differ. }
    if Result.Instances.Count = 0 then
      while Result.Instances.Count < Result.Paths.Count do
        Result.Instances.Add(Result.Instance);
    Result.PositionsFile := ini.ReadString('files', 'positions_file', 'positions.json');
    Result.MaxLineBytes := ini.ReadInteger('files', 'max_line_bytes', 262144);

    s := ini.ReadString('timestamp', 'formats', '%Y-%m-%d %H:%M:%S;unix_ms');
    SplitSemi(s, Result.TimeFormats);
    Result.LevelRegex := ini.ReadString('timestamp', 'level_regex', '\[(INFO|WARN|ERROR|DEBUG)\]');
    Result.TimeZone := LowerCase(ini.ReadString('timestamp', 'tz', 'local'));
    Result.TimeMaxAgeHours := ini.ReadInteger('timestamp', 'max_age_hours', 168);
    if Result.TimeMaxAgeHours < 0 then Result.TimeMaxAgeHours := 0;

    Result.HttpListen := ini.ReadString('http', 'listen', '127.0.0.1:8099');
  finally
    ini.Free;
  end;
end;

procedure FreeConfig(var c: TConfig);
begin
  c.Paths.Free;
  c.Instances.Free;
  c.TimeFormats.Free;
end;

end.
