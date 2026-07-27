%% Visualize the full-file decode results produced by run_decode_uwb_all.m.
% Loads decoded_results/<capture_stem>/all_frames_cir.mat, then produces:
%   Figure 1: packet timeline (Gantt + arrival markers)
%   Figure 2: per-packet metric summary (CFO, clock error, SFD corr, etc.)
%   Figure 3: CIR overlay for every decoded packet
%
% Figures are rendered at screen resolution and saved as PNG. To keep the
% UI responsive, all plots use lightweight primitives (no stem, no imagesc
% on oversized CIR matrices, no per-packet detail pages).
clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% 0. User configuration
% Capture stem used by run_decode_uwb_all.m (file_name without extension).
capture_stem = 'qm35_dw1000_1';

% phy_profile must match what was used in run_decode_uwb_all.m.
phy_profile = 'QM35';   % 'DW1000' or 'QM35'

% Figure output.
save_figures = true;
figure_resolution_dpi = 100;   % 100 is plenty for screen / quick iteration.

% CIR heatmap downsample: max packets shown on the heatmap x-axis and max
% taps on the y-axis. The decoder CIR is usually ~40 taps, so this only
% matters for very long captures with many packets.
max_heatmap_packets = 200;
max_heatmap_taps = 128;

% -------------------------------------------------------------------------
% Auto-generated paths.
% -------------------------------------------------------------------------
scan_file = fullfile(project_dir, 'decoded_results', capture_stem, ...
    'all_frames_cir.mat');
output_dir = fullfile(project_dir, 'decoded_results', capture_stem, ...
    'visualize');

switch upper(phy_profile)
    case 'DW1000'
        profile_tag = 'dw1000';
        expected_code_index = 10;
    case 'QM35'
        profile_tag = 'qm35';
        expected_code_index = 9;
    otherwise
        error('phy_profile must be ''DW1000'' or ''QM35''.');
end

%% 1. Load and validate
if ~isfile(scan_file)
    error('visualize_decode_uwb_all:ScanNotFound', ...
        'Decode result not found: %s', scan_file);
end

saved = load(scan_file, 'results');
if ~isfield(saved, 'results') || ~isfield(saved.results, 'frames')
    error('visualize_decode_uwb_all:InvalidScan', ...
        'The MAT file does not contain results.frames.');
end
results = saved.results;
frames = results.frames;

if numel(frames) == 0
    error('visualize_decode_uwb_all:NoFrames', ...
        'The decode result contains no packets to visualize.');
end

if isfield(results.params, 'code_index') && ...
        results.params.code_index ~= expected_code_index
    warning('visualize_decode_uwb_all:CodeMismatch', ...
        'Selected %s (code %d) but decode used code %d.', ...
        phy_profile, expected_code_index, results.params.code_index);
end

fs_rx = results.params.fs_rx;
total_samples = results.total_samples;
capture_ms = results.duration_s * 1e3;

if save_figures && ~isfolder(output_dir)
    mkdir(output_dir);
end

n_packets = numel(frames);
t_start_ms = [frames.time_start_s].' * 1e3;
t_end_ms = [frames.time_end_s].' * 1e3;
dur_ms = t_end_ms - t_start_ms;
fcs_pass = logical([frames.fcs_pass].');
sfd_corr = [frames.sfd_correlation].';
cfo_khz = [frames.carrier_frequency_offset_hz].' / 1e3;
clk_ppm = [frames.sample_clock_error_ppm].';
psdu_len = [frames.psdu_length_bytes].';
sfd_names = {frames.sfd_name}.';

fprintf('Loaded %d decoded packets from: %s\n', n_packets, scan_file);
fprintf('Capture: %d samples | %.3f ms @ %.3f MHz\n', ...
    total_samples, capture_ms, fs_rx / 1e6);
fprintf('FCS-pass: %d / %d\n', sum(fcs_pass), n_packets);

%% 2. Figure 1: packet timeline
% Draw all Gantt bars in a single plot call using NaN-separated line
% segments. This keeps the object count at O(1) instead of O(N).
fig1 = figure('Name', sprintf('%s decode: packet timeline', profile_tag), ...
    'Color', 'w', 'Position', [60 60 1100 460]);

% Build NaN-separated segment arrays: [x1 NaN x2 NaN x3 ...]
seg_x = zeros(1, n_packets * 3);
seg_y = zeros(1, n_packets * 3);
for k = 1:n_packets
    base = (k - 1) * 3 + 1;
    seg_x(base) = t_start_ms(k);
    seg_x(base + 1) = t_end_ms(k);
    seg_x(base + 2) = NaN;
    seg_y(base:base + 1) = k;
    seg_y(base + 2) = NaN;
end

% Adaptive line width: thin bars when there are many packets so they don't
% merge into a black blob.
if n_packets <= 20
    bar_lw = 5;
elseif n_packets <= 80
    bar_lw = 3;
else
    bar_lw = 1;
end

% Color bars by FCS pass/fail using a two-pass trick: draw all in one color,
% then overlay the other. Simpler: use a single color and rely on markers.
subplot(2, 1, 1); hold on;
if any(fcs_pass)
    plot(seg_x, seg_y, '-', 'Color', [0.20 0.60 0.90], 'LineWidth', bar_lw);
end
% Overlay FCS-fail bars in a second pass.
if any(~fcs_pass)
    fail_x = zeros(1, n_packets * 3);
    fail_y = zeros(1, n_packets * 3);
    for k = find(~fcs_pass).'
        base = (k - 1) * 3 + 1;
        fail_x(base) = t_start_ms(k);
        fail_x(base + 1) = t_end_ms(k);
        fail_x(base + 2) = NaN;
        fail_y(base:base + 1) = k;
        fail_y(base + 2) = NaN;
    end
    plot(fail_x, fail_y, '-', 'Color', [0.90 0.45 0.20], 'LineWidth', bar_lw);
end
% Markers: single scatter call each.
plot(t_start_ms, 1:n_packets, 'o', 'MarkerFaceColor', [0.20 0.60 0.90], ...
    'MarkerEdgeColor', 'k', 'MarkerSize', 3);
plot(t_end_ms, 1:n_packets, 's', 'MarkerFaceColor', [0.20 0.60 0.90], ...
    'MarkerEdgeColor', 'k', 'MarkerSize', 3);
h_ok = plot(nan, nan, '-', 'Color', [0.20 0.60 0.90], 'LineWidth', 4);
h_bad = plot(nan, nan, '-', 'Color', [0.90 0.45 0.20], 'LineWidth', 4);
xlim([0, max(capture_ms, max(t_end_ms) * 1.02)]);
ylim([0.5, n_packets + 0.5]);
set(gca, 'YDir', 'reverse');
% Show at most ~20 y-ticks to avoid overlap when there are many packets.
max_yticks = 20;
if n_packets <= max_yticks
    yticks(1:n_packets);
else
    yticks(round(linspace(1, n_packets, max_yticks)));
end
xlabel('Time (ms)');
ylabel('Packet index');
title(sprintf('%s packet timeline (%d packets, capture %.3f ms)', ...
    profile_tag, n_packets, capture_ms));
legend([h_ok, h_bad], {'FCS pass', 'FCS fail'}, 'Location', 'eastoutside');
grid on; box on;

% Bottom: arrival / end markers. Limit text labels to avoid clutter.
subplot(2, 1, 2); hold on;
plot(t_start_ms, ones(n_packets, 1), 'o', ...
    'Color', [0.20 0.60 0.90], 'MarkerFaceColor', [0.20 0.60 0.90], ...
    'MarkerSize', 5, 'DisplayName', 'Arrival');
plot(t_end_ms, 0.7 * ones(n_packets, 1), 's', ...
    'Color', [0.90 0.45 0.20], 'MarkerFaceColor', [0.90 0.45 0.20], ...
    'MarkerSize', 4, 'DisplayName', 'End');
max_labels = 50;
if n_packets <= max_labels
    for k = 1:n_packets
        text(t_start_ms(k), 1.08, sprintf('#%d', k), ...
            'HorizontalAlignment', 'center', 'FontSize', 7);
    end
end
xlim([0, max(capture_ms, max(t_end_ms) * 1.02)]);
ylim([0, 1.35]);
yticks([]);
xlabel('Time (ms)');
title('Arrival and end markers on capture timeline');
legend('Location', 'eastoutside');
grid on; box on;

sgtitle(sprintf('%s decode: %s', profile_tag, results.file_name), ...
    'Interpreter', 'none');

drawnow;

%% 3. Figure 2: per-packet metric summary
fig2 = figure('Name', sprintf('%s decode: per-packet metrics', profile_tag), ...
    'Color', 'w', 'Position', [60 60 1100 700]);

packet_idx = (1:n_packets).';

subplot(2, 3, 1);
bar(packet_idx, sfd_corr, 'FaceColor', [0.20 0.60 0.90]);
grid on; xlabel('Packet index'); ylabel('SFD correlation');
title('SFD correlation'); ylim([0 1.1]);

subplot(2, 3, 2);
bar(packet_idx, cfo_khz, 'FaceColor', [0.90 0.45 0.20]);
grid on; xlabel('Packet index'); ylabel('CFO (kHz)');
title('Carrier frequency offset');

subplot(2, 3, 3);
bar(packet_idx, clk_ppm, 'FaceColor', [0.30 0.70 0.40]);
grid on; xlabel('Packet index'); ylabel('Clock error (ppm)');
title('Sample clock error');

subplot(2, 3, 4);
bar(packet_idx, psdu_len, 'FaceColor', [0.55 0.35 0.75]);
grid on; xlabel('Packet index'); ylabel('PSDU (bytes)');
title('PSDU length');

subplot(2, 3, 5);
bar(packet_idx, dur_ms, 'FaceColor', [0.10 0.55 0.65]);
grid on; xlabel('Packet index'); ylabel('Duration (ms)');
title('Packet duration');

subplot(2, 3, 6);
fcs_ok_count = sum(fcs_pass);
fcs_fail_count = n_packets - fcs_ok_count;
% pie() returns patch/text handles. Set colors manually because pie ignores
% the axes colormap.
h_pie = pie([fcs_ok_count, fcs_fail_count], ...
    {sprintf('FCS pass (%d)', fcs_ok_count), ...
     sprintf('FCS fail (%d)', fcs_fail_count)});
% h_pie alternates patch/text handles: 1=patch1, 2=text1, 3=patch2, ...
pie_colors = [0.20 0.60 0.90; 0.90 0.45 0.20];
for i = 1:2:numel(h_pie)
    set(h_pie(i), 'FaceColor', pie_colors((i + 1) / 2, :));
end
title('FCS pass / fail');

sgtitle(sprintf('%s decode: per-packet metrics (%d packets)', ...
    profile_tag, n_packets), 'Interpreter', 'none');

drawnow;

%% 4. Figure 3: CIR overlay
fig3 = figure('Name', sprintf('%s decode: CIR overlay', profile_tag), ...
    'Color', 'w', 'Position', [60 60 1100 520]);

% Collect CIRs into a matrix.
cir0 = frames(1).cir;
delay_ns = cir0.delay_ns(:);
n_taps = numel(delay_ns);
cir_matrix = zeros(n_taps, n_packets);
for k = 1:n_packets
    v = frames(k).cir.values(:);
    n = min(n_taps, numel(v));
    cir_matrix(1:n, k) = v(1:n);
end

mag = abs(cir_matrix);
mag_n = mag ./ (max(mag, [], 1) + eps);
mag_db = 20 * log10(max(mag_n, 1e-4));

% Downsample for the heatmap if needed.
if n_packets > max_heatmap_packets
    pkt_idx = round(linspace(1, n_packets, max_heatmap_packets));
    heatmap_data = mag_db(:, pkt_idx);
    heatmap_x = packet_idx(pkt_idx);
else
    heatmap_data = mag_db;
    heatmap_x = packet_idx;
end
if n_taps > max_heatmap_taps
    tap_idx = round(linspace(1, n_taps, max_heatmap_taps));
    heatmap_data = heatmap_data(tap_idx, :);
    heatmap_y = delay_ns(tap_idx);
else
    heatmap_y = delay_ns;
end

subplot(1, 2, 1);
imagesc(heatmap_x, heatmap_y, heatmap_data);
axis xy;
colorbar;
xlabel('Packet index');
ylabel('Relative delay (ns)');
title('CIR magnitude (dB, peak-normalized)');
clim([-60 5]);
colormap(gca, parula);

subplot(1, 2, 2); hold on;
for k = 1:n_packets
    plot(delay_ns, mag_n(:, k), '-', 'LineWidth', 0.7);
end
xline(0, 'k--', 'Nominal zero delay');
grid on;
xlabel('Relative delay (ns)');
ylabel('Normalized |CIR|');
title('CIR overlay (all packets)');

sgtitle(sprintf('%s decode: CIR overlay (%d packets, %d taps)', ...
    profile_tag, n_packets, n_taps), 'Interpreter', 'none');

drawnow;

%% 5. Save figures
if save_figures
    fprintf('Saving figures to %s ...\n', output_dir);
    savefast(fig1, fullfile(output_dir, 'packet_timeline.png'));
    savefast(fig2, fullfile(output_dir, 'per_packet_metrics.png'));
    savefast(fig3, fullfile(output_dir, 'cir_overlay.png'));
end

%% 6. Console summary
fprintf('\n========== %s decode visualization ==========\n', profile_tag);
fprintf('Capture file      : %s\n', results.file_name);
fprintf('Total samples     : %d (%.3f ms)\n', total_samples, capture_ms);
fprintf('Decoded packets   : %d\n', n_packets);
fprintf('FCS-pass packets  : %d\n', sum(fcs_pass));
fprintf('Decode wall time  : %.1f s (energy) / %.1f s (corr) / %.1f s (fine)\n', ...
    results.energy_seconds, results.correlation_seconds, results.fine_seconds);
fprintf('CFO range         : %.3f .. %.3f kHz\n', min(cfo_khz), max(cfo_khz));
fprintf('Clock error range : %.3f .. %.3f ppm\n', min(clk_ppm), max(clk_ppm));
fprintf('SFD corr range    : %.4f .. %.4f\n', min(sfd_corr), max(sfd_corr));
if save_figures
    fprintf('Figures saved to  : %s\n', output_dir);
end
fprintf('=============================================================\n');

timeline_table = table(packet_idx, t_start_ms, t_end_ms, dur_ms, ...
    fcs_pass, sfd_corr, cfo_khz, clk_ppm, psdu_len, sfd_names, ...
    'VariableNames', {'packet', 'start_ms', 'end_ms', 'duration_ms', ...
    'fcs_pass', 'sfd_correlation', 'cfo_khz', 'clock_ppm', ...
    'psdu_bytes', 'sfd_name'});
assignin('base', 'decode_timeline', timeline_table);

%% ------------------------------------------------------------------------
function savefast(fig, png_path)
%SAVEFAST Save a figure as PNG quickly. Try exportgraphics first, fall back
% to saveas if the exportgraphics call fails (e.g. no OpenGL support).
try
    exportgraphics(fig, png_path, 'Resolution', 100);
catch
    try
        saveas(fig, png_path);
    catch ME
        fprintf('  (failed to save %s: %s)\n', png_path, ME.message);
    end
end
end
