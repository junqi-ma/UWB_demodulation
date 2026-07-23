%% Find, regenerate, and subtract every decodable DW1000 frame
% The output keeps the input file length, interleaved I/Q layout, and ADC
% scale. Only CHANNEL_INDEX is modified; all other antenna channels are
% copied bit-for-bit. Configure the paths and radio parameters below.
clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% -------------------- User configuration --------------------
input_file = 'F:\UWB基带数据\DW1000_2.dat';
output_file = fullfile(project_dir, 'decoded_results', ...
    'DW1000_2_all_dw1000_cancelled.dat');

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
options.cir_skip_initial_repetitions = 0;
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
batch.require_fcs_pass = false;
batch.save_individual_cir = false;

cancel = struct();
cancel.require_fcs_pass = false;
cancel.alignment_search_samples = 96;
cancel.alignment_preamble_repetitions = 32;
cancel.cfo_skip_initial_repetitions = 24;
cancel.min_alignment_correlation = 0.10;
cancel.max_abs_cfo_hz = 1e6;
cancel.decode_pre_guard_samples = 5e4;
cancel.decode_post_guard_samples = 2e4;
cancel.output_headroom = 1.0;

%% -------------------- Validate paths and prepare output --------------------
if ~isfile(input_file)
    error('Input capture not found: %s', input_file);
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

output_dir = fileparts(output_file);
if ~isfolder(output_dir)
    mkdir(output_dir);
end
if strcmpi(char(java.io.File(input_file).getCanonicalPath()), ...
        char(java.io.File(output_file).getCanonicalPath()))
    error('The output_file must be different from input_file.');
end

[~, capture_stem] = fileparts(input_file);
scan_dir = fullfile(output_dir, [capture_stem '_dw1000_scan']);
batch.output_directory = scan_dir;
batch.mat_file = fullfile(scan_dir, 'dw1000_all_frames.mat');
batch.summary_csv = fullfile(scan_dir, 'dw1000_all_frames.csv');

%% -------------------- Discover all decodable frames --------------------
fprintf('\nStep 1/3: scanning the complete capture for DW1000 frames...\n');
results = decode_x410_dw1000_all(options, batch);
if results.packet_count == 0
    warning('No decodable DW1000 frame was found. The output is an unchanged copy.');
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
        fprintf('removed %.2f dB, corr %.3f, CFO %+.2f kHz\n', ...
            report.suppression_db, report.alignment_correlation, ...
            report.fitted_cfo_hz/1e3);
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
    'input_file', 'output_file', 'total_samples', '-v7.3');

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

assignin('base', 'dw1000_all_results', results);
assignin('base', 'dw1000_cancellation_reports', reports);

%% ------------------------------------------------------------------------
function report = cancelOneFrame(output_file, frame, options, scan_params, ...
        cancel, total_samples)
% Decode from the original input, then fit/subtract from the current output.
decode_first = max(0, frame.abs_start_sample-cancel.decode_pre_guard_samples);
decode_last = min(total_samples-1, ...
    frame.abs_end_sample+cancel.decode_post_guard_samples);
decode_options = options;
decode_options.sample_offset = decode_first;
decode_options.sample_num = decode_last-decode_first+1;
if isfield(scan_params, 'interference_coefficient')
    decode_options.interference_coefficient = ...
        scan_params.interference_coefficient;
end
decoded = decode_x410_dw1000(decode_options);
if cancel.require_fcs_pass && ~decoded.payload.fcs_pass
    error('FCS failed during regeneration decode.');
end

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
gain = (replica_cfo'*observed_for_fit)/(replica_cfo'*replica_cfo+eps);
modeled = gain*replica_cfo;

before = received(start_local:start_local+available-1);
after = before-modeled;
power_before = mean(abs(before).^2);
power_after = mean(abs(after).^2);
suppression_db = 10*log10(power_before/(power_after+eps));

if alignment_correlation < cancel.min_alignment_correlation
    error('Alignment correlation %.3f is below threshold %.3f.', ...
        alignment_correlation, cancel.min_alignment_correlation);
end

received(start_local:start_local+available-1) = after;
raw = replaceIqChannel(raw, received, options.channel_index, ...
    cancel.output_headroom);
writeIqSegment(output_file, read_first, raw, options.ant_num);

report = struct();
report.index = frame.index;
report.success = true;
report.abs_start_detected = frame.abs_start_sample;
report.abs_start_fitted = read_first+start_local-1;
report.samples_subtracted = available;
report.alignment_correlation = alignment_correlation;
report.fitted_cfo_hz = fitted_cfo_hz;
report.complex_gain = gain;
report.power_before = power_before;
report.power_after = power_after;
report.suppression_db = suppression_db;
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

function raw = replaceIqChannel(raw, rx, channel_index, headroom)
upper_limit = floor(32767*headroom);
lower_limit = ceil(-32768*headroom);
i_row = 2*channel_index-1;
q_row = 2*channel_index;
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
period_rx = round(1016/998.4e6*options.fs_rx);
repetition_count = min(cancel.alignment_preamble_repetitions, ...
    floor(numel(replica)/period_rx));
if repetition_count < 1
    error('Regenerated preamble is too short for alignment.');
end
template_length = repetition_count*period_rx;
template = replica(1:template_length);
starts = round(nominal_start)+ ...
    (-cancel.alignment_search_samples:cancel.alignment_search_samples);
scores = -inf(size(starts));
for k = 1:numel(starts)
    first = starts(k);
    last = first+template_length-1;
    if first < 1 || last > numel(rx)
        continue;
    end
    segment = rx(first:last);
    % Noncoherent accumulation across repetitions makes timing alignment
    % insensitive to the still-unknown carrier-frequency offset.
    repetition_scores = zeros(repetition_count, 1);
    for r = 1:repetition_count
        idx = (r-1)*period_rx+(1:period_rx);
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
period = round(1016/998.4e6*options.fs_rx);
count = min(options.preamble_repetitions, ...
    floor(min(numel(received), numel(replica))/period));
if count < 8
    cfo_hz = 0;
    return;
end
correlations = complex(zeros(count, 1));
for k = 1:count
    idx = (k-1)*period+(1:period);
    correlations(k) = replica(idx)'*received(idx);
end
phase = unwrap(angle(correlations));
time_s = ((0:count-1).'*period)/options.fs_rx;
first = min(cancel.cfo_skip_initial_repetitions+1, max(1, count-7));
fit = polyfit(time_s(first:end), phase(first:end), 1);
cfo_hz = fit(1)/(2*pi);
cfo_hz = max(-cancel.max_abs_cfo_hz, ...
    min(cancel.max_abs_cfo_hz, cfo_hz));
end

function reports = emptyCancellationReport()
reports = struct('index', {}, 'success', {}, 'abs_start_detected', {}, ...
    'abs_start_fitted', {}, 'samples_subtracted', {}, ...
    'alignment_correlation', {}, 'fitted_cfo_hz', {}, ...
    'complex_gain', {}, 'power_before', {}, 'power_after', {}, ...
    'suppression_db', {}, 'fcs_pass', {}, 'message', {});
end

function report = failedCancellationReport(index, frame, message)
report = struct('index', index, 'success', false, ...
    'abs_start_detected', frame.abs_start_sample, ...
    'abs_start_fitted', NaN, 'samples_subtracted', 0, ...
    'alignment_correlation', NaN, 'fitted_cfo_hz', NaN, ...
    'complex_gain', complex(NaN), 'power_before', NaN, ...
    'power_after', NaN, 'suppression_db', NaN, ...
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
    'samples_subtracted,alignment_correlation,fitted_cfo_hz,', ...
    'gain_real,gain_imag,power_before,power_after,suppression_db,', ...
    'fcs_pass,message\n']);
for k = 1:numel(reports)
    r = reports(k);
    message = strrep(r.message, '"', '""');
    fprintf(fid, ['%d,%d,%d,%.0f,%d,%.9g,%.9g,%.9g,%.9g,', ...
        '%.9g,%.9g,%.9g,%d,"%s"\n'], ...
        r.index, r.success, r.abs_start_detected, r.abs_start_fitted, ...
        r.samples_subtracted, r.alignment_correlation, r.fitted_cfo_hz, ...
        real(r.complex_gain), imag(r.complex_gain), r.power_before, ...
        r.power_after, r.suppression_db, r.fcs_pass, message);
end
clear guard;
end
