%% 加载 scheduled dump 中 SIC 前后的 QM35 复数 CIR
% 运行后在工作区生成：
%   cir_before_sic : 插值、峰值对齐和帧间复增益校正后的 SIC 前 CIR
%   cir_after_sic  : 插值、峰值对齐和帧间复增益校正后的 SIC 后 CIR
%   cir_delay_ns   : 相对主峰时延，对齐后的主峰位于 0 ns
%   packet_ids     : 每一行 CIR 对应的 dump packet_id
%   cir_frame_gain : 从 First peak 估计的每帧复增益（幅度和相位变化）
% 同时保留原始 CIR 和仅完成峰值对齐、尚未做复增益校正的 CIR。
clear;
clc;

this_dir = fileparts(mfilename('fullpath'));
if isempty(this_dir)
    this_dir = pwd;
end

%% 唯一配置入口：pipeline 生成的轻量 CIR 文件
cir_file = fullfile(this_dir, 'decoded_results', 'qm35_sensing_1', ...
    'sic_dw1000_removed_qm35_preserved', ...
    'qm35_cir_before_after_sic.mat');

%% 只加载 CIR 数据，不再读取大型 pipeline manifest
assert(isfile(cir_file), 'CIR-only MAT file not found: %s', cir_file);
load_timer = tic;
loaded = load(cir_file, 'cir_before_sic', 'cir_after_sic', ...
    'cir_delay_ns', 'packet_ids');

cir_before_sic_raw = loaded.cir_before_sic;
cir_after_sic_raw = loaded.cir_after_sic;
cir_delay_ns_raw = loaded.cir_delay_ns(:).';
packet_ids = loaded.packet_ids;
clear loaded;

%% 复数 CIR 插值
% 插值直接作用于复数 CIR，不额外旋转相位。
interpolation_factor = 32;
n_taps_raw = numel(cir_delay_ns_raw);
n_taps_interp = (n_taps_raw - 1) * interpolation_factor + 1;
cir_delay_interp_ns = linspace( ...
    cir_delay_ns_raw(1), cir_delay_ns_raw(end), n_taps_interp);

% 轻量 CIR 文件保留了 pipeline 的全部 packet。解调失败的
% packet 对应整行 NaN，必须在 interp1 之前排除，否则该帧
% 剔除 NaN 后不足两个采样点，会导致 griddedInterpolant 报错。
valid_input_rows = sum(isfinite(cir_before_sic_raw), 2) >= 2 & ...
    sum(isfinite(cir_after_sic_raw), 2) >= 2;
assert(any(valid_input_rows), 'No valid before/after CIR frames to interpolate.');

cir_before_interp = complex(nan(size(cir_before_sic_raw, 1), ...
    n_taps_interp));
cir_after_interp = complex(nan(size(cir_after_sic_raw, 1), ...
    n_taps_interp));
cir_before_interp(valid_input_rows, :) = interp1(cir_delay_ns_raw, ...
    cir_before_sic_raw(valid_input_rows, :).', ...
    cir_delay_interp_ns, 'spline', 0).';
cir_after_interp(valid_input_rows, :) = interp1(cir_delay_ns_raw, ...
    cir_after_sic_raw(valid_input_rows, :).', ...
    cir_delay_interp_ns, 'spline', 0).';

%% 按 SIC 后 CIR 的主峰对齐所有帧
% SIC 后 CIR 中的 QM35 主峰通常更干净。每帧用 SIC 后主峰
% 计算平移量，再将同一平移同时应用于 SIC 前后 CIR，
% 从而保留两者之间原有的相对时延。平移不做循环回绕，
% 移出窗口的 tap 丢弃，新进入窗口的 tap 填 0。
peak_amplitude = max(abs(cir_after_interp), [], 2);
valid_rows = valid_input_rows & all(isfinite(cir_before_interp), 2) & ...
    all(isfinite(cir_after_interp), 2) & peak_amplitude > 0;
peak_index = nan(size(cir_after_interp, 1), 1);
[~, peak_index(valid_rows)] = max(abs(cir_after_interp(valid_rows, :)), [], 2);
reference_peak_index = round(median(peak_index(valid_rows)));
peak_shift_samples = nan(size(peak_index));

cir_before_sic = complex(nan(size(cir_before_interp)));
cir_after_sic = complex(nan(size(cir_after_interp)));
for k = find(valid_rows).'
    shift = reference_peak_index - peak_index(k);
    peak_shift_samples(k) = shift;
    cir_before_sic(k, :) = shiftWithoutWrap(cir_before_interp(k, :), shift);
    cir_after_sic(k, :) = shiftWithoutWrap(cir_after_interp(k, :), shift);
end

% 对齐后以公共主峰作为 0 ns。
cir_delay_ns = cir_delay_interp_ns - ...
    cir_delay_interp_ns(reference_peak_index);

%% 用对齐后的 First peak 校正帧间幅度和相位变化
% SIC 后 CIR 的 First peak 同时作为时延、幅度和相位参考。将每帧
% First peak 校正到统一的正实数幅度，因此校正后所有帧在 0 ns 处具有
% 相同的幅度和相位。由 SIC 后 First peak 得到的同一个复增益同时
% 应用于该帧的 SIC 前后 CIR，以保留两者之间原有的相对关系。
cir_before_sic_aligned = cir_before_sic;
cir_after_sic_aligned = cir_after_sic;

aligned_first_peak = cir_after_sic_aligned(:, reference_peak_index);
first_peak_reference_amplitude = median( ...
    abs(aligned_first_peak(valid_rows)), 'omitnan');
assert(isfinite(first_peak_reference_amplitude) && ...
    first_peak_reference_amplitude > 0, ...
    'The aligned First peak has no usable amplitude reference.');

cir_frame_gain = complex(nan(size(aligned_first_peak)));
cir_frame_gain(valid_rows) = aligned_first_peak(valid_rows) / ...
    first_peak_reference_amplitude;
valid_gain_rows = valid_rows & isfinite(cir_frame_gain) & ...
    abs(cir_frame_gain) > eps;
assert(all(valid_gain_rows(valid_rows)), ...
    'Some valid CIR frames have an unusable First peak.');

for k = find(valid_gain_rows).'
    cir_before_sic(k, :) = cir_before_sic_aligned(k, :) / ...
        cir_frame_gain(k);
    cir_after_sic(k, :) = cir_after_sic_aligned(k, :) / ...
        cir_frame_gain(k);
end
load_elapsed_s = toc(load_timer);

%% 绘制插值后的距离谱
% 默认按往返传播距离 R = c*tau/2 换算。若需要单程传播
% 路径长度，将 delay_to_distance_factor 改为 1。
speed_of_light_mps = 299792458;
delay_to_distance_factor = 0.5;
distance_m = cir_delay_ns * 1e-9 * speed_of_light_mps * ...
    delay_to_distance_factor;

% SIC 前后共用 SIC 前全部帧的最大幅度作为 0 dB 参考，
% 不做逐帧归一化，从而保留帧间和 SIC 前后的幅度变化。
reference_amplitude = max(abs(cir_before_sic), [], 'all', 'omitnan');
if ~(isfinite(reference_amplitude) && reference_amplitude > 0)
    reference_amplitude = max(abs(cir_after_sic), [], 'all', 'omitnan');
end
distance_spectrum_before_db = 20 * log10( ...
    max(abs(cir_before_sic) / reference_amplitude, realmin('double')));
distance_spectrum_after_db = 20 * log10( ...
    max(abs(cir_after_sic) / reference_amplitude, realmin('double')));

distance_spectrum_floor_db = -50;
fig = figure('Name', 'Interpolated QM35 distance spectra before/after SIC', ...
    'Color', 'w', 'Position', [60 80 1500 720]);
tiledlayout(fig, 1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
ax1 = nexttile;
imagesc(distance_m, packet_ids, ...
    max(distance_spectrum_before_db, distance_spectrum_floor_db));
axis xy;
clim([distance_spectrum_floor_db, 0]);
colorbar;
xlabel('Relative range (m), R = c\tau/2');
ylabel('packet id');
title('Before SIC, amplitude/phase corrected');

ax2 = nexttile;
imagesc(distance_m, packet_ids, ...
    max(distance_spectrum_after_db, distance_spectrum_floor_db));
axis xy;
clim([distance_spectrum_floor_db, 0]);
colorbar;
xlabel('Relative range (m), R = c\tau/2');
ylabel('packet id');
title('After SIC, amplitude/phase corrected');
linkaxes([ax1, ax2], 'xy');
colormap(fig, turbo(256));
sgtitle(sprintf(['QM35 %dx-interpolated, peak-aligned and complex-gain-corrected | ', ...
    'range bin %.2f cm'], interpolation_factor, ...
    100 * median(diff(distance_m))));

fprintf(['Loaded, %dx interpolated, peak-aligned and complex-gain-corrected ', ...
    '%d frames x ', ...
    '%d CIR taps in %.3f s.\n'], interpolation_factor, ...
    size(cir_before_sic, 1), size(cir_before_sic, 2), load_elapsed_s);
fprintf('Interpolated delay step: %.4f ns; range bin: %.2f cm.\n', ...
    median(diff(cir_delay_ns)), 100 * median(diff(distance_m)));
fprintf(['First-peak complex-gain calibration: common amplitude %.6g; ', ...
    'common phase 0 deg.\n'], first_peak_reference_amplitude);
fprintf(['Variables: cir_before_sic, cir_after_sic, cir_frame_gain, ', ...
    'cir_delay_ns, packet_ids\n']);

function shifted = shiftWithoutWrap(values, shift)
% 整数 tap 平移，不允许 circshift 式的首尾回绕。
n = numel(values);
shifted = complex(zeros(size(values)));
if shift >= n || shift <= -n
    return
elseif shift > 0
    shifted(shift + 1:end) = values(1:end - shift);
elseif shift < 0
    shifted(1:end + shift) = values(1 - shift:end);
else
    shifted = values;
end
end
