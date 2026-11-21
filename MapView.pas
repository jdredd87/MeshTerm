unit MapView;

{ A small slippy map: OpenStreetMap tiles (loaded by background threads and
  cached on disk), drag to pan, smooth animated wheel zoom, +/- buttons,
  node markers, a search pin, and a "click to place" mode. }

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Math,
  System.Types, System.SyncObjs, System.Generics.Collections, System.Generics.Defaults, Vcl.Graphics,
  Vcl.Controls, Vcl.ExtCtrls, Vcl.Imaging.pngimage;

type
  TMapMarker = record
    Id: Cardinal;
    Lat, Lon: Double;
    Caption: string;
    Color: TColor;
    IsMe: Boolean;
  end;

  TMapMarkerEvent = procedure(Sender: TObject; Id: Cardinal) of object;
  TMapPlaceEvent = procedure(Sender: TObject; Lat, Lon: Double) of object;

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

  TMapView = class(TCustomControl)
  private
    FZoom: Double;                       // current (fractional while animating)
    FCX, FCY: Double;                    // view centre, normalised world coords 0..1
    FTiles: TObjectDictionary<string, TBitmap>;
    FTileOrder: TList<string>;           // oldest first, for trimming the memory cache
    FFailed: TDictionary<string, Cardinal>; // key -> tick of failure, retry later
    FLoader: TTileLoader;
    FLoaderRef: IInterface;
    FMarkers: TList<TMapMarker>;
    FDragging, FDragMoved: Boolean;
    FDragStart: TPoint;
    FDragCX, FDragCY: Double;
    FHover: Integer;                     // marker index under the mouse, -1 none
    FHoverBtn: Integer;                  // 1 = zoom in, 2 = zoom out, 0 none
    FMouse: TPoint;
    FMouseIn: Boolean;
    // zoom animation
    FAnim: TTimer;
    FAnimFrom, FAnimTo: Double;
    FAnimStart: Cardinal;
    FAnchorX, FAnchorY: Integer;         // screen point that stays put
    FAnchorNX, FAnchorNY: Double;        // world point under it
    FWheelAcc: Integer;
    // extras
    FPlaceMode: Boolean;
    FHasPin: Boolean;
    FPinLat, FPinLon: Double;
    FPinCaption: string;
    FOnMarkerClick, FOnMarkerDblClick: TMapMarkerEvent;
    FOnPlace: TMapPlaceEvent;
    FOnPlaceModeChange: TNotifyEvent;
    function TileLevel: Integer;
    function WorldPx: Double;
    function ViewLeft: Double;
    function ViewTop: Double;
    procedure StartLoaders;
    procedure TileLoaded(const Key: string; Png: TPngImage);
    procedure AddTileBitmap(const Key: string; Bmp: TBitmap);
    procedure DrawTile(Z, X, Y: Integer; const R: TRect; Smooth: Boolean);
    procedure RequestVisibleTiles;
    function MarkerAt(X, Y: Integer): Integer;
    function ButtonAt(X, Y: Integer): Integer;
    function ButtonRect(Index: Integer): TRect;
    procedure ClampCenter;
    procedure AnimTick(Sender: TObject);
    procedure SetPlaceMode(Value: Boolean);
    procedure UpdateCursor;
    procedure WMEraseBkgnd(var Message: TWMEraseBkgnd); message WM_ERASEBKGND;
    procedure WMGetDlgCode(var Message: TWMGetDlgCode); message WM_GETDLGCODE;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure DblClick; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetView(Lat, Lon: Double; Zoom: Integer);
    procedure ZoomBy(Delta: Integer; AroundX, AroundY: Integer);
    procedure FitMarkers;
    procedure FitBounds(South, North, West, East: Double; MaxZoom: Integer = 16);
    procedure SetMarker(const M: TMapMarker);
    procedure RemoveMarker(Id: Cardinal);
    procedure ClearMarkers;
    function MarkerCount: Integer;
    function HasMarker(Id: Cardinal): Boolean;
    procedure SetPin(Lat, Lon: Double; const Caption: string);
    procedure ClearPin;
    function ScreenToLatLon(X, Y: Integer; out Lat, Lon: Double): Boolean;
    function CenterLat: Double;
    function CenterLon: Double;
    function Zoom: Integer;
    property PlaceMode: Boolean read FPlaceMode write SetPlaceMode;
    property OnMarkerClick: TMapMarkerEvent read FOnMarkerClick write FOnMarkerClick;
    property OnMarkerDblClick: TMapMarkerEvent read FOnMarkerDblClick write FOnMarkerDblClick;
    property OnPlace: TMapPlaceEvent read FOnPlace write FOnPlace;
    property OnPlaceModeChange: TNotifyEvent read FOnPlaceModeChange write FOnPlaceModeChange;
    property PopupMenu;
    property Align;
  end;

implementation

uses
  System.IOUtils, System.Net.HttpClient, System.Net.URLClient;

const
  TILE = 256;
  MIN_ZOOM = 2;
  MAX_ZOOM = 18;
  LOADER_THREADS = 4;
  MAX_MEM_TILES = 300;
  CACHE_DAYS = 30;
  ANIM_MS = 220;
  // OpenStreetMap's tile policy asks for an identifying User-Agent
  USER_AGENT = 'MeshTerm/1.0 (Meshtastic desktop client)';

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

// Keys in priority order, most wanted first. Replaces whatever was waiting.
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
  Path := TPath.Combine(CacheDir, Key.Replace('/', '\') + '.png');
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

function DecodePng(const Data: TBytes): TPngImage;
var
  MS: TBytesStream;
begin
  Result := nil;
  if Length(Data) = 0 then
    Exit;
  MS := TBytesStream.Create(Data);
  try
    Result := TPngImage.Create;
    try
      Result.LoadFromStream(MS);
    except
      FreeAndNil(Result);
    end;
  finally
    MS.Free;
  end;
end;

{ TMapView }

constructor TMapView.Create(AOwner: TComponent);
begin
  inherited;
  ControlStyle := ControlStyle + [csOpaque];
  DoubleBuffered := True;
  TabStop := True;
  FTiles := TObjectDictionary<string, TBitmap>.Create([doOwnsValues]);
  FTileOrder := TList<string>.Create;
  FFailed := TDictionary<string, Cardinal>.Create;
  FMarkers := TList<TMapMarker>.Create;
  FHover := -1;
  FAnim := TTimer.Create(Self);
  FAnim.Enabled := False;
  FAnim.Interval := 15;
  FAnim.OnTimer := AnimTick;
  FZoom := 4;
  FCX := LonToNX(-95);
  FCY := LatToNY(39);
  FLoader := TTileLoader.Create(TPath.Combine(TPath.Combine(
    GetEnvironmentVariable('LOCALAPPDATA'), 'MeshTerm'), 'tiles'));
  FLoaderRef := FLoader;
  StartLoaders;
end;

destructor TMapView.Destroy;
begin
  FLoader.Alive := False;         // results still on their way are dropped
  FLoader.Stop;
  FLoaderRef := nil;              // the threads keep it alive until they finish
  FMarkers.Free;
  FFailed.Free;
  FTileOrder.Free;
  FTiles.Free;
  inherited;
end;

{ Hand a loaded tile to the map on the main thread. A separate routine so the
  queued call gets its own copy of Key and Png (closures capture variables). }
procedure DeliverTile(const Hold: IInterface; L: TTileLoader; Map: TMapView;
  const Key: string; Png: TPngImage);
var
  Ref: IInterface;
begin
  Ref := Hold;                    // keeps L valid even if its threads have ended
  TThread.Queue(nil,
    procedure
    begin
      L.Done(Key);
      if L.Alive then
        Map.TileLoaded(Key, Png)
      else
        Png.Free;
      Ref := nil;
    end);
end;

procedure TMapView.StartLoaders;
var
  I: Integer;
  Ref: IInterface;
  L: TTileLoader;
  Map: TMapView;
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
        Hold := Ref;              // keep the loader alive while this thread runs
        Http := THTTPClient.Create;   // one per thread: keeps its connection open
        try
          Http.UserAgent := USER_AGENT;
          Http.ConnectionTimeout := 8000;
          Http.ResponseTimeout := 15000;
          while L.Take(Key) do
            DeliverTile(Hold, L, Map, Key, DecodePng(FetchTile(Http, L.CacheDir, Key)));
        finally
          Http.Free;
        end;
      end).Start;
end;

procedure TMapView.TileLoaded(const Key: string; Png: TPngImage);
var
  Bmp: TBitmap;
begin
  if Png = nil then
  begin
    FFailed.AddOrSetValue(Key, GetTickCount);
    Exit;
  end;
  try
    Bmp := TBitmap.Create;
    try
      Bmp.PixelFormat := pf24bit;
      Bmp.SetSize(Png.Width, Png.Height);
      Bmp.Canvas.Draw(0, 0, Png);
    except
      Bmp.Free;
      raise;
    end;
  finally
    Png.Free;
  end;
  AddTileBitmap(Key, Bmp);
  Invalidate;
end;

procedure TMapView.AddTileBitmap(const Key: string; Bmp: TBitmap);
begin
  FTiles.AddOrSetValue(Key, Bmp);
  FTileOrder.Remove(Key);
  FTileOrder.Add(Key);
  while FTileOrder.Count > MAX_MEM_TILES do
  begin
    FTiles.Remove(FTileOrder[0]);
    FTileOrder.Delete(0);
  end;
end;

procedure TMapView.WMEraseBkgnd(var Message: TWMEraseBkgnd);
begin
  Message.Result := 1;
end;

procedure TMapView.WMGetDlgCode(var Message: TWMGetDlgCode);
begin
  Message.Result := DLGC_WANTARROWS;
end;

function TMapView.TileLevel: Integer;
begin
  Result := EnsureRange(Round(FZoom), MIN_ZOOM, MAX_ZOOM);
end;

function TMapView.WorldPx: Double;
begin
  Result := TILE * Power(2, FZoom);
end;

function TMapView.ViewLeft: Double;
begin
  Result := FCX * WorldPx - ClientWidth / 2;
end;

function TMapView.ViewTop: Double;
begin
  Result := FCY * WorldPx - ClientHeight / 2;
end;

function TMapView.Zoom: Integer;
begin
  if FAnim.Enabled then
    Result := Round(FAnimTo)
  else
    Result := Round(FZoom);
end;

{ Draw tile Z/X/Y into R. Missing? Use a scaled-up piece of a lower zoom
  tile, then any higher zoom tiles (the four children) on top: what is left
  over from before a zoom, so nothing goes blank while the new tiles load. }
procedure TMapView.DrawTile(Z, X, Y: Integer; const R: TRect; Smooth: Boolean);
var
  Bmp: TBitmap;
  D, PZ, PX, PY, Part, SX, SY, CX, CY, MX, MY: Integer;
  DC: HDC;

  procedure Blit(B: TBitmap; const Dst: TRect; SrcX, SrcY, SrcW, SrcH: Integer);
  begin
    if (Dst.Width = SrcW) and (Dst.Height = SrcH) then
      BitBlt(DC, Dst.Left, Dst.Top, SrcW, SrcH, B.Canvas.Handle, SrcX, SrcY, SRCCOPY)
    else
      StretchBlt(DC, Dst.Left, Dst.Top, Dst.Width, Dst.Height, B.Canvas.Handle,
        SrcX, SrcY, SrcW, SrcH, SRCCOPY);
  end;

begin
  DC := Canvas.Handle;
  if Smooth then
  begin
    SetStretchBltMode(DC, HALFTONE);
    SetBrushOrgEx(DC, 0, 0, nil);
  end
  else
    SetStretchBltMode(DC, COLORONCOLOR);

  if FTiles.TryGetValue(TileKey(Z, X, Y), Bmp) then
  begin
    Blit(Bmp, R, 0, 0, TILE, TILE);
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
      Part := TILE shr D;
      SX := (X - (PX shl D)) * Part;
      SY := (Y - (PY shl D)) * Part;
      Blit(Bmp, R, SX, SY, Part, Part);
      Break;
    end;
  end;
  if Z < MAX_ZOOM then
  begin
    MX := R.Left + R.Width div 2;
    MY := R.Top + R.Height div 2;
    for CY := 0 to 1 do
      for CX := 0 to 1 do
        if FTiles.TryGetValue(TileKey(Z + 1, X * 2 + CX, Y * 2 + CY), Bmp) then
          Blit(Bmp, Rect(IfThen(CX = 0, R.Left, MX), IfThen(CY = 0, R.Top, MY),
            IfThen(CX = 0, MX, R.Right), IfThen(CY = 0, MY, R.Bottom)), 0, 0, TILE, TILE);
  end;
end;

// Hand the loaders the tiles in view (centre first), plus the next level out.
procedure TMapView.RequestVisibleTiles;
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
    Tick := GetTickCount;
    for Lvl := 0 to 1 do
    begin
      Z := TileLevel - Lvl;
      if Z < MIN_ZOOM then
        Break;
      N := 1 shl Z;
      TS := WorldPx / N;
      L := ViewLeft;
      T := ViewTop;
      for TY := Max(0, Floor(T / TS)) to Min(N - 1, Floor((T + ClientHeight) / TS)) do
        for TX := Floor(L / TS) to Floor((L + ClientWidth) / TS) do
        begin
          WX := ((TX mod N) + N) mod N;
          W.Key := TileKey(Z, WX, TY);
          if FTiles.ContainsKey(W.Key) then
            Continue;
          if FFailed.TryGetValue(W.Key, FailT) and (Tick - FailT < 30000) then
            Continue;
          W.Dist := Sqr((TX + 0.5) * TS - L - ClientWidth / 2) +
            Sqr((TY + 0.5) * TS - T - ClientHeight / 2) + Lvl * 1E12;
          Wants.Add(W);
        end;
    end;
    // nearest the centre first; the outer level after everything in view
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

function TMapView.ButtonRect(Index: Integer): TRect;
var
  Sz, Y: Integer;
begin
  Sz := MulDiv(30, CurrentPPI, 96);
  Y := 10 + (Index - 1) * (Sz + 4);
  Result := Rect(10, Y, 10 + Sz, Y + Sz);
end;

function TMapView.ButtonAt(X, Y: Integer): Integer;
var
  I: Integer;
begin
  for I := 1 to 2 do
    if ButtonRect(I).Contains(Point(X, Y)) then
      Exit(I);
  Result := 0;
end;

procedure TMapView.Paint;
var
  N, Z, TX, TY, WX, I, R, X0, Y0, X1, Y1, PX, PY: Integer;
  TS, L, T, WP: Double;
  M: TMapMarker;
  S: string;
  Sz: TSize;
  Smooth: Boolean;
  BR: TRect;

  procedure Banner(const Text: string; Y: Integer);
  var
    E: TSize;
    BX: Integer;
  begin
    Canvas.Font.Style := [fsBold];
    E := Canvas.TextExtent(Text);
    BX := (ClientWidth - E.cx) div 2;
    Canvas.Brush.Style := bsSolid;
    Canvas.Brush.Color := RGB(255, 250, 205);
    Canvas.Pen.Color := RGB(180, 160, 60);
    Canvas.RoundRect(BX - 12, Y, BX + E.cx + 12, Y + E.cy + 10, 8, 8);
    Canvas.Brush.Style := bsClear;
    Canvas.Font.Color := RGB(60, 50, 0);
    Canvas.TextOut(BX, Y + 5, Text);
    Canvas.Brush.Style := bsSolid;
    Canvas.Font.Style := [];
  end;

begin
  Canvas.Brush.Color := RGB(226, 226, 222);
  Canvas.FillRect(ClientRect);

  Z := TileLevel;
  N := 1 shl Z;
  WP := WorldPx;
  TS := WP / N;                                 // on-screen tile size
  L := ViewLeft;
  T := ViewTop;
  Smooth := not FAnim.Enabled and (Abs(TS - TILE) > 0.5);
  for TY := Max(0, Floor(T / TS)) to Min(N - 1, Floor((T + ClientHeight) / TS)) do
    for TX := Floor(L / TS) to Floor((L + ClientWidth) / TS) do
    begin
      WX := ((TX mod N) + N) mod N;             // wrap around the date line
      X0 := Round(TX * TS - L);
      Y0 := Round(TY * TS - T);
      X1 := Round((TX + 1) * TS - L);
      Y1 := Round((TY + 1) * TS - T);
      DrawTile(Z, WX, TY, Rect(X0, Y0, X1, Y1), Smooth);
    end;
  if not FAnim.Enabled then
    RequestVisibleTiles;

  Canvas.Font.Name := 'Segoe UI';
  Canvas.Font.Size := 8;

  // search result pin
  if FHasPin then
  begin
    PX := Round(LonToNX(FPinLon) * WP - L);
    PY := Round(LatToNY(FPinLat) * WP - T);
    Canvas.Pen.Color := RGB(90, 0, 120);
    Canvas.Pen.Width := 3;
    Canvas.Brush.Style := bsClear;
    Canvas.Ellipse(PX - 11, PY - 11, PX + 12, PY + 12);
    Canvas.MoveTo(PX - 16, PY); Canvas.LineTo(PX - 6, PY);
    Canvas.MoveTo(PX + 7, PY); Canvas.LineTo(PX + 17, PY);
    Canvas.MoveTo(PX, PY - 16); Canvas.LineTo(PX, PY - 6);
    Canvas.MoveTo(PX, PY + 7); Canvas.LineTo(PX, PY + 17);
    Canvas.Pen.Width := 1;
    if FPinCaption <> '' then
    begin
      Sz := Canvas.TextExtent(FPinCaption);
      Canvas.Brush.Style := bsSolid;
      Canvas.Brush.Color := RGB(245, 235, 255);
      Canvas.Pen.Color := RGB(90, 0, 120);
      Canvas.Rectangle(PX + 14, PY + 8, PX + 20 + Sz.cx, PY + 12 + Sz.cy);
      Canvas.Brush.Style := bsClear;
      Canvas.Font.Color := RGB(60, 0, 90);
      Canvas.TextOut(PX + 17, PY + 10, FPinCaption);
    end;
    Canvas.Brush.Style := bsSolid;
  end;

  // markers (others first, then this radio on top)
  for R := 0 to 1 do
    for I := 0 to FMarkers.Count - 1 do
    begin
      M := FMarkers[I];
      if M.IsMe <> (R = 1) then
        Continue;
      PX := Round(LonToNX(M.Lon) * WP - L);
      PY := Round(LatToNY(M.Lat) * WP - T);
      // the world repeats sideways: draw the copy nearest the view
      while PX < -WP / 2 do PX := PX + Round(WP);
      while PX > ClientWidth + WP / 2 do PX := PX - Round(WP);
      if (PX < -50) or (PY < -50) or (PX > ClientWidth + 200) or (PY > ClientHeight + 50) then
        Continue;
      Canvas.Pen.Color := clWhite;
      Canvas.Pen.Width := 2;
      Canvas.Brush.Style := bsSolid;
      Canvas.Brush.Color := M.Color;
      if I = FHover then
        Canvas.Ellipse(PX - 9, PY - 9, PX + 10, PY + 10)
      else
        Canvas.Ellipse(PX - 7, PY - 7, PX + 8, PY + 8);
      Canvas.Pen.Width := 1;
      S := M.Caption;
      Sz := Canvas.TextExtent(S);
      Canvas.Brush.Color := RGB(255, 255, 240);
      Canvas.Pen.Color := RGB(150, 150, 150);
      Canvas.Rectangle(PX + 10, PY - Sz.cy div 2 - 2, PX + 16 + Sz.cx, PY + Sz.cy div 2 + 2);
      Canvas.Brush.Style := bsClear;
      Canvas.Font.Color := clBlack;
      if M.IsMe or (I = FHover) then
        Canvas.Font.Style := [fsBold]
      else
        Canvas.Font.Style := [];
      Canvas.TextOut(PX + 13, PY - Sz.cy div 2, S);
      Canvas.Brush.Style := bsSolid;
    end;
  Canvas.Font.Style := [];

  // where the radio would go, following the mouse
  if FPlaceMode and FMouseIn and not FDragMoved and (ButtonAt(FMouse.X, FMouse.Y) = 0) then
  begin
    Canvas.Pen.Color := RGB(215, 40, 40);
    Canvas.Pen.Width := 2;
    Canvas.Brush.Style := bsClear;
    Canvas.Ellipse(FMouse.X - 9, FMouse.Y - 9, FMouse.X + 10, FMouse.Y + 10);
    Canvas.Pen.Width := 1;
    Canvas.Brush.Style := bsSolid;
  end;

  // zoom buttons
  Canvas.Font.Size := 13;
  Canvas.Font.Style := [fsBold];
  for I := 1 to 2 do
  begin
    BR := ButtonRect(I);
    if FHoverBtn = I then
      Canvas.Brush.Color := RGB(235, 242, 255)
    else
      Canvas.Brush.Color := clWhite;
    Canvas.Pen.Color := RGB(150, 150, 150);
    Canvas.RoundRect(BR.Left, BR.Top, BR.Right, BR.Bottom, 6, 6);
    if I = 1 then S := '+' else S := #$2212;
    Sz := Canvas.TextExtent(S);
    Canvas.Brush.Style := bsClear;
    Canvas.Font.Color := RGB(50, 50, 50);
    Canvas.TextOut(BR.Left + (BR.Width - Sz.cx) div 2, BR.Top + (BR.Height - Sz.cy) div 2 - 1, S);
    Canvas.Brush.Style := bsSolid;
  end;
  Canvas.Font.Size := 8;
  Canvas.Font.Style := [];

  if FPlaceMode then
  begin
    Banner('Click the map where your radio is.   Drag to move, scroll to zoom, Esc to cancel.', 10);
    if Zoom < 14 then
      Banner('Tip: zoom in closer first so the spot is accurate.', 40);
  end;

  // attribution (required by the OpenStreetMap licence)
  S := #$00A9' OpenStreetMap contributors';
  Sz := Canvas.TextExtent(S);
  Canvas.Brush.Color := RGB(255, 255, 255);
  Canvas.Pen.Color := RGB(255, 255, 255);
  Canvas.Rectangle(ClientWidth - Sz.cx - 8, ClientHeight - Sz.cy - 4, ClientWidth, ClientHeight);
  Canvas.Font.Color := RGB(60, 60, 60);
  Canvas.TextOut(ClientWidth - Sz.cx - 4, ClientHeight - Sz.cy - 2, S);
end;

procedure TMapView.Resize;
begin
  inherited;
  Invalidate;
end;

procedure TMapView.ClampCenter;
begin
  FCY := EnsureRange(FCY, 0, 1);
  FCX := FCX - Floor(FCX);          // wrap into 0..1
end;

procedure TMapView.SetView(Lat, Lon: Double; Zoom: Integer);
begin
  FAnim.Enabled := False;
  FZoom := EnsureRange(Zoom, MIN_ZOOM, MAX_ZOOM);
  FCX := LonToNX(Lon);
  FCY := LatToNY(Lat);
  ClampCenter;
  Invalidate;
end;

function TMapView.CenterLat: Double;
begin
  Result := NYToLat(FCY);
end;

function TMapView.CenterLon: Double;
begin
  Result := NXToLon(FCX);
end;

// Animated zoom that keeps the spot under (AroundX, AroundY) still
procedure TMapView.ZoomBy(Delta: Integer; AroundX, AroundY: Integer);
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
  FAnchorX := AroundX;
  FAnchorY := AroundY;
  FAnchorNX := (ViewLeft + AroundX) / WorldPx;
  FAnchorNY := (ViewTop + AroundY) / WorldPx;
  FAnimFrom := FZoom;
  FAnimTo := Target;
  FAnimStart := GetTickCount;
  FAnim.Enabled := True;
  AnimTick(nil);
end;

procedure TMapView.AnimTick(Sender: TObject);
var
  P, E, WP: Double;
begin
  P := Min(1, (GetTickCount - FAnimStart) / ANIM_MS);
  E := 1 - Power(1 - P, 3);                 // ease out
  FZoom := FAnimFrom + (FAnimTo - FAnimFrom) * E;
  if P >= 1 then
  begin
    FZoom := FAnimTo;
    FAnim.Enabled := False;
  end;
  WP := WorldPx;
  FCX := FAnchorNX - (FAnchorX - ClientWidth / 2) / WP;
  FCY := FAnchorNY - (FAnchorY - ClientHeight / 2) / WP;
  ClampCenter;
  Invalidate;
end;

procedure TMapView.FitBounds(South, North, West, East: Double; MaxZoom: Integer);
var
  Z: Integer;
  W, H: Double;
begin
  FAnim.Enabled := False;
  Z := EnsureRange(MaxZoom, MIN_ZOOM, MAX_ZOOM);
  while Z > MIN_ZOOM do
  begin
    W := (LonToNX(East) - LonToNX(West)) * TILE * Power(2, Z);
    H := (LatToNY(South) - LatToNY(North)) * TILE * Power(2, Z);
    if (W < ClientWidth - 120) and (H < ClientHeight - 60) then
      Break;
    Dec(Z);
  end;
  FZoom := Z;
  FCX := (LonToNX(West) + LonToNX(East)) / 2;
  FCY := (LatToNY(South) + LatToNY(North)) / 2;
  ClampCenter;
  Invalidate;
end;

procedure TMapView.FitMarkers;
var
  M: TMapMarker;
  MinLat, MaxLat, MinLon, MaxLon: Double;
begin
  if FMarkers.Count = 0 then
    Exit;
  MinLat := 90; MaxLat := -90; MinLon := 180; MaxLon := -180;
  for M in FMarkers do
  begin
    MinLat := Min(MinLat, M.Lat); MaxLat := Max(MaxLat, M.Lat);
    MinLon := Min(MinLon, M.Lon); MaxLon := Max(MaxLon, M.Lon);
  end;
  FitBounds(MinLat, MaxLat, MinLon, MaxLon, 13);
end;

procedure TMapView.SetMarker(const M: TMapMarker);
var
  I: Integer;
begin
  for I := 0 to FMarkers.Count - 1 do
    if FMarkers[I].Id = M.Id then
    begin
      FMarkers[I] := M;
      Invalidate;
      Exit;
    end;
  FMarkers.Add(M);
  Invalidate;
end;

procedure TMapView.RemoveMarker(Id: Cardinal);
var
  I: Integer;
begin
  for I := FMarkers.Count - 1 downto 0 do
    if FMarkers[I].Id = Id then
    begin
      FMarkers.Delete(I);
      FHover := -1;
      Invalidate;
    end;
end;

procedure TMapView.ClearMarkers;
begin
  FMarkers.Clear;
  FHover := -1;
  Invalidate;
end;

function TMapView.MarkerCount: Integer;
begin
  Result := FMarkers.Count;
end;

function TMapView.HasMarker(Id: Cardinal): Boolean;
var
  M: TMapMarker;
begin
  for M in FMarkers do
    if M.Id = Id then
      Exit(True);
  Result := False;
end;

procedure TMapView.SetPin(Lat, Lon: Double; const Caption: string);
begin
  FHasPin := True;
  FPinLat := Lat;
  FPinLon := Lon;
  FPinCaption := Caption;
  Invalidate;
end;

procedure TMapView.ClearPin;
begin
  FHasPin := False;
  Invalidate;
end;

function TMapView.ScreenToLatLon(X, Y: Integer; out Lat, Lon: Double): Boolean;
var
  NX, NY: Double;
begin
  NX := (ViewLeft + X) / WorldPx;
  NY := (ViewTop + Y) / WorldPx;
  Result := (NY >= 0) and (NY <= 1);
  Lat := NYToLat(EnsureRange(NY, 0, 1));
  Lon := NXToLon(NX - Floor(NX));
end;

function TMapView.MarkerAt(X, Y: Integer): Integer;
var
  I, PX, PY: Integer;
  L, T, WP: Double;
begin
  L := ViewLeft;
  T := ViewTop;
  WP := WorldPx;
  for I := FMarkers.Count - 1 downto 0 do
  begin
    PX := Round(LonToNX(FMarkers[I].Lon) * WP - L);
    PY := Round(LatToNY(FMarkers[I].Lat) * WP - T);
    while PX < -WP / 2 do PX := PX + Round(WP);
    while PX > ClientWidth + WP / 2 do PX := PX - Round(WP);
    if Sqr(PX - X) + Sqr(PY - Y) <= 100 then
      Exit(I);
  end;
  Result := -1;
end;

procedure TMapView.SetPlaceMode(Value: Boolean);
begin
  if FPlaceMode = Value then
    Exit;
  FPlaceMode := Value;
  UpdateCursor;
  Invalidate;
  if Value and CanFocus then
    SetFocus;
  if Assigned(FOnPlaceModeChange) then
    FOnPlaceModeChange(Self);
end;

procedure TMapView.UpdateCursor;
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

procedure TMapView.CMMouseLeave(var Message: TMessage);
begin
  inherited;
  FMouseIn := False;
  FHoverBtn := 0;
  if FHover >= 0 then
    FHover := -1;
  Invalidate;
end;

procedure TMapView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  B: Integer;
begin
  inherited;
  if CanFocus then
    SetFocus;
  if Button <> mbLeft then
    Exit;
  B := ButtonAt(X, Y);
  if B > 0 then
  begin
    if B = 1 then
      ZoomBy(1, ClientWidth div 2, ClientHeight div 2)
    else
      ZoomBy(-1, ClientWidth div 2, ClientHeight div 2);
    Exit;
  end;
  FDragging := True;
  FDragMoved := False;
  FDragStart := Point(X, Y);
  FDragCX := FCX;
  FDragCY := FCY;
end;

procedure TMapView.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  H, B: Integer;
  WP: Double;
begin
  inherited;
  FMouse := Point(X, Y);
  FMouseIn := True;
  if FDragging then
  begin
    if not FDragMoved and ((Abs(X - FDragStart.X) > 3) or (Abs(Y - FDragStart.Y) > 3)) then
    begin
      FDragMoved := True;
      FAnim.Enabled := False;
      // restart from here so a zoom that was still animating does not jump
      FDragStart := Point(X, Y);
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
      Invalidate;
    end;
    Exit;
  end;
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
    Invalidate;
  end
  else if FPlaceMode then
    Invalidate;                     // move the "goes here" ring
end;

procedure TMapView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
  Lat, Lon: Double;
begin
  inherited;
  if (Button = mbLeft) and FDragging then
  begin
    FDragging := False;
    if FDragMoved then
    begin
      FDragMoved := False;
      UpdateCursor;
      Invalidate;
      Exit;
    end;
    if FPlaceMode then
    begin
      if ScreenToLatLon(X, Y, Lat, Lon) and Assigned(FOnPlace) then
        FOnPlace(Self, Lat, Lon);
      Exit;
    end;
    I := MarkerAt(X, Y);
    if (I >= 0) and Assigned(FOnMarkerClick) then
      FOnMarkerClick(Self, FMarkers[I].Id);
  end;
end;

procedure TMapView.DblClick;
var
  P: TPoint;
  I: Integer;
begin
  inherited;
  P := ScreenToClient(Mouse.CursorPos);
  if FPlaceMode or (ButtonAt(P.X, P.Y) > 0) then
    Exit;
  I := MarkerAt(P.X, P.Y);
  if I >= 0 then
  begin
    if Assigned(FOnMarkerDblClick) then
      FOnMarkerDblClick(Self, FMarkers[I].Id);
  end
  else
    ZoomBy(1, P.X, P.Y);
end;

function TMapView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
var
  P: TPoint;
begin
  Result := True;
  P := ScreenToClient(MousePos);
  // touchpads send many small steps: one zoom level per notch's worth
  if Sign(WheelDelta) <> Sign(FWheelAcc) then
    FWheelAcc := 0;
  Inc(FWheelAcc, WheelDelta);
  while Abs(FWheelAcc) >= WHEEL_DELTA do
  begin
    ZoomBy(Sign(FWheelAcc), P.X, P.Y);
    Dec(FWheelAcc, Sign(FWheelAcc) * WHEEL_DELTA);
  end;
end;

procedure TMapView.KeyDown(var Key: Word; Shift: TShiftState);
const
  STEP = 120;
var
  WP: Double;
begin
  inherited;
  WP := WorldPx;
  case Key of
    VK_ESCAPE: PlaceMode := False;
    VK_LEFT: FCX := FCX - STEP / WP;
    VK_RIGHT: FCX := FCX + STEP / WP;
    VK_UP: FCY := FCY - STEP / WP;
    VK_DOWN: FCY := FCY + STEP / WP;
    VK_ADD, VK_OEM_PLUS: ZoomBy(1, ClientWidth div 2, ClientHeight div 2);
    VK_SUBTRACT, VK_OEM_MINUS: ZoomBy(-1, ClientWidth div 2, ClientHeight div 2);
  else
    Exit;
  end;
  ClampCenter;
  Invalidate;
  Key := 0;
end;

end.
