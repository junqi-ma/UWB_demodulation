%% Visualize the completed QM35 -> DW1000 SIC pipeline.
% This compatibility entry point intentionally delegates to the validated
% CIR comparison script. The prior Figure-5 prototype referenced helpers
% that were never implemented and could interrupt an otherwise completed
% SIC run.

sic_managed_visualization = ...
    exist('sic_pipeline_managed_visualization', 'var') == 1 && ...
    logical(sic_pipeline_managed_visualization) && ...
    exist('sic_manifest_file', 'var') == 1;
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

if ~sic_managed_visualization
    sic_manifest_file = fullfile(project_dir, 'decoded_results', ...
        'qm35_dw1000_new_1', 'sic_dw1000_removed_qm35_preserved', ...
        'pipeline_manifest.mat');
end

if ~isfile(sic_manifest_file)
    error('visualize_UwbSicPipeline:ManifestNotFound', ...
        'Pipeline manifest not found: %s', sic_manifest_file);
end

fprintf(['Running QM35 CIR before/after DW1000-cancellation analysis ', ...
    'for:\n%s\n'], sic_manifest_file);
% Mark the nested script as managed so it consumes this exact manifest
% instead of falling back to its standalone default.
sic_pipeline_managed_visualization = true; %#ok<NASGU>
run(fullfile(pipeline_dir, 'analyze_qm35_cir_before_after_dw1000.m'));
