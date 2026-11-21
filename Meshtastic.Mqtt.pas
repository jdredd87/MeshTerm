unit Meshtastic.Mqtt;

{ Minimal MQTT 3.1.1 client (QoS 0, plain TCP) on a background thread.
  Just enough to bridge a Meshtastic radio to an MQTT broker. }

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.DateUtils,
  System.Generics.Collections;

type
  TMqttMessageEvent = procedure(const Topic: string; const Payload: TBytes) of object;
  TMqttClosedEvent = procedure(const Reason: string) of object;

  TMqttClient = class(TThread)
  private
    FHost: string;
    FPort: Word;
    FClientId, FUser, FPass: string;
    FLock: TCriticalSection;
    FOut: TList<TBytes>;
    FPacketId: Word;
    FOnConnected: TNotifyEvent;
    FOnMessage: TMqttMessageEvent;
    FOnClosed: TMqttClosedEvent;
    procedure Enqueue(const Packet: TBytes);
    function NextPacketId: Word;
  protected
    procedure Execute; override;
  public
    constructor Create(const Host: string; Port: Word; const ClientId, User, Pass: string);
    destructor Destroy; override;
    procedure Publish(const Topic: string; const Payload: TBytes; Retain: Boolean = False);
    procedure Subscribe(const Topics: array of string);
    property OnConnected: TNotifyEvent read FOnConnected write FOnConnected;
    property OnMessage: TMqttMessageEvent read FOnMessage write FOnMessage;
    property OnClosed: TMqttClosedEvent read FOnClosed write FOnClosed;
  end;

implementation

uses
  IdGlobal, IdTCPClient, Meshtastic.Proto;

const
  MQTT_CONNECT = 1; MQTT_CONNACK = 2; MQTT_PUBLISH = 3; MQTT_PUBACK = 4;
  MQTT_SUBSCRIBE = 8; MQTT_SUBACK = 9; MQTT_PINGREQ = 12; MQTT_PINGRESP = 13;
  MQTT_DISCONNECT = 14;
  KEEP_ALIVE_SECS = 60;

type
  TByteBuilder = record
    Buf: TBytes;
    procedure Add(B: Byte);
    procedure AddWord(W: Word);
    procedure AddBytes(const B: TBytes);
    procedure AddStr(const S: string);   // 2-byte length + UTF-8
  end;

procedure TByteBuilder.Add(B: Byte);
begin
  SetLength(Buf, Length(Buf) + 1);
  Buf[High(Buf)] := B;
end;

procedure TByteBuilder.AddWord(W: Word);
begin
  Add(Byte(W shr 8));
  Add(Byte(W));
end;

procedure TByteBuilder.AddBytes(const B: TBytes);
var
  L: Integer;
begin
  L := Length(Buf);
  SetLength(Buf, L + Length(B));
  if Length(B) > 0 then
    Move(B[0], Buf[L], Length(B));
end;

procedure TByteBuilder.AddStr(const S: string);
var
  U: TBytes;
begin
  U := TEncoding.UTF8.GetBytes(S);
  AddWord(Length(U));
  AddBytes(U);
end;

// Wrap a variable header + payload in an MQTT fixed header.
function MakePacket(TypeAndFlags: Byte; const Body: TBytes): TBytes;
var
  B: TByteBuilder;
  Len: Integer;
  Digit: Byte;
begin
  B.Add(TypeAndFlags);
  Len := Length(Body);
  repeat
    Digit := Len mod 128;
    Len := Len div 128;
    if Len > 0 then
      Digit := Digit or $80;
    B.Add(Digit);
  until Len = 0;
  B.AddBytes(Body);
  Result := B.Buf;
end;

function ToId(const B: TBytes): TIdBytes;
begin
  SetLength(Result, Length(B));
  if Length(B) > 0 then
    Move(B[0], Result[0], Length(B));
end;

function FromId(const B: TIdBytes): TBytes;
begin
  SetLength(Result, Length(B));
  if Length(B) > 0 then
    Move(B[0], Result[0], Length(B));
end;

{ TMqttClient }

constructor TMqttClient.Create(const Host: string; Port: Word;
  const ClientId, User, Pass: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FHost := Host;
  FPort := Port;
  FClientId := ClientId;
  FUser := User;
  FPass := Pass;
  FLock := TCriticalSection.Create;
  FOut := TList<TBytes>.Create;
end;

destructor TMqttClient.Destroy;
begin
  Terminate;
  if not Suspended then
    WaitFor;
  TThread.RemoveQueuedEvents(Self);
  FOut.Free;
  FLock.Free;
  inherited;
end;

function TMqttClient.NextPacketId: Word;
begin
  FLock.Enter;
  try
    Inc(FPacketId);
    if FPacketId = 0 then
      FPacketId := 1;
    Result := FPacketId;
  finally
    FLock.Leave;
  end;
end;

procedure TMqttClient.Enqueue(const Packet: TBytes);
begin
  FLock.Enter;
  try
    FOut.Add(Packet);
  finally
    FLock.Leave;
  end;
end;

procedure TMqttClient.Publish(const Topic: string; const Payload: TBytes; Retain: Boolean);
var
  B: TByteBuilder;
begin
  B.AddStr(Topic);
  B.AddBytes(Payload);       // QoS 0: no packet identifier
  Enqueue(MakePacket((MQTT_PUBLISH shl 4) or Ord(Retain), B.Buf));
end;

procedure TMqttClient.Subscribe(const Topics: array of string);
var
  B: TByteBuilder;
  T: string;
begin
  if Length(Topics) = 0 then
    Exit;
  B.AddWord(NextPacketId);
  for T in Topics do
  begin
    B.AddStr(T);
    B.Add(0);                // requested QoS 0
  end;
  Enqueue(MakePacket((MQTT_SUBSCRIBE shl 4) or $02, B.Buf));
end;

procedure TMqttClient.Execute;
var
  TCP: TIdTCPClient;
  Reason: string;
  LastSend: TDateTime;

  procedure SendNow(const Packet: TBytes);
  begin
    TCP.IOHandler.Write(ToId(Packet));
    LastSend := Now;
  end;

  procedure ReadPacket(out PType, Flags: Byte; out Body: TBytes);
  var
    B: Byte;
    Len, Mult: Integer;
    Raw: TIdBytes;
  begin
    B := TCP.IOHandler.ReadByte;
    PType := B shr 4;
    Flags := B and $0F;
    Len := 0;
    Mult := 1;
    repeat
      B := TCP.IOHandler.ReadByte;
      Inc(Len, (B and $7F) * Mult);
      Mult := Mult * 128;
      if Mult > 128 * 128 * 128 * 128 then
        raise Exception.Create('Malformed MQTT packet length');
    until (B and $80) = 0;
    Body := nil;
    if Len > 0 then
    begin
      Raw := nil;
      TCP.IOHandler.ReadBytes(Raw, Len, False);
      Body := FromId(Raw);
    end;
  end;

  procedure HandlePublish(Flags: Byte; const Body: TBytes);
  var
    TLen, Pos: Integer;
    Topic: string;
    Payload: TBytes;
    QoS: Integer;
    Pid: Word;
    Handler: TMqttMessageEvent;
    Ack: TByteBuilder;
  begin
    if Length(Body) < 2 then Exit;
    TLen := (Body[0] shl 8) or Body[1];
    if 2 + TLen > Length(Body) then Exit;
    Topic := Utf8Text(Body, 2, TLen);
    Pos := 2 + TLen;
    QoS := (Flags shr 1) and 3;
    if QoS > 0 then
    begin
      if Pos + 2 > Length(Body) then Exit;
      Pid := (Body[Pos] shl 8) or Body[Pos + 1];
      Inc(Pos, 2);
      if QoS = 1 then
      begin
        Ack.AddWord(Pid);
        SendNow(MakePacket(MQTT_PUBACK shl 4, Ack.Buf));
      end;
    end;
    Payload := Copy(Body, Pos, Length(Body) - Pos);
    Handler := FOnMessage;
    if Assigned(Handler) then
      TThread.Queue(Self, procedure begin Handler(Topic, Payload); end);
  end;

  procedure FlushOut;
  var
    Pending: TArray<TBytes>;
    P: TBytes;
  begin
    FLock.Enter;
    try
      Pending := FOut.ToArray;
      FOut.Clear;
    finally
      FLock.Leave;
    end;
    for P in Pending do
      SendNow(P);
  end;

var
  PType, Flags: Byte;
  Body: TBytes;
  C: TByteBuilder;
  ConnFlags: Byte;
  Connected: TNotifyEvent;
  Closed: TMqttClosedEvent;
begin
  Reason := '';
  TCP := TIdTCPClient.Create(nil);
  try
    try
      TCP.Host := FHost;
      TCP.Port := FPort;
      TCP.ConnectTimeout := 10000;
      TCP.ReadTimeout := 15000;
      TCP.Connect;

      // CONNECT
      ConnFlags := $02;                     // clean session
      if FUser <> '' then ConnFlags := ConnFlags or $80;
      if FPass <> '' then ConnFlags := ConnFlags or $40;
      C.AddStr('MQTT');
      C.Add(4);                             // protocol level 3.1.1
      C.Add(ConnFlags);
      C.AddWord(KEEP_ALIVE_SECS);
      C.AddStr(FClientId);
      if FUser <> '' then C.AddStr(FUser);
      if FPass <> '' then C.AddStr(FPass);
      SendNow(MakePacket(MQTT_CONNECT shl 4, C.Buf));

      ReadPacket(PType, Flags, Body);
      if (PType <> MQTT_CONNACK) or (Length(Body) < 2) then
        raise Exception.Create('Broker did not answer the MQTT handshake');
      if Body[1] <> 0 then
        raise Exception.CreateFmt('Broker refused the connection (code %d)', [Body[1]]);

      Connected := FOnConnected;
      if Assigned(Connected) then
        TThread.Queue(Self, procedure begin Connected(Self); end);

      while not Terminated do
      begin
        FlushOut;
        if TCP.IOHandler.InputBufferIsEmpty then
        begin
          TCP.IOHandler.CheckForDataOnSource(50);
          TCP.IOHandler.CheckForDisconnect(True, True);
        end;
        while (not Terminated) and not TCP.IOHandler.InputBufferIsEmpty do
        begin
          ReadPacket(PType, Flags, Body);
          if PType = MQTT_PUBLISH then
            HandlePublish(Flags, Body);
          // CONNACK/SUBACK/PINGRESP/PUBACK need no action
        end;
        if SecondsBetween(Now, LastSend) >= KEEP_ALIVE_SECS div 2 then
          SendNow(MakePacket(MQTT_PINGREQ shl 4, nil));
      end;

      try
        SendNow(MakePacket(MQTT_DISCONNECT shl 4, nil));
        TCP.Disconnect;
      except
      end;
    except
      on E: Exception do
        Reason := E.Message;
    end;
  finally
    TCP.Free;
  end;
  Closed := FOnClosed;
  if Assigned(Closed) then
    TThread.Queue(Self, procedure begin Closed(Reason); end);
end;

end.
