unit Meshtastic.Transport;

{ How MeshTerm talks to the radio, whatever the link:

  - TMeshStreamTransport: the Meshtastic "stream API" over a serial port (a
    COM port on Windows, USB serial on Android). Frames are
      0x94 0xC3 <len hi> <len lo> <protobuf payload (<=512 bytes)>
    and anything outside a frame is the firmware's plain-text debug log.
  - TMeshBleTransport (Meshtastic.Ble): the same protobufs over Bluetooth LE.

  A transport runs on a thread of its own; its events always arrive on the
  main thread, and none arrive after Stop returns. }

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections,
  Meshtastic.Port;

type
  TFrameEvent = procedure(const Payload: TBytes) of object;
  TLineEvent = procedure(const Line: string) of object;
  TClosedEvent = procedure(const Reason: string) of object;

  { Shared "still wanted" flag for events queued to the main thread: Stop
    clears it, so events queued before Stop are dropped. Main thread only. }
  TAliveFlag = class(TInterfacedObject)
  public
    Alive: Boolean;
  end;

  TMeshTransport = class
  private
    FAliveObj: TAliveFlag;
    FAlive: IInterface;          // keeps FAliveObj alive while events are queued
    FOnFrame: TFrameEvent;
    FOnLine: TLineEvent;
    FOnClosed: TClosedEvent;
  protected
    // any thread: hand the event to the main thread
    procedure DoFrame(const Payload: TBytes);
    procedure DoLine(const Line: string);
    procedure DoClosed(const Reason: string);
    procedure DoStop; virtual; abstract;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start; virtual; abstract;
    { Ends the link (after sending what is queued); no events after it. }
    procedure Stop;
    procedure SendPayload(const Payload: TBytes); virtual; abstract;
    function Description: string; virtual; abstract;
    property OnFrame: TFrameEvent read FOnFrame write FOnFrame;
    property OnLine: TLineEvent read FOnLine write FOnLine;
    property OnClosed: TClosedEvent read FOnClosed write FOnClosed;
  end;

  TMeshStreamTransport = class(TMeshTransport)
  private
    FPortName: string;
    FThread: TThread;
    FLock: TCriticalSection;
    FOut: TList<TBytes>;
    procedure SendRaw(const Data: TBytes);
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

const
  BLE_PREFIX = 'BLE ';     // port names of Bluetooth radios: 'BLE <name> [<address>]'

{ The transport for a port name from ListSerialPorts or the Bluetooth scan
  (not started yet). }
function CreateTransport(const PortName: string): TMeshTransport;
function IsBlePortName(const PortName: string): Boolean;

function StripAnsi(const S: string): string;

implementation

uses
  Meshtastic.Proto, Meshtastic.Ble;

const
  START1 = $94;
  START2 = $C3;
  MAX_FRAME = 512;

function IsBlePortName(const PortName: string): Boolean;
begin
  Result := PortName.StartsWith(BLE_PREFIX);
end;

function CreateTransport(const PortName: string): TMeshTransport;
begin
  if IsBlePortName(PortName) then
    Result := TMeshBleTransport.Create(PortName)
  else
    Result := TMeshStreamTransport.Create(PortName);
end;

function StripAnsi(const S: string): string;
var
  I: Integer;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create(Length(S));
  try
    I := 1;
    while I <= Length(S) do
    begin
      if (S[I] = #27) and (I < Length(S)) and (S[I + 1] = '[') then
      begin
        Inc(I, 2);
        while (I <= Length(S)) and not CharInSet(S[I], ['@'..'~']) do
          Inc(I);
        Inc(I);
      end
      else
      begin
        if S[I] >= ' ' then
          SB.Append(S[I]);
        Inc(I);
      end;
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{ TMeshTransport }

constructor TMeshTransport.Create;
begin
  inherited Create;
  FAliveObj := TAliveFlag.Create;
  FAliveObj.Alive := True;
  FAlive := FAliveObj;
end;

destructor TMeshTransport.Destroy;
begin
  Stop;
  inherited;
end;

procedure TMeshTransport.Stop;
begin
  FAliveObj.Alive := False;
  DoStop;
end;

procedure TMeshTransport.DoFrame(const Payload: TBytes);
var
  Flag: IInterface;
  Obj: TAliveFlag;
  H: TFrameEvent;
  P: TBytes;
begin
  H := FOnFrame;
  if not Assigned(H) then
    Exit;
  Flag := FAlive;
  Obj := FAliveObj;
  P := Copy(Payload);
  TThread.Queue(nil,
    procedure
    begin
      if Obj.Alive then
        H(P);
      Flag := nil;
    end);
end;

procedure TMeshTransport.DoLine(const Line: string);
var
  Flag: IInterface;
  Obj: TAliveFlag;
  H: TLineEvent;
begin
  H := FOnLine;
  if not Assigned(H) or (Line = '') then
    Exit;
  Flag := FAlive;
  Obj := FAliveObj;
  TThread.Queue(nil,
    procedure
    begin
      if Obj.Alive then
        H(Line);
      Flag := nil;
    end);
end;

procedure TMeshTransport.DoClosed(const Reason: string);
var
  Flag: IInterface;
  Obj: TAliveFlag;
  H: TClosedEvent;
begin
  H := FOnClosed;
  if not Assigned(H) then
    Exit;
  Flag := FAlive;
  Obj := FAliveObj;
  TThread.Queue(nil,
    procedure
    begin
      if Obj.Alive then
        H(Reason);
      Flag := nil;
    end);
end;

{ TMeshStreamTransport }

type
  TStreamThread = class(TThread)
  private
    FOwner: TMeshStreamTransport;
    FPort: ISerialPort;
    // parser state
    FState: Integer;
    FFrameLen: Integer;
    FFrame: TBytes;
    FFramePos: Integer;
    FText: TBytes;
    FTextLen: Integer;
    procedure Flush;
    procedure ProcessByte(B: Byte);
    procedure TextByte(B: Byte);
    procedure EmitLine;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TMeshStreamTransport);
  end;

constructor TStreamThread.Create(AOwner: TMeshStreamTransport);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := AOwner;
  SetLength(FFrame, MAX_FRAME);
  SetLength(FText, 1024);
end;

procedure TStreamThread.Flush;
var
  Data: TBytes;
begin
  for Data in FOwner.TakeOutgoing do
    FPort.Write(Data);
end;

procedure TStreamThread.EmitLine;
begin
  if FTextLen = 0 then
    Exit;
  FOwner.DoLine(StripAnsi(Utf8Text(FText, 0, FTextLen)));
  FTextLen := 0;
end;

procedure TStreamThread.TextByte(B: Byte);
begin
  if B = 10 then
    EmitLine
  else if B <> 13 then
  begin
    if FTextLen >= Length(FText) then
      EmitLine;
    FText[FTextLen] := B;
    Inc(FTextLen);
  end;
end;

procedure TStreamThread.ProcessByte(B: Byte);
begin
  case FState of
    0: if B = START1 then FState := 1 else TextByte(B);
    1: if B = START2 then
         FState := 2
       else
       begin
         FState := 0;
         TextByte(START1);
         ProcessByte(B);
       end;
    2: begin FFrameLen := B shl 8; FState := 3; end;
    3: begin
         FFrameLen := FFrameLen or B;
         if FFrameLen > MAX_FRAME then
           FState := 0           // corrupt header, resync
         else if FFrameLen = 0 then
         begin
           FOwner.DoFrame(nil);
           FState := 0;
         end
         else
         begin
           FFramePos := 0;
           FState := 4;
         end;
       end;
    4: begin
         FFrame[FFramePos] := B;
         Inc(FFramePos);
         if FFramePos >= FFrameLen then
         begin
           FOwner.DoFrame(Copy(FFrame, 0, FFrameLen));
           FState := 0;
         end;
       end;
  end;
end;

procedure TStreamThread.Execute;
var
  Buf: array[0..4095] of Byte;
  Got, I: Integer;
  Reason: string;
begin
  Reason := '';
  try
    FPort := CreateSerialPort(FOwner.FPortName);
    FPort.Open;
    try
      while not Terminated do
      begin
        Flush;
        Got := FPort.Read(Buf, SizeOf(Buf), 50);
        for I := 0 to Got - 1 do
          ProcessByte(Buf[I]);
      end;
      Flush; // e.g. a final "disconnect" message
    finally
      FPort.Close;
      FPort := nil;
    end;
  except
    on E: Exception do
      Reason := E.Message;
  end;
  if not Terminated or (Reason <> '') then
    FOwner.DoClosed(Reason);
end;

constructor TMeshStreamTransport.Create(const PortName: string);
begin
  inherited Create;
  FPortName := PortName;
  FLock := TCriticalSection.Create;
  FOut := TList<TBytes>.Create;
end;

destructor TMeshStreamTransport.Destroy;
begin
  inherited;          // Stop
  FOut.Free;
  FLock.Free;
end;

function TMeshStreamTransport.Description: string;
begin
  Result := FPortName;
end;

procedure TMeshStreamTransport.Start;
begin
  // Wake the radio (32 x START2) before the first request
  SendRaw(TBytes.Create($C3, $C3, $C3, $C3, $C3, $C3, $C3, $C3,
    $C3, $C3, $C3, $C3, $C3, $C3, $C3, $C3, $C3, $C3, $C3, $C3, $C3, $C3,
    $C3, $C3, $C3, $C3, $C3, $C3, $C3, $C3, $C3, $C3));
  FThread := TStreamThread.Create(Self);
  FThread.Start;
end;

procedure TMeshStreamTransport.DoStop;
var
  T: TThread;
begin
  T := FThread;
  FThread := nil;
  if T <> nil then
  begin
    T.Terminate;
    T.WaitFor;
    T.Free;
  end;
end;

procedure TMeshStreamTransport.SendRaw(const Data: TBytes);
begin
  FLock.Enter;
  try
    FOut.Add(Copy(Data));
  finally
    FLock.Leave;
  end;
end;

function TMeshStreamTransport.TakeOutgoing: TArray<TBytes>;
begin
  FLock.Enter;
  try
    Result := FOut.ToArray;
    FOut.Clear;
  finally
    FLock.Leave;
  end;
end;

procedure TMeshStreamTransport.SendPayload(const Payload: TBytes);
var
  Frame: TBytes;
  L: Integer;
begin
  L := Length(Payload);
  if L > MAX_FRAME then
    raise Exception.Create('Meshtastic payload too large');
  SetLength(Frame, L + 4);
  Frame[0] := START1;
  Frame[1] := START2;
  Frame[2] := Byte(L shr 8);
  Frame[3] := Byte(L);
  if L > 0 then
    Move(Payload[0], Frame[4], L);
  SendRaw(Frame);
end;

end.
