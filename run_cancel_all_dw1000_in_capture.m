%% Regenerate and subtract reliably decoded DW1000 frames
% The default is a short validation run. It first extracts a small interval
% from the original capture, scans/cancels only that interval, and writes
% separate before/after files plus a comparison figure. After validating
% the result, set validation.enabled=false to process the complete capture.
clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% -------------------- User configuration --------------------
source_input_file = 'F:\UWB基带数据\DW1000_2.dat';
output_dir = fullfile(project_dir, 'decoded_results');

validation = struct();
validation.enabled = true;
validation.source_sample_offset = 400000;
validation.sample_num = 900000;
validation.original_file = fullfile(output_dir, ...
    'DW1000_2_validation_original.dat');
validation.cancelled_file = fullfile(output_dir, ...
    'DW1000_2_validation_cancelled.dat');
validation.figure_file = fullfile(output_dir, ...
    'DW1000_2_validation_comparison.png');

if validation.enabled
    input_file = validation.original_file;
    output_file = validation.cancelled_file;
else
    input_file = source_input_file;
    output_file = fullfile(output_dir, ...
        'DW1000_2_all_dw1000_cancelled.dat');
end

options = struct();
options.file_name = input_file;
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
if ~isfile(source_input_file)
    error('Source capture not found: %s', source_input_file);
end
if ~isfolder(output_dir)
    mkdir(output_dir);
end
if validation.enabled
    fprintf('\nPreparing short validation capture...\n');
    extractIqInterval(source_input_file, input_file, ...
        validation.source_sample_offset, validation.sample_num, ...
        options.ant_num);
    options.interference_quiet_offset = 0;
    options.interference_quiet_num = min(65536, ...
        floor(validation.sample_num/4));
    batch.coarse_chunk_samples = min(batch.coarse_chunk_samples, ...
        validation.sample_num);
    batch.coarse_step_samples = min(batch.coarse_step_samples, ...
        max(batch.min_window_samples, ...
        validation.sample_num-batch.min_window_samples));
    batch.window_samples = min(batch.window_samples, ...
        validation.sample_num);
end

if ~isfile(input_file)
    error('Working capture not found: %s', input_file);
end
if options.channel_index < 1 || options.channel_index > options.ant_num
    error('channel_index must be in the range 1..ant_num.');
end
input_info = dir(input_file);
bytes_per_sample = 4*options.ant_num;
if mod(input_info.bytes, bytes_per_sample) ~= 0
    error('Input byte count is not a whole number of %d-channel IQ samples.', ...
        options.ant_num);
end
total_samples = input_info.bytes/bytes_per_sample;

if strcmpi(char(java.io.File(input_file).getCanonicalPath()), ...
        char(java.io.File(output_file).getCanonicalPath()))
    error('The output_file must be different from input_file.');
end

[~, capture_stem] = fileparts(input_file);
scan_dir = fullfile(output_dir, [capture_stem '_dw1000_scan']);
batch.output_directory = scan_dir;
batch.mat_file = fullfile(scan_dir, 'dw1000_all_frames.mat');
batch.summary_csv = fullfile(scan_dir, 'dw1000_all_frames.csv');

%% -------------------- Discover reliable frames --------------------
fprintf('\nStep 1/3: scanning the working capture for FCS-valid DW1000 frames...\n');
results = decode_x410_dw1000_all(options, batch);
if results.packet_count == 0
    warning(['No FCS-valid DW1000 frame was found. ', ...
        'The output will be an unchanged copy.']);
end

%% -------------------- Copy complete capture before patching frames --------------------
fprintf('\nStep 2/3: copying the complete capture to:\n  %s\n', output_file);
[copy_ok, copy_message] = copyfile(input_file, output_file, 'f');
if ~copy_ok
    error('Could not create output capture: %s', copy_message);
end

%% -------------------- Regenerate and subtract each frame --------------------
fprintf('\nStep 3/3: regenerating and subtracting %d frame(s)...\n', ...
    results.packet_count);
reports = emptyCancellationReport();
success_count = 0;

for k = 1:results.packet_count
    frame = results.frames(k);
    fprintf('  Frame %d/%d at %.6f ms: ', ...
        k, results.packet_count, frame.time_start_s*1e3);
    try
        report = cancelOneFrame(output_file, frame, options, results.params, ...
            cancel, total_samples);
        reports(end+1) = report; %#ok<SAGROW>
        success_count = success_count+1;
        fprintf(['removed %.2f dB (fit domain), corr %.3f, ', ...
            'CFO %+.2f kHz, clipped %d\n'], ...
            report.fit_suppression_db, report.validation_correlation, ...
            report.fitted_cfo_hz/1e3, report.clipped_sample_count);
    catch frame_error
        report = failedCancellationReport(k, frame, frame_error.message);
        reports(end+1) = report; %#ok<SAGROW>
        fprintf('SKIPPED (%s)\n', frame_error.message);
    end
end

%% -------------------- Save cancellation metadata --------------------
metadata_file = fullfile(output_dir, ...
    [capture_stem '_all_dw1000_cancelled_metadata.mat']);
summary_file = fullfile(output_dir, ...
    [capture_stem '_all_dw1000_cancelled_summary.csv']);
writeCancellationCsv(summary_file, reports);
save(metadata_file, 'results', 'reports', 'options', 'batch', 'cancel', ...
    'source_input_file', 'input_file', 'output_file', 'validation', ...
    'total_samples', '-v7.3');

fprintf('\n========== All-DW1000 cancellation summary ==========\n');
fprintf('Input                         : %s\n', input_file);
fprintf('Output                        : %s\n', output_file);
fprintf('Complex samples / channels    : %d / %d\n', ...
    total_samples, options.ant_num);
fprintf('Detected frames               : %d\n', results.packet_count);
fprintf('Successfully cancelled        : %d\n', success_count);
fprintf('Skipped                       : %d\n', ...
    results.packet_count-success_count);
output_info = dir(output_file);
fprintf('Output bytes                  : %d (same as input: %d)\n', ...
    output_info.bytes, output_info.bytes == input_info.bytes);
fprintf('Metadata                      : %s\n', metadata_file);
fprintf('CSV summary                   : %s\n', summary_file);
fprintf('=====================================================\n');

if validation.enabled
    fprintf('\nCreating short-capture before/after comparison...\n');
    plotValidationComparison(input_file, output_file, options, reports, ...
        validation.source_sample_offset, validation.figure_file);
    fprintf('Validation source interval    : %d..%d\n', ...
        validation.source_sample_offset, ...
        validation.source_sample_offset+validation.sample_num-1);
    fprintf('Validation original           : %s\n', input_file);
    fprintf('Validation cancelled          : %s\n', output_file);
    fprintf('Validation figure             : %s\n', ...
        validation.figure_file);
end

assignin('base', 'dw1000_all_results', results);
assignin('base', 'dw1000_cancellation_reports', reports);

%% ------------------------------------------------------------------------
function report = cancelOneFrame(output_file, frame, options, scan_params, ...
        cancel, total_samples)
% Reuse the exact bytes and CIR accepted by the scan. Re-running the
% unconstrained decoder from a differently anchored window can lock to a
% different peak and previously made regeneration disagree with the scan.
if cancel.require_fcs_pass && ~frame.fcs_pass
    error('The scan result did not pass FCS.');
end
if isempty(frame.payload_bytes)
    error('The scan result contains no PSDU bytes.');
end
decoded = struct();
decoded.payload = struct('bytes', uint8(frame.payload_bytes(:)), ...
    'fcs_pass', logical(frame.fcs_pass));
decoded.sfd = struct('name', frame.sfd_name);
decoded.cir = frame.cir;

tx_options = struct();
tx_options.fs_tx = options.fs_rx;
tx_options.x410_center_frequency = options.x410_center_frequency;
tx_options.qm35_center_frequency = options.dw1000_center_frequency;
tx_options.phy_mode = '802.15.4a';
tx_options.preamble_repetitions = options.preamble_repetitions;
tx_options.code_index = options.code_index;
tx_options.sfd_number = 0;
tx_options.sfd_sequence = selectSfdSequence(decoded, scan_params);
tx_options.peak_amplitude = 0.8;
tx_options.guard_samples = 0;
tx_options.require_fcs_pass = cancel.require_fcs_pass;
tx = generate_qm35_tx_from_decode(decoded, tx_options);
channel = apply_estimated_cir_to_qm35(tx, decoded.cir);
replica = channel.waveform_x410(:);

% Read enough current-output samples to cover alignment search and replica.
nominal_start = frame.abs_start_sample;
read_first = max(0, nominal_start-cancel.alignment_search_samples);
read_last = min(total_samples-1, nominal_start+numel(replica)-1+ ...
    cancel.alignment_search_samples);
[raw, received] = readIqSegment(output_file, read_first, ...
    read_last-read_first+1, options.ant_num, options.channel_index);

% Suppress the known narrow tone only in the fitting copy. The actual saved
% residual below is formed from RECEIVED, so unrelated content is preserved.
fit_received = received;
if options.enable_interference_cancellation && ...
        isfield(scan_params, 'interference_coefficient') && ...
        ~isempty(scan_params.interference_coefficient)
    absolute_n = read_first+(0:numel(fit_received)-1).';
    tone = dw1000decoder.synchronousTone(absolute_n, ...
        options.interference_tone_bin, options.interference_period_samples);
    fit_received = fit_received-scan_params.interference_coefficient(1).*tone;
end

nominal_local = nominal_start-read_first+1;
[start_local, alignment_correlation] = alignReplica( ...
    fit_received, replica, nominal_local, options, cancel);
available = min(numel(replica), numel(received)-start_local+1);
if available < 2
    error('Regenerated waveform falls outside the capture.');
end
replica = replica(1:available);
observed_for_fit = fit_received(start_local:start_local+available-1);

fitted_cfo_hz = fitReplicaCfo(observed_for_fit, replica, options, cancel);
n = (0:available-1).';
replica_cfo = replica.*exp(1j*2*pi*fitted_cfo_hz*n/options.fs_rx);

% Fit gain only on the stable part of SYNC. PHR/payload samples are kept
% out of the fit so corrupted body data cannot make a bad model look good.
period = 1016/998.4e6*options.fs_rx;
stable_first = round((cancel.stable_sync_first-1)*period)+1;
stable_last = min(round(options.preamble_repetitions*period), available);
if stable_first >= stable_last
    error('The stable SYNC fitting interval is outside the replica.');
end
fit_indices = stable_first:stable_last;
gain = (replica_cfo(fit_indices)'*observed_for_fit(fit_indices))/ ...
    (replica_cfo(fit_indices)'*replica_cfo(fit_indices)+eps);
modeled = gain*replica_cfo;

if alignment_correlation < cancel.min_alignment_correlation
    error('Alignment correlation %.3f is below threshold %.3f.', ...
        alignment_correlation, cancel.min_alignment_correlation);
end

validation_correlation = abs( ...
    replica_cfo(fit_indices)'*observed_for_fit(fit_indices))/ ...
    (norm(replica_cfo(fit_indices))* ...
    norm(observed_for_fit(fit_indices))+eps);
fit_before = observed_for_fit(fit_indices);
fit_after = fit_before-modeled(fit_indices);
fit_power_before = mean(abs(fit_before).^2);
fit_power_after = mean(abs(fit_after).^2);
fit_suppression_db = ...
    10*log10(fit_power_before/(fit_power_after+eps));
if validation_correlation < cancel.min_validation_correlation
    error('Validation correlation %.3f is below threshold %.3f.', ...
        validation_correlation, cancel.min_validation_correlation);
end
if fit_suppression_db < cancel.min_fit_suppression_db
    error('Fit suppression %.3f dB is below threshold %.3f dB.', ...
        fit_suppression_db, cancel.min_fit_suppression_db);
end

before = received(start_local:start_local+available-1);
after = before-modeled;
saved_power_before = mean(abs(before).^2);
saved_float_power_after = mean(abs(after).^2);
received(start_local:start_local+available-1) = after;
[raw, clipped_sample_count] = replaceIqChannel( ...
    raw, received, options.channel_index, cancel.output_headroom);
writeIqSegment(output_file, read_first, raw, options.ant_num);

% Validate the actual int16 samples after rounding and saturation.
[~, saved_received] = readIqSegment(output_file, read_first, ...
    size(raw, 2), options.ant_num, options.channel_index);
saved_after = saved_received(start_local:start_local+available-1);
saved_power_after = mean(abs(saved_after).^2);
saved_suppression_db = ...
    10*log10(saved_power_before/(saved_power_after+eps));

report = struct();
report.index = frame.index;
report.success = true;
report.abs_start_detected = frame.abs_start_sample;
report.abs_start_fitted = read_first+start_local-1;
report.samples_subtracted = available;
report.alignment_correlation = alignment_correlation;
report.validation_correlation = validation_correlation;
report.fitted_cfo_hz = fitted_cfo_hz;
report.complex_gain = gain;
report.fit_power_before = fit_power_before;
report.fit_power_after = fit_power_after;
report.fit_suppression_db = fit_suppression_db;
report.saved_power_before = saved_power_before;
report.saved_float_power_after = saved_float_power_after;
report.saved_power_after = saved_power_after;
report.saved_suppression_db = saved_suppression_db;
report.clipped_sample_count = clipped_sample_count;
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

function [raw, rx] = readIqSegment(file_name, sample_offset, sample_num, ...
        ant_num, channel_index)
fid = fopen(file_name, 'rb', 'ieee-le');
if fid < 0
    error('Cannot open output capture for reading: %s', file_name);
end
guard = onCleanup(@() fclose(fid));
status = fseek(fid, sample_offset*ant_num*4, 'bof');
if status ~= 0
    error('Could not seek to output sample %d.', sample_offset);
end
raw = fread(fid, [2*ant_num, sample_num], 'int16=>double');
if size(raw, 2) ~= sample_num
    error('Could not read the complete cancellation interval.');
end
rx = dw1000decoder.selectIqChannel(raw, channel_index);
clear guard;
end

function [raw, clipped_sample_count] = replaceIqChannel( ...
        raw, rx, channel_index, headroom)
upper_limit = floor(32767*headroom);
lower_limit = ceil(-32768*headroom);
i_row = 2*channel_index-1;
q_row = 2*channel_index;
clipped_sample_count = nnz(real(rx) > upper_limit | ...
    real(rx) < lower_limit | imag(rx) > upper_limit | ...
    imag(rx) < lower_limit);
raw(i_row, :) = max(lower_limit, min(upper_limit, round(real(rx)))).';
raw(q_row, :) = max(lower_limit, min(upper_limit, round(imag(rx)))).';
end

function writeIqSegment(file_name, sample_offset, raw, ant_num)
fid = fopen(file_name, 'r+b', 'ieee-le');
if fid < 0
    error('Cannot open output capture for updating: %s', file_name);
end
guard = onCleanup(@() fclose(fid));
status = fseek(fid, sample_offset*ant_num*4, 'bof');
if status ~= 0
    error('Could not seek to output sample %d for writing.', sample_offset);
end
count = fwrite(fid, int16(raw), 'int16');
if count ~= numel(raw)
    error('Only %d of %d int16 values were written.', count, numel(raw));
end
clear guard;
end

function [best_start, best_corr] = alignReplica(rx, replica, nominal_start, ...
        options, cancel)
% One HRP preamble repetition is 1017.628205 ns (1016 chips / 998.4 MHz).
period_rx = 1016/998.4e6*options.fs_rx;
repetition_count = min(cancel.alignment_preamble_repetitions, ...
    floor(numel(replica)/period_rx)-cancel.cfo_skip_initial_repetitions);
if repetition_count < 1
    error('Regenerated preamble is too short for alignment.');
end
template_length = round(repetition_count*period_rx);
template_offset = round(cancel.cfo_skip_initial_repetitions*period_rx);
template = replica(template_offset+(1:template_length));
starts = round(nominal_start)+ ...
    (-cancel.alignment_search_samples:cancel.alignment_search_samples);
scores = -inf(size(starts));
for k = 1:numel(starts)
    first = starts(k)+template_offset;
    last = first+template_length-1;
    if first < 1 || last > numel(rx)
        continue;
    end
    segment = rx(first:last);
    % Noncoherent accumulation across repetitions makes timing alignment
    % insensitive to the still-unknown carrier-frequency offset.
    repetition_scores = zeros(repetition_count, 1);
    for r = 1:repetition_count
        idx = round((r-1)*period_rx)+1:round(r*period_rx);
        a = template(idx);
        b = segment(idx);
        repetition_scores(r) = abs(a'*b)/(norm(a)*norm(b)+eps);
    end
    scores(k) = mean(repetition_scores);
end
[best_corr, best_index] = max(scores);
if ~isfinite(best_corr)
    error('No valid alignment candidate was inside the capture.');
end
best_start = starts(best_index);
end

function cfo_hz = fitReplicaCfo(received, replica, options, cancel)
period = 1016/998.4e6*options.fs_rx;
count = min(options.preamble_repetitions, ...
    floor(min(numel(received), numel(replica))/period));
if count < 8
    cfo_hz = 0;
    return;
end
correlations = complex(zeros(count, 1));
for k = 1:count
    idx = round((k-1)*period)+1:round(k*period);
    correlations(k) = replica(idx)'*received(idx);
end
phase = unwrap(angle(correlations));
time_s = round((0:count-1).'*period)/options.fs_rx;
first = min(cancel.cfo_skip_initial_repetitions+1, max(1, count-7));
fit = polyfit(time_s(first:end), phase(first:end), 1);
cfo_hz = fit(1)/(2*pi);
cfo_hz = max(-cancel.max_abs_cfo_hz, ...
    min(cancel.max_abs_cfo_hz, cfo_hz));
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

function writeCancellationCsv(file_name, reports)
fid = fopen(file_name, 'w');
if fid < 0
    warning('Could not write cancellation summary: %s', file_name);
    return;
end
guard = onCleanup(@() fclose(fid));
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
clear guard;
end

function extractIqInterval(source_file, destination_file, sample_offset, ...
        sample_num, ant_num)
% Copy a small, byte-exact interleaved-IQ interval for safe validation.
if sample_offset < 0 || sample_offset ~= fix(sample_offset) || ...
        sample_num < 1 || sample_num ~= fix(sample_num)
    error('Validation sample offset/count must be positive integers.');
end
bytes_per_sample = 4*ant_num;
source_info = dir(source_file);
total_samples = floor(source_info.bytes/bytes_per_sample);
if sample_offset+sample_num > total_samples
    error(['Validation interval %d..%d exceeds source length %d.'], ...
        sample_offset, sample_offset+sample_num-1, total_samples);
end

source_fid = fopen(source_file, 'rb', 'ieee-le');
if source_fid < 0
    error('Cannot open validation source: %s', source_file);
end
source_guard = onCleanup(@() fclose(source_fid));
if fseek(source_fid, sample_offset*bytes_per_sample, 'bof') ~= 0
    error('Could not seek to validation sample %d.', sample_offset);
end
byte_count = sample_num*bytes_per_sample;
bytes = fread(source_fid, byte_count, 'uint8=>uint8');
if numel(bytes) ~= byte_count
    error('Could not read the complete validation interval.');
end
clear source_guard;

destination_fid = fopen(destination_file, 'wb', 'ieee-le');
if destination_fid < 0
    error('Cannot create validation file: %s', destination_file);
end
destination_guard = onCleanup(@() fclose(destination_fid));
count = fwrite(destination_fid, bytes, 'uint8');
if count ~= byte_count
    error('Could not write the complete validation interval.');
end
clear destination_guard;
fprintf('  Source samples : %d..%d\n', sample_offset, ...
    sample_offset+sample_num-1);
fprintf('  Validation file: %s\n', destination_file);
end

function plotValidationComparison(original_file, cancelled_file, options, ...
        reports, source_sample_offset, figure_file)
info = dir(original_file);
sample_num = info.bytes/(4*options.ant_num);
[~, original] = readIqSegment(original_file, 0, sample_num, ...
    options.ant_num, options.channel_index);
[~, cancelled] = readIqSegment(cancelled_file, 0, sample_num, ...
    options.ant_num, options.channel_index);
removed = original-cancelled;
absolute_time_ms = (source_sample_offset+(0:sample_num-1).')/ ...
    options.fs_rx*1e3;

plot_step = max(1, ceil(sample_num/200000));
overview_idx = 1:plot_step:sample_num;
successful = find([reports.success], 1, 'first');
if isempty(successful)
    zoom_first = 1;
    zoom_last = min(sample_num, 200000);
else
    zoom_guard = 10000;
    zoom_first = max(1, reports(successful).abs_start_fitted+1-zoom_guard);
    zoom_last = min(sample_num, reports(successful).abs_start_fitted+ ...
        reports(successful).samples_subtracted+zoom_guard);
end
zoom_idx = zoom_first:zoom_last;

fig = figure('Name', 'Short-capture DW1000 cancellation validation', ...
    'Color', 'w');
subplot(2, 2, 1);
plot(absolute_time_ms(overview_idx), abs(original(overview_idx)));
hold on;
plot(absolute_time_ms(overview_idx), abs(cancelled(overview_idx)));
grid on;
xlabel('Absolute capture time (ms)');
ylabel('|IQ| (ADC counts)');
legend('Before', 'After');
title('Validation interval overview');

subplot(2, 2, 2);
plot(absolute_time_ms(zoom_idx), abs(original(zoom_idx)));
hold on;
plot(absolute_time_ms(zoom_idx), abs(cancelled(zoom_idx)));
grid on;
xlabel('Absolute capture time (ms)');
ylabel('|IQ| (ADC counts)');
legend('Before', 'After');
title('First successfully cancelled frame');

subplot(2, 2, 3);
plot(absolute_time_ms(zoom_idx), abs(removed(zoom_idx)));
grid on;
xlabel('Absolute capture time (ms)');
ylabel('|Before-after|');
title('Actually removed component');

fft_num = min(sample_num, 262144);
window = 0.5-0.5*cos(2*pi*(0:fft_num-1).'/(fft_num-1));
spec_original = abs(fftshift(fft(original(1:fft_num).*window)));
spec_cancelled = abs(fftshift(fft(cancelled(1:fft_num).*window)));
spec_removed = abs(fftshift(fft(removed(1:fft_num).*window)));
reference = max(spec_original)+eps;
frequency_mhz = (-floor(fft_num/2):ceil(fft_num/2)-1).'* ...
    options.fs_rx/fft_num/1e6;
subplot(2, 2, 4);
plot(frequency_mhz, 20*log10(spec_original/reference+eps));
hold on;
plot(frequency_mhz, 20*log10(spec_cancelled/reference+eps));
plot(frequency_mhz, 20*log10(spec_removed/reference+eps));
grid on;
xlabel('Relative frequency (MHz)');
ylabel('Magnitude / original peak (dB)');
legend('Before', 'After', 'Removed');
title('Validation-interval spectrum');
xlim([-options.fs_rx/2, options.fs_rx/2]/1e6);

sgtitle(sprintf(['DW1000 short-capture validation: ', ...
    '%d accepted / %d detected'], nnz([reports.success]), numel(reports)));
saveas(fig, figure_file);
end
