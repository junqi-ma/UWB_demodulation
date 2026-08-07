function results = decode_uwb_all(options, batch)
%DECODE_UWB_ALL 解码预处理 UWB 采集文件中的全部数据包。
%
%   本函数采用“粗定位 -> 精确相关 -> 局部完整解码”的三级流程：
%   1) 以较大的步长分块读取文件，计算能量包络并找出可能存在突发信号的区间；
%   2) 仅在这些区间内按完整采样率搜索前导码，并利用多次前导码重复进行候选确认；
%   3) 只对确认后的候选位置截取窗口，调用 decode_uwb 完成完整帧解码。
%   这样可以避免对超大采集文件的每个采样点都进行高成本相关和解码。
%
%   输入参数：
%   options - 解码器参数结构体，字段定义与 decode_uwb 及 run_decode_* 保持一致，
%             例如输入文件名、采样率、天线数、通道号和前导码配置等。
%   batch   - 批处理参数结构体，用于控制能量扫描、相关搜索、解码窗口以及输出文件。
%             为空或缺少字段时，将由 mergeBatchOptions 填充默认值并做合法性约束。
%
%   输出参数：
%   results - 包含检测统计、候选位置、数据包时间区间、CIR、帧记录及输出参数的结构体。
%             所有公开的绝对采样位置均使用从 0 开始的索引，区间终点为包含端点。
%
%   说明：第三阶段的候选解码通过 parfor 并行执行；去重、FCS 筛选和结果保存按候选
%   顺序串行完成，以保证“先出现的候选优先保留”这一行为稳定可复现。

if nargin < 1 || isempty(options)
    options = struct();
end
if nargin < 2 || isempty(batch)
    batch = struct();
end

% 合并默认配置与用户配置：mergeOptions 负责解码参数，mergeBatchOptions 负责批处理参数。
baseParams = uwbdecoder.mergeOptions( ...
    uwbdecoder.defaultOptions(), options);
batch = mergeBatchOptions(batch, baseParams);

if ~isfolder(batch.output_directory)
    mkdir(batch.output_directory);
end

% 根据文件字节数推算复数采样点总数（不读文件内容）。
totalSamples = countCaptureSamples(baseParams);
% 采集太短（连一个最小解码窗口都不够）时直接报错。
if totalSamples < batch.min_window_samples
    error('decode_uwb_all:CaptureTooShort', ...
        'Capture has only %d complex samples; need at least %d.', ...
        totalSamples, batch.min_window_samples);
end

% 只构造一次参考信号，供候选窗口完整解码和采样坐标换算共同使用。
reference = uwbdecoder.buildUwbReference(baseParams);
addpath(baseParams.helper_path);

if strcmp(batch.detection_mode, 'fixed_interval')
    %% -------------------- 雷达模式：按固定周期直接生成候选 --------------------
    % first_packet_time_s 是第一个包前导码起点相对采集文件起点的时间。后续候选
    % 直接由固定发包周期推算，不读取 IQ 做能量扫描，也不执行全文件候选相关搜索。
    [candidates, candidateRegions, correlationStats] = ...
        predictFixedIntervalCandidates(baseParams, batch, totalSamples);
    energyRegions = zeros(0, 2);
    energyStats = struct( ...
        'chunk_count', 0, ...
        'raw_regions', zeros(0, 2), ...
        'skipped', true, ...
        'skip_reason', 'fixed_interval_schedule');
    energySeconds = 0;
    correlationSeconds = 0;
    coarseSeconds = 0;
    printProgress('Stage 1/3: fixed-interval schedule', 1, 0);
    fprintf('\n');
else
    % coarseTemplate 为归一化的完整采样率前导码模板，供阶段 2 的相关搜索使用。
    coarseTemplate = buildCoarseTemplate(baseParams, reference, batch);

    printProgress('Stage 1/3: energy scan', 0, 0);

    %% -------------------- 阶段 1：跨步能量包络扫描 --------------------
    % 以 energy_step_samples 为步长跨步读取 IQ，先定位能量突发区间，避免全文件做相关。
    ticEnergy = tic;
    [energyRegions, energyStats] = findEnergyRegions( ...
        baseParams, batch, totalSamples, ...
        @(frac) printProgress('Stage 1/3: energy scan', frac, 0));
    energySeconds = toc(ticEnergy);
    printProgress('Stage 1/3: energy scan', 1, energySeconds);

    %% -------------------- 阶段 2：能量区间内的前导码相关搜索 --------------------
    % 只在能量区间内做全采样率前导码相关，并用多次前导码重复验证候选。
    ticCorrelation = tic;
    [candidates, candidateRegions, correlationStats] = refineEnergyRegions( ...
        baseParams, coarseTemplate, batch, energyRegions, ...
        energyStats.raw_regions, totalSamples, ...
        @(frac) printProgress('Stage 2/3: correlation', frac, 0));
    correlationSeconds = toc(ticCorrelation);
    coarseSeconds = energySeconds + correlationSeconds;
    printProgress('Stage 2/3: correlation', 1, correlationSeconds);
end

%% -------------------- 阶段 3：仅对候选位置执行完整解码 --------------------
% 每个候选的完整解码彼此独立，因此交给 parfor 分发到多个 worker。去重和帧保存
% 依赖已经接受的帧，必须在并行阶段结束后按候选顺序串行完成。
frames = emptyFrameRecord();
packetCount = 0;
ticFine = tic;

% 确保完整解码阶段已经打开并行池。
if isempty(gcp('nocreate'))
    parpool('local');
end

% 预先计算每个候选的窗口偏移和窗口长度，使 parfor 循环体只依赖候选索引。
numCandidates = numel(candidates);
candOffsets = zeros(numCandidates, 1);
candWindowSamples = zeros(numCandidates, 1);
candValid = false(numCandidates, 1);
for candIdx = 1:numCandidates
    candidate = candidates(candIdx);
    candidateRegion = candidateRegions(candIdx, :);
    offset = max(0, max(candidate - batch.pre_packet_guard_samples, ...
        candidateRegion(1)));
    if offset + batch.min_window_samples > totalSamples
        continue;
    end
    regionWindowSamples = candidateRegion(2) - offset + 1;
    windowSamples = min(batch.window_samples, ...
        max(batch.min_window_samples, regionWindowSamples));
    windowSamples = min(windowSamples, totalSamples - offset);
    candOffsets(candIdx) = offset;
    candWindowSamples(candIdx) = windowSamples;
    candValid(candIdx) = true;
end

attemptCount = nnz(candValid);
% 用 cell 数组收集解码结果；对应候选解码失败时保留为空数组。
% TODO: 讨论cell对性能的影响
decodeCells = cell(numCandidates, 1);
timingCells = cell(numCandidates, 1);

parfor c = 1:numCandidates
    if ~candValid(c)
        continue;
    end
    offset = candOffsets(c);
    windowSamples = candWindowSamples(c);

    % baseParams was merged and validated once before entering parfor.
    % Only the candidate-specific file window changes here.
    windowOptions = baseParams;
    windowOptions.sample_offset = offset;
    windowOptions.sample_num = windowSamples;
    windowOptions.show_plots = false;
    seededPreambleStart = candidates(c) - offset + 1;
    % 第 4 个参数复用主流程已构造的 reference，避免每个候选重复生成 PHY 波形。
    try
        result = decode_uwb(windowOptions, [], [], reference, 'single', ...
            seededPreambleStart, true);
    catch decodeError
        continue;  % 单个候选解码失败不影响其他候选。
    end

    timing = locateDecodedFrameSamples( ...
        offset, result, baseParams, reference, batch, totalSamples);

    decodeCells{c} = result;
    timingCells{c} = timing;
end

% 串行后处理：去重并保存帧。按候选顺序遍历可以保持“首次出现者优先”的行为。
for c = 1:numCandidates
    if isempty(decodeCells{c})
        continue;
    end
    result = decodeCells{c};
    timing = timingCells{c};
    absStart = timing.abs_start_sample;

    if isDuplicatePacket(frames, packetCount, absStart, ...
            batch.start_tolerance_samples)
        continue;
    end

    % 可选 FCS 门控：require_fcs_pass 为真时丢弃 FCS 未通过的帧。
    if batch.require_fcs_pass && ~result.payload.fcs_pass
        continue;
    end

    packetCount = packetCount + 1;
    frames(packetCount) = packageFrameRecord( ...
        packetCount, candOffsets(c), timing, result, baseParams);

    if batch.save_individual_cir
        cirFile = fullfile(batch.output_directory, ...
            sprintf('cir_%03d.mat', packetCount));
        cir = frames(packetCount).cir;
        meta = frames(packetCount);
        save(cirFile, 'cir', 'meta', '-v7');
    end
end

if packetCount == 0
    frames = emptyFrameRecord();
else
    frames = frames(1:packetCount);
end
fineSeconds = toc(ticFine);

%% -------------------- 结果打包与落盘 --------------------
% 汇总计时、检测统计、包区间、CIR 矩阵和输出路径，并写盘。
results = struct();
results.file_name = baseParams.file_name;
results.total_samples = totalSamples;
results.duration_s = totalSamples / baseParams.fs_rx;
results.coarse_seconds = coarseSeconds;
results.energy_seconds = energySeconds;
results.correlation_seconds = correlationSeconds;
results.fine_seconds = fineSeconds;
results.coarse_chunk_count = energyStats.chunk_count;
results.coarse_raw_peak_count = correlationStats.raw_candidate_count;
results.energy_regions = energyRegions;
results.energy_stats = energyStats;
results.correlation_stats = correlationStats;
results.candidate_count = numel(candidates);
results.candidates = candidates(:);
results.candidate_regions = candidateRegions;
results.attempt_count = attemptCount;
results.packet_count = packetCount;
% 此版本号需要与 sic_pipeline/uwbSicPipeline.m 中
% latestAlgorithmConfig().detection_algorithm_version 保持一致。当能量扫描或自适应
% 全采样率多包检测器发生不兼容改变时，两处版本号必须同步递增。
if strcmp(batch.detection_mode, 'fixed_interval')
    results.detection_algorithm_version = 1;
    results.detection_algorithm = 'fixed_interval_radar_v1';
else
    results.detection_algorithm_version = 3;
    results.detection_algorithm = 'adaptive_fullrate_multipacket_v3';
end
if packetCount == 0
    results.fcs_pass_count = 0;
else
    results.fcs_pass_count = sum([frames.fcs_pass]);
end
results.params = baseParams;
results.batch = batch;
results.frames = frames;
results.sample_index_base = 0;
results.interval_end_inclusive = true;
results.packet_intervals = zeros(0, 2);
results.blank_intervals = zeros(0, 2);
results.precise_interval_mask = false(0, 1);
results.precise_packet_intervals = zeros(0, 2);
results.precise_blank_intervals = zeros(0, 2);
results.cir_delay_ns = [];
results.cir_values = [];

% 有帧时再填充包区间、精确区间掩码和逐包 CIR 矩阵（每列对应一个包）。
if packetCount > 0
    results.packet_intervals = [ ...
        [frames.abs_start_sample].', [frames.abs_end_sample].'];
    results.blank_intervals = [ ...
        [frames.localization_start_sample].', ...
        [frames.localization_end_sample].'];
    results.precise_interval_mask = ...
        [frames.has_precise_end_sample].';
    results.precise_packet_intervals = results.packet_intervals( ...
        results.precise_interval_mask, :);
    results.precise_blank_intervals = results.blank_intervals( ...
        results.precise_interval_mask, :);
    results.cir_delay_ns = frames(1).cir.delay_ns(:);
    cirLen = numel(results.cir_delay_ns);
    firstCirValues = frames(1).cir.values(:);
    results.cir_values = complex(zeros( ...
        cirLen, packetCount, 'like', firstCirValues));
    for k = 1:packetCount
        values = frames(k).cir.values(:);
        n = min(cirLen, numel(values));
        results.cir_values(1:n, k) = values(1:n);
    end
end

% 结果写盘：MAT 文件保存完整结果，CSV 保存帧级摘要。
save(batch.mat_file, 'results', '-v7');
writeSummaryCsv(batch.summary_csv, frames);

printProgress('Stage 3/3: fine decode', 1, fineSeconds);
fprintf('\n');
end

% -------------------------------------------------------------------------
function printProgress(stage, frac, elapsed)
%PRINTPROGRESS 在命令行中显示可原地刷新的单行进度条。
%
%   输入参数：
%   stage   - 当前阶段的文字标签，例如“Stage 1/3: energy scan”。
%   frac    - 当前阶段的完成比例，通常在 0 到 1 之间；1 表示阶段完成。
%   elapsed - 阶段耗时（秒），仅在 frac >= 1 时用于显示最终耗时。
%
%   函数使用 persistent 保存上一阶段的文本和百分比，只在整数百分比变化时刷新，
%   从而减少大量文件读取或循环计算时的终端输出开销。阶段切换时会自动重置状态。
persistent lastFrac lastStage prevLen
if isempty(lastFrac), lastFrac = -1; end
if isempty(lastStage), lastStage = ''; end
if isempty(prevLen), prevLen = 0; end

% 进入新阶段时重置进度条状态。
if ~strcmp(stage, lastStage)
    lastFrac = -1;
    lastStage = stage;
    prevLen = 0;
end

barLen = 30;
nRound = max(0, min(barLen, round(frac * barLen)));
bar = [repmat('=', 1, nRound) repmat(' ', 1, barLen - nRound)];

if frac >= 1
    % 用退格覆盖上一行，然后输出完成状态。
    fprintf(repmat('\b', 1, prevLen));
    msg = sprintf('[%s] [%-*s] done  %.1f s\n', stage, barLen, bar, elapsed);
    fprintf('%s', msg);
    prevLen = 0;
    lastFrac = -1;
else
    % 只有整数百分比发生变化时才刷新，以将刷新频率限制在约 1% 一次。
    pct = floor(frac * 100);
    if pct == lastFrac, return; end
    lastFrac = pct;
    % 用退格覆盖上一行，然后输出新的进度。
    fprintf(repmat('\b', 1, prevLen));
    msg = sprintf('[%s] [%-*s] %3.0f%%', stage, barLen, bar, frac * 100);
    fprintf('%s', msg);
    prevLen = numel(msg);
end
% 强制刷新输出，使没有换行时进度条也能实时更新。
drawnow('limitrate');
end

% -------------------------------------------------------------------------
function batch = mergeBatchOptions(batch, params)
%MERGEBATCHOPTIONS 合并批处理参数、兼容旧字段并校验参数范围。
%
%   输入参数：
%   batch  - 用户传入的批处理配置。可以只设置少量字段，其余字段使用默认值。
%   params - 已完成合并的基础解码参数，主要用于根据接收采样率计算时间相关的默认值。
%
%   输出参数：
%   batch  - 补全后的批处理配置。函数首先把旧版本的 coarse_* 字段映射到当前字段，
%            然后填充输出路径、取整采样点参数、限制阈值范围，并修复互相矛盾的配置。
%
%   这里的采样区间均按零基、闭区间解释；因此涉及区间长度时统一使用 end-start+1。
%   对明显不合理但可以安全修复的参数发出 warning，而不是直接中止整个解码流程。

% 第一步：旧版 coarse_* 字段名兼容映射到当前字段名。
if isfield(batch, 'coarse_chunk_samples') && ...
        ~isfield(batch, 'energy_chunk_samples')
    batch.energy_chunk_samples = batch.coarse_chunk_samples;
end
if isfield(batch, 'coarse_step_samples') && ...
        ~isfield(batch, 'energy_step_samples')
    batch.energy_step_samples = batch.coarse_step_samples;
end
if isfield(batch, 'coarse_decimation') && ...
        ~isfield(batch, 'correlation_decimation')
    batch.correlation_decimation = batch.coarse_decimation;
end
if isfield(batch, 'coarse_correlation_repetitions') && ...
        ~isfield(batch, 'correlation_repetitions')
    batch.correlation_repetitions = ...
        batch.coarse_correlation_repetitions;
end

% 第二步：填充缺失字段的默认值。时间相关的默认值（µs 换算成采样点）按 fs_rx 计算。
defaults = struct( ...
    'energy_chunk_samples', 20e6, ...
    'energy_step_samples', 19e6, ...
    'energy_read_stride', 100, ...
    'energy_smooth_rx_samples', 8192, ...
    'energy_baseline_fraction', 0.30, ...
    'energy_threshold_sigma_high', 6, ...
    'energy_threshold_sigma_low', 3, ...
    'energy_threshold_margin_db_high', 6, ...
    'energy_threshold_margin_db_low', 4, ...
    'energy_min_region_samples', 3e4, ...
    'energy_region_pre_guard_samples', 1.5e4, ...
    'energy_region_post_guard_samples', 2.5e4, ...
    'energy_region_merge_samples', 1e4, ...
    'correlation_decimation', 1, ...
    'correlation_repetitions', 8, ...
    'correlation_chunk_samples', 4e6, ...
    'correlation_overlap_samples', 3e5, ...
    'correlation_search_level_1_pre_samples', round(5e-6*params.fs_rx), ...
    'correlation_search_level_1_post_samples', round(12e-6*params.fs_rx), ...
    'correlation_search_level_2_pre_samples', round(15e-6*params.fs_rx), ...
    'correlation_search_level_2_post_samples', round(30e-6*params.fs_rx), ...
    'correlation_expected_offset_samples', round(5.2e-6*params.fs_rx), ...
    'correlation_min_repetitions', 3, ...
    'correlation_baseline_fraction', 0.60, ...
    'corr_threshold_sigma', 5, ...
    'corr_min_threshold_ratio', 20, ...
    'corr_candidate_relative_level', 0.20, ...
    'corr_require_hit_every_repetition', true, ...
    'correlation_multi_packet_search', true, ...
    'correlation_single_region_baseline_fraction', 0.60, ...
    'correlation_long_region_threshold_factor', 1.50, ...
    'correlation_long_region_threshold_margin_samples', ...
        round(20e-6*params.fs_rx), ...
    'correlation_min_packet_separation_fraction', 0.75, ...
    'correlation_packet_exclusion_repetitions', ...
        params.preamble_repetitions, ...
    'correlation_candidate_train_gap_repetitions', 4, ...
    'correlation_tail_chunk_samples', round(100e-6*params.fs_rx), ...
    'correlation_peak_min_distance_samples', 400, ...
    'correlation_cluster_gap_samples', 4000, ...
    'correlation_min_cluster_peaks', 4, ...
    'candidate_merge_samples', 5e4, ...
    'pre_packet_guard_samples', 5e4, ...
    'window_samples', 0.8e6, ...
    'localization_pre_guard_samples', 2048, ...
    'localization_post_guard_samples', 4096, ...
    'start_tolerance_samples', 4096, ...
    'min_window_samples', 0.3e6, ...
    'require_fcs_pass', false, ...
    'save_individual_cir', false, ...
    'detection_mode', 'adaptive', ...
    'first_packet_time_s', NaN, ...
    'packet_interval_s', NaN, ...
    'fixed_max_packets', Inf, ...
    'output_directory', '', ...
    'mat_file', '', ...
    'summary_csv', '');

names = fieldnames(defaults);
for k = 1:numel(names)
    name = names{k};
    if ~isfield(batch, name) || isempty(batch.(name))
        batch.(name) = defaults.(name);
    end
end

% 第三步：默认输出路径基于采集文件名自动生成（decoded_results/<文件名>/）。
[~, captureStem] = fileparts(params.file_name);
if strlength(string(batch.output_directory)) == 0
    batch.output_directory = fullfile(pwd, 'decoded_results', captureStem);
end
if strlength(string(batch.mat_file)) == 0
    batch.mat_file = fullfile(batch.output_directory, 'all_frames_cir.mat');
end
if strlength(string(batch.summary_csv)) == 0
    batch.summary_csv = fullfile(batch.output_directory, 'frame_summary.csv');
end

% 第四步：采样点类字段取整并限制下界为 1，比例/阈值类字段夹到合法范围。
integerFields = { ...
    'energy_chunk_samples', 'energy_step_samples', 'energy_read_stride', ...
    'energy_smooth_rx_samples', 'energy_min_region_samples', ...
    'energy_region_pre_guard_samples', ...
    'energy_region_post_guard_samples', ...
    'energy_region_merge_samples', 'correlation_decimation', ...
    'correlation_repetitions', 'correlation_chunk_samples', ...
    'correlation_overlap_samples', ...
    'correlation_search_level_1_pre_samples', ...
    'correlation_search_level_1_post_samples', ...
    'correlation_search_level_2_pre_samples', ...
    'correlation_search_level_2_post_samples', ...
    'correlation_expected_offset_samples', ...
    'correlation_min_repetitions', ...
    'correlation_long_region_threshold_margin_samples', ...
    'correlation_packet_exclusion_repetitions', ...
    'correlation_candidate_train_gap_repetitions', ...
    'correlation_tail_chunk_samples', ...
    'correlation_peak_min_distance_samples', ...
    'correlation_cluster_gap_samples', ...
    'correlation_min_cluster_peaks', 'candidate_merge_samples', ...
    'pre_packet_guard_samples', 'window_samples', ...
    'localization_pre_guard_samples', ...
    'localization_post_guard_samples', 'start_tolerance_samples', ...
    'min_window_samples'};
for k = 1:numel(integerFields)
    name = integerFields{k};
    batch.(name) = max(1, round(batch.(name)));
end
batch.energy_threshold_sigma_high = max(0, ...
    double(batch.energy_threshold_sigma_high));
batch.energy_threshold_sigma_low = max(0, ...
    double(batch.energy_threshold_sigma_low));
batch.energy_threshold_margin_db_high = max(0, ...
    double(batch.energy_threshold_margin_db_high));
batch.energy_threshold_margin_db_low = max(0, ...
    double(batch.energy_threshold_margin_db_low));
batch.energy_baseline_fraction = min(1, max(eps, ...
    double(batch.energy_baseline_fraction)));
batch.corr_threshold_sigma = max(0, double(batch.corr_threshold_sigma));
batch.corr_min_threshold_ratio = max(0, ...
    double(batch.corr_min_threshold_ratio));
batch.correlation_baseline_fraction = min(1, max(eps, ...
    double(batch.correlation_baseline_fraction)));
batch.corr_candidate_relative_level = min(1, max(0, ...
    double(batch.corr_candidate_relative_level)));
batch.corr_require_hit_every_repetition = logical( ...
    batch.corr_require_hit_every_repetition);
batch.correlation_multi_packet_search = logical( ...
    batch.correlation_multi_packet_search);
batch.correlation_single_region_baseline_fraction = min(1, max(eps, ...
    double(batch.correlation_single_region_baseline_fraction)));
batch.correlation_long_region_threshold_factor = max(1, ...
    double(batch.correlation_long_region_threshold_factor));
batch.correlation_min_packet_separation_fraction = max(0, ...
    double(batch.correlation_min_packet_separation_fraction));
batch.require_fcs_pass = logical(batch.require_fcs_pass);
batch.save_individual_cir = logical(batch.save_individual_cir);
batch.detection_mode = validatestring(lower(string(batch.detection_mode)), ...
    ["adaptive", "fixed_interval"], mfilename, 'batch.detection_mode');
batch.detection_mode = char(batch.detection_mode);
batch.first_packet_time_s = double(batch.first_packet_time_s);
batch.packet_interval_s = double(batch.packet_interval_s);
batch.fixed_max_packets = double(batch.fixed_max_packets);

if strcmp(batch.detection_mode, 'fixed_interval')
    validateattributes(batch.first_packet_time_s, {'numeric'}, ...
        {'scalar', 'real', 'finite', 'nonnegative'}, mfilename, ...
        'batch.first_packet_time_s');
    validateattributes(batch.packet_interval_s, {'numeric'}, ...
        {'scalar', 'real', 'finite', 'positive'}, mfilename, ...
        'batch.packet_interval_s');
    validateattributes(batch.fixed_max_packets, {'numeric'}, ...
        {'scalar', 'real', 'positive'}, mfilename, ...
        'batch.fixed_max_packets');
    if isfinite(batch.fixed_max_packets)
        batch.fixed_max_packets = floor(batch.fixed_max_packets);
    end
end

if batch.energy_threshold_sigma_low > batch.energy_threshold_sigma_high
    warning('decode_uwb_all:EnergyThresholdOrder', ...
        'Clamping the low energy threshold to the high threshold.');
    batch.energy_threshold_sigma_low = ...
        batch.energy_threshold_sigma_high;
end
if batch.energy_threshold_margin_db_low > ...
        batch.energy_threshold_margin_db_high
    warning('decode_uwb_all:EnergyMarginOrder', ...
        'Clamping the low energy dB margin to the high margin.');
    batch.energy_threshold_margin_db_low = ...
        batch.energy_threshold_margin_db_high;
end
if batch.energy_step_samples > batch.energy_chunk_samples
    warning('decode_uwb_all:StepExceedsChunk', ...
        ['energy_step_samples > energy_chunk_samples; ', ...
         'clamping step to chunk size.']);
    batch.energy_step_samples = batch.energy_chunk_samples;
end
if batch.correlation_overlap_samples >= batch.correlation_chunk_samples
    warning('decode_uwb_all:CorrelationOverlapTooLarge', ...
        'Clamping correlation overlap below the correlation chunk size.');
    batch.correlation_overlap_samples = ...
        max(1, floor(batch.correlation_chunk_samples/4));
end
batch.correlation_min_repetitions = min( ...
    batch.correlation_min_repetitions, batch.correlation_repetitions);
end

function [candidates, regions, stats] = predictFixedIntervalCandidates( ...
        params, batch, totalSamples)
%PREDICTFIXEDINTERVALCANDIDATES 由雷达首包时间和固定周期生成候选窗口。
%
% 候选采样位置按 round((t0 + k*T)*fs) 独立计算，避免先将周期取整后随包序号
% 累积量化误差。每个区域仅覆盖一次局部完整解码所需的窗口。

firstSample = round(batch.first_packet_time_s*params.fs_rx);
if firstSample >= totalSamples
    error('decode_uwb_all:FirstPacketOutsideCapture', ...
        ['The first packet starts at sample %d, outside the capture ', ...
         '(0..%d).'], firstSample, totalSamples - 1);
end

availableTime = (totalSamples - 1)/params.fs_rx - ...
    batch.first_packet_time_s;
scheduleCount = floor(availableTime/batch.packet_interval_s) + 1;
scheduleCount = min(scheduleCount, batch.fixed_max_packets);
packetIndices = (0:scheduleCount - 1).';
candidates = round((batch.first_packet_time_s + ...
    packetIndices*batch.packet_interval_s)*params.fs_rx);

regionStarts = max(0, candidates - batch.pre_packet_guard_samples);
regionEnds = min(totalSamples - 1, ...
    regionStarts + batch.window_samples - 1);
valid = regionStarts + batch.min_window_samples <= totalSamples;
candidates = candidates(valid);
regions = [regionStarts(valid), regionEnds(valid)];

stats = struct( ...
    'raw_candidate_count', numel(candidates), ...
    'scheduled_candidate_count', scheduleCount, ...
    'discarded_tail_count', scheduleCount - numel(candidates), ...
    'first_packet_sample', firstSample, ...
    'packet_interval_samples', batch.packet_interval_s*params.fs_rx, ...
    'candidate_source', 'fixed_interval_schedule', ...
    'skipped', true, ...
    'skip_reason', 'fixed_interval_schedule');
end

function totalSamples = countCaptureSamples(params)
%COUNTCAPTURESAMPLES 根据文件大小估算复数 IQ 采样点总数。
%
%   输入参数 params.file_name 指向原始采集文件；params.ant_num 指定文件中交错存储的
%   天线/通道数量。函数从 uwbdecoder.constants 取得单个复数 IQ 样本占用的字节数，
%   用“文件字节数 / (每个 IQ 样本字节数 * 天线数)”计算样本数，并向下取整。
%   返回值 totalSamples 是整个文件的零基采样坐标长度，不会读取大文件内容。
%
%   如果文件不存在，函数抛出带有 decode_uwb_all:FileNotFound 标识的错误。
info = dir(params.file_name);
if isempty(info)
    error('decode_uwb_all:FileNotFound', ...
        'Cannot find capture file: %s', params.file_name);
end
c = uwbdecoder.constants();
totalSamples = floor(info.bytes / (c.BYTES_PER_IQ_SAMPLE*params.ant_num));
end

function template = buildCoarseTemplate(params, reference, ~)
%BUILDCOARSETEMPLATE 构造完整接收采样率下的前导码相关模板。
%
%   输入参数：params 提供接收采样率；reference 由 UWB 参考信号构造函数生成，包含
%   前导码波形及其工作采样率；第三个参数为保留接口的批处理配置，目前不使用。
%   输出 template 是供粗到精相关搜索使用的结构体，包含归一化前导码、长度和抽取率。
%
%   当前输入文件必须已经位于 HRP 工作采样率网格上，因此函数要求 params.fs_rx 与
%   reference.fs 的差值不超过 1 Hz，并且明确将 decimation 设为 1，避免改变样本坐标。
if abs(params.fs_rx - reference.fs) > 1
    error('decode_uwb_all:SampleRateMismatch', ...
        ['Preprocessed input must use the HRP work rate %.3f MHz; ', ...
        'received %.3f MHz.'], reference.fs/1e6, params.fs_rx/1e6);
end
prefRx = reference.preamble_waveform(:);
prefRx = prefRx / (norm(prefRx) + eps);
template = struct( ...
    'decimation', 1, ...
    'preamble', prefRx, ...
    'preamble_rx_length', numel(prefRx));
end

function [regions, stats] = findEnergyRegions(params, batch, totalSamples, progress_cb)
%FINDENERGYREGIONS 通过真正的跨步文件读取定位能量突发区间。
%
%   函数按 batch.energy_step_samples 在文件中移动，以每个块的
%   batch.energy_read_stride 为步长读取 IQ，计算平滑能量包络。每个块使用低能量样本
%   的稳健中位数和 MAD 估计噪声基线，再结合 sigma 阈值和 dB 裕量形成高/低双阈值。
%   hysteresisEnergyRegions 保留“穿过高阈值且持续超过低阈值”的区间，最后合并跨
%   块重复检测并增加搜索保护区。
%
%   输出 regions 为带保护区的零基闭区间；stats 保存块偏移、阈值、覆盖率和原始区间等
%   诊断信息。progress_cb 为可选回调，调用形式为 progress_cb(frac)，其中 frac 属于
%   0 到 1，用于更新外部进度显示。
rawRegions = zeros(0, 2);
chunkCount = 0;
samplesRead = 0;
offset = 0;
estimatedChunks = ceil(totalSamples/batch.energy_step_samples);
if nargin < 4, progress_cb = []; end
chunkOffsets = zeros(estimatedChunks, 1);
thresholdHigh = zeros(estimatedChunks, 1);
thresholdLow = zeros(estimatedChunks, 1);
chunkRegionCount = zeros(estimatedChunks, 1);

while offset < totalSamples
    chunkSamples = min(batch.energy_chunk_samples, totalSamples - offset);
    chunkCount = chunkCount + 1;
    % 跨步读取：只读每 energy_read_stride 个 IQ 记录中的一个，降低 I/O 与转换量。
    [raw, sampleIndices] = uwbdecoder.readIqRawStrided( ...
        params.file_name, offset, chunkSamples, params.ant_num, ...
        batch.energy_read_stride, 'single');
    rx = uwbdecoder.selectIqChannel(raw, params.channel_index);
    clear raw;
    % 抽取网格上的滑动平均能量包络。
    smoothLength = max(3, round( ...
        batch.energy_smooth_rx_samples/batch.energy_read_stride));
    energy = movmean(abs(rx).^2, smoothLength);
    % 取能量最低的 baseline_fraction 部分作为噪声基线，用中位数 + MAD 估计底噪。
    baselineCount = max(32, floor( ...
        batch.energy_baseline_fraction*numel(energy)));
    baselineCount = min(baselineCount, numel(energy));
    baselineEnergy = mink(energy, baselineCount);
    energyMedian = median(baselineEnergy);
    energySigma = 1.4826*median(abs(baselineEnergy - energyMedian));
    robustSigma = max(energySigma, ...
        eps(max(abs(energyMedian), single(1))));
    adaptiveHigh = energyMedian + ...
        batch.energy_threshold_sigma_high*robustSigma;
    adaptiveLow = energyMedian + ...
        batch.energy_threshold_sigma_low*robustSigma;
    marginHigh = energyMedian* ...
        10^(batch.energy_threshold_margin_db_high/10);
    marginLow = energyMedian* ...
        10^(batch.energy_threshold_margin_db_low/10);
    % 双阈值取“sigma 阈值”与“dB 裕量阈值”的较大者，形成滞回检测的高/低门限。
    high = max(adaptiveHigh, marginHigh);
    low = max(adaptiveLow, marginLow);

    localRegions = hysteresisEnergyRegions( ...
        energy, sampleIndices, high, low, ...
        batch.energy_read_stride, batch.energy_min_region_samples, ...
        offset + chunkSamples - 1);
    if ~isempty(localRegions)
        rawRegions = [rawRegions; localRegions]; %#ok<AGROW>
    end

    samplesRead = samplesRead + numel(sampleIndices);
    chunkOffsets(chunkCount) = offset;
    thresholdHigh(chunkCount) = high;
    thresholdLow(chunkCount) = low;
    chunkRegionCount(chunkCount) = size(localRegions, 1);

    if ~isempty(progress_cb)
        progress_cb(min(1, offset / totalSamples));
    end

    if offset + chunkSamples >= totalSamples
        break;
    end
    offset = offset + batch.energy_step_samples;
end

% 在增加搜索保护区之前，先合并因文件块重叠造成的重复原始检测。保护区发生重叠
% 时不能把两个数据包身份合并，因此相邻保护窗口会在两个原始能量核心的中点处裁切。
rawRegions = mergeIntervals( ...
    rawRegions, batch.energy_region_merge_samples);
regions = addIndependentGuards(rawRegions, ...
    batch.energy_region_pre_guard_samples, ...
    batch.energy_region_post_guard_samples, totalSamples);
stats = struct( ...
    'chunk_count', chunkCount, ...
    'samples_read', samplesRead, ...
    'read_fraction', samplesRead/max(totalSamples, 1), ...
    'read_stride', batch.energy_read_stride, ...
    'chunk_offsets', chunkOffsets(1:chunkCount), ...
    'threshold_high', thresholdHigh(1:chunkCount), ...
    'threshold_low', thresholdLow(1:chunkCount), ...
    'chunk_region_count', chunkRegionCount(1:chunkCount), ...
    'raw_regions', rawRegions, ...
    'raw_region_count', size(rawRegions, 1), ...
    'raw_coverage', intervalCoverage(rawRegions, totalSamples), ...
    'final_coverage', intervalCoverage(regions, totalSamples));
end

function regions = hysteresisEnergyRegions(energy, sampleIndices, ...
        highThreshold, lowThreshold, stride, minRegionSamples, chunkLast)
%HYSTERESISENERGYREGIONS 提取包含高阈值穿越的低阈值连续能量区间。
%
%   energy 是跨步采样后的能量序列，sampleIndices 给出每个能量点在原文件中的绝对
%   采样位置。函数先找出 energy > lowThreshold 的连续运行，再要求运行内部至少有
%   一个点超过 highThreshold，以抑制纯噪声抬升。区间终点会按 stride 扩展到对应的
%   原始采样范围，并受 chunkLast 限制；长度不足 minRegionSamples 的区间被丢弃。
%   返回值使用零基且包含终点的 [start, end] 区间矩阵。
highMask = energy > highThreshold;
lowMask = energy > lowThreshold;
edges = diff([false; lowMask(:); false]);
runStarts = find(edges == 1);
runEnds = find(edges == -1) - 1;
regions = zeros(0, 2);
for k = 1:numel(runStarts)
    first = runStarts(k);
    last = runEnds(k);
    if ~any(highMask(first:last))
        continue;
    end
    absFirst = sampleIndices(first);
    absLast = min(chunkLast, sampleIndices(last) + stride - 1);
    if absLast - absFirst + 1 < minRegionSamples
        continue;
    end
    regions(end + 1, :) = [absFirst, absLast]; %#ok<AGROW>
end
end

function [candidates, candidateRegions, stats] = refineEnergyRegions( ...
        params, template, batch, energyRegions, rawEnergyRegions, ...
        totalSamples, progress_cb)
%REFINEENERGYREGIONS 在能量区间内自适应搜索一个或多个数据包。
%
%   对每个能量区间，函数只在完整采样率下扫描第一段前导码，先得到相关峰候选，
%   再沿前导码重复周期逐次验证候选。验证达到最小重复次数、阈值比和命中条件后
%   立即接受；窄搜索失败时依次扩大到更宽的搜索范围。对明显长于典型单包长度的
%   能量区间，还会继续扫描尾部，以发现同一区间内紧邻的多个数据包。
%
%   输入的 energyRegions 是加过保护区的搜索区间，rawEnergyRegions 是未加保护区的
%   原始区间，两者必须逐行对应。输出 candidates 为候选前导码起点，candidateRegions
%   为每个候选对应的搜索区间；stats 汇总每个区间的扫描量、验证量、阈值比和多包检测
%   情况。progress_cb 为可选的区间级进度回调。
if nargin < 7, progress_cb = []; end
regionCount = size(energyRegions, 1);
if size(rawEnergyRegions, 1) ~= regionCount
    error('decode_uwb_all:EnergyRegionMismatch', ...
        'Raw and guarded energy-region counts must match.');
end

candidates = zeros(0, 1);
candidateRegions = zeros(0, 2);
candidateRegionIndex = zeros(0, 1);
detectedMask = false(regionCount, 1);
searchLevelUsed = zeros(regionCount, 1);
repetitionsUsed = zeros(regionCount, 1);
candidatesTested = zeros(regionCount, 1);
scannedDelayCount = zeros(regionCount, 1);
regionCandidateCount = zeros(regionCount, 1);
regionPacketCount = zeros(regionCount, 1);
finalThresholdRatios = zeros(regionCount, 1);
scanIntervalCount = zeros(regionCount, 1);
tailSearchUsed = false(regionCount, 1);

% 统计“典型单包长度”：取原始区间长度的中位数，用于把异常长的区间识别为多包候选。
rawRegionLengths = rawEnergyRegions(:, 2) - rawEnergyRegions(:, 1) + 1;
if regionCount == 0
    nominalSingleRegionSamples = 0;
    longRegionThresholdSamples = Inf;
else
    sortedRegionLengths = sort(rawRegionLengths);
    baselineRegionCount = max(1, floor( ...
        batch.correlation_single_region_baseline_fraction*regionCount));
    nominalSingleRegionSamples = median( ...
        sortedRegionLengths(1:baselineRegionCount));
    longRegionThresholdSamples = max( ...
        batch.correlation_long_region_threshold_factor* ...
            nominalSingleRegionSamples, ...
        nominalSingleRegionSamples + ...
            batch.correlation_long_region_threshold_margin_samples);
end
packetExclusionSamples = max( ...
    batch.correlation_packet_exclusion_repetitions* ...
        template.preamble_rx_length, ...
    round(batch.correlation_min_packet_separation_fraction* ...
        nominalSingleRegionSamples));
suspiciousLongRegionMask = rawRegionLengths >= ...
    longRegionThresholdSamples;

% 对每个能量区间执行三级自适应相关搜索；异常长区间额外扫描尾部以发现第二个包。
for regionIdx = 1:regionCount
    [detection, diagnostics] = adaptiveCorrelationCandidate( ...
        params, template.preamble, batch, energyRegions(regionIdx, :), ...
        rawEnergyRegions(regionIdx, 1), totalSamples);
    regionDetections = detection;
    if detection.detected && batch.correlation_multi_packet_search && ...
            suspiciousLongRegionMask(regionIdx)
        [tailDetections, tailDiagnostics] = ...
            searchTailCorrelationCandidates( ...
            params, template.preamble, batch, ...
            rawEnergyRegions(regionIdx, :), detection.candidate, ...
            packetExclusionSamples, totalSamples);
        diagnostics.candidates_tested = diagnostics.candidates_tested + ...
            tailDiagnostics.candidates_tested;
        diagnostics.candidates_extracted = ...
            diagnostics.candidates_extracted + ...
            tailDiagnostics.candidates_extracted;
        diagnostics.scanned_delay_count = ...
            diagnostics.scanned_delay_count + ...
            tailDiagnostics.scanned_delay_count;
        diagnostics.scan_interval_count = ...
            diagnostics.scan_interval_count + ...
            tailDiagnostics.scan_interval_count;
        tailSearchUsed(regionIdx) = tailDiagnostics.search_used;
        if ~isempty(tailDetections)
            regionDetections = [regionDetections; ...
                tailDetections(:)]; %#ok<AGROW>
            [~, order] = sort([regionDetections.candidate]);
            regionDetections = regionDetections(order);
        end
    end

    regionCandidates = [regionDetections.candidate].';
    packetCount = numel(regionCandidates);
    candidates = [candidates; regionCandidates]; %#ok<AGROW>
    candidateRegions = [candidateRegions; ...
        repmat(energyRegions(regionIdx, :), packetCount, 1)]; %#ok<AGROW>
    candidateRegionIndex = [candidateRegionIndex; ...
        repmat(regionIdx, packetCount, 1)]; %#ok<AGROW>
    detectedMask(regionIdx) = detection.detected;
    searchLevelUsed(regionIdx) = detection.level;
    repetitionsUsed(regionIdx) = detection.repetitions_used;
    finalThresholdRatios(regionIdx) = detection.threshold_ratio;
    candidatesTested(regionIdx) = diagnostics.candidates_tested;
    scannedDelayCount(regionIdx) = diagnostics.scanned_delay_count;
    regionCandidateCount(regionIdx) = diagnostics.candidates_extracted;
    regionPacketCount(regionIdx) = packetCount;
    scanIntervalCount(regionIdx) = diagnostics.scan_interval_count;

    if ~isempty(progress_cb)
        progress_cb(regionIdx/max(regionCount, 1));
    end
end

candidateOffsets = max(0, max( ...
    candidates - batch.pre_packet_guard_samples, ...
    candidateRegions(:, 1)));
valid = candidateOffsets + batch.min_window_samples <= totalSamples;
candidates = candidates(valid);
candidateRegions = candidateRegions(valid, :);
candidateRegionIndex = candidateRegionIndex(valid);
stats = struct( ...
    'region_count', regionCount, ...
    'correlation_chunk_count', sum(scanIntervalCount), ...
    'raw_candidate_count', sum(regionCandidateCount), ...
    'fallback_candidate_count', nnz(~detectedMask), ...
    'region_candidate_count', regionCandidateCount, ...
    'region_packet_count', regionPacketCount, ...
    'multi_packet_region_count', nnz(regionPacketCount > 1), ...
    'candidate_region_index', candidateRegionIndex, ...
    'decimation', 1, ...
    'detected_mask', detectedMask, ...
    'search_level_used', searchLevelUsed, ...
    'repetitions_used', repetitionsUsed, ...
    'candidates_tested', candidatesTested, ...
    'scanned_delay_count', scannedDelayCount, ...
    'final_threshold_ratios', finalThresholdRatios, ...
    'scan_interval_count', scanIntervalCount, ...
    'tail_search_used', tailSearchUsed, ...
    'suspicious_long_region_mask', suspiciousLongRegionMask, ...
    'nominal_single_region_samples', nominalSingleRegionSamples, ...
    'long_region_threshold_samples', longRegionThresholdSamples, ...
    'packet_exclusion_samples', packetExclusionSamples);
end

function [detection, diagnostics] = adaptiveCorrelationCandidate( ...
        params, preambleTemplate, batch, guardedRegion, rawStart, ...
        totalSamples)
%ADAPTIVECORRELATIONCANDIDATE 对单个能量区间执行三级自适应前导码搜索。
%
%   搜索范围以原始能量起点 rawStart 为中心，依次尝试较窄、较宽和完整保护区三种
%   level。每一级只扫描相对于上一级新增的区间，避免重复读取和重复计算。对扫描
%   到的相关峰，函数按照“最接近预期前导码偏移”的顺序调用
%   validateCorrelationCandidate，并在第一个通过的候选处提前返回。
%
%   detection 保存是否检测成功、候选位置、使用的搜索级别、重复次数和阈值比；
%   diagnostics 保存测试候选数、扫描采样点数、扫描子区间数等性能统计。所有位置
%   都是相对于整个输入文件的零基采样坐标。
templateLength = numel(preambleTemplate);
repetitionPeriod = templateLength;
maxDelay = max(0, totalSamples - templateLength);
rawStart = min(max(0, rawStart), maxDelay);

% 三级搜索窗（零基闭区间）：Level 1 窄窗 -> Level 2 宽窗 -> Level 3 整个保护区。
levelBounds = [ ...
    rawStart - batch.correlation_search_level_1_pre_samples, ...
    rawStart + batch.correlation_search_level_1_post_samples; ...
    rawStart - batch.correlation_search_level_2_pre_samples, ...
    rawStart + batch.correlation_search_level_2_post_samples];
levelBounds(:, 1) = max(0, levelBounds(:, 1));
levelBounds(:, 2) = min(maxDelay, levelBounds(:, 2));
levelBounds(3, :) = [ ...
    min(guardedRegion(1), levelBounds(2, 1)), ...
    max(guardedRegion(2), levelBounds(2, 2))];
levelBounds(3, 1) = max(0, levelBounds(3, 1));
levelBounds(3, 2) = min(maxDelay, levelBounds(3, 2));

detection = emptyCorrelationDetection(rawStart);
diagnostics = struct( ...
    'candidates_tested', 0, ...
    'candidates_extracted', 0, ...
    'scanned_delay_count', 0, ...
    'scan_interval_count', 0);
previousBounds = zeros(0, 2);

for level = 1:3
    currentBounds = levelBounds(level, :);
    newIntervals = newCorrelationSearchIntervals( ...
        currentBounds, previousBounds);
    if isempty(newIntervals)
        previousBounds = currentBounds;
        continue;
    end

    bufferStart = currentBounds(1);
    bufferEnd = min(totalSamples - 1, currentBounds(2) + ...
        (batch.correlation_repetitions - 1)*repetitionPeriod + ...
        templateLength - 1);
    rxBuffer = readProcessedBuffer( ...
        params, bufferStart, bufferEnd - bufferStart + 1);

    levelCandidates = zeros(0, 1);
    levelCandidateEnergy = zeros(0, 1);
    levelCandidateThreshold = zeros(0, 1);
    for intervalIdx = 1:size(newIntervals, 1)
        interval = newIntervals(intervalIdx, :);
        [correlationEnergy, threshold] = ...
            scanFirstRepetition(rxBuffer, bufferStart, interval, ...
            preambleTemplate, batch.correlation_baseline_fraction, ...
            batch.corr_threshold_sigma);
        diagnostics.scanned_delay_count = ...
            diagnostics.scanned_delay_count + numel(correlationEnergy);
        diagnostics.scan_interval_count = ...
            diagnostics.scan_interval_count + 1;
        [candidatePositions, candidateEnergy] = ...
            extractCorrelationCandidates(interval(1), ...
            correlationEnergy, threshold, ...
            batch.corr_candidate_relative_level, ...
            batch.correlation_peak_min_distance_samples);
        levelCandidates = [levelCandidates; candidatePositions]; %#ok<AGROW>
        levelCandidateEnergy = [ ...
            levelCandidateEnergy; candidateEnergy]; %#ok<AGROW>
        levelCandidateThreshold = [levelCandidateThreshold; ...
            repmat(threshold, numel(candidatePositions), 1)]; %#ok<AGROW>
    end
    diagnostics.candidates_extracted = ...
        diagnostics.candidates_extracted + numel(levelCandidates);

    if ~isempty(levelCandidates)
        expectedCandidate = rawStart + ...
            batch.correlation_expected_offset_samples;
        [~, priority] = sort(abs(levelCandidates - expectedCandidate));
        levelCandidates = levelCandidates(priority);
        levelCandidateEnergy = levelCandidateEnergy(priority);
        levelCandidateThreshold = levelCandidateThreshold(priority);
    end

    % 按“离预期前导码偏移最近”的顺序逐个验证，第一个通过验证的候选即为检测结果。
    for candidateIdx = 1:numel(levelCandidates)
        diagnostics.candidates_tested = ...
            diagnostics.candidates_tested + 1;
        validation = validateCorrelationCandidate( ...
            rxBuffer, bufferStart, levelCandidates(candidateIdx), ...
            levelCandidateEnergy(candidateIdx), ...
            levelCandidateThreshold(candidateIdx), preambleTemplate, ...
            repetitionPeriod, batch.correlation_min_repetitions, ...
            batch.correlation_repetitions, ...
            batch.corr_min_threshold_ratio, ...
            batch.corr_require_hit_every_repetition);
        if validation.detected
            detection = validation;
            detection.candidate = levelCandidates(candidateIdx);
            detection.level = level;
            return;
        end
    end
    previousBounds = currentBounds;
end
end

function [detections, diagnostics] = searchTailCorrelationCandidates( ...
        params, preambleTemplate, batch, rawRegion, primaryCandidate, ...
        packetExclusionSamples, totalSamples)
%SEARCHTAILCORRELATIONCANDIDATES 在主候选之后继续搜索同一区间内的其他数据包。
%
%   当一个能量区间异常偏长时，主候选之后可能还存在第二个或更多数据包。本函数从
%   primaryCandidate + packetExclusionSamples 开始，按块扫描到原始区间尾部附近，
%   对每个相关峰使用多次前导码重复进行验证。搜索缓冲区会额外读取后续重复前导码
%   所需的样本，避免候选位于块尾时无法验证。
%
%   返回的 detections 会经过 selectPacketDetections 分组和最小包间隔抑制；diagnostics
%   记录扫描区间、候选和验证次数，并通过 search_used 标记本次是否实际有可搜索范围。
templateLength = numel(preambleTemplate);
repetitionPeriod = templateLength;
maxDelay = max(0, totalSamples - templateLength);
tailStart = primaryCandidate + packetExclusionSamples;
tailEnd = min(maxDelay, rawRegion(2) + ...
    batch.correlation_search_level_1_post_samples);
diagnostics = struct( ...
    'candidates_tested', 0, ...
    'candidates_extracted', 0, ...
    'scanned_delay_count', 0, ...
    'scan_interval_count', 0, ...
    'search_used', tailStart <= tailEnd);
emptyDetection = emptyCorrelationDetection(0);
validated = emptyDetection([]);

while tailStart <= tailEnd
    chunkEnd = min(tailEnd, ...
        tailStart + batch.correlation_tail_chunk_samples - 1);
    bufferStart = tailStart;
    bufferEnd = min(totalSamples - 1, chunkEnd + ...
        (batch.correlation_repetitions - 1)*repetitionPeriod + ...
        templateLength - 1);
    rxBuffer = readProcessedBuffer( ...
        params, bufferStart, bufferEnd - bufferStart + 1);
    [correlationEnergy, threshold] = ...
        scanFirstRepetition(rxBuffer, bufferStart, ...
        [tailStart, chunkEnd], preambleTemplate, ...
        batch.correlation_baseline_fraction, ...
        batch.corr_threshold_sigma);
    diagnostics.scanned_delay_count = ...
        diagnostics.scanned_delay_count + numel(correlationEnergy);
    diagnostics.scan_interval_count = ...
        diagnostics.scan_interval_count + 1;
    [candidatePositions, candidateEnergy] = ...
        extractCorrelationCandidates(tailStart, ...
        correlationEnergy, threshold, ...
        batch.corr_candidate_relative_level, ...
        batch.correlation_peak_min_distance_samples);
    diagnostics.candidates_extracted = ...
        diagnostics.candidates_extracted + numel(candidatePositions);

    for candidateIdx = 1:numel(candidatePositions)
        diagnostics.candidates_tested = ...
            diagnostics.candidates_tested + 1;
        validation = validateCorrelationCandidate( ...
            rxBuffer, bufferStart, candidatePositions(candidateIdx), ...
            candidateEnergy(candidateIdx), threshold, ...
            preambleTemplate, repetitionPeriod, ...
            batch.correlation_min_repetitions, ...
            batch.correlation_repetitions, ...
            batch.corr_min_threshold_ratio, ...
            batch.corr_require_hit_every_repetition);
        if validation.detected
            validation.candidate = candidatePositions(candidateIdx);
            validation.level = 4;
            validated(end + 1, 1) = validation; %#ok<AGROW>
        end
    end
    tailStart = chunkEnd + 1;
end

detections = selectPacketDetections(validated, ...
    packetExclusionSamples, ...
    batch.correlation_candidate_train_gap_repetitions* ...
        repetitionPeriod);
end

function selected = selectPacketDetections( ...
        detections, minimumPacketSpacing, trainGap)
%SELECTPACKETDETECTIONS 将重复峰分组为候选列车，并抑制过近的数据包候选。
%
%   输入 detections 可能包含同一数据包在不同重复位置形成的多个检测结果。函数先按
%   candidate 时间排序，把相邻间隔不超过 trainGap 的检测归为同一候选列车；每列车以
%   平均重复相关能量最大的检测作为强度代表。随后按列车强度从高到低贪心保留候选，
%   要求任意两个保留位置至少相隔 minimumPacketSpacing 个采样点。
%   输出最终按时间重新排序，便于上层按文件顺序处理和去重。
if isempty(detections)
    selected = detections;
    return;
end

[~, timeOrder] = sort([detections.candidate]);
detections = detections(timeOrder);
candidateSamples = [detections.candidate].';
trainStarts = [1; find(diff(candidateSamples) > trainGap) + 1];
trainEnds = [trainStarts(2:end) - 1; numel(detections)];
representatives = detections(trainStarts);
trainScores = zeros(numel(trainStarts), 1);
for trainIdx = 1:numel(trainStarts)
    members = trainStarts(trainIdx):trainEnds(trainIdx);
    memberScores = zeros(numel(members), 1);
    for memberIdx = 1:numel(members)
        memberScores(memberIdx) = mean( ...
            detections(members(memberIdx)).per_rep_energy);
    end
    [trainScores(trainIdx), bestMember] = max(memberScores);
    representatives(trainIdx) = detections(members(bestMember));
end

[~, strengthOrder] = sort(trainScores, 'descend');
keep = false(numel(representatives), 1);
keptCandidates = zeros(0, 1);
for priorityIdx = 1:numel(strengthOrder)
    representativeIdx = strengthOrder(priorityIdx);
    candidate = representatives(representativeIdx).candidate;
    if isempty(keptCandidates) || all(abs( ...
            candidate - keptCandidates) >= minimumPacketSpacing)
        keep(representativeIdx) = true;
        keptCandidates(end + 1, 1) = candidate; %#ok<AGROW>
    end
end
selected = representatives(keep);
if ~isempty(selected)
    [~, timeOrder] = sort([selected.candidate]);
    selected = reshape(selected(timeOrder), [], 1);
end
end

function detection = emptyCorrelationDetection(fallbackCandidate)
%EMPTYCORRELATIONDETECTION 创建统一格式的“未检测到候选”结果。
%
%   自适应搜索和尾部搜索需要在没有检测结果时仍返回结构字段完整的对象。本函数
%   使用 fallbackCandidate 初始化 candidate，其余字段填入安全的默认值；调用者
%   可以在此基础上更新 detected、level、repetitions_used 等字段，避免不同分支返回
%   不同结构而导致后续拼接失败。
detection = struct( ...
    'detected', false, ...
    'candidate', fallbackCandidate, ...
    'level', 3, ...
    'repetitions_used', 0, ...
    'threshold_ratio', 0, ...
    'hit_count', 0, ...
    'per_rep_energy', zeros(0, 1));
end

function intervals = newCorrelationSearchIntervals(current, previous)
%NEWCORRELATIONSEARCHINTERVALS 计算当前搜索范围相对于上一级新增的区间。
%
%   current 和 previous 均为 [start, end] 的闭区间。若当前范围扩大，函数只返回左侧
%   或右侧新增部分；若范围完全包含于 previous，则返回空矩阵。这样三级自适应搜索
%   可以复用已经扫描过的样本，避免同一位置被重复计算。首次搜索时 previous 为空，
%   直接返回 current。
if isempty(previous)
    intervals = current;
    return;
end
intervals = zeros(0, 2);
if current(1) < previous(1)
    intervals(end + 1, :) = [current(1), previous(1) - 1];
end
if current(2) > previous(2)
    intervals(end + 1, :) = [previous(2) + 1, current(2)];
end
end

function rx = readProcessedBuffer(params, sampleOffset, sampleNum)
%READPROCESSEDBUFFER 读取指定文件窗口并选择目标 IQ 通道。
%
%   sampleOffset 是相对于整个采集文件的零基起点，sampleNum 是要读取的复数样本数。
%   函数先调用统一的原始 IQ 读取接口，再根据 params.channel_index 选择单路信号。
%   输入文件已经处于 HRP 预处理工作采样率，因此这里不再重采样、不改变样本网格，
%   也不额外归一化幅度，以便相关结果与绝对采样坐标保持一致。
raw = uwbdecoder.readIqRaw( ...
    params.file_name, sampleOffset, sampleNum, params.ant_num, 'single');
rx = uwbdecoder.selectIqChannel(raw, params.channel_index);
% 采集数据已经位于预处理后的 HRP 网格上，因此保持采样网格和幅度不变。
end

function [energy, threshold] = scanFirstRepetition( ...
        rxBuffer, bufferStart, interval, preambleTemplate, ...
        baselineFraction, thresholdSigma)
%SCANFIRSTREPETITION 扫描指定区间内第一段前导码的归一化相关能量。
%
%   为了计算区间末端的完整相关窗口，rxBuffer 通常比 interval 多包含
%   templateLength-1 个样本。函数使用 FFT 快速相关得到匹配输出，再用滑动接收能量
%   做归一化，形成不易受幅度变化影响的 score^2。随后用低分位样本估计稳健阈值，
%   返回每个延迟位置的绝对采样坐标、相关能量和该扫描区间的统一阈值。
%   positions 使用零基文件坐标；energy 与 positions 等长。
templateLength = numel(preambleTemplate);
width = interval(2) - interval(1) + 1;
segmentFirst = interval(1) - bufferStart + 1;
segmentLast = segmentFirst + width + templateLength - 2;
segment = rxBuffer(segmentFirst:segmentLast);
% FFT 快速匹配滤波，得到每个延迟点的相关输出。
matched = uwbdecoder.fftFilter( ...
    flipud(conj(preambleTemplate)), segment);
% 滑动接收能量归一化，使相关得分不受幅度变化影响。
receiveNorm = sqrt(movsum(abs(segment).^2, ...
    [templateLength - 1, 0])) + eps;
% 去掉滤波器瞬态段，只保留与 interval 内各延迟点对齐的能量。
validRange = templateLength:templateLength + width - 1;
energy = (abs(matched(validRange))./receiveNorm(validRange)).^2;
% 从能量低分位估计稳健噪声阈值。
threshold = robustCorrelationThreshold( ...
    energy, baselineFraction, thresholdSigma);
end

function [positions, values] = extractCorrelationCandidates( ...
        firstPosition, energy, threshold, relativeLevel, minDistance)
%EXTRACTCORRELATIONCANDIDATES 从相关能量曲线中提取峰值候选。
%
%   峰值必须同时高于稳健噪声阈值 threshold 和全局最大能量的相对门限
%   relativeLevel。优先使用 findpeaks；当 Signal Processing Toolbox 不可用时，
%   使用本文件中的 simpleFindPeaks 兼容实现。minDistance 会先被限制在当前曲线
%   长度允许的范围内，防止 findpeaks 因最小峰距过大而报错。
%   输出 positions 是文件坐标下的峰位置，values 是对应峰能量，二者逐项对应。
level = max(threshold, relativeLevel*max(energy));
% 将 MinPeakDistance 限制在安全范围内；当它大于能量曲线长度时 findpeaks 会报错。
minDistance = max(1, min( ...
    round(minDistance), ...
    floor(length(energy)/2) - 1));
if exist('findpeaks', 'file') == 2
    [values, locations] = findpeaks(energy, ...
        'MinPeakHeight', level, ...
        'MinPeakDistance', minDistance);
else
    locations = simpleFindPeaks(energy, level, minDistance);
    values = energy(locations);
end
positions = firstPosition + locations(:) - 1;
values = values(:);
end

function result = validateCorrelationCandidate( ...
        rxBuffer, bufferStart, candidate, firstEnergy, singleThreshold, ...
        preambleTemplate, repetitionPeriod, minRepetitions, ...
        maxRepetitions, minThresholdRatio, requireAllHits)
%VALIDATECORRELATIONCANDIDATE 用前导码重复序列确认一个相关峰是否真实。
%
%   candidate 表示第一段前导码的起点。函数按 repetitionPeriod 读取后续重复段，
%   对每段计算归一化相关能量，并维护截至当前重复的平均能量/单段阈值比。达到
%   minRepetitions 后，只有阈值比不低于 minThresholdRatio 且满足命中要求才判定成功；
%   requireAllHits 为真时，已检查的每一次重复都必须超过单段阈值。验证一旦成功就
%   提前结束，减少长前导码的计算量；若缓冲区不足以读取下一段，则安全停止。
%   输出 result 同时保留每段能量、实际使用的重复次数、命中数和最终阈值比。
templateLength = numel(preambleTemplate);
perRepEnergy = zeros(maxRepetitions, 1);
perRepEnergy(1) = firstEnergy;
hitCount = double(firstEnergy > singleThreshold);
detected = false;
thresholdRatio = 0;

% 逐段验证后续重复前导码；一旦达到阈值比与命中数要求就提前接受。
for repetition = 1:maxRepetitions
    if repetition > 1
        windowFirst = candidate - bufferStart + 1 + ...
            (repetition - 1)*repetitionPeriod;
        windowLast = windowFirst + templateLength - 1;
        if windowFirst < 1 || windowLast > numel(rxBuffer)
            break;
        end
        window = rxBuffer(windowFirst:windowLast);
        score = abs(sum(window.*conj(preambleTemplate))) / ...
            (sqrt(sum(abs(window).^2)) + eps);
        perRepEnergy(repetition) = score.^2;
        hitCount = hitCount + ...
            (perRepEnergy(repetition) > singleThreshold);
    end
    thresholdRatio = mean(perRepEnergy(1:repetition)) / ...
        max(singleThreshold, eps);
    enoughHits = hitCount >= minRepetitions;
    if requireAllHits
        enoughHits = hitCount == repetition;
    end
    if repetition >= minRepetitions && ...
            thresholdRatio >= minThresholdRatio && enoughHits
        detected = true;
        break;
    end
end

result = struct( ...
    'detected', detected, ...
    'candidate', 0, ...
    'level', 0, ...
    'repetitions_used', repetition, ...
    'threshold_ratio', thresholdRatio, ...
    'hit_count', hitCount, ...
    'per_rep_energy', perRepEnergy(1:repetition));
end

function threshold = robustCorrelationThreshold( ...
        metric, baselineFraction, thresholdSigma)
%ROBUSTCORRELATIONTHRESHOLD 从相关指标的低能量部分估计稳健检测阈值。
%
%   函数将 metric 升序排列，取最低 baselineFraction 比例作为噪声基线，并用中位数
%   与 MAD（乘以 1.4826 后近似标准差）估计中心和离散程度。返回值为
%   baselineMedian + thresholdSigma * baselineSigma。至少保留 16 个样本作为基线，
%   同时用 eps 防止全零或近似常数信号造成除零和零阈值问题。
baselineCount = max(16, floor(baselineFraction*numel(metric)));
baselineCount = min(baselineCount, numel(metric));
baseline = mink(metric, baselineCount);
baselineMedian = median(baseline);
baselineSigma = 1.4826*median(abs(baseline - baselineMedian));
threshold = baselineMedian + ...
    thresholdSigma*max(baselineSigma, eps);
end

function locs = simpleFindPeaks(metric, threshold, minSep)
%SIMPLEFINDPEAKS 在没有 Signal Toolbox 时使用的简易峰值检测器。
%
%   函数扫描内部点，保留不低于 threshold 且不小于左右邻点的局部峰。候选峰随后
%   按幅度从强到弱排序，采用贪心策略保留相互间至少相隔 minSep 的峰，最后按位置
%   升序返回。它只提供本文件所需的基本 findpeaks 行为，不处理复杂平台峰、峰宽或
%   插值，因此主要用于缺少工具箱时保证流程仍可运行。
locs = zeros(0, 1);
n = numel(metric);
if n < 3
    return;
end
candidate = false(n, 1);
for k = 2:n-1
    if metric(k) >= threshold && ...
            metric(k) >= metric(k-1) && metric(k) >= metric(k+1)
        candidate(k) = true;
    end
end
idx = find(candidate);
if isempty(idx)
    return;
end
% 按峰值强度贪心保留相互分离的峰。
[~, order] = sort(metric(idx), 'descend');
idx = idx(order);
keep = false(size(idx));
for k = 1:numel(idx)
    if all(abs(idx(k) - idx(keep)) >= minSep)
        keep(k) = true;
    end
end
locs = sort(idx(keep));
end

function merged = mergeIntervals(intervals, mergeGap)
%MERGEINTERVALS 合并重叠或间隔不超过 mergeGap 的零基闭区间。
%
%   输入 intervals 的每行是 [start, end]，函数先四舍五入并按起点、终点排序，再按
%   时间顺序逐行合并。由于区间终点包含在内，两个区间在“前一区间终点 + mergeGap
%   + 1”以内时视为同一段。返回值仍是按时间排序的闭区间矩阵；空输入返回 0x2 矩阵。
if isempty(intervals)
    merged = zeros(0, 2);
    return;
end
intervals = sortrows(round(intervals), [1, 2]);
merged = intervals(1, :);
for k = 2:size(intervals, 1)
    if intervals(k, 1) <= merged(end, 2) + mergeGap + 1
        merged(end, 2) = max(merged(end, 2), intervals(k, 2));
    else
        merged(end + 1, :) = intervals(k, :); %#ok<AGROW>
    end
end
end

function guarded = addIndependentGuards( ...
        coreRegions, preGuard, postGuard, totalSamples)
%ADDINDEPENDENTGUARDS 为核心能量区间增加前后保护样本，同时保持区间独立。
%
%   每个核心区间分别向前扩展 preGuard、向后扩展 postGuard，并将结果限制在
%   [0, totalSamples-1] 内。若相邻区间扩展后的保护区发生重叠，不把它们再次合并，
%   而是在两个原始核心区间之间的中点切开共享部分，从而既给相关搜索足够上下文，
%   又避免两个相邻数据包被错误地当成同一个候选区间。
if isempty(coreRegions)
    guarded = zeros(0, 2);
    return;
end

guarded = coreRegions;
guarded(:, 1) = max(0, guarded(:, 1) - preGuard);
guarded(:, 2) = min(totalSamples - 1, ...
    guarded(:, 2) + postGuard);

for k = 1:size(coreRegions, 1) - 1
    splitSample = floor((coreRegions(k, 2) + ...
        coreRegions(k + 1, 1))/2);
    guarded(k, 2) = min(guarded(k, 2), splitSample);
    guarded(k + 1, 1) = max( ...
        guarded(k + 1, 1), splitSample + 1);
end
end

function coverage = intervalCoverage(intervals, totalSamples)
%INTERVALCOVERAGE 计算若干零基闭区间覆盖整个采集文件的比例。
%
%   每行区间长度按 end-start+1 计算，所有区间默认已经过合并，因此直接求和即可。
%   totalSamples 用于归一化；当没有区间时返回 0，当总样本数为 0 时通过 max(...,1)
%   避免除零。该指标主要用于能量粗扫描的诊断和性能评估。
if isempty(intervals)
    coverage = 0;
    return;
end
coveredSamples = sum(intervals(:, 2) - intervals(:, 1) + 1);
coverage = coveredSamples/max(totalSamples, 1);
end

function absSample = absoluteRxSample(sampleOffset, workSample, fsRx, fsWork)
%ABSOLUTERXSAMPLE 将解码窗口内的工作采样坐标换算为文件绝对采样坐标。
%
%   workSample 采用 MATLAB 风格的 1 基工作网格，sampleOffset 是该窗口在文件中的
%   零基起点。函数先按 fsRx/fsWork 换算采样率差异，再四舍五入到文件采样点，并将
%   结果限制为不小于 0。该转换集中处理窗口偏移和采样率映射，避免各处重复出现
%   1 基/0 基混用的偏移错误。
absSample = sampleOffset + round((workSample - 1)*fsRx / fsWork);
absSample = max(0, absSample);
end

function timing = locateDecodedFrameSamples(sampleOffset, result, params, ...
        reference, batch, totalSamples)
%LOCATEDECODEDFRAMESAMPLES 将解码器输出的帧坐标转换为文件绝对坐标。
%
%   函数首先取得未裁剪前导码起点，再把 PHR 和 PSDU 的 chip 索引映射到文件采样点。
%   数据包结束点优先使用已解码 PSDU 的最后一个 chip，其次使用 PHR 末 chip；若两者
%   均不可用，则依据前导码重复数、SFD 长度和固定数据部分长度给出估计终点。
%   同时生成用于后续定位/留白分析的前后保护区，并将所有结果裁剪到采集文件范围。
%
%   返回的所有绝对索引均为零基，区间终点均包含在内；当某个 chip 坐标不可用时，
%   对应字段使用 NaN，调用者可通过 isfinite 判断是否为精确定位结果。
startWork = uncroppedPreambleStart(result);
absStart = absoluteRxSample( ...
    sampleOffset, startWork, params.fs_rx, reference.fs);

phrStart = chipIndexToAbsolute( ...
    sampleOffset, result, result.phr.start_chip, params, reference);
phrEnd = chipIndexToAbsolute( ...
    sampleOffset, result, result.phr.end_chip, params, reference);
payloadStart = chipIndexToAbsolute( ...
    sampleOffset, result, result.payload.start_chip, params, reference);
payloadEnd = chipIndexToAbsolute( ...
    sampleOffset, result, result.payload.end_chip, params, reference);

% 包终点优先级：已解码 PSDU 末 chip > PHR 末 chip > 按前导码长度估算。
if isfinite(payloadEnd)
    absEnd = payloadEnd;
    endSource = 'decoded_payload_last_chip';
elseif isfinite(phrEnd)
    absEnd = phrEnd;
    endSource = 'decoded_phr_last_chip';
else
    period = result.preamble.samples_per_repetition;
    sfdSymbols = max(1, numel(result.sfd.sequence));
    endWork = startWork + ...
        (params.preamble_repetitions + sfdSymbols + 64)*period;
    absEnd = absoluteRxSample( ...
        sampleOffset, endWork, params.fs_rx, reference.fs);
    endSource = 'estimated_no_valid_phr';
end
absEnd = min(totalSamples - 1, max(absStart, absEnd));

timing = struct( ...
    'sample_index_base', 0, ...
    'interval_end_inclusive', true, ...
    'abs_start_sample', absStart, ...
    'abs_end_sample', absEnd, ...
    'abs_phr_start_sample', phrStart, ...
    'abs_phr_end_sample', phrEnd, ...
    'abs_payload_start_sample', payloadStart, ...
    'abs_payload_end_sample', payloadEnd, ...
    'end_source', endSource, ...
    'localization_start_sample', max(0, ...
        absStart - batch.localization_pre_guard_samples), ...
    'localization_end_sample', min(totalSamples - 1, ...
        absEnd + batch.localization_post_guard_samples));
end

function absSample = chipIndexToAbsolute( ...
        sampleOffset, result, chipIndex, params, reference)
%CHIPINDEXTOABSOLUTE 将解码结果中的 1 基 chip 索引转换为文件绝对采样点。
%
%   解码器在 soft_chip_timing 中提供未裁剪的第一个 chip 起点和每 chip 的采样数。
%   函数先检查 chipIndex 以及时序字段是否存在且有效，再按线性关系计算工作网格
%   坐标，最后交给 absoluteRxSample 完成窗口偏移和采样率转换。任何无效输入都会
%   返回 NaN，而不是抛出异常，以便上层回退到 PHR 或估计终点。
absSample = NaN;
if isempty(chipIndex) || ~isscalar(chipIndex) || ...
        ~isfinite(chipIndex) || chipIndex < 1
    return;
end
if ~isfield(result, 'soft_chip_timing') || ...
        ~isfield(result.soft_chip_timing, 'first_chip_sample_uncropped')
    return;
end
firstChipWork = result.soft_chip_timing.first_chip_sample_uncropped;
samplesPerChip = result.soft_chip_timing.samples_per_chip;
workSample = firstChipWork + (double(chipIndex) - 1)*samplesPerChip;
absSample = absoluteRxSample( ...
    sampleOffset, workSample, params.fs_rx, reference.fs);
end

function startWork = uncroppedPreambleStart(result)
%UNCROPPEDPREAMBLESTART 取得未裁剪坐标系中的前导码起点。
%
%   新版解码结果包含 start_sample_uncropped，它不受解码窗口内部裁剪影响，适合转换
%   为文件绝对坐标。对于旧版结果，函数回退使用 preamble.start_sample，以保持对
%   历史结果结构的兼容。调用者应确保 result.preamble 已经存在。
if isfield(result.preamble, 'start_sample_uncropped') && ...
        ~isempty(result.preamble.start_sample_uncropped)
    startWork = result.preamble.start_sample_uncropped;
else
    % 兼容未进行窗口裁剪的旧版解码结果。
    startWork = result.preamble.start_sample;
end
end

function tf = isDuplicatePacket(frames, packetCount, absStart, tolerance)
%ISDUPLICATEPACKET 判断候选数据包是否与已接受帧重复。
%
%   函数只比较已接受帧的绝对起点：若任一已有帧与 absStart 的差值不超过 tolerance
%   个采样点，则认为当前候选是同一数据包在不同搜索窗口中的重复检测。packetCount
%   控制实际有效的 frames 元素数量，避免访问预分配但尚未填充的结构体字段。
tf = false;
for k = 1:packetCount
    if abs(frames(k).abs_start_sample - absStart) <= tolerance
        tf = true;
        return;
    end
end
end

function record = emptyFrameRecord()
%EMPTYFRAMERECORD 创建帧记录数组的空模板。
%
%   返回一个 0x0 的结构体数组，但预先声明所有帧记录字段，确保在没有检测到数据包
%   或需要动态追加记录时，字段类型和字段顺序保持稳定。字段覆盖窗口位置、协议解码
%   结果、FCS 状态、时间信息以及 CIR。上层可直接用 frames(k) 追加同结构记录。
record = struct( ...
    'index', {}, ...
    'window_offset', {}, ...
    'abs_start_sample', {}, ...
    'abs_end_sample', {}, ...
    'abs_phr_start_sample', {}, ...
    'abs_phr_end_sample', {}, ...
    'abs_payload_start_sample', {}, ...
    'abs_payload_end_sample', {}, ...
    'localization_start_sample', {}, ...
    'localization_end_sample', {}, ...
    'end_sample_source', {}, ...
    'has_precise_end_sample', {}, ...
    'sample_index_base', {}, ...
    'interval_end_inclusive', {}, ...
    'time_start_s', {}, ...
    'time_end_s', {}, ...
    'detected_repetitions', {}, ...
    'samples_per_repetition', {}, ...
    'sample_clock_error_ppm', {}, ...
    'carrier_frequency_offset_hz', {}, ...
    'sfd_name', {}, ...
    'sfd_correlation', {}, ...
    'phr_secded_pass', {}, ...
    'psdu_length_bytes', {}, ...
    'payload_bytes', {}, ...
    'fcs_received', {}, ...
    'fcs_calculated', {}, ...
    'fcs_pass', {}, ...
    'cir', {});
end

function record = packageFrameRecord( ...
        index, windowOffset, timing, result, params)
%PACKAGEFRAMERECORD 将单帧解码结果整理为统一的输出记录。
%
%   输入 result 是 decode_uwb 返回的完整解码结构，timing 是
%   locateDecodedFrameSamples 生成的绝对坐标信息。函数复制帧序号、解码窗口偏移、
%   前导码/PHR/PSDU 定位、采样时钟误差、CFO、SFD、SECDED、载荷和 FCS 等字段，并保留
%   CIR 结构。时间字段由绝对采样点除以接收采样率得到，payload_bytes 始终整理为
%   行向量；当解码器没有载荷时使用空 uint8 数组，保证后续 CSV 导出类型稳定。
payloadBytes = result.payload.bytes;
if isempty(payloadBytes)
    payloadBytes = uint8([]);
end

record = struct();
record.index = index;
record.window_offset = windowOffset;
record.abs_start_sample = timing.abs_start_sample;
record.abs_end_sample = timing.abs_end_sample;
record.abs_phr_start_sample = timing.abs_phr_start_sample;
record.abs_phr_end_sample = timing.abs_phr_end_sample;
record.abs_payload_start_sample = timing.abs_payload_start_sample;
record.abs_payload_end_sample = timing.abs_payload_end_sample;
record.localization_start_sample = timing.localization_start_sample;
record.localization_end_sample = timing.localization_end_sample;
record.end_sample_source = timing.end_source;
record.has_precise_end_sample = isfinite(timing.abs_payload_end_sample);
record.sample_index_base = timing.sample_index_base;
record.interval_end_inclusive = timing.interval_end_inclusive;
record.time_start_s = timing.abs_start_sample / params.fs_rx;
record.time_end_s = timing.abs_end_sample / params.fs_rx;
record.detected_repetitions = result.preamble.detected_repetitions;
record.samples_per_repetition = result.preamble.samples_per_repetition;
record.sample_clock_error_ppm = result.preamble.sample_clock_error_ppm;
record.carrier_frequency_offset_hz = ...
    result.preamble.carrier_frequency_offset_hz;
record.sfd_name = char(string(result.sfd.name));
record.sfd_correlation = result.sfd.correlation;
record.phr_secded_pass = logical(result.phr.secded_pass);
record.psdu_length_bytes = result.phr.psdu_length_bytes;
record.payload_bytes = payloadBytes(:).';
record.fcs_received = result.payload.fcs_received;
record.fcs_calculated = result.payload.fcs_calculated;
record.fcs_pass = logical(result.payload.fcs_pass);
record.cir = result.cir;
end

function writeSummaryCsv(csvFile, frames)
%WRITESUMMARYCSV 将帧级摘要写入 CSV 文件。
%
%   函数创建目标文件并写入固定表头，随后逐帧输出采样位置、时间、同步质量、PHR/FCS
%   状态以及十六进制载荷。CSV 中的时间单位为毫秒，采样索引仍为零基闭区间语义。
%   文件名字段用双引号包裹，以兼容可能包含特殊字符的 SFD 名称和终点来源；载荷为空
%   时输出空字符串。若文件无法打开，则发出 warning 并直接返回，不影响 MAT 结果保存。
fid = fopen(csvFile, 'w');
if fid < 0
    warning('decode_uwb_all:CsvWriteError', ...
        'Could not write summary CSV: %s', csvFile);
    return;
end
fileGuard = onCleanup(@() fclose(fid));

fprintf(fid, ['index,window_offset,abs_start_sample,abs_end_sample,', ...
    'abs_phr_start_sample,abs_phr_end_sample,', ...
    'abs_payload_start_sample,abs_payload_end_sample,', ...
    ['localization_start_sample,localization_end_sample,end_sample_source,', ...
     'has_precise_end_sample,'], ...
    'time_start_ms,time_end_ms,detected_repetitions,', ...
    'sample_clock_error_ppm,cfo_hz,sfd_name,sfd_correlation,', ...
    'phr_secded_pass,psdu_length_bytes,fcs_received,fcs_calculated,', ...
    'fcs_pass,payload_hex\n']);

for k = 1:numel(frames)
    frame = frames(k);
    if isempty(frame.payload_bytes)
        payloadHex = '';
    else
        payloadHex = sprintf('%02X', frame.payload_bytes);
    end
    fprintf(fid, ['%d,%d,%d,%d,%.0f,%.0f,%.0f,%.0f,%d,%d,"%s",%d,', ...
        '%.6f,%.6f,%d,%.6f,%.6f,"%s",%.6f,', ...
        '%d,%d,0x%04X,0x%04X,%d,"%s"\n'], ...
        frame.index, frame.window_offset, frame.abs_start_sample, ...
        frame.abs_end_sample, frame.abs_phr_start_sample, ...
        frame.abs_phr_end_sample, frame.abs_payload_start_sample, ...
        frame.abs_payload_end_sample, frame.localization_start_sample, ...
        frame.localization_end_sample, frame.end_sample_source, ...
        frame.has_precise_end_sample, ...
        frame.time_start_s*1e3, ...
        frame.time_end_s*1e3, frame.detected_repetitions, ...
        frame.sample_clock_error_ppm, frame.carrier_frequency_offset_hz, ...
        frame.sfd_name, frame.sfd_correlation, frame.phr_secded_pass, ...
        frame.psdu_length_bytes, frame.fcs_received, ...
        frame.fcs_calculated, frame.fcs_pass, payloadHex);
end
clear fileGuard;
end
