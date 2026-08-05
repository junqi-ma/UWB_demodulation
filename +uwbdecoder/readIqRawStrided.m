function [raw, sampleIndices] = readIqRawStrided( ...
        fileName, sampleOffset, sampleNum, antNum, stride)
%READIQRAWSTRIDED Read every STRIDE-th interleaved IQ time sample.
%   [RAW, SAMPLEINDICES] = READIQRAWSTRIDED(FILENAME, SAMPLEOFFSET,
%   SAMPLENUM, ANTNUM, STRIDE) reads complete I/Q records at zero-based
%   capture indices
%
%       SAMPLEOFFSET, SAMPLEOFFSET + STRIDE, ...
%
%   while staying inside the SAMPLENUM-sample input interval. RAW is a
%   (2*ANTNUM)-by-N matrix and SAMPLEINDICES is an N-by-1 vector of
%   zero-based capture sample indices.
%
%   The mapped int16 vector is reshaped by complete multi-antenna records,
%   so the stride is applied between samples, not between I and Q values.
%
%   See also READIQRAW, SELECTIQCHANNEL.

arguments
    fileName {mustBeTextScalar}
    sampleOffset (1, 1) double {mustBeInteger, mustBeNonnegative}
    sampleNum (1, 1) double {mustBeInteger, mustBePositive}
    antNum (1, 1) double {mustBeInteger, mustBePositive}
    stride (1, 1) double {mustBeInteger, mustBePositive}
end

c = uwbdecoder.constants();
recordValueCount = 2*antNum;
recordBytes = c.BYTES_PER_IQ_SAMPLE*antNum;
outputCount = floor((sampleNum - 1)/stride) + 1;

fid = fopen(fileName, 'rb', 'ieee-le');
if fid < 0
    error('readIqRawStrided:FileOpenError', ...
        'Cannot open capture: %s', fileName);
end
fileGuard = onCleanup(@() fclose(fid));

status = fseek(fid, sampleOffset*recordBytes, 'bof');
if status ~= 0
    error('readIqRawStrided:SeekError', ...
        'Failed to seek to sample offset %d.', sampleOffset);
end

precision = sprintf('%d*int16=>double', recordValueCount);
skipBytes = (stride - 1)*recordBytes;
raw = fread(fid, [recordValueCount, outputCount], precision, skipBytes);
if size(raw, 2) ~= outputCount
    error('readIqRawStrided:ShortRead', ...
        ['Could not read %d strided samples at offset %d with ', ...
         'stride %d.'], outputCount, sampleOffset, stride);
end

sampleIndices = sampleOffset + (0:outputCount - 1).'*stride;
clear fileGuard;

end
