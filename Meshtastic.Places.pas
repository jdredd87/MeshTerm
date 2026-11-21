unit Meshtastic.Places;

{ Finding a place for the map: typed coordinates, or a name looked up on
  OpenStreetMap's Nominatim service (one search at a time, as its usage
  policy asks). }

interface

uses
  System.SysUtils, System.Classes;

type
  TFoundPlace = record
    Name: string;
    Lat, Lon, South, North, West, East: Double;
  end;

  TPlacesDone = reference to procedure(const Places: TArray<TFoundPlace>; const Err: string);

{ "40.689, -74.045", "40.689 N 74.045 W", "40.689° N, 74.045° W", or a map
  link containing "@40.689,-74.045". }
function ParseCoords(const Text: string; out Lat, Lon: Double): Boolean;
function ParsePlaces(const Json: string): TArray<TFoundPlace>;
{ Looks Query up on a background thread; Done runs on the main thread. }
procedure SearchPlaces(const Query: string; const Done: TPlacesDone);
{ "Main Street, Springfield, ..." -> "Main Street"; coordinates stay whole. }
function ShortPlaceName(const Name: string): string;

implementation

uses
  System.Math, System.RegularExpressions, System.JSON, System.NetEncoding,
  System.Net.HttpClient, System.Net.URLClient;

function ParseCoords(const Text: string; out Lat, Lon: Double): Boolean;
var
  T: string;
  M: TMatch;
  A, B: Double;
  FS: TFormatSettings;
begin
  Result := False;
  FS := TFormatSettings.Invariant;
  T := StringReplace(Text, #$00B0, ' ', [rfReplaceAll]);
  M := TRegEx.Match(T, '@(-?\d{1,3}(?:\.\d+)?),\s*(-?\d{1,3}(?:\.\d+)?)');
  if M.Success then
  begin
    A := StrToFloatDef(M.Groups[1].Value, 999, FS);
    B := StrToFloatDef(M.Groups[2].Value, 999, FS);
  end
  else
  begin
    M := TRegEx.Match(T, '^\s*([-+]?\d{1,3}(?:\.\d+)?)\s*([NSns])?\s*[,;\s]\s*' +
      '([-+]?\d{1,3}(?:\.\d+)?)\s*([EWew])?\s*$');
    if not M.Success then
      Exit;
    A := StrToFloatDef(M.Groups[1].Value, 999, FS);
    B := StrToFloatDef(M.Groups[3].Value, 999, FS);
    // (unmatched trailing groups are left out of Groups)
    if (M.Groups.Count > 2) and SameText(M.Groups[2].Value, 'S') then
      A := -Abs(A);
    if (M.Groups.Count > 4) and SameText(M.Groups[4].Value, 'W') then
      B := -Abs(B);
  end;
  if (Abs(A) > 90) or (Abs(B) > 180) then
    Exit;
  Lat := A;
  Lon := B;
  Result := True;
end;

function ParsePlaces(const Json: string): TArray<TFoundPlace>;
var
  V: TJSONValue;
  A, BB: TJSONArray;
  I: Integer;
  O: TJSONObject;
  P: TFoundPlace;
  FS: TFormatSettings;
begin
  Result := nil;
  FS := TFormatSettings.Invariant;
  V := TJSONObject.ParseJSONValue(Json);
  try
    if not (V is TJSONArray) then
      Exit;
    A := TJSONArray(V);
    for I := 0 to A.Count - 1 do
    begin
      if not (A.Items[I] is TJSONObject) then
        Continue;
      O := TJSONObject(A.Items[I]);
      P.Name := O.GetValue<string>('display_name', '');
      P.Lat := StrToFloatDef(O.GetValue<string>('lat', ''), 999, FS);
      P.Lon := StrToFloatDef(O.GetValue<string>('lon', ''), 999, FS);
      if (Abs(P.Lat) > 90) or (Abs(P.Lon) > 180) then
        Continue;
      P.South := P.Lat; P.North := P.Lat; P.West := P.Lon; P.East := P.Lon;
      if O.TryGetValue<TJSONArray>('boundingbox', BB) and (BB.Count = 4) then
      begin
        P.South := StrToFloatDef(BB.Items[0].Value, P.Lat, FS);
        P.North := StrToFloatDef(BB.Items[1].Value, P.Lat, FS);
        P.West := StrToFloatDef(BB.Items[2].Value, P.Lon, FS);
        P.East := StrToFloatDef(BB.Items[3].Value, P.Lon, FS);
      end;
      Result := Result + [P];
    end;
  finally
    V.Free;
  end;
end;

procedure SearchPlaces(const Query: string; const Done: TPlacesDone);
begin
  TThread.CreateAnonymousThread(
    procedure
    var
      Http: THTTPClient;
      Resp: IHTTPResponse;
      Places: TArray<TFoundPlace>;
      Err: string;
    begin
      Places := nil;
      Err := '';
      try
        Http := THTTPClient.Create;
        try
          // Nominatim's usage policy: identify the app; one search at a time
          Http.UserAgent := 'MeshTerm/1.0 (Meshtastic client)';
          Http.ConnectionTimeout := 8000;
          Http.ResponseTimeout := 15000;
          Resp := Http.Get('https://nominatim.openstreetmap.org/search?format=jsonv2&limit=8&q=' +
            TNetEncoding.URL.Encode(Query));
          if Resp.StatusCode = 200 then
            Places := ParsePlaces(Resp.ContentAsString(TEncoding.UTF8))
          else
            Err := Format('the search service answered "%d %s"', [Resp.StatusCode, Resp.StatusText]);
        finally
          Http.Free;
        end;
      except
        on E: Exception do
          Err := E.Message;
      end;
      TThread.Queue(nil,
        procedure
        begin
          Done(Places, Err);
        end);
    end).Start;
end;

function ShortPlaceName(const Name: string): string;
begin
  Result := Name;
  if (Pos(',', Result) > 0) and TRegEx.IsMatch(Result, '[A-Za-z]') then
    Result := Trim(Copy(Result, 1, Pos(',', Result) - 1));
  if Length(Result) > 40 then
    Result := Copy(Result, 1, 38) + '...';
end;

end.
