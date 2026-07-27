%% Compare 10 ms of raw vs cancelled capture in the time domain.
% Reads the same 10 ms window from both the original capture and the
% cancelled capture, then plots amplitude, real part, and imaginary part
% side by side. Use this to verify cancellation quality over a longer
% window that spans multiple packets.
clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% 0. User configuration
% Start of the 10 ms window (zero-based complex-sample offset).
window_offset = 4272165;

% Source capture and cancellation mode. Every path below is derived from
% the input file name via fileparts, so switching captures only needs a
% change here.
input_file = 'F:\UWB基带数据\qm35_dw1000_1.dat';
cancellation_mode = 'optimal_complex';   % must match run_cancel_all_uwb_packets

% -------------------------------------------------------------------------
% Auto-generated paths. Do not edit unless your cancel script naming differs.
% The cancelled capture lives inside the profile subdirectory produced by
% run_cancel_all_uwb_packets (decoded_results/<capture>/<cancelled_mode>.dat).
% -------------------------------------------------------------------------
[~, capture_stem] = fileparts(input_file);
cancelled_tag = sprintf('cancelled_%s', cancellation_mode);
output_file = fullfile(project_dir, 'decoded_results', capture_stem, ...
    [cancelled_tag '.dat']);
metadata_file = fullfile(project_dir, 'decoded_results', capture_stem, ...
    [cancelled_tag '_metadata.mat']);

% Noise-floor reference region [offset_samples, length_samples] inside the
% read window. Pick a quiet span with no UWB packets. Set to [] to skip.
noise_ref_region = [3e5, 0.5e5];

% Save figures to disk when true. Set to false to only display on screen.
save_figures = false;
output_dir = fullfile(project_dir, 'decoded_results', ...
    capture_stem, 'visualize_10ms');
figure_resolution_dpi = 140;

%% 1. Load parameters and read the 10 ms window
if ~isfile(metadata_file)
    error('visualize_uwb_cancellation_10ms:MetadataNotFound', ...
        'Metadata file not found: %s', metadata_file);
end
meta = load(metadata_file, 'params');
params = meta.params;

c = uwbdecoder.constants();
fs_rx = params.fs_rx;
ant_num = params.ant_num;
channel_index = params.channel_index;
bytes_per_sample = c.BYTES_PER_IQ_SAMPLE * ant_num;

% 10 ms window length in samples.
window_duration_s = 20e-3;
window_num = round(window_duration_s * fs_rx);

% Clamp to file bounds.
capture_info = dir(input_file);
total_samples = floor(capture_info.bytes / bytes_per_sample);
window_offset = min(window_offset, total_samples - 1);
window_num = min(window_num, total_samples - window_offset);

fprintf('=== 10 ms cancellation comparison ===\n');
fprintf('Window offset : %d (%.3f ms)\n', ...
    window_offset, window_offset / fs_rx * 1e3);
fprintf('Window length : %d samples (%.3f ms)\n', ...
    window_num, window_num / fs_rx * 1e3);

raw_original = uwbdecoder.readIqRaw(input_file, ...
    window_offset, window_num, ant_num);
rx_original = uwbdecoder.selectIqChannel(raw_original, channel_index);
raw_cancelled = uwbdecoder.readIqRaw(output_file, ...
    window_offset, window_num, ant_num);
rx_cancelled = uwbdecoder.selectIqChannel(raw_cancelled, channel_index);

% Time axis in milliseconds.
t_ms = (window_offset + (0:window_num - 1).') / fs_rx * 1e3;

%% 2. Remove the clock-synchronous single tone (same as the decoder)
tone_removed = false;
if params.enable_interference_cancellation && ...
        isfield(params, 'interference_tone_bin') && ...
        ~isempty(params.interference_tone_bin) && ...
        isfield(params, 'interference_period_samples') && ...
        ~isempty(params.interference_period_samples)
    tone_bin = params.interference_tone_bin;
    tone_period = params.interference_period_samples;
    quiet_offset = 0;
    if isfield(params, 'interference_quiet_offset')
        quiet_offset = params.interference_quiet_offset;
    end
    quiet_num = min(params.interference_quiet_num, ...
        max(0, total_samples - quiet_offset));
    if quiet_num >= tone_period
        raw_quiet = uwbdecoder.readIqRaw(input_file, ...
            quiet_offset, quiet_num, ant_num);
        rx_quiet = uwbdecoder.selectIqChannel(raw_quiet, channel_index);
        quiet_n = quiet_offset + (0:numel(rx_quiet) - 1).';
        quiet_basis = uwbdecoder.synchronousTone( ...
            quiet_n, tone_bin, tone_period);
        tone_coeff = mean(rx_quiet .* conj(quiet_basis));

        window_n = window_offset + (0:window_num - 1).';
        window_basis = uwbdecoder.synchronousTone( ...
            window_n, tone_bin, tone_period);
        rx_original = rx_original - tone_coeff .* window_basis;
        rx_cancelled = rx_cancelled - tone_coeff .* window_basis;

        tone_removed = true;
        fprintf('Tone removed: bin=%d/%d | coeff %.1f ADC\n', ...
            tone_bin, tone_period, abs(tone_coeff));
    end
end

% Derived signals.
rx_removed = rx_original - rx_cancelled;
amp_original = abs(rx_original);
amp_cancelled = abs(rx_cancelled);

%% 3. Compute suppression statistics
original_power = mean(abs(rx_original).^2);
cancelled_power = mean(abs(rx_cancelled).^2);
suppression_db = 10 * log10(original_power / (cancelled_power + eps));
fprintf('Window suppression: %.3f dB\n', suppression_db);

%% 4. Plot: amplitude, real part, imaginary part
figure('Name', sprintf('Cancellation 10 ms @ %.3f ms', ...
    window_offset / fs_rx * 1e3), 'Color', 'w', ...
    'Position', [60 50 1400 900]);

% Amplitude.
subplot(3, 1, 1);
plot(t_ms, amp_original,'o', 'Color', [0.10 0.45 0.85], ...
    'LineWidth', 0.6);
hold on;
plot(t_ms, amp_cancelled,'o', 'Color', [0.85 0.30 0.12], ...
    'LineWidth', 0.6);
grid on;
xlabel('Time (ms)');
ylabel('|IQ| (ADC)');
title(sprintf('Amplitude | suppression %.2f dB', suppression_db));
legend('Original', 'Cancelled', 'Location', 'best');
xlim(t_ms([1 end]));

% Real part.
subplot(3, 1, 2);
plot(t_ms, real(rx_original), 'Color', [0.10 0.45 0.85], ...
    'LineWidth', 0.6);
hold on;
plot(t_ms, real(rx_cancelled), 'Color', [0.85 0.30 0.12], ...
    'LineWidth', 0.6);
grid on;
xlabel('Time (ms)');
ylabel('Real (ADC)');
title('Real part');
legend('Original', 'Cancelled', 'Location', 'best');
xlim(t_ms([1 end]));

% Imaginary part.
subplot(3, 1, 3);
plot(t_ms, imag(rx_original), 'Color', [0.10 0.45 0.85], ...
    'LineWidth', 0.6);
hold on;
plot(t_ms, imag(rx_cancelled), 'Color', [0.85 0.30 0.12], ...
    'LineWidth', 0.6);
grid on;
xlabel('Time (ms)');
ylabel('Imaginary (ADC)');
title('Imaginary part');
legend('Original', 'Cancelled', 'Location', 'best');
xlim(t_ms([1 end]));

sgtitle(sprintf(['10 ms cancellation comparison | offset %d (%.3f ms) | ', ...
    '%d samples | tone removed: %s'], window_offset, ...
    window_offset / fs_rx * 1e3, window_num, string(tone_removed)), ...
    'Interpreter', 'none');

%% 5. Figure 2: power spectrum comparison
% Compare the original and cancelled power spectra in a new figure so the
% full 10 ms window (or a user-selected sub-window) can be inspected in the
% frequency domain.
spectrum_window = 1:min(window_num, 2^18);   % up to 256k samples
nfft = numel(spectrum_window);
win = hann(nfft);
spec_original = fftshift(fft(rx_original(spectrum_window) .* win));
spec_cancelled = fftshift(fft(rx_cancelled(spectrum_window) .* win));
f_axis = (-nfft / 2:nfft / 2 - 1).' * fs_rx / nfft / 1e6;
mag_original = 10 * log10(abs(spec_original).^2 + eps);
mag_cancelled = 10 * log10(abs(spec_cancelled).^2 + eps);
spec_floor = max(mag_original);

figure('Name', sprintf('Cancellation 10 ms @ %.3f ms - spectrum', ...
    window_offset / fs_rx * 1e3), 'Color', 'w', ...
    'Position', [70 60 1400 500]);

% Noise-floor reference spectrum from a quiet sub-window.
spec_noise = [];
if ~isempty(noise_ref_region) && numel(noise_ref_region) == 2
    noise_start = noise_ref_region(1);
    noise_len = min(noise_ref_region(2), ...
        window_num - noise_start + 1);
    if noise_len >= 256
        noise_end = noise_start + noise_len - 1;
        noise_nfft = noise_len;
        noise_win = hann(noise_nfft);
        spec_noise = fftshift(fft( ...
            rx_cancelled(noise_start:noise_end) .* noise_win));
        mag_noise = 10 * log10(abs(spec_noise).^2 + eps);
        noise_f_axis = (-noise_nfft / 2:noise_nfft / 2 - 1).' * ...
            fs_rx / noise_nfft / 1e6;
        fprintf('Noise reference: samples %d..%d (%d samples)\n', ...
            noise_start, noise_end, noise_nfft);
    end
end

subplot(1, 2, 1);
plot(f_axis, mag_original - spec_floor, ...
    'Color', [0.10 0.45 0.85], 'LineWidth', 0.8);
hold on;
plot(f_axis, mag_cancelled - spec_floor, ...
    'Color', [0.85 0.30 0.12], 'LineWidth', 0.8);
if ~isempty(spec_noise)
    plot(noise_f_axis, mag_noise - spec_floor, '--', ...
        'Color', [0.55 0.55 0.55], 'LineWidth', 0.8);
end
grid on;
xlabel('Baseband frequency (MHz)');
ylabel('Power spectral density (dB)');
if ~isempty(spec_noise)
    legend('Original', 'Cancelled', 'Noise-only ref', ...
        'Location', 'best');
else
    legend('Original', 'Cancelled', 'Location', 'best');
end
ylim([-70 5]);

subplot(1, 2, 2);
plot(f_axis, mag_original - mag_cancelled, ...
    'Color', [0.20 0.65 0.45], 'LineWidth', 0.8);
grid on;
xlabel('Baseband frequency (MHz)');
ylabel('Suppression (dB)');
title('Cancellation depth (original - cancelled)');

sgtitle(sprintf(['10 ms cancellation spectrum | offset %d (%.3f ms) | ', ...
    'NFFT %d | tone removed: %s'], window_offset, ...
    window_offset / fs_rx * 1e3, nfft, string(tone_removed)), ...
    'Interpreter', 'none');

%% 6. Save figure
if save_figures && ~isempty(output_dir)
    if ~isfolder(output_dir)
        mkdir(output_dir);
    end
    fig_handles = findall(0, 'Type', 'figure');
    fig_handles = sort(fig_handles);
    for f = 1:numel(fig_handles)
        fig_name = sprintf('cancellation_10ms_offset_%d_fig_%d.png', ...
            window_offset, f);
        fig_path = fullfile(output_dir, fig_name);
        try
            exportgraphics(fig_handles(f), fig_path, ...
                'Resolution', figure_resolution_dpi);
            fprintf('Saved: %s\n', fig_path);
        catch ME
            fprintf('  (figure %d not saved: %s)\n', f, ME.message);
        end
    end
end
