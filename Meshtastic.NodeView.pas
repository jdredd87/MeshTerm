unit Meshtastic.NodeView;

{ What the Nodes list shows, without any UI: which nodes pass the filters,
  their order, and the text for each column or the details line. Shared by
  the Windows and Android front ends. }

interface

uses
  System.SysUtils, System.Classes, System.DateUtils, System.Math,
  System.Generics.Collections, System.Generics.Defaults,
  Meshtastic.Proto, Meshtastic.Client, Meshtastic.Settings;

const
  // columns / sort keys (also stored as [Nodes] SortCol)
  NC_NAME = 0; NC_SHORT = 1; NC_ID = 2; NC_HW = 3; NC_ROLE = 4; NC_SNR = 5; NC_RSSI = 6;
  NC_HOPS = 7; NC_BATTERY = 8; NC_DIST = 9; NC_HEARD = 10; NC_POS = 11; NC_NOTE = 12;
  NODE_COLS = 13;

  // TMeshSettings.NodeShow
  SHOW_ALL = 0; SHOW_FRIENDS = 1; SHOW_LOCAL = 2; SHOW_INTERNET = 3; SHOW_DIRECT = 4;
  SHOW_LOCATION = 5; SHOW_NOTE = 6;

  STAR = #$2605;

type
  TNodeView = class
  private
    FClient: TMeshClient;
    FSettings: TMeshSettings;
  public
    Metric: Boolean;
    constructor Create(AClient: TMeshClient; ASettings: TMeshSettings);
    { "Local" = this radio, or a node heard over LoRa (not via the internet). }
    function IsLocalNode(const N: TNodeInfo): Boolean;
    function BatteryText(const N: TNodeInfo; Long: Boolean): string;
    function DistText(Km: Double): string;
    function NodeDistance(const N: TNodeInfo; out Km: Double): Boolean;
    function NamesOf(const Nums: TArray<Cardinal>): string;
    function Visible(Num: Cardinal; const Words: TArray<string>): Boolean;
    function Compare(A, B: Cardinal): Integer;
    function Cell(Num: Cardinal; Col: Integer): string;
    { Filtered + sorted node numbers (friends not heard yet included). }
    function Rows(const Search: string): TArray<Cardinal>;
    function TotalCount: Integer;
    function IsFiltered(const Search: string): Boolean;
    { Not heard for a day (or never): drawn greyed out. }
    function IsStale(Num: Cardinal): Boolean;
    { Three lines: who, how it was heard, battery/location/note. }
    procedure Details(Num: Cardinal; out Who, Heard, Extra: string);
    { One-line summary for a list row under the name. }
    function Summary(Num: Cardinal): string;
  end;

function AgoStr(UnixTime: Cardinal): string;
function DistanceKm(Lat1, Lon1, Lat2, Lon2: Double): Double;
function FriendlyRole(Role: Integer): string;
function UptimeStr(Secs: Cardinal): string;
{ The system's measurement setting: False = miles/feet (US). }
function UsesMetric: Boolean;

implementation

uses
  {$IFDEF MSWINDOWS}Winapi.Windows,{$ENDIF}
  {$IFDEF ANDROID}Androidapi.JNI.JavaTypes, Androidapi.Helpers,{$ENDIF}
  System.StrUtils;

const
  DOT = '  '#$00B7'  ';

function AgoStr(UnixTime: Cardinal): string;
var
  Secs: Int64;
begin
  if UnixTime = 0 then
    Exit('');
  Secs := DateTimeToUnix(Now, False) - UnixTime;
  if Secs < 0 then Secs := 0;
  if Secs < 60 then Result := Format('%ds ago', [Secs])
  else if Secs < 3600 then Result := Format('%dm ago', [Secs div 60])
  else if Secs < 86400 then Result := Format('%dh ago', [Secs div 3600])
  else Result := Format('%dd ago', [Secs div 86400]);
end;

function DistanceKm(Lat1, Lon1, Lat2, Lon2: Double): Double;
var
  DLat, DLon, A: Double;
begin
  DLat := DegToRad(Lat2 - Lat1);
  DLon := DegToRad(Lon2 - Lon1);
  A := Sqr(Sin(DLat / 2)) + Cos(DegToRad(Lat1)) * Cos(DegToRad(Lat2)) * Sqr(Sin(DLon / 2));
  Result := 6371 * 2 * ArcTan2(Sqrt(A), Sqrt(1 - A));
end;

// CLIENT_MUTE -> "Client mute"
function FriendlyRole(Role: Integer): string;
begin
  Result := LowerCase(RoleName(Role)).Replace('_', ' ');
  if Result = '' then
    Exit;
  Result[Low(Result)] := UpCase(Result[Low(Result)]);
  Result := Result.Replace('Tak', 'TAK');
end;

function UptimeStr(Secs: Cardinal): string;
begin
  if Secs >= 86400 then
    Result := Format('%dd %dh', [Secs div 86400, (Secs mod 86400) div 3600])
  else if Secs >= 3600 then
    Result := Format('%dh %dm', [Secs div 3600, (Secs mod 3600) div 60])
  else
    Result := Format('%dm', [Secs div 60]);
end;

function UsesMetric: Boolean;
{$IFDEF MSWINDOWS}
var
  Buf: array[0..3] of Char;
begin
  Result := True;
  if GetLocaleInfo(LOCALE_USER_DEFAULT, LOCALE_IMEASURE, Buf, Length(Buf)) > 0 then
    Result := Buf[0] <> '1';
end;
{$ELSEIF DEFINED(ANDROID)}
var
  C: string;
begin
  try
    C := JStringToString(TJLocale.JavaClass.getDefault.getCountry);
  except
    C := '';
  end;
  // the countries that still use miles
  Result := not (SameText(C, 'US') or SameText(C, 'LR') or SameText(C, 'MM') or SameText(C, 'GB'));
end;
{$ELSE}
begin
  Result := True;
end;
{$ENDIF}

{ TNodeView }

constructor TNodeView.Create(AClient: TMeshClient; ASettings: TMeshSettings);
begin
  inherited Create;
  FClient := AClient;
  FSettings := ASettings;
  Metric := UsesMetric;
end;

function TNodeView.IsLocalNode(const N: TNodeInfo): Boolean;
begin
  Result := (N.Num = FClient.MyNodeNum) or
    (not N.ViaMqtt and ((N.HopsAway >= 0) or (N.Snr <> 0) or (N.Rssi <> 0)));
end;

function TNodeView.BatteryText(const N: TNodeInfo; Long: Boolean): string;
begin
  Result := '';
  if FSettings.NoBattery.Contains(N.Num) then
    Result := IfThen(Long, 'USB powered (no battery)', 'no battery')
  else if not N.Metrics.Valid then
    Exit
  else if N.Metrics.BatteryLevel > 100 then
    Result := IfThen(Long, 'USB powered', 'powered')
  else if N.Metrics.BatteryLevel > 0 then
  begin
    if Long then
      Result := Format('Battery %d%%  %.2f V', [N.Metrics.BatteryLevel, N.Metrics.Voltage])
    else
      Result := Format('%d%% %.2fV', [N.Metrics.BatteryLevel, N.Metrics.Voltage]);
  end;
end;

function TNodeView.DistText(Km: Double): string;
var
  Mi: Double;
begin
  if Metric then
  begin
    if Km < 1 then
      Result := Format('%d m', [Round(Km * 1000)])
    else if Km < 10 then
      Result := FormatFloat('0.0', Km) + ' km'
    else
      Result := FormatFloat('0', Km) + ' km';
  end
  else
  begin
    Mi := Km * 0.621371;
    if Mi < 0.1 then
      Result := Format('%d ft', [Round(Km * 3280.84)])
    else if Mi < 10 then
      Result := FormatFloat('0.0', Mi) + ' mi'
    else
      Result := FormatFloat('0', Mi) + ' mi';
  end;
end;

function TNodeView.NodeDistance(const N: TNodeInfo; out Km: Double): Boolean;
var
  Me: TNodeInfo;
begin
  Km := 0;
  Result := (N.Num <> FClient.MyNodeNum) and N.Position.Valid and
    FClient.Nodes.TryGetValue(FClient.MyNodeNum, Me) and Me.Position.Valid;
  if Result then
    Km := DistanceKm(Me.Position.Lat, Me.Position.Lon, N.Position.Lat, N.Position.Lon);
end;

function TNodeView.NamesOf(const Nums: TArray<Cardinal>): string;
var
  Num: Cardinal;
  L: TStringList;
begin
  L := TStringList.Create;
  try
    for Num in Nums do
      if FClient.NodeName(Num) = NodeIdStr(Num) then
        L.Add(NodeIdStr(Num))
      else
        L.Add(FClient.NodeName(Num) + ' (' + NodeIdStr(Num) + ')');
    Result := string.Join(', ', L.ToStringArray);
  finally
    L.Free;
  end;
end;

function TNodeView.Visible(Num: Cardinal; const Words: TArray<string>): Boolean;
var
  N: TNodeInfo;
  Known: Boolean;
  Hay, W, Note: string;
  MaxAge: Int64;
begin
  Known := FClient.Nodes.TryGetValue(Num, N);
  case FSettings.NodeShow of
    SHOW_FRIENDS: Result := FSettings.Friends.Contains(Num);
    SHOW_LOCAL: Result := Known and IsLocalNode(N);
    SHOW_INTERNET: Result := Known and N.ViaMqtt;
    SHOW_DIRECT: Result := Known and (Num <> FClient.MyNodeNum) and not N.ViaMqtt and (N.HopsAway = 0);
    SHOW_LOCATION: Result := Known and N.Position.Valid;
    SHOW_NOTE: Result := FSettings.Notes.ContainsKey(Num);
  else
    Result := True;
  end;
  if not Result then
    Exit;

  case FSettings.NodeHeard of
    1: MaxAge := 15 * 60;
    2: MaxAge := 3600;
    3: MaxAge := 6 * 3600;
    4: MaxAge := 86400;
    5: MaxAge := 7 * 86400;
  else
    MaxAge := 0;
  end;
  if (MaxAge > 0) and (Num <> FClient.MyNodeNum) then
    if not Known or (N.LastHeard = 0) or
      (DateTimeToUnix(Now, False) - Int64(N.LastHeard) > MaxAge) then
      Exit(False);

  if Length(Words) = 0 then
    Exit;
  if not FSettings.Notes.TryGetValue(Num, Note) then
    Note := '';
  Hay := FClient.NodeName(Num) + ' ' + NodeIdStr(Num) + ' ' + Note;
  if Known then
  begin
    Hay := Hay + ' ' + N.User.ShortName + ' ' + N.User.LongName;
    if N.HasUser then
      Hay := Hay + ' ' + HwModelName(N.User.HwModel) + ' ' + FriendlyRole(N.User.Role);
  end;
  Hay := LowerCase(Hay);
  for W in Words do
    if Pos(W, Hay) = 0 then
      Exit(False);
end;

{ This radio first, then friends (if "Friends at top"), then the rest by the
  sort key. Blank values always go last, whichever direction. }
function TNodeView.Compare(A, B: Cardinal): Integer;

  function Rank(Num: Cardinal): Integer;
  begin
    if Num = FClient.MyNodeNum then
      Result := 0
    else if FSettings.FriendsTop and FSettings.Friends.Contains(Num) then
      Result := 1
    else
      Result := 2;
  end;

  function Opt(HasA, HasB: Boolean; R: Integer): Integer;
  begin
    if HasA and HasB then
    begin
      if FSettings.NodeSortDesc then
        Result := -R
      else
        Result := R;
    end
    else if HasA then
      Result := -1
    else if HasB then
      Result := 1
    else
      Result := 0;
  end;

  function HopKey(Known: Boolean; const N: TNodeInfo): Integer;
  begin
    if not Known then
      Result := -1
    else if N.ViaMqtt then
      Result := 99
    else
      Result := N.HopsAway;     // -1 = unknown
  end;

  function BatKey(Known: Boolean; const N: TNodeInfo): Integer;
  begin
    if not Known or FSettings.NoBattery.Contains(N.Num) or not N.Metrics.Valid or
      (N.Metrics.BatteryLevel <= 0) then
      Result := -1
    else
      Result := Min(N.Metrics.BatteryLevel, 101);
  end;

var
  NA, NB: TNodeInfo;
  KA, KB, HA, HB: Boolean;
  SA, SB: string;
  DA, DB: Double;
begin
  Result := Rank(A) - Rank(B);
  if Result <> 0 then
    Exit;
  KA := FClient.Nodes.TryGetValue(A, NA);
  KB := FClient.Nodes.TryGetValue(B, NB);
  case FSettings.NodeSortCol of
    NC_ID:
      Result := Opt(True, True, CompareValue(Int64(A), Int64(B)));
    NC_SNR:
      Result := Opt(KA and (NA.Snr <> 0), KB and (NB.Snr <> 0), CompareValue(NA.Snr, NB.Snr));
    NC_RSSI:
      Result := Opt(KA and (NA.Rssi <> 0), KB and (NB.Rssi <> 0), CompareValue(NA.Rssi, NB.Rssi));
    NC_HOPS:
      Result := Opt(HopKey(KA, NA) >= 0, HopKey(KB, NB) >= 0,
        CompareValue(HopKey(KA, NA), HopKey(KB, NB)));
    NC_BATTERY:
      Result := Opt(BatKey(KA, NA) >= 0, BatKey(KB, NB) >= 0,
        CompareValue(BatKey(KA, NA), BatKey(KB, NB)));
    NC_DIST:
      begin
        HA := KA and NodeDistance(NA, DA);
        HB := KB and NodeDistance(NB, DB);
        Result := Opt(HA, HB, CompareValue(DA, DB));
      end;
    NC_HEARD:      // ascending = most recently heard first
      Result := Opt(KA and (NA.LastHeard <> 0), KB and (NB.LastHeard <> 0),
        CompareValue(Int64(NB.LastHeard), Int64(NA.LastHeard)));
    NC_POS:
      Result := Opt(KA and NA.Position.Valid, KB and NB.Position.Valid,
        CompareValue(NB.Position.Lat, NA.Position.Lat));
    NC_NAME:
      Result := Opt(True, True, CompareText(FClient.NodeName(A), FClient.NodeName(B)));
  else
    begin
      SA := Cell(A, FSettings.NodeSortCol);
      SB := Cell(B, FSettings.NodeSortCol);
      Result := Opt(SA <> '', SB <> '', CompareText(SA, SB));
    end;
  end;
  if Result = 0 then
    Result := CompareText(FClient.NodeName(A), FClient.NodeName(B));
  if Result = 0 then
    Result := CompareValue(Int64(A), Int64(B));
end;

function TNodeView.Cell(Num: Cardinal; Col: Integer): string;
var
  N: TNodeInfo;
  Known: Boolean;
  Km: Double;
begin
  Result := '';
  Known := FClient.Nodes.TryGetValue(Num, N);
  case Col of
    NC_NAME:
      begin
        Result := FClient.NodeName(Num);
        if Num = FClient.MyNodeNum then
          Result := Result + '  (this radio)';
        if FSettings.Friends.Contains(Num) then
          Result := STAR + ' ' + Result;
      end;
    NC_ID:
      Result := NodeIdStr(Num);
    NC_HEARD:
      if Known then
        Result := AgoStr(N.LastHeard)
      else
        Result := 'not heard yet';
    NC_NOTE:
      if not FSettings.Notes.TryGetValue(Num, Result) then
        Result := '';
  end;
  if not Known then
    Exit;
  case Col of
    NC_SHORT:
      Result := N.User.ShortName;
    NC_HW:
      if N.HasUser then
        Result := HwModelName(N.User.HwModel);
    NC_ROLE:
      if N.HasUser then
        Result := FriendlyRole(N.User.Role);
    NC_SNR:
      if N.Snr <> 0 then
        Result := FormatFloat('0.0', N.Snr);
    NC_RSSI:
      if N.Rssi <> 0 then
        Result := IntToStr(N.Rssi);
    NC_HOPS:
      if Num = FClient.MyNodeNum then
        Result := '-'
      else if N.ViaMqtt then
        Result := 'internet'
      else if N.HopsAway = 0 then
        Result := 'direct'
      else if N.HopsAway > 0 then
        Result := IntToStr(N.HopsAway);
    NC_BATTERY:
      Result := BatteryText(N, False);
    NC_DIST:
      if NodeDistance(N, Km) then
        Result := DistText(Km);
    NC_POS:
      if N.Position.Valid then
        Result := FormatFloat('0.0000', N.Position.Lat) + ', ' +
          FormatFloat('0.0000', N.Position.Lon);
  end;
end;

function TNodeView.Rows(const Search: string): TArray<Cardinal>;
var
  L: TList<Cardinal>;
  Words: TArray<string>;
  Num: Cardinal;
begin
  Words := LowerCase(Trim(Search)).Split([' '], TStringSplitOptions.ExcludeEmpty);
  L := TList<Cardinal>.Create;
  try
    for Num in FClient.Nodes.Keys do
      if Visible(Num, Words) then
        L.Add(Num);
    for Num in FSettings.Friends do
      if not FClient.Nodes.ContainsKey(Num) and Visible(Num, Words) then
        L.Add(Num);
    L.Sort(TComparer<Cardinal>.Construct(
      function(const A, B: Cardinal): Integer
      begin
        Result := Compare(A, B);
      end));
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

function TNodeView.TotalCount: Integer;
var
  Num: Cardinal;
begin
  Result := FClient.Nodes.Count;
  for Num in FSettings.Friends do
    if not FClient.Nodes.ContainsKey(Num) then
      Inc(Result);
end;

function TNodeView.IsFiltered(const Search: string): Boolean;
begin
  Result := (FSettings.NodeShow > 0) or (FSettings.NodeHeard > 0) or (Trim(Search) <> '');
end;

function TNodeView.IsStale(Num: Cardinal): Boolean;
var
  N: TNodeInfo;
begin
  Result := not FClient.Nodes.TryGetValue(Num, N) or (N.LastHeard = 0) or
    (DateTimeToUnix(Now, False) - Int64(N.LastHeard) > 86400);
end;

procedure TNodeView.Details(Num: Cardinal; out Who, Heard, Extra: string);
var
  N: TNodeInfo;
  Known: Boolean;
  T, Note: string;
  Km: Double;

  procedure Add3(const S: string);
  begin
    if S = '' then
      Exit;
    if Extra <> '' then
      Extra := Extra + DOT;
    Extra := Extra + S;
  end;

begin
  Known := FClient.Nodes.TryGetValue(Num, N);
  Who := FClient.NodeName(Num);
  if Known and (N.User.ShortName <> '') then
    Who := Who + ' (' + N.User.ShortName + ')';
  if FClient.NodeName(Num) <> NodeIdStr(Num) then
    Who := Who + DOT + NodeIdStr(Num);
  if Known and N.HasUser then
    Who := Who + DOT + HwModelName(N.User.HwModel) + ', ' + FriendlyRole(N.User.Role);
  if Num = FClient.MyNodeNum then
    Who := Who + DOT + 'this radio'
  else if FSettings.Friends.Contains(Num) then
    Who := Who + DOT + STAR + ' friend';

  if not Known then
    Heard := 'Not heard yet. It shows up as soon as this radio or the internet link hears from it.'
  else
  begin
    if N.LastHeard <> 0 then
      Heard := 'Heard ' + AgoStr(N.LastHeard) + ' (' +
        FormatDateTime('ddd mmm d, t', UnixToDateTime(N.LastHeard, False)) + ')'
    else
      Heard := 'Not heard since MeshTerm connected';
    if Num = FClient.MyNodeNum then
      // nothing about how it was heard
    else if N.ViaMqtt then
      Heard := Heard + ' via the internet'
    else if N.HopsAway = 0 then
      Heard := Heard + ' directly over the air'
    else if N.HopsAway = 1 then
      Heard := Heard + ' over the air, 1 hop away'
    else if N.HopsAway > 1 then
      Heard := Heard + Format(' over the air, %d hops away', [N.HopsAway]);
    if N.Snr <> 0 then
      Heard := Heard + DOT + Format('SNR %.1f dB', [N.Snr]);
    if N.Rssi <> 0 then
      Heard := Heard + DOT + Format('RSSI %d dBm', [N.Rssi]);
  end;

  Extra := '';
  if Known then
  begin
    Add3(BatteryText(N, True));
    if N.Metrics.Valid then
    begin
      if N.Metrics.ChannelUtil > 0 then
        Add3(Format('Channel busy %.1f%%', [N.Metrics.ChannelUtil]));
      if N.Metrics.AirUtilTx > 0 then
        Add3(Format('Own airtime %.1f%%', [N.Metrics.AirUtilTx]));
      if N.Metrics.Uptime > 0 then
        Add3('Up ' + UptimeStr(N.Metrics.Uptime));
    end;
    if N.Position.Valid then
    begin
      T := 'Location ' + FormatFloat('0.00000', N.Position.Lat) + ', ' +
        FormatFloat('0.00000', N.Position.Lon);
      if N.Position.Altitude <> 0 then
        if Metric then
          T := T + Format(' (%d m high)', [N.Position.Altitude])
        else
          T := T + Format(' (%d ft high)', [Round(N.Position.Altitude * 3.28084)]);
      Add3(T);
      if NodeDistance(N, Km) then
        Add3(DistText(Km) + ' from this radio');
    end;
  end;
  if FSettings.Notes.TryGetValue(Num, Note) then
    Add3('Note: ' + Note);
end;

function TNodeView.Summary(Num: Cardinal): string;

  procedure Add(const S: string);
  begin
    if S = '' then
      Exit;
    if Result <> '' then
      Result := Result + DOT;
    Result := Result + S;
  end;

var
  N: TNodeInfo;
  Note: string;
begin
  Result := NodeIdStr(Num);
  if not FClient.Nodes.TryGetValue(Num, N) then
  begin
    Add('not heard yet');
  end
  else
  begin
    Add(AgoStr(N.LastHeard));
    if Num <> FClient.MyNodeNum then
      Add(IfThen(Cell(Num, NC_HOPS) = 'direct', 'direct',
        IfThen(Cell(Num, NC_HOPS) = 'internet', 'internet',
        IfThen(Cell(Num, NC_HOPS) <> '', Cell(Num, NC_HOPS) + ' hops', ''))));
    if N.Snr <> 0 then
      Add(Format('SNR %.1f', [N.Snr]));
    Add(Cell(Num, NC_DIST));
    Add(BatteryText(N, False));
    if N.HasUser then
      Add(HwModelName(N.User.HwModel));
  end;
  if FSettings.Notes.TryGetValue(Num, Note) then
    Add(#$270E' ' + Note);
end;

end.
