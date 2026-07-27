%% Cancel a reconstructed DW1000 packet from a capture interval.
% Reads only a specified [sample_offset, sample_num] interval from a large
% .dat file, removes the clock-synchronous tone, decodes the DW1000 packet,
% regenerates it with the estimated CIR, aligns/fits CFO and complex gain,
% subtracts the replica from the original ADC samples, and writes a full
% copy of the capture with only the selected interval/channel patched.
%
% The output keeps the original capture length and format: same fs_rx,
% antenna layout, and little-endian interleaved int16 I/Q.
clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% 0. User configuration
input_file  = 'F:\UWB基带数据\DW1000_2.dat';
output_file = fullfile(project_dir, 'decoded_results', ...
    'DW1000_2_cancelled.dat');

% Interval to read from the large capture (zero-based complex samples).
% The valid packet starts near absolute sample 8435340. Keep a guard before
% it so detection sees all 256 SYNC repetitions without locking to the
% spurious partial structure near the old offset 7778186.
sample_offset = 8235340;
sample_num    = 1.5e6;

ant_num       = 1;
channel_index = 1;

% CFO source for the replica: 'decoder', 'fitted', 'manual', or 'none'.
cfo_mode = 'fitted';
manual_cfo_hz = 0;

% Match run_analyze_qm35_cancellation_steps.m:
%   'baseline'        - one global complex gain fitted on stable SYNC
%   'fixed_scale'     - additionally scale PHR and Payload by the value below
%   'optimal_real'    - separately fit a real scale for PHR and Payload
%   'optimal_complex' - separately fit a complex gain for PHR and Payload
final_cancellation_mode = 'optimal_complex';
fixed_phr_payload_scale = 0.88;

% Stable SYNC interval used for CFO and complex-gain fitting.
gain_fit_first_sync = 25;
gain_fit_last_sync  = 256;

% Keep the full work buffer so decoder timing maps directly to fs_rx.
enable_frame_crop = false;

% DW1000 PHY parameters (must match the captured waveform).
options = struct( ...
    'file_name', input_file, ...
    'sample_offset', sample_offset, ...
    'sample_num', sample_num, ...
    'ant_num', ant_num, ...
    'channel_index', channel_index, ...
    'fs_rx', 737.28e6, ...
    'x410_center_frequency', 6500e6, ...
    'dw1000_center_frequency', 6489.6e6, ...
    'preamble_repetitions', 256, ...
    'cir_repetitions', 64, ...
    'cir_pre_samples', 8, ...
    'cir_post_samples', 30, ...
    'code_index', 10, ...
    'data_rate', 6.81, ...
    'sfd_mode', 'decawave', ...
    'max_psdu_bytes', 32, ...
    'enable_frame_crop', enable_frame_crop, ...
    'enable_interference_cancellation', true, ...
    'interference_quiet_offset', 400000, ...
    'interference_quiet_num', 262144, ...
    'interference_tone_bin', -169, ...
    'interference_period_samples', 512, ...
    'show_plots', false, ...
    'verbose', true);

%% 1. Read the requested interval and cancel the tone
params = uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), options);
raw_original = uwbdecoder.readIqRaw(params.file_name, ...
    params.sample_offset, params.sample_num, params.ant_num);
rx_original = uwbdecoder.selectIqChannel(raw_original, ...
    params.channel_index);
[rx_tone_cancelled, interference] = ...
    uwbdecoder.readAndCancelInterference(params);

fprintf('\n=== DW1000 segment cancellation ===\n');
fprintf('Input file    : %s\n', input_file);
fprintf('Interval      : %d .. %d (%.3f ms)\n', ...
    sample_offset, sample_offset + sample_num - 1, ...
    sample_num / params.fs_rx * 1e3);
fprintf('Tone frequency: %+.6f MHz\n', interference.frequency_hz / 1e6);
fprintf('Tone suppress : %.3f dB\n', interference.suppression_db);

%% 2. Decode the packet in this interval
try
    result = decode_uwb(params, rx_tone_cancelled, interference);
catch ME
    fprintf('Decode failed: %s\n', ME.message);
    fprintf(['No output was written because no UWB packet could be ', ...
        'reconstructed safely.\n']);
    return;
end

fprintf('Packet decoded: SFD=%s corr=%.3f | PHR pass=%d | PSDU=%d | FCS=%d\n', ...
    char(string(result.sfd.name)), result.sfd.correlation, ...
    result.phr.secded_pass, result.phr.psdu_length_bytes, ...
    result.payload.fcs_pass);
if ~result.phr.secded_pass || ...
        result.phr.psdu_length_bytes > params.max_psdu_bytes || ...
        ~result.payload.fcs_pass
    fprintf(['Decoded packet did not pass PHR/length/FCS validation. ', ...
        'No output was written.\n']);
    return;
end

%% 3. Generate the reconstructed waveform with the measured CIR
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
    'guard_samples', 4096, ...
    'require_fcs_pass', true);

tx = generate_qm35_tx_from_decode(result, tx_options);
tx_after_cir = apply_estimated_cir_to_qm35(tx, result.cir);

replica_no_cfo = tx_after_cir.waveform_work(:);
fs_work = tx_after_cir.sample_rate_work;
samples_per_sync = round(result.preamble.samples_per_repetition);

%% 4. Resample received segment to work rate and refine frame start
reference = uwbdecoder.buildUwbReference(params);
rx_baseband = uwbdecoder.compensateCenterFrequency(rx_tone_cancelled, params);
rx_work = uwbdecoder.resampleCapture(rx_baseband, params.fs_rx, reference.fs);

preamble_detected = uwbdecoder.detectRepeatedPreamble(rx_work, reference, params);
uwbdecoder.validateCaptureLength(rx_work, preamble_detected, reference, params);

[rx_work_cfo_corrected, preamble_corrected] = ...
    uwbdecoder.compensateCarrierOffset( ...
    rx_work, preamble_detected, reference, params);
preamble_corrected = uwbdecoder.refineTimingWithNsSfd( ...
    rx_work_cfo_corrected, preamble_corrected, reference, params);

[frame_start_work, timing_correlation] = refineFrameStartLocal( ...
    rx_work_cfo_corrected, replica_no_cfo, ...
    preamble_corrected.start_sample, reference.samples_per_symbol);

frame_sample_count = min(numel(replica_no_cfo), ...
    numel(rx_work) - frame_start_work + 1);
received_frame_work = rx_work( ...
    frame_start_work:frame_start_work + frame_sample_count - 1);
replica_no_cfo = replica_no_cfo(1:frame_sample_count);

fprintf('Frame start (work rate): %d\n', frame_start_work);
fprintf('Timing correlation     : %.4f\n', timing_correlation);

%% 5. Estimate CFO between received frame and replica preamble
sync_count = min(params.preamble_repetitions, ...
    floor(frame_sample_count / samples_per_sync));
symbol_correlation = complex(zeros(sync_count, 1));
for k = 1:sync_count
    idx = (k - 1) * samples_per_sync + (1:samples_per_sync);
    symbol_correlation(k) = replica_no_cfo(idx)' * received_frame_work(idx);
end
symbol_time_s = ((0:sync_count - 1).' * samples_per_sync) / fs_work;
symbol_phase_rad = unwrap(angle(symbol_correlation));

cfo_fit_first_sync = max(1, min(gain_fit_first_sync, sync_count));
cfo_fit_last_sync  = max(cfo_fit_first_sync, min(gain_fit_last_sync, sync_count));
cfo_fit_symbols = cfo_fit_first_sync:cfo_fit_last_sync;
cfo_line = polyfit(symbol_time_s(cfo_fit_symbols), ...
    symbol_phase_rad(cfo_fit_symbols), 1);
fitted_cfo_hz = cfo_line(1) / (2 * pi);

fprintf('Decoder CFO     : %+.3f kHz\n', ...
    preamble_corrected.frequency_offset_hz / 1e3);
fprintf('Replica-fitted CFO: %+.3f kHz (SYNC %d..%d)\n', ...
    fitted_cfo_hz / 1e3, cfo_fit_first_sync, cfo_fit_last_sync);

%% 6. Apply selected CFO to replica and fit a global complex gain
switch lower(cfo_mode)
    case 'none'
        replica_cfo_hz = 0;
    case 'decoder'
        replica_cfo_hz = preamble_corrected.frequency_offset_hz;
    case 'fitted'
        replica_cfo_hz = fitted_cfo_hz;
    case 'manual'
        replica_cfo_hz = manual_cfo_hz;
    otherwise
        error('Unknown cfo_mode: %s', cfo_mode);
end

n_work = (0:frame_sample_count - 1).';
replica_with_cfo = replica_no_cfo .* ...
    exp(1j * 2 * pi * replica_cfo_hz * n_work / fs_work);

gain_fit_first_sync = max(1, min(gain_fit_first_sync, sync_count));
gain_fit_last_sync  = max(gain_fit_first_sync, min(gain_fit_last_sync, sync_count));
gain_fit_first_sample = (gain_fit_first_sync - 1) * samples_per_sync + 1;
gain_fit_last_sample  = min(frame_sample_count, gain_fit_last_sync * samples_per_sync);
gain_fit_indices = gain_fit_first_sample:gain_fit_last_sample;

fitted_complex_gain = ...
    (replica_with_cfo(gain_fit_indices)' * received_frame_work(gain_fit_indices)) / ...
    (replica_with_cfo(gain_fit_indices)' * replica_with_cfo(gain_fit_indices) + eps);

% Baseline model: one global complex gain fitted on stable SYNC.
modeled_frame_work_baseline = fitted_complex_gain * replica_with_cfo;

% The analysis script shows that the regenerated PHR and Payload can have
% field-dependent amplitude/phase errors. Fit those two fields separately
% relative to the stable-SYNC baseline, then select the configured model.
field_names = ["PHR"; "Payload"];
field_start = [tx.field_indices_work.PHR(1); ...
    tx.field_indices_work.Payload(1)];
field_end = [tx.field_indices_work.PHR(2); ...
    tx.field_indices_work.Payload(2)];
field_end = min(field_end, frame_sample_count);

field_optimal_real = ones(numel(field_names), 1);
field_optimal_complex = complex(ones(numel(field_names), 1));
field_baseline_suppression_db = nan(numel(field_names), 1);
field_selected_suppression_db = nan(numel(field_names), 1);

modeled_frame_work_fixed = modeled_frame_work_baseline;
modeled_frame_work_optimal_real = modeled_frame_work_baseline;
modeled_frame_work_optimal_complex = modeled_frame_work_baseline;
for k = 1:numel(field_names)
    first_sample = max(1, field_start(k));
    last_sample = min(frame_sample_count, field_end(k));
    if first_sample > last_sample
        continue;
    end

    idx = first_sample:last_sample;
    received_field = received_frame_work(idx);
    baseline_field = modeled_frame_work_baseline(idx);
    field_energy = real(baseline_field' * baseline_field);

    field_optimal_real(k) = real(baseline_field' * received_field) / ...
        (field_energy + eps);
    field_optimal_complex(k) = ...
        (baseline_field' * received_field) / (field_energy + eps);

    modeled_frame_work_fixed(idx) = ...
        fixed_phr_payload_scale * baseline_field;
    modeled_frame_work_optimal_real(idx) = ...
        field_optimal_real(k) * baseline_field;
    modeled_frame_work_optimal_complex(idx) = ...
        field_optimal_complex(k) * baseline_field;

    baseline_residual_field = received_field - baseline_field;
    field_baseline_suppression_db(k) = 10 * log10( ...
        mean(abs(received_field).^2) / ...
        (mean(abs(baseline_residual_field).^2) + eps));
end

switch lower(final_cancellation_mode)
    case 'baseline'
        modeled_frame_work = modeled_frame_work_baseline;
        cancellation_scheme = 'Global stable-SYNC complex gain';
    case {'fixed_scale', 'fixed_0p8'}
        modeled_frame_work = modeled_frame_work_fixed;
        cancellation_scheme = sprintf( ...
            'PHR/Payload fixed %.6g amplitude scale', ...
            fixed_phr_payload_scale);
    case 'optimal_real'
        modeled_frame_work = modeled_frame_work_optimal_real;
        cancellation_scheme = ...
            'PHR/Payload LS-optimal real amplitude scale';
    case 'optimal_complex'
        modeled_frame_work = modeled_frame_work_optimal_complex;
        cancellation_scheme = 'PHR/Payload LS-optimal complex gain';
    otherwise
        error(['Unknown final_cancellation_mode: %s. Use baseline, ', ...
            'fixed_scale, optimal_real, or optimal_complex.'], ...
            final_cancellation_mode);
end

residual_frame_work = received_frame_work - modeled_frame_work;

frame_suppression_db = 10 * log10( ...
    mean(abs(received_frame_work).^2) / (mean(abs(residual_frame_work).^2) + eps));

fprintf('Selected CFO    : %+.3f kHz (%s)\n', replica_cfo_hz / 1e3, cfo_mode);
fprintf('Fitted gain     : %.3f dB, %.3f deg\n', ...
    20 * log10(abs(fitted_complex_gain) + eps), ...
    rad2deg(angle(fitted_complex_gain)));
fprintf('Final scheme    : %s\n', cancellation_scheme);
for k = 1:numel(field_names)
    first_sample = max(1, field_start(k));
    last_sample = min(frame_sample_count, field_end(k));
    if first_sample > last_sample
        continue;
    end
    idx = first_sample:last_sample;
    selected_residual_field = ...
        received_frame_work(idx) - modeled_frame_work(idx);
    field_selected_suppression_db(k) = 10 * log10( ...
        mean(abs(received_frame_work(idx)).^2) / ...
        (mean(abs(selected_residual_field).^2) + eps));
    fprintf(['%s correction : real %.6f | complex %.6f%+.6fj | ', ...
        'suppression %.3f -> %.3f dB\n'], ...
        char(field_names(k)), field_optimal_real(k), ...
        real(field_optimal_complex(k)), imag(field_optimal_complex(k)), ...
        field_baseline_suppression_db(k), ...
        field_selected_suppression_db(k));
end
fprintf('Frame suppression: %.3f dB\n', frame_suppression_db);

%% 7. Map the cancellation model back to the original ADC representation
% compensateCenterFrequency() moved the packet to baseband and normalized
% the complete interval to unit RMS. Undo both operations after resampling;
% otherwise a unit-scale baseband replica would be subtracted directly from
% ADC-count samples at the wrong center frequency.
[p, q] = rat(reference.fs / params.fs_rx, 1e-12);
modeled_rx = resample(modeled_frame_work, q, p);

% Map the work-rate frame start to the original fs_rx sample grid.
frame_start_rx = round((frame_start_work - 1) * params.fs_rx / reference.fs) + 1;
end_rx = min(numel(rx_tone_cancelled), frame_start_rx + numel(modeled_rx) - 1);
num_samples = end_rx - frame_start_rx + 1;

normalization_rms = sqrt(mean(abs(rx_tone_cancelled).^2)) + eps;
frequency_shift_hz = params.x410_center_frequency - ...
    params.dw1000_center_frequency;
absolute_sample_indices = params.sample_offset + frame_start_rx - 1 + ...
    (0:num_samples - 1).';
modeled_rx_adc = modeled_rx(1:num_samples) .* normalization_rms .* ...
    exp(-1j * 2 * pi * frequency_shift_hz * ...
    absolute_sample_indices / params.fs_rx);

% Preserve the original tone, DC component, and all samples outside the
% reconstructed UWB packet. Only the modeled UWB waveform is removed.
rx_cancelled = rx_original;
rx_cancelled(frame_start_rx:end_rx) = ...
    rx_cancelled(frame_start_rx:end_rx) - modeled_rx_adc;

%% 8. Copy the full capture and patch the cancelled interval/channel
% Other channels and all samples outside this interval remain byte-for-byte
% identical to the input file.
writePatchedCapture(input_file, output_file, raw_original, rx_cancelled, ...
    sample_offset, channel_index);
scale = 1;  % Fixed ADC-count scale

%% 9. Summary
original_power = mean(abs(rx_original).^2);
residual_power = mean(abs(rx_cancelled).^2);
full_segment_suppression_db = 10 * log10(original_power / (residual_power + eps));

% Verify that the full output capture has the same length as the input.
expected_bytes = dir(input_file).bytes;
actual_bytes = dir(output_file).bytes;

fprintf('\n=== Output ===\n');
fprintf('Output file      : %s\n', output_file);
fprintf('Patched interval : %d .. %d\n', ...
    sample_offset, sample_offset + sample_num - 1);
fprintf('Patched channel  : %d of %d\n', channel_index, ant_num);
fprintf('Output bytes     : %d (expected %d)\n', actual_bytes, expected_bytes);
fprintf('int16 scale      : %.6g\n', scale);
fprintf('Segment suppress : %.3f dB (entire interval)\n', ...
    full_segment_suppression_db);
fprintf('Frame suppress   : %.3f dB (decoded packet only)\n', ...
    frame_suppression_db);

%% Local helper: copy a capture and patch one channel in one interval
function writePatchedCapture(inputFile, outputFile, rawSegment, waveform, ...
        sampleOffset, channelIndex)
if strcmpi(inputFile, outputFile)
    error('run_cancel_dw1000_segment:SameInputOutput', ...
        'Input and output files must be different.');
end

output_dir = fileparts(outputFile);
if ~isfolder(output_dir)
    mkdir(output_dir);
end

if size(rawSegment, 2) ~= numel(waveform)
    error('run_cancel_dw1000_segment:PatchLengthMismatch', ...
        'Patch waveform and raw segment lengths differ.');
end

i_row = 2 * channelIndex - 1;
q_row = i_row + 1;
rawSegment(i_row, :) = max(-32768, min(32767, round(real(waveform))));
rawSegment(q_row, :) = max(-32768, min(32767, round(imag(waveform))));
iq = int16(rawSegment);

temporary_file = [tempname(output_dir), '.dat'];
temporary_guard = onCleanup(@() deleteIfExists(temporary_file));
[copy_ok, copy_message] = copyfile(inputFile, temporary_file, 'f');
if ~copy_ok
    error('run_cancel_dw1000_segment:CopyFailed', ...
        'Cannot copy input capture: %s', copy_message);
end

fid = fopen(temporary_file, 'r+b', 'ieee-le');
if fid < 0
    error('run_cancel_dw1000_segment:OpenFailed', ...
        'Cannot open temporary output file: %s', temporary_file);
end
file_guard = onCleanup(@() fclose(fid));
bytes_per_iq = uwbdecoder.constants().BYTES_PER_IQ_SAMPLE;
status = fseek(fid, sampleOffset * bytes_per_iq * ...
    (size(rawSegment, 1) / 2), 'bof');
if status ~= 0
    error('run_cancel_dw1000_segment:SeekFailed', ...
        'Cannot seek to output sample offset %d.', sampleOffset);
end
count = fwrite(fid, iq, 'int16');
if count ~= numel(iq)
    error('run_cancel_dw1000_segment:ShortWrite', ...
        'Only %d of %d int16 values were written.', count, numel(iq));
end
clear file_guard;

[move_ok, move_message] = movefile(temporary_file, outputFile, 'f');
if ~move_ok
    error('run_cancel_dw1000_segment:MoveFailed', ...
        'Cannot finalize output capture: %s', move_message);
end
clear temporary_guard;
end

function deleteIfExists(fileName)
if isfile(fileName)
    delete(fileName);
end
end

%% Local helper: fine timing alignment between RX and replica
function [best_start, best_correlation] = refineFrameStartLocal( ...
        rx, replica, coarse_start, samples_per_symbol)
search_radius = 32;
template_length = min(numel(replica), round(32 * samples_per_symbol));
template = replica(1:template_length);
candidate_starts = round(coarse_start) + (-search_radius:search_radius);
scores = -inf(size(candidate_starts));
for k = 1:numel(candidate_starts)
    first = candidate_starts(k);
    last = first + template_length - 1;
    if first < 1 || last > numel(rx)
        continue;
    end
    segment = rx(first:last);
    scores(k) = abs(template' * segment) / (norm(template) * norm(segment) + eps);
end
[best_correlation, index] = max(scores);
best_start = candidate_starts(index);
end
