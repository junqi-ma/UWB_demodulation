%% Decode all QM35 packets from a DW1000+QM35 mixed capture
% Branch: feature/two-packet-cir
%
% Same P0 pipeline as run_decode_x410_dw1000_all.m:
%   1) coarse energy + decimated preamble pre-screen over the full .dat
%   2) fine decode only at candidates (QM35 PHY profile)
%   3) keep QM35-like frames, save CIR / timeline
%
% QM35 profile matches run_decode_x410_dw1000_all / README:
%   code_index=9, preamble_repetitions=128, data_rate=6.81, sfd_mode=auto
%   (QM35 typically locks IEEE 802.15.4z SFD #2)
clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% -------------------- Input capture (mixed DW1000 + QM35) --------------------
options = struct();
options.file_name = 'F:\qm35_dw1000_1.dat';
options.ant_num = 1;
options.channel_index = 1;

%% -------------------- QM35 radio / PHY --------------------
options.fs_rx = 737.28e6;
options.x410_center_frequency = 6500e6;
options.dw1000_center_frequency = 6489.6e6;
options.preamble_repetitions = 128;
options.cir_repetitions = 64;
options.code_index = 9;
options.data_rate = 6.81;

options.sfd_mode = 'auto';
options.decawave_sfd = [-1; -1; -1; -1; 1; -1; 0; 0];
options.ieee_sfd = [0; 1; 0; -1; 1; 0; 0; -1];
options.sfd4z_1 = [-1; -1; 1; -1];
options.sfd4z_2 = [-1; -1; -1; 1; -1; -1; 1; -1];
options.sfd4z_3 = [-1; -1; -1; -1; -1; 1; 1; -1; ...
    -1; 1; -1; 1; -1; -1; 1; -1];
options.sfd4z_4 = [-1; -1; -1; -1; -1; -1; -1; 1; ...
    -1; -1; 1; -1; -1; 1; -1; 1; -1; 1; -1; -1; ...
    -1; 1; 1; -1; -1; -1; 1; -1; 1; 1; -1; -1];

options.cir_pre_samples = 8;
options.cir_post_samples = 30;
options.cir_max_path_m = [];
options.max_psdu_bytes = 32;
options.enable_frame_crop = true;
options.verbose = false;

%% -------------------- Interference cancellation --------------------
options.enable_interference_cancellation = true;
options.interference_quiet_offset = 400000;
options.interference_quiet_num = 262144;
options.interference_tone_bin = -169;
options.interference_period_samples = 512;
options.interference_coefficient = [];
options.show_plots = false;

%% -------------------- Coarse pre-screen (same idea as run_decode_*_all) --------------------
batch = struct();
batch.coarse_chunk_samples = 4e6;
batch.coarse_step_samples = 3e6;
batch.coarse_decimation = 32;
batch.energy_smooth_rx_samples = 8192;
% Slightly more sensitive coarse screen to reduce mid-file misses.
batch.energy_threshold_sigma = 5.0;
batch.use_coarse_correlation = true;
batch.corr_threshold_sigma = 4.0;
batch.candidate_merge_samples = 1.2e5;
batch.pre_packet_guard_samples = 5e4;

%% -------------------- Fine decode around candidates --------------------
batch.window_samples = 1.0e6;
batch.min_window_samples = 0.3e6;
batch.search_step_samples = 0.5e6;
batch.post_packet_guard_samples = 4096;
batch.start_tolerance_samples = 4096;
% Keep all decoder successes here; QM35 gating is applied after.
batch.require_fcs_pass = false;
batch.save_individual_cir = true;

%% -------------------- QM35 accept gates (post-filter) --------------------
qm35_gate = struct();
% Prefer IEEE 802.15.4z SFD (QM35). Set false to keep any SFD that decoded.
qm35_gate.require_4z_sfd = true;
qm35_gate.min_sfd_correlation = 0.50;
qm35_gate.require_phr_pass = true;
qm35_gate.require_fcs_pass = false;   % set true to keep only FCS-OK frames

%% -------------------- Output paths --------------------
[~, capture_stem] = fileparts(options.file_name);
batch.output_directory = fullfile(pwd, 'decoded_results', ...
    [capture_stem '_all_qm35']);
batch.mat_file = fullfile(batch.output_directory, 'all_qm35_frames_cir.mat');
batch.summary_csv = fullfile(batch.output_directory, 'qm35_frame_summary.csv');
batch.timeline_png = fullfile(batch.output_directory, 'qm35_packet_timeline.png');

%% -------------------- Full-file decode with QM35 profile --------------------
fprintf('Scanning mixed capture for QM35 packets (code=%d, SYNC=%d)...\n', ...
    options.code_index, options.preamble_repetitions);
results_raw = decode_x410_dw1000_all(options, batch);

%% -------------------- Keep only QM35-like frames --------------------
results = filterQm35Results(results_raw, qm35_gate);

% Re-save filtered results / CIR / CSV under the same output directory.
if ~isfolder(batch.output_directory)
    mkdir(batch.output_directory);
end
save(batch.mat_file, 'results', 'results_raw', 'qm35_gate', 'options', '-v7.3');
writeQm35SummaryCsv(batch.summary_csv, results.frames);

% Optional: rewrite individual CIR files with filtered indices only.
if batch.save_individual_cir && results.packet_count > 0
    for k = 1:results.packet_count
        cir_file = fullfile(batch.output_directory, sprintf('qm35_cir_%03d.mat', k));
        cir = results.frames(k).cir; %#ok<NASGU>
        meta = results.frames(k); %#ok<NASGU>
        save(cir_file, 'cir', 'meta', '-v7.3');
    end
end

%% -------------------- Console summary --------------------
fprintf('\n========== All-QM35 decode summary (mixed capture) ==========\n');
fprintf('Capture file                 : %s\n', options.file_name);
fprintf('Total complex samples        : %d\n', results.total_samples);
fprintf('Capture duration             : %.3f ms\n', results.duration_s*1e3);
fprintf('Coarse candidates            : %d\n', results.candidate_count);
fprintf('Fine decode attempts         : %d\n', results.attempt_count);
fprintf('Raw decoded frames           : %d\n', results_raw.packet_count);
fprintf('QM35 frames kept             : %d\n', results.packet_count);
fprintf('QM35 FCS-pass                : %d\n', results.fcs_pass_count);
fprintf('Time coarse / fine           : %.1f s / %.1f s\n', ...
    results.coarse_seconds, results.fine_seconds);
fprintf('Results MAT                  : %s\n', batch.mat_file);
fprintf('Summary CSV                  : %s\n', batch.summary_csv);
fprintf('Timeline PNG                 : %s\n', batch.timeline_png);
fprintf('=============================================================\n');

if results.packet_count > 0
    for k = 1:results.packet_count
        frame = results.frames(k);
        fprintf(['#%03d  start=%.3f ms  end=%.3f ms  dur=%.3f us  ', ...
            'SFD=%s  corr=%.3f  PSDU=%d B  FCS=%d\n'], ...
            k, frame.time_start_s*1e3, frame.time_end_s*1e3, ...
            (frame.time_end_s-frame.time_start_s)*1e6, ...
            frame.sfd_name, frame.sfd_correlation, ...
            frame.psdu_length_bytes, frame.fcs_pass);
    end
    plotPacketTimeline(results, batch.timeline_png);
else
    fprintf('No QM35 packets kept after gating; timeline skipped.\n');
end

assignin('base', 'qm35_all_results', results);
assignin('base', 'qm35_all_results_raw', results_raw);

%% ------------------------------------------------------------------------
function results = filterQm35Results(results_raw, gate)
results = results_raw;
if results_raw.packet_count == 0
    results.packet_count = 0;
    results.fcs_pass_count = 0;
    results.frames = results_raw.frames;
    results.cir_values = [];
    results.cir_delay_ns = [];
    return;
end

keep = false(results_raw.packet_count, 1);
for k = 1:results_raw.packet_count
    frame = results_raw.frames(k);
    name = lower(string(frame.sfd_name));
    is_4z = contains(name, "4z") || contains(name, "802.15.4z");
    ok = true;
    if gate.require_4z_sfd
        ok = ok && is_4z;
    end
    if gate.require_phr_pass
        ok = ok && logical(frame.phr_secded_pass);
    end
    if gate.require_fcs_pass
        ok = ok && logical(frame.fcs_pass);
    end
    ok = ok && (frame.sfd_correlation >= gate.min_sfd_correlation);
    keep(k) = ok;
end

idx = find(keep);
n = numel(idx);
if n == 0
    empty = results_raw.frames([]);
    results.frames = empty;
    results.packet_count = 0;
    results.fcs_pass_count = 0;
    results.cir_values = [];
    results.cir_delay_ns = [];
    fprintf('Post-filter: kept 0 / %d frames as QM35.\n', results_raw.packet_count);
    return;
end

frames = results_raw.frames(idx);
for k = 1:n
    frames(k).index = k;
end
results.frames = frames;
results.packet_count = n;
results.fcs_pass_count = sum([frames.fcs_pass]);

if ~isempty(results_raw.cir_delay_ns)
    results.cir_delay_ns = results_raw.cir_delay_ns(:);
    cir_len = numel(results.cir_delay_ns);
    results.cir_values = complex(zeros(cir_len, n));
    for k = 1:n
        values = frames(k).cir.values(:);
        m = min(cir_len, numel(values));
        results.cir_values(1:m, k) = values(1:m);
    end
else
    results.cir_delay_ns = [];
    results.cir_values = [];
end

fprintf('Post-filter: kept %d / %d frames as QM35', n, results_raw.packet_count);
if gate.require_4z_sfd
    fprintf(' (require 4z SFD)');
end
fprintf('.\n');
end

function writeQm35SummaryCsv(csv_file, frames)
fid = fopen(csv_file, 'w');
if fid < 0
    warning('Could not write %s', csv_file);
    return;
end
cleanup_obj = onCleanup(@() fclose(fid));
fprintf(fid, ['index,abs_start_sample,abs_end_sample,time_start_ms,time_end_ms,', ...
    'sfd_name,sfd_correlation,phr_secded_pass,psdu_length_bytes,', ...
    'fcs_received,fcs_calculated,fcs_pass,payload_hex\n']);
for k = 1:numel(frames)
    f = frames(k);
    if isempty(f.payload_bytes)
        payload_hex = '';
    else
        payload_hex = sprintf('%02X', f.payload_bytes);
    end
    fprintf(fid, ['%d,%d,%d,%.6f,%.6f,"%s",%.6f,%d,%d,0x%04X,0x%04X,%d,"%s"\n'], ...
        f.index, f.abs_start_sample, f.abs_end_sample, ...
        f.time_start_s*1e3, f.time_end_s*1e3, f.sfd_name, f.sfd_correlation, ...
        f.phr_secded_pass, f.psdu_length_bytes, f.fcs_received, ...
        f.fcs_calculated, f.fcs_pass, payload_hex);
end
clear cleanup_obj;
end

function plotPacketTimeline(results, png_path)
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
duration_ms = t_end_ms - t_start_ms;
capture_ms = results.duration_s*1e3;

figure('Name', 'QM35 packet arrival / end timeline', 'Color', 'w', ...
    'Position', [80 80 1100 420]);

subplot(2, 1, 1); hold on;
for k = 1:n
    if fcs_pass(k)
        face = [0.20 0.60 0.90];
    else
        face = [0.90 0.45 0.20];
    end
    plot([t_start_ms(k), t_end_ms(k)], [k, k], '-', ...
        'Color', face, 'LineWidth', 6);
    plot(t_start_ms(k), k, 'o', 'MarkerFaceColor', face, ...
        'MarkerEdgeColor', 'k', 'MarkerSize', 5);
    plot(t_end_ms(k), k, 's', 'MarkerFaceColor', face, ...
        'MarkerEdgeColor', 'k', 'MarkerSize', 5);
end
h_start = plot(nan, nan, 'ko', 'MarkerFaceColor', [0.2 0.6 0.9]);
h_end = plot(nan, nan, 'ks', 'MarkerFaceColor', [0.2 0.6 0.9]);
h_ok = plot(nan, nan, '-', 'Color', [0.20 0.60 0.90], 'LineWidth', 4);
h_bad = plot(nan, nan, '-', 'Color', [0.90 0.45 0.20], 'LineWidth', 4);
xlim([0, max(capture_ms, max(t_end_ms)*1.02)]);
ylim([0.5, n+0.5]);
set(gca, 'YDir', 'reverse');
yticks(1:max(1, n));
xlabel('Time (ms)');
ylabel('QM35 packet index');
title(sprintf('QM35 packets (%d kept, capture %.3f ms)', n, capture_ms));
legend([h_start, h_end, h_ok, h_bad], ...
    {'Arrival', 'End', 'FCS pass', 'FCS fail'}, 'Location', 'eastoutside');
grid on; box on;

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
title('QM35 arrival / end on capture timeline');
legend('Location', 'eastoutside');
grid on; box on;

sgtitle(sprintf('%s — all QM35 packets', results.file_name), ...
    'Interpreter', 'none');

if ~isempty(png_path)
    try
        exportgraphics(gcf, png_path, 'Resolution', 150);
    catch
        saveas(gcf, png_path);
    end
    fprintf('Saved QM35 timeline figure: %s\n', png_path);
end

timeline_table = table((1:n).', t_start_ms, t_end_ms, duration_ms, fcs_pass, ...
    'VariableNames', {'packet', 'start_ms', 'end_ms', 'duration_ms', 'fcs_pass'});
assignin('base', 'qm35_packet_timeline', timeline_table);
end
