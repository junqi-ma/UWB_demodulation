%% Periodic QM35 search + CIR estimation (5 ms packet interval)
% Branch: feature/two-packet-cir
%
% 1) Find the first QM35 packet in qm35_dw1000_1.dat (QM35 PHY profile).
% 2) Using the known ~5 ms inter-packet interval, search subsequent slots.
% 3) Estimate CIR for every successful lock and visualize results.
clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% -------------------- Capture --------------------
options = struct();
options.file_name = 'F:\qm35_dw1000_1.dat';
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

options.cir_pre_samples = 8;
options.cir_post_samples = 30;
options.cir_max_path_m = [];
options.max_psdu_bytes = 32;
options.enable_frame_crop = true;
options.verbose = false;
options.show_plots = false;

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
for k = 1:n_found
    r = records(k);
    fprintf(['#%02d  t=%.3f ms  start=%d  SFD=%s  corr=%.3f  ', ...
        'SYNC=%d  PSDU=%d B  FCS=%d\n'], ...
        k, r.time_start_s*1e3, r.abs_start_sample, r.result.sfd.name, ...
        r.result.sfd.correlation, r.result.preamble.detected_repetitions, ...
        r.result.phr.psdu_length_bytes, r.result.payload.fcs_pass);
end
fprintf('=============================\n');

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
    xline(0, 'k--');
    grid on;
    xlabel('Relative delay (ns)');
    ylabel('Normalized |CIR|');
    title('Per-packet CIR magnitude (peak-normalized)');
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

%% -------------------- Save --------------------
out_dir = fullfile(project_dir, 'decoded_results', 'qm35_dw1000_1_periodic_cir');
if ~isfolder(out_dir)
    mkdir(out_dir);
end
save(fullfile(out_dir, 'qm35_periodic_cir.mat'), ...
    'records', 'cir_values', 'cir_delay_ns', 'starts_ms', ...
    'options', 'search', 'first', '-v7.3');
writePeriodicCsv(fullfile(out_dir, 'qm35_periodic_summary.csv'), ...
    records, options.fs_rx);
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

%% ========================================================================
function options = estimateToneCoefficientOnce(options, total_samples)
if ~options.enable_interference_cancellation
    return;
end
probe = options;
probe.sample_offset = 0;
probe.sample_num = min(0.5e6, total_samples);
probe.interference_coefficient = [];
[~, interf] = dw1000decoder.readAndCancelInterference( ...
    dw1000decoder.mergeOptions(dw1000decoder.defaultOptions(), probe));
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
