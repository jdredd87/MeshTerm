unit Meshtastic.Crypto;

{ Decrypts packets on channels that use Meshtastic's well-known default key
  (PSK "AQ==", e.g. LongFast). AES-128-CTR, in plain Pascal so it works on
  every platform (Windows and Android).
  Nonce: packet id (uint64 LE) + sender node (uint32 LE) + 4 zero bytes. }

interface

uses
  System.SysUtils;

// True if Enc decrypts with the default key into a sane Data message.
function DecryptDefaultChannel(const Enc: TBytes; PacketId, FromNode: Cardinal;
  out Plain: TBytes): Boolean;

// N bytes from the system's cryptographic random generator (for channel keys).
function SecureRandomBytes(N: Integer): TBytes;

type
  TAesBlock = array[0..15] of Byte;

// One AES-128 block encryption (exposed for the self-test).
procedure Aes128EncryptBlock(const Key: TAesBlock; const Input: TAesBlock; out Output: TAesBlock);

implementation

{$IFDEF MSWINDOWS}
uses
  Winapi.Windows;

function BCryptGenRandom(hAlgorithm: Pointer; pbBuffer: Pointer; cbBuffer, dwFlags: ULONG): LongInt;
  stdcall; external 'bcrypt.dll';
{$ELSE}
uses
  System.Classes;
{$ENDIF}

const
  // Meshtastic default channel key (expanded form of PSK index 1, "AQ==")
  DEFAULT_KEY: TAesBlock = ($D4, $F1, $BB, $3A, $20, $29, $07, $59,
    $F0, $BC, $FF, $AB, $CF, $4E, $69, $01);

  SBOX: array[0..255] of Byte = (
    $63, $7C, $77, $7B, $F2, $6B, $6F, $C5, $30, $01, $67, $2B, $FE, $D7, $AB, $76,
    $CA, $82, $C9, $7D, $FA, $59, $47, $F0, $AD, $D4, $A2, $AF, $9C, $A4, $72, $C0,
    $B7, $FD, $93, $26, $36, $3F, $F7, $CC, $34, $A5, $E5, $F1, $71, $D8, $31, $15,
    $04, $C7, $23, $C3, $18, $96, $05, $9A, $07, $12, $80, $E2, $EB, $27, $B2, $75,
    $09, $83, $2C, $1A, $1B, $6E, $5A, $A0, $52, $3B, $D6, $B3, $29, $E3, $2F, $84,
    $53, $D1, $00, $ED, $20, $FC, $B1, $5B, $6A, $CB, $BE, $39, $4A, $4C, $58, $CF,
    $D0, $EF, $AA, $FB, $43, $4D, $33, $85, $45, $F9, $02, $7F, $50, $3C, $9F, $A8,
    $51, $A3, $40, $8F, $92, $9D, $38, $F5, $BC, $B6, $DA, $21, $10, $FF, $F3, $D2,
    $CD, $0C, $13, $EC, $5F, $97, $44, $17, $C4, $A7, $7E, $3D, $64, $5D, $19, $73,
    $60, $81, $4F, $DC, $22, $2A, $90, $88, $46, $EE, $B8, $14, $DE, $5E, $0B, $DB,
    $E0, $32, $3A, $0A, $49, $06, $24, $5C, $C2, $D3, $AC, $62, $91, $95, $E4, $79,
    $E7, $C8, $37, $6D, $8D, $D5, $4E, $A9, $6C, $56, $F4, $EA, $65, $7A, $AE, $08,
    $BA, $78, $25, $2E, $1C, $A6, $B4, $C6, $E8, $DD, $74, $1F, $4B, $BD, $8B, $8A,
    $70, $3E, $B5, $66, $48, $03, $F6, $0E, $61, $35, $57, $B9, $86, $C1, $1D, $9E,
    $E1, $F8, $98, $11, $69, $D9, $8E, $94, $9B, $1E, $87, $E9, $CE, $55, $28, $DF,
    $8C, $A1, $89, $0D, $BF, $E6, $42, $68, $41, $99, $2D, $0F, $B0, $54, $BB, $16);

  RCON: array[1..10] of Byte = ($01, $02, $04, $08, $10, $20, $40, $80, $1B, $36);

type
  TRoundKeys = array[0..175] of Byte;   // 11 round keys of 16 bytes

function XTime(B: Byte): Byte; inline;
begin
  if B and $80 <> 0 then
    Result := Byte((B shl 1) xor $1B)
  else
    Result := Byte(B shl 1);
end;

procedure ExpandKey(const Key: TAesBlock; out RK: TRoundKeys);
var
  I: Integer;
  T: array[0..3] of Byte;
  B: Byte;
begin
  Move(Key[0], RK[0], 16);
  for I := 4 to 43 do
  begin
    Move(RK[(I - 1) * 4], T[0], 4);
    if I mod 4 = 0 then
    begin
      B := T[0];                       // RotWord + SubWord + Rcon
      T[0] := SBOX[T[1]] xor RCON[I div 4];
      T[1] := SBOX[T[2]];
      T[2] := SBOX[T[3]];
      T[3] := SBOX[B];
    end;
    RK[I * 4] := RK[(I - 4) * 4] xor T[0];
    RK[I * 4 + 1] := RK[(I - 4) * 4 + 1] xor T[1];
    RK[I * 4 + 2] := RK[(I - 4) * 4 + 2] xor T[2];
    RK[I * 4 + 3] := RK[(I - 4) * 4 + 3] xor T[3];
  end;
end;

procedure EncryptWithRoundKeys(const RK: TRoundKeys; const Input: TAesBlock; out Output: TAesBlock);
var
  S, T: TAesBlock;
  Round, C, I: Integer;
  A0, A1, A2, A3, All: Byte;
begin
  for I := 0 to 15 do
    S[I] := Input[I] xor RK[I];
  for Round := 1 to 10 do
  begin
    // SubBytes + ShiftRows (state is column-major: S[col*4 + row])
    for C := 0 to 3 do
      for I := 0 to 3 do
        T[C * 4 + I] := SBOX[S[((C + I) mod 4) * 4 + I]];
    // MixColumns (not in the last round)
    if Round < 10 then
      for C := 0 to 3 do
      begin
        A0 := T[C * 4]; A1 := T[C * 4 + 1]; A2 := T[C * 4 + 2]; A3 := T[C * 4 + 3];
        All := A0 xor A1 xor A2 xor A3;
        T[C * 4] := A0 xor All xor XTime(A0 xor A1);
        T[C * 4 + 1] := A1 xor All xor XTime(A1 xor A2);
        T[C * 4 + 2] := A2 xor All xor XTime(A2 xor A3);
        T[C * 4 + 3] := A3 xor All xor XTime(A3 xor A0);
      end;
    for I := 0 to 15 do
      S[I] := T[I] xor RK[Round * 16 + I];
  end;
  Output := S;
end;

procedure Aes128EncryptBlock(const Key: TAesBlock; const Input: TAesBlock; out Output: TAesBlock);
var
  RK: TRoundKeys;
begin
  ExpandKey(Key, RK);
  EncryptWithRoundKeys(RK, Input, Output);
end;

var
  GDefaultKeys: TRoundKeys;

function AesCtrDefault(const Data, Nonce: TBytes): TBytes;
var
  Counter, Stream: TAesBlock;
  I, J: Integer;
begin
  SetLength(Result, Length(Data));
  Move(Nonce[0], Counter[0], 16);
  I := 0;
  while I < Length(Data) do
  begin
    EncryptWithRoundKeys(GDefaultKeys, Counter, Stream);
    for J := 0 to 15 do
      if I + J < Length(Data) then
        Result[I + J] := Data[I + J] xor Stream[J];
    Inc(I, 16);
    for J := 15 downto 0 do            // big-endian counter increment
    begin
      Inc(Counter[J]);
      if Counter[J] <> 0 then
        Break;
    end;
  end;
end;

// Cheap sanity check that the result is a Data protobuf: first field must be
// portnum (tag 0x08) with a small value, then a length-delimited payload.
function LooksLikeData(const P: TBytes): Boolean;
begin
  Result := (Length(P) >= 2) and (P[0] = $08) and (P[1] > 0) and (P[1] < $80);
end;

function DecryptDefaultChannel(const Enc: TBytes; PacketId, FromNode: Cardinal;
  out Plain: TBytes): Boolean;
var
  Nonce: TBytes;
begin
  Plain := nil;
  Result := False;
  if Length(Enc) = 0 then
    Exit;
  SetLength(Nonce, 16);
  FillChar(Nonce[0], 16, 0);
  Move(PacketId, Nonce[0], 4);         // uint64 LE (high half zero)
  Move(FromNode, Nonce[8], 4);         // uint32 LE
  Plain := AesCtrDefault(Enc, Nonce);
  Result := LooksLikeData(Plain);
end;

function SecureRandomBytes(N: Integer): TBytes;
{$IFDEF MSWINDOWS}
const
  BCRYPT_USE_SYSTEM_PREFERRED_RNG = 2;
begin
  SetLength(Result, N);
  if (N > 0) and (BCryptGenRandom(nil, @Result[0], N, BCRYPT_USE_SYSTEM_PREFERRED_RNG) <> 0) then
    raise Exception.Create('Windows could not generate a random key');
end;
{$ELSE}
var
  F: TFileStream;
begin
  SetLength(Result, N);
  if N = 0 then
    Exit;
  F := TFileStream.Create('/dev/urandom', fmOpenRead or fmShareDenyNone);
  try
    if F.Read(Result[0], N) <> N then
      raise Exception.Create('Could not generate a random key');
  finally
    F.Free;
  end;
end;
{$ENDIF}

initialization
  ExpandKey(DEFAULT_KEY, GDefaultKeys);

end.
