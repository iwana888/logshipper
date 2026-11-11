unit ulevel;
{$mode objfpc}{$H+}
interface
uses
  SysUtils, Classes, RegExpr;

{ Extract a log level from the line using the configured regex.
  If re is nil (regex disabled) or no match, returns ''. }
function ParseLevel(const line: string; re: TRegExpr): string;

implementation

function ParseLevel(const line: string; re: TRegExpr): string;
begin
  Result := '';
  if re = nil then Exit;
  if re.Exec(Copy(line, 1, 256)) then
  begin
    if re.SubExprMatchCount >= 1 then
      Result := re.Match[1]
    else
      Result := re.Match[0];
  end;
end;

end.
