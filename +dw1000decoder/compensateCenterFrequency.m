function rx = compensateCenterFrequency(rx, params)
%COMPENSATECENTERFREQUENCY Move the DW1000 carrier to complex-baseband DC.
frequency_shift = params.x410_center_frequency-params.dw1000_center_frequency;
n = params.sample_offset+(0:length(rx)-1).';
rx = rx.*exp(1j*2*pi*frequency_shift*n/params.fs_rx);
rx = rx/(sqrt(mean(abs(rx).^2))+eps);
if isfield(params, 'verbose') && params.verbose
    fprintf(['Coarse center-frequency compensation: %+0.3f MHz ', ...
        '(%.1f -> %.1f MHz).\n'], frequency_shift/1e6, ...
        params.dw1000_center_frequency/1e6, params.x410_center_frequency/1e6);
end
end

