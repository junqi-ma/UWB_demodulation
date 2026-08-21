%% Visualize one scheduled QM35 packet: raw IQ plus CIR threshold decision.
% packet_index is the packet_id in capture.jsonl / scheduled_dump_matlab.csv.
% Prefers stored CIR diagnostics in decoded_results; otherwise decodes only
% that packet. Raw IQ is the full ~590 us 998.4 MHz window (I/Q, not |IQ|).
%
% DW1000 FCS 失败目前就两类，改 packet_index 对着看：
%   假锁、后面还有完整包 : 1 24 28 51 55 74 78
%   窗头截断（上一包 SYNC 残尾）: 5 9 32 36 59 63 82 86 90

clear;
close all;
clc;

%% -------------------- User parameters --------------------
packet_index = 3;
dump_dir = 'F:\UWB基带数据\8月20日数据\qm35_dw1000_sensing_1';
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
sic_manifest_file = fullfile(result_dir, ...
    'sic_dw1000_removed_qm35_preserved', 'pipeline_manifest.mat');
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
sic_comparison_png = fullfile(result_dir, sprintf( ...
    'qm35_sic_signal_cir_packet_%03d.png', packet_index));

%% -------------------- Load and plot --------------------
iq = loadResampledPacket(packet_index, dump_dir, iq_file, jsonl_file, ...
    cpp_csv, taps_file);
result = loadOrDecodePacket(packet_index, mat_file, sic_manifest_file, dump_dir, ...
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

dwAnn = loadDwAnnotations(result_dir, packet_index);

fig = figure('Name', sprintf('QM35 CIR threshold packet %d', packet_index), ...
    'Color', 'w', 'Position', [20 20 1680 1080]);
set(fig, 'ToolBar', 'none');
tiledlayout(fig, 4, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

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
plotDwFailurePanel(dwAnn, iq);

nexttile([1 2]);
plotRawIq(iq, dwAnn);

stateColor = stateRgb(state);
sgtitle(fig, sprintf( ...
    'packet %d    CIR %s    SIC %s    QM35 FCS %d    %s', ...
    packet_index, upper(char(state)), ...
    yesNo(result.qm35_sic_recommended), result.qm35_fcs_pass, ...
    dwProblemTitle(dwAnn)), ...
    'FontWeight', 'bold', 'Color', stateColor, 'Interpreter', 'none');

printDecisionConsole(result, d, opt);
printIqConsole(iq, dwAnn);

if save_figure
    outDir = fileparts(output_png);
    if ~isempty(outDir) && ~isfolder(outDir)
        mkdir(outDir);
    end
    exportgraphics(fig, output_png, 'Resolution', 160);
    fprintf('figure: %s\n', output_png);
end

%% -------------------- Original / post-SIC / CIR comparison ------------
sicView = reconstructSelectedPacketSic( ...
    packet_index, result_dir, iq);
if sicView.ok
    comparisonFig = plotSelectedPacketSicComparison( ...
        packet_index, iq, sicView);
    if save_figure
        exportgraphics(comparisonFig, sic_comparison_png, 'Resolution', 160);
        fprintf('SIC signal/CIR comparison: %s\n', sic_comparison_png);
    end
else
    warning('visualize_qm35_cir_interference:SicComparisonUnavailable', ...
        'SIC comparison unavailable for packet %d: %s', ...
        packet_index, sicView.message);
end

function sic = reconstructSelectedPacketSic(packetIndex, resultDir, iq)
sic = struct('ok', false, 'message', "", 'after_iq', [], ...
    'before_pack', struct(), 'after_pack', struct(), ...
    'cancel_report', struct(), 'cancel_mode', "none");
if ~isstruct(iq) || ~isfield(iq, 'ok') || ~iq.ok
    sic.message = "raw IQ unavailable";
    return
end
manifestFile = fullfile(resultDir, ...
    'sic_dw1000_removed_qm35_preserved', 'pipeline_manifest.mat');
if ~isfile(manifestFile)
    sic.message = "SIC pipeline manifest not found";
    return
end
loaded = load(manifestFile, 'pipeline');
records = loaded.pipeline.packets;
row = find([records.packet_id] == double(packetIndex), 1);
if isempty(row)
    sic.message = "packet is not present in the SIC manifest";
    return
end
record = records(row);
sic.before_pack = record.qm35_before;
sic.after_pack = record.qm35_after;
sic.cancel_mode = string(record.dw_cancel_mode);
if ~record.sic_applied
    sic.message = "SIC was not applied to this packet";
    return
end

try
    [qmParams, qmReference, qmSfd, qmTx, qmCancel] = buildQm35SicReference();
    xOriginal = iq.x998(:);
    qmDecoded = decode_uwb(qmParams, xOriginal, [], ...
        qmReference, qmSfd, 'single', iq.detected_start_one, true);
    xAfterQm35 = xOriginal;
    if qmDecoded.payload.fcs_pass
        xAfterQm35 = cancel_uwb_packet_in_iq( ...
            xOriginal, qmDecoded, qmTx, qmCancel);
    end

    dwProfile = buildDwSicProfile(record.dw_profile);
    cancelOptions = dwProfile.cancel;
    cancelOptions.min_alignment_correlation = 0.60;
    switch sic.cancel_mode
        case "full"
            dwDecoded = decode_uwb(dwProfile.params, xAfterQm35, [], ...
                dwProfile.reference, dwProfile.sfd, 'single', ...
                record.dw_overlap_start, true);
            [sic.after_iq, sic.cancel_report] = cancel_uwb_packet_in_iq( ...
                xOriginal, dwDecoded, dwProfile.tx, cancelOptions);
        case "preamble"
            [preamble, cirEstimate] = estimate_uwb_preamble_cir( ...
                xAfterQm35, dwProfile.reference, dwProfile.params, ...
                record.dw_overlap_start);
            txOptions = struct( ...
                'code_index', dwProfile.params.code_index, ...
                'visible_reps', record.dw_visible_reps, ...
                'fs_tx', 998.4e6, 'phy_mode', '802.15.4a', ...
                'peak_amplitude', 1, 'guard_samples', 0);
            cancelOptions.cfo_fit_last_sync = record.dw_visible_reps;
            cancelOptions.gain_fit_last_sync = record.dw_visible_reps;
            [sic.after_iq, sic.cancel_report] = ...
                cancel_uwb_preamble_in_iq(xOriginal, preamble, ...
                cirEstimate, txOptions, cancelOptions);
        otherwise
            error('Unsupported SIC mode: %s', sic.cancel_mode);
    end
    sic.after_iq = sic.after_iq(:);
    sic.before_pack = packSicViewQm35(qmDecoded);
    qmAfter = decode_uwb(qmParams, sic.after_iq, [], ...
        qmReference, qmSfd, 'single', iq.detected_start_one, true);
    sic.after_pack = packSicViewQm35(qmAfter);
    sic.ok = true;
catch err
    sic.message = string(err.message);
end
end

function packed = packSicViewQm35(decoded)
interference = uwbdecoder.analyzeCirInterference(decoded.cir, struct( ...
    'occupancy_background_margin_db', 3));
packed = struct('cir', decoded.cir, 'interference', interference, ...
    'first_path_delay_ns', interference.first_path_delay_ns, ...
    'fcs_pass', logical(decoded.payload.fcs_pass));
end

function fig = plotSelectedPacketSicComparison(packetIndex, iq, sic)
xBefore = iq.x998(:);
xAfter = sic.after_iq(:);
n = min(numel(xBefore), numel(xAfter));
xBefore = xBefore(1:n);
xAfter = xAfter(1:n);
fs = iq.fs;
commonScale = max(abs(xBefore)) + eps;
maxPoints = 120000;
stride = max(1, ceil(n/maxPoints));
span = (1:stride:n).';
timeUs = (double(span)-1)/fs*1e6;

fig = figure('Name', sprintf('Packet %d SIC signal and CIR', packetIndex), ...
    'Color', 'w', 'Position', [30 30 1540 980]);
tiledlayout(fig, 3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

nexttile;
plot(timeUs, real(xBefore(span))/commonScale, ...
    'Color', [0.15 0.45 0.85], 'LineWidth', 0.45);
hold on;
plot(timeUs, imag(xBefore(span))/commonScale, '--', ...
    'Color', [0.85 0.25 0.18], 'LineWidth', 0.45);
grid on; ylim([-1.05 1.05]); xlim([timeUs(1) timeUs(end)]);
xlabel('Time from dump-window start (us)');
ylabel('Amplitude / original peak');
title('Original received signal before SIC');
legend('I', 'Q', 'Location', 'northeast');

nexttile;
plot(timeUs, real(xAfter(span))/commonScale, ...
    'Color', [0.15 0.45 0.85], 'LineWidth', 0.45);
hold on;
plot(timeUs, imag(xAfter(span))/commonScale, '--', ...
    'Color', [0.85 0.25 0.18], 'LineWidth', 0.45);
grid on; ylim([-1.05 1.05]); xlim([timeUs(1) timeUs(end)]);
xlabel('Time from dump-window start (us)');
ylabel('Amplitude / original peak');
title(sprintf('Signal after DW1000 SIC (%s cancellation)', sic.cancel_mode));
legend('I', 'Q', 'Location', 'northeast');

nexttile;
[beforeCir, beforeDelay] = packedCoherentCir(sic.before_pack);
[afterCir, afterDelay] = packedCoherentCir(sic.after_pack);
afterCir = interp1(afterDelay, afterCir, beforeDelay, 'linear', 0);
referencePower = max(abs(beforeCir).^2) + eps;
beforeDb = 10*log10(max(abs(beforeCir).^2, eps)/referencePower);
afterDb = 10*log10(max(abs(afterCir).^2, eps)/referencePower);
plot(beforeDelay, beforeDb, 'LineWidth', 1.35, ...
    'Color', [0.15 0.45 0.85]);
hold on;
plot(beforeDelay, afterDb, '--', 'LineWidth', 1.35, ...
    'Color', [0.85 0.30 0.12]);
if isfinite(sic.before_pack.first_path_delay_ns)
    xline(sic.before_pack.first_path_delay_ns, ':', ...
        'Before First Path', 'Color', [0.15 0.45 0.85]);
end
if isfinite(sic.after_pack.first_path_delay_ns)
    xline(sic.after_pack.first_path_delay_ns, ':', ...
        'After First Path', 'Color', [0.85 0.30 0.12]);
end
grid on; ylim([-60 5]);
xlabel('CIR delay (ns)');
ylabel('Power / before-SIC global peak (dB)');
title('QM35 CIR before and after SIC, common absolute reference');
legend('Before SIC', 'After SIC', 'Location', 'best');

sgtitle(sprintf(['packet %d | original and post-SIC signal | ', ...
    'QM35 CIR comparison'], packetIndex));
end

function [values, delay] = packedCoherentCir(pack)
if isfield(pack, 'interference') && ...
        isfield(pack.interference, 'coherent_cir') && ...
        ~isempty(pack.interference.coherent_cir)
    values = pack.interference.coherent_cir(:);
    delay = pack.interference.delay_ns(:);
elseif isfield(pack, 'cir') && isfield(pack.cir, 'values')
    values = pack.cir.values(:);
    delay = pack.cir.delay_ns(:);
else
    error('Packed QM35 result has no CIR values.');
end
end

function [params, reference, sfd, tx, cancel] = buildQm35SicReference()
opt = struct('fs_rx', 998.4e6, 'data_rate', 6.81, ...
    'preamble_repetitions', 64, 'code_index', 9, 'sfd_mode', '4z2', ...
    'cir_skip_initial_repetitions', 10, 'cir_repetitions', 54, ...
    'cir_store_individual_values', true, 'cir_diag_pre_samples', 64, ...
    'cir_diag_post_samples', 64, 'max_psdu_bytes', 127, ...
    'enable_frame_crop', true, 'show_plots', false);
params = uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), opt);
reference = uwbdecoder.buildUwbReference(params);
sfd = buildSicSfdTemplates(params);
tx = struct('fs_tx', 998.4e6, 'phy_mode', 'BPRF', ...
    'ranging', false, 'preamble_repetitions', 64, 'code_index', 9, ...
    'sfd_number', 2, 'sfd_sequence', [], 'peak_amplitude', 1, ...
    'guard_samples', 0, 'require_fcs_pass', true);
cancel = struct('fs_rx', 998.4e6, ...
    'cancellation_mode', 'optimal_complex', ...
    'cfo_fit_last_sync', 64, 'gain_fit_last_sync', 64, ...
    'pll_phase_compensation', load_uwb_pll_phase_compensation( ...
        true, fullfile(fileparts(mfilename('fullpath')), ...
        'decoded_results', 'pll_phase_drift_analysis', 'qm35_new_3', ...
        'subsync_phase_template.csv'), 10, 64));
end

function profile = buildDwSicProfile(profileName)
switch string(profileName)
    case "dw1000_code10_n256"
        codeIndex = 10; repetitions = 256; cirRepetitions = 64;
    case {"dw1000_code11_n256", "dw1000_code11_n128"}
        codeIndex = 11; repetitions = 256; cirRepetitions = 118;
    otherwise
        error('Unknown DW1000 SIC profile: %s', string(profileName));
end
opt = struct('fs_rx', 998.4e6, 'data_rate', 6.81, ...
    'preamble_repetitions', repetitions, 'code_index', codeIndex, ...
    'sfd_mode', 'decawave', 'cir_skip_initial_repetitions', 10, ...
    'cir_repetitions', cirRepetitions, ...
    'cir_store_individual_values', true, 'max_psdu_bytes', 127, ...
    'enable_frame_crop', true, 'show_plots', false);
params = uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), opt);
profile = struct();
profile.params = params;
profile.reference = uwbdecoder.buildUwbReference(params);
profile.sfd = buildSicSfdTemplates(params);
profile.tx = struct('fs_tx', 998.4e6, 'phy_mode', '802.15.4a', ...
    'ranging', true, 'preamble_repetitions', repetitions, ...
    'code_index', codeIndex, 'sfd_number', 0, ...
    'sfd_sequence', [-1; -1; -1; -1; 1; -1; 0; 0], ...
    'peak_amplitude', 1, 'guard_samples', 0, 'require_fcs_pass', true);
profile.cancel = struct('fs_rx', 998.4e6, ...
    'cancellation_mode', 'optimal_complex', ...
    'cfo_fit_last_sync', repetitions, ...
    'gain_fit_last_sync', repetitions, ...
    'pll_phase_compensation', load_uwb_pll_phase_compensation( ...
        true, fullfile(fileparts(mfilename('fullpath')), ...
        'decoded_results', 'pll_phase_drift_analysis', 'dw1000_new_3', ...
        'subsync_phase_template.csv'), 10, repetitions));
end

function templates = buildSicSfdTemplates(params)
templates = struct('decawave', params.decawave_sfd(:), ...
    'ieee', params.ieee_sfd(:), 'sfd4z_1', params.sfd4z_1(:), ...
    'sfd4z_2', params.sfd4z_2(:), 'sfd4z_3', params.sfd4z_3(:), ...
    'sfd4z_4', params.sfd4z_4(:));
end

function plotRawIq(iq, dwAnn)
if nargin < 2
    dwAnn = emptyDwAnnotations();
end
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
tEndUs = n / fs * 1e6;
qm35Start = iq.detected_start_one;
if ~(isfinite(qm35Start) && qm35Start >= 1 && qm35Start <= n)
    qm35Start = NaN;
end

% Full dump window (~500–590 μs): raw I and Q, not |IQ|.
maxPoints = 80000;
stride = max(1, ceil(n / maxPoints));
span = 1:stride:n;
tUs = (double(span) - 1) / fs * 1e6;
xi = real(x998(span));
xq = imag(x998(span));
peakAmp = max(abs(x998));
if ~(isfinite(peakAmp) && peakAmp > 0)
    peakAmp = 1;
end
yl = 1.05 * peakAmp * [-1, 1];

hold on;
syncDwUs = 256 * 1016 / fs * 1e6;
syncQmUs = 64 * 1016 / fs * 1e6;
if isfinite(dwAnn.dw_start)
    shadeTime(sampleToUs(dwAnn.dw_start, fs), syncDwUs, yl, ...
        [0.86 0.28 0.22], 0.12);
end
if isfinite(dwAnn.later_viable)
    shadeTime(sampleToUs(dwAnn.later_viable, fs), syncDwUs, yl, ...
        [0.20 0.65 0.30], 0.14);
end
if isfinite(dwAnn.clipped)
    shadeTime(sampleToUs(dwAnn.clipped, fs), syncDwUs, yl, ...
        [0.95 0.70 0.15], 0.10);
end
if isfinite(qm35Start)
    shadeTime(sampleToUs(qm35Start, fs), syncQmUs, yl, ...
        [0.20 0.40 0.85], 0.12);
end
plot(tUs, xi, 'Color', [0.15 0.40 0.85], 'LineWidth', 0.5);
plot(tUs, xq, '--', 'Color', [0.85 0.20 0.18], 'LineWidth', 0.5);
addTimeMarker(sampleToUs(qm35Start, fs), tEndUs, 'k--', 'QM35');
addTimeMarker(sampleToUs(iq.predicted_start_one, fs), tEndUs, 'b:', 'QM35 pred');
if dwAnn.dw_fcs
    addTimeMarker(sampleToUs(dwAnn.dw_start, fs), tEndUs, 'r-', 'DW FCS ok');
elseif dwAnn.class == "false_lock_missed_later_dw"
    addTimeMarker(sampleToUs(dwAnn.dw_start, fs), tEndUs, 'r-', '假锁');
    addTimeMarker(sampleToUs(dwAnn.later_viable, fs), tEndUs, 'g-', '后段真包');
elseif dwAnn.class == "clipped_head_incomplete_sync"
    addTimeMarker(sampleToUs(dwAnn.dw_start, fs), tEndUs, 'r-', '窗头残尾');
    addTimeMarker(sampleToUs(dwAnn.truncated, fs), tEndUs, 'm-.', '后包SFD出窗');
else
    addTimeMarker(sampleToUs(dwAnn.dw_start, fs), tEndUs, 'r-', 'DW lock');
    addTimeMarker(sampleToUs(dwAnn.later_viable, fs), tEndUs, 'g-', '后段真包');
    addTimeMarker(sampleToUs(dwAnn.truncated, fs), tEndUs, 'm-.', '后包SFD出窗');
end
grid on;
xlim([0, tEndUs]);
ylim(yl);
xlabel('相对窗起点 (\mus)，整窗原始 I/Q');
ylabel('幅度');
legend({'I', 'Q'}, 'Location', 'northeast');
title(sprintf('6. 原始 IQ 全窗  %.1f us    %s', tEndUs, ...
    dwProblemTitle(dwAnn)), 'Interpreter', 'none');
end

function plotDwFailurePanel(dwAnn, iq)
axis off;
xlim([0 1]);
ylim([0 1]);
title('DW1000 失败类型', 'Interpreter', 'none');
lines = dwProblemLines(dwAnn, iq);
text(0.04, 0.92, lines, 'Interpreter', 'none', 'FontSize', 10, ...
    'VerticalAlignment', 'top', 'HorizontalAlignment', 'left');
end

function titleTxt = dwProblemTitle(dwAnn)
if ~isstruct(dwAnn) || strlength(dwAnn.class) == 0
    if isstruct(dwAnn) && dwAnn.has_sic && dwAnn.dw_fcs
        titleTxt = 'DW FCS 通过';
    else
        titleTxt = '无 DW 失败标注';
    end
    return
end
switch dwAnn.class
    case "false_lock_missed_later_dw"
        titleTxt = '假锁：窗头残段，后段还有完整 DW';
    case "clipped_head_incomplete_sync"
        titleTxt = '窗头截断：上一包 SYNC 残尾，本窗解不出';
    otherwise
        titleTxt = char(dwAnn.class);
end
end

function lines = dwProblemLines(dwAnn, iq)
if ~isstruct(dwAnn) || ~dwAnn.has_sic
    lines = {'本窗不在 16 个 DW FCS 失败里。', ...
        '假锁: 1 24 28 51 55 74 78', ...
        '窗头截断: 5 9 32 36 59 63 82 86 90'};
    return
end
fs = 998.4e6;
lockUs = sampleToUs(dwAnn.dw_start, fs);
laterUs = sampleToUs(dwAnn.later_viable, fs);
clipUs = sampleToUs(dwAnn.clipped, fs);
truncUs = sampleToUs(dwAnn.truncated, fs);
switch dwAnn.class
    case "false_lock_missed_later_dw"
        lines = { ...
            '类型: 假锁', ...
            sprintf('检测器锁在窗头 %.1f us', lockUs), ...
            '那是上一包 DW 伸进来的 SYNC 残尾。', ...
            sprintf('后段真包约 %.1f us（绿带）', laterUs), ...
            '单包搜索 earliest-first，没有再往后找。'};
    case "clipped_head_incomplete_sync"
        lines = { ...
            '类型: 窗头截断', ...
            sprintf('上一包 DW 起点在窗外 %.1f us', clipUs), ...
            sprintf('本窗只剩残尾，锁点 %.1f us', lockUs), ...
            sprintf('若有后包，SFD 约 %.1f us 已出窗', truncUs), ...
            '590 us 窗装不下完整 256 SYNC+SFD。'};
    otherwise
        lines = {char(dwAnn.class), sprintf('lock=%.1f us', lockUs)};
end
if nargin >= 2 && isstruct(iq) && isfield(iq, 'detected_start_one')
    lines{end+1} = sprintf('QM35 约 %.1f us', ...
        sampleToUs(iq.detected_start_one, fs));
end
end

function addTimeMarker(tUs, tEndUs, style, label)
if ~(isfinite(tUs) && tUs >= -1 && tUs <= tEndUs + 1)
    return
end
xline(tUs, style, label, 'LineWidth', 1.05, 'Interpreter', 'none', ...
    'LabelOrientation', 'horizontal', 'LabelVerticalAlignment', 'bottom');
end

function tUs = sampleToUs(sampleOne, fs)
tUs = (double(sampleOne) - 1) / fs * 1e6;
end

function shadeTime(t0Us, durUs, yl, color, alpha)
if ~isfinite(t0Us) || ~isfinite(durUs) || numel(yl) < 2
    return
end
x0 = t0Us;
x1 = t0Us + durUs;
patch([x0 x1 x1 x0], [yl(1) yl(1) yl(2) yl(2)], color, ...
    'FaceAlpha', alpha, 'EdgeColor', 'none', 'HandleVisibility', 'off');
end

function ann = emptyDwAnnotations()
ann = struct( ...
    'has_sic', false, ...
    'dw_start', NaN, ...
    'dw_fcs', false, ...
    'later_viable', NaN, ...
    'clipped', NaN, ...
    'truncated', NaN, ...
    'class', "");
end

function ann = loadDwAnnotations(resultDir, packetIndex)
ann = emptyDwAnnotations();
sicDir = fullfile(resultDir, 'sic_dw1000_removed_qm35_preserved');
failCsv = fullfile(sicDir, 'dw1000_decode_failures.csv');
sicMat = fullfile(sicDir, 'pipeline_manifest.mat');
if isfile(failCsv)
    T = readtable(failCsv, 'TextType', 'string');
    row = find(double(T.packet_id) == double(packetIndex), 1);
    if ~isempty(row)
        ann.dw_start = tableNum(T, row, 'dw_lock_start');
        ann.later_viable = tableNum(T, row, 'later_viable_start');
        ann.clipped = tableNum(T, row, 'clipped_start');
        ann.truncated = tableNum(T, row, 'truncated_start');
        if ismember('failure_class', T.Properties.VariableNames)
            ann.class = string(T.failure_class(row));
        end
        ann.dw_fcs = false;
        ann.has_sic = true;
    end
end
if ~ann.has_sic && isfile(sicMat)
    loaded = load(sicMat, 'pipeline');
    packets = loaded.pipeline.packets;
    for k = 1:numel(packets)
        if double(packets(k).packet_id) == double(packetIndex)
            ann.has_sic = true;
            ann.dw_start = packets(k).dw.start_sample;
            ann.dw_fcs = logical(packets(k).dw.fcs_pass);
            break
        end
    end
end
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

function printIqConsole(iq, dwAnn)
if ~isstruct(iq) || ~isfield(iq, 'ok') || ~iq.ok
    return
end
winUs = numel(iq.x998) / iq.fs * 1e6;
fprintf(['IQ packet_id=%d  window=%.1f us  start=%d (%.1f us)  ', ...
    'predicted=%d  det-pred=%+.0f  stored FCS=%g\n'], iq.packet_id, winUs, ...
    iq.detected_start_one, sampleToUs(iq.detected_start_one, iq.fs), ...
    iq.predicted_start_one, iq.det_minus_pred, iq.fcs_pass);
if nargin >= 2 && isstruct(dwAnn) && dwAnn.has_sic
    fprintf('%s\n', dwProblemTitle(dwAnn));
    fprintf('DW lock=%.0f  later=%.0f  clipped=%.0f  trunc=%.0f\n', ...
        dwAnn.dw_start, dwAnn.later_viable, dwAnn.clipped, dwAnn.truncated);
end
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
[xScaled, meta] = read_uwb_packet(iqFile, jsonlFile, packetIndex);
iqScale = 1;
if isfield(meta, 'iq_scale') && ~isempty(meta.iq_scale)
    iqScale = double(meta.iq_scale);
end
xInput = single(xScaled * iqScale);

fs = 998.4e6;
inputFs = double(getFieldOr(meta, 'sample_rate', 737.28e6));
if abs(inputFs - fs) <= fs * 1e-9
    interp = 1;
    decim = 1;
    filterDelay = 0;
    x998 = xInput;
elseif abs(inputFs - 737.28e6) <= 737.28e6 * 1e-9
    if ~isfile(tapsFile)
        iq.message = sprintf('缺少 resampler taps：%s', tapsFile);
        return
    end
    fid = fopen(tapsFile, 'rb');
    if fid < 0
        iq.message = sprintf('无法打开 taps：%s', tapsFile);
        return
    end
    taps = fread(fid, Inf, 'single=>single');
    fclose(fid);
    interp = 65;
    decim = 48;
    filterDelay = (numel(taps) - 1) / 2;
    x998 = upfirdn(xInput, taps, interp, decim);
else
    iq.message = sprintf(['不支持 %.6f MHz dump；期望采样率为 ', ...
        '737.28 或 998.4 MHz。'], inputFs / 1e6);
    return
end
windowStart = double(getFieldOr(meta, 'window_start_sample', ...
    getFieldOr(meta, 'start_sample', 0)));
windowStartOut = round((windowStart * interp + filterDelay) / decim);

detectedStartOne = NaN;
predictedStartOne = NaN;
scheduleIndex = NaN;
fcsPass = NaN;
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
% 新版 dump 可以不带 scheduled_dump_cpp.csv；此时直接使用 JSONL 中
% 与 capture.iq 同源的全局检测/预测位置，并换算到当前窗口的 1-based
% 998.4 MHz 索引。C++ CSV 若存在且有效，仍具有更高优先级。
if ~(isfinite(detectedStartOne) && detectedStartOne >= 1 && ...
        detectedStartOne <= numel(x998)) && ...
        isfield(meta, 'detected_start_sample') && ...
        ~isempty(meta.detected_start_sample)
    detectedInput = double(meta.detected_start_sample);
    detectedStartOne = round( ...
        (detectedInput - windowStart) * interp / decim) + 1;
end
if ~(isfinite(predictedStartOne) && predictedStartOne >= 1 && ...
        predictedStartOne <= numel(x998)) && ...
        isfield(meta, 'predicted_start_sample') && ...
        ~isempty(meta.predicted_start_sample)
    predictedInput = double(meta.predicted_start_sample);
    predictedStartOne = round( ...
        (predictedInput - windowStart) * interp / decim) + 1;
end
if ~isfinite(scheduleIndex)
    scheduleIndex = double(getFieldOr(meta, 'schedule_index', NaN));
end
if ~isfinite(detMinusPred) && isfinite(detectedStartOne) && ...
        isfinite(predictedStartOne)
    detMinusPred = detectedStartOne - predictedStartOne;
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
    'fcs_pass', NaN);
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

function result = loadOrDecodePacket(packetIndex, matFile, ...
        sicManifestFile, dumpDir, ...
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
result = loadSicManifestResult(sicManifestFile, packetIndex);
if ~isempty(result) && hasPlottableDiagnostics(result)
    fprintf('Using SIC manifest CIR diagnostics for packet %d\n', packetIndex);
    return
end
fprintf(['Stored diagnostics for packet %d are missing; ', ...
    'decoding this packet only...\n'], packetIndex);
result = decodeOneScheduledPacket(packetIndex, dumpDir, iqFile, ...
    jsonlFile, cppCsv, tapsFile, iq);
end

function result = loadSicManifestResult(manifestFile, packetIndex)
% 将当前 scheduled-dump SIC manifest 的 QM35-before 记录转换为本脚本
% 使用的旧版单包结果字段，避免为了画图再次解调整个 packet。
result = [];
if ~isfile(manifestFile)
    return
end
loaded = load(manifestFile, 'pipeline');
if ~isfield(loaded, 'pipeline') || ...
        ~isfield(loaded.pipeline, 'packets')
    return
end
records = loaded.pipeline.packets;
row = find([records.packet_id] == double(packetIndex), 1);
if isempty(row) || ~isfield(records(row), 'qm35_before')
    return
end
pack = records(row).qm35_before;
if ~isstruct(pack) || ~isfield(pack, 'interference') || ...
        isempty(pack.interference)
    return
end
d = pack.interference;
result = struct();
result.packet_id = double(packetIndex);
result.qm35_fcs_pass = logical(getFieldOr(pack, 'fcs_pass', false));
result.qm35_cir_interference_valid = logical(getFieldOr(d, 'valid', false));
result.qm35_first_path_delay_ns = getFieldOr( ...
    pack, 'first_path_delay_ns', getFieldOr(d, 'first_path_delay_ns', NaN));
result.qm35_early_tap_count = getFieldOr(d, 'early_tap_count', 0);
result.qm35_early_residual_ratio_db = getFieldOr( ...
    pack, 'early_residual_ratio_db', ...
    getFieldOr(d, 'early_residual_ratio_db', NaN));
result.qm35_early_peak_ratio_db = getFieldOr( ...
    pack, 'early_peak_ratio_db', getFieldOr(d, 'early_peak_ratio_db', NaN));
result.qm35_interference_occupancy = getFieldOr( ...
    pack, 'interference_occupancy', ...
    getFieldOr(d, 'interference_occupancy', NaN));
result.qm35_interference_state = string(getFieldOr( ...
    pack, 'interference_state', getFieldOr(d, 'state', "invalid")));
result.qm35_interference_confidence = getFieldOr(d, 'confidence', NaN);
result.qm35_sic_recommended = logical(getFieldOr( ...
    pack, 'sic_recommended', getFieldOr(d, 'sic_recommended', false)));
result.qm35_cir_interference = d;
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
