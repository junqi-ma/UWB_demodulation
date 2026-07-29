%% Visualize the cancellation effect of a single DW1000 or QM35 packet.
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
packet_index = 122;

% Source capture and cancellation mode. Every path below is derived from
% these two via fileparts + the mode tag, so switching captures only needs
% a change here.
input_file = 'F:\UWB基带数据\qm35_new_3.dat';
cancellation_mode = 'optimal_complex';   % must match run_cancel_all_uwb_packets
use_pll_phase_compensation = true;
use_cir_slow_phase_compensation = true;
show_pll_phase_curve = true;
pll_phase_template_file = '';
pll_phase_curve_repetitions = 10;

% -------------------------------------------------------------------------
% Auto-generated paths. Do not edit unless your cancel script naming differs.
% The cancelled capture lives inside the profile subdirectory produced by
% run_cancel_all_uwb_packets (decoded_results/<capture>/<cancelled_mode>.dat).
% -------------------------------------------------------------------------
[~, capture_stem] = fileparts(input_file);
if use_pll_phase_compensation
    cancelled_tag = sprintf('cancelled_%s_pll_subsync', cancellation_mode);
else
    cancelled_tag = sprintf('cancelled_%s', cancellation_mode);
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
    capture_stem, ['visualize_' cancelled_tag]);
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
    fig_preview = figure('Name', sprintf( ...
        '%s cancellation: suppression preview', capture_stem), ...
        'Color', 'w', 'Position', [80 80 1200 420]);

    packet_list_index = (1:height(summary_table)).';
    success_mask = summary_table.success == 1;
    suppression_db = summary_table.frame_suppression_db;

    has_pll_comparison = ismember( ...
        'frame_suppression_without_pll_db', ...
        summary_table.Properties.VariableNames);
    has_cir_slow_comparison = ismember( ...
        'frame_suppression_without_cir_slow_db', ...
        summary_table.Properties.VariableNames);
    has_sfo_comparison = ismember( ...
        'frame_suppression_without_sfo_db', ...
        summary_table.Properties.VariableNames);
    if has_pll_comparison
        suppression_without_pll_db = ...
            summary_table.frame_suppression_without_pll_db;
        plot(packet_list_index(success_mask), ...
            suppression_without_pll_db(success_mask), ...
            '-', 'Color', [0.60 0.60 0.60], 'LineWidth', 0.9);
        hold on;
    end
    if has_cir_slow_comparison
        suppression_without_cir_slow_db = ...
            summary_table.frame_suppression_without_cir_slow_db;
        plot(packet_list_index(success_mask), ...
            suppression_without_cir_slow_db(success_mask), '-', ...
            'Color', [0.20 0.65 0.30], 'LineWidth', 0.9);
        hold on;
    end
    if has_sfo_comparison
        suppression_without_sfo_db = ...
            summary_table.frame_suppression_without_sfo_db;
        sfo_gain_db = suppression_db - suppression_without_sfo_db;
        plot(packet_list_index(success_mask), ...
            suppression_without_sfo_db(success_mask), '-', ...
            'Color', [0.90 0.55 0.15], 'LineWidth', 0.9);
        hold on;
    end
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
    if has_pll_comparison
        if has_cir_slow_comparison
            pll_gain_db = suppression_without_cir_slow_db - ...
                suppression_without_pll_db;
            cir_slow_gain_db = suppression_db - ...
                suppression_without_cir_slow_db;
        else
            pll_gain_db = suppression_db - suppression_without_pll_db;
            cir_slow_gain_db = zeros(size(pll_gain_db));
        end
        if ~has_sfo_comparison
            sfo_gain_db = zeros(size(suppression_db));
        end
        title(sprintf([ ...
            'PLL cancellation: %d packets (%d successful) | ', ...
            ['median %.2f dB | PLL %+.3f dB | CIR slow %+.3f dB | ', ...
            'SFO %+.3f dB']], ...
            height(summary_table), nnz(success_mask), ...
            median(suppression_db(success_mask)), ...
            median(pll_gain_db(success_mask)), ...
            median(cir_slow_gain_db(success_mask)), ...
            median(sfo_gain_db(success_mask))));
        if has_cir_slow_comparison && has_sfo_comparison
            legend('No nonlinear phase compensation', ...
                'PLL template only', 'Without SFO', ...
                'PLL + CIR slow + SFO', 'Location', 'best');
        elseif has_cir_slow_comparison
            legend('No nonlinear phase compensation', ...
                'PLL template only', 'PLL + CIR slow phase', ...
                'Location', 'best');
        else
            legend('Without PLL template', 'With PLL template', ...
                'Location', 'best');
        end
    else
        title(sprintf([ ...
            'Cancellation summary: %d packets (%d successful) | ', ...
            'median %.2f dB | mean %.2f dB'], ...
            height(summary_table), nnz(success_mask), ...
            median(suppression_db(success_mask)), ...
            mean(suppression_db(success_mask))));
    end
    if any(~success_mask) && ~has_pll_comparison
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
    if has_pll_comparison
        fprintf(['PLL improvement: min %+.3f dB | median %+.3f dB | ', ...
            'max %+.3f dB | improved %.1f%%\n'], ...
            min(pll_gain_db(success_mask)), ...
            median(pll_gain_db(success_mask)), ...
            max(pll_gain_db(success_mask)), ...
            100 * mean(pll_gain_db(success_mask) > 0));
    end
    if has_cir_slow_comparison
        fprintf(['CIR slow improvement: min %+.3f dB | ', ...
            'median %+.3f dB | max %+.3f dB | improved %.1f%%\n'], ...
            min(cir_slow_gain_db(success_mask)), ...
            median(cir_slow_gain_db(success_mask)), ...
            max(cir_slow_gain_db(success_mask)), ...
            100 * mean(cir_slow_gain_db(success_mask) > 0));
    end
    if has_sfo_comparison
        fprintf(['SFO improvement: min %+.3f dB | ', ...
            'median %+.3f dB | max %+.3f dB | improved %.1f%%\n'], ...
            min(sfo_gain_db(success_mask)), ...
            median(sfo_gain_db(success_mask)), ...
            max(sfo_gain_db(success_mask)), ...
            100 * mean(sfo_gain_db(success_mask) > 0));
    end
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
meta = load(metadata_file);
reports = meta.reports;
params = meta.params;
if params.preamble_repetitions <= 72
    phy_label = 'QM35';
    default_pll_template_result = 'qm35_new_3';
else
    phy_label = 'DW1000';
    default_pll_template_result = 'dw1000_new_3';
end

% Load the phase curve independently of which cancellation file is shown.
% A PLL result carries the exact applied template in metadata. For a
% non-PLL result, load the analysis CSV so measured and candidate template
% phase can still be compared on the same plot.
pll_template_available = false;
pll_template_phase_by_repetition_rad = ...
    zeros(params.preamble_repetitions, 1);
pll_template_phase_by_bin_rad = ...
    zeros(params.preamble_repetitions, 1);
pll_template_bins_per_repetition = 1;
pll_sync_count = 0;
if isfield(meta, 'pll_phase_compensation') && ...
        meta.pll_phase_compensation.enabled
    saved_phase = meta.pll_phase_compensation.phase_by_repetition_rad(:);
    pll_sync_count = min([ ...
        meta.pll_phase_compensation.apply_repetitions, ...
        numel(saved_phase), params.preamble_repetitions]);
    pll_template_phase_by_repetition_rad(1:pll_sync_count) = ...
        saved_phase(1:pll_sync_count);
    if isfield(meta.pll_phase_compensation, 'phase_by_bin_rad') && ...
            ~isempty(meta.pll_phase_compensation.phase_by_bin_rad)
        saved_phase_by_bin = ...
            meta.pll_phase_compensation.phase_by_bin_rad;
        pll_template_bins_per_repetition = size(saved_phase_by_bin, 2);
        pll_template_phase_by_bin_rad = zeros( ...
            params.preamble_repetitions, ...
            pll_template_bins_per_repetition);
        saved_sync_count = min(pll_sync_count, ...
            size(saved_phase_by_bin, 1));
        pll_template_phase_by_bin_rad(1:saved_sync_count, :) = ...
            saved_phase_by_bin(1:saved_sync_count, :);
    else
        pll_template_phase_by_bin_rad = ...
            pll_template_phase_by_repetition_rad;
    end
    pll_phase_template_file = ...
        meta.pll_phase_compensation.template_file;
    pll_template_available = true;
elseif show_pll_phase_curve
    if isempty(pll_phase_template_file)
        capture_template_file = fullfile(project_dir, ...
            'decoded_results', 'pll_phase_drift_analysis', ...
            capture_stem, 'subsync_phase_template.csv');
        if isfile(capture_template_file)
            pll_phase_template_file = capture_template_file;
        else
            pll_phase_template_file = fullfile(project_dir, ...
                'decoded_results', 'pll_phase_drift_analysis', ...
                default_pll_template_result, ...
                'subsync_phase_template.csv');
        end
    end
    if isfile(pll_phase_template_file)
        pll_table = readtable(pll_phase_template_file);
        subsync_columns = {'repetition', 'bin_in_repetition', ...
            'applied_template_phase_deg'};
        required_pll_columns = {'repetition', 'template_phase_deg'};
        if all(ismember(subsync_columns, ...
                pll_table.Properties.VariableNames))
            repetitions = double(pll_table.repetition);
            bins = double(pll_table.bin_in_repetition);
            phase_deg = double(pll_table.applied_template_phase_deg);
            valid = isfinite(repetitions) & isfinite(bins) & ...
                isfinite(phase_deg) & repetitions >= 1 & ...
                repetitions <= params.preamble_repetitions & ...
                repetitions == round(repetitions) & bins >= 1 & ...
                bins == round(bins);
            repetitions = repetitions(valid);
            bins = bins(valid);
            phase_deg = phase_deg(valid);
            if ~isempty(repetitions)
                pll_sync_count = min([pll_phase_curve_repetitions, ...
                    params.preamble_repetitions, max(repetitions)]);
                pll_template_bins_per_repetition = max(bins);
                phase_by_bin_deg = NaN(pll_sync_count, ...
                    pll_template_bins_per_repetition);
                for row = 1:numel(phase_deg)
                    if repetitions(row) <= pll_sync_count && ...
                            bins(row) <= pll_template_bins_per_repetition
                        phase_by_bin_deg(repetitions(row), bins(row)) = ...
                            phase_deg(row);
                    end
                end
                if all(isfinite(phase_by_bin_deg), 'all')
                    pll_template_phase_by_bin_rad = zeros( ...
                        params.preamble_repetitions, ...
                        pll_template_bins_per_repetition);
                    pll_template_phase_by_bin_rad(1:pll_sync_count, :) = ...
                        deg2rad(phase_by_bin_deg);
                    pll_template_phase_by_repetition_rad( ...
                        1:pll_sync_count) = angle(mean(exp( ...
                        1j * deg2rad(phase_by_bin_deg)), 2));
                    pll_template_available = true;
                end
            end
        elseif all(ismember(required_pll_columns, ...
                pll_table.Properties.VariableNames))
            repetitions = double(pll_table.repetition);
            phase_deg = double(pll_table.template_phase_deg);
            valid = isfinite(repetitions) & isfinite(phase_deg) & ...
                repetitions >= 1 & ...
                repetitions <= params.preamble_repetitions & ...
                repetitions == round(repetitions);
            repetitions = repetitions(valid);
            phase_deg = phase_deg(valid);
            if ~isempty(repetitions)
                pll_sync_count = min([pll_phase_curve_repetitions, ...
                    params.preamble_repetitions, max(repetitions)]);
                needed = (1:pll_sync_count).';
                [complete, rows] = ismember(needed, repetitions);
                if all(complete)
                    pll_template_phase_by_repetition_rad(needed) = ...
                        deg2rad(phase_deg(rows));
                    pll_template_phase_by_bin_rad = ...
                        pll_template_phase_by_repetition_rad;
                    pll_template_available = true;
                end
            end
        end
    end
end
if show_pll_phase_curve && ~pll_template_available
    warning('visualize_uwb_cancellation:PllTemplateUnavailable', ...
        'No valid PLL phase template is available for plotting.');
end

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
pll_compensated = isfield(report, 'pll_compensation_applied') && ...
    report.pll_compensation_applied;
cir_slow_compensated = isfield(report, 'cir_slow_phase_applied') && ...
    report.cir_slow_phase_applied;
cir_second_cfo_compensated = ...
    isfield(report, 'cir_second_stage_cfo_applied') && ...
    report.cir_second_stage_cfo_applied;
full_packet_sfo_compensated = ...
    isfield(report, 'full_packet_sfo_applied') && ...
    report.full_packet_sfo_applied;
pll_title_suffix = '';
if pll_compensated && isfield(report, 'pll_improvement_db')
    pll_title_suffix = sprintf(' | PLL gain %+.2f dB', ...
        report.pll_improvement_db);
end
if cir_slow_compensated && ...
        isfield(report, 'cir_slow_phase_improvement_db')
    pll_title_suffix = sprintf('%s | CIR slow %+.2f dB', ...
        pll_title_suffix, report.cir_slow_phase_improvement_db);
end
if full_packet_sfo_compensated
    pll_title_suffix = sprintf('%s | SFO %+.2f ppm, %+.2f dB', ...
        pll_title_suffix, report.full_packet_sfo_ppm, ...
        report.sfo_improvement_db);
end
if use_pll_phase_compensation && ~pll_compensated
    warning('visualize_uwb_cancellation:PllMetadataMismatch', ...
        ['A PLL result was requested, but the selected report does not ', ...
        'declare PLL compensation.']);
end
if ~isfile(output_file)
    error('visualize_uwb_cancellation:OutputNotFound', ...
        'Cancelled capture not found: %s', output_file);
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
fprintf('PLL compensation     : %d\n', pll_compensated);
if pll_compensated && isfield(report, 'pll_improvement_db')
    fprintf('PLL frame improvement: %+.3f dB\n', ...
        report.pll_improvement_db);
end
fprintf('CIR slow compensation: %d\n', cir_slow_compensated);
if cir_slow_compensated
    fprintf('CIR slow frame gain  : %+.3f dB\n', ...
        report.cir_slow_phase_improvement_db);
end
fprintf('Full-packet SFO      : %d\n', full_packet_sfo_compensated);
if full_packet_sfo_compensated
    fprintf(['SFO time warp        : %+.3f ppm | intercept %+.4f ', ...
        'sample | drift %+.4f sample | gain %+.3f dB\n'], ...
        report.full_packet_sfo_ppm, ...
        report.full_packet_sfo_delay_intercept_samples, ...
        report.full_packet_sfo_total_drift_samples, ...
        report.sfo_improvement_db);
end

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
pll_template_end_us = NaN;
pll_applied_phase_rad = zeros(read_num, 1);
pll_template_sample_phase_rad = zeros(read_num, 1);
pll_phase_by_repetition_rad = ...
    pll_template_phase_by_repetition_rad;
if pll_template_available
    pll_period_samples = c.PREAMBLE_PERIOD_S * fs_rx;
    for repetition = 1:pll_sync_count
        for bin = 1:pll_template_bins_per_repetition
            first_boundary = (repetition - 1) + ...
                (bin - 1) / pll_template_bins_per_repetition;
            last_boundary = (repetition - 1) + ...
                bin / pll_template_bins_per_repetition;
            phase_first = local_packet_first + ...
                round(first_boundary * pll_period_samples);
            phase_last = min(read_num, local_packet_first + ...
                round(last_boundary * pll_period_samples) - 1);
            phase_first = max(1, phase_first);
            if phase_first <= phase_last
                pll_template_sample_phase_rad(phase_first:phase_last) = ...
                    pll_template_phase_by_bin_rad(repetition, bin);
            end
        end
    end
    if pll_compensated
        pll_applied_phase_rad = pll_template_sample_phase_rad;
    end
    pll_end_sample = local_packet_first + ...
        round(pll_sync_count * pll_period_samples) - 1;
    pll_template_end_us = ...
        (pll_end_sample - local_packet_first) / fs_rx * 1e6;
    if pll_end_sample <= local_packet_last
        field_markers(end + 1) = struct( ...
            'name', sprintf('PLL template end (%d SYNC)', pll_sync_count), ...
            'sample', pll_end_sample); %#ok<SAGROW>
    end
end

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

% Recreate the exact packet-specific CIR correction. The nonlinear curve
% is limited to measured CIR repetitions; its rejected linear component is
% a second-stage CFO ramp that continues through the rest of the packet.
cir_slow_phase_by_repetition_rad = zeros( ...
    params.preamble_repetitions, 1);
cir_slow_sample_phase_rad = zeros(read_num, 1);
cir_slow_diagnostics = struct('applied', false);
if cir_slow_compensated && ~isempty(packet_table_row)
    if isfield(meta, 'cir_slow_phase_options')
        cir_slow_options = meta.cir_slow_phase_options;
    else
        cir_slow_options = struct();
    end
    [cir_slow_phase_by_repetition_rad, cir_slow_diagnostics] = ...
        estimate_uwb_cir_slow_phase(packet_table_row.cir, ...
        params.preamble_repetitions, cir_slow_options);
    slow_period_samples = c.PREAMBLE_PERIOD_S * fs_rx;
    for repetition = 1:params.preamble_repetitions
        phase_first = local_packet_first + ...
            round((repetition - 1) * slow_period_samples);
        phase_last = min(read_num, local_packet_first + ...
            round(repetition * slow_period_samples) - 1);
        phase_first = max(1, phase_first);
        if phase_first <= phase_last
            cir_slow_sample_phase_rad(phase_first:phase_last) = ...
                cir_slow_phase_by_repetition_rad(repetition);
        end
    end
    if cir_second_cfo_compensated && ...
            cir_slow_diagnostics.second_stage_cfo_applied
        cfo2_first_sample = local_packet_first + round( ...
            (cir_slow_diagnostics.first_repetition - 1) * ...
            slow_period_samples);
        cfo2_first_sample = max(1, cfo2_first_sample);
        cfo2_last_sample = min(read_num, local_packet_last);
        if cfo2_first_sample <= cfo2_last_sample
            cfo2_offset_repetitions = ...
                ((cfo2_first_sample:cfo2_last_sample).' - ...
                cfo2_first_sample) / slow_period_samples;
            cir_slow_sample_phase_rad( ...
                cfo2_first_sample:cfo2_last_sample) = ...
                cir_slow_sample_phase_rad( ...
                cfo2_first_sample:cfo2_last_sample) + ...
                cir_slow_diagnostics.linear_phase_slope_rad_per_repetition * ...
                cfo2_offset_repetitions;
        end
        cfo2_repetitions = ...
            (cir_slow_diagnostics.first_repetition: ...
            params.preamble_repetitions).';
        cir_slow_phase_by_repetition_rad(cfo2_repetitions) = ...
            cir_slow_phase_by_repetition_rad(cfo2_repetitions) + ...
            cir_slow_diagnostics.linear_phase_slope_rad_per_repetition * ...
            (cfo2_repetitions - ...
            cir_slow_diagnostics.first_repetition + 0.5);
    end
    fprintf(['CIR slow curve       : SYNC %d..%d | RMS %.3f deg | ', ...
        'max %.3f deg\n'], cir_slow_diagnostics.first_repetition, ...
        cir_slow_diagnostics.last_repetition, ...
        cir_slow_diagnostics.correction_rms_deg, ...
        cir_slow_diagnostics.maximum_abs_correction_deg);
    if cir_second_cfo_compensated
        fprintf('CIR second CFO       : %+.3f kHz\n', ...
            report.cir_second_stage_cfo_hz / 1e3);
    end
end

%% 1. Figure 1: envelope comparison across the read window
figure('Name', sprintf('%s cancellation: packet %d (#%d)', ...
    phy_label, report.index, packet_index), 'Color', 'w', ...
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

sgtitle(sprintf(['%s packet %d (#%d) | suppression %.2f dB | ', ...
    'CFO %+.3f kHz | corr %.3f%s'], phy_label, report.index, packet_index, ...
    report.frame_suppression_db, report.fitted_cfo_hz / 1e3, ...
    report.alignment_correlation, pll_title_suffix), 'Interpreter', 'none');

%% 2. Figure 2: packet-region detail + spectrum
% Extract the packet region (with a small pad) for a zoomed view.
detail_pad = min(512, window_pad_samples);
detail_first = max(1, local_packet_first - detail_pad);
detail_last = min(read_num, local_packet_last + detail_pad);
detail_abs_samples = read_first + (detail_first:detail_last).' - 1;
detail_t_us = (detail_abs_samples - packet_first) / fs_rx * 1e6;

% Suppression computed only inside the subtracted region.
region_original = rx_original(local_packet_first:local_packet_last);
region_cancelled = rx_cancelled(local_packet_first:local_packet_last);
region_suppression_db = 10 * log10( ...
    mean(abs(region_original).^2) / ...
    (mean(abs(region_cancelled).^2) + eps));

figure('Name', sprintf('%s packet %d (#%d) detail', ...
    phy_label, report.index, packet_index), 'Color', 'w', ...
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
pll_metric_text = 'PLL template    : off';
baseline_suppression_text = 'Without PLL     : n/a';
if pll_compensated
    pll_metric_text = sprintf('PLL template    : on (%+.3f dB)', ...
        report.pll_improvement_db);
    if isfield(report, 'frame_suppression_without_pll_db')
        baseline_suppression_text = sprintf('Without PLL     : %.2f dB', ...
            report.frame_suppression_without_pll_db);
    end
end
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
    pll_metric_text;
    baseline_suppression_text;
    sprintf('Reported supp  : %.2f dB', report.frame_suppression_db);
    sprintf('Window meas.   : %.2f dB', region_suppression_db);
    sprintf('Clipped comp.  : %d', report.clipped_component_count);
    sprintf('FCS pass       : %d', report.fcs_pass);
    };
text(0.05, 0.95, summary_text, 'Interpreter', 'none', ...
    'VerticalAlignment', 'top', 'FontName', 'Consolas', 'FontSize', 10);
title('Cancellation metrics');

sgtitle(sprintf('%s packet %d (#%d) detail%s', ...
    phy_label, report.index, packet_index, pll_title_suffix), ...
    'Interpreter', 'none');

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

figure('Name', sprintf('%s packet %d (#%d) envelope overlay', ...
    phy_label, report.index, packet_index), 'Color', 'w', ...
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
if pll_compensated
    reconstructed_label = 'Reconstructed + PLL template';
else
    reconstructed_label = 'Reconstructed';
end
legend('Original', reconstructed_label, 'After cancellation', ...
    'Location', 'best');
xlim(plot_t_us([1 end]));

sgtitle(sprintf('%s packet %d (#%d) | stride %d | Fs %.3f MHz%s', ...
    phy_label, report.index, packet_index, plot_stride, fs_rx / 1e6, ...
    pll_title_suffix), ...
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

strong_threshold = 0.5 * max(abs(model_no_cfo));
strong_idx = find(abs(model_no_cfo) > strong_threshold & ...
    abs(received_no_cfo) > strong_threshold);
strong_t_us = detail_time_from_packet_start(strong_idx) * 1e6;

% Compare the applied template against the measured offset at the same
% one-value-per-SYNC resolution used to create the PLL template.
sync_count = params.preamble_repetitions;
sync_time_us = ((1:sync_count).' - 0.5) * ...
    c.PREAMBLE_PERIOD_S * 1e6;
measured_phase_before_deg = NaN(sync_count, 1);
measured_phase_after_deg = NaN(sync_count, 1);
template_phase_deg = (pll_phase_by_repetition_rad + ...
    cir_slow_phase_by_repetition_rad) * 180 / pi;
template_bin_phase_deg = reshape( ...
    pll_template_phase_by_bin_rad(1:pll_sync_count, :).', [], 1) * ...
    180 / pi;
template_bin_time_us = ((1:numel(template_bin_phase_deg)).' - 0.5) / ...
    pll_template_bins_per_repetition * c.PREAMBLE_PERIOD_S * 1e6;
if pll_compensated
    post_compensation_label = 'Measured residual after compensation';
else
    post_compensation_label = 'Predicted residual after template';
end
for repetition = 1:sync_count
    sync_first = local_packet_first + ...
        round((repetition - 1) * c.PREAMBLE_PERIOD_S * fs_rx);
    sync_last = min(local_packet_last, local_packet_first + ...
        round(repetition * c.PREAMBLE_PERIOD_S * fs_rx) - 1);
    if sync_first < 1 || sync_first > sync_last
        continue
    end
    received_sync = rx_original(sync_first:sync_last);
    model_current_sync = rx_removed(sync_first:sync_last);
    template_sync = pll_template_sample_phase_rad( ...
        sync_first:sync_last) + cir_slow_sample_phase_rad( ...
        sync_first:sync_last);
    if pll_compensated
        model_after_sync = model_current_sync;
        model_before_sync = ...
            model_current_sync .* exp(-1j * template_sync);
    else
        model_before_sync = model_current_sync;
        model_after_sync = ...
            model_current_sync .* exp(1j * template_sync);
    end
    sync_threshold = 0.5 * max(abs(model_after_sync));
    sync_strong = abs(model_after_sync) > sync_threshold & ...
        abs(received_sync) > sync_threshold;
    if nnz(sync_strong) < 4
        continue
    end
    measured_phase_before_deg(repetition) = rad2deg(angle(sum( ...
        conj(model_before_sync(sync_strong)) .* ...
        received_sync(sync_strong))));
    measured_phase_after_deg(repetition) = rad2deg(angle(sum( ...
        conj(model_after_sync(sync_strong)) .* ...
        received_sync(sync_strong))));
end

pll_phase_match_rms_deg = NaN;
if pll_template_available
    comparison_indices = (1:min(pll_sync_count, sync_count)).';
    valid_comparison = isfinite( ...
        measured_phase_before_deg(comparison_indices));
    comparison_indices = comparison_indices(valid_comparison);
    if ~isempty(comparison_indices)
        phase_match_error_rad = angle(exp(1j * deg2rad( ...
            measured_phase_before_deg(comparison_indices) - ...
            template_phase_deg(comparison_indices))));
        pll_phase_match_rms_deg = ...
            rms(rad2deg(phase_match_error_rad));
    end
end

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
        '%s packet %d (#%d) strong peak phase', ...
        phy_label, report.index, packet_index), 'Color', 'w', ...
        'Position', [120 40 1250 1000]);

    subplot(4, 1, 1);
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

    subplot(4, 1, 2);
    h_phase_before = plot(sync_time_us, measured_phase_before_deg, 'o-', ...
        'Color', [0.55 0.20 0.75], 'MarkerSize', 4, ...
        'LineWidth', 1.0);
    hold on;
    h_phase_template = stairs(template_bin_time_us, ...
        template_bin_phase_deg, '-', ...
        'Color', [0.90 0.25 0.15], 'LineWidth', 1.8);
    h_phase_cir_slow = stairs(sync_time_us, ...
        cir_slow_phase_by_repetition_rad * 180 / pi, '-', ...
        'Color', [0.15 0.60 0.25], 'LineWidth', 1.5);
    h_phase_after = plot(sync_time_us, measured_phase_after_deg, '.-', ...
        'Color', [0.10 0.55 0.75], 'MarkerSize', 7, ...
        'LineWidth', 0.8);
    yline(0, 'k--');
    if isfinite(pll_template_end_us)
        xline(pll_template_end_us, 'r--', 'PLL template end');
    end
    grid on;
    xlabel('Time from fitted packet start (us)');
    ylabel('Phase (deg)');
    if isfinite(pll_phase_match_rms_deg)
        title(sprintf([ ...
            'PLL phase: measured offset vs applied template | ', ...
            'match RMS %.2f deg'], pll_phase_match_rms_deg));
    else
        title('PLL phase: measured offset vs applied template');
    end
    legend([h_phase_before, h_phase_template, h_phase_cir_slow, ...
        h_phase_after], 'Measured before compensation', ...
        'Applied PLL template', 'Packet-specific CIR slow phase', ...
        post_compensation_label, 'Location', 'best');
    xlim(sync_time_us([1 end]));

    subplot(4, 1, 3);
    plot(strong_t_us, smooth(phase_error_deg,1), '.', ...
        'Color', [0.55 0.20 0.75], 'MarkerSize', 10);
    hold on;
    yline(0, 'k--');
    if isfinite(pll_template_end_us)
        xline(pll_template_end_us, 'r--', 'PLL template end');
    end
    grid on;
    xlabel('Time (us)');
    ylabel('Phase error (deg)');
    title(sprintf('Strong peak phase error | RMS %.2f deg', ...
        phase_error_rms_deg));
    xlim(strong_t_us([1 end]));

    subplot(4, 1, 4);
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

    sgtitle(sprintf(['%s packet %d (#%d) strong peak | ', ...
        'ampl RMS %.2f dB | phase RMS %.2f deg%s'], ...
        phy_label, report.index, packet_index, amplitude_error_rms_db, ...
        phase_error_rms_deg, pll_title_suffix), 'Interpreter', 'none');

    fprintf('\n=== Strong peak phase analysis (CFO-removed) ===\n');
    fprintf('Strong peaks       : %d\n', numel(strong_idx));
    fprintf('Amplitude error RMS: %.3f dB\n', amplitude_error_rms_db);
    fprintf('Phase error RMS    : %.3f deg\n', phase_error_rms_deg);
    if isfinite(pll_phase_match_rms_deg)
        fprintf('PLL template match : %.3f deg RMS (first %d SYNC)\n', ...
            pll_phase_match_rms_deg, pll_sync_count);
        fprintf('First SYNC phase   : measured %+.3f | template %+.3f | ', ...
            measured_phase_before_deg(1), template_phase_deg(1));
        fprintf('%s %+.3f deg\n', lower(post_compensation_label), ...
            measured_phase_after_deg(1));
    end
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

    figure('Name', sprintf('%s packet %d (#%d) zero-IF I-Q', ...
        phy_label, report.index, packet_index), 'Color', 'w', ...
        'Position', [140 100 900 760]);
    plot(real(orig_scatter), imag(orig_scatter), '.', ...
        'Color', [0.10 0.45 0.85], 'MarkerSize', 4);

    hold on;
    plot(real(model_scatter), imag(model_scatter), '.', ...
        'Color', [0.85 0.30 0.12], 'MarkerSize', 4);

    plot(real(local_resid),imag(local_resid), '.', 'MarkerSize', 4);

    grid on; axis equal;
    xlim([-iq_limit iq_limit]);
    ylim([-iq_limit iq_limit]);
    xlabel('In-phase (ADC)');
    ylabel('Quadrature (ADC)');
    legend('Original', reconstructed_label, 'Residual', ...
        'Location', 'best');
    title(sprintf([ ...
        'Zero-IF I-Q overlay | %d samples | radial p95 %.1f | ', ...
        'tangential p95 %.1f ADC'], numel(scatter_idx), ...
        radial_resid_p95, tangential_resid_p95));

end

%% 6. Figure 6: CIR of the selected packet
% The cancellation metadata retains the decoder frame records, including
% the spreading-code-despread CIR. Plot both the coherent average and the
% individual preamble-repetition estimates when they are available.
if ~isempty(packet_table_row) && isfield(packet_table_row, 'cir') && ...
        isstruct(packet_table_row.cir) && ...
        isfield(packet_table_row.cir, 'values') && ...
        isfield(packet_table_row.cir, 'delay_ns') && ...
        ~isempty(packet_table_row.cir.values)
    packet_cir = packet_table_row.cir;
    cir_values = packet_cir.values(:);
    cir_delay_ns = packet_cir.delay_ns(:);
    cir_count = min(numel(cir_values), numel(cir_delay_ns));
    cir_values = cir_values(1:cir_count);
    cir_delay_ns = cir_delay_ns(1:cir_count);

    cir_magnitude = abs(cir_values);
    cir_magnitude_normalized = cir_magnitude / ...
        (max(cir_magnitude) + eps);
    cir_magnitude_db = 20 * log10(max(cir_magnitude_normalized, 1e-4));
    [~, cir_peak_index] = max(cir_magnitude);
    cir_peak_delay_ns = cir_delay_ns(cir_peak_index);

    cir_power = cir_magnitude .^ 2;
    cir_power = cir_power / (sum(cir_power) + eps);
    cir_mean_delay_ns = sum(cir_power .* cir_delay_ns);
    cir_rms_delay_ns = sqrt(sum(cir_power .* ...
        (cir_delay_ns - cir_mean_delay_ns) .^ 2));

    % Track the complex coefficient at the nominal first-path tap for up to
    % 64 preamble repetitions. The CIR delay axis is referenced to the
    % detected first path, so the tap nearest 0 ns is used instead of the
    % strongest tap (which could be a later multipath component).
    cir_individual = [];
    first_path_repetition = [];
    first_path_phase_change_deg = [];
    [~, cir_first_path_index] = min(abs(cir_delay_ns));
    cir_first_path_delay_ns = cir_delay_ns(cir_first_path_index);
    if isfield(packet_cir, 'individual_values') && ...
            ~isempty(packet_cir.individual_values)
        cir_individual = packet_cir.individual_values;
        cir_individual = cir_individual(1:min(cir_count, ...
            size(cir_individual, 1)), :);
        preamble_count = min(64, size(cir_individual, 2));
        if cir_first_path_index <= size(cir_individual, 1) && ...
                preamble_count > 0
            first_path_values = cir_individual(cir_first_path_index, ...
                1:preamble_count);
            first_path_phase_unwrapped_deg = rad2deg( ...
                unwrap(angle(first_path_values)));
            first_path_phase_change_deg = ...
                first_path_phase_unwrapped_deg - ...
                first_path_phase_unwrapped_deg(1);
            if isfield(packet_cir, 'first_repetition') && ...
                    ~isempty(packet_cir.first_repetition)
                first_path_repetition = packet_cir.first_repetition + ...
                    (0:preamble_count - 1);
            else
                first_path_repetition = 1:preamble_count;
            end
        end
    end

    figure('Name', sprintf('%s packet %d (#%d) CIR', ...
        phy_label, report.index, packet_index), 'Color', 'w', ...
        'Position', [140 40 1200 960]);

    subplot(3, 2, 1);
    if ~isempty(cir_individual)
        cir_individual_magnitude = abs(cir_individual);
        cir_individual_magnitude = cir_individual_magnitude ./ ...
            (max(cir_individual_magnitude, [], 1) + eps);
        imagesc(cir_delay_ns(1:size(cir_individual, 1)), ...
            1:size(cir_individual, 2), cir_individual_magnitude.');
        axis xy;
        colorbar;
        colormap(gca, parula);
        xline(0, 'w--', '0 ns', 'LineWidth', 1.0);
        xlabel('Relative delay (ns)');
        ylabel('Preamble repetition');
        title('Per-repetition normalized CIR magnitude');
    else
        text(0.5, 0.5, 'Individual CIR estimates unavailable', ...
            'HorizontalAlignment', 'center');
        axis off;
        title('Per-repetition CIR');
    end

    subplot(3, 2, 2);
    stem(cir_delay_ns, cir_magnitude_normalized, 'filled', ...
        'Color', [0.10 0.45 0.85], 'MarkerSize', 4);
    hold on;
    xline(0, 'k--', 'Nominal zero delay');
    plot(cir_peak_delay_ns, cir_magnitude_normalized(cir_peak_index), ...
        'ro', 'MarkerFaceColor', 'r');
    grid on;
    ylim([0 1.12]);
    xlabel('Relative delay (ns)');
    ylabel('Normalized |CIR|');
    title(sprintf('Coherent average | peak %.3f ns', ...
        cir_peak_delay_ns));

    subplot(3, 2, 3);
    plot(cir_delay_ns, real(cir_values), '-o', ...
        'Color', [0.10 0.45 0.85], 'MarkerSize', 3);
    hold on;
    plot(cir_delay_ns, imag(cir_values), '-s', ...
        'Color', [0.90 0.30 0.12], 'MarkerSize', 3);
    xline(0, 'k--');
    grid on;
    xlabel('Relative delay (ns)');
    ylabel('Complex coefficient');
    title('Complex CIR coefficients');
    legend('Real', 'Imaginary', 'Location', 'best');

    subplot(3, 2, 4);
    yyaxis left;
    stem(cir_delay_ns, cir_magnitude_db, 'filled', ...
        'Color', [0.10 0.45 0.85], 'MarkerSize', 3);
    ylabel('Normalized |CIR| (dB)');
    ylim([-80 5]);
    yyaxis right;
    cir_phase_valid = cir_magnitude_db >= -30;
    plot(cir_delay_ns(cir_phase_valid), ...
        rad2deg(angle(cir_values(cir_phase_valid))), 'o-', ...
        'Color', [0.90 0.30 0.12], 'MarkerSize', 4);
    ylabel('Phase above -30 dB (deg)');
    ylim([-190 190]);
    xline(0, 'k--');
    grid on;
    xlabel('Relative delay (ns)');
    title(sprintf('Log magnitude and phase | RMS delay %.3f ns', ...
        cir_rms_delay_ns));

    subplot(3, 2, [5 6]);
    if ~isempty(first_path_phase_change_deg)
        plot(first_path_repetition, first_path_phase_change_deg, 'o-', ...
            'Color', [0.55 0.20 0.75], 'LineWidth', 1.2, ...
            'MarkerSize', 4, 'MarkerFaceColor', [0.55 0.20 0.75]);
        hold on;
        yline(0, 'k--');
        grid on;
        xlim(first_path_repetition([1 end]));
        xlabel('Preamble repetition');
        ylabel('Unwrapped phase change (deg)');
        title(sprintf(['First-path phase evolution at %.3f ns | ', ...
            '%d preambles'], cir_first_path_delay_ns, ...
            numel(first_path_repetition)));
    else
        text(0.5, 0.5, 'First-path phase data unavailable', ...
            'HorizontalAlignment', 'center');
        axis off;
        title('First-path phase evolution');
    end

    sgtitle(sprintf('%s packet %d (#%d) CIR | %d taps', ...
        phy_label, report.index, packet_index, cir_count), ...
        'Interpreter', 'none');

    fprintf('\n=== CIR analysis ===\n');
    fprintf('CIR taps          : %d\n', cir_count);
    fprintf('Peak delay        : %.3f ns\n', cir_peak_delay_ns);
    fprintf('Mean delay        : %.3f ns\n', cir_mean_delay_ns);
    fprintf('RMS delay spread  : %.3f ns\n', cir_rms_delay_ns);
    if ~isempty(first_path_phase_change_deg)
        fprintf('First-path phase  : %d preambles, %+.3f deg total change\n', ...
            numel(first_path_phase_change_deg), ...
            first_path_phase_change_deg(end));
    end
else
    warning('visualize_uwb_cancellation:CirUnavailable', ...
        'CIR data is unavailable for packet %d.', report.index);
end

%% 7. Console summary
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
fprintf('PLL compensation : %d\n', pll_compensated);
if pll_compensated
    fprintf('Without PLL supp.: %.2f dB\n', ...
        report.frame_suppression_without_pll_db);
    fprintf('PLL improvement  : %+.3f dB\n', ...
        report.pll_improvement_db);
end
fprintf('CIR slow phase   : %d\n', cir_slow_compensated);
if cir_slow_compensated
    fprintf('CIR slow gain    : %+.3f dB\n', ...
        report.cir_slow_phase_improvement_db);
    fprintf('CIR slow curve   : RMS %.3f deg | max %.3f deg\n', ...
        report.cir_slow_phase_correction_rms_deg, ...
        report.cir_slow_phase_max_abs_deg);
    if cir_second_cfo_compensated
        fprintf('CIR second CFO   : %+.3f kHz\n', ...
            report.cir_second_stage_cfo_hz / 1e3);
    end
end
fprintf('Full-packet SFO  : %d\n', full_packet_sfo_compensated);
if full_packet_sfo_compensated
    fprintf('SFO estimate     : %+.3f ppm\n', ...
        report.full_packet_sfo_ppm);
    fprintf('SFO delay line   : intercept %+.4f | drift %+.4f samples\n', ...
        report.full_packet_sfo_delay_intercept_samples, ...
        report.full_packet_sfo_total_drift_samples);
    fprintf('SFO fit          : %d windows | RMS %.4f | explained %.3f\n', ...
        report.full_packet_sfo_valid_windows, ...
        report.full_packet_sfo_fit_residual_samples, ...
        report.full_packet_sfo_explained_fraction);
    fprintf('SFO gain         : %+.3f dB\n', ...
        report.sfo_improvement_db);
end
fprintf('Reported supp.   : %.2f dB\n', report.frame_suppression_db);
fprintf('Window measured  : %.2f dB\n', region_suppression_db);
fprintf('Clipped comp.    : %d\n', report.clipped_component_count);
fprintf('FCS pass         : %d\n', report.fcs_pass);

%% 8. Save figures to disk
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
