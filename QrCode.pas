unit QrCode;

{ Small QR code generator (byte mode, versions 1-40, all error-correction
  levels, automatic mask choice). Follows the structure of Project Nayuki's
  public-domain-style reference implementation (MIT licence). }

interface

uses
  System.SysUtils;

type
  TQrEcc = (qeLow, qeMedium, qeQuartile, qeHigh);
  TQrMatrix = TArray<TArray<Boolean>>;   // [y][x], True = dark

// Encodes Data in the smallest version that fits at MinEcc (raised if it
// fits for free). Mask -1 = pick the best; 0..7 forces one (for testing).
function QrEncode(const Data: TBytes; MinEcc: TQrEcc = qeMedium; Mask: Integer = -1;
  BoostEcc: Boolean = True): TQrMatrix;

implementation

uses
  System.Math;

const
  ECC_CODEWORDS_PER_BLOCK: array[TQrEcc, 0..40] of ShortInt = (
    (-1,  7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30),
    (-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28),
    (-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30),
    (-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30));

  NUM_ERROR_CORRECTION_BLOCKS: array[TQrEcc, 0..40] of ShortInt = (
    (-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4,  4,  4,  4,  4,  6,  6,  6,  6,  7,  8,  8,  9,  9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25),
    (-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5,  5,  8,  9,  9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49),
    (-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8,  8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68),
    (-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81));

  ECC_FORMAT_BITS: array[TQrEcc] of Integer = (1, 0, 3, 2);

type
  TQrBuilder = record
    Version, Size: Integer;
    Ecc: TQrEcc;
    Modules, IsFunction: TQrMatrix;
    procedure Init(AVersion: Integer; AEcc: TQrEcc);
    procedure SetFunction(X, Y: Integer; Dark: Boolean);
    procedure DrawFunctionPatterns;
    procedure DrawFinder(X, Y: Integer);
    procedure DrawAlignment(X, Y: Integer);
    procedure DrawFormatBits(Mask: Integer);
    procedure DrawVersion;
    procedure DrawCodewords(const Data: TBytes);
    procedure ApplyMask(Mask: Integer);
    function Penalty: Integer;
  end;

function NumRawDataModules(Ver: Integer): Integer;
var
  NumAlign: Integer;
begin
  Result := (16 * Ver + 128) * Ver + 64;
  if Ver >= 2 then
  begin
    NumAlign := Ver div 7 + 2;
    Dec(Result, (25 * NumAlign - 10) * NumAlign - 55);
    if Ver >= 7 then
      Dec(Result, 36);
  end;
end;

function NumDataCodewords(Ver: Integer; Ecc: TQrEcc): Integer;
begin
  Result := NumRawDataModules(Ver) div 8 -
    ECC_CODEWORDS_PER_BLOCK[Ecc, Ver] * NUM_ERROR_CORRECTION_BLOCKS[Ecc, Ver];
end;

function AlignmentPositions(Ver: Integer): TArray<Integer>;
var
  NumAlign, Step, Pos, I: Integer;
begin
  if Ver = 1 then
    Exit(nil);
  NumAlign := Ver div 7 + 2;
  Step := (Ver * 8 + NumAlign * 3 + 5) div (NumAlign * 4 - 4) * 2;
  SetLength(Result, NumAlign);
  Result[0] := 6;
  Pos := Ver * 4 + 17 - 7;
  for I := NumAlign - 1 downto 1 do
  begin
    Result[I] := Pos;
    Dec(Pos, Step);
  end;
end;

{ Reed-Solomon over GF(2^8) with polynomial 0x11D }

function GfMultiply(X, Y: Integer): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 7 downto 0 do
  begin
    Result := (Result shl 1) xor ((Result shr 7) * $11D);
    Result := Result xor (((Y shr I) and 1) * X);
  end;
end;

function RsDivisor(Degree: Integer): TBytes;
var
  Root, I, J: Integer;
begin
  SetLength(Result, Degree);
  FillChar(Result[0], Degree, 0);
  Result[Degree - 1] := 1;
  Root := 1;
  for I := 0 to Degree - 1 do
  begin
    for J := 0 to Degree - 1 do
    begin
      Result[J] := GfMultiply(Result[J], Root);
      if J + 1 < Degree then
        Result[J] := Result[J] xor Result[J + 1];
    end;
    Root := GfMultiply(Root, 2);
  end;
end;

function RsRemainder(const Data: TBytes; const Divisor: TBytes): TBytes;
var
  B: Byte;
  Factor, I, N: Integer;
begin
  N := Length(Divisor);
  SetLength(Result, N);
  FillChar(Result[0], N, 0);
  for B in Data do
  begin
    Factor := B xor Result[0];
    Move(Result[1], Result[0], N - 1);
    Result[N - 1] := 0;
    for I := 0 to N - 1 do
      Result[I] := Result[I] xor GfMultiply(Divisor[I], Factor);
  end;
end;

function AddEccAndInterleave(const Data: TBytes; Ver: Integer; Ecc: TQrEcc): TBytes;
var
  NumBlocks, BlockEccLen, RawCodewords, NumShortBlocks, ShortBlockLen: Integer;
  Divisor, Dat, EccBytes, Block: TBytes;
  Blocks: TArray<TBytes>;
  I, J, K, DatLen, N: Integer;
begin
  NumBlocks := NUM_ERROR_CORRECTION_BLOCKS[Ecc, Ver];
  BlockEccLen := ECC_CODEWORDS_PER_BLOCK[Ecc, Ver];
  RawCodewords := NumRawDataModules(Ver) div 8;
  NumShortBlocks := NumBlocks - RawCodewords mod NumBlocks;
  ShortBlockLen := RawCodewords div NumBlocks;

  Divisor := RsDivisor(BlockEccLen);
  SetLength(Blocks, NumBlocks);
  K := 0;
  for I := 0 to NumBlocks - 1 do
  begin
    DatLen := ShortBlockLen - BlockEccLen;
    if I >= NumShortBlocks then
      Inc(DatLen);
    Dat := Copy(Data, K, DatLen);
    Inc(K, DatLen);
    EccBytes := RsRemainder(Dat, Divisor);
    // short blocks get a dummy byte so all blocks line up; skipped below
    SetLength(Block, ShortBlockLen + 1);
    Move(Dat[0], Block[0], DatLen);
    if I < NumShortBlocks then
      Block[DatLen] := 0;
    Move(EccBytes[0], Block[ShortBlockLen + 1 - BlockEccLen], BlockEccLen);
    Blocks[I] := Copy(Block);
  end;

  SetLength(Result, RawCodewords);
  N := 0;
  for I := 0 to ShortBlockLen do
    for J := 0 to NumBlocks - 1 do
      if (I <> ShortBlockLen - BlockEccLen) or (J >= NumShortBlocks) then
      begin
        Result[N] := Blocks[J][I];
        Inc(N);
      end;
end;

{ TQrBuilder }

procedure TQrBuilder.Init(AVersion: Integer; AEcc: TQrEcc);
var
  Y: Integer;
begin
  Version := AVersion;
  Ecc := AEcc;
  Size := Version * 4 + 17;
  SetLength(Modules, Size);
  SetLength(IsFunction, Size);
  for Y := 0 to Size - 1 do
  begin
    SetLength(Modules[Y], Size);
    SetLength(IsFunction[Y], Size);
  end;
end;

procedure TQrBuilder.SetFunction(X, Y: Integer; Dark: Boolean);
begin
  Modules[Y][X] := Dark;
  IsFunction[Y][X] := True;
end;

procedure TQrBuilder.DrawFinder(X, Y: Integer);
var
  DX, DY, Dist, XX, YY: Integer;
begin
  for DY := -4 to 4 do
    for DX := -4 to 4 do
    begin
      Dist := Abs(DX);
      if Abs(DY) > Dist then
        Dist := Abs(DY);
      XX := X + DX;
      YY := Y + DY;
      if (XX >= 0) and (XX < Size) and (YY >= 0) and (YY < Size) then
        SetFunction(XX, YY, (Dist <> 2) and (Dist <> 4));
    end;
end;

procedure TQrBuilder.DrawAlignment(X, Y: Integer);
var
  DX, DY, Dist: Integer;
begin
  for DY := -2 to 2 do
    for DX := -2 to 2 do
    begin
      Dist := Abs(DX);
      if Abs(DY) > Dist then
        Dist := Abs(DY);
      SetFunction(X + DX, Y + DY, Dist <> 1);
    end;
end;

procedure TQrBuilder.DrawFormatBits(Mask: Integer);
var
  Data, Rem, Bits, I: Integer;

  function Bit(N: Integer): Boolean;
  begin
    Result := ((Bits shr N) and 1) <> 0;
  end;

begin
  Data := (ECC_FORMAT_BITS[Ecc] shl 3) or Mask;
  Rem := Data;
  for I := 0 to 9 do
    Rem := (Rem shl 1) xor ((Rem shr 9) * $537);
  Bits := ((Data shl 10) or Rem) xor $5412;

  // first copy, around the top-left finder
  for I := 0 to 5 do
    SetFunction(8, I, Bit(I));
  SetFunction(8, 7, Bit(6));
  SetFunction(8, 8, Bit(7));
  SetFunction(7, 8, Bit(8));
  for I := 9 to 14 do
    SetFunction(14 - I, 8, Bit(I));
  // second copy, split between the other two finders
  for I := 0 to 7 do
    SetFunction(Size - 1 - I, 8, Bit(I));
  for I := 8 to 14 do
    SetFunction(8, Size - 15 + I, Bit(I));
  SetFunction(8, Size - 8, True);       // always dark
end;

procedure TQrBuilder.DrawVersion;
var
  Rem, Bits, I, A, B: Integer;
  Dark: Boolean;
begin
  if Version < 7 then
    Exit;
  Rem := Version;
  for I := 0 to 11 do
    Rem := (Rem shl 1) xor ((Rem shr 11) * $1F25);
  Bits := (Version shl 12) or Rem;
  for I := 0 to 17 do
  begin
    Dark := ((Bits shr I) and 1) <> 0;
    A := Size - 11 + I mod 3;
    B := I div 3;
    SetFunction(A, B, Dark);
    SetFunction(B, A, Dark);
  end;
end;

procedure TQrBuilder.DrawFunctionPatterns;
var
  I, J, N: Integer;
  Pos: TArray<Integer>;
begin
  for I := 0 to Size - 1 do
  begin
    SetFunction(6, I, I mod 2 = 0);
    SetFunction(I, 6, I mod 2 = 0);
  end;
  DrawFinder(3, 3);
  DrawFinder(Size - 4, 3);
  DrawFinder(3, Size - 4);
  Pos := AlignmentPositions(Version);
  N := Length(Pos);
  for I := 0 to N - 1 do
    for J := 0 to N - 1 do
      if not (((I = 0) and (J = 0)) or ((I = 0) and (J = N - 1)) or ((I = N - 1) and (J = 0))) then
        DrawAlignment(Pos[I], Pos[J]);
  DrawFormatBits(0);   // placeholder, redrawn once the mask is chosen
  DrawVersion;
end;

procedure TQrBuilder.DrawCodewords(const Data: TBytes);
var
  I, Right, Vert, J, X, Y: Integer;
  Upward: Boolean;
begin
  I := 0;
  Right := Size - 1;
  while Right >= 1 do
  begin
    if Right = 6 then
      Right := 5;
    for Vert := 0 to Size - 1 do
      for J := 0 to 1 do
      begin
        X := Right - J;
        Upward := ((Right + 1) and 2) = 0;
        if Upward then
          Y := Size - 1 - Vert
        else
          Y := Vert;
        if not IsFunction[Y][X] and (I < Length(Data) * 8) then
        begin
          Modules[Y][X] := ((Data[I shr 3] shr (7 - (I and 7))) and 1) <> 0;
          Inc(I);
        end;
      end;
    Dec(Right, 2);
  end;
end;

procedure TQrBuilder.ApplyMask(Mask: Integer);
var
  X, Y: Integer;
  Invert: Boolean;
begin
  for Y := 0 to Size - 1 do
    for X := 0 to Size - 1 do
    begin
      case Mask of
        0: Invert := (X + Y) mod 2 = 0;
        1: Invert := Y mod 2 = 0;
        2: Invert := X mod 3 = 0;
        3: Invert := (X + Y) mod 3 = 0;
        4: Invert := (X div 3 + Y div 2) mod 2 = 0;
        5: Invert := (X * Y mod 2 + X * Y mod 3) = 0;
        6: Invert := (X * Y mod 2 + X * Y mod 3) mod 2 = 0;
      else
        Invert := ((X + Y) mod 2 + X * Y mod 3) mod 2 = 0;
      end;
      if Invert and not IsFunction[Y][X] then
        Modules[Y][X] := not Modules[Y][X];
    end;
end;

// Standard ISO 18004 mask penalty (N1..N4)
function TQrBuilder.Penalty: Integer;
const
  FINDER: array[0..10] of Boolean = (True, False, True, True, True, False, True,
    False, False, False, False);

  function Get(Horizontal: Boolean; Line, I: Integer): Boolean;
  begin
    if Horizontal then
      Result := Modules[Line][I]
    else
      Result := Modules[I][Line];
  end;

  function MatchFinder(Horizontal: Boolean; Line, Start: Integer; Reverse: Boolean): Boolean;
  var
    K: Integer;
    Want: Boolean;
  begin
    for K := 0 to 10 do
    begin
      if Reverse then
        Want := FINDER[10 - K]
      else
        Want := FINDER[K];
      if Get(Horizontal, Line, Start + K) <> Want then
        Exit(False);
    end;
    Result := True;
  end;

var
  Line, I, Run, Dark, Total, K: Integer;
  H: Boolean;
  Prev: Boolean;
begin
  Result := 0;
  for H in [True, False] do
    for Line := 0 to Size - 1 do
    begin
      // N1: runs of 5+ same-colour modules
      Run := 1;
      Prev := Get(H, Line, 0);
      for I := 1 to Size - 1 do
        if Get(H, Line, I) = Prev then
        begin
          Inc(Run);
          if Run = 5 then
            Inc(Result, 3)
          else if Run > 5 then
            Inc(Result);
        end
        else
        begin
          Prev := Get(H, Line, I);
          Run := 1;
        end;
      // N3: finder-like 1:1:3:1:1 patterns with 4 light modules on a side
      for I := 0 to Size - 11 do
        if MatchFinder(H, Line, I, False) or MatchFinder(H, Line, I, True) then
          Inc(Result, 40);
    end;
  // N2: 2x2 blocks of one colour
  for Line := 0 to Size - 2 do
    for I := 0 to Size - 2 do
      if (Modules[Line][I] = Modules[Line][I + 1]) and (Modules[Line][I] = Modules[Line + 1][I]) and
        (Modules[Line][I] = Modules[Line + 1][I + 1]) then
        Inc(Result, 3);
  // N4: dark/light balance
  Dark := 0;
  for Line := 0 to Size - 1 do
    for I := 0 to Size - 1 do
      if Modules[Line][I] then
        Inc(Dark);
  Total := Size * Size;
  K := (Abs(Dark * 20 - Total * 10) + Total - 1) div Total - 1;
  if K > 0 then
    Inc(Result, K * 10);
end;

{ encoder }

function QrEncode(const Data: TBytes; MinEcc: TQrEcc; Mask: Integer; BoostEcc: Boolean): TQrMatrix;
var
  Ver, CapBits, UsedBits, CountBits, I, M, BestMask, BestPenalty, P: Integer;
  Ecc, E: TQrEcc;
  Bits: TArray<Boolean>;
  Codewords, AllCodewords: TBytes;
  Q, Best: TQrBuilder;

  procedure AppendBits(Val, Len: Integer);
  var
    K: Integer;
  begin
    for K := Len - 1 downto 0 do
      Bits := Bits + [((Val shr K) and 1) <> 0];
  end;

begin
  Ecc := MinEcc;
  Ver := 0;

  for I := 1 to 40 do
  begin
    if I <= 9 then CountBits := 8 else CountBits := 16;
    UsedBits := 4 + CountBits + Length(Data) * 8;
    if UsedBits <= NumDataCodewords(I, Ecc) * 8 then
    begin
      Ver := I;
      Break;
    end;
  end;
  if Ver = 0 then
    raise Exception.Create('Too much data for a QR code');
  if BoostEcc then
    for E := Succ(MinEcc) to qeHigh do
      if UsedBits <= NumDataCodewords(Ver, E) * 8 then
        Ecc := E;

  // data bits: byte mode, character count, payload, terminator, padding
  Bits := nil;
  AppendBits(4, 4);
  if Ver <= 9 then CountBits := 8 else CountBits := 16;
  AppendBits(Length(Data), CountBits);
  for I := 0 to High(Data) do
    AppendBits(Data[I], 8);
  CapBits := NumDataCodewords(Ver, Ecc) * 8;
  AppendBits(0, Min(4, CapBits - Length(Bits)));
  AppendBits(0, (8 - Length(Bits) mod 8) mod 8);
  SetLength(Codewords, CapBits div 8);
  for I := 0 to Length(Bits) div 8 - 1 do
  begin
    Codewords[I] := 0;
    for M := 0 to 7 do
      if Bits[I * 8 + M] then
        Codewords[I] := Codewords[I] or (1 shl (7 - M));
  end;
  P := $EC;
  for I := Length(Bits) div 8 to High(Codewords) do
  begin
    Codewords[I] := P;
    P := P xor ($EC xor $11);
  end;

  AllCodewords := AddEccAndInterleave(Codewords, Ver, Ecc);

  Q.Init(Ver, Ecc);
  Q.DrawFunctionPatterns;
  Q.DrawCodewords(AllCodewords);

  if Mask < 0 then
  begin
    BestMask := 0;
    BestPenalty := MaxInt;
    for M := 0 to 7 do
    begin
      Q.ApplyMask(M);
      Q.DrawFormatBits(M);
      P := Q.Penalty;
      if P < BestPenalty then
      begin
        BestPenalty := P;
        BestMask := M;
      end;
      Q.ApplyMask(M);                  // XOR again to undo
    end;
  end
  else
    BestMask := Mask;
  Q.ApplyMask(BestMask);
  Q.DrawFormatBits(BestMask);
  Best := Q;
  Result := Best.Modules;
end;

end.
