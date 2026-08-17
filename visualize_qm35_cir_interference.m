%% Visualize one scheduled QM35 packet: raw IQ plus CIR threshold decision.
% packet_index is the packet_id in capture.jsonl / scheduled_dump_matlab.csv.
% Prefers stored CIR diagnostics in decoded_results; otherwise decodes only
% that packet. Raw IQ is the 998.4 MHz resampled window, aligned to the
% C++ QM35 detection start.

clear;
close all;
clc;

%% -------------------- User parameters --------------------
packet_index = 4;
dump_dir = 'F:\UWB基带数据\qm35_clean_scheduled_sc16_dump';
save_figure = true;

%% -------------------- Paths --------------------
this_dir = fileparts(mfilename('fullpath'));
if isempty(this_dir)
    this_dir = pwd;
end
addpath(this_dir);

dump_dir = strtrim(dump_dir);
while ~isempty(dump_dir) && (dump_dir(end) == '/' || dump_dir(end) == '\')
    dump_dir = dump_dir(1:end-1);
end
[~, dump_name] = fileparts(dump_dir);
switch dump_name
    case 'qm35_scheduled_sc16_dump'
        tag = 'scheduled_sc16_dump';
    case 'qm35_clean_scheduled_sc16_dump'
        tag = 'scheduled_sc16_dump_qm35_clean';
    otherwise
        tag = dump_name;
end

result_dir = fullfile(this_dir, 'decoded_results', tag);
mat_file = fullfile(result_dir, 'scheduled_dump_matlab.mat');
iq_file = fullfile(dump_dir, 'capture.iq');
jsonl_file = fullfile(dump_dir, 'capture.jsonl');
cpp_csv = fullfile(result_dir, 'scheduled_dump_cpp.csv');
if ~isfile(cpp_csv)
    cpp_csv = fullfile(dump_dir, 'scheduled_dump_cpp.csv');
end
taps_file = fullfile(this_dir, 'testdata', 'resampler_65_48', ...
    'taps_quality_minorder.txt');

output_png = fullfile(result_dir, sprintf( ...
    'qm35_cir_threshold_packet_%03d.png', packet_index));

%% -------------------- Load and plot --------------------
iq = loadResampledPacket(packet_index, dump_dir, iq_file, jsonl_file, ...
    cpp_csv, taps_file);
result = loadOrDecodePacket(packet_index, mat_file, dump_dir, ...
    iq_file, jsonl_file, cpp_csv, taps_file, iq);
d = result.qm35_cir_interference;
opt = detectorOptions(d);

delayNs = getFieldOr(d, 'delay_ns', []);
hBar = getFieldOr(d, 'coherent_cir', []);
residual = getFieldOr(d, 'residual_power', []);
individual = getFieldOr(d, 'individual_values', []);
earlyIdx = getFieldOr(d, 'early_indices', []);
signalIdx = getFieldOr(d, 'signal_indices', []);
repPower = getFieldOr(d, 'repetition_early_power', []);
repThr = getFieldOr(d, 'repetition_threshold', NaN);
fpIndex = getFieldOr(d, 'first_path_index', NaN);
fpDelay = result.qm35_first_path_delay_ns;
[~, peakPower, peakDelay] = locateFirstPeak( ...
    hBar, delayNs, fpIndex, signalIdx);
rEarly = result.qm35_early_residual_ratio_db;
rPeak = result.qm35_early_peak_ratio_db;
occupancy = result.qm35_interference_occupancy;
state = string(result.qm35_interference_state);

fig = figure('Name', sprintf('QM35 CIR threshold packet %d', packet_index), ...
    'Color', 'w', 'Position', [30 30 1480 960]);
tiledlayout(fig, 3, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

nexttile;
plotFirstPathProcess(delayNs, hBar, earlyIdx, signalIdx, fpIndex, ...
    fpDelay, peakDelay, peakPower, opt);

nexttile;
plotRepetitionHeatmap(delayNs, individual, earlyIdx, fpDelay, ...
    peakDelay, peakPower);

nexttile;
plotResidualThresholds(delayNs, residual, earlyIdx, fpDelay, ...
    getFieldOr(d, 'signal_power', NaN), rEarly, rPeak, opt);

nexttile;
plotOccupancyProcess(repPower, repThr, occupancy, peakPower, opt);

nexttile;
plotFeatureMeters(rEarly, rPeak, occupancy, opt);

nexttile;
plotRawIq(iq);

stateColor = stateRgb(state);
sgtitle(fig, sprintf( ...
    ['QM35 CIR 干扰阈值判定    packet %d    状态 %s    ', ...
    'SIC %s    FCS %d'], packet_index, upper(char(state)), ...
    yesNo(result.qm35_sic_recommended), result.qm35_fcs_pass), ...
    'FontWeight', 'bold', 'Color', stateColor);

printDecisionConsole(result, d, opt);
printIqConsole(iq);

if save_figure
    outDir = fileparts(output_png);
    if ~isempty(outDir) && ~isfolder(outDir)
        mkdir(outDir);
    end
    exportgraphics(fig, output_png, 'Resolution', 160);
    fprintf('figure: %s\n', output_png);
end

function plotRawIq(iq)
if ~isstruct(iq) || ~isfield(iq, 'ok') || ~iq.ok
    if isstruct(iq) && isfield(iq, 'message') && ~isempty(iq.message)
        axisOffMessage(iq.message);
    else
        axisOffMessage('没有可用的原始 IQ');
    end
    return
end

x998 = iq.x998(:);
fs = iq.fs;
n = numel(x998);
origin = iq.detected_start_one;
if ~(isfinite(origin) && origin >= 1 && origin <= n)
    origin = 1;
end

preSamp = round(5e-6 * fs);
postSamp = round(200e-6 * fs);
idx0 = max(1, origin - preSamp);
idx1 = min(n, origin + postSamp);
span = idx0:idx1;
maxPoints = 40000;
stride = max(1, ceil(numel(span) / maxPoints));
span = span(1:stride:end);
tUs = (double(span) - origin) / fs * 1e6;
x = x998(span);

hold on;
plot(tUs, real(x), 'Color', [0.15 0.40 0.85], 'LineWidth', 0.5);
plot(tUs, imag(x), '--','Color', [0.85 0.20 0.18], 'LineWidth', 0.5);
xline(0, 'k--', 'C++ start', 'LineWidth', 1.0);
if isfinite(iq.predicted_start_one)
    predUs = (double(iq.predicted_start_one) - origin) / fs * 1e6;
    if predUs >= tUs(1) && predUs <= tUs(end)
        xline(predUs, 'b:', 'predicted', 'LineWidth', 1.0);
    end
end
grid on;
xlabel('相对 C++ detected start (\mus)');
ylabel('幅度');
legend({'I', 'Q'}, 'Location', 'northeast');
title(sprintf(['6. 原始 IQ    %s    schedule %.0f    C++ FCS=%d    ', ...
    'det-pred=%+.0f samp'], iq.capture_mode, iq.schedule_index, ...
    iq.fcs_pass, iq.det_minus_pred));
end

function plotFirstPathProcess(delayNs, hBar, earlyIdx, signalIdx, ...
        fpIndex, fpDelay, peakDelay, peakPower, opt)
if isempty(delayNs) || isempty(hBar)
    axisOffMessage('没有相干平均 CIR，无法显示 First Path 搜索');
    return
end
powerBar = abs(hBar(:)).^2;
refPower = normalizeRefPower(peakPower, powerBar);
powerDb = 10 * log10(max(powerBar, eps) / refPower);
[~, nominalZero] = min(abs(delayNs(:)));
baselineCount = min(opt.first_path_baseline_taps, ...
    max(1, nominalZero - opt.guard_samples));
baselineMed = median(powerBar(1:baselineCount));
baselineMad = median(abs(powerBar(1:baselineCount) - baselineMed));
fpThr = baselineMed + opt.first_path_k * max(baselineMad, eps);
fpThr = max(fpThr, max(powerBar) * opt.first_path_min_peak_fraction);
fpThrDb = 10 * log10(max(fpThr, eps) / refPower);
searchLo = max(1, nominalZero - opt.first_path_search_radius);
searchHi = min(numel(delayNs), nominalZero + opt.first_path_search_radius);

hold on;
shadeSpan(delayNs, 1, baselineCount, [0.75 0.75 0.75], 0.28);
shadeSpan(delayNs, searchLo, searchHi, [0.70 0.55 0.90], 0.10);
if ~isempty(earlyIdx)
    shadeSpan(delayNs, earlyIdx(1), earlyIdx(end), [0.45 0.80 0.45], 0.16);
end
if isfinite(fpIndex)
    guardLo = max(1, fpIndex - opt.guard_samples);
    shadeSpan(delayNs, guardLo, fpIndex, [1.00 0.72 0.28], 0.28);
end
if ~isempty(signalIdx)
    shadeSpan(delayNs, signalIdx(1), signalIdx(end), [0.45 0.65 0.95], 0.12);
end
plot(delayNs, powerDb, 'k', 'LineWidth', 1.3);
yline(0, 'k:', '0 dB = first peak', 'LineWidth', 1.0, ...
    'LabelHorizontalAlignment', 'right');
yline(fpThrDb, 'r--', sprintf('FP thr %.1f dB', fpThrDb), ...
    'LabelHorizontalAlignment', 'left', 'LineWidth', 1.1);
xline(0, ':', 'Color', [0.35 0.35 0.35]);
if isfinite(fpDelay)
    xline(fpDelay, 'k--', sprintf('First Path %.2f ns', fpDelay), ...
        'LineWidth', 1.15);
end
if isfinite(peakDelay) && ~(isfinite(fpDelay) && abs(peakDelay - fpDelay) < 1e-9)
    xline(peakDelay, 'b-.', sprintf('first peak %.2f ns', peakDelay), ...
        'LineWidth', 1.15);
end
grid on;
xlabel('相对时延 (ns)');
ylabel('相对 first peak (dB)');
title('1. First Path：基线 / 搜索区 / 保护区 / 信号窗');
ylimRange = [-70, max(powerDb) + 3];
ylim(ylimRange);
end

function plotRepetitionHeatmap(delayNs, individual, earlyIdx, fpDelay, ...
        peakDelay, peakPower)
if isempty(delayNs) || isempty(individual)
    axisOffMessage('没有逐 repetition CIR');
    return
end
refAmp = sqrt(normalizeRefPower(peakPower, abs(individual(:)).^2));
imagesc(delayNs, 1:size(individual, 2), ...
    20*log10(max(abs(individual), eps) / refAmp).');
axis xy;
hold on;
if ~isempty(earlyIdx)
    xline(delayNs(earlyIdx(end)), 'w-', 'LineWidth', 1.0);
end
if isfinite(fpDelay)
    xline(fpDelay, 'w--', 'LineWidth', 1.2);
end
if isfinite(peakDelay) && ~(isfinite(fpDelay) && abs(peakDelay - fpDelay) < 1e-9)
    xline(peakDelay, 'c-.', 'LineWidth', 1.2);
end
xlabel('相对时延 (ns)');
ylabel('CIR 所用 SYNC repetition');
title('2. 逐 repetition |CIR|（0 dB=first peak；白线=early 右沿）');
cb = colorbar;
cb.Label.String = 'dB vs first peak';
end

function plotResidualThresholds(delayNs, residual, earlyIdx, fpDelay, ...
        signalPower, rEarly, rPeak, opt)
if isempty(delayNs) || isempty(residual) || ~isfinite(signalPower)
    axisOffMessage('没有残差功率，无法对照 R_{early}/R_{peak} 阈值');
    return
end
ratioDb = 10 * log10(max(residual(:), 0) / (signalPower + eps) + eps);
hold on;
if ~isempty(earlyIdx)
    shadeSpan(delayNs, earlyIdx(1), earlyIdx(end), [0.45 0.80 0.45], 0.18);
    plot(delayNs(earlyIdx), ratioDb(earlyIdx), ...
        'Color', [0.85 0.35 0.10], 'LineWidth', 1.6);
end
plot(delayNs, ratioDb, 'Color', [0.75 0.55 0.40], 'LineWidth', 0.8);
yline(opt.residual_threshold_db, 'r--', ...
    sprintf('R_{early} 阈值 %g dB', opt.residual_threshold_db), ...
    'LineWidth', 1.15);
yline(opt.peak_threshold_db, 'm-.', ...
    sprintf('R_{peak} 阈值 %g dB', opt.peak_threshold_db), ...
    'LineWidth', 1.15);
if isfinite(rEarly)
    yline(rEarly, 'b:', sprintf('median=%.1f dB', rEarly), 'LineWidth', 1.1);
end
if isfinite(rPeak) && ~isempty(earlyIdx)
    [peakVal, peakLoc] = max(ratioDb(earlyIdx));
    plot(delayNs(earlyIdx(peakLoc)), peakVal, 'mp', ...
        'MarkerSize', 10, 'MarkerFaceColor', 'm');
    text(delayNs(earlyIdx(peakLoc)), peakVal, ...
        sprintf('  peak=%.1f dB', rPeak), 'Color', [0.55 0 0.45]);
end
if isfinite(fpDelay)
    xline(fpDelay, 'k--');
end
grid on;
xlabel('相对时延 (ns)');
ylabel('P_{res} / P_{signal} (dB)');
title('3. 残差比对照阈值：median→R_{early}，early 峰值→R_{peak}');
yVals = [ratioDb(:); opt.residual_threshold_db; opt.peak_threshold_db; ...
    rEarly; rPeak];
yVals = yVals(isfinite(yVals));
if ~isempty(yVals)
    ylim([min(yVals) - 5, max(yVals) + 5]);
end
end

function plotOccupancyProcess(repPower, repThr, occupancy, peakPower, opt)
if isempty(repPower)
    axisOffMessage('没有逐 repetition early power');
    return
end
refPower = normalizeRefPower(peakPower, repPower);
repPowerDb = 10 * log10(max(repPower(:), eps) / refPower);
repThrDb = 10 * log10(max(repThr, eps) / refPower);
occupied = repPower(:) > repThr;
colors = repmat([0.45 0.62 0.82], numel(repPower), 1);
colors(occupied, :) = repmat([0.86 0.28 0.22], nnz(occupied), 1);
b = bar(repPowerDb, 'FaceColor', 'flat', 'EdgeColor', 'none');
b.CData = colors;
hold on;
if isfinite(repThr)
    yline(repThrDb, 'r--', sprintf('T_{rep}=%.1f dB', repThrDb), ...
        'LineWidth', 1.2);
end
grid on;
xlabel('CIR 所用 SYNC repetition');
ylabel('early 功率 / first peak (dB)');
title(sprintf(['4. 占用率过程：超过 T_{rep} 的 repetition / 全部 = ', ...
    '%d/%d = %.2f   阈值 %.2f'], nnz(occupied), numel(repPower), ...
    occupancy, opt.occupancy_threshold));
end

function plotFeatureMeters(rEarly, rPeak, occupancy, opt)
names = {'R_{early}', 'R_{peak}', 'occupancy'};
values = [rEarly, rPeak, occupancy];
thrs = [opt.residual_threshold_db, opt.peak_threshold_db, ...
    opt.occupancy_threshold];
units = {'dB', 'dB', ''};
triggered = [rEarly > opt.residual_threshold_db, ...
    rPeak > opt.peak_threshold_db, ...
    occupancy > opt.occupancy_threshold];
% occupancy 与 dB 量纲不同，换成“几个阈值宽度”再乘 10，便于和残差余量同图。
margins = [rEarly - opt.residual_threshold_db, ...
    rPeak - opt.peak_threshold_db, ...
    10 * (occupancy - opt.occupancy_threshold) / ...
    max(opt.occupancy_threshold, eps)];
barColors = zeros(3, 3);
for k = 1:3
    if triggered(k)
        barColors(k, :) = [0.86 0.28 0.22];
    else
        barColors(k, :) = [0.30 0.62 0.38];
    end
end
b = barh(1:3, margins, 'FaceColor', 'flat', 'EdgeColor', 'none');
b.CData = barColors;
hold on;
xline(0, 'k-', 'LineWidth', 1.2);
set(gca, 'YTick', 1:3, 'YTickLabel', names, 'YDir', 'reverse');
grid on;
xlabel('测量值 − 阈值  （0 线右侧=过线）');
title('5. 三个分类特征相对阈值的余量');
xl = xlim;
if xl(1) == xl(2)
    xlim(xl(1) + [-1 1]);
    xl = xlim;
end
for k = 1:3
    if isfinite(values(k))
        if isempty(units{k})
            label = sprintf('  %.2f  vs  %.2f   %s', values(k), thrs(k), ...
                passFail(triggered(k)));
        else
            label = sprintf('  %.2f %s  vs  %.2f %s   %s', ...
                values(k), units{k}, thrs(k), units{k}, passFail(triggered(k)));
        end
        if margins(k) >= 0
            xText = min(xl(2), margins(k));
            align = 'right';
        else
            xText = max(xl(1), margins(k));
            align = 'left';
        end
        text(xText, k, label, 'VerticalAlignment', 'middle', ...
            'HorizontalAlignment', align, 'FontSize', 9);
    end
end
end

function printIqConsole(iq)
if ~isstruct(iq) || ~isfield(iq, 'ok') || ~iq.ok
    return
end
fprintf(['IQ packet_id=%d local_start=%d predicted_local=%d ', ...
    'det_minus_pred=%+.0f C++ FCS=%d\n'], iq.packet_id, ...
    iq.detected_start_one, iq.predicted_start_one, iq.det_minus_pred, ...
    iq.fcs_pass);
end

function printDecisionConsole(result, d, opt)
fprintf('\n=== CIR 阈值判定  packet %d ===\n', result.packet_id);
fprintf('First Path: %.2f ns   early taps: %d   valid: %d   reason: %s\n', ...
    result.qm35_first_path_delay_ns, result.qm35_early_tap_count, ...
    result.qm35_cir_interference_valid, char(getFieldOr(d, 'reason', "")));
fprintf('R_early = %7.2f dB   阈值 %g dB   过线=%s\n', ...
    result.qm35_early_residual_ratio_db, opt.residual_threshold_db, ...
    yesNo(result.qm35_early_residual_ratio_db > opt.residual_threshold_db));
fprintf('R_peak  = %7.2f dB   阈值 %g dB   过线=%s\n', ...
    result.qm35_early_peak_ratio_db, opt.peak_threshold_db, ...
    yesNo(result.qm35_early_peak_ratio_db > opt.peak_threshold_db));
fprintf('occupancy = %.2f      阈值 %.2f    过线=%s\n', ...
    result.qm35_interference_occupancy, opt.occupancy_threshold, ...
    yesNo(result.qm35_interference_occupancy > opt.occupancy_threshold));
fprintf('state=%s   SIC=%s   confidence=%.2f\n\n', ...
    result.qm35_interference_state, ...
    yesNo(result.qm35_sic_recommended), result.qm35_interference_confidence);
end

function iq = loadResampledPacket(packetIndex, dumpDir, iqFile, ...
        jsonlFile, cppCsv, tapsFile)
iq = emptyIqInfo(packetIndex);
if ~isfile(iqFile) || ~isfile(jsonlFile)
    iq.message = sprintf('缺少 dump IQ：%s', dumpDir);
    return
end
if ~isfile(tapsFile)
    iq.message = sprintf('缺少 resampler taps：%s', tapsFile);
    return
end

[xScaled, meta] = read_uwb_packet(iqFile, jsonlFile, packetIndex);
iqScale = 1;
if isfield(meta, 'iq_scale') && ~isempty(meta.iq_scale)
    iqScale = double(meta.iq_scale);
end
x737 = single(xScaled * iqScale);

fid = fopen(tapsFile, 'rb');
if fid < 0
    iq.message = sprintf('无法打开 taps：%s', tapsFile);
    return
end
taps = fread(fid, Inf, 'single=>single');
fclose(fid);

interp = 65;
decim = 48;
fs = 998.4e6;
filterDelay = (numel(taps) - 1) / 2;
x998 = upfirdn(x737, taps, interp, decim);
windowStart = double(getFieldOr(meta, 'window_start_sample', ...
    getFieldOr(meta, 'start_sample', 0)));
windowStartOut = round((windowStart * interp + filterDelay) / decim);

detectedStartOne = NaN;
predictedStartOne = NaN;
scheduleIndex = NaN;
fcsPass = 0;
detMinusPred = NaN;
if isfile(cppCsv)
    truth = readtable(cppCsv);
    row = find(double(truth.packet_id) == double(packetIndex), 1);
    if ~isempty(row)
        if ismember('window_start_native', truth.Properties.VariableNames)
            windowNative = double(truth.window_start_native(row));
            if isfinite(windowNative) && windowNative ~= windowStart
                iq.message = sprintf( ...
                    ['C++ window_start 与 dump 不一致 (packet %d)。', ...
                    '请确认 dump_dir 与 scheduled_dump_cpp.csv 属于同一次捕获。'], ...
                    packetIndex);
                return
            end
        end
        detectedOut = tableNum(truth, row, 'qm35_detected_start');
        predictedOut = tableNum(truth, row, 'qm35_predicted_start_out');
        if isfinite(detectedOut)
            detectedStartOne = round(detectedOut - windowStartOut + 1);
        end
        if isfinite(predictedOut)
            predictedStartOne = round(predictedOut - windowStartOut + 1);
        end
        scheduleIndex = tableNum(truth, row, 'schedule_index');
        fcsPass = tableNum(truth, row, 'qm35_fcs_pass');
        detMinusPred = tableNum(truth, row, 'qm35_det_minus_pred');
        if ~isfinite(detMinusPred) && isfinite(detectedStartOne) && ...
                isfinite(predictedStartOne)
            detMinusPred = detectedStartOne - predictedStartOne;
        end
    end
end
if ~(isfinite(detectedStartOne) && detectedStartOne >= 1 && ...
        detectedStartOne <= numel(x998))
    detectedStartOne = 1;
end

iq.ok = true;
iq.message = '';
iq.x998 = x998;
iq.fs = fs;
iq.meta = meta;
iq.capture_mode = fieldText(meta, 'capture_mode', 'scheduled');
iq.schedule_index = scheduleIndex;
iq.detected_start_one = detectedStartOne;
iq.predicted_start_one = predictedStartOne;
iq.det_minus_pred = detMinusPred;
iq.fcs_pass = fcsPass;
end

function iq = emptyIqInfo(packetIndex)
iq = struct( ...
    'ok', false, ...
    'message', '', ...
    'packet_id', double(packetIndex), ...
    'x998', [], ...
    'fs', 998.4e6, ...
    'meta', struct(), ...
    'capture_mode', 'scheduled', ...
    'schedule_index', NaN, ...
    'detected_start_one', NaN, ...
    'predicted_start_one', NaN, ...
    'det_minus_pred', NaN, ...
    'fcs_pass', 0);
end

function value = tableNum(tbl, row, name)
value = NaN;
if ~istable(tbl) || ~ismember(name, tbl.Properties.VariableNames)
    return
end
value = double(tbl.(name)(row));
end

function text = fieldText(s, name, fallback)
value = getFieldOr(s, name, '');
if isempty(value)
    text = fallback;
    return
end
text = strtrim(char(value));
if isempty(text)
    text = fallback;
end
end

function result = loadOrDecodePacket(packetIndex, matFile, dumpDir, ...
        iqFile, jsonlFile, cppCsv, tapsFile, iq)
results = loadSavedResults(matFile);
if ~isempty(results)
    ids = [results.packet_id];
    row = find(ids == double(packetIndex), 1);
    if ~isempty(row) && hasPlottableDiagnostics(results(row))
        result = results(row);
        fprintf('Using stored CIR diagnostics for packet %d\n', packetIndex);
        return
    end
end
fprintf(['Stored diagnostics for packet %d are missing; ', ...
    'decoding this packet only...\n'], packetIndex);
result = decodeOneScheduledPacket(packetIndex, dumpDir, iqFile, ...
    jsonlFile, cppCsv, tapsFile, iq);
end

function results = loadSavedResults(matFile)
results = [];
if ~isfile(matFile)
    return
end
loaded = load(matFile, 'results');
if isfield(loaded, 'results')
    results = loaded.results;
end
end

function tf = hasPlottableDiagnostics(result)
tf = isfield(result, 'qm35_cir_interference') && ...
    isfield(result.qm35_cir_interference, 'coherent_cir') && ...
    ~isempty(result.qm35_cir_interference.coherent_cir) && ...
    isfield(result.qm35_cir_interference, 'residual_power') && ...
    ~isempty(result.qm35_cir_interference.residual_power);
end

function result = decodeOneScheduledPacket(packetIndex, dumpDir, ...
        iqFile, jsonlFile, cppCsv, tapsFile, iq)
if nargin >= 7 && isstruct(iq) && isfield(iq, 'ok') && iq.ok
    x998 = iq.x998;
    seededStartOne = iq.detected_start_one;
else
    fallback = loadResampledPacket(packetIndex, dumpDir, iqFile, ...
        jsonlFile, cppCsv, tapsFile);
    assert(fallback.ok, '%s', fallback.message);
    x998 = fallback.x998;
    seededStartOne = fallback.detected_start_one;
end

qm35Opt = struct();
qm35Opt.fs_rx = 998.4e6;
qm35Opt.data_rate = 6.81;
qm35Opt.preamble_repetitions = 64;
qm35Opt.code_index = 9;
qm35Opt.sfd_mode = '4z2';
qm35Opt.cir_skip_initial_repetitions = 10;
qm35Opt.cir_repetitions = 54;
qm35Opt.max_psdu_bytes = 127;
qm35Opt.enable_frame_crop = true;
qm35Opt.show_plots = false;
qm35Opt.cir_store_individual_values = true;
qm35Opt.cir_diag_pre_samples = 64;
qm35Opt.cir_diag_post_samples = 64;
qm35Params = uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), qm35Opt);
qm35Ref = uwbdecoder.buildUwbReference(qm35Params);
sfdTemplates = struct( ...
    'decawave', qm35Params.decawave_sfd(:), ...
    'ieee', qm35Params.ieee_sfd(:), ...
    'sfd4z_1', qm35Params.sfd4z_1(:), ...
    'sfd4z_2', qm35Params.sfd4z_2(:), ...
    'sfd4z_3', qm35Params.sfd4z_3(:), ...
    'sfd4z_4', qm35Params.sfd4z_4(:));

decoded = decode_uwb(qm35Params, x998, [], qm35Ref, ...
    sfdTemplates, 'single', seededStartOne, true);
interference = uwbdecoder.analyzeCirInterference(decoded.cir, struct());

result = struct();
result.packet_id = double(packetIndex);
result.qm35_status = "success";
if ~decoded.payload.fcs_pass
    if decoded.phr.secded_pass
        result.qm35_status = "fcs_or_payload_failed";
    else
        result.qm35_status = "phr_failed";
    end
end
result.qm35_fcs_pass = logical(decoded.payload.fcs_pass);
result.qm35_cir_interference_valid = logical(interference.valid);
result.qm35_first_path_delay_ns = interference.first_path_delay_ns;
result.qm35_early_tap_count = interference.early_tap_count;
result.qm35_early_residual_ratio_db = interference.early_residual_ratio_db;
result.qm35_early_peak_ratio_db = interference.early_peak_ratio_db;
result.qm35_interference_occupancy = interference.interference_occupancy;
result.qm35_interference_state = string(interference.state);
result.qm35_interference_confidence = interference.confidence;
result.qm35_sic_recommended = logical(interference.sic_recommended);
result.qm35_cir_interference = interference;
end

function opt = detectorOptions(diagnostics)
if isfield(diagnostics, 'options') && ~isempty(diagnostics.options)
    opt = diagnostics.options;
else
    opt = struct();
end
defaults = struct( ...
    'guard_samples', 6, ...
    'min_early_taps', 16, ...
    'first_path_k', 6, ...
    'first_path_search_radius', 32, ...
    'first_path_baseline_taps', 16, ...
    'first_path_min_peak_fraction', 1e-2, ...
    'residual_threshold_db', -25, ...
    'peak_threshold_db', -15, ...
    'occupancy_threshold', 0.20);
names = fieldnames(defaults);
for k = 1:numel(names)
    name = names{k};
    if ~isfield(opt, name) || isempty(opt.(name))
        opt.(name) = defaults.(name);
    end
end
end

function shadeSpan(delayNs, i0, i1, color, alpha)
i0 = max(1, min(numel(delayNs), round(i0)));
i1 = max(1, min(numel(delayNs), round(i1)));
if i1 < i0
    return
end
x0 = delayNs(i0);
x1 = delayNs(i1);
yl = [-1e9, 1e9];
patch([x0 x1 x1 x0], [yl(1) yl(1) yl(2) yl(2)], color, ...
    'FaceAlpha', alpha, 'EdgeColor', 'none', 'HandleVisibility', 'off');
end

function axisOffMessage(message)
text(0.5, 0.5, message, 'HorizontalAlignment', 'center', ...
    'Interpreter', 'none');
axis off;
end

function [peakIndex, peakPower, peakDelay] = locateFirstPeak( ...
        hBar, delayNs, fpIndex, signalIdx)
% First local maximum of coherent CIR power at or after First Path.
% First Path is the leading edge; first peak is the mainlobe top after it.
peakIndex = NaN;
peakPower = NaN;
peakDelay = NaN;
if isempty(hBar)
    return
end
powerBar = abs(hBar(:)).^2;
n = numel(powerBar);
if ~isempty(signalIdx)
    searchLo = signalIdx(1);
    searchHi = signalIdx(end);
elseif isfinite(fpIndex)
    searchLo = fpIndex;
    searchHi = n;
else
    [peakPower, peakIndex] = max(powerBar);
    if ~isempty(delayNs) && peakIndex <= numel(delayNs)
        peakDelay = delayNs(peakIndex);
    end
    return
end
searchLo = max(1, min(n, round(searchLo)));
searchHi = max(searchLo, min(n, round(searchHi)));
peakIndex = searchLo;
for i = searchLo:(searchHi - 1)
    if powerBar(i + 1) < powerBar(i)
        peakIndex = i;
        break
    end
    peakIndex = i + 1;
end
peakPower = powerBar(peakIndex);
if ~isempty(delayNs) && peakIndex <= numel(delayNs)
    peakDelay = delayNs(peakIndex);
end
end

function refPower = normalizeRefPower(peakPower, powerValues)
if isfinite(peakPower) && peakPower > 0
    refPower = peakPower;
    return
end
refPower = max(powerValues(:));
if ~(isfinite(refPower) && refPower > 0)
    refPower = 1;
end
end

function value = getFieldOr(s, name, fallback)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    value = s.(name);
else
    value = fallback;
end
end

function txt = yesNo(tf)
if tf
    txt = '是';
else
    txt = '否';
end
end

function txt = passFail(tf)
if tf
    txt = '过线';
else
    txt = '未过线';
end
end

function rgb = stateRgb(state)
switch string(state)
    case "interfered"
        rgb = [0.70 0.10 0.10];
    case "suspected"
        rgb = [0.75 0.40 0.05];
    case "clean"
        rgb = [0.08 0.38 0.18];
    otherwise
        rgb = [0.15 0.15 0.15];
end
end
