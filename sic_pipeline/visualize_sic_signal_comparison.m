%% Compare raw IQ with tone/DW1000 removed and QM35 preserved.
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
    'qm35_dw1000_1', 'sic_dw1000_removed_qm35_preserved', ...
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
qm35_preserved_file = pipeline.stages.dw1000_cancel.output_file;

if ~isfile(original_file)
    error('visualize_sic_signal_comparison:OriginalNotFound', ...
        'Original capture not found: %s', original_file);
end
if ~isfile(qm35_preserved_file)
    error('visualize_sic_signal_comparison:CancelledNotFound', ...
        'QM35-preserved output not found: %s', qm35_preserved_file);
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
cancelled_info = dir(qm35_preserved_file);
if original_info.bytes ~= cancelled_info.bytes
    error('visualize_sic_signal_comparison:LengthMismatch', ...
        'Original and QM35-preserved files have different lengths.');
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

raw_cancelled = uwbdecoder.readIqRaw( ...
    qm35_preserved_file, window_offset, window_num, ant_num);
rx_cancelled = uwbdecoder.selectIqChannel(raw_cancelled, channel_index);
clear raw_cancelled;

t_ms = (window_offset + (0:window_num - 1).') / fs_rx * 1e3;
plot_step = max(1, ceil(window_num / max_time_plot_points));
plot_idx = 1:plot_step:window_num;

power_original = mean(abs(rx_original).^2);
power_cancelled = mean(abs(rx_cancelled).^2);
window_suppression_db = 10 * log10( ...
    power_original / (power_cancelled + eps));

%% -------------------- Figure 1: time-domain comparison --------------------
fig_time = figure('Name', 'Raw vs QM35-preserved signal', ...
    'Color', 'w', 'Position', [70 50 1400 900]);

subplot(3, 1, 1);
plot(t_ms(plot_idx), abs(rx_original(plot_idx)), ...
    'Color', [0.15 0.45 0.85], 'LineWidth', 0.7);
hold on;
plot(t_ms(plot_idx), abs(rx_cancelled(plot_idx)), ...
    'Color', [0.85 0.30 0.15], 'LineWidth', 0.7);
xlabel('Capture time (ms)');
ylabel('|IQ| (ADC)');
title(sprintf('Amplitude, interval power suppression %.2f dB', ...
    window_suppression_db));
legend('Original mixed signal', 'Tone/DW1000 removed; QM35 preserved', ...
    'Location', 'best');
grid on;
xlim(t_ms([1 end]));

subplot(3, 1, 2);
plot(t_ms(plot_idx), real(rx_original(plot_idx)), ...
    'Color', [0.15 0.45 0.85], 'LineWidth', 0.7);
hold on;
plot(t_ms(plot_idx), real(rx_cancelled(plot_idx)), ...
    'Color', [0.85 0.30 0.15], 'LineWidth', 0.7);
xlabel('Capture time (ms)');
ylabel('Real (ADC)');
title('In-phase component');
legend('Original', 'QM35-preserved output', 'Location', 'best');
grid on;
xlim(t_ms([1 end]));

subplot(3, 1, 3);
plot(t_ms(plot_idx), imag(rx_original(plot_idx)), ...
    'Color', [0.15 0.45 0.85], 'LineWidth', 0.7);
hold on;
plot(t_ms(plot_idx), imag(rx_cancelled(plot_idx)), ...
    'Color', [0.85 0.30 0.15], 'LineWidth', 0.7);
xlabel('Capture time (ms)');
ylabel('Imaginary (ADC)');
title('Quadrature component');
legend('Original', 'QM35-preserved output', 'Location', 'best');
grid on;
xlim(t_ms([1 end]));

sgtitle(sprintf(['Original vs QM35-preserved output | %.3f--%.3f ms | ', ...
    '%d samples'], t_ms(1), t_ms(end), window_num));

%% -------------------- Figure 2: spectrum comparison --------------------
nfft = min(window_num, max_spectrum_samples);
spec_idx = 1:nfft;
win = hann(nfft);
spec_original = fftshift(fft(rx_original(spec_idx) .* win));
spec_cancelled = fftshift(fft(rx_cancelled(spec_idx) .* win));
frequency_mhz = (-nfft / 2:nfft / 2 - 1).' * fs_rx / nfft / 1e6;

power_spectrum_original = 10 * log10(abs(spec_original).^2 + eps);
power_spectrum_cancelled = 10 * log10(abs(spec_cancelled).^2 + eps);
normalizer = max(power_spectrum_original);

fig_spectrum = figure('Name', 'Raw vs QM35-preserved spectrum', ...
    'Color', 'w', 'Position', [90 70 1300 520]);

subplot(1, 2, 1);
plot(frequency_mhz, power_spectrum_original - normalizer, ...
    'Color', [0.15 0.45 0.85], 'LineWidth', 0.8);
hold on;
plot(frequency_mhz, power_spectrum_cancelled - normalizer, ...
    'Color', [0.85 0.30 0.15], 'LineWidth', 0.8);
xlabel('Baseband frequency (MHz)');
ylabel('Power relative to original peak (dB)');
title('Power spectrum');
legend('Original mixed signal', ...
    'Tone/DW1000 removed; QM35 preserved', 'Location', 'best');
ylim([-80 5]);
grid on;

subplot(1, 2, 2);
plot(frequency_mhz, ...
    power_spectrum_original - power_spectrum_cancelled, ...
    'Color', [0.20 0.65 0.40], 'LineWidth', 0.8);
xlabel('Baseband frequency (MHz)');
ylabel('Original - residual (dB)');
title('Frequency-dependent suppression');
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
        ['raw_vs_qm35_preserved_' tag '_time.png']);
    spectrum_png = fullfile(output_dir, ...
        ['raw_vs_qm35_preserved_' tag '_spectrum.png']);
    exportgraphics(fig_time, time_png, ...
        'Resolution', figure_resolution_dpi);
    exportgraphics(fig_spectrum, spectrum_png, ...
        'Resolution', figure_resolution_dpi);
    fprintf('Saved: %s\n', time_png);
    fprintf('Saved: %s\n', spectrum_png);
end

fprintf('\n=== Raw vs QM35-preserved signal ===\n');
fprintf('Original       : %s\n', original_file);
fprintf('QM35 preserved : %s\n', qm35_preserved_file);
fprintf('Interval       : %.3f .. %.3f ms\n', t_ms(1), t_ms(end));
fprintf('Samples        : %d\n', window_num);
fprintf('Power suppress.: %.3f dB\n', window_suppression_db);
