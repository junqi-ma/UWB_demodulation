%% Decode/cancel QM35 first, then decode/cancel DW1000.
clear;
close all;
clc;

pipeline_dir = fileparts(mfilename('fullpath'));
project_dir = fileparts(pipeline_dir);
addpath(project_dir);
addpath(pipeline_dir);

cfg = struct();
cfg.input_file = 'F:\UWB基带数据\qm35_dw1000_new_3.dat';
[~, capture_stem] = fileparts(cfg.input_file);
cfg.output_root = fullfile(project_dir, 'decoded_results', ...
    capture_stem, 'sic_dw1000_removed_qm35_preserved');
cfg.cancellation_mode = 'optimal_complex';

% Resume completed stages. Existing incomplete or inconsistent products
% still raise an error instead of being overwritten silently.
cfg.resume = true;
cfg.overwrite = false;
cfg.make_plots = true;

pipeline = uwbSicPipeline(cfg);
assignin('base', 'uwb_sic_pipeline', pipeline);
