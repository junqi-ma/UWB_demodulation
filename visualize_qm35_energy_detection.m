%% Visualize the Stage-1 energy detector for the current QM35 capture
% This script starts from the detector in decode_uwb_all.m, then applies
% experimental boundary fixes without changing the production decoder:
% minimum dB margins reject ~47 dB nuisance energy, raw regions are merged
% before guards are added, and neighboring guards retain separate packet
% identities. The figures make these candidate changes easy to inspect.

clear;
close all;
clc;

%% -------------------- Current QM35 configuration --------------------
capture_file = 'F:\UWB基带数据\qm35_dw1000_new_3.dat';
fs_rx = 737.28e6;
ant_num = 1;
channel_index = 1;

enable_interference_cancellation = true;
interference_quiet_offset = 400000;
interference_quiet_num = 262144;
interference_tone_bin = -169;
interference_period_samples = 512;

energy_chunk_samples = 20e6;
energy_step_samples = 19e6;
energy_read_stride = 100;
energy_smooth_rx_samples = 8192;
energy_baseline_fraction = 0.30;
energy_threshold_sigma_high = 6;
energy_threshold_sigma_low = 3;
% Experimental boundary fix: the MAD can be very small, making the
% original thresholds fall below the observed ~47 dB nuisance energy.
% Enforce minimum power margins relative to each chunk's baseline median.
energy_threshold_margin_db_high = 6;
energy_threshold_margin_db_low = 4;
energy_min_region_samples = 3e4;
% Experimental guard fix: use smaller search margins. Guarded windows are
% built only after raw regions are merged, and adjacent windows are clipped
% at their midpoint instead of being merged into one packet.
energy_region_pre_guard_samples = 1.5e4;
energy_region_post_guard_samples = 2.5e4;
energy_region_merge_samples = 1e4;

% Plotting only: retain every Nth sparse energy point in the overview.
% Detection still uses every strided sample.
overview_plot_decimation = 10;
max_zoom_regions = 6;
save_figures = true;

%% -------------------- Validate capture and estimate tone --------------------
if ~isfile(capture_file)
    error('visualize_qm35_energy_detection:FileNotFound', ...
        'Cannot find capture: %s', capture_file);
end

c = uwbdecoder.constants();
file_info = dir(capture_file);
total_samples = floor(file_info.bytes / ...
    (c.BYTES_PER_IQ_SAMPLE * ant_num));
duration_s = total_samples / fs_rx;

tone_coefficient = complex(0); %#ok<NASGU>
if enable_interference_cancellation
    quiet_num = min(interference_quiet_num, ...
        total_samples - interference_quiet_offset);
    raw_quiet = uwbdecoder.readIqRaw(capture_file, ...
        interference_quiet_offset, quiet_num, ant_num);
    rx_quiet = uwbdecoder.selectIqChannel(raw_quiet, channel_index);
    quiet_indices = interference_quiet_offset + ...
        (0:numel(rx_quiet) - 1).';
    quiet_basis = uwbdecoder.synchronousTone(quiet_indices, ...
        interference_tone_bin, interference_period_samples);
    tone_coefficient = mean(rx_quiet .* conj(quiet_basis));
    clear raw_quiet rx_quiet quiet_indices quiet_basis;
end

fprintf('QM35 energy scan: %.3f million samples (%.3f ms)\n', ...
    total_samples / 1e6, duration_s * 1e3);
fprintf('Sparse read stride: %d; effective energy rate: %.3f MHz\n', ...
    energy_read_stride, fs_rx / energy_read_stride / 1e6);

%% -------------------- Reproduce Stage-1 detection --------------------
raw_regions = zeros(0, 2);
chunk_stats = struct('offset', {}, 'last_sample', {}, ...
    'energy_median', {}, 'robust_sigma', {}, 'threshold_high', {}, ...
    'threshold_low', {}, 'raw_region_count', {});

overview_sample = zeros(0, 1);
overview_energy = zeros(0, 1);
overview_high = zeros(0, 1);
overview_low = zeros(0, 1);

diagnostic = struct();
best_diagnostic_score = [-Inf, -Inf];
offset = 0;
chunk_index = 0;
estimated_chunks = ceil(total_samples / energy_step_samples);

while offset < total_samples
    chunk_samples = min(energy_chunk_samples, total_samples - offset);
    chunk_last = offset + chunk_samples - 1;
    chunk_index = chunk_index + 1;

    [raw, sample_indices] = uwbdecoder.readIqRawStrided( ...
        capture_file, offset, chunk_samples, ant_num, energy_read_stride);
    rx = uwbdecoder.selectIqChannel(raw, channel_index);
    clear raw;

    if enable_interference_cancellation
        tone_basis = uwbdecoder.synchronousTone(sample_indices, ...
            interference_tone_bin, interference_period_samples);
        rx = rx - tone_coefficient .* tone_basis;
    end
    rx = rx - mean(rx);

    sparse_smooth_length = max(3, round( ...
        energy_smooth_rx_samples / energy_read_stride));
    instantaneous_energy = abs(rx).^2;
    smoothed_energy = movmean(instantaneous_energy, sparse_smooth_length);

    sorted_energy = sort(smoothed_energy);
    baseline_count = max(32, floor( ...
        energy_baseline_fraction * numel(sorted_energy)));
    baseline_count = min(baseline_count, numel(sorted_energy));
    baseline_energy = sorted_energy(1:baseline_count);
    energy_median = median(baseline_energy);
    energy_sigma = 1.4826 * median(abs( ...
        baseline_energy - energy_median));
    robust_sigma = max(energy_sigma, ...
        eps(max(abs(energy_median), 1)));
    adaptive_threshold_high = energy_median + ...
        energy_threshold_sigma_high * robust_sigma;
    adaptive_threshold_low = energy_median + ...
        energy_threshold_sigma_low * robust_sigma;
    margin_threshold_high = energy_median * ...
        10^(energy_threshold_margin_db_high / 10);
    margin_threshold_low = energy_median * ...
        10^(energy_threshold_margin_db_low / 10);
    threshold_high = max(adaptive_threshold_high, ...
        margin_threshold_high);
    threshold_low = max(adaptive_threshold_low, ...
        margin_threshold_low);

    local_regions = findHysteresisRegions(smoothed_energy, ...
        sample_indices, threshold_high, threshold_low, ...
        energy_read_stride, energy_min_region_samples, chunk_last);
    raw_regions = [raw_regions; local_regions]; %#ok<AGROW>

    chunk_stats(chunk_index).offset = offset;
    chunk_stats(chunk_index).last_sample = chunk_last;
    chunk_stats(chunk_index).energy_median = energy_median;
    chunk_stats(chunk_index).robust_sigma = robust_sigma;
    chunk_stats(chunk_index).threshold_high = threshold_high;
    chunk_stats(chunk_index).threshold_low = threshold_low;
    chunk_stats(chunk_index).raw_region_count = size(local_regions, 1);

    plot_idx = 1:overview_plot_decimation:numel(sample_indices);
    overview_sample = [overview_sample; sample_indices(plot_idx); NaN]; ...
        %#ok<AGROW>
    overview_energy = [overview_energy; smoothed_energy(plot_idx); NaN]; ...
        %#ok<AGROW>
    overview_high = [overview_high; ...
        repmat(threshold_high, numel(plot_idx), 1); NaN]; %#ok<AGROW>
    overview_low = [overview_low; ...
        repmat(threshold_low, numel(plot_idx), 1); NaN]; %#ok<AGROW>

    peak_margin = max(smoothed_energy) / max(threshold_high, eps);
    diagnostic_score = [size(local_regions, 1), peak_margin];
    if isBetterScore(diagnostic_score, best_diagnostic_score)
        best_diagnostic_score = diagnostic_score;
        diagnostic.chunk_index = chunk_index;
        diagnostic.sample_indices = sample_indices;
        diagnostic.instantaneous_energy = instantaneous_energy;
        diagnostic.smoothed_energy = smoothed_energy;
        diagnostic.baseline_energy = baseline_energy;
        diagnostic.energy_median = energy_median;
        diagnostic.robust_sigma = robust_sigma;
        diagnostic.threshold_high = threshold_high;
        diagnostic.threshold_low = threshold_low;
        diagnostic.local_regions = local_regions;
    end

    fprintf('\rScanning chunk %d/%d (%5.1f%%)', chunk_index, ...
        estimated_chunks, 100 * chunk_last / max(total_samples - 1, 1));

    if chunk_last >= total_samples - 1
        break;
    end
    offset = offset + energy_step_samples;
end
fprintf('\n');

raw_regions_merged = mergeIntervals(raw_regions, ...
    energy_region_merge_samples);
final_regions = addIndependentGuards(raw_regions_merged, ...
    energy_region_pre_guard_samples, ...
    energy_region_post_guard_samples, total_samples);
raw_coverage = intervalCoverage(raw_regions_merged, total_samples);
final_coverage = intervalCoverage(final_regions, total_samples);

%% -------------------- Figure 1: full-capture overview --------------------
time_ms = overview_sample / fs_rx * 1e3;
energy_db = 10 * log10(overview_energy + eps);
high_db = 10 * log10(overview_high + eps);
low_db = 10 * log10(overview_low + eps);

fig_overview = figure('Name', 'QM35 energy detector - overview', ...
    'Color', 'w', 'Position', [80, 80, 1500, 780]);
tiledlayout(2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

ax1 = nexttile;
plot(time_ms, energy_db, 'Color', [0.15, 0.35, 0.75], ...
    'LineWidth', 0.7);
hold on;
plot(time_ms, high_db, 'r-', 'LineWidth', 1.0);
plot(time_ms, low_db, 'Color', [0.95, 0.55, 0.05], ...
    'LineWidth', 1.0);
grid on;
xlim([0, duration_s * 1e3]);
xlabel('Capture time (ms)');
ylabel('Smoothed energy (dB)');
title('Step 1-3: sparse read, moving-average energy, robust thresholds');
legend('Smoothed energy', 'High threshold', 'Low threshold', ...
    'Location', 'best');

ax2 = nexttile;
hold on;
if isempty(raw_regions_merged)
    plot([0, duration_s * 1e3], [1, 1], 'Color', [0.7, 0.7, 0.7]);
else
    drawRegionBars(raw_regions_merged, fs_rx, 1, ...
        [0.95, 0.65, 0.15], 'Raw hysteresis regions');
end
if isempty(final_regions)
    plot([0, duration_s * 1e3], [0, 0], 'Color', [0.7, 0.7, 0.7]);
else
    drawRegionBars(final_regions, fs_rx, 0, ...
        [0.20, 0.65, 0.30], 'Guarded + merged regions');
end
xlim([0, duration_s * 1e3]);
ylim([-0.55, 1.55]);
yticks([0, 1]);
yticklabels({'Final', 'Raw'});
grid on;
xlabel('Capture time (ms)');
title(['Step 4-6: hysteresis runs, raw-region merging, then ', ...
    'independent midpoint-clipped guards']);

sgtitle(sprintf(['QM35 Stage-1 energy detection | %d final regions | ', ...
    'coverage %.1f%% raw, %.1f%% final | stride %d | ', ...
    'smooth %d samples | min margins %.1f/%.1f dB'], ...
    size(final_regions, 1), 100 * raw_coverage, 100 * final_coverage, ...
    energy_read_stride, ...
    energy_smooth_rx_samples, energy_threshold_margin_db_high, ...
    energy_threshold_margin_db_low));
linkaxes([ax1, ax2], 'x');

%% -------------------- Figure 2: decision mechanics --------------------
d = diagnostic;
d_time_ms = d.sample_indices / fs_rx * 1e3;
d_inst_db = 10 * log10(d.instantaneous_energy + eps);
d_smooth_db = 10 * log10(d.smoothed_energy + eps);
d_high_db = 10 * log10(d.threshold_high + eps);
d_low_db = 10 * log10(d.threshold_low + eps);
high_mask = d.smoothed_energy > d.threshold_high;
low_mask = d.smoothed_energy > d.threshold_low;

fig_diagnostic = figure('Name', 'QM35 energy detector - mechanics', ...
    'Color', 'w', 'Position', [110, 60, 1500, 900]);
tiledlayout(2, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

nexttile;
plot(d_time_ms, d_inst_db, 'Color', [0.75, 0.75, 0.75]);
hold on;
plot(d_time_ms, d_smooth_db, 'b-', 'LineWidth', 1.0);
yline(d_high_db, 'r-', 'High');
yline(d_low_db, '-', 'Low', 'Color', [0.95, 0.55, 0.05]);
grid on;
xlabel('Capture time (ms)');
ylabel('Energy (dB)');
title(sprintf('Representative chunk %d: energy before/after smoothing', ...
    d.chunk_index));
legend('Instantaneous', 'Smoothed', 'High threshold', ...
    'Low threshold', 'Location', 'best');

nexttile;
histogram(10 * log10(d.smoothed_energy + eps), 160, ...
    'FaceColor', [0.25, 0.45, 0.80], 'EdgeColor', 'none');
hold on;
xline(10 * log10(d.energy_median + eps), 'k-', ...
    'Baseline median', 'LineWidth', 1.2);
xline(d_high_db, 'r-', 'High', 'LineWidth', 1.2);
xline(d_low_db, '-', 'Low', 'Color', [0.95, 0.55, 0.05], ...
    'LineWidth', 1.2);
grid on;
xlabel('Smoothed energy (dB)');
ylabel('Count');
title(sprintf('Lowest %.0f%% defines the robust noise baseline', ...
    energy_baseline_fraction * 100));

nexttile;
stairs(d_time_ms, double(low_mask), 'Color', [0.95, 0.55, 0.05], ...
    'LineWidth', 1.0);
hold on;
stairs(d_time_ms, 1.15 * double(high_mask), 'r-', 'LineWidth', 1.0);
ylim([-0.1, 1.35]);
yticks([0, 1, 1.15]);
yticklabels({'Off', 'Low crossed', 'High crossed'});
grid on;
xlabel('Capture time (ms)');
title('A retained run must exceed Low and contain a High crossing');

nexttile;
plot(d_time_ms, d_smooth_db, 'b-', 'LineWidth', 0.9);
hold on;
yline(d_high_db, 'r-', 'High');
yline(d_low_db, '-', 'Low', 'Color', [0.95, 0.55, 0.05]);
addRegionPatches(gca, d.local_regions, fs_rx, ...
    [0.25, 0.75, 0.35], 0.18);
grid on;
xlabel('Capture time (ms)');
ylabel('Smoothed energy (dB)');
title(sprintf('Accepted runs after %.0f-sample minimum duration', ...
    energy_min_region_samples));

sgtitle('How the QM35 energy detector makes its decision');

%% -------------------- Figure 3: detected-region zooms --------------------
zoom_count = min(max_zoom_regions, size(final_regions, 1));
fig_zoom = [];
if zoom_count > 0
    fig_zoom = figure('Name', 'QM35 energy detector - region zooms', ...
        'Color', 'w', 'Position', [140, 50, 1500, 920]);
    tiledlayout(zoom_count, 1, 'TileSpacing', 'compact', ...
        'Padding', 'compact');

    for k = 1:zoom_count
        nexttile;
        region = final_regions(k, :);
        zoom_guard = max(energy_region_pre_guard_samples, ...
            energy_region_post_guard_samples);
        view_first = max(0, region(1) - zoom_guard);
        view_last = min(total_samples - 1, region(2) + zoom_guard);
        mask = isfinite(overview_sample) & ...
            overview_sample >= view_first & overview_sample <= view_last;

        plot(overview_sample(mask) / fs_rx * 1e3, ...
            10 * log10(overview_energy(mask) + eps), ...
            'b-', 'LineWidth', 0.9);
        hold on;
        plot(overview_sample(mask) / fs_rx * 1e3, ...
            10 * log10(overview_high(mask) + eps), ...
            'r-', 'LineWidth', 0.9);
        plot(overview_sample(mask) / fs_rx * 1e3, ...
            10 * log10(overview_low(mask) + eps), ...
            '-', 'Color', [0.95, 0.55, 0.05], 'LineWidth', 0.9);
        addRegionPatches(gca, raw_regions_merged, fs_rx, ...
            [0.95, 0.65, 0.15], 0.16);
        xline(region(1) / fs_rx * 1e3, 'g--', 'Final start');
        xline(region(2) / fs_rx * 1e3, 'g--', 'Final end');
        xlim([view_first, view_last] / fs_rx * 1e3);
        grid on;
        ylabel('Energy (dB)');
        title(sprintf('Final region %d: %.6f to %.6f ms', k, ...
            region(1) / fs_rx * 1e3, region(2) / fs_rx * 1e3));
        if k == zoom_count
            xlabel('Capture time (ms)');
        end
    end
    sgtitle('First detected regions: thresholds, raw runs, and final guards');
end

%% -------------------- Save and expose results --------------------
[~, capture_stem] = fileparts(capture_file);
output_directory = fullfile(pwd, 'decoded_results', ...
    capture_stem, 'energy_detection_diagnostics');
if save_figures
    if ~isfolder(output_directory)
        mkdir(output_directory);
    end
    exportgraphics(fig_overview, fullfile(output_directory, ...
        'energy_detection_overview.png'), 'Resolution', 180);
    exportgraphics(fig_diagnostic, fullfile(output_directory, ...
        'energy_detection_mechanics.png'), 'Resolution', 180);
    if ~isempty(fig_zoom)
        exportgraphics(fig_zoom, fullfile(output_directory, ...
            'energy_detection_region_zooms.png'), 'Resolution', 180);
    end
end

energy_diagnostics = struct();
energy_diagnostics.capture_file = capture_file;
energy_diagnostics.fs_rx = fs_rx;
energy_diagnostics.total_samples = total_samples;
energy_diagnostics.tone_coefficient = tone_coefficient;
energy_diagnostics.chunk_stats = chunk_stats;
energy_diagnostics.raw_regions = raw_regions_merged;
energy_diagnostics.final_regions = final_regions;
energy_diagnostics.raw_coverage = raw_coverage;
energy_diagnostics.final_coverage = final_coverage;
energy_diagnostics.sample_index_base = 0;
energy_diagnostics.interval_end_inclusive = true;
energy_diagnostics.parameters = struct( ...
    'energy_chunk_samples', energy_chunk_samples, ...
    'energy_step_samples', energy_step_samples, ...
    'energy_read_stride', energy_read_stride, ...
    'energy_smooth_rx_samples', energy_smooth_rx_samples, ...
    'energy_baseline_fraction', energy_baseline_fraction, ...
    'energy_threshold_sigma_high', energy_threshold_sigma_high, ...
    'energy_threshold_sigma_low', energy_threshold_sigma_low, ...
    'energy_threshold_margin_db_high', ...
        energy_threshold_margin_db_high, ...
    'energy_threshold_margin_db_low', ...
        energy_threshold_margin_db_low, ...
    'energy_min_region_samples', energy_min_region_samples, ...
    'energy_region_pre_guard_samples', ...
        energy_region_pre_guard_samples, ...
    'energy_region_post_guard_samples', ...
        energy_region_post_guard_samples, ...
    'energy_region_merge_samples', energy_region_merge_samples);
assignin('base', 'qm35_energy_diagnostics', energy_diagnostics);
if ~isfolder(output_directory)
    mkdir(output_directory);
end
diagnostics_file = fullfile(output_directory, ...
    'energy_diagnostics.mat');
save(diagnostics_file, 'energy_diagnostics', '-v7');

fprintf('\n=== QM35 energy detection summary ===\n');
fprintf('Raw hysteresis regions : %d\n', size(raw_regions_merged, 1));
fprintf('Final guarded regions  : %d\n', size(final_regions, 1));
fprintf('Capture coverage        : %.2f%% raw, %.2f%% final\n', ...
    100 * raw_coverage, 100 * final_coverage);
fprintf('Representative chunk   : %d\n', diagnostic.chunk_index);
fprintf('Diagnostics MAT         : %s\n', diagnostics_file);
if save_figures
    fprintf('Figures saved to        : %s\n', output_directory);
end
fprintf('Workspace result        : qm35_energy_diagnostics\n');

%% -------------------- Local helpers --------------------
function regions = findHysteresisRegions(energy, sample_indices, ...
        high_threshold, low_threshold, stride, min_region_samples, ...
        chunk_last)
high_mask = energy > high_threshold;
low_mask = energy > low_threshold;
edges = diff([false; low_mask(:); false]);
run_starts = find(edges == 1);
run_ends = find(edges == -1) - 1;
regions = zeros(0, 2);
for k = 1:numel(run_starts)
    first = run_starts(k);
    last = run_ends(k);
    if ~any(high_mask(first:last))
        continue;
    end
    abs_first = sample_indices(first);
    abs_last = min(chunk_last, sample_indices(last) + stride - 1);
    if abs_last - abs_first + 1 < min_region_samples
        continue;
    end
    regions(end + 1, :) = [abs_first, abs_last]; %#ok<AGROW>
end
end

function merged = mergeIntervals(intervals, merge_gap)
if isempty(intervals)
    merged = zeros(0, 2);
    return;
end
intervals = sortrows(round(intervals), [1, 2]);
merged = intervals(1, :);
for k = 2:size(intervals, 1)
    if intervals(k, 1) <= merged(end, 2) + merge_gap + 1
        merged(end, 2) = max(merged(end, 2), intervals(k, 2));
    else
        merged(end + 1, :) = intervals(k, :); %#ok<AGROW>
    end
end
end

function guarded = addIndependentGuards(core_regions, pre_guard, ...
        post_guard, total_samples)
% Expand every packet core independently. If adjacent search windows would
% overlap, split the shared space at the midpoint between the two cores.
% This preserves one region per detected packet instead of merging packet
% identities merely because their search guards overlap.
if isempty(core_regions)
    guarded = zeros(0, 2);
    return;
end

guarded = core_regions;
guarded(:, 1) = max(0, guarded(:, 1) - pre_guard);
guarded(:, 2) = min(total_samples - 1, ...
    guarded(:, 2) + post_guard);

for k = 1:size(core_regions, 1) - 1
    split_sample = floor((core_regions(k, 2) + ...
        core_regions(k + 1, 1)) / 2);
    guarded(k, 2) = min(guarded(k, 2), split_sample);
    guarded(k + 1, 1) = max(guarded(k + 1, 1), ...
        split_sample + 1);
end
end

function coverage = intervalCoverage(intervals, total_samples)
if isempty(intervals)
    coverage = 0;
    return;
end
covered_samples = sum(intervals(:, 2) - intervals(:, 1) + 1);
coverage = covered_samples / max(total_samples, 1);
end

function tf = isBetterScore(score, best_score)
tf = score(1) > best_score(1) || ...
    (score(1) == best_score(1) && score(2) > best_score(2));
end

function addRegionPatches(ax, regions, fs_rx, color, alpha_value)
if isempty(regions)
    return;
end
yl = ylim(ax);
for k = 1:size(regions, 1)
    x1 = regions(k, 1) / fs_rx * 1e3;
    x2 = regions(k, 2) / fs_rx * 1e3;
    if x2 < ax.XLim(1) || x1 > ax.XLim(2)
        continue;
    end
    patch(ax, [x1, x2, x2, x1], [yl(1), yl(1), yl(2), yl(2)], ...
        color, 'FaceAlpha', alpha_value, 'EdgeColor', 'none', ...
        'HandleVisibility', 'off');
end
end

function drawRegionBars(regions, fs_rx, y, color, display_name)
first_bar = true;
for k = 1:size(regions, 1)
    x = regions(k, :) / fs_rx * 1e3;
    if first_bar
        plot(x, [y, y], '-', 'Color', color, 'LineWidth', 7, ...
            'DisplayName', display_name);
        first_bar = false;
    else
        plot(x, [y, y], '-', 'Color', color, 'LineWidth', 7, ...
            'HandleVisibility', 'off');
    end
end
end
