function scale = write_x410_iq_int16(fileName, waveform)
%WRITE_X410_IQ_INT16 Write one-channel interleaved I/Q int16 samples.
%   SCALE = WRITE_X410_IQ_INT16(FILENAME, WAVEFORM) writes the complex
%   column vector WAVEFORM to FILENAME as interleaved int16 I/Q samples
%   (I0,Q0,I1,Q1,...), compatible with read_x410.m. The output is scaled
%   so the peak magnitude maps to 32767; the applied scale factor is
%   returned.
%
%   See also READ_X410.

arguments
    fileName (1,:) char
    waveform (:,1) {mustBeNumeric}
end

c = uwbdecoder.constants();

waveform = waveform(:);
peak = max(abs([real(waveform); imag(waveform)]));
if peak > 1
    scale = c.INT16_MAX / peak;
else
    scale = c.INT16_MAX;
end

iq = zeros(2, numel(waveform), 'int16');
iq(1, :) = int16(round(real(waveform)*scale));
iq(2, :) = int16(round(imag(waveform)*scale));

fid = fopen(fileName, 'wb', 'ieee-le');
if fid < 0
    error('write_x410_iq_int16:OpenFailed', ...
        'Cannot open output file: %s', fileName);
end
fileGuard = onCleanup(@() fclose(fid));

count = fwrite(fid, iq, 'int16');
if count ~= numel(iq)
    error('write_x410_iq_int16:ShortWrite', ...
        'Only %d of %d int16 values were written.', count, numel(iq));
end
clear fileGuard;
end
