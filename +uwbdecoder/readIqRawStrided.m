function [raw, sampleIndices] = readIqRawStrided( ...
        fileName, sampleOffset, sampleNum, antNum, stride, outputClass)
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
%   OUTPUTCLASS can be 'double' (default) or 'single'. The mapped int16
%   vector is reshaped by complete multi-antenna records,
%   so the stride is applied between samples, not between I and Q values.
%
%   See also READIQRAW, SELECTIQCHANNEL.

if nargin < 6
    outputClass = 'double';
end
outputClass = validatestring(outputClass, {'double', 'single'}, ...
    mfilename, 'outputClass');

mustBeTextScalar(fileName);
validateattributes(sampleOffset, {'double'}, ...
    {'scalar', 'integer', 'nonnegative'}, mfilename, 'sampleOffset');
validateattributes(sampleNum, {'double'}, ...
    {'scalar', 'integer', 'positive'}, mfilename, 'sampleNum');
validateattributes(antNum, {'double'}, ...
    {'scalar', 'integer', 'positive'}, mfilename, 'antNum');
validateattributes(stride, {'double'}, ...
    {'scalar', 'integer', 'positive'}, mfilename, 'stride');

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

precision = sprintf('%d*int16=>%s', recordValueCount, outputClass);
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
