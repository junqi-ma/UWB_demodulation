%% Visualize a selectable-length segment of a UWB capture.
% Reads an arbitrary-length window from an X410 capture file and plots:
%   Figure 1: time-domain I/Q waveform + envelope
%   Figure 2: power spectrum (full bandwidth + optional zoom)
%   Figure 3: spectrogram (time-frequency view)
%
% All parameters are in the "User configuration" section below. Change
% file_name, sample_offset, and sample_num to inspect any region of any
% capture file.
clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

c = uwbdecoder.constants();

%% 0. User configuration
% Capture file to inspect.
file_name = 'D:\bupt\project\UWB基带数据\qm35_dw1000_processed_1.dat';

% RF center frequency (Hz) for absolute frequency display.
center_frequency = 6489.6e6;

% Sample rate (Hz).
fs = 737.28e6;

% Number of antenna channels in the file.
ant_num = 1;

% Which channel to display (1-based).
channel_index = 1;

% Start offset (zero-based complex-sample index).
sample_offset = 0;

% Number of complex samples to read and display.
sample_num = 2000000;

% Optional: zoom window around DC in the spectrum plot (Hz half-width).
% Set to 0 to disable the zoom panel.
spectrum_zoom_half_width = 50e6;

% Spectrogram FFT size and overlap.
spectrogram_fft_num = 4096;
spectrogram_overlap = 3072;

% Save figures to disk when true.
save_figures = false;
output_dir = fullfile(project_dir, 'decoded_results', ...
    'visualize_segment');
figure_resolution_dpi = 120;

%% 1. Read IQ data
fprintf('Reading %d samples from offset %d of:\n  %s\n', ...
    sample_num, sample_offset, file_name);

raw = uwbdecoder.readIqRaw(file_name, sample_offset, sample_num, ant_num);
comp_data = uwbdecoder.selectIqChannel(raw, channel_index);
clear raw;

actual_count = numel(comp_data);
t_us = (sample_offset + (0:actual_count-1)) / fs * 1e6;
t_start_us = t_us(1);
t_end_us = t_us(end);

fprintf('Read %d complex samples (%.3f us, %.6f ms)\n', ...
    actual_count, t_us(end), t_us(end) / 1e3);

%% 2. Figure 1: time-domain waveform
fig1 = figure('Name', 'UWB segment: time domain', ...
    'Color', 'w', 'Position', [60 60 1200 600]);

% Envelope + I/Q on a shared time axis.
subplot(2, 1, 1); hold on;
env = abs(comp_data);
plot(t_us, env, '-', 'Color', [0.30 0.30 0.30], 'LineWidth', 0.6, ...
    'DisplayName', 'Envelope');
plot(t_us, real(comp_data), '-', 'Color', [0.20 0.60 0.90], ...
    'LineWidth', 0.4, 'DisplayName', 'In-phase (I)');
plot(t_us, imag(comp_data), '-', 'Color', [0.90 0.45 0.20], ...
    'LineWidth', 0.4, 'DisplayName', 'Quadrature (Q)');
grid on;
xlabel('Time (us)');
ylabel('Amplitude (ADC counts)');
title(sprintf('Time domain: %.3f -- %.3f us', t_start_us, t_end_us));
legend('Location', 'best');
xlim([t_start_us, t_end_us]);

% Short detail view: first min(2000, N) samples, to see the waveform shape.
subplot(2, 1, 2); hold on;
detail_count = min(2000, actual_count);
plot(t_us(1:detail_count), real(comp_data(1:detail_count)), ...
    '-', 'Color', [0.20 0.60 0.90], 'LineWidth', 0.8, ...
    'DisplayName', 'In-phase (I)');
plot(t_us(1:detail_count), imag(comp_data(1:detail_count)), ...
    '-', 'Color', [0.90 0.45 0.20], 'LineWidth', 0.8, ...
    'DisplayName', 'Quadrature (Q)');
grid on;
xlabel('Time (us)');
ylabel('Amplitude (ADC counts)');
title(sprintf('Detail: first %d samples', detail_count));
legend('Location', 'best');

sgtitle(sprintf('UWB segment: %s', file_name), 'Interpreter', 'none');
drawnow;

%% 3. Figure 2: power spectrum
fig2 = figure('Name', 'UWB segment: spectrum', ...
    'Color', 'w', 'Position', [60 60 1200 500]);

n_fft = min(actual_count, 262144);
% Hann window reduces spectral leakage.
win = (0.5 - 0.5 * cos(2*pi*(0:n_fft-1) / (n_fft-1))).';
fft_data = fftshift(fft(comp_data(1:n_fft) .* win, n_fft));
spectrum_db = 20 * log10(abs(fft_data) + eps);
spectrum_db = spectrum_db - max(spectrum_db);
freq_rel_hz = ((-floor(n_fft/2):ceil(n_fft/2)-1) * fs / n_fft).';
freq_abs_hz = center_frequency + freq_rel_hz;

if spectrum_zoom_half_width > 0
    layout_rows = 1;
    layout_cols = 2;
else
    layout_rows = 1;
    layout_cols = 1;
end

% Full-band spectrum (absolute RF frequency).
subplot(layout_rows, layout_cols, 1); hold on;
plot(freq_abs_hz / 1e9, spectrum_db, '-', 'Color', [0.20 0.60 0.90], ...
    'LineWidth', 0.6);
xline(center_frequency / 1e9, '--k', 'DC');
grid on;
xlabel('Absolute RF frequency (GHz)');
ylabel('Normalized magnitude (dB)');
title(sprintf('Full-band spectrum (%d-point FFT)', n_fft));
xlim((center_frequency + [-fs/2, fs/2]) / 1e9);
ylim([-100, 5]);

% Optional zoom around DC.
if spectrum_zoom_half_width > 0
    subplot(layout_rows, layout_cols, 2); hold on;
    zoom_mask = abs(freq_rel_hz) <= spectrum_zoom_half_width;
    plot(freq_rel_hz(zoom_mask) / 1e6, spectrum_db(zoom_mask), ...
        '-', 'Color', [0.90 0.45 0.20], 'LineWidth', 0.6);
    xline(0, '--k', 'DC');
    grid on;
    xlabel('Relative frequency (MHz)');
    ylabel('Normalized magnitude (dB)');
    title(sprintf('Zoom around DC (+/- %.1f MHz)', ...
        spectrum_zoom_half_width / 1e6));
    ylim([-100, 5]);
end

sgtitle(sprintf('UWB segment spectrum: %s', file_name), 'Interpreter', 'none');
drawnow;

%% 4. Figure 3: spectrogram
fig3 = figure('Name', 'UWB segment: spectrogram', ...
    'Color', 'w', 'Position', [60 60 1200 500]);

% Use relative frequency so the DC component sits at 0 regardless of the
% absolute RF center frequency.
[s, f_rel, t_spec] = spectrogram(comp_data, ...
    hamming(spectrogram_fft_num), spectrogram_overlap, ...
    spectrogram_fft_num, fs, 'yaxis');
spec_db = 20 * log10(abs(s) + eps);
spec_db = spec_db - max(spec_db(:));

imagesc(t_spec * 1e6 + t_start_us, f_rel / 1e6, spec_db);
axis xy;
colorbar;
colormap(gca, parula);
clim([-80, 0]);
xlabel('Time (us)');
ylabel('Relative frequency (MHz)');
title(sprintf('Spectrogram (FFT %d, overlap %d)', ...
    spectrogram_fft_num, spectrogram_overlap));
yline(0, '--w', 'DC');

sgtitle(sprintf('UWB segment spectrogram: %s', file_name), ...
    'Interpreter', 'none');
drawnow;

%% 5. Save figures
if save_figures
    if ~isfolder(output_dir)
        mkdir(output_dir);
    end
    fprintf('Saving figures to %s ...\n', output_dir);
    savefast(fig1, fullfile(output_dir, 'segment_time.png'));
    savefast(fig2, fullfile(output_dir, 'segment_spectrum.png'));
    savefast(fig3, fullfile(output_dir, 'segment_spectrogram.png'));
end

%% 6. Console summary
fprintf('\n========== UWB segment visualization ==========\n');
fprintf('File         : %s\n', file_name);
fprintf('Offset       : %d samples (%.3f us)\n', sample_offset, ...
    sample_offset / fs * 1e6);
fprintf('Length       : %d samples (%.3f us / %.6f ms)\n', ...
    actual_count, actual_count / fs * 1e6, actual_count / fs * 1e3);
fprintf('Sample rate  : %.3f MHz\n', fs / 1e6);
fprintf('RF center    : %.6f GHz\n', center_frequency / 1e9);
fprintf('Peak amplitude: %.1f ADC counts\n', max(env));
fprintf('RMS amplitude : %.1f ADC counts\n', rms(comp_data));
fprintf('=================================================\n');

%% ------------------------------------------------------------------------
function savefast(fig, png_path)
%SAVEFAST Save a figure as PNG quickly. Try exportgraphics first, fall back
% to saveas if the exportgraphics call fails (e.g. no OpenGL support).
try
    exportgraphics(fig, png_path, 'Resolution', 120);
catch
    try
        saveas(fig, png_path);
    catch ME
        fprintf('  (failed to save %s: %s)\n', png_path, ME.message);
    end
end
end
