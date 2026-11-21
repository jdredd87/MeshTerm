unit FmxSheet;

{ Simple in-window dialogs for FireMonkey: a dimmed overlay with a card of
  text, edits, checkboxes and buttons. Nothing blocks (Android cannot show
  modal dialogs), so the result arrives in the button's procedure. They look
  and behave the same on Windows and Android. }

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, System.Math,
  System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Objects, FMX.StdCtrls, FMX.Edit,
  FMX.Layouts, FMX.Graphics, FMX.TextLayout;

type
  TSheetAction = record
    Caption: string;
    Action: TProc;
    Primary: Boolean;
  end;

  TSheet = class(TRectangle)
  private
    type
      TItemKind = (ikText, ikControl, ikButtons);
      TItem = record
        Kind: TItemKind;
        Ctrl: TControl;
        Height: Single;          // 0 = measure (text)
        Buttons: TArray<TButton>;
        Vertical: Boolean;
      end;
  private
    FForm: TCommonCustomForm;
    FCard: TRectangle;
    FScroll: TVertScrollBox;
    FItems: TList<TItem>;
    FActions: TList<TSheetAction>;
    FFocus: TControl;
    FPrimary: TButton;
    FOnCancel: TProc;
    FClosed: Boolean;
    procedure DoLayout;
    procedure OverlayClick(Sender: TObject);
    procedure ButtonClick(Sender: TObject);
    procedure EditKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure OverlayResized(Sender: TObject);
  public
    Cancelable: Boolean;
    constructor CreateSheet(AForm: TCommonCustomForm; const Title: string);
    destructor Destroy; override;
    function AddText(const S: string; Color: TAlphaColor = 0; Bold: Boolean = False;
      Size: Single = 0): TLabel;
    function AddEdit(const Text, Prompt: string): TEdit;
    function AddCheck(const Caption: string; Checked: Boolean): TCheckBox;
    function AddControl(C: TControl; Height: Single): TControl;
    { Vertical = one full-width button per row (action lists); otherwise a
      row of equal buttons (OK / Cancel). }
    procedure AddButtons(const Actions: array of TSheetAction; Vertical: Boolean = False);
    procedure Present;
    procedure Close;
    property OnCancel: TProc read FOnCancel write FOnCancel;
  end;

function Act(const Caption: string; const Action: TProc; Primary: Boolean = False): TSheetAction;
procedure ShowInfo(Form: TCommonCustomForm; const Title, Text: string);
procedure ShowConfirm(Form: TCommonCustomForm; const Title, Text, YesCaption: string;
  const OnYes: TProc; const NoCaption: string = 'Cancel');
procedure ShowInput(Form: TCommonCustomForm; const Title, Prompt, Default: string;
  const OnOk: TProc<string>; const OkCaption: string = 'OK');
procedure ShowActions(Form: TCommonCustomForm; const Title, Text: string;
  const Actions: array of TSheetAction);
{ Closes the newest open sheet (Android back key). False if none was open. }
function CloseTopSheet: Boolean;
function SheetOpen: Boolean;
{ Height a word-wrapped text needs at width W. }
function MeasureText(const S: string; W, Size: Single; Bold: Boolean = False): Single;

const
  SHEET_TEXT_SIZE = 14;

implementation

var
  Sheets: TList<TSheet>;

function Act(const Caption: string; const Action: TProc; Primary: Boolean): TSheetAction;
begin
  Result.Caption := Caption;
  Result.Action := Action;
  Result.Primary := Primary;
end;

function MeasureText(const S: string; W, Size: Single; Bold: Boolean): Single;
var
  L: TTextLayout;
begin
  L := TTextLayoutManager.DefaultTextLayout.Create;
  try
    L.BeginUpdate;
    try
      L.TopLeft := PointF(0, 0);
      L.MaxSize := PointF(W, 100000);
      L.WordWrap := True;
      L.Font.Size := Size;
      if Bold then
        L.Font.Style := [TFontStyle.fsBold];
      L.Text := S;
    finally
      L.EndUpdate;
    end;
    Result := Ceil(L.TextHeight) + 6;
  finally
    L.Free;
  end;
end;

{ TSheet }

constructor TSheet.CreateSheet(AForm: TCommonCustomForm; const Title: string);
begin
  inherited Create(AForm);
  FForm := AForm;
  FItems := TList<TItem>.Create;
  FActions := TList<TSheetAction>.Create;
  Cancelable := True;
  Parent := AForm;
  Align := TAlignLayout.Contents;
  Fill.Color := $70000000;
  Stroke.Kind := TBrushKind.None;
  HitTest := True;
  OnClick := OverlayClick;
  OnResized := OverlayResized;
  Visible := False;

  FCard := TRectangle.Create(Self);
  FCard.Parent := Self;
  FCard.Fill.Color := TAlphaColors.White;
  FCard.Stroke.Color := $FFB0B0B0;
  FCard.XRadius := 10;
  FCard.YRadius := 10;
  FCard.HitTest := True;
  FCard.Padding.Rect := RectF(16, 12, 16, 12);

  FScroll := TVertScrollBox.Create(Self);
  FScroll.Parent := FCard;
  FScroll.Align := TAlignLayout.Client;

  if Title <> '' then
    AddText(Title, $FF202020, True, 16);
  Sheets.Add(Self);
end;

destructor TSheet.Destroy;
begin
  Sheets.Remove(Self);
  FActions.Free;
  FItems.Free;
  inherited;
end;

function TSheet.AddText(const S: string; Color: TAlphaColor; Bold: Boolean; Size: Single): TLabel;
var
  It: TItem;
begin
  Result := TLabel.Create(Self);
  Result.Parent := FScroll;
  Result.WordWrap := True;
  Result.AutoSize := False;
  Result.StyledSettings := [];
  if Size <= 0 then
    Size := SHEET_TEXT_SIZE;
  Result.TextSettings.Font.Size := Size;
  if Bold then
    Result.TextSettings.Font.Style := [TFontStyle.fsBold];
  if Color = 0 then
    Color := $FF303030;
  Result.TextSettings.FontColor := Color;
  Result.TextSettings.VertAlign := TTextAlign.Leading;
  Result.Text := S;
  It := Default(TItem);
  It.Kind := ikText;
  It.Ctrl := Result;
  FItems.Add(It);
end;

function TSheet.AddEdit(const Text, Prompt: string): TEdit;
begin
  Result := TEdit.Create(Self);
  Result.Text := Text;
  Result.TextPrompt := Prompt;
  Result.OnKeyDown := EditKeyDown;
  AddControl(Result, 36);
  if FFocus = nil then
    FFocus := Result;
end;

function TSheet.AddCheck(const Caption: string; Checked: Boolean): TCheckBox;
begin
  Result := TCheckBox.Create(Self);
  Result.Text := Caption;
  Result.IsChecked := Checked;
  Result.StyledSettings := Result.StyledSettings - [TStyledSetting.Size, TStyledSetting.FontColor];
  Result.TextSettings.Font.Size := SHEET_TEXT_SIZE;
  Result.TextSettings.FontColor := $FF303030;
  AddControl(Result, 34);
end;

function TSheet.AddControl(C: TControl; Height: Single): TControl;
var
  It: TItem;
begin
  C.Parent := FScroll;
  It := Default(TItem);
  It.Kind := ikControl;
  It.Ctrl := C;
  It.Height := Height;
  FItems.Add(It);
  Result := C;
end;

procedure TSheet.AddButtons(const Actions: array of TSheetAction; Vertical: Boolean);
var
  It: TItem;
  A: TSheetAction;
  B: TButton;
begin
  It := Default(TItem);
  It.Kind := ikButtons;
  It.Vertical := Vertical;
  for A in Actions do
  begin
    B := TButton.Create(Self);
    B.Parent := FScroll;
    B.Text := A.Caption;
    B.Tag := FActions.Count;
    B.OnClick := ButtonClick;
    if A.Primary then
    begin
      B.StyledSettings := B.StyledSettings - [TStyledSetting.Style];
      B.TextSettings.Font.Style := [TFontStyle.fsBold];
      FPrimary := B;
    end;
    FActions.Add(A);
    It.Buttons := It.Buttons + [B];
  end;
  FItems.Add(It);
end;

procedure TSheet.DoLayout;
const
  GAP = 8;
  BTN_H = 40;
var
  W, CW, Y, H, BW, Total: Single;
  It: TItem;
  I: Integer;
  L: TLabel;
begin
  W := Min(FForm.ClientWidth - 24, 540);
  CW := W - FCard.Padding.Left - FCard.Padding.Right - 4;
  Y := 0;
  for It in FItems do
  begin
    case It.Kind of
      ikText:
        begin
          L := TLabel(It.Ctrl);
          H := MeasureText(L.Text, CW, L.TextSettings.Font.Size,
            TFontStyle.fsBold in L.TextSettings.Font.Style);
          L.SetBounds(0, Y, CW, H);
          Y := Y + H + GAP;
        end;
      ikControl:
        begin
          It.Ctrl.SetBounds(0, Y, CW, It.Height);
          Y := Y + It.Height + GAP;
        end;
      ikButtons:
        begin
          Y := Y + 4;
          if It.Vertical then
            for I := 0 to High(It.Buttons) do
            begin
              It.Buttons[I].SetBounds(0, Y, CW, BTN_H);
              Y := Y + BTN_H + 6;
            end
          else if Length(It.Buttons) > 0 then
          begin
            BW := (CW - GAP * (Length(It.Buttons) - 1)) / Length(It.Buttons);
            for I := 0 to High(It.Buttons) do
              It.Buttons[I].SetBounds(I * (BW + GAP), Y, BW, BTN_H);
            Y := Y + BTN_H + GAP;
          end;
        end;
    end;
  end;
  Total := Y + FCard.Padding.Top + FCard.Padding.Bottom;
  H := Min(Total, FForm.ClientHeight - 48);
  FCard.SetBounds((FForm.ClientWidth - W) / 2, Min(40, Max(8, (FForm.ClientHeight - H) / 3)), W, H);
end;

procedure TSheet.OverlayResized(Sender: TObject);
begin
  if Visible then
    DoLayout;
end;

procedure TSheet.Present;
begin
  DoLayout;
  Visible := True;
  BringToFront;
  if FFocus <> nil then
    TThread.ForceQueue(nil,
      procedure
      begin
        if not FClosed and (FFocus <> nil) then
          FFocus.SetFocus;
      end);
end;

procedure TSheet.Close;
begin
  if FClosed then
    Exit;
  FClosed := True;
  Visible := False;
  Sheets.Remove(Self);
  // freed later: we may be inside one of our own buttons' click handlers
  TThread.ForceQueue(nil,
    procedure
    begin
      Free;
    end);
end;

procedure TSheet.OverlayClick(Sender: TObject);
begin
  if Cancelable then
  begin
    Close;
    if Assigned(FOnCancel) then
      FOnCancel();
  end;
end;

procedure TSheet.ButtonClick(Sender: TObject);
var
  A: TSheetAction;
begin
  if FClosed then
    Exit;
  A := FActions[TButton(Sender).Tag];
  Close;
  if Assigned(A.Action) then
    A.Action();
end;

procedure TSheet.EditKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  if (Key = vkReturn) and (FPrimary <> nil) then
  begin
    Key := 0;
    ButtonClick(FPrimary);
  end
  else if Key = vkEscape then
  begin
    Key := 0;
    OverlayClick(nil);
  end;
end;

function CloseTopSheet: Boolean;
begin
  Result := Sheets.Count > 0;
  if Result then
    Sheets.Last.OverlayClick(nil);
end;

function SheetOpen: Boolean;
begin
  Result := Sheets.Count > 0;
end;

procedure ShowInfo(Form: TCommonCustomForm; const Title, Text: string);
var
  S: TSheet;
begin
  S := TSheet.CreateSheet(Form, Title);
  S.AddText(Text);
  S.AddButtons([Act('OK', nil, True)]);
  S.Present;
end;

procedure ShowConfirm(Form: TCommonCustomForm; const Title, Text, YesCaption: string;
  const OnYes: TProc; const NoCaption: string);
var
  S: TSheet;
begin
  S := TSheet.CreateSheet(Form, Title);
  S.AddText(Text);
  S.AddButtons([Act(NoCaption, nil), Act(YesCaption, OnYes, True)]);
  S.Present;
end;

procedure ShowInput(Form: TCommonCustomForm; const Title, Prompt, Default: string;
  const OnOk: TProc<string>; const OkCaption: string);
var
  S: TSheet;
  E: TEdit;
begin
  S := TSheet.CreateSheet(Form, Title);
  if Prompt <> '' then
    S.AddText(Prompt);
  E := S.AddEdit(Default, '');
  S.AddButtons([Act('Cancel', nil), Act(OkCaption,
    procedure
    begin
      OnOk(E.Text);
    end, True)]);
  S.Present;
end;

procedure ShowActions(Form: TCommonCustomForm; const Title, Text: string;
  const Actions: array of TSheetAction);
var
  S: TSheet;
begin
  S := TSheet.CreateSheet(Form, Title);
  if Text <> '' then
    S.AddText(Text);
  S.AddButtons(Actions, True);
  S.AddButtons([Act('Cancel', nil)], True);
  S.Present;
end;

initialization
  Sheets := TList<TSheet>.Create;
finalization
  FreeAndNil(Sheets);
end.
