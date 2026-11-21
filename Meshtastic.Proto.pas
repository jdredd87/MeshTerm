unit Meshtastic.Proto;

{ Minimal hand-written protobuf codec for the subset of the Meshtastic
  serial API (meshtastic/protobufs, firmware 2.6) that MeshTerm needs.
  Field numbers were taken from the official generated descriptors. }

interface

uses
  System.SysUtils;

const
  BROADCAST_ADDR = $FFFFFFFF;

  // PortNum
  PORT_TEXT       = 1;
  PORT_POSITION   = 3;
  PORT_NODEINFO   = 4;
  PORT_ROUTING    = 5;
  PORT_ADMIN      = 6;
  PORT_TELEMETRY  = 67;
  PORT_TRACEROUTE = 70;

  MAX_TEXT_BYTES = 200; // firmware limit is ~233 bytes of payload

type
  EPbError = class(Exception);

  TPbReader = record
  private
    FData: TBytes;
    FPos: Integer;
    procedure Need(N: Integer);
  public
    class function Create(const AData: TBytes): TPbReader; static;
    function Eof: Boolean;
    function ReadTag(out Field, WireType: Integer): Boolean;
    function ReadVarint: UInt64;
    function ReadInt32: Integer;   // protobuf int32 (sign-extended varint)
    function ReadFixed32: Cardinal;
    function ReadFloat: Single;
    function ReadBytes: TBytes;
    function ReadString: string;
    procedure Skip(WireType: Integer);
  end;

  TPbWriter = record
  private
    FBuf: TBytes;
    FLen: Integer;
    procedure Put(B: Byte);
    procedure PutVarint(V: UInt64);
    procedure PutTag(Field, WireType: Integer);
  public
    class function Create: TPbWriter; static;
    procedure WriteVarint(Field: Integer; V: UInt64);
    procedure WriteBool(Field: Integer; V: Boolean);
    procedure WriteFixed32(Field: Integer; V: Cardinal);
    procedure WriteBytes(Field: Integer; const V: TBytes);
    procedure WriteString(Field: Integer; const V: string);
    function ToBytes: TBytes;
  end;

  TMeshUser = record
    Id, LongName, ShortName: string;
    HwModel: Integer;
    Role: Integer;
  end;

  TMeshPosition = record
    Valid: Boolean;
    Lat, Lon: Double;
    Altitude: Integer;
  end;

  TDeviceMetrics = record
    Valid: Boolean;
    BatteryLevel: Integer;   // 0-100, 101 = powered externally
    Voltage, ChannelUtil, AirUtilTx: Single;
    Uptime: Cardinal;
  end;

  TNodeInfo = record
    Num: Cardinal;
    HasUser: Boolean;
    User: TMeshUser;
    UserRaw: TBytes;         // the encoded User message, as received
    Position: TMeshPosition;
    Metrics: TDeviceMetrics;
    Snr: Single;
    Rssi: Integer;           // only known from packets we receive live
    LastHeard: Cardinal;     // unix time
    HopsAway: Integer;       // -1 = unknown
    ViaMqtt: Boolean;
  end;

  TMeshData = record
    PortNum: Integer;
    Payload: TBytes;
    RequestId, ReplyId, Emoji: Cardinal;
  end;

  TMeshPacket = record
    From, To_: Cardinal;
    Channel: Cardinal;
    Id: Cardinal;
    HasDecoded: Boolean;
    Decoded: TMeshData;
    Encrypted: Boolean;      // we could not decrypt it (other channel key)
    EncBytes: TBytes;        // the encrypted payload, when Encrypted
    RxTime: Cardinal;
    RxSnr: Single;
    RxRssi: Integer;
    HopLimit, HopStart: Cardinal;
    WantAck, ViaMqtt: Boolean;
  end;

  TMyInfo = record
    MyNodeNum: Cardinal;
    RebootCount: Cardinal;
    PioEnv: string;
  end;

  TChannelInfo = record
    Index: Integer;
    Role: Integer;           // 0 disabled, 1 primary, 2 secondary
    Name: string;
    Uplink, Downlink: Boolean; // MQTT uplink/downlink enabled
    Psk: TBytes;             // empty = no encryption, 1 byte = built-in key index, 16/32 = own key
    PositionPrecision: Integer; // bits of location shared on this channel (0 = none, 32 = exact)
    SettingsRaw: TBytes;     // encoded ChannelSettings, as received
  end;

  // One channel from a meshtastic.org/e/#... share link
  TSharedChannel = record
    Name: string;
    Psk: TBytes;
    Raw: TBytes;             // encoded ChannelSettings
  end;

  TLoRaConfig = record
    Valid: Boolean;
    Region: Integer;
    ModemPreset: Integer;
    UsePreset: Boolean;
    HopLimit: Integer;
    TxEnabled: Boolean;
    TxPower: Integer;
    OkToMqtt: Boolean;
    Raw: TBytes;             // encoded LoRaConfig, as received
  end;

  TMqttConfig = record
    Valid: Boolean;
    Enabled: Boolean;
    Address, Username, Password, Root: string;
    EncryptionEnabled, TlsEnabled: Boolean;
    ProxyToClient, MapReporting: Boolean;
    Raw: TBytes;             // encoded MQTTConfig, as received
  end;

  TMqttProxyMessage = record
    Topic: string;
    Data: TBytes;            // binary payload, or the UTF-8 of "text"
    Retained: Boolean;
  end;

  TDeviceMetadata = record
    FirmwareVersion: string;
    HwModel: Integer;
    Role: Integer;
  end;

  TQueueStatus = record
    Res: Integer;
    Free, MaxLen, MeshPacketId: Cardinal;
  end;

  TFromRadioKind = (frUnknown, frPacket, frMyInfo, frNodeInfo, frConfig,
    frLogRecord, frConfigComplete, frRebooted, frModuleConfig, frChannel,
    frQueueStatus, frMetadata, frClientNotification, frMqttProxy, frOther);

  TFromRadio = record
    Kind: TFromRadioKind;
    Packet: TMeshPacket;
    MyInfo: TMyInfo;
    NodeInfo: TNodeInfo;
    Channel: TChannelInfo;
    LoRa: TLoRaConfig;
    Mqtt: TMqttConfig;
    MqttProxy: TMqttProxyMessage;
    Metadata: TDeviceMetadata;
    Queue: TQueueStatus;
    Text: string;            // log record / client notification text
    ConfigCompleteId: Cardinal;
  end;

function DecodeFromRadio(const Data: TBytes): TFromRadio;
function DecodeUser(const Data: TBytes): TMeshUser;
function DecodePosition(const Data: TBytes): TMeshPosition;
function DecodeTelemetry(const Data: TBytes; out M: TDeviceMetrics): Boolean;
function DecodeRoutingError(const Data: TBytes): Integer; // -1 = not an error_reason

function EncodeWantConfig(Id: Cardinal): TBytes;
function EncodeHeartbeat: TBytes;
function EncodeDisconnect: TBytes;
function EncodeTextMessage(Dest, Channel, PacketId: Cardinal;
  const Text: string; WantAck: Boolean): TBytes;
function EncodeNodeInfoRequest(PacketId: Cardinal; const UserRaw: TBytes): TBytes;
function EncodeMqttProxyToRadio(const Topic: string; const Data: TBytes; Retained: Boolean): TBytes;
function DecodeServiceEnvelope(const Data: TBytes; out Packet: TMeshPacket): Boolean;
function DecodeData(const Data: TBytes): TMeshData;

// Admin messages to our own node. Each returns an encoded AdminMessage.
function AdminGetMetadata: TBytes;
function AdminBeginEdit(const Passkey: TBytes): TBytes;
function AdminCommitEdit(const Passkey: TBytes): TBytes;
function AdminSetTime(const Passkey: TBytes; UnixTime: Cardinal): TBytes;
function AdminSetMqtt(const Passkey: TBytes; const Cfg: TMqttConfig; Enable: Boolean): TBytes;
function AdminSetChannelMqtt(const Passkey: TBytes; const Ch: TChannelInfo; Enable: Boolean): TBytes;
function AdminSetMqttRoot(const Passkey: TBytes; const Cfg: TMqttConfig; const Root: string): TBytes;
function AdminSetLoRaOkToMqtt(const Passkey: TBytes; const LoRa: TLoRaConfig; Enable: Boolean): TBytes;
function AdminSetChannel(const Passkey: TBytes; Index, Role: Integer; const SettingsRaw: TBytes): TBytes;
function AdminSetFixedPosition(const Passkey: TBytes; Lat, Lon: Double): TBytes;
function AdminRemoveFixedPosition(const Passkey: TBytes): TBytes;
function EncodeAdminPacket(MyNode, PacketId: Cardinal; const Admin: TBytes): TBytes;
function DecodeAdminPasskey(const Payload: TBytes): TBytes;

// Channels and share links
function EncodeChannelSettings(const Name: string; const Psk: TBytes; Uplink, Downlink: Boolean): TBytes;
function ChannelSettingsWithMqtt(const Raw: TBytes; Enable: Boolean): TBytes;
function ChannelShareUrl(const SettingsRaw, LoRaRaw: TBytes): string;
function ParseChannelShareUrl(const Url: string; out Channels: TArray<TSharedChannel>): Boolean;
function PskDescription(const Psk: TBytes): string;
function PrecisionDescription(Bits: Integer): string;

function NodeIdStr(Num: Cardinal): string;
function HwModelName(Model: Integer): string;
function RegionName(Region: Integer): string;
function ModemPresetName(Preset: Integer): string;
function ChannelDisplayName(Preset: Integer): string; // e.g. "LongFast", as used in MQTT topics
function RoleName(Role: Integer): string;
function RoutingErrorName(Code: Integer): string;
function PortNumName(Port: Integer): string;

// UTF-8 to string that never raises: bad or cut-off sequences become U+FFFD.
// (TEncoding.UTF8 raises "No mapping for the Unicode character..." on them,
// and text from the internet or a wrongly-decrypted packet can contain them.)
function Utf8Text(const B: TBytes): string; overload;
function Utf8Text(const B: TBytes; Index, Count: Integer): string; overload;

implementation

uses
  System.Math, System.NetEncoding;

var
  LenientUtf8: TEncoding;

function Utf8Text(const B: TBytes): string;
begin
  Result := Utf8Text(B, 0, Length(B));
end;

function Utf8Text(const B: TBytes; Index, Count: Integer): string;
begin
  if (Count <= 0) or (Index < 0) or (Index + Count > Length(B)) then
    Exit('');
  try
    Result := LenientUtf8.GetString(B, Index, Count);
  except
    Result := TEncoding.ANSI.GetString(B, Index, Count);
  end;
end;

const
  WT_VARINT = 0;
  WT_FIXED64 = 1;
  WT_LEN = 2;
  WT_FIXED32 = 5;

{ TPbReader }

class function TPbReader.Create(const AData: TBytes): TPbReader;
begin
  Result.FData := AData;
  Result.FPos := 0;
end;

function TPbReader.Eof: Boolean;
begin
  Result := FPos >= Length(FData);
end;

procedure TPbReader.Need(N: Integer);
begin
  if (N < 0) or (FPos + N > Length(FData)) then
    raise EPbError.Create('Truncated protobuf message');
end;

function TPbReader.ReadVarint: UInt64;
var
  Shift: Integer;
  B: Byte;
begin
  Result := 0;
  Shift := 0;
  repeat
    Need(1);
    B := FData[FPos];
    Inc(FPos);
    if Shift < 64 then
      Result := Result or (UInt64(B and $7F) shl Shift);
    Inc(Shift, 7);
    if Shift > 70 then
      raise EPbError.Create('Malformed varint');
  until (B and $80) = 0;
end;

function TPbReader.ReadInt32: Integer;
begin
  Result := Integer(Cardinal(ReadVarint and $FFFFFFFF));
end;

function TPbReader.ReadTag(out Field, WireType: Integer): Boolean;
var
  T: UInt64;
begin
  Result := not Eof;
  if Result then
  begin
    T := ReadVarint;
    Field := Integer(T shr 3);
    WireType := Integer(T and 7);
  end;
end;

function TPbReader.ReadFixed32: Cardinal;
begin
  Need(4);
  Result := Cardinal(FData[FPos]) or (Cardinal(FData[FPos + 1]) shl 8) or
    (Cardinal(FData[FPos + 2]) shl 16) or (Cardinal(FData[FPos + 3]) shl 24);
  Inc(FPos, 4);
end;

function TPbReader.ReadFloat: Single;
var
  C: Cardinal;
begin
  C := ReadFixed32;
  Move(C, Result, SizeOf(Result));
end;

function TPbReader.ReadBytes: TBytes;
var
  Len: Integer;
begin
  Len := Integer(ReadVarint);
  Need(Len);
  SetLength(Result, Len);
  if Len > 0 then
    Move(FData[FPos], Result[0], Len);
  Inc(FPos, Len);
end;

function TPbReader.ReadString: string;
begin
  Result := Utf8Text(ReadBytes);
end;

procedure TPbReader.Skip(WireType: Integer);
var
  Len: Integer;
begin
  case WireType of
    WT_VARINT: ReadVarint;
    WT_FIXED64: begin Need(8); Inc(FPos, 8); end;
    WT_LEN:
      begin
        Len := Integer(ReadVarint);
        Need(Len);
        Inc(FPos, Len);
      end;
    WT_FIXED32: begin Need(4); Inc(FPos, 4); end;
  else
    raise EPbError.CreateFmt('Unsupported wire type %d', [WireType]);
  end;
end;

{ TPbWriter }

class function TPbWriter.Create: TPbWriter;
begin
  SetLength(Result.FBuf, 64);
  Result.FLen := 0;
end;

procedure TPbWriter.Put(B: Byte);
begin
  if FLen >= Length(FBuf) then
    SetLength(FBuf, Length(FBuf) * 2 + 16);
  FBuf[FLen] := B;
  Inc(FLen);
end;

procedure TPbWriter.PutVarint(V: UInt64);
begin
  while V >= $80 do
  begin
    Put(Byte(V and $7F) or $80);
    V := V shr 7;
  end;
  Put(Byte(V));
end;

procedure TPbWriter.PutTag(Field, WireType: Integer);
begin
  PutVarint(UInt64(Field) shl 3 or UInt64(WireType));
end;

procedure TPbWriter.WriteVarint(Field: Integer; V: UInt64);
begin
  PutTag(Field, WT_VARINT);
  PutVarint(V);
end;

procedure TPbWriter.WriteBool(Field: Integer; V: Boolean);
begin
  WriteVarint(Field, Ord(V));
end;

procedure TPbWriter.WriteFixed32(Field: Integer; V: Cardinal);
begin
  PutTag(Field, WT_FIXED32);
  Put(Byte(V));
  Put(Byte(V shr 8));
  Put(Byte(V shr 16));
  Put(Byte(V shr 24));
end;

procedure TPbWriter.WriteBytes(Field: Integer; const V: TBytes);
var
  B: Byte;
begin
  PutTag(Field, WT_LEN);
  PutVarint(Length(V));
  for B in V do
    Put(B);
end;

procedure TPbWriter.WriteString(Field: Integer; const V: string);
begin
  WriteBytes(Field, TEncoding.UTF8.GetBytes(V));
end;

function TPbWriter.ToBytes: TBytes;
begin
  Result := Copy(FBuf, 0, FLen);
end;

{ Decoders }

function DecodeUser(const Data: TBytes): TMeshUser;
var
  R: TPbReader;
  F, W: Integer;
begin
  Result := Default(TMeshUser);
  R := TPbReader.Create(Data);
  while R.ReadTag(F, W) do
    case F of
      1: Result.Id := R.ReadString;
      2: Result.LongName := R.ReadString;
      3: Result.ShortName := R.ReadString;
      5: Result.HwModel := Integer(R.ReadVarint);
      7: Result.Role := Integer(R.ReadVarint);
    else
      R.Skip(W);
    end;
end;

function DecodePosition(const Data: TBytes): TMeshPosition;
var
  R: TPbReader;
  F, W: Integer;
  LatI, LonI: Integer;
begin
  Result := Default(TMeshPosition);
  LatI := 0;
  LonI := 0;
  R := TPbReader.Create(Data);
  while R.ReadTag(F, W) do
    case F of
      1: LatI := Integer(R.ReadFixed32);   // sfixed32, degrees * 1e7
      2: LonI := Integer(R.ReadFixed32);
      3: Result.Altitude := R.ReadInt32;
    else
      R.Skip(W);
    end;
  Result.Valid := (LatI <> 0) or (LonI <> 0);
  Result.Lat := LatI / 1e7;
  Result.Lon := LonI / 1e7;
end;

function DecodeDeviceMetrics(const Data: TBytes): TDeviceMetrics;
var
  R: TPbReader;
  F, W: Integer;
begin
  Result := Default(TDeviceMetrics);
  Result.Valid := True;
  R := TPbReader.Create(Data);
  while R.ReadTag(F, W) do
    case F of
      1: Result.BatteryLevel := Integer(R.ReadVarint);
      2: Result.Voltage := R.ReadFloat;
      3: Result.ChannelUtil := R.ReadFloat;
      4: Result.AirUtilTx := R.ReadFloat;
      5: Result.Uptime := Cardinal(R.ReadVarint);
    else
      R.Skip(W);
    end;
end;

function DecodeTelemetry(const Data: TBytes; out M: TDeviceMetrics): Boolean;
var
  R: TPbReader;
  F, W: Integer;
begin
  Result := False;
  M := Default(TDeviceMetrics);
  R := TPbReader.Create(Data);
  while R.ReadTag(F, W) do
    if F = 2 then // Telemetry.device_metrics
    begin
      M := DecodeDeviceMetrics(R.ReadBytes);
      Result := True;
    end
    else
      R.Skip(W);
end;

function DecodeRoutingError(const Data: TBytes): Integer;
var
  R: TPbReader;
  F, W: Integer;
begin
  Result := -1;
  R := TPbReader.Create(Data);
  while R.ReadTag(F, W) do
    if F = 3 then // Routing.error_reason
      Result := Integer(R.ReadVarint)
    else
      R.Skip(W);
end;

function DecodeData(const Data: TBytes): TMeshData;
var
  R: TPbReader;
  F, W: Integer;
begin
  Result := Default(TMeshData);
  R := TPbReader.Create(Data);
  while R.ReadTag(F, W) do
    case F of
      1: Result.PortNum := Integer(R.ReadVarint);
      2: Result.Payload := R.ReadBytes;
      6: Result.RequestId := R.ReadFixed32;
      7: Result.ReplyId := R.ReadFixed32;
      8: Result.Emoji := R.ReadFixed32;
    else
      R.Skip(W);
    end;
end;

function DecodeMeshPacket(const Data: TBytes): TMeshPacket;
var
  R: TPbReader;
  F, W: Integer;
begin
  Result := Default(TMeshPacket);
  R := TPbReader.Create(Data);
  while R.ReadTag(F, W) do
    case F of
      1: Result.From := R.ReadFixed32;
      2: Result.To_ := R.ReadFixed32;
      3: Result.Channel := Cardinal(R.ReadVarint);
      4: begin Result.Decoded := DecodeData(R.ReadBytes); Result.HasDecoded := True; end;
      5: begin
           Result.EncBytes := R.ReadBytes;
           Result.Encrypted := Length(Result.EncBytes) > 0;
         end;
      6: Result.Id := R.ReadFixed32;
      7: Result.RxTime := R.ReadFixed32;
      8: Result.RxSnr := R.ReadFloat;
      9: Result.HopLimit := Cardinal(R.ReadVarint);
      10: Result.WantAck := R.ReadVarint <> 0;
      12: Result.RxRssi := R.ReadInt32;
      14: Result.ViaMqtt := R.ReadVarint <> 0;
      15: Result.HopStart := Cardinal(R.ReadVarint);
    else
      R.Skip(W);
    end;
end;

function DecodeNodeInfo(const Data: TBytes): TNodeInfo;
var
  R: TPbReader;
  F, W: Integer;
begin
  Result := Default(TNodeInfo);
  Result.HopsAway := -1;
  R := TPbReader.Create(Data);
  while R.ReadTag(F, W) do
    case F of
      1: Result.Num := Cardinal(R.ReadVarint);
      2:
        begin
          Result.UserRaw := R.ReadBytes;
          Result.User := DecodeUser(Result.UserRaw);
          Result.HasUser := True;
        end;
      3: Result.Position := DecodePosition(R.ReadBytes);
      4: Result.Snr := R.ReadFloat;
      5: Result.LastHeard := R.ReadFixed32;
      6: Result.Metrics := DecodeDeviceMetrics(R.ReadBytes);
      8: Result.ViaMqtt := R.ReadVarint <> 0;
      9: Result.HopsAway := Integer(R.ReadVarint);
    else
      R.Skip(W);
    end;
end;

function DecodeMyInfo(const Data: TBytes): TMyInfo;
var
  R: TPbReader;
  F, W: Integer;
begin
  Result := Default(TMyInfo);
  R := TPbReader.Create(Data);
  while R.ReadTag(F, W) do
    case F of
      1: Result.MyNodeNum := Cardinal(R.ReadVarint);
      8: Result.RebootCount := Cardinal(R.ReadVarint);
      13: Result.PioEnv := R.ReadString;
    else
      R.Skip(W);
    end;
end;

// ModuleSettings.position_precision (field 1)
function ReadPositionPrecision(const Data: TBytes): Integer;
var
  R: TPbReader;
  F, W: Integer;
begin
  Result := 0;
  R := TPbReader.Create(Data);
  while R.ReadTag(F, W) do
    if F = 1 then
      Result := Integer(R.ReadVarint)
    else
      R.Skip(W);
end;

function DecodeChannel(const Data: TBytes): TChannelInfo;
var
  R, S: TPbReader;
  F, W, F2, W2: Integer;
begin
  Result := Default(TChannelInfo);
  R := TPbReader.Create(Data);
  while R.ReadTag(F, W) do
    case F of
      1: Result.Index := R.ReadInt32;
      2:
        begin
          Result.SettingsRaw := R.ReadBytes;
          S := TPbReader.Create(Result.SettingsRaw); // ChannelSettings
          while S.ReadTag(F2, W2) do
            case F2 of
              2: Result.Psk := S.ReadBytes;
              3: Result.Name := S.ReadString;
              5: Result.Uplink := S.ReadVarint <> 0;
              6: Result.Downlink := S.ReadVarint <> 0;
              7: Result.PositionPrecision := ReadPositionPrecision(S.ReadBytes);
            else
              S.Skip(W2);
            end;
        end;
      3: Result.Role := Integer(R.ReadVarint);
    else
      R.Skip(W);
    end;
end;

function DecodeLoRaConfig(const Data: TBytes): TLoRaConfig;
var
  R: TPbReader;
  F, W: Integer;
begin
  Result := Default(TLoRaConfig);
  Result.Valid := True;
  Result.Raw := Data;
  R := TPbReader.Create(Data);
  while R.ReadTag(F, W) do
    case F of
      1: Result.UsePreset := R.ReadVarint <> 0;
      2: Result.ModemPreset := Integer(R.ReadVarint);
      7: Result.Region := Integer(R.ReadVarint);
      8: Result.HopLimit := Integer(R.ReadVarint);
      9: Result.TxEnabled := R.ReadVarint <> 0;
      10: Result.TxPower := R.ReadInt32;
      105: Result.OkToMqtt := R.ReadVarint <> 0;
    else
      R.Skip(W);
    end;
end;

function DecodeConfig(const Data: TBytes): TLoRaConfig;
var
  R: TPbReader;
  F, W: Integer;
begin
  Result := Default(TLoRaConfig);
  R := TPbReader.Create(Data);
  while R.ReadTag(F, W) do
    if F = 6 then // Config.lora
      Result := DecodeLoRaConfig(R.ReadBytes)
    else
      R.Skip(W);
end;

function DecodeMqttConfig(const Data: TBytes): TMqttConfig;
var
  R: TPbReader;
  F, W: Integer;
begin
  Result := Default(TMqttConfig);
  Result.Valid := True;
  Result.Raw := Data;
  R := TPbReader.Create(Data);
  while R.ReadTag(F, W) do
    case F of
      1: Result.Enabled := R.ReadVarint <> 0;
      2: Result.Address := R.ReadString;
      3: Result.Username := R.ReadString;
      4: Result.Password := R.ReadString;
      5: Result.EncryptionEnabled := R.ReadVarint <> 0;
      7: Result.TlsEnabled := R.ReadVarint <> 0;
      8: Result.Root := R.ReadString;
      9: Result.ProxyToClient := R.ReadVarint <> 0;
      10: Result.MapReporting := R.ReadVarint <> 0;
    else
      R.Skip(W);
    end;
end;

function DecodeModuleConfig(const Data: TBytes): TMqttConfig;
var
  R: TPbReader;
  F, W: Integer;
begin
  Result := Default(TMqttConfig);
  R := TPbReader.Create(Data);
  while R.ReadTag(F, W) do
    if F = 1 then // ModuleConfig.mqtt
      Result := DecodeMqttConfig(R.ReadBytes)
    else
      R.Skip(W);
end;

function DecodeMqttProxy(const Data: TBytes): TMqttProxyMessage;
var
  R: TPbReader;
  F, W: Integer;
begin
  Result := Default(TMqttProxyMessage);
  R := TPbReader.Create(Data);
  while R.ReadTag(F, W) do
    case F of
      1: Result.Topic := R.ReadString;
      2, 3: Result.Data := R.ReadBytes;   // data (bytes) or text (UTF-8)
      4: Result.Retained := R.ReadVarint <> 0;
    else
      R.Skip(W);
    end;
end;

function DecodeServiceEnvelope(const Data: TBytes; out Packet: TMeshPacket): Boolean;
var
  R: TPbReader;
  F, W: Integer;
begin
  Result := False;
  Packet := Default(TMeshPacket);
  try
    R := TPbReader.Create(Data);
    while R.ReadTag(F, W) do
      if (F = 1) and (W = WT_LEN) then // ServiceEnvelope.packet
      begin
        Packet := DecodeMeshPacket(R.ReadBytes);
        Result := True;
      end
      else
        R.Skip(W);
  except
    Result := False;
  end;
end;

function DecodeAdminPasskey(const Payload: TBytes): TBytes;
var
  R: TPbReader;
  F, W: Integer;
begin
  Result := nil;
  R := TPbReader.Create(Payload);
  while R.ReadTag(F, W) do
    if (F = 101) and (W = WT_LEN) then // AdminMessage.session_passkey
      Result := R.ReadBytes
    else
      R.Skip(W);
end;

function DecodeMetadata(const Data: TBytes): TDeviceMetadata;
var
  R: TPbReader;
  F, W: Integer;
begin
  Result := Default(TDeviceMetadata);
  R := TPbReader.Create(Data);
  while R.ReadTag(F, W) do
    case F of
      1: Result.FirmwareVersion := R.ReadString;
      7: Result.Role := Integer(R.ReadVarint);
      9: Result.HwModel := Integer(R.ReadVarint);
    else
      R.Skip(W);
    end;
end;

function DecodeQueueStatus(const Data: TBytes): TQueueStatus;
var
  R: TPbReader;
  F, W: Integer;
begin
  Result := Default(TQueueStatus);
  R := TPbReader.Create(Data);
  while R.ReadTag(F, W) do
    case F of
      1: Result.Res := R.ReadInt32;
      2: Result.Free := Cardinal(R.ReadVarint);
      3: Result.MaxLen := Cardinal(R.ReadVarint);
      4: Result.MeshPacketId := Cardinal(R.ReadVarint);
    else
      R.Skip(W);
    end;
end;

function DecodeStringField(const Data: TBytes; Field: Integer): string;
var
  R: TPbReader;
  F, W: Integer;
begin
  Result := '';
  R := TPbReader.Create(Data);
  while R.ReadTag(F, W) do
    if (F = Field) and (W = WT_LEN) then
      Result := R.ReadString
    else
      R.Skip(W);
end;

function DecodeFromRadio(const Data: TBytes): TFromRadio;
var
  R: TPbReader;
  F, W: Integer;
  Sub: TBytes;
begin
  Result := Default(TFromRadio);
  R := TPbReader.Create(Data);
  while R.ReadTag(F, W) do
  begin
    if F = 1 then // FromRadio.id
    begin
      R.Skip(W);
      Continue;
    end;
    case F of
      7: begin Result.Kind := frConfigComplete; Result.ConfigCompleteId := Cardinal(R.ReadVarint); end;
      8: begin Result.Kind := frRebooted; R.Skip(W); end;
    else
      if W <> WT_LEN then
      begin
        R.Skip(W);
        Continue;
      end;
      Sub := R.ReadBytes;
      case F of
        2: begin Result.Kind := frPacket; Result.Packet := DecodeMeshPacket(Sub); end;
        3: begin Result.Kind := frMyInfo; Result.MyInfo := DecodeMyInfo(Sub); end;
        4: begin Result.Kind := frNodeInfo; Result.NodeInfo := DecodeNodeInfo(Sub); end;
        5: begin Result.Kind := frConfig; Result.LoRa := DecodeConfig(Sub); end;
        6: begin Result.Kind := frLogRecord; Result.Text := DecodeStringField(Sub, 1); end;
        9: begin Result.Kind := frModuleConfig; Result.Mqtt := DecodeModuleConfig(Sub); end;
        14: begin Result.Kind := frMqttProxy; Result.MqttProxy := DecodeMqttProxy(Sub); end;
        10: begin Result.Kind := frChannel; Result.Channel := DecodeChannel(Sub); end;
        11: begin Result.Kind := frQueueStatus; Result.Queue := DecodeQueueStatus(Sub); end;
        13: begin Result.Kind := frMetadata; Result.Metadata := DecodeMetadata(Sub); end;
        16: begin Result.Kind := frClientNotification; Result.Text := DecodeStringField(Sub, 4); end;
      else
        Result.Kind := frOther;
      end;
    end;
  end;
end;

{ Encoders }

function EncodeWantConfig(Id: Cardinal): TBytes;
var
  W: TPbWriter;
begin
  W := TPbWriter.Create;
  W.WriteVarint(3, Id); // ToRadio.want_config_id
  Result := W.ToBytes;
end;

function EncodeHeartbeat: TBytes;
var
  W: TPbWriter;
begin
  W := TPbWriter.Create;
  W.WriteBytes(7, nil); // ToRadio.heartbeat = {}
  Result := W.ToBytes;
end;

function EncodeDisconnect: TBytes;
var
  W: TPbWriter;
begin
  W := TPbWriter.Create;
  W.WriteBool(4, True); // ToRadio.disconnect
  Result := W.ToBytes;
end;

function EncodeTextMessage(Dest, Channel, PacketId: Cardinal;
  const Text: string; WantAck: Boolean): TBytes;
var
  D, P, T: TPbWriter;
begin
  D := TPbWriter.Create;               // Data
  D.WriteVarint(1, PORT_TEXT);
  D.WriteString(2, Text);

  P := TPbWriter.Create;               // MeshPacket
  P.WriteFixed32(2, Dest);
  if Channel <> 0 then
    P.WriteVarint(3, Channel);
  P.WriteBytes(4, D.ToBytes);
  P.WriteFixed32(6, PacketId);
  if WantAck then
    P.WriteBool(10, True);

  T := TPbWriter.Create;               // ToRadio
  T.WriteBytes(1, P.ToBytes);
  Result := T.ToBytes;
end;

{ Names }

function EncodeNodeInfoRequest(PacketId: Cardinal; const UserRaw: TBytes): TBytes;
var
  D, P, T: TPbWriter;
begin
  D := TPbWriter.Create;               // Data
  D.WriteVarint(1, PORT_NODEINFO);
  D.WriteBytes(2, UserRaw);            // our own User record
  D.WriteBool(3, True);                // want_response: "please introduce yourselves"

  P := TPbWriter.Create;               // MeshPacket
  P.WriteFixed32(2, BROADCAST_ADDR);
  P.WriteBytes(4, D.ToBytes);
  P.WriteFixed32(6, PacketId);

  T := TPbWriter.Create;               // ToRadio
  T.WriteBytes(1, P.ToBytes);
  Result := T.ToBytes;
end;

function ConcatBytes(const A, B: TBytes): TBytes;
begin
  SetLength(Result, Length(A) + Length(B));
  if Length(A) > 0 then Move(A[0], Result[0], Length(A));
  if Length(B) > 0 then Move(B[0], Result[Length(A)], Length(B));
end;

function EncodeMqttProxyToRadio(const Topic: string; const Data: TBytes; Retained: Boolean): TBytes;
var
  M, T: TPbWriter;
begin
  M := TPbWriter.Create;               // MqttClientProxyMessage
  M.WriteString(1, Topic);
  M.WriteBytes(2, Data);
  if Retained then
    M.WriteBool(4, True);
  T := TPbWriter.Create;               // ToRadio
  T.WriteBytes(6, M.ToBytes);
  Result := T.ToBytes;
end;

function AdminWithPasskey(const Passkey: TBytes; var W: TPbWriter): TBytes;
begin
  if Length(Passkey) > 0 then
    W.WriteBytes(101, Passkey);        // session_passkey
  Result := W.ToBytes;
end;

function AdminGetMetadata: TBytes;
var
  W: TPbWriter;
begin
  W := TPbWriter.Create;
  W.WriteBool(12, True);               // get_device_metadata_request
  Result := W.ToBytes;
end;

function AdminBeginEdit(const Passkey: TBytes): TBytes;
var
  W: TPbWriter;
begin
  W := TPbWriter.Create;
  W.WriteBool(64, True);               // begin_edit_settings
  Result := AdminWithPasskey(Passkey, W);
end;

function AdminCommitEdit(const Passkey: TBytes): TBytes;
var
  W: TPbWriter;
begin
  W := TPbWriter.Create;
  W.WriteBool(65, True);               // commit_edit_settings
  Result := AdminWithPasskey(Passkey, W);
end;

function AdminSetTime(const Passkey: TBytes; UnixTime: Cardinal): TBytes;
var
  W: TPbWriter;
begin
  W := TPbWriter.Create;
  W.WriteFixed32(43, UnixTime);        // set_time_only (UTC seconds)
  Result := AdminWithPasskey(Passkey, W);
end;

{ The set_* builders re-send the config block exactly as the radio reported it
  and append only the fields we change. In protobuf the last value of a field
  wins, so every other setting is preserved untouched. }

function AdminSetMqtt(const Passkey: TBytes; const Cfg: TMqttConfig; Enable: Boolean): TBytes;
var
  Ovr, MC, W: TPbWriter;
begin
  Ovr := TPbWriter.Create;
  Ovr.WriteBool(1, Enable);            // enabled
  Ovr.WriteBool(9, Enable);            // proxy_to_client_enabled
  MC := TPbWriter.Create;              // ModuleConfig
  MC.WriteBytes(1, ConcatBytes(Cfg.Raw, Ovr.ToBytes));
  W := TPbWriter.Create;
  W.WriteBytes(35, MC.ToBytes);        // set_module_config
  Result := AdminWithPasskey(Passkey, W);
end;

function AdminSetMqttRoot(const Passkey: TBytes; const Cfg: TMqttConfig; const Root: string): TBytes;
var
  Ovr, MC, W: TPbWriter;
begin
  Ovr := TPbWriter.Create;
  Ovr.WriteString(8, Root);            // root (topic prefix)
  MC := TPbWriter.Create;              // ModuleConfig
  MC.WriteBytes(1, ConcatBytes(Cfg.Raw, Ovr.ToBytes));
  W := TPbWriter.Create;
  W.WriteBytes(35, MC.ToBytes);        // set_module_config
  Result := AdminWithPasskey(Passkey, W);
end;

function AdminSetChannelMqtt(const Passkey: TBytes; const Ch: TChannelInfo; Enable: Boolean): TBytes;
var
  Ovr, C, W: TPbWriter;
begin
  Ovr := TPbWriter.Create;
  Ovr.WriteBool(5, Enable);            // uplink_enabled
  Ovr.WriteBool(6, Enable);            // downlink_enabled
  C := TPbWriter.Create;               // Channel
  C.WriteVarint(1, Cardinal(Ch.Index));
  C.WriteBytes(2, ConcatBytes(Ch.SettingsRaw, Ovr.ToBytes));
  C.WriteVarint(3, Ch.Role);
  W := TPbWriter.Create;
  W.WriteBytes(33, C.ToBytes);         // set_channel
  Result := AdminWithPasskey(Passkey, W);
end;

function AdminSetLoRaOkToMqtt(const Passkey: TBytes; const LoRa: TLoRaConfig; Enable: Boolean): TBytes;
var
  Ovr, C, W: TPbWriter;
begin
  Ovr := TPbWriter.Create;
  Ovr.WriteBool(105, Enable);          // config_ok_to_mqtt
  C := TPbWriter.Create;               // Config
  C.WriteBytes(6, ConcatBytes(LoRa.Raw, Ovr.ToBytes));
  W := TPbWriter.Create;
  W.WriteBytes(34, C.ToBytes);         // set_config
  Result := AdminWithPasskey(Passkey, W);
end;

function AdminSetChannel(const Passkey: TBytes; Index, Role: Integer; const SettingsRaw: TBytes): TBytes;
var
  C, W: TPbWriter;
begin
  C := TPbWriter.Create;               // Channel
  C.WriteVarint(1, Cardinal(Index));
  C.WriteBytes(2, SettingsRaw);
  C.WriteVarint(3, Cardinal(Role));    // 0 disabled, 1 primary, 2 secondary
  W := TPbWriter.Create;
  W.WriteBytes(33, C.ToBytes);         // set_channel
  Result := AdminWithPasskey(Passkey, W);
end;

function AdminSetFixedPosition(const Passkey: TBytes; Lat, Lon: Double): TBytes;
var
  P, W: TPbWriter;
begin
  P := TPbWriter.Create;               // Position
  P.WriteFixed32(1, Cardinal(Integer(Round(Lat * 1e7))));  // latitude_i (sfixed32)
  P.WriteFixed32(2, Cardinal(Integer(Round(Lon * 1e7))));  // longitude_i (sfixed32)
  P.WriteVarint(5, 1);                 // location_source = LOC_MANUAL
  W := TPbWriter.Create;
  W.WriteBytes(41, P.ToBytes);         // set_fixed_position
  Result := AdminWithPasskey(Passkey, W);
end;

function AdminRemoveFixedPosition(const Passkey: TBytes): TBytes;
var
  W: TPbWriter;
begin
  W := TPbWriter.Create;
  W.WriteBool(42, True);               // remove_fixed_position
  Result := AdminWithPasskey(Passkey, W);
end;

function EncodeChannelSettings(const Name: string; const Psk: TBytes; Uplink, Downlink: Boolean): TBytes;
var
  W: TPbWriter;
begin
  W := TPbWriter.Create;               // ChannelSettings
  W.WriteBytes(2, Psk);
  W.WriteString(3, Name);
  if Uplink then W.WriteBool(5, True);
  if Downlink then W.WriteBool(6, True);
  Result := W.ToBytes;
end;

// Same settings with MQTT uplink/downlink forced on or off (last field wins)
function ChannelSettingsWithMqtt(const Raw: TBytes; Enable: Boolean): TBytes;
var
  W: TPbWriter;
begin
  W := TPbWriter.Create;
  W.WriteBool(5, Enable);
  W.WriteBool(6, Enable);
  Result := ConcatBytes(Raw, W.ToBytes);
end;

// https://meshtastic.org/e/?add=true#<base64url ChannelSet>: the phone apps
// add the channel next to the ones they have instead of replacing them.
function ChannelShareUrl(const SettingsRaw, LoRaRaw: TBytes): string;
var
  W: TPbWriter;
  Enc: TBase64Encoding;
  B64: string;
begin
  W := TPbWriter.Create;               // ChannelSet
  W.WriteBytes(1, SettingsRaw);        // settings (repeated)
  if Length(LoRaRaw) > 0 then
    W.WriteBytes(2, LoRaRaw);          // lora_config
  Enc := TBase64Encoding.Create(0);    // no line breaks
  try
    B64 := Enc.EncodeBytesToString(W.ToBytes);
  finally
    Enc.Free;
  end;
  B64 := B64.Replace('+', '-').Replace('/', '_').Replace('=', '');
  Result := 'https://meshtastic.org/e/?add=true#' + B64;
end;

function ParseChannelShareUrl(const Url: string; out Channels: TArray<TSharedChannel>): Boolean;
var
  B64: string;
  I, F, W, F2, W2: Integer;
  Data: TBytes;
  R, S: TPbReader;
  C: TSharedChannel;
begin
  Channels := nil;
  Result := False;
  I := Pos('#', Url);
  if I = 0 then
    Exit;
  B64 := Trim(Copy(Url, I + 1, MaxInt)).Replace('-', '+').Replace('_', '/');
  // some links put ?add=true after the data
  I := Pos('?', B64);
  if I > 0 then
    B64 := Copy(B64, 1, I - 1);
  while Length(B64) mod 4 <> 0 do
    B64 := B64 + '=';
  try
    Data := TNetEncoding.Base64.DecodeStringToBytes(B64);
    R := TPbReader.Create(Data);
    while R.ReadTag(F, W) do
      if F = 1 then
      begin
        C := Default(TSharedChannel);
        C.Raw := R.ReadBytes;
        S := TPbReader.Create(C.Raw);
        while S.ReadTag(F2, W2) do
          case F2 of
            2: C.Psk := S.ReadBytes;
            3: C.Name := S.ReadString;
          else
            S.Skip(W2);
          end;
        Channels := Channels + [C];
      end
      else
        R.Skip(W);
  except
    Channels := nil;
  end;
  Result := Length(Channels) > 0;
end;

function PskDescription(const Psk: TBytes): string;
begin
  case Length(Psk) of
    0: Result := 'none (unencrypted)';
    1: if Psk[0] = 0 then
         Result := 'none (unencrypted)'
       else
         Result := 'public default key';
    16: Result := 'private 128-bit key';
    32: Result := 'private 256-bit key';
  else
    Result := Format('%d-byte key', [Length(Psk)]);
  end;
end;

// Meshtastic rounds shared positions to this many bits; show it as a radius
function PrecisionDescription(Bits: Integer): string;
var
  Meters: Double;
begin
  if Bits <= 0 then
    Exit('not shared');
  if Bits >= 32 then
    Exit('exact');
  Meters := Power(2, 32 - Bits) * 1e-7 * 111320 / 2;
  if Meters >= 1000 then
    Result := Format('rounded to about %.1f km', [Meters / 1000])
  else
    Result := Format('rounded to about %d m', [Round(Meters)]);
end;

function EncodeAdminPacket(MyNode, PacketId: Cardinal; const Admin: TBytes): TBytes;
var
  D, P, T: TPbWriter;
begin
  D := TPbWriter.Create;               // Data
  D.WriteVarint(1, PORT_ADMIN);
  D.WriteBytes(2, Admin);
  D.WriteBool(3, True);                // want_response
  P := TPbWriter.Create;               // MeshPacket
  P.WriteFixed32(2, MyNode);
  P.WriteBytes(4, D.ToBytes);
  P.WriteFixed32(6, PacketId);
  T := TPbWriter.Create;               // ToRadio
  T.WriteBytes(1, P.ToBytes);
  Result := T.ToBytes;
end;

function NodeIdStr(Num: Cardinal): string;
begin
  Result := '!' + LowerCase(IntToHex(Num, 8));
end;

function PickName(const CSV: string; Index: Integer): string;
var
  Parts: TArray<string>;
begin
  Parts := CSV.Split([',']);
  if (Index >= 0) and (Index < Length(Parts)) then
    Result := Parts[Index]
  else
    Result := '#' + IntToStr(Index);
end;

function HwModelName(Model: Integer): string;
const
  Names =
    'UNSET,TLORA_V2,TLORA_V1,TLORA_V2_1_1P6,TBEAM,HELTEC_V2_0,TBEAM_V0P7,T_ECHO,' +
    'TLORA_V1_1P3,RAK4631,HELTEC_V2_1,HELTEC_V1,LILYGO_TBEAM_S3_CORE,RAK11200,' +
    'NANO_G1,TLORA_V2_1_1P8,TLORA_T3_S3,NANO_G1_EXPLORER,NANO_G2_ULTRA,LORA_TYPE,' +
    'WIPHONE,WIO_WM1110,RAK2560,HELTEC_HRU_3601,HELTEC_WIRELESS_BRIDGE,STATION_G1,' +
    'RAK11310,SENSELORA_RP2040,SENSELORA_S3,CANARYONE,RP2040_LORA,STATION_G2,' +
    'LORA_RELAY_V1,T_ECHO_PLUS,PPR,GENIEBLOCKS,NRF52_UNKNOWN,PORTDUINO,ANDROID_SIM,' +
    'DIY_V1,NRF52840_PCA10059,DR_DEV,M5STACK,HELTEC_V3,HELTEC_WSL_V3,BETAFPV_2400_TX,' +
    'BETAFPV_900_NANO_TX,RPI_PICO,HELTEC_WIRELESS_TRACKER,HELTEC_WIRELESS_PAPER,' +
    'T_DECK,T_WATCH_S3,PICOMPUTER_S3,HELTEC_HT62,EBYTE_ESP32_S3,ESP32_S3_PICO,' +
    'CHATTER_2,HELTEC_WIRELESS_PAPER_V1_0,HELTEC_WIRELESS_TRACKER_V1_0,UNPHONE,' +
    'TD_LORAC,CDEBYTE_EORA_S3,TWC_MESH_V4,NRF52_PROMICRO_DIY,' +
    'RADIOMASTER_900_BANDIT_NANO,HELTEC_CAPSULE_SENSOR_V3,HELTEC_VISION_MASTER_T190,' +
    'HELTEC_VISION_MASTER_E213,HELTEC_VISION_MASTER_E290,HELTEC_MESH_NODE_T114,' +
    'SENSECAP_INDICATOR,TRACKER_T1000_E,RAK3172,WIO_E5,RADIOMASTER_900_BANDIT,' +
    'ME25LS01_4Y10TD,RP2040_FEATHER_RFM95,M5STACK_COREBASIC,M5STACK_CORE2,RPI_PICO2,' +
    'M5STACK_CORES3,SEEED_XIAO_S3,MS24SF1,TLORA_C6,WISMESH_TAP,ROUTASTIC,MESH_TAB,' +
    'MESHLINK,XIAO_NRF52_KIT,THINKNODE_M1,THINKNODE_M2,T_ETH_ELITE,HELTEC_SENSOR_HUB,' +
    'MUZI_BASE,HELTEC_MESH_POCKET,SEEED_SOLAR_NODE,NOMADSTAR_METEOR_PRO,CROWPANEL,' +
    'LINK_32,SEEED_WIO_TRACKER_L1,SEEED_WIO_TRACKER_L1_EINK,MUZI_R1_NEO,T_DECK_PRO,' +
    'T_LORA_PAGER,M5STACK_RESERVED,WISMESH_TAG,RAK3312,THINKNODE_M5,HELTEC_MESH_SOLAR,' +
    'T_ECHO_LITE,HELTEC_V4,M5STACK_C6L,M5STACK_CARDPUTER_ADV,' +
    'HELTEC_WIRELESS_TRACKER_V2,T_WATCH_ULTRA,THINKNODE_M3,WISMESH_TAP_V2,RAK3401,' +
    'RAK6421,THINKNODE_M4,THINKNODE_M6,MESHSTICK_1262,TBEAM_1_WATT,T5_S3_EPAPER_PRO,' +
    'TBEAM_BPF,MINI_EPAPER_S3,TDISPLAY_S3_PRO,HELTEC_MESH_NODE_T096,' +
    'TRACKER_T1000_E_PRO,THINKNODE_M7,THINKNODE_M8,THINKNODE_M9,HELTEC_V4_R8,' +
    'HELTEC_MESH_NODE_T1,STATION_G3,T_IMPULSE_PLUS,T_ECHO_CARD,SEEED_WIO_TRACKER_L2,' +
    'CROWPANEL_P4,HELTEC_MESH_TOWER_V2,MESHNOLOGY_W10';
begin
  if Model = 255 then
    Result := 'PRIVATE_HW'
  else
    Result := PickName(Names, Model);
end;

function RegionName(Region: Integer): string;
const
  Names = 'UNSET,US,EU_433,EU_868,CN,JP,ANZ,KR,TW,RU,IN,NZ_865,TH,LORA_24,UA_433,' +
    'UA_868,MY_433,MY_919,SG_923,PH_433,PH_868,PH_915,ANZ_433,KZ_433,KZ_863,NP_865,' +
    'BR_902,ITU1_2M,ITU2_2M,EU_866,EU_874,EU_917,EU_N_868,ITU3_2M';
begin
  Result := PickName(Names, Region);
end;

function ModemPresetName(Preset: Integer): string;
const
  Names = 'LONG_FAST,LONG_SLOW,VERY_LONG_SLOW,MEDIUM_SLOW,MEDIUM_FAST,SHORT_SLOW,' +
    'SHORT_FAST,LONG_MODERATE,SHORT_TURBO,LONG_TURBO,LITE_FAST,LITE_SLOW,' +
    'NARROW_FAST,NARROW_SLOW';
begin
  Result := PickName(Names, Preset);
end;

function ChannelDisplayName(Preset: Integer): string;
begin
  case Preset of
    0: Result := 'LongFast';
    1: Result := 'LongSlow';
    2: Result := 'VLongSlow';
    3: Result := 'MediumSlow';
    4: Result := 'MediumFast';
    5: Result := 'ShortSlow';
    6: Result := 'ShortFast';
    7: Result := 'LongMod';
    8: Result := 'ShortTurbo';
    9: Result := 'LongTurbo';
  else
    Result := ModemPresetName(Preset);
  end;
end;

function RoleName(Role: Integer): string;
const
  Names = 'CLIENT,CLIENT_MUTE,ROUTER,ROUTER_CLIENT,REPEATER,TRACKER,SENSOR,TAK,' +
    'CLIENT_HIDDEN,LOST_AND_FOUND,TAK_TRACKER,ROUTER_LATE,CLIENT_BASE';
begin
  Result := PickName(Names, Role);
end;

function RoutingErrorName(Code: Integer): string;
begin
  case Code of
    0: Result := 'NONE';
    1: Result := 'NO_ROUTE';
    2: Result := 'GOT_NAK';
    3: Result := 'TIMEOUT';
    4: Result := 'NO_INTERFACE';
    5: Result := 'MAX_RETRANSMIT';
    6: Result := 'NO_CHANNEL';
    7: Result := 'TOO_LARGE';
    8: Result := 'NO_RESPONSE';
    9: Result := 'DUTY_CYCLE_LIMIT';
    32: Result := 'BAD_REQUEST';
    33: Result := 'NOT_AUTHORIZED';
    34: Result := 'PKI_FAILED';
    35: Result := 'PKI_UNKNOWN_PUBKEY';
    36: Result := 'ADMIN_BAD_SESSION_KEY';
    37: Result := 'ADMIN_PUBLIC_KEY_UNAUTHORIZED';
    38: Result := 'RATE_LIMIT_EXCEEDED';
    39: Result := 'PKI_SEND_FAIL_PUBLIC_KEY';
  else
    Result := 'ERROR_' + IntToStr(Code);
  end;
end;

function PortNumName(Port: Integer): string;
begin
  case Port of
    0: Result := 'UNKNOWN';
    1: Result := 'TEXT';
    2: Result := 'REMOTE_HARDWARE';
    3: Result := 'POSITION';
    4: Result := 'NODEINFO';
    5: Result := 'ROUTING';
    6: Result := 'ADMIN';
    7: Result := 'TEXT_COMPRESSED';
    8: Result := 'WAYPOINT';
    10: Result := 'DETECTION_SENSOR';
    11: Result := 'ALERT';
    32: Result := 'REPLY';
    34: Result := 'PAXCOUNTER';
    64: Result := 'SERIAL';
    65: Result := 'STORE_FORWARD';
    66: Result := 'RANGE_TEST';
    67: Result := 'TELEMETRY';
    70: Result := 'TRACEROUTE';
    71: Result := 'NEIGHBORINFO';
    73: Result := 'MAP_REPORT';
  else
    Result := 'PORT_' + IntToStr(Port);
  end;
end;

initialization
  // no MB_ERR_INVALID_CHARS flag: invalid bytes are replaced, not an error
  LenientUtf8 := TMBCSEncoding.Create(CP_UTF8, 0, 0);

finalization
  LenientUtf8.Free;

end.
