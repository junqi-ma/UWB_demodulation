%% Compare raw vs cancelled capture over a selectable window (full impl).
% Reads a window from the original capture and the fully compensated
% cancellation output (PLL template + CIR slow phase + SFO), then produces:
%   Figure 1: per-packet suppression preview (Gantt + suppression bars)
%   Figure 2: time-domain envelope before/after + removed signal
%   Figure 3: spectrum comparison (full band + cancellation depth)
%   Figure 4: per-packet suppression breakdown (PLL / CIR slow / SFO gains)
%   Figure 5: phase error diagnostic for the strongest packet in window
%
% Requires run_cancel_all_uwb_packets output with full compensation:
%   decoded_results/<capture_stem>/cancelled_<mode>_pll_subsync_cirslow.dat
clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

c = uwbdecoder.constants();

%% 0. User configuration
% Source capture and cancellation mode.
input_file = 'F:\UWB基带数据\qm35_new_3.dat';
cancellation_mode = 'optimal_complex';

% Full compensation toggles. Set all true for the complete implementation.
use_pll_phase_compensation = true;
use_cir_slow_phase_compensation = true;
use_sfo_compensation = true;

% Window to display (zero-based complex-sample index + length).
window_offset = 4272165;
window_duration_ms = 5;   % ms

% Save figures to disk when true.
save_figures = false;
output_dir = fullfile(project_dir, 'decoded_results', ...
    'qm35_new_3', 'visualize_10ms_full');
figure_resolution_dpi = 120;

% -------------------------------------------------------------------------
% Auto-generated paths.
% -------------------------------------------------------------------------
[~, capture_stem] = fileparts(input_file);
cancelled_tag = sprintf('cancelled_%s', cancellation_mode);
if use_pll_phase_compensation
    cancelled_tag = [cancelled_tag '_pll_subsync'];
end
if use_cir_slow_phase_compensation
    cancelled_tag = [cancelled_tag '_cirslow'];
end
output_file = fullfile(project_dir, 'decoded_results', capture_stem, ...
    [cancelled_tag '.dat']);
metadata_file = fullfile(project_dir, 'decoded_results', capture_stem, ...
    [cancelled_tag '_metadata.mat']);
summary_file = fullfile(project_dir, 'decoded_results', capture_stem, ...
    [cancelled_tag '_summary.csv']);

%% 1. Load metadata and summary
if ~isfile(metadata_file)
    error('visualize_uwb_cancellation_10ms:MetadataNotFound', ...
        'Metadata file not found: %s', metadata_file);
end
meta = load(metadata_file);
params = meta.params;
fs_rx = params.fs_rx;
ant_num = params.ant_num;
channel_index = params.channel_index;
bytes_per_sample = c.BYTES_PER_IQ_SAMPLE * ant_num;

% Load per-packet suppression summary.
if isfile(summary_file)
    summary_table = readtable(summary_file);
else
    summary_table = table([]);
end

capture_info = dir(input_file);
total_samples = floor(capture_info.bytes / bytes_per_sample);

% Window length.
window_num = round(window_duration_ms * 1e-3 * fs_rx);
window_offset = min(window_offset, total_samples - 1);
window_num = min(window_num, total_samples - window_offset);

fprintf('=== Full-implementation %d ms cancellation view ===\n', ...
    window_duration_ms);
fprintf('Cancellation file: %s\n', output_file);
fprintf('Window offset     : %d (%.3f ms)\n', ...
    window_offset, window_offset / fs_rx * 1e3);
fprintf('Window length     : %d samples (%.3f ms)\n', ...
    window_num, window_num / fs_rx * 1e3);

%% 2. Read the window from both captures.
raw_original = uwbdecoder.readIqRaw(input_file, ...
    window_offset, window_num, ant_num);
rx_original = uwbdecoder.selectIqChannel(raw_original, channel_index);
raw_cancelled = uwbdecoder.readIqRaw(output_file, ...
    window_offset, window_num, ant_num);
rx_cancelled = uwbdecoder.selectIqChannel(raw_cancelled, channel_index);
clear raw_original raw_cancelled;

% Remove the clock-synchronous single tone.
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

% Sliding-RMS envelope.
envelope_samples = max(1, round(0.25e-6 * fs_rx));
env_original = sqrt(movmean(abs(rx_original).^2, envelope_samples));
env_cancelled = sqrt(movmean(abs(rx_cancelled).^2, envelope_samples));
env_removed = sqrt(movmean(abs(rx_removed).^2, envelope_samples));

% Time axis.
t_ms = (window_offset + (0:window_num - 1).') / fs_rx * 1e3;

% Suppression over the whole window.
original_power = mean(abs(rx_original).^2);
cancelled_power = mean(abs(rx_cancelled).^2);
suppression_db = 10 * log10(original_power / (cancelled_power + eps));
fprintf('Window suppression: %.3f dB\n', suppression_db);

%% 3. Find packets inside the window.
window_first = window_offset;
window_last = window_offset + window_num - 1;
packet_in_window = [];
if ~isempty(summary_table) && ismember('abs_start_sample', ...
        summary_table.Properties.VariableNames)
    starts = summary_table.abs_start_sample;
    ends = starts + summary_table.samples_subtracted - 1;
    in_window = (ends >= window_first) & (starts <= window_last);
    packet_in_window = find(in_window);
    fprintf('Packets in window: %d / %d total\n', ...
        numel(packet_in_window), height(summary_table));
end

%% 4. Figure 1: per-packet suppression preview.
if ~isempty(summary_table) && ismember('frame_suppression_db', ...
        summary_table.Properties.VariableNames)
    fig1 = figure('Name', sprintf( ...
        '%s full-impl: suppression preview', capture_stem), ...
        'Color', 'w', 'Position', [80 80 1400 500]);

    packet_list_index = (1:height(summary_table)).';
    success_mask = summary_table.success == 1;
    suppression_db_all = summary_table.frame_suppression_db;

    has_pll = ismember('frame_suppression_without_pll_db', ...
        summary_table.Properties.VariableNames);
    has_cir_slow = ismember('frame_suppression_without_cir_slow_db', ...
        summary_table.Properties.VariableNames);
    has_sfo = ismember('frame_suppression_without_sfo_db', ...
        summary_table.Properties.VariableNames);

    hold on;
    if has_pll
        plot(packet_list_index(success_mask), ...
            summary_table.frame_suppression_without_pll_db(success_mask), ...
            '-', 'Color', [0.60 0.60 0.60], 'LineWidth', 0.8);
    end
    if has_cir_slow
        plot(packet_list_index(success_mask), ...
            summary_table.frame_suppression_without_cir_slow_db(success_mask), ...
            '-', 'Color', [0.20 0.65 0.30], 'LineWidth', 0.8);
    end
    if has_sfo
        plot(packet_list_index(success_mask), ...
            summary_table.frame_suppression_without_sfo_db(success_mask), ...
            '-', 'Color', [0.90 0.55 0.15], 'LineWidth', 0.8);
    end
    plot(packet_list_index(success_mask), ...
        suppression_db_all(success_mask), 'o-', ...
        'Color', [0.10 0.45 0.85], 'MarkerSize', 3, ...
        'MarkerFaceColor', [0.10 0.45 0.85], 'LineWidth', 0.7);
    if any(~success_mask)
        plot(packet_list_index(~success_mask), ...
            zeros(nnz(~success_mask), 1), 'x', ...
            'Color', [0.85 0.30 0.12], 'MarkerSize', 5);
    end

    % Highlight packets in the current window.
    if ~isempty(packet_in_window)
        for k = 1:numel(packet_in_window)
            idx = packet_in_window(k);
            if summary_table.success(idx)
                plot(idx, suppression_db_all(idx), 'o', ...
                    'MarkerSize', 8, 'MarkerEdgeColor', [0.10 0.70 0.90], ...
                    'MarkerFaceColor', 'none', 'LineWidth', 1.5);
            end
        end
    end

    grid on;
    xlabel('Packet list index');
    ylabel('Frame suppression (dB)');
    title(sprintf( ...
        'Full-implementation suppression: %d packets (%d successful)', ...
        height(summary_table), nnz(success_mask)));
    legend_entries = {};
    if has_pll
        legend_entries{end + 1} = 'No PLL'; %#ok<SAGROW>
    end
    if has_cir_slow
        legend_entries{end + 1} = 'PLL only'; %#ok<SAGROW>
    end
    if has_sfo
        legend_entries{end + 1} = 'No SFO'; %#ok<SAGROW>
    end
    legend_entries{end + 1} = 'Full compensation';
    if any(~success_mask)
        legend_entries{end + 1} = 'Skipped';
    end
    legend(legend_entries, 'Location', 'best');

    drawnow;
end

%% 5. Figure 2: time-domain envelope comparison (overlay).
fig2 = figure('Name', sprintf( ...
    '%s full-impl: %d ms envelope @ %.3f ms', ...
    capture_stem, window_duration_ms, window_offset / fs_rx * 1e3), ...
    'Color', 'w', 'Position', [60 50 1400 700]);

% Common packet markers.
field_xlines = [];
field_names = {};
if ~isempty(packet_in_window)
    for k = 1:numel(packet_in_window)
        idx = packet_in_window(k);
        pkt_start_ms = summary_table.abs_start_sample(idx) / fs_rx * 1e3;
        pkt_end_ms = (summary_table.abs_start_sample(idx) + ...
            summary_table.samples_subtracted(idx) - 1) / fs_rx * 1e3;
        field_xlines(end + 1) = pkt_start_ms; %#ok<SAGROW>
        field_names{end + 1} = sprintf('Pkt %d start', ...
            summary_table.index(idx)); %#ok<SAGROW>
        field_xlines(end + 1) = pkt_end_ms; %#ok<SAGROW>
        field_names{end + 1} = sprintf('Pkt %d end', ...
            summary_table.index(idx)); %#ok<SAGROW>
    end
end

% --- Top: original vs cancelled overlaid on the same axes ---
subplot(2, 1, 1);
plot(t_ms, env_original, 'Color', [0.10 0.45 0.85], 'LineWidth', 1.0);
hold on;
plot(t_ms, env_cancelled, 'Color', [0.85 0.30 0.12], 'LineWidth', 1.0);
for m = 1:numel(field_xlines)
    xline(field_xlines(m), '--', field_names{m}, ...
        'LabelOrientation', 'horizontal', 'FontSize', 7, ...
        'Color', [0.4 0.4 0.4]);
end
grid on;
xlabel('Time (ms)');
ylabel('RMS amplitude');
title(sprintf('Original vs Cancelled (overlay) | window suppression %.2f dB', ...
    suppression_db));
legend('Original', 'Cancelled', 'Location', 'best');
set(gca, 'XLim', t_ms([1 end]));

% --- Bottom: removed signal ---
subplot(2, 1, 2);
plot(t_ms, env_removed, 'Color', [0.20 0.65 0.45], 'LineWidth', 0.8);
hold on;
for m = 1:numel(field_xlines)
    xline(field_xlines(m), '--', 'LabelOrientation', 'horizontal', ...
        'FontSize', 7, 'Color', [0.4 0.4 0.4]);
end
grid on;
xlabel('Time (ms)');
ylabel('RMS amplitude');
title('Removed signal (original - cancelled)');
set(gca, 'XLim', t_ms([1 end]));

sgtitle(sprintf(['%s full-implementation cancellation | offset %d (%.3f ms) | ', ...
    '%d ms window | tone removed: %s'], capture_stem, window_offset, ...
    window_offset / fs_rx * 1e3, window_duration_ms, string(tone_removed)), ...
    'Interpreter', 'none');
drawnow;

%% 6. Figure 3: power spectrum comparison.
spectrum_window = 1:min(window_num, 2^18);
nfft = numel(spectrum_window);
win = 0.5 - 0.5 * cos(2*pi*(0:nfft-1).' / (nfft-1));
spec_original = fftshift(fft(rx_original(spectrum_window) .* win));
spec_cancelled = fftshift(fft(rx_cancelled(spectrum_window) .* win));
f_axis = (-nfft / 2:nfft / 2 - 1).' * fs_rx / nfft / 1e6;
mag_original = 10 * log10(abs(spec_original).^2 + eps);
mag_cancelled = 10 * log10(abs(spec_cancelled).^2 + eps);
spec_floor = max(mag_original);

fig3 = figure('Name', sprintf( ...
    '%s full-impl: spectrum @ %.3f ms', capture_stem, ...
    window_offset / fs_rx * 1e3), 'Color', 'w', ...
    'Position', [70 60 1400 500]);

subplot(1, 2, 1);
plot(f_axis, mag_original - spec_floor, ...
    'Color', [0.10 0.45 0.85], 'LineWidth', 0.8);
hold on;
plot(f_axis, mag_cancelled - spec_floor, ...
    'Color', [0.85 0.30 0.12], 'LineWidth', 0.8);
grid on;
xlabel('Baseband frequency (MHz)');
ylabel('Power spectral density (dB)');
legend('Original', 'Cancelled', 'Location', 'best');
title(sprintf('Spectrum | NFFT %d', nfft));
ylim([-70 5]);

subplot(1, 2, 2);
plot(f_axis, mag_original - mag_cancelled, ...
    'Color', [0.20 0.65 0.45], 'LineWidth', 0.8);
grid on;
xlabel('Baseband frequency (MHz)');
ylabel('Suppression (dB)');
title('Cancellation depth (original - cancelled)');

sgtitle(sprintf('%s full-implementation spectrum | %d ms window', ...
    capture_stem, window_duration_ms), 'Interpreter', 'none');
drawnow;

%% 7. Figure 4: per-packet suppression breakdown for packets in window.
if ~isempty(packet_in_window) && ismember('frame_suppression_db', ...
        summary_table.Properties.VariableNames)
    fig4 = figure('Name', sprintf( ...
        '%s full-impl: per-packet breakdown', capture_stem), ...
        'Color', 'w', 'Position', [80 80 1200 500]);

    n_pkts = numel(packet_in_window);
    pkt_labels = cell(n_pkts, 1);
    pkt_full = zeros(n_pkts, 1);
    pkt_no_pll = zeros(n_pkts, 1);
    pkt_no_cir_slow = zeros(n_pkts, 1);
    pkt_no_sfo = zeros(n_pkts, 1);
    has_pll_col = ismember('frame_suppression_without_pll_db', ...
        summary_table.Properties.VariableNames);
    has_cir_slow_col = ismember('frame_suppression_without_cir_slow_db', ...
        summary_table.Properties.VariableNames);
    has_sfo_col = ismember('frame_suppression_without_sfo_db', ...
        summary_table.Properties.VariableNames);

    for k = 1:n_pkts
        idx = packet_in_window(k);
        pkt_labels{k} = sprintf('#%d', summary_table.index(idx));
        if summary_table.success(idx)
            pkt_full(k) = summary_table.frame_suppression_db(idx);
            if has_pll_col
                pkt_no_pll(k) = ...
                    summary_table.frame_suppression_without_pll_db(idx);
            end
            if has_cir_slow_col
                pkt_no_cir_slow(k) = ...
                    summary_table.frame_suppression_without_cir_slow_db(idx);
            end
            if has_sfo_col
                pkt_no_sfo(k) = ...
                    summary_table.frame_suppression_without_sfo_db(idx);
            end
        else
            pkt_full(k) = NaN;
            pkt_no_pll(k) = NaN;
            pkt_no_cir_slow(k) = NaN;
            pkt_no_sfo(k) = NaN;
        end
    end

    x_idx = 1:n_pkts;
    hold on;
    bar_width = 0.2;
    if has_pll_col
        bar(x_idx - 1.5*bar_width, pkt_no_pll, bar_width, ...
            'FaceColor', [0.60 0.60 0.60], 'DisplayName', 'No PLL');
    end
    if has_cir_slow_col
        bar(x_idx - 0.5*bar_width, pkt_no_cir_slow, bar_width, ...
            'FaceColor', [0.20 0.65 0.30], 'DisplayName', 'PLL only');
    end
    if has_sfo_col
        bar(x_idx + 0.5*bar_width, pkt_no_sfo, bar_width, ...
            'FaceColor', [0.90 0.55 0.15], 'DisplayName', 'No SFO');
    end
    bar(x_idx + 1.5*bar_width, pkt_full, bar_width, ...
        'FaceColor', [0.10 0.45 0.85], 'DisplayName', 'Full');

    grid on;
    set(gca, 'XTick', x_idx, 'XTickLabel', pkt_labels);
    xlabel('Packet index');
    ylabel('Suppression (dB)');
    title(sprintf( ...
        'Per-packet suppression breakdown (%d packets in window)', n_pkts));
    legend('Location', 'best');

    sgtitle(sprintf('%s full-implementation: PLL + CIR slow + SFO gains', ...
        capture_stem), 'Interpreter', 'none');
    drawnow;
end

%% 8. Figure 5: phase error for the strongest packet in window.
if ~isempty(packet_in_window) && isfield(meta, 'reports')
    % Pick the packet with the largest envelope in the window.
    best_pkt = [];
    best_env = 0;
    for k = 1:numel(packet_in_window)
        idx = packet_in_window(k);
        pkt_center = summary_table.abs_start_sample(idx) + ...
            round(summary_table.samples_subtracted(idx) / 2);
        [~, center_local] = min(abs((window_offset:window_last).' - ...
            pkt_center));
        if env_original(center_local) > best_env
            best_env = env_original(center_local);
            best_pkt = idx;
        end
    end

    if ~isempty(best_pkt)
        % Find the report for this packet.
        report_idx = find([meta.reports.index] == ...
            summary_table.index(best_pkt), 1);
        if ~isempty(report_idx)
            report = meta.reports(report_idx);
            pkt_start = report.abs_start_fitted;
            pkt_samples = report.samples_subtracted;

            % Read a small window around this packet.
            read_first = max(0, pkt_start - 1024);
            read_last = min(total_samples - 1, ...
                pkt_start + pkt_samples - 1 + 1024);
            read_num = read_last - read_first + 1;
            raw_orig = uwbdecoder.readIqRaw(input_file, read_first, ...
                read_num, ant_num);
            rx_orig_pkt = uwbdecoder.selectIqChannel(raw_orig, channel_index);
            raw_cancel = uwbdecoder.readIqRaw(output_file, read_first, ...
                read_num, ant_num);
            rx_cancel_pkt = uwbdecoder.selectIqChannel(raw_cancel, channel_index);
            clear raw_orig raw_cancel;

            % Remove tone.
            if tone_removed && exist('tone_coeff', 'var')
                pkt_n = read_first + (0:read_num - 1).';
                pkt_basis = uwbdecoder.synchronousTone( ...
                    pkt_n, tone_bin, tone_period);
                rx_orig_pkt = rx_orig_pkt - tone_coeff .* pkt_basis;
                rx_cancel_pkt = rx_cancel_pkt - tone_coeff .* pkt_basis;
            end

            rx_removed_pkt = rx_orig_pkt - rx_cancel_pkt;

            % Zero-IF derotation.
            nominal_digital_offset_hz = 0;
            if isfield(params, 'dw1000_center_frequency') && ...
                    isfield(params, 'x410_center_frequency')
                nominal_digital_offset_hz = ...
                    params.dw1000_center_frequency - ...
                    params.x410_center_frequency;
            end
            display_rotation_hz = nominal_digital_offset_hz + ...
                report.fitted_cfo_hz;
            local_packet_first = pkt_start - read_first + 1;
            local_packet_last = local_packet_first + pkt_samples - 1;
            detail_first = max(1, local_packet_first - 512);
            detail_last = min(read_num, local_packet_last + 512);
            detail_abs = read_first + (detail_first:detail_last).' - 1;
            detail_time = (detail_abs - pkt_start) / fs_rx;
            zero_if = exp(-1j * 2 * pi * display_rotation_hz * detail_time);

            received_no_cfo = rx_orig_pkt(detail_first:detail_last) .* ...
                zero_if;
            model_no_cfo = rx_removed_pkt(detail_first:detail_last) .* ...
                zero_if;

            % Strong peaks.
            strong_threshold = 0.5 * max(abs(model_no_cfo));
            strong_idx = find(abs(model_no_cfo) > strong_threshold & ...
                abs(received_no_cfo) > strong_threshold);

            if ~isempty(strong_idx)
                detail_t_us = detail_time(strong_idx) * 1e6;
                phase_error_deg = rad2deg(angle( ...
                    received_no_cfo(strong_idx) .* ...
                    conj(model_no_cfo(strong_idx))));
                phase_error_rms = rms(phase_error_deg);

                fig5 = figure('Name', sprintf( ...
                    '%s full-impl: phase error pkt %d', ...
                    capture_stem, report.index), 'Color', 'w', ...
                    'Position', [100 100 1200 600]);

                subplot(2, 1, 1);
                plot(detail_t_us, phase_error_deg, '.', ...
                    'Color', [0.55 0.20 0.75], 'MarkerSize', 6);
                hold on;
                yline(0, 'k--');
                grid on;
                xlabel('Time from packet start (us)');
                ylabel('Phase error (deg)');
                title(sprintf( ...
                    'Strong-peak phase error | pkt %d | RMS %.2f deg', ...
                    report.index, phase_error_rms));
                xlim(detail_t_us([1 end]));

                % Radial / tangential residual.
                model_unit = model_no_cfo(strong_idx) ./ ...
                    (abs(model_no_cfo(strong_idx)) + eps);
                local_residual = (received_no_cfo(strong_idx) - ...
                    model_no_cfo(strong_idx)) .* conj(model_unit);
                radial_res = real(local_residual);
                tangential_res = imag(local_residual);

                subplot(2, 1, 2);
                yyaxis left;
                plot(detail_t_us, radial_res, '.', ...
                    'Color', [0.20 0.65 0.45], 'MarkerSize', 4);
                ylabel('Radial (ADC)');
                yyaxis right;
                plot(detail_t_us, tangential_res, '.', ...
                    'Color', [0.85 0.55 0.10], 'MarkerSize', 4);
                ylabel('Tangential (ADC)');
                grid on;
                xlabel('Time from packet start (us)');
                title(sprintf( ...
                    'Radial (ampl) vs Tangential (phase) residual | pkt %d', ...
                    report.index));
                xlim(detail_t_us([1 end]));

                sgtitle(sprintf(['%s full-implementation phase error | ', ...
                    'pkt %d | CFO %+.3f kHz | suppression %.2f dB | ', ...
                    'phase RMS %.2f deg'], capture_stem, report.index, ...
                    report.fitted_cfo_hz / 1e3, ...
                    report.frame_suppression_db, phase_error_rms), ...
                    'Interpreter', 'none');

                drawnow;
            end
        end
    end
end

%% 9. Save figures.
if save_figures && ~isfolder(output_dir)
    mkdir(output_dir);
end
if save_figures
    fprintf('Saving figures to %s ...\n', output_dir);
    fig_handles = findall(0, 'Type', 'figure');
    fig_handles = sort(fig_handles);
    for f = 1:numel(fig_handles)
        fig_name = sprintf('full_impl_10ms_fig_%d.png', f);
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

%% 10. Console summary.
fprintf('\n========== Full-implementation 10 ms summary ==========\n');
fprintf('File              : %s\n', input_file);
fprintf('Cancellation      : %s\n', cancelled_tag);
fprintf('Window offset     : %d (%.3f ms)\n', window_offset, ...
    window_offset / fs_rx * 1e3);
fprintf('Window length     : %d samples (%.3f ms)\n', ...
    window_num, window_num / fs_rx * 1e3);
fprintf('Window suppression: %.3f dB\n', suppression_db);
fprintf('Tone removed      : %d\n', tone_removed);
if ~isempty(summary_table)
    fprintf('Total packets     : %d\n', height(summary_table));
    fprintf('In window         : %d\n', numel(packet_in_window));
    success_mask = summary_table.success == 1;
    if any(success_mask)
        fprintf('Median suppression: %.2f dB\n', ...
            median(summary_table.frame_suppression_db(success_mask)));
    end
end
fprintf('=======================================================\n');