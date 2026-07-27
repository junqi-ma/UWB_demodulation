%% Decode every UWB packet in an X410 capture and save all CIRs
% Three-stage flow:
%   1) read every 100th IQ record and form a robust energy envelope
%   2) run 32x-decimated preamble correlation only in energetic intervals
%   3) fully decode surviving candidates and export exact sample intervals
clear;
close all;
clc;

%% -------------------- Signal type --------------------
% Select exactly one signal type: 'DW1000' or 'QM35'.
signal_type = 'QM35';

%% -------------------- Input capture --------------------
options = struct();
options.file_name = 'F:\UWB基带数据\qm35_1.dat';
options.ant_num = 1;
options.channel_index = 1;

%% -------------------- X410 / DW1000 radio --------------------
options.fs_rx = 737.28e6;
options.x410_center_frequency = 6500e6;
options.dw1000_center_frequency = 6489.6e6;
options.data_rate = 6.81;

options.decawave_sfd = [-1; -1; -1; -1; 1; -1; 0; 0];
options.ieee_sfd = [0; 1; 0; -1; 1; 0; 0; -1];
options.sfd4z_1 = [-1; -1; 1; -1];
options.sfd4z_2 = [-1; -1; -1; 1; -1; -1; 1; -1];
options.sfd4z_3 = [-1; -1; -1; -1; -1; 1; 1; -1; ...
    -1; 1; -1; 1; -1; -1; 1; -1];
options.sfd4z_4 = [-1; -1; -1; -1; -1; -1; -1; 1; ...
    -1; -1; 1; -1; -1; 1; -1; 1; -1; 1; -1; -1; ...
    -1; 1; 1; -1; -1; -1; 1; -1; 1; 1; -1; -1];

switch upper(signal_type)
    case 'DW1000'
        signal_type = 'DW1000';
        options.preamble_repetitions = 256;
        options.code_index = 10;
        options.sfd_mode = 'decawave';
        options.cir_skip_initial_repetitions = [];
        options.cir_repetitions = 64;
        interference_quiet_num = 1500000;
        output_suffix = '';
    case 'QM35'
        signal_type = 'QM35';
        options.preamble_repetitions = 128;
        options.code_index = 9;
        % QM35 uses IEEE 802.15.4z SFD #2. Its first 24 SYNCs have a
        % visible phase transient, so estimate CIR from stable SYNC 25..128.
        options.sfd_mode = '4z2';
        options.cir_skip_initial_repetitions = 24;
        options.cir_repetitions = 60;
        interference_quiet_num = 262144;
        output_suffix = '_qm35';
    otherwise
        error('signal_type must be ''DW1000'' or ''QM35''.');
end

%% -------------------- Interference cancellation --------------------
options.enable_interference_cancellation = true;
options.interference_quiet_offset = 400000;
options.interference_quiet_num = interference_quiet_num;
options.interference_tone_bin = -169;
options.interference_period_samples = 512;
% Leave empty to estimate once from the quiet interval, then reuse.
options.interference_coefficient = [];
options.show_plots = false;

%% -------------------- Stage 1: strided energy scan --------------------
batch = struct();
% The reader skips complete IQ records in the file, so this reduces both
% conversion work and the amount of capture data returned to MATLAB.
batch.energy_chunk_samples = 20e6;
batch.energy_step_samples = 19e6;
batch.energy_read_stride = 100;
% Moving-average length and region controls use original RX sample units.
batch.energy_smooth_rx_samples = 8192;
% Estimate the quiet floor from the lowest-energy 30% so dense packet
% traffic does not push the background estimate into the signal population.
batch.energy_baseline_fraction = 0.30;
% Hysteresis thresholds: quiet-floor median + k * robust sigma.
batch.energy_threshold_sigma_high = 6;
batch.energy_threshold_sigma_low = 3;
batch.energy_min_region_samples = 3e4;
batch.energy_region_pre_guard_samples = 5e4;
batch.energy_region_post_guard_samples = 5e4;
batch.energy_region_merge_samples = 1e4;

%% -------------------- Stage 2: correlation refinement --------------------
batch.correlation_decimation = 32;
batch.correlation_repetitions = 8;
batch.correlation_chunk_samples = 4e6;
batch.correlation_overlap_samples = 3e5;
batch.corr_threshold_sigma = 5;
batch.correlation_peak_min_distance_samples = 400;
batch.correlation_cluster_gap_samples = 4000;
batch.correlation_min_cluster_peaks = 4;
batch.candidate_merge_samples = 5e4;

%% -------------------- Stage 3: full-rate decode --------------------
% Start the full decoder before the refined preamble estimate.
batch.pre_packet_guard_samples = 5e4;
batch.window_samples = 0.8e6;
batch.min_window_samples = 0.3e6;
% Exact packet_intervals have no guard. blank_intervals use these margins
% and can be passed directly to options.blank_intervals in other decoders.
batch.localization_pre_guard_samples = 2048;
batch.localization_post_guard_samples = 4096;
batch.start_tolerance_samples = 4096;
batch.require_fcs_pass = false;
batch.save_individual_cir = true;

%% -------------------- Output paths --------------------
[~, capture_stem] = fileparts(options.file_name);
batch.output_directory = fullfile(pwd, 'decoded_results', ...
    [capture_stem output_suffix]);
batch.mat_file = fullfile(batch.output_directory, 'all_frames_cir.mat');
batch.summary_csv = fullfile(batch.output_directory, 'frame_summary.csv');
batch.timeline_png = fullfile(batch.output_directory, 'packet_timeline.png');

%% -------------------- Run one full-file decode --------------------
fprintf('\n========== Selected signal type: %s ==========\n', signal_type);
results = decode_x410_dw1000_all(options, batch);

%% -------------------- Compact console summary --------------------
fprintf('\n========== Full-file %s decode summary ==========\n', signal_type);
fprintf('Capture file                 : %s\n', options.file_name);
fprintf('Total complex samples        : %d\n', results.total_samples);
fprintf('Capture duration             : %.3f ms\n', results.duration_s*1e3);
fprintf('%-30s: %d\n', [signal_type ' packets'], results.packet_count);
fprintf('FCS-pass packets            : %d\n', results.fcs_pass_count);
fprintf('Precisely bounded packets   : %d\n', ...
    sum(results.precise_interval_mask));
fprintf('Time energy / corr / fine   : %.1f s / %.1f s / %.1f s\n', ...
    results.energy_seconds, results.correlation_seconds, ...
    results.fine_seconds);
fprintf('Results MAT                  : %s\n', batch.mat_file);
fprintf('Summary CSV                  : %s\n', batch.summary_csv);
fprintf('Timeline PNG                 : %s\n', batch.timeline_png);
fprintf('=============================================================\n');

if results.packet_count > 0
    for k = 1:results.packet_count
        frame = results.frames(k);
        profile = signal_type;
        if isfield(frame, 'profile') && ~isempty(frame.profile)
            profile = frame.profile;
        end
        fprintf(['#%02d [%s]  start=%.3f ms  end=%.3f ms  ', ...
            'dur=%.3f us  samples=[%d,%d]  SFD=%s  corr=%.3f  ', ...
            'PSDU=%d B  FCS=%d\n'], ...
            k, profile, ...
            frame.time_start_s*1e3, frame.time_end_s*1e3, ...
            (frame.time_end_s-frame.time_start_s)*1e6, ...
            frame.abs_start_sample, frame.abs_end_sample, ...
            frame.sfd_name, frame.sfd_correlation, ...
            frame.psdu_length_bytes, frame.fcs_pass);
    end

    %% -------------------- Packet arrival / end timeline plot --------------------
    plotPacketTimeline(results, batch.timeline_png);
else
    fprintf('No packets decoded; timeline plot skipped.\n');
end

%% ------------------------------------------------------------------------
function plotPacketTimeline(results, png_path)
%PLOTPACKETTIMELINE Plot each packet's arrival and end time on one axis.
frames = results.frames;
n = numel(frames);
t_start_ms = zeros(n, 1);
t_end_ms = zeros(n, 1);
fcs_pass = false(n, 1);
for k = 1:n
    t_start_ms(k) = frames(k).time_start_s*1e3;
    t_end_ms(k) = frames(k).time_end_s*1e3;
    fcs_pass(k) = logical(frames(k).fcs_pass);
end
duration_ms = t_end_ms-t_start_ms;
capture_ms = results.duration_s*1e3;

figure('Name', 'Packet arrival / end timeline', 'Color', 'w', ...
    'Position', [80 80 1100 420]);

% Top: Gantt-style bars (arrival -> end) for each packet index.
subplot(2, 1, 1); hold on;
for k = 1:n
    if fcs_pass(k)
        face = [0.20 0.60 0.90];
    else
        face = [0.90 0.45 0.20];
    end
    % Draw a horizontal bar from start to end at y = packet index.
    plot([t_start_ms(k), t_end_ms(k)], [k, k], '-', ...
        'Color', face, 'LineWidth', 6);
    plot(t_start_ms(k), k, 'o', 'MarkerFaceColor', face, ...
        'MarkerEdgeColor', 'k', 'MarkerSize', 5);
    plot(t_end_ms(k), k, 's', 'MarkerFaceColor', face, ...
        'MarkerEdgeColor', 'k', 'MarkerSize', 5);
end
% Invisible handles for legend.
h_start = plot(nan, nan, 'ko', 'MarkerFaceColor', [0.2 0.6 0.9]);
h_end = plot(nan, nan, 'ks', 'MarkerFaceColor', [0.2 0.6 0.9]);
h_ok = plot(nan, nan, '-', 'Color', [0.20 0.60 0.90], 'LineWidth', 4);
h_bad = plot(nan, nan, '-', 'Color', [0.90 0.45 0.20], 'LineWidth', 4);
xlim([0, max(capture_ms, max(t_end_ms)*1.02)]);
ylim([0.5, n+0.5]);
set(gca, 'YDir', 'reverse');
yticks(1:n);
xlabel('Time (ms)');
ylabel('Packet index');
title(sprintf('Packet arrival / end timeline (%d packets, capture %.3f ms)', ...
    n, capture_ms));
legend([h_start, h_end, h_ok, h_bad], ...
    {'Arrival (start)', 'End', 'FCS pass', 'FCS fail'}, ...
    'Location', 'eastoutside');
grid on; box on;

% Bottom: stem of arrival times + overlay end markers on one time axis.
subplot(2, 1, 2); hold on;
stem(t_start_ms, ones(n, 1), 'filled', 'Color', [0.20 0.60 0.90], ...
    'LineWidth', 1.2, 'MarkerSize', 5, 'DisplayName', 'Arrival');
stem(t_end_ms, 0.7*ones(n, 1), 'filled', 'Color', [0.90 0.45 0.20], ...
    'LineWidth', 1.0, 'MarkerSize', 4, 'DisplayName', 'End');
for k = 1:n
    text(t_start_ms(k), 1.08, sprintf('#%d', k), ...
        'HorizontalAlignment', 'center', 'FontSize', 8);
end
xlim([0, max(capture_ms, max(t_end_ms)*1.02)]);
ylim([0, 1.35]);
yticks([]);
xlabel('Time (ms)');
title('Arrival and end markers on capture timeline');
legend('Location', 'eastoutside');
grid on; box on;

sgtitle(sprintf('%s — packet timing', results.file_name), 'Interpreter', 'none');

if ~isempty(png_path)
    try
        exportgraphics(gcf, png_path, 'Resolution', 150);
    catch
        saveas(gcf, png_path);
    end
    fprintf('Saved packet timeline figure: %s\n', png_path);
end

% Also leave a compact table in the base workspace.
timeline_table = table((1:n).', t_start_ms, t_end_ms, duration_ms, fcs_pass, ...
    'VariableNames', {'packet', 'start_ms', 'end_ms', 'duration_ms', 'fcs_pass'});
assignin('base', 'packet_timeline', timeline_table);
end
