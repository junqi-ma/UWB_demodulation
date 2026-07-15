function result = decode_x410_dw1000(options)
%DECODE_X410_DW1000 Decode a DW1000 capture recorded by an X410 receiver.
%   RESULT = DECODE_X410_DW1000() uses the project defaults.
%   RESULT = DECODE_X410_DW1000(OPTIONS) overrides default fields.
%
%   Processing stages are implemented as separate files in the
%   +dw1000decoder package folder.

if nargin < 1
    options = struct();
end
params = dw1000decoder.mergeOptions( ...
    dw1000decoder.defaultOptions(), options);
addpath(params.helper_path);

[rx, interference] = dw1000decoder.readAndCancelInterference(params);
rx = dw1000decoder.compensateCenterFrequency(rx, params);
reference = dw1000decoder.buildDw1000Reference(params);
rx_work = dw1000decoder.resampleCapture(rx, params.fs_rx, reference.fs);

preamble = dw1000decoder.detectRepeatedPreamble( ...
    rx_work, reference, params);
dw1000decoder.validateCaptureLength( ...
    rx_work, preamble, reference, params);

% Shrink the work buffer to the active frame before the heavy stages.
if params.enable_frame_crop
    [rx_work, preamble] = dw1000decoder.cropToFrame( ...
        rx_work, preamble, reference, params);
end

[rx_work, preamble] = dw1000decoder.compensateCarrierOffset( ...
    rx_work, preamble, reference, params);
preamble = dw1000decoder.refineTimingWithNsSfd( ...
    rx_work, preamble, reference, params);
sfd_symbols = dw1000decoder.analyzeNsSfdSymbols( ...
    rx_work, preamble, reference, params);
[cir, chips] = dw1000decoder.estimateCirAndSoftChips( ...
    rx_work, preamble, reference, params);
sfd = dw1000decoder.locateNsSfd(chips.soft, reference, params, preamble);
frame = dw1000decoder.decodePhrAndPayload( ...
    chips.soft, sfd, reference.cfg);

if params.show_plots
    dw1000decoder.plotPreambleDetection(preamble, reference, params);
    dw1000decoder.plotDespreadCir(cir, params);
    dw1000decoder.plotSfdDetection(sfd);
end

result = dw1000decoder.packageResult(params, reference, interference, ...
    preamble, sfd_symbols, cir, chips, sfd, frame);
end
