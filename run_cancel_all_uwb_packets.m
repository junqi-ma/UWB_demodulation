%% Cancel every reliably decoded DW1000 or QM35 packet in a capture.
% Reuses the full-file scan produced by decode_uwb_all, reconstructs
% every FCS-valid frame, applies stable-SYNC CFO/global-gain fitting plus
% field-specific PHR/Payload complex fitting, and patches one output copy.
% When called by sic_pipeline/uwbSicPipeline.m, sic_stage_config carries
% explicit stage paths. Direct interactive use keeps the original defaults.
sic_managed_run = exist('sic_stage_config', 'var') == 1;
if ~sic_managed_run
    clear;
    sic_managed_run = false;
end
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% 0. User configuration
% Keep phy_profile consistent with run_decode_uwb_all.m.
phy_profile = 'QM35';  % 'DW1000' or 'QM35'
input_file = 'F:\UWB基带数据\qm35_dw1000_new_1.dat';
fitting_file = input_file;
output_base_file = input_file;
final_cancellation_mode = 'optimal_complex';

% Compensate the repeatable nonlinear phase transient at packet start.
% The default template uses 32 phase bins per SYNC repetition, learned by
% analyze_uwb_pll_phase_drift.m after removing each packet's constant phase
% and stable CFO. Keep the correction limited to the early preamble so
% SFD/PHR/Payload are unchanged.
enable_pll_phase_compensation = true;
pll_phase_template_file = '';
maximum_pll_phase_apply_repetitions = 10;
pll_phase_apply_repetitions = maximum_pll_phase_apply_repetitions;

% Estimate slower packet-specific phase wander from the saved repetition
% CIR. The profile default enables it for both QM35 and DW1000.
enable_cir_slow_phase_compensation = [];
cir_slow_phase_options = struct( ...
    'tap_half_width', 2, ...
    'smoothing_lambda', 0.10, ...
    'minimum_subspace_coherence', 0.85, ...
    'minimum_correction_rms_deg', 0.20, ...
    'minimum_explained_fraction', 0.10, ...
    'maximum_abs_correction_deg', 15.0, ...
    'maximum_abs_second_stage_cfo_hz', 2e3);

% Estimate residual sampling-frequency offset from delay drift across the
% complete reconstructed packet, then apply one continuous affine time
% warp. The intercept refines the fixed alignment; the slope is SFO.
enable_full_packet_sfo_correction = true;
full_packet_sfo_options = struct( ...
    'window_duration_us', 8.0, ...
    'maximum_abs_window_delay_samples', 0.50, ...
    'coarse_delay_step_samples', 0.025, ...
    'fine_delay_step_samples', 0.0025, ...
    'minimum_window_correlation', 0.90, ...
    'minimum_valid_windows', 6, ...
    'minimum_relative_model_rms', 0.02, ...
    'strong_model_fraction', 0.10, ...
    'minimum_strong_samples', 64, ...
    'minimum_total_drift_samples', 0.02, ...
    'maximum_abs_sfo_ppm', 20.0, ...
    'maximum_fit_residual_samples', 0.08, ...
    'minimum_explained_fraction', 0.50);
if sic_managed_run
    phy_profile = sic_stage_config.phy_profile;
    input_file = sic_stage_config.input_file;
    fitting_file = sic_stage_config.input_file;
    output_base_file = sic_stage_config.output_base_file;
    final_cancellation_mode = sic_stage_config.cancellation_mode;
    if isfield(sic_stage_config, 'enable_pll_phase_compensation')
        enable_pll_phase_compensation = ...
            sic_stage_config.enable_pll_phase_compensation;
    end
    if isfield(sic_stage_config, 'pll_phase_template_file')
        pll_phase_template_file = ...
            sic_stage_config.pll_phase_template_file;
    end
    if isfield(sic_stage_config, 'pll_phase_apply_repetitions')
        pll_phase_apply_repetitions = ...
            sic_stage_config.pll_phase_apply_repetitions;
    end
    if isfield(sic_stage_config, ...
            'enable_cir_slow_phase_compensation')
        enable_cir_slow_phase_compensation = ...
            sic_stage_config.enable_cir_slow_phase_compensation;
    end
    if isfield(sic_stage_config, 'cir_slow_phase_options')
        cir_slow_phase_options = sic_stage_config.cir_slow_phase_options;
    end
    if isfield(sic_stage_config, 'enable_full_packet_sfo_correction')
        enable_full_packet_sfo_correction = ...
            sic_stage_config.enable_full_packet_sfo_correction;
    end
    if isfield(sic_stage_config, 'full_packet_sfo_options')
        full_packet_sfo_options = ...
            sic_stage_config.full_packet_sfo_options;
    end
end
pll_phase_apply_repetitions = min(pll_phase_apply_repetitions, ...
    maximum_pll_phase_apply_repetitions);

switch upper(phy_profile)
    case 'DW1000'
        phy_profile = 'DW1000';
        profile_tag = 'dw1000';
        expected_code_index = 11;
        expected_preamble_repetitions = 128;
        expected_sfd_mode = 'decawave';
        tx_phy_mode = '802.15.4a';
        tx_ranging = true;
        tx_sfd_number = 0;
        tx_sfd_sequence = [-1; -1; -1; -1; 1; -1; 0; 0];
        default_pll_template_result = 'dw1000_new_3';
    case 'QM35'
        phy_profile = 'QM35';
        profile_tag = 'qm35';
        expected_code_index = 9;
        expected_preamble_repetitions = 64;
        expected_sfd_mode = '4z2';
        tx_phy_mode = 'BPRF';
        tx_ranging = false;
        tx_sfd_number = 2;
        tx_sfd_sequence = [];
        default_pll_template_result = 'qm35_new_3';
    otherwise
        error('phy_profile must be ''DW1000'' or ''QM35''.');
end

if isempty(enable_cir_slow_phase_compensation)
    enable_cir_slow_phase_compensation = true;
end

if isempty(pll_phase_template_file)
    pll_phase_template_file = fullfile(project_dir, 'decoded_results', ...
        'pll_phase_drift_analysis', default_pll_template_result, ...
        'subsync_phase_template.csv');
end

% Avoid redundant suffix when the capture filename already encodes the
% profile (e.g. qm35_1.dat decoded as QM35 -> qm35_1/, not qm35_1_qm35/).
[~, capture_stem] = fileparts(input_file);
capture_lower = lower(capture_stem);
if contains(capture_lower, 'qm35') && strcmpi(phy_profile, 'QM35')
    profile_suffix = '';
elseif contains(capture_lower, 'dw1000') && strcmpi(phy_profile, 'DW1000')
    profile_suffix = '';
else
    profile_suffix = ['_' profile_tag];
end

% -------------------------------------------------------------------------
% Auto-generated paths. Do not edit below unless your decode output layout
% differs from the decode_uwb_all defaults.
% All outputs (scan + cancelled capture + reports) live under
% decoded_results/<capture_stem><profile_suffix>/.
% -------------------------------------------------------------------------
result_stem = [capture_stem profile_suffix];
packet_result_dir = fullfile(project_dir, 'decoded_results', result_stem);
if sic_managed_run
    packet_result_dir = sic_stage_config.result_directory;
end
packet_summary_file = fullfile(packet_result_dir, 'frame_summary.csv');
scan_file = fullfile(packet_result_dir, 'all_frames_cir.mat');
if enable_pll_phase_compensation
    cancelled_tag = sprintf( ...
        'cancelled_%s_pll_subsync', final_cancellation_mode);
else
    cancelled_tag = sprintf('cancelled_%s', final_cancellation_mode);
end
if enable_cir_slow_phase_compensation
    cancelled_tag = [cancelled_tag '_cirslow'];
end
output_file = fullfile(packet_result_dir, [cancelled_tag '.dat']);
metadata_file = fullfile(packet_result_dir, [cancelled_tag '_metadata.mat']);
summary_file = fullfile(packet_result_dir, [cancelled_tag '_summary.csv']);
if sic_managed_run
    output_file = sic_stage_config.output_file;
    metadata_file = sic_stage_config.metadata_file;
    summary_file = sic_stage_config.summary_file;
end
[summary_directory, summary_stem] = fileparts(summary_file);
field_summary_file = fullfile(summary_directory, ...
    [summary_stem '_fields.csv']);

max_psdu_bytes = 128;
require_fcs_pass = true;
fixed_phr_payload_scale = 0.88;

% Reconstruction uses the PHY settings stored by the decoder in
% results.params, so cancellation cannot silently disagree with the scan.
cfo_fit_first_sync = 25;
gain_fit_first_sync = 25;
alignment_search_samples = 128;
alignment_template_syncs = 32;

% Fractional-alignment knobs (shared across profiles).
fractional_alignment_max_samples = 0.75;
fractional_alignment_coarse_step = 0.10;
fractional_alignment_fine_step = 0.003;
fractional_alignment_min_improvement = 5e-4;

% Reject unsafe fits instead of modifying the output.
min_alignment_correlation = 0.70;
min_frame_suppression_db = 0.20;
max_abs_cfo_hz = 100e3;

%% 1. Load and validate the existing full-file scan
if ~isfile(input_file)
    error('run_cancel_all_uwb_packets:InputNotFound', ...
        'Input capture does not exist: %s', input_file);
end
if ~isfile(scan_file)
    error('run_cancel_all_uwb_packets:ScanNotFound', ...
        'Packet/CIR result does not exist: %s', scan_file);
end
if ~isfile(packet_summary_file)
    error('run_cancel_all_uwb_packets:SummaryNotFound', ...
        'Packet summary does not exist: %s', packet_summary_file);
end

saved_scan = load(scan_file, 'results');
if ~isfield(saved_scan, 'results') || ...
        ~isfield(saved_scan.results, 'frames')
    error('run_cancel_all_uwb_packets:InvalidScan', ...
        'The scan MAT file does not contain results.frames.');
end
results = saved_scan.results;
frames = results.frames;
params = results.params;
params.file_name = input_file;
params.max_psdu_bytes = max_psdu_bytes;

required_params = {'code_index', 'preamble_repetitions'};
missing_params = required_params(~isfield(params, required_params));
if ~isempty(missing_params)
    error('run_cancel_all_uwb_packets:MissingDecodeParameters', ...
        'Decode results.params is missing: %s', ...
        strjoin(missing_params, ', '));
end
if params.code_index ~= expected_code_index || ...
        params.preamble_repetitions ~= expected_preamble_repetitions
    error('run_cancel_all_uwb_packets:DecodeProfileMismatch', ...
        ['Selected %s, but decode results use code %d / %d SYNC. ', ...
        'Rerun run_decode_uwb_all.m with the same phy_profile.'], ...
        phy_profile, params.code_index, params.preamble_repetitions);
end
if ~isfield(params, 'sfd_mode') || ...
        ~strcmpi(params.sfd_mode, expected_sfd_mode)
    error('run_cancel_all_uwb_packets:SfdProfileMismatch', ...
        ['Selected %s requires sfd_mode=''%s''. Rerun the decoder ', ...
        'to regenerate matching frame and CIR information.'], ...
        phy_profile, expected_sfd_mode);
end
cfo_fit_last_sync = params.preamble_repetitions;
gain_fit_last_sync = params.preamble_repetitions;
pll_phase_compensation = loadPllPhaseCompensation( ...
    enable_pll_phase_compensation, pll_phase_template_file, ...
    pll_phase_apply_repetitions, params.preamble_repetitions);

% frame_summary.csv is the authoritative source of packet start times.
% Match rows to MAT records by packet index; the MAT file supplies payload
% bytes, CIR, and other reconstruction metadata.
packet_summary = readtable(packet_summary_file);
required_columns = {'index', 'abs_start_sample', 'time_start_ms', ...
    'phr_secded_pass', 'psdu_length_bytes', 'fcs_pass'};
missing_columns = setdiff(required_columns, ...
    packet_summary.Properties.VariableNames);
if ~isempty(missing_columns)
    error('run_cancel_all_uwb_packets:MissingSummaryColumns', ...
        'frame_summary.csv is missing: %s', ...
        strjoin(missing_columns, ', '));
end

if isfield(results, 'sample_index_base') && ...
        results.sample_index_base ~= 0
    error('run_cancel_all_uwb_packets:UnsupportedIndexBase', ...
        ['Packet starts must be zero-based capture sample offsets; ', ...
        'the result declares sample_index_base=%g.'], ...
        results.sample_index_base);
end

frame_indices = [frames.index].';
[matched, summary_rows] = ismember(frame_indices, packet_summary.index);
if ~all(matched)
    error('run_cancel_all_uwb_packets:UnmatchedPacketIndex', ...
        '%d MAT packet(s) have no matching CSV summary row.', ...
        nnz(~matched));
end
if numel(unique(packet_summary.index)) ~= height(packet_summary)
    error('run_cancel_all_uwb_packets:DuplicatePacketIndex', ...
        'frame_summary.csv contains duplicate packet indices.');
end

summary_start_samples = ...
    round(packet_summary.abs_start_sample(summary_rows));
summary_start_ms = packet_summary.time_start_ms(summary_rows);
time_derived_samples = round(summary_start_ms * 1e-3 * params.fs_rx);
time_sample_error = time_derived_samples - summary_start_samples;
if any(abs(time_sample_error) > 1)
    error('run_cancel_all_uwb_packets:StartTimeMismatch', ...
        ['CSV time_start_ms and abs_start_sample disagree by up to ', ...
        '%d samples.'], max(abs(time_sample_error)));
end

for k = 1:numel(frames)
    frames(k).abs_start_sample = summary_start_samples(k);
    frames(k).time_start_s = summary_start_ms(k) * 1e-3;
end

if isempty(frames)
    error('run_cancel_all_uwb_packets:NoFrames', ...
        'The scan contains no decoded frames.');
end

phr_ok = [frames.phr_secded_pass];
fcs_ok = [frames.fcs_pass];
psdu_length = [frames.psdu_length_bytes];
has_payload = arrayfun(@(x) ~isempty(x.payload_bytes), frames);
selected = phr_ok & has_payload & psdu_length <= max_psdu_bytes;
if require_fcs_pass
    selected = selected & fcs_ok;
end
frames = frames(selected);
[~, order] = sort([frames.abs_start_sample]);
frames = frames(order);

if enable_cir_slow_phase_compensation && ...
        pll_phase_compensation.enabled
    expected_cir_first_repetition = ...
        pll_phase_compensation.apply_repetitions + 1;
    for k = 1:numel(frames)
        has_cir_start = isfield(frames(k).cir, 'first_repetition') && ...
            ~isempty(frames(k).cir.first_repetition);
        if ~has_cir_start || ...
                round(double(frames(k).cir.first_repetition)) ~= ...
                expected_cir_first_repetition
            error('run_cancel_all_uwb_packets:CirPllWindowMismatch', ...
                ['Packet %d CIR must start at SYNC %d, immediately ', ...
                'after PLL compensation. Rerun run_decode_uwb_all.m ', ...
                'to refresh all_frames_cir.mat.'], ...
                frames(k).index, expected_cir_first_repetition);
        end
    end
end

fprintf('\n=== All-%s cancellation ===\n', phy_profile);
fprintf('Packet directory   : %s\n', packet_result_dir);
fprintf('Start-time source  : %s\n', packet_summary_file);
fprintf('Reconstruction PHY : %s / SFD #%d\n', ...
    tx_phy_mode, tx_sfd_number);
fprintf('Scan frames        : %d\n', results.packet_count);
fprintf('FCS-pass frames    : %d\n', results.fcs_pass_count);
fprintf('Selected frames    : %d\n', numel(frames));
fprintf('Cancellation mode  : %s\n', final_cancellation_mode);
fprintf('Fitting input      : %s\n', fitting_file);
fprintf('Output base        : %s\n', output_base_file);
fprintf('Input grid         : preprocessed 998.4 MHz complex baseband\n');
fprintf('PLL compensation   : %d\n', pll_phase_compensation.enabled);
if pll_phase_compensation.enabled
    fprintf('PLL template       : %s\n', ...
        pll_phase_compensation.template_file);
    fprintf('PLL template grid  : %s | %d bins/SYNC\n', ...
        pll_phase_compensation.resolution, ...
        pll_phase_compensation.bins_per_repetition);
    fprintf('PLL corrected SYNC : 1..%d | first %+.2f deg | peak %.2f deg\n', ...
        pll_phase_compensation.apply_repetitions, ...
        pll_phase_compensation.first_phase_deg, ...
        pll_phase_compensation.peak_abs_phase_deg);
end
fprintf('CIR slow phase     : %d\n', ...
    enable_cir_slow_phase_compensation);
if enable_cir_slow_phase_compensation
    fprintf('CIR slow smoother  : lambda %.3f | max %.1f deg\n', ...
        cir_slow_phase_options.smoothing_lambda, ...
        cir_slow_phase_options.maximum_abs_correction_deg);
end
fprintf('Full-packet SFO    : %d\n', ...
    enable_full_packet_sfo_correction);
if enable_full_packet_sfo_correction
    fprintf('SFO windows        : %.1f us | max %.1f ppm\n', ...
        full_packet_sfo_options.window_duration_us, ...
        full_packet_sfo_options.maximum_abs_sfo_ppm);
end

%% 2. Create the full output capture once
if strcmpi(output_base_file, output_file)
    error('run_cancel_all_uwb_packets:SameInputOutput', ...
        'Output base and output files must be different.');
end
if ~isfile(output_base_file)
    error('run_cancel_all_uwb_packets:OutputBaseNotFound', ...
        'Output-base capture does not exist: %s', output_base_file);
end
output_dir = fileparts(output_file);
if ~isfolder(output_dir)
    mkdir(output_dir);
end

fprintf('Copying complete capture to:\n  %s\n', output_file);
[copy_ok, copy_message] = copyfile(output_base_file, output_file, 'f');
if ~copy_ok
    error('run_cancel_all_uwb_packets:CopyFailed', ...
        'Cannot create output capture: %s', copy_message);
end

c = uwbdecoder.constants();
input_info = dir(fitting_file);
base_info = dir(output_base_file);
if input_info.bytes ~= base_info.bytes
    error('run_cancel_all_uwb_packets:InputLengthMismatch', ...
        'Fitting input and output base must have identical lengths.');
end
bytes_per_time_sample = c.BYTES_PER_IQ_SAMPLE * params.ant_num;
total_samples = input_info.bytes / bytes_per_time_sample;

%% 3. Reconstruct, fit, and subtract every selected packet
% The per-packet work is split into a compute-only stage and a serial
% file-patch stage. Reconstruction / alignment / CFO / gain fitting are
% the expensive, read-only steps, so they run in parfor across packets. The
% resulting residual patches are written back to the output capture
% afterwards, sequentially, because multiple workers cannot safely share a
% single open file.
fprintf('Parallel pool: starting (if not already open) ...\n');
if isempty(gcp('nocreate'))
    parpool('local');
end

report_prototype = emptyReport();
report_prototype.patch_raw = [];
report_prototype.patch_offset = 0;
report_prototype.patch_samples = 0;
reports = repmat(report_prototype, numel(frames), 1);
success_count = 0;

parfor k = 1:numel(frames)
    frame = frames(k);
    report = report_prototype;
    report.index = frame.index;
    report.abs_start_detected = frame.abs_start_sample;
    try
        [report, patch_raw, patch_offset, patch_samples] = ...
            computeOnePacketPatch(fitting_file, frame, params, ...
            total_samples, c, final_cancellation_mode, ...
            fixed_phr_payload_scale, ...
            cfo_fit_first_sync, cfo_fit_last_sync, ...
            gain_fit_first_sync, gain_fit_last_sync, ...
            alignment_search_samples, ...
            alignment_template_syncs, ...
            fractional_alignment_max_samples, ...
            fractional_alignment_coarse_step, ...
            fractional_alignment_fine_step, ...
            fractional_alignment_min_improvement, ...
            min_alignment_correlation, min_frame_suppression_db, ...
            max_abs_cfo_hz, ...
            params.code_index, params.preamble_repetitions, ...
            tx_phy_mode, tx_ranging, tx_sfd_number, tx_sfd_sequence, ...
            pll_phase_compensation, ...
            enable_cir_slow_phase_compensation, ...
            cir_slow_phase_options, ...
            enable_full_packet_sfo_correction, ...
            full_packet_sfo_options);
        report.patch_raw = patch_raw;
        report.patch_offset = patch_offset;
        report.patch_samples = patch_samples;
    catch ME
        report.success = false;
        report.message = ME.message;
    end
    reports(k) = report;
end

fprintf('Applying %d computed patches to the output file (serial I/O).\n', ...
    numel(frames));
for k = 1:numel(frames)
    report = reports(k);
    if report.success
        applyPatchToFile( ...
            fitting_file, output_file, report, params.ant_num, c);
    end
    fprintf('[%4d/%4d] abs_start=%d: ', ...
        k, numel(frames), report.abs_start_detected);
    if report.success
        fprintf(['OK, corr %.3f -> %.3f, frac %+.3f samp, ', ...
            'CFO %+.3f kHz, %.2f dB'], ...
            report.integer_alignment_correlation, ...
            report.alignment_correlation, ...
            report.fractional_delay_samples, ...
            report.fitted_cfo_hz / 1e3, ...
            report.frame_suppression_db);
        if report.pll_compensation_applied
            fprintf(' (PLL %+.2f dB)', report.pll_improvement_db);
        end
        if report.cir_slow_phase_applied
            fprintf(' (CIR slow %+.2f dB', ...
                report.cir_slow_phase_improvement_db);
            if report.cir_second_stage_cfo_applied
                fprintf(', CFO2 %+.3f kHz', ...
                    report.cir_second_stage_cfo_hz / 1e3);
            end
            fprintf(')');
        end
        if report.full_packet_sfo_applied
            fprintf(' (SFO %+.2f ppm, %+.2f dB)', ...
                report.full_packet_sfo_ppm, ...
                report.sfo_improvement_db);
        end
        fprintf('\n');
        success_count = success_count + 1;
    else
        fprintf('SKIPPED: %s\n', report.message);
    end
end

% Discard the bulky raw patches now that they have been written to disk.
if isfield(reports, 'patch_raw')
    reports = rmfield(reports, {'patch_raw', 'patch_offset', 'patch_samples'});
end

%% 4. Save final report and verify output length
report_table = struct2table(reports);
writetable(report_table, summary_file);
field_summary_table = makeFieldSummaryTable(report_table);
writetable(field_summary_table, field_summary_file);
save(metadata_file, 'reports', 'success_count', 'frames', 'params', ...
    'input_file', 'fitting_file', 'output_base_file', 'output_file', ...
    'scan_file', 'packet_summary_file', 'final_cancellation_mode', ...
    'pll_phase_compensation', ...
    'enable_cir_slow_phase_compensation', ...
    'cir_slow_phase_options', ...
    'enable_full_packet_sfo_correction', ...
    'full_packet_sfo_options', 'field_summary_file', ...
    'field_summary_table', '-v7.3');

output_info = dir(output_file);
if output_info.bytes ~= base_info.bytes
    error('run_cancel_all_uwb_packets:OutputLengthMismatch', ...
        'Output has %d bytes; expected %d.', ...
        output_info.bytes, base_info.bytes);
end

fprintf('\n=== Final summary ===\n');
fprintf('Selected packets : %d\n', numel(frames));
fprintf('Decode PHY       : code %d / %d SYNC\n', ...
    params.code_index, params.preamble_repetitions);
fprintf('Cancelled packets: %d\n', success_count);
fprintf('Skipped packets  : %d\n', numel(frames) - success_count);
fprintf('Output bytes     : %d\n', output_info.bytes);
fprintf('Output file      : %s\n', output_file);
fprintf('Summary CSV      : %s\n', summary_file);
fprintf('Field summary CSV: %s\n', field_summary_file);
if pll_phase_compensation.enabled && success_count > 0
    pll_improvements = [reports([reports.success]).pll_improvement_db];
    fprintf('PLL median gain  : %+.3f dB\n', ...
        median(pll_improvements, 'omitnan'));
    fprintf('PLL improved pkts: %.1f %%\n', ...
        100 * mean(pll_improvements > 0, 'omitnan'));
end
if enable_cir_slow_phase_compensation && success_count > 0
    cir_applied = [reports.success] & ...
        [reports.cir_slow_phase_applied];
    cir_improvements = ...
        [reports(cir_applied).cir_slow_phase_improvement_db];
    fprintf('CIR slow applied : %d / %d\n', ...
        nnz(cir_applied), success_count);
    if ~isempty(cir_improvements)
        fprintf('CIR slow med gain: %+.3f dB\n', ...
            median(cir_improvements, 'omitnan'));
        fprintf('CIR slow positive: %.1f %%\n', ...
            100 * mean(cir_improvements > 0, 'omitnan'));
    end
    cfo2_applied = [reports.success] & ...
        [reports.cir_second_stage_cfo_applied];
    if any(cfo2_applied)
        cfo2_values = [reports(cfo2_applied).cir_second_stage_cfo_hz];
        fprintf('CIR CFO2 median  : %+.3f kHz\n', ...
            median(cfo2_values, 'omitnan') / 1e3);
    end
end
if enable_full_packet_sfo_correction && success_count > 0
    sfo_applied = [reports.success] & ...
        [reports.full_packet_sfo_applied];
    fprintf('SFO applied      : %d / %d\n', ...
        nnz(sfo_applied), success_count);
    if any(sfo_applied)
        sfo_values = [reports(sfo_applied).full_packet_sfo_ppm];
        sfo_gains = [reports(sfo_applied).sfo_improvement_db];
        fprintf('SFO median       : %+.3f ppm\n', ...
            median(sfo_values, 'omitnan'));
        fprintf('SFO median gain  : %+.3f dB\n', ...
            median(sfo_gains, 'omitnan'));
        fprintf('SFO positive     : %.1f %%\n', ...
            100 * mean(sfo_gains > 0, 'omitnan'));
    end
end

%% ------------------------------------------------------------------------
function [report, patchRaw, patchOffset, patchSamples] = ...
        computeOnePacketPatch(fittingFile, frame, params, totalSamples, ...
        c, cancellationMode, fixedScale, cfoFirst, cfoLast, gainFirst, ...
        gainLast, searchRadius, templateSyncs, fractionalMaxSamples, ...
        fractionalCoarseStep, fractionalFineStep, ...
        fractionalMinImprovement, minCorrelation, minSuppressionDb, ...
        maxAbsCfoHz, codeIndex, preambleRepetitions, phyMode, ranging, ...
        sfdNumber, sfdSequence, pllCompensation, ...
        enableCirSlowPhase, cirSlowPhaseOptions, ...
        enableFullPacketSfo, fullPacketSfoOptions)
% Compute the residual patch for one packet without writing to disk.
% Returns the report plus the raw patch (int16 IQ rows), the capture
% sample offset where it starts, and its length in samples. The caller is
% responsible for applying the patch to the output file (serially).

decoded = struct();
decoded.payload = struct('bytes', uint8(frame.payload_bytes(:)), ...
    'fcs_pass', logical(frame.fcs_pass));
decoded.sfd = struct('name', frame.sfd_name);
decoded.cir = frame.cir;

tx_options = struct( ...
    'fs_tx', params.fs_rx, ...
    'phy_mode', phyMode, ...
    'ranging', ranging, ...
    'preamble_repetitions', preambleRepetitions, ...
    'code_index', codeIndex, ...
    'sfd_number', sfdNumber, ...
    'sfd_sequence', sfdSequence, ...
    'peak_amplitude', 1, ...
    'guard_samples', 0, ...
    'require_fcs_pass', true);
tx = generate_uwb_tx_from_decode(decoded, tx_options);
channel = apply_estimated_cir_to_uwb(tx, decoded.cir);
replica = channel.waveform_x410(:);

nominal_start = frame.abs_start_sample;
read_first = max(0, nominal_start - searchRadius);
read_last = min(totalSamples - 1, ...
    nominal_start + numel(replica) - 1 + searchRadius);
[raw, received] = readIqSegment(fittingFile, read_first, ...
    read_last - read_first + 1, params.ant_num, params.channel_index);

% The input has already had its front-end preprocessing applied. Fit the
% reconstructed packet directly against the stored complex-baseband data.
fit_received = received;

period_rx = c.PREAMBLE_PERIOD_S * params.fs_rx;
nominal_local = nominal_start - read_first + 1;
[start_local, alignment_correlation] = alignReplica( ...
    fit_received, replica, nominal_local, period_rx, searchRadius, ...
    gainFirst, templateSyncs);
integer_alignment_correlation = alignment_correlation;

available = min(numel(replica), numel(received) - start_local + 1);
if available < round(params.preamble_repetitions * period_rx)
    error('The complete preamble is not available in the fitting window.');
end
replica = replica(1:available);
observed = fit_received(start_local:start_local + available - 1);

% Estimate CFO once at the integer-aligned position, then use the
% CFO-corrected replica to refine the remaining sub-sample delay. Finally,
% shift the no-CFO replica and re-estimate CFO so timing and phase slope are
% mutually consistent.
initial_cfo_hz = fitReplicaCfo( ...
    observed, replica, period_rx, cfoFirst, cfoLast, params.fs_rx);
if abs(initial_cfo_hz) > maxAbsCfoHz
    error('Fitted CFO %+.3f kHz exceeds the safety limit.', ...
        initial_cfo_hz / 1e3);
end
n = (0:available - 1).';
replica_cfo_initial = replica .* ...
    exp(1j * 2 * pi * initial_cfo_hz * n / params.fs_rx);
[fractional_delay_samples, alignment_correlation] = ...
    refineFractionalAlignment(observed, replica_cfo_initial, period_rx, ...
        gainFirst, templateSyncs, fractionalMaxSamples, ...
        fractionalCoarseStep, fractionalFineStep, ...
        fractionalMinImprovement);
replica = applyFractionalShift(replica, fractional_delay_samples);

fitted_cfo_hz = fitReplicaCfo( ...
    observed, replica, period_rx, cfoFirst, cfoLast, params.fs_rx);
if abs(fitted_cfo_hz) > maxAbsCfoHz
    error('Fitted CFO %+.3f kHz exceeds the safety limit.', ...
        fitted_cfo_hz / 1e3);
end
replica_cfo_without_pll = replica .* ...
    exp(1j * 2 * pi * fitted_cfo_hz * n / params.fs_rx);
replica_cfo_without_cir_slow = applyPllPhaseCompensation( ...
    replica_cfo_without_pll, period_rx, pllCompensation);
cir_slow_phase_by_repetition_rad = zeros( ...
    params.preamble_repetitions, 1);
cir_slow_diagnostics = emptyCirSlowDiagnostics();
if enableCirSlowPhase
    if pllCompensation.enabled
        expectedCirFirstRepetition = ...
            pllCompensation.apply_repetitions + 1;
        if ~isfield(frame.cir, 'first_repetition') || ...
                isempty(frame.cir.first_repetition) || ...
                round(double(frame.cir.first_repetition)) ~= ...
                expectedCirFirstRepetition
            error(['CIR repetition phase must start at SYNC %d, ', ...
                'immediately after PLL compensation. Rerun ', ...
                'run_decode_uwb_all.m to refresh all_frames_cir.mat.'], ...
                expectedCirFirstRepetition);
        end
    end
    [cir_slow_phase_by_repetition_rad, cir_slow_diagnostics] = ...
        estimate_uwb_cir_slow_phase(frame.cir, ...
        params.preamble_repetitions, cirSlowPhaseOptions);
end
cir_phase_compensation_applied = cir_slow_diagnostics.applied || ...
    cir_slow_diagnostics.second_stage_cfo_applied;
replica_cfo_with_second_stage = applyCirSecondStageCfo( ...
    replica_cfo_without_cir_slow, period_rx, cir_slow_diagnostics);
replica_cfo = applyRepetitionPhaseCurve( ...
    replica_cfo_with_second_stage, period_rx, ...
    cir_slow_phase_by_repetition_rad);
replica_cfo_without_sfo = replica_cfo;
full_packet_sfo_diagnostics = estimate_uwb_full_packet_sfo( ...
    [], [], params.fs_rx, fullPacketSfoOptions);
if enableFullPacketSfo
    full_packet_sfo_diagnostics = estimate_uwb_full_packet_sfo( ...
        observed, replica_cfo, params.fs_rx, fullPacketSfoOptions);
end
if full_packet_sfo_diagnostics.applied
    replica_cfo = apply_uwb_full_packet_sfo( ...
        replica_cfo, full_packet_sfo_diagnostics);
    replica_cfo_without_cir_slow = apply_uwb_full_packet_sfo( ...
        replica_cfo_without_cir_slow, full_packet_sfo_diagnostics);
    replica_cfo_without_pll = apply_uwb_full_packet_sfo( ...
        replica_cfo_without_pll, full_packet_sfo_diagnostics);
end

if alignment_correlation < minCorrelation
    error(['Fractional alignment correlation %.3f is below %.3f ', ...
        '(integer alignment %.3f).'], alignment_correlation, ...
        minCorrelation, integer_alignment_correlation);
end

gain_first_sample = round((gainFirst - 1) * period_rx) + 1;
gain_last_sample = min(available, round(gainLast * period_rx));
gain_indices = gain_first_sample:gain_last_sample;
global_gain = (replica_cfo(gain_indices)' * observed(gain_indices)) / ...
    (replica_cfo(gain_indices)' * replica_cfo(gain_indices) + eps);
baseline_model = global_gain * replica_cfo;
global_gain_without_sfo = ...
    (replica_cfo_without_sfo(gain_indices)' * ...
    observed(gain_indices)) / ...
    (replica_cfo_without_sfo(gain_indices)' * ...
    replica_cfo_without_sfo(gain_indices) + eps);
baseline_model_without_sfo = ...
    global_gain_without_sfo * replica_cfo_without_sfo;

% Build PLL-only and fully uncorrected models in parallel. Every branch
% refits its complex gain, so the A/B metrics isolate nonlinear phase
% correction instead of a constant rotation.
global_gain_without_cir_slow = ...
    (replica_cfo_without_cir_slow(gain_indices)' * ...
    observed(gain_indices)) / ...
    (replica_cfo_without_cir_slow(gain_indices)' * ...
    replica_cfo_without_cir_slow(gain_indices) + eps);
baseline_model_without_cir_slow = ...
    global_gain_without_cir_slow * replica_cfo_without_cir_slow;
global_gain_without_pll = ...
    (replica_cfo_without_pll(gain_indices)' * observed(gain_indices)) / ...
    (replica_cfo_without_pll(gain_indices)' * ...
    replica_cfo_without_pll(gain_indices) + eps);
baseline_model_without_pll = ...
    global_gain_without_pll * replica_cfo_without_pll;

sync_indices = workFieldToRxIndices( ...
    tx.field_indices_work.SYNC, tx.sample_rate_work, ...
    params.fs_rx, available);
sfd_indices = workFieldToRxIndices( ...
    tx.field_indices_work.SFD, tx.sample_rate_work, ...
    params.fs_rx, available);
phr_indices = workFieldToRxIndices( ...
    tx.field_indices_work.PHR, tx.sample_rate_work, ...
    params.fs_rx, available);
payload_indices = workFieldToRxIndices( ...
    tx.field_indices_work.Payload, tx.sample_rate_work, ...
    params.fs_rx, available);
[selected_model, phr_gain, payload_gain] = selectFieldModel( ...
    baseline_model, observed, phr_indices, payload_indices, ...
    cancellationMode, fixedScale);
[selected_model_without_sfo, ~, ~] = selectFieldModel( ...
    baseline_model_without_sfo, observed, phr_indices, payload_indices, ...
    cancellationMode, fixedScale);
[selected_model_without_cir_slow, ~, ~] = selectFieldModel( ...
    baseline_model_without_cir_slow, observed, phr_indices, ...
    payload_indices, cancellationMode, fixedScale);
[selected_model_without_pll, ~, ~] = selectFieldModel( ...
    baseline_model_without_pll, observed, phr_indices, payload_indices, ...
    cancellationMode, fixedScale);

residual_fit = observed - selected_model;
frame_suppression_db = 10 * log10( ...
    mean(abs(observed).^2) / (mean(abs(residual_fit).^2) + eps));
residual_without_sfo = observed - selected_model_without_sfo;
frame_suppression_without_sfo_db = 10 * log10( ...
    mean(abs(observed).^2) / ...
    (mean(abs(residual_without_sfo).^2) + eps));
sfo_improvement_db = frame_suppression_db - ...
    frame_suppression_without_sfo_db;
residual_without_pll = observed - selected_model_without_pll;
frame_suppression_without_pll_db = 10 * log10( ...
    mean(abs(observed).^2) / ...
    (mean(abs(residual_without_pll).^2) + eps));
residual_without_cir_slow = observed - ...
    selected_model_without_cir_slow;
frame_suppression_without_cir_slow_db = 10 * log10( ...
    mean(abs(observed).^2) / ...
    (mean(abs(residual_without_cir_slow).^2) + eps));
pll_improvement_db = frame_suppression_without_cir_slow_db - ...
    frame_suppression_without_pll_db;
cir_slow_phase_improvement_db = frame_suppression_db - ...
    frame_suppression_without_cir_slow_db;

% Field-level A/B statistics use identical sample intervals for all four
% model branches. In addition to PHY fields, split SYNC into the fixed PLL
% window, any uncompensated gap, and the packet-specific CIR window.
sync_metrics = fieldSuppressionMetrics(observed, selected_model, ...
    selected_model_without_sfo, selected_model_without_cir_slow, ...
    selected_model_without_pll, sync_indices);
sfd_metrics = fieldSuppressionMetrics(observed, selected_model, ...
    selected_model_without_sfo, selected_model_without_cir_slow, ...
    selected_model_without_pll, sfd_indices);
phr_metrics = fieldSuppressionMetrics(observed, selected_model, ...
    selected_model_without_sfo, selected_model_without_cir_slow, ...
    selected_model_without_pll, phr_indices);
payload_metrics = fieldSuppressionMetrics(observed, selected_model, ...
    selected_model_without_sfo, selected_model_without_cir_slow, ...
    selected_model_without_pll, payload_indices);

pll_window_indices = syncRepetitionRangeIndices(1, ...
    pllCompensation.apply_repetitions, period_rx, available);
if cir_phase_compensation_applied
    cir_window_indices = syncRepetitionRangeIndices( ...
        cir_slow_diagnostics.first_repetition, ...
        cir_slow_diagnostics.last_repetition, period_rx, available);
    gap_window_indices = syncRepetitionRangeIndices( ...
        pllCompensation.apply_repetitions + 1, ...
        cir_slow_diagnostics.first_repetition - 1, ...
        period_rx, available);
else
    cir_window_indices = [];
    gap_window_indices = syncRepetitionRangeIndices( ...
        pllCompensation.apply_repetitions + 1, ...
        params.preamble_repetitions, period_rx, available);
end
pll_window_metrics = fieldSuppressionMetrics(observed, selected_model, ...
    selected_model_without_sfo, selected_model_without_cir_slow, ...
    selected_model_without_pll, pll_window_indices);
gap_window_metrics = fieldSuppressionMetrics(observed, selected_model, ...
    selected_model_without_sfo, selected_model_without_cir_slow, ...
    selected_model_without_pll, gap_window_indices);
cir_window_metrics = fieldSuppressionMetrics(observed, selected_model, ...
    selected_model_without_sfo, selected_model_without_cir_slow, ...
    selected_model_without_pll, cir_window_indices);
if frame_suppression_db < minSuppressionDb
    error('Frame suppression %.3f dB is below %.3f dB.', ...
        frame_suppression_db, minSuppressionDb);
end

before = received(start_local:start_local + available - 1);
after = before - selected_model;
received(start_local:start_local + available - 1) = after;
[patchRaw, clipped_count] = replaceIqChannel( ...
    raw, received, params.channel_index, c);
patchOffset = read_first;
patchSamples = read_last - read_first + 1;

report = emptyReport();
report.index = frame.index;
report.success = true;
report.abs_start_detected = nominal_start;
report.abs_start_fitted = read_first + start_local - 1;
report.samples_subtracted = available;
report.alignment_correlation = alignment_correlation;
report.integer_alignment_correlation = integer_alignment_correlation;
report.fractional_delay_samples = fractional_delay_samples;
report.fitted_cfo_hz = fitted_cfo_hz;
report.global_gain = global_gain;
report.phr_gain = phr_gain;
report.payload_gain = payload_gain;
report.frame_suppression_db = frame_suppression_db;
report.frame_suppression_without_sfo_db = ...
    frame_suppression_without_sfo_db;
report.sfo_improvement_db = sfo_improvement_db;
report.full_packet_sfo_applied = full_packet_sfo_diagnostics.applied;
report.full_packet_sfo_ppm = full_packet_sfo_diagnostics.sfo_ppm;
report.full_packet_sfo_delay_intercept_samples = ...
    full_packet_sfo_diagnostics.delay_intercept_samples;
report.full_packet_sfo_total_drift_samples = ...
    full_packet_sfo_diagnostics.total_drift_samples;
report.full_packet_sfo_valid_windows = ...
    full_packet_sfo_diagnostics.valid_window_count;
report.full_packet_sfo_fit_residual_samples = ...
    full_packet_sfo_diagnostics.fit_residual_rms_samples;
report.full_packet_sfo_explained_fraction = ...
    full_packet_sfo_diagnostics.explained_fraction;
report.frame_suppression_without_pll_db = ...
    frame_suppression_without_pll_db;
report.pll_improvement_db = pll_improvement_db;
report.pll_compensation_applied = pllCompensation.enabled;
report.frame_suppression_without_cir_slow_db = ...
    frame_suppression_without_cir_slow_db;
report.cir_slow_phase_improvement_db = ...
    cir_slow_phase_improvement_db;
report.cir_slow_phase_applied = cir_phase_compensation_applied;
report.cir_slow_phase_first_repetition = ...
    cir_slow_diagnostics.first_repetition;
report.cir_slow_phase_last_repetition = ...
    cir_slow_diagnostics.last_repetition;
report.cir_slow_phase_subspace_coherence = ...
    cir_slow_diagnostics.subspace_coherence;
report.cir_slow_phase_raw_rms_deg = ...
    cir_slow_diagnostics.raw_nonlinear_rms_deg;
report.cir_slow_phase_correction_rms_deg = ...
    cir_slow_diagnostics.correction_rms_deg;
report.cir_slow_phase_noise_rms_deg = ...
    cir_slow_diagnostics.noise_rms_deg;
report.cir_slow_phase_max_abs_deg = ...
    cir_slow_diagnostics.maximum_abs_correction_deg;
report.cir_slow_phase_explained_fraction = ...
    cir_slow_diagnostics.explained_fraction;
report.cir_second_stage_cfo_applied = ...
    cir_slow_diagnostics.second_stage_cfo_applied;
report.cir_second_stage_cfo_hz = ...
    cir_slow_diagnostics.second_stage_cfo_hz;
report = addFieldMetrics(report, 'sync', sync_metrics);
report = addFieldMetrics(report, 'sfd', sfd_metrics);
report = addFieldMetrics(report, 'phr', phr_metrics);
report = addFieldMetrics(report, 'payload', payload_metrics);
report = addFieldMetrics(report, 'sync_pll_window', pll_window_metrics);
report = addFieldMetrics(report, 'sync_gap_window', gap_window_metrics);
report = addFieldMetrics(report, 'sync_cir_window', cir_window_metrics);
report.clipped_component_count = clipped_count;
report.fcs_pass = frame.fcs_pass;
report.message = '';
end

function applyPatchToFile(inputFile, outputFile, report, antNum, c)
% Apply the modeled component as a delta against the current output.
% Reading the current output preserves an earlier cancellation when two
% packet patch windows overlap; writing report.patch_raw directly would
% restore the old samples in the overlap.
if ~report.success || isempty(report.patch_raw)
    return
end
[sourceRaw, ~] = readIqSegment(inputFile, report.patch_offset, ...
    report.patch_samples, antNum, 1);
[currentRaw, ~] = readIqSegment(outputFile, report.patch_offset, ...
    report.patch_samples, antNum, 1);
removedRaw = double(sourceRaw) - double(report.patch_raw);
mergedRaw = double(currentRaw) - removedRaw;
mergedRaw = int16(max(double(intmin('int16')), ...
    min(double(intmax('int16')), round(mergedRaw))));
writeIqSegment( ...
    outputFile, report.patch_offset, mergedRaw, antNum, c);
end

function [bestStart, bestCorrelation] = alignReplica( ...
        received, replica, nominalStart, periodRx, searchRadius, ...
        firstSync, templateSyncs)
template_first = round((firstSync - 1) * periodRx) + 1;
template_last = min(numel(replica), ...
    round((firstSync - 1 + templateSyncs) * periodRx));
template = replica(template_first:template_last);
candidate_starts = nominalStart + (-searchRadius:searchRadius);
scores = -inf(size(candidate_starts));
for k = 1:numel(candidate_starts)
    first = candidate_starts(k) + template_first - 1;
    last = first + numel(template) - 1;
    if first < 1 || last > numel(received)
        continue;
    end
    segment = received(first:last);
    scores(k) = abs(template' * segment) / ...
        (norm(template) * norm(segment) + eps);
end
[bestCorrelation, idx] = max(scores);
bestStart = candidate_starts(idx);
end

function [bestDelay, bestCorrelation] = refineFractionalAlignment( ...
        received, replica, periodRx, firstSync, templateSyncs, ...
        maxDelay, coarseStep, fineStep, minImprovement)
% Refine an integer packet start with a sub-sample delay. The convention is
% shifted(n) = replica(n - delay), so a negative delay advances the replica.
template_first = round((firstSync - 1) * periodRx) + 1;
template_last = min(numel(replica), ...
    round((firstSync - 1 + templateSyncs) * periodRx));
template_indices = (template_first:template_last).';
received_template = received(template_indices);

padding = ceil(maxDelay) + 3;
segment_first = max(1, template_first - padding);
segment_last = min(numel(replica), template_last + padding);
segment_axis = (segment_first:segment_last).';
interpolator = griddedInterpolant(segment_axis, ...
    replica(segment_first:segment_last), 'spline', 'none');

scoreAtDelay = @(delay) fractionalAlignmentScore( ...
    interpolator, template_indices, received_template, delay);
zeroCorrelation = scoreAtDelay(0);

coarseDelays = unique([(-maxDelay:coarseStep:maxDelay), 0]);
coarseScores = zeros(size(coarseDelays));
for k = 1:numel(coarseDelays)
    coarseScores(k) = scoreAtDelay(coarseDelays(k));
end
[~, coarseBestIndex] = max(coarseScores);
coarseBestDelay = coarseDelays(coarseBestIndex);

fineFirst = max(-maxDelay, coarseBestDelay - coarseStep);
fineLast = min(maxDelay, coarseBestDelay + coarseStep);
fineDelays = unique([fineFirst:fineStep:fineLast, ...
    coarseBestDelay, 0]);
fineScores = zeros(size(fineDelays));
for k = 1:numel(fineDelays)
    fineScores(k) = scoreAtDelay(fineDelays(k));
end
[bestCorrelation, fineBestIndex] = max(fineScores);
bestDelay = fineDelays(fineBestIndex);

if bestCorrelation - zeroCorrelation < minImprovement
    bestDelay = 0;
    bestCorrelation = zeroCorrelation;
end
end

function score = fractionalAlignmentScore( ...
        interpolator, templateIndices, receivedTemplate, delay)
shiftedTemplate = interpolator(templateIndices - delay);
if any(~isfinite(shiftedTemplate))
    score = -inf;
    return;
end
score = abs(shiftedTemplate' * receivedTemplate) / ...
    (norm(shiftedTemplate) * norm(receivedTemplate) + eps);
end

function shifted = applyFractionalShift(signal, delay)
% Cubic-spline interpolation preserves the wideband pulse shape much better
% than linear interpolation near a half-sample delay. Samples outside the
% finite replica are zero-filled.
if delay == 0
    shifted = signal;
    return;
end
sample_axis = (1:numel(signal)).';
interpolator = griddedInterpolant( ...
    sample_axis, signal(:), 'spline', 'none');
shifted = interpolator(sample_axis - delay);
shifted(~isfinite(shifted)) = 0;
end

function cfoHz = fitReplicaCfo( ...
        received, replica, periodRx, firstSync, lastSync, fs)
sync_count = min(lastSync, floor(min(numel(received), ...
    numel(replica)) / periodRx));
firstSync = min(firstSync, sync_count);
correlations = complex(zeros(sync_count - firstSync + 1, 1));
times = zeros(size(correlations));
for k = firstSync:sync_count
    first = round((k - 1) * periodRx) + 1;
    last = min(numel(replica), round(k * periodRx));
    idx = first:last;
    q = k - firstSync + 1;
    correlations(q) = replica(idx)' * received(idx);
    times(q) = ((first + last) / 2 - 1) / fs;
end
phase = unwrap(angle(correlations));
line_fit = polyfit(times, phase, 1);
cfoHz = line_fit(1) / (2 * pi);
end

function indices = workFieldToRxIndices( ...
        workRange, fsWork, fsRx, available)
first = round((workRange(1) - 1) * fsRx / fsWork) + 1;
last = min(available, round(workRange(2) * fsRx / fsWork));
if first > last
    indices = [];
else
    indices = first:last;
end
end

function [model, phrGain, payloadGain] = selectFieldModel( ...
        baseline, received, phrIdx, payloadIdx, mode, fixedScale)
model = baseline;
fields = {phrIdx, payloadIdx};
gains = complex(ones(2, 1));
for k = 1:2
    idx = fields{k};
    if isempty(idx)
        continue;
    end
    m = baseline(idx);
    r = received(idx);
    switch lower(mode)
        case 'baseline'
            gains(k) = 1;
        case {'fixed_scale', 'fixed_0p8'}
            gains(k) = fixedScale;
        case 'optimal_real'
            gains(k) = real(m' * r) / (real(m' * m) + eps);
        case 'optimal_complex'
            gains(k) = (m' * r) / (m' * m + eps);
        otherwise
            error('Unknown cancellation mode: %s', mode);
    end
    model(idx) = gains(k) * m;
end
phrGain = gains(1);
payloadGain = gains(2);
end

function [raw, rx] = readIqSegment( ...
        fileName, sampleOffset, sampleNum, antNum, channelIndex)
raw = uwbdecoder.readIqRaw( ...
    fileName, sampleOffset, sampleNum, antNum);
rx = uwbdecoder.selectIqChannel(raw, channelIndex);
end

function [raw, clippedCount] = replaceIqChannel( ...
        raw, rx, channelIndex, c)
i_row = 2 * channelIndex - 1;
q_row = i_row + 1;
i_values = round(real(rx));
q_values = round(imag(rx));
clippedCount = nnz(i_values > c.INT16_MAX | i_values < c.INT16_MIN) + ...
    nnz(q_values > c.INT16_MAX | q_values < c.INT16_MIN);
raw(i_row, :) = max(c.INT16_MIN, min(c.INT16_MAX, i_values));
raw(q_row, :) = max(c.INT16_MIN, min(c.INT16_MAX, q_values));
end

function writeIqSegment(fileName, sampleOffset, raw, antNum, c)
fid = fopen(fileName, 'r+b', 'ieee-le');
if fid < 0
    error('Cannot open output capture for patching: %s', fileName);
end
guard = onCleanup(@() fclose(fid));
status = fseek(fid, ...
    sampleOffset * c.BYTES_PER_IQ_SAMPLE * antNum, 'bof');
if status ~= 0
    error('Cannot seek to output sample %d.', sampleOffset);
end
count = fwrite(fid, int16(raw), 'int16');
if count ~= numel(raw)
    error('Only %d of %d int16 values were written.', count, numel(raw));
end
clear guard;
end

function compensation = loadPllPhaseCompensation( ...
        enabled, templateFile, applyRepetitions, preambleRepetitions)
% Load and validate the nonlinear phase template produced by
% analyze_uwb_pll_phase_drift.m. Fine sub-SYNC templates are preferred;
% legacy repetition-level templates remain supported for reproducibility.
% A missing template is expected during the bootstrap cancellation run:
% analyze_uwb_pll_phase_drift.m needs an existing cancellation result before
% it can learn the template. In that case, keep the cancellation run usable
% and make the fallback explicit in the command-window warning.
compensation = struct( ...
    'enabled', logical(enabled), ...
    'template_file', char(templateFile), ...
    'resolution', 'disabled', ...
    'bins_per_repetition', 0, ...
    'apply_repetitions', 0, ...
    'phase_by_repetition_rad', zeros(preambleRepetitions, 1), ...
    'phase_by_bin_rad', zeros(preambleRepetitions, 0), ...
    'first_phase_deg', 0, ...
    'peak_abs_phase_deg', 0);
if ~compensation.enabled
    return
end
if ~isfile(templateFile)
    warning('run_cancel_all_uwb_packets:PllTemplateNotFound', ...
        ['PLL phase template does not exist; skipping PLL phase ', ...
        'compensation for this run: %s\n', ...
        'Run analyze_uwb_pll_phase_drift.m after cancellation, then ', ...
        'rerun this script to apply the learned template.'], templateFile);
    compensation.enabled = false;
    compensation.resolution = 'missing_template';
    return
end
validateattributes(applyRepetitions, {'numeric'}, ...
    {'scalar', 'integer', 'positive'}, mfilename, ...
    'pll_phase_apply_repetitions');

templateTable = readtable(templateFile);
variableNames = templateTable.Properties.VariableNames;
isSubsync = all(ismember( ...
    {'repetition', 'bin_in_repetition', ...
    'applied_template_phase_deg'}, variableNames));
if isSubsync
    repetitions = double(templateTable.repetition);
    bins = double(templateTable.bin_in_repetition);
    phaseDeg = double(templateTable.applied_template_phase_deg);
    valid = isfinite(repetitions) & isfinite(bins) & isfinite(phaseDeg) & ...
        repetitions >= 1 & repetitions <= preambleRepetitions & ...
        repetitions == round(repetitions) & bins >= 1 & ...
        bins == round(bins);
    repetitions = repetitions(valid);
    bins = bins(valid);
    phaseDeg = phaseDeg(valid);
    if isempty(repetitions)
        error('run_cancel_all_uwb_packets:InvalidPllTemplate', ...
            'The sub-SYNC PLL template has no valid rows.');
    end

    binsPerRepetition = max(bins);
    applyCount = min([applyRepetitions, preambleRepetitions, ...
        max(repetitions)]);
    phaseByBinDeg = NaN(applyCount, binsPerRepetition);
    for row = 1:numel(phaseDeg)
        repetition = repetitions(row);
        bin = bins(row);
        if repetition <= applyCount && bin <= binsPerRepetition
            if isfinite(phaseByBinDeg(repetition, bin))
                error('run_cancel_all_uwb_packets:InvalidPllTemplate', ...
                    'Sub-SYNC PLL template contains duplicated bins.');
            end
            phaseByBinDeg(repetition, bin) = phaseDeg(row);
        end
    end
    if any(~isfinite(phaseByBinDeg), 'all')
        error('run_cancel_all_uwb_packets:IncompletePllTemplate', ...
            ['Sub-SYNC PLL template must contain every bin 1..%d ', ...
            'for repetitions 1..%d.'], binsPerRepetition, applyCount);
    end

    compensation.resolution = 'subsync';
    compensation.bins_per_repetition = binsPerRepetition;
    compensation.phase_by_bin_rad = zeros( ...
        preambleRepetitions, binsPerRepetition);
    compensation.phase_by_bin_rad(1:applyCount, :) = ...
        phaseByBinDeg * pi / 180;
    % Retain a circular repetition average for older readers of metadata.
    compensation.phase_by_repetition_rad(1:applyCount) = ...
        angle(mean(exp(1j * phaseByBinDeg * pi / 180), 2));
    compensation.apply_repetitions = applyCount;
    compensation.first_phase_deg = phaseByBinDeg(1, 1);
    compensation.peak_abs_phase_deg = max(abs(phaseByBinDeg), [], 'all');
    return
end

requiredColumns = {'repetition', 'template_phase_deg'};
missingColumns = setdiff(requiredColumns, variableNames);
if ~isempty(missingColumns)
    error('run_cancel_all_uwb_packets:InvalidPllTemplate', ...
        ['PLL template must use either the sub-SYNC schema or the ', ...
        'legacy repetition schema. Missing legacy columns: %s'], ...
        strjoin(missingColumns, ', '));
end

repetitions = double(templateTable.repetition);
phaseDeg = double(templateTable.template_phase_deg);
valid = isfinite(repetitions) & isfinite(phaseDeg) & ...
    repetitions >= 1 & repetitions <= preambleRepetitions & ...
    repetitions == round(repetitions);
repetitions = repetitions(valid);
phaseDeg = phaseDeg(valid);
if isempty(repetitions) || numel(unique(repetitions)) ~= numel(repetitions)
    error('run_cancel_all_uwb_packets:InvalidPllTemplate', ...
        'PLL template repetitions are empty or duplicated.');
end

applyCount = min([applyRepetitions, preambleRepetitions, ...
    max(repetitions)]);
requiredRepetitions = (1:applyCount).';
if ~all(ismember(requiredRepetitions, repetitions))
    error('run_cancel_all_uwb_packets:IncompletePllTemplate', ...
        'PLL template must contain every repetition from 1 through %d.', ...
        applyCount);
end
[~, rows] = ismember(requiredRepetitions, repetitions);
compensation.resolution = 'repetition';
compensation.bins_per_repetition = 1;
compensation.phase_by_repetition_rad(requiredRepetitions) = ...
    phaseDeg(rows) * pi / 180;
compensation.phase_by_bin_rad = compensation.phase_by_repetition_rad;
compensation.apply_repetitions = applyCount;
compensation.first_phase_deg = phaseDeg(rows(1));
compensation.peak_abs_phase_deg = max(abs(phaseDeg(rows)));
end

function corrected = applyPllPhaseCompensation( ...
        replica, periodSamples, compensation)
% Map the measured phase grid to the generated waveform. Rounding every bin
% boundary independently prevents cumulative sample-index drift when a
% SYNC period is not an integer number of receiver samples. After the
% configured early window the correction is exactly zero.
if ~compensation.enabled
    corrected = replica;
    return
end

samplePhase = zeros(numel(replica), 1);
for repetition = 1:compensation.apply_repetitions
    for bin = 1:compensation.bins_per_repetition
        firstBoundary = (repetition - 1) + ...
            (bin - 1) / compensation.bins_per_repetition;
        lastBoundary = (repetition - 1) + ...
            bin / compensation.bins_per_repetition;
        firstSample = round(firstBoundary * periodSamples) + 1;
        lastSample = min(numel(replica), ...
            round(lastBoundary * periodSamples));
        if firstSample > lastSample
            continue
        end
        samplePhase(firstSample:lastSample) = ...
            compensation.phase_by_bin_rad(repetition, bin);
    end
end
corrected = replica .* exp(1j * samplePhase);
end

function corrected = applyCirSecondStageCfo( ...
        replica, periodSamples, diagnostics)
% Convert the CIR phase line rejected by the nonlinear smoother into a
% residual CFO correction. Anchor it at the first CIR repetition, then
% continue the phase ramp through SFD, PHR, and Payload.
if ~diagnostics.second_stage_cfo_applied
    corrected = replica;
    return
end
firstSample = round( ...
    (diagnostics.first_repetition - 1) * periodSamples) + 1;
if firstSample > numel(replica)
    corrected = replica;
    return
end
samplePhase = zeros(numel(replica), 1);
sampleOffsetRepetitions = ((firstSample:numel(replica)).' - ...
    firstSample) / periodSamples;
samplePhase(firstSample:end) = ...
    diagnostics.linear_phase_slope_rad_per_repetition * ...
    sampleOffsetRepetitions;
corrected = replica .* exp(1j * samplePhase);
end

function corrected = applyRepetitionPhaseCurve( ...
        replica, periodSamples, phaseByRepetitionRad)
% Apply one packet-specific phase value to every represented SYNC. Values
% outside the available CIR region are zero and leave the waveform intact.
samplePhase = zeros(numel(replica), 1);
for repetition = 1:numel(phaseByRepetitionRad)
    phase = phaseByRepetitionRad(repetition);
    if phase == 0
        continue
    end
    firstSample = round((repetition - 1) * periodSamples) + 1;
    lastSample = min(numel(replica), round(repetition * periodSamples));
    if firstSample <= lastSample
        samplePhase(firstSample:lastSample) = phase;
    end
end
corrected = replica .* exp(1j * samplePhase);
end

function diagnostics = emptyCirSlowDiagnostics()
diagnostics = struct( ...
    'applied', false, ...
    'second_stage_cfo_applied', false, ...
    'first_repetition', 0, ...
    'last_repetition', 0, ...
    'subspace_coherence', NaN, ...
    'raw_nonlinear_rms_deg', NaN, ...
    'correction_rms_deg', NaN, ...
    'noise_rms_deg', NaN, ...
    'maximum_abs_correction_deg', NaN, ...
    'explained_fraction', NaN, ...
    'linear_phase_slope_rad_per_repetition', NaN, ...
    'second_stage_cfo_hz', NaN);
end

function indices = syncRepetitionRangeIndices( ...
        firstRepetition, lastRepetition, periodSamples, available)
if firstRepetition < 1 || lastRepetition < firstRepetition
    indices = [];
    return
end
firstSample = round((firstRepetition - 1) * periodSamples) + 1;
lastSample = min(available, round(lastRepetition * periodSamples));
if firstSample > lastSample || firstSample > available
    indices = [];
else
    indices = firstSample:lastSample;
end
end

function metrics = fieldSuppressionMetrics( ...
        observed, finalModel, modelWithoutSfo, modelWithoutCirSlow, ...
        modelWithoutPll, indices)
metrics = struct( ...
    'sample_count', 0, ...
    'suppression_db', NaN, ...
    'suppression_without_sfo_db', NaN, ...
    'suppression_without_cir_slow_db', NaN, ...
    'suppression_without_pll_db', NaN, ...
    'sfo_improvement_db', NaN, ...
    'cir_slow_improvement_db', NaN, ...
    'pll_improvement_db', NaN);
indices = indices(indices >= 1 & indices <= numel(observed));
if isempty(indices)
    return
end
metrics.sample_count = numel(indices);
inputPower = mean(abs(observed(indices)) .^ 2);
metrics.suppression_db = suppressionForModel( ...
    observed, finalModel, indices, inputPower);
metrics.suppression_without_sfo_db = suppressionForModel( ...
    observed, modelWithoutSfo, indices, inputPower);
metrics.suppression_without_cir_slow_db = suppressionForModel( ...
    observed, modelWithoutCirSlow, indices, inputPower);
metrics.suppression_without_pll_db = suppressionForModel( ...
    observed, modelWithoutPll, indices, inputPower);
metrics.sfo_improvement_db = metrics.suppression_db - ...
    metrics.suppression_without_sfo_db;
metrics.cir_slow_improvement_db = metrics.suppression_db - ...
    metrics.suppression_without_cir_slow_db;
metrics.pll_improvement_db = ...
    metrics.suppression_without_cir_slow_db - ...
    metrics.suppression_without_pll_db;
end

function suppressionDb = suppressionForModel( ...
        observed, model, indices, inputPower)
residual = observed(indices) - model(indices);
suppressionDb = 10 * log10(inputPower / ...
    (mean(abs(residual) .^ 2) + eps));
end

function report = addFieldMetrics(report, prefix, metrics)
report.([prefix '_sample_count']) = metrics.sample_count;
report.([prefix '_suppression_db']) = metrics.suppression_db;
report.([prefix '_suppression_without_sfo_db']) = ...
    metrics.suppression_without_sfo_db;
report.([prefix '_suppression_without_cir_slow_db']) = ...
    metrics.suppression_without_cir_slow_db;
report.([prefix '_suppression_without_pll_db']) = ...
    metrics.suppression_without_pll_db;
report.([prefix '_cir_slow_improvement_db']) = ...
    metrics.cir_slow_improvement_db;
report.([prefix '_sfo_improvement_db']) = ...
    metrics.sfo_improvement_db;
report.([prefix '_pll_improvement_db']) = ...
    metrics.pll_improvement_db;
end

function summaryTable = makeFieldSummaryTable(reportTable)
prefixes = {'sync', 'sfd', 'phr', 'payload', ...
    'sync_pll_window', 'sync_gap_window', 'sync_cir_window'};
labels = ["SYNC"; "SFD"; "PHR"; "Payload"; ...
    "SYNC PLL window"; "SYNC uncompensated gap"; "SYNC CIR slow window"];
fieldCount = numel(prefixes);
validPackets = zeros(fieldCount, 1);
medianSampleCount = NaN(fieldCount, 1);
suppressionP10Db = NaN(fieldCount, 1);
suppressionMedianDb = NaN(fieldCount, 1);
suppressionP90Db = NaN(fieldCount, 1);
withoutSfoMedianDb = NaN(fieldCount, 1);
sfoGainMedianDb = NaN(fieldCount, 1);
sfoPositivePercent = NaN(fieldCount, 1);
pllOnlyMedianDb = NaN(fieldCount, 1);
noNonlinearCompMedianDb = NaN(fieldCount, 1);
pllGainMedianDb = NaN(fieldCount, 1);
pllPositivePercent = NaN(fieldCount, 1);
cirSlowGainMedianDb = NaN(fieldCount, 1);
cirSlowPositivePercent = NaN(fieldCount, 1);

successful = logical(reportTable.success);
for k = 1:fieldCount
    prefix = prefixes{k};
    finalSuppression = reportTable.([prefix '_suppression_db']);
    sampleCount = reportTable.([prefix '_sample_count']);
    valid = successful & isfinite(finalSuppression) & sampleCount > 0;
    validPackets(k) = nnz(valid);
    if ~any(valid)
        continue
    end
    finalValues = finalSuppression(valid);
    withoutSfoValues = reportTable.( ...
        [prefix '_suppression_without_sfo_db'])(valid);
    sfoGain = reportTable.([prefix '_sfo_improvement_db'])(valid);
    pllOnlyValues = reportTable.( ...
        [prefix '_suppression_without_cir_slow_db'])(valid);
    noCompValues = reportTable.( ...
        [prefix '_suppression_without_pll_db'])(valid);
    pllGain = reportTable.([prefix '_pll_improvement_db'])(valid);
    cirGain = reportTable.( ...
        [prefix '_cir_slow_improvement_db'])(valid);
    medianSampleCount(k) = median(sampleCount(valid));
    suppressionP10Db(k) = prctile(finalValues, 10);
    suppressionMedianDb(k) = median(finalValues);
    suppressionP90Db(k) = prctile(finalValues, 90);
    withoutSfoMedianDb(k) = median(withoutSfoValues, 'omitnan');
    sfoGainMedianDb(k) = median(sfoGain, 'omitnan');
    sfoPositivePercent(k) = 100 * mean(sfoGain > 0, 'omitnan');
    pllOnlyMedianDb(k) = median(pllOnlyValues, 'omitnan');
    noNonlinearCompMedianDb(k) = median(noCompValues, 'omitnan');
    pllGainMedianDb(k) = median(pllGain, 'omitnan');
    pllPositivePercent(k) = 100 * mean(pllGain > 0, 'omitnan');
    cirSlowGainMedianDb(k) = median(cirGain, 'omitnan');
    cirSlowPositivePercent(k) = ...
        100 * mean(cirGain > 0, 'omitnan');
end

summaryTable = table(labels, validPackets, medianSampleCount, ...
    suppressionP10Db, suppressionMedianDb, suppressionP90Db, ...
    withoutSfoMedianDb, sfoGainMedianDb, sfoPositivePercent, ...
    pllOnlyMedianDb, noNonlinearCompMedianDb, pllGainMedianDb, ...
    pllPositivePercent, cirSlowGainMedianDb, ...
    cirSlowPositivePercent, ...
    'VariableNames', {'field', 'valid_packets', ...
    'median_sample_count', 'suppression_p10_db', ...
    'suppression_median_db', 'suppression_p90_db', ...
    'without_sfo_suppression_median_db', ...
    'sfo_gain_median_db', 'sfo_positive_percent', ...
    'pll_only_suppression_median_db', ...
    'no_nonlinear_comp_suppression_median_db', ...
    'pll_gain_median_db', 'pll_positive_percent', ...
    'cir_slow_gain_median_db', 'cir_slow_positive_percent'});
end

function report = emptyReport()
report = struct( ...
    'index', 0, ...
    'success', false, ...
    'abs_start_detected', 0, ...
    'abs_start_fitted', NaN, ...
    'samples_subtracted', 0, ...
    'alignment_correlation', NaN, ...
    'integer_alignment_correlation', NaN, ...
    'fractional_delay_samples', NaN, ...
    'fitted_cfo_hz', NaN, ...
    'global_gain', complex(NaN), ...
    'phr_gain', complex(NaN), ...
    'payload_gain', complex(NaN), ...
    'frame_suppression_db', NaN, ...
    'frame_suppression_without_sfo_db', NaN, ...
    'sfo_improvement_db', NaN, ...
    'full_packet_sfo_applied', false, ...
    'full_packet_sfo_ppm', NaN, ...
    'full_packet_sfo_delay_intercept_samples', NaN, ...
    'full_packet_sfo_total_drift_samples', NaN, ...
    'full_packet_sfo_valid_windows', 0, ...
    'full_packet_sfo_fit_residual_samples', NaN, ...
    'full_packet_sfo_explained_fraction', NaN, ...
    'frame_suppression_without_pll_db', NaN, ...
    'pll_improvement_db', NaN, ...
    'pll_compensation_applied', false, ...
    'frame_suppression_without_cir_slow_db', NaN, ...
    'cir_slow_phase_improvement_db', NaN, ...
    'cir_slow_phase_applied', false, ...
    'cir_slow_phase_first_repetition', 0, ...
    'cir_slow_phase_last_repetition', 0, ...
    'cir_slow_phase_subspace_coherence', NaN, ...
    'cir_slow_phase_raw_rms_deg', NaN, ...
    'cir_slow_phase_correction_rms_deg', NaN, ...
    'cir_slow_phase_noise_rms_deg', NaN, ...
    'cir_slow_phase_max_abs_deg', NaN, ...
    'cir_slow_phase_explained_fraction', NaN, ...
    'cir_second_stage_cfo_applied', false, ...
    'cir_second_stage_cfo_hz', NaN, ...
    'clipped_component_count', 0, ...
    'fcs_pass', false, ...
    'message', '', ...
    'patch_raw', [], ...
    'patch_offset', 0, ...
    'patch_samples', 0);
emptyMetrics = fieldSuppressionMetrics([], [], [], [], [], []);
prefixes = {'sync', 'sfd', 'phr', 'payload', ...
    'sync_pll_window', 'sync_gap_window', 'sync_cir_window'};
for k = 1:numel(prefixes)
    report = addFieldMetrics(report, prefixes{k}, emptyMetrics);
end
end

function results = applyMergedSummary(results, merged_summary_file, ...
        ~, profile_dirs) %#ok<DEFNU>
% Legacy dual-pass merge helper (unused).
% — crucially — source each frame's data (CIR/payload/timing) from the
% MAT that matches its profile. Frames decoded with the wrong PHY would
% otherwise carry garbage metadata.
tbl = readtable(merged_summary_file);
if ~ismember('index', tbl.Properties.VariableNames) || ...
        ~ismember('abs_start_sample', tbl.Properties.VariableNames)
    return;
end
% Load per-profile frame pools.
profile_names = fieldnames(profile_dirs);
profile_pools = struct();
fprintf('applyMergedSummary: profile_dirs fields = %s\n', strjoin(fieldnames(profile_dirs), ','));
for p = 1:numel(profile_names)
    pname = profile_names{p};
    pmats = {
        fullfile(profile_dirs.(pname), 'all_frames_cir.mat'), ...
        fullfile(profile_dirs.(pname), sprintf('all_frames_cir_%s.mat', lower(pname))) ...
    };
    frames_tmp = [];
    for m = 1:numel(pmats)
        if ~isfile(pmats{m})
            continue;
        end
        tmp = load(pmats{m}, 'results');
        if isfield(tmp, 'results') && isfield(tmp.results, 'frames') && ...
                numel(tmp.results.frames) > 0
            frames_tmp = tmp.results.frames;
            break;
        end
    end
    if ~isempty(frames_tmp)
        profile_pools.(pname) = frames_tmp;
    end
end
% Build lookup: profile -> (abs_start_sample -> frame). Use a plain struct
% of maps keyed by profile name to avoid char-key edge cases on empty keys.
fprintf('  profile_pools fields: %s\n', strjoin(fieldnames(profile_pools), ','));
fprintf('  isfield(DW)=%d isfield(QM35)=%d\n', isfield(profile_pools,'DW'), isfield(profile_pools,'QM35'));
dw_map = containers.Map('KeyType','double','ValueType','any');
qm_map = containers.Map('KeyType','double','ValueType','any');
for p = 1:numel(profile_names)
    pname = profile_names{p};
    if ~isfield(profile_pools, pname)
        continue;
    end
    pool = profile_pools.(pname);
    if strcmp(pname, 'DW')
        target_map = dw_map;
    else
        target_map = qm_map;
    end
    for k = 1:numel(pool)
        if isfield(pool(k), 'abs_start_sample')
            target_map(pool(k).abs_start_sample) = pool(k);
        end
    end
end
% Walk the merged CSV in order, sourcing each frame from its profile pool.
% Collect into a cell array first to avoid cross-structure assignment when
% the per-profile frames have differing fields.
matched_cells = cell(height(tbl), 1);
matched_count = 0;
for r = 1:height(tbl)
    tbl_profile = '';
    if ismember('profile', tbl.Properties.VariableNames) && ...
            ~ismissing(tbl.profile(r))
        tbl_profile = char(string(tbl.profile(r)));
    end
    start_sample = tbl.abs_start_sample(r);
    f = [];
    switch tbl_profile
        case 'DW'
            if dw_map.isKey(start_sample)
                f = dw_map(start_sample);
            end
        case 'QM35'
            if qm_map.isKey(start_sample)
                f = qm_map(start_sample);
            end
    end
    if isempty(f)
        continue
    end
    f.index = r;
    if ~isfield(f, 'profile') || isempty(f.profile)
        f.profile = tbl_profile;
    end
    matched_cells{r} = f;
    matched_count = matched_count + 1;
end
if matched_count > 0
    new_frames = [matched_cells{:}];
else
    new_frames = results.frames([]);
end
results.frames = new_frames;
results.packet_count = numel(new_frames);
results.fcs_pass_count = sum([new_frames.fcs_pass]);
fprintf('Sourced %d/%d frames by profile (DW pool:%d, QM35 pool:%d).\n', ...
    matched_count, height(tbl), ...
    dw_map.Count, qm_map.Count);
end  % applyMergedSummary
