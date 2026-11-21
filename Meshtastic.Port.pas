unit Meshtastic.Port;

{ A byte stream to the radio: a COM port on Windows, a USB serial device on
  Android (Meshtastic.Usb.Android, from UVScan). The same interface as
  UVScan's ISerialPort, so its drivers drop in unchanged.

  A port is owned and used by one thread (the transport's reader thread). }

interface

uses
  {$IFDEF MSWINDOWS}Winapi.Windows,{$ENDIF} System.SysUtils, System.Classes;

type
  ESerialError = class(Exception);

  TFlowControl = (fcNone, fcRtsCts);

  ISerialPort = interface
    ['{2E7B3C51-8A44-4F0C-9C1E-7D5B2A6E9F10}']
    procedure Open;
    procedure Close;
    function IsOpen: Boolean;
    { Waits up to TimeoutMs for at least one byte; returns bytes read (0 on timeout). }
    function Read(var Buffer; Count: Integer; TimeoutMs: Cardinal): Integer;
    procedure Write(const Data: TBytes);
    procedure Purge;
    function Description: string;
  end;

{ Serial ports the radio could be on: COM ports (USB ones first) on Windows,
  attached USB serial devices on Android. }
function ListSerialPorts: TArray<string>;

{ The port called Name, not opened yet. }
function CreateSerialPort(const Name: string): ISerialPort;

implementation

{$IFDEF MSWINDOWS}
uses
  System.Math, System.Win.Registry, System.Generics.Collections;

type
  TWinComPort = class(TInterfacedObject, ISerialPort)
  private
    FName: string;
    FHandle: THandle;
    FTimeout: Cardinal;
    procedure SetTimeout(Ms: Cardinal);
  public
    constructor Create(const Name: string);
    destructor Destroy; override;
    procedure Open;
    procedure Close;
    function IsOpen: Boolean;
    function Read(var Buffer; Count: Integer; TimeoutMs: Cardinal): Integer;
    procedure Write(const Data: TBytes);
    procedure Purge;
    function Description: string;
  end;

constructor TWinComPort.Create(const Name: string);
begin
  inherited Create;
  FName := Name;
  FHandle := INVALID_HANDLE_VALUE;
end;

destructor TWinComPort.Destroy;
begin
  Close;
  inherited;
end;

function TWinComPort.Description: string;
begin
  Result := FName;
end;

function TWinComPort.IsOpen: Boolean;
begin
  Result := FHandle <> INVALID_HANDLE_VALUE;
end;

procedure TWinComPort.Open;
const
  DTR_ENABLE = 1;
  RTS_ENABLE = 1;
var
  DCB: TDCB;
begin
  if IsOpen then
    Exit;
  FHandle := CreateFile(PChar('\\.\' + FName), GENERIC_READ or GENERIC_WRITE,
    0, nil, OPEN_EXISTING, 0, 0);
  if FHandle = INVALID_HANDLE_VALUE then
    raise ESerialError.CreateFmt('%s: %s', [FName, SysErrorMessage(GetLastError)]);
  SetupComm(FHandle, 16384, 4096);
  FillChar(DCB, SizeOf(DCB), 0);
  DCB.DCBlength := SizeOf(DCB);
  GetCommState(FHandle, DCB);
  DCB.BaudRate := 115200;  // ignored by USB CDC, but set it sensibly
  DCB.ByteSize := 8;
  DCB.Parity := NOPARITY;
  DCB.StopBits := ONESTOPBIT;
  // fBinary(bit0) | fDtrControl(bits4-5) | fRtsControl(bits12-13)
  DCB.Flags := 1 or (DTR_ENABLE shl 4) or (RTS_ENABLE shl 12);
  if not SetCommState(FHandle, DCB) then
  begin
    Close;
    raise ESerialError.CreateFmt('%s: could not set up the port', [FName]);
  end;
  FTimeout := 0;
  SetTimeout(50);
  EscapeCommFunction(FHandle, SETDTR);
  PurgeComm(FHandle, PURGE_RXCLEAR or PURGE_TXCLEAR);
end;

procedure TWinComPort.SetTimeout(Ms: Cardinal);
var
  T: TCommTimeouts;
begin
  if Ms = FTimeout then
    Exit;
  FTimeout := Ms;
  // ReadFile returns as soon as any bytes arrive, or after Ms
  T.ReadIntervalTimeout := MAXDWORD;
  T.ReadTotalTimeoutMultiplier := MAXDWORD;
  T.ReadTotalTimeoutConstant := Max(1, Ms);
  T.WriteTotalTimeoutMultiplier := 0;
  T.WriteTotalTimeoutConstant := 2000;
  SetCommTimeouts(FHandle, T);
end;

procedure TWinComPort.Close;
begin
  if FHandle <> INVALID_HANDLE_VALUE then
  begin
    CloseHandle(FHandle);
    FHandle := INVALID_HANDLE_VALUE;
  end;
end;

function TWinComPort.Read(var Buffer; Count: Integer; TimeoutMs: Cardinal): Integer;
var
  Got: DWORD;
begin
  if not IsOpen then
    raise ESerialError.CreateFmt('%s is not open', [FName]);
  SetTimeout(TimeoutMs);
  if not ReadFile(FHandle, Buffer, Count, Got, nil) then
    raise ESerialError.CreateFmt('%s: %s', [FName, SysErrorMessage(GetLastError)]);
  Result := Got;
end;

procedure TWinComPort.Write(const Data: TBytes);
var
  Written: DWORD;
begin
  if Length(Data) = 0 then
    Exit;
  if not IsOpen then
    raise ESerialError.CreateFmt('%s is not open', [FName]);
  if not WriteFile(FHandle, Data[0], Length(Data), Written, nil) then
    raise ESerialError.CreateFmt('%s: %s', [FName, SysErrorMessage(GetLastError)]);
end;

procedure TWinComPort.Purge;
begin
  if IsOpen then
    PurgeComm(FHandle, PURGE_RXCLEAR or PURGE_TXCLEAR);
end;

function ListSerialPorts: TArray<string>;
var
  Reg: TRegistry;
  Names: TStringList;
  I: Integer;
  USB, Other: TList<string>;
begin
  // USB CDC ports (\Device\USBSER...) are listed first: most likely the radio.
  USB := TList<string>.Create;
  Other := TList<string>.Create;
  Names := TStringList.Create;
  Reg := TRegistry.Create(KEY_READ);
  try
    Reg.RootKey := HKEY_LOCAL_MACHINE;
    if Reg.OpenKeyReadOnly('HARDWARE\DEVICEMAP\SERIALCOMM') then
    begin
      Reg.GetValueNames(Names);
      for I := 0 to Names.Count - 1 do
        if Pos('USBSER', UpperCase(Names[I])) > 0 then
          USB.Add(Reg.ReadString(Names[I]))
        else
          Other.Add(Reg.ReadString(Names[I]));
    end;
    USB.Sort;
    Other.Sort;
    USB.AddRange(Other);
    Result := USB.ToArray;
  finally
    Reg.Free;
    Names.Free;
    USB.Free;
    Other.Free;
  end;
end;

function CreateSerialPort(const Name: string): ISerialPort;
begin
  Result := TWinComPort.Create(Name);
end;

{$ELSEIF DEFINED(ANDROID)}
uses
  Meshtastic.Usb.Android;

function ListSerialPorts: TArray<string>;
begin
  Result := ListUsbSerialPorts;
end;

function CreateSerialPort(const Name: string): ISerialPort;
begin
  Result := CreateUsbSerialPort(Name, 115200, fcNone);
end;

{$ELSE}
function ListSerialPorts: TArray<string>;
begin
  Result := nil;
end;

function CreateSerialPort(const Name: string): ISerialPort;
begin
  raise ESerialError.Create('No serial ports on this platform');
end;
{$ENDIF}

end.
