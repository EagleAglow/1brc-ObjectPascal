﻿unit OneBRC;

interface

uses
  System.Classes, System.SysUtils, System.Generics.Collections,
  mormot.core.os,
  Utils;


const
  cNumStations: Integer = 45000;

type
  // record is packed to minimize its size
  // use pointers to avoid passing entire records around
  TStationData = packed record
    Min: SmallInt;
    Max: SmallInt;
    Count: UInt32;
    Sum: Integer;
  end;
  PStationData = ^TStationData;

  TOneBRC = class
  private
    // mormot memory map for fast bytes read.
    // I tried using CreateFileMapping and failed, more details in unit FileReader
    FMemoryMap: TMemoryMap;
    FData: pAnsiChar;
    FDataSize: Int64;

    FStationsDict: TDictionary<AnsiString, PStationData>;

    // pre-allocate space for N records at once (why can't I use a const in here??)
    FRecords: array[0..45000] of TStationData;

    procedure ExtractLineData(const aStart: Int64; const aEnd: Int64; var aStation, aTempStr: AnsiString); inline;

  public
    constructor Create;
    function mORMotMMF (const afilename: string): Boolean;
    procedure SingleThread;
    procedure GenerateOutput;
  end;


implementation

uses System.AnsiStrings,
     System.Generics.Defaults;

//---------------------------------------------------
{ TProcesser }

procedure TOneBRC.ExtractLineData(const aStart: Int64; const aEnd: Int64; var aStation, aTempStr: AnsiString);
// given a line of data, extract the station name and temperature, as strings.
var
  I: Int64;
begin
  // we're looking for the semicolon ';', but backwards since there's fewer characters to traverse
  // a thermo measurement must be at least 3 characters long (one decimal, one period, and the units)
  // e.g. input: Rock Hill;-54.3
  // can safely skip 3:      ^^^
  I := aEnd-3;

  while True do begin
    if FData[I] = ';' then
      break;
    Dec(I);
  end;

  // I is the position of the semi-colon, extract what's before and after it
  SetString(aStation, pAnsiChar(@FData[aStart]), i-aStart);
  SetString(aTempStr, pAnsiChar(@FData[i+1])   , aEnd-i);
end;

//---------------------------------------------------

procedure DoTempsDict (var aDict: TDictionary<AnsiString, SmallInt>; var aStrVal: AnsiString;
                       var aIntVal: SmallInt); inline;
// the parsed temperatures are as strings, we need them as smallInts.
// however, a few problems:
// - StrToInt is VERY expensive
// - Val is less expensive than StrToInt, but still very expensive
// solution:
// temperatures vary (between at most -100.0 and 100.0, that's 200*10=2000 possible different readings,
// regardless if there are 100M or 1B lines.
// practically in this input file, there are 1998 readings exactly:
// convert each one once, and store the resulting smallInt in a dictionary
{TODO: thread-safety}
var vSuccess: Integer;
begin
  // replicate the last char, then drop it
  aStrVal[Length(aStrVal) - 1] := aStrVal[Length(aStrVal)];
  SetLength (aStrVal, Length(aStrVal) - 1);

  if not aDict.TryGetValue(aStrVal, aIntVal) then begin
    Val (aStrVal, aIntVal, vSuccess);
    if vSuccess <> 0 then
      raise Exception.Create('cannot decode value');
    aDict.Add (aStrVal, aIntVal);
  end;
end;

//---------------------------------------------------

constructor TOneBRC.Create;
begin
  FStationsDict := TDictionary<AnsiString, PStationData>.Create (45000);
end;

//---------------------------------------------------

function TOneBRC.mORMotMMF (const afilename: string): Boolean;
begin
  Result := FMemoryMap.Map (aFilename);
  if Result then begin
    FData     := FMemoryMap.Buffer;
    FDataSize := FMemoryMap.Size;
  end;
end;

//---------------------------------------------------

procedure TOneBRC.SingleThread;
var
  vTempDict: TDictionary<AnsiString, SmallInt>;
  i: Int64;
  vStation: AnsiString;
  vTempStr: AnsiString;
  vTemp: SmallInt;
  vData: PStationData;
  vLineStart: Int64;
  vRecIdx: Integer;
begin
  // expecting 1998 different temperature measurements
  vTempDict := TDictionary<AnsiString, SmallInt>.Create (2000);

  vLineStart := 0;
  i := 0;
  vRecIdx := 0;

  while i < FDataSize - 1 do begin
    if FData[i] = #13 then begin
      // new line parsed, process its contents
      ExtractLineData (vLineStart, i -1, vStation, vTempStr);
      DoTempsDict (vTempDict, vTempStr, vTemp);

      // next char is #10, so we can skip 2 instead of 1
      vLineStart := i+2;

      // pre-allocated array of records instead of on-the-go allocation
      if FStationsDict.TryGetValue (vStation, vData) then begin
        if vTemp < vData^.Min then
          vData^.Min := vTemp;
        if vTemp > vData^.Max then
          vData^.Max := vTemp;
        vData^.Sum := vData^.Sum + vTemp;
        Inc (vData^.Count);
      end
      else begin
        vData := @FRecords[vRecIdx];
        vData^.Min := vTemp;
        vData^.Max := vTemp;
        vData^.Sum := vTemp;
        vData^.Count := 1;
        FStationsDict.Add (vStation, vData);

        Inc (vRecIdx);
      end;
    end;

    Inc (i);
  end;
end;

//---------------------------------------------------

procedure TOneBRC.GenerateOutput;
var vMin, vMean, vMax: Double;
    vStream: TStringStream;
    I, N: Int64;
    vData: PStationData;
    iStation: AnsiString;
    vStations: TList<AnsiString>;
    vComparer: IComparer<AnsiString>;
begin
  vStream := TStringStream.Create;
  vStations := TList<AnsiString>.Create;
  vStations.Capacity := cNumStations;
  try
    vComparer := TDelegatedComparer<AnsiString>.Create(
      function (const aLeft, aRight: AnsiString): Integer
      begin
        // use System.AnsiStrings.CompareStr to match the hash,
        // otherwise some Unicode chars will be out-of-order
        Result := CompareStr (aLeft, aRight);
      end);

    for iStation in FStationsDict.Keys do begin
      vStations.Add (iStation);
    end;
    vStations.Sort (vComparer);

    I := 0;
    N := vStations.Count;

    vStream.WriteString('{');
    while I < N do begin
      FStationsDict.TryGetValue(vStations[i], vData);
      vMin := vData^.Min/10;
      vMax := vData^.Max/10;
      vMean := RoundExDouble(vData^.Sum/vData^.Count/10);

      vStream.WriteString(
        vStations[i] + '=' + FormatFloat('0.0', vMin)
                     + '/' + FormatFloat('0.0', vMean)
                     + '/' + FormatFloat('0.0', vMax) + ', '
      );
      Inc(I);
    end;

    vStream.SetSize(vStream.Size - 2);
    vStream.WriteString('}' + #10);
{$IFDEF DEBUG}
    vStream.SaveToFile('ghatem-out.txt');
{$ELSEIF defined(RELEASE)}
    WriteLn (vStream.DataString);
{$ENDIF}
  finally
    vStations.Free;
    vStream.Free;
  end;
end;

//---------------------------------------------------

end.
