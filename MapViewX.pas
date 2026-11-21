unit MapViewX;

{ A small slippy map for FireMonkey (Windows and Android): OpenStreetMap
  tiles loaded by background threads and cached on disk, drag to pan,
  pinch / wheel / +- buttons to zoom, node markers, a search pin and a
  "tap to place" mode. }

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, System.Math, System.SyncObjs,
  System.Generics.Collections, System.Generics.Defaults,
  FMX.Types, FMX.Controls, FMX.Graphics;

type
  TMapMarker = record
    Id: Cardinal;
    Lat, Lon: Double;
    Caption: string;
    Color: TAlphaColor;
    IsMe: Boolean;
  end;

  TMapMarkerEvent = procedure(Sender: TObject; Id: Cardinal) of object;
  TMapPointEvent = procedure(Sender: TObject; X, Y: Single; Lat, Lon: Double) of object;

  { Work list shared by the map and its loader threads. Reference counted, so
    threads still downloading when the map closes finish and clean up. }
  TTileLoader = class(TInterfacedObject)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FQueue: TList<string>;   // waiting; highest priority last
    FBusy: TList<string>;    // being loaded, or delivered but not yet handed over
    FStop: Boolean;
  public
    Alive: Boolean;          // main thread only: False once the map is gone
    CacheDir: string;
    constructor Create(const ACacheDir: string);
    destructor Destroy; override;
    procedure SetWanted(const Keys: TArray<string>);
    function Take(out Key: string): Boolean;
    procedure Done(const Key: string);
    procedure Stop;
  end;

  TMapViewX = class(TControl)
  private
    FZoom: Double;                       // current (fractional while animating / pinching)
    FCX, FCY: Double;                    // view centre, normalised world coords 0..1
    FTileSize: Single;                   // on-screen size of one tile at an integer zoom
    FTiles: TObjectDictionary<string, TBitmap>;
    FTileOrder: TList<string>;           // oldest first, for trimming the memory cache
    FFailed: TDictionary<string, Cardinal>;
    FLoader: TTileLoader;
    FLoaderRef: IInterface;
    FMarkers: TList<TMapMarker>;
    FDragging, FDragMoved, FIgnoreUp: Boolean;
    FDragStart: TPointF;
    FDragCX, FDragCY: Double;
    FHover: Integer;                     // marker index under the mouse, -1 none
    FHoverBtn: Integer;                  // 1 = zoom in, 2 = zoom out
    FMouse: TPointF;
    FMouseIn: Boolean;
    FSelected: Cardinal;
    // zoom animation
    FAnim: TTimer;
    FAnimFrom, FAnimTo: Double;
    FAnimStart: Cardinal;
    FAnchor: TPointF;
    FAnchorNX, FAnchorNY: Double;
    FWheelAcc: Integer;
    // pinch
    FPinching: Boolean;
    FPinchDist0, FPinchZoom0: Double;
    FFitPending: Boolean;                // FitMarkers asked for before the map had a size
    // extras
    FPlaceMode: Boolean;
    FHasPin: Boolean;
    FPinLat, FPinLon: Double;
    FPinCaption: string;
    FOnMarkerClick, FOnMarkerDblClick: TMapMarkerEvent;
    FOnPlace, FOnContext: TMapPointEvent;
    FOnPlaceModeChange: TNotifyEvent;
    procedure UpdateTileSize;
    function TileLevel: Integer;
    function WorldPx: Double;
    function ViewLeft: Double;
    function ViewTop: Double;
    procedure StartLoaders;
    procedure TileLoaded(const Key: string; const Data: TBytes);
    procedure DrawTile(Z, X, Y: Integer; const R: TRectF; Smooth: Boolean);
    procedure RequestVisibleTiles;
    function MarkerPos(const M: TMapMarker): TPointF;
    function MarkerAt(X, Y: Single): Integer;
    function ButtonRect(Index: Integer): TRectF;
    function ButtonAt(X, Y: Single): Integer;
    procedure ClampCenter;
    procedure ZoomAround(NewZoom: Double; const P: TPointF);
    procedure AnimTick(Sender: TObject);
    procedure SetPlaceMode(Value: Boolean);
    procedure SetSelected(Value: Cardinal);
    procedure UpdateCursor;
    procedure DoubleTap(X, Y: Single);
    procedure Context(X, Y: Single);
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Single); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean); override;
    procedure KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState); override;
    procedure DoMouseLeave; override;
    procedure CMGesture(var EventInfo: TGestureEventInfo); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetView(Lat, Lon: Double; AZoom: Integer);
    procedure ZoomBy(Delta: Integer; AroundX, AroundY: Single);
    procedure ZoomByCenter(Delta: Integer);
    procedure FitMarkers;
    procedure FitBounds(South, North, West, East: Double; MaxZoom: Integer = 16);
    procedure SetMarker(const M: TMapMarker);
    procedure RemoveMarker(Id: Cardinal);
    procedure ClearMarkers;
    function MarkerCount: Integer;
    function HasMarker(Id: Cardinal): Boolean;
    procedure SetPin(Lat, Lon: Double; const Caption: string);
    procedure ClearPin;
    function ScreenToLatLon(X, Y: Single; out Lat, Lon: Double): Boolean;
    function CenterLat: Double;
    function CenterLon: Double;
    function Zoom: Integer;
    property PlaceMode: Boolean read FPlaceMode write SetPlaceMode;
    property Selected: Cardinal read FSelected write SetSelected;
    property OnMarkerClick: TMapMarkerEvent read FOnMarkerClick write FOnMarkerClick;
    property OnMarkerDblClick: TMapMarkerEvent read FOnMarkerDblClick write FOnMarkerDblClick;
    property OnPlace: TMapPointEvent read FOnPlace write FOnPlace;
    { right-click (Windows) or long press (Android) }
    property OnContext: TMapPointEvent read FOnContext write FOnContext;
    property OnPlaceModeChange: TNotifyEvent read FOnPlaceModeChange write FOnPlaceModeChange;
  end;

implementation

uses
  System.IOUtils, System.Net.HttpClient, System.Net.URLClient;

const
  TILE = 256;                // pixels in a tile image
  MIN_ZOOM = 2;
  MAX_ZOOM = 18;
  LOADER_THREADS = 4;
  MAX_MEM_TILES = 250;
  CACHE_DAYS = 30;
  ANIM_MS = 220;
  // OpenStreetMap's tile policy asks for an identifying User-Agent
  USER_AGENT = 'MeshTerm/1.0 (Meshtastic client)';
  {$IFDEF ANDROID}
  IS_TOUCH = True;
  {$ELSE}
  IS_TOUCH = False;
  {$ENDIF}

function Ticks: Cardinal; inline;
begin
  Result := TThread.GetTickCount;
end;

// normalised Web Mercator: 0..1 across the world
function LonToNX(Lon: Double): Double;
begin
  Result := (Lon + 180) / 360;
end;

function LatToNY(Lat: Double): Double;
var
  S: Double;
begin
  Lat := EnsureRange(Lat, -85.05, 85.05);
  S := Sin(DegToRad(Lat));
  Result := 0.5 - Ln((1 + S) / (1 - S)) / (4 * Pi);
end;

function NXToLon(X: Double): Double;
begin
  Result := X * 360 - 180;
end;

function NYToLat(Y: Double): Double;
var
  N: Double;
begin
  N := Pi - 2 * Pi * Y;
  Result := RadToDeg(ArcTan(0.5 * (Exp(N) - Exp(-N))));
end;

function TileKey(Z, X, Y: Integer): string;
begin
  Result := Format('%d/%d/%d', [Z, X, Y]);
end;

{ TTileLoader }

constructor TTileLoader.Create(const ACacheDir: string);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, True, False, '');
  FQueue := TList<string>.Create;
  FBusy := TList<string>.Create;
  CacheDir := ACacheDir;
  Alive := True;
end;

destructor TTileLoader.Destroy;
begin
  FBusy.Free;
  FQueue.Free;
  FWake.Free;
  FLock.Free;
  inherited;
end;

procedure TTileLoader.SetWanted(const Keys: TArray<string>);
var
  I: Integer;
begin
  FLock.Enter;
  try
    FQueue.Clear;
    for I := High(Keys) downto 0 do
      if not FBusy.Contains(Keys[I]) then
        FQueue.Add(Keys[I]);
    if FQueue.Count > 0 then
      FWake.SetEvent;
  finally
    FLock.Leave;
  end;
end;

function TTileLoader.Take(out Key: string): Boolean;
begin
  while True do
  begin
    FLock.Enter;
    try
      if FStop then
        Exit(False);
      if FQueue.Count > 0 then
      begin
        Key := FQueue[FQueue.Count - 1];
        FQueue.Delete(FQueue.Count - 1);
        FBusy.Add(Key);
        Exit(True);
      end;
      FWake.ResetEvent;
    finally
      FLock.Leave;
    end;
    FWake.WaitFor(1000);
  end;
end;

procedure TTileLoader.Done(const Key: string);
begin
  FLock.Enter;
  try
    FBusy.Remove(Key);
  finally
    FLock.Leave;
  end;
end;

procedure TTileLoader.Stop;
begin
  FLock.Enter;
  try
    FStop := True;
    FQueue.Clear;
    FWake.SetEvent;
  finally
    FLock.Leave;
  end;
end;

// Worker side: disk cache, else download (and cache). Runs on a loader thread.
function FetchTile(Http: THTTPClient; const CacheDir, Key: string): TBytes;
var
  Path: string;
  Fresh: Boolean;
  MS: TBytesStream;
  Resp: IHTTPResponse;
begin
  Result := nil;
  Path := TPath.Combine(CacheDir, Key.Replace('/', PathDelim) + '.png');
  Fresh := False;
  try
    if TFile.Exists(Path) then
    begin
      Result := TFile.ReadAllBytes(Path);
      Fresh := Now - TFile.GetLastWriteTime(Path) < CACHE_DAYS;
    end;
  except
    Result := nil;
  end;
  if Fresh and (Length(Result) > 0) then
    Exit;
  MS := TBytesStream.Create;
  try
    try
      Resp := Http.Get('https://tile.openstreetmap.org/' + Key + '.png', MS);
      if (Resp.StatusCode = 200) and (MS.Size > 0) then
      begin
        Result := Copy(MS.Bytes, 0, MS.Size);
        try
          ForceDirectories(TPath.GetDirectoryName(Path));
          TFile.WriteAllBytes(Path, Result);
        except
          // the cache is optional
        end;
      end;
    except
      // offline: fall back to a stale cached copy if there is one
    end;
  finally
    MS.Free;
  end;
end;

{ Hand a loaded tile to the map on the main thread (decoding happens there:
  FMX bitmaps belong to the main thread). A separate routine so the queued
  call gets its own copy of Key and Data. }
procedure DeliverTile(const Hold: IInterface; L: TTileLoader; Map: TMapViewX;
  const Key: string; const Data: TBytes);
var
  Ref: IInterface;
begin
  Ref := Hold;
  TThread.Queue(nil,
    procedure
    begin
      L.Done(Key);
      if L.Alive then
        Map.TileLoaded(Key, Data);
      Ref := nil;
    end);
end;

{ TMapViewX }

constructor TMapViewX.Create(AOwner: TComponent);
begin
  inherited;
  HitTest := True;
  CanFocus := True;
  AutoCapture := True;
  Touch.InteractiveGestures := [TInteractiveGesture.Zoom, TInteractiveGesture.LongTap];
  FTiles := TObjectDictionary<string, TBitmap>.Create([doOwnsValues]);
  FTileOrder := TList<string>.Create;
  FFailed := TDictionary<string, Cardinal>.Create;
  FMarkers := TList<TMapMarker>.Create;
  FHover := -1;
  FTileSize := TILE;
  FAnim := TTimer.Create(Self);
  FAnim.Enabled := False;
  FAnim.Interval := 15;
  FAnim.OnTimer := AnimTick;
  FZoom := 4;
  FCX := LonToNX(-95);
  FCY := LatToNY(39);
  FLoader := TTileLoader.Create(TPath.Combine(TPath.Combine(TPath.GetCachePath, 'MeshTerm'), 'tiles'));
  FLoaderRef := FLoader;
  StartLoaders;
end;

destructor TMapViewX.Destroy;
begin
  FLoader.Alive := False;
  FLoader.Stop;
  FLoaderRef := nil;
  FMarkers.Free;
  FFailed.Free;
  FTileOrder.Free;
  FTiles.Free;
  inherited;
end;

procedure TMapViewX.StartLoaders;
var
  I: Integer;
  Ref: IInterface;
  L: TTileLoader;
  Map: TMapViewX;
begin
  Ref := FLoaderRef;
  L := FLoader;
  Map := Self;
  for I := 1 to LOADER_THREADS do
    TThread.CreateAnonymousThread(
      procedure
      var
        Http: THTTPClient;
        Key: string;
        Hold: IInterface;
      begin
        Hold := Ref;
        Http := THTTPClient.Create;
        try
          Http.UserAgent := USER_AGENT;
          Http.ConnectionTimeout := 8000;
          Http.ResponseTimeout := 15000;
          while L.Take(Key) do
            DeliverTile(Hold, L, Map, Key, FetchTile(Http, L.CacheDir, Key));
        finally
          Http.Free;
        end;
      end).Start;
end;

procedure TMapViewX.TileLoaded(const Key: string; const Data: TBytes);
var
  MS: TBytesStream;
  Bmp: TBitmap;
begin
  Bmp := nil;
  if Length(Data) > 0 then
  begin
    MS := TBytesStream.Create(Data);
    try
      Bmp := TBitmap.Create;
      try
        Bmp.LoadFromStream(MS);
      except
        FreeAndNil(Bmp);
      end;
    finally
      MS.Free;
    end;
  end;
  if Bmp = nil then
  begin
    FFailed.AddOrSetValue(Key, Ticks);
    Exit;
  end;
  FTiles.AddOrSetValue(Key, Bmp);
  FTileOrder.Remove(Key);
  FTileOrder.Add(Key);
  while FTileOrder.Count > MAX_MEM_TILES do
  begin
    FTiles.Remove(FTileOrder[0]);
    FTileOrder.Delete(0);
  end;
  Repaint;
end;

{ Tiles are drawn at up to 2 device pixels per tile pixel: on a phone (scale
  3 or more) full 256-dp tiles would be blurry, and 1:1 would make the map
  text too small to read. }
procedure TMapViewX.UpdateTileSize;
var
  S: Single;
begin
  S := 1;
  if Scene <> nil then
    S := Scene.GetSceneScale;
  if S < 1 then
    S := 1;
  FTileSize := TILE * Min(S, 2) / S;
end;

function TMapViewX.TileLevel: Integer;
begin
  Result := EnsureRange(Round(FZoom), MIN_ZOOM, MAX_ZOOM);
end;

function TMapViewX.WorldPx: Double;
begin
  Result := FTileSize * Power(2, FZoom);
end;

function TMapViewX.ViewLeft: Double;
begin
  Result := FCX * WorldPx - Width / 2;
end;

function TMapViewX.ViewTop: Double;
begin
  Result := FCY * WorldPx - Height / 2;
end;

function TMapViewX.Zoom: Integer;
begin
  if FAnim.Enabled then
    Result := Round(FAnimTo)
  else
    Result := Round(FZoom);
end;

{ Draw tile Z/X/Y into R. Missing? Use a scaled-up piece of a lower zoom tile,
  then any higher zoom tiles (the four children) on top, so nothing goes
  blank while the new tiles load. }
procedure TMapViewX.DrawTile(Z, X, Y: Integer; const R: TRectF; Smooth: Boolean);
var
  Bmp: TBitmap;
  D, PZ, PX, PY, CX, CY: Integer;
  Part, SX, SY, MX, MY: Single;

  procedure Blit(B: TBitmap; const Dst: TRectF; SrcX, SrcY, SrcW, SrcH: Single);
  begin
    Canvas.DrawBitmap(B, RectF(SrcX, SrcY, SrcX + SrcW, SrcY + SrcH), Dst, 1, not Smooth);
  end;

begin
  if FTiles.TryGetValue(TileKey(Z, X, Y), Bmp) then
  begin
    Blit(Bmp, R, 0, 0, Bmp.Width, Bmp.Height);
    Exit;
  end;
  for D := 1 to 6 do
  begin
    PZ := Z - D;
    if PZ < 0 then
      Break;
    PX := X shr D;
    PY := Y shr D;
    if FTiles.TryGetValue(TileKey(PZ, PX, PY), Bmp) then
    begin
      Part := Bmp.Width / (1 shl D);
      SX := (X - (PX shl D)) * Part;
      SY := (Y - (PY shl D)) * Part;
      Blit(Bmp, R, SX, SY, Part, Part);
      Break;
    end;
  end;
  if Z < MAX_ZOOM then
  begin
    MX := (R.Left + R.Right) / 2;
    MY := (R.Top + R.Bottom) / 2;
    for CY := 0 to 1 do
      for CX := 0 to 1 do
        if FTiles.TryGetValue(TileKey(Z + 1, X * 2 + CX, Y * 2 + CY), Bmp) then
          Blit(Bmp, RectF(IfThen(CX = 0, R.Left, MX), IfThen(CY = 0, R.Top, MY),
            IfThen(CX = 0, MX, R.Right), IfThen(CY = 0, MY, R.Bottom)), 0, 0, Bmp.Width, Bmp.Height);
  end;
end;

procedure TMapViewX.RequestVisibleTiles;
type
  TWant = record
    Key: string;
    Dist: Double;
  end;
var
  Wants: TList<TWant>;
  Keys: TArray<string>;
  Z, N, TX, TY, WX, I, Lvl: Integer;
  TS, L, T: Double;
  W: TWant;
  Tick, FailT: Cardinal;
begin
  Wants := TList<TWant>.Create;
  try
    Tick := Ticks;
    for Lvl := 0 to 1 do
    begin
      Z := TileLevel - Lvl;
      if Z < MIN_ZOOM then
        Break;
      N := 1 shl Z;
      TS := WorldPx / N;
      L := ViewLeft;
      T := ViewTop;
      for TY := Max(0, Floor(T / TS)) to Min(N - 1, Floor((T + Height) / TS)) do
        for TX := Floor(L / TS) to Floor((L + Width) / TS) do
        begin
          WX := ((TX mod N) + N) mod N;
          W.Key := TileKey(Z, WX, TY);
          if FTiles.ContainsKey(W.Key) then
            Continue;
          if FFailed.TryGetValue(W.Key, FailT) and (Tick - FailT < 30000) then
            Continue;
          W.Dist := Sqr((TX + 0.5) * TS - L - Width / 2) +
            Sqr((TY + 0.5) * TS - T - Height / 2) + Lvl * 1E12;
          Wants.Add(W);
        end;
    end;
    Wants.Sort(TComparer<TWant>.Construct(
      function(const A, B: TWant): Integer
      begin
        Result := CompareValue(A.Dist, B.Dist);
      end));
    SetLength(Keys, Wants.Count);
    for I := 0 to Wants.Count - 1 do
      Keys[I] := Wants[I].Key;
  finally
    Wants.Free;
  end;
  FLoader.SetWanted(Keys);
end;

function TMapViewX.ButtonRect(Index: Integer): TRectF;
var
  Sz, Y: Single;
begin
  if IS_TOUCH then Sz := 40 else Sz := 30;
  Y := 10 + (Index - 1) * (Sz + 6);
  Result := RectF(10, Y, 10 + Sz, Y + Sz);
end;

function TMapViewX.ButtonAt(X, Y: Single): Integer;
var
  I: Integer;
begin
  for I := 1 to 2 do
    if ButtonRect(I).Contains(PointF(X, Y)) then
      Exit(I);
  Result := 0;
end;

function TMapViewX.MarkerPos(const M: TMapMarker): TPointF;
var
  WP: Double;
begin
  WP := WorldPx;
  Result.X := LonToNX(M.Lon) * WP - ViewLeft;
  Result.Y := LatToNY(M.Lat) * WP - ViewTop;
  // the world repeats sideways: the copy nearest the view
  while Result.X < -WP / 2 do Result.X := Result.X + WP;
  while Result.X > Width + WP / 2 do Result.X := Result.X - WP;
end;

procedure TMapViewX.Paint;
var
  State: TCanvasSaveState;
  N, Z, TX, TY, WX, I, R: Integer;
  TS, L, T, WP: Double;
  M: TMapMarker;
  S: string;
  P: TPointF;
  TW, TH, Rad: Single;
  Smooth: Boolean;
  BR: TRectF;

  procedure Banner(const Text: string; Y: Single);
  var
    W, H, BX: Single;
  begin
    Canvas.Font.Size := 12;
    Canvas.Font.Style := [TFontStyle.fsBold];
    W := Min(Canvas.TextWidth(Text), Width - 40);
    H := Canvas.TextHeight(Text);
    if Canvas.TextWidth(Text) > W then
      H := H * 2.2;
    BX := (Width - W) / 2;
    Canvas.Fill.Color := $FFFFFACD;
    Canvas.FillRect(RectF(BX - 10, Y, BX + W + 10, Y + H + 10), 6, 6, AllCorners, 0.95);
    Canvas.Stroke.Color := $FFB4A03C;
    Canvas.Stroke.Thickness := 1;
    Canvas.DrawRect(RectF(BX - 10, Y, BX + W + 10, Y + H + 10), 6, 6, AllCorners, 1);
    Canvas.Fill.Color := $FF3C3200;
    Canvas.FillText(RectF(BX, Y + 5, BX + W, Y + 5 + H), Text, True, 1, [], TTextAlign.Center, TTextAlign.Center);
    Canvas.Font.Style := [];
  end;

begin
  UpdateTileSize;
  State := Canvas.SaveState;
  try
    Canvas.IntersectClipRect(LocalRect);
    Canvas.Fill.Kind := TBrushKind.Solid;
    Canvas.Stroke.Kind := TBrushKind.Solid;
    Canvas.Fill.Color := $FFE2E2DE;
    Canvas.FillRect(LocalRect, 0, 0, [], 1);

    Z := TileLevel;
    N := 1 shl Z;
    WP := WorldPx;
    TS := WP / N;
    L := ViewLeft;
    T := ViewTop;
    Smooth := not FAnim.Enabled and not FPinching and not FDragMoved;
    for TY := Max(0, Floor(T / TS)) to Min(N - 1, Floor((T + Height) / TS)) do
      for TX := Floor(L / TS) to Floor((L + Width) / TS) do
      begin
        WX := ((TX mod N) + N) mod N;
        // a hair of overlap hides seams between tiles
        DrawTile(Z, WX, TY, RectF(TX * TS - L, TY * TS - T, (TX + 1) * TS - L + 0.6,
          (TY + 1) * TS - T + 0.6), Smooth);
      end;
    if not FAnim.Enabled and not FPinching then
      RequestVisibleTiles;

    Canvas.Font.Size := 11;
    Canvas.Font.Style := [];

    // search result pin
    if FHasPin then
    begin
      P.X := LonToNX(FPinLon) * WP - L;
      P.Y := LatToNY(FPinLat) * WP - T;
      Canvas.Stroke.Color := $FF5A0078;
      Canvas.Stroke.Thickness := 3;
      Canvas.DrawEllipse(RectF(P.X - 11, P.Y - 11, P.X + 11, P.Y + 11), 1);
      Canvas.DrawLine(PointF(P.X - 17, P.Y), PointF(P.X - 6, P.Y), 1);
      Canvas.DrawLine(PointF(P.X + 6, P.Y), PointF(P.X + 17, P.Y), 1);
      Canvas.DrawLine(PointF(P.X, P.Y - 17), PointF(P.X, P.Y - 6), 1);
      Canvas.DrawLine(PointF(P.X, P.Y + 6), PointF(P.X, P.Y + 17), 1);
      if FPinCaption <> '' then
      begin
        TW := Canvas.TextWidth(FPinCaption);
        TH := Canvas.TextHeight(FPinCaption);
        Canvas.Fill.Color := $FFF5EBFF;
        Canvas.FillRect(RectF(P.X + 14, P.Y + 8, P.X + 22 + TW, P.Y + 12 + TH), 0, 0, [], 1);
        Canvas.Stroke.Thickness := 1;
        Canvas.DrawRect(RectF(P.X + 14, P.Y + 8, P.X + 22 + TW, P.Y + 12 + TH), 0, 0, [], 1);
        Canvas.Fill.Color := $FF3C005A;
        Canvas.FillText(RectF(P.X + 18, P.Y + 10, P.X + 20 + TW, P.Y + 10 + TH), FPinCaption,
          False, 1, [], TTextAlign.Leading, TTextAlign.Center);
      end;
    end;

    // markers: others first, then this radio, then the selected one on top
    for R := 0 to 2 do
      for I := 0 to FMarkers.Count - 1 do
      begin
        M := FMarkers[I];
        if (R = 2) <> ((FSelected <> 0) and (M.Id = FSelected)) then
          Continue;
        if (R < 2) and (M.IsMe <> (R = 1)) then
          Continue;
        P := MarkerPos(M);
        if (P.X < -50) or (P.Y < -50) or (P.X > Width + 250) or (P.Y > Height + 50) then
          Continue;
        if (I = FHover) or (M.Id = FSelected) then
          Rad := 10
        else
          Rad := 7.5;
        if M.Id = FSelected then
        begin
          Canvas.Fill.Color := $55000000 or (M.Color and $00FFFFFF);
          Canvas.FillEllipse(RectF(P.X - 17, P.Y - 17, P.X + 17, P.Y + 17), 1);
        end;
        Canvas.Fill.Color := M.Color;
        Canvas.FillEllipse(RectF(P.X - Rad, P.Y - Rad, P.X + Rad, P.Y + Rad), 1);
        Canvas.Stroke.Color := TAlphaColors.White;
        Canvas.Stroke.Thickness := 2;
        Canvas.DrawEllipse(RectF(P.X - Rad, P.Y - Rad, P.X + Rad, P.Y + Rad), 1);
        S := M.Caption;
        if M.IsMe or (I = FHover) or (M.Id = FSelected) then
          Canvas.Font.Style := [TFontStyle.fsBold]
        else
          Canvas.Font.Style := [];
        TW := Canvas.TextWidth(S);
        TH := Canvas.TextHeight(S);
        Canvas.Fill.Color := $F0FFFFF0;
        Canvas.FillRect(RectF(P.X + 12, P.Y - TH / 2 - 2, P.X + 19 + TW, P.Y + TH / 2 + 2), 2, 2, AllCorners, 1);
        Canvas.Stroke.Color := $FF969696;
        Canvas.Stroke.Thickness := 1;
        Canvas.DrawRect(RectF(P.X + 12, P.Y - TH / 2 - 2, P.X + 19 + TW, P.Y + TH / 2 + 2), 2, 2, AllCorners, 1);
        Canvas.Fill.Color := TAlphaColors.Black;
        Canvas.FillText(RectF(P.X + 15, P.Y - TH / 2, P.X + 17 + TW, P.Y + TH / 2), S, False, 1, [],
          TTextAlign.Leading, TTextAlign.Center);
      end;
    Canvas.Font.Style := [];

    // where the radio would go, following the mouse (desktop)
    if FPlaceMode and FMouseIn and not IS_TOUCH and not FDragMoved and (ButtonAt(FMouse.X, FMouse.Y) = 0) then
    begin
      Canvas.Stroke.Color := $FFD72828;
      Canvas.Stroke.Thickness := 2;
      Canvas.DrawEllipse(RectF(FMouse.X - 9, FMouse.Y - 9, FMouse.X + 9, FMouse.Y + 9), 1);
    end;

    // zoom buttons
    Canvas.Font.Size := 18;
    Canvas.Font.Style := [TFontStyle.fsBold];
    for I := 1 to 2 do
    begin
      BR := ButtonRect(I);
      if FHoverBtn = I then
        Canvas.Fill.Color := $FFEBF2FF
      else
        Canvas.Fill.Color := TAlphaColors.White;
      Canvas.FillRect(BR, 6, 6, AllCorners, 0.95);
      Canvas.Stroke.Color := $FF969696;
      Canvas.Stroke.Thickness := 1;
      Canvas.DrawRect(BR, 6, 6, AllCorners, 1);
      if I = 1 then S := '+' else S := #$2212;
      Canvas.Fill.Color := $FF323232;
      Canvas.FillText(BR, S, False, 1, [], TTextAlign.Center, TTextAlign.Center);
    end;
    Canvas.Font.Style := [];

    if FPlaceMode then
    begin
      if IS_TOUCH then
        Banner('Tap the map where your radio is. Drag to move, pinch to zoom.', 10)
      else
        Banner('Click the map where your radio is.  Drag to move, scroll to zoom, Esc to cancel.', 10);
      if Zoom < 14 then
        Banner('Tip: zoom in closer first so the spot is accurate.', 64);
    end;

    // attribution (required by the OpenStreetMap licence)
    Canvas.Font.Size := 10;
    S := #$00A9' OpenStreetMap contributors';
    TW := Canvas.TextWidth(S);
    TH := Canvas.TextHeight(S);
    Canvas.Fill.Color := $D0FFFFFF;
    Canvas.FillRect(RectF(Width - TW - 10, Height - TH - 4, Width, Height), 0, 0, [], 1);
    Canvas.Fill.Color := $FF3C3C3C;
    Canvas.FillText(RectF(Width - TW - 6, Height - TH - 2, Width - 2, Height), S, False, 1, [],
      TTextAlign.Leading, TTextAlign.Leading);
  finally
    Canvas.RestoreState(State);
  end;
end;

procedure TMapViewX.Resize;
begin
  inherited;
  if FFitPending and (Width > 50) and (Height > 50) then
    FitMarkers;
  Repaint;
end;

procedure TMapViewX.ClampCenter;
begin
  FCY := EnsureRange(FCY, 0, 1);
  FCX := FCX - Floor(FCX);
end;

procedure TMapViewX.SetView(Lat, Lon: Double; AZoom: Integer);
begin
  FFitPending := False;
  FAnim.Enabled := False;
  FZoom := EnsureRange(AZoom, MIN_ZOOM, MAX_ZOOM);
  FCX := LonToNX(Lon);
  FCY := LatToNY(Lat);
  ClampCenter;
  Repaint;
end;

function TMapViewX.CenterLat: Double;
begin
  Result := NYToLat(FCY);
end;

function TMapViewX.CenterLon: Double;
begin
  Result := NXToLon(FCX);
end;

// zoom to NewZoom keeping the world point under P where it is
procedure TMapViewX.ZoomAround(NewZoom: Double; const P: TPointF);
var
  NX, NY, WP: Double;
begin
  NX := (ViewLeft + P.X) / WorldPx;
  NY := (ViewTop + P.Y) / WorldPx;
  FZoom := EnsureRange(NewZoom, MIN_ZOOM, MAX_ZOOM);
  WP := WorldPx;
  FCX := NX - (P.X - Width / 2) / WP;
  FCY := NY - (P.Y - Height / 2) / WP;
  ClampCenter;
  Repaint;
end;

procedure TMapViewX.ZoomBy(Delta: Integer; AroundX, AroundY: Single);
var
  Target: Double;
begin
  if FAnim.Enabled then
    Target := FAnimTo + Delta
  else
    Target := Round(FZoom) + Delta;
  Target := EnsureRange(Target, MIN_ZOOM, MAX_ZOOM);
  if Abs(Target - FZoom) < 0.001 then
    Exit;
  FAnchor := PointF(AroundX, AroundY);
  FAnchorNX := (ViewLeft + AroundX) / WorldPx;
  FAnchorNY := (ViewTop + AroundY) / WorldPx;
  FAnimFrom := FZoom;
  FAnimTo := Target;
  FAnimStart := Ticks;
  FAnim.Enabled := True;
  AnimTick(nil);
end;

procedure TMapViewX.ZoomByCenter(Delta: Integer);
begin
  ZoomBy(Delta, Width / 2, Height / 2);
end;

procedure TMapViewX.AnimTick(Sender: TObject);
var
  P, E, WP: Double;
begin
  P := Min(1, (Ticks - FAnimStart) / ANIM_MS);
  E := 1 - Power(1 - P, 3);
  FZoom := FAnimFrom + (FAnimTo - FAnimFrom) * E;
  if P >= 1 then
  begin
    FZoom := FAnimTo;
    FAnim.Enabled := False;
  end;
  WP := WorldPx;
  FCX := FAnchorNX - (FAnchor.X - Width / 2) / WP;
  FCY := FAnchorNY - (FAnchor.Y - Height / 2) / WP;
  ClampCenter;
  Repaint;
end;

procedure TMapViewX.FitBounds(South, North, West, East: Double; MaxZoom: Integer);
var
  Z: Integer;
  W, H: Double;
begin
  FAnim.Enabled := False;
  UpdateTileSize;
  Z := EnsureRange(MaxZoom, MIN_ZOOM, MAX_ZOOM);
  while Z > MIN_ZOOM do
  begin
    W := (LonToNX(East) - LonToNX(West)) * FTileSize * Power(2, Z);
    H := (LatToNY(South) - LatToNY(North)) * FTileSize * Power(2, Z);
    if (W < Width - 120) and (H < Height - 60) then
      Break;
    Dec(Z);
  end;
  FZoom := Z;
  FCX := (LonToNX(West) + LonToNX(East)) / 2;
  FCY := (LatToNY(South) + LatToNY(North)) / 2;
  ClampCenter;
  Repaint;
end;

procedure TMapViewX.FitMarkers;
var
  M: TMapMarker;
  MinLat, MaxLat, MinLon, MaxLon: Double;
begin
  if FMarkers.Count = 0 then
    Exit;
  // not laid out yet (a hidden tab): fit once it has its real size
  FFitPending := (Width <= 50) or (Height <= 50);
  if FFitPending then
    Exit;
  MinLat := 90; MaxLat := -90; MinLon := 180; MaxLon := -180;
  for M in FMarkers do
  begin
    MinLat := Min(MinLat, M.Lat); MaxLat := Max(MaxLat, M.Lat);
    MinLon := Min(MinLon, M.Lon); MaxLon := Max(MaxLon, M.Lon);
  end;
  FitBounds(MinLat, MaxLat, MinLon, MaxLon, 13);
end;

procedure TMapViewX.SetMarker(const M: TMapMarker);
var
  I: Integer;
begin
  for I := 0 to FMarkers.Count - 1 do
    if FMarkers[I].Id = M.Id then
    begin
      FMarkers[I] := M;
      Repaint;
      Exit;
    end;
  FMarkers.Add(M);
  Repaint;
end;

procedure TMapViewX.RemoveMarker(Id: Cardinal);
var
  I: Integer;
begin
  for I := FMarkers.Count - 1 downto 0 do
    if FMarkers[I].Id = Id then
    begin
      FMarkers.Delete(I);
      FHover := -1;
      Repaint;
    end;
end;

procedure TMapViewX.ClearMarkers;
begin
  FMarkers.Clear;
  FHover := -1;
  Repaint;
end;

function TMapViewX.MarkerCount: Integer;
begin
  Result := FMarkers.Count;
end;

function TMapViewX.HasMarker(Id: Cardinal): Boolean;
var
  M: TMapMarker;
begin
  for M in FMarkers do
    if M.Id = Id then
      Exit(True);
  Result := False;
end;

procedure TMapViewX.SetPin(Lat, Lon: Double; const Caption: string);
begin
  FHasPin := True;
  FPinLat := Lat;
  FPinLon := Lon;
  FPinCaption := Caption;
  Repaint;
end;

procedure TMapViewX.ClearPin;
begin
  FHasPin := False;
  Repaint;
end;

procedure TMapViewX.SetSelected(Value: Cardinal);
begin
  if FSelected <> Value then
  begin
    FSelected := Value;
    Repaint;
  end;
end;

function TMapViewX.ScreenToLatLon(X, Y: Single; out Lat, Lon: Double): Boolean;
var
  NX, NY: Double;
begin
  NX := (ViewLeft + X) / WorldPx;
  NY := (ViewTop + Y) / WorldPx;
  Result := (NY >= 0) and (NY <= 1);
  Lat := NYToLat(EnsureRange(NY, 0, 1));
  Lon := NXToLon(NX - Floor(NX));
end;

function TMapViewX.MarkerAt(X, Y: Single): Integer;
var
  I: Integer;
  P: TPointF;
  R2: Single;
begin
  if IS_TOUCH then R2 := 22 * 22 else R2 := 11 * 11;   // fingers are wider than mice
  Result := -1;
  for I := FMarkers.Count - 1 downto 0 do
  begin
    P := MarkerPos(FMarkers[I]);
    if Sqr(P.X - X) + Sqr(P.Y - Y) <= R2 then
    begin
      // prefer the nearest when several are close
      if (Result < 0) then
        Result := I;
      if FMarkers[I].Id = FSelected then
        Exit(I);
    end;
  end;
end;

procedure TMapViewX.SetPlaceMode(Value: Boolean);
begin
  if FPlaceMode = Value then
    Exit;
  FPlaceMode := Value;
  UpdateCursor;
  Repaint;
  if Value and CanFocus then
    SetFocus;
  if Assigned(FOnPlaceModeChange) then
    FOnPlaceModeChange(Self);
end;

procedure TMapViewX.UpdateCursor;
begin
  if FDragMoved and FDragging then
    Cursor := crSizeAll
  else if (FHoverBtn > 0) or ((FHover >= 0) and not FPlaceMode) then
    Cursor := crHandPoint
  else if FPlaceMode then
    Cursor := crCross
  else
    Cursor := crDefault;
end;

procedure TMapViewX.DoMouseLeave;
begin
  inherited;
  FMouseIn := False;
  FHoverBtn := 0;
  FHover := -1;
  Repaint;
end;

procedure TMapViewX.DoubleTap(X, Y: Single);
var
  I: Integer;
begin
  if FPlaceMode or (ButtonAt(X, Y) > 0) then
    Exit;
  I := MarkerAt(X, Y);
  if I >= 0 then
  begin
    if Assigned(FOnMarkerDblClick) then
      FOnMarkerDblClick(Self, FMarkers[I].Id);
  end
  else
    ZoomBy(1, X, Y);
end;

procedure TMapViewX.Context(X, Y: Single);
var
  Lat, Lon: Double;
begin
  FDragging := False;
  FDragMoved := False;
  if Assigned(FOnContext) and ScreenToLatLon(X, Y, Lat, Lon) then
    FOnContext(Self, X, Y, Lat, Lon);
end;

procedure TMapViewX.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
var
  B: Integer;
begin
  inherited;
  FIgnoreUp := False;
  if Button = TMouseButton.mbRight then
  begin
    Context(X, Y);
    Exit;
  end;
  if Button <> TMouseButton.mbLeft then
    Exit;
  B := ButtonAt(X, Y);
  if B > 0 then
  begin
    if B = 1 then ZoomByCenter(1) else ZoomByCenter(-1);
    FIgnoreUp := True;
    Exit;
  end;
  if ssDouble in Shift then
  begin
    DoubleTap(X, Y);
    FIgnoreUp := True;
    Exit;
  end;
  FDragging := True;
  FDragMoved := False;
  FDragStart := PointF(X, Y);
  FDragCX := FCX;
  FDragCY := FCY;
end;

procedure TMapViewX.MouseMove(Shift: TShiftState; X, Y: Single);
var
  H, B: Integer;
  WP, Slop: Double;
begin
  inherited;
  FMouse := PointF(X, Y);
  FMouseIn := True;
  if FPinching then
    Exit;
  if FDragging then
  begin
    if IS_TOUCH then Slop := 8 else Slop := 3;
    if not FDragMoved and ((Abs(X - FDragStart.X) > Slop) or (Abs(Y - FDragStart.Y) > Slop)) then
    begin
      FDragMoved := True;
      FAnim.Enabled := False;
      FDragStart := PointF(X, Y);
      FDragCX := FCX;
      FDragCY := FCY;
      UpdateCursor;
    end;
    if FDragMoved then
    begin
      WP := WorldPx;
      FCX := FDragCX - (X - FDragStart.X) / WP;
      FCY := FDragCY - (Y - FDragStart.Y) / WP;
      ClampCenter;
      Repaint;
    end;
    Exit;
  end;
  if IS_TOUCH then
    Exit;
  B := ButtonAt(X, Y);
  if B > 0 then
    H := -1
  else
    H := MarkerAt(X, Y);
  if (H <> FHover) or (B <> FHoverBtn) then
  begin
    FHover := H;
    FHoverBtn := B;
    UpdateCursor;
    Repaint;
  end
  else if FPlaceMode then
    Repaint;
end;

procedure TMapViewX.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
var
  I: Integer;
  Lat, Lon: Double;
  WasDrag: Boolean;
begin
  inherited;
  if Button <> TMouseButton.mbLeft then
    Exit;
  WasDrag := FDragMoved or FPinching or FIgnoreUp or not FDragging;
  FDragging := False;
  FDragMoved := False;
  FIgnoreUp := False;
  UpdateCursor;
  if WasDrag then
  begin
    Repaint;               // redraw smooth now that movement stopped
    Exit;
  end;
  if FPlaceMode then
  begin
    if ScreenToLatLon(X, Y, Lat, Lon) and Assigned(FOnPlace) then
      FOnPlace(Self, X, Y, Lat, Lon);
    Exit;
  end;
  I := MarkerAt(X, Y);
  if I >= 0 then
  begin
    Selected := FMarkers[I].Id;
    if Assigned(FOnMarkerClick) then
      FOnMarkerClick(Self, FMarkers[I].Id);
  end;
end;

procedure TMapViewX.MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean);
var
  P: TPointF;
begin
  inherited;
  Handled := True;
  if FMouseIn then
    P := FMouse
  else
    P := PointF(Width / 2, Height / 2);
  // touchpads send many small steps: one zoom level per notch's worth
  if Sign(WheelDelta) <> Sign(FWheelAcc) then
    FWheelAcc := 0;
  Inc(FWheelAcc, WheelDelta);
  while Abs(FWheelAcc) >= 120 do
  begin
    ZoomBy(Sign(FWheelAcc), P.X, P.Y);
    Dec(FWheelAcc, Sign(FWheelAcc) * 120);
  end;
end;

procedure TMapViewX.KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
const
  STEP = 120;
var
  WP: Double;
begin
  inherited;
  WP := WorldPx;
  case Key of
    vkEscape: PlaceMode := False;
    vkLeft: FCX := FCX - STEP / WP;
    vkRight: FCX := FCX + STEP / WP;
    vkUp: FCY := FCY - STEP / WP;
    vkDown: FCY := FCY + STEP / WP;
    vkAdd: ZoomByCenter(1);
    vkSubtract: ZoomByCenter(-1);
  else
    case KeyChar of
      '+', '=': ZoomByCenter(1);
      '-': ZoomByCenter(-1);
    else
      Exit;
    end;
  end;
  ClampCenter;
  Repaint;
  Key := 0;
  KeyChar := #0;
end;

procedure TMapViewX.CMGesture(var EventInfo: TGestureEventInfo);
var
  P: TPointF;
begin
  if EventInfo.GestureID = igiZoom then
  begin
    P := AbsoluteToLocal(EventInfo.Location);
    if (TInteractiveGestureFlag.gfBegin in EventInfo.Flags) or not FPinching then
    begin
      FPinching := True;
      FDragging := False;
      FDragMoved := False;
      FAnim.Enabled := False;
      FPinchDist0 := Max(1, EventInfo.Distance);
      FPinchZoom0 := FZoom;
    end
    else if EventInfo.Distance > 0 then
      ZoomAround(FPinchZoom0 + Log2(EventInfo.Distance / FPinchDist0), P);
    if TInteractiveGestureFlag.gfEnd in EventInfo.Flags then
    begin
      FPinching := False;
      FIgnoreUp := True;
      Repaint;
    end;
  end
  else if EventInfo.GestureID = igiLongTap then
  begin
    P := AbsoluteToLocal(EventInfo.Location);
    FIgnoreUp := True;
    Context(P.X, P.Y);
  end
  else
    inherited;
end;

end.
