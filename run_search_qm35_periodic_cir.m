%% Periodic QM35 search + CIR estimation (5 ms packet interval)
% Branch: feature/two-packet-cir
%
% 1) Find the first QM35 packet in qm35_dw1000_1.dat (QM35 PHY profile).
% 2) Using the known ~5 ms inter-packet interval, search subsequent slots.
% 3) Estimate CIR for every successful lock and visualize results.
% 4) Use pre-first-path CIR bins as DW1000 interference proxy and report SIR.
clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% -------------------- Capture --------------------
options = struct();
options.file_name = 'F:\UWB基带数据\qm35_dw1000_1.dat';
options.ant_num = 1;
options.channel_index = 1;
options.fs_rx = 737.28e6;
options.x410_center_frequency = 6500e6;
options.dw1000_center_frequency = 6489.6e6;

%% -------------------- QM35 PHY (run_decode / README) --------------------
options.preamble_repetitions = 128;
options.cir_repetitions = 64;
options.code_index = 9;
options.data_rate = 6.81;
% Fixed 4z#2: auto can pick Decawave DW-8 under collision and then fail SFD gates.
options.sfd_mode = '4z2';
options.decawave_sfd = [-1; -1; -1; -1; 1; -1; 0; 0];
options.ieee_sfd = [0; 1; 0; -1; 1; 0; 0; -1];
options.sfd4z_1 = [-1; -1; 1; -1];
options.sfd4z_2 = [-1; -1; -1; 1; -1; -1; 1; -1];
options.sfd4z_3 = [-1; -1; -1; -1; -1; 1; 1; -1; ...
    -1; 1; -1; 1; -1; -1; 1; -1];
options.sfd4z_4 = [-1; -1; -1; -1; -1; -1; -1; 1; ...
    -1; -1; 1; -1; -1; 1; -1; 1; -1; 1; -1; -1; ...
    -1; 1; 1; -1; -1; -1; 1; -1; 1; 1; -1; -1];

% CIR window: pre bins are range samples strictly before the nominal first path
% (delay=0). Previously ~8 (~5 usable after guard); expand to 15 for pre-path
% DW1000 interference / SIR analysis.
options.cir_pre_samples = 15;
options.cir_post_samples = 30;
options.cir_max_path_m = [];
options.max_psdu_bytes = 32;
options.enable_frame_crop = true;
options.verbose = false;
options.show_plots = false;

%% -------------------- Pre-path SIR analysis --------------------
% Model: bins before first path contain little/no QM35 multipath energy, so
% residual power there proxies DW1000 interference + thermal noise after
% code-despread. Signal = first-path peak power of the QM35 CIR.
sir = struct();
sir.pre_path_guard_bins = 2;   % exclude leading edge of first path
sir.signal_half_width = 1;     % peak search window around delay=0 (bins)
sir.min_pre_bins = 4;          % require enough pre-path bins after guard

%% -------------------- Tone cancel --------------------
options.enable_interference_cancellation = true;
options.interference_quiet_offset = 400000;
options.interference_quiet_num = 262144;
options.interference_tone_bin = -169;
options.interference_period_samples = 512;
options.interference_coefficient = [];
options.blank_intervals = [];
options.blank_weight = 0;
options.blank_taper_samples = 256;

%% -------------------- Search / period control --------------------
search = struct();
% --- first-packet coarse search ---
search.first_window_samples = 1.0e6;
search.first_step_samples = 0.25e6;
search.first_max_search_samples = 40e6;   % only scan head for the first lock
search.require_fcs_pass = false;          % accept PHR-OK if FCS fails under collision
search.require_4z_sfd = false;
search.min_sfd_correlation = 0.35;       % slightly looser under DW1000 collision
% Accept if FCS passes even when soft-chip SFD corr is mediocre.
search.accept_fcs_override = true;
% Max |measured_start - expected_start| as a fraction of the period.
search.max_timing_error_frac = 0.35;

% --- periodic follow-on search (user: 5 ms spacing) ---
search.packet_period_s = 5e-3;
search.period_samples = round(search.packet_period_s * options.fs_rx);  % 3686400
% Fine window placed relative to expected start of each slot.
search.slot_pre_samples = 0.25e6;    % open window before expected start
search.slot_window_samples = 1.00e6; % decode window length
% Local re-try offsets around the nominal slot (drift / collision).
search.slot_retry_offsets = round( ...
    [-0.35e6, -0.25e6, -0.15e6, -0.05e6, 0, 0.05e6, 0.15e6, 0.25e6, 0.35e6]);
% How many periods to follow after the first packet (0 = until file end).
search.max_periods = 0;
% 0 = never early-stop; otherwise stop after this many consecutive misses.
% Previous default 8 caused only ~9 slots to be tried (~45 ms of a 1 s file).
search.max_miss_streak = 0;

%% -------------------- File + tone coefficient once --------------------
info = dir(options.file_name);
if isempty(info)
    error('Capture not found: %s', options.file_name);
end
total_samples = floor(info.bytes / (options.ant_num * 4));
duration_s = total_samples / options.fs_rx;

options = estimateToneCoefficientOnce(options, total_samples);

fprintf('\n========== Periodic QM35 CIR search ==========\n');
fprintf('File                         : %s\n', options.file_name);
fprintf('Duration                     : %.3f ms  (%d samples)\n', ...
    duration_s*1e3, total_samples);
fprintf('QM35 config                  : code=%d  SYNC=%d\n', ...
    options.code_index, options.preamble_repetitions);
fprintf('Packet period                : %.3f ms  (%d samples)\n', ...
    search.packet_period_s*1e3, search.period_samples);
fprintf('================================================\n');

%% -------------------- Stage 1: find first QM35 --------------------
fprintf('\n--- Stage 1: find first QM35 ---\n');
[first, options] = findFirstQm35(options, search, total_samples);
fprintf('First QM35 abs_start=%d  t=%.3f ms  SFD=%s  FCS=%d\n', ...
    first.abs_start_sample, first.time_start_s*1e3, ...
    first.result.sfd.name, first.result.payload.fcs_pass);

%% -------------------- Stage 2: periodic slots + CIR --------------------
fprintf('\n--- Stage 2: follow %.3f ms period ---\n', search.packet_period_s*1e3);

if search.max_periods > 0
    n_slots = search.max_periods + 1;
else
    n_slots = floor((total_samples - first.abs_start_sample) / ...
        search.period_samples) + 1;
end

records = repmat(emptyRecord(), n_slots, 1);
records(1) = first;
n_found = 1;
miss_streak = 0;

for slot = 1:n_slots-1
    expected_start = first.abs_start_sample + slot * search.period_samples;
    if expected_start >= total_samples
        break;
    end

    fprintf('\n==== Slot %d / ~%d | expected start=%d (%.3f ms) ====\n', ...
        slot+1, n_slots, expected_start, expected_start/options.fs_rx*1e3);

    [rec, ok, diag] = tryDecodeAround(options, search, total_samples, expected_start);
    if ok
        n_found = n_found + 1;
        rec.slot_index = slot;
        records(n_found) = rec;
        miss_streak = 0;
        fprintf('  LOCK  abs_start=%d  t=%.3f ms  SFD=%s  corr=%.3f  FCS=%d\n', ...
            rec.abs_start_sample, rec.time_start_s*1e3, ...
            rec.result.sfd.name, rec.result.sfd.correlation, ...
            rec.result.payload.fcs_pass);
    else
        miss_streak = miss_streak + 1;
        fprintf('  MISS  (streak=%d)  best: %s\n', miss_streak, diag);
        if search.max_miss_streak > 0 && miss_streak >= search.max_miss_streak
            fprintf('Stopping after %d consecutive misses.\n', miss_streak);
            break;
        end
    end
end

records = records(1:n_found);

%% -------------------- Pack CIR matrix / summary --------------------
cir_delay_ns = [];
cir_values = [];
if n_found > 0
    cir_delay_ns = records(1).result.cir.delay_ns(:);
    L = numel(cir_delay_ns);
    cir_values = complex(nan(L, n_found));
    for k = 1:n_found
        v = records(k).result.cir.values(:);
        n = min(L, numel(v));
        cir_values(1:n, k) = v(1:n);
    end
end

starts_ms = [records.time_start_s] * 1e3;
if n_found >= 2
    d_ms = diff(starts_ms);
    fprintf('\nMeasured inter-packet intervals (ms):\n');
    fprintf('  mean=%.3f  std=%.3f  min=%.3f  max=%.3f\n', ...
        mean(d_ms), std(d_ms), min(d_ms), max(d_ms));
end

fprintf('\n========== Summary ==========\n');
fprintf('QM35 packets found            : %d\n', n_found);
fprintf('CIR pre / post samples        : %d / %d\n', ...
    options.cir_pre_samples, options.cir_post_samples);
for k = 1:n_found
    r = records(k);
    fprintf(['#%02d  t=%.3f ms  start=%d  SFD=%s  corr=%.3f  ', ...
        'SYNC=%d  PSDU=%d B  FCS=%d\n'], ...
        k, r.time_start_s*1e3, r.abs_start_sample, r.result.sfd.name, ...
        r.result.sfd.correlation, r.result.preamble.detected_repetitions, ...
        r.result.phr.psdu_length_bytes, r.result.payload.fcs_pass);
end
fprintf('=============================\n');

%% -------------------- Pre-path SIR (DW1000 on QM35) --------------------
sir_table = emptySirTable(n_found);
if n_found > 0 && ~isempty(cir_delay_ns)
    sir_table = analyzePrePathSir(cir_values, cir_delay_ns, starts_ms, ...
        records, sir);
    printSirSummary(sir_table, sir, options.cir_pre_samples);
end

%% -------------------- Plots --------------------
% 1) Arrival timeline
figure('Name', 'QM35 periodic arrivals', 'Color', 'w', 'Position', [60 80 1000 360]);
hold on;
for k = 1:n_found
    col = [0.2 0.55 0.9];
    if ~records(k).result.payload.fcs_pass
        col = [0.9 0.45 0.2];
    end
    stem(starts_ms(k), 1, 'filled', 'Color', col, 'LineWidth', 1.2);
    text(starts_ms(k), 1.08, sprintf('#%d', k), ...
        'HorizontalAlignment', 'center', 'FontSize', 8);
end
xlim([0, max(duration_s*1e3, max(starts_ms)*1.05)]);
ylim([0 1.35]);
yticks([]);
xlabel('Time (ms)');
title(sprintf('QM35 arrivals (period target %.1f ms, found %d)', ...
    search.packet_period_s*1e3, n_found));
grid on; box on;

% 2) CIR overlay
if n_found > 0
    figure('Name', 'QM35 CIR overlay', 'Color', 'w', 'Position', [80 60 1000 520]);
    subplot(2, 1, 1); hold on;
    for k = 1:n_found
        h = cir_values(:, k);
        if all(isnan(h))
            continue;
        end
        mag = abs(h) / (max(abs(h)) + eps);
        plot(cir_delay_ns, mag, 'LineWidth', 1.0);
    end
    xline(0, 'k--', 'first path (nominal)');
    grid on;
    xlabel('Relative delay (ns)');
    ylabel('Normalized |CIR|');
    title(sprintf( ...
        'Per-packet CIR magnitude (peak-normalized, pre=%d post=%d)', ...
        options.cir_pre_samples, options.cir_post_samples));
    if n_found <= 12
        legend(arrayfun(@(k) sprintf('#%d t=%.2fms', k, starts_ms(k)), ...
            1:n_found, 'UniformOutput', false), 'Location', 'eastoutside');
    end

    subplot(2, 1, 2);
    mag_db = 20*log10(max(abs(cir_values) ./ (max(abs(cir_values), [], 1) + eps), 1e-3));
    imagesc(1:n_found, cir_delay_ns, mag_db);
    axis xy;
    colorbar;
    caxis([-50 0]);
    xlabel('Packet index');
    ylabel('Delay (ns)');
    title('|CIR| (dB, each column peak-normalized)');
    sgtitle(sprintf('%s — periodic QM35 CIR', options.file_name), ...
        'Interpreter', 'none');
end

% 3) Interval stem
if n_found >= 2
    figure('Name', 'QM35 inter-packet interval', 'Color', 'w');
    stem(1:n_found-1, diff(starts_ms), 'filled');
    yline(search.packet_period_s*1e3, 'r--', '5 ms target');
    grid on;
    xlabel('Interval index');
    ylabel('Delta t (ms)');
    title('Measured QM35 packet spacing');
end

% 4) Pre-path interference / SIR
if n_found > 0 && any([sir_table.ok])
    plotPrePathSir(cir_values, cir_delay_ns, sir_table, sir, ...
        options.cir_pre_samples, starts_ms);
end

%% -------------------- Save --------------------
out_dir = fullfile(project_dir, 'decoded_results', 'qm35_dw1000_1_periodic_cir');
if ~isfolder(out_dir)
    mkdir(out_dir);
end
save(fullfile(out_dir, 'qm35_periodic_cir.mat'), ...
    'records', 'cir_values', 'cir_delay_ns', 'starts_ms', ...
    'sir_table', 'sir', 'options', 'search', 'first', '-v7.3');
writePeriodicCsv(fullfile(out_dir, 'qm35_periodic_summary.csv'), ...
    records, options.fs_rx);
writeSirCsv(fullfile(out_dir, 'qm35_prepath_sir.csv'), sir_table);
figs = findall(0, 'Type', 'figure');
for k = 1:numel(figs)
    try
        exportgraphics(figs(k), fullfile(out_dir, sprintf('fig_%d.png', k)), ...
            'Resolution', 140);
    catch
    end
end
fprintf('Saved: %s\n', out_dir);

assignin('base', 'qm35_periodic_records', records);
assignin('base', 'qm35_periodic_cir_values', cir_values);
assignin('base', 'qm35_periodic_cir_delay_ns', cir_delay_ns);
assignin('base', 'qm35_periodic_starts_ms', starts_ms);
assignin('base', 'qm35_prepath_sir_table', sir_table);

%% ========================================================================
function options = estimateToneCoefficientOnce(options, total_samples)
if ~options.enable_interference_cancellation
    return;
end
probe = options;
probe.sample_offset = 0;
probe.sample_num = min(0.5e6, total_samples);
probe.interference_coefficient = [];
[~, interf] = uwbdecoder.readAndCancelInterference( ...
    uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), probe));
if interf.enabled && isfield(interf, 'coefficient') && ...
        ~isnan(real(interf.coefficient))
    options.interference_coefficient = interf.coefficient;
    fprintf('Tone coefficient |A|=%.3f  phase=%.1f deg\n', ...
        abs(interf.coefficient), angle(interf.coefficient)*180/pi);
end
end

function [first, options] = findFirstQm35(options, search, total_samples)
search_limit = min(total_samples, search.first_max_search_samples);
offset = 0;
attempt = 0;
while offset + search.first_window_samples <= search_limit
    attempt = attempt + 1;
    wopts = options;
    wopts.sample_offset = offset;
    wopts.sample_num = search.first_window_samples;
    fprintf('  first-search attempt %d | offset=%d (%.3f ms)\n', ...
        attempt, offset, offset/options.fs_rx*1e3);
    try
        result = decode_x410_dw1000(wopts);
    catch ME
        fprintf('    fail: %s\n', ME.message);
        offset = offset + search.first_step_samples;
        continue;
    end
    [tf_acc, why_acc] = acceptQm35(result, search);
    if ~tf_acc
        fprintf('    reject SFD=%s corr=%.3f PHR=%d FCS=%d (%s)\n', ...
            result.sfd.name, result.sfd.correlation, ...
            result.phr.secded_pass, result.payload.fcs_pass, why_acc);
        offset = offset + search.first_step_samples;
        continue;
    end
    abs_start = absStartFromResult(offset, result, options.fs_rx);
    first = emptyRecord();
    first.slot_index = 0;
    first.window_offset = offset;
    first.abs_start_sample = abs_start;
    first.time_start_s = abs_start / options.fs_rx;
    first.expected_start_sample = abs_start;
    first.result = result;
    first.ok = true;
    return;
end
error('Could not find the first QM35 packet within the search limit.');
end

function [rec, ok, diag] = tryDecodeAround(options, search, total_samples, expected_start)
ok = false;
diag = 'no successful decode in slot retries';
rec = emptyRecord();
rec.expected_start_sample = expected_start;
best = [];
best_score = -inf;
best_reject = '';

for k = 1:numel(search.slot_retry_offsets)
    off = expected_start - search.slot_pre_samples + search.slot_retry_offsets(k);
    off = max(0, off);
    win = search.slot_window_samples;
    if off + win > total_samples
        win = total_samples - off;
    end
    if win < 0.25e6
        continue;
    end
    wopts = options;
    wopts.sample_offset = off;
    wopts.sample_num = win;
    try
        result = decode_x410_dw1000(wopts);
    catch ME
        if strlength(string(best_reject)) == 0
            best_reject = sprintf('decode-error: %s', ME.message);
        end
        continue;
    end
    abs_start = absStartFromResult(off, result, options.fs_rx);
    [tf, why] = acceptQm35(result, search, abs_start, expected_start);
    if ~tf
        cand = sprintf('SFD=%s corr=%.3f PHR=%d FCS=%d dt=%.3fms (%s)', ...
            result.sfd.name, result.sfd.correlation, result.phr.secded_pass, ...
            result.payload.fcs_pass, ...
            (abs_start-expected_start)/options.fs_rx*1e3, why);
        best_reject = cand;
        continue;
    end
    % Prefer locks close to the expected period grid and high SFD corr.
    score = result.sfd.correlation - 0.15 * abs(abs_start - expected_start) / ...
        max(search.period_samples, 1);
    if result.payload.fcs_pass
        score = score + 0.05;
    end
    if score > best_score
        best_score = score;
        best = struct('offset', off, 'result', result, ...
            'abs_start', abs_start);
    end
end

if isempty(best)
    if strlength(string(best_reject)) > 0
        diag = best_reject;
    end
    return;
end

ok = true;
diag = 'ok';
rec.slot_index = NaN;
rec.window_offset = best.offset;
rec.abs_start_sample = best.abs_start;
rec.time_start_s = best.abs_start / options.fs_rx;
rec.expected_start_sample = expected_start;
rec.result = best.result;
rec.ok = true;
end

function [tf, why] = acceptQm35(result, search, abs_start, expected_start)
why = '';
name = lower(string(result.sfd.name));
is_4z = contains(name, "4z") || contains(name, "802.15.4z");

if ~result.phr.secded_pass
    tf = false;
    why = 'PHR fail';
    return;
end

if nargin >= 4 && ~isempty(expected_start) && isfield(search, 'max_timing_error_frac')
    max_err = search.max_timing_error_frac * search.period_samples;
    if abs(abs_start - expected_start) > max_err
        dt_ms = abs(abs_start - expected_start) / search.period_samples * ...
            search.packet_period_s * 1e3;
        why = sprintf('timing |dt|=%.3fms > limit', dt_ms);
        tf = false;
        return;
    end
end

corr_ok = result.sfd.correlation >= search.min_sfd_correlation;
fcs_ok = logical(result.payload.fcs_pass);
if search.require_fcs_pass && ~fcs_ok
    tf = false;
    why = 'FCS required but failed';
    return;
end
if search.require_4z_sfd && ~is_4z
    tf = false;
    why = 'not 4z SFD';
    return;
end

if corr_ok
    tf = true;
    why = 'corr+PHR';
    return;
end
if isfield(search, 'accept_fcs_override') && search.accept_fcs_override && fcs_ok
    tf = true;
    why = 'FCS override';
    return;
end

tf = false;
why = sprintf('low SFD corr=%.3f', result.sfd.correlation);
end

function abs_start = absStartFromResult(window_offset, result, fs_rx)
abs_start = window_offset + round( ...
    (result.preamble.start_sample - 1) * fs_rx / result.phy_config.SampleRate);
abs_start = max(0, abs_start);
end

function rec = emptyRecord()
rec = struct( ...
    'slot_index', NaN, ...
    'window_offset', NaN, ...
    'abs_start_sample', NaN, ...
    'time_start_s', NaN, ...
    'expected_start_sample', NaN, ...
    'result', [], ...
    'ok', false);
end

function writePeriodicCsv(csv_file, records, fs_rx)
fid = fopen(csv_file, 'w');
if fid < 0
    return;
end
c = onCleanup(@() fclose(fid));
fprintf(fid, ['index,slot,abs_start,time_ms,expected_ms,delta_ms,', ...
    'sfd,sfd_corr,sync_reps,psdu_len,fcs_pass\n']);
for k = 1:numel(records)
    r = records(k);
    exp_ms = r.expected_start_sample / fs_rx * 1e3;
    if k == 1
        d_ms = 0;
    else
        d_ms = (r.time_start_s - records(k-1).time_start_s) * 1e3;
    end
    fprintf(fid, '%d,%d,%d,%.6f,%.6f,%.6f,"%s",%.4f,%d,%d,%d\n', ...
        k, r.slot_index, r.abs_start_sample, r.time_start_s*1e3, ...
        exp_ms, d_ms, r.result.sfd.name, ...
        r.result.sfd.correlation, r.result.preamble.detected_repetitions, ...
        r.result.phr.psdu_length_bytes, r.result.payload.fcs_pass);
end
clear c;
end

function t = emptySirTable(n)
t = repmat(struct( ...
    'index', NaN, ...
    'time_ms', NaN, ...
    'ok', false, ...
    'n_pre_bins', NaN, ...
    'fp_delay_ns', NaN, ...
    'fp_idx', NaN, ...
    'P_signal', NaN, ...
    'P_interf_mean', NaN, ...
    'P_interf_rms', NaN, ...
    'P_interf_max', NaN, ...
    'sir_db', NaN, ...
    'sir_peak_db', NaN, ...
    'prepath_floor_db', NaN, ...
    'fcs_pass', false), n, 1);
end

function sir_table = analyzePrePathSir(cir_values, cir_delay_ns, starts_ms, ...
        records, sir)
%ANALYZEPREPATHSIR Estimate DW1000-on-QM35 SIR from pre-first-path CIR bins.
%
%   Pre-path region (delay < 0, minus a small guard near the first path)
%   should contain little QM35 multipath; residual power is treated as
%   DW1000 interference + noise after code despreading.
%
%   Definitions (per packet, on L2-normalized CIR taps):
%     P_signal      = |h_fp|^2 at nominal first path (peak near delay=0)
%     P_interf_mean = mean(|h_pre|^2) over pre-path bins
%     SIR_dB        = 10*log10(P_signal / P_interf_mean)
%     SIR_peak_dB   = 10*log10(P_signal / max(|h_pre|^2))  (worst bin)

n_pkt = size(cir_values, 2);
sir_table = emptySirTable(n_pkt);
delay = cir_delay_ns(:);
L = numel(delay);

% Nominal first-path index: delay closest to 0.
[~, fp0] = min(abs(delay));
guard = max(0, round(sir.pre_path_guard_bins));
half_w = max(0, round(sir.signal_half_width));

for k = 1:n_pkt
    sir_table(k).index = k;
    sir_table(k).time_ms = starts_ms(k);
    if k <= numel(records) && isstruct(records(k).result) && ...
            isfield(records(k).result, 'payload')
        sir_table(k).fcs_pass = logical(records(k).result.payload.fcs_pass);
    end

    h = cir_values(:, k);
    if all(isnan(h)) || numel(h) < L
        continue;
    end
    h = h(1:L);
    pwr = abs(h).^2;

    % Signal: strongest tap in a small window around delay=0.
    i0 = max(1, fp0 - half_w);
    i1 = min(L, fp0 + half_w);
    [P_s, loc] = max(pwr(i0:i1));
    fp_idx = i0 + loc - 1;

    % Pre-path: all bins strictly before (fp_idx - guard).
    pre_end = fp_idx - 1 - guard;
    if pre_end < sir.min_pre_bins
        continue;
    end
    pre_idx = 1:pre_end;
    p_pre = pwr(pre_idx);
    p_pre = p_pre(~isnan(p_pre));
    if numel(p_pre) < sir.min_pre_bins || P_s <= 0 || ~isfinite(P_s)
        continue;
    end

    P_i_mean = mean(p_pre);
    P_i_rms = sqrt(mean(p_pre.^2));
    P_i_max = max(p_pre);

    sir_table(k).ok = true;
    sir_table(k).n_pre_bins = numel(p_pre);
    sir_table(k).fp_delay_ns = delay(fp_idx);
    sir_table(k).fp_idx = fp_idx;
    sir_table(k).P_signal = P_s;
    sir_table(k).P_interf_mean = P_i_mean;
    sir_table(k).P_interf_rms = P_i_rms;
    sir_table(k).P_interf_max = P_i_max;
    sir_table(k).sir_db = 10*log10(P_s / max(P_i_mean, eps));
    sir_table(k).sir_peak_db = 10*log10(P_s / max(P_i_max, eps));
    sir_table(k).prepath_floor_db = 10*log10(P_i_mean / max(P_s, eps));
end
end

function printSirSummary(sir_table, sir, cir_pre_samples)
ok = [sir_table.ok];
fprintf('\n========== Pre-path SIR (DW1000 → QM35) ==========\n');
fprintf('CIR pre-path bins configured  : %d\n', cir_pre_samples);
fprintf('Guard bins before first path  : %d\n', sir.pre_path_guard_bins);
fprintf('Packets with valid SIR        : %d / %d\n', nnz(ok), numel(sir_table));
if ~any(ok)
    fprintf('No valid pre-path SIR estimates.\n');
    fprintf('=================================================\n');
    return;
end

sir_db = [sir_table(ok).sir_db];
sir_pk = [sir_table(ok).sir_peak_db];
floor_db = [sir_table(ok).prepath_floor_db];
n_pre = [sir_table(ok).n_pre_bins];

fprintf('Pre-path bins used (mean)     : %.1f\n', mean(n_pre));
fprintf('SIR = P_fp / mean(P_pre)      : mean=%.2f  std=%.2f  min=%.2f  max=%.2f dB\n', ...
    mean(sir_db), std(sir_db), min(sir_db), max(sir_db));
fprintf('SIR_peak = P_fp / max(P_pre)  : mean=%.2f  std=%.2f  min=%.2f  max=%.2f dB\n', ...
    mean(sir_pk), std(sir_pk), min(sir_pk), max(sir_pk));
fprintf('Pre-path floor vs FP          : mean=%.2f  std=%.2f dB\n', ...
    mean(floor_db), std(floor_db));
fprintf('\nPer-packet SIR (dB):\n');
for k = 1:numel(sir_table)
    if ~sir_table(k).ok
        fprintf('  #%02d  t=%.3f ms  SIR=n/a\n', k, sir_table(k).time_ms);
        continue;
    end
    fprintf(['  #%02d  t=%.3f ms  SIR=%.2f dB  SIR_peak=%.2f dB  ', ...
        'floor=%.1f dB  pre_bins=%d  FCS=%d\n'], ...
        k, sir_table(k).time_ms, sir_table(k).sir_db, ...
        sir_table(k).sir_peak_db, sir_table(k).prepath_floor_db, ...
        sir_table(k).n_pre_bins, sir_table(k).fcs_pass);
end
fprintf('=================================================\n');
fprintf(['Note: CIR taps are L2-normalized per packet, so SIR here is a ', ...
    'relative first-path / pre-path energy ratio (despread interference ', ...
    'floor), not absolute RF SIR.\n']);
end

function plotPrePathSir(cir_values, cir_delay_ns, sir_table, sir, ...
        cir_pre_samples, starts_ms)
ok = [sir_table.ok];
idx_ok = find(ok);
if isempty(idx_ok)
    return;
end

delay = cir_delay_ns(:);
[~, fp0] = min(abs(delay));
guard = max(0, round(sir.pre_path_guard_bins));

figure('Name', 'QM35 pre-path SIR (DW1000 interference)', ...
    'Color', 'w', 'Position', [100 40 1100 720]);

% (a) Zoomed CIR around pre-path + first path
subplot(2, 2, 1); hold on;
n_show = min(numel(idx_ok), 20);
for ii = 1:n_show
    k = idx_ok(ii);
    h = cir_values(:, k);
    if all(isnan(h))
        continue;
    end
    mag = abs(h) / (max(abs(h)) + eps);
    plot(delay, mag, 'LineWidth', 0.9);
end
xline(0, 'k--', 'first path');
if fp0 > guard + 1
    pre_end_delay = delay(max(1, fp0 - 1 - guard));
    xline(pre_end_delay, 'r:', 'pre-path end');
end
grid on;
xlabel('Relative delay (ns)');
ylabel('Normalized |CIR|');
title(sprintf('CIR zoom (pre=%d bins, guard=%d)', ...
    cir_pre_samples, guard));
xlim([min(delay), max(5, min(max(delay), 20))]);

% (b) Pre-path floor (dB relative to first path) per packet
subplot(2, 2, 2); hold on;
floor_db = nan(numel(sir_table), 1);
sir_db = nan(numel(sir_table), 1);
for k = 1:numel(sir_table)
    if sir_table(k).ok
        floor_db(k) = sir_table(k).prepath_floor_db;
        sir_db(k) = sir_table(k).sir_db;
    end
end
stem(1:numel(sir_table), floor_db, 'filled', 'Color', [0.85 0.35 0.15]);
floor_mu = mean(floor_db(isfinite(floor_db)));
if isfinite(floor_mu)
    yline(floor_mu, 'k--', sprintf('mean %.1f dB', floor_mu));
end
grid on;
xlabel('Packet index');
ylabel('Pre-path floor / P_{fp} (dB)');
title('Pre-first-path interference floor');

% (c) SIR over packet index / time
subplot(2, 2, 3); hold on;
stem(1:numel(sir_table), sir_db, 'filled', 'Color', [0.2 0.45 0.85]);
sir_mu = mean(sir_db(isfinite(sir_db)));
if isfinite(sir_mu)
    yline(sir_mu, 'r--', sprintf('mean %.1f dB', sir_mu));
end
grid on;
xlabel('Packet index');
ylabel('SIR (dB)');
title('SIR = P_{first path} / mean(P_{pre-path})');

% (d) SIR vs arrival time
subplot(2, 2, 4); hold on;
t_ok = starts_ms(idx_ok);
sir_ok = [sir_table(idx_ok).sir_db];
plot(t_ok, sir_ok, 'o-', 'LineWidth', 1.2, 'MarkerFaceColor', [0.2 0.55 0.9]);
if numel(sir_ok) >= 2
    yline(mean(sir_ok), 'r--');
end
grid on;
xlabel('Arrival time (ms)');
ylabel('SIR (dB)');
title('DW1000→QM35 pre-path SIR over time');

sgtitle(sprintf([ ...
    'Pre-first-path SIR analysis  |  CIR pre=%d  guard=%d  |  ', ...
    'valid %d/%d packets'], ...
    cir_pre_samples, guard, nnz(ok), numel(sir_table)), ...
    'Interpreter', 'none');
end

function writeSirCsv(csv_file, sir_table)
fid = fopen(csv_file, 'w');
if fid < 0
    return;
end
c = onCleanup(@() fclose(fid));
fprintf(fid, ['index,time_ms,ok,n_pre_bins,fp_delay_ns,fp_idx,', ...
    'P_signal,P_interf_mean,P_interf_max,sir_db,sir_peak_db,', ...
    'prepath_floor_db,fcs_pass\n']);
for k = 1:numel(sir_table)
    s = sir_table(k);
    fprintf(fid, ['%d,%.6f,%d,%g,%.6f,%g,%.6e,%.6e,%.6e,', ...
        '%.4f,%.4f,%.4f,%d\n'], ...
        s.index, s.time_ms, s.ok, s.n_pre_bins, s.fp_delay_ns, s.fp_idx, ...
        s.P_signal, s.P_interf_mean, s.P_interf_max, ...
        s.sir_db, s.sir_peak_db, s.prepath_floor_db, s.fcs_pass);
end
clear c;
end
