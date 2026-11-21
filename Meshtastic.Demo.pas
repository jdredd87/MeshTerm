unit Meshtastic.Demo;

{ Made-up mesh for screenshots and demos (MeshTermX -demo, or a file named
  demo.flag next to MeshTerm.ini on Android). Every name, node ID and place
  here is invented; the nodes sit around downtown Springfield, Illinois. }

interface

uses
  System.SysUtils, System.DateUtils, System.Generics.Collections, Meshtastic.Proto;

type
  TDemoMessage = record
    Text, Detail: string;
  end;

const
  DEMO_ME = $DE30A001;
  DEMO_FRIEND1 = $A11CE042;
  DEMO_FRIEND2 = $B0B5E7A1;

function DemoNodes: TArray<TNodeInfo>;
function DemoChannels: TArray<TChannelInfo>;
function DemoLoRa: TLoRaConfig;
function DemoMetadata: TDeviceMetadata;
function DemoMessages: TArray<TDemoMessage>;
function DemoNotes: TArray<TPair<Cardinal, string>>;

implementation

uses
  Meshtastic.Crypto;

const
  LAT0 = 39.7990;
  LON0 = -89.6440;
  // hardware model numbers (see HwModelName)
  HW_TBEAM = 4; HW_TECHO = 7; HW_RAK4631 = 9; HW_STATION_G2 = 25; HW_HELTEC_V3 = 43;
  ROLE_CLIENT = 0; ROLE_ROUTER = 2; ROLE_CLIENT_MUTE = 1;

function Node(Num: Cardinal; const Long, Short: string; Hw, Role: Integer; DLat, DLon: Double;
  HasPos: Boolean; Snr: Single; Rssi, Hops, Battery: Integer; Volts: Single; AgoSecs: Integer;
  ViaMqtt: Boolean): TNodeInfo;
begin
  Result := Default(TNodeInfo);
  Result.Num := Num;
  Result.HasUser := True;
  Result.User.Id := NodeIdStr(Num);
  Result.User.LongName := Long;
  Result.User.ShortName := Short;
  Result.User.HwModel := Hw;
  Result.User.Role := Role;
  if HasPos then
  begin
    Result.Position.Valid := True;
    Result.Position.Lat := LAT0 + DLat;
    Result.Position.Lon := LON0 + DLon;
    Result.Position.Altitude := 180 + Round(Abs(DLat) * 300);
  end;
  Result.Snr := Snr;
  Result.Rssi := Rssi;
  Result.HopsAway := Hops;
  if Battery <> 0 then
  begin
    Result.Metrics.Valid := True;
    Result.Metrics.BatteryLevel := Battery;
    Result.Metrics.Voltage := Volts;
    Result.Metrics.ChannelUtil := 8.5;
    Result.Metrics.AirUtilTx := 1.2;
    Result.Metrics.Uptime := 3 * 86400 + 5 * 3600;
  end;
  if AgoSecs >= 0 then
    Result.LastHeard := DateTimeToUnix(Now, False) - AgoSecs;
  Result.ViaMqtt := ViaMqtt;
end;

function DemoNodes: TArray<TNodeInfo>;
begin
  Result := [
    Node(DEMO_ME, 'Demo Base Station', 'DEMO', HW_RAK4631, ROLE_CLIENT, 0.0010, 0.0020, True, 0, 0, 0, 101, 4.9, 20, False),
    Node(DEMO_FRIEND1, 'Alice Trail Radio', 'ALIC', HW_TECHO, ROLE_CLIENT, -0.0310, 0.0420, True, 7.25, -88, 0, 84, 4.02, 95, False),
    Node(DEMO_FRIEND2, 'Bob Mobile', 'BOB', HW_TBEAM, ROLE_CLIENT, 0.0520, -0.0610, True, -3.5, -112, 1, 47, 3.71, 640, False),
    Node($C0FFEE10, 'Hilltop Repeater', 'HILL', HW_STATION_G2, ROLE_ROUTER, 0.0950, 0.1200, True, 9.5, -79, 0, 101, 5.1, 40, False),
    Node($5A1A2B3C, 'Riverside Solar', 'RIVR', HW_RAK4631, ROLE_CLIENT, -0.0870, -0.0950, True, 1.75, -104, 1, 100, 4.19, 300, False),
    Node($7E57AB01, 'Library Roof', 'LIB', HW_HELTEC_V3, ROLE_CLIENT, 0.0120, -0.0180, True, 11.0, -71, 0, 101, 5.0, 150, False),
    Node($3A7F0C12, 'Weather Station', 'WX01', HW_RAK4631, ROLE_CLIENT_MUTE, -0.1500, 0.0800, True, -8.25, -118, 2, 92, 4.11, 1800, False),
    Node($9B1D4E77, 'Farm Gateway', 'FARM', HW_HELTEC_V3, ROLE_CLIENT, 0.2100, 0.2600, True, 0, 0, -1, 76, 3.95, 5400, True),
    Node($4C2A9F05, 'Lakeside Camper', 'CAMP', HW_TBEAM, ROLE_CLIENT, -0.2300, -0.1900, True, 0, 0, -1, 35, 3.62, 9000, True),
    Node($61E8D2B9, 'Pocket Node', 'PKT', HW_TECHO, ROLE_CLIENT, 0, 0, False, 4.5, -97, 1, 66, 3.86, 2400, False),
    Node($1F00D5E3, 'Downtown Cafe', 'CAFE', HW_HELTEC_V3, ROLE_CLIENT, -0.0040, 0.0060, True, 6.0, -90, 0, 0, 0, 7200, False),
    Node($88AB3C41, 'Night Owl', 'OWL', HW_RAK4631, ROLE_CLIENT, 0, 0, False, 0, 0, -1, 58, 3.80, 3 * 86400, True)];
end;

function DemoChannels: TArray<TChannelInfo>;
var
  C: TChannelInfo;
begin
  C := Default(TChannelInfo);
  C.Index := 0;
  C.Role := 1;
  C.Name := '';
  C.Psk := TBytes.Create(1);
  C.PositionPrecision := 13;
  C.SettingsRaw := EncodeChannelSettings('', C.Psk, False, False);
  Result := [C];
  C := Default(TChannelInfo);
  C.Index := 1;
  C.Role := 2;
  C.Name := 'Family';
  C.Psk := SecureRandomBytes(32);
  C.PositionPrecision := 32;
  C.SettingsRaw := EncodeChannelSettings(C.Name, C.Psk, False, False);
  Result := Result + [C];
end;

function DemoLoRa: TLoRaConfig;
begin
  Result := Default(TLoRaConfig);
  Result.Valid := True;
  Result.Region := 1;          // US
  Result.ModemPreset := 0;     // LONG_FAST
  Result.UsePreset := True;
  Result.HopLimit := 3;
  Result.TxEnabled := True;
end;

function DemoMetadata: TDeviceMetadata;
begin
  Result := Default(TDeviceMetadata);
  Result.FirmwareVersion := '2.6.2.demo';
  Result.HwModel := HW_RAK4631;
end;

function DemoMessages: TArray<TDemoMessage>;

  function M(const Text, Detail: string): TDemoMessage;
  begin
    Result.Text := Text;
    Result.Detail := Detail;
  end;

const
  D = '  '#$00B7'  ';
  A = ' '#$2192' ';
begin
  Result := [
    M('Morning all! Hilltop repeater is back up after the storm.', '08:02  Hilltop Repeater' + A + '#LongFast' + D + 'SNR 9.5'),
    M('Thanks! Hearing you loud and clear from the trail head.', '08:04  Alice Trail Radio' + A + '#LongFast' + D + 'SNR 7.3  hops 0'),
    M('Anyone near Riverside? Testing range from the car.', '08:15  Bob Mobile' + A + '#LongFast' + D + 'SNR -3.5  hops 1'),
    M('Got you at -104 dBm, one hop through Hilltop.', '08:16  me' + A + '#LongFast' + D + 'sent ' + #$2713 + ' (heard by the mesh)'),
    M('Lunch at the cafe at noon?', '09:30  Alice Trail Radio' + A + 'me' + D + 'SNR 6.8  hops 0'),
    M('Sounds good, see you there.', '09:31  me' + A + 'Alice Trail Radio' + D + 'delivered ' + #$2713),
    M('Rain moving in from the west around 3 pm.', '10:05  Weather Station' + A + '#LongFast' + D + 'SNR -8.3  hops 2'),
    M('Dinner is at 6, bring the extra antenna!', '10:12  Bob Mobile' + A + '#Family' + D + 'SNR -2.0  hops 1')];
end;

function DemoNotes: TArray<TPair<Cardinal, string>>;
begin
  Result := [TPair<Cardinal, string>.Create($C0FFEE10, 'Solar + 8 dBi antenna on the water tower'),
    TPair<Cardinal, string>.Create(DEMO_FRIEND2, 'Usually on the road 7-9 am')];
end;

end.
