unit Meshtastic.Client;

{ High-level Meshtastic client: owns the serial thread, performs the
  want_config handshake, keeps a node database and raises UI-friendly events. }

interface

uses
  System.SysUtils, System.Classes, System.DateUtils, System.Generics.Collections,
  System.IniFiles, System.IOUtils, Meshtastic.Proto, Meshtastic.Transport;

type
  TMeshState = (msDisconnected, msConnecting, msReady);

  TMeshLogEvent = procedure(Sender: TObject; const Line: string) of object;
  TMeshNodeEvent = procedure(Sender: TObject; const Node: TNodeInfo) of object;
  TMeshTextEvent = procedure(Sender: TObject; const Packet: TMeshPacket;
    const Text: string) of object;
  TMeshAckEvent = procedure(Sender: TObject; PacketId: Cardinal;
    ErrorCode: Integer; FromNode: Cardinal) of object;
  TMeshMqttEvent = procedure(Sender: TObject; const Msg: TMqttProxyMessage) of object;
  // builds one admin message once the session passkey is known
  TAdminBuilder = reference to function(const Passkey: TBytes): TBytes;

  TMeshClient = class
  private
    FThread: TMeshTransport;      // serial or Bluetooth link
    FState: TMeshState;
    FConfigId: Cardinal;
    FMyNodeNum: Cardinal;
    FMyInfo: TMyInfo;
    FMetadata: TDeviceMetadata;
    FLoRa: TLoRaConfig;
    FMqtt: TMqttConfig;
    FPasskey: TBytes;
    FPendingMqtt: Integer;        // -1 none, 0 = switch to radio-only, 1 = switch to internet
    FRefreshAt: TDateTime;        // re-request config after a settings change
    FTimeState: Integer;          // 0 = clock not set yet, 1 = waiting for passkey, 2 = done
    FPendingRoot: string;         // MQTT root topic to write once we have the passkey
    FPendingOps: TList<TAdminBuilder>; // admin writes waiting for the passkey
    FPendingDirect: TList<TAdminBuilder>; // same, but sent outside an edit transaction
    FCheckPos: Integer;          // after a location change: 1 = expect one, 2 = expect none
    FNodes: TDictionary<Cardinal, TNodeInfo>;
    FChannels: TList<TChannelInfo>;
    FLastHeartbeat: TDateTime;
    FOnLog: TMeshLogEvent;
    FOnDeviceLog: TMeshLogEvent;
    FOnStateChange: TNotifyEvent;
    FOnNodeUpdated: TMeshNodeEvent;
    FOnText: TMeshTextEvent;
    FOnAck: TMeshAckEvent;
    FOnMqttProxy: TMeshMqttEvent;
    FOnConnectionLost: TMeshLogEvent;
    procedure ApplyMqttMode(Enable: Boolean);
    procedure SendAdmin(const Admin: TBytes);
    procedure FixNodeClock;
    procedure HandleFrame(const Payload: TBytes);
    procedure HandleLine(const Line: string);
    procedure HandleClosed(const Reason: string);
    procedure HandlePacket(const P: TMeshPacket);
    procedure SetState(S: TMeshState);
    procedure Log(const Fmt: string; const Args: array of const);
    procedure UpdateNode(const N: TNodeInfo);
    function TouchNode(Num: Cardinal): TNodeInfo;
    procedure FreeThread;
    procedure QueueAdmin(const Op: TAdminBuilder; InEditTransaction: Boolean = True);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Connect(const PortName: string);
    procedure Disconnect;
    procedure Tick; // call ~1/s from a UI timer: sends keep-alive heartbeats
    function SendText(const Text: string; Dest: Cardinal = BROADCAST_ADDR;
      Channel: Cardinal = 0): Cardinal;
    procedure SendDiscover;
    procedure SetInternetMode(Enable: Boolean);
    procedure SetMqttRoot(const Root: string);
    function SendMqttToRadio(const Topic: string; const Data: TBytes; Retained: Boolean): Boolean;
    function InternetMode: Boolean;
    function NodeName(Num: Cardinal): string;
    function ChannelName(Index: Integer): string;
    function FreeChannelIndex: Integer;   // first unused secondary slot, -1 if full
    procedure SetChannel(Index, Role: Integer; const SettingsRaw: TBytes);
    procedure SetFixedPosition(Lat, Lon: Double);
    procedure ClearFixedPosition;
    { Screenshots / demos: pretend to be connected to a radio with these nodes
      and channels (nothing is sent anywhere). }
    procedure LoadDemo(MyNum: Cardinal; const ANodes: TArray<TNodeInfo>;
      const AChannels: TArray<TChannelInfo>; const ALoRa: TLoRaConfig;
      const AMeta: TDeviceMetadata);
    property State: TMeshState read FState;
    property MyNodeNum: Cardinal read FMyNodeNum;
    property MyInfo: TMyInfo read FMyInfo;
    property Metadata: TDeviceMetadata read FMetadata;
    property LoRa: TLoRaConfig read FLoRa;
    property Mqtt: TMqttConfig read FMqtt;
    property Nodes: TDictionary<Cardinal, TNodeInfo> read FNodes;
    property Channels: TList<TChannelInfo> read FChannels;
    property OnLog: TMeshLogEvent read FOnLog write FOnLog;
    property OnDeviceLog: TMeshLogEvent read FOnDeviceLog write FOnDeviceLog;
    property OnStateChange: TNotifyEvent read FOnStateChange write FOnStateChange;
    property OnNodeUpdated: TMeshNodeEvent read FOnNodeUpdated write FOnNodeUpdated;
    property OnText: TMeshTextEvent read FOnText write FOnText;
    property OnAck: TMeshAckEvent read FOnAck write FOnAck;
    property OnMqttProxy: TMeshMqttEvent read FOnMqttProxy write FOnMqttProxy;
    // fired when the serial link drops unexpectedly (unplug, radio reboot)
    property OnConnectionLost: TMeshLogEvent read FOnConnectionLost write FOnConnectionLost;
  end;

implementation

function RandomId: Cardinal;
begin
  repeat
    Result := (Cardinal(Random($10000)) shl 16) or Cardinal(Random($10000));
  until Result > 100000; // avoid 0 and the firmware's special config nonces
end;

{ TMeshClient }

constructor TMeshClient.Create;
begin
  inherited;
  FNodes := TDictionary<Cardinal, TNodeInfo>.Create;
  FChannels := TList<TChannelInfo>.Create;
  FPendingOps := TList<TAdminBuilder>.Create;
  FPendingDirect := TList<TAdminBuilder>.Create;
  FPendingMqtt := -1;
end;

destructor TMeshClient.Destroy;
begin
  FOnStateChange := nil;
  Disconnect;
  FChannels.Free;
  FPendingOps.Free;
  FPendingDirect.Free;
  FNodes.Free;
  inherited;
end;

procedure TMeshClient.Log(const Fmt: string; const Args: array of const);
begin
  if Assigned(FOnLog) then
    FOnLog(Self, Format(Fmt, Args));
end;

procedure TMeshClient.SetState(S: TMeshState);
begin
  if FState <> S then
  begin
    FState := S;
    if Assigned(FOnStateChange) then
      FOnStateChange(Self);
  end;
end;

procedure TMeshClient.FreeThread;
var
  T: TMeshTransport;
begin
  T := FThread;
  FThread := nil;
  if T <> nil then
  begin
    T.OnFrame := nil;
    T.OnLine := nil;
    T.OnClosed := nil;
    T.Free;            // stops it; nothing it queued is delivered afterwards
  end;
end;

procedure TMeshClient.Connect(const PortName: string);
begin
  Disconnect;
  FNodes.Clear;
  FChannels.Clear;
  FMyNodeNum := 0;
  FMyInfo := Default(TMyInfo);
  FMetadata := Default(TDeviceMetadata);
  FLoRa := Default(TLoRaConfig);
  FMqtt := Default(TMqttConfig);
  FPasskey := nil;
  FPendingMqtt := -1;
  FRefreshAt := 0;
  FTimeState := 0;
  FPendingRoot := '';
  FPendingOps.Clear;
  FPendingDirect.Clear;

  FThread := CreateTransport(PortName);
  FThread.OnFrame := HandleFrame;
  FThread.OnLine := HandleLine;
  FThread.OnClosed := HandleClosed;
  SetState(msConnecting);
  Log('Opening %s ...', [PortName]);
  FThread.Start;

  // Request the full config/node DB (a serial link first wakes the radio).
  FConfigId := RandomId;
  FThread.SendPayload(EncodeWantConfig(FConfigId));
  FLastHeartbeat := Now;
end;

procedure TMeshClient.Disconnect;
begin
  if FThread <> nil then
  begin
    try
      FThread.SendPayload(EncodeDisconnect);
    except
    end;
    FreeThread;
    Log('Disconnected', []);
  end;
  SetState(msDisconnected);
end;

procedure TMeshClient.Tick;
begin
  // The firmware drops an API client that is silent for too long.
  if (FThread <> nil) and (SecondsBetween(Now, FLastHeartbeat) >= 60) then
  begin
    FThread.SendPayload(EncodeHeartbeat);
    FLastHeartbeat := Now;
  end;
  if (FRefreshAt <> 0) and (Now >= FRefreshAt) then
  begin
    FRefreshAt := 0;
    if FThread <> nil then
    begin
      // The radio applied the change without rebooting: reload its config.
      Log('Reloading radio settings', []);
      FChannels.Clear;
      SetState(msConnecting);
      FConfigId := RandomId;
      FThread.SendPayload(EncodeWantConfig(FConfigId));
    end;
  end;
end;

procedure TMeshClient.HandleClosed(const Reason: string);
begin
  if FThread = nil then
    Exit;
  if Reason <> '' then
    Log('Connection closed: %s', [Reason]);
  FreeThread;
  FRefreshAt := 0;
  SetState(msDisconnected);
  if Assigned(FOnConnectionLost) then
    FOnConnectionLost(Self, Reason);
end;

procedure TMeshClient.HandleLine(const Line: string);
begin
  if Assigned(FOnDeviceLog) then
    FOnDeviceLog(Self, Line);
end;

function TMeshClient.TouchNode(Num: Cardinal): TNodeInfo;
begin
  if not FNodes.TryGetValue(Num, Result) then
  begin
    Result := Default(TNodeInfo);
    Result.Num := Num;
    Result.HopsAway := -1;
  end;
end;

procedure TMeshClient.UpdateNode(const N: TNodeInfo);
begin
  FNodes.AddOrSetValue(N.Num, N);
  if Assigned(FOnNodeUpdated) then
    FOnNodeUpdated(Self, N);
end;

{ The radio has no GPS/RTC, so until its clock is set it counts from the
  firmware build date and stamps "last heard" with that wrong time. Our own
  entry is stamped with the radio's "now", which tells us how far off it is;
  shift the other entries by the same amount. Entries that would land in the
  future were stamped while the clock was right (before a reboot): keep them. }
{ Once we set the radio's clock, entries it stamped earlier stay wrong in its
  saved node list. So remember, per radio, how far off the clock was and the
  (wrong) radio time we last saw: on later connects, stamps at or before that
  point still get shifted. Stored in %APPDATA%\MeshTerm\MeshTerm.ini. }
procedure TMeshClient.FixNodeClock;
var
  Me, N: TNodeInfo;
  PcNow, Skew, Boundary, Fixed: Int64;
  ClockWrong: Boolean;
  All: TArray<TNodeInfo>;
  Ini: TIniFile;
  Dir, Section: string;
begin
  PcNow := DateTimeToUnix(Now, False);
  if not FNodes.TryGetValue(FMyNodeNum, Me) or (Me.LastHeard = 0) then
    Exit;
  Dir := TPath.Combine(TPath.GetHomePath, 'MeshTerm');
  Section := 'Clock ' + NodeIdStr(FMyNodeNum);
  Skew := PcNow - Int64(Me.LastHeard);
  ClockWrong := Abs(Skew) >= 3600;
  try
    ForceDirectories(Dir);
    Ini := TIniFile.Create(TPath.Combine(Dir, 'MeshTerm.ini'));
    try
      Boundary := StrToInt64Def(Ini.ReadString(Section, 'Boundary', ''), 0);
      if ClockWrong then
      begin
        if Int64(Me.LastHeard) > Boundary then
          Boundary := Me.LastHeard;
        Ini.WriteString(Section, 'Skew', IntToStr(Skew));
        Ini.WriteString(Section, 'Boundary', IntToStr(Boundary));
      end
      else
        Skew := StrToInt64Def(Ini.ReadString(Section, 'Skew', ''), 0);
    finally
      Ini.Free;
    end;
  except
    if not ClockWrong then
      Exit;                                 // no saved info: nothing to fix
    Boundary := Me.LastHeard;
  end;
  if Skew = 0 then
    Exit;
  if ClockWrong then
    Log('Radio clock is off by %d days: correcting "last heard" times', [Skew div 86400]);
  All := FNodes.Values.ToArray;
  for N in All do
  begin
    if (N.LastHeard = 0) or (N.Num = FMyNodeNum) then
      Continue;
    // with the clock now right, only stamps from before it was set are wrong
    if not ClockWrong and (Int64(N.LastHeard) > Boundary + 600) then
      Continue;
    Fixed := Int64(N.LastHeard) + Skew;
    if Fixed > PcNow + 3600 then
      Continue;
    if Fixed > PcNow then
      Fixed := PcNow;
    var C := N;
    C.LastHeard := Cardinal(Fixed);
    UpdateNode(C);
  end;
end;

procedure TMeshClient.HandleFrame(const Payload: TBytes);
var
  M: TFromRadio;
  Ch: TChannelInfo;
  I: Integer;
begin
  try
    M := DecodeFromRadio(Payload);
  except
    on E: Exception do
    begin
      Log('Bad frame (%d bytes): %s', [Length(Payload), E.Message]);
      Exit;
    end;
  end;

  case M.Kind of
    frMyInfo:
      begin
        FMyInfo := M.MyInfo;
        FMyNodeNum := M.MyInfo.MyNodeNum;
        Log('My node: %s (%s)', [NodeIdStr(FMyNodeNum), M.MyInfo.PioEnv]);
      end;
    frNodeInfo:
      UpdateNode(M.NodeInfo);
    frChannel:
      if M.Channel.Role <> 0 then
      begin
        Ch := M.Channel;
        for I := 0 to FChannels.Count - 1 do
          if FChannels[I].Index = Ch.Index then
          begin
            FChannels[I] := Ch;
            Ch.Index := -1;
            Break;
          end;
        if Ch.Index >= 0 then
          FChannels.Add(Ch);
      end;
    frConfig:
      if M.LoRa.Valid then
      begin
        FLoRa := M.LoRa;
        Log('LoRa: region=%s preset=%s hops=%d tx=%s', [RegionName(FLoRa.Region),
          ModemPresetName(FLoRa.ModemPreset), FLoRa.HopLimit,
          BoolToStr(FLoRa.TxEnabled, True)]);
        if FLoRa.Region = 0 then
          Log('WARNING: LoRa region is UNSET - the radio will not transmit.', []);
      end;
    frMetadata:
      begin
        FMetadata := M.Metadata;
        Log('Firmware %s on %s', [FMetadata.FirmwareVersion, HwModelName(FMetadata.HwModel)]);
      end;
    frConfigComplete:
      if M.ConfigCompleteId = FConfigId then
      begin
        Log('Config complete: %d nodes, %d channels', [FNodes.Count, FChannels.Count]);
        FixNodeClock;
        if FCheckPos <> 0 then
        begin
          var Me: TNodeInfo;
          var Has := FNodes.TryGetValue(FMyNodeNum, Me) and Me.Position.Valid;
          if (FCheckPos = 1) and Has then
            Log('The radio saved its location.', [])
          else if FCheckPos = 1 then
            Log('PROBLEM: the radio did not keep the location. Try setting it again.', [])
          else if not Has then
            Log('The radio''s location was removed.', []);
          FCheckPos := 0;
        end;
        SetState(msReady);
        if FTimeState = 0 then
        begin
          // Set the radio's clock from the PC (it has no GPS/RTC). Admin writes
          // need the session passkey, which comes back with this harmless request.
          FTimeState := 1;
          SendAdmin(AdminGetMetadata);
        end;
      end;
    frRebooted:
      begin
        Log('Radio rebooted - re-requesting config', []);
        SetState(msConnecting);
        FConfigId := RandomId;
        FThread.SendPayload(EncodeWantConfig(FConfigId));
      end;
    frLogRecord:
      HandleLine(M.Text);
    frClientNotification:
      Log('Radio says: %s', [M.Text]);
    frModuleConfig:
      if M.Mqtt.Valid then
        FMqtt := M.Mqtt;
    frMqttProxy:
      if Assigned(FOnMqttProxy) then
        FOnMqttProxy(Self, M.MqttProxy);
    frQueueStatus:
      if M.Queue.Res = 33 then
        Log('SEND FAILED: the radio has no working LoRa interface. Unplug and replug ' +
          'the radio (it only starts the LoRa chip at boot, e.g. after a region change).', [])
      else if M.Queue.Res <> 0 then
        Log('TX queue error %d (free %d/%d)', [M.Queue.Res, M.Queue.Free, M.Queue.MaxLen]);
    frPacket:
      try
        HandlePacket(M.Packet);
      except
        on E: Exception do      // a malformed payload must not stop the session
          Log('Bad packet from %s (port %d): %s', [NodeIdStr(M.Packet.From),
            M.Packet.Decoded.PortNum, E.Message]);
      end;
  end;
end;

procedure TMeshClient.HandlePacket(const P: TMeshPacket);
var
  N: TNodeInfo;
  Text: string;
  Err: Integer;
  M: TDeviceMetrics;
  Key: TBytes;
begin
  // Everything we hear refreshes "last heard" / signal for the sender.
  if P.From <> FMyNodeNum then
  begin
    N := TouchNode(P.From);
    // We are hearing it right now: use the PC clock. P.RxTime comes from the
    // radio's clock, which is wrong until it has been set (no GPS/RTC).
    N.LastHeard := DateTimeToUnix(Now, False);
    if P.RxSnr <> 0 then N.Snr := P.RxSnr;
    if P.RxRssi <> 0 then N.Rssi := P.RxRssi;
    if (P.HopStart > 0) and (P.HopStart >= P.HopLimit) then
      N.HopsAway := P.HopStart - P.HopLimit;
    N.ViaMqtt := P.ViaMqtt;
  end
  else
    N := TouchNode(P.From);

  if not P.HasDecoded then
  begin
    if P.From <> FMyNodeNum then UpdateNode(N);
    Log('Encrypted packet from %s (not on our channels)', [NodeName(P.From)]);
    Exit;
  end;

  case P.Decoded.PortNum of
    PORT_TEXT:
      begin
        Text := Utf8Text(P.Decoded.Payload);
        if P.From <> FMyNodeNum then UpdateNode(N);
        if Assigned(FOnText) then
          FOnText(Self, P, Text);
      end;
    PORT_NODEINFO:
      begin
        N.UserRaw := P.Decoded.Payload;
        N.User := DecodeUser(N.UserRaw);
        N.HasUser := True;
        UpdateNode(N);
        Log('Node info: %s = %s (%s)', [NodeIdStr(P.From), N.User.LongName,
          HwModelName(N.User.HwModel)]);
      end;
    PORT_POSITION:
      begin
        N.Position := DecodePosition(P.Decoded.Payload);
        UpdateNode(N);
      end;
    PORT_TELEMETRY:
      begin
        if DecodeTelemetry(P.Decoded.Payload, M) then
          N.Metrics := M;
        UpdateNode(N);
      end;
    PORT_ADMIN:
      if P.From = FMyNodeNum then
      begin
        Key := DecodeAdminPasskey(P.Decoded.Payload);
        if Length(Key) > 0 then
          FPasskey := Key;
        if FTimeState = 1 then
        begin
          FTimeState := 2;
          SendAdmin(AdminSetTime(FPasskey, DateTimeToUnix(Now, False)));
          Log('Set radio clock to PC time (%s UTC)',
            [FormatDateTime('yyyy-mm-dd hh:nn:ss', TTimeZone.Local.ToUniversalTime(Now))]);
        end;
        if FPendingMqtt >= 0 then
        begin
          ApplyMqttMode(FPendingMqtt = 1);
          FPendingMqtt := -1;
        end;
        if FPendingRoot <> '' then
        begin
          SendAdmin(AdminBeginEdit(FPasskey));
          SendAdmin(AdminSetMqttRoot(FPasskey, FMqtt, FPendingRoot));
          SendAdmin(AdminCommitEdit(FPasskey));
          Log('Radio MQTT root topic set to "%s". Saving...', [FPendingRoot]);
          FPendingRoot := '';
          FRefreshAt := IncSecond(Now, 6);   // reload settings if it does not reboot
        end;
        // set/remove fixed position: on their own, not inside begin/commit
        // edit. The commit saves settings and reboots but does not save the
        // node database, where the radio keeps the position, so it was lost.
        // Sent alone, the radio saves it straight away (no reboot).
        if FPendingDirect.Count > 0 then
        begin
          for var Op in FPendingDirect do
            SendAdmin(Op(FPasskey));
          FPendingDirect.Clear;
          FRefreshAt := IncSecond(Now, 3);   // reload to confirm what the radio kept
        end;
        if FPendingOps.Count > 0 then
        begin
          SendAdmin(AdminBeginEdit(FPasskey));
          for var Op in FPendingOps do
            SendAdmin(Op(FPasskey));
          SendAdmin(AdminCommitEdit(FPasskey));
          FPendingOps.Clear;
          FRefreshAt := IncSecond(Now, 3);   // reload channels / position
        end;
      end;
    PORT_ROUTING:
      begin
        if P.From <> FMyNodeNum then UpdateNode(N);
        Err := DecodeRoutingError(P.Decoded.Payload);
        if (Err >= 0) and (P.Decoded.RequestId <> 0) and Assigned(FOnAck) then
          FOnAck(Self, P.Decoded.RequestId, Err, P.From);
      end;
  else
    if P.From <> FMyNodeNum then UpdateNode(N);
    Log('%s packet from %s', [PortNumName(P.Decoded.PortNum), NodeName(P.From)]);
  end;
end;

function TMeshClient.SendText(const Text: string; Dest, Channel: Cardinal): Cardinal;
begin
  if FState <> msReady then
    raise Exception.Create('Not connected to a radio');
  if Length(TEncoding.UTF8.GetBytes(Text)) > MAX_TEXT_BYTES then
    raise Exception.CreateFmt('Message too long (max %d bytes)', [MAX_TEXT_BYTES]);
  Result := RandomId;
  FThread.SendPayload(EncodeTextMessage(Dest, Channel, Result, Text, True));
end;

procedure TMeshClient.SendDiscover;
var
  Me: TNodeInfo;
begin
  if FState <> msReady then
    raise Exception.Create('Not connected to a radio');
  if not FNodes.TryGetValue(FMyNodeNum, Me) or (Length(Me.UserRaw) = 0) then
    raise Exception.Create('Radio has not reported its own node info yet');
  FThread.SendPayload(EncodeNodeInfoRequest(RandomId, Me.UserRaw));
  Log('Discover: broadcast our node info asking nearby nodes to reply', []);
end;

procedure TMeshClient.SendAdmin(const Admin: TBytes);
begin
  FThread.SendPayload(EncodeAdminPacket(FMyNodeNum, RandomId, Admin));
end;

function TMeshClient.InternetMode: Boolean;
begin
  Result := FMqtt.Valid and FMqtt.Enabled and FMqtt.ProxyToClient;
end;

procedure TMeshClient.SetInternetMode(Enable: Boolean);
begin
  if FState <> msReady then
    raise Exception.Create('Not connected to a radio');
  if not FMqtt.Valid or not FLoRa.Valid then
    raise Exception.Create('Radio has not reported its settings yet');
  // Admin changes need a session passkey: ask for something harmless first,
  // the reply carries the key, then ApplyMqttMode runs (see PORT_ADMIN).
  FPendingMqtt := Ord(Enable);
  SendAdmin(AdminGetMetadata);
  Log('Requesting admin session from radio...', []);
end;

procedure TMeshClient.SetMqttRoot(const Root: string);
begin
  if FState <> msReady then
    raise Exception.Create('Not connected to a radio');
  if not FMqtt.Valid then
    raise Exception.Create('Radio has not reported its MQTT settings yet');
  FPendingRoot := Root;
  SendAdmin(AdminGetMetadata);           // reply carries the passkey (see PORT_ADMIN)
  Log('Requesting admin session from radio...', []);
end;

procedure TMeshClient.ApplyMqttMode(Enable: Boolean);
var
  Ch: TChannelInfo;
begin
  if FThread = nil then
    Exit;
  SendAdmin(AdminBeginEdit(FPasskey));
  SendAdmin(AdminSetMqtt(FPasskey, FMqtt, Enable));
  for Ch in FChannels do
    if Ch.Role <> 0 then
      SendAdmin(AdminSetChannelMqtt(FPasskey, Ch, Enable));
  SendAdmin(AdminSetLoRaOkToMqtt(FPasskey, FLoRa, Enable));
  SendAdmin(AdminCommitEdit(FPasskey));
  if Enable then
    Log('Radio set to Radio + Internet (MQTT proxy, channel uplink/downlink, OK-to-MQTT). Saving...', [])
  else
    Log('Radio set to Radio only (MQTT off, channel uplink/downlink off). Saving...', []);
  // The radio may reboot to apply this; if it does not, reload settings.
  FRefreshAt := IncSecond(Now, 6);
end;

function TMeshClient.SendMqttToRadio(const Topic: string; const Data: TBytes;
  Retained: Boolean): Boolean;
var
  Payload: TBytes;
begin
  Result := False;
  if (FThread = nil) or (FState <> msReady) then
    Exit;
  Payload := EncodeMqttProxyToRadio(Topic, Data, Retained);
  if Length(Payload) > 512 then
    Exit;                                // too big for one serial frame
  FThread.SendPayload(Payload);
  Result := True;
end;

function TMeshClient.NodeName(Num: Cardinal): string;
var
  N: TNodeInfo;
begin
  if Num = BROADCAST_ADDR then
    Exit('Everyone');
  if FNodes.TryGetValue(Num, N) and N.HasUser and (N.User.LongName <> '') then
    Result := N.User.LongName
  else
    Result := NodeIdStr(Num);
end;

procedure TMeshClient.QueueAdmin(const Op: TAdminBuilder; InEditTransaction: Boolean);
begin
  if FState <> msReady then
    raise Exception.Create('Not connected to a radio');
  if InEditTransaction then
    FPendingOps.Add(Op)
  else
    FPendingDirect.Add(Op);
  SendAdmin(AdminGetMetadata);           // reply carries the passkey (see PORT_ADMIN)
end;

function TMeshClient.FreeChannelIndex: Integer;
var
  I: Integer;
  Used: Boolean;
  C: TChannelInfo;
begin
  for I := 1 to 7 do
  begin
    Used := False;
    for C in FChannels do
      if (C.Index = I) and (C.Role <> 0) then
        Used := True;
    if not Used then
      Exit(I);
  end;
  Result := -1;
end;

procedure TMeshClient.SetChannel(Index, Role: Integer; const SettingsRaw: TBytes);
var
  Idx, R: Integer;
  Raw: TBytes;
begin
  Idx := Index;
  R := Role;
  Raw := Copy(SettingsRaw);
  QueueAdmin(function(const Key: TBytes): TBytes
    begin
      Result := AdminSetChannel(Key, Idx, R, Raw);
    end);
  if Role = 0 then
    Log('Removing channel %d...', [Index])
  else
    Log('Writing channel %d to the radio...', [Index]);
end;

procedure TMeshClient.SetFixedPosition(Lat, Lon: Double);
var
  La, Lo: Double;
  N: TNodeInfo;
begin
  La := Lat;
  Lo := Lon;
  QueueAdmin(function(const Key: TBytes): TBytes
    begin
      Result := AdminSetFixedPosition(Key, La, Lo);
    end, False);
  N := TouchNode(FMyNodeNum);
  N.Position.Valid := True;
  N.Position.Lat := Lat;
  N.Position.Lon := Lon;
  UpdateNode(N);
  FCheckPos := 1;
  Log('Setting this radio''s fixed location to %.5f, %.5f', [Lat, Lon]);
end;

procedure TMeshClient.ClearFixedPosition;
var
  N: TNodeInfo;
begin
  QueueAdmin(function(const Key: TBytes): TBytes
    begin
      Result := AdminRemoveFixedPosition(Key);
    end, False);
  N := TouchNode(FMyNodeNum);
  N.Position := Default(TMeshPosition);
  UpdateNode(N);
  FCheckPos := 2;
  Log('Removing this radio''s fixed location', []);
end;

procedure TMeshClient.LoadDemo(MyNum: Cardinal; const ANodes: TArray<TNodeInfo>;
  const AChannels: TArray<TChannelInfo>; const ALoRa: TLoRaConfig; const AMeta: TDeviceMetadata);
var
  N: TNodeInfo;
  C: TChannelInfo;
begin
  Disconnect;
  FNodes.Clear;
  FChannels.Clear;
  FMyNodeNum := MyNum;
  FLoRa := ALoRa;
  FMetadata := AMeta;
  FMqtt := Default(TMqttConfig);
  FMqtt.Valid := True;
  for C in AChannels do
    FChannels.Add(C);
  for N in ANodes do
    FNodes.AddOrSetValue(N.Num, N);
  SetState(msReady);
  for N in ANodes do
    if Assigned(FOnNodeUpdated) then
      FOnNodeUpdated(Self, N);
end;

function TMeshClient.ChannelName(Index: Integer): string;
var
  C: TChannelInfo;
begin
  for C in FChannels do
    if C.Index = Index then
    begin
      if C.Name <> '' then
        Exit(C.Name)
      else if C.Role = 1 then
        Exit(ChannelDisplayName(FLoRa.ModemPreset)); // default primary channel
    end;
  Result := 'Ch ' + IntToStr(Index);
end;

end.
