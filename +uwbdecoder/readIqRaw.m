function raw = readIqRaw(fileName, sampleOffset, sampleNum, antNum)
%READIQRAW Read interleaved int16 IQ from a capture file.
%   RAW = READIQRAW(FILENAME, SAMPLEOFFSET, SAMPLENUM, ANTNUM) opens
%   FILENAME, seeks to the given complex-sample offset, and reads
%   SAMPLENUM interleaved int16 I/Q samples for ANTNUM antenna channels.
%   RAW is a (2*ANTNUM)-by-SAMPLENUM matrix. The file is closed on
%   return (even on error) via onCleanup.
%
%   See also SELECTIQCHANNEL, READIQRAWSTRIDED.

c = uwbdecoder.constants();

fid = fopen(fileName, 'rb', 'ieee-le');
if fid < 0
    error('readIqRaw:FileOpenError', ...
        'Cannot open capture: %s', fileName);
end
fileGuard = onCleanup(@() fclose(fid));

status = fseek(fid, sampleOffset*c.BYTES_PER_IQ_SAMPLE*antNum, 'bof');
if status ~= 0
    error('readIqRaw:SeekError', ...
        'Failed to seek to sample offset %d.', sampleOffset);
end

raw = fread(fid, [2*antNum, sampleNum], 'int16=>double');
if size(raw, 2) ~= sampleNum
    error('readIqRaw:ShortRead', ...
        'Could not read %d samples at offset %d.', sampleNum, sampleOffset);
end

clear fileGuard;
end
