%% Correlate a preprocessed QM35 capture against the known preamble.
% The capture is already sampled at 998.4 MHz, tone-cleaned, and
% center-frequency corrected. This script only reads and analyzes it.
clear;
close all;
clc;

capture_file = 'F:\UWB鍩哄甫鏁版嵁\qm35_new_3.dat';
fs_rx = 998.4e6;
ant_num = 1;
channel_index = 1;
template_kind = 'preamble_code';
core_block_samples = 20e6;
minimum_candidate_score = 0.03;
minimum_report_score = 0.10;
maximum_report_peaks = 2000;
plot_bin_samples = 500;

if ~isfile(capture_file)
    error('analyze_qm35_new_decimated_preamble_correlation:FileNotFound', ...
        'Capture file was not found: %s', capture_file);
end

project_dir = fileparts(mfilename('fullpath'));
addpath(project_dir);
options = struct('fs_rx', fs_rx, 'data_rate', 6.81, ...
    'preamble_repetitions', 64, 'code_index', 9, ...
    'sfd_mode', '4z2', 'show_plots', false);
params = uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), options);
reference = uwbdecoder.buildUwbReference(params);
if abs(fs_rx - reference.fs) > 1
    error('analyze_qm35_new_decimated_preamble_correlation:SampleRateMismatch', ...
        'Preprocessed input must use the HRP work rate.');
end

switch lower(template_kind)
    case 'preamble_code'
        template = reference.sampled_code(:);
        template_label = 'code-9 sampled_code';
    case 'waveform'
        template = reference.preamble_waveform(:);
        template_label = 'code-9 preamble_waveform';
    otherwise
        error('template_kind must be ''preamble_code'' or ''waveform''.');
end
template_norm = norm(template);
matched_filter = flipud(conj(template));
template_length = numel(template);
overlap_samples = template_length + 20;

file_info = dir(capture_file);
bytes_per_complex_sample = 4 * ant_num;
total_samples = floor(file_info.bytes / bytes_per_complex_sample);
core_block_count = ceil(total_samples / core_block_samples);

[~, capture_stem] = fileparts(capture_file);
output_dir = fullfile(project_dir, 'decoded_results', ...
    sprintf('%s_%s_correlation', capture_stem, template_kind));
if ~isfolder(output_dir)
    mkdir(output_dir);
end

fprintf('\n========== QM35 preamble correlation ==========\n');
fprintf('Capture       : %s\n', capture_file);
fprintf('Input rate    : %.3f MHz\n', fs_rx / 1e6);
fprintf('Template      : %s, %d samples\n', template_label, template_length);
fprintf('Input samples : %d (%.3f s)\n\n', total_samples, total_samples / fs_rx);

all_peak_locations = zeros(0, 1);
all_peak_scores = zeros(0, 1);
trace_locations = zeros(0, 1);
trace_scores = zeros(0, 1);

for block_index = 1:core_block_count
    core_start = (block_index - 1) * core_block_samples;
    core_end = min(total_samples, core_start + core_block_samples);
    read_start = max(0, core_start - overlap_samples);
    read_count = core_end - read_start;

    raw = uwbdecoder.readIqRaw(capture_file, read_start, ...
        read_count, ant_num);
    rx = uwbdecoder.selectIqChannel(raw, channel_index);
    if numel(rx) < template_length
        continue;
    end

    matched = fftfilt(matched_filter, rx);
    numerator = matched(template_length:end);
    local_energy = filter(ones(template_length, 1), 1, abs(rx).^2);
    denominator = sqrt(local_energy(template_length:end)) * template_norm;
    score = abs(numerator) ./ max(denominator, eps);
    positions = read_start + (0:numel(score)-1).';
    in_core = positions >= core_start & positions < core_end;

    candidate_indices = localMaxima(score, minimum_candidate_score);
    candidate_indices = candidate_indices(in_core(candidate_indices));
    all_peak_locations = [all_peak_locations; positions(candidate_indices)]; %#ok<AGROW>
    all_peak_scores = [all_peak_scores; score(candidate_indices)]; %#ok<AGROW>

    [block_locations, block_scores] = maxBinnedTrace( ...
        positions(in_core), score(in_core), plot_bin_samples);
    trace_locations = [trace_locations; block_locations]; %#ok<AGROW>
    trace_scores = [trace_scores; block_scores]; %#ok<AGROW>
    fprintf('Block %3d/%3d: %8.3f..%8.3f ms, local peaks: %d\n', ...
        block_index, core_block_count, core_start/fs_rx*1e3, ...
        core_end/fs_rx*1e3, numel(candidate_indices));
end

if isempty(all_peak_scores)
    robust_threshold = minimum_report_score;
    selected = false(0, 1);
else
    robust_sigma = 1.4826 * mad(all_peak_scores, 1);
    robust_threshold = max(minimum_report_score, ...
        median(all_peak_scores) + 8 * robust_sigma);
    selected = all_peak_scores >= robust_threshold;
end

peak_table = table((1:numel(all_peak_scores)).', all_peak_locations, ...
    all_peak_locations/fs_rx*1e3, all_peak_scores, selected, ...
    'VariableNames', {'local_peak_index', 'start_sample_rx', ...
    'time_ms', 'normalized_correlation', 'above_robust_threshold'});
peak_table = sortrows(peak_table, 'normalized_correlation', 'descend');
if height(peak_table) > maximum_report_peaks
    peak_table = peak_table(1:maximum_report_peaks, :);
end
writetable(peak_table, fullfile(output_dir, 'preamble_correlation_peaks.csv'));

figure('Color', 'w', 'Name', 'QM35 preamble correlation');
plot(trace_locations/fs_rx*1e3, trace_scores, 'b-');
hold on;
yline(robust_threshold, 'r--', 'Robust report threshold');
if any(selected)
    scatter(all_peak_locations(selected)/fs_rx*1e3, ...
        all_peak_scores(selected), 18, 'r', 'filled');
end
grid on;
xlabel('Time (ms)');
ylabel('Normalized preamble correlation');
title(sprintf('QM35 %s correlation on preprocessed grid', template_label));
legend('Block maximum trace', 'Threshold', 'Selected local peaks', ...
    'Location', 'best');
exportgraphics(gcf, fullfile(output_dir, 'preamble_correlation_overview.png'), ...
    'Resolution', 180);

result = struct('capture_file', capture_file, 'fs_rx', fs_rx, ...
    'template_kind', template_kind, 'template_label', template_label, ...
    'total_samples', total_samples, 'template_length', template_length, ...
    'minimum_candidate_score', minimum_candidate_score, ...
    'robust_threshold', robust_threshold, ...
    'peak_locations_rx', all_peak_locations, 'peak_scores', all_peak_scores, ...
    'selected_peak_count', nnz(selected), ...
    'trace_locations_rx', trace_locations, 'trace_scores', trace_scores);
save(fullfile(output_dir, 'preamble_correlation_result.mat'), 'result', ...
    'peak_table', '-v7.3');

fprintf('\nLocal peaks (score >= %.3f): %d\n', ...
    minimum_candidate_score, numel(all_peak_scores));
fprintf('Robust report threshold       : %.4f\n', robust_threshold);
fprintf('Selected peaks                : %d\n', nnz(selected));

function indices = localMaxima(values, minimum_value)
if numel(values) < 3
    indices = zeros(0, 1);
    return;
end
mask = values(2:end-1) >= values(1:end-2) & ...
    values(2:end-1) > values(3:end) & ...
    values(2:end-1) >= minimum_value;
indices = find(mask) + 1;
end

function [locations, values] = maxBinnedTrace(sample_locations, score, bin_size)
usable_count = floor(numel(score)/bin_size) * bin_size;
if usable_count == 0
    locations = sample_locations(:);
    values = score(:);
    return;
end
score_matrix = reshape(score(1:usable_count), bin_size, []);
[values, row] = max(score_matrix, [], 1);
column = 0:numel(values)-1;
indices = row + column*bin_size;
locations = sample_locations(indices(:));
locations = locations(:);
values = values(:);
if usable_count < numel(score)
    [tail_value, tail_index] = max(score(usable_count+1:end));
    locations(end+1, 1) = sample_locations(usable_count + tail_index);
    values(end+1, 1) = tail_value;
end
end
