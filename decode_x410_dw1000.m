function result = decode_x410_dw1000(options, preprocessedRx, interference)
%DECODE_X410_DW1000 Decode a DW1000 capture recorded by an X410 receiver.
%   RESULT = DECODE_X410_DW1000() uses the project defaults.
%   RESULT = DECODE_X410_DW1000(OPTIONS) overrides default fields.
%   RESULT = DECODE_X410_DW1000(OPTIONS, RX, INTERFERENCE) skips file I/O
%   and tone cancellation, using the already tone-cancelled RX vector and
%   its INTERFERENCE diagnostic structure. This ensures downstream decode
%   and comparison operate on exactly the same preprocessed samples.
%
%   Processing stages are implemented as separate files in the
%   +dw1000decoder package folder.
%
%   See also DW1000DECODER, DECODE_X410_DW1000_ALL.

if nargin < 1
    options = struct();
end
params = dw1000decoder.mergeOptions( ...
    dw1000decoder.defaultOptions(), options);
addpath(params.helper_path);

if nargin < 2 || isempty(preprocessedRx)
    [rx, interference] = dw1000decoder.readAndCancelInterference(params);
else
    if ~isnumeric(preprocessedRx) || ~isvector(preprocessedRx)
        error('decode_x410_dw1000:InvalidPreprocessedRx', ...
            'Preprocessed RX must be a numeric vector.');
    end
    rx = preprocessedRx(:);
    if nargin < 3 || isempty(interference)
        interference = struct('enabled', true, 'frequency_hz', NaN, ...
            'coefficient', complex(NaN), 'suppression_db', NaN, ...
            'source', 'preprocessed input');
    end
end

rx = dw1000decoder.compensateCenterFrequency(rx, params);
reference = dw1000decoder.buildDw1000Reference(params);
rxWork = dw1000decoder.resampleCapture(rx, params.fs_rx, reference.fs);

preamble = dw1000decoder.detectRepeatedPreamble( ...
    rxWork, reference, params);
dw1000decoder.validateCaptureLength( ...
    rxWork, preamble, reference, params);

% Shrink the work buffer to the active frame before the heavy stages.
% Keep the crop origin so the public result can also report timing in the
% original, uncropped work-rate buffer. Internal stages continue to use the
% cropped coordinate system.
cropStartWork = 1;
if params.enable_frame_crop
    [rxWork, preamble, cropInfo] = dw1000decoder.cropToFrame( ...
        rxWork, preamble, reference, params);
    cropStartWork = cropInfo.crop_start;
end

[rxWork, preamble] = dw1000decoder.compensateCarrierOffset( ...
    rxWork, preamble, reference, params);
preamble = dw1000decoder.refineTimingWithNsSfd( ...
    rxWork, preamble, reference, params);
sfdSymbols = dw1000decoder.analyzeNsSfdSymbols( ...
    rxWork, preamble, reference, params);
[cir, chips] = dw1000decoder.estimateCirAndSoftChips( ...
    rxWork, preamble, reference, params);
sfd = dw1000decoder.locateNsSfd(chips.soft, reference, params, preamble);
frame = dw1000decoder.decodePhrAndPayload( ...
    chips.soft, sfd, reference.cfg, params.max_psdu_bytes);

if params.show_plots
    dw1000decoder.plotPreambleDetection(preamble, reference, params);
    dw1000decoder.plotDespreadCir(cir, params);
    dw1000decoder.plotSfdDetection(sfd);
end

result = dw1000decoder.packageResult(params, reference, interference, ...
    preamble, sfdSymbols, cir, chips, sfd, frame);
result.preamble.start_sample_uncropped = ...
    result.preamble.start_sample + cropStartWork - 1;
result.preamble.crop_start_sample = cropStartWork;
result.soft_chip_timing = struct( ...
    'sample_index_base', 1, ...
    'coordinate_system', 'uncropped work-rate input window', ...
    'samples_per_chip', chips.samples_per_chip, ...
    'first_chip_sample_uncropped', ...
        chips.chip_start_sample + cropStartWork - 1, ...
    'last_chip_sample_uncropped', ...
        chips.chip_end_sample + cropStartWork - 1, ...
    'num_chips', chips.num_chips);
end
