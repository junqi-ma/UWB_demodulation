%% Decode every UWB packet in an X410 capture and save all CIRs
% P0 flow:
%   1) cheap coarse energy + decimated preamble correlation over the full file
%   2) full decode only at surviving candidates
%   3) save CIR / summary
clear;
close all;
clc;

%% -------------------- Input capture --------------------
options = struct();
options.file_name = 'F:\QM35_1.dat';
options.ant_num = 1;
options.channel_index = 1;

%% -------------------- X410 / DW1000 radio --------------------
options.fs_rx = 737.28e6;
options.x410_center_frequency = 6500e6;
options.dw1000_center_frequency = 6489.6e6;
options.preamble_repetitions = 128;
options.cir_repetitions = 64;
options.code_index = 9;
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

%% -------------------- Interference cancellation --------------------
options.enable_interference_cancellation = true;
options.interference_quiet_offset = 400000;
options.interference_quiet_num = 1500000;
options.interference_tone_bin = -169;
options.interference_period_samples = 512;
% Leave empty to estimate once from the quiet interval, then reuse.
options.interference_coefficient = [];
options.show_plots = false;

%% -------------------- Coarse pre-screen (P0) --------------------
batch = struct();
% Large chunks with modest overlap; no full decode here.
batch.coarse_chunk_samples = 4e6;
batch.coarse_step_samples = 3e6;
% Decimate by 32 before energy / matched-filter pre-screen.
batch.coarse_decimation = 32;
% Moving-average length for |r|^2, measured in original RX samples.
batch.energy_smooth_rx_samples = 8192;
% Energy threshold: median + k * MAD.
batch.energy_threshold_sigma = 6;
% Also require a decimated preamble-correlation peak inside energetic regions.
batch.use_coarse_correlation = true;
batch.corr_threshold_sigma = 5;
% Merge peaks closer than this into one candidate.
batch.candidate_merge_samples = 2e5;
% Start the fine window a little before the coarse peak.
batch.pre_packet_guard_samples = 5e4;

%% -------------------- Fine decode around candidates --------------------
% Full decoder window at each candidate (still much rarer than old sliding scan).
batch.window_samples = 0.8e6;
batch.min_window_samples = 0.3e6;
% Kept for compatibility; coarse scan no longer uses dense stepping.
batch.search_step_samples = 0.5e6;
batch.post_packet_guard_samples = 4096;
batch.start_tolerance_samples = 4096;
batch.require_fcs_pass = false;
batch.save_individual_cir = true;

%% -------------------- Output paths --------------------
[~, capture_stem] = fileparts(options.file_name);
batch.output_directory = fullfile(pwd, 'decoded_results', capture_stem);
batch.mat_file = fullfile(batch.output_directory, 'all_frames_cir.mat');
batch.summary_csv = fullfile(batch.output_directory, 'frame_summary.csv');

%% -------------------- Run full-file decode --------------------
results = decode_x410_dw1000_all(options, batch);

%% -------------------- Compact console summary --------------------
fprintf('\n========== Full-file DW1000 decode summary ==========\n');
fprintf('Capture file                 : %s\n', options.file_name);
fprintf('Total complex samples        : %d\n', results.total_samples);
fprintf('Coarse chunks                : %d\n', results.coarse_chunk_count);
fprintf('Coarse raw peaks             : %d\n', results.coarse_raw_peak_count);
fprintf('Merged candidates           : %d\n', results.candidate_count);
fprintf('Fine decode attempts        : %d\n', results.attempt_count);
fprintf('Unique packets found        : %d\n', results.packet_count);
fprintf('FCS-pass packets            : %d\n', results.fcs_pass_count);
fprintf('Time coarse / fine          : %.1f s / %.1f s\n', ...
    results.coarse_seconds, results.fine_seconds);
fprintf('Results MAT                 : %s\n', batch.mat_file);
fprintf('Summary CSV                 : %s\n', batch.summary_csv);
fprintf('=====================================================\n');

if results.packet_count > 0
    for k = 1:results.packet_count
        frame = results.frames(k);
        fprintf(['#%02d  t=%.3f ms  abs_start=%d  SFD=%s  ', ...
            'corr=%.3f  PSDU=%d B  FCS=%d\n'], ...
            k, frame.time_start_s*1e3, frame.abs_start_sample, ...
            frame.sfd_name, frame.sfd_correlation, ...
            frame.psdu_length_bytes, frame.fcs_pass);
    end
end
