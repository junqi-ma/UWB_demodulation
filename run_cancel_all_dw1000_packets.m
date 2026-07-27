%% Cancel every reliably decoded DW1000 or QM35 packet in a capture.
% Reuses the full-file scan produced by decode_uwb_all, reconstructs
% every FCS-valid frame, applies stable-SYNC CFO/global-gain fitting plus
% field-specific PHR/Payload complex fitting, and patches one output copy.
clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% 0. User configuration
% Keep signal_type consistent with run_decode_uwb_all.m.
signal_type = 'QM35';  % 'DW1000' or 'QM35'
input_file = 'F:\UWB基带数据\qm35_1.dat';
final_cancellation_mode = 'optimal_complex';

switch upper(signal_type)
    case 'DW1000'
        signal_type = 'DW1000';
        result_suffix = '';
        expected_code_index = 10;
        expected_preamble_repetitions = 256;
        expected_sfd_mode = 'decawave';
        tx_phy_mode = '802.15.4a';
        tx_ranging = true;
        tx_sfd_number = 0;
        tx_sfd_sequence = [-1; -1; -1; -1; 1; -1; 0; 0];
    case 'QM35'
        signal_type = 'QM35';
        result_suffix = '_qm35';
        expected_code_index = 9;
        expected_preamble_repetitions = 128;
        expected_sfd_mode = '4z2';
        tx_phy_mode = 'BPRF';
        tx_ranging = false;
        tx_sfd_number = 2;
        tx_sfd_sequence = [];
    otherwise
        error('signal_type must be ''DW1000'' or ''QM35''.');
end

% -------------------------------------------------------------------------
% Auto-generated paths. Do not edit below unless your decode output layout
% differs from the decode_uwb_all defaults.
% -------------------------------------------------------------------------
[~, capture_stem] = fileparts(input_file);
result_stem = [capture_stem result_suffix];
packet_result_dir = fullfile(project_dir, 'decoded_results', result_stem);
packet_summary_file = fullfile(packet_result_dir, 'frame_summary.csv');
scan_file = fullfile(packet_result_dir, 'all_frames_cir.mat');
output_file = fullfile(project_dir, 'decoded_results', ...
    sprintf('%s_all_cancelled_%s.dat', result_stem, final_cancellation_mode));
metadata_file = fullfile(project_dir, 'decoded_results', ...
    sprintf('%s_all_cancelled_%s_metadata.mat', ...
    result_stem, final_cancellation_mode));
summary_file = fullfile(project_dir, 'decoded_results', ...
    sprintf('%s_all_cancelled_%s_summary.csv', ...
    result_stem, final_cancellation_mode));

max_psdu_bytes = 32;
require_fcs_pass = true;
fixed_phr_payload_scale = 0.88;

% Reconstruction uses the PHY settings stored by the decoder in
% results.params, so cancellation cannot silently disagree with the scan.
cfo_fit_first_sync = 25;
gain_fit_first_sync = 25;
alignment_search_samples = 128;
alignment_template_syncs = 32;

% Fractional-alignment knobs (shared across profiles).
fractional_alignment_max_samples = 0.75;
fractional_alignment_coarse_step = 0.10;
fractional_alignment_fine_step = 0.01;
fractional_alignment_min_improvement = 5e-4;

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

required_params = {'code_index', 'preamble_repetitions'};
missing_params = required_params(~isfield(params, required_params));
if ~isempty(missing_params)
    error('run_cancel_all_dw1000_packets:MissingDecodeParameters', ...
        'Decode results.params is missing: %s', ...
        strjoin(missing_params, ', '));
end
if params.code_index ~= expected_code_index || ...
        params.preamble_repetitions ~= expected_preamble_repetitions
    error('run_cancel_all_dw1000_packets:DecodeProfileMismatch', ...
        ['Selected %s, but decode results use code %d / %d SYNC. ', ...
        'Rerun run_decode_uwb_all.m with the same signal_type.'], ...
        signal_type, params.code_index, params.preamble_repetitions);
end
if ~isfield(params, 'sfd_mode') || ...
        ~strcmpi(params.sfd_mode, expected_sfd_mode)
    error('run_cancel_all_dw1000_packets:SfdProfileMismatch', ...
        ['Selected %s requires sfd_mode=''%s''. Rerun the decoder ', ...
        'to regenerate matching frame and CIR information.'], ...
        signal_type, expected_sfd_mode);
end
cfo_fit_last_sync = params.preamble_repetitions;
gain_fit_last_sync = params.preamble_repetitions;

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

fprintf('\n=== All-%s cancellation ===\n', signal_type);
fprintf('Packet directory   : %s\n', packet_result_dir);
fprintf('Start-time source  : %s\n', packet_summary_file);
fprintf('Reconstruction PHY : %s / SFD #%d\n', ...
    tx_phy_mode, tx_sfd_number);
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

c = uwbdecoder.constants();
input_info = dir(input_file);
bytes_per_time_sample = c.BYTES_PER_IQ_SAMPLE * params.ant_num;
total_samples = input_info.bytes / bytes_per_time_sample;

%% 3. Reconstruct, fit, and subtract every selected packet
% The per-packet work is split into a compute-only stage and a serial
% file-patch stage. Reconstruction / alignment / CFO / gain fitting are
% the expensive, read-only steps, so they run in parfor across packets. The
% resulting residual patches are written back to the output capture
% afterwards, sequentially, because multiple workers cannot safely share a
% single open file.
fprintf('Parallel pool: starting (if not already open) ...\n');
if isempty(gcp('nocreate'))
    parpool('local');
end

report_prototype = emptyReport();
report_prototype.patch_raw = [];
report_prototype.patch_offset = 0;
report_prototype.patch_samples = 0;
reports = repmat(report_prototype, numel(frames), 1);
success_count = 0;

parfor k = 1:numel(frames)
    frame = frames(k);
    report = report_prototype;
    report.index = frame.index;
    report.abs_start_detected = frame.abs_start_sample;
    try
        [report, patch_raw, patch_offset, patch_samples] = ...
            computeOnePacketPatch(output_file, frame, params, ...
            total_samples, c, final_cancellation_mode, ...
            fixed_phr_payload_scale, ...
            cfo_fit_first_sync, cfo_fit_last_sync, ...
            gain_fit_first_sync, gain_fit_last_sync, ...
            alignment_search_samples, ...
            alignment_template_syncs, ...
            fractional_alignment_max_samples, ...
            fractional_alignment_coarse_step, ...
            fractional_alignment_fine_step, ...
            fractional_alignment_min_improvement, ...
            min_alignment_correlation, min_frame_suppression_db, ...
            max_abs_cfo_hz, ...
            params.code_index, params.preamble_repetitions, ...
            tx_phy_mode, tx_ranging, tx_sfd_number, tx_sfd_sequence);
        report.patch_raw = patch_raw;
        report.patch_offset = patch_offset;
        report.patch_samples = patch_samples;
    catch ME
        report.success = false;
        report.message = ME.message;
    end
    reports(k) = report;
end

fprintf('Applying %d computed patches to the output file (serial I/O).\n', ...
    numel(frames));
for k = 1:numel(frames)
    report = reports(k);
    if report.success
        applyPatchToFile(output_file, report, params.ant_num, c);
    end
    fprintf('[%4d/%4d] abs_start=%d: ', ...
        k, numel(frames), report.abs_start_detected);
    if report.success
        fprintf(['OK, corr %.3f -> %.3f, frac %+.3f samp, ', ...
            'CFO %+.3f kHz, %.2f dB\n'], ...
            report.integer_alignment_correlation, ...
            report.alignment_correlation, ...
            report.fractional_delay_samples, ...
            report.fitted_cfo_hz / 1e3, ...
            report.frame_suppression_db);
        success_count = success_count + 1;
    else
        fprintf('SKIPPED: %s\n', report.message);
    end
end

% Discard the bulky raw patches now that they have been written to disk.
if isfield(reports, 'patch_raw')
    reports = rmfield(reports, {'patch_raw', 'patch_offset', 'patch_samples'});
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
fprintf('Decode PHY       : code %d / %d SYNC\n', ...
    params.code_index, params.preamble_repetitions);
fprintf('Cancelled packets: %d\n', success_count);
fprintf('Skipped packets  : %d\n', numel(frames) - success_count);
fprintf('Output bytes     : %d\n', output_info.bytes);
fprintf('Output file      : %s\n', output_file);
fprintf('Summary CSV      : %s\n', summary_file);

%% ------------------------------------------------------------------------
function [report, patchRaw, patchOffset, patchSamples] = ...
        computeOnePacketPatch(outputFile, frame, params, totalSamples, ...
        c, cancellationMode, fixedScale, cfoFirst, cfoLast, gainFirst, ...
        gainLast, searchRadius, templateSyncs, fractionalMaxSamples, ...
        fractionalCoarseStep, fractionalFineStep, ...
        fractionalMinImprovement, minCorrelation, minSuppressionDb, ...
        maxAbsCfoHz, codeIndex, preambleRepetitions, phyMode, ranging, ...
        sfdNumber, sfdSequence)
% Compute the residual patch for one packet without writing to disk.
% Returns the report plus the raw patch (int16 IQ rows), the capture
% sample offset where it starts, and its length in samples. The caller is
% responsible for applying the patch to the output file (serially).

decoded = struct();
decoded.payload = struct('bytes', uint8(frame.payload_bytes(:)), ...
    'fcs_pass', logical(frame.fcs_pass));
decoded.sfd = struct('name', frame.sfd_name);
decoded.cir = frame.cir;

tx_options = struct( ...
    'fs_tx', params.fs_rx, ...
    'x410_center_frequency', params.x410_center_frequency, ...
    'qm35_center_frequency', params.dw1000_center_frequency, ...
    'phy_mode', phyMode, ...
    'ranging', ranging, ...
    'preamble_repetitions', preambleRepetitions, ...
    'code_index', codeIndex, ...
    'sfd_number', sfdNumber, ...
    'sfd_sequence', sfdSequence, ...
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
    tone = uwbdecoder.synchronousTone(absolute_n, ...
        params.interference_tone_bin, params.interference_period_samples);
    fit_received = fit_received - ...
        params.interference_coefficient(1) .* tone;
end

period_rx = c.PREAMBLE_PERIOD_S * params.fs_rx;
nominal_local = nominal_start - read_first + 1;
[start_local, alignment_correlation] = alignReplica( ...
    fit_received, replica, nominal_local, period_rx, searchRadius, ...
    gainFirst, templateSyncs);
integer_alignment_correlation = alignment_correlation;

available = min(numel(replica), numel(received) - start_local + 1);
if available < round(params.preamble_repetitions * period_rx)
    error('The complete preamble is not available in the fitting window.');
end
replica = replica(1:available);
observed = fit_received(start_local:start_local + available - 1);

% Estimate CFO once at the integer-aligned position, then use the
% CFO-corrected replica to refine the remaining sub-sample delay. Finally,
% shift the no-CFO replica and re-estimate CFO so timing and phase slope are
% mutually consistent.
initial_cfo_hz = fitReplicaCfo( ...
    observed, replica, period_rx, cfoFirst, cfoLast, params.fs_rx);
if abs(initial_cfo_hz) > maxAbsCfoHz
    error('Fitted CFO %+.3f kHz exceeds the safety limit.', ...
        initial_cfo_hz / 1e3);
end
n = (0:available - 1).';
replica_cfo_initial = replica .* ...
    exp(1j * 2 * pi * initial_cfo_hz * n / params.fs_rx);
[fractional_delay_samples, alignment_correlation] = ...
    refineFractionalAlignment(observed, replica_cfo_initial, period_rx, ...
        gainFirst, templateSyncs, fractionalMaxSamples, ...
        fractionalCoarseStep, fractionalFineStep, ...
        fractionalMinImprovement);
replica = applyFractionalShift(replica, fractional_delay_samples);

fitted_cfo_hz = fitReplicaCfo( ...
    observed, replica, period_rx, cfoFirst, cfoLast, params.fs_rx);
if abs(fitted_cfo_hz) > maxAbsCfoHz
    error('Fitted CFO %+.3f kHz exceeds the safety limit.', ...
        fitted_cfo_hz / 1e3);
end
replica_cfo = replica .* ...
    exp(1j * 2 * pi * fitted_cfo_hz * n / params.fs_rx);

if alignment_correlation < minCorrelation
    error(['Fractional alignment correlation %.3f is below %.3f ', ...
        '(integer alignment %.3f).'], alignment_correlation, ...
        minCorrelation, integer_alignment_correlation);
end

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
[patchRaw, clipped_count] = replaceIqChannel( ...
    raw, received, params.channel_index, c);
patchOffset = read_first;
patchSamples = read_last - read_first + 1;

report = emptyReport();
report.index = frame.index;
report.success = true;
report.abs_start_detected = nominal_start;
report.abs_start_fitted = read_first + start_local - 1;
report.samples_subtracted = available;
report.alignment_correlation = alignment_correlation;
report.integer_alignment_correlation = integer_alignment_correlation;
report.fractional_delay_samples = fractional_delay_samples;
report.fitted_cfo_hz = fitted_cfo_hz;
report.global_gain = global_gain;
report.phr_gain = phr_gain;
report.payload_gain = payload_gain;
report.frame_suppression_db = frame_suppression_db;
report.clipped_component_count = clipped_count;
report.fcs_pass = frame.fcs_pass;
report.message = '';
end

function applyPatchToFile(outputFile, report, antNum, c)
% Write a precomputed patch back to the output capture. Called serially from
% the main loop so that only one worker touches the file at a time.
if ~report.success || isempty(report.patch_raw)
    return
end
writeIqSegment(outputFile, report.patch_offset, ...
    report.patch_raw, antNum, c);
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

function [bestDelay, bestCorrelation] = refineFractionalAlignment( ...
        received, replica, periodRx, firstSync, templateSyncs, ...
        maxDelay, coarseStep, fineStep, minImprovement)
% Refine an integer packet start with a sub-sample delay. The convention is
% shifted(n) = replica(n - delay), so a negative delay advances the replica.
template_first = round((firstSync - 1) * periodRx) + 1;
template_last = min(numel(replica), ...
    round((firstSync - 1 + templateSyncs) * periodRx));
template_indices = (template_first:template_last).';
received_template = received(template_indices);

padding = ceil(maxDelay) + 3;
segment_first = max(1, template_first - padding);
segment_last = min(numel(replica), template_last + padding);
segment_axis = (segment_first:segment_last).';
interpolator = griddedInterpolant(segment_axis, ...
    replica(segment_first:segment_last), 'spline', 'none');

scoreAtDelay = @(delay) fractionalAlignmentScore( ...
    interpolator, template_indices, received_template, delay);
zeroCorrelation = scoreAtDelay(0);

coarseDelays = unique([(-maxDelay:coarseStep:maxDelay), 0]);
coarseScores = zeros(size(coarseDelays));
for k = 1:numel(coarseDelays)
    coarseScores(k) = scoreAtDelay(coarseDelays(k));
end
[~, coarseBestIndex] = max(coarseScores);
coarseBestDelay = coarseDelays(coarseBestIndex);

fineFirst = max(-maxDelay, coarseBestDelay - coarseStep);
fineLast = min(maxDelay, coarseBestDelay + coarseStep);
fineDelays = unique([fineFirst:fineStep:fineLast, ...
    coarseBestDelay, 0]);
fineScores = zeros(size(fineDelays));
for k = 1:numel(fineDelays)
    fineScores(k) = scoreAtDelay(fineDelays(k));
end
[bestCorrelation, fineBestIndex] = max(fineScores);
bestDelay = fineDelays(fineBestIndex);

if bestCorrelation - zeroCorrelation < minImprovement
    bestDelay = 0;
    bestCorrelation = zeroCorrelation;
end
end

function score = fractionalAlignmentScore( ...
        interpolator, templateIndices, receivedTemplate, delay)
shiftedTemplate = interpolator(templateIndices - delay);
if any(~isfinite(shiftedTemplate))
    score = -inf;
    return;
end
score = abs(shiftedTemplate' * receivedTemplate) / ...
    (norm(shiftedTemplate) * norm(receivedTemplate) + eps);
end

function shifted = applyFractionalShift(signal, delay)
% Cubic-spline interpolation preserves the wideband pulse shape much better
% than linear interpolation near a half-sample delay. Samples outside the
% finite replica are zero-filled.
if delay == 0
    shifted = signal;
    return;
end
sample_axis = (1:numel(signal)).';
interpolator = griddedInterpolant( ...
    sample_axis, signal(:), 'spline', 'none');
shifted = interpolator(sample_axis - delay);
shifted(~isfinite(shifted)) = 0;
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
raw = uwbdecoder.readIqRaw( ...
    fileName, sampleOffset, sampleNum, antNum);
rx = uwbdecoder.selectIqChannel(raw, channelIndex);
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
    'integer_alignment_correlation', NaN, ...
    'fractional_delay_samples', NaN, ...
    'fitted_cfo_hz', NaN, ...
    'global_gain', complex(NaN), ...
    'phr_gain', complex(NaN), ...
    'payload_gain', complex(NaN), ...
    'frame_suppression_db', NaN, ...
    'clipped_component_count', 0, ...
    'fcs_pass', false, ...
    'message', '', ...
    'patch_raw', [], ...
    'patch_offset', 0, ...
    'patch_samples', 0);
end

function results = applyMergedSummary(results, merged_summary_file, ...
        ~, profile_dirs) %#ok<DEFNU>
% Legacy dual-pass merge helper (unused).
% — crucially — source each frame's data (CIR/payload/timing) from the
% MAT that matches its profile. Frames decoded with the wrong PHY would
% otherwise carry garbage metadata.
tbl = readtable(merged_summary_file);
if ~ismember('index', tbl.Properties.VariableNames) || ...
        ~ismember('abs_start_sample', tbl.Properties.VariableNames)
    return;
end
% Load per-profile frame pools.
profile_names = fieldnames(profile_dirs);
profile_pools = struct();
fprintf('applyMergedSummary: profile_dirs fields = %s\n', strjoin(fieldnames(profile_dirs), ','));
for p = 1:numel(profile_names)
    pname = profile_names{p};
    pmats = {
        fullfile(profile_dirs.(pname), 'all_frames_cir.mat'), ...
        fullfile(profile_dirs.(pname), sprintf('all_frames_cir_%s.mat', lower(pname))) ...
    };
    frames_tmp = [];
    for m = 1:numel(pmats)
        if ~isfile(pmats{m})
            continue;
        end
        tmp = load(pmats{m}, 'results');
        if isfield(tmp, 'results') && isfield(tmp.results, 'frames') && ...
                numel(tmp.results.frames) > 0
            frames_tmp = tmp.results.frames;
            break;
        end
    end
    if ~isempty(frames_tmp)
        profile_pools.(pname) = frames_tmp;
    end
end
% Build lookup: profile -> (abs_start_sample -> frame). Use a plain struct
% of maps keyed by profile name to avoid char-key edge cases on empty keys.
fprintf('  profile_pools fields: %s\n', strjoin(fieldnames(profile_pools), ','));
fprintf('  isfield(DW)=%d isfield(QM35)=%d\n', isfield(profile_pools,'DW'), isfield(profile_pools,'QM35'));
dw_map = containers.Map('KeyType','double','ValueType','any');
qm_map = containers.Map('KeyType','double','ValueType','any');
for p = 1:numel(profile_names)
    pname = profile_names{p};
    if ~isfield(profile_pools, pname)
        continue;
    end
    pool = profile_pools.(pname);
    if strcmp(pname, 'DW')
        target_map = dw_map;
    else
        target_map = qm_map;
    end
    for k = 1:numel(pool)
        if isfield(pool(k), 'abs_start_sample')
            target_map(pool(k).abs_start_sample) = pool(k);
        end
    end
end
% Walk the merged CSV in order, sourcing each frame from its profile pool.
% Collect into a cell array first to avoid cross-structure assignment when
% the per-profile frames have differing fields.
matched_cells = cell(height(tbl), 1);
matched_count = 0;
for r = 1:height(tbl)
    tbl_profile = '';
    if ismember('profile', tbl.Properties.VariableNames) && ...
            ~ismissing(tbl.profile(r))
        tbl_profile = char(string(tbl.profile(r)));
    end
    start_sample = tbl.abs_start_sample(r);
    f = [];
    switch tbl_profile
        case 'DW'
            if dw_map.isKey(start_sample)
                f = dw_map(start_sample);
            end
        case 'QM35'
            if qm_map.isKey(start_sample)
                f = qm_map(start_sample);
            end
    end
    if isempty(f)
        continue
    end
    f.index = r;
    if ~isfield(f, 'profile') || isempty(f.profile)
        f.profile = tbl_profile;
    end
    matched_cells{r} = f;
    matched_count = matched_count + 1;
end
if matched_count > 0
    new_frames = [matched_cells{:}];
else
    new_frames = results.frames([]);
end
results.frames = new_frames;
results.packet_count = numel(new_frames);
results.fcs_pass_count = sum([new_frames.fcs_pass]);
fprintf('Sourced %d/%d frames by profile (DW pool:%d, QM35 pool:%d).\n', ...
    matched_count, height(tbl), ...
    dw_map.Count, qm_map.Count);
end  % applyMergedSummary
