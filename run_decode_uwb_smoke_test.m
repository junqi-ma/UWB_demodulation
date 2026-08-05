%% Non-interactive smoke test for DW1000 single-packet decode.
% Runs decode without plots and exits with a clear pass/fail report.
clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

options = struct();
options.file_name = 'F:\UWB基带数据\DW1000_1.dat';
options.sample_offset = 0;
options.sample_num = 1.5e6;
options.ant_num = 1;
options.channel_index = 1;
options.fs_rx = 998.4e6;
options.preamble_repetitions = 256;
options.cir_repetitions = 64;
options.cir_pre_samples = 8;
options.cir_post_samples = 30;
options.cir_max_path_m = [];
options.code_index = 10;
options.data_rate = 6.81;
options.sfd_mode = 'auto';
options.decawave_sfd = [-1; -1; -1; -1; 1; -1; 0; 0];
options.ieee_sfd = [0; 1; 0; -1; 1; 0; 0; -1];
options.sfd4z_1 = [-1; -1; 1; -1];
options.sfd4z_2 = [-1; -1; -1; 1; -1; -1; 1; -1];
options.sfd4z_3 = [-1; -1; -1; -1; -1; 1; 1; -1; ...
    -1; 1; -1; 1; -1; -1; 1; -1];
options.sfd4z_4 = [-1; -1; -1; -1; -1; -1; -1; 1; ...
    -1; -1; 1; -1; -1; 1; -1; 1; -1; 1; -1; -1; ...
    -1; 1; 1; -1; -1; -1; 1; -1; 1; 1; -1; -1];
options.max_psdu_bytes = 32;
options.enable_frame_crop = true;
options.verbose = true;
options.show_plots = false;

fprintf('Smoke test: decode_uwb on %s\n', options.file_name);
t0 = tic;
try
    result = decode_uwb(options);
    elapsed = toc(t0);
    fprintf('\n========== SMOKE TEST PASS ==========\n');
    fprintf('Elapsed                      : %.3f s\n', elapsed);
    fprintf('Soft chips                   : %d\n', numel(result.soft_chips));
    fprintf('SFD                         : %s corr=%.4f\n', ...
        result.sfd.name, result.sfd.correlation);
    fprintf('PHR SECDED                  : %d\n', result.phr.secded_pass);
    fprintf('PSDU length                 : %d bytes\n', ...
        result.phr.psdu_length_bytes);
    if ~isempty(result.payload.bytes)
        fprintf('PSDU bytes                   : ');
        fprintf('%02X ', result.payload.bytes);
        fprintf('\n');
    end
    fprintf('FCS pass                    : %d (rx=0x%04X calc=0x%04X)\n', ...
        result.payload.fcs_pass, result.payload.fcs_received, ...
        result.payload.fcs_calculated);
    if ~result.payload.fcs_pass || ~result.phr.secded_pass
        error('Decode finished but PHR/FCS did not pass.');
    end
    fprintf('=====================================\n');
catch ME
    elapsed = toc(t0);
    fprintf('\n========== SMOKE TEST FAIL ==========\n');
    fprintf('Elapsed                      : %.3f s\n', elapsed);
    fprintf('Error                         : %s\n', ME.message);
    if ~isempty(ME.stack)
        fprintf('Location                     : %s (line %d)\n', ...
            ME.stack(1).name, ME.stack(1).line);
    end
    fprintf('=====================================\n');
    rethrow(ME);
end
