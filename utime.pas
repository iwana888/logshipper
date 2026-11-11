unit utime;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, DateUtils;

{ Convert current wall-clock time to Unix nanoseconds (used as read-time fallback). }
function NowNs: Int64;

{ Try to parse a log-line timestamp from the BEGINNING of the line using the
  configured format list. Supported formats:
    - literal 'unix_s'  : leading Unix seconds
    - literal 'unix_ms' : leading Unix milliseconds
    - strptime-style    : e.g. '%Y-%m-%d %H:%M:%S'
  When AssumeUTC is False (default) a parsed wall-clock time is treated as LOCAL
  time and converted to UTC; set AssumeUTC=True only if the logs carry UTC with
  no zone. Returns True and tsNs (nanoseconds) on success, False otherwise. }
function ParseLogTimestamp(const line: string; const fmts: TStringList; out tsNs: Int64;
  AssumeUTC: Boolean = False): Boolean;

implementation

function NowNs: Int64;
begin
  { Now() is local time; convert local -> UTC. }
  Result := DateTimeToUnix(Now, False) * 1000000000;
end;

function LeadingInt(const line: string; out v: Int64): Boolean;
var
  i, code: Integer;
begin
  Result := False;
  i := 1;
  while (i <= Length(line)) and (line[i] in ['0'..'9']) do Inc(i);
  if i > 1 then
  begin
    Val(Copy(line, 1, i - 1), v, code);
    Result := code = 0;
  end;
end;

{ FPC's ScanDateTime uses Pascal date tokens (yyyy-mm-dd hh:nn:ss), not the
  strptime style (%Y-%m-%d %H:%M:%S) used in our config. Translate the common
  strptime directives so user config can stay in the familiar syntax. }
function StrptimeToFPC(const fmt: string): string;
var
  i: Integer;
  c: Char;
begin
  Result := '';
  i := 1;
  while i <= Length(fmt) do
  begin
    if fmt[i] = '%' then
    begin
      Inc(i);
      if i > Length(fmt) then Break;
      c := fmt[i];
      case c of
        'Y': Result := Result + 'yyyy';
        'y': Result := Result + 'yy';
        'm': Result := Result + 'mm';
        'd': Result := Result + 'dd';
        'H': Result := Result + 'hh';
        'M': Result := Result + 'nn';
        'S': Result := Result + 'ss';
        'b': Result := Result + 'mmm';   { abbreviated month name }
        'B': Result := Result + 'mmmm';  { full month name }
        'p': Result := Result + 'am/pm';
        else Result := Result + c;       { unknown directive: pass through }
      end;
    end
    else
      Result := Result + fmt[i];
    Inc(i);
  end;
end;

function TryParseFmt(const fmt, s: string; out dt: TDateTime): Boolean;
var
  i, L, start, foundL: Integer;
  fpcFmt, cand: string;
  tmp: TDateTime;
begin
  { ScanDateTime matches from a start position and ignores trailing text, which
    is handy for real log lines (leading prefix + trailing message). Its numeric
    fields are VARIABLE width, so a short candidate can parse successfully but
    wrongly: with 'yyyymmdd hhnnss' the string '20261104 16591' yields 16:59:01,
    while the real line '20261104 16591800 ...' means 16:59:18. So keep the
    LONGEST successful candidate (trailing text does not change the parsed
    value) instead of returning on the first success. }
  Result := False;
  fpcFmt := StrptimeToFPC(fmt);
  i := 1;
  while i <= Length(s) do
  begin
    if s[i] in ['0'..'9'] then
    begin
      foundL := 0;
      L := 1;
      while (i + L - 1 <= Length(s)) and (L <= 30) do
      begin
        cand := Copy(s, i, L);
        start := 1;
        try
          tmp := ScanDateTime(fpcFmt, cand, start);
          if L >= foundL then
          begin
            foundL := L;
            dt := tmp;
          end;
        except
          on E: Exception do ;
        end;
        Inc(L);
      end;
      if foundL > 0 then
      begin
        Result := True;
        Exit;
      end;
    end;
    Inc(i);
  end;
end;

function YearPlausible(dt: TDateTime): Boolean;
var
  y: Word;
begin
  y := YearOf(dt);
  Result := (y >= 2000) and (y <= 2100);
end;

function ParseLogTimestamp(const line: string; const fmts: TStringList; out tsNs: Int64;
  AssumeUTC: Boolean = False): Boolean;
var
  i: Integer;
  fmt, s: string;
  dt: TDateTime;
  n, secs: Int64;
begin
  Result := False;
  if line = '' then Exit;
  for i := 0 to fmts.Count - 1 do
  begin
    fmt := Trim(fmts[i]);
    if fmt = '' then Continue;
    if fmt = 'unix_s' then
    begin
      if LeadingInt(line, n) then
      begin
        secs := n;
        { Reject numbers that don't decode to a sane year — they are not real
          timestamps (e.g. an ID/metric at the start of the line). Fall through
          so the line gets the "now" fallback instead of a bogus 1970 date. }
        if YearPlausible(UnixToDateTime(secs)) then
        begin
          tsNs := secs * 1000000000; Result := True; Exit;
        end;
      end;
    end
    else if fmt = 'unix_ms' then
    begin
      if LeadingInt(line, n) then
      begin
        secs := n div 1000;
        if YearPlausible(UnixToDateTime(secs)) then
        begin
          tsNs := n * 1000000; Result := True; Exit;
        end;
      end;
    end
    else
    begin
      s := Copy(line, 1, 64);
      if TryParseFmt(fmt, s, dt) then
      begin
        if YearPlausible(dt) then
        begin
          tsNs := DateTimeToUnix(dt, AssumeUTC) * 1000000000; Result := True; Exit;
        end;
      end;
    end;
  end;
end;

end.
