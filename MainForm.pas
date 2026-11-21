unit MainForm;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes,
  System.DateUtils, System.Math, System.Types, System.Generics.Collections, System.Generics.Defaults,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls,
  Vcl.ComCtrls, Vcl.Dialogs, Vcl.Menus, Vcl.Clipbrd, System.UITypes, System.IniFiles,
  System.IOUtils, Meshtastic.Proto, Meshtastic.Port, Meshtastic.Transport, Meshtastic.Client, Meshtastic.Mqtt,
  Meshtastic.Crypto, MapView, QrCode;

type
  TDestination = record
    Dest: Cardinal;
    Channel: Cardinal;
  end;

  TFoundPlace = record           // a place search result
    Name: string;
    Lat, Lon, South, North, West, East: Double;
  end;

  TMainForm = class(TForm)
  private
    FClient: TMeshClient;
    FTimer: TTimer;
    FDests: TList<TDestination>;
    FPending: TDictionary<Cardinal, TListItem>;
    // controls
    pnlTop: TPanel;
    cbPort: TComboBox;
    btnRefresh, btnConnect, btnDiscover: TButton;
    FDiscoverUntil: TDateTime;   // cooldown end; 0 = idle
    FDiscoverStart: Int64;       // unix time the last discover was sent
    chkDeviceLog: TCheckBox;
    Pages: TPageControl;
    tsChat, tsNodes, tsMap, tsChannels, tsMqtt, tsLog: TTabSheet;
    // map
    Map: TMapView;
    chkMapLocal: TCheckBox;
    lblMapInfo, lblMapSel: TLabel;
    mnuMap: TPopupMenu;
    miSetLoc, miClearLoc: TMenuItem;
    FMapClickPos: TPoint;
    btnMapPlace, btnMapFind: TButton;
    edMapFind: TEdit;
    mnuFind: TPopupMenu;
    FFound: TArray<TFoundPlace>;
    FFinding: Boolean;
    FMapFitted: Boolean;
    // channels
    lvChannels: TListView;
    btnNewChannel, btnShareChannel, btnJoinChannel, btnDeleteChannel: TButton;
    FShareAfterCreate: string;   // open the QR dialog once this new channel shows up
    // desktop alerts
    Tray: TTrayIcon;
    btnAlerts: TButton;
    mnuAlerts: TPopupMenu;
    miAlertDM, miAlertFriend, miAlertPrivate, miAlertPublic, miAlertAway: TMenuItem;
    FAlertDest: TDestination;    // conversation to open when the alert is clicked
    FLastAlert: TDateTime;
    FAlertHeld: Integer;         // alerts held back while they come in quickly
    FAlertHeldTitle, FAlertHeldText: string;
    // internet (MQTT) bridge
    lblMqttMode, lblMqttRadio, lblMqttBroker, lblMqttStats: TLabel;
    btnInternet, btnRadioOnly: TButton;
    chkMqttAll: TCheckBox;
    edRoot, edExtra, edFriends: TEdit;
    btnSetRoot, btnExtra, btnFriends: TButton;
    FFriends: TList<Cardinal>;   // node IDs whose traffic always comes in
    FNoBattery: TList<Cardinal>; // radios the user says have no battery (reading is junk)
    mnuBattery: TPopupMenu;
    miNoBattery: TMenuItem;
    FBatteryNode: Cardinal;      // node the battery menu applies to
    FTexts: Integer;             // public text messages let in
    FRootShown: string;          // radio root last copied into edRoot
    FBridgeRoot: string;         // root the running bridge subscribed with
    FExtraTopics: TStringList;   // listen-only topic roots (saved in MeshTerm.ini)
    memoMqtt: TMemo;
    FMqtt: TMqttClient;
    FMqttReady: Boolean;
    FMqttRetryAt: TDateTime;
    FSubs: TStringList;
    FUp, FDown, FDropped, FIgnored, FDownThisSec: Integer;
    // auto-reconnect after the radio reboots / is replugged
    FLastPort: string;
    FReconnectUntil, FNextReconnect: TDateTime;
    lvChat, lvNodes: TListView;
    // nodes tab
    edNodeFind: TEdit;
    cbNodeShow, cbNodeHeard: TComboBox;
    chkFriendsTop: TCheckBox;
    btnAddFriend: TButton;
    lblNodeCount, lblNodeInfo: TLabel;
    mnuNodes: TPopupMenu;
    miNodeMsg, miNodeFriend, miNodeNote, miNodeMap, miNodeCopyId, miNodeCopyName,
      miNodeNoBat: TMenuItem;
    FNodeRows: TList<Cardinal>;  // node numbers shown, in display order
    FNodeSortCol: Integer;
    FNodeSortDesc, FNodesDirty, FNodeLoading: Boolean;
    FNotes: TDictionary<Cardinal, string>;  // the user's own notes per node
    FMetric: Boolean;
    pnlSend: TPanel;
    cbDest: TComboBox;
    edMsg: TEdit;
    btnSend: TButton;
    lblBytes: TLabel;
    memoLog: TMemo;
    Status: TStatusBar;
    function S(Px: Integer): Integer;
    procedure BuildUI;
    procedure RefreshPorts;
    procedure RefreshDestinations;
    procedure RefreshStatus;
    procedure LoadNoBattery;
    procedure SaveNoBattery;
    function BatteryText(const N: TNodeInfo; Long: Boolean): string;
    procedure BatteryMenuPopup(Sender: TObject);
    procedure NoBatteryClick(Sender: TObject);
    procedure UpdateNodeRow(const N: TNodeInfo);
    procedure UpdateLastHeard;
    procedure UpdateNodesCaption;
    function IsLocalNode(const N: TNodeInfo): Boolean;
    // nodes tab
    procedure BuildNodesTab;
    procedure RefreshNodeRows;
    function NodeVisible(Num: Cardinal; const Words: TArray<string>): Boolean;
    function CompareNodes(A, B: Cardinal): Integer;
    function NodeCell(Num: Cardinal; Col: Integer): string;
    function NodeDistance(const N: TNodeInfo; out Km: Double): Boolean;
    function DistText(Km: Double): string;
    function NamesOf(const Nums: TArray<Cardinal>): string;
    function SelectedNodes: TArray<Cardinal>;
    function FocusedNode: Cardinal;
    procedure UpdateSortArrows;
    procedure UpdateNodeInfo;
    procedure NodesData(Sender: TObject; Item: TListItem);
    procedure NodesCustomDraw(Sender: TCustomListView; Item: TListItem;
      State: TCustomDrawState; var DefaultDraw: Boolean);
    procedure NodesColumnClick(Sender: TObject; Column: TListColumn);
    procedure NodeFilterChange(Sender: TObject);
    procedure NodesClick(Sender: TObject);
    procedure NodesKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure NodesKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure NodesMenuPopup(Sender: TObject);
    procedure NodeMsgClick(Sender: TObject);
    procedure NodeFriendClick(Sender: TObject);
    procedure RemoveSelectedFriends;
    procedure FriendsChanged(const Msg: string);
    procedure AddFriendClick(Sender: TObject);
    procedure NodeNoteClick(Sender: TObject);
    procedure NodeMapClick(Sender: TObject);
    procedure NodeCopyIdClick(Sender: TObject);
    procedure NodeCopyNameClick(Sender: TObject);
    procedure NodeNoBatClick(Sender: TObject);
    procedure LoadNodeSettings;
    procedure SaveNodeSettings;
    procedure SaveNote(Num: Cardinal);
    procedure AddLog(const Line: string);
    function AddChat(const From, To_, Msg, State: string): TListItem;
    // UI events
    procedure ConnectClick(Sender: TObject);
    procedure DiscoverClick(Sender: TObject);
    procedure UpdateDiscoverButton;
    procedure FinishDiscover;
    procedure RefreshClick(Sender: TObject);
    procedure SendClick(Sender: TObject);
    procedure MsgChange(Sender: TObject);
    procedure MsgKeyPress(Sender: TObject; var Key: Char);
    procedure NodesDblClick(Sender: TObject);
    procedure TimerTick(Sender: TObject);
    procedure PageChange(Sender: TObject);
    procedure AppException(Sender: TObject; E: Exception);
    // client events
    procedure ClientLog(Sender: TObject; const Line: string);
    procedure ClientDeviceLog(Sender: TObject; const Line: string);
    procedure ClientState(Sender: TObject);
    procedure ClientNode(Sender: TObject; const Node: TNodeInfo);
    procedure ClientText(Sender: TObject; const Packet: TMeshPacket; const Text: string);
    procedure ClientAck(Sender: TObject; PacketId: Cardinal; ErrorCode: Integer; FromNode: Cardinal);
    procedure ClientMqttProxy(Sender: TObject; const Msg: TMqttProxyMessage);
    procedure ClientConnectionLost(Sender: TObject; const Reason: string);
    // bridge
    procedure BuildMqttTab;
    procedure UpdateMqttTab;
    procedure UpdateBridge;
    procedure StartBridge;
    procedure StopBridge;
    procedure EnsureSubscribed(const Filter: string);
    function RootTopic: string;
    procedure MqttLog(const Line: string);
    procedure MqttConnected(Sender: TObject);
    procedure MqttMessage(const Topic: string; const Payload: TBytes);
    procedure MqttClosed(const Reason: string);
    procedure InternetClick(Sender: TObject);
    procedure RadioOnlyClick(Sender: TObject);
    procedure SetRootClick(Sender: TObject);
    procedure ExtraClick(Sender: TObject);
    procedure FriendsClick(Sender: TObject);
    function FriendsText: string;
    procedure LoadExtraTopics;
    procedure SaveExtraTopics;
    procedure SubscribeRoot(const Root: string);
    function IsPrivateChannelTopic(const Chan: string): Boolean;
    function SelectDest(Dest, Channel: Cardinal): Boolean;
    // map
    procedure BuildMapTab;
    procedure UpdateMapMarker(const N: TNodeInfo);
    procedure RebuildMap;
    procedure UpdateMapInfo;
    procedure LoadMapView;
    procedure SaveMapView;
    procedure MapFitClick(Sender: TObject);
    procedure MapMeClick(Sender: TObject);
    procedure MapFilterClick(Sender: TObject);
    procedure MapPopup(Sender: TObject);
    procedure MapSetLocClick(Sender: TObject);
    procedure MapClearLocClick(Sender: TObject);
    procedure MapZoomInClick(Sender: TObject);
    procedure MapPlaceClick(Sender: TObject);
    procedure MapPlaced(Sender: TObject; Lat, Lon: Double);
    procedure MapPlaceModeChanged(Sender: TObject);
    function SetLocationAt(Lat, Lon: Double): Boolean;
    procedure MapFindClick(Sender: TObject);
    procedure MapFindKeyPress(Sender: TObject; var Key: Char);
    procedure FindDone(const Query: string; const Places: TArray<TFoundPlace>; const Err: string);
    procedure FoundItemClick(Sender: TObject);
    procedure ShowFoundPlace(const P: TFoundPlace);
    procedure MapZoomOutClick(Sender: TObject);
    procedure MapMarkerClick(Sender: TObject; Id: Cardinal);
    procedure MapMarkerDblClick(Sender: TObject; Id: Cardinal);
    // channels
    procedure BuildChannelsTab;
    procedure RefreshChannelsList;
    procedure UpdateChannelButtons;
    function SelectedChannel(out C: TChannelInfo): Boolean;
    procedure ChannelSelect(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure NewChannelClick(Sender: TObject);
    procedure ShareChannelClick(Sender: TObject);
    procedure JoinChannelClick(Sender: TObject);
    procedure DeleteChannelClick(Sender: TObject);
    procedure ShowShareDialog(const C: TChannelInfo);
    // alerts
    procedure BuildAlerts;
    procedure LoadAlertSettings;
    procedure AlertOptionClick(Sender: TObject);
    procedure AlertsBtnClick(Sender: TObject);
    procedure TestAlertClick(Sender: TObject);
    procedure MaybeAlert(const Packet: TMeshPacket; const Text: string);
    procedure ShowAlert(const Title, Text: string);
    procedure TrayBalloonClick(Sender: TObject);
    procedure TrayRestore(Sender: TObject);
    procedure RestoreWindow;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  frmMain: TMainForm;

implementation

uses
  Winapi.CommCtrl, System.Net.HttpClient, System.NetEncoding, System.JSON, System.RegularExpressions;

{ helpers }

// %APPDATA%\MeshTerm\MeshTerm.ini (settings); messages.log lives beside it
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

{ TMainForm }

constructor TMainForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);  // no .dfm: the UI is built in code
  Randomize;
  Application.OnException := AppException;
  FDests := TList<TDestination>.Create;
  FPending := TDictionary<Cardinal, TListItem>.Create;

  FClient := TMeshClient.Create;
  FClient.OnLog := ClientLog;
  FClient.OnDeviceLog := ClientDeviceLog;
  FClient.OnStateChange := ClientState;
  FClient.OnNodeUpdated := ClientNode;
  FClient.OnText := ClientText;
  FClient.OnAck := ClientAck;
  FClient.OnMqttProxy := ClientMqttProxy;
  FClient.OnConnectionLost := ClientConnectionLost;
  FSubs := TStringList.Create;
  FExtraTopics := TStringList.Create;
  FFriends := TList<Cardinal>.Create;
  FNoBattery := TList<Cardinal>.Create;
  FNodeRows := TList<Cardinal>.Create;
  FNotes := TDictionary<Cardinal, string>.Create;
  FNodeSortCol := 10;   // last heard
  LoadNoBattery;
  LoadExtraTopics;

  BuildUI;
  LoadNodeSettings;
  RefreshPorts;
  RefreshDestinations;
  RefreshStatus;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 1000;
  FTimer.OnTimer := TimerTick;
end;

destructor TMainForm.Destroy;
begin
  if FTimer <> nil then
    FTimer.Enabled := False;
  SaveMapView;
  SaveNodeSettings;
  if lvNodes <> nil then
  begin
    lvNodes.OnData := nil;
    lvNodes.OnCustomDrawItem := nil;
  end;
  if Tray <> nil then
    Tray.Visible := False;
  StopBridge;
  FClient.Free;      // sends "disconnect" to the radio
  FSubs.Free;
  FExtraTopics.Free;
  FFriends.Free;
  FNoBattery.Free;
  FNodeRows.Free;
  FNotes.Free;
  FPending.Free;
  FDests.Free;
  inherited;
end;

function TMainForm.S(Px: Integer): Integer;
begin
  Result := MulDiv(Px, Screen.PixelsPerInch, 96);
end;

procedure TMainForm.BuildUI;

  procedure AddCol(LV: TListView; const ACaption: string; AWidth: Integer);
  var
    Col: TListColumn;
  begin
    Col := LV.Columns.Add;
    Col.Caption := ACaption;
    Col.Width := S(AWidth);
  end;

  function MakeList(Parent: TWinControl): TListView;
  begin
    Result := TListView.Create(Self);
    Result.Parent := Parent;
    Result.Align := alClient;
    Result.ViewStyle := vsReport;
    Result.ReadOnly := True;
    Result.RowSelect := True;
    Result.HideSelection := False;
    Result.DoubleBuffered := True;
  end;

var
  L: TLabel;
begin
  Caption := 'MeshTerm - Meshtastic LoRa terminal';
  Font.Name := 'Segoe UI';
  Font.Size := 9;
  Width := S(1000);
  Height := S(640);
  // the toolbars need this much room; smaller squashes them together
  Constraints.MinWidth := S(1000);
  Constraints.MinHeight := S(480);
  Position := poScreenCenter;

  // --- top bar ---
  pnlTop := TPanel.Create(Self);
  pnlTop.Parent := Self;
  pnlTop.Align := alTop;
  pnlTop.Height := S(42);
  pnlTop.BevelOuter := bvNone;
  pnlTop.Padding.SetBounds(S(8), S(8), S(8), S(8));

  L := TLabel.Create(Self);
  L.Parent := pnlTop;
  L.Caption := 'Port:';
  L.Align := alLeft;
  L.Layout := tlCenter;
  L.AlignWithMargins := True;
  L.Margins.SetBounds(0, 0, S(6), 0);

  cbPort := TComboBox.Create(Self);
  cbPort.Parent := pnlTop;
  cbPort.Style := csDropDownList;
  cbPort.Align := alLeft;
  cbPort.Width := S(110);
  cbPort.Left := S(60);

  btnRefresh := TButton.Create(Self);
  btnRefresh.Parent := pnlTop;
  btnRefresh.Caption := 'Rescan';
  btnRefresh.Align := alLeft;
  btnRefresh.Left := S(200);
  btnRefresh.Width := S(70);
  btnRefresh.AlignWithMargins := True;
  btnRefresh.Margins.SetBounds(S(6), 0, 0, 0);
  btnRefresh.OnClick := RefreshClick;

  btnConnect := TButton.Create(Self);
  btnConnect.Parent := pnlTop;
  btnConnect.Caption := 'Connect';
  btnConnect.Align := alLeft;
  btnConnect.Left := S(300);
  btnConnect.Width := S(90);
  btnConnect.AlignWithMargins := True;
  btnConnect.Margins.SetBounds(S(6), 0, 0, 0);
  btnConnect.OnClick := ConnectClick;

  btnDiscover := TButton.Create(Self);
  btnDiscover.Parent := pnlTop;
  btnDiscover.Caption := 'Discover';
  btnDiscover.Align := alLeft;
  btnDiscover.Left := S(400);
  btnDiscover.Width := S(110);
  btnDiscover.AlignWithMargins := True;
  btnDiscover.Margins.SetBounds(S(6), 0, 0, 0);
  btnDiscover.Hint := 'Ask every node in range to reply with its info';
  btnDiscover.ShowHint := True;
  btnDiscover.OnClick := DiscoverClick;

  chkDeviceLog := TCheckBox.Create(Self);
  chkDeviceLog.Parent := pnlTop;
  chkDeviceLog.Caption := 'Show radio debug output in Log';
  chkDeviceLog.Align := alRight;
  chkDeviceLog.Width := S(210);
  chkDeviceLog.Left := S(2000);
  BuildAlerts;

  // --- status bar ---
  Status := TStatusBar.Create(Self);
  Status.Parent := Self;
  Status.Panels.Add.Width := S(110);
  Status.Panels.Add.Width := S(240);
  Status.Panels.Add.Width := S(230);
  Status.Panels.Add.Width := S(170);
  Status.Panels.Add.Width := S(150);
  mnuBattery := TPopupMenu.Create(Self);
  mnuBattery.OnPopup := BatteryMenuPopup;
  miNoBattery := TMenuItem.Create(mnuBattery);
  miNoBattery.OnClick := NoBatteryClick;
  mnuBattery.Items.Add(miNoBattery);
  Status.PopupMenu := mnuBattery;

  // --- pages ---
  Pages := TPageControl.Create(Self);
  Pages.Parent := Self;
  Pages.Align := alClient;
  Pages.AlignWithMargins := True;
  Pages.Margins.SetBounds(S(8), 0, S(8), S(4));
  Pages.OnChange := PageChange;

  tsChat := TTabSheet.Create(Self);
  tsChat.PageControl := Pages;
  tsChat.Caption := 'Messages';
  tsNodes := TTabSheet.Create(Self);
  tsNodes.PageControl := Pages;
  tsNodes.Caption := 'Nodes';
  tsMap := TTabSheet.Create(Self);
  tsMap.PageControl := Pages;
  tsMap.Caption := 'Map';
  tsChannels := TTabSheet.Create(Self);
  tsChannels.PageControl := Pages;
  tsChannels.Caption := 'Channels';
  tsMqtt := TTabSheet.Create(Self);
  tsMqtt.PageControl := Pages;
  tsMqtt.Caption := 'Internet';
  tsLog := TTabSheet.Create(Self);
  tsLog.PageControl := Pages;
  tsLog.Caption := 'Log';

  // chat tab: send bar + message list
  pnlSend := TPanel.Create(Self);
  pnlSend.Parent := tsChat;
  pnlSend.Align := alBottom;
  pnlSend.Height := S(40);
  pnlSend.BevelOuter := bvNone;
  pnlSend.Padding.SetBounds(S(4), S(6), S(4), S(6));

  L := TLabel.Create(Self);
  L.Parent := pnlSend;
  L.Caption := 'To:';
  L.Align := alLeft;
  L.Layout := tlCenter;
  L.AlignWithMargins := True;
  L.Margins.SetBounds(0, 0, S(6), 0);

  cbDest := TComboBox.Create(Self);
  cbDest.Parent := pnlSend;
  cbDest.Style := csDropDownList;
  cbDest.Align := alLeft;
  cbDest.Left := S(40);
  cbDest.Width := S(230);
  cbDest.DropDownCount := 20;

  btnSend := TButton.Create(Self);
  btnSend.Parent := pnlSend;
  btnSend.Caption := 'Send';
  btnSend.Align := alRight;
  btnSend.Width := S(80);
  btnSend.OnClick := SendClick;

  lblBytes := TLabel.Create(Self);
  lblBytes.Parent := pnlSend;
  lblBytes.Align := alRight;
  lblBytes.Layout := tlCenter;
  lblBytes.AutoSize := False;
  lblBytes.Width := S(64);
  lblBytes.Alignment := taCenter;
  lblBytes.Caption := Format('0/%d', [MAX_TEXT_BYTES]);

  edMsg := TEdit.Create(Self);
  edMsg.Parent := pnlSend;
  edMsg.Align := alClient;
  edMsg.AlignWithMargins := True;
  edMsg.Margins.SetBounds(S(6), 0, S(4), 0);
  edMsg.TextHint := 'Type a message and press Enter';
  edMsg.OnChange := MsgChange;
  edMsg.OnKeyPress := MsgKeyPress;

  lvChat := MakeList(tsChat);
  AddCol(lvChat, 'Time', 70);
  AddCol(lvChat, 'From', 150);
  AddCol(lvChat, 'To', 130);
  AddCol(lvChat, 'Message', 420);
  AddCol(lvChat, 'Status / signal', 170);

  // nodes tab
  BuildNodesTab;

  // log tab
  memoLog := TMemo.Create(Self);
  memoLog.Parent := tsLog;
  memoLog.Align := alClient;
  memoLog.ReadOnly := True;
  memoLog.ScrollBars := ssBoth;
  memoLog.WordWrap := False;
  memoLog.Font.Name := 'Consolas';
  memoLog.Font.Size := 9;

  BuildMqttTab;
  BuildMapTab;
  BuildChannelsTab;
  ActiveControl := cbPort;
end;

procedure TMainForm.RefreshPorts;
var
  Ports: TArray<string>;
  Prev: string;
  P: string;
begin
  Prev := cbPort.Text;
  Ports := ListSerialPorts;
  cbPort.Items.Clear;
  for P in Ports do
    cbPort.Items.Add(P);
  cbPort.ItemIndex := cbPort.Items.IndexOf(Prev);
  if (cbPort.ItemIndex < 0) and (cbPort.Items.Count > 0) then
    cbPort.ItemIndex := 0; // USB CDC ports are listed first
end;

procedure TMainForm.RefreshDestinations;
var
  Prev, D: TDestination;
  HavePrev: Boolean;
  C: TChannelInfo;
  N: TNodeInfo;
  NodeList: TList<TNodeInfo>;
  I: Integer;
begin
  HavePrev := (cbDest.ItemIndex >= 0) and (cbDest.ItemIndex < FDests.Count);
  if HavePrev then
    Prev := FDests[cbDest.ItemIndex];

  cbDest.Items.BeginUpdate;
  try
    cbDest.Items.Clear;
    FDests.Clear;

    // channels (broadcast)
    for C in FClient.Channels do
    begin
      D.Dest := BROADCAST_ADDR;
      D.Channel := C.Index;
      FDests.Add(D);
      cbDest.Items.Add(Format('# %s (everyone, ch %d)', [FClient.ChannelName(C.Index), C.Index]));
    end;
    if FDests.Count = 0 then
    begin
      D.Dest := BROADCAST_ADDR;
      D.Channel := 0;
      FDests.Add(D);
      cbDest.Items.Add('# Primary channel (everyone)');
    end;

    // friends first - listed even if the radio has not heard from them yet
    for I := 0 to FFriends.Count - 1 do
      if FFriends[I] <> FClient.MyNodeNum then
      begin
        D.Dest := FFriends[I];
        D.Channel := 0;
        FDests.Add(D);
        if FClient.NodeName(FFriends[I]) = NodeIdStr(FFriends[I]) then
          cbDest.Items.Add('@ ' + NodeIdStr(FFriends[I]) + '  (friend)')
        else
          cbDest.Items.Add('@ ' + FClient.NodeName(FFriends[I]) + '  ' +
            NodeIdStr(FFriends[I]) + '  (friend)');
      end;

    // direct messages, sorted by name
    NodeList := TList<TNodeInfo>.Create;
    try
      for N in FClient.Nodes.Values do
        if (N.Num <> FClient.MyNodeNum) and not FFriends.Contains(N.Num) then
          NodeList.Add(N);
      NodeList.Sort(TComparer<TNodeInfo>.Construct(
        function(const A, B: TNodeInfo): Integer
        begin
          Result := CompareText(FClient.NodeName(A.Num), FClient.NodeName(B.Num));
        end));
      for N in NodeList do
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
      NodeList.Free;
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

procedure TMainForm.RefreshStatus;
var
  Me: TNodeInfo;
  Bat: string;
begin
  case FClient.State of
    msDisconnected: Status.Panels[0].Text := 'Disconnected';
    msConnecting: Status.Panels[0].Text := 'Connecting...';
    msReady: Status.Panels[0].Text := 'Connected';
  end;
  if FClient.State = msDisconnected then
    btnConnect.Caption := 'Connect'
  else
    btnConnect.Caption := 'Disconnect';
  cbPort.Enabled := FClient.State = msDisconnected;
  btnRefresh.Enabled := cbPort.Enabled;
  btnSend.Enabled := FClient.State = msReady;
  UpdateDiscoverButton;
  UpdateChannelButtons;

  if FClient.MyNodeNum <> 0 then
    Status.Panels[1].Text := FClient.NodeName(FClient.MyNodeNum) + '  ' +
      NodeIdStr(FClient.MyNodeNum)
  else
    Status.Panels[1].Text := '';

  if FClient.Metadata.FirmwareVersion <> '' then
    Status.Panels[2].Text := HwModelName(FClient.Metadata.HwModel) + '  fw ' +
      FClient.Metadata.FirmwareVersion
  else
    Status.Panels[2].Text := '';

  if FClient.LoRa.Valid then
  begin
    Status.Panels[3].Text := RegionName(FClient.LoRa.Region) + ' / ' +
      ModemPresetName(FClient.LoRa.ModemPreset);
    if FClient.LoRa.Region = 0 then
      Status.Panels[3].Text := 'REGION UNSET - no TX!';
  end
  else
    Status.Panels[3].Text := '';

  Bat := '';
  if (FClient.MyNodeNum <> 0) and FClient.Nodes.TryGetValue(FClient.MyNodeNum, Me) then
    Bat := BatteryText(Me, True);
  Status.Panels[4].Text := Bat;
end;

{ Battery column / status bar text. A radio with no battery fitted still
  reports a percentage (its battery pin floats), so the user can mark it. }
function TMainForm.BatteryText(const N: TNodeInfo; Long: Boolean): string;
begin
  Result := '';
  if FNoBattery.Contains(N.Num) then
  begin
    if Long then
      Result := 'USB powered (no battery)'
    else
      Result := 'no battery';
  end
  else if not N.Metrics.Valid then
    Exit
  else if N.Metrics.BatteryLevel > 100 then
  begin
    if Long then
      Result := 'USB powered'
    else
      Result := 'powered';
  end
  else if N.Metrics.BatteryLevel > 0 then
  begin
    if Long then
      Result := Format('Battery %d%%  %.2f V', [N.Metrics.BatteryLevel, N.Metrics.Voltage])
    else
      Result := Format('%d%% %.2fV', [N.Metrics.BatteryLevel, N.Metrics.Voltage]);
  end;
end;

// [Power] NoBattery=9f8e7d6c,... in MeshTerm.ini
procedure TMainForm.LoadNoBattery;
var
  Ini: TIniFile;
  L: TStringList;
  I: Integer;
  N: Int64;
begin
  FNoBattery.Clear;
  try
    Ini := TIniFile.Create(IniPath);
    L := TStringList.Create;
    try
      L.CommaText := Ini.ReadString('Power', 'NoBattery', '');
      for I := 0 to L.Count - 1 do
      begin
        N := StrToInt64Def('$' + Trim(L[I]).Replace('!', ''), 0);
        if (N > 0) and (N <= $FFFFFFFF) and not FNoBattery.Contains(Cardinal(N)) then
          FNoBattery.Add(Cardinal(N));
      end;
    finally
      L.Free;
      Ini.Free;
    end;
  except
    // no list
  end;
end;

procedure TMainForm.SaveNoBattery;
var
  Ini: TIniFile;
  L: TStringList;
  N: Cardinal;
begin
  try
    Ini := TIniFile.Create(IniPath);
    L := TStringList.Create;
    try
      for N in FNoBattery do
        L.Add(LowerCase(IntToHex(N, 8)));
      Ini.WriteString('Power', 'NoBattery', L.CommaText);
    finally
      L.Free;
      Ini.Free;
    end;
  except
    on E: Exception do
      AddLog('Could not save settings: ' + E.Message);
  end;
end;

// Right-click on the status bar (this radio) or on a row in the Nodes list
procedure TMainForm.BatteryMenuPopup(Sender: TObject);
begin
  FBatteryNode := 0;
  if mnuBattery.PopupComponent = lvNodes then
  begin
    if lvNodes.Selected <> nil then
      FBatteryNode := Cardinal(NativeUInt(lvNodes.Selected.Data));
  end
  else
    FBatteryNode := FClient.MyNodeNum;
  if (FBatteryNode = 0) or (FBatteryNode = FClient.MyNodeNum) then
    miNoBattery.Caption := 'This radio has no battery (hide its battery reading)'
  else
    miNoBattery.Caption := 'This node has no battery (hide its battery reading)';
  miNoBattery.Enabled := FBatteryNode <> 0;
  miNoBattery.Checked := FNoBattery.Contains(FBatteryNode);
end;

procedure TMainForm.NoBatteryClick(Sender: TObject);
var
  N: TNodeInfo;
begin
  if FBatteryNode = 0 then
    Exit;
  if FNoBattery.Contains(FBatteryNode) then
    FNoBattery.Remove(FBatteryNode)
  else
    FNoBattery.Add(FBatteryNode);
  SaveNoBattery;
  if FClient.Nodes.TryGetValue(FBatteryNode, N) then
    UpdateNodeRow(N);
  RefreshStatus;
end;

{ "Local" = this radio, or a node it actually heard over LoRa: not relayed from
  the internet, and with a hop count or signal reading (internet nodes and
  stale database entries have neither). }
function TMainForm.IsLocalNode(const N: TNodeInfo): Boolean;
begin
  Result := (N.Num = FClient.MyNodeNum) or
    (not N.ViaMqtt and ((N.HopsAway >= 0) or (N.Snr <> 0) or (N.Rssi <> 0)));
end;

procedure TMainForm.AddLog(const Line: string);
begin
  if memoLog.Lines.Count > 5000 then
    memoLog.Lines.Delete(0);
  memoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + Line);
end;

function TMainForm.AddChat(const From, To_, Msg, State: string): TListItem;
begin
  Result := lvChat.Items.Add;
  Result.Caption := FormatDateTime('hh:nn:ss', Now);
  Result.SubItems.Add(From);
  Result.SubItems.Add(To_);
  Result.SubItems.Add(Msg);
  Result.SubItems.Add(State);
  Result.MakeVisible(False);
  // keep a permanent record: %APPDATA%\MeshTerm\messages.log
  try
    TFile.AppendAllText(TPath.Combine(TPath.GetDirectoryName(IniPath), 'messages.log'),
      Format('%s'#9'%s'#9'%s'#9'%s'#9'%s', [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now),
      From, To_, Msg, State]) + sLineBreak, TEncoding.UTF8);
  except
    // logging must never break the chat
  end;
end;

{ UI events }

procedure TMainForm.RefreshClick(Sender: TObject);
begin
  RefreshPorts;
end;

procedure TMainForm.ConnectClick(Sender: TObject);
begin
  FReconnectUntil := 0;
  if FClient.State <> msDisconnected then
  begin
    StopBridge;
    FClient.Disconnect;
    Exit;
  end;
  if cbPort.ItemIndex < 0 then
  begin
    ShowMessage('No serial port selected. Plug in the radio and click Rescan.');
    Exit;
  end;
  FNodesDirty := True;
  FPending.Clear;
  FLastPort := cbPort.Text;
  FClient.Connect(FLastPort);
end;

procedure TMainForm.UpdateDiscoverButton;
var
  Left: Integer;
begin
  if FDiscoverUntil = 0 then
  begin
    btnDiscover.Caption := 'Discover';
    btnDiscover.Enabled := FClient.State = msReady;
  end
  else
  begin
    Left := Max(0, SecondsBetween(FDiscoverUntil, Now));
    btnDiscover.Caption := Format('Listening %ds', [Left]);
    btnDiscover.Enabled := False;
  end;
end;

procedure TMainForm.DiscoverClick(Sender: TObject);
begin
  try
    FClient.SendDiscover;
  except
    on E: Exception do
    begin
      ShowMessage(E.Message);
      Exit;
    end;
  end;
  FDiscoverStart := DateTimeToUnix(Now, False);
  FDiscoverUntil := IncSecond(Now, 60);
  UpdateDiscoverButton;
  Pages.ActivePage := tsNodes;
end;

procedure TMainForm.SendClick(Sender: TObject);
var
  Text: string;
  D: TDestination;
  Id: Cardinal;
  To_: string;
begin
  Text := Trim(edMsg.Text);
  if (Text = '') or (FClient.State <> msReady) then
    Exit;
  if (cbDest.ItemIndex < 0) or (cbDest.ItemIndex >= FDests.Count) then
    Exit;
  D := FDests[cbDest.ItemIndex];
  try
    Id := FClient.SendText(Text, D.Dest, D.Channel);
  except
    on E: Exception do
    begin
      ShowMessage(E.Message);
      Exit;
    end;
  end;
  if D.Dest = BROADCAST_ADDR then
    To_ := '#' + FClient.ChannelName(D.Channel)
  else
    To_ := FClient.NodeName(D.Dest);
  FPending.AddOrSetValue(Id, AddChat('me', To_, Text, 'Sending...'));
  FPending[Id].Data := Pointer(NativeUInt(D.Dest));
  edMsg.Clear;
  edMsg.SetFocus;
end;

procedure TMainForm.MsgChange(Sender: TObject);
var
  N: Integer;
begin
  N := Length(TEncoding.UTF8.GetBytes(edMsg.Text));
  lblBytes.Caption := Format('%d/%d', [N, MAX_TEXT_BYTES]);
  if N > MAX_TEXT_BYTES then
    lblBytes.Font.Color := clRed
  else
    lblBytes.Font.Color := clWindowText;
end;

procedure TMainForm.MsgKeyPress(Sender: TObject; var Key: Char);
begin
  if Key = #13 then
  begin
    Key := #0;
    SendClick(Sender);
  end;
end;

// Pick a conversation in the "To:" box and switch to the Messages tab
function TMainForm.SelectDest(Dest, Channel: Cardinal): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to FDests.Count - 1 do
    if (FDests[I].Dest = Dest) and ((Dest <> BROADCAST_ADDR) or (FDests[I].Channel = Channel)) then
    begin
      cbDest.ItemIndex := I;
      Pages.ActivePage := tsChat;
      PageChange(nil);
      if edMsg.CanFocus then
        edMsg.SetFocus;
      Exit(True);
    end;
end;

procedure TMainForm.FinishDiscover;
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
    AddLog(Format('Discover: %d node(s) heard in the last minute - see the Nodes tab.', [Found]));
  UpdateLastHeard;
end;

procedure TMainForm.TimerTick(Sender: TObject);
var
  P: string;
  Present: Boolean;
begin
  FClient.Tick;
  FDownThisSec := 0;
  if FNodesDirty then
    RefreshNodeRows;
  UpdateNodeInfo;
  if (FMqttRetryAt <> 0) and (Now >= FMqttRetryAt) then
  begin
    FMqttRetryAt := 0;
    UpdateBridge;
  end;
  if (FReconnectUntil <> 0) and (FClient.State = msDisconnected) and (Now >= FNextReconnect) then
  begin
    if Now > FReconnectUntil then
    begin
      FReconnectUntil := 0;
      AddLog('Radio did not come back. Unplug it and plug it back in (or press its reset ' +
        'button), then click Connect.');
    end
    else
    begin
      Present := False;
      for P in ListSerialPorts do
        if SameText(P, FLastPort) then
          Present := True;
      if Present then
      begin
        AddLog('Reconnecting to ' + FLastPort + '...');
        FNodesDirty := True;
        // the port vanished during the reboot: show the one we reconnect to
        RefreshPorts;
        cbPort.ItemIndex := cbPort.Items.IndexOf(FLastPort);
        FClient.Connect(FLastPort);
      end;
      FNextReconnect := IncSecond(Now, 3);
    end;
  end;
  if FDiscoverUntil <> 0 then
  begin
    if (Now >= FDiscoverUntil) or (FClient.State <> msReady) then
      FinishDiscover;
    UpdateDiscoverButton;
  end;
  if (FClient.State = msReady) and (SecondOf(Now) mod 10 = 0) then
    UpdateLastHeard;
  if (FAlertHeld > 0) and (MilliSecondsBetween(Now, FLastAlert) >= 4000) then
  begin
    if FAlertHeld = 1 then
      ShowAlert(FAlertHeldTitle, FAlertHeldText)
    else
      ShowAlert(Format('%d more new messages', [FAlertHeld]),
        'Latest: ' + FAlertHeldTitle + ': ' + FAlertHeldText);
    FAlertHeld := 0;
  end;
end;

{ Unexpected errors go to the Log tab instead of a message box: most come from
  odd packets arriving from the mesh or the internet, and a box per packet
  piles up. Actions the user starts show their own errors. }
procedure TMainForm.AppException(Sender: TObject; E: Exception);
begin
  try
    AddLog('Error: ' + E.Message);
    if (tsLog <> nil) and (Pages.ActivePage <> tsLog) then
      tsLog.Caption := 'Log *';
  except
    // never let the error handler raise
  end;
end;

procedure TMainForm.PageChange(Sender: TObject);
begin
  if Pages.ActivePage = tsLog then
    tsLog.Caption := 'Log';
  if Pages.ActivePage = tsChat then
    tsChat.Caption := 'Messages';
  // first visit: zoom out to show every node that has a location
  if (Pages.ActivePage = tsMap) and not FMapFitted and (Map.MarkerCount > 0) then
  begin
    FMapFitted := True;
    Map.FitMarkers;
  end;
end;

{ client events }

procedure TMainForm.ClientLog(Sender: TObject; const Line: string);
begin
  AddLog(Line);
end;

procedure TMainForm.ClientDeviceLog(Sender: TObject; const Line: string);
begin
  if chkDeviceLog.Checked then
    AddLog('[radio] ' + Line);
end;

procedure TMainForm.ClientState(Sender: TObject);
begin
  RefreshStatus;
  UpdateBridge;
  if FClient.State = msReady then
  begin
    FReconnectUntil := 0;
    RefreshDestinations;
    RefreshChannelsList;
    RebuildMap;
    if FClient.LoRa.Valid and (FClient.LoRa.Region = 0) then
      MessageDlg('This radio has no LoRa region set, so it cannot transmit.' + sLineBreak +
        'Set it with the Meshtastic app or:  meshtastic --set lora.region US',
        mtWarning, [mbOK], 0);
  end
  else if FClient.State = msDisconnected then
    RefreshPorts;
end;

procedure TMainForm.ClientNode(Sender: TObject; const Node: TNodeInfo);
var
  IsNew: Boolean;
  I: Integer;
begin
  IsNew := True;
  for I := 0 to FDests.Count - 1 do
    if FDests[I].Dest = Node.Num then
      IsNew := False;
  UpdateNodeRow(Node);
  UpdateMapMarker(Node);
  UpdateMapInfo;
  if Node.Num = FClient.MyNodeNum then
    RefreshStatus
  else if IsNew and (FClient.State = msReady) then
    RefreshDestinations;
  UpdateNodesCaption;
end;

procedure TMainForm.ClientText(Sender: TObject; const Packet: TMeshPacket; const Text: string);
var
  To_, Sig: string;
begin
  if Packet.To_ = BROADCAST_ADDR then
    To_ := '#' + FClient.ChannelName(Packet.Channel)
  else if Packet.To_ = FClient.MyNodeNum then
    To_ := 'me (direct)'
  else
    To_ := FClient.NodeName(Packet.To_);
  Sig := '';
  if (Packet.RxSnr <> 0) or (Packet.RxRssi <> 0) then
    Sig := Format('SNR %.1f  RSSI %d', [Packet.RxSnr, Packet.RxRssi]);
  if Packet.HopStart > 0 then
    Sig := Sig + Format('  hops %d', [Integer(Packet.HopStart) - Integer(Packet.HopLimit)]);
  if Packet.ViaMqtt then
    Sig := 'via internet (MQTT)';
  AddChat(FClient.NodeName(Packet.From), To_, Text, Trim(Sig));
  if Pages.ActivePage <> tsChat then
    tsChat.Caption := 'Messages *';
  FlashWindow(Handle, True);
  MaybeAlert(Packet, Text);
end;

procedure TMainForm.ClientAck(Sender: TObject; PacketId: Cardinal;
  ErrorCode: Integer; FromNode: Cardinal);
var
  Item: TListItem;
  Dest: Cardinal;
  Msg: string;
begin
  if not FPending.TryGetValue(PacketId, Item) then
    Exit;
  Dest := Cardinal(NativeUInt(Item.Data));
  if ErrorCode = 0 then
  begin
    if (Dest <> BROADCAST_ADDR) and (FromNode = Dest) then
      Msg := 'Delivered ' + #$2713
    else if Dest = BROADCAST_ADDR then
      Msg := 'Sent ' + #$2713 + ' (heard by mesh)'
    else
      Msg := 'Relayed, awaiting reply...';
  end
  else if (ErrorCode = 5) and (Dest = BROADCAST_ADDR) then
    Msg := 'Sent - no other node heard it'
  else if ErrorCode = 4 then
    Msg := 'Failed: LoRa radio not running (replug radio)'
  else
    Msg := 'Failed: ' + RoutingErrorName(ErrorCode);
  Item.SubItems[3] := Msg;
  if (ErrorCode <> 0) or (Dest = BROADCAST_ADDR) or (FromNode = Dest) then
    FPending.Remove(PacketId);
end;

{ ---------------------------------------------------------------------------
  Internet (MQTT) bridge.
  "Radio only":       the radio's MQTT is off; nothing touches the internet.
  "Radio + Internet": the radio has MQTT + "proxy to client" enabled. It hands
  us the MQTT messages it wants published, and we feed it messages from the
  broker. The broker address/credentials/root come from the radio's settings.
  --------------------------------------------------------------------------- }

procedure TMainForm.BuildMqttTab;

  // Each label sits in its own fixed-height row panel: auto-sizing word-wrapped
  // alTop labels overlap each other in VCL, fixed rows always lay out cleanly.
  function MakeLabel(Parent: TWinControl; Bold: Boolean; RowTop, RowHeight: Integer): TLabel;
  var
    Row: TPanel;
  begin
    Row := TPanel.Create(Self);
    Row.Parent := Parent;
    Row.BevelOuter := bvNone;
    Row.Height := RowHeight;
    Row.Top := RowTop;            // increasing Top keeps alTop rows in order
    Row.Align := alTop;
    Row.Padding.SetBounds(S(8), 0, S(8), 0);
    Result := TLabel.Create(Self);
    Result.Parent := Row;
    Result.AutoSize := False;
    Result.Align := alClient;
    Result.Layout := tlCenter;
    Result.WordWrap := True;
    if Bold then
      Result.Font.Style := [fsBold];
  end;

  // one "caption | edit | button | hint" row of the Topics section
  procedure MakeTopicRow(Parent: TWinControl; RowTop: Integer; const Caption, Hint,
    BtnCaption: string; out Ed: TEdit; out Btn: TButton; OnClick: TNotifyEvent);
  var
    Row: TPanel;
    L: TLabel;
  begin
    Row := TPanel.Create(Self);
    Row.Parent := Parent;
    Row.BevelOuter := bvNone;
    Row.Height := S(32);
    Row.Top := RowTop;
    Row.Align := alTop;
    Row.Padding.SetBounds(S(8), S(4), S(8), S(4));
    L := TLabel.Create(Self);
    L.Parent := Row;
    L.AutoSize := False;
    L.Width := S(120);
    L.Align := alLeft;
    L.Layout := tlCenter;
    L.Caption := Caption;
    Ed := TEdit.Create(Self);
    Ed.Parent := Row;
    Ed.Left := S(130);
    Ed.Width := S(300);
    Ed.Align := alLeft;
    Ed.Hint := Hint;
    Ed.ShowHint := True;
    Btn := TButton.Create(Self);
    Btn.Parent := Row;
    Btn.Left := S(440);
    Btn.Width := S(110);
    Btn.Align := alLeft;
    Btn.AlignWithMargins := True;
    Btn.Margins.SetBounds(S(6), 0, 0, 0);
    Btn.Caption := BtnCaption;
    Btn.OnClick := OnClick;
    L := TLabel.Create(Self);
    L.Parent := Row;
    L.AutoSize := False;
    L.Align := alClient;
    L.AlignWithMargins := True;
    L.Margins.SetBounds(S(10), 0, 0, 0);
    L.Layout := tlCenter;
    L.Font.Color := clGrayText;
    L.Caption := Hint;
    L.EllipsisPosition := epEndEllipsis;
  end;

var
  Top, Bottom, Topics, Buttons: TPanel;
begin
  Top := TPanel.Create(Self);
  Top.Parent := tsMqtt;
  Top.Align := alTop;
  Top.Height := S(152 + 100);
  Top.BevelOuter := bvNone;

  // bottom block: topic rows above the mode buttons
  Bottom := TPanel.Create(Self);
  Bottom.Parent := Top;
  Bottom.Align := alBottom;
  Bottom.Height := S(40 + 100);
  Bottom.BevelOuter := bvNone;

  Buttons := TPanel.Create(Self);
  Buttons.Parent := Bottom;
  Buttons.Align := alBottom;
  Buttons.Height := S(40);
  Buttons.BevelOuter := bvNone;
  Buttons.Padding.SetBounds(S(8), S(6), S(8), S(6));

  Topics := TPanel.Create(Self);
  Topics.Parent := Bottom;
  Topics.Align := alClient;
  Topics.BevelOuter := bvNone;
  Topics.Padding.SetBounds(0, S(2), 0, S(2));
  MakeTopicRow(Topics, 0, 'Radio root topic:',
    'Where your radio publishes, e.g. msh/US or msh/US/Springfield. Changes a radio setting.',
    'Set on radio', edRoot, btnSetRoot, SetRootClick);
  MakeTopicRow(Topics, S(100), 'Also listen to:',
    'Extra topics, comma separated, e.g. msh/US/Springfield, msh/US/TX/#. All their traffic comes in.',
    'Apply', edExtra, btnExtra, ExtraClick);
  edExtra.Text := string.Join(', ', FExtraTopics.ToStringArray);
  MakeTopicRow(Topics, S(200), 'Friends:',
    'Friends'' node IDs, e.g. !1a2b3c4d. Everything they send on a topic you listen to comes in. ' +
    'Also managed on the Nodes tab (right-click a node, or Add friend...).',
    'Apply', edFriends, btnFriends, FriendsClick);
  edFriends.Text := FriendsText;

  btnInternet := TButton.Create(Self);
  btnInternet.Parent := Buttons;
  btnInternet.Align := alLeft;
  btnInternet.Width := S(190);
  btnInternet.Caption := 'Switch to Radio + Internet';
  btnInternet.OnClick := InternetClick;

  btnRadioOnly := TButton.Create(Self);
  btnRadioOnly.Parent := Buttons;
  btnRadioOnly.Align := alLeft;
  btnRadioOnly.Left := S(300);
  btnRadioOnly.Width := S(170);
  btnRadioOnly.AlignWithMargins := True;
  btnRadioOnly.Margins.SetBounds(S(8), 0, 0, 0);
  btnRadioOnly.Caption := 'Switch to Radio only';
  btnRadioOnly.OnClick := RadioOnlyClick;

  chkMqttAll := TCheckBox.Create(Self);
  chkMqttAll.Parent := Buttons;
  chkMqttAll.Align := alClient;
  chkMqttAll.AlignWithMargins := True;
  chkMqttAll.Margins.SetBounds(S(16), 0, 0, 0);
  chkMqttAll.Caption := 'Also show all traffic on the root topic (msh/US is busy: several messages/sec)';
  chkMqttAll.Hint := 'Off: only messages sent directly to you come in on the root topic. ' +
    '"Also listen to" topics always let everything in.';
  chkMqttAll.ShowHint := True;

  lblMqttMode := MakeLabel(Top, True, 0, S(26));
  lblMqttRadio := MakeLabel(Top, False, S(100), S(36));   // long line: room for 2 lines
  lblMqttBroker := MakeLabel(Top, False, S(200), S(22));
  lblMqttStats := MakeLabel(Top, False, S(300), S(22));

  memoMqtt := TMemo.Create(Self);
  memoMqtt.Parent := tsMqtt;
  memoMqtt.Align := alClient;
  memoMqtt.ReadOnly := True;
  memoMqtt.ScrollBars := ssBoth;
  memoMqtt.WordWrap := False;
  memoMqtt.Font.Name := 'Consolas';
  memoMqtt.Font.Size := 9;

  UpdateMqttTab;
end;

function OnOff(B: Boolean): string;
begin
  if B then Result := 'on' else Result := 'off';
end;

procedure TMainForm.UpdateMqttTab;
var
  Ready, AnyLink: Boolean;
  Up, Down: Boolean;
  Ch: TChannelInfo;
  Addr, BrokerState: string;
begin
  if lblMqttMode = nil then
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
    lblMqttMode.Caption := 'Mode: (connect to the radio first)'
  else if FClient.InternetMode then
    lblMqttMode.Caption := 'Mode: Radio + Internet  -  MeshTerm relays your radio to the MQTT server'
  else
    lblMqttMode.Caption := 'Mode: Radio only  -  nothing is sent to the internet';

  if Ready then
    lblMqttRadio.Caption := Format('Radio settings: MQTT %s, proxy via this PC %s, ' +
      'channel uplink %s, downlink %s, OK-to-MQTT %s, map reporting %s',
      [OnOff(FClient.Mqtt.Enabled), OnOff(FClient.Mqtt.ProxyToClient), OnOff(Up),
       OnOff(Down), OnOff(FClient.LoRa.OkToMqtt), OnOff(FClient.Mqtt.MapReporting)])
  else
    lblMqttRadio.Caption := 'Radio settings: unknown';

  Addr := FClient.Mqtt.Address;
  if Addr = '' then
    Addr := 'mqtt.meshtastic.org';
  if FMqtt = nil then
    BrokerState := 'not connected'
  else if FMqttReady then
    BrokerState := 'CONNECTED'
  else
    BrokerState := 'connecting...';
  lblMqttBroker.Caption := Format('Server: %s   root topic: %s   -   %s',
    [Addr, RootTopic, BrokerState]);
  if FExtraTopics.Count > 0 then
    lblMqttBroker.Caption := lblMqttBroker.Caption + '   (also listening to ' +
      string.Join(', ', FExtraTopics.ToStringArray) + ')';
  lblMqttStats.Caption := Format('To internet: %d    From internet: %d    Public chat texts: %d    ' +
    'Ignored (not for you): %d    Dropped (rate limit): %d', [FUp, FDown, FTexts, FIgnored, FDropped]);

  // show the radio's root, but don't overwrite something the user is typing
  if Ready and (FRootShown <> RootTopic) and not edRoot.Focused then
  begin
    FRootShown := RootTopic;
    edRoot.Text := FRootShown;
  end;
  btnSetRoot.Enabled := Ready;

  btnInternet.Enabled := Ready and not FClient.InternetMode;
  btnRadioOnly.Enabled := Ready and (FClient.InternetMode or AnyLink);
  if FClient.InternetMode then
    tsMqtt.Caption := 'Internet (on)'
  else
    tsMqtt.Caption := 'Internet';
end;

procedure TMainForm.MqttLog(const Line: string);
begin
  if memoMqtt.Lines.Count > 2000 then
    memoMqtt.Lines.Delete(0);
  memoMqtt.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + Line);
end;

function TMainForm.RootTopic: string;
begin
  Result := FClient.Mqtt.Root;
  if Result = '' then
    Result := 'msh';
end;

procedure TMainForm.UpdateBridge;
var
  Want: Boolean;
begin
  Want := (FClient.State = msReady) and FClient.InternetMode;
  // radio root changed: resubscribe from scratch
  if Want and (FMqtt <> nil) and (FBridgeRoot <> RootTopic) then
  begin
    MqttLog('Root topic changed to ' + RootTopic + ' - reconnecting');
    StopBridge;
  end;
  if Want and (FMqtt = nil) and (FMqttRetryAt = 0) then
    StartBridge
  else if (FMqtt <> nil) and ((FClient.State = msDisconnected) or
    ((FClient.State = msReady) and not FClient.InternetMode)) then
    StopBridge;
  UpdateMqttTab;
end;

procedure TMainForm.StartBridge;
var
  Addr, ClientId: string;
  Port, I: Integer;
begin
  Addr := FClient.Mqtt.Address;
  if Addr = '' then
    Addr := 'mqtt.meshtastic.org';
  Port := 1883;
  I := LastDelimiter(':', Addr);
  if I > 0 then
  begin
    Port := StrToIntDef(Copy(Addr, I + 1, 5), 1883);
    Addr := Copy(Addr, 1, I - 1);
  end;
  if FClient.Mqtt.TlsEnabled then
  begin
    MqttLog('The radio asks for TLS, which MeshTerm does not support. ' +
      'Turn TLS off in the radio''s MQTT settings.');
    Exit;
  end;

  ClientId := Format('MeshTerm_%s_%.4x', [Copy(NodeIdStr(FClient.MyNodeNum), 2, 8), Random($10000)]);
  FSubs.Clear;
  FMqttReady := False;
  FBridgeRoot := RootTopic;
  FMqtt := TMqttClient.Create(Addr, Port, ClientId, FClient.Mqtt.Username, FClient.Mqtt.Password);
  FMqtt.OnConnected := MqttConnected;
  FMqtt.OnMessage := MqttMessage;
  FMqtt.OnClosed := MqttClosed;
  FMqtt.Start;
  MqttLog(Format('Connecting to %s:%d ...', [Addr, Port]));
end;

procedure TMainForm.StopBridge;
var
  M: TMqttClient;
begin
  FMqttRetryAt := 0;
  M := FMqtt;
  if M = nil then
    Exit;
  FMqtt := nil;
  FMqttReady := False;
  M.OnClosed := nil;
  M.OnConnected := nil;
  M.OnMessage := nil;
  M.Free;                       // sends DISCONNECT and waits for the thread
  FSubs.Clear;
  MqttLog('Disconnected from MQTT server');
  UpdateMqttTab;
end;

procedure TMainForm.EnsureSubscribed(const Filter: string);
begin
  if (FMqtt = nil) or (FSubs.IndexOf(Filter) >= 0) then
    Exit;
  FSubs.Add(Filter);
  FMqtt.Subscribe([Filter]);
  MqttLog('Subscribed to ' + Filter);
end;

// Listen on <root>/2/e/<channel>/+ for each downlink channel, plus PKI (direct
// messages). An entry ending in /# is subscribed as-is (root + all sub-regions).
procedure TMainForm.SubscribeRoot(const Root: string);
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

procedure TMainForm.MqttConnected(Sender: TObject);
var
  T: string;
begin
  FMqttReady := True;
  MqttLog('Connected to MQTT server');
  SubscribeRoot(RootTopic);
  for T in FExtraTopics do
    if not SameText(T, RootTopic) then
      SubscribeRoot(T);
  UpdateMqttTab;
end;

// "!1a2b3c4d" or "1a2b3c4d" -> node number; 0 if not a node ID
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

function TMainForm.FriendsText: string;
var
  N: Cardinal;
  L: TStringList;
begin
  L := TStringList.Create;
  try
    for N in FFriends do
      L.Add(NodeIdStr(N));
    Result := string.Join(', ', L.ToStringArray);
  finally
    L.Free;
  end;
end;

procedure TMainForm.LoadExtraTopics;
var
  Ini: TIniFile;
  T: string;
  N: Cardinal;
begin
  FExtraTopics.Clear;
  FFriends.Clear;
  try
    Ini := TIniFile.Create(IniPath);
    try
      for T in Ini.ReadString('MQTT', 'ExtraTopics', '').Split([',']) do
        if T.Trim <> '' then
          FExtraTopics.Add(T.Trim);
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
    // no settings file yet: nothing extra
  end;
end;

procedure TMainForm.SaveExtraTopics;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(IniPath);
  try
    Ini.WriteString('MQTT', 'ExtraTopics', string.Join(',', FExtraTopics.ToStringArray));
    Ini.WriteString('MQTT', 'Friends', FriendsText.Replace(' ', ''));
  finally
    Ini.Free;
  end;
end;

// A topic root as typed by the user: msh/..., no spaces or wildcards
// (except a trailing /# on listen-only topics), no trailing slash.
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

procedure TMainForm.SetRootClick(Sender: TObject);
var
  Root, Err: string;
begin
  Root := Trim(edRoot.Text);
  if not CheckTopic(Root, False, Err) then
  begin
    ShowMessage(Err);
    Exit;
  end;
  if SameText(Root, RootTopic) then
  begin
    ShowMessage('The radio already uses ' + Root);
    Exit;
  end;
  if MessageDlg(Format('Change the radio''s MQTT root topic from %s to %s?', [RootTopic, Root]) +
    sLineBreak + sLineBreak +
    Format('Your radio will publish to %s/2/e/<channel>/%s, so your node shows up for ' +
    'people watching %s instead of %s.', [Root, NodeIdStr(FClient.MyNodeNum), Root, RootTopic]) +
    sLineBreak + 'MeshTerm will listen there too. The radio saves the setting and may reboot.',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  try
    FClient.SetMqttRoot(Root);
    FRootShown := '';              // refresh the box from the radio once it reports back
    MqttLog('Asking the radio to change its root topic to ' + Root + '...');
  except
    on E: Exception do
      ShowMessage(E.Message);
  end;
end;

procedure TMainForm.FriendsClick(Sender: TObject);
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
          ShowMessage(Format('"%s" is not a node ID. Use the form !1a2b3c4d ' +
            '(! followed by 8 hex digits).', [T.Trim]));
          Exit;
        end;
        if not L.Contains(N) then
          L.Add(N);
      end;
    FFriends.Clear;
    FFriends.AddRange(L);
  finally
    L.Free;
  end;
  if FFriends.Count = 0 then
    FriendsChanged('Friends list cleared')
  else
    FriendsChanged('Friends: ' + FriendsText);
end;

procedure TMainForm.ExtraClick(Sender: TObject);
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
          ShowMessage(Err);
          Exit;
        end;
        if L.IndexOf(T.Trim) < 0 then
          L.Add(T.Trim);
      end;
    FExtraTopics.Assign(L);
  finally
    L.Free;
  end;
  SaveExtraTopics;
  edExtra.Text := string.Join(', ', FExtraTopics.ToStringArray);
  if FExtraTopics.Count = 0 then
    MqttLog('Extra listen topics cleared')
  else
    MqttLog('Extra listen topics: ' + edExtra.Text);
  if FMqtt <> nil then
  begin
    StopBridge;                    // resubscribe with the new list
    UpdateBridge;
  end
  else if not FClient.InternetMode then
    MqttLog('Saved. They are used once the radio is in Radio + Internet mode.');
end;

procedure TMainForm.MqttClosed(const Reason: string);
begin
  if FMqtt = nil then
    Exit;
  if Reason <> '' then
    MqttLog('MQTT connection closed: ' + Reason)
  else
    MqttLog('MQTT connection closed');
  FMqtt.Free;
  FMqtt := nil;
  FMqttReady := False;
  FSubs.Clear;
  if FClient.InternetMode then
  begin
    FMqttRetryAt := IncSecond(Now, 15);
    MqttLog('Retrying in 15 seconds');
  end;
  UpdateMqttTab;
end;

function TopicSegments(const Topic: string): TArray<string>;
begin
  Result := Topic.Split(['/']);
end;

procedure TMainForm.ClientMqttProxy(Sender: TObject; const Msg: TMqttProxyMessage);
var
  Segs: TArray<string>;
  I: Integer;
  Prefix: string;
begin
  if (FMqtt = nil) or not FMqttReady then
  begin
    Inc(FDropped);
    UpdateMqttTab;
    Exit;
  end;
  FMqtt.Publish(Msg.Topic, Msg.Data, Msg.Retained);
  Inc(FUp);
  MqttLog(Format('-> %s  (%d bytes)', [Msg.Topic, Length(Msg.Data)]));
  // Learn the exact channel topic the radio uses and listen on it too.
  Segs := TopicSegments(Msg.Topic);
  for I := 0 to High(Segs) - 2 do
    if (Segs[I] = '2') and (Segs[I + 1] = 'e') and (I + 2 < High(Segs)) then
    begin
      Prefix := string.Join('/', Copy(Segs, 0, I + 3));
      EnsureSubscribed(Prefix + '/+');
      Break;
    end;
  UpdateMqttTab;
end;

procedure TMainForm.MqttMessage(const Topic: string; const Payload: TBytes);
var
  Segs: TArray<string>;
  P: TMeshPacket;
  Gateway, Chan: string;
  IsExtra, IsText, IsFriend: Boolean;
  Plain: TBytes;
  D: TMeshData;
begin
  Segs := TopicSegments(Topic);
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
    Exit;                                     // payload-less stub (~98% of the public feed)
  // Peek inside packets on the default-key channel (LongFast & co.): public
  // chat text is rare and always worth showing, unlike position/telemetry.
  IsText := False;
  if P.Encrypted and not SameText(Chan, 'PKI') and
    DecryptDefaultChannel(P.EncBytes, P.Id, P.From, Plain) then
  begin
    // a packet on a different key "decrypts" to garbage that will not parse
    try
      D := DecodeData(Plain);
      IsText := D.PortNum = PORT_TEXT;
    except
      IsText := False;
    end;
    if IsText then
    begin
      Inc(FTexts);
      if P.To_ = BROADCAST_ADDR then
        Gateway := 'everyone'
      else
        Gateway := NodeIdStr(P.To_);
      MqttLog(Format('TEXT  %s -> %s  [%s]  %s', [NodeIdStr(P.From), Gateway, Topic,
        Utf8Text(D.Payload)]));
    end;
  end;
  IsFriend := FFriends.Contains(P.From) or IsPrivateChannelTopic(Chan);

  // Not for us: always skip other people's direct messages; skip channel
  // traffic on the (busy) root topic unless it is chat text, from a friend,
  // on one of our private channels, or "all traffic" is ticked; "Also listen to" topics were picked on
  // purpose, so their channel traffic comes in.
  IsExtra := not SameText(Copy(Topic, 1, Pos('/2/e/', Topic) - 1), FBridgeRoot);
  if (P.To_ <> FClient.MyNodeNum) and (SameText(Chan, 'PKI') or
    (not IsExtra and not IsText and not IsFriend and not chkMqttAll.Checked)) then
  begin
    Inc(FIgnored);                            // not addressed to us
    if FIgnored mod 50 = 0 then
      UpdateMqttTab;
    Exit;
  end;
  if FDownThisSec >= 10 then
  begin
    Inc(FDropped);                            // protect the radio from floods
    UpdateMqttTab;
    Exit;
  end;
  Inc(FDownThisSec);
  if FClient.SendMqttToRadio(Topic, Payload, False) then
  begin
    Inc(FDown);
    MqttLog(Format('<- %s  from %s', [Topic, NodeIdStr(P.From)]));
  end
  else
    Inc(FDropped);
  UpdateMqttTab;
end;

procedure TMainForm.InternetClick(Sender: TObject);

  function LocationNote: string;
  var
    Me: TNodeInfo;
  begin
    if FClient.Nodes.TryGetValue(FClient.MyNodeNum, Me) and Me.Position.Valid then
      Result := '  - Your radio has a location set. The public server only passes it on rounded (to a few km).'
    else
      Result := '  - This radio has no location set, so no location is shared.';
  end;

begin
  if MessageDlg('Switch to Radio + Internet?' + sLineBreak + sLineBreak +
    'MeshTerm will relay between your radio and the public Meshtastic MQTT server:' + sLineBreak +
    '  - Messages and node info on your channels are published to the server. On the ' +
    'default channel the key is public, so anyone can read them.' + sLineBreak +
    '  - Messages from other gateways reach your radio and show up here as "via internet".' + sLineBreak +
    LocationNote + sLineBreak + sLineBreak +
    'The radio saves the settings and may reboot; MeshTerm reconnects automatically.',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  try
    FClient.SetInternetMode(True);
    MqttLog('Asking the radio to switch to Radio + Internet...');
  except
    on E: Exception do
      ShowMessage(E.Message);
  end;
end;

procedure TMainForm.RadioOnlyClick(Sender: TObject);
begin
  StopBridge;
  try
    FClient.SetInternetMode(False);
    MqttLog('Asking the radio to switch to Radio only...');
  except
    on E: Exception do
      ShowMessage(E.Message);
  end;
end;

procedure TMainForm.ClientConnectionLost(Sender: TObject; const Reason: string);
begin
  // Unplugged, or rebooting after a settings change: try to reconnect for a minute.
  if (FLastPort <> '') and (FReconnectUntil = 0) then
  begin
    FReconnectUntil := IncSecond(Now, 60);
    FNextReconnect := IncSecond(Now, 2);
    AddLog('Lost the radio - will reconnect automatically when it is back.');
    if Pos('121', Reason) > 0 then
      AddLog('(The radio stopped answering over USB. If it does not come back by itself, ' +
        'unplug it and plug it back in.)');
  end;
end;

// True if an MQTT topic's channel segment is one of our private (secondary) channels
function TMainForm.IsPrivateChannelTopic(const Chan: string): Boolean;
var
  C: TChannelInfo;
begin
  for C in FClient.Channels do
    if (C.Role = 2) and (C.Name <> '') and SameText(C.Name, Chan) then
      Exit(True);
  Result := False;
end;

{ ---------------------------------------------------------------------------
  Map tab
  --------------------------------------------------------------------------- }

function DistanceKm(Lat1, Lon1, Lat2, Lon2: Double): Double;
var
  DLat, DLon, A: Double;
begin
  DLat := DegToRad(Lat2 - Lat1);
  DLon := DegToRad(Lon2 - Lon1);
  A := Sqr(Sin(DLat / 2)) + Cos(DegToRad(Lat1)) * Cos(DegToRad(Lat2)) * Sqr(Sin(DLon / 2));
  Result := 6371 * 2 * ArcTan2(Sqrt(A), Sqrt(1 - A));
end;

procedure TMainForm.BuildMapTab;
var
  Bar, Foot: TPanel;
  NextLeft: Integer;

  function AddBtn(const ACaption: string; AWidth: Integer; Ev: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := Bar;
    Result.Align := alLeft;
    Result.Left := NextLeft;
    Inc(NextLeft, 1000);
    Result.Width := S(AWidth);
    Result.AlignWithMargins := True;
    Result.Margins.SetBounds(0, 0, S(6), 0);
    Result.Caption := ACaption;
    Result.OnClick := Ev;
  end;

  function AddItem(const ACaption: string; Ev: TNotifyEvent): TMenuItem;
  begin
    Result := TMenuItem.Create(mnuMap);
    Result.Caption := ACaption;
    Result.OnClick := Ev;
    mnuMap.Items.Add(Result);
  end;

begin
  NextLeft := 0;
  Bar := TPanel.Create(Self);
  Bar.Parent := tsMap;
  Bar.Align := alTop;
  Bar.Height := S(36);
  Bar.BevelOuter := bvNone;
  Bar.Padding.SetBounds(S(4), S(5), S(4), S(5));
  btnMapPlace := AddBtn('Set my location...', 125, MapPlaceClick);
  btnMapPlace.Hint := 'Then click the map where your radio is';
  btnMapPlace.ShowHint := True;
  AddBtn('Go to my radio', 105, MapMeClick);
  AddBtn('Fit all nodes', 90, MapFitClick);

  edMapFind := TEdit.Create(Self);
  edMapFind.Parent := Bar;
  edMapFind.Align := alLeft;
  edMapFind.Left := NextLeft;
  Inc(NextLeft, 1000);
  edMapFind.Width := S(230);
  edMapFind.AlignWithMargins := True;
  edMapFind.Margins.SetBounds(S(10), S(1), S(4), S(1));
  edMapFind.TextHint := 'Address, town, or coordinates';
  edMapFind.Hint := 'Find a place: an address, a town, a ZIP code, or coordinates like ' +
    '40.689, -74.045 (place names are looked up on OpenStreetMap)';
  edMapFind.ShowHint := True;
  edMapFind.OnKeyPress := MapFindKeyPress;
  btnMapFind := AddBtn('Find', 55, MapFindClick);
  mnuFind := TPopupMenu.Create(Self);

  chkMapLocal := TCheckBox.Create(Self);
  chkMapLocal.Parent := Bar;
  chkMapLocal.Align := alLeft;
  chkMapLocal.Left := NextLeft;
  Inc(NextLeft, 1000);
  chkMapLocal.Width := S(130);
  chkMapLocal.AlignWithMargins := True;
  chkMapLocal.Margins.SetBounds(S(8), 0, S(8), 0);
  chkMapLocal.Caption := 'Local nodes only';
  chkMapLocal.OnClick := MapFilterClick;

  lblMapInfo := TLabel.Create(Self);
  lblMapInfo.Parent := Bar;
  lblMapInfo.Align := alClient;
  lblMapInfo.AutoSize := False;
  lblMapInfo.Layout := tlCenter;
  lblMapInfo.EllipsisPosition := epEndEllipsis;

  Foot := TPanel.Create(Self);
  Foot.Parent := tsMap;
  Foot.Align := alBottom;
  Foot.Height := S(24);
  Foot.BevelOuter := bvNone;
  Foot.Padding.SetBounds(S(6), 0, S(6), 0);
  lblMapSel := TLabel.Create(Self);
  lblMapSel.Parent := Foot;
  lblMapSel.Align := alClient;
  lblMapSel.AutoSize := False;
  lblMapSel.Layout := tlCenter;
  lblMapSel.EllipsisPosition := epEndEllipsis;
  lblMapSel.Caption := 'Red = this radio, orange = friend, blue = heard over the air, ' +
    'grey = via internet.  Click a node for details; double-click to message it.';

  mnuMap := TPopupMenu.Create(Self);
  mnuMap.OnPopup := MapPopup;
  miSetLoc := AddItem('Set my radio''s location here...', MapSetLocClick);
  miClearLoc := AddItem('Remove my radio''s location...', MapClearLocClick);
  AddItem('-', nil);
  AddItem('Zoom in', MapZoomInClick);
  AddItem('Zoom out', MapZoomOutClick);
  AddItem('Fit all nodes', MapFitClick);

  Map := TMapView.Create(Self);
  Map.Parent := tsMap;
  Map.Align := alClient;
  Map.PopupMenu := mnuMap;
  Map.OnMarkerClick := MapMarkerClick;
  Map.OnMarkerDblClick := MapMarkerDblClick;
  Map.OnPlace := MapPlaced;
  Map.OnPlaceModeChange := MapPlaceModeChanged;
  LoadMapView;
  UpdateMapInfo;
end;

procedure TMainForm.LoadMapView;
var
  Ini: TIniFile;
  Lat, Lon: Double;
  Z: Integer;
begin
  try
    Ini := TIniFile.Create(IniPath);
    try
      Z := Ini.ReadInteger('Map', 'Zoom', 0);
      Lat := StrToFloatDef(Ini.ReadString('Map', 'Lat', ''), 999, TFormatSettings.Invariant);
      Lon := StrToFloatDef(Ini.ReadString('Map', 'Lon', ''), 999, TFormatSettings.Invariant);
      if (Z > 0) and (Abs(Lat) <= 90) and (Abs(Lon) <= 180) then
      begin
        Map.SetView(Lat, Lon, Z);  // only a starting point: the first visit still shows all nodes
      end;
    finally
      Ini.Free;
    end;
  except
    // no saved view
  end;
end;

procedure TMainForm.SaveMapView;
var
  Ini: TIniFile;
begin
  if (Map = nil) or not FMapFitted then
    Exit;
  try
    Ini := TIniFile.Create(IniPath);
    try
      Ini.WriteInteger('Map', 'Zoom', Map.Zoom);
      Ini.WriteString('Map', 'Lat', FormatFloat('0.000000', Map.CenterLat, TFormatSettings.Invariant));
      Ini.WriteString('Map', 'Lon', FormatFloat('0.000000', Map.CenterLon, TFormatSettings.Invariant));
    finally
      Ini.Free;
    end;
  except
    // settings are optional
  end;
end;

procedure TMainForm.UpdateMapMarker(const N: TNodeInfo);
var
  M: TMapMarker;
begin
  if Map = nil then
    Exit;
  if not N.Position.Valid or (chkMapLocal.Checked and not IsLocalNode(N)) then
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
    M.Color := RGB(215, 40, 40)
  else if FFriends.Contains(N.Num) then
    M.Color := RGB(240, 140, 0)
  else if IsLocalNode(N) then
    M.Color := RGB(30, 110, 220)
  else
    M.Color := RGB(125, 125, 125);
  Map.SetMarker(M);
end;

procedure TMainForm.RebuildMap;
var
  N: TNodeInfo;
begin
  if Map = nil then
    Exit;
  Map.ClearMarkers;
  for N in FClient.Nodes.Values do
    UpdateMapMarker(N);
  UpdateMapInfo;
  if (Pages.ActivePage = tsMap) and not FMapFitted and (Map.MarkerCount > 0) then
  begin
    FMapFitted := True;
    Map.FitMarkers;
  end;
end;

procedure TMainForm.UpdateMapInfo;
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
  lblMapInfo.Caption := Format('%d of %d nodes have a location.  %s',
    [WithPos, FClient.Nodes.Count, MeTxt]);
end;

procedure TMainForm.MapFitClick(Sender: TObject);
begin
  if Map.MarkerCount = 0 then
  begin
    ShowMessage('No node has shared a location yet.');
    Exit;
  end;
  FMapFitted := True;
  Map.FitMarkers;
end;

procedure TMainForm.MapMeClick(Sender: TObject);
var
  Me: TNodeInfo;
begin
  if FClient.Nodes.TryGetValue(FClient.MyNodeNum, Me) and Me.Position.Valid then
  begin
    FMapFitted := True;
    Map.SetView(Me.Position.Lat, Me.Position.Lon, Max(Map.Zoom, 12));
  end
  else
    ShowMessage('Your radio has no location yet (it has no GPS).' + sLineBreak + sLineBreak +
      'Type your address or town in the box next to Find to jump there, then click ' +
      '"Set my location..." and click the exact spot on the map.');
end;

procedure TMainForm.MapFilterClick(Sender: TObject);
begin
  FMapFitted := False;   // re-fit to the nodes now shown
  RebuildMap;
end;

procedure TMainForm.MapPopup(Sender: TObject);
var
  Me: TNodeInfo;
begin
  FMapClickPos := Map.ScreenToClient(mnuMap.PopupPoint);
  // always clickable: when not connected the click explains why instead
  miSetLoc.Enabled := True;
  miClearLoc.Enabled := FClient.Nodes.TryGetValue(FClient.MyNodeNum, Me) and Me.Position.Valid;
end;

function NotConnectedMsg: string;
begin
  Result := 'MeshTerm is not connected to the radio right now, so it cannot change its settings.' +
    sLineBreak + sLineBreak + 'Click Connect. If that fails ("access denied" or a timeout in the ' +
    'Log tab), unplug the radio and plug it back in, then click Connect again.';
end;

procedure TMainForm.MapSetLocClick(Sender: TObject);
var
  Lat, Lon: Double;
begin
  if Map.ScreenToLatLon(FMapClickPos.X, FMapClickPos.Y, Lat, Lon) then
    SetLocationAt(Lat, Lon);
end;

// Confirm, then store a fixed position on the radio. True if it was sent.
function TMainForm.SetLocationAt(Lat, Lon: Double): Boolean;
var
  C, Shared: TChannelInfo;
  Found: Boolean;
  Where: string;
begin
  Result := False;
  if FClient.State <> msReady then
  begin
    MessageDlg(NotConnectedMsg, mtInformation, [mbOK], 0);
    Exit;
  end;
  // the radio sends its position on the first channel that allows locations
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
    Where := Where + sLineBreak + 'Radio + Internet is on: the public server only passes on ' +
      'rounded locations.';
  if MessageDlg(Format('Set this radio''s location to %.5f, %.5f?', [Lat, Lon]) + sLineBreak +
    sLineBreak + 'The radio has no GPS, so it will keep this fixed spot and report it like a ' +
    'GPS position.' + sLineBreak + Where + sLineBreak + sLineBreak +
    'To move it later, click "Set my location..." again. To remove it, right-click the map.',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  try
    FClient.SetFixedPosition(Lat, Lon);
    Result := True;
    Map.ClearPin;
    lblMapSel.Caption := Format('Location sent to the radio: %.5f, %.5f', [Lat, Lon]);
  except
    on E: Exception do
      ShowMessage(E.Message);
  end;
end;

procedure TMainForm.MapPlaceClick(Sender: TObject);
begin
  if Map.PlaceMode then
  begin
    Map.PlaceMode := False;
    Exit;
  end;
  if FClient.State <> msReady then
  begin
    MessageDlg(NotConnectedMsg, mtInformation, [mbOK], 0);
    Exit;
  end;
  Map.PlaceMode := True;
end;

procedure TMainForm.MapPlaceModeChanged(Sender: TObject);
begin
  if Map.PlaceMode then
  begin
    btnMapPlace.Caption := 'Cancel';
    lblMapSel.Caption := 'Click the exact spot where your radio is. Scroll or use + / ' +
      #$2212' to zoom, drag to move the map. Tip: find your address first with the search box.';
  end
  else
  begin
    btnMapPlace.Caption := 'Set my location...';
    if Pos('Click the exact spot', lblMapSel.Caption) = 1 then
      lblMapSel.Caption := '';
  end;
end;

procedure TMainForm.MapPlaced(Sender: TObject; Lat, Lon: Double);
begin
  // a "No" leaves place mode on so the user can click again
  if SetLocationAt(Lat, Lon) then
    Map.PlaceMode := False;
end;

{ Coordinates typed or pasted: "40.689, -74.045", "40.689 N 74.045 W",
  "40.689° N, 74.045° W", or a Google Maps link containing "@40.689,-74.045". }
function ParseCoords(const Text: string; out Lat, Lon: Double): Boolean;
var
  T: string;
  M: TMatch;
  A, B: Double;
  FS: TFormatSettings;
begin
  Result := False;
  FS := TFormatSettings.Invariant;
  T := StringReplace(Text, #$00B0, ' ', [rfReplaceAll]);
  M := TRegEx.Match(T, '@(-?\d{1,3}(?:\.\d+)?),\s*(-?\d{1,3}(?:\.\d+)?)');
  if M.Success then
  begin
    A := StrToFloatDef(M.Groups[1].Value, 999, FS);
    B := StrToFloatDef(M.Groups[2].Value, 999, FS);
  end
  else
  begin
    M := TRegEx.Match(T, '^\s*([-+]?\d{1,3}(?:\.\d+)?)\s*([NSns])?\s*[,;\s]\s*' +
      '([-+]?\d{1,3}(?:\.\d+)?)\s*([EWew])?\s*$');
    if not M.Success then
      Exit;
    A := StrToFloatDef(M.Groups[1].Value, 999, FS);
    B := StrToFloatDef(M.Groups[3].Value, 999, FS);
    // (unmatched trailing groups are left out of Groups)
    if (M.Groups.Count > 2) and SameText(M.Groups[2].Value, 'S') then
      A := -Abs(A);
    if (M.Groups.Count > 4) and SameText(M.Groups[4].Value, 'W') then
      B := -Abs(B);
  end;
  if (Abs(A) > 90) or (Abs(B) > 180) then
    Exit;
  Lat := A;
  Lon := B;
  Result := True;
end;

function ParsePlaces(const Json: string): TArray<TFoundPlace>;
var
  V: TJSONValue;
  A, BB: TJSONArray;
  I: Integer;
  O: TJSONObject;
  P: TFoundPlace;
  FS: TFormatSettings;
begin
  Result := nil;
  FS := TFormatSettings.Invariant;
  V := TJSONObject.ParseJSONValue(Json);
  try
    if not (V is TJSONArray) then
      Exit;
    A := TJSONArray(V);
    for I := 0 to A.Count - 1 do
    begin
      if not (A.Items[I] is TJSONObject) then
        Continue;
      O := TJSONObject(A.Items[I]);
      P.Name := O.GetValue<string>('display_name', '');
      P.Lat := StrToFloatDef(O.GetValue<string>('lat', ''), 999, FS);
      P.Lon := StrToFloatDef(O.GetValue<string>('lon', ''), 999, FS);
      if (Abs(P.Lat) > 90) or (Abs(P.Lon) > 180) then
        Continue;
      P.South := P.Lat; P.North := P.Lat; P.West := P.Lon; P.East := P.Lon;
      if O.TryGetValue<TJSONArray>('boundingbox', BB) and (BB.Count = 4) then
      begin
        P.South := StrToFloatDef(BB.Items[0].Value, P.Lat, FS);
        P.North := StrToFloatDef(BB.Items[1].Value, P.Lat, FS);
        P.West := StrToFloatDef(BB.Items[2].Value, P.Lon, FS);
        P.East := StrToFloatDef(BB.Items[3].Value, P.Lon, FS);
      end;
      Result := Result + [P];
    end;
  finally
    V.Free;
  end;
end;

procedure TMainForm.MapFindKeyPress(Sender: TObject; var Key: Char);
begin
  if Key = #13 then
  begin
    Key := #0;                       // no beep
    MapFindClick(nil);
  end;
end;

procedure TMainForm.MapFindClick(Sender: TObject);
var
  Q: string;
  P: TFoundPlace;
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
  lblMapSel.Caption := 'Searching OpenStreetMap for "' + Q + '"...';
  TThread.CreateAnonymousThread(
    procedure
    var
      Http: THTTPClient;
      Resp: IHTTPResponse;
      Places: TArray<TFoundPlace>;
      Err: string;
    begin
      Places := nil;
      Err := '';
      try
        Http := THTTPClient.Create;
        try
          // Nominatim's usage policy: identify the app; one search at a time
          Http.UserAgent := 'MeshTerm/1.0 (Meshtastic desktop client)';
          Http.ConnectionTimeout := 8000;
          Http.ResponseTimeout := 15000;
          Resp := Http.Get('https://nominatim.openstreetmap.org/search?format=jsonv2&limit=8&q=' +
            TNetEncoding.URL.Encode(Q));
          if Resp.StatusCode = 200 then
            Places := ParsePlaces(Resp.ContentAsString(TEncoding.UTF8))
          else
            Err := Format('the search service answered "%d %s"', [Resp.StatusCode, Resp.StatusText]);
        finally
          Http.Free;
        end;
      except
        on E: Exception do
          Err := E.Message;
      end;
      TThread.Queue(nil,
        procedure
        begin
          if not (csDestroying in ComponentState) then
            FindDone(Q, Places, Err);
        end);
    end).Start;
end;

procedure TMainForm.FindDone(const Query: string; const Places: TArray<TFoundPlace>;
  const Err: string);
var
  I: Integer;
  Item: TMenuItem;
  Pt: TPoint;
  Name: string;
begin
  // a short pause before the next search (the free service allows 1 per second)
  TThread.CreateAnonymousThread(
    procedure
    begin
      Sleep(1100);
      TThread.Queue(nil,
        procedure
        begin
          if not (csDestroying in ComponentState) then
          begin
            FFinding := False;
            btnMapFind.Enabled := True;
          end;
        end);
    end).Start;
  if Err <> '' then
  begin
    lblMapSel.Caption := 'Search failed: ' + Err;
    Exit;
  end;
  if Length(Places) = 0 then
  begin
    lblMapSel.Caption := 'Nothing found for "' + Query + '". Try adding the town and state, ' +
      'or paste coordinates like 40.689, -74.045.';
    Exit;
  end;
  if Length(Places) = 1 then
  begin
    ShowFoundPlace(Places[0]);
    Exit;
  end;
  // several matches: let the user pick
  FFound := Places;
  mnuFind.Items.Clear;
  for I := 0 to High(Places) do
  begin
    Name := Places[I].Name;
    if Length(Name) > 100 then
      Name := Copy(Name, 1, 97) + '...';
    Item := TMenuItem.Create(mnuFind);
    Item.Caption := StringReplace(Name, '&', '&&', [rfReplaceAll]);
    Item.Tag := I;
    Item.OnClick := FoundItemClick;
    mnuFind.Items.Add(Item);
  end;
  lblMapSel.Caption := Format('%d places match "%s": pick one from the list.', [Length(Places), Query]);
  Pt := edMapFind.ClientToScreen(Point(0, edMapFind.Height));
  mnuFind.Popup(Pt.X, Pt.Y);
end;

procedure TMainForm.FoundItemClick(Sender: TObject);
var
  I: Integer;
begin
  I := (Sender as TMenuItem).Tag;
  if (I >= 0) and (I <= High(FFound)) then
    ShowFoundPlace(FFound[I]);
end;

procedure TMainForm.ShowFoundPlace(const P: TFoundPlace);
var
  Short: string;
begin
  FMapFitted := True;
  if (Abs(P.North - P.South) < 0.002) and (Abs(P.East - P.West) < 0.002) then
    Map.SetView(P.Lat, P.Lon, 17)
  else
    Map.FitBounds(P.South, P.North, P.West, P.East, 17);
  Short := P.Name;
  // a place name: keep the first part; typed coordinates: keep them whole
  if (Pos(',', Short) > 0) and TRegEx.IsMatch(Short, '[A-Za-z]') then
    Short := Trim(Copy(Short, 1, Pos(',', Short) - 1));
  if Length(Short) > 40 then
    Short := Copy(Short, 1, 38) + '...';
  Map.SetPin(P.Lat, P.Lon, Short);
  if Map.PlaceMode then
    lblMapSel.Caption := 'Found: ' + P.Name + '.  Now click the exact spot where your radio is.'
  else
    lblMapSel.Caption := 'Found: ' + P.Name + '.  To put your radio here, click "Set my ' +
      'location..." and then click the exact spot.';
end;

procedure TMainForm.MapClearLocClick(Sender: TObject);
begin
  if FClient.State <> msReady then
  begin
    MessageDlg(NotConnectedMsg, mtInformation, [mbOK], 0);
    Exit;
  end;
  if MessageDlg('Remove this radio''s location?' + sLineBreak +
    'It stops reporting a position. Nodes that already got it may keep showing the old spot for a while.',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  try
    FClient.ClearFixedPosition;
  except
    on E: Exception do
      ShowMessage(E.Message);
  end;
end;

procedure TMainForm.MapZoomInClick(Sender: TObject);
begin
  Map.ZoomBy(1, FMapClickPos.X, FMapClickPos.Y);
end;

procedure TMainForm.MapZoomOutClick(Sender: TObject);
begin
  Map.ZoomBy(-1, FMapClickPos.X, FMapClickPos.Y);
end;

procedure TMainForm.MapMarkerClick(Sender: TObject; Id: Cardinal);
var
  N, Me: TNodeInfo;
  T, How: string;
begin
  if not FClient.Nodes.TryGetValue(Id, N) then
    Exit;
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
  T := T + '   -   ' + How;
  if N.LastHeard <> 0 then
    T := T + ', last heard ' + AgoStr(N.LastHeard);
  if N.Metrics.Valid and (N.Metrics.BatteryLevel > 0) and (N.Metrics.BatteryLevel <= 100) and
    not FNoBattery.Contains(N.Num) then
    T := T + Format(', battery %d%%', [N.Metrics.BatteryLevel]);
  if (Id <> FClient.MyNodeNum) and FClient.Nodes.TryGetValue(FClient.MyNodeNum, Me) and
    Me.Position.Valid then
    T := T + Format(', %.1f km from you', [DistanceKm(Me.Position.Lat, Me.Position.Lon,
      N.Position.Lat, N.Position.Lon)]);
  lblMapSel.Caption := T + '.   Double-click to message.';
end;

procedure TMainForm.MapMarkerDblClick(Sender: TObject; Id: Cardinal);
begin
  if Id <> FClient.MyNodeNum then
    SelectDest(Id, 0);
end;

{ ---------------------------------------------------------------------------
  Channels tab: private channels and share links / QR codes
  --------------------------------------------------------------------------- }

procedure TMainForm.BuildChannelsTab;
var
  Info, Bar: TPanel;
  L: TLabel;
  NextLeft: Integer;

  function AddBtn(const ACaption: string; AWidth: Integer; Ev: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := Bar;
    Result.Align := alLeft;
    Result.Left := NextLeft;
    Inc(NextLeft, 1000);
    Result.Width := S(AWidth);
    Result.AlignWithMargins := True;
    Result.Margins.SetBounds(0, 0, S(8), 0);
    Result.Caption := ACaption;
    Result.OnClick := Ev;
  end;

  procedure AddCol(const ACaption: string; AWidth: Integer);
  begin
    with lvChannels.Columns.Add do
    begin
      Caption := ACaption;
      Width := S(AWidth);
    end;
  end;

begin
  NextLeft := 0;
  Info := TPanel.Create(Self);
  Info.Parent := tsChannels;
  Info.Align := alTop;
  Info.Height := S(58);
  Info.BevelOuter := bvNone;
  Info.Padding.SetBounds(S(8), S(6), S(8), S(4));
  L := TLabel.Create(Self);
  L.Parent := Info;
  L.Align := alClient;
  L.AutoSize := False;
  L.WordWrap := True;
  L.Caption := 'A private channel has its own secret key: only radios that have the key can read ' +
    'or send on it. Create one, then let your friend scan its QR code with the Meshtastic app ' +
    '(or send them the link privately). Its messages show up in the Messages tab as #name. ' +
    'Your radio keeps the public channel as well.';

  Bar := TPanel.Create(Self);
  Bar.Parent := tsChannels;
  Bar.Align := alBottom;
  Bar.Height := S(42);
  Bar.BevelOuter := bvNone;
  Bar.Padding.SetBounds(S(6), S(7), S(6), S(7));
  btnNewChannel := AddBtn('New private channel...', 160, NewChannelClick);
  btnShareChannel := AddBtn('Share / QR code...', 140, ShareChannelClick);
  btnJoinChannel := AddBtn('Join from a link...', 140, JoinChannelClick);
  btnDeleteChannel := AddBtn('Delete channel', 120, DeleteChannelClick);

  lvChannels := TListView.Create(Self);
  lvChannels.Parent := tsChannels;
  lvChannels.Align := alClient;
  lvChannels.AlignWithMargins := True;
  lvChannels.Margins.SetBounds(S(6), 0, S(6), 0);
  lvChannels.ViewStyle := vsReport;
  lvChannels.ReadOnly := True;
  lvChannels.RowSelect := True;
  lvChannels.HideSelection := False;
  AddCol('Slot', 45);
  AddCol('Name', 140);
  AddCol('Type', 90);
  AddCol('Encryption', 160);
  AddCol('Internet', 70);
  AddCol('Location shared', 190);
  lvChannels.OnSelectItem := ChannelSelect;
  lvChannels.OnDblClick := ShareChannelClick;
  UpdateChannelButtons;
end;

procedure TMainForm.RefreshChannelsList;
var
  List: TList<TChannelInfo>;
  C: TChannelInfo;
  Item: TListItem;
  PrevIndex: Integer;
begin
  PrevIndex := -1;
  if lvChannels.Selected <> nil then
    PrevIndex := Integer(NativeInt(lvChannels.Selected.Data));
  List := TList<TChannelInfo>.Create;
  try
    List.AddRange(FClient.Channels);
    List.Sort(TComparer<TChannelInfo>.Construct(
      function(const A, B: TChannelInfo): Integer
      begin
        Result := A.Index - B.Index;
      end));
    lvChannels.Items.BeginUpdate;
    try
      lvChannels.Items.Clear;
      for C in List do
      begin
        Item := lvChannels.Items.Add;
        Item.Data := Pointer(NativeInt(C.Index));
        Item.Caption := IntToStr(C.Index);
        Item.SubItems.Add('#' + FClient.ChannelName(C.Index));
        if C.Role = 1 then
          Item.SubItems.Add('Primary')
        else
          Item.SubItems.Add('Secondary');
        Item.SubItems.Add(PskDescription(C.Psk));
        if C.Uplink or C.Downlink then
          Item.SubItems.Add('on')
        else
          Item.SubItems.Add('off');
        Item.SubItems.Add(PrecisionDescription(C.PositionPrecision));
        if C.Index = PrevIndex then
          Item.Selected := True;
      end;
    finally
      lvChannels.Items.EndUpdate;
    end;
  finally
    List.Free;
  end;
  tsChannels.Caption := Format('Channels (%d)', [FClient.Channels.Count]);
  UpdateChannelButtons;

  // a channel we just created: show its QR code straight away
  if FShareAfterCreate <> '' then
    for C in FClient.Channels do
      if SameText(C.Name, FShareAfterCreate) then
      begin
        FShareAfterCreate := '';
        Pages.ActivePage := tsChannels;
        ShowShareDialog(C);
        Break;
      end;
end;

function TMainForm.SelectedChannel(out C: TChannelInfo): Boolean;
var
  Idx: Integer;
begin
  Result := False;
  if lvChannels.Selected = nil then
    Exit;
  Idx := Integer(NativeInt(lvChannels.Selected.Data));
  for var Ch in FClient.Channels do
    if Ch.Index = Idx then
    begin
      C := Ch;
      Exit(True);
    end;
end;

procedure TMainForm.UpdateChannelButtons;
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

procedure TMainForm.ChannelSelect(Sender: TObject; Item: TListItem; Selected: Boolean);
begin
  UpdateChannelButtons;
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

procedure TMainForm.NewChannelClick(Sender: TObject);
var
  Name, Extra: string;
  Idx: Integer;
  C: TChannelInfo;
  Raw: TBytes;
begin
  Idx := FClient.FreeChannelIndex;
  if Idx < 0 then
  begin
    ShowMessage('All 8 channel slots are in use. Delete one first.');
    Exit;
  end;
  Name := '';
  repeat
    if not InputQuery('New private channel',
      'Channel name (1-11 letters, digits, - or _), e.g. Friends:', Name) then
      Exit;
    Name := Trim(Name);
    if not ValidChannelName(Name) then
      ShowMessage('Use 1 to 11 letters, digits, - or _ (no spaces).')
    else
    begin
      for C in FClient.Channels do
        if SameText(FClient.ChannelName(C.Index), Name) then
        begin
          ShowMessage('You already have a channel called ' + Name + '.');
          Name := '';
          Break;
        end;
      if Name <> '' then
        Break;
    end;
  until False;

  Extra := '';
  if FClient.InternetMode then
    Extra := sLineBreak + 'Radio + Internet is on, so the channel also travels via the internet ' +
      'server, encrypted with your key: the server can see that you sent something, but not what.';
  if MessageDlg(Format('Create private channel #%s?', [Name]) + sLineBreak + sLineBreak +
    'MeshTerm makes a random 256-bit key for it. Only radios you give the key to (by QR code or ' +
    'link) can read or send on this channel.' + Extra + sLineBreak + sLineBreak +
    'Once the radio has saved it, MeshTerm shows the QR code to share.',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  try
    Raw := EncodeChannelSettings(Name, SecureRandomBytes(32), FClient.InternetMode,
      FClient.InternetMode);
    FClient.SetChannel(Idx, 2, Raw);
    FShareAfterCreate := Name;
  except
    on E: Exception do
      ShowMessage(E.Message);
  end;
end;

procedure TMainForm.ShareChannelClick(Sender: TObject);
var
  C: TChannelInfo;
begin
  if not SelectedChannel(C) then
    Exit;
  if (C.Role = 1) and (Length(C.Psk) <= 1) then
  begin
    ShowMessage('#' + FClient.ChannelName(C.Index) + ' is the public channel: everyone has it ' +
      'already. Pick a private channel, or create one with "New private channel".');
    Exit;
  end;
  ShowShareDialog(C);
end;

procedure TMainForm.ShowShareDialog(const C: TChannelInfo);
var
  F: TForm;
  Img: TImage;
  Ed: TEdit;
  L1, L2: TLabel;
  BCopy, BCopyImg, BClose: TButton;
  Q: TQrMatrix;
  Bmp: TBitmap;
  Url, ChName: string;
  N, Px, X, Y, W, Top: Integer;
begin
  ChName := '#' + FClient.ChannelName(C.Index);
  Url := ChannelShareUrl(C.SettingsRaw, FClient.LoRa.Raw);
  Q := QrEncode(TEncoding.UTF8.GetBytes(Url), qeMedium);
  N := Length(Q);
  Px := Max(3, S(330) div (N + 8));
  Bmp := TBitmap.Create;
  F := TForm.CreateNew(Self);
  try
    Bmp.SetSize((N + 8) * Px, (N + 8) * Px);   // 4-module quiet zone on each side
    Bmp.Canvas.Brush.Color := clWhite;
    Bmp.Canvas.FillRect(Rect(0, 0, Bmp.Width, Bmp.Height));
    Bmp.Canvas.Brush.Color := clBlack;
    for Y := 0 to N - 1 do
      for X := 0 to N - 1 do
        if Q[Y][X] then
          Bmp.Canvas.FillRect(Rect((X + 4) * Px, (Y + 4) * Px, (X + 5) * Px, (Y + 5) * Px));

    F.Caption := 'Share ' + ChName;
    F.BorderStyle := bsDialog;
    F.Position := poOwnerFormCenter;
    F.Font.Assign(Font);
    W := Max(Bmp.Width + S(40), S(480));
    F.ClientWidth := W;

    L1 := TLabel.Create(F);
    L1.Parent := F;
    L1.AutoSize := False;
    L1.WordWrap := True;
    L1.SetBounds(S(16), S(12), W - S(32), S(36));
    L1.Caption := 'Your friend scans this code with their phone camera or in the Meshtastic app ' +
      '(or opens the link). The app adds ' + ChName + ' next to their existing channels.';
    Top := S(52);

    Img := TImage.Create(F);
    Img.Parent := F;
    Img.SetBounds((W - Bmp.Width) div 2, Top, Bmp.Width, Bmp.Height);
    Img.Picture.Assign(Bmp);
    Inc(Top, Bmp.Height + S(8));

    L2 := TLabel.Create(F);
    L2.Parent := F;
    L2.AutoSize := False;
    L2.WordWrap := True;
    L2.Font.Color := RGB(170, 30, 30);
    L2.SetBounds(S(16), Top, W - S(32), S(36));
    L2.Caption := 'Anyone with this code or link can read and send on ' + ChName +
      '. Show it in person or send it privately - not on a public channel.';
    Inc(Top, S(40));

    Ed := TEdit.Create(F);
    Ed.Parent := F;
    Ed.ReadOnly := True;
    Ed.SetBounds(S(16), Top, W - S(32), S(24));
    Ed.Text := Url;
    Inc(Top, S(34));

    BCopy := TButton.Create(F);
    BCopy.Parent := F;
    BCopy.SetBounds(S(16), Top, S(110), S(28));
    BCopy.Caption := 'Copy link';
    BCopy.OnClick := nil;
    BCopy.Tag := 1;

    BCopyImg := TButton.Create(F);
    BCopyImg.Parent := F;
    BCopyImg.SetBounds(S(134), Top, S(130), S(28));
    BCopyImg.Caption := 'Copy QR picture';
    BCopyImg.Tag := 2;

    BClose := TButton.Create(F);
    BClose.Parent := F;
    BClose.SetBounds(W - S(16) - S(90), Top, S(90), S(28));
    BClose.Caption := 'Close';
    BClose.ModalResult := mrOk;
    BClose.Cancel := True;
    BClose.Default := True;
    F.ClientHeight := Top + S(28) + S(14);

    // the copy buttons close the dialog with their own result; loop until Close
    BCopy.ModalResult := 101;
    BCopyImg.ModalResult := 102;
    repeat
      case F.ShowModal of
        101:
          begin
            Clipboard.AsText := Url;
            BCopy.Caption := 'Copied ' + #$2713;
          end;
        102:
          begin
            Clipboard.Assign(Bmp);
            BCopyImg.Caption := 'Copied ' + #$2713;
          end;
      else
        Break;
      end;
    until False;
  finally
    F.Free;
    Bmp.Free;
  end;
end;

procedure TMainForm.JoinChannelClick(Sender: TObject);
var
  Url, Names: string;
  Chans, ToAdd: TArray<TSharedChannel>;
  Ch: TSharedChannel;
  C: TChannelInfo;
  Have: Boolean;
  Slots: TList<Integer>;
  I: Integer;
begin
  Url := '';
  if not InputQuery('Join a channel', 'Paste the channel link (https://meshtastic.org/e/#...):', Url) then
    Exit;
  if not ParseChannelShareUrl(Trim(Url), Chans) then
  begin
    ShowMessage('That does not look like a Meshtastic channel link.');
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
    ShowMessage('Your radio already has the channel(s) in that link.');
    Exit;
  end;

  Slots := TList<Integer>.Create;
  try
    for I := 1 to 7 do
    begin
      Have := False;
      for C in FClient.Channels do
        if C.Index = I then
          Have := True;
      if not Have then
        Slots.Add(I);
    end;
    if Slots.Count < Length(ToAdd) then
    begin
      ShowMessage('Not enough free channel slots. Delete a channel first.');
      Exit;
    end;
    if MessageDlg('Add to your radio:' + sLineBreak + Names + sLineBreak +
      'Your other channels are kept.', mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
      Exit;
    try
      for I := 0 to High(ToAdd) do
        FClient.SetChannel(Slots[I], 2, ChannelSettingsWithMqtt(ToAdd[I].Raw, FClient.InternetMode));
    except
      on E: Exception do
        ShowMessage(E.Message);
    end;
  finally
    Slots.Free;
  end;
end;

procedure TMainForm.DeleteChannelClick(Sender: TObject);
var
  C: TChannelInfo;
begin
  if not SelectedChannel(C) or (C.Role <> 2) then
    Exit;
  if MessageDlg(Format('Delete #%s from your radio?', [FClient.ChannelName(C.Index)]) +
    sLineBreak + sLineBreak + 'The radio forgets its key. To rejoin you need the QR code or ' +
    'link again (from someone who still has the channel).', mtWarning, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  try
    FClient.SetChannel(C.Index, 0, EncodeChannelSettings('', nil, False, False));
  except
    on E: Exception do
      ShowMessage(E.Message);
  end;
end;

{ ---------------------------------------------------------------------------
  Desktop alerts: a tray icon whose balloon becomes a Windows notification
  --------------------------------------------------------------------------- }

procedure TMainForm.BuildAlerts;

  function AddItem(const ACaption: string; Check: Boolean): TMenuItem;
  begin
    Result := TMenuItem.Create(mnuAlerts);
    Result.Caption := ACaption;
    if Check then
    begin
      Result.AutoCheck := True;
      Result.OnClick := AlertOptionClick;
    end;
    mnuAlerts.Items.Add(Result);
  end;

begin
  btnAlerts := TButton.Create(Self);
  btnAlerts.Parent := pnlTop;
  btnAlerts.Align := alRight;
  btnAlerts.Left := S(1000);
  btnAlerts.Width := S(90);
  btnAlerts.AlignWithMargins := True;
  btnAlerts.Margins.SetBounds(0, 0, S(12), 0);
  btnAlerts.Caption := 'Alerts...';
  btnAlerts.Hint := 'Choose which messages pop up a Windows notification';
  btnAlerts.ShowHint := True;
  btnAlerts.OnClick := AlertsBtnClick;

  mnuAlerts := TPopupMenu.Create(Self);
  with AddItem('Pop up a notification for:', False) do
    Enabled := False;
  miAlertDM := AddItem('Direct messages to me', True);
  miAlertFriend := AddItem('Anything from friends', True);
  miAlertPrivate := AddItem('Private channels', True);
  miAlertPublic := AddItem('Public channel (busy)', True);
  AddItem('-', False);
  miAlertAway := AddItem('Only when I''m not looking at MeshTerm', True);
  AddItem('-', False);
  AddItem('Show a test notification', False).OnClick := TestAlertClick;
  LoadAlertSettings;

  Tray := TTrayIcon.Create(Self);
  Tray.Icon.Assign(Application.Icon);
  Tray.Hint := 'MeshTerm';
  Tray.OnBalloonClick := TrayBalloonClick;
  Tray.OnClick := TrayRestore;
  Tray.Visible := True;
end;

procedure TMainForm.LoadAlertSettings;
var
  Ini: TIniFile;
begin
  miAlertDM.Checked := True;
  miAlertFriend.Checked := True;
  miAlertPrivate.Checked := True;
  miAlertPublic.Checked := False;
  miAlertAway.Checked := True;
  try
    Ini := TIniFile.Create(IniPath);
    try
      miAlertDM.Checked := Ini.ReadBool('Alerts', 'Direct', True);
      miAlertFriend.Checked := Ini.ReadBool('Alerts', 'Friends', True);
      miAlertPrivate.Checked := Ini.ReadBool('Alerts', 'Private', True);
      miAlertPublic.Checked := Ini.ReadBool('Alerts', 'Public', False);
      miAlertAway.Checked := Ini.ReadBool('Alerts', 'OnlyWhenAway', True);
    finally
      Ini.Free;
    end;
  except
    // defaults
  end;
end;

procedure TMainForm.AlertOptionClick(Sender: TObject);
var
  Ini: TIniFile;
begin
  try
    Ini := TIniFile.Create(IniPath);
    try
      Ini.WriteBool('Alerts', 'Direct', miAlertDM.Checked);
      Ini.WriteBool('Alerts', 'Friends', miAlertFriend.Checked);
      Ini.WriteBool('Alerts', 'Private', miAlertPrivate.Checked);
      Ini.WriteBool('Alerts', 'Public', miAlertPublic.Checked);
      Ini.WriteBool('Alerts', 'OnlyWhenAway', miAlertAway.Checked);
    finally
      Ini.Free;
    end;
  except
    // settings are optional
  end;
end;

procedure TMainForm.AlertsBtnClick(Sender: TObject);
var
  P: TPoint;
begin
  P := btnAlerts.ClientToScreen(Point(0, btnAlerts.Height));
  mnuAlerts.Popup(P.X, P.Y);
end;

procedure TMainForm.TestAlertClick(Sender: TObject);
begin
  FAlertDest.Dest := BROADCAST_ADDR;
  FAlertDest.Channel := 0;
  FLastAlert := 0;
  ShowAlert('MeshTerm test', 'This is how new messages will pop up. Click it to open MeshTerm.');
end;

procedure TMainForm.MaybeAlert(const Packet: TMeshPacket; const Text: string);
var
  IsDM, IsFriend, IsPrivate, IsPublic: Boolean;
  Title: string;
begin
  if (Tray = nil) or (Packet.From = FClient.MyNodeNum) then
    Exit;
  IsDM := Packet.To_ = FClient.MyNodeNum;
  IsFriend := FFriends.Contains(Packet.From);
  IsPrivate := (Packet.To_ = BROADCAST_ADDR) and (Packet.Channel <> 0);
  IsPublic := (Packet.To_ = BROADCAST_ADDR) and (Packet.Channel = 0);
  if not ((IsDM and miAlertDM.Checked) or (IsFriend and miAlertFriend.Checked) or
    (IsPrivate and miAlertPrivate.Checked) or (IsPublic and miAlertPublic.Checked)) then
    Exit;
  if miAlertAway.Checked and Application.Active and (WindowState <> wsMinimized) then
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

procedure TMainForm.ShowAlert(const Title, Text: string);
begin
  // several messages in a burst: show the first now, sum up the rest shortly
  if (FLastAlert <> 0) and (MilliSecondsBetween(Now, FLastAlert) < 4000) then
  begin
    Inc(FAlertHeld);
    FAlertHeldTitle := Title;
    FAlertHeldText := Text;
    Exit;
  end;
  FLastAlert := Now;
  Tray.BalloonTitle := Copy(Title, 1, 63);
  Tray.BalloonHint := Copy(Text, 1, 250);
  Tray.BalloonFlags := bfInfo;
  Tray.ShowBalloonHint;
end;

procedure TMainForm.RestoreWindow;
begin
  if WindowState = wsMinimized then
    WindowState := wsNormal;
  Application.Restore;
  Show;
  Application.BringToFront;
  SetForegroundWindow(Handle);
end;

procedure TMainForm.TrayRestore(Sender: TObject);
begin
  RestoreWindow;
end;

procedure TMainForm.TrayBalloonClick(Sender: TObject);
begin
  RestoreWindow;
  if not SelectDest(FAlertDest.Dest, FAlertDest.Channel) then
  begin
    Pages.ActivePage := tsChat;
    PageChange(nil);
  end;
end;

{ ---------------- Nodes tab: search, filters, sorting, friends, notes ---------------- }

const
  NC_NAME = 0; NC_SHORT = 1; NC_ID = 2; NC_HW = 3; NC_ROLE = 4; NC_SNR = 5; NC_RSSI = 6;
  NC_HOPS = 7; NC_BATTERY = 8; NC_DIST = 9; NC_HEARD = 10; NC_POS = 11; NC_NOTE = 12;
  NODE_COLS = 13;
  STAR = #$2605;
  DOT = '   '#$00B7'   ';

// CLIENT_MUTE -> "Client mute"
function FriendlyRole(Role: Integer): string;
begin
  Result := LowerCase(RoleName(Role)).Replace('_', ' ');
  if Result = '' then
    Exit;
  Result[1] := UpCase(Result[1]);
  Result := Result.Replace('Tak', 'TAK');
end;

// Windows "measurement system" setting: 1 = US (miles/feet)
function UsesMetric: Boolean;
var
  Buf: array[0..3] of Char;
begin
  Result := True;
  if GetLocaleInfo(LOCALE_USER_DEFAULT, LOCALE_IMEASURE, Buf, Length(Buf)) > 0 then
    Result := Buf[0] <> '1';
end;

function UptimeStr(Secs: Cardinal): string;
begin
  if Secs >= 86400 then
    Result := Format('%dd %dh', [Secs div 86400, (Secs mod 86400) div 3600])
  else if Secs >= 3600 then
    Result := Format('%dh %dm', [Secs div 3600, (Secs mod 3600) div 60])
  else
    Result := Format('%dm', [Secs div 60]);
end;

function TMainForm.DistText(Km: Double): string;
var
  Mi: Double;
begin
  if FMetric then
  begin
    if Km < 1 then
      Result := Format('%d m', [Round(Km * 1000)])
    else if Km < 10 then
      Result := FormatFloat('0.0', Km) + ' km'
    else
      Result := FormatFloat('0', Km) + ' km';
  end
  else
  begin
    Mi := Km * 0.621371;
    if Mi < 0.1 then
      Result := Format('%d ft', [Round(Km * 3280.84)])
    else if Mi < 10 then
      Result := FormatFloat('0.0', Mi) + ' mi'
    else
      Result := FormatFloat('0', Mi) + ' mi';
  end;
end;

function TMainForm.NodeDistance(const N: TNodeInfo; out Km: Double): Boolean;
var
  Me: TNodeInfo;
begin
  Km := 0;
  Result := (N.Num <> FClient.MyNodeNum) and N.Position.Valid and
    FClient.Nodes.TryGetValue(FClient.MyNodeNum, Me) and Me.Position.Valid;
  if Result then
    Km := DistanceKm(Me.Position.Lat, Me.Position.Lon, N.Position.Lat, N.Position.Lon);
end;

function TMainForm.NamesOf(const Nums: TArray<Cardinal>): string;
var
  Num: Cardinal;
  L: TStringList;
begin
  L := TStringList.Create;
  try
    for Num in Nums do
      if FClient.NodeName(Num) = NodeIdStr(Num) then
        L.Add(NodeIdStr(Num))
      else
        L.Add(FClient.NodeName(Num) + ' (' + NodeIdStr(Num) + ')');
    Result := string.Join(', ', L.ToStringArray);
  finally
    L.Free;
  end;
end;

procedure TMainForm.BuildNodesTab;
var
  Bar, Info: TPanel;
  X: Integer;

  procedure Place(C: TControl; W: Integer; Gap: Integer);
  begin
    C.Parent := Bar;
    C.Align := alLeft;
    C.Left := X;
    C.Width := S(W);
    Inc(X, S(W) + S(20));
    C.AlignWithMargins := True;
    C.Margins.SetBounds(S(Gap), S(1), 0, S(1));
  end;

  procedure Col(const ACaption: string; AWidth: Integer; Right: Boolean = False);
  var
    C: TListColumn;
  begin
    C := lvNodes.Columns.Add;
    C.Caption := ACaption;
    C.Width := S(AWidth);
    if Right then
      C.Alignment := taRightJustify;
  end;

  function Item(const ACaption: string; Handler: TNotifyEvent): TMenuItem;
  begin
    Result := TMenuItem.Create(mnuNodes);
    Result.Caption := ACaption;
    Result.OnClick := Handler;
    mnuNodes.Items.Add(Result);
  end;

begin
  Bar := TPanel.Create(Self);
  Bar.Parent := tsNodes;
  Bar.Align := alTop;
  Bar.Height := S(34);
  Bar.BevelOuter := bvNone;
  Bar.Padding.SetBounds(S(2), S(5), S(6), S(5));
  X := 0;

  edNodeFind := TEdit.Create(Self);
  Place(edNodeFind, 210, 0);
  edNodeFind.TextHint := 'Search name, ID, hardware or note';
  edNodeFind.OnChange := NodeFilterChange;

  cbNodeShow := TComboBox.Create(Self);
  Place(cbNodeShow, 185, 8);
  cbNodeShow.Style := csDropDownList;
  cbNodeShow.DropDownCount := 12;
  cbNodeShow.Items.Add('All nodes');
  cbNodeShow.Items.Add('Friends');
  cbNodeShow.Items.Add('Heard over the air (local)');
  cbNodeShow.Items.Add('Heard via the internet');
  cbNodeShow.Items.Add('Direct neighbours (0 hops)');
  cbNodeShow.Items.Add('Has a location');
  cbNodeShow.Items.Add('Has a note');
  cbNodeShow.ItemIndex := 0;
  cbNodeShow.OnChange := NodeFilterChange;

  cbNodeHeard := TComboBox.Create(Self);
  Place(cbNodeHeard, 125, 8);
  cbNodeHeard.Style := csDropDownList;
  cbNodeHeard.Items.Add('Heard any time');
  cbNodeHeard.Items.Add('Last 15 minutes');
  cbNodeHeard.Items.Add('Last hour');
  cbNodeHeard.Items.Add('Last 6 hours');
  cbNodeHeard.Items.Add('Last 24 hours');
  cbNodeHeard.Items.Add('Last 7 days');
  cbNodeHeard.ItemIndex := 0;
  cbNodeHeard.OnChange := NodeFilterChange;

  chkFriendsTop := TCheckBox.Create(Self);
  Place(chkFriendsTop, 105, 12);
  chkFriendsTop.Caption := 'Friends at top';
  chkFriendsTop.Checked := True;
  chkFriendsTop.OnClick := NodeFilterChange;

  btnAddFriend := TButton.Create(Self);
  Place(btnAddFriend, 95, 8);
  btnAddFriend.Caption := 'Add friend...';
  btnAddFriend.Hint := 'Add a friend by node ID (like !1a2b3c4d), even one not heard yet';
  btnAddFriend.ShowHint := True;
  btnAddFriend.OnClick := AddFriendClick;

  lblNodeCount := TLabel.Create(Self);
  lblNodeCount.Parent := Bar;
  lblNodeCount.Align := alClient;
  lblNodeCount.Layout := tlCenter;
  lblNodeCount.AlignWithMargins := True;
  lblNodeCount.Margins.SetBounds(S(14), 0, 0, 0);
  lblNodeCount.ShowAccelChar := False;

  // details of the selected node
  Info := TPanel.Create(Self);
  Info.Parent := tsNodes;
  Info.Align := alBottom;
  Info.Height := S(74);
  Info.BevelOuter := bvNone;
  Info.Padding.SetBounds(S(6), S(4), S(6), S(4));
  lblNodeInfo := TLabel.Create(Self);
  lblNodeInfo.Parent := Info;
  lblNodeInfo.Align := alClient;
  lblNodeInfo.AutoSize := False;
  lblNodeInfo.WordWrap := True;
  lblNodeInfo.ShowAccelChar := False;

  // right-click menu
  mnuNodes := TPopupMenu.Create(Self);
  mnuNodes.OnPopup := NodesMenuPopup;
  miNodeMsg := Item('Send a direct message', NodeMsgClick);
  mnuNodes.Items.Add(NewLine);
  miNodeFriend := Item('Add to friends', NodeFriendClick);
  miNodeNote := Item('Edit note...', NodeNoteClick);
  mnuNodes.Items.Add(NewLine);
  miNodeMap := Item('Show on map', NodeMapClick);
  miNodeCopyId := Item('Copy node ID', NodeCopyIdClick);
  miNodeCopyName := Item('Copy name', NodeCopyNameClick);
  mnuNodes.Items.Add(NewLine);
  miNodeNoBat := Item('This node has no battery (hide its battery reading)', NodeNoBatClick);

  lvNodes := TListView.Create(Self);
  lvNodes.Parent := tsNodes;
  lvNodes.Align := alClient;
  lvNodes.ViewStyle := vsReport;
  lvNodes.ReadOnly := True;
  lvNodes.RowSelect := True;
  lvNodes.HideSelection := False;
  lvNodes.MultiSelect := True;
  lvNodes.DoubleBuffered := True;
  lvNodes.OwnerData := True;          // rows come from FNodeRows (filtered + sorted)
  Col('Name', 190);
  Col('Short', 50);
  Col('ID', 80);
  Col('Hardware', 140);
  Col('Role', 80);
  Col('SNR', 50, True);
  Col('RSSI', 50, True);
  Col('Hops', 60, True);
  Col('Battery', 90);
  Col('Distance', 70, True);
  Col('Last heard', 90);
  Col('Position', 140);
  Col('Note', 200);
  lvNodes.OnData := NodesData;
  lvNodes.OnColumnClick := NodesColumnClick;
  lvNodes.OnCustomDrawItem := NodesCustomDraw;
  lvNodes.OnDblClick := NodesDblClick;
  lvNodes.OnKeyDown := NodesKeyDown;
  lvNodes.OnKeyUp := NodesKeyUp;
  lvNodes.OnClick := NodesClick;
  lvNodes.PopupMenu := mnuNodes;
end;

{ What the filters let through. Num may be a friend the radio has not heard
  yet (no TNodeInfo). }
function TMainForm.NodeVisible(Num: Cardinal; const Words: TArray<string>): Boolean;
var
  N: TNodeInfo;
  Known: Boolean;
  Hay, W, Note: string;
  MaxAge: Int64;
begin
  Known := FClient.Nodes.TryGetValue(Num, N);
  case cbNodeShow.ItemIndex of
    1: Result := FFriends.Contains(Num);
    2: Result := Known and IsLocalNode(N);
    3: Result := Known and N.ViaMqtt;
    4: Result := Known and (Num <> FClient.MyNodeNum) and not N.ViaMqtt and (N.HopsAway = 0);
    5: Result := Known and N.Position.Valid;
    6: Result := FNotes.ContainsKey(Num);
  else
    Result := True;
  end;
  if not Result then
    Exit;

  case cbNodeHeard.ItemIndex of
    1: MaxAge := 15 * 60;
    2: MaxAge := 3600;
    3: MaxAge := 6 * 3600;
    4: MaxAge := 86400;
    5: MaxAge := 7 * 86400;
  else
    MaxAge := 0;
  end;
  if (MaxAge > 0) and (Num <> FClient.MyNodeNum) then
    if not Known or (N.LastHeard = 0) or
      (DateTimeToUnix(Now, False) - Int64(N.LastHeard) > MaxAge) then
      Exit(False);

  if Length(Words) = 0 then
    Exit;
  if not FNotes.TryGetValue(Num, Note) then
    Note := '';
  Hay := FClient.NodeName(Num) + ' ' + NodeIdStr(Num) + ' ' + Note;
  if Known then
  begin
    Hay := Hay + ' ' + N.User.ShortName + ' ' + N.User.LongName;
    if N.HasUser then
      Hay := Hay + ' ' + HwModelName(N.User.HwModel) + ' ' + FriendlyRole(N.User.Role);
  end;
  Hay := LowerCase(Hay);
  for W in Words do
    if Pos(W, Hay) = 0 then
      Exit(False);
end;

{ Row order: this radio, then friends (if "Friends at top"), then the rest by
  the clicked column. Blank values always go last, whichever direction. }
function TMainForm.CompareNodes(A, B: Cardinal): Integer;

  function Rank(Num: Cardinal): Integer;
  begin
    if Num = FClient.MyNodeNum then
      Result := 0
    else if chkFriendsTop.Checked and FFriends.Contains(Num) then
      Result := 1
    else
      Result := 2;
  end;

  function Opt(HasA, HasB: Boolean; R: Integer): Integer;
  begin
    if HasA and HasB then
    begin
      if FNodeSortDesc then
        Result := -R
      else
        Result := R;
    end
    else if HasA then
      Result := -1
    else if HasB then
      Result := 1
    else
      Result := 0;
  end;

  function HopKey(Known: Boolean; const N: TNodeInfo): Integer;
  begin
    if not Known then
      Result := -1
    else if N.ViaMqtt then
      Result := 99
    else
      Result := N.HopsAway;     // -1 = unknown
  end;

  function BatKey(Known: Boolean; const N: TNodeInfo): Integer;
  begin
    if not Known or FNoBattery.Contains(N.Num) or not N.Metrics.Valid or
      (N.Metrics.BatteryLevel <= 0) then
      Result := -1
    else
      Result := Min(N.Metrics.BatteryLevel, 101);
  end;

var
  NA, NB: TNodeInfo;
  KA, KB, HA, HB: Boolean;
  SA, SB: string;
  DA, DB: Double;
begin
  Result := Rank(A) - Rank(B);
  if Result <> 0 then
    Exit;
  KA := FClient.Nodes.TryGetValue(A, NA);
  KB := FClient.Nodes.TryGetValue(B, NB);
  case FNodeSortCol of
    NC_ID:
      Result := Opt(True, True, CompareValue(Int64(A), Int64(B)));
    NC_SNR:
      Result := Opt(KA and (NA.Snr <> 0), KB and (NB.Snr <> 0), CompareValue(NA.Snr, NB.Snr));
    NC_RSSI:
      Result := Opt(KA and (NA.Rssi <> 0), KB and (NB.Rssi <> 0), CompareValue(NA.Rssi, NB.Rssi));
    NC_HOPS:
      Result := Opt(HopKey(KA, NA) >= 0, HopKey(KB, NB) >= 0,
        CompareValue(HopKey(KA, NA), HopKey(KB, NB)));
    NC_BATTERY:
      Result := Opt(BatKey(KA, NA) >= 0, BatKey(KB, NB) >= 0,
        CompareValue(BatKey(KA, NA), BatKey(KB, NB)));
    NC_DIST:
      begin
        HA := KA and NodeDistance(NA, DA);
        HB := KB and NodeDistance(NB, DB);
        Result := Opt(HA, HB, CompareValue(DA, DB));
      end;
    NC_HEARD:      // ascending = most recently heard first
      Result := Opt(KA and (NA.LastHeard <> 0), KB and (NB.LastHeard <> 0),
        CompareValue(Int64(NB.LastHeard), Int64(NA.LastHeard)));
    NC_POS:
      Result := Opt(KA and NA.Position.Valid, KB and NB.Position.Valid,
        CompareValue(NB.Position.Lat, NA.Position.Lat));
    NC_NAME:
      Result := Opt(True, True, CompareText(FClient.NodeName(A), FClient.NodeName(B)));
  else
    begin
      SA := NodeCell(A, FNodeSortCol);
      SB := NodeCell(B, FNodeSortCol);
      Result := Opt(SA <> '', SB <> '', CompareText(SA, SB));
    end;
  end;
  if Result = 0 then
    Result := CompareText(FClient.NodeName(A), FClient.NodeName(B));
  if Result = 0 then
    Result := CompareValue(Int64(A), Int64(B));
end;

function TMainForm.NodeCell(Num: Cardinal; Col: Integer): string;
var
  N: TNodeInfo;
  Known: Boolean;
  Km: Double;
begin
  Result := '';
  Known := FClient.Nodes.TryGetValue(Num, N);
  case Col of
    NC_NAME:
      begin
        Result := FClient.NodeName(Num);
        if Num = FClient.MyNodeNum then
          Result := Result + '  (this radio)';
        if FFriends.Contains(Num) then
          Result := STAR + ' ' + Result;
      end;
    NC_ID:
      Result := NodeIdStr(Num);
    NC_HEARD:
      if Known then
        Result := AgoStr(N.LastHeard)
      else
        Result := 'not heard yet';
    NC_NOTE:
      if not FNotes.TryGetValue(Num, Result) then
        Result := '';
  end;
  if not Known then
    Exit;
  case Col of
    NC_SHORT:
      Result := N.User.ShortName;
    NC_HW:
      if N.HasUser then
        Result := HwModelName(N.User.HwModel);
    NC_ROLE:
      if N.HasUser then
        Result := FriendlyRole(N.User.Role);
    NC_SNR:
      if N.Snr <> 0 then
        Result := FormatFloat('0.0', N.Snr);
    NC_RSSI:
      if N.Rssi <> 0 then
        Result := IntToStr(N.Rssi);
    NC_HOPS:
      if Num = FClient.MyNodeNum then
        Result := '-'
      else if N.ViaMqtt then
        Result := 'internet'
      else if N.HopsAway = 0 then
        Result := 'direct'
      else if N.HopsAway > 0 then
        Result := IntToStr(N.HopsAway);
    NC_BATTERY:
      Result := BatteryText(N, False);
    NC_DIST:
      if NodeDistance(N, Km) then
        Result := DistText(Km);
    NC_POS:
      if N.Position.Valid then
        Result := FormatFloat('0.0000', N.Position.Lat) + ', ' +
          FormatFloat('0.0000', N.Position.Lon);
  end;
end;

function TMainForm.SelectedNodes: TArray<Cardinal>;
var
  I: Integer;
begin
  Result := nil;
  if (lvNodes = nil) or not lvNodes.HandleAllocated then
    Exit;
  I := ListView_GetNextItem(lvNodes.Handle, -1, LVNI_SELECTED);
  while I >= 0 do
  begin
    if I < FNodeRows.Count then
      Result := Result + [FNodeRows[I]];
    I := ListView_GetNextItem(lvNodes.Handle, I, LVNI_SELECTED);
  end;
end;

function TMainForm.FocusedNode: Cardinal;
var
  I: Integer;
begin
  Result := 0;
  if (lvNodes = nil) or not lvNodes.HandleAllocated then
    Exit;
  I := ListView_GetNextItem(lvNodes.Handle, -1, LVNI_FOCUSED);
  if (I >= 0) and (I < FNodeRows.Count) then
    Result := FNodeRows[I];
end;

{ Rebuild the visible rows from the node database + friends, keeping the
  selection on the same nodes. Called on filter/sort changes and, at most once
  a second, after nodes change (FNodesDirty). }
procedure TMainForm.RefreshNodeRows;
var
  Sel: TArray<Cardinal>;
  Foc, Num: Cardinal;
  Words: TArray<string>;
  Idx: Integer;
  H: HWND;
begin
  FNodesDirty := False;
  if lvNodes = nil then
    Exit;
  Sel := SelectedNodes;
  Foc := FocusedNode;
  Words := LowerCase(Trim(edNodeFind.Text)).Split([' '], TStringSplitOptions.ExcludeEmpty);

  FNodeRows.Clear;
  for Num in FClient.Nodes.Keys do
    if NodeVisible(Num, Words) then
      FNodeRows.Add(Num);
  for Num in FFriends do
    if not FClient.Nodes.ContainsKey(Num) and NodeVisible(Num, Words) then
      FNodeRows.Add(Num);
  FNodeRows.Sort(TComparer<Cardinal>.Construct(
    function(const A, B: Cardinal): Integer
    begin
      Result := CompareNodes(A, B);
    end));

  lvNodes.Items.Count := FNodeRows.Count;
  if lvNodes.HandleAllocated then
  begin
    H := lvNodes.Handle;
    ListView_SetItemState(H, -1, 0, LVIS_SELECTED or LVIS_FOCUSED);
    for Num in Sel do
    begin
      Idx := FNodeRows.IndexOf(Num);
      if Idx >= 0 then
        ListView_SetItemState(H, Idx, LVIS_SELECTED, LVIS_SELECTED);
    end;
    if Foc <> 0 then
    begin
      Idx := FNodeRows.IndexOf(Foc);
      if Idx >= 0 then
        ListView_SetItemState(H, Idx, LVIS_FOCUSED, LVIS_FOCUSED);
    end;
  end;
  lvNodes.Invalidate;
  UpdateSortArrows;
  UpdateNodesCaption;
  UpdateNodeInfo;
end;

procedure TMainForm.UpdateNodeRow(const N: TNodeInfo);
begin
  FNodesDirty := True;     // the timer redraws (at most once a second)
end;

procedure TMainForm.UpdateLastHeard;
begin
  if lvNodes = nil then
    Exit;
  lvNodes.Invalidate;      // "5m ago" texts
  if cbNodeHeard.ItemIndex > 0 then
    FNodesDirty := True;   // nodes age out of the "last hour" etc. view
end;

procedure TMainForm.UpdateNodesCaption;
var
  Total: Integer;
  Num: Cardinal;
  Filtered: Boolean;
begin
  if lblNodeCount = nil then
    Exit;
  Total := FClient.Nodes.Count;
  for Num in FFriends do
    if not FClient.Nodes.ContainsKey(Num) then
      Inc(Total);
  Filtered := (cbNodeShow.ItemIndex > 0) or (cbNodeHeard.ItemIndex > 0) or
    (Trim(edNodeFind.Text) <> '');
  if Filtered then
  begin
    tsNodes.Caption := Format('Nodes (%d of %d)', [FNodeRows.Count, Total]);
    lblNodeCount.Caption := Format('Showing %d of %d', [FNodeRows.Count, Total]);
  end
  else
  begin
    tsNodes.Caption := Format('Nodes (%d)', [Total]);
    lblNodeCount.Caption := Format('%d nodes', [Total]);
  end;
  lblNodeCount.Caption := lblNodeCount.Caption + Format(', %d friend(s)', [FFriends.Count]);
end;

procedure TMainForm.UpdateSortArrows;
var
  Hdr: HWND;
  I: Integer;
  It: THDItem;
begin
  if (lvNodes = nil) or not lvNodes.HandleAllocated then
    Exit;
  Hdr := ListView_GetHeader(lvNodes.Handle);
  for I := 0 to lvNodes.Columns.Count - 1 do
  begin
    FillChar(It, SizeOf(It), 0);
    It.Mask := HDI_FORMAT;
    if Header_GetItem(Hdr, I, It) then
    begin
      It.fmt := It.fmt and not (HDF_SORTUP or HDF_SORTDOWN);
      if I = FNodeSortCol then
        if FNodeSortDesc then
          It.fmt := It.fmt or HDF_SORTDOWN
        else
          It.fmt := It.fmt or HDF_SORTUP;
      Header_SetItem(Hdr, I, It);
    end;
  end;
end;

procedure TMainForm.UpdateNodeInfo;
var
  Sel: TArray<Cardinal>;
  Num: Cardinal;
  N: TNodeInfo;
  Known: Boolean;
  L1, L2, L3, T, Note: string;
  Km: Double;

  procedure Add3(const S: string);
  begin
    if S = '' then
      Exit;
    if L3 <> '' then
      L3 := L3 + DOT;
    L3 := L3 + S;
  end;

begin
  if lblNodeInfo = nil then
    Exit;
  Sel := SelectedNodes;
  if Length(Sel) = 0 then
  begin
    lblNodeInfo.Caption := 'Click a node to see its details. Double-click it (or press Enter) to ' +
      'message it. Right-click for friends, notes, map and more. Click a column heading to sort ' +
      '(click again to reverse). Ctrl+click or Shift+click to select several.';
    Exit;
  end;
  if Length(Sel) > 1 then
  begin
    lblNodeInfo.Caption := Format('%d nodes selected. Right-click to add or remove them as ' +
      'friends, or copy their IDs.', [Length(Sel)]);
    Exit;
  end;

  Num := Sel[0];
  Known := FClient.Nodes.TryGetValue(Num, N);
  L1 := FClient.NodeName(Num);
  if Known and (N.User.ShortName <> '') then
    L1 := L1 + ' (' + N.User.ShortName + ')';
  if FClient.NodeName(Num) <> NodeIdStr(Num) then
    L1 := L1 + DOT + NodeIdStr(Num);
  if Known and N.HasUser then
    L1 := L1 + DOT + HwModelName(N.User.HwModel) + ', ' + FriendlyRole(N.User.Role);
  if Num = FClient.MyNodeNum then
    L1 := L1 + DOT + 'this radio'
  else if FFriends.Contains(Num) then
    L1 := L1 + DOT + STAR + ' friend (everything they send on the internet comes in)';

  if not Known then
    L2 := 'Not heard yet. It shows up here as soon as this radio or the internet link hears from it.'
  else
  begin
    if N.LastHeard <> 0 then
      L2 := 'Heard ' + AgoStr(N.LastHeard) + ' (' +
        FormatDateTime('ddd mmm d, t', UnixToDateTime(N.LastHeard, False)) + ')'
    else
      L2 := 'Not heard since MeshTerm connected';
    if Num = FClient.MyNodeNum then
      // nothing about how it was heard
    else if N.ViaMqtt then
      L2 := L2 + ' via the internet'
    else if N.HopsAway = 0 then
      L2 := L2 + ' directly over the air'
    else if N.HopsAway = 1 then
      L2 := L2 + ' over the air, 1 hop away'
    else if N.HopsAway > 1 then
      L2 := L2 + Format(' over the air, %d hops away', [N.HopsAway]);
    if N.Snr <> 0 then
      L2 := L2 + DOT + Format('SNR %.1f dB', [N.Snr]);
    if N.Rssi <> 0 then
      L2 := L2 + DOT + Format('RSSI %d dBm', [N.Rssi]);
  end;

  L3 := '';
  if Known then
  begin
    Add3(BatteryText(N, True));
    if N.Metrics.Valid then
    begin
      if N.Metrics.ChannelUtil > 0 then
        Add3(Format('Channel busy %.1f%%', [N.Metrics.ChannelUtil]));
      if N.Metrics.AirUtilTx > 0 then
        Add3(Format('Own airtime %.1f%%', [N.Metrics.AirUtilTx]));
      if N.Metrics.Uptime > 0 then
        Add3('Up ' + UptimeStr(N.Metrics.Uptime));
    end;
    if N.Position.Valid then
    begin
      T := 'Location ' + FormatFloat('0.00000', N.Position.Lat) + ', ' +
        FormatFloat('0.00000', N.Position.Lon);
      if N.Position.Altitude <> 0 then
        if FMetric then
          T := T + Format(' (%d m high)', [N.Position.Altitude])
        else
          T := T + Format(' (%d ft high)', [Round(N.Position.Altitude * 3.28084)]);
      Add3(T);
      if NodeDistance(N, Km) then
        Add3(DistText(Km) + ' from this radio');
    end;
  end;
  if FNotes.TryGetValue(Num, Note) then
    Add3('Note: ' + Note);
  lblNodeInfo.Caption := L1 + sLineBreak + L2 + sLineBreak + L3;
end;

procedure TMainForm.NodesData(Sender: TObject; Item: TListItem);
var
  Num: Cardinal;
  C: Integer;
begin
  if (Item.Index < 0) or (Item.Index >= FNodeRows.Count) then
    Exit;
  Num := FNodeRows[Item.Index];
  Item.Caption := NodeCell(Num, NC_NAME);
  Item.SubItems.Clear;
  for C := 1 to NODE_COLS - 1 do
    Item.SubItems.Add(NodeCell(Num, C));
end;

// Colours match the map: red = this radio, orange = friend, grey = internet;
// light grey = not heard for a day (or never)
procedure TMainForm.NodesCustomDraw(Sender: TCustomListView; Item: TListItem;
  State: TCustomDrawState; var DefaultDraw: Boolean);
var
  Num: Cardinal;
  N: TNodeInfo;
  Known, Stale: Boolean;
begin
  DefaultDraw := True;
  Sender.Canvas.Font.Style := [];
  Sender.Canvas.Font.Color := clWindowText;
  if (Item = nil) or (Item.Index < 0) or (Item.Index >= FNodeRows.Count) then
    Exit;
  Num := FNodeRows[Item.Index];
  Known := FClient.Nodes.TryGetValue(Num, N);
  Stale := not Known or (N.LastHeard = 0) or
    (DateTimeToUnix(Now, False) - Int64(N.LastHeard) > 86400);
  if Num = FClient.MyNodeNum then
  begin
    Sender.Canvas.Font.Style := [fsBold];
    Sender.Canvas.Font.Color := RGB(190, 30, 30);
  end
  else if FFriends.Contains(Num) then
  begin
    Sender.Canvas.Font.Style := [fsBold];
    if Stale then
      Sender.Canvas.Font.Color := RGB(205, 150, 90)
    else
      Sender.Canvas.Font.Color := RGB(205, 105, 0);
  end
  else if Stale then
    Sender.Canvas.Font.Color := RGB(160, 160, 160)
  else if N.ViaMqtt then
    Sender.Canvas.Font.Color := RGB(105, 105, 105);
end;

procedure TMainForm.NodesColumnClick(Sender: TObject; Column: TListColumn);
begin
  if Column.Index = FNodeSortCol then
    FNodeSortDesc := not FNodeSortDesc
  else
  begin
    FNodeSortCol := Column.Index;
    // bigger-is-better columns start with the biggest
    FNodeSortDesc := Column.Index in [NC_SNR, NC_RSSI, NC_BATTERY];
  end;
  RefreshNodeRows;
  SaveNodeSettings;
end;

procedure TMainForm.NodeFilterChange(Sender: TObject);
begin
  if FNodeLoading then
    Exit;
  RefreshNodeRows;
  if Sender <> edNodeFind then
    SaveNodeSettings;
end;

procedure TMainForm.NodesClick(Sender: TObject);
begin
  UpdateNodeInfo;
end;

procedure TMainForm.NodesKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  UpdateNodeInfo;
end;

procedure TMainForm.NodesKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  case Key of
    VK_RETURN:
      begin
        Key := 0;
        NodesDblClick(Sender);
      end;
    VK_DELETE:
      begin
        Key := 0;
        RemoveSelectedFriends;
      end;
    Ord('C'):
      if ssCtrl in Shift then
      begin
        Key := 0;
        NodeCopyIdClick(Sender);
      end;
    Ord('A'):
      if ssCtrl in Shift then
      begin
        Key := 0;
        ListView_SetItemState(lvNodes.Handle, -1, LVIS_SELECTED, LVIS_SELECTED);
        UpdateNodeInfo;
      end;
  end;
end;

procedure TMainForm.NodesDblClick(Sender: TObject);
var
  Num: Cardinal;
begin
  Num := FocusedNode;
  if (Num = 0) and (Length(SelectedNodes) > 0) then
    Num := SelectedNodes[0];
  if (Num <> 0) and (Num <> FClient.MyNodeNum) then
    SelectDest(Num, 0);
end;

procedure TMainForm.NodesMenuPopup(Sender: TObject);
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
    if not FFriends.Contains(Num) then
      AllFriends := False;
  miNodeMsg.Enabled := One and (Sel[0] <> FClient.MyNodeNum);
  if AllFriends then
    miNodeFriend.Caption := 'Remove from friends'
  else
    miNodeFriend.Caption := 'Add to friends';
  if Length(Sel) > 1 then
    miNodeFriend.Caption := miNodeFriend.Caption + Format(' (%d nodes)', [Length(Sel)]);
  miNodeFriend.Enabled := (Length(Sel) > 0) and not (One and (Sel[0] = FClient.MyNodeNum));
  miNodeNote.Enabled := One;
  miNodeMap.Enabled := One and FClient.Nodes.TryGetValue(Sel[0], N) and N.Position.Valid;
  miNodeCopyId.Enabled := Length(Sel) > 0;
  miNodeCopyName.Enabled := Length(Sel) > 0;
  miNodeNoBat.Enabled := One and FClient.Nodes.ContainsKey(Sel[0]);
  miNodeNoBat.Checked := One and FNoBattery.Contains(Sel[0]);
end;

procedure TMainForm.NodeMsgClick(Sender: TObject);
begin
  NodesDblClick(Sender);
end;

procedure TMainForm.NodeFriendClick(Sender: TObject);
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
    if not FFriends.Contains(Num) then
      AllFriends := False;
  if AllFriends then
  begin
    RemoveSelectedFriends;
    Exit;
  end;
  Changed := nil;
  for Num in Sel do
    if (Num <> FClient.MyNodeNum) and not FFriends.Contains(Num) then
    begin
      FFriends.Add(Num);
      Changed := Changed + [Num];
    end;
  if Length(Changed) > 0 then
    FriendsChanged('Added to friends: ' + NamesOf(Changed));
end;

procedure TMainForm.RemoveSelectedFriends;
var
  Gone: TArray<Cardinal>;
  Num: Cardinal;
begin
  Gone := nil;
  for Num in SelectedNodes do
    if FFriends.Contains(Num) then
      Gone := Gone + [Num];
  if Length(Gone) = 0 then
    Exit;
  if MessageDlg('Remove from your friends?' + sLineBreak + sLineBreak + NamesOf(Gone),
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  for Num in Gone do
    FFriends.Remove(Num);
  FriendsChanged('Removed from friends: ' + NamesOf(Gone));
end;

{ After any change to the friends list: save it, and update everything that
  shows friends (Internet tab box, To: list, node list, map colours). }
procedure TMainForm.FriendsChanged(const Msg: string);
begin
  try
    SaveExtraTopics;
  except
    on E: Exception do
      AddLog('Could not save settings: ' + E.Message);
  end;
  if edFriends <> nil then
    edFriends.Text := FriendsText;
  RefreshDestinations;
  RefreshNodeRows;
  RebuildMap;
  if Msg <> '' then
    AddLog(Msg);
end;

procedure TMainForm.AddFriendClick(Sender: TObject);
var
  S, T: string;
  Num, Found: Cardinal;
  Matches: Integer;
  N: TNodeInfo;
  Added: TArray<Cardinal>;
begin
  S := '';
  if not InputQuery('Add friend', 'Node ID (like !1a2b3c4d) or exact name; commas between several:', S) then
    Exit;
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
          ShowMessage(Format('"%s" is not a node ID (! and 8 letters/digits, like !1a2b3c4d) ' +
            'or the name of a node in the list.', [T.Trim]))
        else
          ShowMessage(Format('More than one node is called "%s". Use its ID instead.', [T.Trim]));
        Exit;
      end;
    end;
    if (Num <> FClient.MyNodeNum) and not FFriends.Contains(Num) then
    begin
      FFriends.Add(Num);
      Added := Added + [Num];
    end;
  end;
  if Length(Added) = 0 then
    ShowMessage('Nothing new to add: already a friend (or this radio).')
  else
    FriendsChanged('Added to friends: ' + NamesOf(Added));
end;

procedure TMainForm.NodeNoteClick(Sender: TObject);
var
  Sel: TArray<Cardinal>;
  Note: string;
begin
  Sel := SelectedNodes;
  if Length(Sel) <> 1 then
    Exit;
  if not FNotes.TryGetValue(Sel[0], Note) then
    Note := '';
  if not InputQuery('Note (kept on this PC only)', 'Note for ' + FClient.NodeName(Sel[0]) +
    ' (empty = remove):', Note) then
    Exit;
  Note := Trim(Note.Replace(#13, ' ').Replace(#10, ' '));
  if Note = '' then
    FNotes.Remove(Sel[0])
  else
    FNotes.AddOrSetValue(Sel[0], Note);
  SaveNote(Sel[0]);
  RefreshNodeRows;
end;

procedure TMainForm.NodeMapClick(Sender: TObject);
var
  Sel: TArray<Cardinal>;
  N: TNodeInfo;
begin
  Sel := SelectedNodes;
  if (Length(Sel) <> 1) or not FClient.Nodes.TryGetValue(Sel[0], N) or not N.Position.Valid then
    Exit;
  FMapFitted := True;
  Pages.ActivePage := tsMap;
  PageChange(nil);
  Map.SetView(N.Position.Lat, N.Position.Lon, Max(Map.Zoom, 12));
  MapMarkerClick(Map, N.Num);
end;

procedure TMainForm.NodeCopyIdClick(Sender: TObject);
var
  L: TStringList;
  Num: Cardinal;
begin
  L := TStringList.Create;
  try
    for Num in SelectedNodes do
      L.Add(NodeIdStr(Num));
    if L.Count > 0 then
      Clipboard.AsText := string.Join(', ', L.ToStringArray);
  finally
    L.Free;
  end;
end;

procedure TMainForm.NodeCopyNameClick(Sender: TObject);
var
  L: TStringList;
  Num: Cardinal;
begin
  L := TStringList.Create;
  try
    for Num in SelectedNodes do
      L.Add(FClient.NodeName(Num));
    if L.Count > 0 then
      Clipboard.AsText := string.Join(sLineBreak, L.ToStringArray);
  finally
    L.Free;
  end;
end;

procedure TMainForm.NodeNoBatClick(Sender: TObject);
var
  Sel: TArray<Cardinal>;
begin
  Sel := SelectedNodes;
  if Length(Sel) <> 1 then
    Exit;
  FBatteryNode := Sel[0];
  NoBatteryClick(Sender);
end;

// [Nodes] filter/sort/column widths and [Notes] <node hex>=text in MeshTerm.ini
procedure TMainForm.LoadNodeSettings;
var
  Ini: TIniFile;
  Keys: TStringList;
  K, V: string;
  W: TArray<string>;
  I, Px: Integer;
  N: Int64;
begin
  FMetric := UsesMetric;
  FNotes.Clear;
  FNodeLoading := True;
  try
    try
      Ini := TIniFile.Create(IniPath);
      Keys := TStringList.Create;
      try
        cbNodeShow.ItemIndex := EnsureRange(Ini.ReadInteger('Nodes', 'Show', 0), 0,
          cbNodeShow.Items.Count - 1);
        cbNodeHeard.ItemIndex := EnsureRange(Ini.ReadInteger('Nodes', 'Heard', 0), 0,
          cbNodeHeard.Items.Count - 1);
        chkFriendsTop.Checked := Ini.ReadBool('Nodes', 'FriendsTop', True);
        FNodeSortCol := EnsureRange(Ini.ReadInteger('Nodes', 'SortCol', NC_HEARD), 0, NODE_COLS - 1);
        FNodeSortDesc := Ini.ReadBool('Nodes', 'SortDesc', False);
        W := Ini.ReadString('Nodes', 'Widths', '').Split([',']);
        for I := 0 to Min(Length(W), lvNodes.Columns.Count) - 1 do
        begin
          Px := StrToIntDef(Trim(W[I]), 0);
          if Px >= 20 then
            lvNodes.Columns[I].Width := S(Px);
        end;
        Ini.ReadSection('Notes', Keys);
        for K in Keys do
        begin
          N := StrToInt64Def('$' + K, 0);
          V := Trim(Ini.ReadString('Notes', K, ''));
          if (N > 0) and (N <= $FFFFFFFF) and (V <> '') then
            FNotes.AddOrSetValue(Cardinal(N), V);
        end;
      finally
        Keys.Free;
        Ini.Free;
      end;
    except
      // no settings yet
    end;
  finally
    FNodeLoading := False;
  end;
end;

procedure TMainForm.SaveNodeSettings;
var
  Ini: TIniFile;
  L: TStringList;
  I: Integer;
begin
  if (lvNodes = nil) or FNodeLoading then
    Exit;
  try
    Ini := TIniFile.Create(IniPath);
    L := TStringList.Create;
    try
      Ini.WriteInteger('Nodes', 'Show', cbNodeShow.ItemIndex);
      Ini.WriteInteger('Nodes', 'Heard', cbNodeHeard.ItemIndex);
      Ini.WriteBool('Nodes', 'FriendsTop', chkFriendsTop.Checked);
      Ini.WriteInteger('Nodes', 'SortCol', FNodeSortCol);
      Ini.WriteBool('Nodes', 'SortDesc', FNodeSortDesc);
      for I := 0 to lvNodes.Columns.Count - 1 do       // stored at 96 dpi
        L.Add(IntToStr(MulDiv(lvNodes.Columns[I].Width, 96, Screen.PixelsPerInch)));
      Ini.WriteString('Nodes', 'Widths', L.CommaText);
    finally
      L.Free;
      Ini.Free;
    end;
  except
    // settings are optional
  end;
end;

procedure TMainForm.SaveNote(Num: Cardinal);
var
  Ini: TIniFile;
  Note: string;
begin
  try
    Ini := TIniFile.Create(IniPath);
    try
      if FNotes.TryGetValue(Num, Note) then
        Ini.WriteString('Notes', LowerCase(IntToHex(Num, 8)), Note)
      else
        Ini.DeleteKey('Notes', LowerCase(IntToHex(Num, 8)));
    finally
      Ini.Free;
    end;
  except
    on E: Exception do
      AddLog('Could not save the note: ' + E.Message);
  end;
end;

end.
