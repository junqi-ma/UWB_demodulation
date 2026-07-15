function results = decode_x410_dw1000_all(options, batch)
%DECODE_X410_DW1000_ALL Decode every packet in an X410 capture file.
%   RESULTS = DECODE_X410_DW1000_ALL(OPTIONS, BATCH) first runs a cheap
%   coarse energy / decimated-correlation pre-screen over the full .dat,
%   then fully decodes only the surviving candidates and saves CIR data.
%
%   OPTIONS uses the same fields as decode_x410_dw1000 / run_decode_*.
%   BATCH controls coarse scan, fine decode, and output paths.

if nargin < 1 || isempty(options)
    options = struct();
end
if nargin < 2 || isempty(batch)
    batch = struct();
end

base_params = dw1000decoder.mergeOptions( ...
    dw1000decoder.defaultOptions(), options);
batch = mergeBatchOptions(batch, base_params);

if ~isfolder(batch.output_directory)
    mkdir(batch.output_directory);
end

total_samples = countCaptureSamples(base_params);
if total_samples < batch.min_window_samples
    error('Capture has only %d complex samples; need at least %d.', ...
        total_samples, batch.min_window_samples);
end

% Estimate the interference coefficient once and reuse it everywhere.
if base_params.enable_interference_cancellation && ...
        isempty(base_params.interference_coefficient)
    base_params.interference_coefficient = estimateInterferenceCoefficient( ...
        base_params, total_samples);
end

% Build the reference once for coarse correlation and packet-end estimates.
reference = dw1000decoder.buildDw1000Reference(base_params);
addpath(base_params.helper_path);
coarse_template = buildCoarseTemplate(base_params, reference, batch);

fprintf('\n========== Full-file DW1000 decode (P0 coarse+fine) ==========\n');
fprintf('Capture file                 : %s\n', base_params.file_name);
fprintf('Total complex samples        : %d (%.3f ms @ %.2f MHz)\n', ...
    total_samples, total_samples/base_params.fs_rx*1e3, ...
    base_params.fs_rx/1e6);
fprintf('Coarse chunk/step            : %d / %d\n', ...
    batch.coarse_chunk_samples, batch.coarse_step_samples);
fprintf('Coarse decimation            : %d\n', batch.coarse_decimation);
fprintf('Fine decode window           : %d\n', batch.window_samples);
fprintf('==============================================================\n\n');

%% -------------------- Stage 1: coarse candidate pre-screen --------------------
tic_coarse = tic;
[candidates, coarse_stats] = findCoarseCandidates( ...
    base_params, coarse_template, batch, total_samples);
coarse_seconds = toc(tic_coarse);

fprintf(['Coarse scan done in %.1f s | chunks=%d | raw peaks=%d | ', ...
    'merged candidates=%d\n\n'], ...
    coarse_seconds, coarse_stats.chunk_count, ...
    coarse_stats.raw_peak_count, numel(candidates));

%% -------------------- Stage 2: fine decode only at candidates --------------------
frames = emptyFrameRecord();
packet_count = 0;
attempt_count = 0;
next_allowed_sample = 0;
tic_fine = tic;

for cand_index = 1:numel(candidates)
    candidate = candidates(cand_index);
    if candidate < next_allowed_sample
        continue;
    end

    offset = max(0, candidate-batch.pre_packet_guard_samples);
    if offset + batch.min_window_samples > total_samples
        continue;
    end
    window_samples = min(batch.window_samples, total_samples-offset);
    attempt_count = attempt_count+1;

    window_options = options;
    window_options.sample_offset = offset;
    window_options.sample_num = window_samples;
    window_options.show_plots = false;
    window_options.interference_coefficient = ...
        base_params.interference_coefficient;

    fprintf(['---- Fine decode %d/%d | candidate=%d | ', ...
        'offset=%d | samples=%d ----\n'], ...
        attempt_count, numel(candidates), candidate, offset, window_samples);

    try
        result = decode_x410_dw1000(window_options);
    catch decode_error
        fprintf('  Decode failed: %s\n', decode_error.message);
        % Keep searching nearby candidates; do not jump over a long gap.
        continue;
    end

    abs_start = absoluteRxSample( ...
        offset, result.preamble.start_sample, ...
        base_params.fs_rx, reference.fs);
    abs_end = estimatePacketEndSample( ...
        offset, result, base_params, reference, batch);

    if isDuplicatePacket(frames, packet_count, abs_start, ...
            batch.start_tolerance_samples)
        fprintf('  Duplicate packet near abs_start=%d; skipping.\n', ...
            abs_start);
        next_allowed_sample = max(next_allowed_sample, abs_end);
        continue;
    end

    if batch.require_fcs_pass && ~result.payload.fcs_pass
        fprintf('  Packet rejected: FCS failed at abs_start=%d.\n', ...
            abs_start);
        next_allowed_sample = max(next_allowed_sample, abs_end);
        continue;
    end

    packet_count = packet_count+1;
    frames(packet_count) = packageFrameRecord( ...
        packet_count, offset, abs_start, abs_end, result, base_params);

    fprintf(['  Saved packet #%d | abs_start=%d | t=%.3f ms | ', ...
        'SFD=%s | corr=%.3f | FCS=%d\n'], ...
        packet_count, abs_start, frames(packet_count).time_start_s*1e3, ...
        frames(packet_count).sfd_name, ...
        frames(packet_count).sfd_correlation, ...
        frames(packet_count).fcs_pass);

    if batch.save_individual_cir
        cir_file = fullfile(batch.output_directory, ...
            sprintf('cir_%03d.mat', packet_count));
        cir = frames(packet_count).cir; %#ok<NASGU>
        meta = frames(packet_count); %#ok<NASGU>
        save(cir_file, 'cir', 'meta', '-v7.3');
    end

    next_allowed_sample = max(next_allowed_sample, abs_end);
end
fine_seconds = toc(tic_fine);

if packet_count == 0
    frames = emptyFrameRecord();
    frames(1) = [];
else
    frames = frames(1:packet_count);
end

results = struct();
results.file_name = base_params.file_name;
results.total_samples = total_samples;
results.duration_s = total_samples/base_params.fs_rx;
results.coarse_seconds = coarse_seconds;
results.fine_seconds = fine_seconds;
results.coarse_chunk_count = coarse_stats.chunk_count;
results.coarse_raw_peak_count = coarse_stats.raw_peak_count;
results.candidate_count = numel(candidates);
results.candidates = candidates(:);
results.attempt_count = attempt_count;
results.packet_count = packet_count;
if packet_count == 0
    results.fcs_pass_count = 0;
else
    results.fcs_pass_count = sum([frames.fcs_pass]);
end
results.params = base_params;
results.batch = batch;
results.frames = frames;
results.cir_delay_ns = [];
results.cir_values = [];

if packet_count > 0
    results.cir_delay_ns = frames(1).cir.delay_ns(:);
    cir_len = numel(results.cir_delay_ns);
    results.cir_values = complex(zeros(cir_len, packet_count));
    for k = 1:packet_count
        values = frames(k).cir.values(:);
        n = min(cir_len, numel(values));
        results.cir_values(1:n, k) = values(1:n);
    end
end

save(batch.mat_file, 'results', '-v7.3');
writeSummaryCsv(batch.summary_csv, frames);

fprintf('\nSaved %d packet(s) to:\n  %s\n  %s\n', ...
    packet_count, batch.mat_file, batch.summary_csv);
fprintf('Timing: coarse %.1f s | fine %.1f s | fine attempts %d\n', ...
    coarse_seconds, fine_seconds, attempt_count);
end

%% ------------------------------------------------------------------------
function batch = mergeBatchOptions(batch, params)
defaults = struct( ...
    'coarse_chunk_samples', 4e6, ...
    'coarse_step_samples', 3e6, ...
    'coarse_decimation', 32, ...
    'energy_smooth_rx_samples', 8192, ...
    'energy_threshold_sigma', 6, ...
    'use_coarse_correlation', true, ...
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

[~, capture_stem] = fileparts(params.file_name);
if strlength(string(batch.output_directory)) == 0
    batch.output_directory = fullfile(pwd, 'decoded_results', capture_stem);
end
if strlength(string(batch.mat_file)) == 0
    batch.mat_file = fullfile(batch.output_directory, 'all_frames_cir.mat');
end
if strlength(string(batch.summary_csv)) == 0
    batch.summary_csv = fullfile(batch.output_directory, 'frame_summary.csv');
end

integer_fields = { ...
    'coarse_chunk_samples', 'coarse_step_samples', 'coarse_decimation', ...
    'energy_smooth_rx_samples', 'candidate_merge_samples', ...
    'pre_packet_guard_samples', 'window_samples', 'search_step_samples', ...
    'post_packet_guard_samples', 'start_tolerance_samples', ...
    'min_window_samples'};
for k = 1:numel(integer_fields)
    name = integer_fields{k};
    batch.(name) = max(1, round(batch.(name)));
end
batch.energy_threshold_sigma = max(0, double(batch.energy_threshold_sigma));
batch.corr_threshold_sigma = max(0, double(batch.corr_threshold_sigma));
batch.use_coarse_correlation = logical(batch.use_coarse_correlation);
batch.require_fcs_pass = logical(batch.require_fcs_pass);
batch.save_individual_cir = logical(batch.save_individual_cir);

if batch.coarse_step_samples > batch.coarse_chunk_samples
    warning(['coarse_step_samples > coarse_chunk_samples; ', ...
        'clamping step to chunk size.']);
    batch.coarse_step_samples = batch.coarse_chunk_samples;
end
end

function total_samples = countCaptureSamples(params)
info = dir(params.file_name);
if isempty(info)
    error('Cannot find capture file: %s', params.file_name);
end
bytes_per_complex_sample = params.ant_num*4; % interleaved int16 I/Q
total_samples = floor(info.bytes/bytes_per_complex_sample);
end

function coefficient = estimateInterferenceCoefficient(params, total_samples)
quiet_offset = params.interference_quiet_offset;
quiet_num = params.interference_quiet_num;
if quiet_offset < 0 || quiet_offset >= total_samples
    error('interference_quiet_offset is outside the capture.');
end
quiet_num = min(quiet_num, total_samples-quiet_offset);
if quiet_num < params.interference_period_samples
    error('Not enough samples available for interference estimation.');
end

fid = fopen(params.file_name, 'rb');
if fid < 0
    error('Cannot open capture: %s', params.file_name);
end
file_guard = onCleanup(@() fclose(fid));
status = fseek(fid, quiet_offset*params.ant_num*4, 'bof');
if status ~= 0
    error('Failed to seek to the interference-estimation interval.');
end
raw_quiet = fread(fid, [2*params.ant_num, quiet_num], 'int16=>double');
if size(raw_quiet, 2) < quiet_num
    error('Could not read the interference-estimation interval.');
end
rx_quiet = dw1000decoder.selectIqChannel(raw_quiet, params.channel_index);
quiet_n = quiet_offset+(0:length(rx_quiet)-1).';
quiet_basis = dw1000decoder.synchronousTone(quiet_n, ...
    params.interference_tone_bin, params.interference_period_samples);
coefficient = mean(rx_quiet.*conj(quiet_basis));
clear file_guard;

fprintf('Precomputed interference coefficient once for full-file scan.\n');
fprintf('  Amplitude: %.3f ADC counts, phase: %.3f deg\n', ...
    abs(coefficient), angle(coefficient)*180/pi);
end

function template = buildCoarseTemplate(params, reference, batch)
%BUILDCOARSETEMPLATE Map one preamble symbol to the coarse decimated grid.
[p, q] = rat(params.fs_rx/reference.fs, 1e-12);
pref_rx = resample(reference.preamble_waveform, p, q);
pref_rx = pref_rx(:);
D = batch.coarse_decimation;
pref_ds = pref_rx(1:D:end);
pref_ds = pref_ds/(norm(pref_ds)+eps);
template = struct( ...
    'decimation', D, ...
    'preamble_ds', pref_ds, ...
    'preamble_rx_length', numel(pref_rx));
end

function [candidates, stats] = findCoarseCandidates(params, template, ...
        batch, total_samples)
candidates = zeros(0, 1);
raw_peak_count = 0;
chunk_count = 0;
offset = 0;
D = batch.coarse_decimation;

fprintf('Stage 1/2: coarse pre-screen over full capture...\n');
while offset + batch.min_window_samples <= total_samples
    chunk_samples = min(batch.coarse_chunk_samples, total_samples-offset);
    chunk_count = chunk_count+1;
    rx = readProcessedChunkSilent(params, offset, chunk_samples);

    local_peaks = detectChunkCandidates(rx, offset, template, batch);
    raw_peak_count = raw_peak_count+numel(local_peaks);
    candidates = [candidates; local_peaks(:)]; %#ok<AGROW>

    if mod(chunk_count, 10) == 0 || ...
            offset+batch.coarse_step_samples >= total_samples
        fprintf('  coarse chunk %d | offset=%d (%.1f%%) | peaks so far=%d\n', ...
            chunk_count, offset, 100*offset/max(total_samples, 1), ...
            raw_peak_count);
    end

    if offset + chunk_samples >= total_samples
        break;
    end
    offset = offset+batch.coarse_step_samples;
end

candidates = mergeCandidates(candidates, batch.candidate_merge_samples);
% Keep candidates that still leave room for a fine window.
max_start = max(0, total_samples-batch.min_window_samples);
candidates = candidates(candidates <= max_start);

stats = struct( ...
    'chunk_count', chunk_count, ...
    'raw_peak_count', raw_peak_count, ...
    'decimation', D);
end

function peaks = detectChunkCandidates(rx, sample_offset, template, batch)
D = batch.coarse_decimation;
rx_ds = rx(1:D:end);
if numel(rx_ds) < 32
    peaks = zeros(0, 1);
    return;
end

% --- Energy gate on decimated magnitude-squared ---
power = abs(rx_ds).^2;
smooth_len = max(3, round(batch.energy_smooth_rx_samples/D));
energy = movmean(power, smooth_len);
energy_median = median(energy);
energy_sigma = 1.4826*median(abs(energy-energy_median));
energy_thr = energy_median+batch.energy_threshold_sigma*max(energy_sigma, eps);
energy_mask = energy > energy_thr;

if ~any(energy_mask)
    peaks = zeros(0, 1);
    return;
end

metric = energy;
if batch.use_coarse_correlation && numel(template.preamble_ds) >= 4 && ...
        numel(rx_ds) > numel(template.preamble_ds)
    matched = fftfilt(flipud(conj(template.preamble_ds)), rx_ds);
    energy_norm = sqrt(movsum(abs(rx_ds).^2, ...
        [numel(template.preamble_ds)-1, 0]))+eps;
    corr_score = abs(matched)./energy_norm;
    corr_median = median(corr_score);
    corr_sigma = 1.4826*median(abs(corr_score-corr_median));
    corr_thr = corr_median+batch.corr_threshold_sigma*max(corr_sigma, eps);
    % Keep only correlation peaks that also sit in energetic regions.
    metric = corr_score;
    metric(~energy_mask) = 0;
    peak_thr = corr_thr;
else
    peak_thr = energy_thr;
end

min_sep = max(1, round(batch.candidate_merge_samples/D));
if exist('findpeaks', 'file') == 2
    [~, locs] = findpeaks(metric, ...
        'MinPeakHeight', peak_thr, ...
        'MinPeakDistance', min_sep);
else
    locs = simpleFindPeaks(metric, peak_thr, min_sep);
end

if isempty(locs)
    peaks = zeros(0, 1);
    return;
end

% Map decimated peak index -> absolute capture sample, then back up a little
% so the fine window starts before the burst / correlation peak.
peaks = sample_offset+(double(locs(:))-1)*D;
peaks = max(0, peaks-batch.pre_packet_guard_samples);
end

function locs = simpleFindPeaks(metric, threshold, min_sep)
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
    if all(abs(idx(k)-idx(keep)) >= min_sep)
        keep(k) = true;
    end
end
locs = sort(idx(keep));
end

function merged = mergeCandidates(candidates, merge_samples)
if isempty(candidates)
    merged = zeros(0, 1);
    return;
end
candidates = sort(candidates(:));
merged = candidates(1);
for k = 2:numel(candidates)
    if candidates(k)-merged(end) > merge_samples
        merged(end+1, 1) = candidates(k); %#ok<AGROW>
    end
end
end

function rx = readProcessedChunkSilent(params, sample_offset, sample_num)
%READPROCESSEDCHUNKSILENT Cheap read + tone cancel + CF shift (no logging).
fid = fopen(params.file_name, 'rb');
if fid < 0
    error('Cannot open capture: %s', params.file_name);
end
file_guard = onCleanup(@() fclose(fid));
status = fseek(fid, sample_offset*params.ant_num*4, 'bof');
if status ~= 0
    error('Failed to seek to sample offset %d.', sample_offset);
end
raw = fread(fid, [2*params.ant_num, sample_num], 'int16=>double');
if size(raw, 2) ~= sample_num
    error('Could not read %d samples at offset %d.', sample_num, sample_offset);
end
rx = dw1000decoder.selectIqChannel(raw, params.channel_index);
clear file_guard;

if params.enable_interference_cancellation
    if isempty(params.interference_coefficient)
        error('Silent chunk reader requires a precomputed interference coefficient.');
    end
    coefficient = params.interference_coefficient(1);
    n = sample_offset+(0:length(rx)-1).';
    basis = dw1000decoder.synchronousTone(n, ...
        params.interference_tone_bin, params.interference_period_samples);
    rx = rx-coefficient.*basis;
end

frequency_shift = params.x410_center_frequency-params.dw1000_center_frequency;
n = sample_offset+(0:length(rx)-1).';
rx = rx.*exp(1j*2*pi*frequency_shift*n/params.fs_rx);
rx = rx-mean(rx);
end

function abs_sample = absoluteRxSample(sample_offset, work_sample, fs_rx, fs_work)
abs_sample = sample_offset+round((work_sample-1)*fs_rx/fs_work);
abs_sample = max(0, abs_sample);
end

function abs_end = estimatePacketEndSample(sample_offset, result, params, ...
        reference, batch)
fs_rx = params.fs_rx;
fs_work = reference.fs;
period = result.preamble.samples_per_repetition;
start_work = result.preamble.start_sample;

if ~isempty(result.payload.end_chip) && result.payload.end_chip > 0
    chips_per_symbol = reference.chips_per_symbol;
    samples_per_chip = period/max(chips_per_symbol, 1);
    end_work = start_work+result.payload.end_chip*samples_per_chip;
else
    sfd_symbols = max(1, numel(result.sfd.sequence));
    end_work = start_work+ ...
        (params.preamble_repetitions+sfd_symbols+64)*period;
end

abs_end = sample_offset+ceil(end_work*fs_rx/fs_work)+ ...
    batch.post_packet_guard_samples;
end

function tf = isDuplicatePacket(frames, packet_count, abs_start, tolerance)
tf = false;
for k = 1:packet_count
    if abs(frames(k).abs_start_sample-abs_start) <= tolerance
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

function record = packageFrameRecord(index, window_offset, abs_start, ...
        abs_end, result, params)
payload_bytes = result.payload.bytes;
if isempty(payload_bytes)
    payload_bytes = uint8([]);
end

record = struct();
record.index = index;
record.window_offset = window_offset;
record.abs_start_sample = abs_start;
record.abs_end_sample = abs_end;
record.time_start_s = abs_start/params.fs_rx;
record.time_end_s = abs_end/params.fs_rx;
record.detected_repetitions = result.preamble.detected_repetitions;
record.samples_per_repetition = result.preamble.samples_per_repetition;
record.sample_clock_error_ppm = result.preamble.sample_clock_error_ppm;
record.carrier_frequency_offset_hz = ...
    result.preamble.carrier_frequency_offset_hz;
record.sfd_name = char(string(result.sfd.name));
record.sfd_correlation = result.sfd.correlation;
record.phr_secded_pass = logical(result.phr.secded_pass);
record.psdu_length_bytes = result.phr.psdu_length_bytes;
record.payload_bytes = payload_bytes(:).';
record.fcs_received = result.payload.fcs_received;
record.fcs_calculated = result.payload.fcs_calculated;
record.fcs_pass = logical(result.payload.fcs_pass);
record.cir = result.cir;
end

function writeSummaryCsv(csv_file, frames)
fid = fopen(csv_file, 'w');
if fid < 0
    warning('Could not write summary CSV: %s', csv_file);
    return;
end
cleanup_obj = onCleanup(@() fclose(fid));

fprintf(fid, ['index,window_offset,abs_start_sample,abs_end_sample,', ...
    'time_start_ms,time_end_ms,detected_repetitions,', ...
    'sample_clock_error_ppm,cfo_hz,sfd_name,sfd_correlation,', ...
    'phr_secded_pass,psdu_length_bytes,fcs_received,fcs_calculated,', ...
    'fcs_pass,payload_hex\n']);

for k = 1:numel(frames)
    frame = frames(k);
    if isempty(frame.payload_bytes)
        payload_hex = '';
    else
        payload_hex = sprintf('%02X', frame.payload_bytes);
    end
    fprintf(fid, ['%d,%d,%d,%d,%.6f,%.6f,%d,%.6f,%.6f,"%s",%.6f,', ...
        '%d,%d,0x%04X,0x%04X,%d,"%s"\n'], ...
        frame.index, frame.window_offset, frame.abs_start_sample, ...
        frame.abs_end_sample, frame.time_start_s*1e3, ...
        frame.time_end_s*1e3, frame.detected_repetitions, ...
        frame.sample_clock_error_ppm, frame.carrier_frequency_offset_hz, ...
        frame.sfd_name, frame.sfd_correlation, frame.phr_secded_pass, ...
        frame.psdu_length_bytes, frame.fcs_received, ...
        frame.fcs_calculated, frame.fcs_pass, payload_hex);
end
clear cleanup_obj;
end
