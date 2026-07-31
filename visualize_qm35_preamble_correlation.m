%% Visualize hybrid multi-packet full-rate QM35 preamble correlation
% The energy onset is a soft prior. A small delay window is scanned first
% with one full-rate preamble repetition. Later repetitions validate only
% the resulting candidate peaks. If no candidate passes, the search grows
% to a wider window and finally to the complete guarded energy interval.
% When enough interval remains after the first confirmed preamble, the tail
% is scanned in chunks so one merged energy interval may yield many packets.

clear;
close all;
clc;

%% -------------------- Inputs and plotting controls --------------------
capture_stem = 'qm35_dw1000_new_3';
energy_diagnostics_file = fullfile(pwd, 'decoded_results', ...
    capture_stem, 'energy_detection_diagnostics', ...
    'energy_diagnostics.mat');
detail_region_indices = 1:6;
auto_include_longest_regions = 6;
save_figures = true;

%% -------------------- Adaptive search controls --------------------
% Levels 1 and 2 are relative to the raw energy leading edge. Level 3 is
% constructed per packet from its complete guarded energy interval.
search_level_us = [-5, 12; -15, 30];
expected_candidate_offset_us = 5.2;

min_repetitions = 3;
max_repetitions = 8;
baseline_fraction = 0.60;
threshold_sigma = 5;
% Mixed DW1000 data creates locally self-normalized noise peaks with ratios
% around 3..7, while confirmed QM35 preambles are hundreds to thousands.
min_threshold_ratio = 20;
candidate_relative_level = 0.20;
candidate_min_distance_samples = 400;
require_hit_every_repetition = true;

% A confirmed packet suppresses all candidate peaks belonging to the same
% frame. The typical one-frame energy duration is learned from the shorter
% energy regions. Only substantially longer regions activate tail search.
multi_packet_search = true;
packet_exclusion_repetitions = 64;
single_region_baseline_fraction = 0.60;
long_region_threshold_factor = 1.50;
long_region_threshold_margin_us = 20;
minimum_packet_separation_fraction = 0.75;
candidate_train_gap_repetitions = 4;
tail_scan_chunk_us = 100;

if ~isfile(energy_diagnostics_file)
    error('visualize_qm35_preamble_correlation:EnergyDiagnosticsNotFound', ...
        ['Run visualize_qm35_energy_detection.m first. Missing file: ', ...
         '%s'], energy_diagnostics_file);
end

loaded = load(energy_diagnostics_file, 'energy_diagnostics');
energy_diagnostics = loaded.energy_diagnostics;
energy_regions = energy_diagnostics.final_regions;
raw_energy_regions = energy_diagnostics.raw_regions;
region_count = size(energy_regions, 1);

if region_count == 0
    error('visualize_qm35_preamble_correlation:NoEnergyRegions', ...
        'The energy detector produced no regions.');
end
if size(raw_energy_regions, 1) ~= region_count
    error('visualize_qm35_preamble_correlation:RegionCountMismatch', ...
        'Expected one raw core per guarded energy region.');
end

detail_region_indices = unique(round(detail_region_indices(:).'));
detail_region_indices = detail_region_indices( ...
    detail_region_indices >= 1 & detail_region_indices <= region_count);
raw_region_length_samples = raw_energy_regions(:, 2) - ...
    raw_energy_regions(:, 1) + 1;
[~, longest_region_order] = sort(raw_region_length_samples, 'descend');
auto_detail_count = min(auto_include_longest_regions, region_count);
detail_region_indices = unique([detail_region_indices, ...
    longest_region_order(1:auto_detail_count).']);
representative_region_index = longest_region_order(1);

%% -------------------- Current QM35 PHY and tone configuration --------------------
options = struct();
options.file_name = energy_diagnostics.capture_file;
options.fs_rx = energy_diagnostics.fs_rx;
options.ant_num = 1;
options.channel_index = 1;
options.x410_center_frequency = 6500e6;
options.dw1000_center_frequency = 6489.6e6;
options.data_rate = 6.81;
options.preamble_repetitions = 64;
options.code_index = 9;
options.sfd_mode = '4z2';
options.enable_interference_cancellation = true;
options.interference_tone_bin = -169;
options.interference_period_samples = 512;
options.interference_coefficient = ...
    energy_diagnostics.tone_coefficient;
options.show_plots = false;

params = uwbdecoder.mergeOptions( ...
    uwbdecoder.defaultOptions(), options);
addpath(params.helper_path);
reference = uwbdecoder.buildUwbReference(params);

[p, q] = rat(params.fs_rx / reference.fs, 1e-12);
preamble_template = resample(reference.preamble_waveform, p, q);
preamble_template = preamble_template(:);
preamble_template = preamble_template / ...
    (norm(preamble_template) + eps);
template_length = numel(preamble_template);
repetition_period = template_length;
packet_exclusion_samples = packet_exclusion_repetitions * ...
    repetition_period;
sorted_region_lengths = sort(raw_region_length_samples);
baseline_region_count = max(1, floor( ...
    single_region_baseline_fraction * region_count));
nominal_single_region_samples = median( ...
    sorted_region_lengths(1:baseline_region_count));
long_region_threshold_samples = max( ...
    long_region_threshold_factor * nominal_single_region_samples, ...
    nominal_single_region_samples + round( ...
    long_region_threshold_margin_us * params.fs_rx / 1e6));
packet_exclusion_samples = max(packet_exclusion_samples, round( ...
    minimum_packet_separation_fraction * ...
    nominal_single_region_samples));
tail_scan_chunk_samples = round(tail_scan_chunk_us * ...
    params.fs_rx / 1e6);
suspicious_long_region_mask = raw_region_length_samples >= ...
    long_region_threshold_samples;

search_level_samples = round(search_level_us * ...
    params.fs_rx / 1e6);
expected_offset_samples = round(expected_candidate_offset_us * ...
    params.fs_rx / 1e6);

fprintf('QM35 hybrid multi-packet correlation: %d energy regions\n', ...
    region_count);
fprintf('Full rate %.3f MHz | template/period %d samples\n', ...
    params.fs_rx / 1e6, template_length);
fprintf(['Level 1 %.1f..%.1f us | Level 2 %.1f..%.1f us | ', ...
    'Level 3 guarded interval\n'], search_level_us(1, 1), ...
    search_level_us(1, 2), search_level_us(2, 1), ...
    search_level_us(2, 2));
fprintf(['Nominal single region %.1f us | long-region threshold ', ...
    '%.1f us | minimum packet spacing %.1f us\n'], ...
    nominal_single_region_samples / params.fs_rx * 1e6, ...
    long_region_threshold_samples / params.fs_rx * 1e6, ...
    packet_exclusion_samples / params.fs_rx * 1e6);

%% -------------------- Adaptive per-region search --------------------
selected_candidates = zeros(region_count, 1);
detected_mask = false(region_count, 1);
all_selected_candidates = cell(region_count, 1);
all_detections = cell(region_count, 1);
region_packet_count = zeros(region_count, 1);
tail_search_used = false(region_count, 1);
tail_scanned_delay_count = zeros(region_count, 1);
search_level_used = zeros(region_count, 1);
repetitions_used = zeros(region_count, 1);
candidates_tested = zeros(region_count, 1);
scanned_delay_count = zeros(region_count, 1);
final_threshold_ratios = zeros(region_count, 1);
candidate_offset_from_core_us = zeros(region_count, 1);
details = cell(region_count, 1);

tic_scan = tic;
for region_index = 1:region_count
    raw_start = raw_energy_regions(region_index, 1);
    guarded = energy_regions(region_index, :);

    max_delay = max(0, energy_diagnostics.total_samples - ...
        template_length);
    level_bounds = zeros(3, 2);
    for level = 1:2
        level_bounds(level, 1) = max(0, raw_start + ...
            search_level_samples(level, 1));
        level_bounds(level, 2) = min( ...
            max_delay, raw_start + ...
            search_level_samples(level, 2));
    end
    % Ensure the final level contains all earlier levels as well as the
    % complete guarded interval.
    level_bounds(3, 1) = min(guarded(1), level_bounds(2, 1));
    level_bounds(3, 2) = min(max_delay, ...
        max(guarded(2), level_bounds(2, 2)));

    keep_detail = ismember(region_index, detail_region_indices) || ...
        region_index == representative_region_index;
    region_detail = initializeDetail();
    previous_bounds = zeros(0, 2);
    detection = emptyDetection(raw_start);

    for level = 1:3
        current_bounds = level_bounds(level, :);
        new_intervals = newSearchIntervals( ...
            current_bounds, previous_bounds);

        % One compact buffer supports first-repetition scanning plus direct
        % validation through MAX_REPETITIONS.
        buffer_start = current_bounds(1);
        buffer_end = min(energy_diagnostics.total_samples - 1, ...
            current_bounds(2) + (max_repetitions - 1) * ...
            repetition_period + template_length - 1);
        [rx_buffer, ~] = readProcessedBuffer(params, ...
            buffer_start, buffer_end - buffer_start + 1);

        level_candidates = zeros(0, 1);
        level_candidate_energy = zeros(0, 1);
        level_candidate_threshold = zeros(0, 1);

        for interval_index = 1:size(new_intervals, 1)
            interval = new_intervals(interval_index, :);
            [delay_positions, correlation_energy, threshold] = ...
                scanFirstRepetition(rx_buffer, buffer_start, ...
                interval, preamble_template, baseline_fraction, ...
                threshold_sigma);
            scanned_delay_count(region_index) = ...
                scanned_delay_count(region_index) + ...
                numel(delay_positions);

            [candidate_positions, candidate_energy] = ...
                extractCandidates(delay_positions, ...
                correlation_energy, threshold, ...
                candidate_relative_level, ...
                candidate_min_distance_samples);
            level_candidates = [level_candidates; ...
                candidate_positions]; %#ok<AGROW>
            level_candidate_energy = [level_candidate_energy; ...
                candidate_energy]; %#ok<AGROW>
            level_candidate_threshold = [ ...
                level_candidate_threshold; ...
                repmat(threshold, numel(candidate_positions), 1)]; ...
                %#ok<AGROW>

            if keep_detail
                region_detail.scan_positions = [ ...
                    region_detail.scan_positions; ...
                    delay_positions]; %#ok<AGROW>
                region_detail.scan_energy = [ ...
                    region_detail.scan_energy; ...
                    correlation_energy]; %#ok<AGROW>
                region_detail.scan_threshold = [ ...
                    region_detail.scan_threshold; ...
                    repmat(threshold, numel(delay_positions), 1)]; ...
                    %#ok<AGROW>
            end
        end

        if ~isempty(level_candidates)
            expected_candidate = raw_start + expected_offset_samples;
            [~, priority] = sort(abs( ...
                level_candidates - expected_candidate));
            level_candidates = level_candidates(priority);
            level_candidate_energy = ...
                level_candidate_energy(priority);
            level_candidate_threshold = ...
                level_candidate_threshold(priority);
        end

        for candidate_index = 1:numel(level_candidates)
            candidates_tested(region_index) = ...
                candidates_tested(region_index) + 1;
            candidate = level_candidates(candidate_index);
            validation = validateCandidate(rx_buffer, buffer_start, ...
                candidate, level_candidate_energy(candidate_index), ...
                level_candidate_threshold(candidate_index), ...
                preamble_template, repetition_period, ...
                min_repetitions, max_repetitions, ...
                min_threshold_ratio, ...
                require_hit_every_repetition);

            if keep_detail
                region_detail.candidate_positions(end + 1, 1) = ...
                    candidate; %#ok<AGROW>
                region_detail.candidate_pass(end + 1, 1) = ...
                    validation.detected; %#ok<AGROW>
            end

            if validation.detected
                detection = validation;
                detection.candidate = candidate;
                detection.level = level;
                break;
            end
        end

        previous_bounds = current_bounds;
        if detection.detected
            break;
        end
    end

    accepted_detections = struct([]);
    if detection.detected
        accepted_detections = detection;
    end

    % Hybrid continuation: interval length and the first confirmed packet
    % jointly decide whether a second packet can fit. All validated tail
    % candidates are collected first. Only afterwards are repetition trains
    % grouped and minimum packet spacing applied, so an early weak candidate
    % cannot suppress a later strong QM35 preamble.
    % Do not use the post-guard as evidence of another packet. The raw
    % energetic core plus the normal narrow-search allowance defines the
    % tail in which another preamble may begin.
    tail_end = min(max_delay, raw_energy_regions(region_index, 2) + ...
        search_level_samples(1, 2));
    is_suspiciously_long = raw_region_length_samples(region_index) >= ...
        long_region_threshold_samples;
    if multi_packet_search && detection.detected && ...
            is_suspiciously_long
        tail_start = detection.candidate + packet_exclusion_samples;
        tail_validated_detections = detection([]);
        if tail_start <= tail_end
            tail_search_used(region_index) = true;
        end

        while tail_start <= tail_end
            chunk_end = min(tail_end, ...
                tail_start + tail_scan_chunk_samples - 1);
            buffer_start = tail_start;
            buffer_end = min(energy_diagnostics.total_samples - 1, ...
                chunk_end + (max_repetitions - 1) * ...
                repetition_period + template_length - 1);
            [rx_buffer, ~] = readProcessedBuffer(params, ...
                buffer_start, buffer_end - buffer_start + 1);

            [delay_positions, correlation_energy, threshold] = ...
                scanFirstRepetition(rx_buffer, buffer_start, ...
                [tail_start, chunk_end], preamble_template, ...
                baseline_fraction, threshold_sigma);
            scanned_delay_count(region_index) = ...
                scanned_delay_count(region_index) + ...
                numel(delay_positions);
            tail_scanned_delay_count(region_index) = ...
                tail_scanned_delay_count(region_index) + ...
                numel(delay_positions);

            [candidate_positions, candidate_energy] = ...
                extractCandidates(delay_positions, ...
                correlation_energy, threshold, ...
                candidate_relative_level, ...
                candidate_min_distance_samples);
            [candidate_positions, candidate_order] = ...
                sort(candidate_positions);
            candidate_energy = candidate_energy(candidate_order);

            if keep_detail
                region_detail.scan_positions = [ ...
                    region_detail.scan_positions; ...
                    delay_positions]; %#ok<AGROW>
                region_detail.scan_energy = [ ...
                    region_detail.scan_energy; ...
                    correlation_energy]; %#ok<AGROW>
                region_detail.scan_threshold = [ ...
                    region_detail.scan_threshold; ...
                    repmat(threshold, numel(delay_positions), 1)]; ...
                    %#ok<AGROW>
            end

            for candidate_index = 1:numel(candidate_positions)
                candidate = candidate_positions(candidate_index);
                candidates_tested(region_index) = ...
                    candidates_tested(region_index) + 1;
                validation = validateCandidate( ...
                    rx_buffer, buffer_start, candidate, ...
                    candidate_energy(candidate_index), threshold, ...
                    preamble_template, repetition_period, ...
                    min_repetitions, max_repetitions, ...
                    min_threshold_ratio, ...
                    require_hit_every_repetition);

                if keep_detail
                    region_detail.candidate_positions(end + 1, 1) = ...
                        candidate; %#ok<AGROW>
                    region_detail.candidate_pass(end + 1, 1) = ...
                        validation.detected; %#ok<AGROW>
                end
                if validation.detected
                    validation.candidate = candidate;
                    validation.level = 4;
                    tail_validated_detections(end + 1, 1) = ...
                        validation; ...
                        %#ok<AGROW>
                end
            end
            tail_start = chunk_end + 1;
        end

        tail_packet_detections = selectPacketDetections( ...
            tail_validated_detections, packet_exclusion_samples, ...
            candidate_train_gap_repetitions * repetition_period);
        if ~isempty(tail_packet_detections)
            accepted_detections = [accepted_detections; ...
                tail_packet_detections(:)]; %#ok<AGROW>
            [~, packet_order] = sort( ...
                [accepted_detections.candidate]);
            accepted_detections = ...
                accepted_detections(packet_order);
        end
    end

    selected_candidates(region_index) = detection.candidate;
    detected_mask(region_index) = detection.detected;
    if detection.detected
        region_candidates = [accepted_detections.candidate].';
    else
        region_candidates = zeros(0, 1);
    end
    all_selected_candidates{region_index} = region_candidates;
    all_detections{region_index} = accepted_detections;
    region_packet_count(region_index) = numel(region_candidates);
    search_level_used(region_index) = detection.level;
    repetitions_used(region_index) = detection.repetitions_used;
    final_threshold_ratios(region_index) = ...
        detection.threshold_ratio;
    candidate_offset_from_core_us(region_index) = ...
        (detection.candidate - raw_start) / params.fs_rx * 1e6;

    if keep_detail
        region_detail.region_index = region_index;
        region_detail.raw_energy_region = ...
            raw_energy_regions(region_index, :);
        region_detail.guarded_energy_region = guarded;
        region_detail.detection = detection;
        region_detail.detections = accepted_detections;
        details{region_index} = region_detail;
    end

    if mod(region_index, 25) == 0 || region_index == region_count
        fprintf('\rAdaptive search %d/%d (%5.1f%%)', ...
            region_index, region_count, ...
            100 * region_index / region_count);
    end
end
scan_seconds = toc(tic_scan);
fprintf('\n');

candidate_time_ms = selected_candidates / params.fs_rx * 1e3;
capture_duration_ms = energy_diagnostics.total_samples / ...
    params.fs_rx * 1e3;
all_candidate_samples = vertcat(all_selected_candidates{:});
candidate_region_cells = arrayfun(@(k) ...
    repmat(k, region_packet_count(k), 1), (1:region_count).', ...
    'UniformOutput', false);
all_candidate_region_index = vertcat(candidate_region_cells{:});
candidate_ordinal_cells = arrayfun(@(n) ...
    (1:n).', region_packet_count, 'UniformOutput', false);
all_candidate_ordinal = vertcat(candidate_ordinal_cells{:});
all_candidate_time_ms = all_candidate_samples / params.fs_rx * 1e3;
all_candidate_offset_us = (all_candidate_samples - ...
    raw_energy_regions(all_candidate_region_index, 1)) / ...
    params.fs_rx * 1e6;
raw_region_start_ms = raw_energy_regions(:, 1) / params.fs_rx * 1e3;
raw_region_duration_us = raw_region_length_samples / ...
    params.fs_rx * 1e6;
multi_region_mask = region_packet_count > 1;

%% -------------------- Figure 1: all-region overview --------------------
fig_overview = figure('Name', ...
    'QM35 hybrid multi-packet correlation - overview', ...
    'Color', 'w', 'Position', [70, 70, 1500, 900]);
tiledlayout(3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

nexttile;
plot(all_candidate_time_ms, all_candidate_ordinal, '.', ...
    'Color', [0.10, 0.35, 0.80], 'MarkerSize', 9);
hold on;
if any(all_candidate_ordinal > 1)
    plot(all_candidate_time_ms(all_candidate_ordinal > 1), ...
        all_candidate_ordinal(all_candidate_ordinal > 1), 'ro', ...
        'MarkerSize', 5);
end
grid on;
xlim([0, capture_duration_ms]);
ylim([0.5, max(1.5, max([1; all_candidate_ordinal]) + 0.5)]);
ylabel('Packet ordinal in region');
title('All confirmed QM35 preambles; red circles are additional packets');

nexttile;
plot(raw_region_start_ms, raw_region_duration_us, '.', ...
    'Color', [0.10, 0.35, 0.80], 'MarkerSize', 8);
hold on;
plot(raw_region_start_ms(suspicious_long_region_mask), ...
    raw_region_duration_us(suspicious_long_region_mask), 'ks', ...
    'MarkerSize', 6, 'LineWidth', 1);
plot(raw_region_start_ms(multi_region_mask), ...
    raw_region_duration_us(multi_region_mask), 'ro', ...
    'MarkerSize', 6, 'LineWidth', 1);
grid on;
xlim([0, capture_duration_ms]);
xlabel('Raw energy-region start (ms)');
ylabel('Raw energy duration (\mus)');
title('Long energy regions containing multiple confirmed preambles');

nexttile;
scatter(raw_region_duration_us, region_packet_count, 12, ...
    tail_scanned_delay_count, 'filled');
hold on;
yline(1, 'k--', 'One packet');
xline(long_region_threshold_samples / params.fs_rx * 1e6, ...
    'r--', 'Tail-search threshold');
grid on;
xlim([0.95 * min(raw_region_duration_us), ...
    1.05 * max(max(raw_region_duration_us), ...
    long_region_threshold_samples / params.fs_rx * 1e6)]);
clim([0, max(1, max(tail_scanned_delay_count))]);
xlabel('Raw energy-region duration (\mus)');
ylabel('Confirmed packet count');
title('Length triggers tail search; color shows additional scanned delays');
colorbar;

sgtitle(sprintf(['QM35 hybrid search | %d packets in %d/%d regions | ', ...
    '%d multi-packet regions | %.2f s'], ...
    numel(all_candidate_samples), nnz(detected_mask), region_count, ...
    nnz(multi_region_mask), scan_seconds));

%% -------------------- Figure 2: selected region details --------------------
detail_count = numel(detail_region_indices);
fig_details = [];
if detail_count > 0
    fig_details = figure('Name', ...
        'QM35 adaptive correlation - details', ...
        'Color', 'w', 'Position', [100, 45, 1500, 950]);
    tiledlayout(detail_count, 1, 'TileSpacing', 'compact', ...
        'Padding', 'compact');

    for k = 1:detail_count
        region_index = detail_region_indices(k);
        d = details{region_index};
        order = sortOrder(d.scan_positions);
        delay_us = (d.scan_positions(order) - ...
            d.raw_energy_region(1)) / params.fs_rx * 1e6;

        nexttile;
        plot(delay_us, d.scan_energy(order), ...
            'b-', 'LineWidth', 0.9);
        hold on;
        plot(delay_us, d.scan_threshold(order), ...
            'r-', 'LineWidth', 0.9);
        detected_offsets_us = (all_selected_candidates{region_index} - ...
            d.raw_energy_region(1)) / params.fs_rx * 1e6;
        for packet_index = 1:numel(detected_offsets_us)
            xline(detected_offsets_us(packet_index), 'g-', ...
                sprintf('P%d', packet_index), 'LineWidth', 1.2);
        end
        grid on;
        ylabel('Corr. energy');
        title(sprintf(['Region %d | %d packet(s) | first level %d | ', ...
            'R=%d | tested %d'], region_index, ...
            region_packet_count(region_index), ...
            search_level_used(region_index), ...
            repetitions_used(region_index), ...
            candidates_tested(region_index)));
        if k == detail_count
            xlabel('Delay relative to energy start (\mus)');
        end
    end
    sgtitle(['First-repetition scan; later repetitions validate ', ...
        'candidate peaks only']);
end

%% -------------------- Figure 3: candidate validation mechanics --------------------
d = details{representative_region_index};
v = d.detection;
fig_mechanics = figure('Name', ...
    'QM35 adaptive correlation - mechanics', ...
    'Color', 'w', 'Position', [130, 55, 1500, 850]);
tiledlayout(2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

order = sortOrder(d.scan_positions);
delay_us = (d.scan_positions(order) - ...
    d.raw_energy_region(1)) / params.fs_rx * 1e6;
nexttile;
plot(delay_us, d.scan_energy(order), 'b-', 'LineWidth', 0.9);
hold on;
plot(delay_us, d.scan_threshold(order), 'r-', 'LineWidth', 0.9);
representative_offsets_us = ( ...
    all_selected_candidates{representative_region_index} - ...
    d.raw_energy_region(1)) / params.fs_rx * 1e6;
for packet_index = 1:numel(representative_offsets_us)
    xline(representative_offsets_us(packet_index), 'g-', ...
        sprintf('P%d', packet_index), 'LineWidth', 1.2);
end
grid on;
xlabel('Delay relative to energy start (\mus)');
ylabel('First-repetition energy');
title(sprintf(['Region contains %d packet(s); first level %d; ', ...
    '%d tested candidates; priority center %.1f \\mus'], ...
    region_packet_count(representative_region_index), v.level, ...
    candidates_tested(representative_region_index), ...
    expected_candidate_offset_us));

nexttile;
repetition_axis = 1:v.repetitions_used;
yyaxis left;
plot(repetition_axis, v.per_rep_energy, ...
    'bo-', 'LineWidth', 1.1, 'MarkerFaceColor', 'b');
hold on;
plot(repetition_axis, v.running_mean_energy, ...
    's-', 'Color', [0.10, 0.65, 0.25], ...
    'LineWidth', 1.1, 'MarkerFaceColor', [0.10, 0.65, 0.25]);
yline(v.single_threshold, 'r--', 'Hit threshold');
ylabel('Normalized correlation energy');
yyaxis right;
plot(repetition_axis, v.running_ratio, ...
    'd-', 'Color', [0.45, 0.20, 0.75], ...
    'LineWidth', 1.1, 'MarkerFaceColor', [0.45, 0.20, 0.75]);
yline(min_threshold_ratio, 'k--', 'Stop ratio');
ylabel('Running mean / threshold');
grid on;
xticks(repetition_axis);
xlabel('Preamble repetition');
title(sprintf(['Candidate validation stopped at R=%d | ', ...
    'ratio %.2f | hits %d'], v.repetitions_used, ...
    v.threshold_ratio, v.hit_count));
legend('Per-repetition energy', 'Running mean', ...
    'Location', 'best');

sgtitle(sprintf(['Adaptive candidate-first correlation | ', ...
    '%d-tap full-rate template'], template_length));

%% -------------------- Save and expose diagnostics --------------------
[~, capture_stem] = fileparts(options.file_name);
output_directory = fullfile(pwd, 'decoded_results', ...
    capture_stem, 'correlation_adaptive_diagnostics');
if ~isfolder(output_directory)
    mkdir(output_directory);
end

if save_figures
    exportgraphics(fig_overview, fullfile(output_directory, ...
        'adaptive_correlation_overview.png'), 'Resolution', 180);
    if ~isempty(fig_details)
        exportgraphics(fig_details, fullfile(output_directory, ...
            'adaptive_correlation_region_details.png'), ...
            'Resolution', 180);
    end
    exportgraphics(fig_mechanics, fullfile(output_directory, ...
        'adaptive_correlation_mechanics.png'), 'Resolution', 180);
end

correlation_diagnostics = struct();
correlation_diagnostics.energy_diagnostics_file = ...
    energy_diagnostics_file;
correlation_diagnostics.selected_candidates = selected_candidates;
correlation_diagnostics.all_selected_candidates = ...
    all_selected_candidates;
correlation_diagnostics.all_detections = all_detections;
correlation_diagnostics.all_candidate_samples = all_candidate_samples;
correlation_diagnostics.all_candidate_region_index = ...
    all_candidate_region_index;
correlation_diagnostics.region_packet_count = region_packet_count;
correlation_diagnostics.multi_region_mask = multi_region_mask;
correlation_diagnostics.suspicious_long_region_mask = ...
    suspicious_long_region_mask;
correlation_diagnostics.tail_search_used = tail_search_used;
correlation_diagnostics.tail_scanned_delay_count = ...
    tail_scanned_delay_count;
correlation_diagnostics.detected_mask = detected_mask;
correlation_diagnostics.search_level_used = search_level_used;
correlation_diagnostics.repetitions_used = repetitions_used;
correlation_diagnostics.candidates_tested = candidates_tested;
correlation_diagnostics.scanned_delay_count = scanned_delay_count;
correlation_diagnostics.final_threshold_ratios = ...
    final_threshold_ratios;
correlation_diagnostics.candidate_offset_from_core_us = ...
    candidate_offset_from_core_us;
correlation_diagnostics.scan_seconds = scan_seconds;
correlation_diagnostics.details = details(detail_region_indices);
correlation_diagnostics.parameters = struct( ...
    'search_level_us', search_level_us, ...
    'expected_candidate_offset_us', ...
        expected_candidate_offset_us, ...
    'min_repetitions', min_repetitions, ...
    'max_repetitions', max_repetitions, ...
    'baseline_fraction', baseline_fraction, ...
    'threshold_sigma', threshold_sigma, ...
    'min_threshold_ratio', min_threshold_ratio, ...
    'candidate_relative_level', candidate_relative_level, ...
    'candidate_min_distance_samples', ...
        candidate_min_distance_samples, ...
    'multi_packet_search', multi_packet_search, ...
    'packet_exclusion_repetitions', ...
        packet_exclusion_repetitions, ...
    'packet_exclusion_samples', packet_exclusion_samples, ...
    'single_region_baseline_fraction', ...
        single_region_baseline_fraction, ...
    'nominal_single_region_samples', ...
        nominal_single_region_samples, ...
    'long_region_threshold_factor', ...
        long_region_threshold_factor, ...
    'long_region_threshold_margin_us', ...
        long_region_threshold_margin_us, ...
    'long_region_threshold_samples', ...
        long_region_threshold_samples, ...
    'minimum_packet_separation_fraction', ...
        minimum_packet_separation_fraction, ...
    'candidate_train_gap_repetitions', ...
        candidate_train_gap_repetitions, ...
    'tail_scan_chunk_us', tail_scan_chunk_us);

diagnostics_file = fullfile(output_directory, ...
    'adaptive_correlation_diagnostics.mat');
save(diagnostics_file, 'correlation_diagnostics', '-v7');
assignin('base', 'qm35_correlation_diagnostics', ...
    correlation_diagnostics);

fprintf('\n=== QM35 hybrid correlation summary ===\n');
fprintf('Energy regions       : %d\n', region_count);
fprintf('Detected regions     : %d\n', nnz(detected_mask));
fprintf('Undetected           : %d\n', nnz(~detected_mask));
fprintf('Confirmed packets    : %d\n', numel(all_candidate_samples));
fprintf('Multi-packet regions : %d\n', nnz(multi_region_mask));
fprintf('Suspicious long      : %d\n', ...
    nnz(suspicious_long_region_mask));
fprintf('Extra packets found  : %d\n', ...
    sum(max(0, region_packet_count - 1)));
fprintf('Tail searches used   : %d\n', nnz(tail_search_used));
for level = 1:3
    fprintf('Search level %d used  : %d\n', level, ...
        nnz(search_level_used == level));
end
fprintf('Repetitions median   : %.1f\n', median(repetitions_used));
fprintf('Candidates tested med: %.1f\n', median(candidates_tested));
fprintf('Scanned delays median: %.1f\n', median(scanned_delay_count));
fprintf('Candidate offset med.: %.3f us\n', ...
    median(candidate_offset_from_core_us));
fprintf('Adaptive scan time   : %.3f s\n', scan_seconds);
fprintf('Diagnostics MAT      : %s\n', diagnostics_file);
if save_figures
    fprintf('Figures saved to     : %s\n', output_directory);
end

%% -------------------- Local helpers --------------------
function selected = selectPacketDetections( ...
        detections, minimum_packet_spacing, train_gap)
%SELECTPACKETDETECTIONS Group repetition peaks, then suppress packets.
if isempty(detections)
    selected = struct([]);
    return;
end

[~, time_order] = sort([detections.candidate]);
detections = detections(time_order);
candidate_samples = [detections.candidate].';
train_starts = [1; find(diff(candidate_samples) > train_gap) + 1];
train_ends = [train_starts(2:end) - 1; numel(detections)];

representatives = detections(train_starts);
train_scores = zeros(numel(train_starts), 1);
for train_index = 1:numel(train_starts)
    members = train_starts(train_index):train_ends(train_index);
    member_scores = zeros(numel(members), 1);
    for member_index = 1:numel(members)
        member_scores(member_index) = mean( ...
            detections(members(member_index)).per_rep_energy);
    end
    train_scores(train_index) = max(member_scores);
    % The earliest validated peak is the best estimate of the start of the
    % repeated preamble; the maximum member energy ranks the whole train.
    representatives(train_index) = detections(members(1));
end

[~, strength_order] = sort(train_scores, 'descend');
keep = false(numel(representatives), 1);
kept_candidates = zeros(0, 1);
for priority_index = 1:numel(strength_order)
    representative_index = strength_order(priority_index);
    candidate = representatives(representative_index).candidate;
    if isempty(kept_candidates) || all(abs( ...
            candidate - kept_candidates) >= minimum_packet_spacing)
        keep(representative_index) = true;
        kept_candidates(end + 1, 1) = candidate; %#ok<AGROW>
    end
end

selected = representatives(keep);
if ~isempty(selected)
    [~, time_order] = sort([selected.candidate]);
    selected = reshape(selected(time_order), [], 1);
end
end

function detail = initializeDetail()
detail = struct( ...
    'scan_positions', zeros(0, 1), ...
    'scan_energy', zeros(0, 1), ...
    'scan_threshold', zeros(0, 1), ...
    'candidate_positions', zeros(0, 1), ...
    'candidate_pass', false(0, 1));
end

function detection = emptyDetection(fallback_candidate)
detection = struct( ...
    'detected', false, ...
    'candidate', fallback_candidate, ...
    'level', 3, ...
    'repetitions_used', 0, ...
    'threshold_ratio', 0, ...
    'hit_count', 0, ...
    'single_threshold', NaN, ...
    'per_rep_energy', zeros(0, 1), ...
    'running_mean_energy', zeros(0, 1), ...
    'running_ratio', zeros(0, 1));
end

function intervals = newSearchIntervals(current, previous)
if isempty(previous)
    intervals = current;
    return;
end
intervals = zeros(0, 2);
if current(1) < previous(1)
    intervals(end + 1, :) = [current(1), previous(1) - 1]; ...
        %#ok<AGROW>
end
if current(2) > previous(2)
    intervals(end + 1, :) = [previous(2) + 1, current(2)]; ...
        %#ok<AGROW>
end
end

function [rx, sample_indices] = readProcessedBuffer( ...
        params, sample_offset, sample_num)
raw = uwbdecoder.readIqRaw(params.file_name, ...
    sample_offset, sample_num, params.ant_num);
rx = uwbdecoder.selectIqChannel(raw, params.channel_index);
sample_indices = sample_offset + (0:sample_num - 1).';

if params.enable_interference_cancellation
    basis = uwbdecoder.synchronousTone(sample_indices, ...
        params.interference_tone_bin, ...
        params.interference_period_samples);
    rx = rx - params.interference_coefficient(1) .* basis;
end

frequency_shift = params.x410_center_frequency - ...
    params.dw1000_center_frequency;
rx = rx .* exp(1j * 2 * pi * frequency_shift * ...
    sample_indices / params.fs_rx);
rx = rx - mean(rx);
end

function [positions, energy, threshold] = scanFirstRepetition( ...
        rx_buffer, buffer_start, interval, template, ...
        baseline_fraction, threshold_sigma)
template_length = numel(template);
width = interval(2) - interval(1) + 1;
segment_first = interval(1) - buffer_start + 1;
segment_last = segment_first + width + template_length - 2;
segment = rx_buffer(segment_first:segment_last);

matched = fftfilt(flipud(conj(template)), segment);
energy_norm = sqrt(movsum(abs(segment).^2, ...
    [template_length - 1, 0])) + eps;
score = abs(matched) ./ energy_norm;
score = score(template_length:template_length + width - 1);
energy = score.^2;
threshold = robustThreshold( ...
    energy, baseline_fraction, threshold_sigma);
positions = (interval(1):interval(2)).';
end

function [positions, values] = extractCandidates( ...
        delay_positions, energy, threshold, relative_level, ...
        min_distance)
level = max(threshold, relative_level * max(energy));
if exist('findpeaks', 'file') == 2
    [values, locations] = findpeaks(energy, ...
        'MinPeakHeight', level, ...
        'MinPeakDistance', min_distance);
else
    locations = simpleFindPeaks(energy, level, min_distance);
    values = energy(locations);
end
positions = delay_positions(locations);
values = values(:);
end

function result = validateCandidate(rx_buffer, buffer_start, ...
        candidate, first_energy, single_threshold, template, ...
        repetition_period, min_repetitions, max_repetitions, ...
        min_threshold_ratio, require_all_hits)
template_length = numel(template);
per_rep_energy = zeros(max_repetitions, 1);
running_mean = zeros(max_repetitions, 1);
running_ratio = zeros(max_repetitions, 1);
per_rep_energy(1) = first_energy;
hit_count = double(first_energy > single_threshold);
detected = false;

for repetition = 1:max_repetitions
    if repetition > 1
        window_first = candidate - buffer_start + 1 + ...
            (repetition - 1) * repetition_period;
        window_last = window_first + template_length - 1;
        if window_first < 1 || window_last > numel(rx_buffer)
            break;
        end
        window = rx_buffer(window_first:window_last);
        score = abs(sum(window .* conj(template))) / ...
            (sqrt(sum(abs(window).^2)) + eps);
        per_rep_energy(repetition) = score.^2;
        hit_count = hit_count + ...
            (per_rep_energy(repetition) > single_threshold);
    end

    running_mean(repetition) = mean( ...
        per_rep_energy(1:repetition));
    running_ratio(repetition) = ...
        running_mean(repetition) / max(single_threshold, eps);

    enough_hits = hit_count >= min_repetitions;
    if require_all_hits
        enough_hits = hit_count == repetition;
    end
    if repetition >= min_repetitions && ...
            running_ratio(repetition) >= ...
                min_threshold_ratio && enough_hits
        detected = true;
        break;
    end
end

result = struct();
result.detected = detected;
result.repetitions_used = repetition;
result.threshold_ratio = running_ratio(repetition);
result.hit_count = hit_count;
result.single_threshold = single_threshold;
result.per_rep_energy = per_rep_energy(1:repetition);
result.running_mean_energy = running_mean(1:repetition);
result.running_ratio = running_ratio(1:repetition);
end

function threshold = robustThreshold( ...
        metric, baseline_fraction, threshold_sigma)
sorted_metric = sort(metric);
baseline_count = max(16, floor( ...
    baseline_fraction * numel(sorted_metric)));
baseline_count = min(baseline_count, numel(sorted_metric));
baseline = sorted_metric(1:baseline_count);
baseline_median = median(baseline);
baseline_sigma = 1.4826 * median(abs( ...
    baseline - baseline_median));
threshold = baseline_median + threshold_sigma * ...
    max(baseline_sigma, eps);
end

function locs = simpleFindPeaks(metric, threshold, min_separation)
candidate = false(numel(metric), 1);
for k = 2:numel(metric) - 1
    candidate(k) = metric(k) >= threshold && ...
        metric(k) >= metric(k - 1) && metric(k) >= metric(k + 1);
end
idx = find(candidate);
if isempty(idx)
    locs = zeros(0, 1);
    return;
end
[~, order] = sort(metric(idx), 'descend');
idx = idx(order);
keep = false(size(idx));
for k = 1:numel(idx)
    if all(abs(idx(k) - idx(keep)) >= min_separation)
        keep(k) = true;
    end
end
locs = sort(idx(keep));
end

function order = sortOrder(values)
[~, order] = sort(values);
end
