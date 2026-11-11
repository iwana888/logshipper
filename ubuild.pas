unit ubuild;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, fpjson, utail, uconfig, utime, ucommon;

{ Build the Loki push body (JSON) from a batch of log lines.
  Lines are grouped by stream labels (job, instance, level); a different
  instance or level produces its own stream object, so lines from several app
  instances never share a stream (or a monotonic timestamp clock). Within each
  stream, timestamps must be monotonically non-decreasing — out-of-order parsed
  timestamps are nudged to (previous + 1ns) and monotonicFixed is reported. }
function BuildPushBody(lines: TList; const cfg: TConfig; out monotonicFixed: Boolean): string;

implementation

var
  LastClampWarn: QWord;

function BuildPushBody(lines: TList; const cfg: TConfig; out monotonicFixed: Boolean): string;
var
  root, st, labels: TJSONObject;
  streams, v: TJSONArray;
  grpArray: array of TJSONArray;
  lastTs: array of Int64;
  i, idx: Integer;
  key, inst: string;
  pl: PLogLine;
  ts, nowVal, maxAgeNs: Int64;
  keys: TStringList;
  found, clamped: Boolean;
const
  FUTURE_SKEW_NS = 3600 * 1000000000;   { 1 hour }
begin
  monotonicFixed := False;
  clamped := False;
  keys := TStringList.Create;
  root := TJSONObject.Create;
  streams := TJSONArray.Create;
  root.Add('streams', streams);
  SetLength(grpArray, 0);
  SetLength(lastTs, 0);
  nowVal := NowNs;
  if cfg.TimeMaxAgeHours > 0 then
    maxAgeNs := cfg.TimeMaxAgeHours * 3600 * 1000000000
  else
    maxAgeNs := 0;
  try
    for i := 0 to lines.Count - 1 do
    begin
      pl := PLogLine(lines[i]);
      inst := pl^.Instance;
      if inst = '' then inst := cfg.Instance;
      { #1 cannot occur in an instance name or a level; keeping instance in the
        key prevents lines from different app instances sharing one stream (and
        one monotonic timestamp clock). }
      key := inst + #1 + pl^.Level;
      found := False;
      idx := -1;
      for idx := 0 to keys.Count - 1 do
        if keys[idx] = key then begin found := True; Break; end;
      if not found then
      begin
        idx := keys.Add(key);
        SetLength(grpArray, idx + 1);
        SetLength(lastTs, idx + 1);
        grpArray[idx] := TJSONArray.Create;
        lastTs[idx] := 0;
        st := TJSONObject.Create;
        labels := TJSONObject.Create;
        labels.Add('job', cfg.Job);
        labels.Add('instance', inst);
        if key <> '' then labels.Add('level', key);
        st.Add('stream', labels);
        st.Add('values', grpArray[idx]);
        streams.Add(st);
      end;

      ts := pl^.TsNs;
      { A single timestamp outside Loki's acceptance window makes Loki reject the
        WHOLE batch. Clamp such lines to "now" so the rest of the batch survives
        and no content is lost. Raise timestamp_max_age_hours (and Loki's
        reject_old_samples_max_age) if you want older real timestamps preserved. }
      if (maxAgeNs > 0) and (ts <> 0) and
         ((ts < nowVal - maxAgeNs) or (ts > nowVal + FUTURE_SKEW_NS)) then
      begin
        ts := nowVal;
        clamped := True;
      end;
      if (lastTs[idx] <> 0) and (ts < lastTs[idx]) then
      begin
        ts := lastTs[idx] + 1;
        monotonicFixed := True;
      end;
      if ts = 0 then ts := nowNs;
      lastTs[idx] := ts;

      v := TJSONArray.Create;
      v.Add(IntToStr(ts));
      v.Add(pl^.Text);
      grpArray[idx].Add(v);
    end;
    Result := root.AsJSON;
  finally
    keys.Free;
    root.Free;
  end;
  if clamped then
  begin
    { Throttle to one warning / 10s so a backfill of old logs stays quiet. }
    if GetTickCount64 - LastClampWarn > 10000 then
    begin
      LogWarn('timestamp(s) outside Loki acceptance window reset to now; ' +
              'raise timestamp_max_age_hours (and Loki reject_old_samples_max_age) to keep older real times');
      LastClampWarn := GetTickCount64;
    end;
  end;
end;

end.
