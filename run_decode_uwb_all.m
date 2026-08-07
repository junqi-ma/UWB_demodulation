%% 解码 X410 采集文件中的所有 UWB 数据包并保存全部 CIR
% 三阶段流程：
%   1) 每隔 100 条 IQ 记录读取一次，并生成稳健的能量包络
%   2) 在每个能量起始点附近以全采样率执行自适应前导码相关检测
%   3) 完整解码通过筛选的候选项，并导出精确的采样区间
% 由 sic_pipeline/uwbSicPipeline.m 调用时，sic_stage_config 会提供
% 明确的各阶段路径。直接交互运行时则保留原有默认值。
sic_managed_run = exist('sic_stage_config', 'var') == 1;
if ~sic_managed_run
    clear;
    sic_managed_run = false;
end
close all;
clc;

%% -------------------- 信号类型 --------------------
% 只能选择一种信号类型：'DW1000' 或 'QM35'。
phy_profile = 'QM35';
if sic_managed_run
    phy_profile = sic_stage_config.phy_profile;
end

%% -------------------- 输入采集文件 --------------------
options = struct();
options.file_name = 'F:\UWB基带数据\qm35_new_processed_1.dat';
%options.file_name = 'F:\USRP数据解调\decoded_results\qm35_dw1000_1\cancelled_optimal_complex.dat';
if sic_managed_run
    options.file_name = sic_stage_config.input_file;
end
options.ant_num = 1;
options.channel_index = 1;

%% -------------------- 已预处理的输入 --------------------
options.fs_rx = 998.4e6;
options.data_rate = 6.81;
pll_phase_compensation_repetitions = 10;
if sic_managed_run && isfield(sic_stage_config, ...
        'pll_phase_compensation_repetitions')
    pll_phase_compensation_repetitions = ...
        sic_stage_config.pll_phase_compensation_repetitions;
end
validateattributes(pll_phase_compensation_repetitions, {'numeric'}, ...
    {'scalar', 'integer', 'nonnegative'}, mfilename, ...
    'pll_phase_compensation_repetitions');

options.decawave_sfd = [-1; -1; -1; -1; 1; -1; 0; 0];
options.ieee_sfd = [0; 1; 0; -1; 1; 0; 0; -1];
options.sfd4z_1 = [-1; -1; 1; -1];
options.sfd4z_2 = [-1; -1; -1; 1; -1; -1; 1; -1];
options.sfd4z_3 = [-1; -1; -1; -1; -1; 1; 1; -1; ...
    -1; 1; -1; 1; -1; -1; 1; -1];
options.sfd4z_4 = [-1; -1; -1; -1; -1; -1; -1; 1; ...
    -1; -1; 1; -1; -1; 1; -1; 1; -1; 1; -1; -1; ...
    -1; 1; 1; -1; -1; -1; 1; -1; 1; 1; -1; -1];

switch upper(phy_profile)
    case 'DW1000'
        phy_profile = 'DW1000';
        options.preamble_repetitions = 128;
        options.code_index = 11;
        options.sfd_mode = 'decawave';
        % PLL 补偿负责处理 SYNC 1..10；从 SYNC 11 开始保存逐重复 CIR，
        % 使慢速相位补偿可以无缝接管。
        options.cir_skip_initial_repetitions = ...
            pll_phase_compensation_repetitions;
        options.cir_repetitions = options.preamble_repetitions - ...
            options.cir_skip_initial_repetitions;
        fine_window_min_samples = 2.9e5;
        profile_tag = 'dw1000';
    case 'QM35'
        phy_profile = 'QM35';
        options.preamble_repetitions = 64;
        options.code_index = 9;
        % QM35 使用 IEEE 802.15.4z SFD #2。PLL 补偿负责处理 SYNC
        % 1..10；从 SYNC 11 开始保存逐重复 CIR。
        options.sfd_mode = '4z2';
        options.cir_skip_initial_repetitions = ...
            pll_phase_compensation_repetitions;
        options.cir_repetitions = options.preamble_repetitions - ...
            options.cir_skip_initial_repetitions;
        fine_window_min_samples = 2.0e5;
        profile_tag = 'qm35';
    otherwise
        error('phy_profile must be ''DW1000'' or ''QM35''.');
end

% 当采集文件名已包含配置名称时，避免添加重复后缀
%（例如将 qm35_1.dat 按 QM35 解码时使用 qm35_1/，而不是 qm35_1_qm35/）。
[~, capture_stem] = fileparts(options.file_name);
capture_lower = lower(capture_stem);
if contains(capture_lower, 'qm35') && strcmpi(phy_profile, 'QM35')
    profile_suffix = '';
elseif contains(capture_lower, 'dw1000') && strcmpi(phy_profile, 'DW1000')
    profile_suffix = '';
else
    profile_suffix = ['_' profile_tag];
end

options.show_plots = false;

%% -------------------- 阶段 1：跨步能量扫描 --------------------
batch = struct();
% 读取器会跳过文件中的完整 IQ 记录，因此既减少了转换工作量，
% 也减少了返回 MATLAB 的采集数据量。
batch.energy_chunk_samples = 40e6;
batch.energy_step_samples = 39e6;
batch.energy_read_stride = 200;
% 移动平均长度和区域控制参数均使用原始接收采样点为单位。
batch.energy_smooth_rx_samples = 4096;
% 使用能量最低的 30% 数据估计静默噪声基线，避免密集的数据包流量
% 将背景估计推入信号能量分布范围。
batch.energy_baseline_fraction = 0.30;
% 滞回阈值：静默噪声基线中位数 + k × 稳健标准差。
batch.energy_threshold_sigma_high = 6;
batch.energy_threshold_sigma_low = 3;
% 此采集数据的 MAD 可能很小。对高于静默噪声基线中位数的功率差
% 设置最小下限，避免观测到的约 47 dB 干扰能量将相邻 UWB 数据包连接起来。
batch.energy_threshold_margin_db_high = 6;
batch.energy_threshold_margin_db_low = 4;
batch.energy_min_region_samples = 3e4;
% 先合并原始区域，再应用这些保护区。重叠的数据包保护区仍保持独立，
% 并由 decode_uwb_all 在数据包之间的中点处截断。
batch.energy_region_pre_guard_samples = 1.5e4;
batch.energy_region_post_guard_samples = 2.5e4;
batch.energy_region_merge_samples = 1e4;

%% -------------------- 阶段 2：相关检测精化 --------------------
% 以全采样率搜索第一次重复。首先在原始能量起始点附近使用窄窗口，
% 仅在判定失败后扩大窗口，最后回退到完整的带保护区能量区间。
batch.correlation_decimation = 1;       % 相关搜索的解码步长（设为1即全采样率）
batch.correlation_repetitions = 8;      % 单个候选包的重复次数（共搜索8个重复）
batch.correlation_min_repetitions = 2;  % 最小通过的重复计数（仅2个重复即可判定候选）
batch.correlation_search_level_1_pre_samples = ... % 第一层搜索窗（窄窗口）在包起点前的采样点数
    round(5e-6*options.fs_rx);
batch.correlation_search_level_1_post_samples = ... % 第一层搜索窗（窄窗口）在包起点后的采样点数
    round(12e-6*options.fs_rx);
batch.correlation_search_level_2_pre_samples = ... % 第二层搜索窗（扩大后）在包起点前的采样点数
    round(15e-6*options.fs_rx);
batch.correlation_search_level_2_post_samples = ... % 第二层搜索窗（扩大后）在包起点后的采样点数
    round(30e-6*options.fs_rx);
batch.correlation_expected_offset_samples = ... % 相对预期包起始的采样点偏移（用于排序候选）
    round(5.2e-6*options.fs_rx);
batch.correlation_baseline_fraction = 0.60; % 相关检测的基线功率比例（占区域能量的60%作为参考阈值）
batch.corr_threshold_sigma = 5;       % 相关峰值的判别阈值倍数（5σ）
batch.corr_min_threshold_ratio = 20;  % 最小相关峰值比率（峰值必须大于最小平均的20倍）
batch.corr_candidate_relative_level = 0.20; % 候选提起的相对能量比例（在平均能量基础上+20%）
batch.corr_require_hit_every_repetition = true; % 是否要求每次重复都通过验证
batch.correlation_peak_min_distance_samples = 200; % 同一包内连续峰值的最小采样间距
batch.correlation_multi_packet_search = true;   % 是否允许同一区域搜索多个包
batch.correlation_single_region_baseline_fraction = 0.60; % 单包区域的基准能量占比
batch.correlation_long_region_threshold_factor = 1.50; % 长区域判定为包的数量倍数
batch.correlation_long_region_threshold_margin_samples = ... % 长区域额外保留的采样点
    round(20e-6*options.fs_rx);
batch.correlation_min_packet_separation_fraction = 0.75; % 包间最小分隔比例
batch.correlation_packet_exclusion_repetitions = ... % 包间排斥重复周期数
    options.preamble_repetitions;
batch.correlation_candidate_train_gap_repetitions = 4; % 候选包之间的训练间隔（采样点数）
batch.correlation_tail_chunk_samples = round(100e-6*options.fs_rx); % 尾部搜索每次处理的采样点数

%% -------------------- 阶段 3：全采样率解码 --------------------
% 在精化后的前导码估计位置之前启动完整解码器。
batch.pre_packet_guard_samples = 5e4;
batch.window_samples = 0.8e6;
% 针对不同配置设置下限，在保留测得的完整帧及包前保护区的同时，
% 避免读取不必要的过长尾部。
batch.min_window_samples = fine_window_min_samples;
% 精确的 packet_intervals 不含保护区。blank_intervals 使用以下边距，
% 可直接传给其他解码器中的 options.blank_intervals。
batch.localization_pre_guard_samples = 2048;
batch.localization_post_guard_samples = 4096;
batch.start_tolerance_samples = 4096;
batch.require_fcs_pass = false;
% all_frames_cir.mat 已包含所有帧及 CIR。除非下游流程明确需要，
% 否则不生成数千个小型 HDF5 文件。
batch.save_individual_cir = false;

%% -------------------- 输出路径 --------------------
batch.output_directory = fullfile(pwd, 'decoded_results', ...
    [capture_stem profile_suffix]);
if sic_managed_run
    batch.output_directory = sic_stage_config.result_directory;
end
batch.mat_file = fullfile(batch.output_directory, 'all_frames_cir.mat');
batch.summary_csv = fullfile(batch.output_directory, 'frame_summary.csv');
batch.timeline_png = fullfile(batch.output_directory, 'packet_timeline.png');

%% -------------------- 执行一次完整文件解码 --------------------
results = decode_uwb_all(options, batch);

%% -------------------- 控制台摘要（紧凑单行） --------------------
fprintf('[%s] %s | %d pkts (%d FCS-ok) | %.1f ms | %.1f/%.1f/%.1f s\n', ...
    phy_profile, options.file_name, results.packet_count, ...
    results.fcs_pass_count, results.duration_s*1e3, ...
    results.energy_seconds, results.correlation_seconds, ...
    results.fine_seconds);
