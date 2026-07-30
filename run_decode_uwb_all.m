%% Decode every UWB packet in an X410 capture and save all CIRs
% Three-stage flow:
%   1) read every 100th IQ record and form a robust energy envelope
%   2) run 32x-decimated preamble correlation only in energetic intervals
%   3) fully decode surviving candidates and export exact sample intervals
% When called by sic_pipeline/uwbSicPipeline.m, sic_stage_config carries
% explicit stage paths. Direct interactive use keeps the original defaults.
sic_managed_run = exist('sic_stage_config', 'var') == 1;
if ~sic_managed_run
    clear;
    sic_managed_run = false;
end
close all;
clc;

%% -------------------- Signal type --------------------
% Select exactly one signal type: 'DW1000' or 'QM35'.
phy_profile = 'QM35';
if sic_managed_run
    phy_profile = sic_stage_config.phy_profile;
end

%% -------------------- Input capture --------------------
options = struct();
options.file_name = 'F:\UWB基带数据\qm35_new_3.dat';
%options.file_name = 'F:\USRP数据解调\decoded_results\qm35_dw1000_1\cancelled_optimal_complex.dat';
if sic_managed_run
    options.file_name = sic_stage_config.input_file;
end
options.ant_num = 1;
options.channel_index = 1;

%% -------------------- X410 / DW1000 radio --------------------
options.fs_rx = 737.28e6;
options.x410_center_frequency = 6500e6;
options.dw1000_center_frequency = 6489.6e6;
options.data_rate = 6.81;
pll_phase_compensation_repetitions = 10;
if sic_managed_run && isfield(sic_stage_config, ...
        'pll_phase_compensation_repetitions')
    pll_phase_compensation_repetitions = ...
        sic_stage_config.pll_phase_compensation_repetitions;
end
validateattributes(pll_phase_compensation_repetitions, {'numeric'}, ...
    {'scalar', 'integer', 'nonnegative'}, mfilename, ...
    'pll_phase_compensation_repetitions');

options.decawave_sfd = [-1; -1; -1; -1; 1; -1; 0; 0];
options.ieee_sfd = [0; 1; 0; -1; 1; 0; 0; -1];
options.sfd4z_1 = [-1; -1; 1; -1];
options.sfd4z_2 = [-1; -1; -1; 1; -1; -1; 1; -1];
options.sfd4z_3 = [-1; -1; -1; -1; -1; 1; 1; -1; ...
    -1; 1; -1; 1; -1; -1; 1; -1];
options.sfd4z_4 = [-1; -1; -1; -1; -1; -1; -1; 1; ...
    -1; -1; 1; -1; -1; 1; -1; 1; -1; 1; -1; -1; ...
    -1; 1; 1; -1; -1; -1; 1; -1; 1; 1; -1; -1];

switch upper(phy_profile)
    case 'DW1000'
        phy_profile = 'DW1000';
        options.preamble_repetitions = 128;
        options.code_index = 11;
        options.sfd_mode = 'decawave';
        % PLL compensation owns SYNC 1..10; save per-repetition CIR from
        % SYNC 11 onward so slow phase compensation takes over seamlessly.
        options.cir_skip_initial_repetitions = ...
            pll_phase_compensation_repetitions;
        options.cir_repetitions = options.preamble_repetitions - ...
            options.cir_skip_initial_repetitions;
        interference_quiet_num = 1500000;
        fine_window_min_samples = 2.9e5;
        profile_tag = 'dw1000';
    case 'QM35'
        phy_profile = 'QM35';
        options.preamble_repetitions = 64;
        options.code_index = 9;
        % QM35 uses IEEE 802.15.4z SFD #2. PLL compensation owns SYNC
        % 1..10; save per-repetition CIR from SYNC 11 onward.
        options.sfd_mode = '4z2';
        options.cir_skip_initial_repetitions = ...
            pll_phase_compensation_repetitions;
        options.cir_repetitions = options.preamble_repetitions - ...
            options.cir_skip_initial_repetitions;
        interference_quiet_num = 262144;
        fine_window_min_samples = 2.0e5;
        profile_tag = 'qm35';
    otherwise
        error('phy_profile must be ''DW1000'' or ''QM35''.');
end

% Avoid redundant suffix when the capture filename already encodes the
% profile (e.g. qm35_1.dat decoded as QM35 -> qm35_1/, not qm35_1_qm35/).
[~, capture_stem] = fileparts(options.file_name);
capture_lower = lower(capture_stem);
if contains(capture_lower, 'qm35') && strcmpi(phy_profile, 'QM35')
    profile_suffix = '';
elseif contains(capture_lower, 'dw1000') && strcmpi(phy_profile, 'DW1000')
    profile_suffix = '';
else
    profile_suffix = ['_' profile_tag];
end

%% -------------------- Interference cancellation --------------------
options.enable_interference_cancellation = true;
options.interference_quiet_offset = 400000;
options.interference_quiet_num = interference_quiet_num;
options.interference_tone_bin = -169;
options.interference_period_samples = 512;
% Leave empty to estimate once from the quiet interval, then reuse.
options.interference_coefficient = [];
options.show_plots = false;

%% -------------------- Stage 1: strided energy scan --------------------
batch = struct();
% The reader skips complete IQ records in the file, so this reduces both
% conversion work and the amount of capture data returned to MATLAB.
batch.energy_chunk_samples = 20e6;
batch.energy_step_samples = 19e6;
batch.energy_read_stride = 100;
% Moving-average length and region controls use original RX sample units.
batch.energy_smooth_rx_samples = 8192;
% Estimate the quiet floor from the lowest-energy 30% so dense packet
% traffic does not push the background estimate into the signal population.
batch.energy_baseline_fraction = 0.30;
% Hysteresis thresholds: quiet-floor median + k * robust sigma.
batch.energy_threshold_sigma_high = 6;
batch.energy_threshold_sigma_low = 3;
batch.energy_min_region_samples = 3e4;
batch.energy_region_pre_guard_samples = 5e4;
batch.energy_region_post_guard_samples = 5e4;
batch.energy_region_merge_samples = 1e4;

%% -------------------- Stage 2: correlation refinement --------------------
batch.correlation_decimation = 32;
batch.correlation_repetitions = 8;
batch.correlation_chunk_samples = 4e6;
batch.correlation_overlap_samples = 3e5;
batch.corr_threshold_sigma = 5;
batch.correlation_peak_min_distance_samples = 400;
batch.correlation_cluster_gap_samples = 4000;
batch.correlation_min_cluster_peaks = 4;
batch.candidate_merge_samples = 5e4;

%% -------------------- Stage 3: full-rate decode --------------------
% Start the full decoder before the refined preamble estimate.
batch.pre_packet_guard_samples = 5e4;
batch.window_samples = 0.8e6;
% Profile-specific lower bounds retain the measured complete frame plus
% the pre-packet guard without resampling an unnecessarily long tail.
batch.min_window_samples = fine_window_min_samples;
% Exact packet_intervals have no guard. blank_intervals use these margins
% and can be passed directly to options.blank_intervals in other decoders.
batch.localization_pre_guard_samples = 2048;
batch.localization_post_guard_samples = 4096;
batch.start_tolerance_samples = 4096;
batch.require_fcs_pass = false;
% all_frames_cir.mat already contains every frame and CIR. Avoid thousands
% of small HDF5 files unless a downstream workflow explicitly needs them.
batch.save_individual_cir = false;

%% -------------------- Output paths --------------------
batch.output_directory = fullfile(pwd, 'decoded_results', ...
    [capture_stem profile_suffix]);
if sic_managed_run
    batch.output_directory = sic_stage_config.result_directory;
end
batch.mat_file = fullfile(batch.output_directory, 'all_frames_cir.mat');
batch.summary_csv = fullfile(batch.output_directory, 'frame_summary.csv');
batch.timeline_png = fullfile(batch.output_directory, 'packet_timeline.png');

%% -------------------- Run one full-file decode --------------------
results = decode_uwb_all(options, batch);

%% -------------------- Console summary (compact, single line) --------------------
fprintf('[%s] %s | %d pkts (%d FCS-ok) | %.1f ms | %.1f/%.1f/%.1f s\n', ...
    phy_profile, options.file_name, results.packet_count, ...
    results.fcs_pass_count, results.duration_s*1e3, ...
    results.energy_seconds, results.correlation_seconds, ...
    results.fine_seconds);
