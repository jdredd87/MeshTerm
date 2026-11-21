unit MainFormX;

{ MeshTerm's FireMonkey main form (Windows and Android). The UI is built in
  code, like the VCL version, so there is no .fmx file.

  Layout works from a phone up: a connection bar on top, then tabs
  (Messages, Nodes, Log), each usable with a finger. }

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.DateUtils,
  System.Math, System.Generics.Collections, System.Generics.Defaults, System.IniFiles,
  System.IOUtils,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.StdCtrls, FMX.Layouts,
  FMX.ListBox, FMX.Edit, FMX.Memo, FMX.Memo.Types, FMX.TabControl, FMX.Controls.Presentation,
  FMX.ScrollBox,
  Meshtastic.Proto, Meshtastic.Client, Meshtastic.Transport;

type
  TDest = record
    Dest: Cardinal;
    Channel: Cardinal;
  end;

  TMainFormX = class(TForm)
  private
    FClient: TMeshClient;
    FTimer: TTimer;
    FFriends: TList<Cardinal>;
    FDests: TList<TDest>;
    FPending: TDictionary<Cardinal, TListBoxItem>;
    FNodesDirty: Boolean;
    FScanning: Boolean;
    FBlePorts: TArray<string>;
    FAutoConnect: string;
    // connection bar
    cbPort: TComboBox;
    btnScan, btnConnect: TButton;
    lblStatus: TLabel;
    // tabs
    Tabs: TTabControl;
    tabChat, tabNodes, tabLog: TTabItem;
    lbChat: TListBox;
    cbDest: TComboBox;
    edMsg: TEdit;
    btnSend: TButton;
    edFind: TEdit;
    lbNodes: TListBox;
    memoLog: TMemo;
    procedure BuildUI;
    procedure FillPorts(const Select: string);
    procedure RefreshStatus;
    procedure RefreshDests;
    procedure RefreshNodes;
    procedure AddLog(const S: string);
    function AddChat(const Text, Detail: string): TListBoxItem;
    procedure LoadFriends;
    function SelectedPort: string;
    // UI events
    procedure ScanClick(Sender: TObject);
    procedure ConnectClick(Sender: TObject);
    procedure SendClick(Sender: TObject);
    procedure MsgKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure FindChange(Sender: TObject);
    procedure NodeClick(const Sender: TCustomListBox; const Item: TListBoxItem);
    procedure TimerTick(Sender: TObject);
    procedure DoScan(const AfterFound: TProc = nil);
    // client events
    procedure ClientLog(Sender: TObject; const Line: string);
    procedure ClientDeviceLog(Sender: TObject; const Line: string);
    procedure ClientState(Sender: TObject);
    procedure ClientNode(Sender: TObject; const Node: TNodeInfo);
    procedure ClientText(Sender: TObject; const Packet: TMeshPacket; const Text: string);
    procedure ClientAck(Sender: TObject; PacketId: Cardinal; ErrorCode: Integer; FromNode: Cardinal);
    procedure ClientLost(Sender: TObject; const Reason: string);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  MainFormXInstance: TMainFormX;

implementation

uses
  {$IFDEF ANDROID}System.Permissions, FMX.DialogService.Async,{$ENDIF}
  Meshtastic.Port, Meshtastic.Ble;

const
  STAR = #$2605;
  DOT = '  '#$00B7'  ';

function IniPath: string;
var
  Dir: string;
begin
  Dir := TPath.Combine(TPath.GetHomePath, 'MeshTerm');
  ForceDirectories(Dir);
  Result := TPath.Combine(Dir, 'MeshTerm.ini');
end;

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

{ TMainFormX }

constructor TMainFormX.Create(AOwner: TComponent);
var
  I: Integer;
begin
  inherited CreateNew(AOwner);
  Caption := 'MeshTerm';
  Width := 900;
  Height := 640;
  Position := TFormPosition.ScreenCenter;
  FFriends := TList<Cardinal>.Create;
  FDests := TList<TDest>.Create;
  FPending := TDictionary<Cardinal, TListBoxItem>.Create;
  FClient := TMeshClient.Create;
  FClient.OnLog := ClientLog;
  FClient.OnDeviceLog := ClientDeviceLog;
  FClient.OnStateChange := ClientState;
  FClient.OnNodeUpdated := ClientNode;
  FClient.OnText := ClientText;
  FClient.OnAck := ClientAck;
  FClient.OnConnectionLost := ClientLost;
  LoadFriends;
  BuildUI;
  FillPorts('');
  RefreshDests;
  RefreshStatus;
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 1000;
  FTimer.OnTimer := TimerTick;
  // for testing: MeshTermX -connect COM11|BLE [-tab nodes|log]
  FAutoConnect := '';
  for I := 1 to ParamCount - 1 do
    if SameText(ParamStr(I), '-connect') then
      FAutoConnect := ParamStr(I + 1)
    else if SameText(ParamStr(I), '-tab') then
      if SameText(ParamStr(I + 1), 'nodes') then
        Tabs.ActiveTab := tabNodes
      else if SameText(ParamStr(I + 1), 'log') then
        Tabs.ActiveTab := tabLog;
end;

destructor TMainFormX.Destroy;
begin
  if FTimer <> nil then
    FTimer.Enabled := False;
  FClient.Free;
  FPending.Free;
  FDests.Free;
  FFriends.Free;
  inherited;
end;

procedure TMainFormX.BuildUI;
var
  Bar, Row, SendBar, FindBar: TLayout;
begin
  // --- connection bar ---
  Bar := TLayout.Create(Self);
  Bar.Parent := Self;
  Bar.Align := TAlignLayout.Top;
  Bar.Height := 86;
  Bar.Padding.Rect := RectF(6, 6, 6, 2);

  Row := TLayout.Create(Self);
  Row.Parent := Bar;
  Row.Align := TAlignLayout.Top;
  Row.Height := 40;

  btnScan := TButton.Create(Self);
  btnScan.Parent := Row;
  btnScan.Align := TAlignLayout.Right;
  btnScan.Width := 120;
  btnScan.Margins.Left := 6;
  btnScan.Text := 'Find Bluetooth';
  btnScan.OnClick := ScanClick;

  btnConnect := TButton.Create(Self);
  btnConnect.Parent := Row;
  btnConnect.Align := TAlignLayout.Right;
  btnConnect.Width := 100;
  btnConnect.Margins.Left := 6;
  btnConnect.Text := 'Connect';
  btnConnect.OnClick := ConnectClick;

  cbPort := TComboBox.Create(Self);
  cbPort.Parent := Row;
  cbPort.Align := TAlignLayout.Client;

  lblStatus := TLabel.Create(Self);
  lblStatus.Parent := Bar;
  lblStatus.Align := TAlignLayout.Client;
  lblStatus.Margins.Top := 4;
  lblStatus.WordWrap := True;
  lblStatus.Text := 'Not connected';

  // --- tabs ---
  Tabs := TTabControl.Create(Self);
  Tabs.Parent := Self;
  Tabs.Align := TAlignLayout.Client;
  tabChat := Tabs.Add;
  tabChat.Text := 'Messages';
  tabNodes := Tabs.Add;
  tabNodes.Text := 'Nodes';
  tabLog := Tabs.Add;
  tabLog.Text := 'Log';

  // messages: list + send bar
  SendBar := TLayout.Create(Self);
  SendBar.Parent := tabChat;
  SendBar.Align := TAlignLayout.Bottom;
  SendBar.Height := 92;
  SendBar.Padding.Rect := RectF(4, 4, 4, 4);

  cbDest := TComboBox.Create(Self);
  cbDest.Parent := SendBar;
  cbDest.Align := TAlignLayout.Top;
  cbDest.Height := 36;

  btnSend := TButton.Create(Self);
  btnSend.Parent := SendBar;
  btnSend.Align := TAlignLayout.Right;
  btnSend.Width := 80;
  btnSend.Margins.Top := 6;
  btnSend.Margins.Left := 6;
  btnSend.Text := 'Send';
  btnSend.OnClick := SendClick;

  edMsg := TEdit.Create(Self);
  edMsg.Parent := SendBar;
  edMsg.Align := TAlignLayout.Client;
  edMsg.Margins.Top := 6;
  edMsg.TextPrompt := 'Type a message';
  edMsg.MaxLength := 200;
  edMsg.OnKeyDown := MsgKeyDown;
  edMsg.ReturnKeyType := TReturnKeyType.Send;

  lbChat := TListBox.Create(Self);
  lbChat.Parent := tabChat;
  lbChat.Align := TAlignLayout.Client;
  lbChat.DefaultItemStyles.ItemStyle := 'listboxitembottomdetail';
  lbChat.ItemHeight := 52;

  // nodes: search + list
  FindBar := TLayout.Create(Self);
  FindBar.Parent := tabNodes;
  FindBar.Align := TAlignLayout.Top;
  FindBar.Height := 44;
  FindBar.Padding.Rect := RectF(4, 4, 4, 4);
  edFind := TEdit.Create(Self);
  edFind.Parent := FindBar;
  edFind.Align := TAlignLayout.Client;
  edFind.TextPrompt := 'Search name, ID or hardware';
  edFind.OnChangeTracking := FindChange;

  lbNodes := TListBox.Create(Self);
  lbNodes.Parent := tabNodes;
  lbNodes.Align := TAlignLayout.Client;
  lbNodes.DefaultItemStyles.ItemStyle := 'listboxitembottomdetail';
  lbNodes.ItemHeight := 52;
  lbNodes.OnItemClick := NodeClick;

  // log
  memoLog := TMemo.Create(Self);
  memoLog.Parent := tabLog;
  memoLog.Align := TAlignLayout.Client;
  memoLog.ReadOnly := True;
  memoLog.TextSettings.Font.Size := 11;
  memoLog.TextSettings.WordWrap := True;

  Tabs.ActiveTab := tabChat;
end;

procedure TMainFormX.AddLog(const S: string);
begin
  memoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + S);
  if memoLog.Lines.Count > 2000 then
    memoLog.Lines.Delete(0);
  memoLog.GoToTextEnd;
end;

function TMainFormX.AddChat(const Text, Detail: string): TListBoxItem;
begin
  Result := TListBoxItem.Create(lbChat);
  Result.Parent := lbChat;
  Result.StyleLookup := 'listboxitembottomdetail';
  Result.Text := Text;
  Result.ItemData.Detail := Detail;
  Result.Height := 52;
  lbChat.ScrollToItem(Result);
end;

procedure TMainFormX.LoadFriends;
var
  Ini: TIniFile;
  T: string;
  N: Cardinal;
begin
  FFriends.Clear;
  try
    Ini := TIniFile.Create(IniPath);
    try
      for T in Ini.ReadString('MQTT', 'Friends', '').Split([',']) do
      begin
        N := ParseNodeId(T);
        if (N <> 0) and not FFriends.Contains(N) then
          FFriends.Add(N);
      end;
    finally
      Ini.Free;
    end;
  except
    // no settings yet
  end;
end;

function TMainFormX.SelectedPort: string;
begin
  if cbPort.ItemIndex >= 0 then
    Result := cbPort.Items[cbPort.ItemIndex]
  else
    Result := '';
end;

procedure TMainFormX.FillPorts(const Select: string);
var
  P, Prev: string;
begin
  Prev := Select;
  if Prev = '' then
    Prev := SelectedPort;
  cbPort.Items.BeginUpdate;
  try
    cbPort.Items.Clear;
    for P in ListSerialPorts do
      cbPort.Items.Add(P);
    for P in FBlePorts do
      cbPort.Items.Add(P);
  finally
    cbPort.Items.EndUpdate;
  end;
  cbPort.ItemIndex := cbPort.Items.IndexOf(Prev);
  if (cbPort.ItemIndex < 0) and (cbPort.Items.Count > 0) then
    cbPort.ItemIndex := 0;
end;

procedure TMainFormX.RefreshStatus;
var
  S: string;
begin
  case FClient.State of
    msDisconnected: S := 'Not connected';
    msConnecting: S := 'Connecting...';
    msReady: S := 'Connected';
  end;
  if FClient.MyNodeNum <> 0 then
    S := S + DOT + FClient.NodeName(FClient.MyNodeNum) + ' ' + NodeIdStr(FClient.MyNodeNum);
  if FClient.LoRa.Valid then
    S := S + DOT + RegionName(FClient.LoRa.Region) + ' / ' + ModemPresetName(FClient.LoRa.ModemPreset);
  if FClient.State <> msDisconnected then
    S := S + DOT + Format('%d nodes', [FClient.Nodes.Count]);
  lblStatus.Text := S;
  if FClient.State = msDisconnected then
    btnConnect.Text := 'Connect'
  else
    btnConnect.Text := 'Disconnect';
  cbPort.Enabled := FClient.State = msDisconnected;
  btnScan.Enabled := (FClient.State = msDisconnected) and not FScanning;
  btnSend.Enabled := FClient.State = msReady;
end;

procedure TMainFormX.RefreshDests;
var
  C: TChannelInfo;
  D, Prev: TDest;
  HavePrev: Boolean;
  N: TNodeInfo;
  L: TList<TNodeInfo>;
  I: Integer;
begin
  HavePrev := (cbDest.ItemIndex >= 0) and (cbDest.ItemIndex < FDests.Count);
  if HavePrev then
    Prev := FDests[cbDest.ItemIndex];
  cbDest.Items.BeginUpdate;
  try
    cbDest.Items.Clear;
    FDests.Clear;
    for C in FClient.Channels do
    begin
      D.Dest := BROADCAST_ADDR;
      D.Channel := C.Index;
      FDests.Add(D);
      cbDest.Items.Add(Format('# %s (everyone)', [FClient.ChannelName(C.Index)]));
    end;
    if FDests.Count = 0 then
    begin
      D.Dest := BROADCAST_ADDR;
      D.Channel := 0;
      FDests.Add(D);
      cbDest.Items.Add('# Primary channel (everyone)');
    end;
    for I := 0 to FFriends.Count - 1 do
      if FFriends[I] <> FClient.MyNodeNum then
      begin
        D.Dest := FFriends[I];
        D.Channel := 0;
        FDests.Add(D);
        cbDest.Items.Add(STAR + ' ' + FClient.NodeName(FFriends[I]));
      end;
    L := TList<TNodeInfo>.Create;
    try
      for N in FClient.Nodes.Values do
        if (N.Num <> FClient.MyNodeNum) and not FFriends.Contains(N.Num) then
          L.Add(N);
      L.Sort(TComparer<TNodeInfo>.Construct(
        function(const A, B: TNodeInfo): Integer
        begin
          Result := CompareText(FClient.NodeName(A.Num), FClient.NodeName(B.Num));
        end));
      for N in L do
      begin
        D.Dest := N.Num;
        D.Channel := 0;
        FDests.Add(D);
        cbDest.Items.Add('@ ' + FClient.NodeName(N.Num));
      end;
    finally
      L.Free;
    end;
  finally
    cbDest.Items.EndUpdate;
  end;
  cbDest.ItemIndex := 0;
  if HavePrev then
    for I := 0 to FDests.Count - 1 do
      if (FDests[I].Dest = Prev.Dest) and (FDests[I].Channel = Prev.Channel) then
      begin
        cbDest.ItemIndex := I;
        Break;
      end;
end;

procedure TMainFormX.RefreshNodes;
var
  L: TList<TNodeInfo>;
  N: TNodeInfo;
  It: TListBoxItem;
  Find, T, D, Hay: string;
  SelNum: Cardinal;
begin
  FNodesDirty := False;
  SelNum := 0;
  if lbNodes.Selected <> nil then
    SelNum := Cardinal(lbNodes.Selected.Tag);
  Find := LowerCase(Trim(edFind.Text));
  L := TList<TNodeInfo>.Create;
  try
    for N in FClient.Nodes.Values do
    begin
      if Find <> '' then
      begin
        Hay := LowerCase(FClient.NodeName(N.Num) + ' ' + N.User.ShortName + ' ' + NodeIdStr(N.Num));
        if N.HasUser then
          Hay := Hay + ' ' + LowerCase(HwModelName(N.User.HwModel));
        if Pos(Find, Hay) = 0 then
          Continue;
      end;
      L.Add(N);
    end;
    // this radio, then friends, then most recently heard
    L.Sort(TComparer<TNodeInfo>.Construct(
      function(const A, B: TNodeInfo): Integer
        function Rank(const X: TNodeInfo): Integer;
        begin
          if X.Num = FClient.MyNodeNum then Result := 0
          else if FFriends.Contains(X.Num) then Result := 1
          else Result := 2;
        end;
      begin
        Result := Rank(A) - Rank(B);
        if Result = 0 then
          Result := CompareValue(Int64(B.LastHeard), Int64(A.LastHeard));
        if Result = 0 then
          Result := CompareText(FClient.NodeName(A.Num), FClient.NodeName(B.Num));
      end));
    lbNodes.BeginUpdate;
    try
      lbNodes.Clear;
      for N in L do
      begin
        T := FClient.NodeName(N.Num);
        if N.User.ShortName <> '' then
          T := T + ' (' + N.User.ShortName + ')';
        if N.Num = FClient.MyNodeNum then
          T := T + ' - this radio'
        else if FFriends.Contains(N.Num) then
          T := STAR + ' ' + T;
        D := NodeIdStr(N.Num);
        if N.LastHeard <> 0 then
          D := D + DOT + AgoStr(N.LastHeard);
        if N.Num <> FClient.MyNodeNum then
          if N.ViaMqtt then
            D := D + DOT + 'internet'
          else if N.HopsAway = 0 then
            D := D + DOT + 'direct'
          else if N.HopsAway > 0 then
            D := D + DOT + Format('%d hops', [N.HopsAway]);
        if N.Snr <> 0 then
          D := D + DOT + Format('SNR %.1f', [N.Snr]);
        if N.Metrics.Valid and (N.Metrics.BatteryLevel > 0) and (N.Metrics.BatteryLevel <= 100) then
          D := D + DOT + Format('%d%%', [N.Metrics.BatteryLevel]);
        if N.HasUser then
          D := D + DOT + HwModelName(N.User.HwModel);
        It := TListBoxItem.Create(lbNodes);
        It.Parent := lbNodes;
        It.StyleLookup := 'listboxitembottomdetail';
        It.Height := 52;
        It.Text := T;
        It.ItemData.Detail := D;
        It.Tag := NativeInt(N.Num);
        if N.Num = SelNum then
          It.IsSelected := True;
      end;
    finally
      lbNodes.EndUpdate;
    end;
    tabNodes.Text := Format('Nodes (%d)', [L.Count]);
  finally
    L.Free;
  end;
end;

{ UI events }

procedure TMainFormX.DoScan(const AfterFound: TProc);
begin
  FScanning := True;
  btnScan.Text := 'Searching...';
  RefreshStatus;
  AddLog('Looking for Meshtastic radios over Bluetooth (10 s)...');
  StartBleScan(10,
    procedure(const Names: TArray<string>; const Error: string)
    var
      P: string;
    begin
      FScanning := False;
      btnScan.Text := 'Find Bluetooth';
      if Error <> '' then
        AddLog('Bluetooth: ' + Error)
      else if Length(Names) = 0 then
      begin
        AddLog('No Meshtastic radio found over Bluetooth. Is Bluetooth on in the radio, and is it ' +
          'close by? (A radio connected to another phone does not show up.)');
        AddLog(Format('The scan saw %d other device(s):', [Length(BleScanReport)]));
        for P in BleScanReport do
          AddLog('  ' + P);
      end
      else
      begin
        for P in Names do
          AddLog('Found ' + P);
        FBlePorts := Names;
        FillPorts(Names[0]);
        if Assigned(AfterFound) then
          AfterFound();
      end;
      RefreshStatus;
    end);
end;

procedure TMainFormX.ScanClick(Sender: TObject);
{$IFDEF ANDROID}
var
  Perms: TArray<string>;
{$ENDIF}
begin
  if FScanning then
    Exit;
  {$IFDEF ANDROID}
  if TOSVersion.Check(12) then
    Perms := ['android.permission.BLUETOOTH_SCAN', 'android.permission.BLUETOOTH_CONNECT']
  else
    Perms := ['android.permission.ACCESS_FINE_LOCATION'];
  PermissionsService.RequestPermissions(Perms,
    procedure(const APermissions: TClassicStringDynArray; const AGrantResults: TClassicPermissionStatusDynArray)
    var
      G: TPermissionStatus;
    begin
      for G in AGrantResults do
        if G <> TPermissionStatus.Granted then
        begin
          if TOSVersion.Check(12) then
            AddLog('MeshTerm needs the "Nearby devices" permission to find the radio over Bluetooth.')
          else
            AddLog('MeshTerm needs the location permission to find the radio over Bluetooth ' +
              '(Android 11 and older), and Location must be switched on.');
          Exit;
        end;
      DoScan;
    end);
  {$ELSE}
  DoScan;
  {$ENDIF}
end;

procedure TMainFormX.ConnectClick(Sender: TObject);
var
  P: string;
begin
  if FClient.State <> msDisconnected then
  begin
    FClient.Disconnect;
    Exit;
  end;
  FillPorts('');
  P := SelectedPort;
  if P = '' then
  begin
    AddLog('No radio to connect to. Plug it in (USB), or tap Find Bluetooth.');
    Tabs.ActiveTab := tabLog;
    Exit;
  end;
  FPending.Clear;
  FClient.Connect(P);
end;

procedure TMainFormX.SendClick(Sender: TObject);
var
  Text, ToName: string;
  D: TDest;
  Id: Cardinal;
  It: TListBoxItem;
begin
  Text := Trim(edMsg.Text);
  if (Text = '') or (FClient.State <> msReady) then
    Exit;
  if (cbDest.ItemIndex < 0) or (cbDest.ItemIndex >= FDests.Count) then
    Exit;
  if Length(TEncoding.UTF8.GetBytes(Text)) > MAX_TEXT_BYTES then
  begin
    AddLog('Message too long');
    Exit;
  end;
  D := FDests[cbDest.ItemIndex];
  try
    Id := FClient.SendText(Text, D.Dest, D.Channel);
  except
    on E: Exception do
    begin
      AddLog('Send failed: ' + E.Message);
      Exit;
    end;
  end;
  if D.Dest = BROADCAST_ADDR then
    ToName := '#' + FClient.ChannelName(D.Channel)
  else
    ToName := FClient.NodeName(D.Dest);
  It := AddChat(Text, FormatDateTime('hh:nn', Now) + '  me ' + #$2192 + ' ' + ToName + DOT + 'sending...');
  It.TagString := FormatDateTime('hh:nn', Now) + '  me ' + #$2192 + ' ' + ToName;
  FPending.AddOrSetValue(Id, It);
  edMsg.Text := '';
end;

procedure TMainFormX.MsgKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  if Key = vkReturn then
  begin
    Key := 0;
    SendClick(Sender);
  end;
end;

procedure TMainFormX.FindChange(Sender: TObject);
begin
  RefreshNodes;
end;

procedure TMainFormX.NodeClick(const Sender: TCustomListBox; const Item: TListBoxItem);
var
  Num: Cardinal;
  I: Integer;
begin
  Num := Cardinal(Item.Tag);
  if Num = FClient.MyNodeNum then
    Exit;
  for I := 0 to FDests.Count - 1 do
    if FDests[I].Dest = Num then
    begin
      cbDest.ItemIndex := I;
      Tabs.ActiveTab := tabChat;
      Exit;
    end;
end;

procedure TMainFormX.TimerTick(Sender: TObject);
begin
  if SameText(FAutoConnect, 'BLE') then
  begin
    // test: -connect BLE = find a radio over Bluetooth and connect to it
    FAutoConnect := '';
    DoScan(procedure begin FClient.Connect(SelectedPort); end);
  end
  else if FAutoConnect <> '' then
  begin
    FillPorts(FAutoConnect);
    if cbPort.Items.IndexOf(FAutoConnect) < 0 then
      cbPort.Items.Add(FAutoConnect);
    cbPort.ItemIndex := cbPort.Items.IndexOf(FAutoConnect);
    FAutoConnect := '';
    FClient.Connect(SelectedPort);
  end;
  FClient.Tick;
  if FNodesDirty then
    RefreshNodes;
end;

{ client events }

procedure TMainFormX.ClientLog(Sender: TObject; const Line: string);
begin
  AddLog(Line);
end;

procedure TMainFormX.ClientDeviceLog(Sender: TObject; const Line: string);
begin
  // only MeshTerm's own Bluetooth steps; the radio's debug output is too chatty here
  if Line.StartsWith('BLE: ') then
    AddLog(Line);
end;

procedure TMainFormX.ClientState(Sender: TObject);
begin
  RefreshStatus;
  if FClient.State = msReady then
  begin
    RefreshDests;
    FNodesDirty := True;
  end;
end;

procedure TMainFormX.ClientNode(Sender: TObject; const Node: TNodeInfo);
begin
  FNodesDirty := True;
  if Node.Num = FClient.MyNodeNum then
    RefreshStatus;
end;

procedure TMainFormX.ClientText(Sender: TObject; const Packet: TMeshPacket; const Text: string);
var
  ToName, D: string;
begin
  if Packet.To_ = BROADCAST_ADDR then
    ToName := '#' + FClient.ChannelName(Packet.Channel)
  else if Packet.To_ = FClient.MyNodeNum then
    ToName := 'me'
  else
    ToName := FClient.NodeName(Packet.To_);
  D := FormatDateTime('hh:nn', Now) + '  ' + FClient.NodeName(Packet.From) + ' ' + #$2192 + ' ' + ToName;
  if Packet.ViaMqtt then
    D := D + DOT + 'internet'
  else if Packet.RxSnr <> 0 then
    D := D + DOT + Format('SNR %.1f', [Packet.RxSnr]);
  AddChat(Text, D);
end;

procedure TMainFormX.ClientAck(Sender: TObject; PacketId: Cardinal; ErrorCode: Integer; FromNode: Cardinal);
var
  It: TListBoxItem;
  S: string;
begin
  if not FPending.TryGetValue(PacketId, It) then
    Exit;
  if ErrorCode = 0 then
  begin
    if (FromNode <> 0) and (FromNode <> FClient.MyNodeNum) then
      S := 'delivered ' + #$2713
    else
      S := 'sent';
  end
  else
    S := 'failed: ' + RoutingErrorName(ErrorCode);
  It.ItemData.Detail := It.TagString + DOT + S;
  if (ErrorCode <> 0) or ((FromNode <> 0) and (FromNode <> FClient.MyNodeNum)) then
    FPending.Remove(PacketId);
end;

procedure TMainFormX.ClientLost(Sender: TObject; const Reason: string);
begin
  if Reason <> '' then
    AddLog('Connection lost: ' + Reason)
  else
    AddLog('Connection lost');
  RefreshStatus;
end;

end.
