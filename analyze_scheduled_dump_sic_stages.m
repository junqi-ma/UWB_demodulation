%% Analyze every SIC stage for one scheduled-dump packet.
% The pipeline uses xAfterQm35 only to expose/decode DW1000. DW1000 is then
% subtracted from the original mixture so that the desired QM35 is kept.
clear;
close all;
clc;

this_dir = fileparts(mfilename('fullpath'));
if isempty(this_dir)
    this_dir = pwd;
end
addpath(this_dir);

%% -------------------- User parameters --------------------
dump_dir = 'F:\UWB基带数据\qm35_gain1_scheduled_sc16_dump_20260817';
[~, dump_name] = fileparts(char(strtrim(string(dump_dir))));
manifest_file = fullfile(this_dir, 'decoded_results', dump_name, ...
    'sic_dw1000_removed_qm35_preserved', 'pipeline_manifest.mat');
packet_id = 27;
save_figure = true;
figure_resolution_dpi = 160;
max_plot_points = 120000;
phase_min_amplitude_ratio = 0.05; % ignore noise-dominated phase samples

%% -------------------- Load and reconstruct --------------------
assert(isfile(manifest_file), 'Pipeline manifest not found: %s', manifest_file);
saved = load(manifest_file, 'pipeline');
pipeline = saved.pipeline;
row = find([pipeline.packets.packet_id] == packet_id, 1);
assert(~isempty(row), 'packet_id %d is not in the manifest.', packet_id);
record = pipeline.packets(row);
assert(record.ok, 'packet_id %d failed in the SIC pipeline: %s', ...
    packet_id, record.error_message);
assert(record.sic_applied, 'SIC was not applied to packet_id %d.', packet_id);

stage = reconstructSicStages(record, pipeline.config);

%% -------------------- Plot --------------------
signalLength = min([numel(stage.original), numel(stage.after_qm35), ...
    numel(stage.after_dw1000)]);
stride = max(1, ceil(signalLength / max_plot_points));
span = (1:stride:signalLength).';
timeUs = (double(span) - 1) / stage.fs * 1e6;
commonScale = max(abs(stage.original)) + eps;

% Figure 1: signals at the three actual SIC pipeline states.
figStages = figure('Name', sprintf('SIC stages packet %d', packet_id), ...
    'Color', 'w', 'Position', [30 30 1500 920]);
tiledlayout(figStages, 3, 1, ...
    'TileSpacing', 'compact', 'Padding', 'compact');
stageAxes = gobjects(3, 1);
stageAxes(1) = nexttile;
plotIqStage(timeUs, stage.original(span) / commonScale, ...
    '1. Original received mixture');
stageAxes(2) = nexttile;
plotIqStage(timeUs, stage.after_qm35(span) / commonScale, ...
    '2. After QM35 cancellation (used for DW1000 decoding)');
stageAxes(3) = nexttile;
plotIqStage(timeUs, stage.after_dw1000(span) / commonScale, ...
    sprintf('3. After DW1000 cancellation (%s; QM35 preserved)', ...
    record.dw_cancel_mode));
linkaxes(stageAxes, 'xy');
sgtitle(sprintf(['packet %d | SIC pipeline signal states | ', ...
    'DW profile %s | common scale: original peak'], ...
    packet_id, record.dw_profile), 'Interpreter', 'none');

% Figure 2: generated cancellation signals versus the corresponding
% single-user states, including phase error where both signals are active.
figGenerated = figure('Name', sprintf( ...
    'Generated-signal comparison packet %d', packet_id), ...
    'Color', 'w', 'Position', [45 45 1640 900]);
tiledlayout(figGenerated, 2, 2, ...
    'TileSpacing', 'compact', 'Padding', 'compact');
comparisonAxes = gobjects(4, 1);
comparisonAxes(1) = nexttile;
plotMagnitudeOverlay(timeUs, ...
    stage.estimated_qm35(span) / commonScale, ...
    stage.after_dw1000(span) / commonScale, ...
    'Generated QM35', 'QM35-only state (after DW1000 SIC)', ...
    'QM35 magnitude: generated signal vs QM35-only state');
comparisonAxes(2) = nexttile;
stage.qm35_phase_comparison = plotPhaseComparison(timeUs, ...
    stage.estimated_qm35(span) / commonScale, ...
    stage.after_dw1000(span) / commonScale, ...
    phase_min_amplitude_ratio, 'QM35');
comparisonAxes(3) = nexttile;
plotMagnitudeOverlay(timeUs, ...
    stage.estimated_dw1000(span) / commonScale, ...
    stage.after_qm35(span) / commonScale, ...
    'Generated DW1000', 'DW1000-only state (after QM35 SIC)', ...
    'DW1000 magnitude: generated signal vs DW1000-only state');
comparisonAxes(4) = nexttile;
stage.dw1000_phase_comparison = plotPhaseComparison(timeUs, ...
    stage.estimated_dw1000(span) / commonScale, ...
    stage.after_qm35(span) / commonScale, ...
    phase_min_amplitude_ratio, 'DW1000');
linkaxes(comparisonAxes, 'x');
sgtitle(sprintf(['packet %d | generated cancellation waveform versus ', ...
    'single-user SIC state | active threshold %.0f%% of original peak'], ...
    packet_id, 100 * phase_min_amplitude_ratio));

% Figure 3: CIR is kept separate so its delay axis is not visually mixed
% with the complete dump-window time axes above.
figCir = figure('Name', sprintf('CIR comparison packet %d', packet_id), ...
    'Color', 'w', 'Position', [90 90 1100 650]);
plotCirBeforeAfter(record.qm35_before, record.qm35_after);
title(sprintf('QM35 CIR before/after DW1000 SIC | coherence %.4f', ...
    record.cir_metrics.cir_coherence));

fprintf('\n=== Scheduled-dump SIC stage analysis ===\n');
fprintf('packet_id       : %d\n', packet_id);
fprintf('DW profile/mode : %s / %s\n', record.dw_profile, record.dw_cancel_mode);
fprintf('QM35 cancel     : %.2f dB\n', record.qm35_cancel.frame_suppression_db);
fprintf('DW1000 cancel   : %.2f dB\n', record.dw_cancel.frame_suppression_db);
fprintf('CIR coherence   : %.4f\n', record.cir_metrics.cir_coherence);
fprintf('QM35 phase error: mean %.2f deg, RMS %.2f deg (%d active samples)\n', ...
    stage.qm35_phase_comparison.circular_mean_deg, ...
    stage.qm35_phase_comparison.circular_rms_deg, ...
    stage.qm35_phase_comparison.active_samples);
fprintf('DW phase error  : mean %.2f deg, RMS %.2f deg (%d active samples)\n', ...
    stage.dw1000_phase_comparison.circular_mean_deg, ...
    stage.dw1000_phase_comparison.circular_rms_deg, ...
    stage.dw1000_phase_comparison.active_samples);

if save_figure
    output_dir = pipeline.paths.validation_dir;
    if ~isfolder(output_dir)
        mkdir(output_dir);
    end
    stage_png = fullfile(output_dir, sprintf( ...
        'sic_stage_waveforms_packet_%03d.png', packet_id));
    generated_png = fullfile(output_dir, sprintf( ...
        'sic_generated_signal_comparison_packet_%03d.png', packet_id));
    cir_png = fullfile(output_dir, sprintf( ...
        'sic_cir_comparison_packet_%03d.png', packet_id));
    exportgraphics(figStages, stage_png, 'Resolution', figure_resolution_dpi);
    exportgraphics(figGenerated, generated_png, ...
        'Resolution', figure_resolution_dpi);
    exportgraphics(figCir, cir_png, 'Resolution', figure_resolution_dpi);
    fprintf('Stage figure    : %s\n', stage_png);
    fprintf('Signal figure   : %s\n', generated_png);
    fprintf('CIR figure      : %s\n', cir_png);
end

assignin('base', 'scheduled_dump_sic_stage_analysis', stage);

function plotIqStage(timeUs, values, plotTitle)
plot(timeUs, real(values), 'Color', [0.15 0.45 0.85], 'LineWidth', 0.40);
hold on;
plot(timeUs, imag(values), '--', 'Color', [0.85 0.25 0.18], ...
    'LineWidth', 0.40);
grid on;
xlim([timeUs(1), timeUs(end)]);
ylim([-1.05, 1.05]);
xlabel('Time from dump-window start (us)');
ylabel('Amplitude / original peak');
title(plotTitle);
legend('I', 'Q', 'Location', 'northeast');
end

function plotMagnitudeOverlay(timeUs, estimated, singleUserState, ...
        estimatedName, stateName, plotTitle)
plot(timeUs, abs(estimated), 'Color', [0.10 0.42 0.82], ...
    'LineWidth', 0.55);
hold on;
plot(timeUs, abs(singleUserState), '--', 'Color', [0.88 0.28 0.12], ...
    'LineWidth', 0.55);
grid on;
xlim([timeUs(1), timeUs(end)]);
ylim([0, 1.05]);
xlabel('Time from dump-window start (us)');
ylabel('|IQ| / original peak');
title(plotTitle);
legend(estimatedName, stateName, 'Location', 'northeast');
end

function stats = plotPhaseComparison(timeUs, generated, singleUserState, ...
        minAmplitudeRatio, signalName)
generated = generated(:);
singleUserState = singleUserState(:);
valid = isfinite(generated) & isfinite(singleUserState) & ...
    abs(generated) >= minAmplitudeRatio & ...
    abs(singleUserState) >= minAmplitudeRatio;
phaseError = angle(singleUserState(valid) .* conj(generated(valid)));
validTime = timeUs(valid);

stats = struct('active_samples', nnz(valid), ...
    'circular_mean_deg', NaN, 'circular_rms_deg', NaN);
if isempty(phaseError)
    text(0.5, 0.5, 'No samples passed the phase-amplitude gate', ...
        'Units', 'normalized', 'HorizontalAlignment', 'center');
else
    weights = abs(generated(valid)) .* abs(singleUserState(valid));
    weightSum = sum(weights) + eps;
    meanPhase = angle(sum(weights .* exp(1j * phaseError)));
    centeredError = angle(exp(1j * (phaseError - meanPhase)));
    rmsPhase = sqrt(sum(weights .* centeredError.^2) / weightSum);
    stats.circular_mean_deg = rad2deg(meanPhase);
    stats.circular_rms_deg = rad2deg(rmsPhase);
    plot(validTime, rad2deg(phaseError), '.', ...
        'Color', [0.36 0.20 0.72], 'MarkerSize', 2.5);
end
hold on;
yline(0, 'k:', 'Zero phase error');
grid on;
xlim([timeUs(1), timeUs(end)]);
ylim([-180, 180]);
yticks(-180:60:180);
xlabel('Time from dump-window start (us)');
ylabel('State phase - generated phase (deg)');
title(sprintf(['%s phase comparison | circular mean %.1f deg | ', ...
    'RMS %.1f deg'], signalName, stats.circular_mean_deg, ...
    stats.circular_rms_deg));
end

function plotCirBeforeAfter(beforePack, afterPack)
[beforeCir, delay] = coherentCir(beforePack);
[afterCir, afterDelay] = coherentCir(afterPack);
afterCir = interp1(afterDelay, afterCir, delay, 'linear', 0);
referencePower = max(abs(beforeCir).^2) + eps;
beforeDb = 10 * log10(max(abs(beforeCir).^2, eps) / referencePower);
afterDb = 10 * log10(max(abs(afterCir).^2, eps) / referencePower);
plot(delay, beforeDb, 'Color', [0.15 0.45 0.85], 'LineWidth', 1.3);
hold on;
plot(delay, afterDb, '--', 'Color', [0.85 0.30 0.12], 'LineWidth', 1.3);
if isfinite(beforePack.first_path_delay_ns)
    xline(beforePack.first_path_delay_ns, ':', 'Before first path', ...
        'Color', [0.15 0.45 0.85]);
end
if isfinite(afterPack.first_path_delay_ns)
    xline(afterPack.first_path_delay_ns, ':', 'After first path', ...
        'Color', [0.85 0.30 0.12]);
end
grid on;
ylim([-50, 25]);
xlabel('CIR delay (ns)');
ylabel('Power / before-SIC peak (dB)');
legend('Before DW1000 SIC', 'After DW1000 SIC', 'Location', 'best');
end

function [values, delay] = coherentCir(pack)
if isfield(pack, 'interference') && ...
        isfield(pack.interference, 'coherent_cir') && ...
        ~isempty(pack.interference.coherent_cir)
    values = pack.interference.coherent_cir(:);
    delay = pack.interference.delay_ns(:);
elseif isfield(pack, 'cir') && isfield(pack.cir, 'values') && ...
        ~isempty(pack.cir.values)
    values = pack.cir.values(:);
    delay = pack.cir.delay_ns(:);
else
    error('QM35 result has no CIR estimate.');
end
end

function stage = reconstructSicStages(record, cfg)
[xScaled, meta] = read_uwb_packet(cfg.iq_file, cfg.jsonl_file, record.packet_id);
iqScale = double(fieldOr(meta, 'iq_scale', 1));
x737 = single(xScaled * iqScale);
taps = loadResamplerTaps(cfg.taps_file);
interp = 65;
decim = 48;
filterDelay = (numel(taps) - 1) / 2;
xOriginal = upfirdn(x737, taps, interp, decim);
seededStart = seededQm35Start(record.packet_id, meta, cfg, ...
    numel(xOriginal), interp, decim, filterDelay);

refs = buildSicReferences(record.dw_profile);
qmDecoded = decode_uwb(refs.qm.params, xOriginal, [], ...
    refs.qm.reference, refs.qm.sfd, 'single', seededStart, true);
assert(qmDecoded.payload.fcs_pass, ...
    'QM35 reconstruction decode did not pass FCS for packet %d.', ...
    record.packet_id);
[xAfterQm35, qmCancel] = cancel_uwb_packet_in_iq( ...
    xOriginal, qmDecoded, refs.qm.tx, refs.qm.cancel);

cancelOptions = refs.dw.cancel;
cancelOptions.min_alignment_correlation = fieldOr( ...
    cfg, 'min_alignment_correlation', 0.60);
switch string(record.dw_cancel_mode)
    case "full"
        dwDecoded = decode_uwb(refs.dw.params, xAfterQm35, [], ...
            refs.dw.reference, refs.dw.sfd, 'single', ...
            record.dw_overlap_start, true);
        [xAfterDw1000, dwCancel] = cancel_uwb_packet_in_iq( ...
            xOriginal, dwDecoded, refs.dw.tx, cancelOptions);
    case "preamble"
        [preamble, cirEstimate] = estimate_uwb_preamble_cir( ...
            xAfterQm35, refs.dw.reference, refs.dw.params, ...
            record.dw_overlap_start);
        txOptions = struct('code_index', refs.dw.params.code_index, ...
            'visible_reps', record.dw_visible_reps, ...
            'fs_tx', 998.4e6, 'phy_mode', '802.15.4a', ...
            'peak_amplitude', 1, 'guard_samples', 0);
        cancelOptions.cfo_fit_last_sync = record.dw_visible_reps;
        cancelOptions.gain_fit_last_sync = record.dw_visible_reps;
        [xAfterDw1000, dwCancel] = cancel_uwb_preamble_in_iq( ...
            xOriginal, preamble, cirEstimate, txOptions, cancelOptions);
    otherwise
        error('Unsupported SIC mode: %s', record.dw_cancel_mode);
end

stage = struct();
stage.packet_id = record.packet_id;
stage.fs = 998.4e6;
stage.original = xOriginal(:);
stage.after_qm35 = xAfterQm35(:);
stage.after_dw1000 = xAfterDw1000(:);
stage.estimated_qm35 = stage.original - stage.after_qm35;
stage.estimated_dw1000 = stage.original - stage.after_dw1000;
stage.qm35_cancel_report = qmCancel;
stage.dw1000_cancel_report = dwCancel;
stage.qm35_before = record.qm35_before;
stage.qm35_after = record.qm35_after;
end

function seededStart = seededQm35Start(packetId, meta, cfg, signalLength, ...
        interp, decim, filterDelay)
windowStart = double(fieldOr(meta, 'window_start_sample', ...
    fieldOr(meta, 'start_sample', 0)));
windowStartOut = round((windowStart * interp + filterDelay) / decim);
seededStart = NaN;
if isfile(cfg.cpp_truth_csv)
    truth = readtable(cfg.cpp_truth_csv, 'VariableNamingRule', 'preserve');
    row = find(double(truth.packet_id) == double(packetId), 1);
    if ~isempty(row) && ismember('qm35_detected_start', ...
            truth.Properties.VariableNames)
        seededStart = round(double(truth.qm35_detected_start(row)) - ...
            windowStartOut + 1);
    end
end
if ~(isfinite(seededStart) && seededStart >= 1 && seededStart <= signalLength)
    pre = double(fieldOr(meta, 'pre_guard_samples', ...
        fieldOr(meta, 'pre_trigger_samples', 0)));
    seededStart = round(pre * interp / decim) + 1;
end
end

function refs = buildSicReferences(dwProfileName)
projectDir = fileparts(mfilename('fullpath'));
pllRoot = fullfile(projectDir, 'decoded_results', 'pll_phase_drift_analysis');
qmOpt = struct('fs_rx', 998.4e6, 'data_rate', 6.81, ...
    'preamble_repetitions', 64, 'code_index', 9, 'sfd_mode', '4z2', ...
    'cir_skip_initial_repetitions', 10, 'cir_repetitions', 54, ...
    'cir_store_individual_values', true, 'cir_diag_pre_samples', 64, ...
    'cir_diag_post_samples', 64, 'max_psdu_bytes', 127, ...
    'enable_frame_crop', true, 'show_plots', false);
qmParams = uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), qmOpt);
refs.qm = struct('params', qmParams, ...
    'reference', uwbdecoder.buildUwbReference(qmParams), ...
    'sfd', sfdTemplates(qmParams), ...
    'tx', struct('fs_tx', 998.4e6, 'phy_mode', 'BPRF', ...
        'ranging', false, 'preamble_repetitions', 64, 'code_index', 9, ...
        'sfd_number', 2, 'sfd_sequence', [], 'peak_amplitude', 1, ...
        'guard_samples', 0, 'require_fcs_pass', true), ...
    'cancel', struct('fs_rx', 998.4e6, ...
        'cancellation_mode', 'optimal_complex', 'cfo_fit_last_sync', 64, ...
        'gain_fit_last_sync', 64, 'pll_phase_compensation', ...
        load_uwb_pll_phase_compensation(true, fullfile(pllRoot, ...
        'qm35_new_3', 'subsync_phase_template.csv'), 10, 64)));

switch string(dwProfileName)
    case "dw1000_code10_n256"
        codeIndex = 10; repetitions = 256; cirRepetitions = 64;
    case "dw1000_code11_n128"
        codeIndex = 11; repetitions = 128; cirRepetitions = 118;
    otherwise
        error('Unknown DW1000 profile: %s', string(dwProfileName));
end
dwOpt = struct('fs_rx', 998.4e6, 'data_rate', 6.81, ...
    'preamble_repetitions', repetitions, 'code_index', codeIndex, ...
    'sfd_mode', 'decawave', 'cir_skip_initial_repetitions', 10, ...
    'cir_repetitions', cirRepetitions, 'cir_store_individual_values', true, ...
    'max_psdu_bytes', 127, 'enable_frame_crop', true, 'show_plots', false);
dwParams = uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), dwOpt);
refs.dw = struct('params', dwParams, ...
    'reference', uwbdecoder.buildUwbReference(dwParams), ...
    'sfd', sfdTemplates(dwParams), ...
    'tx', struct('fs_tx', 998.4e6, 'phy_mode', '802.15.4a', ...
        'ranging', true, 'preamble_repetitions', repetitions, ...
        'code_index', codeIndex, 'sfd_number', 0, ...
        'sfd_sequence', [-1; -1; -1; -1; 1; -1; 0; 0], ...
        'peak_amplitude', 1, 'guard_samples', 0, ...
        'require_fcs_pass', true), ...
    'cancel', struct('fs_rx', 998.4e6, ...
        'cancellation_mode', 'optimal_complex', ...
        'cfo_fit_last_sync', repetitions, 'gain_fit_last_sync', repetitions, ...
        'pll_phase_compensation', load_uwb_pll_phase_compensation(true, ...
        fullfile(pllRoot, 'dw1000_new_3', 'subsync_phase_template.csv'), ...
        10, repetitions)));
end

function templates = sfdTemplates(params)
templates = struct('decawave', params.decawave_sfd(:), ...
    'ieee', params.ieee_sfd(:), 'sfd4z_1', params.sfd4z_1(:), ...
    'sfd4z_2', params.sfd4z_2(:), 'sfd4z_3', params.sfd4z_3(:), ...
    'sfd4z_4', params.sfd4z_4(:));
end

function taps = loadResamplerTaps(tapsFile)
fid = fopen(tapsFile, 'rb');
assert(fid >= 0, 'Cannot open resampler taps: %s', tapsFile);
taps = fread(fid, Inf, 'single=>single');
fclose(fid);
assert(~isempty(taps), 'Empty resampler taps: %s', tapsFile);
end

function value = fieldOr(s, name, fallback)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    value = s.(name);
else
    value = fallback;
end
end
