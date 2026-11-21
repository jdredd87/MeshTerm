unit Meshtastic.Ble;

{ Meshtastic over Bluetooth LE (Windows and Android, through Delphi's
  System.Bluetooth).

  The radio's GATT service carries the same ToRadio / FromRadio protobufs as
  the serial stream, without the 0x94 0xC3 framing:
    ToRadio   - write one ToRadio message
    FromRadio - read one FromRadio message; an empty read means "no more"
    FromNum   - notifies when there is something new to read

  Delphi's BLE calls block (writes, service discovery) or answer on another
  thread (reads), and Android allows one GATT operation at a time, so one
  worker thread does them all in turn.

  The radio wants the link encrypted: the first connection makes the phone
  (or Windows) pair with it and ask for its PIN (123456 unless the radio
  shows another on its screen or was set to a fixed one). }

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections,
  System.Bluetooth, Meshtastic.Transport;

type
  TBleScanDone = reference to procedure(const Names: TArray<string>; const Error: string);

{ Looks for Meshtastic radios for Seconds; calls OnDone on the main thread
  with their port names ('BLE <name> [<address>]'). Main thread. }
procedure StartBleScan(Seconds: Integer; const OnDone: TBleScanDone);
function BleAvailable(out Why: string): Boolean;

var
  { What the last scan saw (every device, for the log when no radio is found). }
  BleScanReport: TArray<string>;

type
  TMeshBleTransport = class(TMeshTransport)
  private
    FPortName, FAddress: string;
    FThread: TThread;
    FLock: TCriticalSection;
    FOut: TList<TBytes>;
    FWake: TEvent;
    function TakeOutgoing: TArray<TBytes>;
  protected
    procedure DoStop; override;
  public
    constructor Create(const PortName: string);
    destructor Destroy; override;
    procedure Start; override;
    procedure SendPayload(const Payload: TBytes); override;
    function Description: string; override;
  end;

implementation

const
  MESH_SERVICE: TBluetoothUUID = '{6BA1B218-15A8-461F-9FA8-5DCAE273EAFD}';
  TO_RADIO: TBluetoothUUID     = '{F75C76D2-129E-4DAD-A1DD-7866124401E7}';
  FROM_RADIO: TBluetoothUUID   = '{2C55E69E-4993-11ED-B878-0242AC120002}';
  FROM_NUM: TBluetoothUUID     = '{ED9DA18C-A800-4F66-A670-AA7547E34453}';

{ Scanning }

type
  TScanner = class
  public
    OnDone: TBleScanDone;
    procedure DiscoveryEnd(const Sender: TObject; const ADeviceList: TBluetoothLEDeviceList);
  end;

var
  GScanner: TScanner;

function BleAvailable(out Why: string): Boolean;
begin
  Why := '';
  try
    Result := TBluetoothLEManager.Current <> nil;
    if Result and (TBluetoothLEManager.Current.CurrentAdapter = nil) then
    begin
      Why := 'Bluetooth is off or this device has none';
      Result := False;
    end;
  except
    on E: Exception do
    begin
      Why := E.Message;
      Result := False;
    end;
  end;
end;

function IsMeshtastic(D: TBluetoothLEDevice): Boolean;
var
  U: TBluetoothUUID;
begin
  Result := False;
  try
    if D.ScannedAdvertiseData <> nil then
      for U in D.ScannedAdvertiseData.ServiceUUIDs do
        if U = MESH_SERVICE then
          Exit(True);
  except
    // some stacks have no advertisement data for a cached device
  end;
end;

function PortNameOf(D: TBluetoothLEDevice): string;
var
  N: string;
begin
  N := D.DeviceName;
  if N = '' then
    N := 'Meshtastic radio';
  Result := Format('%s%s [%s]', [BLE_PREFIX, N, D.Identifier]);
end;

function DescribeDevice(D: TBluetoothLEDevice): string;
var
  U: TBluetoothUUID;
begin
  Result := Format('"%s" [%s]', [D.DeviceName, D.Identifier]);
  try
    if D.ScannedAdvertiseData <> nil then
      for U in D.ScannedAdvertiseData.ServiceUUIDs do
        Result := Result + ' ' + U.ToString;
  except
  end;
end;

procedure TScanner.DiscoveryEnd(const Sender: TObject; const ADeviceList: TBluetoothLEDeviceList);
var
  Names, Report: TList<string>;
  D: TBluetoothLEDevice;
  Done: TBleScanDone;
  Arr: TArray<string>;
begin
  Names := TList<string>.Create;
  Report := TList<string>.Create;
  try
    if ADeviceList <> nil then
      for D in ADeviceList do
      begin
        Report.Add(DescribeDevice(D));
        if IsMeshtastic(D) and not Names.Contains(PortNameOf(D)) then
          Names.Add(PortNameOf(D));
      end;
    Arr := Names.ToArray;
    BleScanReport := Report.ToArray;
  finally
    Names.Free;
    Report.Free;
  end;
  Done := OnDone;
  OnDone := nil;
  if Assigned(Done) then
    TThread.Queue(nil, procedure begin Done(Arr, ''); end);
end;

procedure StartBleScan(Seconds: Integer; const OnDone: TBleScanDone);
var
  Why: string;
begin
  if not BleAvailable(Why) then
  begin
    OnDone(nil, Why);
    Exit;
  end;
  if GScanner = nil then
    GScanner := TScanner.Create;
  if Assigned(GScanner.OnDone) then
    TBluetoothLEManager.Current.CancelDiscovery;
  GScanner.OnDone := OnDone;
  TBluetoothLEManager.Current.OnDiscoveryEnd := GScanner.DiscoveryEnd;
  // no scan filter: the radio may list its service in the scan response,
  // which some filters miss; IsMeshtastic checks each device instead
  if not TBluetoothLEManager.Current.StartDiscovery(Seconds * 1000) then
  begin
    GScanner.OnDone := nil;
    OnDone(nil, 'Could not start the Bluetooth scan');
  end;
end;

function FindDevice(const Address: string): TBluetoothLEDevice;
var
  D: TBluetoothLEDevice;
begin
  Result := nil;
  for D in TBluetoothLEManager.Current.AllDiscoveredDevices do
    if SameText(D.Identifier, Address) then
      Exit(D);
  for D in TBluetoothLEManager.Current.LastDiscoveredDevices do
    if SameText(D.Identifier, Address) then
      Exit(D);
end;

{ The worker }

type
  TBleWorker = class(TThread)
  private
    FOwner: TMeshBleTransport;
    FDevice: TBluetoothLEDevice;
    FToRadio, FFromRadio, FFromNum: TBluetoothGattCharacteristic;
    FReadDone, FMtuDone: TEvent;
    FReadOk, FLost: Boolean;
    procedure CharRead(const Sender: TObject; const ACharacteristic: TBluetoothGattCharacteristic;
      AGattStatus: TBluetoothGattStatus);
    procedure MtuChanged(const Sender: TObject; AMTU: Integer; AGattStatus: TBluetoothGattStatus);
    procedure Disconnected(Sender: TObject);
    procedure Setup;
    procedure WriteOut;
    procedure Drain;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TMeshBleTransport);
    destructor Destroy; override;
  end;

constructor TBleWorker.Create(AOwner: TMeshBleTransport);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := AOwner;
  FReadDone := TEvent.Create(nil, False, False, '');
  FMtuDone := TEvent.Create(nil, False, False, '');
end;

destructor TBleWorker.Destroy;
begin
  FReadDone.Free;
  FMtuDone.Free;
  inherited;
end;

procedure TBleWorker.CharRead(const Sender: TObject; const ACharacteristic: TBluetoothGattCharacteristic;
  AGattStatus: TBluetoothGattStatus);
begin
  if ACharacteristic = nil then
    Exit;
  if (ACharacteristic = FFromNum) or SameText(ACharacteristic.UUID.ToString, FROM_NUM.ToString) then
    FOwner.FWake.SetEvent              // a notification: something new to read
  else if (ACharacteristic = FFromRadio) or SameText(ACharacteristic.UUID.ToString, FROM_RADIO.ToString) then
  begin
    FReadOk := AGattStatus = TBluetoothGattStatus.Success;
    FReadDone.SetEvent;
  end;
end;

procedure TBleWorker.MtuChanged(const Sender: TObject; AMTU: Integer; AGattStatus: TBluetoothGattStatus);
begin
  FMtuDone.SetEvent;
end;

procedure TBleWorker.Disconnected(Sender: TObject);
begin
  FOwner.DoLine('BLE: the radio disconnected');
  {$IFDEF ANDROID}
  FLost := True;
  FOwner.FWake.SetEvent;
  FReadDone.SetEvent;
  {$ENDIF}
  // Windows reports a disconnect between operations and reconnects by itself
  // on the next one; a real loss shows up as failing reads/writes
end;

procedure TBleWorker.Setup;
var
  Service: TBluetoothGattService;
  C: TBluetoothGattCharacteristic;
  Tries: Integer;
  Found: string;
begin
  FDevice := FindDevice(FOwner.FAddress);
  if FDevice = nil then
    raise Exception.Create('Radio not found: search for Bluetooth radios again, then connect');
  FOwner.DoLine('BLE: connecting to ' + FDevice.DeviceName);
  FDevice.OnCharacteristicRead := CharRead;
  FDevice.OnMTUChanged := MtuChanged;
  FDevice.OnDisconnect := Disconnected;
  if not FDevice.IsConnected then
    FDevice.Connect;                   // Android; Windows connects on first use
  Service := nil;
  for Tries := 1 to 3 do
  begin
    if Terminated then
      Exit;
    if FDevice.DiscoverServices then
      Service := FDevice.GetService(MESH_SERVICE);
    if Service <> nil then
      Break;
    Sleep(1000);
  end;
  FOwner.DoLine('BLE: services found');
  if Service = nil then
    raise Exception.Create('The radio did not offer the Meshtastic service (is it in range and ' +
      'Bluetooth enabled on it?)');
  // matched by hand: Service.GetCharacteristic did not find them on Android
  for C in Service.Characteristics do
    if SameText(C.UUID.ToString, TO_RADIO.ToString) then
      FToRadio := C
    else if SameText(C.UUID.ToString, FROM_RADIO.ToString) then
      FFromRadio := C
    else if SameText(C.UUID.ToString, FROM_NUM.ToString) then
      FFromNum := C;
  if (FToRadio = nil) or (FFromRadio = nil) then
  begin
    Found := '';
    for C in Service.Characteristics do
      Found := Found + ' ' + C.UUID.ToString;
    raise Exception.Create('The radio''s Bluetooth service is missing parts. It has:' + Found);
  end;
  // big packets in one go (Android starts at 23 bytes; Windows negotiates itself)
  if FDevice.RequestMTU(512) then
    FMtuDone.WaitFor(3000);
  if FFromNum <> nil then
    if not FDevice.SetCharacteristicNotification(FFromNum, True) then
      FOwner.DoLine('BLE: could not turn on notifications (polling instead)');
  FOwner.DoLine('BLE: ready');
end;

procedure TBleWorker.WriteOut;
var
  Data: TBytes;
  Tries: Integer;
begin
  for Data in FOwner.TakeOutgoing do
  begin
    FToRadio.SetValue(Data);
    Tries := 0;
    while not FDevice.WriteCharacteristic(FToRadio) do
    begin
      Inc(Tries);
      // the first connection pairs: Android shows the PIN dialog and the
      // writes fail until it is answered, so give the user time to type it
      if (Tries >= 60) or FLost or Terminated then
        raise Exception.Create('Could not send to the radio over Bluetooth. If Android asked ' +
          'for a PIN, enter the radio''s (123456 unless it shows or was set to another), then connect again.');
      Sleep(1000);
    end;
  end;
end;

procedure TBleWorker.Drain;
var
  V: TBytes;
  Fails: Integer;
begin
  Fails := 0;
  while not Terminated and not FLost do
  begin
    FReadOk := False;
    FReadDone.ResetEvent;
    if not FDevice.ReadCharacteristic(FFromRadio) then
      raise Exception.Create('Bluetooth read failed');
    if FReadDone.WaitFor(10000) <> wrSignaled then
      raise Exception.Create('The radio stopped answering over Bluetooth');
    if not FReadOk then
    begin
      Inc(Fails);                      // not paired yet: Android asks for the PIN now
      if Fails >= 30 then
        {$IFDEF MSWINDOWS}
        raise Exception.Create('The radio only talks to paired devices, and Windows does not ask ' +
          'for the PIN by itself. Pair it once in Settings > Bluetooth & devices > Add device > ' +
          'Bluetooth (PIN 123456 unless the radio uses another), then connect again.');
        {$ELSE}
        raise Exception.Create('The radio refused the Bluetooth read (pairing PIN not entered?)');
        {$ENDIF}
      Sleep(1000);
      Continue;
    end;
    V := FFromRadio.GetValue;
    if Length(V) = 0 then
      Break;                           // nothing more for now
    FOwner.DoFrame(V);
    WriteOut;                          // keep requests flowing during a long download
  end;
end;

procedure TBleWorker.Execute;
var
  Reason: string;
begin
  Reason := '';
  try
    Setup;
    while not Terminated and not FLost do
    begin
      WriteOut;
      Drain;
      FOwner.FWake.WaitFor(2000);      // FromNum notification, an outgoing message, or poll
    end;
    if not FLost then
      WriteOut;                        // e.g. a final "disconnect" message
    if FLost and not Terminated then
      Reason := 'Bluetooth connection lost';
  except
    on E: Exception do
      Reason := E.Message;
  end;
  if FDevice <> nil then
  try
    FDevice.OnCharacteristicRead := nil;
    FDevice.OnMTUChanged := nil;
    FDevice.OnDisconnect := nil;
    if FFromNum <> nil then
      FDevice.SetCharacteristicNotification(FFromNum, False);
    FDevice.Disconnect;
  except
    // already gone
  end;
  if not Terminated or (Reason <> '') then
    FOwner.DoClosed(Reason);
end;

{ TMeshBleTransport }

constructor TMeshBleTransport.Create(const PortName: string);
var
  A, B: Integer;
begin
  inherited Create;
  FPortName := PortName;
  A := PortName.LastIndexOf('[');
  B := PortName.LastIndexOf(']');
  if (A >= 0) and (B > A) then
    FAddress := PortName.Substring(A + 1, B - A - 1)
  else
    FAddress := PortName.Substring(Length(BLE_PREFIX)).Trim;
  FLock := TCriticalSection.Create;
  FOut := TList<TBytes>.Create;
  FWake := TEvent.Create(nil, False, False, '');
end;

destructor TMeshBleTransport.Destroy;
begin
  inherited;          // Stop
  FOut.Free;
  FLock.Free;
  FWake.Free;
end;

function TMeshBleTransport.Description: string;
begin
  Result := FPortName;
end;

procedure TMeshBleTransport.Start;
begin
  FThread := TBleWorker.Create(Self);
  FThread.Start;
end;

procedure TMeshBleTransport.DoStop;
var
  T: TThread;
begin
  T := FThread;
  FThread := nil;
  if T <> nil then
  begin
    T.Terminate;
    FWake.SetEvent;
    T.WaitFor;
    T.Free;
  end;
end;

function TMeshBleTransport.TakeOutgoing: TArray<TBytes>;
begin
  FLock.Enter;
  try
    Result := FOut.ToArray;
    FOut.Clear;
  finally
    FLock.Leave;
  end;
end;

procedure TMeshBleTransport.SendPayload(const Payload: TBytes);
begin
  if Length(Payload) > 512 then
    raise Exception.Create('Meshtastic payload too large');
  FLock.Enter;
  try
    FOut.Add(Copy(Payload));
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

initialization

finalization
  GScanner.Free;

end.
