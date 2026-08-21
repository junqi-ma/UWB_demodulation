%% Compare QM35 CIR before and after DW1000 cancellation on a dump SIC run.
% scheduledDumpSicPipeline injects sic_dump_manifest_file when this script
% is launched as its visualization stage. Standalone execution uses the
% dumpDir default below.

sic_managed = exist('sic_dump_managed_visualization', 'var') == 1 && ...
    logical(sic_dump_managed_visualization) && ...
    exist('sic_dump_manifest_file', 'var') == 1;
if ~sic_managed
    clear;
    sic_managed = false;
end
close all;
clc;

this_dir = fileparts(mfilename('fullpath'));
if isempty(this_dir)
    this_dir = pwd;
end
addpath(this_dir);

%% -------------------- User parameters --------------------
if sic_managed
    manifest_file = sic_dump_manifest_file;
else
    dump_dir = 'F:\UWB基带数据\8月20日数据\qm35_sensing_1';
    [~, dump_name] = fileparts(char(strtrim(string(dump_dir))));
    switch dump_name
        case 'qm35_scheduled_sc16_dump'
            tag = 'scheduled_sc16_dump';
        case 'qm35_clean_scheduled_sc16_dump'
            tag = 'scheduled_sc16_dump_qm35_clean';
        otherwise
            tag = dump_name;
    end
    manifest_file = fullfile(this_dir, 'decoded_results', tag, ...
        'sic_dw1000_removed_qm35_preserved', 'pipeline_manifest.mat');
end

save_figures = true;
figure_resolution_dpi = 140;
selected_packet_id = [];

%% -------------------- Load --------------------
if ~isfile(manifest_file)
    error('visualize_scheduled_dump_sic_cir:ManifestNotFound', ...
        'Pipeline manifest not found: %s', manifest_file);
end
saved = load(manifest_file, 'pipeline');
pipeline = saved.pipeline;
records = pipeline.packets;
output_dir = pipeline.paths.validation_dir;
if ~isfolder(output_dir)
    mkdir(output_dir);
end

ok = [records.ok];
records = records(ok);
if isempty(records)
    warning('visualize_scheduled_dump_sic_cir:NoRecords', ...
        'No successful dump SIC packets to plot.');
    return
end

fprintf('\n=== Dump SIC CIR before/after ===\n');
fprintf('Manifest : %s\n', manifest_file);
fprintf('Packets  : %d  SIC applied: %d\n', ...
    numel(records), nnz([records.sic_applied]));

%% -------------------- Figures --------------------
selected = selectDumpPacket(records, selected_packet_id);
plotSelectedDumpCir(records(selected), output_dir, save_figures, ...
    figure_resolution_dpi);
plotDumpCirDistributions(records, output_dir, save_figures, ...
    figure_resolution_dpi);
plotDumpCirHeatmaps(records, output_dir, save_figures, ...
    figure_resolution_dpi);
plotDumpCirOverlays(records, output_dir, save_figures, ...
    figure_resolution_dpi);

function idx = selectDumpPacket(records, requestedId)
ids = [records.packet_id];
if ~isempty(requestedId)
    idx = find(ids == requestedId, 1);
    if isempty(idx)
        error('visualize_scheduled_dump_sic_cir:MissingPacket', ...
            'packet_id %d is not in the SIC result.', requestedId);
    end
    return
end
sic = find([records.sic_applied]);
if isempty(sic)
    sic = 1:numel(records);
end
coherence = nan(size(sic));
for k = 1:numel(sic)
    coherence(k) = records(sic(k)).cir_metrics.cir_coherence;
end
valid = find(isfinite(coherence));
if isempty(valid)
    idx = sic(1);
    return
end
[~, rel] = min(abs(coherence(valid) - median(coherence(valid), 'omitnan')));
idx = sic(valid(rel));
end

function plotSelectedDumpCir(record, outputDir, saveFigures, dpi)
[b, a, delay] = alignedCir(record.qm35_before, record.qm35_after);
if isempty(b)
    warning('visualize_scheduled_dump_sic_cir:NoCir', ...
        'Packet %d has no aligned CIR to plot.', record.packet_id);
    return
end
alpha = (a' * b) / (a' * a + eps);
aAligned = alpha * a;
[peakIdx, ~] = firstPeakIndex(b, delay, record.qm35_before.first_path_delay_ns);
refPower = abs(b(peakIdx))^2 + eps;
beforeDb = 10 * log10(max(abs(b).^2, eps) / refPower);
afterDb = 10 * log10(max(abs(aAligned).^2, eps) / refPower);

fig = figure('Name', 'Dump SIC QM35 CIR before/after', ...
    'Color', 'w', 'Position', [60 60 1280 820]);
tiledlayout(fig, 2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

nexttile;
plot(delay, beforeDb, 'LineWidth', 1.3, 'Color', [0.15 0.45 0.85]);
hold on;
plot(delay, afterDb, '--', 'LineWidth', 1.3, 'Color', [0.85 0.30 0.12]);
if isfinite(record.qm35_before.first_path_delay_ns)
    xline(record.qm35_before.first_path_delay_ns, 'k:', ...
        'First Path', 'LineWidth', 1.0);
end
grid on;
ylim([-50 25]);
xlabel('CIR delay (ns)');
ylabel('Normalized |CIR|^2 (dB)');
legend('Before DW1000 cancellation', ...
    'After DW1000 cancellation, globally aligned', 'Location', 'best');
title(sprintf(['packet %d | SIC %s | state %s -> %s | ', ...
    'coherence %.4f'], record.packet_id, yesNo(record.sic_applied), ...
    record.qm35_before.interference_state, ...
    record.qm35_after.interference_state, ...
    record.cir_metrics.cir_coherence));

nexttile;
plot(delay, 10 * log10(max(abs(b - aAligned).^2, eps) / refPower), ...
    'k', 'LineWidth', 1.2);
grid on;
ylim([-50 25]);
xlabel('CIR delay (ns)');
ylabel('Normalized |before - aligned after|^2 (dB)');
title(sprintf(['CIR difference | early residual %.1f -> %.1f dB | ', ...
    'occupancy %.2f -> %.2f'], ...
    record.cir_metrics.early_residual_before_db, ...
    record.cir_metrics.early_residual_after_db, ...
    record.cir_metrics.occupancy_before, ...
    record.cir_metrics.occupancy_after));

if saveFigures
    file = fullfile(outputDir, sprintf( ...
        'qm35_cir_before_after_packet_%03d.png', record.packet_id));
    exportgraphics(fig, file, 'Resolution', dpi);
    fprintf('Representative CIR plot: %s\n', file);
end
end

function plotDumpCirDistributions(records, outputDir, saveFigures, dpi)
coherence = arrayfun(@(r) r.cir_metrics.cir_coherence, records);
residual = arrayfun(@(r) r.cir_metrics.cir_normalized_residual, records);
earlyDelta = arrayfun(@(r) r.cir_metrics.early_residual_after_db - ...
    r.cir_metrics.early_residual_before_db, records);
fig = figure('Name', 'Dump SIC CIR metrics', ...
    'Color', 'w', 'Position', [80 80 1180 420]);
tiledlayout(fig, 1, 3, 'TileSpacing', 'compact', 'Padding', 'compact');
nexttile; histogram(coherence, 20); grid on;
xlabel('CIR coherence'); ylabel('Packets');
nexttile; histogram(residual, 20); grid on;
xlabel('Normalized CIR residual'); ylabel('Packets');
nexttile; histogram(earlyDelta, 20); grid on;
xlabel('After - before early residual (dB)'); ylabel('Packets');
sgtitle(sprintf('QM35 CIR change after dump SIC (%d packets, %d cancelled)', ...
    numel(records), nnz([records.sic_applied])));
if saveFigures
    file = fullfile(outputDir, 'qm35_cir_before_after_distributions.png');
    exportgraphics(fig, file, 'Resolution', dpi);
    fprintf('CIR metric distributions: %s\n', file);
end
end

function plotDumpCirHeatmaps(records, outputDir, saveFigures, dpi)
[beforeMap, afterMap, delay] = dumpCirMaps(records);
diffMap = afterMap - beforeMap;
packetIds = [records.packet_id];
rowIdx = 1:numel(records);
fig = figure('Name', 'Dump SIC CIR heatmaps', ...
    'Color', 'w', 'Position', [40 60 1560 780]);
tiledlayout(fig, 1, 3, 'TileSpacing', 'compact', 'Padding', 'compact');
ax1 = nexttile;
imagesc(delay, rowIdx, beforeMap); axis xy; clim([-50 25]); colorbar;
yticks(rowIdx); yticklabels(string(packetIds));
xlabel('CIR delay (ns)'); ylabel('packet id');
title(sprintf('Before DW1000 cancellation (%d)', numel(records)));
ax2 = nexttile;
imagesc(delay, rowIdx, afterMap); axis xy; clim([-50 25]); colorbar;
yticks(rowIdx); yticklabels(string(packetIds));
xlabel('CIR delay (ns)'); ylabel('packet id');
title(sprintf('After DW1000 cancellation (%d)', numel(records)));
ax3 = nexttile;
imagesc(delay, rowIdx, diffMap); axis xy; clim([-10 10]); colorbar;
yticks(rowIdx); yticklabels(string(packetIds));
xlabel('CIR delay (ns)'); ylabel('packet id');
title('After - before (dB)');
colormap(fig, turbo(256));
linkaxes([ax1 ax2 ax3], 'x');
sgtitle('Dump SIC QM35 CIR heatmaps | first-peak normalized per packet');
if saveFigures
    file = fullfile(outputDir, 'qm35_cir_before_after_heatmaps.png');
    exportgraphics(fig, file, 'Resolution', dpi);
    fprintf('All-packet CIR heatmaps: %s\n', file);
end
end

function plotDumpCirOverlays(records, outputDir, saveFigures, dpi)
[beforeMap, afterMap, delay] = dumpCirMaps(records);
fig = figure('Name', 'Dump SIC CIR overlays', ...
    'Color', 'w', 'Position', [80 100 1340 560]);
tiledlayout(fig, 1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
ax1 = nexttile;
plot(delay, beforeMap.', 'Color', [0.62 0.80 0.94], 'LineWidth', 0.45);
hold on;
plot(delay, median(beforeMap, 1, 'omitnan'), 'k', 'LineWidth', 2.0);
grid on; ylim([-60 0]);
xlabel('CIR delay (ns)'); ylabel('Normalized CIR power (dB)');
title(sprintf('Before (%d packets)', numel(records)));
legend('Per-packet CIR', 'Median', 'Location', 'southwest');
ax2 = nexttile;
plot(delay, afterMap.', 'Color', [0.97 0.73 0.57], 'LineWidth', 0.45);
hold on;
plot(delay, median(afterMap, 1, 'omitnan'), 'k', 'LineWidth', 2.0);
grid on; ylim([-60 0]);
xlabel('CIR delay (ns)'); ylabel('Normalized CIR power (dB)');
title(sprintf('After (%d packets)', numel(records)));
legend('Per-packet CIR', 'Median', 'Location', 'southwest');
linkaxes([ax1 ax2], 'xy');
sgtitle('Dump SIC QM35 CIR overlays | first-peak normalized');
if saveFigures
    file = fullfile(outputDir, 'qm35_cir_before_after_overlays.png');
    exportgraphics(fig, file, 'Resolution', dpi);
    fprintf('All-packet CIR overlays: %s\n', file);
end
end

function [beforeMap, afterMap, delay] = dumpCirMaps(records)
[~, delay] = cirForPlot(records(1).qm35_before);
delay = delay(:).';
beforeMap = nan(numel(records), numel(delay));
afterMap = nan(numel(records), numel(delay));
for k = 1:numel(records)
    beforeMap(k, :) = normalizedCirDb(records(k).qm35_before, delay);
    afterMap(k, :) = normalizedCirDb(records(k).qm35_after, delay);
end
beforeMap = max(beforeMap, -60);
afterMap = max(afterMap, -60);
end

function valuesDb = normalizedCirDb(pack, referenceDelay)
[values0, delay0] = cirForPlot(pack);
if isempty(values0)
    valuesDb = nan(size(referenceDelay));
    return
end
values = interp1(delay0, values0, referenceDelay(:), 'linear', 0);
[peakIdx, ~] = firstPeakIndex(values, referenceDelay(:), ...
    pack.first_path_delay_ns);
refPower = abs(values(peakIdx))^2 + eps;
valuesDb = 10 * log10(max(abs(values).^2, eps) / refPower);
valuesDb = valuesDb(:).';
end

function [beforeValues, afterValues, delay] = alignedCir(beforePack, afterPack)
[beforeValues, delay] = cirForPlot(beforePack);
[afterValues, afterDelay] = cirForPlot(afterPack);
if isempty(beforeValues) || isempty(afterValues)
    delay = [];
    beforeValues = [];
    afterValues = [];
    return
end
if numel(afterDelay) ~= numel(delay) || max(abs(afterDelay - delay)) >= 1e-9
    afterValues = interp1(afterDelay, afterValues, delay, 'linear', 0);
end
valid = isfinite(beforeValues) & isfinite(afterValues);
beforeValues = beforeValues(valid);
afterValues = afterValues(valid);
delay = delay(valid);
end

function [values, delay] = cirForPlot(pack)
values = [];
delay = [];
if isstruct(pack) && isfield(pack, 'interference') && ...
        isstruct(pack.interference) && ...
        isfield(pack.interference, 'coherent_cir') && ...
        ~isempty(pack.interference.coherent_cir)
    values = pack.interference.coherent_cir(:);
    delay = pack.interference.delay_ns(:);
    return
end
if isstruct(pack) && isfield(pack, 'cir') && isstruct(pack.cir) && ...
        isfield(pack.cir, 'values') && ~isempty(pack.cir.values)
    values = pack.cir.values(:);
    delay = pack.cir.delay_ns(:);
end
end

function [peakIdx, peakDelay] = firstPeakIndex(values, delay, firstPathDelayNs)
values = values(:);
delay = delay(:);
peakIdx = 1;
if isempty(values)
    peakDelay = NaN;
    return
end
power = abs(values).^2;
search = true(size(power));
if isfinite(firstPathDelayNs)
    search = delay >= firstPathDelayNs;
end
idx = find(search);
if isempty(idx)
    idx = (1:numel(power)).';
end
region = power(idx);
isPeak = false(size(region));
if isscalar(region)
    isPeak = true;
else
    isPeak(1) = region(1) >= region(2);
    isPeak(end) = region(end) >= region(end - 1);
    if numel(region) > 2
        isPeak(2:end-1) = region(2:end-1) >= region(1:end-2) & ...
            region(2:end-1) >= region(3:end);
    end
end
peakLocal = find(isPeak, 1, 'first');
if isempty(peakLocal)
    [~, peakLocal] = max(region);
end
peakIdx = idx(peakLocal);
peakDelay = delay(peakIdx);
end

function text = yesNo(tf)
if tf
    text = 'yes';
else
    text = 'no';
end
end
