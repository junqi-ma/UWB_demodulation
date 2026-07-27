%% Step-by-step regenerated-signal cancellation analysis (QM35 / DW1000)
% This script intentionally keeps every important intermediate variable in
% the base workspace. Run one section at a time when tuning cancellation.
clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% 0. Analysis knobs -- edit these first
% Use 'dw1000' for the original DW1000 transmitter or 'qm35' for QM35.
phy_profile = 'qm35';

switch lower(phy_profile)
    case 'dw1000'
        device_label = 'DW1000';
        capture_file = 'F:\UWB基带数据\DW1000_2.dat';
        profile_tag = 'dw1000';
        options = struct( ...
            'file_name', capture_file, ...
            'sample_offset', 0, 'sample_num', 1.5e6, ...
            'ant_num', 1, 'channel_index', 1, ...
            'fs_rx', 737.28e6, ...
            'x410_center_frequency', 6500e6, ...
            'dw1000_center_frequency', 6489.6e6, ...
            'preamble_repetitions', 256, ...
            'cir_repetitions', 64, ...
            'cir_pre_samples', 8, 'cir_post_samples', 30, ...
            'code_index', 10, 'data_rate', 6.81, ...
            'sfd_mode', 'decawave', ...
            'max_psdu_bytes', 32, 'enable_frame_crop', true, ...
            'enable_interference_cancellation', true, ...
            'interference_quiet_offset', 400000, ...
            'interference_quiet_num', 262144, ...
            'interference_tone_bin', -169, ...
            'interference_period_samples', 512, ...
            'show_plots', false, 'verbose', true);
        cfo_fit_last_sync_default = 256;
        gain_fit_last_sync_default = 256;
    case 'qm35'
        device_label = 'QM35';
        capture_file = 'F:\UWB基带数据\qm35_1.dat';
        profile_tag = 'qm35';
        cfo_fit_last_sync_default = 128;
        gain_fit_last_sync_default = 128;
        options = struct( ...
            'file_name', capture_file, ...
            'sample_offset', 0, 'sample_num', 1.5e6, ...
            'ant_num', 1, 'channel_index', 1, ...
            'fs_rx', 737.28e6, ...
            'x410_center_frequency', 6500e6, ...
            'dw1000_center_frequency', 6489.6e6, ...
            'preamble_repetitions', 128, ...
            'cir_repetitions', 64, ...
            'cir_pre_samples', 8, 'cir_post_samples', 30, ...
            'code_index', 9, 'data_rate', 6.81, ...
            'sfd_mode', '4z2', ...
            'max_psdu_bytes', 32, 'enable_frame_crop', true, ...
            'enable_interference_cancellation', true, ...
            'interference_quiet_offset', 400000, ...
            'interference_quiet_num', 262144, ...
            'interference_tone_bin', -169, ...
            'interference_period_samples', 512, ...
            'show_plots', false, 'verbose', true);
    otherwise
        error('Unknown phy_profile: %s', phy_profile);
end

% Build a unified output directory: decoded_results/<capture>[_<profile>]/regenerated/
[~, capture_stem] = fileparts(capture_file);
capture_lower = lower(capture_stem);
if contains(capture_lower, 'qm35') && strcmpi(phy_profile, 'QM35')
    profile_suffix = '';
elseif contains(capture_lower, 'dw1000') && strcmpi(phy_profile, 'DW1000')
    profile_suffix = '';
else
    profile_suffix = ['_' profile_tag];
end
scan_dir = fullfile(project_dir, 'decoded_results', ...
    [capture_stem profile_suffix]);
output_dir = fullfile(scan_dir, 'regenerated');
saved_result_file = fullfile(output_dir, 'decoded_and_regenerated.mat');
if ~isfolder(output_dir)
    mkdir(output_dir);
end

% CFO choice: 'none', 'decoder', 'fitted', or 'manual'.
cfo_mode = 'fitted';
manual_cfo_hz = 0;

% Final cancellation output:
%   'baseline'        - one global complex gain fitted on stable SYNC
%   'fixed_scale'      - multiply PHR and Payload by the value below
%   'optimal_real'    - LS-optimal real scale for PHR and Payload
%   'optimal_complex' - LS-optimal complex gain for PHR and Payload
final_cancellation_mode = 'optimal_complex';
fixed_phr_payload_scale = 0.88;

% Estimate CFO and complex gain only from stable preamble symbols.
cfo_fit_first_sync = 25;
cfo_fit_last_sync = cfo_fit_last_sync_default;
gain_fit_first_sync = 25;
gain_fit_last_sync = gain_fit_last_sync_default;

% Set true to save the diagnostic figure.
save_analysis_figure = true;
analysis_png = fullfile(output_dir, sprintf( ...
    '%s_cancellation_step_analysis.png', lower(device_label)));
preamble_correlation_png = fullfile(output_dir, sprintf( ...
    '%s_preamble_raw_correlation.png', lower(device_label)));
amplitude_phase_png = fullfile(output_dir, sprintf( ...
    '%s_amplitude_phase_difference.png', lower(device_label)));
interpolation_png = fullfile(output_dir, sprintf( ...
    '%s_interpolated_fractional_delay.png', lower(device_label)));
cfo_free_png = fullfile(output_dir, sprintf( ...
    '%s_cfo_free_amplitude_phase.png', lower(device_label)));
field_scale_png = fullfile(output_dir, sprintf( ...
    '%s_phr_payload_scale_validation.png', lower(device_label)));

%% 1. Common configuration for both DW1000 and QM35
% Both profiles now carry a fully populated OPTIONS struct (see Section 0).
% The per-profile decode happens once in Section 2b, so no pre-saved MAT is
% required to start an analysis run.
options.file_name = capture_file;
options.verbose = true;

%% 2. Read the raw IQ and remove the clock-synchronous single tone
params = uwbdecoder.mergeOptions( ...
    uwbdecoder.defaultOptions(), options);
[rx_tone_cancelled, interference] = ...
    uwbdecoder.readAndCancelInterference(params);

fprintf('\nTone frequency   : %+.6f MHz\n', interference.frequency_hz/1e6);
fprintf('Tone suppression : %.3f dB\n', interference.suppression_db);

%% 2b. Decode and reconstruct the frame using its actual PHY parameters
% Both DW1000 and QM35 follow the same decode -> generate -> apply-CIR
% sequence. The decoder returns one packet result; the per-profile tx_options
% below map that result back to a waveform that matches the captured signal.
result = decode_uwb(options, rx_tone_cancelled, interference);

switch lower(phy_profile)
    case 'dw1000'
        tx_options = struct( ...
            'fs_tx', options.fs_rx, ...
            'x410_center_frequency', options.x410_center_frequency, ...
            'qm35_center_frequency', options.dw1000_center_frequency, ...
            'phy_mode', '802.15.4a', ...
            'ranging', true, ...
            'preamble_repetitions', options.preamble_repetitions, ...
            'code_index', options.code_index, ...
            'sfd_number', 0, ...
            'sfd_sequence', [-1; -1; -1; -1; 1; -1; 0; 0], ...
            'peak_amplitude', 1, 'guard_samples', 4096, ...
            'require_fcs_pass', true);
    case 'qm35'
        tx_options = struct( ...
            'fs_tx', options.fs_rx, ...
            'x410_center_frequency', options.x410_center_frequency, ...
            'qm35_center_frequency', options.dw1000_center_frequency, ...
            'phy_mode', 'BPRF', ...
            'ranging', false, ...
            'preamble_repetitions', options.preamble_repetitions, ...
            'code_index', options.code_index, ...
            'sfd_number', 2, ...
            'sfd_sequence', [], ...
            'peak_amplitude', 1, 'guard_samples', 4096, ...
            'require_fcs_pass', true);
    otherwise
        error('Unknown phy_profile: %s', phy_profile);
end

tx = generate_uwb_tx_from_decode(result, tx_options);
tx_after_cir = apply_estimated_cir_to_uwb(tx, result.cir);
save(saved_result_file, 'result', 'tx', 'tx_after_cir', ...
    'options', 'tx_options', '-v7.3');
fprintf('%s reconstructed result: %s\n', device_label, saved_result_file);

% This is the generated {-1,0,+1} pulse train after each pulse has been
% replaced by the estimated complex CIR. It has no residual CFO yet.
replica_no_cfo = tx_after_cir.waveform_work(:);
fs_work = tx_after_cir.sample_rate_work;
samples_per_sync = round(result.preamble.samples_per_repetition);

%% 3. Center-frequency compensation and resampling to 998.4 MHz
rx_baseband = uwbdecoder.compensateCenterFrequency( ...
    rx_tone_cancelled, params);
reference = uwbdecoder.buildUwbReference(params);
rx_work = uwbdecoder.resampleCapture( ...
    rx_baseband, params.fs_rx, reference.fs);

% rx_work is the signal on which subtraction will be performed. It still
% contains the small residual carrier-frequency offset.

%% 4. Detect the packet and obtain the decoder CFO estimate
preamble_detected = uwbdecoder.detectRepeatedPreamble( ...
    rx_work, reference, params);
uwbdecoder.validateCaptureLength( ...
    rx_work, preamble_detected, reference, params);

% This corrected copy is used only to refine timing. rx_work stays intact.
[rx_work_cfo_corrected, preamble_corrected] = ...
    uwbdecoder.compensateCarrierOffset( ...
    rx_work, preamble_detected, reference, params);
preamble_corrected = uwbdecoder.refineTimingWithNsSfd( ...
    rx_work_cfo_corrected, preamble_corrected, reference, params);
decoder_cfo_hz = preamble_corrected.frequency_offset_hz;

%% 5. Align and extract the received frame
[frame_start_work, timing_correlation] = refineFrameStartLocal( ...
    rx_work_cfo_corrected, replica_no_cfo, ...
    preamble_corrected.start_sample, reference.samples_per_symbol);
frame_sample_count = min(numel(replica_no_cfo), ...
    numel(rx_work)-frame_start_work+1);
received_frame = rx_work( ...
    frame_start_work:frame_start_work+frame_sample_count-1);
replica_no_cfo = replica_no_cfo(1:frame_sample_count);
frame_time_us = (0:frame_sample_count-1).'/fs_work*1e6;

fprintf('\nAligned frame start : work sample %d\n', frame_start_work);
fprintf('Timing correlation  : %.4f\n', timing_correlation);

%% 6. Estimate CFO directly between the received and generated preambles
sync_count = min(options.preamble_repetitions, ...
    floor(frame_sample_count/samples_per_sync));
symbol_correlation = complex(zeros(sync_count, 1));
for k = 1:sync_count
    idx = (k-1)*samples_per_sync+(1:samples_per_sync);
    symbol_correlation(k) = replica_no_cfo(idx)'*received_frame(idx);
end
symbol_time_s = ((0:sync_count-1).'*samples_per_sync)/fs_work;
symbol_phase_rad = unwrap(angle(symbol_correlation));

cfo_fit_first_sync = max(1, min(cfo_fit_first_sync, sync_count));
cfo_fit_last_sync = max(cfo_fit_first_sync, ...
    min(cfo_fit_last_sync, sync_count));
cfo_fit_symbols = cfo_fit_first_sync:cfo_fit_last_sync;
cfo_line = polyfit(symbol_time_s(cfo_fit_symbols), ...
    symbol_phase_rad(cfo_fit_symbols), 1);
fitted_cfo_hz = cfo_line(1)/(2*pi);
fitted_phase_rad = polyval(cfo_line, symbol_time_s);

fprintf('Decoder CFO        : %+.3f kHz\n', decoder_cfo_hz/1e3);
fprintf('Replica-fitted CFO : %+.3f kHz (SYNC %d..%d)\n', ...
    fitted_cfo_hz/1e3, cfo_fit_first_sync, cfo_fit_last_sync);

%% 6b. Plot the original preamble cross-correlation outputs
% Keep explicit copies in the workspace for custom analysis.
preamble_raw_matched = preamble_detected.matched(:);
preamble_normalized_score = preamble_detected.score(:);
preamble_accumulated_metric = preamble_detected.metric(:);
if preamble_detected.matched_is_roi
    preamble_score_sample_axis = preamble_detected.roi_start + ...
        (0:numel(preamble_normalized_score)-1).';
    preamble_metric_sample_axis = preamble_detected.roi_start + ...
        (0:numel(preamble_accumulated_metric)-1).';
else
    preamble_score_sample_axis = (1:numel(preamble_normalized_score)).';
    preamble_metric_sample_axis = (1:numel(preamble_accumulated_metric)).';
end
preamble_peak_local_indices = preamble_detected.peaks - ...
    preamble_detected.roi_start + 1;
preamble_peak_values = ...
    preamble_raw_matched(preamble_peak_local_indices);
preamble_peak_phase_wrapped_rad = angle(preamble_peak_values);
preamble_peak_phase_unwrapped_rad = unwrap( ...
    preamble_peak_phase_wrapped_rad);
preamble_peak_time_s = (double(preamble_detected.peaks)- ...
    double(preamble_detected.peaks(1)))/fs_work;
preamble_peak_time_us = preamble_peak_time_s*1e6;
preamble_peak_phase_difference_rad = ...
    diff(preamble_peak_phase_unwrapped_rad);
preamble_peak_instantaneous_cfo_hz = ...
    preamble_peak_phase_difference_rad./ ...
    (2*pi*diff(preamble_peak_time_s));

raw_phase_fit_last = min(cfo_fit_last_sync, ...
    numel(preamble_peak_phase_unwrapped_rad));
raw_phase_fit_symbols = cfo_fit_first_sync:raw_phase_fit_last;
raw_peak_phase_line = polyfit( ...
    preamble_peak_time_s(raw_phase_fit_symbols), ...
    preamble_peak_phase_unwrapped_rad(raw_phase_fit_symbols), 1);
raw_peak_phase_fitted_rad = polyval( ...
    raw_peak_phase_line, preamble_peak_time_s);
raw_peak_cfo_hz = raw_peak_phase_line(1)/(2*pi);

figure('Name', sprintf('Raw %s preamble cross-correlation', device_label), ...
    'Color', 'w', 'Position', [50 30 1250 1080]);

subplot(3, 2, 1);
plot(preamble_score_sample_axis, abs(preamble_raw_matched), ...
    'Color', [0.10 0.45 0.85]);
hold on;
plot(preamble_detected.peaks, ...
    abs(preamble_raw_matched(preamble_peak_local_indices)), ...
    'r.', 'MarkerSize', 8);
xline(preamble_detected.start_sample, 'g--', 'Estimated frame start');
grid on;
xlabel('Absolute work-rate sample');
ylabel('|Raw complex correlation|');
title('Raw matched-filter magnitude (before normalization)');

% Show the complex matched-filter samples around the first four repeats.
zoom_first = max(1, preamble_peak_local_indices(1)-samples_per_sync);
zoom_last = min(numel(preamble_raw_matched), ...
    preamble_peak_local_indices(min(4, numel(preamble_peak_local_indices)))+ ...
    samples_per_sync);
zoom_indices = zoom_first:zoom_last;
subplot(3, 2, 2);
plot(preamble_score_sample_axis(zoom_indices), ...
    real(preamble_raw_matched(zoom_indices)), ...
    'Color', [0.10 0.45 0.85]);
hold on;
plot(preamble_score_sample_axis(zoom_indices), ...
    imag(preamble_raw_matched(zoom_indices)), ...
    'Color', [0.90 0.30 0.12]);
grid on;
xlabel('Absolute work-rate sample');
ylabel('Raw correlation');
title('Complex matched-filter output near preamble start');
legend('Real', 'Imaginary', 'Location', 'best');

subplot(3, 2, 3);
plot(preamble_score_sample_axis, preamble_normalized_score, ...
    'Color', [0.10 0.45 0.85]);
hold on;
yline(preamble_detected.threshold, 'k--', 'Detection threshold');
plot(preamble_detected.peaks, ...
    preamble_normalized_score(preamble_peak_local_indices), ...
    'r.', 'MarkerSize', 8);
xline(preamble_detected.peaks(cfo_fit_first_sync), ...
    'm--', 'CFO fit start');
grid on;
xlabel('Absolute work-rate sample');
ylabel('Normalized correlation');
title(sprintf('Per-symbol score and %d tracked peaks', ...
    preamble_detected.detected_repetitions));

subplot(3, 2, 4);
plot(preamble_metric_sample_axis, preamble_accumulated_metric, ...
    'Color', [0.10 0.45 0.85]);
hold on;
metric_peak_absolute = preamble_detected.roi_start + ...
    preamble_detected.metric_peak_index-1;
plot(metric_peak_absolute, preamble_detected.metric_peak, ...
    'ro', 'MarkerFaceColor', 'r');
grid on;
xlabel('Absolute work-rate sample');
ylabel('16-symbol accumulated metric');
title(sprintf('Accumulated preamble metric, peak %.3f', ...
    preamble_detected.metric_peak));

subplot(3, 2, 5);
plot(1:numel(preamble_peak_phase_unwrapped_rad), ...
    preamble_peak_phase_unwrapped_rad, '.-', ...
    'Color', [0.10 0.45 0.85], 'MarkerSize', 7);
hold on;
plot(1:numel(raw_peak_phase_fitted_rad), ...
    raw_peak_phase_fitted_rad, 'r-', 'LineWidth', 1.4);
xline(cfo_fit_first_sync, 'k--', 'stable fit start');
grid on;
xlabel('Tracked preamble repetition');
ylabel('Unwrapped phase (rad)');
title(sprintf('Phase of raw correlation peaks | stable CFO %+.3f kHz', ...
    raw_peak_cfo_hz/1e3));
legend('Peak phase', 'Stable linear fit', 'Location', 'best');

subplot(3, 2, 6);
instantaneous_repetition = 2:numel(preamble_peak_phase_unwrapped_rad);
plot(instantaneous_repetition, ...
    preamble_peak_instantaneous_cfo_hz/1e3, '.-', ...
    'Color', [0.55 0.20 0.75], 'MarkerSize', 6);
hold on;
yline(raw_peak_cfo_hz/1e3, 'r--', 'stable fitted CFO');
xline(cfo_fit_first_sync, 'k--', 'stable fit start');
grid on;
xlabel('Tracked preamble repetition');
ylabel('Phase increment / period (kHz)');
title('Instantaneous CFO implied by adjacent correlation peaks');

sgtitle(sprintf(['%s preamble raw cross-correlation | Code %d | ', ...
    'ROI %d:%d'], device_label, options.code_index, ...
    preamble_detected.roi_start, preamble_detected.roi_end));
if save_analysis_figure
    exportgraphics(gcf, preamble_correlation_png, 'Resolution', 180);
    fprintf('Preamble correlation figure: %s\n', ...
        preamble_correlation_png);
end

%% 7. Select the CFO and add it to the generated signal
switch lower(cfo_mode)
    case 'none'
        replica_cfo_hz = 0;
    case 'decoder'
        replica_cfo_hz = decoder_cfo_hz;
    case 'fitted'
        replica_cfo_hz = fitted_cfo_hz;
    case 'manual'
        replica_cfo_hz = manual_cfo_hz;
    otherwise
        error('Unknown cfo_mode: %s', cfo_mode);
end

n = (0:frame_sample_count-1).';
replica_with_cfo = replica_no_cfo .* ...
    exp(1j*2*pi*replica_cfo_hz*n/fs_work);

%% 8. Fit one complex gain using the selected stable preamble interval
gain_fit_first_sync = max(1, min(gain_fit_first_sync, sync_count));
gain_fit_last_sync = max(gain_fit_first_sync, ...
    min(gain_fit_last_sync, sync_count));
gain_fit_first_sample = (gain_fit_first_sync-1)*samples_per_sync+1;
gain_fit_last_sample = min(frame_sample_count, ...
    gain_fit_last_sync*samples_per_sync);
gain_fit_indices = gain_fit_first_sample:gain_fit_last_sample;

fitted_complex_gain = ...
    (replica_with_cfo(gain_fit_indices)'*received_frame(gain_fit_indices))/ ...
    (replica_with_cfo(gain_fit_indices)'* ...
     replica_with_cfo(gain_fit_indices)+eps);
generated_received_model = fitted_complex_gain*replica_with_cfo;

fprintf('\nSelected CFO       : %+.3f kHz (%s)\n', ...
    replica_cfo_hz/1e3, cfo_mode);
fprintf('Gain fit SYNC       : %d..%d\n', ...
    gain_fit_first_sync, gain_fit_last_sync);
fprintf('Fitted gain         : %.3f dB, phase %.3f deg\n', ...
    20*log10(abs(fitted_complex_gain)+eps), ...
    rad2deg(angle(fitted_complex_gain)));

%% 9. Subtract -- these are the primary variables for manual analysis
residual = received_frame-generated_received_model;
original_power = mean(abs(received_frame).^2);
residual_power = mean(abs(residual).^2);
full_frame_suppression_db = ...
    10*log10(original_power/(residual_power+eps));

stable_first_sample = 24*samples_per_sync+1;
stable_indices = stable_first_sample:frame_sample_count;
stable_original_power = mean(abs(received_frame(stable_indices)).^2);
stable_residual_power = mean(abs(residual(stable_indices)).^2);
stable_suppression_db = ...
    10*log10(stable_original_power/(stable_residual_power+eps));

fprintf('\nFull-frame suppression : %.3f dB\n', full_frame_suppression_db);
fprintf('Stable suppression     : %.3f dB (after first 24 SYNC)\n', ...
    stable_suppression_db);

%% 10. Measure cancellation separately in SYNC, SFD, PHR, and payload
field_names = ["SYNC all"; "SYNC stable"; "SFD"; "PHR"; "Payload"];
field_start = [tx.field_indices_work.SYNC(1); stable_first_sample; ...
    tx.field_indices_work.SFD(1); tx.field_indices_work.PHR(1); ...
    tx.field_indices_work.Payload(1)];
field_end = [tx.field_indices_work.SYNC(2); ...
    tx.field_indices_work.SYNC(2); tx.field_indices_work.SFD(2); ...
    tx.field_indices_work.PHR(2); tx.field_indices_work.Payload(2)];
field_end = min(field_end, frame_sample_count);

field_original_power = zeros(numel(field_names), 1);
field_residual_power = zeros(numel(field_names), 1);
field_suppression_db = zeros(numel(field_names), 1);
field_complex_correction = complex(zeros(numel(field_names), 1));
field_amplitude_difference_db = zeros(numel(field_names), 1);
field_phase_difference_deg = zeros(numel(field_names), 1);
field_amplitude_only_suppression_db = zeros(numel(field_names), 1);
field_phase_only_suppression_db = zeros(numel(field_names), 1);
field_refit_suppression_db = zeros(numel(field_names), 1);
for k = 1:numel(field_names)
    idx = field_start(k):field_end(k);
    field_original_power(k) = mean(abs(received_frame(idx)).^2);
    field_residual_power(k) = mean(abs(residual(idx)).^2);
    field_suppression_db(k) = 10*log10( ...
        field_original_power(k)/(field_residual_power(k)+eps));
    field_complex_correction(k) = ...
        (generated_received_model(idx)'*received_frame(idx))/ ...
        (generated_received_model(idx)'*generated_received_model(idx)+eps);
    field_amplitude_difference_db(k) = ...
        20*log10(abs(field_complex_correction(k))+eps);
    field_phase_difference_deg(k) = ...
        rad2deg(angle(field_complex_correction(k)));
    field_amplitude_only_residual = received_frame(idx)- ...
        abs(field_complex_correction(k))*generated_received_model(idx);
    field_phase_only_residual = received_frame(idx)- ...
        exp(1j*angle(field_complex_correction(k)))* ...
        generated_received_model(idx);
    field_refit_residual = received_frame(idx)- ...
        field_complex_correction(k)*generated_received_model(idx);
    field_amplitude_only_suppression_db(k) = 10*log10( ...
        field_original_power(k)/(mean( ...
        abs(field_amplitude_only_residual).^2)+eps));
    field_phase_only_suppression_db(k) = 10*log10( ...
        field_original_power(k)/(mean( ...
        abs(field_phase_only_residual).^2)+eps));
    field_refit_suppression_db(k) = 10*log10( ...
        field_original_power(k)/(mean(abs(field_refit_residual).^2)+eps));
end
field_metrics = table(field_names, field_start, field_end, ...
    field_original_power, field_residual_power, field_suppression_db, ...
    field_amplitude_difference_db, field_phase_difference_deg, ...
    field_amplitude_only_suppression_db, ...
    field_phase_only_suppression_db, ...
    field_refit_suppression_db);
disp(field_metrics);

%% 10a. Validate the configured fixed scale in PHR and Payload
scale_test_value = fixed_phr_payload_scale;
scale_test_field_rows = find(ismember(field_names, ["PHR", "Payload"]));
scale_test_field_names = field_names(scale_test_field_rows);
scale_test_count = numel(scale_test_field_rows);
scale_model_to_received_power_db = zeros(scale_test_count, 1);
scale08_model_to_received_power_db = zeros(scale_test_count, 1);
scale_power_match = zeros(scale_test_count, 1);
scale_optimal_real = zeros(scale_test_count, 1);
scale_optimal_complex = complex(zeros(scale_test_count, 1));
scale_baseline_suppression_db = zeros(scale_test_count, 1);
scale08_suppression_db = zeros(scale_test_count, 1);
scale_optimal_real_suppression_db = zeros(scale_test_count, 1);
scale_optimal_complex_suppression_db = zeros(scale_test_count, 1);

generated_model_scale08_fields = generated_received_model;
for q = 1:scale_test_count
    row = scale_test_field_rows(q);
    ii = field_start(row):field_end(row);
    r_field = received_frame(ii);
    m_field = generated_received_model(ii);
    received_field_power = mean(abs(r_field).^2);
    model_field_power = mean(abs(m_field).^2);

    scale_model_to_received_power_db(q) = 10*log10( ...
        model_field_power/(received_field_power+eps));
    scale08_model_to_received_power_db(q) = 10*log10( ...
        scale_test_value^2*model_field_power/(received_field_power+eps));
    scale_power_match(q) = sqrt( ...
        received_field_power/(model_field_power+eps));
    scale_optimal_real(q) = real(m_field'*r_field)/(real(m_field'*m_field)+eps);
    scale_optimal_complex(q) = (m_field'*r_field)/(m_field'*m_field+eps);

    residual_baseline_field = r_field-m_field;
    residual_scale08_field = r_field-scale_test_value*m_field;
    residual_optimal_real_field = r_field-scale_optimal_real(q)*m_field;
    residual_optimal_complex_field = r_field-scale_optimal_complex(q)*m_field;
    scale_baseline_suppression_db(q) = 10*log10( ...
        received_field_power/(mean(abs(residual_baseline_field).^2)+eps));
    scale08_suppression_db(q) = 10*log10( ...
        received_field_power/(mean(abs(residual_scale08_field).^2)+eps));
    scale_optimal_real_suppression_db(q) = 10*log10( ...
        received_field_power/(mean(abs(residual_optimal_real_field).^2)+eps));
    scale_optimal_complex_suppression_db(q) = 10*log10( ...
        received_field_power/(mean(abs(residual_optimal_complex_field).^2)+eps));

    generated_model_scale08_fields(ii) = scale_test_value*m_field;
end

residual_scale08_fields = received_frame-generated_model_scale08_fields;
full_frame_scale08_suppression_db = 10*log10( ...
    original_power/(mean(abs(residual_scale08_fields).^2)+eps));
scale_validation = table(scale_test_field_names, ...
    scale_model_to_received_power_db, scale08_model_to_received_power_db, ...
    scale_power_match, scale_optimal_real, scale_optimal_complex, ...
    scale_baseline_suppression_db, scale08_suppression_db, ...
    scale_optimal_real_suppression_db, ...
    scale_optimal_complex_suppression_db);

% Build all selectable final models. Preserve the globally fitted baseline
% so changing final_cancellation_mode does not affect the validation data.
generated_received_model_baseline = generated_received_model;
residual_baseline = residual;
field_metrics_baseline = field_metrics;
full_frame_suppression_db_baseline = full_frame_suppression_db;
stable_suppression_db_baseline = stable_suppression_db;

generated_received_model_optimal_real = generated_received_model_baseline;
generated_received_model_optimal_complex = generated_received_model_baseline;
for q = 1:scale_test_count
    row = scale_test_field_rows(q);
    ii = field_start(row):field_end(row);
    generated_received_model_optimal_real(ii) = ...
        scale_optimal_real(q)*generated_received_model_baseline(ii);
    generated_received_model_optimal_complex(ii) = ...
        scale_optimal_complex(q)*generated_received_model_baseline(ii);
end
generated_received_model_optimal = generated_received_model_optimal_real;
residual_optimal_real = received_frame-generated_received_model_optimal_real;
residual_optimal_complex = ...
    received_frame-generated_received_model_optimal_complex;
full_frame_optimal_real_suppression_db = 10*log10( ...
    original_power/(mean(abs(residual_optimal_real).^2)+eps));
full_frame_optimal_complex_suppression_db = 10*log10( ...
    original_power/(mean(abs(residual_optimal_complex).^2)+eps));

applied_field_gain = complex(ones(numel(field_names), 1));
switch lower(final_cancellation_mode)
    case 'baseline'
        generated_received_model = generated_received_model_baseline;
        cancellation_scheme = 'Global stable-SYNC complex gain';
    case {'fixed_scale', 'fixed_0p8'}
        generated_received_model = generated_model_scale08_fields;
        applied_field_gain(scale_test_field_rows) = scale_test_value;
        cancellation_scheme = sprintf( ...
            'PHR/Payload fixed %.6g amplitude scale', scale_test_value);
    case 'optimal_real'
        generated_received_model = generated_received_model_optimal_real;
        applied_field_gain(scale_test_field_rows) = scale_optimal_real;
        cancellation_scheme = 'PHR/Payload LS-optimal real amplitude scale';
    case 'optimal_complex'
        generated_received_model = generated_received_model_optimal_complex;
        applied_field_gain(scale_test_field_rows) = scale_optimal_complex;
        cancellation_scheme = 'PHR/Payload LS-optimal complex gain';
    otherwise
        error(['Unknown final_cancellation_mode: %s. Use baseline, ', ...
            'fixed_scale, optimal_real, or optimal_complex.'], ...
            final_cancellation_mode);
end
applied_field_scale = abs(applied_field_gain);
applied_field_phase_deg = rad2deg(angle(applied_field_gain));

% From this point onward, primary variables follow the selected mode.
residual = received_frame-generated_received_model;
cancellation_model_final = generated_received_model;
cancellation_residual_final = residual;
residual_power = mean(abs(residual).^2);
full_frame_suppression_db = 10*log10( ...
    original_power/(residual_power+eps));
stable_residual_power = mean(abs(residual(stable_indices)).^2);
stable_suppression_db = 10*log10( ...
    stable_original_power/(stable_residual_power+eps));

% Refresh every field metric so all later plots/tables use the final model.
for k = 1:numel(field_names)
    ii = field_start(k):field_end(k);
    r_field = received_frame(ii);
    m_field = generated_received_model(ii);
    residual_field = r_field-m_field;
    field_residual_power(k) = mean(abs(residual_field).^2);
    field_suppression_db(k) = 10*log10( ...
        field_original_power(k)/(field_residual_power(k)+eps));
    field_complex_correction(k) = ...
        (m_field'*r_field)/(m_field'*m_field+eps);
    field_amplitude_difference_db(k) = ...
        20*log10(abs(field_complex_correction(k))+eps);
    field_phase_difference_deg(k) = ...
        rad2deg(angle(field_complex_correction(k)));
    amplitude_only_residual = r_field- ...
        abs(field_complex_correction(k))*m_field;
    phase_only_residual = r_field- ...
        exp(1j*angle(field_complex_correction(k)))*m_field;
    complex_refit_residual = r_field- ...
        field_complex_correction(k)*m_field;
    field_amplitude_only_suppression_db(k) = 10*log10( ...
        field_original_power(k)/(mean(abs(amplitude_only_residual).^2)+eps));
    field_phase_only_suppression_db(k) = 10*log10( ...
        field_original_power(k)/(mean(abs(phase_only_residual).^2)+eps));
    field_refit_suppression_db(k) = 10*log10( ...
        field_original_power(k)/(mean(abs(complex_refit_residual).^2)+eps));
end
field_metrics_selected = table(field_names, field_start, field_end, ...
    applied_field_gain, applied_field_scale, applied_field_phase_deg, ...
    field_original_power, field_residual_power, ...
    field_suppression_db, field_amplitude_difference_db, ...
    field_phase_difference_deg, field_amplitude_only_suppression_db, ...
    field_phase_only_suppression_db, field_refit_suppression_db);
field_metrics_optimal = field_metrics_selected;
field_metrics = field_metrics_selected;

fprintf('\nPHR/Payload fixed-scale validation (scale %.6g):\n', ...
    scale_test_value);
disp(scale_validation);
fprintf(['Full frame: baseline %.3f dB, PHR/Payload x%.6g ', ...
    '%.3f dB\n'], full_frame_suppression_db_baseline, ...
    scale_test_value, full_frame_scale08_suppression_db);
fprintf(['Final mode %s: full %.3f dB, stable %.3f dB ', ...
    '(baseline full %.3f dB)\n'], final_cancellation_mode, ...
    full_frame_suppression_db, stable_suppression_db, ...
    full_frame_suppression_db_baseline);
fprintf('Final scheme: %s\n', cancellation_scheme);
disp(field_metrics_selected);

figure('Name', sprintf('%s PHR/Payload scale validation', device_label), ...
    'Color', 'w', 'Position', [100 60 1200 820]);
scale_categories = categorical(scale_test_field_names);
subplot(2, 2, 1);
bar(scale_categories, [scale_model_to_received_power_db, ...
    scale08_model_to_received_power_db]);
hold on; yline(0, 'k--'); grid on;
ylabel('Model / received power (dB)');
title(sprintf('Power mismatch before and after x%.6g', scale_test_value));
legend('Original model', sprintf('Model x%.6g', scale_test_value), ...
    'Location', 'best');

subplot(2, 2, 2);
bar(scale_categories, [scale_test_value*ones(scale_test_count, 1), ...
    scale_power_match, scale_optimal_real]);
grid on; ylabel('Scale factor'); ylim([0.5 1.1]);
title('Fixed, power-matched, and LS-real scales');
legend(sprintf('Fixed %.6g', scale_test_value), ...
    'Power match', 'LS real', 'Location', 'best');

subplot(2, 2, 3);
bar(scale_categories, [scale_baseline_suppression_db, ...
    scale08_suppression_db, scale_optimal_real_suppression_db, ...
    scale_optimal_complex_suppression_db]);
grid on; ylabel('Suppression (dB)');
title('Cancellation improvement by field');
legend('Baseline', sprintf('x%.6g', scale_test_value), ...
    'Optimal real', 'Optimal complex', ...
    'Location', 'best');

subplot(2, 2, 4);
bar(categorical(["Baseline", "Fixed scale", ...
    "Optimal real", "Optimal complex"]), ...
    [full_frame_suppression_db_baseline, ...
    full_frame_scale08_suppression_db, ...
    full_frame_optimal_real_suppression_db, ...
    full_frame_optimal_complex_suppression_db]);
grid on; ylabel('Suppression (dB)');
title('Full-frame impact of field-only scaling');

sgtitle(sprintf('%s PHR/Payload amplitude-scale validation', device_label));
if save_analysis_figure
    exportgraphics(gcf, field_scale_png, 'Resolution', 180);
    fprintf('PHR/Payload scale figure: %s\n', field_scale_png);
end

%% 10b. Separate amplitude and phase differences
% Pointwise phase is meaningful only where the reconstructed pulse has
% appreciable energy. The blockwise estimate below is more noise-robust.
active_threshold = 0.20*max(abs(generated_received_model));
active_indices = find(abs(generated_received_model) >= active_threshold);
point_amplitude_difference_db = 20*log10( ...
    (abs(received_frame(active_indices))+eps)./ ...
    (abs(generated_received_model(active_indices))+eps));
point_phase_difference_deg = rad2deg(angle( ...
    received_frame(active_indices).* ...
    conj(generated_received_model(active_indices))));
point_weights = abs(generated_received_model(active_indices)).^2;
weighted_amplitude_difference_db = sum( ...
    point_weights.*point_amplitude_difference_db)/sum(point_weights);
weighted_phase_bias_deg = rad2deg(angle(sum(point_weights.*exp( ...
    1j*deg2rad(point_phase_difference_deg)))));
point_phase_error_about_bias_deg = rad2deg(angle(exp(1j*( ...
    deg2rad(point_phase_difference_deg)-deg2rad(weighted_phase_bias_deg)))));
weighted_phase_rms_deg = sqrt(sum(point_weights.* ...
    point_phase_error_about_bias_deg.^2)/sum(point_weights));

diagnostic_block_samples = samples_per_sync;
diagnostic_block_count = floor(frame_sample_count/diagnostic_block_samples);
block_time_us = zeros(diagnostic_block_count, 1);
block_complex_correction = complex(nan(diagnostic_block_count, 1));
block_amplitude_difference_db = nan(diagnostic_block_count, 1);
block_phase_difference_deg = nan(diagnostic_block_count, 1);
block_coherence = nan(diagnostic_block_count, 1);
block_amplitude_corrected_model = generated_received_model;
block_phase_corrected_model = generated_received_model;
block_complex_corrected_model = generated_received_model;
for k = 1:diagnostic_block_count
    idx = (k-1)*diagnostic_block_samples+(1:diagnostic_block_samples);
    block_time_us(k) = mean(frame_time_us(idx));
    model_block = generated_received_model(idx);
    received_block = received_frame(idx);
    model_energy = real(model_block'*model_block);
    if model_energy <= eps
        continue;
    end
    block_complex_correction(k) = ...
        (model_block'*received_block)/(model_energy+eps);
    block_amplitude_difference_db(k) = ...
        20*log10(abs(block_complex_correction(k))+eps);
    block_phase_difference_deg(k) = ...
        rad2deg(angle(block_complex_correction(k)));
    block_coherence(k) = abs(model_block'*received_block)/ ...
        (norm(model_block)*norm(received_block)+eps);
    block_amplitude_corrected_model(idx) = ...
        abs(block_complex_correction(k))*model_block;
    block_phase_corrected_model(idx) = ...
        exp(1j*angle(block_complex_correction(k)))*model_block;
    block_complex_corrected_model(idx) = ...
        block_complex_correction(k)*model_block;
end

block_amplitude_suppression_db = 10*log10(original_power/( ...
    mean(abs(received_frame-block_amplitude_corrected_model).^2)+eps));
block_phase_suppression_db = 10*log10(original_power/( ...
    mean(abs(received_frame-block_phase_corrected_model).^2)+eps));
block_complex_suppression_db = 10*log10(original_power/( ...
    mean(abs(received_frame-block_complex_corrected_model).^2)+eps));

fprintf('\nAmplitude/phase comparison on strong pulse samples:\n');
fprintf('  Weighted amplitude difference : %+.3f dB\n', ...
    weighted_amplitude_difference_db);
fprintf('  Weighted phase bias          : %+.3f deg\n', ...
    weighted_phase_bias_deg);
fprintf('  Weighted phase RMS           : %.3f deg\n', ...
    weighted_phase_rms_deg);
fprintf('Blockwise diagnostic suppression (one SYNC period/block):\n');
fprintf('  Original fixed model         : %.3f dB\n', ...
    full_frame_suppression_db);
fprintf('  Amplitude correction only    : %.3f dB\n', ...
    block_amplitude_suppression_db);
fprintf('  Phase correction only        : %.3f dB\n', ...
    block_phase_suppression_db);
fprintf('  Amplitude + phase correction : %.3f dB\n', ...
    block_complex_suppression_db);

amplitude_power_window = max(8, round(0.25e-6*fs_work));
received_local_power = movmean(abs(received_frame).^2, ...
    amplitude_power_window);
model_local_power = movmean(abs(generated_received_model).^2, ...
    amplitude_power_window);
local_amplitude_difference_db = 10*log10( ...
    (received_local_power+eps)./(model_local_power+eps));
amplitude_plot_step = max(1, ceil(frame_sample_count/6000));
amplitude_plot_idx = 1:amplitude_plot_step:frame_sample_count;

figure('Name', sprintf('%s amplitude and phase difference', device_label), ...
    'Color', 'w', 'Position', [90 60 1200 850]);
subplot(2, 2, 1);
plot(frame_time_us(amplitude_plot_idx), ...
    local_amplitude_difference_db(amplitude_plot_idx), ...
    'Color', [0.10 0.45 0.85]);
yline(0, 'k--'); grid on; ylim([-6 6]);
xlabel('Time from frame start (\mus)');
ylabel('Received / model amplitude (dB)');
title('Local amplitude difference (0.25 \mus power window)');

subplot(2, 2, 2);
plot(block_time_us, block_amplitude_difference_db, '.-', ...
    'Color', [0.10 0.45 0.85]);
yline(0, 'k--'); grid on; ylim([-6 6]);
xlabel('Time from frame start (\mus)');
ylabel('Block amplitude correction (dB)');
title('Complex fit amplitude, one SYNC period per block');

subplot(2, 2, 3);
plot(block_time_us, block_phase_difference_deg, '.-', ...
    'Color', [0.75 0.20 0.20]);
yline(0, 'k--'); grid on; ylim([-60 60]);
xlabel('Time from frame start (\mus)');
ylabel('Received - model phase (deg)');
title('Complex fit phase, one SYNC period per block');

subplot(2, 2, 4);
field_categories = categorical(field_names);
yyaxis left;
bar(field_categories, field_amplitude_difference_db, 0.65);
ylabel('Amplitude correction (dB)'); ylim([-3 3]);
yyaxis right;
plot(field_categories, field_phase_difference_deg, 'ro-', ...
    'LineWidth', 1.3, 'MarkerFaceColor', 'r');
ylabel('Phase correction (deg)'); ylim([-30 30]);
grid on; xtickangle(25);
title('Independent complex correction by PHY field');

sgtitle(sprintf([ ...
    '%s received-model difference | amplitude %+.2f dB | ', ...
    'phase bias %+.2f deg | phase RMS %.2f deg'], ...
    device_label, weighted_amplitude_difference_db, ...
    weighted_phase_bias_deg, weighted_phase_rms_deg));
if save_analysis_figure
    exportgraphics(gcf, amplitude_phase_png, 'Resolution', 180);
    fprintf('Amplitude/phase figure: %s\n', amplitude_phase_png);
end

%% 11. Plots -- edit or add panels freely
% Raw sample-domain views are intentionally kept for interactive analysis.

smooth_samples = round(0.25e-6*fs_work);
env_original = movmean(abs(received_frame), smooth_samples);
env_model = movmean(abs(generated_received_model), smooth_samples);
env_residual = movmean(abs(residual), smooth_samples);
normalizer = max(env_original)+eps;
plot_step = max(1, ceil(frame_sample_count/6000));
plot_idx = 1:plot_step:frame_sample_count;

cfo_derotation = exp(-1j*2*pi*replica_cfo_hz*n/fs_work);
received_frame_no_cfo = received_frame.*cfo_derotation;
generated_model_no_cfo = generated_received_model.*cfo_derotation;
residual_no_cfo = received_frame_no_cfo-generated_model_no_cfo;

figure
plot(real(received_frame_no_cfo));hold on
plot(real(generated_model_no_cfo));hold on
plot(real(received_frame_no_cfo)-real(generated_model_no_cfo))

figure
plot(imag(received_frame_no_cfo));hold on
plot(imag(generated_model_no_cfo));hold on
plot(imag(received_frame_no_cfo)-imag(generated_model_no_cfo))

threshold = 3;

idx = find(abs(generated_received_model)>threshold & ...
           abs(received_frame)>threshold);

phase_error_deg = rad2deg(angle( ...
    received_frame(idx).*conj(generated_received_model(idx))));

phase_received = angle(received_frame_no_cfo(idx));
%phase_received(phase_received<0) = -phase_received(phase_received<0);
phase_generated = angle(generated_model_no_cfo(idx));
%phase_generated(phase_generated<0) = -phase_generated(phase_generated<0);

figure;
%plot(frame_time_us(idx), phase_error_deg);
plot(phase_received/2/pi*360);hold on
plot(phase_generated/2/pi*360);
grid on;


sm = 2;
figure
plot(smooth(abs(received_frame(idx)),sm));hold on
plot(smooth(abs(generated_received_model(idx)),sm));hold on
plot(smooth((abs(received_frame(idx))-abs(generated_received_model(idx))),sm));hold on


%start = 4e4;
start = 1.39e5;
%ending = 1.2e5;
ending = 180160;

figure
plot(received_frame_no_cfo(start:ending),'.');hold on
plot(generated_model_no_cfo(start:ending),'.');hold on
plot((received_frame_no_cfo(start:ending))-(generated_model_no_cfo(start:ending)),'.')
axis equal


%% 11a. Received and generated signals with their common CFO removed
% Removing the same CFO from both signals only changes the observation
% coordinates. Residual power must remain unchanged.

no_cfo_suppression_db = 10*log10( ...
    mean(abs(received_frame_no_cfo).^2)/( ...
    mean(abs(residual_no_cfo).^2)+eps));
no_cfo_residual_equivalence_error = max(abs( ...
    residual_no_cfo-residual.*cfo_derotation));

no_cfo_idx = find(abs(generated_model_no_cfo)>threshold & ...
    abs(received_frame_no_cfo)>threshold);
no_cfo_relative_amplitude_error_db = 20*log10( ...
    (abs(received_frame_no_cfo(no_cfo_idx))+eps)./( ...
    abs(generated_model_no_cfo(no_cfo_idx))+eps));
no_cfo_phase_error_deg = rad2deg(angle( ...
    received_frame_no_cfo(no_cfo_idx).*conj( ...
    generated_model_no_cfo(no_cfo_idx))));

% Rotate residual into the model's local coordinates. The real component
% is radial/amplitude; the imaginary component is tangential/phase.
no_cfo_model_unit = generated_model_no_cfo(no_cfo_idx)./( ...
    abs(generated_model_no_cfo(no_cfo_idx))+eps);
no_cfo_local_residual = residual_no_cfo(no_cfo_idx).* ...
    conj(no_cfo_model_unit);
no_cfo_radial_residual = real(no_cfo_local_residual);
no_cfo_tangential_residual = imag(no_cfo_local_residual);
no_cfo_radial_power = mean(no_cfo_radial_residual.^2);
no_cfo_tangential_power = mean(no_cfo_tangential_residual.^2);
no_cfo_tangential_to_radial_db = 10*log10( ...
    no_cfo_tangential_power/(no_cfo_radial_power+eps));
no_cfo_amplitude_error_rms_db = rms(no_cfo_relative_amplitude_error_db);
no_cfo_phase_error_rms_deg = rms(no_cfo_phase_error_deg);

fprintf('\nCommon-CFO-removed comparison:\n');
fprintf('  Suppression (unchanged)       : %.3f dB\n', ...
    no_cfo_suppression_db);
fprintf('  Residual rotation check       : %.3e\n', ...
    no_cfo_residual_equivalence_error);
fprintf('  Strong-sample amplitude RMS   : %.3f dB\n', ...
    no_cfo_amplitude_error_rms_db);
fprintf('  Strong-sample phase RMS       : %.3f deg\n', ...
    no_cfo_phase_error_rms_deg);
fprintf('  Tangential/radial power ratio : %+.3f dB\n', ...
    no_cfo_tangential_to_radial_db);

no_cfo_plot_step = max(1, ceil(frame_sample_count/12000));
no_cfo_plot_idx = 1:no_cfo_plot_step:frame_sample_count;
figure('Name', sprintf('%s common-CFO-removed comparison', device_label), ...
    'Color', 'w', 'Position', [100 50 1250 900]);

subplot(3, 2, 1);
plot(frame_time_us(no_cfo_plot_idx), ...
    real(received_frame_no_cfo(no_cfo_plot_idx)));
hold on;
plot(frame_time_us(no_cfo_plot_idx), ...
    real(generated_model_no_cfo(no_cfo_plot_idx)));
plot(frame_time_us(no_cfo_plot_idx), ...
    real(residual_no_cfo(no_cfo_plot_idx)));
grid on; xlabel('Time (\mus)'); ylabel('Real part');
title('CFO-free real components');
legend('Received', 'Model', 'Residual', 'Location', 'best');

subplot(3, 2, 2);
plot(frame_time_us(no_cfo_plot_idx), ...
    imag(received_frame_no_cfo(no_cfo_plot_idx)));
hold on;
plot(frame_time_us(no_cfo_plot_idx), ...
    imag(generated_model_no_cfo(no_cfo_plot_idx)));
plot(frame_time_us(no_cfo_plot_idx), ...
    imag(residual_no_cfo(no_cfo_plot_idx)));
grid on; xlabel('Time (\mus)'); ylabel('Imaginary part');
title('CFO-free imaginary components');
legend('Received', 'Model', 'Residual', 'Location', 'best');

subplot(3, 2, 3);
plot(frame_time_us(no_cfo_idx), no_cfo_relative_amplitude_error_db, '.');
grid on; ylim([-6 6]);
xlabel('Time (\mus)'); ylabel('Received / model (dB)');
title('Strong-sample amplitude error');

subplot(3, 2, 4);
plot(frame_time_us(no_cfo_idx), no_cfo_phase_error_deg, '.');
grid on; ylim([-60 60]);
xlabel('Time (\mus)'); ylabel('Received - model phase (deg)');
title('Strong-sample phase error');

subplot(3, 2, 5);
plot(frame_time_us(no_cfo_idx), no_cfo_radial_residual, '.');
grid on;
xlabel('Time (\mus)'); ylabel('Radial residual');
title(sprintf('Amplitude-direction power %.4g', no_cfo_radial_power));

subplot(3, 2, 6);
plot(frame_time_us(no_cfo_idx), no_cfo_tangential_residual, '.');
grid on;
xlabel('Time (\mus)'); ylabel('Tangential residual');
title(sprintf('Phase-direction power %.4g', no_cfo_tangential_power));

sgtitle(sprintf([ ...
    '%s common CFO removed | suppression %.2f dB | ', ...
    'phase/amplitude residual %+.2f dB'], ...
    device_label, no_cfo_suppression_db, ...
    no_cfo_tangential_to_radial_db));
if save_analysis_figure
    exportgraphics(gcf, cfo_free_png, 'Resolution', 180);
    fprintf('CFO-free amplitude/phase figure: %s\n', cfo_free_png);
end

%% 11b. Summary plots
figure('Name', sprintf('Step-by-step %s cancellation analysis', ...
    device_label), 'Color', 'w', 'Position', [70 70 1180 820]);
subplot(2, 2, 1);
plot(frame_time_us(plot_idx), env_original(plot_idx)/normalizer);
hold on;
plot(frame_time_us(plot_idx), env_model(plot_idx)/normalizer, '--');
plot(frame_time_us(plot_idx), env_residual(plot_idx)/normalizer, '-.');
grid on;
xlabel('Time from frame start (\mus)');
ylabel('Envelope / received peak');
title('Received, fitted replica, and residual');
legend('Received', 'Fitted replica', 'Residual', 'Location', 'best');

subplot(2, 2, 2);
plot(symbol_time_s*1e6, symbol_phase_rad, '.');
hold on;
plot(symbol_time_s*1e6, fitted_phase_rad, 'r-', 'LineWidth', 1.4);
xline(symbol_time_s(cfo_fit_first_sync)*1e6, 'k--', 'fit start');
grid on;
xlabel('Preamble time (\mus)');
ylabel('Unwrapped phase (rad)');
title(sprintf('CFO fit: %+.3f kHz', fitted_cfo_hz/1e3));

nfft = 2^floor(log2(min(frame_sample_count, 262144)));
window = 0.5-0.5*cos(2*pi*(0:nfft-1).'/(nfft-1));
spec_original = 20*log10(abs(fftshift(fft( ...
    received_frame(1:nfft).*window, nfft)))+eps);
spec_residual = 20*log10(abs(fftshift(fft( ...
    residual(1:nfft).*window, nfft)))+eps);
spec_reference = max(spec_original);
frequency_mhz = (-nfft/2:nfft/2-1).'*fs_work/nfft/1e6;
subplot(2, 2, 3);
plot(frequency_mhz, spec_original-spec_reference);
hold on;
plot(frequency_mhz, spec_residual-spec_reference);
grid on;
ylim([-70 5]);
xlabel('Baseband frequency (MHz)');
ylabel('Relative magnitude (dB)');
title('Before/after subtraction spectrum');
legend('Received', 'Residual', 'Location', 'best');

subplot(2, 2, 4);
bar(categorical(field_names), field_suppression_db);
grid on;
ylabel('Suppression (dB)');
title('Cancellation by PHY field');
xtickangle(25);

sgtitle(sprintf(['%s cancellation (%s) | CFO %+.3f kHz | ', ...
    'full %.2f dB | stable %.2f dB'], device_label, ...
    final_cancellation_mode, replica_cfo_hz/1e3, ...
    full_frame_suppression_db, stable_suppression_db));
if save_analysis_figure
    exportgraphics(gcf, analysis_png, 'Resolution', 180);
    fprintf('Analysis figure: %s\n', analysis_png);
end

%% Local helper: only timing refinement is kept out of the main sections
function [best_start, best_correlation] = refineFrameStartLocal( ...
        rx, replica, coarse_start, samples_per_symbol)
search_radius = 32;
template_length = min(numel(replica), round(32*samples_per_symbol));
template = replica(1:template_length);
candidate_starts = round(coarse_start)+(-search_radius:search_radius);
scores = -inf(size(candidate_starts));
for k = 1:numel(candidate_starts)
    first = candidate_starts(k);
    last = first+template_length-1;
    if first < 1 || last > numel(rx)
        continue;
    end
    segment = rx(first:last);
    scores(k) = abs(template'*segment)/(norm(template)*norm(segment)+eps);
end
[best_correlation, index] = max(scores);
best_start = candidate_starts(index);
end
