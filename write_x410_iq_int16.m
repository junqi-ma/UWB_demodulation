function scale = write_x410_iq_int16(file_name, waveform)
%WRITE_X410_IQ_INT16 Write one-channel interleaved I/Q int16 samples.
%   File layout is I0,Q0,I1,Q1,... and matches read_x410.m.

arguments
    file_name (1,:) char
    waveform (:,1) {mustBeNumeric}
end

waveform = waveform(:);
peak = max(abs([real(waveform); imag(waveform)]));
if peak > 1
    scale = 32767/peak;
else
    scale = 32767;
end
iq = zeros(2, numel(waveform), 'int16');
iq(1, :) = int16(round(real(waveform)*scale));
iq(2, :) = int16(round(imag(waveform)*scale));

fid = fopen(file_name, 'wb', 'ieee-le');
if fid < 0
    error('write_x410_iq_int16:OpenFailed', ...
        'Cannot open output file: %s', file_name);
end
cleanup = onCleanup(@() fclose(fid));
count = fwrite(fid, iq, 'int16');
if count ~= numel(iq)
    error('write_x410_iq_int16:ShortWrite', ...
        'Only %d of %d int16 values were written.', count, numel(iq));
end
clear cleanup;
end
