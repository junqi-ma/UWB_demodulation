%% Compare raw IQ with the QM35-removed intermediate IQ.
% This standalone script reads only one configurable time interval.
clear;
close all;
clc;

pipeline_dir = fileparts(mfilename('fullpath'));
project_dir = fileparts(pipeline_dir);
addpath(project_dir);
addpath(pipeline_dir);

%% -------------------- User configuration --------------------
manifest_file = fullfile(project_dir, 'decoded_results', ...
    'qm35_dw1000_new_3', 'sic_dw1000_removed_qm35_preserved', ...
    'pipeline_manifest.mat');

% Requested comparison interval on the original capture timeline.
window_start_ms = 25;
window_duration_ms = 10.0;

save_figures = true;
figure_resolution_dpi = 140;
max_time_plot_points = 150000;
max_spectrum_samples = 2^18;

%% -------------------- Load paths and radio parameters --------------------
if ~isfile(manifest_file)
    error('visualize_sic_signal_comparison:ManifestNotFound', ...
        'Pipeline manifest not found: %s', manifest_file);
end

saved_pipeline = load(manifest_file, 'pipeline');
pipeline = saved_pipeline.pipeline;
original_file = pipeline.config.input_file;
qm35_removed_file = pipeline.stages.qm35_cancel.output_file;

if ~isfile(original_file)
    error('visualize_sic_signal_comparison:OriginalNotFound', ...
        'Original capture not found: %s', original_file);
end
if ~isfile(qm35_removed_file)
    error('visualize_sic_signal_comparison:Qm35RemovedNotFound', ...
        'QM35-removed intermediate output not found: %s', ...
        qm35_removed_file);
end
decode_saved = load( ...
    pipeline.stages.dw1000_decode.scan_file, 'results');
params = decode_saved.results.params;
fs_rx = params.fs_rx;
ant_num = params.ant_num;
channel_index = params.channel_index;

c = uwbdecoder.constants();
bytes_per_sample = c.BYTES_PER_IQ_SAMPLE * ant_num;
original_info = dir(original_file);
qm35_removed_info = dir(qm35_removed_file);
if original_info.bytes ~= qm35_removed_info.bytes
    error('visualize_sic_signal_comparison:LengthMismatch', ...
        'Original and QM35-removed files must have the same length.');
end
total_samples = floor(original_info.bytes / bytes_per_sample);

window_offset = round(window_start_ms * 1e-3 * fs_rx);
window_num = round(window_duration_ms * 1e-3 * fs_rx);
if window_offset < 0 || window_offset >= total_samples
    error('visualize_sic_signal_comparison:OffsetOutOfRange', ...
        'window_start_ms is outside the capture.');
end
window_num = min(window_num, total_samples - window_offset);
if window_num < 2
    error('visualize_sic_signal_comparison:WindowTooShort', ...
        'The selected comparison interval is too short.');
end

%% -------------------- Read the selected interval --------------------
raw_original = uwbdecoder.readIqRaw( ...
    original_file, window_offset, window_num, ant_num);
rx_original = uwbdecoder.selectIqChannel(raw_original, channel_index);
clear raw_original;

raw_qm35_removed = uwbdecoder.readIqRaw( ...
    qm35_removed_file, window_offset, window_num, ant_num);
rx_qm35_removed = uwbdecoder.selectIqChannel( ...
    raw_qm35_removed, channel_index);
clear raw_qm35_removed;

t_ms = (window_offset + (0:window_num - 1).') / fs_rx * 1e3;
plot_step = max(1, ceil(window_num / max_time_plot_points));
plot_idx = 1:plot_step:window_num;

power_original = mean(abs(rx_original).^2);
power_qm35_removed = mean(abs(rx_qm35_removed).^2);
qm35_stage_suppression_db = 10 * log10( ...
    power_original / (power_qm35_removed + eps));

%% -------------------- Figure 1: time-domain comparison --------------------
fig_time = figure('Name', 'Original vs QM35-removed signal', ...
    'Color', 'w', 'Position', [70 50 1400 900]);

subplot(3, 1, 1);
plot(t_ms(plot_idx), abs(rx_original(plot_idx)), ...
    'Color', [0.15 0.45 0.85], 'LineWidth', 0.7);
hold on;
plot(t_ms(plot_idx), abs(rx_qm35_removed(plot_idx)), ...
    'Color', [0.20 0.65 0.40], 'LineWidth', 0.7);
xlabel('Capture time (ms)');
ylabel('|IQ| (ADC)');
title(sprintf('Amplitude | QM35-stage suppression: %.2f dB', ...
    qm35_stage_suppression_db));
legend('Original mixed signal', 'Tone/QM35 removed; DW1000 retained', ...
    'Location', 'best');
grid on;
xlim(t_ms([1 end]));

subplot(3, 1, 2);
plot(t_ms(plot_idx), real(rx_original(plot_idx)), ...
    'Color', [0.15 0.45 0.85], 'LineWidth', 0.7);
hold on;
plot(t_ms(plot_idx), real(rx_qm35_removed(plot_idx)), ...
    'Color', [0.20 0.65 0.40], 'LineWidth', 0.7);
xlabel('Capture time (ms)');
ylabel('Real (ADC)');
title('In-phase component');
legend('Original', 'QM35-removed intermediate', 'Location', 'best');
grid on;
xlim(t_ms([1 end]));

subplot(3, 1, 3);
plot(t_ms(plot_idx), imag(rx_original(plot_idx)), ...
    'Color', [0.15 0.45 0.85], 'LineWidth', 0.7);
hold on;
plot(t_ms(plot_idx), imag(rx_qm35_removed(plot_idx)), ...
    'Color', [0.20 0.65 0.40], 'LineWidth', 0.7);
xlabel('Capture time (ms)');
ylabel('Imaginary (ADC)');
title('Quadrature component');
legend('Original', 'QM35-removed intermediate', 'Location', 'best');
grid on;
xlim(t_ms([1 end]));

sgtitle(sprintf(['Original vs QM35-removed intermediate | ', ...
    '%.3f--%.3f ms | ', ...
    '%d samples'], t_ms(1), t_ms(end), window_num));

%% -------------------- Figure 2: spectrum comparison --------------------
nfft = min(window_num, max_spectrum_samples);
spec_idx = 1:nfft;
win = hann(nfft);
spec_original = fftshift(fft(rx_original(spec_idx) .* win));
spec_qm35_removed = fftshift(fft(rx_qm35_removed(spec_idx) .* win));
frequency_mhz = (-nfft / 2:nfft / 2 - 1).' * fs_rx / nfft / 1e6;

power_spectrum_original = 10 * log10(abs(spec_original).^2 + eps);
power_spectrum_qm35_removed = ...
    10 * log10(abs(spec_qm35_removed).^2 + eps);
normalizer = max(power_spectrum_original);

fig_spectrum = figure('Name', 'Original vs QM35-removed spectrum', ...
    'Color', 'w', 'Position', [90 70 1300 520]);

subplot(1, 2, 1);
plot(frequency_mhz, power_spectrum_original - normalizer, ...
    'Color', [0.15 0.45 0.85], 'LineWidth', 0.8);
hold on;
plot(frequency_mhz, power_spectrum_qm35_removed - normalizer, ...
    'Color', [0.20 0.65 0.40], 'LineWidth', 0.8);
xlabel('Baseband frequency (MHz)');
ylabel('Power relative to original peak (dB)');
title('Power spectrum');
legend('Original mixed signal', ...
    'Tone/QM35 removed; DW1000 retained', 'Location', 'best');
ylim([-80 5]);
grid on;

subplot(1, 2, 2);
plot(frequency_mhz, ...
    power_spectrum_original - power_spectrum_qm35_removed, ...
    'Color', [0.20 0.65 0.40], 'LineWidth', 0.8);
xlabel('Baseband frequency (MHz)');
ylabel('Original - residual (dB)');
title('Frequency-dependent suppression');
legend('After QM35 cancellation', 'Location', 'best');
grid on;

sgtitle(sprintf('Spectrum comparison | start %.3f ms | NFFT %d', ...
    window_start_ms, nfft));

%% -------------------- Save figures --------------------
if save_figures
    output_dir = pipeline.paths.validation_dir;
    if ~isfolder(output_dir)
        mkdir(output_dir);
    end
    tag = sprintf('start_%0.3fms_duration_%0.3fms', ...
        window_start_ms, window_duration_ms);
    tag = strrep(tag, '.', 'p');
    time_png = fullfile(output_dir, ...
        ['raw_vs_qm35_removed_' tag '_time.png']);
    spectrum_png = fullfile(output_dir, ...
        ['raw_vs_qm35_removed_' tag '_spectrum.png']);
    exportgraphics(fig_time, time_png, ...
        'Resolution', figure_resolution_dpi);
    exportgraphics(fig_spectrum, spectrum_png, ...
        'Resolution', figure_resolution_dpi);
    fprintf('Saved: %s\n', time_png);
    fprintf('Saved: %s\n', spectrum_png);
end

fprintf('\n=== Original vs QM35-removed signal ===\n');
fprintf('Original          : %s\n', original_file);
fprintf('QM35 removed      : %s\n', qm35_removed_file);
fprintf('Interval          : %.3f .. %.3f ms\n', t_ms(1), t_ms(end));
fprintf('Samples           : %d\n', window_num);
fprintf('QM35-stage suppress.: %.3f dB\n', qm35_stage_suppression_db);
