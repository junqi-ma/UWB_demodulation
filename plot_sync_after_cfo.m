%% Plot the SYNC-field waveform of one dump frame after CFO compensation,
% i.e. exactly the signal state that estimateCir receives as input.
clear;
close all;
clc;

this_dir = fileparts(mfilename('fullpath'));
if isempty(this_dir)
    this_dir = pwd;
end
addpath(this_dir);

%% -------------------- User parameters --------------------
dump_dir = 'F:\UWB基带数据\8月20日数据\qm35_sensing_1';
packet_id = 5;
save_figure = true;
figure_resolution_dpi = 160;
zoom_reps = 6;
outlier_threshold_sigma = 3.5;
outlier_color = [0.90 0.08 0.05];

iq_file = fullfile(dump_dir, 'capture.iq');
jsonl_file = fullfile(dump_dir, 'capture.jsonl');
[~, dump_name] = fileparts(dump_dir);
taps_file = fullfile(this_dir, 'testdata', 'resampler_65_48', ...
    'taps_quality_minorder.txt');
cpp_truth_csv = fullfile(this_dir, 'decoded_results', dump_name, ...
    'scheduled_dump_cpp.csv');
if ~isfile(cpp_truth_csv)
    cpp_truth_csv = fullfile(dump_dir, 'scheduled_dump_cpp.csv');
end

%% -------------------- Load and resample --------------------
[xScaled, meta] = read_uwb_packet(iq_file, jsonl_file, packet_id);
iqScale = double(fieldOr(meta, 'iq_scale', 1));
xInput = single(xScaled * iqScale);
inputFs = double(fieldOr(meta, 'sample_rate', 737.28e6));
targetFs = 998.4e6;
if abs(inputFs - targetFs) <= targetFs * 1e-9
    x998 = xInput;
elseif abs(inputFs - 737.28e6) <= 737.28e6 * 1e-9
    fid = fopen(taps_file, 'rb');
    assert(fid >= 0, 'Cannot open resampler taps: %s', taps_file);
    taps = fread(fid, Inf, 'single=>single');
    fclose(fid);
    x998 = upfirdn(xInput, taps, 65, 48);
else
    error('Unsupported dump sample rate %.6f MHz.', inputFs / 1e6);
end

%% -------------------- Reference and seeded start --------------------
params = uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), struct( ...
    'fs_rx', 998.4e6, 'data_rate', 6.81, ...
    'preamble_repetitions', 64, 'code_index', 9, 'sfd_mode', '4z2', ...
    'cir_skip_initial_repetitions', 10, 'cir_repetitions', 54, ...
    'cir_store_individual_values', true, 'max_psdu_bytes', 127, ...
    'enable_frame_crop', true, 'show_plots', false));
reference = uwbdecoder.buildUwbReference(params);

windowStart = double(fieldOr(meta, 'window_start_sample', ...
    fieldOr(meta, 'start_sample', 0)));
seededStart = NaN;
if isfile(cpp_truth_csv)
    truth = readtable(cpp_truth_csv, 'VariableNamingRule', 'preserve');
    row = find(double(truth.packet_id) == double(packet_id), 1);
    if ~isempty(row) && ismember('qm35_detected_start', ...
            truth.Properties.VariableNames)
        seededStart = round(double(truth.qm35_detected_start(row)) - ...
            windowStart + 1);
    end
end
if ~(isfinite(seededStart) && seededStart >= 1 && ...
        seededStart <= numel(x998)) && ...
        isfield(meta, 'detected_start_sample') && ...
        ~isempty(meta.detected_start_sample)
    seededStart = round(double(meta.detected_start_sample) - ...
        windowStart) + 1;
end
if ~(isfinite(seededStart) && seededStart >= 1 && ...
        seededStart <= numel(x998))
    pre = double(fieldOr(meta, 'pre_guard_samples', 0));
    seededStart = pre + 1;
end
assert(isfinite(seededStart) && seededStart >= 1 && ...
    seededStart <= numel(x998), ...
    'Seeded start %g outside window 1:%d.', seededStart, numel(x998));

%% -------------------- Preamble detection + CFO compensation --------------------
preamble = uwbdecoder.detectRepeatedPreamble(x998, reference, params, ...
    seededStart);
rxComp = x998;
try
    [rxComp, preamble] = uwbdecoder.compensateCarrierOffset( ...
        x998(:), preamble, reference, params);
catch err
    fprintf('CFO compensation failed (%s); plotting uncompensated rx.\n', ...
        err.message);
end

nReps = min(double(params.preamble_repetitions), ...
    double(preamble.detected_repetitions));
period = double(preamble.measured_period);
syncFirst = double(preamble.start_sample);
syncLast = syncFirst + nReps * period;
spanFirst = max(1, floor(syncFirst));
spanLast = min(numel(rxComp), ceil(syncLast) - 1);
span = (spanFirst:spanLast).';

fprintf('packet %d | fs=%.1f MHz\n', packet_id, targetFs / 1e6);
fprintf('seeded start=%d, preamble.start_sample=%d, detected_reps=%d\n', ...
    seededStart, preamble.start_sample, preamble.detected_repetitions);
fprintf('measured period=%.3f samples (%.1f ns), plotted reps=%d\n', ...
    period, period / targetFs * 1e9, nReps);
fprintf('CFO=%+.3f kHz, skipped transient reps=%d\n', ...
    fieldOr(preamble, 'frequency_offset_hz', NaN) / 1e3, ...
    fieldOr(preamble, 'frequency_offset_skipped_repetitions', NaN));

%% -------------------- Per-SYNC phasor after compensation --------------------
waveLen = numel(reference.preamble_waveform);
wave = reference.preamble_waveform(:);
repStarts = round(syncFirst + (0:nReps - 1)' * period);
okRep = repStarts >= 1 & repStarts + waveLen - 1 <= numel(rxComp);
phasor = nan(nReps, 1);
for k = find(okRep)'
    idx = repStarts(k):(repStarts(k) + waveLen - 1);
    phasor(k) = sum(rxComp(idx) .* conj(wave));
end
phaseDeg = unwrap(angle(phasor)) * 180 / pi;
phaseDeg(~okRep) = NaN;

peakIdx = double(preamble.peaks);
peakIdx = peakIdx(peakIdx >= spanFirst & peakIdx <= spanLast);

%% -------------------- Per-repetition CIR (what estimateCir averages) --------------------
cir = uwbdecoder.estimateCir(rxComp, preamble, reference, params);
allCirParams = params;
allCirParams.cir_skip_initial_repetitions = [];
allCirParams.cir_repetitions = nReps;
allCir = uwbdecoder.estimateCir(rxComp, preamble, reference, allCirParams);
globalCirPeak = max(abs(allCir.individual_values(:))) + eps;
individualDb = 20 * log10(abs(allCir.individual_values) / globalCirPeak + eps);
meanCirDb = 20 * log10(abs(cir.values_raw) / globalCirPeak + eps);
individualCir = allCir.individual_values;
medianCir = median(real(individualCir), 2) + ...
    1j * median(imag(individualCir), 2);
medianNorm = sqrt(sum(abs(medianCir).^2)) + eps;
individualNorm = sqrt(sum(abs(individualCir).^2, 1)) + eps;
residualRatio = sqrt(sum(abs(individualCir - medianCir).^2, 1)) ./ ...
    medianNorm;
energyDb = 10 * log10(mean(abs(individualCir).^2, 1) + eps);
residualZ = robustAbsZ(residualRatio);
energyZ = robustAbsZ(energyDb);
outlierScore = max(residualZ, energyZ);
isOutlier = outlierScore >= outlier_threshold_sigma;
outlierIndices = find(isOutlier);
fprintf(['CIR: production=%d repetitions, all-SYNC plot=%d repetitions, ', ...
    '%d taps (%.1f..%.1f ns)\n'], cir.repetition_count, ...
    allCir.repetition_count, numel(allCir.delay_ns), min(allCir.delay_ns), ...
    max(allCir.delay_ns));
if isempty(outlierIndices)
    fprintf('CIR outliers: none (threshold %.2f robust sigma)\n', ...
        outlier_threshold_sigma);
else
    fprintf('CIR outliers: SYNC ');
    fprintf('%d ', outlierIndices);
    fprintf('(threshold %.2f robust sigma)\n', outlier_threshold_sigma);
    for k = outlierIndices
        fprintf('  SYNC %d: score=%.2f residualZ=%.2f energyZ=%.2f\n', ...
            k, outlierScore(k), residualZ(k), energyZ(k));
    end
end

%% -------------------- Plots --------------------
timeUs = (span - 1) / targetFs * 1e6;
fig = figure('Name', sprintf('SYNC after CFO packet %d', packet_id), ...
    'Color', 'w', 'Position', [60 30 1500 1550]);
tiledlayout(fig, 4, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

nexttile;
plot(timeUs, real(rxComp(span)), 'Color', [0.15 0.45 0.85], ...
    'LineWidth', 0.4);
hold on;
plot(timeUs, imag(rxComp(span)), '--', 'Color', [0.85 0.25 0.18], ...
    'LineWidth', 0.4);
grid on;
xlim([timeUs(1) timeUs(end)]);
xlabel('Time from SYNC start (\mus)');
ylabel('Amplitude');
title(sprintf(['Full SYNC span after CFO compensation | ', ...
    '%d reps | CFO %+.2f kHz'], nReps, ...
    fieldOr(preamble, 'frequency_offset_hz', NaN) / 1e3));
legend('I', 'Q', 'Location', 'northeast');

nexttile;
plot(timeUs, abs(rxComp(span)), 'Color', [0.36 0.20 0.72], ...
    'LineWidth', 0.4);
hold on;
plot((peakIdx - 1) / targetFs * 1e6, ...
    abs(rxComp(round(peakIdx))), 'v', 'MarkerSize', 3, ...
    'Color', [0.13 0.55 0.13]);
grid on;
xlim([timeUs(1) timeUs(end)]);
xlabel('Time from SYNC start (\mus)');
ylabel('|IQ|');
title('Envelope with detected repetition peaks');

zoomSpanFirst = max(spanFirst, round(syncFirst));
zoomSpanLast = min(numel(rxComp), ...
    ceil(syncFirst + zoom_reps * period) - 1);
zSpan = (zoomSpanFirst:zoomSpanLast).';
nexttile;
plot((zSpan - 1) / targetFs * 1e6, real(rxComp(zSpan)), ...
    'Color', [0.15 0.45 0.85], 'LineWidth', 0.6);
hold on;
plot((zSpan - 1) / targetFs * 1e6, imag(rxComp(zSpan)), '--', ...
    'Color', [0.85 0.25 0.18], 'LineWidth', 0.6);
grid on;
xlim([(zSpan(1) - 1) / targetFs * 1e6, (zSpan(end) - 1) / targetFs * 1e6]);
xlabel('Time from SYNC start (\mus)');
ylabel('Amplitude');
title(sprintf('Zoom: first %d repetitions', zoom_reps));
legend('I', 'Q', 'Location', 'northeast');

nexttile;
plot(1:nReps, phaseDeg, '.', Color=[0.36 0.20 0.72], MarkerSize=6);
hold on;
yline(0, 'k:');
grid on;
xlabel('SYNC repetition index');
ylabel('Residual phasor phase (deg)');
title(sprintf('Per-repetition phase after CFO fit (%d anchors used)', ...
    fieldOr(preamble, 'frequency_offset_anchor_count', NaN)));
ylim padded;

nexttile([1 2]);
cmap = turbo(max(allCir.repetition_count, 2));
normalIndices = find(~isOutlier);
for k = normalIndices
    plot(allCir.delay_ns, individualDb(:, k), 'LineWidth', 0.3, ...
        'Color', cmap(k, :));
    hold on;
end
for k = outlierIndices
    plot(allCir.delay_ns, individualDb(:, k), 'LineWidth', 1.8, ...
        'Color', outlier_color);
    hold on;
end
plot(allCir.delay_ns, meanCirDb, 'k-', 'LineWidth', 1.8);
xline(0, ':', 'Expected first path', Color=[0.5 0.5 0.5]);
grid on;
xlim([-60, 200]);
ylim([-45, 3]);
xlabel('Delay relative to expected first path (ns)');
ylabel('Power (dB, global max)');
title(sprintf(['Per-repetition local CIR overlay | %d traces ', ...
    '(%d outliers highlighted) + production average of %d (black)'], ...
    allCir.repetition_count, numel(outlierIndices), cir.repetition_count));
colormap(gca, cmap);

nexttile([1 2]);
complexScale = max(abs(allCir.individual_values(:))) + eps;
complexValues = allCir.individual_values / complexScale;
productionComplex = cir.values_raw / complexScale;
for k = normalIndices
    plot(real(complexValues(:, k)), imag(complexValues(:, k)), ...
        'LineWidth', 0.3, 'Color', cmap(k, :));
    hold on;
end
for k = outlierIndices
    plot(real(complexValues(:, k)), imag(complexValues(:, k)), ...
        'LineWidth', 1.8, 'Color', outlier_color);
    hold on;
end
plot(real(productionComplex), imag(productionComplex), 'k-', ...
    'LineWidth', 1.8);
xline(0, 'k:');
yline(0, 'k:');
grid on;
axis equal;
complexLimit = 1.05 * max(abs(complexValues(:)));
xlim([-complexLimit, complexLimit]);
ylim([-complexLimit, complexLimit]);
xlabel('Real(CIR) / all-SYNC peak');
ylabel('Imag(CIR) / all-SYNC peak');
title(sprintf(['Complex-plane trajectories | %d SYNC traces ', ...
    '(%d outliers highlighted) + production average of %d (black)'], ...
    allCir.repetition_count, numel(outlierIndices), cir.repetition_count));
colormap(gca, cmap);
clim([1, max(allCir.repetition_count, 2)]);
cb = colorbar;
cb.Label.String = 'SYNC repetition index';

sgtitle(sprintf('packet %d | QM35 SYNC field entering CIR estimation', ...
    packet_id));

%% -------------------- Save --------------------
if save_figure
    outDir = fullfile(this_dir, 'decoded_results', dump_name, ...
        'validation');
    if ~isfolder(outDir)
        mkdir(outDir);
    end
    outFile = fullfile(outDir, ...
        sprintf('cfo_compensated_sync_packet_%03d.png', packet_id));
    exportgraphics(fig, outFile, 'Resolution', figure_resolution_dpi);
    fprintf('Figure saved: %s\n', outFile);
end

assignin('base', 'cfo_compensated_sync_view', struct( ...
    'packet_id', packet_id, 'rx_compensated', rxComp, ...
    'preamble', preamble, 'reference', reference, 'params', params, ...
    'span', span, 'per_rep_phase_deg', phaseDeg, 'cir', cir, ...
    'all_cir', allCir, 'outlier_indices', outlierIndices, ...
    'outlier_score', outlierScore, 'outlier_residual_z', residualZ, ...
    'outlier_energy_z', energyZ));

function value = fieldOr(s, name, fallback)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    value = s.(name);
else
    value = fallback;
end
end

function z = robustAbsZ(values)
center = median(values, 'omitnan');
scale = median(abs(values - center), 'omitnan');
scale = max(scale, 1e-6 * max(1, abs(center)));
z = 0.6745 * abs(values - center) / scale;
z(~isfinite(z)) = Inf;
end
