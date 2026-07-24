function results = decode_x410_dw1000_all(options, batch)
%DECODE_X410_DW1000_ALL Decode every packet in an X410 capture file.
%   RESULTS = DECODE_X410_DW1000_ALL(OPTIONS, BATCH) first runs a cheap
%   coarse energy / decimated-correlation pre-screen over the full .dat,
%   then fully decodes only the surviving candidates and saves CIR data.
%
%   OPTIONS uses the same fields as decode_x410_dw1000 / run_decode_*.
%   BATCH controls coarse scan, fine decode, and output paths.
%
%   See also DECODE_X410_DW1000, DW1000DECODER.

if nargin < 1 || isempty(options)
    options = struct();
end
if nargin < 2 || isempty(batch)
    batch = struct();
end

c = dw1000decoder.constants();

baseParams = dw1000decoder.mergeOptions( ...
    dw1000decoder.defaultOptions(), options);
batch = mergeBatchOptions(batch, baseParams);

if ~isfolder(batch.output_directory)
    mkdir(batch.output_directory);
end

totalSamples = countCaptureSamples(baseParams);
if totalSamples < batch.min_window_samples
    error('decode_x410_dw1000_all:CaptureTooShort', ...
        'Capture has only %d complex samples; need at least %d.', ...
        totalSamples, batch.min_window_samples);
end

% Estimate the interference coefficient once and reuse it everywhere.
if baseParams.enable_interference_cancellation && ...
        isempty(baseParams.interference_coefficient)
    baseParams.interference_coefficient = estimateInterferenceCoefficient( ...
        baseParams, totalSamples, c);
end

% Build the reference once for coarse correlation and packet-end estimates.
reference = dw1000decoder.buildDw1000Reference(baseParams);
addpath(baseParams.helper_path);
coarseTemplate = buildCoarseTemplate(baseParams, reference, batch);

fprintf('\n========== Full-file DW1000 decode (P0 coarse+fine) ==========\n');
fprintf('Capture file                 : %s\n', baseParams.file_name);
fprintf('Total complex samples        : %d (%.3f ms @ %.2f MHz)\n', ...
    totalSamples, totalSamples/baseParams.fs_rx*1e3, ...
    baseParams.fs_rx/1e6);
fprintf('Coarse chunk/step            : %d / %d\n', ...
    batch.coarse_chunk_samples, batch.coarse_step_samples);
fprintf('Coarse decimation            : %d\n', batch.coarse_decimation);
fprintf('Fine decode window           : %d\n', batch.window_samples);
fprintf('==============================================================\n\n');

%% -------------------- Stage 1: coarse candidate pre-screen --------------------
ticCoarse = tic;
[candidates, coarseStats] = findCoarseCandidates( ...
    baseParams, coarseTemplate, batch, totalSamples);
coarseSeconds = toc(ticCoarse);

fprintf(['Coarse scan done in %.1f s | chunks=%d | raw peaks=%d | ', ...
    'merged candidates=%d\n\n'], ...
    coarseSeconds, coarseStats.chunk_count, ...
    coarseStats.raw_peak_count, numel(candidates));

%% -------------------- Stage 2: fine decode only at candidates --------------------
frames = emptyFrameRecord();
packetCount = 0;
attemptCount = 0;
nextAllowedSample = 0;
ticFine = tic;

for candIdx = 1:numel(candidates)
    candidate = candidates(candIdx);
    if candidate < nextAllowedSample
        continue;
    end

    offset = max(0, candidate - batch.pre_packet_guard_samples);
    if offset + batch.min_window_samples > totalSamples
        continue;
    end
    windowSamples = min(batch.window_samples, totalSamples - offset);
    attemptCount = attemptCount + 1;

    windowOptions = options;
    windowOptions.sample_offset = offset;
    windowOptions.sample_num = windowSamples;
    windowOptions.show_plots = false;
    windowOptions.interference_coefficient = ...
        baseParams.interference_coefficient;

    fprintf(['---- Fine decode %d/%d | candidate=%d | ', ...
        'offset=%d | samples=%d ----\n'], ...
        attemptCount, numel(candidates), candidate, offset, windowSamples);

    try
        result = decode_x410_dw1000(windowOptions);
    catch decodeError
        fprintf('  Decode failed: %s\n', decodeError.message);
        % Keep searching nearby candidates; do not jump over a long gap.
        continue;
    end

    absStart = absoluteRxSample( ...
        offset, result.preamble.start_sample, ...
        baseParams.fs_rx, reference.fs);
    absEnd = estimatePacketEndSample( ...
        offset, result, baseParams, reference, batch);

    if isDuplicatePacket(frames, packetCount, absStart, ...
            batch.start_tolerance_samples)
        fprintf('  Duplicate packet near abs_start=%d; skipping.\n', ...
            absStart);
        nextAllowedSample = max(nextAllowedSample, absEnd);
        continue;
    end

    if batch.require_fcs_pass && ~result.payload.fcs_pass
        fprintf('  Packet rejected: FCS failed at abs_start=%d.\n', ...
            absStart);
        nextAllowedSample = max(nextAllowedSample, absEnd);
        continue;
    end

    packetCount = packetCount + 1;
    frames(packetCount) = packageFrameRecord( ...
        packetCount, offset, absStart, absEnd, result, baseParams);

    fprintf(['  Saved packet #%d | abs_start=%d | t=%.3f ms | ', ...
        'SFD=%s | corr=%.3f | FCS=%d\n'], ...
        packetCount, absStart, frames(packetCount).time_start_s*1e3, ...
        frames(packetCount).sfd_name, ...
        frames(packetCount).sfd_correlation, ...
        frames(packetCount).fcs_pass);

    if batch.save_individual_cir
        cirFile = fullfile(batch.output_directory, ...
            sprintf('cir_%03d.mat', packetCount));
        cir = frames(packetCount).cir; %#ok<NASGU>
        meta = frames(packetCount); %#ok<NASGU>
        save(cirFile, 'cir', 'meta', '-v7.3');
    end

    nextAllowedSample = max(nextAllowedSample, absEnd);
end
fineSeconds = toc(ticFine);

if packetCount == 0
    frames = emptyFrameRecord();
else
    frames = frames(1:packetCount);
end

results = struct();
results.file_name = baseParams.file_name;
results.total_samples = totalSamples;
results.duration_s = totalSamples / baseParams.fs_rx;
results.coarse_seconds = coarseSeconds;
results.fine_seconds = fineSeconds;
results.coarse_chunk_count = coarseStats.chunk_count;
results.coarse_raw_peak_count = coarseStats.raw_peak_count;
results.candidate_count = numel(candidates);
results.candidates = candidates(:);
results.attempt_count = attemptCount;
results.packet_count = packetCount;
if packetCount == 0
    results.fcs_pass_count = 0;
else
    results.fcs_pass_count = sum([frames.fcs_pass]);
end
results.params = baseParams;
results.batch = batch;
results.frames = frames;
results.cir_delay_ns = [];
results.cir_values = [];

if packetCount > 0
    results.cir_delay_ns = frames(1).cir.delay_ns(:);
    cirLen = numel(results.cir_delay_ns);
    results.cir_values = complex(zeros(cirLen, packetCount));
    for k = 1:packetCount
        values = frames(k).cir.values(:);
        n = min(cirLen, numel(values));
        results.cir_values(1:n, k) = values(1:n);
    end
end

save(batch.mat_file, 'results', '-v7.3');
writeSummaryCsv(batch.summary_csv, frames);

fprintf('\nSaved %d packet(s) to:\n  %s\n  %s\n', ...
    packetCount, batch.mat_file, batch.summary_csv);
fprintf('Timing: coarse %.1f s | fine %.1f s | fine attempts %d\n', ...
    coarseSeconds, fineSeconds, attemptCount);
end

% -------------------------------------------------------------------------
function batch = mergeBatchOptions(batch, params)
defaults = struct( ...
    'coarse_chunk_samples', 4e6, ...
    'coarse_step_samples', 3e6, ...
    'coarse_decimation', 32, ...
    'energy_smooth_rx_samples', 8192, ...
    'energy_threshold_sigma', 6, ...
    'use_coarse_correlation', true, ...
    'require_energy_gate_for_correlation', false, ...
    'coarse_correlation_repetitions', 8, ...
    'corr_threshold_sigma', 5, ...
    'candidate_merge_samples', 2e5, ...
    'pre_packet_guard_samples', 5e4, ...
    'window_samples', 0.8e6, ...
    'search_step_samples', 0.5e6, ...
    'post_packet_guard_samples', 4096, ...
    'start_tolerance_samples', 4096, ...
    'min_window_samples', 0.3e6, ...
    'require_fcs_pass', false, ...
    'save_individual_cir', true, ...
    'output_directory', '', ...
    'mat_file', '', ...
    'summary_csv', '');

names = fieldnames(defaults);
for k = 1:numel(names)
    name = names{k};
    if ~isfield(batch, name) || isempty(batch.(name))
        batch.(name) = defaults.(name);
    end
end

[~, captureStem] = fileparts(params.file_name);
if strlength(string(batch.output_directory)) == 0
    batch.output_directory = fullfile(pwd, 'decoded_results', captureStem);
end
if strlength(string(batch.mat_file)) == 0
    batch.mat_file = fullfile(batch.output_directory, 'all_frames_cir.mat');
end
if strlength(string(batch.summary_csv)) == 0
    batch.summary_csv = fullfile(batch.output_directory, 'frame_summary.csv');
end

integerFields = { ...
    'coarse_chunk_samples', 'coarse_step_samples', 'coarse_decimation', ...
    'energy_smooth_rx_samples', 'coarse_correlation_repetitions', ...
    'candidate_merge_samples', ...
    'pre_packet_guard_samples', 'window_samples', 'search_step_samples', ...
    'post_packet_guard_samples', 'start_tolerance_samples', ...
    'min_window_samples'};
for k = 1:numel(integerFields)
    name = integerFields{k};
    batch.(name) = max(1, round(batch.(name)));
end
batch.energy_threshold_sigma = max(0, double(batch.energy_threshold_sigma));
batch.corr_threshold_sigma = max(0, double(batch.corr_threshold_sigma));
batch.use_coarse_correlation = logical(batch.use_coarse_correlation);
batch.require_energy_gate_for_correlation = ...
    logical(batch.require_energy_gate_for_correlation);
batch.require_fcs_pass = logical(batch.require_fcs_pass);
batch.save_individual_cir = logical(batch.save_individual_cir);

if batch.coarse_step_samples > batch.coarse_chunk_samples
    warning('decode_x410_dw1000_all:StepExceedsChunk', ...
        ['coarse_step_samples > coarse_chunk_samples; ', ...
         'clamping step to chunk size.']);
    batch.coarse_step_samples = batch.coarse_chunk_samples;
end
end

function totalSamples = countCaptureSamples(params)
info = dir(params.file_name);
if isempty(info)
    error('decode_x410_dw1000_all:FileNotFound', ...
        'Cannot find capture file: %s', params.file_name);
end
c = dw1000decoder.constants();
totalSamples = floor(info.bytes / (c.BYTES_PER_IQ_SAMPLE*params.ant_num));
end

function coefficient = estimateInterferenceCoefficient(params, totalSamples, c)
quietOffset = params.interference_quiet_offset;
quietNum = params.interference_quiet_num;
if quietOffset < 0 || quietOffset >= totalSamples
    error('decode_x410_dw1000_all:QuietOffsetOutOfRange', ...
        'interference_quiet_offset is outside the capture.');
end
quietNum = min(quietNum, totalSamples - quietOffset);
if quietNum < params.interference_period_samples
    error('decode_x410_dw1000_all:NotEnoughQuietSamples', ...
        'Not enough samples available for interference estimation.');
end

rawQuiet = dw1000decoder.readIqRaw(params.file_name, quietOffset, quietNum, params.ant_num);
rxQuiet = dw1000decoder.selectIqChannel(rawQuiet, params.channel_index);
quietN = quietOffset + (0:length(rxQuiet)-1).';
quietBasis = dw1000decoder.synchronousTone(quietN, ...
    params.interference_tone_bin, params.interference_period_samples);
coefficient = mean(rxQuiet .* conj(quietBasis));

fprintf('Precomputed interference coefficient once for full-file scan.\n');
fprintf('  Amplitude: %.3f ADC counts, phase: %.3f deg\n', ...
    abs(coefficient), angle(coefficient)*180/pi);
end

function template = buildCoarseTemplate(params, reference, batch)
%BUILDCOARSETEMPLATE Map one preamble symbol to the coarse decimated grid.
c = dw1000decoder.constants();

[p, q] = rat(params.fs_rx / reference.fs, 1e-12);
prefRx = resample(reference.preamble_waveform, p, q);
prefRx = prefRx(:);
D = batch.coarse_decimation;
prefDs = prefRx(1:D:end);
prefDs = prefDs / (norm(prefDs) + eps);
template = struct( ...
    'decimation', D, ...
    'preamble_ds', prefDs, ...
    'preamble_rx_length', numel(prefRx));
end

function [candidates, stats] = findCoarseCandidates(params, template, ...
        batch, totalSamples)
candidates = zeros(0, 1);
rawPeakCount = 0;
chunkCount = 0;
offset = 0;
D = batch.coarse_decimation;

fprintf('Stage 1/2: coarse pre-screen over full capture...\n');
while offset + batch.min_window_samples <= totalSamples
    chunkSamples = min(batch.coarse_chunk_samples, totalSamples - offset);
    chunkCount = chunkCount + 1;
    rx = readProcessedChunkSilent(params, offset, chunkSamples);

    localPeaks = detectChunkCandidates(rx, offset, template, batch);
    rawPeakCount = rawPeakCount + numel(localPeaks);
    candidates = [candidates; localPeaks(:)]; %#ok<AGROW>

    if mod(chunkCount, 10) == 0 || ...
            offset + batch.coarse_step_samples >= totalSamples
        fprintf('  coarse chunk %d | offset=%d (%.1f%%) | peaks so far=%d\n', ...
            chunkCount, offset, 100*offset / max(totalSamples, 1), ...
            rawPeakCount);
    end

    if offset + chunkSamples >= totalSamples
        break;
    end
    offset = offset + batch.coarse_step_samples;
end

candidates = mergeCandidates(candidates, batch.candidate_merge_samples);
% Keep candidates that still leave room for a fine window.
maxStart = max(0, totalSamples - batch.min_window_samples);
candidates = candidates(candidates <= maxStart);

stats = struct( ...
    'chunk_count', chunkCount, ...
    'raw_peak_count', rawPeakCount, ...
    'decimation', D);
end

function peaks = detectChunkCandidates(rx, sampleOffset, template, batch)
D = batch.coarse_decimation;
rxDs = rx(1:D:end);
if numel(rxDs) < 32
    peaks = zeros(0, 1);
    return;
end

% --- Energy gate on decimated magnitude-squared ---
power = abs(rxDs).^2;
smoothLen = max(3, round(batch.energy_smooth_rx_samples / D));
energy = movmean(power, smoothLen);
energyMedian = median(energy);
energySigma = 1.4826*median(abs(energy - energyMedian));
energyThr = energyMedian + batch.energy_threshold_sigma*max(energySigma, eps);
energyMask = energy > energyThr;

metric = energy;
if batch.use_coarse_correlation && numel(template.preamble_ds) >= 4 && ...
        numel(rxDs) > numel(template.preamble_ds)
    matched = fftfilt(flipud(conj(template.preamble_ds)), rxDs);
    energyNorm = sqrt(movsum(abs(rxDs).^2, ...
        [numel(template.preamble_ds)-1, 0])) + eps;
    corrScore = abs(matched) ./ energyNorm;
    % Accumulate several noncoherent, symbol-spaced correlations. Using
    % rounded cumulative shifts (rather than one rounded period) preserves
    % the fractional decimated-grid period over multiple repetitions.
    repetitionCount = min(batch.coarse_correlation_repetitions, ...
        max(1, floor((numel(corr_score)-1)*D / ...
        max(template.preamble_rx_length, 1)) + 1));
    shifts = round((0:repetitionCount-1)* ...
        template.preamble_rx_length / D);
    validLength = numel(corr_score) - shifts(end);
    repeatedScore = zeros(size(corr_score));
    for r = 1:repetitionCount
        repeatedScore(1:validLength) = ...
            repeatedScore(1:validLength) + ...
            corrScore(1+shifts(r):validLength+shifts(r));
    end
    repeatedScore(1:validLength) = ...
        repeatedScore(1:validLength) / repetitionCount;
    corrValid = repeatedScore(1:validLength);
    corrMedian = median(corrValid);
    corrSigma = 1.4826*median(abs(corrValid - corrMedian));
    corrThr = corrMedian + batch.corr_threshold_sigma*max(corrSigma, eps);
    metric = repeatedScore;
    % A UWB preamble can be well below a long-window energy threshold.
    % Correlation is therefore independent by default; callers may restore
    % the stricter AND gate for captures with many false correlations.
    if batch.require_energy_gate_for_correlation
        metric(~energyMask) = 0;
    end
    peakThr = corrThr;
else
    if ~any(energyMask)
        peaks = zeros(0, 1);
        return;
    end
    peakThr = energyThr;
end

minSep = max(1, round(batch.candidate_merge_samples / D));
if exist('findpeaks', 'file') == 2
    [~, locs] = findpeaks(metric, ...
        'MinPeakHeight', peakThr, ...
        'MinPeakDistance', minSep);
else
    locs = simpleFindPeaks(metric, peakThr, minSep);
end

if isempty(locs)
    peaks = zeros(0, 1);
    return;
end

% Map decimated peak index -> absolute capture sample, then back up a little
% so the fine window starts before the burst / correlation peak.
peaks = sampleOffset + (double(locs(:)) - 1)*D;
peaks = max(0, peaks - batch.pre_packet_guard_samples);
end

function locs = simpleFindPeaks(metric, threshold, minSep)
%SIMPLEFINDPEAKS Minimal peak picker when Signal Toolbox is unavailable.
locs = zeros(0, 1);
n = numel(metric);
if n < 3
    return;
end
candidate = false(n, 1);
for k = 2:n-1
    if metric(k) >= threshold && ...
            metric(k) >= metric(k-1) && metric(k) >= metric(k+1)
        candidate(k) = true;
    end
end
idx = find(candidate);
if isempty(idx)
    return;
end
% Greedy keep of strongest peaks with separation.
[~, order] = sort(metric(idx), 'descend');
idx = idx(order);
keep = false(size(idx));
for k = 1:numel(idx)
    if all(abs(idx(k) - idx(keep)) >= minSep)
        keep(k) = true;
    end
end
locs = sort(idx(keep));
end

function merged = mergeCandidates(candidates, mergeSamples)
if isempty(candidates)
    merged = zeros(0, 1);
    return;
end
candidates = sort(candidates(:));
merged = candidates(1);
for k = 2:numel(candidates)
    if candidates(k) - merged(end) > mergeSamples
        merged(end+1, 1) = candidates(k); %#ok<AGROW>
    end
end
end

function rx = readProcessedChunkSilent(params, sampleOffset, sampleNum)
%READPROCESSEDCHUNKSILENT Cheap read + tone cancel + CF shift (no logging).
c = dw1000decoder.constants();

raw = dw1000decoder.readIqRaw(params.file_name, sampleOffset, sampleNum, params.ant_num);
rx = dw1000decoder.selectIqChannel(raw, params.channel_index);

if params.enable_interference_cancellation
    if isempty(params.interference_coefficient)
        error('decode_x410_dw1000_all:MissingInterferenceCoefficient', ...
            'Silent chunk reader requires a precomputed interference coefficient.');
    end
    coefficient = params.interference_coefficient(1);
    n = sampleOffset + (0:length(rx)-1).';
    basis = dw1000decoder.synchronousTone(n, ...
        params.interference_tone_bin, params.interference_period_samples);
    rx = rx - coefficient .* basis;
end

frequencyShift = params.x410_center_frequency - params.dw1000_center_frequency;
n = sampleOffset + (0:length(rx)-1).';
rx = rx .* exp(1j*2*pi*frequencyShift*n / params.fs_rx);
rx = rx - mean(rx);
end

function absSample = absoluteRxSample(sampleOffset, workSample, fsRx, fsWork)
absSample = sampleOffset + round((workSample - 1)*fsRx / fsWork);
absSample = max(0, absSample);
end

function absEnd = estimatePacketEndSample(sampleOffset, result, params, ...
        reference, batch)
fsRx = params.fs_rx;
fsWork = reference.fs;
period = result.preamble.samples_per_repetition;
startWork = result.preamble.start_sample;

if ~isempty(result.payload.end_chip) && result.payload.end_chip > 0
    chipsPerSymbol = reference.chips_per_symbol;
    samplesPerChip = period / max(chipsPerSymbol, 1);
    endWork = startWork + result.payload.end_chip*samplesPerChip;
else
    sfdSymbols = max(1, numel(result.sfd.sequence));
    endWork = startWork + ...
        (params.preamble_repetitions + sfdSymbols + 64)*period;
end

absEnd = sampleOffset + ceil(endWork*fsRx / fsWork) + ...
    batch.post_packet_guard_samples;
end

function tf = isDuplicatePacket(frames, packetCount, absStart, tolerance)
tf = false;
for k = 1:packetCount
    if abs(frames(k).abs_start_sample - absStart) <= tolerance
        tf = true;
        return;
    end
end
end

function record = emptyFrameRecord()
record = struct( ...
    'index', {}, ...
    'window_offset', {}, ...
    'abs_start_sample', {}, ...
    'abs_end_sample', {}, ...
    'time_start_s', {}, ...
    'time_end_s', {}, ...
    'detected_repetitions', {}, ...
    'samples_per_repetition', {}, ...
    'sample_clock_error_ppm', {}, ...
    'carrier_frequency_offset_hz', {}, ...
    'sfd_name', {}, ...
    'sfd_correlation', {}, ...
    'phr_secded_pass', {}, ...
    'psdu_length_bytes', {}, ...
    'payload_bytes', {}, ...
    'fcs_received', {}, ...
    'fcs_calculated', {}, ...
    'fcs_pass', {}, ...
    'cir', {});
end

function record = packageFrameRecord(index, windowOffset, absStart, ...
        absEnd, result, params)
payloadBytes = result.payload.bytes;
if isempty(payloadBytes)
    payloadBytes = uint8([]);
end

record = struct();
record.index = index;
record.window_offset = windowOffset;
record.abs_start_sample = absStart;
record.abs_end_sample = absEnd;
record.time_start_s = absStart / params.fs_rx;
record.time_end_s = absEnd / params.fs_rx;
record.detected_repetitions = result.preamble.detected_repetitions;
record.samples_per_repetition = result.preamble.samples_per_repetition;
record.sample_clock_error_ppm = result.preamble.sample_clock_error_ppm;
record.carrier_frequency_offset_hz = ...
    result.preamble.carrier_frequency_offset_hz;
record.sfd_name = char(string(result.sfd.name));
record.sfd_correlation = result.sfd.correlation;
record.phr_secded_pass = logical(result.phr.secded_pass);
record.psdu_length_bytes = result.phr.psdu_length_bytes;
record.payload_bytes = payloadBytes(:).';
record.fcs_received = result.payload.fcs_received;
record.fcs_calculated = result.payload.fcs_calculated;
record.fcs_pass = logical(result.payload.fcs_pass);
record.cir = result.cir;
end

function writeSummaryCsv(csvFile, frames)
fid = fopen(csvFile, 'w');
if fid < 0
    warning('decode_x410_dw1000_all:CsvWriteError', ...
        'Could not write summary CSV: %s', csvFile);
    return;
end
fileGuard = onCleanup(@() fclose(fid));

fprintf(fid, ['index,window_offset,abs_start_sample,abs_end_sample,', ...
    'time_start_ms,time_end_ms,detected_repetitions,', ...
    'sample_clock_error_ppm,cfo_hz,sfd_name,sfd_correlation,', ...
    'phr_secded_pass,psdu_length_bytes,fcs_received,fcs_calculated,', ...
    'fcs_pass,payload_hex\n']);

for k = 1:numel(frames)
    frame = frames(k);
    if isempty(frame.payload_bytes)
        payloadHex = '';
    else
        payloadHex = sprintf('%02X', frame.payload_bytes);
    end
    fprintf(fid, ['%d,%d,%d,%d,%.6f,%.6f,%d,%.6f,%.6f,"%s",%.6f,', ...
        '%d,%d,0x%04X,0x%04X,%d,"%s"\n'], ...
        frame.index, frame.window_offset, frame.abs_start_sample, ...
        frame.abs_end_sample, frame.time_start_s*1e3, ...
        frame.time_end_s*1e3, frame.detected_repetitions, ...
        frame.sample_clock_error_ppm, frame.carrier_frequency_offset_hz, ...
        frame.sfd_name, frame.sfd_correlation, frame.phr_secded_pass, ...
        frame.psdu_length_bytes, frame.fcs_received, ...
        frame.fcs_calculated, frame.fcs_pass, payloadHex);
end
clear fileGuard;
end