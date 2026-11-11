program fedit;
{ fedit - format-preserving text patcher.

  Applies literal search/replace blocks to text files while keeping their
  encoding (UTF-8 with/without BOM, Windows-1252), line endings (LF/CRLF)
  and final-newline state untouched. All edits are checked in memory first;
  nothing is written unless every block matched the expected number of times.

  Usage:
    fedit info FILE...
    fedit cat [-n] FILE [A-B]
    fedit apply [--dry-run] [--check "COMMAND (braces = file)"] PATCHFILE|-
    fedit help

  Patch file format (UTF-8, no escaping needed):
    @@@ path/to/file
    <<<<
    text to find (one or more lines)
    ====
    replacement text (zero or more lines)
    >>>>
    <<<< x2          <- optional: expected number of occurrences (default 1)
    ...
}

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, StrUtils;

type
  { Detected on-disk format of a text file. }
  TFileFormat = record
    HasBom: Boolean;
    IsCp1252: Boolean;
    IsCrlf: Boolean;
    EndsWithEol: Boolean;
  end;

  { One search/replace block of a patch. }
  TBlock = record
    OldText: RawByteString;
    NewText: RawByteString;
    Expected: Integer;
    Line: Integer;
  end;

  { All blocks targeting one file. }
  TFilePatch = record
    Path: string;
    Blocks: array of TBlock;
  end;

  TFilePatchArray = array of TFilePatch;

const
  { Windows-1252 code points for bytes $80..$9F (0 = undefined). }
  Cp1252High: array[0..31] of Word = (
    $20AC, 0, $201A, $0192, $201E, $2026, $2020, $2021,
    $02C6, $2030, $0160, $2039, $0152, 0, $017D, 0,
    0, $2018, $2019, $201C, $201D, $2022, $2013, $2014,
    $02DC, $2122, $0161, $203A, $0153, 0, $017E, $0178);

{ Prints an error on stderr and stops with exit code 2. }
procedure Fail(const Msg: string);
begin
  WriteLn(StdErr, 'fedit: ', Msg);
  Halt(2);
end;

{ On Windows, turns POSIX-style drive paths (/c/dir, /mnt/c/dir, /cygdrive/c/dir) into C:\dir. }
function ResolvePath(const Path: string): string;
var
  Prefix: string;
  Rest: string;
begin
  Result := Path;
  {$IFDEF MSWINDOWS}
  Prefix := '';
  if Copy(Path, 1, 5) = '/mnt/' then
    Prefix := '/mnt'
  else if Copy(Path, 1, 10) = '/cygdrive/' then
    Prefix := '/cygdrive';
  Rest := Copy(Path, Length(Prefix) + 1, Length(Path));
  if (Length(Rest) >= 2) and (Rest[1] = '/') and (UpCase(Rest[2]) in ['A'..'Z'])
    and ((Length(Rest) = 2) or (Rest[3] = '/')) then
    Result := UpCase(Rest[2]) + ':' + StringReplace(Copy(Rest, 3, Length(Rest)), '/', '\', [rfReplaceAll]);
  {$ENDIF}
end;

{ Reads a whole file as raw bytes. }
function ReadAllBytes(const PathArg: string): RawByteString;
var
  Stream: TFileStream;
  Path: string;
begin
  Result := '';
  Path := ResolvePath(PathArg);
  if not FileExists(Path) then
    Fail('file not found: ' + Path);
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[1], Stream.Size);
  finally
    Stream.Free;
  end;
end;

{ Reads all of standard input as raw bytes. }
function ReadStdin: RawByteString;
var
  Stream: THandleStream;
  Buffer: array[0..4095] of Byte;
  Got: Integer;
  Chunk: RawByteString;
begin
  Result := '';
  Stream := THandleStream.Create(StdInputHandle);
  try
    repeat
      Got := Stream.Read(Buffer, SizeOf(Buffer));
      if Got > 0 then
      begin
        SetLength(Chunk, Got);
        Move(Buffer[0], Chunk[1], Got);
        Result := Result + Chunk;
      end;
    until Got <= 0;
  finally
    Stream.Free;
  end;
end;

{ Writes raw bytes to a file, replacing its content. }
procedure WriteAllBytes(const Path: string; const Data: RawByteString);
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(Path, fmCreate);
  try
    if Length(Data) > 0 then
      Stream.WriteBuffer(Data[1], Length(Data));
  finally
    Stream.Free;
  end;
end;

{ True when S is well-formed UTF-8 (pure ASCII included). }
function IsValidUtf8(const S: RawByteString): Boolean;
var
  I, N, Extra, K: Integer;
  B: Byte;
begin
  Result := True;
  I := 1;
  N := Length(S);
  while I <= N do
  begin
    B := Ord(S[I]);
    if B < $80 then
      Extra := 0
    else if (B and $E0) = $C0 then
      Extra := 1
    else if (B and $F0) = $E0 then
      Extra := 2
    else if (B and $F8) = $F0 then
      Extra := 3
    else
      Exit(False);
    if I + Extra > N then
      Exit(False);
    for K := 1 to Extra do
      if (Ord(S[I + K]) and $C0) <> $80 then
        Exit(False);
    Inc(I, Extra + 1);
  end;
end;

{ Maps a Unicode code point to its Windows-1252 byte, or -1 if none. }
function CodePointToCp1252(CodePoint: Cardinal): Integer;
var
  I: Integer;
begin
  if (CodePoint < $80) or ((CodePoint >= $A0) and (CodePoint <= $FF)) then
    Exit(Integer(CodePoint));
  for I := 0 to 31 do
    if (Cp1252High[I] <> 0) and (Cp1252High[I] = CodePoint) then
      Exit($80 + I);
  Result := -1;
end;

{ Converts valid UTF-8 text to Windows-1252; False if a character has no mapping. }
function Utf8ToCp1252(const S: RawByteString; out Res: RawByteString): Boolean;
var
  I, N, Extra, K, Mapped, Count: Integer;
  B: Byte;
  CodePoint: Cardinal;
begin
  Result := True;
  N := Length(S);
  SetLength(Res, N);
  Count := 0;
  I := 1;
  while I <= N do
  begin
    B := Ord(S[I]);
    if B < $80 then
    begin
      CodePoint := B;
      Extra := 0;
    end
    else if (B and $E0) = $C0 then
    begin
      CodePoint := B and $1F;
      Extra := 1;
    end
    else if (B and $F0) = $E0 then
    begin
      CodePoint := B and $0F;
      Extra := 2;
    end
    else
    begin
      CodePoint := B and $07;
      Extra := 3;
    end;
    for K := 1 to Extra do
      CodePoint := (CodePoint shl 6) or (Ord(S[I + K]) and $3F);
    Inc(I, Extra + 1);
    Mapped := CodePointToCp1252(CodePoint);
    if Mapped < 0 then
      Exit(False);
    Inc(Count);
    Res[Count] := Chr(Mapped);
  end;
  SetLength(Res, Count);
end;

{ Converts Windows-1252 bytes to UTF-8 (undefined bytes become '?'). }
function Cp1252ToUtf8(const S: RawByteString): RawByteString;
var
  I: Integer;
  B: Byte;
  CodePoint: Cardinal;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    B := Ord(S[I]);
    if (B >= $80) and (B <= $9F) then
      CodePoint := Cp1252High[B - $80]
    else
      CodePoint := B;
    if CodePoint = 0 then
      CodePoint := Ord('?');
    if CodePoint < $80 then
      Result := Result + Chr(CodePoint)
    else if CodePoint < $800 then
      Result := Result + Chr($C0 or (CodePoint shr 6)) + Chr($80 or (CodePoint and $3F))
    else
      Result := Result + Chr($E0 or (CodePoint shr 12))
        + Chr($80 or ((CodePoint shr 6) and $3F)) + Chr($80 or (CodePoint and $3F));
  end;
end;

{ Detects BOM, encoding and line endings of Raw; Body is Raw without BOM. }
procedure DetectFormat(const Raw: RawByteString; out Fmt: TFileFormat; out Body: RawByteString);
var
  I, CrLfCount, LfCount: Integer;
begin
  Fmt.HasBom := (Length(Raw) >= 3) and (Raw[1] = #$EF) and (Raw[2] = #$BB) and (Raw[3] = #$BF);
  if Fmt.HasBom then
    Body := Copy(Raw, 4, Length(Raw) - 3)
  else
    Body := Raw;
  Fmt.IsCp1252 := not IsValidUtf8(Body);
  CrLfCount := 0;
  LfCount := 0;
  for I := 1 to Length(Body) do
  begin
    if Body[I] = #10 then
    begin
      if (I > 1) and (Body[I - 1] = #13) then
        Inc(CrLfCount)
      else
        Inc(LfCount);
    end
    else if (Body[I] = #13) and ((I = Length(Body)) or (Body[I + 1] <> #10)) then
      Fail('lone CR found; mixed line endings are not supported');
  end;
  if (CrLfCount > 0) and (LfCount > 0) then
    Fail(Format('mixed line endings (%d CRLF, %d LF); not supported', [CrLfCount, LfCount]));
  Fmt.IsCrlf := CrLfCount > 0;
  Fmt.EndsWithEol := (Length(Body) > 0) and (Body[Length(Body)] = #10);
end;

{ Human-readable description of a file format. }
function FormatName(const Fmt: TFileFormat): string;
begin
  if Fmt.IsCp1252 then
    Result := 'cp1252'
  else
    Result := 'utf-8';
  if Fmt.HasBom then
    Result := Result + '+BOM';
  if Fmt.IsCrlf then
    Result := Result + ' CRLF'
  else
    Result := Result + ' LF';
  if not Fmt.EndsWithEol then
    Result := Result + ' no-final-newline';
end;

{ Number of non-overlapping occurrences of Sub in S. }
function CountOccurrences(const S, Sub: RawByteString): Integer;
var
  P: Integer;
begin
  Result := 0;
  P := PosEx(Sub, S, 1);
  while P > 0 do
  begin
    Inc(Result);
    P := PosEx(Sub, S, P + Length(Sub));
  end;
end;

{ Literal replace of every occurrence of OldText by NewText (no escapes). }
function ReplaceAll(const S, OldText, NewText: RawByteString): RawByteString;
var
  P, From: Integer;
begin
  Result := '';
  From := 1;
  P := PosEx(OldText, S, From);
  while P > 0 do
  begin
    Result := Result + Copy(S, From, P - From) + NewText;
    From := P + Length(OldText);
    P := PosEx(OldText, S, From);
  end;
  Result := Result + Copy(S, From, Length(S) - From + 1);
end;

{ Joins lines with LF (no trailing LF). }
function JoinLines(Lines: TStringList): RawByteString;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to Lines.Count - 1 do
  begin
    if I > 0 then
      Result := Result + #10;
    Result := Result + Lines[I];
  end;
end;

{ Parses the patch text into per-file block lists. }
function ParsePatch(const PatchText: RawByteString): TFilePatchArray;
var
  Lines: TStringList;
  Buffer: RawByteString;
  I, State, BlockCount, FileCount: Integer;
  Line, Rest: string;
  Collected: TStringList;
  Current: TBlock;
  HaveFile: Boolean;
begin
  Result := nil;
  FileCount := 0;
  HaveFile := False;
  State := 0; { 0 = between blocks, 1 = in OLD, 2 = in NEW }
  Buffer := PatchText;
  if (Length(Buffer) >= 3) and (Buffer[1] = #$EF) and (Buffer[2] = #$BB) and (Buffer[3] = #$BF) then
    Buffer := Copy(Buffer, 4, Length(Buffer) - 3);
  if not IsValidUtf8(Buffer) then
    Fail('patch file is not valid UTF-8');
  Lines := TStringList.Create;
  Collected := TStringList.Create;
  try
    Lines.LineBreak := #10;
    Lines.Text := Buffer;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      if (Length(Line) > 0) and (Line[Length(Line)] = #13) then
        SetLength(Line, Length(Line) - 1);
      if State = 0 then
      begin
        if Copy(Line, 1, 4) = '@@@ ' then
        begin
          Inc(FileCount);
          SetLength(Result, FileCount);
          Result[FileCount - 1].Path := ResolvePath(Trim(Copy(Line, 5, Length(Line))));
          HaveFile := True;
        end
        else if Copy(Line, 1, 4) = '<<<<' then
        begin
          if not HaveFile then
            Fail(Format('patch line %d: block before any "@@@ file" header', [I + 1]));
          Rest := Trim(Copy(Line, 5, Length(Line)));
          Current.Expected := 1;
          Current.Line := I + 1;
          if Rest <> '' then
          begin
            if Rest[1] in ['x', 'X'] then
              Delete(Rest, 1, 1);
            Current.Expected := StrToIntDef(Rest, -1);
            if Current.Expected < 1 then
              Fail(Format('patch line %d: bad count "%s"', [I + 1, Rest]));
          end;
          Collected.Clear;
          State := 1;
        end
        else if (Trim(Line) <> '') and (Line[1] <> '#') then
          Fail(Format('patch line %d: unexpected text outside a block', [I + 1]));
      end
      else if State = 1 then
      begin
        if Line = '====' then
        begin
          Current.OldText := JoinLines(Collected);
          Collected.Clear;
          State := 2;
        end
        else
          Collected.Add(Line);
      end
      else
      begin
        if Line = '>>>>' then
        begin
          Current.NewText := JoinLines(Collected);
          if Current.OldText = '' then
            Fail(Format('patch line %d: empty search text', [Current.Line]));
          BlockCount := Length(Result[FileCount - 1].Blocks);
          SetLength(Result[FileCount - 1].Blocks, BlockCount + 1);
          Result[FileCount - 1].Blocks[BlockCount] := Current;
          State := 0;
        end
        else
          Collected.Add(Line);
      end;
    end;
    if State <> 0 then
      Fail('patch ends inside an unterminated block');
  finally
    Lines.Free;
    Collected.Free;
  end;
end;

{ Rebuilds on-disk bytes from LF-normalised text and the original format. }
function Rebuild(const Fmt: TFileFormat; const Text: RawByteString): RawByteString;
begin
  if Fmt.IsCrlf then
    Result := ReplaceAll(Text, #10, #13#10)
  else
    Result := Text;
  if Fmt.HasBom then
    Result := #$EF#$BB#$BF + Result;
end;

{ Counts lines removed/added in the region that differs (common head/tail trimmed). }
procedure ChangedLines(const OldText, NewText: RawByteString; out Removed, Added: Integer);
var
  A, B: TStringList;
  Head, Tail: Integer;
begin
  A := TStringList.Create;
  B := TStringList.Create;
  try
    A.LineBreak := #10;
    B.LineBreak := #10;
    A.Text := OldText;
    B.Text := NewText;
    Head := 0;
    while (Head < A.Count) and (Head < B.Count) and (A[Head] = B[Head]) do
      Inc(Head);
    Tail := 0;
    while (Tail < A.Count - Head) and (Tail < B.Count - Head)
      and (A[A.Count - 1 - Tail] = B[B.Count - 1 - Tail]) do
      Inc(Tail);
    Removed := A.Count - Head - Tail;
    Added := B.Count - Head - Tail;
  finally
    A.Free;
    B.Free;
  end;
end;

{ Runs a shell command; returns its exit code. }
function RunShell(const CommandLine: string): Integer;
begin
  {$IFDEF MSWINDOWS}
  Result := ExecuteProcess(GetEnvironmentVariable('COMSPEC'), '/c "' + CommandLine + '"');
  {$ELSE}
  Result := ExecuteProcess('/bin/sh', ['-c', CommandLine]);
  {$ENDIF}
end;

{ Prints the format of each given file. }
procedure CmdInfo;
var
  I: Integer;
  Raw, Body: RawByteString;
  Fmt: TFileFormat;
begin
  if ParamCount < 2 then
    Fail('info: no file given');
  for I := 2 to ParamCount do
  begin
    Raw := ReadAllBytes(ParamStr(I));
    DetectFormat(Raw, Fmt, Body);
    WriteLn(ParamStr(I), ': ', FormatName(Fmt));
  end;
end;

{ Parses a line range "A-B", "A-", "-B" or "A" into 1-based bounds (High = open end). }
procedure ParseRange(const Spec: string; out First, Last: Integer);
var
  Dash: Integer;
begin
  First := 1;
  Last := MaxInt;
  Dash := Pos('-', Spec);
  if Dash = 0 then
  begin
    First := StrToIntDef(Spec, -1);
    Last := First;
  end
  else
  begin
    if Dash > 1 then
      First := StrToIntDef(Copy(Spec, 1, Dash - 1), -1);
    if Dash < Length(Spec) then
      Last := StrToIntDef(Copy(Spec, Dash + 1, Length(Spec)), -1);
  end;
  if (First < 1) or (Last < First) then
    Fail('bad line range: ' + Spec);
end;

{ Prints a file as UTF-8 with LF endings and no BOM; the format goes to stderr. }
procedure CmdCat;
var
  First, Last, ArgIndex, LineNumber, Start, Stop: Integer;
  ShowNumbers: Boolean;
  Path, RangeSpec: string;
  Raw, Body, Output: RawByteString;
  Fmt: TFileFormat;
  Stream: THandleStream;
begin
  ShowNumbers := False;
  Path := '';
  RangeSpec := '';
  for ArgIndex := 2 to ParamCount do
  begin
    if ParamStr(ArgIndex) = '-n' then
      ShowNumbers := True
    else if Path = '' then
      Path := ParamStr(ArgIndex)
    else
      RangeSpec := ParamStr(ArgIndex);
  end;
  if Path = '' then
    Fail('cat: no file given');
  First := 1;
  Last := MaxInt;
  if RangeSpec <> '' then
    ParseRange(RangeSpec, First, Last);
  Raw := ReadAllBytes(Path);
  DetectFormat(Raw, Fmt, Body);
  Body := ReplaceAll(Body, #13#10, #10);
  if Fmt.IsCp1252 then
    Body := Cp1252ToUtf8(Body);
  WriteLn(StdErr, '# ', FormatName(Fmt));
  Output := '';
  LineNumber := 1;
  Start := 1;
  while (Start <= Length(Body)) and (LineNumber <= Last) do
  begin
    Stop := PosEx(#10, Body, Start);
    if Stop = 0 then
      Stop := Length(Body) + 1;
    if LineNumber >= First then
    begin
      if ShowNumbers then
        Output := Output + IntToStr(LineNumber) + #9;
      Output := Output + Copy(Body, Start, Stop - Start) + #10;
    end;
    Inc(LineNumber);
    Start := Stop + 1;
  end;
  if Length(Output) > 0 then
  begin
    Stream := THandleStream.Create(StdOutputHandle);
    try
      Stream.WriteBuffer(Output[1], Length(Output));
    finally
      Stream.Free;
    end;
  end;
end;

{ Applies a patch file: all-or-nothing, format preserving. }
procedure CmdApply;
var
  I, J, K, ArgIndex: Integer;
  DryRun: Boolean;
  CheckCmd, PatchPath: string;
  PatchText, Raw, Body, OldText, NewText, Original: RawByteString;
  Patches: TFilePatchArray;
  Fmt: TFileFormat;
  Found, Removed, Added: Integer;
  Outputs: array of RawByteString;
  Failed: Boolean;
begin
  DryRun := False;
  CheckCmd := '';
  PatchPath := '';
  ArgIndex := 2;
  while ArgIndex <= ParamCount do
  begin
    if ParamStr(ArgIndex) = '--dry-run' then
      DryRun := True
    else if ParamStr(ArgIndex) = '--check' then
    begin
      Inc(ArgIndex);
      if ArgIndex > ParamCount then
        Fail('--check needs a command');
      CheckCmd := ParamStr(ArgIndex);
    end
    else
      PatchPath := ParamStr(ArgIndex);
    Inc(ArgIndex);
  end;
  if PatchPath = '' then
    Fail('apply: no patch file given');
  if PatchPath = '-' then
    PatchText := ReadStdin
  else
    PatchText := ReadAllBytes(PatchPath);
  Patches := ParsePatch(PatchText);
  if Length(Patches) = 0 then
    Fail('patch contains no file section');

  SetLength(Outputs, Length(Patches));
  Failed := False;
  for I := 0 to High(Patches) do
  begin
    Raw := ReadAllBytes(Patches[I].Path);
    DetectFormat(Raw, Fmt, Body);
    Original := ReplaceAll(Body, #13#10, #10);
    Body := Original;
    for J := 0 to High(Patches[I].Blocks) do
    begin
      OldText := Patches[I].Blocks[J].OldText;
      NewText := Patches[I].Blocks[J].NewText;
      if Fmt.IsCp1252 then
      begin
        if not Utf8ToCp1252(Patches[I].Blocks[J].OldText, OldText)
          or not Utf8ToCp1252(Patches[I].Blocks[J].NewText, NewText) then
        begin
          WriteLn(StdErr, Format('%s: block at patch line %d has a character not representable in cp1252',
            [Patches[I].Path, Patches[I].Blocks[J].Line]));
          Failed := True;
          Continue;
        end;
      end;
      Found := CountOccurrences(Body, OldText);
      if Found <> Patches[I].Blocks[J].Expected then
      begin
        WriteLn(StdErr, Format('%s: block at patch line %d found %d time(s), expected %d',
          [Patches[I].Path, Patches[I].Blocks[J].Line, Found, Patches[I].Blocks[J].Expected]));
        Failed := True;
        Continue;
      end;
      Body := ReplaceAll(Body, OldText, NewText);
    end;
    Outputs[I] := Rebuild(Fmt, Body);
    ChangedLines(Original, Body, Removed, Added);
    WriteLn(Format('%s [%s]: %d block(s), -%d/+%d lines',
      [Patches[I].Path, FormatName(Fmt), Length(Patches[I].Blocks), Removed, Added]));
  end;
  if Failed then
  begin
    WriteLn(StdErr, 'fedit: nothing written');
    Halt(2);
  end;
  if DryRun then
  begin
    WriteLn('dry run: nothing written');
    Exit;
  end;
  for I := 0 to High(Patches) do
    WriteAllBytes(Patches[I].Path, Outputs[I]);
  WriteLn('written.');
  if CheckCmd <> '' then
    for I := 0 to High(Patches) do
    begin
      K := RunShell(StringReplace(CheckCmd, '{}', '"' + Patches[I].Path + '"', [rfReplaceAll]));
      if K <> 0 then
      begin
        WriteLn(StdErr, Format('fedit: check failed (exit %d) for %s', [K, Patches[I].Path]));
        Halt(3);
      end;
    end;
  if CheckCmd <> '' then
    WriteLn('check ok.');
end;

{ Prints usage. }
procedure CmdHelp;
begin
  WriteLn('fedit - format-preserving text patcher');
  WriteLn('  fedit info FILE...');
  WriteLn('  fedit cat [-n] FILE [A-B]     (prints as UTF-8, LF, no BOM)');
  WriteLn('  fedit apply [--dry-run] [--check "CMD {}"] PATCHFILE|-');
  WriteLn;
  WriteLn('Patch file (UTF-8, no escaping):');
  WriteLn('  @@@ path/to/file');
  WriteLn('  <<<<            (or "<<<< x2" to expect 2 occurrences)');
  WriteLn('  text to find');
  WriteLn('  ====');
  WriteLn('  replacement');
  WriteLn('  >>>>');
  WriteLn('Preserves BOM, UTF-8/cp1252, LF/CRLF. All-or-nothing.');
end;

begin
  if ParamCount < 1 then
  begin
    CmdHelp;
    Halt(1);
  end;
  case LowerCase(ParamStr(1)) of
    'info': CmdInfo;
    'cat': CmdCat;
    'apply': CmdApply;
    'help', '--help', '-h': CmdHelp;
  else
    Fail('unknown command: ' + ParamStr(1));
  end;
end.
