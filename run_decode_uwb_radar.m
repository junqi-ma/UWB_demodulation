%% 按固定发包周期解调 QM35825 雷达模式数据
% X410 是 QM35825 雷达 Rx 的旁路。已知第一个包的前导码起始时间和固定发包
% 间隔后，直接预测全部候选窗口，跳过全文件 energy scan 和候选 correlation。
% 每个预测窗口仍调用 decode_uwb 完成定时细化、CIR、PHR、payload 和 FCS 解码。
clear;
close all;
clc;

%% -------------------- 必填：采集文件与雷达时序 --------------------
options = struct();
options.file_name = 'F:\UWB基带数据\qm35_new_processed_1.dat';

% 时间均相对于 X410 采集文件的第 0 个复采样点。
% first_packet_time_s 应对应第一个 QM35825 包的前导码起点，而不是包结束时间。
first_packet_time_s = 340998/998.4e6;        % 首个完整 FCS-ok 包：采样点 340998
packet_interval_s = 350e-6;                  % QM35825 雷达周期：350 us

if ~isfinite(first_packet_time_s) || first_packet_time_s < 0 || ...
        ~isfinite(packet_interval_s) || packet_interval_s <= 0
    error('run_decode_uwb_radar:RadarTimingRequired', ...
        ['请先填写 first_packet_time_s（首包相对采集起点的时间）和 ', ...
         'packet_interval_s（固定发包间隔）。']);
end

%% -------------------- X410 与 QM35825 PHY 配置 --------------------
options.ant_num = 1;
options.channel_index = 1;
options.fs_rx = 998.4e6;
options.data_rate = 6.81;
options.preamble_repetitions = 16;
options.code_index = 9;
options.sfd_mode = '4z2';
options.cir_skip_initial_repetitions = 10;
options.cir_repetitions = options.preamble_repetitions - ...
    options.cir_skip_initial_repetitions;
options.show_plots = false;

%% -------------------- 固定周期候选与局部解码 --------------------
batch = struct();
batch.detection_mode = 'fixed_interval';
batch.first_packet_time_s = first_packet_time_s;
batch.packet_interval_s = packet_interval_s;

% Inf 表示一直预测到采集文件末尾；调试时可改为较小的正整数。
batch.fixed_max_packets = Inf;

% 每个预测时刻前保留约 10 us，以容纳首包时间误差和两台设备的时钟漂移。
% 如果长采集末尾的实际包逐渐移出窗口，可适当增大该值。
% QM35 当前帧约占 162 us；230 us 窗口既能覆盖完整帧，也小于 350 us 发包周期，
% 避免相邻候选窗口重叠并重复处理同一段 IQ。
batch.pre_packet_guard_samples = round(10e-6*options.fs_rx);
batch.window_samples = round(190e-6*options.fs_rx);
batch.min_window_samples = 2.0e5;

batch.localization_pre_guard_samples = 2048;
batch.localization_post_guard_samples = 4096;
batch.start_tolerance_samples = 4096;
batch.require_fcs_pass = false;
batch.save_individual_cir = false;

%% -------------------- 输出路径 --------------------
[~, capture_stem] = fileparts(options.file_name);
batch.output_directory = fullfile(pwd, 'decoded_results', ...
    [capture_stem '_radar']);
batch.mat_file = fullfile(batch.output_directory, 'all_frames_cir.mat');
batch.summary_csv = fullfile(batch.output_directory, 'frame_summary.csv');

%% -------------------- 执行并显示摘要 --------------------
results = decode_uwb_all(options, batch);

fprintf(['[QM35825 radar] %s | %d scheduled, %d decoded (%d FCS-ok) | ', ...
    '%.1f ms | scan/correlation %.1f/%.1f s | decode %.1f s\n'], ...
    options.file_name, results.candidate_count, results.packet_count, ...
    results.fcs_pass_count, results.duration_s*1e3, ...
    results.energy_seconds, results.correlation_seconds, ...
    results.fine_seconds);
