unit Meshtastic.Bridge;

{ The Internet (MQTT) bridge, without any UI.

  "Radio only":       the radio's MQTT is off; nothing touches the internet.
  "Radio + Internet": the radio has MQTT + "proxy to client" enabled. It hands
  us the MQTT messages it wants published (HandleProxy), and we feed it
  messages from the broker. The broker address, credentials and root topic
  come from the radio's own settings. }

interface

uses
  System.SysUtils, System.Classes, System.DateUtils, System.Math,
  Meshtastic.Proto, Meshtastic.Client, Meshtastic.Mqtt, Meshtastic.Settings;

type
  TMeshBridge = class
  private
    FClient: TMeshClient;
    FSettings: TMeshSettings;
    FMqtt: TMqttClient;
    FReady: Boolean;
    FRetryAt: TDateTime;
    FSubs: TStringList;
    FBridgeRoot: string;
    FDownThisSec: Integer;
    FOnLog: TProc<string>;
    FOnChange: TProc;
    procedure Log(const S: string);
    procedure Changed;
    procedure Start;
    procedure EnsureSubscribed(const Filter: string);
    procedure SubscribeRoot(const Root: string);
    function IsPrivateChannelTopic(const Chan: string): Boolean;
    procedure MqttConnected(Sender: TObject);
    procedure MqttMessage(const Topic: string; const Payload: TBytes);
    procedure MqttClosed(const Reason: string);
  public
    Up, Down, Dropped, Ignored, Texts: Integer;
    ShowAll: Boolean;          // let all channel traffic on the root topic in
    constructor Create(AClient: TMeshClient; ASettings: TMeshSettings);
    destructor Destroy; override;
    { Start or stop to match the radio: call after every client state change. }
    procedure Update;
    procedure Stop;
    { Resubscribe (after the extra topics changed). }
    procedure Restart;
    procedure Tick;            // once a second
    procedure HandleProxy(const Msg: TMqttProxyMessage);
    function RootTopic: string;
    function ServerAddress: string;
    function Running: Boolean;
    function Connected: Boolean;
    property OnLog: TProc<string> read FOnLog write FOnLog;
    property OnChange: TProc read FOnChange write FOnChange;
  end;

{ A topic root as typed by the user: msh/..., no spaces or wildcards (except a
  trailing /# on listen-only topics), no leading or trailing slash. }
function CheckTopic(const T: string; AllowHash: Boolean; out Err: string): Boolean;

implementation

uses
  Meshtastic.Crypto;

function CheckTopic(const T: string; AllowHash: Boolean; out Err: string): Boolean;
var
  Body: string;
begin
  Err := '';
  Body := T;
  if AllowHash and Body.EndsWith('/#') then
    Body := Copy(Body, 1, Length(Body) - 2);
  if Body = '' then
    Err := 'Topic is empty'
  else if (Body.IndexOfAny([' ', '+', '#']) >= 0) then
    Err := Format('"%s": no spaces, + or # allowed (only a trailing /# on listen topics)', [T])
  else if Body.EndsWith('/') or Body.StartsWith('/') then
    Err := Format('"%s": remove the leading/trailing slash', [T])
  else if not Body.StartsWith('msh/') and not SameText(Body, 'msh') then
    Err := Format('"%s": the public server only allows topics starting with msh/', [T]);
  Result := Err = '';
end;

{ TMeshBridge }

constructor TMeshBridge.Create(AClient: TMeshClient; ASettings: TMeshSettings);
begin
  inherited Create;
  FClient := AClient;
  FSettings := ASettings;
  FSubs := TStringList.Create;
end;

destructor TMeshBridge.Destroy;
begin
  FOnLog := nil;
  FOnChange := nil;
  Stop;
  FSubs.Free;
  inherited;
end;

procedure TMeshBridge.Log(const S: string);
begin
  if Assigned(FOnLog) then
    FOnLog(S);
end;

procedure TMeshBridge.Changed;
begin
  if Assigned(FOnChange) then
    FOnChange();
end;

function TMeshBridge.RootTopic: string;
begin
  Result := FClient.Mqtt.Root;
  if Result = '' then
    Result := 'msh';
end;

function TMeshBridge.ServerAddress: string;
begin
  Result := FClient.Mqtt.Address;
  if Result = '' then
    Result := 'mqtt.meshtastic.org';
end;

function TMeshBridge.Running: Boolean;
begin
  Result := FMqtt <> nil;
end;

function TMeshBridge.Connected: Boolean;
begin
  Result := (FMqtt <> nil) and FReady;
end;

procedure TMeshBridge.Update;
var
  Want: Boolean;
begin
  Want := (FClient.State = msReady) and FClient.InternetMode;
  // radio root changed: resubscribe from scratch
  if Want and (FMqtt <> nil) and (FBridgeRoot <> RootTopic) then
  begin
    Log('Root topic changed to ' + RootTopic + ' - reconnecting');
    Stop;
  end;
  if Want and (FMqtt = nil) and (FRetryAt = 0) then
    Start
  else if (FMqtt <> nil) and ((FClient.State = msDisconnected) or
    ((FClient.State = msReady) and not FClient.InternetMode)) then
    Stop;
  Changed;
end;

procedure TMeshBridge.Start;
var
  Addr, ClientId: string;
  Port, I: Integer;
begin
  Addr := ServerAddress;
  Port := 1883;
  I := LastDelimiter(':', Addr);
  if I > 0 then
  begin
    Port := StrToIntDef(Copy(Addr, I + 1, 5), 1883);
    Addr := Copy(Addr, 1, I - 1);
  end;
  if FClient.Mqtt.TlsEnabled then
  begin
    Log('The radio asks for TLS, which MeshTerm does not support. ' +
      'Turn TLS off in the radio''s MQTT settings.');
    Exit;
  end;
  ClientId := Format('MeshTerm_%s_%.4x', [Copy(NodeIdStr(FClient.MyNodeNum), 2, 8), Random($10000)]);
  FSubs.Clear;
  FReady := False;
  FBridgeRoot := RootTopic;
  FMqtt := TMqttClient.Create(Addr, Port, ClientId, FClient.Mqtt.Username, FClient.Mqtt.Password);
  FMqtt.OnConnected := MqttConnected;
  FMqtt.OnMessage := MqttMessage;
  FMqtt.OnClosed := MqttClosed;
  FMqtt.Start;
  Log(Format('Connecting to %s:%d ...', [Addr, Port]));
end;

procedure TMeshBridge.Stop;
var
  M: TMqttClient;
begin
  FRetryAt := 0;
  M := FMqtt;
  if M = nil then
    Exit;
  FMqtt := nil;
  FReady := False;
  M.OnClosed := nil;
  M.OnConnected := nil;
  M.OnMessage := nil;
  M.Free;                       // sends DISCONNECT and waits for the thread
  FSubs.Clear;
  Log('Disconnected from MQTT server');
  Changed;
end;

procedure TMeshBridge.Restart;
begin
  if FMqtt <> nil then
  begin
    Stop;
    Update;
  end;
end;

procedure TMeshBridge.Tick;
begin
  FDownThisSec := 0;
  if (FRetryAt <> 0) and (Now >= FRetryAt) then
  begin
    FRetryAt := 0;
    Update;
  end;
end;

procedure TMeshBridge.EnsureSubscribed(const Filter: string);
begin
  if (FMqtt = nil) or (FSubs.IndexOf(Filter) >= 0) then
    Exit;
  FSubs.Add(Filter);
  FMqtt.Subscribe([Filter]);
  Log('Subscribed to ' + Filter);
end;

// <root>/2/e/<channel>/+ for each downlink channel, plus PKI (direct messages).
// An entry ending in /# is subscribed as-is (root + all sub-regions).
procedure TMeshBridge.SubscribeRoot(const Root: string);
var
  Ch: TChannelInfo;
begin
  if Root.EndsWith('/#') then
  begin
    EnsureSubscribed(Root);
    Exit;
  end;
  for Ch in FClient.Channels do
    if (Ch.Role <> 0) and Ch.Downlink then
      EnsureSubscribed(Root + '/2/e/' + FClient.ChannelName(Ch.Index) + '/+');
  EnsureSubscribed(Root + '/2/e/PKI/+');
end;

procedure TMeshBridge.MqttConnected(Sender: TObject);
var
  T: string;
begin
  FReady := True;
  Log('Connected to MQTT server');
  SubscribeRoot(RootTopic);
  for T in FSettings.ExtraTopics do
    if not SameText(T, RootTopic) then
      SubscribeRoot(T);
  Changed;
end;

procedure TMeshBridge.MqttClosed(const Reason: string);
begin
  if FMqtt = nil then
    Exit;
  if Reason <> '' then
    Log('MQTT connection closed: ' + Reason)
  else
    Log('MQTT connection closed');
  FMqtt.Free;
  FMqtt := nil;
  FReady := False;
  FSubs.Clear;
  if FClient.InternetMode then
  begin
    FRetryAt := IncSecond(Now, 15);
    Log('Retrying in 15 seconds');
  end;
  Changed;
end;

function TMeshBridge.IsPrivateChannelTopic(const Chan: string): Boolean;
var
  C: TChannelInfo;
begin
  for C in FClient.Channels do
    if (C.Role = 2) and (C.Name <> '') and SameText(C.Name, Chan) then
      Exit(True);
  Result := False;
end;

procedure TMeshBridge.HandleProxy(const Msg: TMqttProxyMessage);
var
  Segs: TArray<string>;
  I: Integer;
  Prefix: string;
begin
  if (FMqtt = nil) or not FReady then
  begin
    Inc(Dropped);
    Changed;
    Exit;
  end;
  FMqtt.Publish(Msg.Topic, Msg.Data, Msg.Retained);
  Inc(Up);
  Log(Format('-> %s  (%d bytes)', [Msg.Topic, Length(Msg.Data)]));
  // learn the exact channel topic the radio uses and listen on it too
  Segs := Msg.Topic.Split(['/']);
  for I := 0 to High(Segs) - 2 do
    if (Segs[I] = '2') and (Segs[I + 1] = 'e') and (I + 2 < High(Segs)) then
    begin
      Prefix := string.Join('/', Copy(Segs, 0, I + 3));
      EnsureSubscribed(Prefix + '/+');
      Break;
    end;
  Changed;
end;

procedure TMeshBridge.MqttMessage(const Topic: string; const Payload: TBytes);
var
  Segs: TArray<string>;
  P: TMeshPacket;
  Gateway, Chan: string;
  IsExtra, IsText, IsFriend: Boolean;
  Plain: TBytes;
  D: TMeshData;
begin
  Segs := Topic.Split(['/']);
  if (Length(Segs) < 3) or (Pos('/2/e/', Topic) = 0) then
    Exit;                                     // only encrypted envelopes
  Gateway := Segs[High(Segs)];
  Chan := Segs[High(Segs) - 1];
  if SameText(Gateway, NodeIdStr(FClient.MyNodeNum)) then
    Exit;                                     // our own uplink echoed back
  if not DecodeServiceEnvelope(Payload, P) then
    Exit;
  if P.From = FClient.MyNodeNum then
    Exit;
  if not P.Encrypted and not P.HasDecoded then
    Exit;                                     // payload-less stub (most of the public feed)
  // Peek inside packets on the default-key channel: public chat text is rare
  // and always worth showing, unlike position/telemetry.
  IsText := False;
  if P.Encrypted and not SameText(Chan, 'PKI') and
    DecryptDefaultChannel(P.EncBytes, P.Id, P.From, Plain) then
  begin
    try
      D := DecodeData(Plain);
      IsText := D.PortNum = PORT_TEXT;
    except
      IsText := False;                        // another key: garbage that will not parse
    end;
    if IsText then
    begin
      Inc(Texts);
      if P.To_ = BROADCAST_ADDR then
        Gateway := 'everyone'
      else
        Gateway := NodeIdStr(P.To_);
      Log(Format('TEXT  %s -> %s  [%s]  %s', [NodeIdStr(P.From), Gateway, Topic,
        Utf8Text(D.Payload)]));
    end;
  end;
  IsFriend := FSettings.Friends.Contains(P.From) or IsPrivateChannelTopic(Chan);

  // Not for us: always skip other people's direct messages; skip channel
  // traffic on the busy root topic unless it is chat text, from a friend, on
  // one of our private channels, or "all traffic" is on. "Also listen to"
  // topics were picked on purpose, so their channel traffic comes in.
  IsExtra := not SameText(Copy(Topic, 1, Pos('/2/e/', Topic) - 1), FBridgeRoot);
  if (P.To_ <> FClient.MyNodeNum) and (SameText(Chan, 'PKI') or
    (not IsExtra and not IsText and not IsFriend and not ShowAll)) then
  begin
    Inc(Ignored);
    if Ignored mod 50 = 0 then
      Changed;
    Exit;
  end;
  if FDownThisSec >= 10 then
  begin
    Inc(Dropped);                             // protect the radio from floods
    Changed;
    Exit;
  end;
  Inc(FDownThisSec);
  if FClient.SendMqttToRadio(Topic, Payload, False) then
  begin
    Inc(Down);
    Log(Format('<- %s  from %s', [Topic, NodeIdStr(P.From)]));
  end
  else
    Inc(Dropped);
  Changed;
end;

end.
