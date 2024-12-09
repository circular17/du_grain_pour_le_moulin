program stegano;

uses
  SysUtils;

var
  path: string;
  Data: packed array of byte;

  function readInt32(var f: file): int32;
  begin
    blockread(f, Result, sizeof(Result));
    Result := LEtoN(Result);
  end;

  procedure loadData;
  var
    f: file;
    startOfs, Width, Height: int32;
  begin
    writeln('Opening Bitmap...');
    assignfile(f, path + 'lmd-defi-stegano.bmp');
    reset(f, 1);
    writeln('Getting info...');
    seek(f, 10);
    startOfs := readInt32(f);
    seek(f, 18);
    Width := readInt32(f);
    Height := readInt32(f);
    seek(f, startOfs);
    writeln('Reading data...');
    setlength(Data, Width * Height * 3);
    blockread(f, Data[0], length(Data));
    closefile(f);
  end;

  procedure decodeData;
  var
    t: textfile;
    i: int32;
    ofs: int32;
    b: byte;
  begin
    writeln('Creating output...');
    assignfile(t, path + 'decode.txt');
    rewrite(t);
    ofs := 0;
    writeln('Decoding...');
    for i := 0 to (length(Data) div 4) - 1 do
    begin
      b := Data[ofs] and 3 + Data[ofs + 1] and 3 shl 2 + Data[ofs + 2] and
        3 shl 4 + Data[ofs + 3] and 3 shl 6;
      if b < 32 then break;
      Write(t, chr(b));
      Inc(ofs, 4);
    end;
    closefile(t);
  end;

begin
  path := ExtractFilePath(ParamStr(0));
  loadData;
  decodeData;
  writeln('Done.');
end.
