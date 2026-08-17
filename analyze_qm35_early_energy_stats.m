%% Analyze First-Path-early energy across QM35 scheduled-dump frames.
% Reads per-repetition CIR from scheduled_dump_matlab.mat, summarizes
% energy in the early window before First Path, and plots the frame-to-
% frame variation.

clear;
close all;
clc;

%% -------------------- 手动修改 --------------------
save_figure = true;

%% -------------------- 路径 --------------------
thisDir = fileparts(mfilename('fullpath'));
if isempty(thisDir)
    thisDir = pwd;
end
cd(thisDir);
addpath(thisDir);

resultDir = fullfile(thisDir, 'decoded_results', 'qm35_gain1_scheduled_sc16_dump_20260817');
matFile = fullfile(resultDir, 'scheduled_dump_matlab.mat');
assert(isfile(matFile), 'Missing decode MAT: %s', matFile);
loaded = load(matFile, 'results');
results = loaded.results;
assert(~isempty(results), 'results is empty in %s', matFile);

%% -------------------- 逐帧提取 --------------------
stats = collectEarlyEnergyStats(results);
n = stats.count;
fprintf('\n=== First Path 前能量  %d 帧 ===\n', n);
fprintf('valid=%d/%d   FCS=%d/%d\n', ...
    nnz(stats.valid), n, nnz(stats.fcs_pass), n);
fprintf('First Path:  min=%6.2f  median=%6.2f  max=%6.2f ns\n', ...
    min(stats.first_path_delay_ns), median(stats.first_path_delay_ns), ...
    max(stats.first_path_delay_ns));
fprintf('early taps:  min=%d  median=%.0f  max=%d\n', ...
    min(stats.early_tap_count), median(stats.early_tap_count), ...
    max(stats.early_tap_count));
fprintf('early/signal: min=%6.2f  median=%6.2f  max=%6.2f  std=%.2f dB\n', ...
    min(stats.early_to_signal_db), median(stats.early_to_signal_db), ...
    max(stats.early_to_signal_db), std(stats.early_to_signal_db));
fprintf('R_early:      min=%6.2f  median=%6.2f  max=%6.2f  std=%.2f dB\n', ...
    min(stats.r_early_db), median(stats.r_early_db), ...
    max(stats.r_early_db), std(stats.r_early_db));
fprintf('R_peak:       min=%6.2f  median=%6.2f  max=%6.2f  std=%.2f dB\n', ...
    min(stats.r_peak_db), median(stats.r_peak_db), ...
    max(stats.r_peak_db), std(stats.r_peak_db));
fprintf('occupancy:    min=%.2f  median=%.2f  max=%.2f\n', ...
    min(stats.occupancy), median(stats.occupancy), max(stats.occupancy));
fprintf('rep CV:       min=%.3f  median=%.3f  max=%.3f\n', ...
    min(stats.repetition_cv), median(stats.repetition_cv), ...
    max(stats.repetition_cv));
[u, ~, ic] = unique(stats.state);
fprintf('state:');
for i = 1:numel(u)
    fprintf(' %s=%d', u(i), nnz(ic == i));
end
fprintf('\n');

%% -------------------- 表 --------------------
tableOut = table(stats.packet_id, stats.schedule_index, stats.valid, ...
    stats.fcs_pass, stats.state, stats.first_path_delay_ns, ...
    stats.early_tap_count, stats.early_noise_power, ...
    stats.early_residual_power, stats.signal_power, ...
    stats.early_to_signal_db, stats.r_early_db, stats.r_peak_db, ...
    stats.occupancy, stats.repetition_cv, ...
    'VariableNames', {'packet_id', 'schedule_index', 'valid', 'fcs_pass', ...
    'state', 'first_path_delay_ns', 'early_tap_count', ...
    'early_noise_power', 'early_residual_power', 'signal_power', ...
    'early_to_signal_db', 'r_early_db', 'r_peak_db', ...
    'occupancy', 'repetition_cv'});
csvFile = fullfile(resultDir, 'qm35_early_energy_stats.csv');
writetable(tableOut, csvFile);
fprintf('CSV: %s\n', csvFile);

%% -------------------- 图 --------------------
fig = figure('Name', 'QM35 First Path early energy, 100 frames', ...
    'Color', 'w', 'Position', [20 20 1500 960]);
tiledlayout(fig, 3, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

nexttile;
plot(stats.packet_id, stats.early_to_signal_db, '-o', ...
    'Color', [0.10 0.45 0.80], 'MarkerSize', 3.5, 'LineWidth', 1.0);
hold on;
plot(stats.packet_id, stats.r_early_db, '-s', ...
    'Color', [0.85 0.35 0.10], 'MarkerSize', 3.5, 'LineWidth', 1.0);
yline(-25, 'r--', 'R_{early} 阈值 -25 dB', 'LineWidth', 1.1);
grid on;
xlabel('packet\_id');
ylabel('dB');
title('1. 每帧 First Path 前能量（相对 QM35 主径）');
legend('early 总能量 / P_{signal}', '非相干残差比 R_{early}', ...
    'Location', 'best');
xlim(packetXlim(stats.packet_id));

nexttile;
hold on;
histogram(stats.early_to_signal_db, 'BinWidth', 1, ...
    'FaceColor', [0.10 0.45 0.80], 'FaceAlpha', 0.55, 'EdgeColor', 'none');
histogram(stats.r_early_db, 'BinWidth', 1, ...
    'FaceColor', [0.85 0.35 0.10], 'FaceAlpha', 0.55, 'EdgeColor', 'none');
xline(-25, 'r--', 'LineWidth', 1.1);
grid on;
xlabel('dB');
ylabel('帧数');
title(sprintf('2. 分布    early/sig  std=%.2f dB    R_{early}  std=%.2f dB', ...
    std(stats.early_to_signal_db), std(stats.r_early_db)));
legend('early 总能量 / P_{signal}', 'R_{early}', 'Location', 'best');

nexttile;
imagesc(stats.delay_rel_ns, stats.packet_id, stats.residual_ratio_aligned_db);
axis xy;
hold on;
xline(0, 'w--', 'First Path', 'LineWidth', 1.15);
xline(-6 / 0.9984, 'w:', 'guard', 'LineWidth', 1.0);
xlabel('相对 First Path 的时延 (ns)');
ylabel('packet\_id');
title('3. 对齐 First Path 后的残差比  P_{res}/P_{signal} (dB)');
cb = colorbar;
cb.Label.String = 'dB';
if any(isfinite(stats.residual_ratio_aligned_db(:)))
    clim([prctile(stats.residual_ratio_aligned_db(:), 5), ...
        min(-20, prctile(stats.residual_ratio_aligned_db(:), 99))]);
end

nexttile;
imagesc(stats.delay_rel_ns, 1:size(stats.repetition_cir_median_db, 1), ...
    stats.repetition_cir_median_db);
axis xy;
xline(0, 'w--', 'First Path', 'LineWidth', 1.15);
xline(-6 / 0.9984, 'w:', 'guard', 'LineWidth', 1.0);
xlabel('相对 First Path 的时延 (ns)');
ylabel('CIR 所用 SYNC repetition');
title(sprintf('4. 逐 repetition CIR 功率 / P_{signal} (dB，%d 帧中位数)', n));
cb = colorbar;
cb.Label.String = 'dB';
if any(isfinite(stats.repetition_cir_median_db(:)))
    clim([prctile(stats.repetition_cir_median_db(:), 5), ...
        prctile(stats.repetition_cir_median_db(:), 99)]);
end

nexttile;
yyaxis left;
plot(stats.packet_id, stats.occupancy, '-o', 'MarkerSize', 3.5, ...
    'LineWidth', 1.0);
ylabel('occupancy');
ylim([0, max(0.25, max(stats.occupancy) + 0.05)]);
yline(0.20, '--', '占用率阈值 0.20');
yyaxis right;
plot(stats.packet_id, stats.repetition_cv, '-s', 'MarkerSize', 3.5, ...
    'LineWidth', 1.0);
ylabel('repetition CV');
grid on;
xlabel('packet\_id');
title('5. 帧内变化：占用率和 early 能量变异系数');
xlim(packetXlim(stats.packet_id));

nexttile;
axis off;
summary = {
    sprintf('帧数 %d    valid %d/%d    FCS %d/%d', ...
        n, nnz(stats.valid), n, nnz(stats.fcs_pass), n)
    sprintf('First Path  %.2f ~ %.2f ns   early taps  %d ~ %d', ...
        min(stats.first_path_delay_ns), max(stats.first_path_delay_ns), ...
        min(stats.early_tap_count), max(stats.early_tap_count))
    sprintf('early/signal    median %+6.2f dB    std %.2f dB    range %.2f dB', ...
        median(stats.early_to_signal_db), std(stats.early_to_signal_db), ...
        max(stats.early_to_signal_db) - min(stats.early_to_signal_db))
    sprintf('R_early         median %+6.2f dB    std %.2f dB    range %.2f dB', ...
        median(stats.r_early_db), std(stats.r_early_db), ...
        max(stats.r_early_db) - min(stats.r_early_db))
    sprintf('R_peak          median %+6.2f dB    std %.2f dB', ...
        median(stats.r_peak_db), std(stats.r_peak_db))
    sprintf('occupancy       median %.2f         max %.2f', ...
        median(stats.occupancy), max(stats.occupancy))
    sprintf('rep CV          median %.3f         max %.3f', ...
        median(stats.repetition_cv), max(stats.repetition_cv))
    sprintf('超过 R_early=-25 dB 的帧: %d', nnz(stats.r_early_db > -25))
    sprintf('超过 occupancy=0.20 的帧: %d', nnz(stats.occupancy > 0.20))
    };
stateLine = "state:";
for i = 1:numel(u)
    stateLine = stateLine + sprintf(' %s=%d', u(i), nnz(ic == i));
end
summary{end + 1} = char(stateLine);
text(0.02, 0.96, summary, 'Units', 'normalized', ...
    'VerticalAlignment', 'top', 'FontName', 'Consolas', ...
    'FontSize', 11, 'Interpreter', 'none');
title('6. 100 帧摘要');

sgtitle(fig, sprintf('QM35 First Path 前能量变化  (%d 帧)', n), ...
    'FontWeight', 'bold');

if save_figure
    pngFile = fullfile(resultDir, 'qm35_early_energy_stats.png');
    axesList = findall(fig, 'Type', 'axes');
    for k = 1:numel(axesList)
        if isprop(axesList(k), 'Toolbar') && ~isempty(axesList(k).Toolbar)
            axesList(k).Toolbar.Visible = 'off';
        end
    end
    exportgraphics(fig, pngFile, 'Resolution', 160);
    fprintf('figure: %s\n', pngFile);
end

function stats = collectEarlyEnergyStats(results)
n = numel(results);
packetId = nan(n, 1);
scheduleIndex = nan(n, 1);
valid = false(n, 1);
fcsPass = false(n, 1);
state = strings(n, 1);
fpDelay = nan(n, 1);
earlyTaps = zeros(n, 1);
earlyNoise = nan(n, 1);
earlyResidual = nan(n, 1);
signalPower = nan(n, 1);
rEarly = nan(n, 1);
rPeak = nan(n, 1);
occupancy = nan(n, 1);
repCv = nan(n, 1);
repCount = 0;
for k = 1:n
    d = results(k).qm35_cir_interference;
    if isfield(d, 'repetition_early_power')
        repCount = max(repCount, numel(d.repetition_early_power));
    end
end
repEarlyDb = nan(n, max(repCount, 1));
delayRelNs = (-60:0.5:15).';
alignedDb = nan(n, numel(delayRelNs));
repCirAlignedDb = nan(n, max(repCount, 1), numel(delayRelNs));

for k = 1:n
    r = results(k);
    d = r.qm35_cir_interference;
    packetId(k) = r.packet_id;
    scheduleIndex(k) = r.schedule_index;
    valid(k) = logical(r.qm35_cir_interference_valid);
    fcsPass(k) = logical(r.qm35_fcs_pass);
    state(k) = string(r.qm35_interference_state);
    fpDelay(k) = r.qm35_first_path_delay_ns;
    earlyTaps(k) = r.qm35_early_tap_count;
    rEarly(k) = r.qm35_early_residual_ratio_db;
    rPeak(k) = r.qm35_early_peak_ratio_db;
    occupancy(k) = r.qm35_interference_occupancy;
    if isfield(d, 'early_noise_power')
        earlyNoise(k) = d.early_noise_power;
    end
    if isfield(d, 'early_residual_power')
        earlyResidual(k) = d.early_residual_power;
    end
    if isfield(d, 'signal_power')
        signalPower(k) = d.signal_power;
    end
    if isfield(d, 'repetition_early_power') && ~isempty(d.repetition_early_power)
        ep = d.repetition_early_power(:);
        m = min(numel(ep), size(repEarlyDb, 2));
        if isfinite(signalPower(k))
            repEarlyDb(k, 1:m) = 10 * log10(ep(1:m) / (signalPower(k) + eps) + eps);
        end
        repCv(k) = std(ep) / (mean(ep) + eps);
    end
    if isfield(d, 'delay_ns') && isfield(d, 'residual_power') && ...
            ~isempty(d.delay_ns) && ~isempty(d.residual_power) && ...
            isfinite(fpDelay(k)) && isfinite(signalPower(k))
        ratioDb = 10 * log10(max(d.residual_power(:), 0) / ...
            (signalPower(k) + eps) + eps);
        alignedDb(k, :) = interp1(d.delay_ns(:) - fpDelay(k), ratioDb, ...
            delayRelNs, 'linear', NaN);
    end
    if isfield(d, 'delay_ns') && isfield(d, 'individual_values') && ...
            ~isempty(d.delay_ns) && ~isempty(d.individual_values) && ...
            isfinite(fpDelay(k)) && isfinite(signalPower(k))
        repValues = d.individual_values;
        m = min(size(repValues, 2), size(repCirAlignedDb, 2));
        for rep = 1:m
            repRatioDb = 10 * log10(abs(repValues(:, rep)).^2 / ...
                (signalPower(k) + eps) + eps);
            alignedRep = interp1(d.delay_ns(:) - fpDelay(k), ...
                repRatioDb, delayRelNs, 'linear', NaN);
            repCirAlignedDb(k, rep, :) = reshape(alignedRep, 1, 1, []);
        end
    end
end

stats = struct();
stats.count = n;
stats.packet_id = packetId;
stats.schedule_index = scheduleIndex;
stats.valid = valid;
stats.fcs_pass = fcsPass;
stats.state = state;
stats.first_path_delay_ns = fpDelay;
stats.early_tap_count = earlyTaps;
stats.early_noise_power = earlyNoise;
stats.early_residual_power = earlyResidual;
stats.signal_power = signalPower;
stats.early_to_signal_db = 10 * log10(earlyNoise ./ (signalPower + eps) + eps);
stats.r_early_db = rEarly;
stats.r_peak_db = rPeak;
stats.occupancy = occupancy;
stats.repetition_cv = repCv;
stats.repetition_early_db = repEarlyDb;
stats.delay_rel_ns = delayRelNs;
stats.residual_ratio_aligned_db = alignedDb;
stats.repetition_cir_median_db = squeeze( ...
    median(repCirAlignedDb, 1, 'omitnan'));
end

function xl = packetXlim(packetId)
if isempty(packetId)
    xl = [0 1];
    return
end
span = max(packetId) - min(packetId);
xl = [min(packetId) - 0.5, max(packetId) + 0.5];
if span <= 0
    xl = xl + [-1 1];
end
end
