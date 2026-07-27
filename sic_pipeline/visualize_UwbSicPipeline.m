%% Visualize the completed QM35 -> DW1000 SIC pipeline.
% This is a standalone script. It may also be called automatically by
% uwbSicPipeline.m, which injects sic_manifest_file.

sic_managed_visualization = exist('sic_manifest_file', 'var') == 1;
if ~sic_managed_visualization
    clear;
    sic_managed_visualization = false;
end
close all;
clc;

pipeline_dir = fileparts(mfilename('fullpath'));
project_dir = fileparts(pipeline_dir);
addpath(project_dir);
addpath(pipeline_dir);

%% -------------------- User configuration --------------------
if ~sic_managed_visualization
    sic_manifest_file = fullfile(project_dir, 'decoded_results', ...
        'qm35_dw1000_1', 'sic_dw1000_removed_qm35_preserved', ...
        'pipeline_manifest.mat');
end

save_figures = true;
figure_resolution_dpi = 140;

%% -------------------- Load pipeline products --------------------
if ~isfile(sic_manifest_file)
    error('visualize_UwbSicPipeline:ManifestNotFound', ...
        'Pipeline manifest not found: %s', sic_manifest_file);
end

saved_pipeline = load(sic_manifest_file, 'pipeline');
pipeline = saved_pipeline.pipeline;
if ~isfield(pipeline, 'stages') || ...
        ~isfield(pipeline.stages, 'dw1000_cancel')
    error('visualize_UwbSicPipeline:IncompletePipeline', ...
        'The manifest does not contain all SIC stages.');
end

qm_decode = load(pipeline.stages.qm35_decode.scan_file, 'results');
dw_decode = load(pipeline.stages.dw1000_decode.scan_file, 'results');
qm_meta = load(pipeline.stages.qm35_cancel.metadata_file, 'reports');
dw_meta = load(pipeline.stages.dw1000_cancel.metadata_file, 'reports');

qm_results = qm_decode.results;
dw_results = dw_decode.results;
qm_reports = qm_meta.reports;
dw_reports = dw_meta.reports;

qm_suppression = successfulSuppression(qm_reports);
dw_suppression = successfulSuppression(dw_reports);

validation_dir = pipeline.paths.validation_dir;
if save_figures && ~isfolder(validation_dir)
    mkdir(validation_dir);
end

%% -------------------- Figure 1: counts and suppression --------------------
fig_summary = figure('Name', 'QM35 -> DW1000 SIC summary', ...
    'Color', 'w', 'Position', [80 70 1200 760]);

subplot(2, 2, 1);
counts = [pipeline.stages.qm35_decode.packet_count, ...
    pipeline.stages.qm35_cancel.cancelled_count; ...
    pipeline.stages.dw1000_decode.packet_count, ...
    pipeline.stages.dw1000_cancel.cancelled_count];
bar(counts);
set(gca, 'XTickLabel', {'QM35', 'DW1000'});
ylabel('Packet count');
legend('Decoded', 'Cancelled', 'Location', 'best');
title('Packets by SIC stage');
grid on;

subplot(2, 2, 2);
plotSuppression(qm_suppression, [0.15 0.55 0.85]);
title(sprintf('QM35 cancellation: median %.2f dB', ...
    safeMedian(qm_suppression)));

subplot(2, 2, 3);
plotSuppression(dw_suppression, [0.85 0.35 0.15]);
title(sprintf('DW1000 cancellation: median %.2f dB', ...
    safeMedian(dw_suppression)));

subplot(2, 2, 4);
axis off;
summary_text = sprintf([ ...
    'Input\n%s\n\n', ...
    'After QM35 cancellation\n%s\n\n', ...
    'Tone/DW1000 removed, QM35 preserved\n%s\n\n', ...
    'QM35: %d decoded, %d cancelled\n', ...
    'DW1000: %d decoded, %d cancelled'], ...
    pipeline.config.input_file, ...
    pipeline.stages.qm35_cancel.output_file, ...
    pipeline.stages.dw1000_cancel.output_file, ...
    pipeline.stages.qm35_decode.packet_count, ...
    pipeline.stages.qm35_cancel.cancelled_count, ...
    pipeline.stages.dw1000_decode.packet_count, ...
    pipeline.stages.dw1000_cancel.cancelled_count);
text(0, 1, summary_text, 'VerticalAlignment', 'top', ...
    'Interpreter', 'none');

sgtitle('Successive interference cancellation: QM35 then DW1000');

%% -------------------- Figure 2: packet transmission times --------------------
qm_start_ms = [qm_results.frames.time_start_s].' * 1e3;
qm_end_ms = [qm_results.frames.time_end_s].' * 1e3;
dw_start_ms = [dw_results.frames.time_start_s].' * 1e3;
dw_end_ms = [dw_results.frames.time_end_s].' * 1e3;

capture_duration_ms = max([ ...
    qm_results.duration_s, dw_results.duration_s]) * 1e3;

fig_timing = figure('Name', 'QM35 and DW1000 packet transmission times', ...
    'Color', 'w', 'Position', [90 80 1300 760]);

subplot(3, 1, 1);
hold on;
plotPacketIntervals(qm_start_ms, qm_end_ms, 1, [0.15 0.55 0.85]);
plotPacketIntervals(dw_start_ms, dw_end_ms, 2, [0.85 0.35 0.15]);
yticks([1 2]);
yticklabels({'QM35', 'DW1000'});
ylim([0.5 2.5]);
xlim([0 max(capture_duration_ms, eps)]);
xlabel('Capture time (ms)');
title('Packet transmission intervals');
grid on;

subplot(3, 1, 2);
plot(qm_start_ms, 1:numel(qm_start_ms), '.', ...
    'Color', [0.15 0.55 0.85], 'MarkerSize', 8);
xlim([0 max(capture_duration_ms, eps)]);
xlabel('QM35 transmission start time (ms)');
ylabel('Packet index');
title(sprintf('QM35 packet starts (%d packets)', numel(qm_start_ms)));
grid on;

subplot(3, 1, 3);
plot(dw_start_ms, 1:numel(dw_start_ms), '.', ...
    'Color', [0.85 0.35 0.15], 'MarkerSize', 7);
xlim([0 max(capture_duration_ms, eps)]);
xlabel('DW1000 transmission start time (ms)');
ylabel('Packet index');
title(sprintf('DW1000 packet starts after QM35 cancellation (%d packets)', ...
    numel(dw_start_ms)));
grid on;

sgtitle('Decoded packet transmission times on the original sample timeline');

%% -------------------- Save figures --------------------
if save_figures
    summary_png = fullfile(validation_dir, 'sic_pipeline_summary.png');
    timing_png = fullfile(validation_dir, 'packet_transmission_times.png');
    exportgraphics(fig_summary, summary_png, ...
        'Resolution', figure_resolution_dpi);
    exportgraphics(fig_timing, timing_png, ...
        'Resolution', figure_resolution_dpi);
    fprintf('Saved: %s\n', summary_png);
    fprintf('Saved: %s\n', timing_png);
end

fprintf('\n=== SIC visualization ===\n');
fprintf('QM35 packets   : %d\n', numel(qm_start_ms));
fprintf('DW1000 packets : %d\n', numel(dw_start_ms));
fprintf('Capture length : %.3f ms\n', capture_duration_ms);

%% ------------------------------------------------------------------------
function values = successfulSuppression(reports)
values = [reports.frame_suppression_db];
values = values([reports.success] & isfinite(values));
end

function plotSuppression(values, color)
if isempty(values)
    text(0.5, 0.5, 'No successfully cancelled packets', ...
        'HorizontalAlignment', 'center');
    axis off;
    return;
end
plot(1:numel(values), values, '.', 'Color', color, 'MarkerSize', 8);
hold on;
yline(median(values), 'k--', 'Median');
xlabel('Successfully cancelled packet');
ylabel('Suppression (dB)');
grid on;
end

function plotPacketIntervals(starts, ends, level, color)
if isempty(starts)
    return;
end
n = numel(starts);
x = nan(3 * n, 1);
y = nan(3 * n, 1);
x(1:3:end) = starts;
x(2:3:end) = ends;
y(1:3:end) = level;
y(2:3:end) = level;
plot(x, y, '-', 'Color', color, 'LineWidth', 2);
plot(starts, level * ones(size(starts)), '|', ...
    'Color', color, 'MarkerSize', 6);
end

function value = safeMedian(values)
if isempty(values)
    value = NaN;
else
    value = median(values);
end
end
