unit Meshtastic.Settings;

{ MeshTerm's saved settings (MeshTerm.ini in <home>\MeshTerm), shared by the
  Windows and Android front ends. The sections and keys are the same ones the
  VCL MeshTerm.exe uses, so both see the same friends, notes and so on:

    [MQTT]   Friends=1a2b3c4d,...  ExtraTopics=msh/US/TX,...
    [Power]  NoBattery=9f8e7d6c,...
    [Notes]  <node hex>=text
    [Nodes]  Show, Heard, FriendsTop, SortCol, SortDesc
    [Alerts] Direct, Friends, Private, Public, OnlyWhenAway
    [Map]    Zoom, Lat, Lon }

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, System.IOUtils, System.Math,
  System.Generics.Collections;

type
  TMeshSettings = class
  private
    FOnError: TProc<string>;
    procedure Fail(const What: string; E: Exception);
    function OpenIni: TMemIniFile;
  public
    Friends: TList<Cardinal>;            // node IDs whose traffic always comes in
    NoBattery: TList<Cardinal>;          // radios with no battery (their reading is junk)
    Notes: TDictionary<Cardinal, string>;
    ExtraTopics: TStringList;            // listen-only MQTT topic roots
    // Nodes view
    NodeShow, NodeHeard, NodeSortCol: Integer;
    NodeSortDesc, FriendsTop: Boolean;
    // alerts
    AlertDirect, AlertFriends, AlertPrivate, AlertPublic, AlertOnlyAway: Boolean;
    // map
    MapZoom: Integer;
    MapLat, MapLon: Double;
    ShowDeviceLog: Boolean;
    constructor Create;
    destructor Destroy; override;
    procedure Load;
    procedure SaveFriendsAndTopics;
    procedure SaveNoBattery;
    procedure SaveNote(Num: Cardinal);
    procedure SaveNodeView;
    procedure SaveAlerts;
    procedure SaveMapView(Zoom: Integer; Lat, Lon: Double);
    procedure SaveMisc;
    function FriendsText: string;        // "!1a2b3c4d, !9f8e7d6c"
    function IsFriend(Num: Cardinal): Boolean;
    property OnError: TProc<string> read FOnError write FOnError;
  end;

function IniPath: string;
function MessagesLogPath: string;
{ "!1a2b3c4d" or "1a2b3c4d" -> node number; 0 if not a node ID }
function ParseNodeId(const S: string): Cardinal;

implementation

uses
  Meshtastic.Proto;

function IniPath: string;
var
  Dir: string;
begin
  Dir := TPath.Combine(TPath.GetHomePath, 'MeshTerm');
  ForceDirectories(Dir);
  Result := TPath.Combine(Dir, 'MeshTerm.ini');
end;

function MessagesLogPath: string;
begin
  Result := TPath.Combine(TPath.GetDirectoryName(IniPath), 'messages.log');
end;

function ParseNodeId(const S: string): Cardinal;
var
  T: string;
  V: Int64;
begin
  Result := 0;
  T := S.Trim;
  if T.StartsWith('!') then
    T := Copy(T, 2, MaxInt);
  if (Length(T) = 8) and TryStrToInt64('$' + T, V) then
    Result := Cardinal(V);
end;

function HexList(L: TList<Cardinal>; const Sep: string): string;
var
  N: Cardinal;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    for N in L do
    begin
      if SB.Length > 0 then
        SB.Append(Sep);
      SB.Append(LowerCase(IntToHex(N, 8)));
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

procedure ReadIdList(L: TList<Cardinal>; const CSV: string);
var
  T: string;
  N: Cardinal;
begin
  L.Clear;
  for T in CSV.Split([',', ';', ' ']) do
  begin
    N := ParseNodeId(T);
    if (N <> 0) and not L.Contains(N) then
      L.Add(N);
  end;
end;

{ TMeshSettings }

constructor TMeshSettings.Create;
begin
  inherited Create;
  Friends := TList<Cardinal>.Create;
  NoBattery := TList<Cardinal>.Create;
  Notes := TDictionary<Cardinal, string>.Create;
  ExtraTopics := TStringList.Create;
  NodeSortCol := 10;   // last heard
  FriendsTop := True;
  AlertDirect := True;
  AlertFriends := True;
  AlertPrivate := True;
  AlertOnlyAway := True;
end;

destructor TMeshSettings.Destroy;
begin
  ExtraTopics.Free;
  Notes.Free;
  NoBattery.Free;
  Friends.Free;
  inherited;
end;

procedure TMeshSettings.Fail(const What: string; E: Exception);
begin
  if Assigned(FOnError) then
    FOnError(Format('Could not save %s: %s', [What, E.Message]));
end;

{ A TMemIniFile reads the whole file and writes it back on UpdateFile, so a
  save only touches the keys we set (the VCL app may own the other ones). }
function TMeshSettings.OpenIni: TMemIniFile;
begin
  Result := TMemIniFile.Create(IniPath, TEncoding.UTF8);
end;

procedure TMeshSettings.Load;
var
  Ini: TMemIniFile;
  Keys: TStringList;
  K, V, T: string;
  N: Int64;
begin
  Notes.Clear;
  ExtraTopics.Clear;
  try
    Ini := OpenIni;
    Keys := TStringList.Create;
    try
      ReadIdList(Friends, Ini.ReadString('MQTT', 'Friends', ''));
      ReadIdList(NoBattery, Ini.ReadString('Power', 'NoBattery', ''));
      for T in Ini.ReadString('MQTT', 'ExtraTopics', '').Split([',']) do
        if T.Trim <> '' then
          ExtraTopics.Add(T.Trim);
      Ini.ReadSection('Notes', Keys);
      for K in Keys do
      begin
        N := StrToInt64Def('$' + K, 0);
        V := Trim(Ini.ReadString('Notes', K, ''));
        if (N > 0) and (N <= $FFFFFFFF) and (V <> '') then
          Notes.AddOrSetValue(Cardinal(N), V);
      end;
      NodeShow := Max(0, Ini.ReadInteger('Nodes', 'Show', 0));
      NodeHeard := Max(0, Ini.ReadInteger('Nodes', 'Heard', 0));
      FriendsTop := Ini.ReadBool('Nodes', 'FriendsTop', True);
      NodeSortCol := Max(0, Ini.ReadInteger('Nodes', 'SortCol', 10));
      NodeSortDesc := Ini.ReadBool('Nodes', 'SortDesc', False);
      AlertDirect := Ini.ReadBool('Alerts', 'Direct', True);
      AlertFriends := Ini.ReadBool('Alerts', 'Friends', True);
      AlertPrivate := Ini.ReadBool('Alerts', 'Private', True);
      AlertPublic := Ini.ReadBool('Alerts', 'Public', False);
      AlertOnlyAway := Ini.ReadBool('Alerts', 'OnlyWhenAway', True);
      MapZoom := Ini.ReadInteger('Map', 'Zoom', 0);
      MapLat := StrToFloatDef(Ini.ReadString('Map', 'Lat', ''), 999, TFormatSettings.Invariant);
      MapLon := StrToFloatDef(Ini.ReadString('Map', 'Lon', ''), 999, TFormatSettings.Invariant);
      ShowDeviceLog := Ini.ReadBool('MeshTermX', 'DeviceLog', False);
    finally
      Keys.Free;
      Ini.Free;
    end;
  except
    // no settings file yet: defaults
  end;
end;

function TMeshSettings.FriendsText: string;
var
  N: Cardinal;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    for N in Friends do
    begin
      if SB.Length > 0 then
        SB.Append(', ');
      SB.Append(NodeIdStr(N));
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function TMeshSettings.IsFriend(Num: Cardinal): Boolean;
begin
  Result := Friends.Contains(Num);
end;

procedure TMeshSettings.SaveFriendsAndTopics;
var
  Ini: TMemIniFile;
begin
  try
    Ini := OpenIni;
    try
      Ini.WriteString('MQTT', 'ExtraTopics', string.Join(',', ExtraTopics.ToStringArray));
      Ini.WriteString('MQTT', 'Friends', FriendsText.Replace(' ', ''));
      Ini.UpdateFile;
    finally
      Ini.Free;
    end;
  except
    on E: Exception do
      Fail('the friends list', E);
  end;
end;

procedure TMeshSettings.SaveNoBattery;
var
  Ini: TMemIniFile;
begin
  try
    Ini := OpenIni;
    try
      Ini.WriteString('Power', 'NoBattery', HexList(NoBattery, ','));
      Ini.UpdateFile;
    finally
      Ini.Free;
    end;
  except
    on E: Exception do
      Fail('settings', E);
  end;
end;

procedure TMeshSettings.SaveNote(Num: Cardinal);
var
  Ini: TMemIniFile;
  Note: string;
begin
  try
    Ini := OpenIni;
    try
      if Notes.TryGetValue(Num, Note) then
        Ini.WriteString('Notes', LowerCase(IntToHex(Num, 8)), Note)
      else
        Ini.DeleteKey('Notes', LowerCase(IntToHex(Num, 8)));
      Ini.UpdateFile;
    finally
      Ini.Free;
    end;
  except
    on E: Exception do
      Fail('the note', E);
  end;
end;

procedure TMeshSettings.SaveNodeView;
var
  Ini: TMemIniFile;
begin
  try
    Ini := OpenIni;
    try
      Ini.WriteInteger('Nodes', 'Show', NodeShow);
      Ini.WriteInteger('Nodes', 'Heard', NodeHeard);
      Ini.WriteBool('Nodes', 'FriendsTop', FriendsTop);
      Ini.WriteInteger('Nodes', 'SortCol', NodeSortCol);
      Ini.WriteBool('Nodes', 'SortDesc', NodeSortDesc);
      Ini.UpdateFile;
    finally
      Ini.Free;
    end;
  except
    // view settings are optional
  end;
end;

procedure TMeshSettings.SaveAlerts;
var
  Ini: TMemIniFile;
begin
  try
    Ini := OpenIni;
    try
      Ini.WriteBool('Alerts', 'Direct', AlertDirect);
      Ini.WriteBool('Alerts', 'Friends', AlertFriends);
      Ini.WriteBool('Alerts', 'Private', AlertPrivate);
      Ini.WriteBool('Alerts', 'Public', AlertPublic);
      Ini.WriteBool('Alerts', 'OnlyWhenAway', AlertOnlyAway);
      Ini.UpdateFile;
    finally
      Ini.Free;
    end;
  except
    // optional
  end;
end;

procedure TMeshSettings.SaveMapView(Zoom: Integer; Lat, Lon: Double);
var
  Ini: TMemIniFile;
begin
  MapZoom := Zoom;
  MapLat := Lat;
  MapLon := Lon;
  try
    Ini := OpenIni;
    try
      Ini.WriteInteger('Map', 'Zoom', Zoom);
      Ini.WriteString('Map', 'Lat', FormatFloat('0.000000', Lat, TFormatSettings.Invariant));
      Ini.WriteString('Map', 'Lon', FormatFloat('0.000000', Lon, TFormatSettings.Invariant));
      Ini.UpdateFile;
    finally
      Ini.Free;
    end;
  except
    // optional
  end;
end;

procedure TMeshSettings.SaveMisc;
var
  Ini: TMemIniFile;
begin
  try
    Ini := OpenIni;
    try
      Ini.WriteBool('MeshTermX', 'DeviceLog', ShowDeviceLog);
      Ini.UpdateFile;
    finally
      Ini.Free;
    end;
  except
    // optional
  end;
end;

end.
