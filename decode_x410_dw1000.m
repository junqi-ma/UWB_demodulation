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
%   +uwbdecoder package folder.
%
%   See also DW1000DECODER, DECODE_X410_DW1000_ALL.

if nargin < 1
    options = struct();
end
params = uwbdecoder.mergeOptions( ...
    uwbdecoder.defaultOptions(), options);
addpath(params.helper_path);

if nargin < 2 || isempty(preprocessedRx)
    [rx, interference] = uwbdecoder.readAndCancelInterference(params);
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

rx = uwbdecoder.compensateCenterFrequency(rx, params);
reference = uwbdecoder.buildUwbReference(params);
rxWork = uwbdecoder.resampleCapture(rx, params.fs_rx, reference.fs);

preamble = uwbdecoder.detectRepeatedPreamble( ...
    rxWork, reference, params);
uwbdecoder.validateCaptureLength( ...
    rxWork, preamble, reference, params);

% Shrink the work buffer to the active frame before the heavy stages.
% Keep the crop origin so the public result can also report timing in the
% original, uncropped work-rate buffer. Internal stages continue to use the
% cropped coordinate system.
cropStartWork = 1;
if params.enable_frame_crop
    [rxWork, preamble, cropInfo] = uwbdecoder.cropToFrame( ...
        rxWork, preamble, reference, params);
    cropStartWork = cropInfo.crop_start;
end

[rxWork, preamble] = uwbdecoder.compensateCarrierOffset( ...
    rxWork, preamble, reference, params);
preamble = uwbdecoder.refineTimingWithNsSfd( ...
    rxWork, preamble, reference, params);
sfdSymbols = uwbdecoder.analyzeNsSfdSymbols( ...
    rxWork, preamble, reference, params);
[cir, chips] = uwbdecoder.estimateCirAndSoftChips( ...
    rxWork, preamble, reference, params);
sfd = uwbdecoder.locateNsSfd(chips.soft, reference, params, preamble);
frame = uwbdecoder.decodePhrAndPayload( ...
    chips.soft, sfd, reference.cfg, params.max_psdu_bytes);

if params.show_plots
    uwbdecoder.plotPreambleDetection(preamble, reference, params);
    uwbdecoder.plotDespreadCir(cir, params);
    uwbdecoder.plotSfdDetection(sfd);
end

result = uwbdecoder.packageResult(params, reference, interference, ...
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
