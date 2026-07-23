%% DW1000 preamble raw correlation and phase-settling analysis
clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% 1. DW1000 capture and PHY parameters
options = struct();
options.file_name = 'F:\UWB基带数据\DW1000_1.dat';
options.sample_offset = 0;
options.sample_num = 1.5e6;
options.ant_num = 1;
options.channel_index = 1;
options.fs_rx = 737.28e6;
options.x410_center_frequency = 6500e6;
options.dw1000_center_frequency = 6489.6e6;
options.preamble_repetitions = 256;
options.cir_repetitions = 64;
options.code_index = 10;
options.data_rate = 6.81;
options.sfd_mode = 'decawave';
options.max_psdu_bytes = 32;
options.enable_frame_crop = true;
options.verbose = true;
options.show_plots = false;

options.enable_interference_cancellation = true;
options.interference_quiet_offset = 400000;
options.interference_quiet_num = 262144;
options.interference_tone_bin = -169;
options.interference_period_samples = 512;

% Exclude early repetitions when fitting the stable phase slope.
phase_fit_first_repetition = 25;
phase_fit_last_repetition = options.preamble_repetitions;

output_dir = fullfile(project_dir, 'decoded_results', ...
    'dw1000_preamble_phase');
if ~isfolder(output_dir)
    mkdir(output_dir);
end
output_png = fullfile(output_dir, ...
    'dw1000_preamble_raw_correlation_phase.png');

%% 2. Single-tone cancellation and HRP-rate conversion
params = dw1000decoder.mergeOptions( ...
    dw1000decoder.defaultOptions(), options);
[rx_tone_cancelled, interference] = ...
    dw1000decoder.readAndCancelInterference(params);
rx_baseband = dw1000decoder.compensateCenterFrequency( ...
    rx_tone_cancelled, params);
reference = dw1000decoder.buildDw1000Reference(params);
rx_work = dw1000decoder.resampleCapture( ...
    rx_baseband, params.fs_rx, reference.fs);

%% 3. Original Preamble matched-filter result
preamble = dw1000decoder.detectRepeatedPreamble( ...
    rx_work, reference, params);
dw1000decoder.validateCaptureLength(rx_work, preamble, reference, params);

raw_matched = preamble.matched(:);
normalized_score = preamble.score(:);
accumulated_metric = preamble.metric(:);
if preamble.matched_is_roi
    score_sample_axis = preamble.roi_start + ...
        (0:numel(normalized_score)-1).';
    metric_sample_axis = preamble.roi_start + ...
        (0:numel(accumulated_metric)-1).';
    peak_local_indices = preamble.peaks-preamble.roi_start+1;
else
    score_sample_axis = (1:numel(normalized_score)).';
    metric_sample_axis = (1:numel(accumulated_metric)).';
    peak_local_indices = preamble.peaks;
end

%% 4. Correlation-peak amplitude, phase, and instantaneous CFO
peak_values = raw_matched(peak_local_indices);
peak_magnitude = abs(peak_values);
peak_phase_wrapped_rad = angle(peak_values);
peak_phase_unwrapped_rad = unwrap(peak_phase_wrapped_rad);
peak_time_s = (double(preamble.peaks)-double(preamble.peaks(1)))/ ...
    reference.fs;
peak_time_us = peak_time_s*1e6;

phase_fit_first_repetition = max(1, ...
    min(phase_fit_first_repetition, numel(peak_values)));
phase_fit_last_repetition = max(phase_fit_first_repetition, ...
    min(phase_fit_last_repetition, numel(peak_values)));
phase_fit_indices = ...
    phase_fit_first_repetition:phase_fit_last_repetition;
phase_line = polyfit(peak_time_s(phase_fit_indices), ...
    peak_phase_unwrapped_rad(phase_fit_indices), 1);
peak_phase_fitted_rad = polyval(phase_line, peak_time_s);
stable_cfo_hz = phase_line(1)/(2*pi);

peak_phase_difference_rad = diff(peak_phase_unwrapped_rad);
instantaneous_cfo_hz = peak_phase_difference_rad./ ...
    (2*pi*diff(peak_time_s));

fprintf('\n========== DW1000 Preamble phase summary ==========\n');
fprintf('Capture                   : %s\n', options.file_name);
fprintf('Code / configured SYNC    : %d / %d\n', ...
    options.code_index, options.preamble_repetitions);
fprintf('Tracked correlation peaks : %d\n', numel(peak_values));
fprintf('Measured period           : %.6f samples\n', ...
    preamble.measured_period);
fprintf('Stable CFO (%d..%d)       : %+.3f kHz\n', ...
    phase_fit_first_repetition, phase_fit_last_repetition, ...
    stable_cfo_hz/1e3);
fprintf('Tone suppression          : %.2f dB\n', ...
    interference.suppression_db);
fprintf('===================================================\n');

%% 5. Plot for direct comparison with the QM35 result
figure('Name', 'DW1000 Preamble correlation phase', ...
    'Color', 'w', 'Position', [50 50 1250 900]);

subplot(2, 2, 1);
plot(score_sample_axis, abs(raw_matched), ...
    'Color', [0.10 0.45 0.85]);
hold on;
plot(preamble.peaks, peak_magnitude, 'r.', 'MarkerSize', 7);
xline(preamble.start_sample, 'g--', 'Estimated frame start');
grid on;
xlabel('Absolute work-rate sample');
ylabel('|Raw complex correlation|');
title('Raw matched-filter magnitude');

subplot(2, 2, 2);
plot(1:numel(peak_magnitude), ...
    peak_magnitude/(max(peak_magnitude)+eps), '.-', ...
    'Color', [0.10 0.45 0.85]);
hold on;
xline(phase_fit_first_repetition, 'k--', 'stable fit start');
xline(options.preamble_repetitions, 'm--', 'configured SYNC end');
grid on;
xlabel('Tracked preamble repetition');
ylabel('Normalized peak magnitude');
title(sprintf('Tracked peak amplitude (%d peaks)', numel(peak_magnitude)));

subplot(2, 2, 3);
plot(1:numel(peak_phase_unwrapped_rad), ...
    peak_phase_unwrapped_rad, '.-', ...
    'Color', [0.10 0.45 0.85], 'MarkerSize', 6);
hold on;
plot(1:numel(peak_phase_fitted_rad), ...
    peak_phase_fitted_rad, 'r-', 'LineWidth', 1.4);
xline(phase_fit_first_repetition, 'k--', 'stable fit start');
xline(options.preamble_repetitions, 'm--', 'configured SYNC end');
grid on;
xlabel('Tracked preamble repetition');
ylabel('Unwrapped phase (rad)');
title(sprintf('Correlation-peak phase | stable CFO %+.3f kHz', ...
    stable_cfo_hz/1e3));
legend('Peak phase', 'Stable linear fit', 'Location', 'best');

subplot(2, 2, 4);
plot(2:numel(peak_values), instantaneous_cfo_hz/1e3, '.-', ...
    'Color', [0.55 0.20 0.75], 'MarkerSize', 5);
hold on;
yline(stable_cfo_hz/1e3, 'r--', 'stable fitted CFO');
xline(phase_fit_first_repetition, 'k--', 'stable fit start');
xline(options.preamble_repetitions, 'm--', 'configured SYNC end');
grid on;
xlabel('Tracked preamble repetition');
ylabel('Phase increment / period (kHz)');
title('Instantaneous CFO from adjacent correlation peaks');

sgtitle(sprintf(['DW1000 Preamble raw correlation phase | Code %d | ', ...
    'configured SYNC %d'], options.code_index, ...
    options.preamble_repetitions));
exportgraphics(gcf, output_png, 'Resolution', 180);
fprintf('Figure saved: %s\n', output_png);
