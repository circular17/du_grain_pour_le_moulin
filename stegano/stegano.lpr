program stegano;
uses SysUtils;
var
  path: string;
  data: packed array of byte;

  function readInt32(var f: file): int32;
  begin
    blockread(f, result, sizeof(result));
    result := LEtoN(result);
  end;

  procedure loadData;
  var
    f: file;
    startOfs, width, height: int32;
  begin
    writeln('Opening Bitmap...');
    assignfile(f, path+'lmd-defi-stegano.bmp');
    reset(f, 1);
    writeln('Getting info...');
    seek(f, 10);
    startOfs := readInt32(f);
    seek(f, 18);
    width := readInt32(f);
    height := readInt32(f);
    seek(f, startOfs);
    writeln('Reading data...');
    setlength(data, width*height*3);
    blockread(f, data[0], length(data));
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
    assignfile(t, path+'decode.txt');
    rewrite(t);
    ofs := 0;
    writeln('Decoding...');
    for i := 0 to (length(data) div 4)-1 do
    begin
      b := data[ofs] and 3 + data[ofs+1] and 3 shl 2
       + data[ofs+2] and 3 shl 4 + data[ofs+3] and 3 shl 6;
      if b < 32 then break;
      write(t, chr(b));
      inc(ofs, 4);
    end;
    closefile(t);
  end;

begin
  path := ExtractFilePath(ParamStr(0));
  loadData;
  decodeData;
  writeln('Done.');
end.

