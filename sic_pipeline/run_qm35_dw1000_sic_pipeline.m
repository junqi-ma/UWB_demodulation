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
cfg.input_file = 'D:\bupt\project\UWB基带数据\qm35_dw1000_processed_1.dat';
[~, capture_stem] = fileparts(cfg.input_file);
cfg.output_root = fullfile(project_dir, 'decoded_results', ...
    capture_stem, 'sic_dw1000_removed_qm35_preserved');
cfg.cancellation_mode = 'optimal_complex';
cfg.remove_synchronous_tone = false;
cfg.require_pll_template = false;
cfg.require_fcs_pass_for_cancellation = false;

% Resume completed stages. Existing incomplete or inconsistent products
% still raise an error instead of being overwritten silently.
cfg.resume = true;
% Rebuild after adaptive full-rate detector v3 (detection_algorithm_version=3).
% Set false after one complete successful pipeline run.
cfg.overwrite = true;
% The legacy aggregate visualizer is currently incomplete; it is not part
% of decode/cancel validation and must not interrupt a completed SIC run.
cfg.make_plots = false;

pipeline = uwbSicPipeline(cfg);
assignin('base', 'uwb_sic_pipeline', pipeline);
