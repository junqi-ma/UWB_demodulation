%% Regenerate and subtract reliably decoded DW1000 frames
% The default is a short validation run. It first extracts a small interval
% from the original capture, scans/cancels only that interval, and writes
% separate before/after files plus a comparison figure. After validating
% the result, set validation.enabled=false to process the complete capture.
clear;
close all;
clc;

c = dw1000decoder.constants();

projectDir = fileparts(mfilename('fullpath'));
cd(projectDir);
addpath(projectDir);

%% -------------------- User configuration --------------------
sourceInputFile = 'F:\UWB基带数据\DW1000_2.dat';
outputDir = fullfile(projectDir, 'decoded_results');

validation = struct();
validation.enabled = true;
validation.source_sample_offset = 400000;
validation.sample_num = 900000;
validation.original_file = fullfile(outputDir, ...
    'DW1000_2_validation_original.dat');
validation.cancelled_file = fullfile(outputDir, ...
    'DW1000_2_validation_cancelled.dat');
validation.figure_file = fullfile(outputDir, ...
    'DW1000_2_validation_comparison.png');

if validation.enabled
    inputFile = validation.original_file;
    outputFile = validation.cancelled_file;
else
    inputFile = sourceInputFile;
    outputFile = fullfile(outputDir, ...
        'DW1000_2_all_dw1000_cancelled.dat');
end

options = struct();
options.file_name = inputFile;
options.ant_num = 1;
options.channel_index = 1;
options.fs_rx = 737.28e6;
options.x410_center_frequency = 6500e6;
options.dw1000_center_frequency = 6489.6e6;

% DW1000 HRP profile. Change these fields if the capture uses another PHY.
options.preamble_repetitions = 256;
options.code_index = 10;
options.data_rate = 6.81;
options.sfd_mode = 'decawave';
options.decawave_sfd = [-1; -1; -1; -1; 1; -1; 0; 0];
options.ieee_sfd = [0; 1; 0; -1; 1; 0; 0; -1];
options.max_psdu_bytes = 127;
% Skip the receiver/resampler startup transient when estimating the CIR.
options.cir_skip_initial_repetitions = 24;
options.cir_repetitions = 64;
options.cir_pre_samples = 8;
options.cir_post_samples = 30;
options.cir_max_path_m = [];
options.enable_frame_crop = true;
options.verbose = false;
options.show_plots = false;

% Known clock-synchronous X410 tone: it is removed only while detecting and
% fitting a DW1000 replica. It is NOT removed from the saved output.
options.enable_interference_cancellation = true;
options.interference_quiet_offset = 400000;
options.interference_quiet_num = 262144;
options.interference_tone_bin = -169;
options.interference_period_samples = 512;

% Full-file detector. Increase window_samples when very long PSDUs are used.
batch = struct();
batch.coarse_chunk_samples = 4e6;
batch.coarse_step_samples = 3e6;
batch.coarse_decimation = 32;
batch.energy_smooth_rx_samples = 8192;
batch.energy_threshold_sigma = 5.5;
batch.use_coarse_correlation = true;
% Do not require long-window energy to pass before testing the preamble.
% Sparse UWB frames can have a strong code correlation but little change in
% average power over an 8192-sample window.
batch.require_energy_gate_for_correlation = false;
batch.coarse_correlation_repetitions = 8;
batch.corr_threshold_sigma = 4.5;
batch.candidate_merge_samples = 1.5e5;
batch.pre_packet_guard_samples = 5e4;
batch.window_samples = 1.5e6;
batch.min_window_samples = 0.3e6;
batch.post_packet_guard_samples = 4096;
batch.start_tolerance_samples = 4096;
% Never regenerate a frame whose decoded bytes are not protected by a
% valid FCS. False decodes otherwise produce a plausible preamble but a
% wrong PHR/payload replica.
batch.require_fcs_pass = true;
batch.save_individual_cir = false;

cancel = struct();
cancel.require_fcs_pass = true;
cancel.alignment_search_samples = 512;
cancel.alignment_preamble_repetitions = 32;
cancel.stable_sync_first = 25;
cancel.cfo_skip_initial_repetitions = 24;
cancel.min_alignment_correlation = 0.10;
cancel.min_validation_correlation = 0.20;
cancel.min_fit_suppression_db = 0.20;
cancel.max_abs_cfo_hz = 1e6;
cancel.output_headroom = 1.0;

%% -------------------- Prepare validation input and output paths --------------------
if ~isfile(sourceInputFile)
    error('run_cancel_all_dw1000_in_capture:SourceNotFound', ...
        'Source capture not found: %s', sourceInputFile);
end
if ~isfolder(outputDir)
    mkdir(outputDir);
end
if validation.enabled
    fprintf('\nPreparing short validation capture...\n');
    extractIqInterval(sourceInputFile, inputFile, ...
        validation.source_sample_offset, validation.sample_num, ...
        options.ant_num, c);
    options.interference_quiet_offset = 0;
    options.interference_quiet_num = min(65536, ...
        floor(validation.sample_num / 4));
    batch.coarse_chunk_samples = min(batch.coarse_chunk_samples, ...
        validation.sample_num);
    batch.coarse_step_samples = min(batch.coarse_step_samples, ...
        max(batch.min_window_samples, ...
        validation.sample_num - batch.min_window_samples));
    batch.window_samples = min(batch.window_samples, ...
        validation.sample_num);
end

if ~isfile(inputFile)
    error('run_cancel_all_dw1000_in_capture:WorkingCaptureNotFound', ...
        'Working capture not found: %s', inputFile);
end
if options.channel_index < 1 || options.channel_index > options.ant_num
    error('run_cancel_all_dw1000_in_capture:InvalidChannel', ...
        'channel_index must be in the range 1..ant_num.');
end
inputInfo = dir(inputFile);
bytesPerSample = c.BYTES_PER_IQ_SAMPLE*options.ant_num;
if mod(inputInfo.bytes, bytesPerSample) ~= 0
    error('run_cancel_all_dw1000_in_capture:InvalidFileSize', ...
        'Input byte count is not a whole number of %d-channel IQ samples.', ...
        options.ant_num);
end
totalSamples = inputInfo.bytes / bytesPerSample;

if strcmpi(char(java.io.File(inputFile).getCanonicalPath()), ...
        char(java.io.File(outputFile).getCanonicalPath()))
    error('run_cancel_all_dw1000_in_capture:OutputSameAsInput', ...
        'The outputFile must be different from inputFile.');
end

[~, captureStem] = fileparts(inputFile);
scanDir = fullfile(outputDir, [captureStem '_dw1000_scan']);
batch.output_directory = scanDir;
batch.mat_file = fullfile(scanDir, 'dw1000_all_frames.mat');
batch.summary_csv = fullfile(scanDir, 'dw1000_all_frames.csv');

%% -------------------- Discover reliable frames --------------------
fprintf('\nStep 1/3: scanning the working capture for FCS-valid DW1000 frames...\n');
results = decode_x410_dw1000_all(options, batch);
if results.packet_count == 0
    warning('run_cancel_all_dw1000_in_capture:NoFramesFound', ...
        ['No FCS-valid DW1000 frame was found. ', ...
         'The output will be an unchanged copy.']);
end

%% -------------------- Copy complete capture before patching frames --------------------
fprintf('\nStep 2/3: copying the complete capture to:\n  %s\n', outputFile);
[copyOk, copyMessage] = copyfile(inputFile, outputFile, 'f');
if ~copyOk
    error('run_cancel_all_dw1000_in_capture:CopyFailed', ...
        'Could not create output capture: %s', copyMessage);
end

%% -------------------- Regenerate and subtract each frame --------------------
fprintf('\nStep 3/3: regenerating and subtracting %d frame(s)...\n', ...
    results.packet_count);
reports = emptyCancellationReport();
successCount = 0;

for k = 1:results.packet_count
    frame = results.frames(k);
    fprintf('  Frame %d/%d at %.6f ms: ', ...
        k, results.packet_count, frame.time_start_s*1e3);
    try
        report = cancelOneFrame(outputFile, frame, options, results.params, ...
            cancel, totalSamples, c);
        reports(end+1) = report; %#ok<SAGROW>
        successCount = successCount + 1;
        fprintf(['removed %.2f dB (fit domain), corr %.3f, ', ...
            'CFO %+.2f kHz, clipped %d\n'], ...
            report.fit_suppression_db, report.validation_correlation, ...
            report.fitted_cfo_hz/1e3, report.clipped_sample_count);
    catch frameError
        report = failedCancellationReport(k, frame, frameError.message);
        reports(end+1) = report; %#ok<SAGROW>
        fprintf('SKIPPED (%s)\n', frameError.message);
    end
end

%% -------------------- Save cancellation metadata --------------------
metadataFile = fullfile(outputDir, ...
    [captureStem '_all_dw1000_cancelled_metadata.mat']);
summaryFile = fullfile(outputDir, ...
    [captureStem '_all_dw1000_cancelled_summary.csv']);
writeCancellationCsv(summaryFile, reports);
save(metadataFile, 'results', 'reports', 'options', 'batch', 'cancel', ...
    'sourceInputFile', 'inputFile', 'outputFile', 'validation', ...
    'totalSamples', '-v7.3');

fprintf('\n========== All-DW1000 cancellation summary ==========\n');
fprintf('Input                         : %s\n', inputFile);
fprintf('Output                        : %s\n', outputFile);
fprintf('Complex samples / channels    : %d / %d\n', ...
    totalSamples, options.ant_num);
fprintf('Detected frames               : %d\n', results.packet_count);
fprintf('Successfully cancelled        : %d\n', successCount);
fprintf('Skipped                       : %d\n', ...
    results.packet_count - successCount);
outputInfo = dir(outputFile);
fprintf('Output bytes                  : %d (same as input: %d)\n', ...
    outputInfo.bytes, outputInfo.bytes == inputInfo.bytes);
fprintf('Metadata                      : %s\n', metadataFile);
fprintf('CSV summary                   : %s\n', summaryFile);
fprintf('=====================================================\n');

if validation.enabled
    fprintf('\nCreating short-capture before/after comparison...\n');
    plotValidationComparison(inputFile, outputFile, options, reports, ...
        validation.source_sample_offset, validation.figure_file, c);
    fprintf('Validation source interval    : %d..%d\n', ...
        validation.source_sample_offset, ...
        validation.source_sample_offset + validation.sample_num - 1);
    fprintf('Validation original           : %s\n', inputFile);
    fprintf('Validation cancelled          : %s\n', outputFile);
    fprintf('Validation figure             : %s\n', ...
        validation.figure_file);
end

assignin('base', 'dw1000_all_results', results);
assignin('base', 'dw1000_cancellation_reports', reports);

% -------------------------------------------------------------------------
function report = cancelOneFrame(outputFile, frame, options, scanParams, ...
        cancel, totalSamples, c)
% Reuse the exact bytes and CIR accepted by the scan. Re-running the
% unconstrained decoder from a differently anchored window can lock to a
% different peak and previously made regeneration disagree with the scan.
if cancel.require_fcs_pass && ~frame.fcs_pass
    error('cancelOneFrame:FcsFailed', ...
        'The scan result did not pass FCS.');
end
if isempty(frame.payload_bytes)
    error('cancelOneFrame:EmptyPayload', ...
        'The scan result contains no PSDU bytes.');
end
decoded = struct();
decoded.payload = struct('bytes', uint8(frame.payload_bytes(:)), ...
    'fcs_pass', logical(frame.fcs_pass));
decoded.sfd = struct('name', frame.sfd_name);
decoded.cir = frame.cir;

txOptions = struct();
txOptions.fs_tx = options.fs_rx;
txOptions.x410_center_frequency = options.x410_center_frequency;
txOptions.qm35_center_frequency = options.dw1000_center_frequency;
txOptions.phy_mode = '802.15.4a';
txOptions.preamble_repetitions = options.preamble_repetitions;
txOptions.code_index = options.code_index;
txOptions.sfd_number = 0;
txOptions.sfd_sequence = selectSfdSequence(decoded, scanParams);
txOptions.peak_amplitude = 0.8;
txOptions.guard_samples = 0;
txOptions.require_fcs_pass = cancel.require_fcs_pass;
tx = generate_qm35_tx_from_decode(decoded, txOptions);
channel = apply_estimated_cir_to_qm35(tx, decoded.cir);
replica = channel.waveform_x410(:);

% Read enough current-output samples to cover alignment search and replica.
nominalStart = frame.abs_start_sample;
readFirst = max(0, nominalStart - cancel.alignment_search_samples);
readLast = min(totalSamples - 1, nominalStart + numel(replica) - 1 + ...
    cancel.alignment_search_samples);
[raw, received] = readIqSegment(outputFile, readFirst, ...
    readLast - readFirst + 1, options.ant_num, options.channel_index, c);

% Suppress the known narrow tone only in the fitting copy. The actual saved
% residual below is formed from RECEIVED, so unrelated content is preserved.
fitReceived = received;
if options.enable_interference_cancellation && ...
        isfield(scanParams, 'interference_coefficient') && ...
        ~isempty(scanParams.interference_coefficient)
    absoluteN = readFirst + (0:numel(fitReceived)-1).';
    tone = dw1000decoder.synchronousTone(absoluteN, ...
        options.interference_tone_bin, options.interference_period_samples);
    fitReceived = fitReceived - scanParams.interference_coefficient(1).*tone;
end

nominalLocal = nominalStart - readFirst + 1;
[startLocal, alignmentCorrelation] = alignReplica( ...
    fitReceived, replica, nominalLocal, options, cancel);
available = min(numel(replica), numel(received) - startLocal + 1);
if available < 2
    error('cancelOneFrame:WaveformOutsideCapture', ...
        'Regenerated waveform falls outside the capture.');
end
replica = replica(1:available);
observedForFit = fitReceived(startLocal:startLocal + available - 1);

fittedCfoHz = fitReplicaCfo(observedForFit, replica, options, cancel, c);
n = (0:available - 1).';
replicaCfo = replica .* exp(1j*2*pi*fittedCfoHz*n / options.fs_rx);

% Fit gain only on the stable part of SYNC. PHR/payload samples are kept
% out of the fit so corrupted body data cannot make a bad model look good.
period = c.PREAMBLE_PERIOD_S * options.fs_rx;
stableFirst = round((cancel.stable_sync_first - 1)*period) + 1;
stableLast = min(round(options.preamble_repetitions*period), available);
if stableFirst >= stableLast
    error('cancelOneFrame:StableIntervalOutsideReplica', ...
        'The stable SYNC fitting interval is outside the replica.');
end
fitIndices = stableFirst:stableLast;
gain = (replicaCfo(fitIndices)' * observedForFit(fitIndices)) / ...
    (replicaCfo(fitIndices)' * replicaCfo(fitIndices) + eps);
modeled = gain * replicaCfo;

if alignmentCorrelation < cancel.min_alignment_correlation
    error('cancelOneFrame:AlignmentCorrelationTooLow', ...
        'Alignment correlation %.3f is below threshold %.3f.', ...
        alignmentCorrelation, cancel.min_alignment_correlation);
end

validationCorrelation = abs( ...
    replicaCfo(fitIndices)' * observedForFit(fitIndices)) / ...
    (norm(replicaCfo(fitIndices)) * ...
    norm(observedForFit(fitIndices)) + eps);
fitBefore = observedForFit(fitIndices);
fitAfter = fitBefore - modeled(fitIndices);
fitPowerBefore = mean(abs(fitBefore).^2);
fitPowerAfter = mean(abs(fitAfter).^2);
fitSuppressionDb = ...
    10*log10(fitPowerBefore / (fitPowerAfter + eps));
if validationCorrelation < cancel.min_validation_correlation
    error('cancelOneFrame:ValidationCorrelationTooLow', ...
        'Validation correlation %.3f is below threshold %.3f.', ...
        validationCorrelation, cancel.min_validation_correlation);
end
if fitSuppressionDb < cancel.min_fit_suppression_db
    error('cancelOneFrame:FitSuppressionTooLow', ...
        'Fit suppression %.3f dB is below threshold %.3f dB.', ...
        fitSuppressionDb, cancel.min_fit_suppression_db);
end

before = received(startLocal:startLocal + available - 1);
after = before - modeled;
savedPowerBefore = mean(abs(before).^2);
savedFloatPowerAfter = mean(abs(after).^2);
received(startLocal:startLocal + available - 1) = after;
[raw, clippedSampleCount] = replaceIqChannel( ...
    raw, received, options.channel_index, cancel.output_headroom, c);
writeIqSegment(outputFile, readFirst, raw, options.ant_num, c);

% Validate the actual int16 samples after rounding and saturation.
[~, savedReceived] = readIqSegment(outputFile, readFirst, ...
    size(raw, 2), options.ant_num, options.channel_index, c);
savedAfter = savedReceived(startLocal:startLocal + available - 1);
savedPowerAfter = mean(abs(savedAfter).^2);
savedSuppressionDb = ...
    10*log10(savedPowerBefore / (savedPowerAfter + eps));

report = struct();
report.index = frame.index;
report.success = true;
report.abs_start_detected = frame.abs_start_sample;
report.abs_start_fitted = readFirst + startLocal - 1;
report.samples_subtracted = available;
report.alignment_correlation = alignmentCorrelation;
report.validation_correlation = validationCorrelation;
report.fitted_cfo_hz = fittedCfoHz;
report.complex_gain = gain;
report.fit_power_before = fitPowerBefore;
report.fit_power_after = fitPowerAfter;
report.fit_suppression_db = fitSuppressionDb;
report.saved_power_before = savedPowerBefore;
report.saved_float_power_after = savedFloatPowerAfter;
report.saved_power_after = savedPowerAfter;
report.saved_suppression_db = savedSuppressionDb;
report.clipped_sample_count = clippedSampleCount;
report.fcs_pass = logical(decoded.payload.fcs_pass);
report.message = '';
end

function sequence = selectSfdSequence(decoded, options)
sequence = [];
name = lower(string(decoded.sfd.name));
if contains(name, "decawave") || contains(name, "dw-8")
    sequence = options.decawave_sfd;
elseif contains(name, "ieee")
    sequence = options.ieee_sfd;
end
end

function [raw, rx] = readIqSegment(fileName, sampleOffset, sampleNum, ...
        antNum, channelIdx, c)
raw = dw1000decoder.readIqRaw(fileName, sampleOffset, sampleNum, antNum);
rx = dw1000decoder.selectIqChannel(raw, channelIdx);
end

function [raw, clippedSampleCount] = replaceIqChannel( ...
        raw, rx, channelIdx, headroom, c)
upperLimit = floor(c.INT16_MAX * headroom);
lowerLimit = ceil(c.INT16_MIN * headroom);
iRow = 2*channelIdx - 1;
qRow = 2*channelIdx;
clippedSampleCount = nnz(real(rx) > upperLimit | ...
    real(rx) < lowerLimit | imag(rx) > upperLimit | ...
    imag(rx) < lowerLimit);
raw(iRow, :) = max(lowerLimit, min(upperLimit, round(real(rx)))).';
raw(qRow, :) = max(lowerLimit, min(upperLimit, round(imag(rx)))).';
end

function writeIqSegment(fileName, sampleOffset, raw, antNum, c)
fid = fopen(fileName, 'r+b', 'ieee-le');
if fid < 0
    error('writeIqSegment:FileOpenError', ...
        'Cannot open output capture for updating: %s', fileName);
end
fileGuard = onCleanup(@() fclose(fid));

status = fseek(fid, sampleOffset*c.BYTES_PER_IQ_SAMPLE*antNum, 'bof');
if status ~= 0
    error('writeIqSegment:SeekError', ...
        'Could not seek to output sample %d for writing.', sampleOffset);
end

count = fwrite(fid, int16(raw), 'int16');
if count ~= numel(raw)
    error('writeIqSegment:ShortWrite', ...
        'Only %d of %d int16 values were written.', count, numel(raw));
end
clear fileGuard;
end

function [bestStart, bestCorr] = alignReplica(rx, replica, nominalStart, ...
        options, cancel)
% One HRP preamble repetition is 1017.628205 ns (1016 chips / 998.4 MHz).
c = dw1000decoder.constants();
periodRx = c.PREAMBLE_PERIOD_S * options.fs_rx;
repetitionCount = min(cancel.alignment_preamble_repetitions, ...
    floor(numel(replica) / periodRx) - cancel.cfo_skip_initial_repetitions);
if repetitionCount < 1
    error('alignReplica:PreambleTooShort', ...
        'Regenerated preamble is too short for alignment.');
end
templateLength = round(repetitionCount * periodRx);
templateOffset = round(cancel.cfo_skip_initial_repetitions * periodRx);
template = replica(templateOffset + (1:templateLength));
starts = round(nominalStart) + ...
    (-cancel.alignment_search_samples:cancel.alignment_search_samples);
scores = -inf(size(starts));
for k = 1:numel(starts)
    first = starts(k) + templateOffset;
    last = first + templateLength - 1;
    if first < 1 || last > numel(rx)
        continue;
    end
    segment = rx(first:last);
    % Noncoherent accumulation across repetitions makes timing alignment
    % insensitive to the still-unknown carrier-frequency offset.
    repetitionScores = zeros(repetitionCount, 1);
    for r = 1:repetitionCount
        idx = round((r-1)*periodRx) + 1:round(r*periodRx);
        a = template(idx);
        b = segment(idx);
        repetitionScores(r) = abs(a'*b) / (norm(a)*norm(b) + eps);
    end
    scores(k) = mean(repetitionScores);
end
[bestCorr, bestIdx] = max(scores);
if ~isfinite(bestCorr)
    error('alignReplica:NoValidCandidate', ...
        'No valid alignment candidate was inside the capture.');
end
bestStart = starts(bestIdx);
end

function cfoHz = fitReplicaCfo(received, replica, options, cancel, c)
period = c.PREAMBLE_PERIOD_S * options.fs_rx;
count = min(options.preamble_repetitions, ...
    floor(min(numel(received), numel(replica)) / period));
if count < 8
    cfoHz = 0;
    return;
end
correlations = complex(zeros(count, 1));
for k = 1:count
    idx = round((k-1)*period) + 1:round(k*period);
    correlations(k) = replica(idx)' * received(idx);
end
phase = unwrap(angle(correlations));
timeS = round((0:count-1).' * period) / options.fs_rx;
first = min(cancel.cfo_skip_initial_repetitions + 1, max(1, count - 7));
fit = polyfit(timeS(first:end), phase(first:end), 1);
cfoHz = fit(1) / (2*pi);
cfoHz = max(-cancel.max_abs_cfo_hz, ...
    min(cancel.max_abs_cfo_hz, cfoHz));
end

function reports = emptyCancellationReport()
reports = struct('index', {}, 'success', {}, 'abs_start_detected', {}, ...
    'abs_start_fitted', {}, 'samples_subtracted', {}, ...
    'alignment_correlation', {}, 'validation_correlation', {}, ...
    'fitted_cfo_hz', {}, 'complex_gain', {}, ...
    'fit_power_before', {}, 'fit_power_after', {}, ...
    'fit_suppression_db', {}, 'saved_power_before', {}, ...
    'saved_float_power_after', {}, 'saved_power_after', {}, ...
    'saved_suppression_db', {}, 'clipped_sample_count', {}, ...
    'fcs_pass', {}, 'message', {});
end

function report = failedCancellationReport(index, frame, message)
report = struct('index', index, 'success', false, ...
    'abs_start_detected', frame.abs_start_sample, ...
    'abs_start_fitted', NaN, 'samples_subtracted', 0, ...
    'alignment_correlation', NaN, 'validation_correlation', NaN, ...
    'fitted_cfo_hz', NaN, 'complex_gain', complex(NaN), ...
    'fit_power_before', NaN, 'fit_power_after', NaN, ...
    'fit_suppression_db', NaN, 'saved_power_before', NaN, ...
    'saved_float_power_after', NaN, 'saved_power_after', NaN, ...
    'saved_suppression_db', NaN, 'clipped_sample_count', 0, ...
    'fcs_pass', false, 'message', message);
end

function writeCancellationCsv(fileName, reports)
fid = fopen(fileName, 'w');
if fid < 0
    warning('writeCancellationCsv:CsvWriteError', ...
        'Could not write cancellation summary: %s', fileName);
    return;
end
fileGuard = onCleanup(@() fclose(fid));

fprintf(fid, ['index,success,abs_start_detected,abs_start_fitted,', ...
    'samples_subtracted,alignment_correlation,validation_correlation,', ...
    'fitted_cfo_hz,gain_real,gain_imag,fit_power_before,', ...
    'fit_power_after,fit_suppression_db,saved_power_before,', ...
    'saved_float_power_after,saved_power_after,saved_suppression_db,', ...
    'clipped_sample_count,fcs_pass,message\n']);

for k = 1:numel(reports)
    r = reports(k);
    message = strrep(r.message, '"', '""');
    fprintf(fid, ['%d,%d,%d,%.0f,%d,%.9g,%.9g,%.9g,%.9g,%.9g,', ...
        '%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%d,%d,"%s"\n'], ...
        r.index, r.success, r.abs_start_detected, r.abs_start_fitted, ...
        r.samples_subtracted, r.alignment_correlation, ...
        r.validation_correlation, r.fitted_cfo_hz, ...
        real(r.complex_gain), imag(r.complex_gain), ...
        r.fit_power_before, r.fit_power_after, r.fit_suppression_db, ...
        r.saved_power_before, r.saved_float_power_after, ...
        r.saved_power_after, r.saved_suppression_db, ...
        r.clipped_sample_count, r.fcs_pass, message);
end
clear fileGuard;
end

function extractIqInterval(sourceFile, destinationFile, sampleOffset, ...
        sampleNum, antNum, c)
% Copy a small, byte-exact interleaved-IQ interval for safe validation.
if sampleOffset < 0 || sampleOffset ~= fix(sampleOffset) || ...
        sampleNum < 1 || sampleNum ~= fix(sampleNum)
    error('extractIqInterval:InvalidArgs', ...
        'Validation sample offset/count must be positive integers.');
end
bytesPerSample = c.BYTES_PER_IQ_SAMPLE*antNum;
sourceInfo = dir(sourceFile);
totalSamples = floor(sourceInfo.bytes / bytesPerSample);
if sampleOffset + sampleNum > totalSamples
    error('extractIqInterval:IntervalExceedsSource', ...
        'Validation interval %d..%d exceeds source length %d.', ...
        sampleOffset, sampleOffset + sampleNum - 1, totalSamples);
end

sourceFid = fopen(sourceFile, 'rb', 'ieee-le');
if sourceFid < 0
    error('extractIqInterval:SourceOpenError', ...
        'Cannot open validation source: %s', sourceFile);
end
sourceGuard = onCleanup(@() fclose(sourceFid));

if fseek(sourceFid, sampleOffset*bytesPerSample, 'bof') ~= 0
    error('extractIqInterval:SeekError', ...
        'Could not seek to validation sample %d.', sampleOffset);
end
byteCount = sampleNum * bytesPerSample;
bytes = fread(sourceFid, byteCount, 'uint8=>uint8');
if numel(bytes) ~= byteCount
    error('extractIqInterval:ShortRead', ...
        'Could not read the complete validation interval.');
end
clear sourceGuard;

destinationFid = fopen(destinationFile, 'wb', 'ieee-le');
if destinationFid < 0
    error('extractIqInterval:DestinationOpenError', ...
        'Cannot create validation file: %s', destinationFile);
end
destinationGuard = onCleanup(@() fclose(destinationFid));

count = fwrite(destinationFid, bytes, 'uint8');
if count ~= byteCount
    error('extractIqInterval:ShortWrite', ...
        'Could not write the complete validation interval.');
end
clear destinationGuard;

fprintf('  Source samples : %d..%d\n', sampleOffset, ...
    sampleOffset + sampleNum - 1);
fprintf('  Validation file: %s\n', destinationFile);
end

function plotValidationComparison(originalFile, cancelledFile, options, ...
        reports, sourceSampleOffset, figureFile, c)
info = dir(originalFile);
sampleNum = info.bytes / (c.BYTES_PER_IQ_SAMPLE*options.ant_num);
[~, original] = readIqSegment(originalFile, 0, sampleNum, ...
    options.ant_num, options.channel_index, c);
[~, cancelled] = readIqSegment(cancelledFile, 0, sampleNum, ...
    options.ant_num, options.channel_index, c);
removed = original - cancelled;
absoluteTimeMs = (sourceSampleOffset + (0:sampleNum-1).') / ...
    options.fs_rx * 1e3;

plotStep = max(1, ceil(sampleNum / 200000));
overviewIdx = 1:plotStep:sampleNum;
successful = find([reports.success], 1, 'first');
if isempty(successful)
    zoomFirst = 1;
    zoomLast = min(sampleNum, 200000);
else
    zoomGuard = 10000;
    zoomFirst = max(1, reports(successful).abs_start_fitted + 1 - zoomGuard);
    zoomLast = min(sampleNum, reports(successful).abs_start_fitted + ...
        reports(successful).samples_subtracted + zoomGuard);
end
zoomIdx = zoomFirst:zoomLast;

fig = figure('Name', 'Short-capture DW1000 cancellation validation', ...
    'Color', 'w');
subplot(2, 2, 1);
plot(absoluteTimeMs(overviewIdx), abs(original(overviewIdx)));
hold on;
plot(absoluteTimeMs(overviewIdx), abs(cancelled(overviewIdx)));
grid on;
xlabel('Absolute capture time (ms)');
ylabel('|IQ| (ADC counts)');
legend('Before', 'After');
title('Validation interval overview');

subplot(2, 2, 2);
plot(absoluteTimeMs(zoomIdx), abs(original(zoomIdx)));
hold on;
plot(absoluteTimeMs(zoomIdx), abs(cancelled(zoomIdx)));
grid on;
xlabel('Absolute capture time (ms)');
ylabel('|IQ| (ADC counts)');
legend('Before', 'After');
title('First successfully cancelled frame');

subplot(2, 2, 3);
plot(absoluteTimeMs(zoomIdx), abs(removed(zoomIdx)));
grid on;
xlabel('Absolute capture time (ms)');
ylabel('|Before-after|');
title('Actually removed component');

fftNum = min(sampleNum, 262144);
window = 0.5 - 0.5*cos(2*pi*(0:fftNum-1).'/(fftNum-1));
specOriginal = abs(fftshift(fft(original(1:fftNum).*window)));
specCancelled = abs(fftshift(fft(cancelled(1:fftNum).*window)));
specRemoved = abs(fftshift(fft(removed(1:fftNum).*window)));
reference = max(specOriginal) + eps;
frequencyMhz = (-floor(fftNum/2):ceil(fftNum/2)-1).'* ...
    options.fs_rx / fftNum / 1e6;
subplot(2, 2, 4);
plot(frequencyMhz, 20*log10(specOriginal / reference + eps));
hold on;
plot(frequencyMhz, 20*log10(specCancelled / reference + eps));
plot(frequencyMhz, 20*log10(specRemoved / reference + eps));
grid on;
xlabel('Relative frequency (MHz)');
ylabel('Magnitude / original peak (dB)');
legend('Before', 'After', 'Removed');
title('Validation-interval spectrum');
xlim([-options.fs_rx/2, options.fs_rx/2]/1e6);

sgtitle(sprintf(['DW1000 short-capture validation: ', ...
    '%d accepted / %d detected'], nnz([reports.success]), numel(reports)));
saveas(fig, figureFile);
end