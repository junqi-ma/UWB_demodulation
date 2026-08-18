%% Decode all standalone QM35 processed captures.
% This script reuses run_decode_uwb_all.m with explicit stage config so the
% three standalone QM35 captures are decoded into separate output folders.
clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

data_dir = 'D:\bupt\project\UWB基带数据';
input_files = {
    fullfile(data_dir, 'qm35_new_processed_1.dat')
    fullfile(data_dir, 'qm35_new_processed_2.dat')
    fullfile(data_dir, 'qm35_new_processed_3.dat')
};

for k = 1:numel(input_files)
    input_file = input_files{k};
    if ~isfile(input_file)
        error('run_decode_qm35_processed_all:InputNotFound', ...
            'Input file does not exist: %s', input_file);
    end

    [~, capture_stem] = fileparts(input_file);
    sic_stage_config = struct( ...
        'input_file', input_file, ...
        'phy_profile', 'QM35', ...
        'result_directory', fullfile(project_dir, 'decoded_results', ...
            capture_stem), ...
        'pll_phase_compensation_repetitions', 10); %#ok<NASGU>

    fprintf('\n========== Decode QM35 processed %d / %d ==========\n', ...
        k, numel(input_files));
    fprintf('Input : %s\n', input_file);
    fprintf('Output: %s\n', sic_stage_config.result_directory);

    run(fullfile(project_dir, 'run_decode_uwb_all.m'));
end

clear sic_stage_config;
fprintf('\n========== All standalone QM35 decodes complete ==========\n');
