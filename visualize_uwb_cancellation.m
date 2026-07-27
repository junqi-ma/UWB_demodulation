%% Visualize the cancellation effect of a single DW1000 packet.
% Reads both the original capture and the cancelled capture, compares them
% around one user-selected packet, and plots the envelope before/after, the
% subtracted (removed) signal, and the spectrum. The packet index parameter
% selects which packet to inspect from the cancellation run.
%
% Requires the run_cancel_all_uwb_packets output: the cancelled capture,
% its metadata MAT (carries params + per-packet reports), and optionally the
% decoded_results/<scan>/all_frames_cir.mat for PHR/Payload boundaries.
clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% 0. User configuration
% Which packet to inspect (1-based index into the sorted report list).
packet_index = 1;

% Source capture and cancellation mode. Every path below is derived from
% these two via fileparts + the mode tag, so switching captures only needs
% a change here.
input_file = 'F:\UWB基带数据\qm35_1.dat';
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
summary_file = fullfile(project_dir, 'decoded_results', capture_stem, ...
    [cancelled_tag '_summary.csv']);

% Context window (samples) shown on each side of the packet.
window_pad_samples = 2048;

% Noise-only reference region [offset, num_samples] for the noise-floor
% spectrum. Leave empty to use the guard interval immediately before the
% packet (same length as the packet, i.e. packet_samples long).
noise_ref_region = [];   % e.g. [400000, 227565]

% Save figures to disk when true. Set to false to only display on screen.
save_figures = false;
pause_on_suppression_preview = false;
output_dir = fullfile(project_dir, 'decoded_results', ...
    capture_stem, 'visualize');
figure_resolution_dpi = 140;

% -------------------------------------------------------------------------
% Load run metadata and select the requested packet.
% -------------------------------------------------------------------------
if ~isempty(summary_file) && isfile(summary_file)
    summary_table = readtable(summary_file);
else
    summary_table = table([]);
end

% -------------------------------------------------------------------------
% Preview: suppression vs packet index, so the user can pick a packet.
% Plotted before any heavy IQ read. Close the figure to continue.
% -------------------------------------------------------------------------
if ~isempty(summary_table) && ismember('frame_suppression_db', ...
        summary_table.Properties.VariableNames)
    fig_preview = figure('Name', 'DW1000 cancellation: suppression preview', ...
        'Color', 'w', 'Position', [80 80 1200 420]);

    packet_list_index = (1:height(summary_table)).';
    success_mask = summary_table.success == 1;
    suppression_db = summary_table.frame_suppression_db;

    plot(packet_list_index(success_mask), suppression_db(success_mask), ...
        'o-', 'Color', [0.10 0.45 0.85], 'MarkerSize', 4, ...
        'MarkerFaceColor', [0.10 0.45 0.85], 'LineWidth', 0.8);
    hold on;
    if any(~success_mask)
        plot(packet_list_index(~success_mask), ...
            zeros(nnz(~success_mask), 1), 'x', ...
            'Color', [0.85 0.30 0.12], 'MarkerSize', 6);
    end
    grid on;
    xlabel('Packet list index');
    ylabel('Frame suppression (dB)');
    title(sprintf(['Cancellation summary: %d packets (%d successful) | ', ...
        'median %.2f dB | mean %.2f dB'], ...
        height(summary_table), nnz(success_mask), ...
        median(suppression_db(success_mask)), ...
        mean(suppression_db(success_mask))));
    if any(~success_mask)
        legend('Successful', 'Skipped', 'Location', 'best');
    end

    if save_figures && ~isempty(output_dir)
        if ~isfolder(output_dir)
            mkdir(output_dir);
        end
        preview_path = fullfile(output_dir, 'suppression_preview.png');
        try
            exportgraphics(fig_preview, preview_path, ...
                'Resolution', figure_resolution_dpi);
            fprintf('Saved preview to: %s\n', preview_path);
        catch ME
            fprintf('  (preview not saved: %s)\n', ME.message);
        end
    end

    fprintf('\n=== Suppression preview ===\n');
    fprintf('Loaded %d packets from: %s\n', height(summary_table), summary_file);
    fprintf('Successful : %d\n', nnz(success_mask));
    fprintf('Suppression: min %.2f dB | median %.2f dB | max %.2f dB\n', ...
        min(suppression_db(success_mask)), ...
        median(suppression_db(success_mask)), ...
        max(suppression_db(success_mask)));
    if pause_on_suppression_preview
        fprintf(['Close the preview figure to continue, or Ctrl+C to ', ...
            'pick another packet_index.\n']);
        uiwait(fig_preview);
    end
end

if ~isfile(metadata_file)
    error('visualize_uwb_cancellation:MetadataNotFound', ...
        'Metadata file not found: %s', metadata_file);
end
meta = load(metadata_file, 'reports', 'params', 'success_count', 'frames');
reports = meta.reports;
params = meta.params;

if isempty(reports)
    error('visualize_uwb_cancellation:NoReports', ...
        'The metadata contains no packet reports.');
end
validateattributes(packet_index, {'numeric'}, ...
    {'scalar', 'integer', 'positive', '<=', numel(reports)}, ...
    'packet_index');

report = reports(packet_index);
if ~report.success
    error('visualize_uwb_cancellation:PacketFailed', ...
        'Packet %d (list position %d) was not cancelled successfully: %s', ...
        report.index, packet_index, report.message);
end

c = uwbdecoder.constants();
fs_rx = params.fs_rx;
ant_num = params.ant_num;
channel_index = params.channel_index;
bytes_per_sample = c.BYTES_PER_IQ_SAMPLE * ant_num;

% Read a window around the fitted packet start. Keep a pad on each side so
% the plot shows unaffected neighbours for context.
packet_first = report.abs_start_fitted;
packet_samples = report.samples_subtracted;
read_first = max(0, packet_first - window_pad_samples);
packet_last_absolute = packet_first + packet_samples - 1;
read_last = packet_last_absolute + window_pad_samples;
capture_info = dir(input_file);
total_samples = floor(capture_info.bytes / bytes_per_sample);
read_last = min(read_last, total_samples - 1);
read_num = read_last - read_first + 1;

fprintf('=== Visualize single-packet cancellation ===\n');
fprintf('Packet list position : %d / %d\n', packet_index, numel(reports));
fprintf('Packet index         : %d\n', report.index);
fprintf('Fitted start (sample): %d (%.3f ms)\n', ...
    packet_first, packet_first / fs_rx * 1e3);
fprintf('Samples subtracted   : %d\n', packet_samples);
fprintf('Read window          : %d .. %d (%d samples)\n', ...
    read_first, read_last, read_num);

% Read the same window from both captures.
raw_original = uwbdecoder.readIqRaw(input_file, read_first, read_num, ant_num);
rx_original = uwbdecoder.selectIqChannel(raw_original, channel_index);
raw_cancelled = uwbdecoder.readIqRaw(output_file, read_first, read_num, ant_num);
rx_cancelled = uwbdecoder.selectIqChannel(raw_cancelled, channel_index);

% Everything outside the subtracted region should be byte-for-byte equal.
% The difference signal is therefore exactly the removed UWB model.
rx_removed = rx_original - rx_cancelled;

% Absolute time axis (seconds) for the read window.
t_abs = read_first + (0:read_num - 1).';
t_sec = t_abs / fs_rx;
t_ms = t_sec * 1e3;

% Remove the clock-synchronous single tone before computing envelopes.
% The tone is an out-of-band interferer that would otherwise dominate the
% envelope and mask the UWB pulse structure. Estimate its coefficient from a
% quiet region (same as the decoder's interference cancellation), then
% subtract it from the original, cancelled, and reconstructed signals.
tone_cancelled = false;
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

        % Subtract the tone from each signal using its absolute sample grid.
        original_n = read_first + (0:read_num - 1).';
        original_basis = uwbdecoder.synchronousTone( ...
            original_n, tone_bin, tone_period);
        rx_original = rx_original - tone_coeff .* original_basis;
        rx_cancelled = rx_cancelled - tone_coeff .* original_basis;
        rx_removed = rx_original - rx_cancelled;

        tone_freq_hz = tone_bin / tone_period * fs_rx;
        tone_cancelled = true;
        fprintf('Tone removed: bin=%d/%d -> %+.3f MHz | coeff %.1f ADC\n', ...
            tone_bin, tone_period, tone_freq_hz / 1e6, abs(tone_coeff));
    end
end

% Local envelope via a sliding RMS so dense UWB pulses read as a smooth curve.
envelope_samples = max(1, round(0.25e-6 * fs_rx));
env_original = sqrt(movmean(abs(rx_original).^2, envelope_samples));
env_cancelled = sqrt(movmean(abs(rx_cancelled).^2, envelope_samples));
env_removed = sqrt(movmean(abs(rx_removed).^2, envelope_samples));

% Noise-floor reference: a same-length segment with no UWB signal. Default to
% the guard interval immediately before the packet (packet_samples long,
% starting at max(0, packet_first - packet_samples)). Override with
% noise_ref_region = [offset, num_samples] to pick a custom quiet region.
if isempty(noise_ref_region)
    noise_ref_offset = max(0, packet_first - packet_samples);
    noise_ref_num = packet_samples;
else
    noise_ref_offset = noise_ref_region(1);
    noise_ref_num = noise_ref_region(2);
end
noise_ref_offset = min(noise_ref_offset, total_samples - 1);
noise_ref_num = min(noise_ref_num, total_samples - noise_ref_offset);
env_noise = [];
if noise_ref_num >= 256
    raw_noise = uwbdecoder.readIqRaw(input_file, ...
        noise_ref_offset, noise_ref_num, ant_num);
    rx_noise = uwbdecoder.selectIqChannel(raw_noise, channel_index);
    env_noise = sqrt(movmean(abs(rx_noise).^2, envelope_samples));
    noise_rms = sqrt(mean(abs(rx_noise).^2));
    fprintf('Noise reference: offset=%d, %d samples, RMS=%.2f ADC\n', ...
        noise_ref_offset, noise_ref_num, noise_rms);
end

% Region markers in window-local coordinates.
local_packet_first = packet_first - read_first + 1;
local_packet_last = packet_last_absolute - read_first + 1;
field_markers = struct( ...
    'name', {'Packet start'; 'Packet end'}, ...
    'sample', [local_packet_first; local_packet_last]);

% Add PHR / Payload boundaries when available from the frame table.
packet_table_row = [];
if isfield(meta, 'frames')
    frame_match = find([meta.frames.index] == report.index, 1);
    if ~isempty(frame_match)
        packet_table_row = meta.frames(frame_match);
    end
end
if ~isempty(packet_table_row)
    if isfield(packet_table_row, 'abs_phr_start_sample') && ...
            ~isempty(packet_table_row.abs_phr_start_sample)
        field_markers(end + 1) = struct('name', 'PHR start', ...
            'sample', packet_table_row.abs_phr_start_sample - read_first + 1); %#ok<SAGROW>
    end
    if isfield(packet_table_row, 'abs_payload_start_sample') && ...
            ~isempty(packet_table_row.abs_payload_start_sample)
        field_markers(end + 1) = struct('name', 'Payload start', ...
            'sample', packet_table_row.abs_payload_start_sample - read_first + 1); %#ok<SAGROW>
    end
end

%% 1. Figure 1: envelope comparison across the read window
figure('Name', sprintf('DW1000 cancellation: packet %d (#%d)', ...
    report.index, packet_index), 'Color', 'w', ...
    'Position', [60 50 1200 820]);

% Constant noise-floor level (RMS) for reference horizontal lines.
noise_floor_level = [];
if ~isempty(env_noise)
    noise_floor_level = mean(env_noise);
end

subplot(3, 1, 1);
plot(t_ms, env_original, 'Color', [0.10 0.45 0.85], 'LineWidth', 1.1);
hold on;
if ~isempty(noise_floor_level)
    yline(noise_floor_level, '--', 'Color', [0.55 0.55 0.55], ...
        'LineWidth', 1.0, 'Label', 'Noise floor', ...
        'LabelHorizontalAlignment', 'left');
end
for m = 1:numel(field_markers)
    xline(t_ms(field_markers(m).sample), '--', field_markers(m).name, ...
        'LabelOrientation', 'horizontal', 'FontSize', 8, ...
        'Color', [0.4 0.4 0.4]);
end
grid on;
ylabel('RMS amplitude');
title(sprintf('Original capture  |  packet at %.3f ms', ...
    packet_first / fs_rx * 1e3));
set(gca, 'XLim', t_ms([1 end]));

subplot(3, 1, 2);
plot(t_ms, env_cancelled, 'Color', [0.85 0.30 0.12], 'LineWidth', 1.1);
hold on;
if ~isempty(noise_floor_level)
    yline(noise_floor_level, '--', 'Color', [0.55 0.55 0.55], ...
        'LineWidth', 1.0, 'Label', 'Noise floor', ...
        'LabelHorizontalAlignment', 'left');
end
for m = 1:numel(field_markers)
    xline(t_ms(field_markers(m).sample), '--', ...
        'LabelOrientation', 'horizontal', 'FontSize', 8, ...
        'Color', [0.4 0.4 0.4]);
end
grid on;
ylabel('RMS amplitude');
title('Cancelled capture');
set(gca, 'XLim', t_ms([1 end]));

subplot(3, 1, 3);
plot(t_ms, env_removed, 'Color', [0.20 0.65 0.45], 'LineWidth', 1.1);
hold on;
if ~isempty(noise_floor_level)
    yline(noise_floor_level, '--', 'Color', [0.55 0.55 0.55], ...
        'LineWidth', 1.0, 'Label', 'Noise floor', ...
        'LabelHorizontalAlignment', 'left');
end
for m = 1:numel(field_markers)
    xline(t_ms(field_markers(m).sample), '--', ...
        'LabelOrientation', 'horizontal', 'FontSize', 8, ...
        'Color', [0.4 0.4 0.4]);
end
grid on;
xlabel('Time (ms)');
ylabel('RMS amplitude');
title('Removed signal (original - cancelled)');
set(gca, 'XLim', t_ms([1 end]));

sgtitle(sprintf(['DW1000 packet %d (#%d) | suppression %.2f dB | ', ...
    'CFO %+.3f kHz | corr %.3f'], report.index, packet_index, ...
    report.frame_suppression_db, report.fitted_cfo_hz / 1e3, ...
    report.alignment_correlation), 'Interpreter', 'none');

%% 2. Figure 2: packet-region detail + spectrum
% Extract the packet region (with a small pad) for a zoomed view.
detail_pad = min(512, window_pad_samples);
detail_first = max(1, local_packet_first - detail_pad);
detail_last = min(read_num, local_packet_last + detail_pad);
detail_t_us = (detail_first:detail_last).' / fs_rx * 1e6;

% Suppression computed only inside the subtracted region.
region_original = rx_original(local_packet_first:local_packet_last);
region_cancelled = rx_cancelled(local_packet_first:local_packet_last);
region_suppression_db = 10 * log10( ...
    mean(abs(region_original).^2) / ...
    (mean(abs(region_cancelled).^2) + eps));

figure('Name', sprintf('DW1000 packet %d (#%d) detail', ...
    report.index, packet_index), 'Color', 'w', ...
    'Position', [80 60 1200 800]);

subplot(2, 2, 1);
plot(detail_t_us, env_original(detail_first:detail_last), ...
    'Color', [0.10 0.45 0.85], 'LineWidth', 1.1);
hold on;
plot(detail_t_us, env_cancelled(detail_first:detail_last), ...
    'Color', [0.85 0.30 0.12], 'LineWidth', 1.1);
if ~isempty(noise_floor_level)
    yline(noise_floor_level, '--', 'Color', [0.55 0.55 0.55], ...
        'LineWidth', 1.0, 'Label', 'Noise floor', ...
        'LabelHorizontalAlignment', 'left');
end
grid on;
xlabel('Time (us)');
ylabel('RMS amplitude');
title('Envelope: original vs cancelled');
legend('Original', 'Cancelled', 'Location', 'best');

subplot(2, 2, 2);
plot(detail_t_us, env_removed(detail_first:detail_last), ...
    'Color', [0.20 0.65 0.45], 'LineWidth', 1.1);
hold on;
if ~isempty(noise_floor_level)
    yline(noise_floor_level, '--', 'Color', [0.55 0.55 0.55], ...
        'LineWidth', 1.0, 'Label', 'Noise floor', ...
        'LabelHorizontalAlignment', 'left');
end
grid on;
xlabel('Time (us)');
ylabel('RMS amplitude');
title('Removed signal envelope');

% Spectrum of the packet region before/after cancellation, plus a noise-only
% reference of the same length (no UWB signal) to show the noise floor.
nfft = 2^floor(log2(packet_samples));
win = hann(nfft);
spec_original = fftshift(fft(region_original(1:nfft) .* win));
spec_cancelled = fftshift(fft(region_cancelled(1:nfft) .* win));
f_axis = (-nfft / 2:nfft / 2 - 1).' * fs_rx / nfft / 1e6;
mag_original = 20 * log10(abs(spec_original) + eps);
mag_cancelled = 20 * log10(abs(spec_cancelled) + eps);
spec_floor = max(mag_original);

% Read the noise-only reference segment. Default to the guard interval right
% before the packet (packet_samples long). Fall back gracefully if the file
% is shorter than requested.
spec_noise = [];
if isempty(noise_ref_region)
    noise_ref_offset = max(0, packet_first - packet_samples);
    noise_ref_num = packet_samples;
else
    noise_ref_offset = noise_ref_region(1);
    noise_ref_num = noise_ref_region(2);
end
noise_ref_offset = min(noise_ref_offset, total_samples - 1);
noise_ref_num = min(noise_ref_num, total_samples - noise_ref_offset);
if noise_ref_num >= nfft
    raw_noise = uwbdecoder.readIqRaw(input_file, ...
        noise_ref_offset, noise_ref_num, ant_num);
    rx_noise = uwbdecoder.selectIqChannel(raw_noise, channel_index);
    spec_noise = fftshift(fft(rx_noise(1:nfft) .* win));
    mag_noise = 20 * log10(abs(spec_noise) + eps);
end

subplot(2, 2, 3);
plot(f_axis, mag_original - spec_floor, ...
    'Color', [0.10 0.45 0.85], 'LineWidth', 1.1);
hold on;
plot(f_axis, mag_cancelled - spec_floor, ...
    'Color', [0.85 0.30 0.12], 'LineWidth', 1.1);
if ~isempty(spec_noise)
    plot(f_axis, mag_noise - spec_floor, '--', ...
        'Color', [0.55 0.55 0.55], 'LineWidth', 1.0);
end
grid on;
xlabel('Baseband frequency (MHz)');
ylabel('Magnitude (dB)');
if ~isempty(spec_noise)
    legend('Original', 'Cancelled', 'Noise-only ref', ...
        'Location', 'best');
else
    legend('Original', 'Cancelled', 'Location', 'best');
end
title(sprintf('Packet-region spectrum | noise ref @%d', ...
    noise_ref_offset));
ylim([-70 5]);

% Text summary panel.
subplot(2, 2, 4);
axis off;
summary_text = {
    sprintf('Packet index   : %d (#%d in list)', ...
        report.index, packet_index);
    sprintf('Fitted start   : %d (%.3f ms)', ...
        packet_first, packet_first / fs_rx * 1e3);
    sprintf('Samples        : %d', packet_samples);
    '';
    sprintf('Align corr     : %.4f', report.alignment_correlation);
    sprintf('Fitted CFO     : %+.3f kHz', report.fitted_cfo_hz / 1e3);
    sprintf('Global gain    : %.2f dB / %.1f deg', ...
        20 * log10(abs(report.global_gain) + eps), ...
        rad2deg(angle(report.global_gain)));
    sprintf('PHR gain       : %.3f / %.1f deg', ...
        abs(report.phr_gain), rad2deg(angle(report.phr_gain)));
    sprintf('Payload gain   : %.3f / %.1f deg', ...
        abs(report.payload_gain), rad2deg(angle(report.payload_gain)));
    '';
    sprintf('Reported supp  : %.2f dB', report.frame_suppression_db);
    sprintf('Window meas.   : %.2f dB', region_suppression_db);
    sprintf('Clipped comp.  : %d', report.clipped_component_count);
    sprintf('FCS pass       : %d', report.fcs_pass);
    };
text(0.05, 0.95, summary_text, 'Interpreter', 'none', ...
    'VerticalAlignment', 'top', 'FontName', 'Consolas', 'FontSize', 10);
title('Cancellation metrics');

sgtitle(sprintf('DW1000 packet %d (#%d) detail', ...
    report.index, packet_index), 'Interpreter', 'none');

%% 3. Figure 3: original / reconstructed / cancelled overlay
% Overlay the sliding-RMS envelopes of all three complex signals on one
% time-domain axis. A stride keeps the plotted point count manageable at the
% ~737 MHz sample rate. Figure 4/5 retain the phase and I-Q diagnostics.
max_plot_points = 4000;
detail_len = detail_last - detail_first + 1;
plot_stride = max(1, ceil(detail_len / max_plot_points));
plot_idx = detail_first:plot_stride:detail_last;
plot_abs_samples = read_first + plot_idx - 1;
plot_t_us = (plot_abs_samples - packet_first) / fs_rx * 1e6;

figure('Name', sprintf('DW1000 packet %d (#%d) envelope overlay', ...
    report.index, packet_index), 'Color', 'w', ...
    'Position', [100 120 1200 520]);

plot(plot_t_us, env_original(plot_idx), ...
    'Color', [0.10 0.45 0.85], 'LineWidth', 0.9);
hold on;
plot(plot_t_us, env_removed(plot_idx), ...
    'Color', [0.20 0.65 0.45], 'LineWidth', 0.9);
plot(plot_t_us, env_cancelled(plot_idx), ...
    'Color', [0.85 0.30 0.12], 'LineWidth', 0.9);
grid on;
xlabel('Time from fitted packet start (us)');
ylabel('Sliding-RMS envelope (ADC)');
title('Envelope overlay: original / reconstructed / cancellation result');
legend('Original', 'Reconstructed', 'After cancellation', ...
    'Location', 'best');
xlim(plot_t_us([1 end]));

sgtitle(sprintf('DW1000 packet %d (#%d) | stride %d | Fs %.3f MHz', ...
    report.index, packet_index, plot_stride, fs_rx / 1e6), ...
    'Interpreter', 'none');

%% 4. Figure 4: strong peak phase difference (zero-IF, CFO-removed)
% Reproduce the strong-sample phase-error diagnostic from
% run_analyze_uwb_cancellation_steps.m. The regenerated waveform contains
% the intentional digital offset between the X410 tuning frequency and the
% DW1000 center frequency. Remove that offset AND the fitted CFO from both
% signals before plotting. Keep only strong samples where both amplitudes
% exceed a threshold, then compare their phases. Radial/tangential
% decomposition separates amplitude and phase contributions to the residual.
% Use time relative to the fitted packet start. The reference only fixes a
% constant display phase, while the time slope removes both rotations.
detail_abs_samples = read_first + (detail_first:detail_last).' - 1;
detail_time_from_packet_start = ...
    (detail_abs_samples - packet_first) / fs_rx;
nominal_digital_offset_hz = params.dw1000_center_frequency - ...
    params.x410_center_frequency;
display_rotation_hz = nominal_digital_offset_hz + ...
    report.fitted_cfo_hz;
zero_if_derotation = exp(-1j * 2 * pi * display_rotation_hz * ...
    detail_time_from_packet_start);
received_no_cfo = rx_original(detail_first:detail_last) .* ...
    zero_if_derotation;
model_no_cfo = rx_removed(detail_first:detail_last) .* ...
    zero_if_derotation;
residual_no_cfo = received_no_cfo - model_no_cfo;

strong_threshold = 0.20 * max(abs(model_no_cfo));
strong_idx = find(abs(model_no_cfo) > strong_threshold & ...
    abs(received_no_cfo) > strong_threshold);
strong_t_us = (strong_idx - 1) / fs_rx * 1e6;

if isempty(strong_idx)
    fprintf('No strong samples found above threshold %.2f ADC.\n', ...
        strong_threshold);
else
    phase_received_deg = rad2deg(angle(received_no_cfo(strong_idx)));
    phase_model_deg = rad2deg(angle(model_no_cfo(strong_idx)));
    phase_error_deg = rad2deg(angle( ...
        received_no_cfo(strong_idx) .* conj(model_no_cfo(strong_idx))));

    relative_amplitude_error_db = 20 * log10( ...
        (abs(received_no_cfo(strong_idx)) + eps) ./ ...
        (abs(model_no_cfo(strong_idx)) + eps));

    % Rotate residual into the model's local coordinates: real = radial
    % (amplitude), imaginary = tangential (phase).
    model_unit = model_no_cfo(strong_idx) ./ ...
        (abs(model_no_cfo(strong_idx)) + eps);
    local_residual = residual_no_cfo(strong_idx) .* conj(model_unit);
    radial_residual = real(local_residual);
    tangential_residual = imag(local_residual);
    radial_power = mean(radial_residual .^ 2);
    tangential_power = mean(tangential_residual .^ 2);
    tangential_to_radial_db = 10 * log10( ...
        tangential_power / (radial_power + eps));
    amplitude_error_rms_db = rms(relative_amplitude_error_db);
    phase_error_rms_deg = rms(phase_error_deg);

    figure('Name', sprintf( ...
        'DW1000 packet %d (#%d) strong peak phase', ...
        report.index, packet_index), 'Color', 'w', ...
        'Position', [120 80 1200 820]);

    subplot(3, 1, 1);
    plot(strong_t_us, phase_received_deg, '.', ...
        'Color', [0.10 0.45 0.85], 'MarkerSize', 5);
    hold on;
    plot(strong_t_us, phase_model_deg, '.', ...
        'Color', [0.85 0.30 0.12], 'MarkerSize', 5);
    grid on;
    xlabel('Time (us)');
    ylabel('Phase (deg)');
    title(sprintf( ...
        'Zero-IF phase | offset %+.3f MHz, CFO %+.3f kHz | %d peaks', ...
        nominal_digital_offset_hz / 1e6, ...
        report.fitted_cfo_hz / 1e3, numel(strong_idx)));
    legend('Received phase', 'Model phase', 'Location', 'best');
    xlim(strong_t_us([1 end]));

    subplot(3, 1, 2);
    plot(strong_t_us, phase_error_deg, '.', ...
        'Color', [0.55 0.20 0.75], 'MarkerSize', 5);
    hold on;
    yline(0, 'k--');
    grid on;
    xlabel('Time (us)');
    ylabel('Phase error (deg)');
    title(sprintf('Strong peak phase error | RMS %.2f deg', ...
        phase_error_rms_deg));
    xlim(strong_t_us([1 end]));

    subplot(3, 1, 3);
    yyaxis left;
    plot(strong_t_us, radial_residual, '.', ...
        'Color', [0.20 0.65 0.45], 'MarkerSize', 5);
    ylabel('Radial residual (ADC)');
    yyaxis right;
    plot(strong_t_us, tangential_residual, '.', ...
        'Color', [0.85 0.55 0.10], 'MarkerSize', 5);
    ylabel('Tangential residual (ADC)');
    grid on;
    xlabel('Time (us)');
    title(sprintf(['Radial (ampl) vs Tangential (phase) residual | ', ...
        'P_tan/P_rad %+.2f dB'], tangential_to_radial_db));
    legend('Radial', 'Tangential', 'Location', 'best');
    xlim(strong_t_us([1 end]));

    sgtitle(sprintf(['DW1000 packet %d (#%d) strong peak | ', ...
        'ampl RMS %.2f dB | phase RMS %.2f deg'], ...
        report.index, packet_index, amplitude_error_rms_db, ...
        phase_error_rms_deg), 'Interpreter', 'none');

    fprintf('\n=== Strong peak phase analysis (CFO-removed) ===\n');
    fprintf('Strong peaks       : %d\n', numel(strong_idx));
    fprintf('Amplitude error RMS: %.3f dB\n', amplitude_error_rms_db);
    fprintf('Phase error RMS    : %.3f deg\n', phase_error_rms_deg);
    fprintf('Tangential/radial  : %+.3f dB\n', tangential_to_radial_db);
end

%% 5. Figure 5: zero-IF original and reconstructed signal in I-Q plane
% First overlay the two signals after removing both the nominal digital
% offset and fitted CFO. Then rotate BOTH signals sample-by-sample into the
% reconstructed signal's local frame. The reconstructed samples consequently
% lie on the positive real axis; horizontal mismatch is radial (amplitude)
% error and vertical mismatch is tangential (phase) error.
if ~isempty(strong_idx)
    % Subsample for plotting if there are many strong peaks.
    max_scatter_points = 5000;
    if numel(strong_idx) > max_scatter_points
        scatter_idx = strong_idx(1:ceil(numel(strong_idx) / ...
            max_scatter_points):end);
    else
        scatter_idx = strong_idx;
    end

    orig_scatter = received_no_cfo(scatter_idx);
    model_scatter = model_no_cfo(scatter_idx);

    % Rotate both signals into the model's local frame. The model becomes a
    % real, nonnegative reference and the received sample retains its radial
    % and tangential mismatch relative to that reference.
    model_unit_scatter = model_scatter ./ (abs(model_scatter) + eps);
    orig_local = orig_scatter .* conj(model_unit_scatter);
    model_local = model_scatter .* conj(model_unit_scatter);
    local_resid = orig_local - model_local;
    radial_resid = real(local_resid);
    tangential_resid = imag(local_resid);

    amplitude_error_db_scatter = 20 * log10( ...
        (abs(orig_scatter) + eps) ./ (abs(model_scatter) + eps));
    phase_error_deg_scatter = rad2deg(angle( ...
        orig_scatter .* conj(model_scatter)));
    radial_resid_p95 = prctile(abs(radial_resid), 95);
    tangential_resid_p95 = prctile(abs(tangential_resid), 95);
    iq_limit = 1.05 * max(abs([orig_scatter; model_scatter]));
    if iq_limit == 0
        iq_limit = 1;
    end

    %plot(real(orig_scatter), imag(orig_scatter), '.', ...
        % 'Color', [0.10 0.45 0.85], 'MarkerSize', 4);
    plot(abs(orig_scatter), ...
        'Color', [0.10 0.45 0.85], 'MarkerSize', 4);
    hold on;
    %plot(real(model_scatter), imag(model_scatter), '.', ...
        % 'Color', [0.85 0.30 0.12], 'MarkerSize', 4);
    plot(abs(model_scatter), ...
        'Color', [0.85 0.30 0.12], 'MarkerSize', 4);
    grid on; %axis equal;
    %xlim([-iq_limit iq_limit]);
    %ylim([-iq_limit iq_limit]);
    xlabel('In-phase (ADC)');
    ylabel('Quadrature (ADC)');
    legend('Original', 'Reconstructed', 'Location', 'best');
    title(sprintf('Zero-IF I-Q overlay | %d paired samples', ...
        numel(scatter_idx)));
end

%% 6. Console summary
fprintf('\n=== Packet %d (#%d) summary ===\n', report.index, packet_index);
fprintf('Fitted start     : %d (%.3f ms)\n', ...
    packet_first, packet_first / fs_rx * 1e3);
fprintf('Samples          : %d\n', packet_samples);
fprintf('Align corr       : %.4f\n', report.alignment_correlation);
if isfield(report, 'integer_alignment_correlation')
    fprintf('Integer align    : %.4f\n', ...
        report.integer_alignment_correlation);
end
if isfield(report, 'fractional_delay_samples')
    fprintf('Fractional delay : %+.4f samples\n', ...
        report.fractional_delay_samples);
end
fprintf('Fitted CFO       : %+.3f kHz\n', report.fitted_cfo_hz / 1e3);
fprintf('Global gain      : %.2f dB / %.1f deg\n', ...
    20 * log10(abs(report.global_gain) + eps), ...
    rad2deg(angle(report.global_gain)));
fprintf('PHR gain         : %.3f / %.1f deg\n', ...
    abs(report.phr_gain), rad2deg(angle(report.phr_gain)));
fprintf('Payload gain     : %.3f / %.1f deg\n', ...
    abs(report.payload_gain), rad2deg(angle(report.payload_gain)));
fprintf('Reported supp.   : %.2f dB\n', report.frame_suppression_db);
fprintf('Window measured  : %.2f dB\n', region_suppression_db);
fprintf('Clipped comp.    : %d\n', report.clipped_component_count);
fprintf('FCS pass         : %d\n', report.fcs_pass);

%% 7. Save figures to disk
if save_figures && ~isempty(output_dir)
    if ~isfolder(output_dir)
        mkdir(output_dir);
    end
    fig_files = cell(0, 1);
    fig_handles = findall(0, 'Type', 'figure');
    fig_handles = sort(fig_handles);
    for f = 1:numel(fig_handles)
        fig_name = sprintf('packet_%04d_fig_%d.png', report.index, f);
        fig_path = fullfile(output_dir, fig_name);
        try
            exportgraphics(fig_handles(f), fig_path, ...
                'Resolution', figure_resolution_dpi);
            fig_files{end + 1} = fig_path; %#ok<SAGROW>
        catch ME
            fprintf('  (figure %d not saved: %s)\n', f, ME.message);
        end
    end
    if ~isempty(fig_files)
        fprintf('\nSaved %d figure(s) to:\n  %s\n', ...
            numel(fig_files), output_dir);
        for f = 1:numel(fig_files)
            fprintf('  %s\n', fig_files{f});
        end
    end
end
