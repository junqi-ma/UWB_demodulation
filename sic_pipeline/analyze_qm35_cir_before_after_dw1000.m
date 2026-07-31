%% Compare QM35 CIR before and after DW1000 cancellation.
% The SIC pipeline preserves QM35 in its final output:
%   original mixed capture -> QM35 removed -> DW1000 removed, QM35 preserved.
% This script decodes QM35 again from that final output, matches packets on
% the unchanged absolute capture timeline, then measures and plots CIR change.

% uwbSicPipeline injects sic_manifest_file when this analysis is launched
% as its visualization stage. Standalone execution keeps the default below.
sic_managed_analysis = ...
    exist('sic_pipeline_managed_visualization', 'var') == 1 && ...
    logical(sic_pipeline_managed_visualization) && ...
    exist('sic_manifest_file', 'var') == 1;
if ~sic_managed_analysis
    clear;
    sic_managed_analysis = false;
end
close all;
clc;

pipeline_dir = fileparts(mfilename('fullpath'));
project_dir = fileparts(pipeline_dir);
addpath(project_dir);
addpath(pipeline_dir);

%% User configuration
if sic_managed_analysis
    manifest_file = sic_manifest_file;
else
    manifest_file = fullfile(project_dir, 'decoded_results', ...
        'qm35_dw1000_new_1', 'sic_dw1000_removed_qm35_preserved', ...
        'pipeline_manifest.mat');
end

% Reuse a matching post-DW1000 QM35 decode unless explicitly rebuilt.
overwrite_after_decode = false;
save_figures = true;
figure_resolution_dpi = 140;

% Match starts after DW1000 cancellation to raw-capture starts. SIC never
% shifts samples; this only tolerates independent decoder alignment jitter.
match_tolerance_samples = 1024;

% Empty selects a representative matched FCS-pass packet automatically.
% Set to a 1-based packet-list index from the original QM35 decode to
% inspect a specific packet.
selected_before_packet = [];

%% Load the completed SIC pipeline
if ~isfile(manifest_file)
    error('analyze_qm35_cir_before_after_dw1000:ManifestNotFound', ...
        'Pipeline manifest not found: %s', manifest_file);
end
saved = load(manifest_file, 'pipeline');
pipeline = saved.pipeline;
requirePipelineFields(pipeline);

before_scan_file = pipeline.stages.qm35_decode.scan_file;
after_input_file = pipeline.stages.dw1000_cancel.output_file;
validation_dir = pipeline.paths.validation_dir;
after_decode_dir = fullfile(validation_dir, 'qm35_decode_after_dw1000');
after_scan_file = fullfile(after_decode_dir, 'all_frames_cir.mat');

if ~isfile(before_scan_file)
    error('analyze_qm35_cir_before_after_dw1000:BeforeMissing', ...
        'Original QM35 decode is missing: %s', before_scan_file);
end
if ~isfile(after_input_file)
    error('analyze_qm35_cir_before_after_dw1000:AfterInputMissing', ...
        'QM35-preserved SIC output is missing: %s', after_input_file);
end
if ~isfolder(validation_dir)
    mkdir(validation_dir);
end

%% Decode QM35 after DW1000 cancellation with the shared current decoder
if overwrite_after_decode || ~isfile(after_scan_file) || ...
        ~isReusableAfterDecode(after_scan_file, after_input_file)
    if ~isfolder(after_decode_dir)
        mkdir(after_decode_dir);
    end
    sic_stage_config = struct( ...
        'input_file', after_input_file, ...
        'phy_profile', 'QM35', ...
        'result_directory', after_decode_dir, ...
        'pll_phase_compensation_repetitions', 10); %#ok<NASGU>
    run(fullfile(project_dir, 'run_decode_uwb_all.m'));
end

before_saved = load(before_scan_file, 'results');
after_saved = load(after_scan_file, 'results');
before = before_saved.results;
after = after_saved.results;
validateQm35Results(before, before_scan_file);
validateQm35Results(after, after_scan_file);

%% Match packets by their immutable absolute start sample
[match_table, matched_before, matched_after] = matchPackets( ...
    before.frames, after.frames, match_tolerance_samples);

metrics = measureMatchedCir(before.frames, after.frames, ...
    matched_before, matched_after, match_table);
metrics_file = fullfile(validation_dir, ...
    'qm35_cir_before_after_dw1000_metrics.csv');
writetable(metrics, metrics_file);
save(fullfile(validation_dir, ...
    'qm35_cir_before_after_dw1000_metrics.mat'), ...
    'metrics', 'match_table', 'before_scan_file', 'after_scan_file', ...
    'after_input_file');

fprintf('\n=== QM35 CIR before/after DW1000 cancellation ===\n');
fprintf('Before QM35 decode : %s\n', before_scan_file);
fprintf('After QM35 decode  : %s\n', after_scan_file);
fprintf('Before packets/FCS : %d / %d\n', ...
    before.packet_count, before.fcs_pass_count);
fprintf('After packets/FCS  : %d / %d\n', ...
    after.packet_count, after.fcs_pass_count);
fprintf('Matched packets    : %d (tolerance %d samples)\n', ...
    height(metrics), match_tolerance_samples);
fprintf('After-only packets : %d\n', ...
    numel(after.frames) - numel(unique(matched_after)));
fprintf('Metrics CSV        : %s\n', metrics_file);

if isempty(metrics)
    warning('analyze_qm35_cir_before_after_dw1000:NoMatches', ...
        'No QM35 packets matched between before and after decodes.');
    return;
end

fprintf('Median CIR coherence: %.4f\n', ...
    median(metrics.cir_coherence, 'omitnan'));
fprintf('Median normalized residual: %.4f\n', ...
    median(metrics.cir_normalized_residual, 'omitnan'));
fprintf('Median repetition coherence: %.4f\n', ...
    median(metrics.repetition_coherence_median, 'omitnan'));

%% Plot one representative matched packet plus all-packet distributions
selected_row = selectPacketRow(metrics, selected_before_packet);
plotSelectedCir(before.frames(matched_before(selected_row)), ...
    after.frames(matched_after(selected_row)), metrics(selected_row, :), ...
    validation_dir, save_figures, figure_resolution_dpi);
plotMetricDistributions(metrics, validation_dir, save_figures, ...
    figure_resolution_dpi);
plotAllPacketCirHeatmaps(before.frames, after.frames, matched_before, ...
    matched_after, validation_dir, save_figures, figure_resolution_dpi);
plotAllPacketCirOverlays(before.frames, after.frames, validation_dir, ...
    save_figures, figure_resolution_dpi);

%% Local functions
function requirePipelineFields(pipeline)
required = {'paths', 'stages'};
if ~all(isfield(pipeline, required)) || ...
        ~isfield(pipeline.stages, 'qm35_decode') || ...
        ~isfield(pipeline.stages, 'dw1000_cancel') || ...
        ~isfield(pipeline.paths, 'validation_dir')
    error('analyze_qm35_cir_before_after_dw1000:IncompletePipeline', ...
        'Manifest does not contain the required QM35 decode and DW1000 cancellation stages.');
end
end

function reusable = isReusableAfterDecode(scanFile, expectedInput)
reusable = false;
try
    saved = load(scanFile, 'results');
    results = saved.results;
    reusable = isfield(results, 'file_name') && ...
        strcmpi(char(string(results.file_name)), char(string(expectedInput))) && ...
        isfield(results, 'params') && results.params.code_index == 9 && ...
        isfield(results, 'detection_algorithm_version') && ...
        results.detection_algorithm_version == 3;
catch
    reusable = false;
end
end

function validateQm35Results(results, scanFile)
if ~isfield(results, 'params') || results.params.code_index ~= 9 || ...
        ~isfield(results, 'frames')
    error('analyze_qm35_cir_before_after_dw1000:InvalidQm35Decode', ...
        'Expected a QM35 all_frames_cir result: %s', scanFile);
end
end

function [tableOut, beforeIndex, afterIndex] = matchPackets( ...
        beforeFrames, afterFrames, tolerance)
beforeStarts = double([beforeFrames.abs_start_sample]).';
afterStarts = double([afterFrames.abs_start_sample]).';
beforeIndex = zeros(0, 1);
afterIndex = zeros(0, 1);
delta = zeros(0, 1);
usedAfter = false(numel(afterFrames), 1);
for k = 1:numel(beforeFrames)
    [distance, candidate] = min(abs(afterStarts - beforeStarts(k)));
    if ~isempty(candidate) && distance <= tolerance && ~usedAfter(candidate)
        beforeIndex(end + 1, 1) = k; %#ok<AGROW>
        afterIndex(end + 1, 1) = candidate; %#ok<AGROW>
        delta(end + 1, 1) = afterStarts(candidate) - beforeStarts(k); %#ok<AGROW>
        usedAfter(candidate) = true;
    end
end
tableOut = table(beforeIndex, afterIndex, delta, ...
    'VariableNames', {'before_packet_index', 'after_packet_index', ...
    'start_delta_samples'});
end

function metrics = measureMatchedCir(beforeFrames, afterFrames, ...
        beforeIndex, afterIndex, matchTable)
n = numel(beforeIndex);
beforeFcs = false(n, 1);
afterFcs = false(n, 1);
coherence = nan(n, 1);
normalizedResidual = nan(n, 1);
beforeEnergyDb = nan(n, 1);
afterEnergyDb = nan(n, 1);
beforePeakNs = nan(n, 1);
afterPeakNs = nan(n, 1);
repetitionCoherence = nan(n, 1);
for k = 1:n
    beforeFrame = beforeFrames(beforeIndex(k));
    afterFrame = afterFrames(afterIndex(k));
    beforeFcs(k) = beforeFrame.fcs_pass;
    afterFcs(k) = afterFrame.fcs_pass;
    [b, a, delay] = alignedAverageCir(beforeFrame.cir, afterFrame.cir);
    if isempty(b)
        continue;
    end
    alpha = (a' * b) / (a' * a + eps);
    aAligned = alpha * a;
    coherence(k) = abs(b' * a) / (norm(b) * norm(a) + eps);
    normalizedResidual(k) = norm(b - aAligned) / (norm(b) + eps);
    beforeEnergyDb(k) = 10 * log10(mean(abs(b).^2) + eps);
    afterEnergyDb(k) = 10 * log10(mean(abs(a).^2) + eps);
    [~, beforePeak] = max(abs(b));
    [~, afterPeak] = max(abs(a));
    beforePeakNs(k) = delay(beforePeak);
    afterPeakNs(k) = delay(afterPeak);
    repetitionCoherence(k) = individualCirCoherence( ...
        beforeFrame.cir, afterFrame.cir);
end
metrics = [matchTable, table(beforeFcs, afterFcs, coherence, ...
    normalizedResidual, beforeEnergyDb, afterEnergyDb, beforePeakNs, ...
    afterPeakNs, repetitionCoherence, ...
    'VariableNames', {'before_fcs_pass', 'after_fcs_pass', ...
    'cir_coherence', 'cir_normalized_residual', 'before_cir_energy_db', ...
    'after_cir_energy_db', 'before_peak_delay_ns', ...
    'after_peak_delay_ns', 'repetition_coherence_median'})];
end

function [beforeValues, afterValues, delay] = alignedAverageCir(beforeCir, afterCir)
delay = beforeCir.delay_ns(:);
beforeValues = beforeCir.values(:);
if numel(afterCir.delay_ns) == numel(delay) && ...
        max(abs(afterCir.delay_ns(:) - delay)) < 1e-9
    afterValues = afterCir.values(:);
else
    afterValues = interp1(afterCir.delay_ns(:), afterCir.values(:), ...
        delay, 'linear', 0);
end
valid = isfinite(beforeValues) & isfinite(afterValues);
beforeValues = beforeValues(valid);
afterValues = afterValues(valid);
delay = delay(valid);
end

function value = individualCirCoherence(beforeCir, afterCir)
value = NaN;
beforeValues = beforeCir.individual_values;
afterValues = afterCir.individual_values;
if isempty(beforeValues) || isempty(afterValues)
    return;
end
if size(beforeValues, 1) ~= size(afterValues, 1) || ...
        size(beforeValues, 2) ~= size(afterValues, 2)
    return;
end
numerator = sum(conj(beforeValues) .* afterValues, 1);
denominator = sqrt(sum(abs(beforeValues).^2, 1) .* ...
    sum(abs(afterValues).^2, 1));
value = median(abs(numerator ./ (denominator + eps)), 'omitnan');
end

function row = selectPacketRow(metrics, requestedBeforePacket)
if ~isempty(requestedBeforePacket)
    row = find(metrics.before_packet_index == requestedBeforePacket, 1);
    if isempty(row)
        error('analyze_qm35_cir_before_after_dw1000:RequestedPacketUnmatched', ...
            'Requested original packet %d is not in the matched set.', ...
            requestedBeforePacket);
    end
    return;
end
valid = find(metrics.before_fcs_pass & metrics.after_fcs_pass & ...
    isfinite(metrics.cir_coherence));
if isempty(valid)
    valid = find(isfinite(metrics.cir_coherence));
end
[~, relative] = min(abs(metrics.cir_coherence(valid) - ...
    median(metrics.cir_coherence(valid), 'omitnan')));
row = valid(relative);
end

function plotSelectedCir(beforeFrame, afterFrame, metric, outputDir, ...
        saveFigures, dpi)
[b, a, delay] = alignedAverageCir(beforeFrame.cir, afterFrame.cir);
alpha = (a' * b) / (a' * a + eps);
aAligned = alpha * a;
fig = figure('Name', 'QM35 CIR before/after DW1000 cancellation', ...
    'Color', 'w', 'Position', [80 80 1250 780]);
subplot(2, 1, 1);
plot(delay, abs(b), 'LineWidth', 1.3, 'Color', [0.15 0.45 0.85]);
hold on;
plot(delay, abs(aAligned), '--', 'LineWidth', 1.3, ...
    'Color', [0.85 0.30 0.12]);
grid on;
xlabel('CIR delay (ns)');
ylabel('|CIR|');
legend('Before DW1000 cancellation', ...
    'After DW1000 cancellation, globally aligned', 'Location', 'best');
title(sprintf(['QM35 packet %d -> %d | coherence %.4f | ', ...
    'normalized residual %.4f'], metric.before_packet_index, ...
    metric.after_packet_index, metric.cir_coherence, ...
    metric.cir_normalized_residual));

subplot(2, 1, 2);
plot(delay, abs(b - aAligned), 'k', 'LineWidth', 1.2);
grid on;
xlabel('CIR delay (ns)');
ylabel('|Before - aligned after|');
title('CIR difference after removal of global complex gain');

if saveFigures
    file = fullfile(outputDir, sprintf( ...
        'qm35_cir_before_after_dw1000_packet_%d_to_%d.png', ...
        metric.before_packet_index, metric.after_packet_index));
    exportgraphics(fig, file, 'Resolution', dpi);
    fprintf('Representative CIR plot: %s\n', file);
end
end

function plotMetricDistributions(metrics, outputDir, saveFigures, dpi)
fig = figure('Name', 'QM35 CIR metrics before/after DW1000 cancellation', ...
    'Color', 'w', 'Position', [100 100 1180 500]);
subplot(1, 3, 1);
histogram(metrics.cir_coherence, 30);
xlabel('CIR coherence'); ylabel('Matched packets'); grid on;
subplot(1, 3, 2);
histogram(metrics.cir_normalized_residual, 30);
xlabel('Normalized CIR residual'); ylabel('Matched packets'); grid on;
subplot(1, 3, 3);
histogram(metrics.after_cir_energy_db - metrics.before_cir_energy_db, 30);
xlabel('After - before CIR energy (dB)'); ylabel('Matched packets'); grid on;
sgtitle('QM35 CIR change after DW1000 cancellation');
if saveFigures
    file = fullfile(outputDir, 'qm35_cir_before_after_dw1000_distributions.png');
    exportgraphics(fig, file, 'Resolution', dpi);
    fprintf('CIR metric distributions: %s\n', file);
end
end

function plotAllPacketCirHeatmaps(beforeFrames, afterFrames, ...
        matchedBefore, matchedAfter, outputDir, saveFigures, dpi)
% Plot each decoded packet's average CIR after normalizing its own peak.
% This exposes CIR shape and timing changes independently of packet power.
[beforeMap, beforeTimeMs, delay] = allPacketCirMap(beforeFrames, []);
[afterMap, afterTimeMs, ~] = allPacketCirMap(afterFrames, delay);

matchedDifference = nan(numel(matchedBefore), numel(delay));
for k = 1:numel(matchedBefore)
    [b, a, matchedDelay] = alignedAverageCir( ...
        beforeFrames(matchedBefore(k)).cir, afterFrames(matchedAfter(k)).cir);
    alpha = (a' * b) / (a' * a + eps);
    a = alpha * a;
    difference = 20 * log10((abs(a) + eps) ./ (abs(b) + eps));
    matchedDifference(k, :) = interp1(matchedDelay, difference, ...
        delay, 'linear', NaN);
end

fig = figure('Name', 'All-packet QM35 CIR heatmaps', ...
    'Color', 'w', 'Position', [60 80 1560 820]);
tiledlayout(1, 3, 'TileSpacing', 'compact', 'Padding', 'compact');

axBefore = nexttile;
imagesc(delay, beforeTimeMs, beforeMap);
axis xy;
clim([-40 0]);
colorbar;
xlabel('CIR delay (ns)');
ylabel('Capture time (ms)');
title(sprintf('Before DW1000 cancellation (%d QM35 packets)', ...
    numel(beforeFrames)));

axAfter = nexttile;
imagesc(delay, afterTimeMs, afterMap);
axis xy;
clim([-40 0]);
colorbar;
xlabel('CIR delay (ns)');
ylabel('Capture time (ms)');
title(sprintf('After DW1000 cancellation (%d QM35 packets)', ...
    numel(afterFrames)));

axDifference = nexttile;
matchedTimeMs = [beforeFrames(matchedBefore).time_start_s].' * 1e3;
imagesc(delay, matchedTimeMs, matchedDifference);
axis xy;
clim([-10 10]);
colorbar;
xlabel('CIR delay (ns)');
ylabel('Capture time (ms)');
title(sprintf('Matched after - before (%d packets, dB)', ...
    numel(matchedBefore)));

colormap(fig, turbo(256));
sgtitle(['All-packet QM35 CIR heatmaps | first two panels are ', ...
    'normalized independently per packet']);
linkaxes([axBefore axAfter axDifference], 'x');

if saveFigures
    file = fullfile(outputDir, 'qm35_cir_before_after_dw1000_heatmaps.png');
    exportgraphics(fig, file, 'Resolution', dpi);
    fprintf('All-packet CIR heatmaps: %s\n', file);
end
end

function [cirMapDb, timeMs, referenceDelay] = allPacketCirMap( ...
        frames, referenceDelay)
if isempty(frames)
    cirMapDb = zeros(0, 0);
    timeMs = zeros(0, 1);
    return;
end
if isempty(referenceDelay)
    referenceDelay = frames(1).cir.delay_ns(:).';
end
cirMapDb = nan(numel(frames), numel(referenceDelay));
timeMs = [frames.time_start_s].' * 1e3;
for k = 1:numel(frames)
    cir = frames(k).cir;
    values = interp1(cir.delay_ns(:), cir.values(:), ...
        referenceDelay(:), 'linear', 0);
    values = values(:).';
    peak = max(abs(values));
    cirMapDb(k, :) = 20 * log10((abs(values) + eps) / (peak + eps));
end
cirMapDb = max(cirMapDb, -40);
end

function plotAllPacketCirOverlays(beforeFrames, afterFrames, outputDir, ...
        saveFigures, dpi)
% Overlay every normalized average CIR. With only 38 delay taps per packet,
% plotting all packets preserves the packet-to-packet spread clearly.
[beforeMap, ~, delay] = allPacketCirMap(beforeFrames, []);
[afterMap, ~, ~] = allPacketCirMap(afterFrames, delay);
fig = figure('Name', 'All-packet QM35 CIR amplitude overlays', ...
    'Color', 'w', 'Position', [80 120 1340 600]);
tiledlayout(1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

axBefore = nexttile;
plot(delay, beforeMap.', 'Color', [0.62 0.80 0.94], ...
    'LineWidth', 0.45);
hold on;
plot(delay, median(beforeMap, 1, 'omitnan'), 'k', 'LineWidth', 2.0);
grid on;
ylim([-40 0]);
xlabel('CIR delay (ns)');
ylabel('Normalized CIR amplitude (dB)');
title(sprintf('Before DW1000 cancellation (%d QM35 packets)', ...
    numel(beforeFrames)));
legend('Per-packet CIR', 'Median', 'Location', 'southwest');

axAfter = nexttile;
plot(delay, afterMap.', 'Color', [0.97 0.73 0.57], ...
    'LineWidth', 0.45);
hold on;
plot(delay, median(afterMap, 1, 'omitnan'), 'k', 'LineWidth', 2.0);
grid on;
ylim([-40 0]);
xlabel('CIR delay (ns)');
ylabel('Normalized CIR amplitude (dB)');
title(sprintf('After DW1000 cancellation (%d QM35 packets)', ...
    numel(afterFrames)));
legend('Per-packet CIR', 'Median', 'Location', 'southwest');
linkaxes([axBefore axAfter], 'xy');
sgtitle('All-packet QM35 CIR amplitude overlays');

if saveFigures
    file = fullfile(outputDir, 'qm35_cir_before_after_dw1000_overlays.png');
    exportgraphics(fig, file, 'Resolution', dpi);
    fprintf('All-packet CIR overlays: %s\n', file);
end
end
