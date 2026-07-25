%% Cancel every reliably decoded DW1000 packet in a complete capture.
% Reuses the full-file scan produced by decode_x410_dw1000_all, reconstructs
% every FCS-valid frame, applies stable-SYNC CFO/global-gain fitting plus
% field-specific PHR/Payload complex fitting, and patches one output copy.
clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% 0. User configuration
input_file = 'F:\UWB基带数据\DW1000_2.dat';
packet_result_dir = fullfile(project_dir, 'decoded_results', 'DW1000_2');
packet_summary_file = fullfile(packet_result_dir, 'frame_summary.csv');
scan_file = fullfile(packet_result_dir, 'all_frames_cir.mat');
output_file = fullfile(project_dir, 'decoded_results', ...
    'DW1000_2_all_cancelled_optimal_complex.dat');
metadata_file = fullfile(project_dir, 'decoded_results', ...
    'DW1000_2_all_cancelled_optimal_complex_metadata.mat');
summary_file = fullfile(project_dir, 'decoded_results', ...
    'DW1000_2_all_cancelled_optimal_complex_summary.csv');

max_psdu_bytes = 32;
require_fcs_pass = true;
final_cancellation_mode = 'optimal_complex';
fixed_phr_payload_scale = 0.88;

% Stable preamble interval and packet-local alignment search.
cfo_fit_first_sync = 25;
cfo_fit_last_sync = 256;
gain_fit_first_sync = 25;
gain_fit_last_sync = 256;
alignment_search_samples = 128;
alignment_template_syncs = 32;

% Reject unsafe fits instead of modifying the output.
min_alignment_correlation = 0.70;
min_frame_suppression_db = 0.20;
max_abs_cfo_hz = 100e3;

%% 1. Load and validate the existing full-file scan
if ~isfile(input_file)
    error('run_cancel_all_dw1000_packets:InputNotFound', ...
        'Input capture does not exist: %s', input_file);
end
if ~isfile(scan_file)
    error('run_cancel_all_dw1000_packets:ScanNotFound', ...
        'Packet/CIR result does not exist: %s', scan_file);
end
if ~isfile(packet_summary_file)
    error('run_cancel_all_dw1000_packets:SummaryNotFound', ...
        'Packet summary does not exist: %s', packet_summary_file);
end

saved_scan = load(scan_file, 'results');
if ~isfield(saved_scan, 'results') || ...
        ~isfield(saved_scan.results, 'frames')
    error('run_cancel_all_dw1000_packets:InvalidScan', ...
        'The scan MAT file does not contain results.frames.');
end
results = saved_scan.results;
frames = results.frames;
params = results.params;
params.file_name = input_file;
params.max_psdu_bytes = max_psdu_bytes;

% frame_summary.csv is the authoritative source of packet start times.
% Match rows to MAT records by packet index; the MAT file supplies payload
% bytes, CIR, and other reconstruction metadata.
packet_summary = readtable(packet_summary_file);
required_columns = {'index', 'abs_start_sample', 'time_start_ms', ...
    'phr_secded_pass', 'psdu_length_bytes', 'fcs_pass'};
missing_columns = setdiff(required_columns, ...
    packet_summary.Properties.VariableNames);
if ~isempty(missing_columns)
    error('run_cancel_all_dw1000_packets:MissingSummaryColumns', ...
        'frame_summary.csv is missing: %s', ...
        strjoin(missing_columns, ', '));
end

if isfield(results, 'sample_index_base') && ...
        results.sample_index_base ~= 0
    error('run_cancel_all_dw1000_packets:UnsupportedIndexBase', ...
        ['Packet starts must be zero-based capture sample offsets; ', ...
        'the result declares sample_index_base=%g.'], ...
        results.sample_index_base);
end

frame_indices = [frames.index].';
[matched, summary_rows] = ismember(frame_indices, packet_summary.index);
if ~all(matched)
    error('run_cancel_all_dw1000_packets:UnmatchedPacketIndex', ...
        '%d MAT packet(s) have no matching CSV summary row.', ...
        nnz(~matched));
end
if numel(unique(packet_summary.index)) ~= height(packet_summary)
    error('run_cancel_all_dw1000_packets:DuplicatePacketIndex', ...
        'frame_summary.csv contains duplicate packet indices.');
end

summary_start_samples = ...
    round(packet_summary.abs_start_sample(summary_rows));
summary_start_ms = packet_summary.time_start_ms(summary_rows);
time_derived_samples = round(summary_start_ms * 1e-3 * params.fs_rx);
time_sample_error = time_derived_samples - summary_start_samples;
if any(abs(time_sample_error) > 1)
    error('run_cancel_all_dw1000_packets:StartTimeMismatch', ...
        ['CSV time_start_ms and abs_start_sample disagree by up to ', ...
        '%d samples.'], max(abs(time_sample_error)));
end

for k = 1:numel(frames)
    frames(k).abs_start_sample = summary_start_samples(k);
    frames(k).time_start_s = summary_start_ms(k) * 1e-3;
end

if isempty(frames)
    error('run_cancel_all_dw1000_packets:NoFrames', ...
        'The scan contains no decoded frames.');
end

phr_ok = [frames.phr_secded_pass];
fcs_ok = [frames.fcs_pass];
psdu_length = [frames.psdu_length_bytes];
has_payload = arrayfun(@(x) ~isempty(x.payload_bytes), frames);
selected = phr_ok & has_payload & psdu_length <= max_psdu_bytes;
if require_fcs_pass
    selected = selected & fcs_ok;
end
frames = frames(selected);
[~, order] = sort([frames.abs_start_sample]);
frames = frames(order);

fprintf('\n=== All-DW1000 cancellation ===\n');
fprintf('Packet directory   : %s\n', packet_result_dir);
fprintf('Start-time source  : %s\n', packet_summary_file);
fprintf('Scan frames        : %d\n', results.packet_count);
fprintf('FCS-pass frames    : %d\n', results.fcs_pass_count);
fprintf('Selected frames    : %d\n', numel(frames));
fprintf('Cancellation mode  : %s\n', final_cancellation_mode);

%% 2. Create the full output capture once
if strcmpi(input_file, output_file)
    error('run_cancel_all_dw1000_packets:SameInputOutput', ...
        'Input and output files must be different.');
end
output_dir = fileparts(output_file);
if ~isfolder(output_dir)
    mkdir(output_dir);
end

fprintf('Copying complete capture to:\n  %s\n', output_file);
[copy_ok, copy_message] = copyfile(input_file, output_file, 'f');
if ~copy_ok
    error('run_cancel_all_dw1000_packets:CopyFailed', ...
        'Cannot create output capture: %s', copy_message);
end

c = dw1000decoder.constants();
input_info = dir(input_file);
bytes_per_time_sample = c.BYTES_PER_IQ_SAMPLE * params.ant_num;
total_samples = input_info.bytes / bytes_per_time_sample;

%% 3. Reconstruct, fit, and subtract every selected packet
reports = repmat(emptyReport(), numel(frames), 1);
success_count = 0;
for k = 1:numel(frames)
    frame = frames(k);
    fprintf('[%4d/%4d] abs_start=%d: ', ...
        k, numel(frames), frame.abs_start_sample);
    try
        reports(k) = cancelOnePacket(output_file, frame, params, ...
            total_samples, c, final_cancellation_mode, ...
            fixed_phr_payload_scale, cfo_fit_first_sync, ...
            cfo_fit_last_sync, gain_fit_first_sync, gain_fit_last_sync, ...
            alignment_search_samples, alignment_template_syncs, ...
            min_alignment_correlation, min_frame_suppression_db, ...
            max_abs_cfo_hz);
        success_count = success_count + 1;
        fprintf('OK, corr %.3f, CFO %+.3f kHz, %.2f dB\n', ...
            reports(k).alignment_correlation, ...
            reports(k).fitted_cfo_hz / 1e3, ...
            reports(k).frame_suppression_db);
    catch ME
        reports(k) = emptyReport();
        reports(k).index = frame.index;
        reports(k).abs_start_detected = frame.abs_start_sample;
        reports(k).fcs_pass = frame.fcs_pass;
        reports(k).message = ME.message;
        fprintf('SKIPPED: %s\n', ME.message);
    end

    % Leave a recoverable progress record during a long run.
    if mod(k, 25) == 0 || k == numel(frames)
        checkpoint = struct('completed_count', k, ...
            'success_count', success_count);
        save(metadata_file, 'reports', 'checkpoint', ...
            'success_count', 'input_file', 'output_file', 'scan_file', ...
            'packet_summary_file', ...
            'final_cancellation_mode', '-v7.3');
    end
end

%% 4. Save final report and verify output length
report_table = struct2table(reports);
writetable(report_table, summary_file);
save(metadata_file, 'reports', 'success_count', 'frames', 'params', ...
    'input_file', 'output_file', 'scan_file', 'packet_summary_file', ...
    'final_cancellation_mode', '-v7.3');

output_info = dir(output_file);
if output_info.bytes ~= input_info.bytes
    error('run_cancel_all_dw1000_packets:OutputLengthMismatch', ...
        'Output has %d bytes; expected %d.', ...
        output_info.bytes, input_info.bytes);
end

fprintf('\n=== Final summary ===\n');
fprintf('Selected packets : %d\n', numel(frames));
fprintf('Cancelled packets: %d\n', success_count);
fprintf('Skipped packets  : %d\n', numel(frames) - success_count);
fprintf('Output bytes     : %d\n', output_info.bytes);
fprintf('Output file      : %s\n', output_file);
fprintf('Summary CSV      : %s\n', summary_file);

%% ------------------------------------------------------------------------
function report = cancelOnePacket(outputFile, frame, params, totalSamples, ...
        c, cancellationMode, fixedScale, cfoFirst, cfoLast, gainFirst, ...
        gainLast, searchRadius, templateSyncs, minCorrelation, ...
        minSuppressionDb, maxAbsCfoHz)

decoded = struct();
decoded.payload = struct('bytes', uint8(frame.payload_bytes(:)), ...
    'fcs_pass', logical(frame.fcs_pass));
decoded.sfd = struct('name', frame.sfd_name);
decoded.cir = frame.cir;

tx_options = struct( ...
    'fs_tx', params.fs_rx, ...
    'x410_center_frequency', params.x410_center_frequency, ...
    'qm35_center_frequency', params.dw1000_center_frequency, ...
    'phy_mode', '802.15.4a', ...
    'ranging', true, ...
    'preamble_repetitions', params.preamble_repetitions, ...
    'code_index', params.code_index, ...
    'sfd_number', 0, ...
    'sfd_sequence', [-1; -1; -1; -1; 1; -1; 0; 0], ...
    'peak_amplitude', 1, ...
    'guard_samples', 0, ...
    'require_fcs_pass', true);
tx = generate_qm35_tx_from_decode(decoded, tx_options);
channel = apply_estimated_cir_to_qm35(tx, decoded.cir);
replica = channel.waveform_x410(:);

nominal_start = frame.abs_start_sample;
read_first = max(0, nominal_start - searchRadius);
read_last = min(totalSamples - 1, ...
    nominal_start + numel(replica) - 1 + searchRadius);
[raw, received] = readIqSegment(outputFile, read_first, ...
    read_last - read_first + 1, params.ant_num, params.channel_index);

% The tone is removed only in the fitting copy. The saved residual retains
% the original tone and every component not represented by the UWB model.
fit_received = received;
if params.enable_interference_cancellation && ...
        isfield(params, 'interference_coefficient') && ...
        ~isempty(params.interference_coefficient)
    absolute_n = read_first + (0:numel(fit_received) - 1).';
    tone = dw1000decoder.synchronousTone(absolute_n, ...
        params.interference_tone_bin, params.interference_period_samples);
    fit_received = fit_received - ...
        params.interference_coefficient(1) .* tone;
end

period_rx = c.PREAMBLE_PERIOD_S * params.fs_rx;
nominal_local = nominal_start - read_first + 1;
[start_local, alignment_correlation] = alignReplica( ...
    fit_received, replica, nominal_local, period_rx, searchRadius, ...
    gainFirst, templateSyncs);
if alignment_correlation < minCorrelation
    error('Alignment correlation %.3f is below %.3f.', ...
        alignment_correlation, minCorrelation);
end

available = min(numel(replica), numel(received) - start_local + 1);
if available < round(params.preamble_repetitions * period_rx)
    error('The complete preamble is not available in the fitting window.');
end
replica = replica(1:available);
observed = fit_received(start_local:start_local + available - 1);

fitted_cfo_hz = fitReplicaCfo( ...
    observed, replica, period_rx, cfoFirst, cfoLast, params.fs_rx);
if abs(fitted_cfo_hz) > maxAbsCfoHz
    error('Fitted CFO %+.3f kHz exceeds the safety limit.', ...
        fitted_cfo_hz / 1e3);
end
n = (0:available - 1).';
replica_cfo = replica .* ...
    exp(1j * 2 * pi * fitted_cfo_hz * n / params.fs_rx);

gain_first_sample = round((gainFirst - 1) * period_rx) + 1;
gain_last_sample = min(available, round(gainLast * period_rx));
gain_indices = gain_first_sample:gain_last_sample;
global_gain = (replica_cfo(gain_indices)' * observed(gain_indices)) / ...
    (replica_cfo(gain_indices)' * replica_cfo(gain_indices) + eps);
baseline_model = global_gain * replica_cfo;

phr_indices = workFieldToRxIndices( ...
    tx.field_indices_work.PHR, tx.sample_rate_work, ...
    params.fs_rx, available);
payload_indices = workFieldToRxIndices( ...
    tx.field_indices_work.Payload, tx.sample_rate_work, ...
    params.fs_rx, available);
[selected_model, phr_gain, payload_gain] = selectFieldModel( ...
    baseline_model, observed, phr_indices, payload_indices, ...
    cancellationMode, fixedScale);

residual_fit = observed - selected_model;
frame_suppression_db = 10 * log10( ...
    mean(abs(observed).^2) / (mean(abs(residual_fit).^2) + eps));
if frame_suppression_db < minSuppressionDb
    error('Frame suppression %.3f dB is below %.3f dB.', ...
        frame_suppression_db, minSuppressionDb);
end

before = received(start_local:start_local + available - 1);
after = before - selected_model;
received(start_local:start_local + available - 1) = after;
[raw, clipped_count] = replaceIqChannel( ...
    raw, received, params.channel_index, c);
writeIqSegment(outputFile, read_first, raw, params.ant_num, c);

report = emptyReport();
report.index = frame.index;
report.success = true;
report.abs_start_detected = nominal_start;
report.abs_start_fitted = read_first + start_local - 1;
report.samples_subtracted = available;
report.alignment_correlation = alignment_correlation;
report.fitted_cfo_hz = fitted_cfo_hz;
report.global_gain = global_gain;
report.phr_gain = phr_gain;
report.payload_gain = payload_gain;
report.frame_suppression_db = frame_suppression_db;
report.clipped_component_count = clipped_count;
report.fcs_pass = frame.fcs_pass;
report.message = '';
end

function [bestStart, bestCorrelation] = alignReplica( ...
        received, replica, nominalStart, periodRx, searchRadius, ...
        firstSync, templateSyncs)
template_first = round((firstSync - 1) * periodRx) + 1;
template_last = min(numel(replica), ...
    round((firstSync - 1 + templateSyncs) * periodRx));
template = replica(template_first:template_last);
candidate_starts = nominalStart + (-searchRadius:searchRadius);
scores = -inf(size(candidate_starts));
for k = 1:numel(candidate_starts)
    first = candidate_starts(k) + template_first - 1;
    last = first + numel(template) - 1;
    if first < 1 || last > numel(received)
        continue;
    end
    segment = received(first:last);
    scores(k) = abs(template' * segment) / ...
        (norm(template) * norm(segment) + eps);
end
[bestCorrelation, idx] = max(scores);
bestStart = candidate_starts(idx);
end

function cfoHz = fitReplicaCfo( ...
        received, replica, periodRx, firstSync, lastSync, fs)
sync_count = min(lastSync, floor(min(numel(received), ...
    numel(replica)) / periodRx));
firstSync = min(firstSync, sync_count);
correlations = complex(zeros(sync_count - firstSync + 1, 1));
times = zeros(size(correlations));
for k = firstSync:sync_count
    first = round((k - 1) * periodRx) + 1;
    last = min(numel(replica), round(k * periodRx));
    idx = first:last;
    q = k - firstSync + 1;
    correlations(q) = replica(idx)' * received(idx);
    times(q) = ((first + last) / 2 - 1) / fs;
end
phase = unwrap(angle(correlations));
line_fit = polyfit(times, phase, 1);
cfoHz = line_fit(1) / (2 * pi);
end

function indices = workFieldToRxIndices( ...
        workRange, fsWork, fsRx, available)
first = round((workRange(1) - 1) * fsRx / fsWork) + 1;
last = min(available, round(workRange(2) * fsRx / fsWork));
if first > last
    indices = [];
else
    indices = first:last;
end
end

function [model, phrGain, payloadGain] = selectFieldModel( ...
        baseline, received, phrIdx, payloadIdx, mode, fixedScale)
model = baseline;
fields = {phrIdx, payloadIdx};
gains = complex(ones(2, 1));
for k = 1:2
    idx = fields{k};
    if isempty(idx)
        continue;
    end
    m = baseline(idx);
    r = received(idx);
    switch lower(mode)
        case 'baseline'
            gains(k) = 1;
        case {'fixed_scale', 'fixed_0p8'}
            gains(k) = fixedScale;
        case 'optimal_real'
            gains(k) = real(m' * r) / (real(m' * m) + eps);
        case 'optimal_complex'
            gains(k) = (m' * r) / (m' * m + eps);
        otherwise
            error('Unknown cancellation mode: %s', mode);
    end
    model(idx) = gains(k) * m;
end
phrGain = gains(1);
payloadGain = gains(2);
end

function [raw, rx] = readIqSegment( ...
        fileName, sampleOffset, sampleNum, antNum, channelIndex)
raw = dw1000decoder.readIqRaw( ...
    fileName, sampleOffset, sampleNum, antNum);
rx = dw1000decoder.selectIqChannel(raw, channelIndex);
end

function [raw, clippedCount] = replaceIqChannel( ...
        raw, rx, channelIndex, c)
i_row = 2 * channelIndex - 1;
q_row = i_row + 1;
i_values = round(real(rx));
q_values = round(imag(rx));
clippedCount = nnz(i_values > c.INT16_MAX | i_values < c.INT16_MIN) + ...
    nnz(q_values > c.INT16_MAX | q_values < c.INT16_MIN);
raw(i_row, :) = max(c.INT16_MIN, min(c.INT16_MAX, i_values));
raw(q_row, :) = max(c.INT16_MIN, min(c.INT16_MAX, q_values));
end

function writeIqSegment(fileName, sampleOffset, raw, antNum, c)
fid = fopen(fileName, 'r+b', 'ieee-le');
if fid < 0
    error('Cannot open output capture for patching: %s', fileName);
end
guard = onCleanup(@() fclose(fid));
status = fseek(fid, ...
    sampleOffset * c.BYTES_PER_IQ_SAMPLE * antNum, 'bof');
if status ~= 0
    error('Cannot seek to output sample %d.', sampleOffset);
end
count = fwrite(fid, int16(raw), 'int16');
if count ~= numel(raw)
    error('Only %d of %d int16 values were written.', count, numel(raw));
end
clear guard;
end

function report = emptyReport()
report = struct( ...
    'index', 0, ...
    'success', false, ...
    'abs_start_detected', 0, ...
    'abs_start_fitted', NaN, ...
    'samples_subtracted', 0, ...
    'alignment_correlation', NaN, ...
    'fitted_cfo_hz', NaN, ...
    'global_gain', complex(NaN), ...
    'phr_gain', complex(NaN), ...
    'payload_gain', complex(NaN), ...
    'frame_suppression_db', NaN, ...
    'clipped_component_count', 0, ...
    'fcs_pass', false, ...
    'message', '');
end
