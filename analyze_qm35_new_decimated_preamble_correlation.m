%% 使用已知 QM35 前导码，对完整采集数据进行降采样互相关搜索
% 本脚本仅用于观察相关峰，不进行 QM35 解码，也不会修改现有 SIC 流程。
% 采集文件按块读取，因此能够处理完整的 X410 数据文件而无需一次性载入内存。

clear;
close all;
clc;

%% -------------------- 基本配置 --------------------
% 当前选择 qm35_new_3；如需分析其他采集文件，只修改此处路径。
capture_file = 'F:\UWB基带数据\qm35_new_3.dat';
% X410 原始复基带采样率。
fs_rx = 737.28e6;
ant_num = 1;
channel_index = 1;
% 互相关前的降采样倍数。接收数据和模板一定使用相同的该倍数。
decimation_factor = 1;
% 检测模板：'preamble_code' 直接使用稀疏前导码；'waveform' 使用
% lrwpanWaveformGenerator 生成的完整理想前导码物理波形。
template_kind = 'preamble_code';
% 每次从磁盘读取的“核心”原始采样点数；必须能被降采样倍数整除。
core_block_samples = 20e6;
% 局部峰进入候选列表的最低归一化相关值。
minimum_candidate_score = 0.03;
% 最终报告阈值的下限；实际阈值还会由全局鲁棒统计确定。
minimum_report_score = 0.10;
% CSV 中按相关强度保留的最多候选峰数量。
maximum_report_peaks = 2000;
% 概览图中每个点覆盖的降采样域采样点数，保存每个区间的最大相关值。
plot_bin_samples = 500;

if ~isfile(capture_file)
    error('analyze_qm35_new_decimated_preamble_correlation:FileNotFound', ...
        'Capture file was not found: %s', capture_file);
end
if mod(core_block_samples, decimation_factor) ~= 0
    error('core_block_samples must be divisible by decimation_factor.');
end

project_dir = fileparts(mfilename('fullpath'));
addpath(project_dir);

%% -------------------- 生成与接收数据同速率的 QM35 模板 --------------------
% buildUwbReference 同时提供稀疏码序列 sampled_code 和其理想发射
% 波形 preamble_waveform。默认使用前者，以直接测试 preamble code 检测。
options = struct('fs_rx', fs_rx, 'data_rate', 6.81, ...
    'preamble_repetitions', 64, 'code_index', 9, ...
    'sfd_mode', '4z2', 'show_plots', false);
params = uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), options);
addpath(params.helper_path);
reference = uwbdecoder.buildUwbReference(params);
[p, q] = rat(fs_rx / reference.fs, 1e-12);
switch lower(template_kind)
    case 'preamble_code'
        % sampled_code 是以零填充的 +/-1 前导扩频码，未包含理想脉冲形状。
        template_native = reference.sampled_code;
        template_label = 'code-9 sampled_code';
    case 'waveform'
        % 保留该选项，便于与 uwbdecoder 当前的包检测模板直接比较。
        template_native = reference.preamble_waveform;
        template_label = 'code-9 preamble_waveform';
    otherwise
        error('template_kind must be ''preamble_code'' or ''waveform''.');
end
% 先把选择的模板重采样到 X410 的 737.28 MHz，再与接收信号同步降采样。
% 不上采样原始接收信号；模板和接收信号只需在同一个采样率上进行比较。
template_rx = resample(template_native, p, q);
template_ds = resample(template_rx, 1, decimation_factor);
template_ds = template_ds(:);
template_norm = norm(template_ds);
matched_filter = flipud(conj(template_ds));
template_length_ds = numel(template_ds);
template_length_rx = numel(template_rx);

% 块首额外读入一个模板长度的历史数据，确保块边界附近也可完成一次完整相关，
% 并在后面仅保留本块核心区间内的结果，避免相邻块重复统计。
overlap_samples = template_length_rx + 20 * decimation_factor;
file_info = dir(capture_file);
bytes_per_complex_sample = 4 * ant_num;
total_samples = floor(file_info.bytes / bytes_per_complex_sample);
core_block_count = ceil(total_samples / core_block_samples);
fs_ds = fs_rx / decimation_factor;

[~, capture_stem] = fileparts(capture_file);
output_dir = fullfile(project_dir, 'decoded_results', ...
    sprintf('%s_%s_ds%d_correlation', capture_stem, template_kind, ...
    decimation_factor));
if ~isfolder(output_dir)
    mkdir(output_dir);
end

fprintf('\n========== QM35 preamble correlation ==========\n');
fprintf('Capture       : %s\n', capture_file);
fprintf('Input rate    : %.3f MHz\n', fs_rx / 1e6);
fprintf('Search rate   : %.3f MHz (1/%d)\n', fs_ds / 1e6, decimation_factor);
fprintf('Template      : %s, %d samples after decimation\n', ...
    template_label, template_length_ds);
fprintf('Input samples : %d (%.3f s)\n\n', total_samples, total_samples / fs_rx);

%% -------------------- 流式降采样并与整段数据互相关 --------------------
all_peak_locations = zeros(0, 1);
all_peak_scores = zeros(0, 1);
trace_locations = zeros(0, 1);
trace_scores = zeros(0, 1);

for block_index = 1:core_block_count
    core_start = (block_index - 1) * core_block_samples;
    core_end = min(total_samples, core_start + core_block_samples);
    read_start = max(0, core_start - overlap_samples);
    read_count = core_end - read_start;

    raw = uwbdecoder.readIqRaw(capture_file, read_start, read_count, ant_num);
    rx = uwbdecoder.selectIqChannel(raw, channel_index);
    %clear raw;
    rx_ds = resample(rx, 1, decimation_factor);
    %clear rx;
    if numel(rx_ds) < template_length_ds
        continue;
    end

    % 归一化匹配滤波得分：分子是复互相关幅度，分母是当前窗口信号能量与
    % 模板能量的乘积平方根。这样宽带干扰的单纯功率抬升不会被误认为前导码。
    matched = fftfilt(matched_filter, rx_ds);
    numerator = matched(template_length_ds:end);
    local_energy = filter(ones(template_length_ds, 1), 1, abs(rx_ds).^2);
    denominator = sqrt(local_energy(template_length_ds:end)) * template_norm;
    score = abs(numerator) ./ max(denominator, eps);
    clear matched numerator local_energy denominator rx_ds;

    % score 的第 k 项对应模板起点：read_start + (k-1)*降采样倍数。
    % 该位置仍以原始 737.28 MHz 采样点为单位，方便后续精定位和 SIC 使用。
    positions_rx = read_start + (0:numel(score)-1).' * decimation_factor;
    % 只接收当前核心区间的结果，重叠历史区间仅用于保证边界相关正确。
    in_core = positions_rx >= core_start & positions_rx < core_end;
    candidate_indices = localMaxima(score, minimum_candidate_score);
    candidate_indices = candidate_indices(in_core(candidate_indices));
    all_peak_locations = [all_peak_locations; positions_rx(candidate_indices)]; %#ok<AGROW>
    all_peak_scores = [all_peak_scores; score(candidate_indices)]; %#ok<AGROW>

    [block_locations, block_scores] = maxBinnedTrace( ...
        positions_rx(in_core), score(in_core), plot_bin_samples);
    trace_locations = [trace_locations; block_locations]; %#ok<AGROW>
    trace_scores = [trace_scores; block_scores]; %#ok<AGROW>
    fprintf('Block %3d/%3d: %8.3f..%8.3f ms, local peaks: %d\n', ...
        block_index, core_block_count, core_start/fs_rx*1e3, ...
        core_end/fs_rx*1e3, numel(candidate_indices));
end

%% -------------------- 全局阈值、结果保存与概览图 --------------------
if isempty(all_peak_scores)
    robust_threshold = minimum_report_score;
    selected = false(0, 1);
else
    % 用中位数和 MAD 估计背景峰分布，避免少数真实强峰抬高阈值。
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
title(sprintf('QM35 %s correlation, decimation 1/%d', ...
    template_label, decimation_factor));
legend('Block maximum trace', 'Threshold', 'Selected local peaks', ...
    'Location', 'best');
exportgraphics(gcf, fullfile(output_dir, 'preamble_correlation_overview.png'), ...
    'Resolution', 180);

result = struct('capture_file', capture_file, 'fs_rx', fs_rx, ...
    'fs_ds', fs_ds, 'decimation_factor', decimation_factor, ...
    'template_kind', template_kind, 'template_label', template_label, ...
    'total_samples', total_samples, 'template_length_rx', template_length_rx, ...
    'template_length_ds', template_length_ds, ...
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
fprintf('Saved overview                : %s\n', ...
    fullfile(output_dir, 'preamble_correlation_overview.png'));
fprintf('Saved peak table              : %s\n', ...
    fullfile(output_dir, 'preamble_correlation_peaks.csv'));

function indices = localMaxima(values, minimum_value)
%LOCALMAXIMA 返回大于相邻点且超过最低门限的局部峰索引。
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
%MAXBINNEDTRACE 为全时长概览图降采样：每个时间箱仅保留最大相关值。
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
% MATLAB 在线性索引时有时会保留索引的行/列形状；显式转为列向量，
% 以便与前一数据块的结果安全纵向拼接。
locations = sample_locations(indices(:));
locations = locations(:);
values = values(:);
if usable_count < numel(score)
    [tail_value, tail_index] = max(score(usable_count+1:end));
    locations(end+1, 1) = sample_locations(usable_count + tail_index);
    values(end+1, 1) = tail_value;
end
end
