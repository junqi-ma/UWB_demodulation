function result = decode_uwb(options, preprocessedRx, interference, preparedReference)
%DECODE_X410_DW1000 Decode a DW1000 capture recorded by an X410 receiver.
%   RESULT = DECODE_X410_DW1000() uses the project defaults.
%   RESULT = DECODE_X410_DW1000(OPTIONS) overrides default fields.
%   RESULT = DECODE_UWB(OPTIONS, RX, INTERFERENCE) skips file I/O and uses
%   the already preprocessed complex-baseband RX vector. The input is
%   expected to use the configured 998.4 MHz sample rate, with resampling,
%   single-tone cancellation, and center-frequency shift already applied.
%   RESULT = DECODE_UWB(OPTIONS, RX, INTERFERENCE, REFERENCE) reuses a
%   prebuilt UWB reference. Batch decoders use this form to avoid rebuilding
%   the same PHY waveform for every candidate packet.
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

% Suppress all progress fprintf inside +uwbdecoder so the console stays
% clean for CLI / LLM-driven debugging. The decode results are fully saved
% to disk; use visualize_decode_uwb_all.m to inspect them.
params.verbose = false;

if nargin < 2 || isempty(preprocessedRx)
    raw = uwbdecoder.readIqRaw(params.file_name, params.sample_offset, ...
        params.sample_num, params.ant_num);
    rx = uwbdecoder.selectIqChannel(raw, params.channel_index);
    interference = struct('enabled', false, 'frequency_hz', NaN, ...
        'coefficient', complex(0), 'suppression_db', NaN, ...
        'source', 'preprocessed input');
else
    if ~isnumeric(preprocessedRx) || ~isvector(preprocessedRx)
        error('decode_uwb:InvalidPreprocessedRx', ...
            'Preprocessed RX must be a numeric vector.');
    end
    rx = preprocessedRx(:);
    if nargin < 3 || isempty(interference)
        interference = struct('enabled', true, 'frequency_hz', NaN, ...
            'coefficient', complex(NaN), 'suppression_db', NaN, ...
            'source', 'preprocessed input');
    end
end

if nargin < 4 || isempty(preparedReference)
    reference = uwbdecoder.buildUwbReference(params);
else
    reference = preparedReference;
end
if abs(params.fs_rx - reference.fs) > 1
    error('decode_uwb:SampleRateMismatch', ...
        ['Preprocessed input must use the HRP work rate %.3f MHz; ', ...
        'received %.3f MHz.'], reference.fs/1e6, params.fs_rx/1e6);
end
rxWork = rx;

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
