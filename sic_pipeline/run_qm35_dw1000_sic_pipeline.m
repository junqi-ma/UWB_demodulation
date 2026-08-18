%% Decode/cancel QM35 first, then decode/cancel DW1000.
% Uses project-root run_decode_uwb_all.m / run_cancel_all_uwb_packets.m
% (adaptive full-rate multi-packet detector + PLL/CIR-slow/SFO cancel).
clear;
close all;
clc;

pipeline_dir = fileparts(mfilename('fullpath'));
project_dir = fileparts(pipeline_dir);
addpath(project_dir);
addpath(pipeline_dir);

cfg = struct();
cfg.input_file = 'F:\UWB基带数据\qm35_dw1000_new_processed_1.dat';
[~, capture_stem] = fileparts(cfg.input_file);
cfg.output_root = fullfile(project_dir, 'decoded_results', ...
    capture_stem, 'sic_dw1000_removed_qm35_preserved');
cfg.cancellation_mode = 'optimal_complex';

% Resume completed stages. Existing incomplete or inconsistent products
% still raise an error instead of being overwritten silently.
cfg.resume = true;
% Force a cold run so timing measures actual decode/cancel computation.
% Set false to allow reuse of complete provenance-valid products.
cfg.overwrite = true;
% The legacy aggregate visualizer is currently incomplete; it is not part
% of decode/cancel validation and must not interrupt a completed SIC run.
cfg.make_plots = false;

tic_total = tic;
pipeline = uwbSicPipeline(cfg);
driver_elapsed = toc(tic_total);

fprintf('\n=== SIC timing summary ===\n');
fprintf('Driver elapsed time       : %.2f s\n', driver_elapsed);
if isfield(pipeline, 'timing')
    fprintf('QM35 decode               : %.2f s\n', ...
        pipeline.timing.qm35_decode);
    fprintf('QM35 cancellation         : %.2f s\n', ...
        pipeline.timing.qm35_cancel);
    fprintf('DW1000 decode             : %.2f s\n', ...
        pipeline.timing.dw1000_decode);
    fprintf('DW1000 cancellation       : %.2f s\n', ...
        pipeline.timing.dw1000_cancel);
    fprintf('Visualization             : %.2f s\n', ...
        pipeline.timing.visualization);
    fprintf('SIC processing total      : %.2f s\n', ...
        pipeline.timing.sic_processing_total);
    fprintf('Pipeline elapsed total    : %.2f s\n', ...
        pipeline.timing.total_elapsed);
    fprintf('Non-SIC overhead          : %.2f s\n', ...
        pipeline.timing.non_sic_overhead);
    fprintf('Timing CSV                : %s\n', ...
        pipeline.paths.timing_file);
end
assignin('base', 'uwb_sic_pipeline', pipeline);
assignin('base', 'sic_pipeline_driver_elapsed', driver_elapsed);
assignin('base', 'sic_pipeline_timing', pipeline.timing);
