%% Search N QM35 packets on a 5 ms grid with FULL fixed windows
% Branch: feature/two-packet-cir
%
% 1) Free-search the first QM35 from file head, then re-center a full window
%    on its measured start so preamble correlation is not edge-clipped.
% 2) For k=1..N-1, open a FIXED-length window around
%       expected = first_start + k * 5ms
%    so the whole SYNC sits well inside the window.
% 3) If a decode finds the packet too close to the window tail (incomplete
%    SFD), automatically re-center once on the measured start and retry.
% 4) Export one preamble-correlation PNG per lock.
clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% -------------------- How many packets --------------------
N = 50;

%% -------------------- Capture --------------------
options = struct();
options.file_name = 'F:\qm35_dw1000_1.dat';
options.ant_num = 1;
options.channel_index = 1;
options.fs_rx = 737.28e6;
options.x410_center_frequency = 6500e6;
options.dw1000_center_frequency = 6489.6e6;

%% -------------------- QM35 PHY --------------------
options.preamble_repetitions = 128;
options.cir_repetitions = 64;
options.code_index = 9;
options.data_rate = 6.81;
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

%% -------------------- 5 ms grid + full-window geometry --------------------
search = struct();
% First packet free search
search.first_window_samples = 1.2e6;
search.first_step_samples = 0.25e6;
search.first_max_search_samples = 40e6;

% Period grid
search.packet_period_s = 5e-3;
search.period_samples = round(search.packet_period_s * options.fs_rx); % 3686400

% FIXED window: expected/measured start is always near this interior point.
% pre must NOT be too large (otherwise detect can lock a late interferer and
% leave no room for SFD). post must cover full 128-SYNC + SFD + payload.
search.fixed_pre_samples  = 0.20e6;   % start ~0.20e6 into the window
search.fixed_post_samples = 1.20e6;   % long tail so packet is complete
search.fixed_window_samples = search.fixed_pre_samples + search.fixed_post_samples;

% Minimum RX samples required AFTER abs_start for a complete QM35 frame.
% 128 SYNC * ~1 us * 737 MHz ≈ 0.10e6; use 0.55e6 with margin for SFD/PSDU.
search.min_tail_after_start = 0.55e6;
search.min_head_before_start = 0.05e6;

% Small retries around the nominal grid (window length unchanged).
search.slot_retry_offsets = round([-0.15e6, -0.05e6, 0, 0.05e6, 0.15e6]);

search.min_sfd_correlation = 0.35;
search.require_fcs_pass = false;
search.require_phr_pass = true;
search.max_timing_error_frac = 0.40;

%% -------------------- Output --------------------
out_dir = fullfile(project_dir, 'decoded_results', ...
    sprintf('qm35_n%d_preamble_corr', N));
if ~isfolder(out_dir)
    mkdir(out_dir);
end
fig_dir = fullfile(out_dir, 'preamble_corr_figs');
if ~isfolder(fig_dir)
    mkdir(fig_dir);
end

%% -------------------- File + tone once --------------------
info = dir(options.file_name);
if isempty(info)
    error('Capture not found: %s', options.file_name);
end
total_samples = floor(info.bytes/(options.ant_num*4));
options = estimateToneOnce(options, total_samples);

fprintf('\n========== N QM35 on 5 ms grid (full windows) ==========\n');
fprintf('File                         : %s\n', options.file_name);
fprintf('Duration                     : %.3f ms\n', total_samples/options.fs_rx*1e3);
fprintf('N                            : %d\n', N);
fprintf('Period                       : %.3f ms (%d samples)\n', ...
    search.packet_period_s*1e3, search.period_samples);
fprintf('Fixed window                 : pre=%d + post=%d = %d\n', ...
    search.fixed_pre_samples, search.fixed_post_samples, ...
    search.fixed_window_samples);
fprintf('Output                       : %s\n', out_dir);
fprintf('========================================================\n\n');

%% -------------------- Stage 1: first QM35 + re-center full window --------------------
fprintf('--- Stage 1: find first QM35 ---\n');
t0 = tic;
[first_raw, options] = findFirstQm35(options, search, total_samples);
fprintf('  raw first start=%d (%.3f ms)\n', ...
    first_raw.abs_start_sample, first_raw.time_start_s*1e3);

% Re-decode with a full fixed window centered on the measured start so the
% preamble correlation figure is complete and comparable to later slots.
fprintf('  re-centering full window on first packet...\n');
[first, ok1, msg1] = decodeCenteredOn(options, search, total_samples, ...
    first_raw.abs_start_sample, first_raw.abs_start_sample);
if ~ok1
    warning('Re-center of first packet failed (%s); keeping raw first lock.', msg1);
    first = first_raw;
else
    first.index = 1;
    first.slot_index = 0;
    first.expected_start_sample = first.abs_start_sample;
end

records = repmat(emptyRec(), N, 1);
records(1) = first;
n_found = 1;
fprintf('#%02d FIRST  t=%.3f ms  start=%d  win=[%d,%d)  corr=%.3f  FCS=%d\n', ...
    1, first.time_start_s*1e3, first.abs_start_sample, ...
    first.window_offset, first.window_offset+first.window_samples, ...
    first.sfd_corr, first.fcs_pass);

%% -------------------- Stage 2: 5 ms grid with full fixed windows --------------------
fprintf('\n--- Stage 2: follow 5 ms grid ---\n');
anchor = records(1).abs_start_sample;

for k = 1:N-1
    expected = anchor + k * search.period_samples;
    if expected >= total_samples
        fprintf('Slot %d beyond EOF, stop.\n', k+1);
        break;
    end
    fprintf('\n==== Slot %d / %d | expected=%d (%.3f ms) ====\n', ...
        k+1, N, expected, expected/options.fs_rx*1e3);

    [rec, ok, diag] = tryGridSlot(options, search, total_samples, expected);
    if ~ok
        fprintf('  MISS (%s)\n', diag);
        continue;
    end
    n_found = n_found + 1;
    rec.index = n_found;
    rec.slot_index = k;
    rec.expected_start_sample = expected;
    records(n_found) = rec;
    fprintf('  LOCK abs=%d t=%.3f ms dt=%.3f ms win=[%d,%d) corr=%.3f FCS=%d\n', ...
        rec.abs_start_sample, rec.time_start_s*1e3, ...
        (rec.abs_start_sample-expected)/options.fs_rx*1e3, ...
        rec.window_offset, rec.window_offset+rec.window_samples, ...
        rec.sfd_corr, rec.fcs_pass);
end

records = records(1:n_found);
elapsed = toc(t0);
fprintf('\nFound %d / %d in %.1f s\n', n_found, N, elapsed);

%% -------------------- Figures --------------------
fprintf('Exporting preamble correlation figures...\n');
for k = 1:n_found
    fig = plotPreambleCorrelation(records(k), options);
    png = fullfile(fig_dir, sprintf('qm35_%03d_preamble_corr.png', k));
    try
        exportgraphics(fig, png, 'Resolution', 140);
    catch
        saveas(fig, png);
    end
    fprintf('  %s\n', png);
    close(fig);
end

figure('Name', 'QM35 arrivals', 'Color', 'w', 'Position', [60 80 1000 340]);
hold on;
for k = 1:n_found
    col = [0.2 0.55 0.9];
    if ~records(k).fcs_pass, col = [0.9 0.45 0.2]; end
    stem(records(k).time_start_s*1e3, 1, 'filled', 'Color', col);
    text(records(k).time_start_s*1e3, 1.08, sprintf('#%d', k), ...
        'HorizontalAlignment', 'center', 'FontSize', 8);
end
for g = 0:N-1
    gt = (anchor + g*search.period_samples)/options.fs_rx*1e3;
    if gt <= total_samples/options.fs_rx*1e3
        xline(gt, 'Color', [0.85 0.85 0.85], 'HandleVisibility', 'off');
    end
end
ylim([0 1.35]); yticks([]); xlabel('Time (ms)');
title(sprintf('QM35 arrivals vs 5 ms grid (found %d / %d)', n_found, N));
grid on; box on;
try
    exportgraphics(gcf, fullfile(out_dir, 'arrivals_timeline.png'), 'Resolution', 140);
catch
end

if n_found >= 2
    figure('Name', 'Spacing', 'Color', 'w');
    d_ms = diff([records.time_start_s])*1e3;
    stem(1:numel(d_ms), d_ms, 'filled');
    yline(5, 'r--', '5 ms');
    grid on; xlabel('Interval'); ylabel('\Delta t (ms)');
    title(sprintf('mean=%.3f ms  std=%.3f ms', mean(d_ms), std(d_ms)));
    try
        exportgraphics(gcf, fullfile(out_dir, 'spacing.png'), 'Resolution', 140);
    catch
    end
end

save(fullfile(out_dir, 'qm35_n_preamble_corr.mat'), ...
    'records', 'options', 'search', 'N', 'n_found', 'anchor', '-v7.3');
writeCsv(fullfile(out_dir, 'qm35_n_summary.csv'), records, options.fs_rx);
assignin('base', 'qm35_n_records', records);
assignin('base', 'qm35_n_found', n_found);

fprintf('\n========== Done ==========\n');
fprintf('Packets found : %d / %d\n', n_found, N);
fprintf('Figures       : %s\n', fig_dir);
for k = 1:n_found
    r = records(k);
    fprintf('#%02d t=%.3f ms start=%d win=[%d + %d) corr=%.3f FCS=%d\n', ...
        k, r.time_start_s*1e3, r.abs_start_sample, r.window_offset, ...
        r.window_samples, r.sfd_corr, r.fcs_pass);
end
fprintf('==========================\n');

%% ========================================================================
function options = estimateToneOnce(options, total_samples)
if ~options.enable_interference_cancellation, return; end
probe = options;
probe.sample_offset = 0;
probe.sample_num = min(0.5e6, total_samples);
probe.interference_coefficient = [];
params = dw1000decoder.mergeOptions(dw1000decoder.defaultOptions(), probe);
[~, interf] = dw1000decoder.readAndCancelInterference(params);
if interf.enabled && isfield(interf, 'coefficient')
    options.interference_coefficient = interf.coefficient;
    fprintf('Tone |A|=%.3f  phase=%.1f deg\n', ...
        abs(interf.coefficient), angle(interf.coefficient)*180/pi);
end
end

function [first, options] = findFirstQm35(options, search, total_samples)
limit = min(total_samples, search.first_max_search_samples);
offset = 0;
attempt = 0;
while offset + search.first_window_samples <= limit
    attempt = attempt + 1;
    wopts = options;
    wopts.sample_offset = offset;
    wopts.sample_num = search.first_window_samples;
    fprintf('  first-search %d | offset=%d (%.3f ms)\n', ...
        attempt, offset, offset/options.fs_rx*1e3);
    try
        [result, corr_diag] = decodeWithPreambleDiag(wopts);
    catch ME
        fprintf('    fail: %s\n', ME.message);
        offset = offset + search.first_step_samples;
        continue;
    end
    abs_s = absStart(offset, result, options.fs_rx);
    [tf, why] = acceptResult(result, search, abs_s, []);
    if ~tf
        fprintf('    reject (%s) SFD=%s corr=%.3f\n', why, result.sfd.name, ...
            result.sfd.correlation);
        offset = offset + search.first_step_samples;
        continue;
    end
    % If the lock is too close to the free-search window tail, it is incomplete
    % for correlation plots — still return it; Stage1 re-center will fix.
    first = packRec(1, 0, offset, search.first_window_samples, abs_s, abs_s, ...
        result, corr_diag, options.fs_rx);
    return;
end
error('Could not find the first QM35 packet.');
end

function [rec, ok, msg] = tryGridSlot(options, search, total_samples, expected)
ok = false;
msg = 'no candidate';
rec = emptyRec();
best = [];
best_score = -inf;

for k = 1:numel(search.slot_retry_offsets)
    target = expected + search.slot_retry_offsets(k);
    [cand, cok, cmsg] = decodeCenteredOn(options, search, total_samples, ...
        target, expected);
    if ~cok
        msg = cmsg;
        continue;
    end
    score = cand.sfd_corr - 0.15*abs(cand.abs_start_sample-expected)/ ...
        max(search.period_samples, 1);
    if cand.fcs_pass, score = score + 0.05; end
    if score > best_score
        best_score = score;
        best = cand;
        msg = 'ok';
    end
end
if isempty(best), return; end
ok = true;
rec = best;
end

function [rec, ok, msg] = decodeCenteredOn(options, search, total_samples, ...
        center_abs, expected_for_gate)
% Place a full fixed window with center_abs at fixed_pre interior, decode,
% then if the measured start is too close to either edge, re-center once.
ok = false;
msg = '';
rec = emptyRec();

[off, win] = placeFullWindow(center_abs, search, total_samples);
if win < 0.6e6
    msg = 'window too short near EOF';
    return;
end

try
    [result, diag] = decodeWindow(options, off, win);
catch ME
    % Incomplete SFD often means detect locked near window end — try to
    % re-center using a lighter preamble-only guess is hard; try shifting
    % window earlier (more pre) once.
    if contains(ME.message, 'Capture ends before SFD') || ...
            contains(ME.message, 'preamble')
        [off2, win2] = placeFullWindow(center_abs - 0.15e6, search, total_samples);
        try
            [result, diag] = decodeWindow(options, off2, win2);
            off = off2; win = win2;
        catch ME2
            msg = ME2.message;
            return;
        end
    else
        msg = ME.message;
        return;
    end
end

abs_s = absStart(off, result, options.fs_rx);

% Recenter if measured start is not safely interior.
need_recenter = (abs_s - off) < search.min_head_before_start || ...
    (off + win - abs_s) < search.min_tail_after_start;
if need_recenter
    [off2, win2] = placeFullWindow(abs_s, search, total_samples);
    try
        [result2, diag2] = decodeWindow(options, off2, win2);
        abs_s2 = absStart(off2, result2, options.fs_rx);
        % Prefer recentered if still valid
        [tf2, ~] = acceptResult(result2, search, abs_s2, expected_for_gate);
        if tf2
            result = result2; diag = diag2; off = off2; win = win2; abs_s = abs_s2;
        end
    catch
        % keep first result
    end
end

[tf, why] = acceptResult(result, search, abs_s, expected_for_gate);
if ~tf
    msg = sprintf('SFD=%s corr=%.3f PHR=%d FCS=%d dt=%.3fms (%s)', ...
        result.sfd.name, result.sfd.correlation, result.phr.secded_pass, ...
        result.payload.fcs_pass, ...
        (abs_s-expected_for_gate)/options.fs_rx*1e3, why);
    return;
end

ok = true;
msg = 'ok';
rec = packRec(NaN, NaN, off, win, abs_s, expected_for_gate, result, diag, options.fs_rx);
end

function [off, win] = placeFullWindow(center_abs, search, total_samples)
off = round(center_abs - search.fixed_pre_samples);
win = search.fixed_window_samples;
if off < 0
    win = win + off;
    off = 0;
end
if off + win > total_samples
    win = total_samples - off;
end
off = max(0, off);
win = max(0, win);
end

function [result, diag] = decodeWindow(options, off, win)
wopts = options;
wopts.sample_offset = off;
wopts.sample_num = win;
[result, diag] = decodeWithPreambleDiag(wopts);
end

function [result, diag] = decodeWithPreambleDiag(options)
params = dw1000decoder.mergeOptions(dw1000decoder.defaultOptions(), options);
addpath(params.helper_path);
[rx, interference] = dw1000decoder.readAndCancelInterference(params);
rx = dw1000decoder.compensateCenterFrequency(rx, params);
reference = dw1000decoder.buildDw1000Reference(params);
rx_work = dw1000decoder.resampleCapture(rx, params.fs_rx, reference.fs);
preamble = dw1000decoder.detectRepeatedPreamble(rx_work, reference, params);
dw1000decoder.validateCaptureLength(rx_work, preamble, reference, params);
if params.enable_frame_crop
    [rx_work, preamble] = dw1000decoder.cropToFrame(rx_work, preamble, reference, params);
end
[rx_work, preamble] = dw1000decoder.compensateCarrierOffset( ...
    rx_work, preamble, reference, params);
preamble = dw1000decoder.refineTimingWithNsSfd(rx_work, preamble, reference, params);
sfd_symbols = dw1000decoder.analyzeNsSfdSymbols(rx_work, preamble, reference, params);
[cir, chips] = dw1000decoder.estimateCirAndSoftChips(rx_work, preamble, reference, params);
sfd = dw1000decoder.locateNsSfd(chips.soft, reference, params, preamble);
frame = dw1000decoder.decodePhrAndPayload(chips.soft, sfd, reference.cfg);
result = dw1000decoder.packageResult(params, reference, interference, ...
    preamble, sfd_symbols, cir, chips, sfd, frame);

if isfield(preamble, 'matched_is_roi') && preamble.matched_is_roi
    roi_start = preamble.roi_start;
else
    roi_start = 1;
end
diag = struct();
diag.fs_work = reference.fs;
diag.samples_per_symbol = reference.samples_per_symbol;
diag.measured_period = preamble.measured_period;
diag.score = preamble.score(:);
diag.metric = preamble.metric(:);
diag.peaks = preamble.peaks(:);
diag.start_sample = preamble.start_sample;
diag.threshold = preamble.threshold;
diag.roi_start = roi_start;
diag.metric_peak = preamble.metric_peak;
if isfield(preamble, 'metric_peak_index')
    diag.metric_peak_index = preamble.metric_peak_index;
else
    [~, diag.metric_peak_index] = max(preamble.metric);
end
end

function fig = plotPreambleCorrelation(rec, options)
diag = rec.corr_diag;
score = diag.score; metric = diag.metric; peaks = diag.peaks;
start_sample = diag.start_sample; thr = diag.threshold;
roi_start = diag.roi_start;
samples_per_symbol = diag.samples_per_symbol;
period = diag.measured_period;
score_idx = roi_start + (0:numel(score)-1).';
metric_idx = roi_start + (0:numel(metric)-1).';
pk_local = peaks - roi_start + 1;
valid_pk = pk_local >= 1 & pk_local <= numel(score);
pk_local = pk_local(valid_pk); pk_abs = peaks(valid_pk);

fig = figure('Name', sprintf('QM35 #%d preamble', rec.index), ...
    'Color', 'w', 'Position', [80 60 1100 720], 'Visible', 'off');

subplot(3,1,1);
plot(score_idx, score, 'b'); hold on;
yline(thr, 'k--', 'threshold');
if ~isempty(pk_abs), plot(pk_abs, score(pk_local), 'ro', 'MarkerSize', 4); end
xline(start_sample, 'g--', 'start');
grid on;
xlabel('Work-rate sample (window)'); ylabel('score');
title(sprintf('#%d preamble score | t=%.3f ms abs=%d win=[%d+%d) peaks=%d', ...
    rec.index, rec.time_start_s*1e3, rec.abs_start_sample, ...
    rec.window_offset, rec.window_samples, numel(pk_abs)));

subplot(3,1,2);
plot(metric_idx, metric, 'Color', [0.1 0.55 0.25], 'LineWidth', 1.1); hold on;
mi = min(max(1, round(diag.metric_peak_index)), numel(metric));
plot(metric_idx(mi), metric(mi), 'ro', 'MarkerFaceColor', 'r');
xline(start_sample, 'g--'); grid on;
xlabel('Work-rate sample (window)'); ylabel('16-sym metric');
title(sprintf('metric peak=%.3f | SFD corr=%.3f FCS=%d', ...
    diag.metric_peak, rec.sfd_corr, rec.fcs_pass));

subplot(3,1,3);
zoom0 = start_sample - 2*samples_per_symbol;
zoom1 = start_sample + (options.preamble_repetitions+16)*period;
in_zoom = score_idx >= zoom0 & score_idx <= zoom1;
if any(in_zoom)
    plot(score_idx(in_zoom), score(in_zoom), 'b'); hold on;
else
    plot(score_idx, score, 'b'); hold on;
end
yline(thr, 'k--');
pk_z = pk_abs(pk_abs>=zoom0 & pk_abs<=zoom1);
if ~isempty(pk_z)
    pl = pk_z - roi_start + 1; pl = pl(pl>=1 & pl<=numel(score));
    plot(pk_z(1:numel(pl)), score(pl), 'ro', 'MarkerSize', 4);
end
xline(start_sample, 'g--', 'start');
xline(start_sample + options.preamble_repetitions*period, 'm--', 'SYNC end');
grid on; xlim([zoom0 zoom1]);
xlabel('Work-rate sample (window)'); ylabel('score');
title(sprintf('Fixed zoom around full SYNC | %s | reps=%d', ...
    rec.sfd_name, rec.sync_reps));

sgtitle(sprintf('QM35 #%d preamble correlation | abs_start=%d | t=%.3f ms', ...
    rec.index, rec.abs_start_sample, rec.time_start_s*1e3), 'Interpreter', 'none');
end

function [tf, why] = acceptResult(result, search, abs_start, expected_start)
why = 'ok';
if search.require_phr_pass && ~result.phr.secded_pass
    tf = false; why = 'PHR fail'; return;
end
if result.sfd.correlation < search.min_sfd_correlation && ~result.payload.fcs_pass
    tf = false; why = sprintf('low corr=%.3f', result.sfd.correlation); return;
end
if search.require_fcs_pass && ~result.payload.fcs_pass
    tf = false; why = 'FCS fail'; return;
end
if ~isempty(expected_start) && isfield(search, 'max_timing_error_frac')
    max_err = search.max_timing_error_frac * search.period_samples;
    if abs(abs_start - expected_start) > max_err
        tf = false;
        why = sprintf('|dt|=%.3fms', ...
            abs(abs_start-expected_start)/search.period_samples*search.packet_period_s*1e3);
        return;
    end
end
tf = true;
end

function abs_s = absStart(window_offset, result, fs_rx)
abs_s = window_offset + round( ...
    (result.preamble.start_sample-1)*fs_rx/result.phy_config.SampleRate);
abs_s = max(0, abs_s);
end

function rec = packRec(index, slot, off, win, abs_s, expected, result, diag, fs_rx)
rec = emptyRec();
rec.index = index;
rec.slot_index = slot;
rec.window_offset = off;
rec.window_samples = win;
rec.abs_start_sample = abs_s;
rec.expected_start_sample = expected;
rec.time_start_s = abs_s / fs_rx;
rec.sfd_name = char(string(result.sfd.name));
rec.sfd_corr = result.sfd.correlation;
rec.fcs_pass = logical(result.payload.fcs_pass);
rec.phr_pass = logical(result.phr.secded_pass);
rec.psdu_len = result.phr.psdu_length_bytes;
rec.sync_reps = result.preamble.detected_repetitions;
rec.result = result;
rec.corr_diag = diag;
end

function rec = emptyRec()
rec = struct('index',NaN,'slot_index',NaN,'window_offset',NaN, ...
    'window_samples',NaN,'abs_start_sample',NaN,'expected_start_sample',NaN, ...
    'time_start_s',NaN,'sfd_name','','sfd_corr',NaN,'fcs_pass',false, ...
    'phr_pass',false,'psdu_len',NaN,'sync_reps',NaN,'result',[],'corr_diag',[]);
end

function writeCsv(csv_file, records, fs_rx)
fid = fopen(csv_file, 'w');
if fid < 0, return; end
c = onCleanup(@() fclose(fid));
fprintf(fid, ['index,slot,abs_start,expected,time_ms,expected_ms,dt_ms,', ...
    'win_off,win_len,sfd,sfd_corr,sync_reps,psdu,fcs\n']);
for k = 1:numel(records)
    r = records(k);
    fprintf(fid, '%d,%d,%d,%d,%.6f,%.6f,%.6f,%d,%d,"%s",%.4f,%d,%d,%d\n', ...
        r.index, r.slot_index, r.abs_start_sample, r.expected_start_sample, ...
        r.time_start_s*1e3, r.expected_start_sample/fs_rx*1e3, ...
        (r.abs_start_sample-r.expected_start_sample)/fs_rx*1e3, ...
        r.window_offset, r.window_samples, r.sfd_name, r.sfd_corr, ...
        r.sync_reps, r.psdu_len, r.fcs_pass);
end
clear c;
end
