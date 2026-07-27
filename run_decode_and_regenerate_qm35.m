%% Decode one QM35 frame and regenerate its transmit waveform
clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% -------------------- QM35 capture --------------------
options = struct();
options.file_name = 'F:\UWB基带数据\QM35_1.dat';
options.sample_offset = 0;
options.sample_num = 0.5e6;
options.ant_num = 1;
options.channel_index = 1;

options.fs_rx = 737.28e6;
options.x410_center_frequency = 6500e6;
options.dw1000_center_frequency = 6489.6e6;
options.preamble_repetitions = 128;
% QM35825 has a visible phase transient at packet start. Exclude the first
% 24 SYNC repetitions and estimate CIR from the stable 25..128 region.
options.cir_skip_initial_repetitions = 24;
options.cir_repetitions = 104;
options.cir_pre_samples = 8;
options.cir_post_samples = 30;
options.cir_max_path_m = [];
options.code_index = 9;
options.data_rate = 6.81;
options.sfd_mode = '4z2';
options.max_psdu_bytes = 32;
options.enable_frame_crop = true;
options.verbose = true;
options.show_plots = false;

% The periodic X410 interference cancellation used by the reference script.
options.enable_interference_cancellation = true;
options.interference_quiet_offset = 400000;
options.interference_quiet_num = 262144;
options.interference_tone_bin = -169;
options.interference_period_samples = 512;

%% -------------------- Cancel the single-tone interference first --------------------
% This is deliberately outside the decoder: the same tone-cancelled IQ is
% reused for both decoding and the original/generated waveform comparison.
params = uwbdecoder.mergeOptions( ...
    uwbdecoder.defaultOptions(), options);
addpath(params.helper_path);
fprintf('Reading QM35 capture and cancelling the single tone first: %s\n', ...
    options.file_name);
[rx_tone_cancelled, interference] = ...
    uwbdecoder.readAndCancelInterference(params);

%% -------------------- Decode the tone-cancelled signal --------------------
fprintf('Decoding the tone-cancelled QM35 signal...\n');
result = decode_x410_dw1000(options, rx_tone_cancelled, interference);
if ~result.phr.secded_pass
    error('QM35 PHR SECDED failed; transmit waveform was not generated.');
end
if ~result.payload.fcs_pass
    error('QM35 FCS failed; transmit waveform was not generated.');
end

fprintf('\nDecoded QM35 PSDU (%d bytes): ', numel(result.payload.bytes));
fprintf('%02X ', result.payload.bytes);
fprintf('\n');

%% -------------------- Regenerate the decoded frame --------------------
tx_options = struct();
tx_options.fs_tx = options.fs_rx;
tx_options.x410_center_frequency = options.x410_center_frequency;
tx_options.qm35_center_frequency = options.dw1000_center_frequency;
tx_options.preamble_repetitions = options.preamble_repetitions;
tx_options.code_index = options.code_index;
tx_options.sfd_number = 2;
tx_options.peak_amplitude = 0.8;
tx_options.guard_samples = 4096;
tx_options.require_fcs_pass = true;

tx = generate_qm35_tx_from_decode(result, tx_options);

%% -------------------- Replace every shaping pulse with measured CIR --------------------
tx_after_cir = apply_estimated_cir_to_qm35(tx, result.cir);

%% -------------------- Compare captured and regenerated signals --------------------
output_dir = fullfile(project_dir, 'regenerated_qm35');
if ~isfolder(output_dir)
    mkdir(output_dir);
end
comparison_png = fullfile(output_dir, ...
    'qm35_tone_cancelled_vs_regenerated.png');
cir_png = fullfile(output_dir, 'qm35_estimated_cir_diagnostics.png');
cancellation_png = fullfile(output_dir, ...
    'qm35_regenerated_subtraction_cancellation.png');
show_comparison_figure = true;
cir_diagnostics = plot_qm35_estimated_cir( ...
    result.cir, cir_png, show_comparison_figure);
comparison = compare_qm35_original_and_generated( ...
    options, tx, comparison_png, show_comparison_figure, ...
    rx_tone_cancelled, interference, tx_after_cir);
cancellation = cancel_qm35_with_regenerated( ...
    options, tx_after_cir, rx_tone_cancelled, ...
    cancellation_png, show_comparison_figure);

%% -------------------- Save MATLAB and X410-ready outputs --------------------
mat_file = fullfile(output_dir, 'qm35_decoded_and_regenerated.mat');
iq_file = fullfile(output_dir, 'qm35_regenerated_x410_int16.dat');
cir_iq_file = fullfile(output_dir, ...
    'qm35_regenerated_after_cir_x410_int16.dat');
save(mat_file, 'result', 'tx', 'tx_after_cir', 'comparison', ...
    'cancellation', 'cir_diagnostics', 'interference', ...
    'options', 'tx_options', '-v7.3');
int16_scale = write_x410_iq_int16(iq_file, tx.waveform_x410);
cir_int16_scale = write_x410_iq_int16( ...
    cir_iq_file, tx_after_cir.waveform_x410);

fprintf('\n========== QM35 decode/regenerate summary ==========\n');
fprintf('SFD                           : %s (corr %.4f)\n', ...
    result.sfd.name, result.sfd.correlation);
fprintf('PHR / FCS pass                : %d / %d\n', ...
    result.phr.secded_pass, result.payload.fcs_pass);
fprintf('PSDU length                   : %d bytes\n', ...
    numel(tx.psdu_bytes));
fprintf('Work / X410 sample rate       : %.2f / %.2f MHz\n', ...
    tx.sample_rate_work/1e6, tx.sample_rate_tx/1e6);
fprintf('X410 digital frequency offset : %.3f MHz\n', ...
    tx.digital_offset_hz/1e6);
fprintf('X410 waveform                 : %d samples (%.3f us)\n', ...
    numel(tx.waveform_x410), tx.duration_s*1e6);
fprintf('Original/generated correlation: %.4f\n', ...
    comparison.waveform_correlation);
fprintf('Original/generated NMSE       : %.2f dB\n', ...
    comparison.nmse_db);
fprintf('CIR-pulse correlation          : %.4f\n', ...
    comparison.cir_waveform_correlation);
fprintf('CIR-pulse NMSE                 : %.2f dB\n', ...
    comparison.cir_nmse_db);
fprintf('Tone suppression before decode : %.2f dB\n', ...
    interference.suppression_db);
fprintf('Replica cancellation, no CFO    : %.2f dB\n', ...
    cancellation.no_cfo.suppression_db);
fprintf('Replica cancellation, with CFO  : %.2f dB\n', ...
    cancellation.replica_fitted_cfo.suppression_db);
fprintf('Replica cancellation, steady     : %.2f dB\n', ...
    cancellation.replica_fitted_cfo.steady_state_suppression_db);
fprintf('Replica-fitted CFO               : %+.3f kHz\n', ...
    cancellation.replica_fitted_cfo_hz/1e3);
fprintf('int16 scale                   : %.1f\n', int16_scale);
fprintf('after-CIR int16 scale          : %.1f\n', cir_int16_scale);
fprintf('MAT output                    : %s\n', mat_file);
fprintf('IQ output                     : %s\n', iq_file);
fprintf('After-CIR IQ output            : %s\n', cir_iq_file);
fprintf('Comparison plot               : %s\n', comparison_png);
fprintf('CIR diagnostics plot           : %s\n', cir_png);
fprintf('Cancellation plot              : %s\n', cancellation_png);
fprintf('=====================================================\n');

assignin('base', 'qm35_decode_result', result);
assignin('base', 'qm35_tx', tx);
assignin('base', 'qm35_tx_after_cir', tx_after_cir);
