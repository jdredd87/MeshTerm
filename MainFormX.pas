unit MainFormX;

{ MeshTerm's FireMonkey main form (Windows and Android). The UI is built in
  code, so there is no .fmx file.

  Layout works from a phone up: a connection bar on top, then tabs -
  Messages, Nodes, Map, Channels, Internet, Log - each usable with a finger.
  The non-visual work lives in shared units: Meshtastic.Client (the radio),
  .NodeView (node filters/sorting), .Bridge (MQTT), .Settings (MeshTerm.ini),
  .Places (place search), MapViewX (the map) and FmxSheet (dialogs). }

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.DateUtils,
  System.Math, System.Generics.Collections, System.Generics.Defaults, System.IOUtils, System.Notification,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.StdCtrls, FMX.Layouts,
  FMX.ListBox, FMX.Edit, FMX.Memo, FMX.Memo.Types, FMX.TabControl, FMX.Controls.Presentation,
  FMX.ScrollBox, FMX.Objects, FMX.Platform,
  Meshtastic.Proto, Meshtastic.Client, Meshtastic.Transport, Meshtastic.Settings,
  Meshtastic.NodeView, Meshtastic.Bridge, Meshtastic.Places, MapViewX, FmxSheet;

type
  TDest = record
    Dest: Cardinal;
    Channel: Cardinal;
  end;

  TPendingMsg = record
    Item: TListBoxItem;
    Dest: Cardinal;
    Head: string;            // "12:34  me -> Bob" (the detail line before the status)
  end;

  TMainFormX = class(TForm)
  private
    FClient: TMeshClient;
    FSettings: TMeshSettings;
    FView: TNodeView;
    FBridge: TMeshBridge;
    FTimer: TTimer;
    FAliveObj: TAliveFlag;
    FAlive: IInterface;              // for callbacks that may arrive after the form is gone
    FDests: TList<TDest>;
    FPending: TDictionary<Cardinal, TPendingMsg>;
    FOrder: Single;                  // for stacking aligned controls in creation order
    FFlows: TList<TFlowLayout>;
    FEqualRows: TList<TLayout>;
    FTabNames: TDictionary<TTabItem, TPair<string, string>>;   // long, short caption
    FNarrow: Boolean;
    FNodesDirty, FNodeLoading, FScanning, FMapFitted, FFinding, FRegionWarned: Boolean;
    FBlePorts: TArray<string>;
    FAutoConnect: string;
    FLastPort: string;
    FReconnectUntil, FNextReconnect: TDateTime;
    FDiscoverUntil: TDateTime;
    FDiscoverStart: Int64;
    FShareAfterCreate: string;
    FMapSel: Cardinal;
    FAppActive: Boolean;
    FRootShown: string;
    // alerts
    FNotify: TNotificationCenter;
    FAlertDest: TDest;
    FLastAlert: TDateTime;
    FAlertHeld: Integer;
    FAlertHeldTitle, FAlertHeldText: string;
    // connection bar
    FBar: TLayout;
    cbPort: TComboBox;
    btnScan, btnConnect, btnMenu: TButton;
    lblStatus: TLabel;
    // tabs
    Tabs: TTabControl;
    tabChat, tabNodes, tabMap, tabChannels, tabNet, tabLog: TTabItem;
    // messages
    lbChat: TListBox;
    cbDest: TComboBox;
    edMsg: TEdit;
    btnSend: TButton;
    lblBytes: TLabel;
    // nodes
    edFind: TEdit;
    btnAddFriend, btnSortDir, btnDiscover: TButton;
    cbShow, cbHeard, cbSort: TComboBox;
    chkFriendsTop: TCheckBox;
    lblNodeCount, lblNodeInfo: TLabel;
    lbNodes: TListBox;
    pnlNodeInfo: TRectangle;
    btnNodeMsg, btnNodeFriend, btnNodeNote, btnNodeMap, btnNodeMore: TButton;
    // map
    Map: TMapViewX;
    btnMapPlace, btnMapFind, btnMapMsg: TButton;
    edMapFind: TEdit;
    chkMapLocal: TCheckBox;
    lblMapInfo, lblMapSel: TLabel;
    FMapFoot: TLayout;
    // channels
    lblChanInfo: TLabel;
    lbChannels: TListBox;
    btnNewChannel, btnShareChannel, btnJoinChannel, btnDeleteChannel: TButton;
    // internet
    NetTop: TLayout;
    lblNetMode, lblNetRadio, lblNetBroker, lblNetStats: TLabel;
    edRoot, edExtra, edFriends: TEdit;
    btnSetRoot, btnExtra, btnFriends, btnInternet, btnRadioOnly: TButton;
    chkNetAll: TCheckBox;
    memoNet: TMemo;
    // log
    chkDeviceLog: TCheckBox;
    memoLog: TMemo;

    // building
    procedure BuildUI;
    procedure BuildBar;
    procedure BuildChatTab;
    procedure BuildNodesTab;
    procedure BuildMapTab;
    procedure BuildChannelsTab;
    procedure BuildNetTab;
    procedure BuildLogTab;
    procedure Stack(C: TControl; AParent: TFmxObject; A: TAlignLayout);
    function MakeButton(AParent: TFmxObject; const AText: string; AWidth: Single;
      AOnClick: TNotifyEvent): TButton;
    function MakeLabel(AParent: TFmxObject; Size: Single = 0; Bold: Boolean = False): TLabel;
    function MakeFlow(AParent: TFmxObject; A: TAlignLayout): TFlowLayout;
    function MakeCombo(AParent: TFmxObject; AWidth: Single; const Items: array of string): TComboBox;
    function MakeCheck(AParent: TFmxObject; const AText: string; AWidth: Single): TCheckBox;
    function MakeEqualRow(AParent: TFmxObject; A: TAlignLayout; AHeight: Single): TLayout;
    procedure EqualRowResized(Sender: TObject);
    procedure Relayout;
    procedure FitLabel(L: TLabel; MinH: Single = 0);
    procedure FormResized(Sender: TObject);
    procedure SetTab(T: TTabItem; const Long, Short: string);
    // general
    procedure AddLog(const S: string);
    procedure NetLog(const S: string);
    procedure FillPorts(const Select: string);
    function SelectedPort: string;
    procedure RefreshStatus;
    procedure RefreshDests;
    function SelectDest(Dest, Channel: Cardinal): Boolean;
    function AddChat(const Text, Detail: string; const LogFrom, LogTo, LogState: string): TListBoxItem;
    procedure CopyText(const S: string);
    function IsUserLooking: Boolean;
    procedure DoScan(const AfterFound: TProc = nil);
    procedure StartScan(const AfterFound: TProc);
    procedure FriendsChanged(const Msg: string);
    // connection bar / menu
    procedure ScanClick(Sender: TObject);
    procedure ConnectClick(Sender: TObject);
    procedure MenuClick(Sender: TObject);
    // messages
    procedure SendClick(Sender: TObject);
    procedure MsgKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure MsgChange(Sender: TObject);
    // nodes
    procedure RefreshNodeRows;
    procedure UpdateNodeInfo;
    procedure UpdateNodeButtons;
    function SelectedNodes: TArray<Cardinal>;
    procedure NodeFilterChange(Sender: TObject);
    procedure SortDirClick(Sender: TObject);
    procedure NodesChange(Sender: TObject);
    procedure NodesDblClick(Sender: TObject);
    procedure NodesKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure NodeMsgClick(Sender: TObject);
    procedure NodeFriendClick(Sender: TObject);
    procedure NodeNoteClick(Sender: TObject);
    procedure NodeMapClick(Sender: TObject);
    procedure NodeMoreClick(Sender: TObject);
    procedure RemoveFriends(const Nums: TArray<Cardinal>);
    procedure AddFriendClick(Sender: TObject);
    procedure DiscoverClick(Sender: TObject);
    procedure UpdateDiscoverButton;
    procedure FinishDiscover;
    procedure ToggleNoBattery(Num: Cardinal);
    // map
    procedure UpdateMapMarker(const N: TNodeInfo);
    procedure RebuildMap;
    procedure UpdateMapInfo;
    procedure ShowNodeOnMap(Num: Cardinal);
    procedure MapPlaceClick(Sender: TObject);
    procedure MapMeClick(Sender: TObject);
    procedure MapFitClick(Sender: TObject);
    procedure MapFindClick(Sender: TObject);
    procedure MapFindKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure MapLocalChange(Sender: TObject);
    procedure MapMsgClick(Sender: TObject);
    procedure MapMarkerClick(Sender: TObject; Id: Cardinal);
    procedure MapMarkerDblClick(Sender: TObject; Id: Cardinal);
    procedure MapPlaced(Sender: TObject; X, Y: Single; Lat, Lon: Double);
    procedure MapContext(Sender: TObject; X, Y: Single; Lat, Lon: Double);
    procedure MapPlaceModeChanged(Sender: TObject);
    procedure SetLocationAt(Lat, Lon: Double; const Done: TProc);
    procedure ClearLocation;
    procedure FindDone(const Query: string; const Places: TArray<TFoundPlace>; const Err: string);
    procedure ShowFoundPlace(const P: TFoundPlace);
    function NotConnected: Boolean;
    // channels
    procedure RefreshChannels;
    procedure UpdateChannelButtons;
    function SelectedChannel(out C: TChannelInfo): Boolean;
    procedure ChannelChange(Sender: TObject);
    procedure NewChannelClick(Sender: TObject);
    procedure AskChannelName(const Default: string);
    procedure CreateChannel(const Name: string);
    procedure ShareChannelClick(Sender: TObject);
    procedure JoinChannelClick(Sender: TObject);
    procedure JoinChannel(const Url: string);
    procedure DeleteChannelClick(Sender: TObject);
    procedure ShowShareSheet(const C: TChannelInfo);
    // internet
    procedure UpdateNetTab;
    procedure InternetClick(Sender: TObject);
    procedure RadioOnlyClick(Sender: TObject);
    procedure SetRootClick(Sender: TObject);
    procedure ExtraClick(Sender: TObject);
    procedure FriendsApplyClick(Sender: TObject);
    procedure NetAllChange(Sender: TObject);
    // log
    procedure DeviceLogChange(Sender: TObject);
    // alerts
    procedure SetupNotifications;
    procedure MaybeAlert(const Packet: TMeshPacket; const Text: string);
    procedure ShowAlert(const Title, Text: string);
    procedure NotificationClicked(Sender: TObject; ANotification: TNotification);
    function AppEvent(AAppEvent: TApplicationEvent; AContext: TObject): Boolean;
    // form / timer
    procedure TabChange(Sender: TObject);
    procedure TimerTick(Sender: TObject);
    procedure FormKeyUp(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure KeyboardShown(Sender: TObject; KeyboardVisible: Boolean; const Bounds: TRect);
    procedure KeyboardHidden(Sender: TObject; KeyboardVisible: Boolean; const Bounds: TRect);
    // client events
    procedure ClientLog(Sender: TObject; const Line: string);
    procedure ClientDeviceLog(Sender: TObject; const Line: string);
    procedure ClientState(Sender: TObject);
    procedure ClientNode(Sender: TObject; const Node: TNodeInfo);
    procedure ClientText(Sender: TObject; const Packet: TMeshPacket; const Text: string);
    procedure ClientAck(Sender: TObject; PacketId: Cardinal; ErrorCode: Integer; FromNode: Cardinal);
    procedure ClientMqttProxy(Sender: TObject; const Msg: TMqttProxyMessage);
    procedure ClientLost(Sender: TObject; const Reason: string);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  MainFormXInstance: TMainFormX;

implementation

uses
  {$IFDEF ANDROID}
  System.Permissions, Androidapi.Helpers, Androidapi.JNI.App, FMX.MediaLibrary,
  {$ENDIF}
  {$IFDEF MSWINDOWS}FMX.Platform.Win,{$ENDIF}
  FMX.Clipboard, FMX.Surfaces,
  Meshtastic.Port, Meshtastic.Ble, Meshtastic.Crypto, QrCode;

{$IFDEF MSWINDOWS}
function FlashWindow(hWnd: THandle; bInvert: LongBool): LongBool; stdcall; external 'user32.dll';
{$ENDIF}

const
  DOT = '  '#$00B7'  ';
  ARROW = ' '#$2192' ';
  CHECK = #$2713;
  UNREAD = ' '#$2022;
  {$IFDEF ANDROID}
  IS_TOUCH = True;
  LABEL_SIZE = 15;
  {$ELSE}
  IS_TOUCH = False;
  LABEL_SIZE = 12;
  {$ENDIF}

  SORT_COLS: array[0..12] of Integer = (NC_HEARD, NC_NAME, NC_DIST, NC_SNR, NC_RSSI, NC_HOPS,
    NC_BATTERY, NC_HW, NC_ROLE, NC_SHORT, NC_ID, NC_NOTE, NC_POS);
  SORT_NAMES: array[0..12] of string = ('Sort: last heard', 'Sort: name', 'Sort: distance',
    'Sort: signal (SNR)', 'Sort: RSSI', 'Sort: hops', 'Sort: battery', 'Sort: hardware',
    'Sort: role', 'Sort: short name', 'Sort: node ID', 'Sort: note', 'Sort: position');

  COLOR_ME = $FFD72828;
  COLOR_FRIEND = $FFF08C00;
  COLOR_LOCAL = $FF1E6EDC;
  COLOR_NET = $FF7D7D7D;

function OnOff(B: Boolean): string;
begin
  if B then Result := 'on' else Result := 'off';
end;

function ValidChannelName(const Name: string): Boolean;
var
  Ch: Char;
begin
  Result := (Length(Name) >= 1) and (Length(Name) <= 11);
  for Ch in Name do
    if not CharInSet(Ch, ['A'..'Z', 'a'..'z', '0'..'9', '-', '_']) then
      Exit(False);
end;

{ TMainFormX }

constructor TMainFormX.Create(AOwner: TComponent);
var
  I: Integer;
  T: string;
  Svc: IFMXApplicationEventService;
begin
  inherited CreateNew(AOwner);
  Caption := 'MeshTerm';
  Width := 1000;
  Height := 680;
  Position := TFormPosition.ScreenCenter;
  Randomize;
  FAliveObj := TAliveFlag.Create;
  FAliveObj.Alive := True;
  FAlive := FAliveObj;
  FAppActive := True;
  FDests := TList<TDest>.Create;
  FPending := TDictionary<Cardinal, TPendingMsg>.Create;
  FFlows := TList<TFlowLayout>.Create;
  FEqualRows := TList<TLayout>.Create;
  FTabNames := TDictionary<TTabItem, TPair<string, string>>.Create;
  FSettings := TMeshSettings.Create;
  FSettings.OnError := procedure(Msg: string) begin AddLog(Msg); end;
  FSettings.Load;
  FClient := TMeshClient.Create;
  FClient.OnLog := ClientLog;
  FClient.OnDeviceLog := ClientDeviceLog;
  FClient.OnStateChange := ClientState;
  FClient.OnNodeUpdated := ClientNode;
  FClient.OnText := ClientText;
  FClient.OnAck := ClientAck;
  FClient.OnMqttProxy := ClientMqttProxy;
  FClient.OnConnectionLost := ClientLost;
  FView := TNodeView.Create(FClient, FSettings);
  FBridge := TMeshBridge.Create(FClient, FSettings);
  FBridge.OnLog := procedure(S: string) begin NetLog(S); end;
  FBridge.OnChange := procedure begin UpdateNetTab; end;

  BuildUI;
  FillPorts('');
  RefreshDests;
  RefreshStatus;
  RefreshNodeRows;
  UpdateNetTab;
  UpdateMapInfo;
  SetupNotifications;
  OnResize := FormResized;
  OnKeyUp := FormKeyUp;
  OnVirtualKeyboardShown := KeyboardShown;
  OnVirtualKeyboardHidden := KeyboardHidden;
  if TPlatformServices.Current.SupportsPlatformService(IFMXApplicationEventService, Svc) then
    Svc.SetApplicationEventHandler(AppEvent);

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 1000;
  FTimer.OnTimer := TimerTick;

  // for testing: MeshTermX -connect COM11|BLE [-tab nodes|map|channels|internet|log]
  FAutoConnect := '';
  for I := 1 to ParamCount - 1 do
    if SameText(ParamStr(I), '-connect') then
      FAutoConnect := ParamStr(I + 1)
    else if SameText(ParamStr(I), '-tab') then
    begin
      T := LowerCase(ParamStr(I + 1));
      if T = 'nodes' then Tabs.ActiveTab := tabNodes
      else if T = 'map' then Tabs.ActiveTab := tabMap
      else if T = 'channels' then Tabs.ActiveTab := tabChannels
      else if T = 'internet' then Tabs.ActiveTab := tabNet
      else if T = 'log' then Tabs.ActiveTab := tabLog;
    end;
  // for testing: -testalert pops up a test notification
  if FindCmdLineSwitch('testalert', True) then
    TThread.ForceQueue(nil,
      procedure
      begin
        ShowAlert('MeshTerm test', 'This is how new messages will pop up.');
      end, 3000);
end;

destructor TMainFormX.Destroy;
begin
  FAliveObj.Alive := False;
  if FTimer <> nil then
    FTimer.Enabled := False;
  if (Map <> nil) and FMapFitted then
    FSettings.SaveMapView(Map.Zoom, Map.CenterLat, Map.CenterLon);
  FBridge.Free;               // before the client: it may still talk to it
  FClient.Free;               // sends "disconnect" to the radio
  FView.Free;
  FSettings.Free;
  FFlows.Free;
  FEqualRows.Free;
  FTabNames.Free;
  FPending.Free;
  FDests.Free;
  inherited;
end;

{ ---------------- building blocks ---------------- }

procedure TMainFormX.Stack(C: TControl; AParent: TFmxObject; A: TAlignLayout);
begin
  // aligned controls line up by position: give each a later one than the last
  FOrder := FOrder + 1000;
  C.Parent := AParent;
  C.Position.Y := FOrder;
  C.Position.X := FOrder;
  C.Align := A;
end;

function TMainFormX.MakeButton(AParent: TFmxObject; const AText: string; AWidth: Single;
  AOnClick: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Self);
  Result.Parent := AParent;
  Result.Text := AText;
  Result.Width := AWidth;
  Result.Height := 36;
  Result.OnClick := AOnClick;
end;

function TMainFormX.MakeLabel(AParent: TFmxObject; Size: Single; Bold: Boolean): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := AParent;
  Result.WordWrap := True;
  Result.AutoSize := False;
  Result.TextSettings.VertAlign := TTextAlign.Center;
  // always an explicit size, so MeasureText (label heights) matches what is drawn
  if Size <= 0 then
    Size := LABEL_SIZE;
  Result.StyledSettings := Result.StyledSettings - [TStyledSetting.Size];
  Result.TextSettings.Font.Size := Size;
  if Bold then
  begin
    Result.StyledSettings := Result.StyledSettings - [TStyledSetting.Style];
    Result.TextSettings.Font.Style := [TFontStyle.fsBold];
  end;
end;

function TMainFormX.MakeFlow(AParent: TFmxObject; A: TAlignLayout): TFlowLayout;
begin
  Result := TFlowLayout.Create(Self);
  Stack(Result, AParent, A);
  Result.HorizontalGap := 6;
  Result.VerticalGap := 6;
  Result.Padding.Rect := RectF(4, 4, 4, 4);
  Result.Height := 44;
  FFlows.Add(Result);
end;

function TMainFormX.MakeCombo(AParent: TFmxObject; AWidth: Single; const Items: array of string): TComboBox;
var
  S: string;
begin
  Result := TComboBox.Create(Self);
  Result.Parent := AParent;
  Result.Width := AWidth;
  Result.Height := 36;
  for S in Items do
    Result.Items.Add(S);
  if Result.Items.Count > 0 then
    Result.ItemIndex := 0;
end;

function TMainFormX.MakeCheck(AParent: TFmxObject; const AText: string; AWidth: Single): TCheckBox;
begin
  Result := TCheckBox.Create(Self);
  Result.Parent := AParent;
  Result.Text := AText;
  Result.Width := AWidth;
  Result.Height := 36;
end;

function TMainFormX.MakeEqualRow(AParent: TFmxObject; A: TAlignLayout; AHeight: Single): TLayout;
begin
  Result := TLayout.Create(Self);
  Stack(Result, AParent, A);
  Result.Height := AHeight;
  Result.OnResized := EqualRowResized;
  FEqualRows.Add(Result);
end;

// a row of buttons sharing the width equally
procedure TMainFormX.EqualRowResized(Sender: TObject);
const
  GAP = 6;
var
  R: TLayout;
  I, N: Integer;
  W: Single;
  C: TControl;
begin
  R := TLayout(Sender);
  N := 0;
  for I := 0 to R.ControlsCount - 1 do
    if R.Controls[I].Visible then
      Inc(N);
  if N = 0 then
    Exit;
  W := (R.Width - R.Padding.Left - R.Padding.Right - GAP * (N - 1)) / N;
  N := 0;
  for I := 0 to R.ControlsCount - 1 do
  begin
    C := R.Controls[I];
    if not C.Visible then
      Continue;
    C.SetBounds(R.Padding.Left + N * (W + GAP), R.Padding.Top, W,
      R.Height - R.Padding.Top - R.Padding.Bottom);
    Inc(N);
  end;
end;

// flow layouts do not size themselves: work out how many rows they need
procedure FitFlow(F: TFlowLayout);
var
  X, RowH, H, W: Single;
  I: Integer;
  C: TControl;
begin
  W := F.Width - F.Padding.Left - F.Padding.Right;
  if W <= 10 then
    Exit;
  X := 0;
  RowH := 0;
  H := 0;
  for I := 0 to F.ControlsCount - 1 do
  begin
    C := F.Controls[I];
    if not C.Visible then
      Continue;
    if (X > 0) and (X + C.Width > W + 0.5) then
    begin
      H := H + RowH + F.VerticalGap;
      X := 0;
      RowH := 0;
    end;
    X := X + C.Width + F.HorizontalGap;
    RowH := Max(RowH, C.Height);
  end;
  F.Height := H + RowH + F.Padding.Top + F.Padding.Bottom;
end;

procedure TMainFormX.FitLabel(L: TLabel; MinH: Single);
var
  W: Single;
begin
  W := L.Width;
  if W < 20 then
    W := ClientWidth - 24;
  L.Height := Max(MinH, MeasureText(L.Text, W - 4, L.TextSettings.Font.Size,
    TFontStyle.fsBold in L.TextSettings.Font.Style));
end;

// phones: six tab names do not fit, so short ones without counts
procedure TMainFormX.SetTab(T: TTabItem; const Long, Short: string);
begin
  FTabNames.AddOrSetValue(T, TPair<string, string>.Create(Long, Short));
  if FNarrow then
    T.Text := Short
  else
    T.Text := Long;
end;

procedure TMainFormX.Relayout;
var
  F: TFlowLayout;
  R: TLayout;
  H: Single;
  I: Integer;
  P: TPair<TTabItem, TPair<string, string>>;
begin
  if FNarrow <> (ClientWidth < 600) then
  begin
    FNarrow := ClientWidth < 600;
    for P in FTabNames do
      if FNarrow then
        P.Key.Text := P.Value.Value
      else
        P.Key.Text := P.Value.Key;
  end;
  for F in FFlows do
    FitFlow(F);
  for R in FEqualRows do
    EqualRowResized(R);
  if lblStatus <> nil then
  begin
    FitLabel(lblStatus, 22);
    FBar.Height := 40 + lblStatus.Height + 12;
  end;
  if lblChanInfo <> nil then
    FitLabel(lblChanInfo, 30);
  if (lblMapSel <> nil) and (lblMapSel.Width > 20) then
    FMapFoot.Height := Max(44, MeasureText(lblMapSel.Text, lblMapSel.Width - 4,
      lblMapSel.TextSettings.Font.Size) + 10);
  if NetTop <> nil then
  begin
    FitLabel(lblNetMode, 24);
    FitLabel(lblNetRadio, 24);
    FitLabel(lblNetBroker, 24);
    FitLabel(lblNetStats, 24);
    H := NetTop.Padding.Top + NetTop.Padding.Bottom;
    for I := 0 to NetTop.ControlsCount - 1 do
      if NetTop.Controls[I].Visible then
        H := H + NetTop.Controls[I].Height + NetTop.Controls[I].Margins.Top +
          NetTop.Controls[I].Margins.Bottom;
    NetTop.Height := H;
  end;
  UpdateNodeInfo;
end;

procedure TMainFormX.FormResized(Sender: TObject);
begin
  Relayout;
end;

{ ---------------- UI ---------------- }

procedure TMainFormX.BuildUI;
begin
  BuildBar;
  Tabs := TTabControl.Create(Self);
  Stack(Tabs, Self, TAlignLayout.Client);
  Tabs.TabPosition := TTabPosition.Top;
  FNarrow := ClientWidth < 600;
  tabChat := Tabs.Add;
  SetTab(tabChat, 'Messages', 'Chat');
  tabNodes := Tabs.Add;
  SetTab(tabNodes, 'Nodes', 'Nodes');
  tabMap := Tabs.Add;
  SetTab(tabMap, 'Map', 'Map');
  tabChannels := Tabs.Add;
  SetTab(tabChannels, 'Channels', 'Chan');
  tabNet := Tabs.Add;
  SetTab(tabNet, 'Internet', 'Net');
  tabLog := Tabs.Add;
  SetTab(tabLog, 'Log', 'Log');
  BuildChatTab;
  BuildNodesTab;
  BuildMapTab;
  BuildChannelsTab;
  BuildNetTab;
  BuildLogTab;
  Tabs.ActiveTab := tabChat;
  Tabs.OnChange := TabChange;
end;

procedure TMainFormX.BuildBar;
var
  Bar, Row: TLayout;
begin
  Bar := TLayout.Create(Self);
  FBar := Bar;
  Stack(Bar, Self, TAlignLayout.Top);
  Bar.Padding.Rect := RectF(6, 6, 6, 0);
  Bar.Height := 72;

  Row := TLayout.Create(Self);
  Stack(Row, Bar, TAlignLayout.Top);
  Row.Height := 40;

  btnMenu := MakeButton(Row, #$22EE, 44, MenuClick);
  btnMenu.Align := TAlignLayout.Right;
  btnMenu.Margins.Left := 6;
  {$IFDEF ANDROID}
  btnScan := MakeButton(Row, 'Bluetooth', 100, ScanClick);
  {$ELSE}
  btnScan := MakeButton(Row, 'Find Bluetooth', 124, ScanClick);
  {$ENDIF}
  btnScan.Align := TAlignLayout.Right;
  btnScan.Margins.Left := 6;
  btnConnect := MakeButton(Row, 'Connect', 100, ConnectClick);
  btnConnect.Align := TAlignLayout.Right;
  btnConnect.Margins.Left := 6;

  cbPort := TComboBox.Create(Self);
  cbPort.Parent := Row;
  cbPort.Align := TAlignLayout.Client;

  lblStatus := MakeLabel(Bar);
  Stack(lblStatus, Bar, TAlignLayout.Top);
  lblStatus.Margins.Top := 4;
  lblStatus.Height := 22;
  lblStatus.Text := 'Not connected';
end;

procedure TMainFormX.BuildChatTab;
var
  SendBar, Row: TLayout;
begin
  SendBar := TLayout.Create(Self);
  Stack(SendBar, tabChat, TAlignLayout.Bottom);
  SendBar.Height := 88;
  SendBar.Padding.Rect := RectF(4, 4, 4, 4);

  cbDest := TComboBox.Create(Self);
  Stack(cbDest, SendBar, TAlignLayout.Top);
  cbDest.Height := 36;

  Row := TLayout.Create(Self);
  Stack(Row, SendBar, TAlignLayout.Client);
  Row.Margins.Top := 6;

  btnSend := MakeButton(Row, 'Send', 80, SendClick);
  btnSend.Align := TAlignLayout.Right;
  btnSend.Margins.Left := 6;

  lblBytes := MakeLabel(Row, 11);
  lblBytes.Align := TAlignLayout.Right;
  lblBytes.Width := 58;
  lblBytes.TextSettings.HorzAlign := TTextAlign.Center;
  lblBytes.Text := Format('0/%d', [MAX_TEXT_BYTES]);

  edMsg := TEdit.Create(Self);
  edMsg.Parent := Row;
  edMsg.Align := TAlignLayout.Client;
  edMsg.TextPrompt := 'Type a message';
  edMsg.OnKeyDown := MsgKeyDown;
  edMsg.OnChangeTracking := MsgChange;
  edMsg.ReturnKeyType := TReturnKeyType.Send;

  lbChat := TListBox.Create(Self);
  Stack(lbChat, tabChat, TAlignLayout.Client);
  lbChat.DefaultItemStyles.ItemStyle := 'listboxitembottomdetail';
  lbChat.ItemHeight := 54;
end;

procedure TMainFormX.BuildNodesTab;
var
  Row: TLayout;
  Flow: TFlowLayout;
  Btns: TLayout;
  I: Integer;
begin
  Row := TLayout.Create(Self);
  Stack(Row, tabNodes, TAlignLayout.Top);
  Row.Height := 44;
  Row.Padding.Rect := RectF(4, 4, 4, 0);
  btnAddFriend := MakeButton(Row, 'Add friend', 104, AddFriendClick);
  btnAddFriend.Align := TAlignLayout.Right;
  btnAddFriend.Margins.Left := 6;
  edFind := TEdit.Create(Self);
  edFind.Parent := Row;
  edFind.Align := TAlignLayout.Client;
  edFind.TextPrompt := 'Search name, ID, hardware or note';
  edFind.OnChangeTracking := NodeFilterChange;

  Flow := MakeFlow(tabNodes, TAlignLayout.Top);
  cbShow := MakeCombo(Flow, 180, ['All nodes', 'Friends', 'Heard over the air (local)',
    'Heard via the internet', 'Direct neighbours (0 hops)', 'Has a location', 'Has a note']);
  cbHeard := MakeCombo(Flow, 150, ['Heard any time', 'Last 15 minutes', 'Last hour',
    'Last 6 hours', 'Last 24 hours', 'Last 7 days']);
  cbSort := MakeCombo(Flow, 170, SORT_NAMES);
  btnSortDir := MakeButton(Flow, #$25B2, 40, SortDirClick);
  chkFriendsTop := MakeCheck(Flow, 'Friends at top', 130);
  btnDiscover := MakeButton(Flow, 'Discover', 110, DiscoverClick);
  lblNodeCount := MakeLabel(Flow);
  lblNodeCount.Width := 220;
  lblNodeCount.Height := 36;
  lblNodeCount.WordWrap := False;

  // the saved view
  FNodeLoading := True;
  cbShow.ItemIndex := EnsureRange(FSettings.NodeShow, 0, cbShow.Items.Count - 1);
  cbHeard.ItemIndex := EnsureRange(FSettings.NodeHeard, 0, cbHeard.Items.Count - 1);
  cbSort.ItemIndex := 0;
  for I := 0 to High(SORT_COLS) do
    if SORT_COLS[I] = FSettings.NodeSortCol then
      cbSort.ItemIndex := I;
  chkFriendsTop.IsChecked := FSettings.FriendsTop;
  FNodeLoading := False;
  cbShow.OnChange := NodeFilterChange;
  cbHeard.OnChange := NodeFilterChange;
  cbSort.OnChange := NodeFilterChange;
  chkFriendsTop.OnChange := NodeFilterChange;

  // details of the selected node + what to do with it
  pnlNodeInfo := TRectangle.Create(Self);
  Stack(pnlNodeInfo, tabNodes, TAlignLayout.Bottom);
  pnlNodeInfo.Fill.Color := $FFF4F6F8;
  pnlNodeInfo.Stroke.Color := $FFD8DCE0;
  pnlNodeInfo.Padding.Rect := RectF(8, 6, 8, 6);
  pnlNodeInfo.Height := 130;
  Btns := MakeEqualRow(pnlNodeInfo, TAlignLayout.Bottom, 40);
  btnNodeMsg := MakeButton(Btns, 'Message', 80, NodeMsgClick);
  btnNodeFriend := MakeButton(Btns, STAR + ' Friend', 80, NodeFriendClick);
  btnNodeNote := MakeButton(Btns, 'Note', 80, NodeNoteClick);
  btnNodeMap := MakeButton(Btns, 'Map', 80, NodeMapClick);
  btnNodeMore := MakeButton(Btns, 'More...', 80, NodeMoreClick);
  lblNodeInfo := MakeLabel(pnlNodeInfo);
  Stack(lblNodeInfo, pnlNodeInfo, TAlignLayout.Client);
  lblNodeInfo.TextSettings.VertAlign := TTextAlign.Leading;
  lblNodeInfo.Margins.Bottom := 4;

  lbNodes := TListBox.Create(Self);
  Stack(lbNodes, tabNodes, TAlignLayout.Client);
  lbNodes.DefaultItemStyles.ItemStyle := 'listboxitembottomdetail';
  lbNodes.ItemHeight := 54;
  if not IS_TOUCH then
    lbNodes.MultiSelectStyle := TMultiSelectStyle.Extended;
  lbNodes.OnChange := NodesChange;
  lbNodes.OnDblClick := NodesDblClick;
  lbNodes.OnKeyDown := NodesKeyDown;
end;

procedure TMainFormX.BuildMapTab;
var
  Flow: TFlowLayout;
  Foot: TLayout;
begin
  Flow := MakeFlow(tabMap, TAlignLayout.Top);
  btnMapPlace := MakeButton(Flow, 'Set my location', 140, MapPlaceClick);
  MakeButton(Flow, 'My radio', 96, MapMeClick);
  MakeButton(Flow, 'Fit all', 84, MapFitClick);
  edMapFind := TEdit.Create(Self);
  edMapFind.Parent := Flow;
  edMapFind.Width := 230;
  edMapFind.Height := 36;
  edMapFind.TextPrompt := 'Address, town, or coordinates';
  edMapFind.OnKeyDown := MapFindKeyDown;
  btnMapFind := MakeButton(Flow, 'Find', 70, MapFindClick);
  chkMapLocal := MakeCheck(Flow, 'Local nodes only', 150);
  chkMapLocal.OnChange := MapLocalChange;

  lblMapInfo := MakeLabel(tabMap, 11);
  Stack(lblMapInfo, tabMap, TAlignLayout.Top);
  lblMapInfo.Height := 22;
  lblMapInfo.Margins.Rect := RectF(6, 0, 6, 0);

  Foot := TLayout.Create(Self);
  FMapFoot := Foot;
  Stack(Foot, tabMap, TAlignLayout.Bottom);
  Foot.Height := 48;
  Foot.Padding.Rect := RectF(6, 4, 6, 4);
  btnMapMsg := MakeButton(Foot, 'Message', 96, MapMsgClick);
  btnMapMsg.Align := TAlignLayout.Right;
  btnMapMsg.Margins.Left := 6;
  btnMapMsg.Visible := False;
  lblMapSel := MakeLabel(Foot);
  lblMapSel.Align := TAlignLayout.Client;
  if IS_TOUCH then
    lblMapSel.Text := 'Red = this radio, orange = friend, blue = heard over the air, grey = via internet. ' +
      'Tap a node for details, long-press the map for more.'
  else
    lblMapSel.Text := 'Red = this radio, orange = friend, blue = heard over the air, grey = via internet. ' +
      'Click a node for details; double-click to message it; right-click the map for more.';

  Map := TMapViewX.Create(Self);
  Stack(Map, tabMap, TAlignLayout.Client);
  Map.OnMarkerClick := MapMarkerClick;
  Map.OnMarkerDblClick := MapMarkerDblClick;
  Map.OnPlace := MapPlaced;
  Map.OnContext := MapContext;
  Map.OnPlaceModeChange := MapPlaceModeChanged;
  if (FSettings.MapZoom > 0) and (Abs(FSettings.MapLat) <= 90) and (Abs(FSettings.MapLon) <= 180) then
    Map.SetView(FSettings.MapLat, FSettings.MapLon, FSettings.MapZoom);
end;

procedure TMainFormX.BuildChannelsTab;
var
  Flow: TFlowLayout;
begin
  lblChanInfo := MakeLabel(tabChannels, 12);
  Stack(lblChanInfo, tabChannels, TAlignLayout.Top);
  lblChanInfo.Margins.Rect := RectF(8, 6, 8, 4);
  lblChanInfo.TextSettings.VertAlign := TTextAlign.Leading;
  lblChanInfo.Text := 'A private channel has its own secret key: only radios that have the key can ' +
    'read or send on it. Create one, then let your friend scan its QR code with the Meshtastic app ' +
    '(or send them the link privately). Its messages show up in Messages as #name. Your radio keeps ' +
    'the public channel as well.';
  lblChanInfo.Height := 70;

  Flow := MakeFlow(tabChannels, TAlignLayout.Bottom);
  btnNewChannel := MakeButton(Flow, 'New private channel', 170, NewChannelClick);
  btnShareChannel := MakeButton(Flow, 'Share / QR code', 150, ShareChannelClick);
  btnJoinChannel := MakeButton(Flow, 'Join from a link', 150, JoinChannelClick);
  btnDeleteChannel := MakeButton(Flow, 'Delete channel', 130, DeleteChannelClick);

  lbChannels := TListBox.Create(Self);
  Stack(lbChannels, tabChannels, TAlignLayout.Client);
  lbChannels.Margins.Rect := RectF(6, 0, 6, 0);
  lbChannels.DefaultItemStyles.ItemStyle := 'listboxitembottomdetail';
  lbChannels.ItemHeight := 54;
  lbChannels.OnChange := ChannelChange;
  lbChannels.OnDblClick := ShareChannelClick;
end;

procedure TMainFormX.BuildNetTab;

  procedure TopicRow(const Caption, Prompt, BtnText: string; out Ed: TEdit; out Btn: TButton;
    OnClick: TNotifyEvent);
  var
    L: TLabel;
    Row: TLayout;
  begin
    L := MakeLabel(NetTop, 12, True);
    Stack(L, NetTop, TAlignLayout.Top);
    L.Height := 22;
    L.Margins.Top := 4;
    L.Text := Caption;
    Row := TLayout.Create(Self);
    Stack(Row, NetTop, TAlignLayout.Top);
    Row.Height := 38;
    Btn := MakeButton(Row, BtnText, 110, OnClick);
    Btn.Align := TAlignLayout.Right;
    Btn.Margins.Left := 6;
    Ed := TEdit.Create(Self);
    Ed.Parent := Row;
    Ed.Align := TAlignLayout.Client;
    Ed.TextPrompt := Prompt;
  end;

var
  Flow: TFlowLayout;
begin
  NetTop := TLayout.Create(Self);
  Stack(NetTop, tabNet, TAlignLayout.Top);
  NetTop.Padding.Rect := RectF(8, 4, 8, 4);
  NetTop.Height := 400;

  lblNetMode := MakeLabel(NetTop, 0, True);
  Stack(lblNetMode, NetTop, TAlignLayout.Top);
  lblNetRadio := MakeLabel(NetTop, 12);
  Stack(lblNetRadio, NetTop, TAlignLayout.Top);
  lblNetBroker := MakeLabel(NetTop, 12);
  Stack(lblNetBroker, NetTop, TAlignLayout.Top);
  lblNetStats := MakeLabel(NetTop, 12);
  Stack(lblNetStats, NetTop, TAlignLayout.Top);

  TopicRow('Radio root topic (where your radio publishes; changes a radio setting)',
    'e.g. msh/US or msh/US/Springfield', 'Set on radio', edRoot, btnSetRoot, SetRootClick);
  TopicRow('Also listen to (all their traffic comes in)', 'e.g. msh/US/Springfield, msh/US/TX/#',
    'Apply', edExtra, btnExtra, ExtraClick);
  edExtra.Text := string.Join(', ', FSettings.ExtraTopics.ToStringArray);
  TopicRow('Friends (everything they send on a topic you listen to comes in)',
    'e.g. !1a2b3c4d, !9f8e7d6c', 'Apply', edFriends, btnFriends, FriendsApplyClick);
  edFriends.Text := FSettings.FriendsText;

  Flow := TFlowLayout.Create(Self);
  Stack(Flow, NetTop, TAlignLayout.Top);
  Flow.Margins.Top := 6;
  Flow.HorizontalGap := 8;
  Flow.VerticalGap := 6;
  Flow.Height := 40;
  FFlows.Add(Flow);
  btnInternet := MakeButton(Flow, 'Switch to Radio + Internet', 210, InternetClick);
  btnRadioOnly := MakeButton(Flow, 'Switch to Radio only', 180, RadioOnlyClick);
  chkNetAll := MakeCheck(Flow, 'Show all root-topic traffic (busy)', 330);
  chkNetAll.OnChange := NetAllChange;

  memoNet := TMemo.Create(Self);
  Stack(memoNet, tabNet, TAlignLayout.Client);
  memoNet.Margins.Rect := RectF(6, 0, 6, 6);
  memoNet.ReadOnly := True;
  memoNet.TextSettings.Font.Size := 11;
  memoNet.TextSettings.WordWrap := True;
end;

procedure TMainFormX.BuildLogTab;
begin
  chkDeviceLog := MakeCheck(tabLog, 'Show radio debug output', 260);
  Stack(chkDeviceLog, tabLog, TAlignLayout.Top);
  chkDeviceLog.Margins.Rect := RectF(8, 2, 8, 2);
  chkDeviceLog.IsChecked := FSettings.ShowDeviceLog;
  chkDeviceLog.OnChange := DeviceLogChange;
  memoLog := TMemo.Create(Self);
  Stack(memoLog, tabLog, TAlignLayout.Client);
  memoLog.ReadOnly := True;
  memoLog.TextSettings.Font.Size := 11;
  memoLog.TextSettings.WordWrap := True;
end;

{ ---------------- general ---------------- }

procedure TMainFormX.AddLog(const S: string);
begin
  if memoLog = nil then
    Exit;
  memoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + S);
  if memoLog.Lines.Count > 3000 then
    memoLog.Lines.Delete(0);
  memoLog.GoToTextEnd;
end;

procedure TMainFormX.NetLog(const S: string);
begin
  if memoNet = nil then
    Exit;
  memoNet.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + S);
  if memoNet.Lines.Count > 2000 then
    memoNet.Lines.Delete(0);
  memoNet.GoToTextEnd;
end;

procedure TMainFormX.CopyText(const S: string);
var
  Svc: IFMXClipboardService;
begin
  if TPlatformServices.Current.SupportsPlatformService(IFMXClipboardService, Svc) then
    Svc.SetClipboard(S);
end;

function TMainFormX.IsUserLooking: Boolean;
begin
  {$IFDEF ANDROID}
  Result := FAppActive;
  {$ELSE}
  Result := Active and (WindowState <> TWindowState.wsMinimized);
  {$ENDIF}
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
  S, Bat: string;
  Me: TNodeInfo;
begin
  case FClient.State of
    msDisconnected: S := 'Not connected';
    msConnecting: S := 'Connecting...';
    msReady: S := 'Connected';
  end;
  if FClient.MyNodeNum <> 0 then
    S := S + DOT + FClient.NodeName(FClient.MyNodeNum) + ' ' + NodeIdStr(FClient.MyNodeNum);
  if FClient.Metadata.FirmwareVersion <> '' then
    S := S + DOT + HwModelName(FClient.Metadata.HwModel) + ' fw ' + FClient.Metadata.FirmwareVersion;
  if FClient.LoRa.Valid then
  begin
    if FClient.LoRa.Region = 0 then
      S := S + DOT + 'REGION NOT SET - cannot transmit!'
    else
      S := S + DOT + RegionName(FClient.LoRa.Region) + ' / ' + ModemPresetName(FClient.LoRa.ModemPreset);
  end;
  if FClient.State <> msDisconnected then
    S := S + DOT + Format('%d nodes', [FClient.Nodes.Count]);
  if (FClient.MyNodeNum <> 0) and FClient.Nodes.TryGetValue(FClient.MyNodeNum, Me) then
  begin
    Bat := FView.BatteryText(Me, True);
    if Bat <> '' then
      S := S + DOT + Bat;
  end;
  if FReconnectUntil <> 0 then
    S := S + DOT + 'reconnecting...';
  lblStatus.Text := S;
  if FClient.State = msDisconnected then
    btnConnect.Text := 'Connect'
  else
    btnConnect.Text := 'Disconnect';
  cbPort.Enabled := FClient.State = msDisconnected;
  btnScan.Enabled := (FClient.State = msDisconnected) and not FScanning;
  btnSend.Enabled := FClient.State = msReady;
  UpdateDiscoverButton;
  UpdateChannelButtons;
end;

procedure TMainFormX.RefreshDests;
var
  C: TChannelInfo;
  D, Prev: TDest;
  HavePrev: Boolean;
  N: TNodeInfo;
  L: TList<TNodeInfo>;
  I: Integer;
  Num: Cardinal;
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
    // friends first, even if the radio has not heard from them yet
    for Num in FSettings.Friends do
      if Num <> FClient.MyNodeNum then
      begin
        D.Dest := Num;
        D.Channel := 0;
        FDests.Add(D);
        if FClient.NodeName(Num) = NodeIdStr(Num) then
          cbDest.Items.Add(STAR + ' ' + NodeIdStr(Num))
        else
          cbDest.Items.Add(STAR + ' ' + FClient.NodeName(Num) + '  ' + NodeIdStr(Num));
      end;
    L := TList<TNodeInfo>.Create;
    try
      for N in FClient.Nodes.Values do
        if (N.Num <> FClient.MyNodeNum) and not FSettings.Friends.Contains(N.Num) then
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
        if FClient.NodeName(N.Num) = NodeIdStr(N.Num) then
          cbDest.Items.Add('@ ' + NodeIdStr(N.Num))
        else
          cbDest.Items.Add('@ ' + FClient.NodeName(N.Num) + '  ' + NodeIdStr(N.Num));
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

// pick a conversation in the "To" box and go to Messages
function TMainFormX.SelectDest(Dest, Channel: Cardinal): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to FDests.Count - 1 do
    if (FDests[I].Dest = Dest) and ((Dest <> BROADCAST_ADDR) or (FDests[I].Channel = Channel)) then
    begin
      cbDest.ItemIndex := I;
      Tabs.ActiveTab := tabChat;
      if not IS_TOUCH then
        edMsg.SetFocus;
      Exit(True);
    end;
end;

function TMainFormX.AddChat(const Text, Detail: string; const LogFrom, LogTo, LogState: string): TListBoxItem;
begin
  Result := TListBoxItem.Create(lbChat);
  Result.Parent := lbChat;
  Result.StyleLookup := 'listboxitembottomdetail';
  Result.Text := Text;
  Result.ItemData.Detail := Detail;
  Result.Height := 54;
  lbChat.ScrollToItem(Result);
  // a permanent record next to MeshTerm.ini
  try
    TFile.AppendAllText(MessagesLogPath, Format('%s'#9'%s'#9'%s'#9'%s'#9'%s',
      [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), LogFrom, LogTo, Text, LogState]) + sLineBreak,
      TEncoding.UTF8);
  except
    // logging must never break the chat
  end;
end;

{ After any change to the friends list: save it and update everything that
  shows friends. }
procedure TMainFormX.FriendsChanged(const Msg: string);
begin
  FSettings.SaveFriendsAndTopics;
  edFriends.Text := FSettings.FriendsText;
  RefreshDests;
  RefreshNodeRows;
  RebuildMap;
  if Msg <> '' then
    AddLog(Msg);
end;

{ ---------------- connection bar ---------------- }

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
      if not FAliveObj.Alive then
        Exit;
      FScanning := False;
      {$IFDEF ANDROID}
      btnScan.Text := 'Bluetooth';
      {$ELSE}
      btnScan.Text := 'Find Bluetooth';
      {$ENDIF}
      if Error <> '' then
        AddLog('Bluetooth: ' + Error)
      else if Length(Names) = 0 then
      begin
        AddLog('No Meshtastic radio found over Bluetooth. Is Bluetooth on in the radio, and is it ' +
          'close by? (A radio connected to another phone does not show up.)');
        AddLog(Format('The scan saw %d other device(s):', [Length(BleScanReport)]));
        for P in BleScanReport do
          AddLog('  ' + P);
        Tabs.ActiveTab := tabLog;
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

procedure TMainFormX.StartScan(const AfterFound: TProc);
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
          Tabs.ActiveTab := tabLog;
          Exit;
        end;
      DoScan(AfterFound);
    end);
  {$ELSE}
  DoScan(AfterFound);
  {$ENDIF}
end;

procedure TMainFormX.ScanClick(Sender: TObject);
begin
  StartScan(nil);
end;

procedure TMainFormX.ConnectClick(Sender: TObject);
var
  P: string;
begin
  FReconnectUntil := 0;
  if FClient.State <> msDisconnected then
  begin
    FBridge.Stop;
    FClient.Disconnect;
    Exit;
  end;
  FillPorts('');
  P := SelectedPort;
  if P = '' then
  begin
    ShowInfo(Self, 'No radio', 'No radio to connect to. Plug it in (USB), or tap ' + btnScan.Text +
      ' to find it over Bluetooth.');
    Exit;
  end;
  FPending.Clear;
  FLastPort := P;
  FRegionWarned := False;
  FClient.Connect(P);
end;

procedure TMainFormX.MenuClick(Sender: TObject);
var
  S: TSheet;
  cDM, cFriend, cPrivate, cPublic, cAway: TCheckBox;
begin
  S := TSheet.CreateSheet(Self, 'Alerts');
  S.Cancelable := False;
  S.AddText('Pop up a notification for:');
  cDM := S.AddCheck('Direct messages to me', FSettings.AlertDirect);
  cFriend := S.AddCheck('Anything from friends', FSettings.AlertFriends);
  cPrivate := S.AddCheck('Private channels', FSettings.AlertPrivate);
  cPublic := S.AddCheck('Public channel (busy)', FSettings.AlertPublic);
  cAway := S.AddCheck('Only when I''m not looking at MeshTerm', FSettings.AlertOnlyAway);
  S.AddButtons([
    Act('Test notification',
      procedure
      begin
        FAlertDest.Dest := BROADCAST_ADDR;
        FAlertDest.Channel := 0;
        FLastAlert := 0;
        ShowAlert('MeshTerm test', 'This is how new messages will pop up. Tap it to open MeshTerm.');
      end),
    Act('Done',
      procedure
      begin
        FSettings.AlertDirect := cDM.IsChecked;
        FSettings.AlertFriends := cFriend.IsChecked;
        FSettings.AlertPrivate := cPrivate.IsChecked;
        FSettings.AlertPublic := cPublic.IsChecked;
        FSettings.AlertOnlyAway := cAway.IsChecked;
        FSettings.SaveAlerts;
      end, True)]);
  S.Present;
end;

{ ---------------- messages ---------------- }

procedure TMainFormX.SendClick(Sender: TObject);
var
  Text, ToName, Head: string;
  D: TDest;
  Id: Cardinal;
  P: TPendingMsg;
begin
  Text := Trim(edMsg.Text);
  if (Text = '') or (FClient.State <> msReady) then
    Exit;
  if (cbDest.ItemIndex < 0) or (cbDest.ItemIndex >= FDests.Count) then
    Exit;
  if Length(TEncoding.UTF8.GetBytes(Text)) > MAX_TEXT_BYTES then
  begin
    ShowInfo(Self, 'Too long', Format('A message can be at most %d bytes.', [MAX_TEXT_BYTES]));
    Exit;
  end;
  D := FDests[cbDest.ItemIndex];
  try
    Id := FClient.SendText(Text, D.Dest, D.Channel);
  except
    on E: Exception do
    begin
      ShowInfo(Self, 'Send failed', E.Message);
      Exit;
    end;
  end;
  if D.Dest = BROADCAST_ADDR then
    ToName := '#' + FClient.ChannelName(D.Channel)
  else
    ToName := FClient.NodeName(D.Dest);
  Head := FormatDateTime('hh:nn', Now) + '  me' + ARROW + ToName;
  P.Item := AddChat(Text, Head + DOT + 'sending...', 'me', ToName, 'Sending...');
  P.Dest := D.Dest;
  P.Head := Head;
  FPending.AddOrSetValue(Id, P);
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

procedure TMainFormX.MsgChange(Sender: TObject);
var
  N: Integer;
begin
  N := Length(TEncoding.UTF8.GetBytes(edMsg.Text));
  lblBytes.Text := Format('%d/%d', [N, MAX_TEXT_BYTES]);
  lblBytes.StyledSettings := lblBytes.StyledSettings - [TStyledSetting.FontColor];
  if N > MAX_TEXT_BYTES then
    lblBytes.TextSettings.FontColor := TAlphaColors.Red
  else
    lblBytes.TextSettings.FontColor := $FF606060;
end;

{ ---------------- nodes ---------------- }

function TMainFormX.SelectedNodes: TArray<Cardinal>;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to lbNodes.Count - 1 do
    if lbNodes.ListItems[I].IsSelected then
      Result := Result + [Cardinal(lbNodes.ListItems[I].Tag)];
end;

{ Rebuild the rows from the node database + friends, reusing the list items
  (keeps the scroll position) and the selection. }
procedure TMainFormX.RefreshNodeRows;
var
  Rows, Sel: TArray<Cardinal>;
  I: Integer;
  It: TListBoxItem;
  Num: Cardinal;
  N: TNodeInfo;
  Known, Stale: Boolean;
  Color: TAlphaColor;
  Total: Integer;

  function InSel(X: Cardinal): Boolean;
  var
    Y: Cardinal;
  begin
    for Y in Sel do
      if X = Y then
        Exit(True);
    Result := False;
  end;

begin
  FNodesDirty := False;
  if lbNodes = nil then
    Exit;
  Sel := SelectedNodes;
  Rows := FView.Rows(edFind.Text);
  FNodeLoading := True;
  lbNodes.BeginUpdate;
  try
    while lbNodes.Count > Length(Rows) do
      lbNodes.ListItems[lbNodes.Count - 1].Free;
    while lbNodes.Count < Length(Rows) do
    begin
      It := TListBoxItem.Create(lbNodes);
      It.Parent := lbNodes;
      It.StyleLookup := 'listboxitembottomdetail';
      It.Height := 54;
      It.StyledSettings := It.StyledSettings - [TStyledSetting.FontColor, TStyledSetting.Style];
    end;
    for I := 0 to High(Rows) do
    begin
      Num := Rows[I];
      It := lbNodes.ListItems[I];
      It.Tag := NativeInt(Num);
      Known := FClient.Nodes.TryGetValue(Num, N);
      if Known and (N.User.ShortName <> '') then
        It.Text := FView.Cell(Num, NC_NAME) + '  (' + N.User.ShortName + ')'
      else
        It.Text := FView.Cell(Num, NC_NAME);
      It.ItemData.Detail := FView.Summary(Num);
      // colours match the map: red = this radio, orange = friend, grey = internet / stale
      Stale := FView.IsStale(Num);
      if Num = FClient.MyNodeNum then
        Color := $FFBE1E1E
      else if FSettings.Friends.Contains(Num) and Stale then
        Color := $FFCD965A
      else if FSettings.Friends.Contains(Num) then
        Color := $FFCD6900
      else if Stale then
        Color := $FF999999
      else if Known and N.ViaMqtt then
        Color := $FF696969
      else
        Color := $FF202020;
      It.TextSettings.FontColor := Color;
      if (Num = FClient.MyNodeNum) or FSettings.Friends.Contains(Num) then
        It.TextSettings.Font.Style := [TFontStyle.fsBold]
      else
        It.TextSettings.Font.Style := [];
      It.IsSelected := InSel(Num);
    end;
  finally
    lbNodes.EndUpdate;
    FNodeLoading := False;
  end;
  Total := FView.TotalCount;
  if FView.IsFiltered(edFind.Text) then
  begin
    SetTab(tabNodes, Format('Nodes (%d/%d)', [Length(Rows), Total]), 'Nodes');
    lblNodeCount.Text := Format('Showing %d of %d, %d friend(s)', [Length(Rows), Total,
      FSettings.Friends.Count]);
  end
  else
  begin
    SetTab(tabNodes, Format('Nodes (%d)', [Total]), 'Nodes');
    lblNodeCount.Text := Format('%d nodes, %d friend(s)', [Total, FSettings.Friends.Count]);
  end;
  if FSettings.NodeSortDesc then
    btnSortDir.Text := #$25BC
  else
    btnSortDir.Text := #$25B2;
  UpdateNodeInfo;
end;

procedure TMainFormX.UpdateNodeButtons;
var
  Sel: TArray<Cardinal>;
  Num: Cardinal;
  AllFriends, One: Boolean;
  N: TNodeInfo;
begin
  Sel := SelectedNodes;
  One := Length(Sel) = 1;
  AllFriends := Length(Sel) > 0;
  for Num in Sel do
    if not FSettings.Friends.Contains(Num) then
      AllFriends := False;
  btnNodeMsg.Enabled := One and (Sel[0] <> FClient.MyNodeNum);
  if AllFriends then
    btnNodeFriend.Text := 'Unfriend'
  else
    btnNodeFriend.Text := STAR + ' Friend';
  btnNodeFriend.Enabled := (Length(Sel) > 0) and not (One and (Sel[0] = FClient.MyNodeNum));
  btnNodeNote.Enabled := One;
  btnNodeMap.Enabled := One and FClient.Nodes.TryGetValue(Sel[0], N) and N.Position.Valid;
  btnNodeMore.Enabled := Length(Sel) > 0;
end;

procedure TMainFormX.UpdateNodeInfo;
var
  Sel: TArray<Cardinal>;
  Who, Heard, Extra, T: string;
  H: Single;
begin
  if lblNodeInfo = nil then
    Exit;
  Sel := SelectedNodes;
  if Length(Sel) = 0 then
  begin
    if IS_TOUCH then
      T := 'Tap a node to see its details and what you can do with it (message, friend, note, map).'
    else
      T := 'Click a node to see its details. Double-click it (or press Enter) to message it. ' +
        'Ctrl+click or Shift+click to select several. Delete removes friends, Ctrl+C copies IDs.';
  end
  else if Length(Sel) > 1 then
    T := Format('%d nodes selected. Add or remove them as friends, or copy their IDs (More...).',
      [Length(Sel)])
  else
  begin
    FView.Details(Sel[0], Who, Heard, Extra);
    T := Who + sLineBreak + Heard;
    if Extra <> '' then
      T := T + sLineBreak + Extra;
  end;
  lblNodeInfo.Text := T;
  if lblNodeInfo.Width > 20 then
  begin
    H := MeasureText(T, lblNodeInfo.Width - 4, lblNodeInfo.TextSettings.Font.Size) + 4;
    H := Min(H, Max(80, tabNodes.Height * 0.4));
    pnlNodeInfo.Height := H + 40 + pnlNodeInfo.Padding.Top + pnlNodeInfo.Padding.Bottom + 6;
  end;
  UpdateNodeButtons;
end;

procedure TMainFormX.NodeFilterChange(Sender: TObject);
var
  NewCol: Integer;
begin
  if FNodeLoading then
    Exit;
  FSettings.NodeShow := cbShow.ItemIndex;
  FSettings.NodeHeard := cbHeard.ItemIndex;
  FSettings.FriendsTop := chkFriendsTop.IsChecked;
  if cbSort.ItemIndex >= 0 then
  begin
    NewCol := SORT_COLS[cbSort.ItemIndex];
    if NewCol <> FSettings.NodeSortCol then
    begin
      FSettings.NodeSortCol := NewCol;
      // bigger-is-better keys start with the biggest
      FSettings.NodeSortDesc := NewCol in [NC_SNR, NC_RSSI, NC_BATTERY];
    end;
  end;
  RefreshNodeRows;
  if Sender <> edFind then
    FSettings.SaveNodeView;
end;

procedure TMainFormX.SortDirClick(Sender: TObject);
begin
  FSettings.NodeSortDesc := not FSettings.NodeSortDesc;
  RefreshNodeRows;
  FSettings.SaveNodeView;
end;

procedure TMainFormX.NodesChange(Sender: TObject);
begin
  if not FNodeLoading then
    UpdateNodeInfo;
end;

procedure TMainFormX.NodesDblClick(Sender: TObject);
begin
  NodeMsgClick(Sender);
end;

procedure TMainFormX.NodesKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
var
  Sel: TArray<Cardinal>;
  L: TStringList;
  Num: Cardinal;
begin
  case Key of
    vkReturn:
      begin
        Key := 0;
        NodeMsgClick(Sender);
      end;
    vkDelete:
      begin
        Key := 0;
        Sel := nil;
        for Num in SelectedNodes do
          if FSettings.Friends.Contains(Num) then
            Sel := Sel + [Num];
        RemoveFriends(Sel);
      end;
  else
    if (ssCtrl in Shift) and ((KeyChar = 'c') or (KeyChar = 'C') or (Key = Ord('C'))) then
    begin
      L := TStringList.Create;
      try
        for Num in SelectedNodes do
          L.Add(NodeIdStr(Num));
        if L.Count > 0 then
          CopyText(string.Join(', ', L.ToStringArray));
      finally
        L.Free;
      end;
      Key := 0;
      KeyChar := #0;
    end;
  end;
end;

procedure TMainFormX.NodeMsgClick(Sender: TObject);
var
  Sel: TArray<Cardinal>;
begin
  Sel := SelectedNodes;
  if (Length(Sel) >= 1) and (Sel[0] <> FClient.MyNodeNum) then
    if not SelectDest(Sel[0], 0) then
    begin
      RefreshDests;
      SelectDest(Sel[0], 0);
    end;
end;

procedure TMainFormX.NodeFriendClick(Sender: TObject);
var
  Sel, Changed: TArray<Cardinal>;
  Num: Cardinal;
  AllFriends: Boolean;
begin
  Sel := SelectedNodes;
  if Length(Sel) = 0 then
    Exit;
  AllFriends := True;
  for Num in Sel do
    if not FSettings.Friends.Contains(Num) then
      AllFriends := False;
  if AllFriends then
  begin
    RemoveFriends(Sel);
    Exit;
  end;
  Changed := nil;
  for Num in Sel do
    if (Num <> FClient.MyNodeNum) and not FSettings.Friends.Contains(Num) then
    begin
      FSettings.Friends.Add(Num);
      Changed := Changed + [Num];
    end;
  if Length(Changed) > 0 then
    FriendsChanged('Added to friends: ' + FView.NamesOf(Changed));
end;

procedure TMainFormX.RemoveFriends(const Nums: TArray<Cardinal>);
var
  Gone: TArray<Cardinal>;
begin
  Gone := Nums;
  if Length(Gone) = 0 then
    Exit;
  ShowConfirm(Self, 'Remove from friends?', FView.NamesOf(Gone), 'Remove',
    procedure
    var
      Num: Cardinal;
    begin
      for Num in Gone do
        FSettings.Friends.Remove(Num);
      FriendsChanged('Removed from friends: ' + FView.NamesOf(Gone));
    end);
end;

procedure TMainFormX.NodeNoteClick(Sender: TObject);
var
  Sel: TArray<Cardinal>;
  Note: string;
  Num: Cardinal;
begin
  Sel := SelectedNodes;
  if Length(Sel) <> 1 then
    Exit;
  Num := Sel[0];
  if not FSettings.Notes.TryGetValue(Num, Note) then
    Note := '';
  ShowInput(Self, 'Note (kept on this device only)', 'Note for ' + FClient.NodeName(Num) +
    ' (empty = remove):', Note,
    procedure(Value: string)
    begin
      Value := Trim(Value.Replace(#13, ' ').Replace(#10, ' '));
      if Value = '' then
        FSettings.Notes.Remove(Num)
      else
        FSettings.Notes.AddOrSetValue(Num, Value);
      FSettings.SaveNote(Num);
      RefreshNodeRows;
    end, 'Save');
end;

procedure TMainFormX.NodeMapClick(Sender: TObject);
var
  Sel: TArray<Cardinal>;
begin
  Sel := SelectedNodes;
  if Length(Sel) = 1 then
    ShowNodeOnMap(Sel[0]);
end;

procedure TMainFormX.ToggleNoBattery(Num: Cardinal);
begin
  if FSettings.NoBattery.Contains(Num) then
    FSettings.NoBattery.Remove(Num)
  else
    FSettings.NoBattery.Add(Num);
  FSettings.SaveNoBattery;
  RefreshNodeRows;
  RefreshStatus;
end;

procedure TMainFormX.NodeMoreClick(Sender: TObject);
var
  Sel: TArray<Cardinal>;
  Acts: TArray<TSheetAction>;
  Num: Cardinal;
  Cap: string;
begin
  Sel := SelectedNodes;
  if Length(Sel) = 0 then
    Exit;
  if Length(Sel) > 1 then Cap := 's' else Cap := '';
  Acts := [
    Act('Copy node ID' + Cap,
      procedure
      var
        L: TStringList;
        X: Cardinal;
      begin
        L := TStringList.Create;
        try
          for X in Sel do
            L.Add(NodeIdStr(X));
          CopyText(string.Join(', ', L.ToStringArray));
        finally
          L.Free;
        end;
      end),
    Act('Copy name' + Cap,
      procedure
      var
        L: TStringList;
        X: Cardinal;
      begin
        L := TStringList.Create;
        try
          for X in Sel do
            L.Add(FClient.NodeName(X));
          CopyText(string.Join(sLineBreak, L.ToStringArray));
        finally
          L.Free;
        end;
      end)];
  if (Length(Sel) = 1) and FClient.Nodes.ContainsKey(Sel[0]) then
  begin
    Num := Sel[0];
    if FSettings.NoBattery.Contains(Num) then
      Cap := 'It has a battery after all (show its reading)'
    else if Num = FClient.MyNodeNum then
      Cap := 'This radio has no battery (hide its reading)'
    else
      Cap := 'This node has no battery (hide its reading)';
    Acts := Acts + [Act(Cap, procedure begin ToggleNoBattery(Num); end)];
  end;
  ShowActions(Self, FView.NamesOf(Sel), '', Acts);
end;

procedure TMainFormX.AddFriendClick(Sender: TObject);
begin
  ShowInput(Self, 'Add friend', 'Node ID (like !1a2b3c4d) or exact name; commas between several:', '',
    procedure(S: string)
    var
      T: string;
      Num, Found: Cardinal;
      Matches: Integer;
      N: TNodeInfo;
      Added: TArray<Cardinal>;
    begin
      Added := nil;
      for T in S.Split([',', ';']) do
      begin
        if T.Trim = '' then
          Continue;
        Num := ParseNodeId(T);
        if Num = 0 then
        begin
          Matches := 0;
          Found := 0;
          for N in FClient.Nodes.Values do
            if SameText(N.User.LongName, T.Trim) or SameText(N.User.ShortName, T.Trim) then
            begin
              Inc(Matches);
              Found := N.Num;
            end;
          if Matches = 1 then
            Num := Found
          else
          begin
            if Matches = 0 then
              ShowInfo(Self, 'Add friend', Format('"%s" is not a node ID (! and 8 letters/digits, ' +
                'like !1a2b3c4d) or the name of a node in the list.', [T.Trim]))
            else
              ShowInfo(Self, 'Add friend', Format('More than one node is called "%s". Use its ID instead.',
                [T.Trim]));
            Exit;
          end;
        end;
        if (Num <> FClient.MyNodeNum) and not FSettings.Friends.Contains(Num) then
        begin
          FSettings.Friends.Add(Num);
          Added := Added + [Num];
        end;
      end;
      if Length(Added) = 0 then
        ShowInfo(Self, 'Add friend', 'Nothing new to add: already a friend (or this radio).')
      else
        FriendsChanged('Added to friends: ' + FView.NamesOf(Added));
    end, 'Add');
end;

procedure TMainFormX.UpdateDiscoverButton;
begin
  if btnDiscover = nil then
    Exit;
  if FDiscoverUntil = 0 then
  begin
    btnDiscover.Text := 'Discover';
    btnDiscover.Enabled := FClient.State = msReady;
  end
  else
  begin
    btnDiscover.Text := Format('Listening %ds', [Max(0, SecondsBetween(FDiscoverUntil, Now))]);
    btnDiscover.Enabled := False;
  end;
end;

procedure TMainFormX.DiscoverClick(Sender: TObject);
begin
  try
    FClient.SendDiscover;
  except
    on E: Exception do
    begin
      ShowInfo(Self, 'Discover', E.Message);
      Exit;
    end;
  end;
  FDiscoverStart := DateTimeToUnix(Now, False);
  FDiscoverUntil := IncSecond(Now, 60);
  UpdateDiscoverButton;
  AddLog('Discover: asked every node in range to reply with its info.');
end;

procedure TMainFormX.FinishDiscover;
var
  N: TNodeInfo;
  Found: Integer;
begin
  FDiscoverUntil := 0;
  Found := 0;
  for N in FClient.Nodes.Values do
    if (N.Num <> FClient.MyNodeNum) and (Int64(N.LastHeard) >= FDiscoverStart) then
      Inc(Found);
  if Found = 0 then
    AddLog('Discover: no replies. No other node in range yet - try a higher spot for the antenna.')
  else
    AddLog(Format('Discover: %d node(s) heard in the last minute.', [Found]));
  FNodesDirty := True;
end;

{ ---------------- map ---------------- }

procedure TMainFormX.UpdateMapMarker(const N: TNodeInfo);
var
  M: TMapMarker;
begin
  if Map = nil then
    Exit;
  if not N.Position.Valid or (chkMapLocal.IsChecked and not FView.IsLocalNode(N)) then
  begin
    Map.RemoveMarker(N.Num);
    Exit;
  end;
  M.Id := N.Num;
  M.Lat := N.Position.Lat;
  M.Lon := N.Position.Lon;
  M.Caption := FClient.NodeName(N.Num);
  if Length(M.Caption) > 24 then
    M.Caption := Copy(M.Caption, 1, 23) + '...';
  M.IsMe := N.Num = FClient.MyNodeNum;
  if M.IsMe then
    M.Color := COLOR_ME
  else if FSettings.Friends.Contains(N.Num) then
    M.Color := COLOR_FRIEND
  else if FView.IsLocalNode(N) then
    M.Color := COLOR_LOCAL
  else
    M.Color := COLOR_NET;
  Map.SetMarker(M);
end;

procedure TMainFormX.RebuildMap;
var
  N: TNodeInfo;
begin
  if Map = nil then
    Exit;
  Map.ClearMarkers;
  for N in FClient.Nodes.Values do
    UpdateMapMarker(N);
  UpdateMapInfo;
  if (Tabs.ActiveTab = tabMap) and not FMapFitted and (Map.MarkerCount > 0) then
  begin
    FMapFitted := True;
    Map.FitMarkers;
  end;
end;

procedure TMainFormX.UpdateMapInfo;
var
  N, Me: TNodeInfo;
  WithPos: Integer;
  MeTxt: string;
begin
  if lblMapInfo = nil then
    Exit;
  WithPos := 0;
  for N in FClient.Nodes.Values do
    if N.Position.Valid then
      Inc(WithPos);
  if FClient.Nodes.TryGetValue(FClient.MyNodeNum, Me) and Me.Position.Valid then
    MeTxt := 'Your radio is on the map.'
  else
    MeTxt := 'Your radio has no location yet.';
  lblMapInfo.Text := Format('%d of %d nodes have a location.  %s', [WithPos, FClient.Nodes.Count, MeTxt]);
end;

procedure TMainFormX.ShowNodeOnMap(Num: Cardinal);
var
  N: TNodeInfo;
begin
  if not FClient.Nodes.TryGetValue(Num, N) or not N.Position.Valid then
    Exit;
  FMapFitted := True;
  Tabs.ActiveTab := tabMap;
  Map.SetView(N.Position.Lat, N.Position.Lon, Max(Map.Zoom, 12));
  Map.Selected := Num;
  MapMarkerClick(Map, Num);
end;

function TMainFormX.NotConnected: Boolean;
begin
  Result := FClient.State <> msReady;
  if Result then
    ShowInfo(Self, 'Not connected', 'MeshTerm is not connected to the radio right now, so it cannot ' +
      'change its settings. Connect first.');
end;

procedure TMainFormX.MapPlaceClick(Sender: TObject);
begin
  if Map.PlaceMode then
  begin
    Map.PlaceMode := False;
    Exit;
  end;
  if NotConnected then
    Exit;
  Map.PlaceMode := True;
end;

procedure TMainFormX.MapPlaceModeChanged(Sender: TObject);
begin
  if Map.PlaceMode then
  begin
    btnMapPlace.Text := 'Cancel';
    if IS_TOUCH then
      lblMapSel.Text := 'Tap the exact spot where your radio is. Pinch to zoom, drag to move. ' +
        'Tip: find your address first with the search box.'
    else
      lblMapSel.Text := 'Click the exact spot where your radio is. Scroll or use + / ' + #$2212 +
        ' to zoom, drag to move. Tip: find your address first with the search box.';
  end
  else
  begin
    btnMapPlace.Text := 'Set my location';
    if lblMapSel.Text.Contains('the exact spot') then
      lblMapSel.Text := '';
  end;
  Relayout;
end;

procedure TMainFormX.MapPlaced(Sender: TObject; X, Y: Single; Lat, Lon: Double);
begin
  // a "No" leaves place mode on so the user can try again
  SetLocationAt(Lat, Lon,
    procedure
    begin
      Map.PlaceMode := False;
    end);
end;

// Confirm, then store a fixed position on the radio
procedure TMainFormX.SetLocationAt(Lat, Lon: Double; const Done: TProc);
var
  C, Shared: TChannelInfo;
  Found: Boolean;
  Where: string;
begin
  if NotConnected then
    Exit;
  Found := False;
  for C in FClient.Channels do
    if (C.PositionPrecision > 0) and (not Found or (C.Index < Shared.Index)) then
    begin
      Shared := C;
      Found := True;
    end;
  if Found then
    Where := Format('It will be shared on #%s, %s.', [FClient.ChannelName(Shared.Index),
      PrecisionDescription(Shared.PositionPrecision)])
  else
    Where := 'None of your channels allow sharing a location, so other nodes will not get it.';
  if FClient.InternetMode then
    Where := Where + sLineBreak + 'Radio + Internet is on: the public server only passes on rounded locations.';
  ShowConfirm(Self, 'Set your radio''s location?', Format('%.5f, %.5f', [Lat, Lon]) + sLineBreak +
    sLineBreak + 'The radio has no GPS, so it will keep this fixed spot and report it like a GPS ' +
    'position.' + sLineBreak + Where, 'Set location',
    procedure
    begin
      try
        FClient.SetFixedPosition(Lat, Lon);
        Map.ClearPin;
        lblMapSel.Text := Format('Location sent to the radio: %.5f, %.5f', [Lat, Lon]);
        if Assigned(Done) then
          Done();
      except
        on E: Exception do
          ShowInfo(Self, 'Set location', E.Message);
      end;
    end);
end;

procedure TMainFormX.ClearLocation;
begin
  if NotConnected then
    Exit;
  ShowConfirm(Self, 'Remove your radio''s location?', 'It stops reporting a position. Nodes that ' +
    'already got it may keep showing the old spot for a while.', 'Remove',
    procedure
    begin
      try
        FClient.ClearFixedPosition;
      except
        on E: Exception do
          ShowInfo(Self, 'Remove location', E.Message);
      end;
    end);
end;

procedure TMainFormX.MapContext(Sender: TObject; X, Y: Single; Lat, Lon: Double);
var
  Me: TNodeInfo;
  Acts: TArray<TSheetAction>;
begin
  Acts := [Act('Set my radio''s location here', procedure begin SetLocationAt(Lat, Lon, nil); end)];
  if FClient.Nodes.TryGetValue(FClient.MyNodeNum, Me) and Me.Position.Valid then
    Acts := Acts + [Act('Remove my radio''s location', procedure begin ClearLocation; end)];
  Acts := Acts + [
    Act('Zoom in here', procedure begin Map.ZoomBy(1, X, Y); end),
    Act('Zoom out', procedure begin Map.ZoomBy(-1, X, Y); end),
    Act('Fit all nodes', procedure begin MapFitClick(nil); end)];
  ShowActions(Self, Format('%.5f, %.5f', [Lat, Lon]), '', Acts);
end;

procedure TMainFormX.MapMeClick(Sender: TObject);
var
  Me: TNodeInfo;
begin
  if FClient.Nodes.TryGetValue(FClient.MyNodeNum, Me) and Me.Position.Valid then
  begin
    FMapFitted := True;
    Map.SetView(Me.Position.Lat, Me.Position.Lon, Max(Map.Zoom, 12));
  end
  else
    ShowInfo(Self, 'No location', 'Your radio has no location yet (it has no GPS).' + sLineBreak +
      sLineBreak + 'Type your address or town in the search box to jump there, then use "Set my ' +
      'location" and pick the exact spot on the map.');
end;

procedure TMainFormX.MapFitClick(Sender: TObject);
begin
  if Map.MarkerCount = 0 then
  begin
    ShowInfo(Self, 'Map', 'No node has shared a location yet.');
    Exit;
  end;
  FMapFitted := True;
  Map.FitMarkers;
end;

procedure TMainFormX.MapLocalChange(Sender: TObject);
begin
  FMapFitted := False;
  RebuildMap;
end;

procedure TMainFormX.MapFindKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  if Key = vkReturn then
  begin
    Key := 0;
    MapFindClick(nil);
  end;
end;

procedure TMainFormX.MapFindClick(Sender: TObject);
var
  Q: string;
  P: TFoundPlace;
  Flag: IInterface;
  Obj: TAliveFlag;
begin
  Q := Trim(edMapFind.Text);
  if Q = '' then
  begin
    edMapFind.SetFocus;
    Exit;
  end;
  if ParseCoords(Q, P.Lat, P.Lon) then
  begin
    P.Name := Format('%.5f, %.5f', [P.Lat, P.Lon]);
    P.South := P.Lat; P.North := P.Lat; P.West := P.Lon; P.East := P.Lon;
    ShowFoundPlace(P);
    Exit;
  end;
  if FFinding then
    Exit;
  FFinding := True;
  btnMapFind.Enabled := False;
  lblMapSel.Text := 'Searching OpenStreetMap for "' + Q + '"...';
  Flag := FAlive;
  Obj := FAliveObj;
  SearchPlaces(Q,
    procedure(const Places: TArray<TFoundPlace>; const Err: string)
    begin
      if Obj.Alive then
        FindDone(Q, Places, Err);
      Flag := nil;
    end);
end;

procedure TMainFormX.FindDone(const Query: string; const Places: TArray<TFoundPlace>; const Err: string);

  function PlaceAction(const P: TFoundPlace): TSheetAction;
  var
    Name: string;
  begin
    Name := P.Name;
    if Length(Name) > 90 then
      Name := Copy(Name, 1, 87) + '...';
    Result := Act(Name, procedure begin ShowFoundPlace(P); end);
  end;

var
  Acts: TArray<TSheetAction>;
  P: TFoundPlace;
  Flag: IInterface;
  Obj: TAliveFlag;
begin
  // the free service allows one search a second
  Flag := FAlive;
  Obj := FAliveObj;
  TThread.CreateAnonymousThread(
    procedure
    begin
      Sleep(1100);
      TThread.Queue(nil,
        procedure
        begin
          if Obj.Alive then
          begin
            FFinding := False;
            btnMapFind.Enabled := True;
          end;
          Flag := nil;
        end);
    end).Start;
  if Err <> '' then
    lblMapSel.Text := 'Search failed: ' + Err
  else if Length(Places) = 0 then
    lblMapSel.Text := 'Nothing found for "' + Query + '". Try adding the town and state, or ' +
      'paste coordinates like 40.689, -74.045.'
  else if Length(Places) = 1 then
    ShowFoundPlace(Places[0])
  else
  begin
    Acts := nil;
    for P in Places do
      Acts := Acts + [PlaceAction(P)];
    lblMapSel.Text := Format('%d places match "%s".', [Length(Places), Query]);
    ShowActions(Self, 'Which one?', Format('%d places match "%s":', [Length(Places), Query]), Acts);
  end;
  Relayout;
end;

procedure TMainFormX.ShowFoundPlace(const P: TFoundPlace);
begin
  FMapFitted := True;
  Tabs.ActiveTab := tabMap;
  if (Abs(P.North - P.South) < 0.002) and (Abs(P.East - P.West) < 0.002) then
    Map.SetView(P.Lat, P.Lon, 17)
  else
    Map.FitBounds(P.South, P.North, P.West, P.East, 17);
  Map.SetPin(P.Lat, P.Lon, ShortPlaceName(P.Name));
  if Map.PlaceMode then
    lblMapSel.Text := 'Found: ' + P.Name + '.  Now pick the exact spot where your radio is.'
  else
    lblMapSel.Text := 'Found: ' + P.Name + '.  To put your radio here, use "Set my location" and ' +
      'pick the exact spot.';
  Relayout;
end;

procedure TMainFormX.MapMarkerClick(Sender: TObject; Id: Cardinal);
var
  N, Me: TNodeInfo;
  T, How: string;
begin
  if not FClient.Nodes.TryGetValue(Id, N) then
    Exit;
  FMapSel := Id;
  T := FClient.NodeName(Id) + '  ' + NodeIdStr(Id);
  if Id = FClient.MyNodeNum then
    How := 'this radio'
  else if N.ViaMqtt then
    How := 'via internet'
  else if N.HopsAway = 0 then
    How := 'heard directly'
  else if N.HopsAway > 0 then
    How := Format('%d hop(s) away', [N.HopsAway])
  else
    How := 'not heard live yet';
  T := T + ' - ' + How;
  if N.LastHeard <> 0 then
    T := T + ', last heard ' + AgoStr(N.LastHeard);
  if N.Metrics.Valid and (N.Metrics.BatteryLevel > 0) and (N.Metrics.BatteryLevel <= 100) and
    not FSettings.NoBattery.Contains(N.Num) then
    T := T + Format(', battery %d%%', [N.Metrics.BatteryLevel]);
  if (Id <> FClient.MyNodeNum) and FClient.Nodes.TryGetValue(FClient.MyNodeNum, Me) and
    Me.Position.Valid then
    T := T + ', ' + FView.DistText(DistanceKm(Me.Position.Lat, Me.Position.Lon,
      N.Position.Lat, N.Position.Lon)) + ' from you';
  lblMapSel.Text := T + '.';
  btnMapMsg.Visible := Id <> FClient.MyNodeNum;
  Relayout;
end;

procedure TMainFormX.MapMarkerDblClick(Sender: TObject; Id: Cardinal);
begin
  if Id <> FClient.MyNodeNum then
    SelectDest(Id, 0);
end;

procedure TMainFormX.MapMsgClick(Sender: TObject);
begin
  if (FMapSel <> 0) and (FMapSel <> FClient.MyNodeNum) then
    SelectDest(FMapSel, 0);
end;

{ ---------------- channels ---------------- }

procedure TMainFormX.RefreshChannels;
var
  List: TList<TChannelInfo>;
  C: TChannelInfo;
  It: TListBoxItem;
  Prev: Integer;
  D: string;
begin
  Prev := -1;
  if lbChannels.Selected <> nil then
    Prev := lbChannels.Selected.Tag;
  List := TList<TChannelInfo>.Create;
  try
    List.AddRange(FClient.Channels);
    List.Sort(TComparer<TChannelInfo>.Construct(
      function(const A, B: TChannelInfo): Integer
      begin
        Result := A.Index - B.Index;
      end));
    lbChannels.BeginUpdate;
    try
      lbChannels.Clear;
      for C in List do
      begin
        It := TListBoxItem.Create(lbChannels);
        It.Parent := lbChannels;
        It.StyleLookup := 'listboxitembottomdetail';
        It.Height := 54;
        It.Tag := C.Index;
        It.Text := '#' + FClient.ChannelName(C.Index);
        if C.Role = 1 then D := 'Primary' else D := 'Secondary';
        D := D + DOT + PskDescription(C.Psk) + DOT + 'internet ' + OnOff(C.Uplink or C.Downlink) +
          DOT + 'location: ' + PrecisionDescription(C.PositionPrecision) + DOT + Format('slot %d', [C.Index]);
        It.ItemData.Detail := D;
        if C.Index = Prev then
          It.IsSelected := True;
      end;
    finally
      lbChannels.EndUpdate;
    end;
  finally
    List.Free;
  end;
  SetTab(tabChannels, Format('Channels (%d)', [FClient.Channels.Count]), 'Chan');
  UpdateChannelButtons;
  // a channel we just created: show its QR code straight away
  if FShareAfterCreate <> '' then
    for C in FClient.Channels do
      if SameText(C.Name, FShareAfterCreate) then
      begin
        FShareAfterCreate := '';
        Tabs.ActiveTab := tabChannels;
        ShowShareSheet(C);
        Break;
      end;
end;

function TMainFormX.SelectedChannel(out C: TChannelInfo): Boolean;
var
  Ch: TChannelInfo;
begin
  Result := False;
  if (lbChannels = nil) or (lbChannels.Selected = nil) then
    Exit;
  for Ch in FClient.Channels do
    if Ch.Index = lbChannels.Selected.Tag then
    begin
      C := Ch;
      Exit(True);
    end;
end;

procedure TMainFormX.UpdateChannelButtons;
var
  C: TChannelInfo;
  Ready, HaveSel: Boolean;
begin
  if btnNewChannel = nil then
    Exit;
  Ready := FClient.State = msReady;
  HaveSel := SelectedChannel(C);
  btnNewChannel.Enabled := Ready;
  btnJoinChannel.Enabled := Ready;
  btnShareChannel.Enabled := Ready and HaveSel;
  btnDeleteChannel.Enabled := Ready and HaveSel and (C.Role = 2);
end;

procedure TMainFormX.ChannelChange(Sender: TObject);
begin
  UpdateChannelButtons;
end;

procedure TMainFormX.NewChannelClick(Sender: TObject);
begin
  if FClient.FreeChannelIndex < 0 then
  begin
    ShowInfo(Self, 'No free slot', 'All 8 channel slots are in use. Delete one first.');
    Exit;
  end;
  AskChannelName('');
end;

procedure TMainFormX.AskChannelName(const Default: string);
begin
  ShowInput(Self, 'New private channel', 'Channel name (1-11 letters, digits, - or _), e.g. Friends:',
    Default,
    procedure(Name: string)
    var
      C: TChannelInfo;
    begin
      Name := Trim(Name);
      if not ValidChannelName(Name) then
      begin
        ShowInput(Self, 'New private channel', 'Use 1 to 11 letters, digits, - or _ (no spaces):',
          Name, procedure(N2: string) begin AskChannelName(N2); end, 'Next');
        Exit;
      end;
      for C in FClient.Channels do
        if SameText(FClient.ChannelName(C.Index), Name) then
        begin
          ShowInfo(Self, 'Name taken', 'You already have a channel called ' + Name + '.');
          Exit;
        end;
      CreateChannel(Name);
    end, 'Next');
end;

procedure TMainFormX.CreateChannel(const Name: string);
var
  Extra: string;
begin
  Extra := '';
  if FClient.InternetMode then
    Extra := sLineBreak + 'Radio + Internet is on, so the channel also travels via the internet server, ' +
      'encrypted with your key: the server can see that you sent something, but not what.';
  ShowConfirm(Self, Format('Create private channel #%s?', [Name]),
    'MeshTerm makes a random 256-bit key for it. Only radios you give the key to (by QR code or link) ' +
    'can read or send on this channel.' + Extra + sLineBreak + sLineBreak +
    'Once the radio has saved it, MeshTerm shows the QR code to share.', 'Create',
    procedure
    var
      Idx: Integer;
    begin
      try
        Idx := FClient.FreeChannelIndex;
        if Idx < 0 then
          raise Exception.Create('All 8 channel slots are in use.');
        FClient.SetChannel(Idx, 2, EncodeChannelSettings(Name, SecureRandomBytes(32),
          FClient.InternetMode, FClient.InternetMode));
        FShareAfterCreate := Name;
      except
        on E: Exception do
          ShowInfo(Self, 'New channel', E.Message);
      end;
    end);
end;

procedure TMainFormX.ShareChannelClick(Sender: TObject);
var
  C: TChannelInfo;
begin
  if not SelectedChannel(C) then
    Exit;
  if (C.Role = 1) and (Length(C.Psk) <= 1) then
  begin
    ShowInfo(Self, 'Public channel', '#' + FClient.ChannelName(C.Index) + ' is the public channel: ' +
      'everyone has it already. Pick a private channel, or create one with "New private channel".');
    Exit;
  end;
  ShowShareSheet(C);
end;

procedure TMainFormX.ShowShareSheet(const C: TChannelInfo);
var
  S: TSheet;
  Q: TQrMatrix;
  N, X, Y, Px: Integer;
  Bmp: TBitmap;
  Img: TImage;
  Ed: TEdit;
  Url, ChName: string;
  Acts: TArray<TSheetAction>;
begin
  ChName := '#' + FClient.ChannelName(C.Index);
  Url := ChannelShareUrl(C.SettingsRaw, FClient.LoRa.Raw);
  Q := QrEncode(TEncoding.UTF8.GetBytes(Url), qeMedium);
  N := Length(Q);
  Px := 8;
  S := TSheet.CreateSheet(Self, 'Share ' + ChName);
  S.AddText('Your friend scans this code with their phone camera or in the Meshtastic app (or opens ' +
    'the link). The app adds ' + ChName + ' next to their existing channels.');
  Img := TImage.Create(S);
  Img.WrapMode := TImageWrapMode.Fit;
  Img.DisableInterpolation := True;
  Bmp := TBitmap.Create((N + 8) * Px, (N + 8) * Px);   // 4-module quiet zone
  try
    Bmp.Canvas.BeginScene;
    try
      Bmp.Canvas.Clear(TAlphaColors.White);
      Bmp.Canvas.Fill.Kind := TBrushKind.Solid;
      Bmp.Canvas.Fill.Color := TAlphaColors.Black;
      for Y := 0 to N - 1 do
        for X := 0 to N - 1 do
          if Q[Y][X] then
            Bmp.Canvas.FillRect(RectF((X + 4) * Px, (Y + 4) * Px, (X + 5) * Px, (Y + 5) * Px), 0, 0, [], 1);
    finally
      Bmp.Canvas.EndScene;
    end;
    Img.Bitmap.Assign(Bmp);
  finally
    Bmp.Free;
  end;
  S.AddControl(Img, 260);
  S.AddText('Anyone with this code or link can read and send on ' + ChName + '. Show it in person or ' +
    'send it privately - not on a public channel.', $FFAA1E1E);
  Ed := TEdit.Create(S);
  Ed.Text := Url;
  Ed.ReadOnly := True;
  S.AddControl(Ed, 36);
  Acts := [Act('Copy link', procedure begin CopyText(Url); end)];
  {$IFDEF ANDROID}
  Acts := Acts + [Act('Share link...',
    procedure
    var
      Share: IFMXShareSheetActionsService;
    begin
      if TPlatformServices.Current.SupportsPlatformService(IFMXShareSheetActionsService, Share) then
        Share.Share(btnShareChannel, Url, TBitmap(nil));
    end)];
  {$ELSE}
  Acts := Acts + [Act('Copy QR picture',
    procedure
    var
      Clip: IFMXExtendedClipboardService;
      Surf: TBitmapSurface;
    begin
      if TPlatformServices.Current.SupportsPlatformService(IFMXExtendedClipboardService, Clip) then
      begin
        Surf := TBitmapSurface.Create;
        try
          Surf.Assign(Img.Bitmap);
          Clip.SetImage(Surf);
        finally
          Surf.Free;
        end;
      end;
    end)];
  {$ENDIF}
  Acts := Acts + [Act('Close', nil, True)];
  S.AddButtons(Acts);
  S.Present;
end;

procedure TMainFormX.JoinChannelClick(Sender: TObject);
begin
  ShowInput(Self, 'Join a channel', 'Paste the channel link (https://meshtastic.org/e/#...):', '',
    procedure(Url: string)
    begin
      JoinChannel(Trim(Url));
    end, 'Next');
end;

procedure TMainFormX.JoinChannel(const Url: string);
var
  Names: string;
  Chans, ToAdd: TArray<TSharedChannel>;
  Ch: TSharedChannel;
  C: TChannelInfo;
  Have: Boolean;
  Slots: TArray<Integer>;
  I: Integer;
begin
  if not ParseChannelShareUrl(Url, Chans) then
  begin
    ShowInfo(Self, 'Join a channel', 'That does not look like a Meshtastic channel link.');
    Exit;
  end;
  ToAdd := nil;
  Names := '';
  for Ch in Chans do
  begin
    if (Ch.Name = '') and (Length(Ch.Psk) <= 1) then
      Continue;                              // the public default channel: already there
    Have := False;
    for C in FClient.Channels do
      if SameText(C.Name, Ch.Name) and (Length(C.Psk) = Length(Ch.Psk)) and
        ((Length(C.Psk) = 0) or CompareMem(@C.Psk[0], @Ch.Psk[0], Length(C.Psk))) then
        Have := True;
    if Have then
      Continue;
    ToAdd := ToAdd + [Ch];
    Names := Names + Format('  #%s  (%s)', [Ch.Name, PskDescription(Ch.Psk)]) + sLineBreak;
  end;
  if Length(ToAdd) = 0 then
  begin
    ShowInfo(Self, 'Join a channel', 'Your radio already has the channel(s) in that link.');
    Exit;
  end;
  Slots := nil;
  for I := 1 to 7 do
  begin
    Have := False;
    for C in FClient.Channels do
      if C.Index = I then
        Have := True;
    if not Have then
      Slots := Slots + [I];
  end;
  if Length(Slots) < Length(ToAdd) then
  begin
    ShowInfo(Self, 'Join a channel', 'Not enough free channel slots. Delete a channel first.');
    Exit;
  end;
  ShowConfirm(Self, 'Add to your radio?', Names + sLineBreak + 'Your other channels are kept.', 'Add',
    procedure
    var
      K: Integer;
    begin
      try
        for K := 0 to High(ToAdd) do
          FClient.SetChannel(Slots[K], 2, ChannelSettingsWithMqtt(ToAdd[K].Raw, FClient.InternetMode));
      except
        on E: Exception do
          ShowInfo(Self, 'Join a channel', E.Message);
      end;
    end);
end;

procedure TMainFormX.DeleteChannelClick(Sender: TObject);
var
  C: TChannelInfo;
  Idx: Integer;
begin
  if not SelectedChannel(C) or (C.Role <> 2) then
    Exit;
  Idx := C.Index;
  ShowConfirm(Self, Format('Delete #%s from your radio?', [FClient.ChannelName(Idx)]),
    'The radio forgets its key. To rejoin you need the QR code or link again (from someone who ' +
    'still has the channel).', 'Delete',
    procedure
    begin
      try
        FClient.SetChannel(Idx, 0, EncodeChannelSettings('', nil, False, False));
      except
        on E: Exception do
          ShowInfo(Self, 'Delete channel', E.Message);
      end;
    end);
end;

{ ---------------- internet ---------------- }

procedure TMainFormX.UpdateNetTab;
var
  Ready, AnyLink, Up, Down: Boolean;
  Ch: TChannelInfo;
  S, State: string;
begin
  if lblNetMode = nil then
    Exit;
  Ready := (FClient.State = msReady) and FClient.Mqtt.Valid;
  Up := False;
  Down := False;
  for Ch in FClient.Channels do
  begin
    Up := Up or Ch.Uplink;
    Down := Down or Ch.Downlink;
  end;
  AnyLink := FClient.Mqtt.Enabled or Up or Down;
  if not Ready then
    lblNetMode.Text := 'Mode: (connect to the radio first)'
  else if FClient.InternetMode then
    lblNetMode.Text := 'Mode: Radio + Internet - MeshTerm relays your radio to the MQTT server'
  else
    lblNetMode.Text := 'Mode: Radio only - nothing is sent to the internet';
  if Ready then
    lblNetRadio.Text := Format('Radio settings: MQTT %s, proxy via this device %s, channel uplink %s, ' +
      'downlink %s, OK-to-MQTT %s, map reporting %s', [OnOff(FClient.Mqtt.Enabled),
      OnOff(FClient.Mqtt.ProxyToClient), OnOff(Up), OnOff(Down), OnOff(FClient.LoRa.OkToMqtt),
      OnOff(FClient.Mqtt.MapReporting)])
  else
    lblNetRadio.Text := 'Radio settings: unknown';
  if FBridge.Connected then
    State := 'CONNECTED'
  else if FBridge.Running then
    State := 'connecting...'
  else
    State := 'not connected';
  S := Format('Server: %s   root topic: %s - %s', [FBridge.ServerAddress, FBridge.RootTopic, State]);
  if FSettings.ExtraTopics.Count > 0 then
    S := S + '   (also listening to ' + string.Join(', ', FSettings.ExtraTopics.ToStringArray) + ')';
  lblNetBroker.Text := S;
  lblNetStats.Text := Format('To internet: %d   From internet: %d   Public chat texts: %d   ' +
    'Ignored (not for you): %d   Dropped (rate limit): %d', [FBridge.Up, FBridge.Down, FBridge.Texts,
    FBridge.Ignored, FBridge.Dropped]);
  if Ready and (FRootShown <> FBridge.RootTopic) and not edRoot.IsFocused then
  begin
    FRootShown := FBridge.RootTopic;
    edRoot.Text := FRootShown;
  end;
  btnSetRoot.Enabled := Ready;
  btnInternet.Enabled := Ready and not FClient.InternetMode;
  btnRadioOnly.Enabled := Ready and (FClient.InternetMode or AnyLink);
  if FClient.InternetMode then
    SetTab(tabNet, 'Internet (on)', 'Net' + UNREAD)
  else
    SetTab(tabNet, 'Internet', 'Net');
end;

procedure TMainFormX.InternetClick(Sender: TObject);
var
  Me: TNodeInfo;
  Loc: string;
begin
  if FClient.Nodes.TryGetValue(FClient.MyNodeNum, Me) and Me.Position.Valid then
    Loc := '- Your radio has a location set. The public server only passes it on rounded (to a few km).'
  else
    Loc := '- This radio has no location set, so no location is shared.';
  ShowConfirm(Self, 'Switch to Radio + Internet?',
    'MeshTerm will relay between your radio and the public Meshtastic MQTT server:' + sLineBreak +
    '- Messages and node info on your channels are published to the server. On the default channel ' +
    'the key is public, so anyone can read them.' + sLineBreak +
    '- Messages from other gateways reach your radio and show up here as "via internet".' + sLineBreak +
    Loc + sLineBreak + sLineBreak +
    'The radio saves the settings and may reboot; MeshTerm reconnects automatically.', 'Switch',
    procedure
    begin
      try
        FClient.SetInternetMode(True);
        NetLog('Asking the radio to switch to Radio + Internet...');
      except
        on E: Exception do
          ShowInfo(Self, 'Internet', E.Message);
      end;
    end);
end;

procedure TMainFormX.RadioOnlyClick(Sender: TObject);
begin
  FBridge.Stop;
  try
    FClient.SetInternetMode(False);
    NetLog('Asking the radio to switch to Radio only...');
  except
    on E: Exception do
      ShowInfo(Self, 'Internet', E.Message);
  end;
end;

procedure TMainFormX.SetRootClick(Sender: TObject);
var
  Root, Err, Old: string;
begin
  Root := Trim(edRoot.Text);
  if not CheckTopic(Root, False, Err) then
  begin
    ShowInfo(Self, 'Root topic', Err);
    Exit;
  end;
  Old := FBridge.RootTopic;
  if SameText(Root, Old) then
  begin
    ShowInfo(Self, 'Root topic', 'The radio already uses ' + Root);
    Exit;
  end;
  ShowConfirm(Self, 'Change the radio''s MQTT root topic?', Format('From %s to %s.', [Old, Root]) +
    sLineBreak + sLineBreak + Format('Your radio will publish to %s/2/e/<channel>/%s, so your node shows ' +
    'up for people watching %s instead of %s.', [Root, NodeIdStr(FClient.MyNodeNum), Root, Old]) +
    sLineBreak + 'MeshTerm will listen there too. The radio saves the setting and may reboot.', 'Change',
    procedure
    begin
      try
        FClient.SetMqttRoot(Root);
        FRootShown := '';
        NetLog('Asking the radio to change its root topic to ' + Root + '...');
      except
        on E: Exception do
          ShowInfo(Self, 'Root topic', E.Message);
      end;
    end);
end;

procedure TMainFormX.ExtraClick(Sender: TObject);
var
  T, Err: string;
  L: TStringList;
begin
  L := TStringList.Create;
  try
    for T in string(edExtra.Text).Split([',', ';', ' ']) do
      if T.Trim <> '' then
      begin
        if not CheckTopic(T.Trim, True, Err) then
        begin
          ShowInfo(Self, 'Listen topics', Err);
          Exit;
        end;
        if L.IndexOf(T.Trim) < 0 then
          L.Add(T.Trim);
      end;
    FSettings.ExtraTopics.Assign(L);
  finally
    L.Free;
  end;
  FSettings.SaveFriendsAndTopics;
  edExtra.Text := string.Join(', ', FSettings.ExtraTopics.ToStringArray);
  if FSettings.ExtraTopics.Count = 0 then
    NetLog('Extra listen topics cleared')
  else
    NetLog('Extra listen topics: ' + edExtra.Text);
  if FBridge.Running then
    FBridge.Restart
  else if not FClient.InternetMode then
    NetLog('Saved. They are used once the radio is in Radio + Internet mode.');
  UpdateNetTab;
end;

procedure TMainFormX.FriendsApplyClick(Sender: TObject);
var
  T: string;
  N: Cardinal;
  L: TList<Cardinal>;
begin
  L := TList<Cardinal>.Create;
  try
    for T in string(edFriends.Text).Split([',', ';', ' ']) do
      if T.Trim <> '' then
      begin
        N := ParseNodeId(T);
        if N = 0 then
        begin
          ShowInfo(Self, 'Friends', Format('"%s" is not a node ID. Use the form !1a2b3c4d ' +
            '(! followed by 8 hex digits).', [T.Trim]));
          Exit;
        end;
        if not L.Contains(N) then
          L.Add(N);
      end;
    FSettings.Friends.Clear;
    FSettings.Friends.AddRange(L);
  finally
    L.Free;
  end;
  if FSettings.Friends.Count = 0 then
    FriendsChanged('Friends list cleared')
  else
    FriendsChanged('Friends: ' + FSettings.FriendsText);
end;

procedure TMainFormX.NetAllChange(Sender: TObject);
begin
  FBridge.ShowAll := chkNetAll.IsChecked;
end;

procedure TMainFormX.DeviceLogChange(Sender: TObject);
begin
  FSettings.ShowDeviceLog := chkDeviceLog.IsChecked;
  FSettings.SaveMisc;
end;

{ ---------------- alerts ---------------- }

procedure TMainFormX.SetupNotifications;
var
  Ch: TChannel;
begin
  try
    FNotify := TNotificationCenter.Create(Self);
    FNotify.OnReceiveLocalNotification := NotificationClicked;
    Ch := FNotify.CreateChannel;
    try
      Ch.Id := 'messages';
      Ch.Title := 'Messages';
      Ch.Description := 'New Meshtastic messages';
      Ch.Importance := TImportance.High;
      FNotify.CreateOrUpdateChannel(Ch);
    finally
      Ch.Free;
    end;
  except
    on E: Exception do
      AddLog('Notifications are not available: ' + E.Message);
  end;
  {$IFDEF ANDROID}
  if TOSVersion.Check(13) then
    PermissionsService.RequestPermissions(['android.permission.POST_NOTIFICATIONS'],
      procedure(const APermissions: TClassicStringDynArray; const AGrantResults: TClassicPermissionStatusDynArray)
      begin
        if (Length(AGrantResults) > 0) and (AGrantResults[0] <> TPermissionStatus.Granted) then
          AddLog('Message alerts are off: Android did not allow MeshTerm to show notifications.');
      end);
  {$ENDIF}
end;

procedure TMainFormX.MaybeAlert(const Packet: TMeshPacket; const Text: string);
var
  IsDM, IsFriend, IsPrivate, IsPublic: Boolean;
  Title: string;
begin
  if (FNotify = nil) or (Packet.From = FClient.MyNodeNum) then
    Exit;
  IsDM := Packet.To_ = FClient.MyNodeNum;
  IsFriend := FSettings.Friends.Contains(Packet.From);
  IsPrivate := (Packet.To_ = BROADCAST_ADDR) and (Packet.Channel <> 0);
  IsPublic := (Packet.To_ = BROADCAST_ADDR) and (Packet.Channel = 0);
  if not ((IsDM and FSettings.AlertDirect) or (IsFriend and FSettings.AlertFriends) or
    (IsPrivate and FSettings.AlertPrivate) or (IsPublic and FSettings.AlertPublic)) then
    Exit;
  if FSettings.AlertOnlyAway and IsUserLooking then
    Exit;
  if IsDM then
  begin
    Title := FClient.NodeName(Packet.From) + ' (direct message)';
    FAlertDest.Dest := Packet.From;
    FAlertDest.Channel := 0;
  end
  else
  begin
    Title := FClient.NodeName(Packet.From) + ' on #' + FClient.ChannelName(Packet.Channel);
    FAlertDest.Dest := BROADCAST_ADDR;
    FAlertDest.Channel := Packet.Channel;
  end;
  ShowAlert(Title, Text);
end;

procedure TMainFormX.ShowAlert(const Title, Text: string);
var
  N: TNotification;
begin
  if FNotify = nil then
    Exit;
  // several in a burst: show the first now, sum up the rest shortly
  if (FLastAlert <> 0) and (MilliSecondsBetween(Now, FLastAlert) < 4000) then
  begin
    Inc(FAlertHeld);
    FAlertHeldTitle := Title;
    FAlertHeldText := Text;
    Exit;
  end;
  FLastAlert := Now;
  try
    N := FNotify.CreateNotification;
    try
      N.Name := 'meshterm' + IntToStr(Random(MaxInt));
      N.Title := Copy(Title, 1, 63);
      N.AlertBody := Copy(Text, 1, 250);
      N.EnableSound := True;
      N.ChannelId := 'messages';
      FNotify.PresentNotification(N);
    finally
      N.Free;
    end;
  except
    on E: Exception do
      AddLog('Could not show a notification: ' + E.Message);
  end;
end;

procedure TMainFormX.NotificationClicked(Sender: TObject; ANotification: TNotification);
begin
  {$IFNDEF ANDROID}
  if WindowState = TWindowState.wsMinimized then
    WindowState := TWindowState.wsNormal;
  Show;
  BringToFront;
  Activate;
  {$ENDIF}
  if not SelectDest(FAlertDest.Dest, FAlertDest.Channel) then
    Tabs.ActiveTab := tabChat;
end;

function TMainFormX.AppEvent(AAppEvent: TApplicationEvent; AContext: TObject): Boolean;
begin
  Result := True;
  case AAppEvent of
    TApplicationEvent.BecameActive:
      FAppActive := True;
    TApplicationEvent.WillBecomeInactive, TApplicationEvent.EnteredBackground:
      FAppActive := False;
  end;
end;

{ ---------------- form / timer ---------------- }

procedure TMainFormX.TabChange(Sender: TObject);
begin
  if Tabs.ActiveTab = tabChat then
    SetTab(tabChat, 'Messages', 'Chat')
  else if Tabs.ActiveTab = tabLog then
    SetTab(tabLog, 'Log', 'Log');
  // first visit: zoom out to show every node that has a location
  if (Tabs.ActiveTab = tabMap) and not FMapFitted and (Map.MarkerCount > 0) then
  begin
    FMapFitted := True;
    TThread.ForceQueue(nil, procedure begin Map.FitMarkers; end);   // after the map has its size
  end;
  TThread.ForceQueue(nil, procedure begin Relayout; end);
end;

procedure TMainFormX.FormKeyUp(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  if (Key = vkHardwareBack) or (Key = vkEscape) then
  begin
    if CloseTopSheet then
      Key := 0
    else if Map.PlaceMode then
    begin
      Map.PlaceMode := False;
      Key := 0;
    end
    {$IFDEF ANDROID}
    else if Key = vkHardwareBack then
    begin
      // keep running (and connected) in the background instead of closing
      Key := 0;
      TAndroidHelper.Activity.moveTaskToBack(True);
    end
    {$ENDIF};
  end;
end;

// Android: keep the focused edit above the on-screen keyboard
procedure TMainFormX.KeyboardShown(Sender: TObject; KeyboardVisible: Boolean; const Bounds: TRect);
var
  P: TPointF;
begin
  P := ScreenToClient(PointF(Bounds.Left, Bounds.Top));
  Padding.Bottom := Max(0, ClientHeight - P.Y);
end;

procedure TMainFormX.KeyboardHidden(Sender: TObject; KeyboardVisible: Boolean; const Bounds: TRect);
begin
  Padding.Bottom := 0;
end;

procedure TMainFormX.TimerTick(Sender: TObject);
var
  P: string;
  Present: Boolean;
begin
  if SameText(FAutoConnect, 'BLE') then
  begin
    FAutoConnect := '';
    StartScan(procedure
      begin
        FLastPort := SelectedPort;
        FClient.Connect(FLastPort);
      end);
  end
  else if FAutoConnect <> '' then
  begin
    FillPorts(FAutoConnect);
    if cbPort.Items.IndexOf(FAutoConnect) < 0 then
      cbPort.Items.Add(FAutoConnect);
    cbPort.ItemIndex := cbPort.Items.IndexOf(FAutoConnect);
    FAutoConnect := '';
    FLastPort := SelectedPort;
    FClient.Connect(FLastPort);
  end;
  FClient.Tick;
  FBridge.Tick;
  // after the radio reboots (settings change) or is unplugged: reconnect
  if (FReconnectUntil <> 0) and (FClient.State = msDisconnected) and (Now >= FNextReconnect) then
  begin
    if Now > FReconnectUntil then
    begin
      FReconnectUntil := 0;
      AddLog('The radio did not come back. Unplug it and plug it back in (or press its reset ' +
        'button), then connect again.');
      RefreshStatus;
    end
    else
    begin
      Present := IsBlePortName(FLastPort);
      if not Present then
        for P in ListSerialPorts do
          if SameText(P, FLastPort) then
            Present := True;
      if Present then
      begin
        AddLog('Reconnecting to ' + FLastPort + '...');
        FillPorts(FLastPort);
        FClient.Connect(FLastPort);
      end;
      if IsBlePortName(FLastPort) then
        FNextReconnect := IncSecond(Now, 8)
      else
        FNextReconnect := IncSecond(Now, 3);
    end;
  end;
  if FDiscoverUntil <> 0 then
  begin
    if (Now >= FDiscoverUntil) or (FClient.State <> msReady) then
      FinishDiscover;
    UpdateDiscoverButton;
  end;
  // "5m ago" texts, and nodes ageing out of the "last hour" etc. view
  if (FClient.State = msReady) and (SecondOf(Now) mod 15 = 0) then
    FNodesDirty := True;
  if FNodesDirty then
    RefreshNodeRows;
  if (FAlertHeld > 0) and (MilliSecondsBetween(Now, FLastAlert) >= 4000) then
  begin
    FLastAlert := 0;
    if FAlertHeld = 1 then
      ShowAlert(FAlertHeldTitle, FAlertHeldText)
    else
      ShowAlert(Format('%d more new messages', [FAlertHeld]),
        'Latest: ' + FAlertHeldTitle + ': ' + FAlertHeldText);
    FAlertHeld := 0;
  end;
end;

{ ---------------- client events ---------------- }

procedure TMainFormX.ClientLog(Sender: TObject; const Line: string);
begin
  AddLog(Line);
end;

procedure TMainFormX.ClientDeviceLog(Sender: TObject; const Line: string);
begin
  if Line.StartsWith('BLE: ') then
    AddLog(Line)                       // MeshTerm's own Bluetooth steps
  else if chkDeviceLog.IsChecked then
    AddLog('[radio] ' + Line);
end;

procedure TMainFormX.ClientState(Sender: TObject);
begin
  RefreshStatus;
  FBridge.Update;
  if FClient.State = msReady then
  begin
    FReconnectUntil := 0;
    RefreshStatus;
    RefreshDests;
    RefreshChannels;
    RebuildMap;
    FNodesDirty := True;
    if FClient.LoRa.Valid and (FClient.LoRa.Region = 0) and not FRegionWarned then
    begin
      FRegionWarned := True;
      ShowInfo(Self, 'No LoRa region', 'This radio has no LoRa region set, so it cannot transmit. ' +
        'Set it with the Meshtastic app (or: meshtastic --set lora.region US).');
    end;
  end
  else if FClient.State = msDisconnected then
  begin
    FillPorts('');
    UpdateChannelButtons;
  end;
  Relayout;
end;

procedure TMainFormX.ClientNode(Sender: TObject; const Node: TNodeInfo);
var
  IsNew: Boolean;
  D: TDest;
begin
  IsNew := True;
  for D in FDests do
    if D.Dest = Node.Num then
      IsNew := False;
  FNodesDirty := True;
  UpdateMapMarker(Node);
  UpdateMapInfo;
  if Node.Num = FClient.MyNodeNum then
    RefreshStatus
  else if IsNew and (FClient.State = msReady) then
    RefreshDests;
end;

procedure TMainFormX.ClientText(Sender: TObject; const Packet: TMeshPacket; const Text: string);
var
  ToName, D, Sig: string;
begin
  if Packet.To_ = BROADCAST_ADDR then
    ToName := '#' + FClient.ChannelName(Packet.Channel)
  else if Packet.To_ = FClient.MyNodeNum then
    ToName := 'me'
  else
    ToName := FClient.NodeName(Packet.To_);
  D := FormatDateTime('hh:nn', Now) + '  ' + FClient.NodeName(Packet.From) + ARROW + ToName;
  Sig := '';
  if Packet.ViaMqtt then
    Sig := 'via internet'
  else
  begin
    if Packet.RxSnr <> 0 then
      Sig := Format('SNR %.1f', [Packet.RxSnr]);
    if Packet.HopStart > 0 then
      Sig := Trim(Sig + Format('  hops %d', [Integer(Packet.HopStart) - Integer(Packet.HopLimit)]));
  end;
  if Sig <> '' then
    D := D + DOT + Sig;
  AddChat(Text, D, FClient.NodeName(Packet.From), ToName, Sig);
  if Tabs.ActiveTab <> tabChat then
    SetTab(tabChat, 'Messages' + UNREAD, 'Chat' + UNREAD);
  {$IFDEF MSWINDOWS}
  if not IsUserLooking then
    FlashWindow(FormToHWND(Self), True);
  {$ENDIF}
  MaybeAlert(Packet, Text);
end;

procedure TMainFormX.ClientAck(Sender: TObject; PacketId: Cardinal; ErrorCode: Integer; FromNode: Cardinal);
var
  P: TPendingMsg;
  Msg: string;
begin
  if not FPending.TryGetValue(PacketId, P) then
    Exit;
  if ErrorCode = 0 then
  begin
    if (P.Dest <> BROADCAST_ADDR) and (FromNode = P.Dest) then
      Msg := 'delivered ' + CHECK
    else if P.Dest = BROADCAST_ADDR then
      Msg := 'sent ' + CHECK + ' (heard by the mesh)'
    else
      Msg := 'relayed, waiting for a reply...';
  end
  else if (ErrorCode = 5) and (P.Dest = BROADCAST_ADDR) then
    Msg := 'sent - no other node heard it'
  else if ErrorCode = 4 then
    Msg := 'failed: LoRa radio not running (replug the radio)'
  else
    Msg := 'failed: ' + RoutingErrorName(ErrorCode);
  P.Item.ItemData.Detail := P.Head + DOT + Msg;
  if (ErrorCode <> 0) or (P.Dest = BROADCAST_ADDR) or (FromNode = P.Dest) then
    FPending.Remove(PacketId);
end;

procedure TMainFormX.ClientMqttProxy(Sender: TObject; const Msg: TMqttProxyMessage);
begin
  FBridge.HandleProxy(Msg);
end;

procedure TMainFormX.ClientLost(Sender: TObject; const Reason: string);
begin
  if Reason <> '' then
    AddLog('Connection lost: ' + Reason)
  else
    AddLog('Connection lost');
  // unplugged, or rebooting after a settings change: try to reconnect for a while
  if (FLastPort <> '') and (FReconnectUntil = 0) then
  begin
    if IsBlePortName(FLastPort) then
      FReconnectUntil := IncSecond(Now, 120)
    else
      FReconnectUntil := IncSecond(Now, 60);
    FNextReconnect := IncSecond(Now, 3);
    AddLog('Will reconnect automatically when the radio is back.');
  end;
  if Tabs.ActiveTab <> tabLog then
    SetTab(tabLog, 'Log' + UNREAD, 'Log' + UNREAD);
  RefreshStatus;
end;

end.
