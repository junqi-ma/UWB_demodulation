%% Decode all QM35 packets with *gap-fill* interference mitigation
% Branch: feature/two-packet-cir
%
% Previous full-file DW1000 blanking was too aggressive: large pads wiped out
% nearby QM35 frames and total QM35 count dropped. This rewrite uses a safer
% strategy that should never do worse than the no-IC baseline:
%
%   Pass 1  QM35 full-file decode WITHOUT blanking  -> keep all good packets
%   Pass 2  Detect strong DW1000 interferers (code 10 / SYNC 256)
%   Pass 3  Only inside large *gaps* between QM35 successes, re-search with
%           conservative soft-blanking of DW1000 intervals (excluding any
%           overlap with already-found QM35 packets)
%   Merge   Union of Pass-1 and Pass-3 packets (dedup by absolute start)
%
% Result: baseline packets are always kept; IC can only *add* recoveries.
clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% -------------------- Shared capture / RF --------------------
file_name = 'F:\UWB基带数据\qm35_dw1000_1.dat';
fs_rx = 737.28e6;
x410_center_frequency = 6500e6;
uwb_center_frequency = 6489.6e6;

%% -------------------- IC / gap-fill controls --------------------
ic = struct();
% Conservative blank pads (much smaller than the previous 2.5e5 post-pad).
ic.pad_pre_samples = 5e3;
ic.pad_post_samples = 1.2e5;
ic.blank_weight = 0.15;            % soft suppress, not hard zero
ic.blank_taper_samples = 512;
ic.min_dw_sfd_corr = 0.55;         % only fairly confident DW1000
ic.require_dw_decawave_sfd = true; % prefer DW-8 style interferers
ic.merge_gap_samples = 2e4;
% Protect already-found QM35: shrink/remove blanks that overlap them.
ic.protect_qm35_pad = 3e4;
% Gaps must be at least this long (RX samples) to trigger a re-search.
ic.min_gap_samples = 0.8e6;
% Extra margin inside each gap when re-searching.
ic.gap_edge_margin = 0.1e6;
% Sliding re-search inside each gap.
ic.gap_window_samples = 1.0e6;
ic.gap_step_samples = 0.2e6;

%% -------------------- Batch parameters (full-file passes) --------------------
batch = struct();
batch.coarse_chunk_samples = 4e6;
batch.coarse_step_samples = 3e6;
batch.coarse_decimation = 32;
batch.energy_smooth_rx_samples = 8192;
batch.energy_threshold_sigma = 5.5;   % slightly more sensitive than before
batch.use_coarse_correlation = true;
batch.corr_threshold_sigma = 4.5;
batch.candidate_merge_samples = 1.5e5;
batch.pre_packet_guard_samples = 5e4;
batch.window_samples = 1.0e6;
batch.min_window_samples = 0.3e6;
batch.search_step_samples = 0.5e6;
batch.post_packet_guard_samples = 4096;
batch.start_tolerance_samples = 4096;
batch.require_fcs_pass = false;
batch.save_individual_cir = true;

%% -------------------- Output root --------------------
[~, capture_stem] = fileparts(file_name);
out_root = fullfile(pwd, 'decoded_results', [capture_stem '_qm35'], 'gapfill_ic');
if ~isfolder(out_root)
    mkdir(out_root);
end

info = dir(file_name);
if isempty(info)
    error('Capture not found: %s', file_name);
end
total_samples = floor(info.bytes/4);

%% ========================================================================
%% Pass 1: QM35 baseline (no blanking) — this is the floor
%% ========================================================================
fprintf('\n========== Pass 1: QM35 baseline (no IC) ==========\n');
qm_opts = qm35Options(file_name, fs_rx, x410_center_frequency, uwb_center_frequency);
qm_opts.blank_intervals = [];
qm_batch = batch;
qm_batch.output_directory = fullfile(out_root, 'pass1_baseline');
qm_batch.mat_file = fullfile(qm_batch.output_directory, 'baseline.mat');
qm_batch.summary_csv = fullfile(qm_batch.output_directory, 'baseline.csv');

results_base_raw = decode_uwb_all(qm_opts, qm_batch);
results_base = filterQm35Like(results_base_raw);
fprintf('QM35 baseline kept            : %d (raw decoded %d)\n', ...
    results_base.packet_count, results_base_raw.packet_count);

%% ========================================================================
%% Pass 2: DW1000 interferer map (for gap-fill only)
%% ========================================================================
fprintf('\n========== Pass 2: DW1000 interferer map ==========\n');
dw_opts = dw1000Options(file_name, fs_rx, x410_center_frequency, uwb_center_frequency);
dw_batch = batch;
dw_batch.save_individual_cir = false;
dw_batch.energy_threshold_sigma = 6;
dw_batch.output_directory = fullfile(out_root, 'pass2_interferer_map');
dw_batch.mat_file = fullfile(dw_batch.output_directory, 'interferer_map.mat');
dw_batch.summary_csv = fullfile(dw_batch.output_directory, 'interferer_map.csv');

results_dw = decode_uwb_all(dw_opts, dw_batch);
blank_raw = buildBlankIntervals(results_dw, ic);
% Never blank over already-found QM35 packets.
blank_intervals = protectQm35Intervals(blank_raw, results_base, ic);
fprintf('DW1000 frames                 : %d\n', results_dw.packet_count);
fprintf('Blank intervals (raw/protected): %d / %d\n', ...
    size(blank_raw, 1), size(blank_intervals, 1));
save(fullfile(out_root, 'blank_intervals.mat'), ...
    'blank_raw', 'blank_intervals', 'ic', 'results_dw', '-v7.3');


%% ========================================================================
%% Pass 3: gap-fill re-search with soft blanking
%% ========================================================================
fprintf('\n========== Pass 3: gap-fill re-search with soft blank ==========\n');
gaps = findPacketGaps(results_base, total_samples, ic.min_gap_samples);
fprintf('Large gaps to re-search       : %d\n', size(gaps, 1));

extra_frames = emptyFrameLike(results_base);
extra_count = 0;
tone_coeff = [];
if isfield(results_base_raw, 'params') && ...
        ~isempty(results_base_raw.params.interference_coefficient)
    tone_coeff = results_base_raw.params.interference_coefficient;
end

for g = 1:size(gaps, 1)
    g0 = gaps(g, 1) + ic.gap_edge_margin;
    g1 = gaps(g, 2) - ic.gap_edge_margin;
    if g1 - g0 < ic.gap_window_samples
        continue;
    end
    fprintf('  Gap %d: samples [%d, %d] (%.3f--%.3f ms)\n', ...
        g, g0, g1, g0/fs_rx*1e3, g1/fs_rx*1e3);

    % Blank intervals restricted to this gap (and already QM35-protected).
    local_blank = intersectIntervals(blank_intervals, g0, g1);
    offset = g0;
    while offset + ic.gap_window_samples <= g1
        wopts = qm_opts;
        wopts.sample_offset = offset;
        wopts.sample_num = ic.gap_window_samples;
        wopts.blank_intervals = local_blank;
        wopts.blank_weight = ic.blank_weight;
        wopts.blank_taper_samples = ic.blank_taper_samples;
        if ~isempty(tone_coeff)
            wopts.interference_coefficient = tone_coeff;
        end
        wopts.show_plots = false;
        wopts.verbose = false;

        try
            result = decode_uwb(wopts);
        catch
            offset = offset + ic.gap_step_samples;
            continue;
        end

        if ~isQm35LikeResult(result)
            offset = offset + ic.gap_step_samples;
            continue;
        end

        abs_start = offset + round( ...
            (result.preamble.start_sample-1)*fs_rx/result.phy_config.SampleRate);
        abs_start = max(0, abs_start);
        abs_end = estimateAbsEnd(offset, result, fs_rx);

        if isNearExisting(results_base, extra_frames, extra_count, abs_start, 8192)
            offset = max(offset + ic.gap_step_samples, abs_end);
            continue;
        end

        extra_count = extra_count + 1;
        extra_frames(extra_count) = packageExtraFrame( ...
            extra_count, offset, abs_start, abs_end, result, fs_rx);
        fprintf('    + recovered QM35 @ %.3f ms  SFD=%s  FCS=%d\n', ...
            abs_start/fs_rx*1e3, result.sfd.name, result.payload.fcs_pass);
        offset = max(offset + ic.gap_step_samples, abs_end);
    end
end

if extra_count == 0
    extra_frames = extra_frames([]);
else
    extra_frames = extra_frames(1:extra_count);
end
fprintf('Recovered in gaps             : %d\n', extra_count);

%% ========================================================================
%% Merge baseline + recoveries
%% ========================================================================
results = mergeQm35Results(results_base, extra_frames, fs_rx, total_samples);
results.ic = ic;
results.blank_intervals = blank_intervals;
results.baseline_count = results_base.packet_count;
results.recovered_count = extra_count;
results.gaps = gaps;
results.file_name = file_name;
results.duration_s = total_samples/fs_rx;

save(fullfile(out_root, 'gapfill_ic_results.mat'), ...
    'results', 'results_base', 'results_base_raw', 'results_dw', ...
    'extra_frames', 'blank_intervals', 'gaps', 'ic', '-v7.3');
writeSimpleCsv(fullfile(out_root, 'gapfill_summary.csv'), results.frames);

fprintf('\n========== Gap-fill IC summary ==========\n');
fprintf('Capture                       : %s\n', file_name);
fprintf('QM35 baseline (no IC)         : %d\n', results_base.packet_count);
fprintf('Recovered in gaps with IC     : %d\n', extra_count);
fprintf('QM35 total after merge        : %d\n', results.packet_count);
fprintf('FCS-pass total                : %d\n', results.fcs_pass_count);
fprintf('Output                        : %s\n', out_root);
fprintf('=========================================\n');

if results.packet_count > 0
    for k = 1:results.packet_count
        f = results.frames(k);
        tag = '';
        if isfield(f, 'recovered') && f.recovered
            tag = ' [gap-fill]';
        end
        fprintf(['#%03d  t=%.3f..%.3f ms  SFD=%s  corr=%.3f  ', ...
            'PSDU=%d  FCS=%d%s\n'], ...
            k, f.time_start_s*1e3, f.time_end_s*1e3, f.sfd_name, ...
            f.sfd_correlation, f.psdu_length_bytes, f.fcs_pass, tag);
    end
    plotTimeline(results, fullfile(out_root, 'gapfill_timeline.png'));
end

assignin('base', 'uwb_ic_results', results);
assignin('base', 'uwb_baseline_results', results_base);
assignin('base', 'blank_intervals', blank_intervals);

%% ------------------------------------------------------------------------
function options = baseRadioOptions(file_name, fs_rx, x410_fc, uwb_fc)
options = struct();
options.file_name = file_name;
options.ant_num = 1;
options.channel_index = 1;
options.fs_rx = fs_rx;
options.x410_center_frequency = x410_fc;
options.dw1000_center_frequency = uwb_fc;
options.decawave_sfd = [-1; -1; -1; -1; 1; -1; 0; 0];
options.ieee_sfd = [0; 1; 0; -1; 1; 0; 0; -1];
options.sfd4z_1 = [-1; -1; 1; -1];
options.sfd4z_2 = [-1; -1; -1; 1; -1; -1; 1; -1];
options.sfd4z_3 = [-1; -1; -1; -1; -1; 1; 1; -1; ...
    -1; 1; -1; 1; -1; -1; 1; -1];
options.sfd4z_4 = [-1; -1; -1; -1; -1; -1; -1; 1; ...
    -1; -1; 1; -1; -1; 1; -1; 1; -1; 1; -1; -1; ...
    -1; 1; 1; -1; -1; -1; 1; -1; 1; 1; -1; -1];
options.enable_interference_cancellation = true;
options.interference_quiet_offset = 400000;
options.interference_quiet_num = 262144;
options.interference_tone_bin = -169;
options.interference_period_samples = 512;
options.interference_coefficient = [];
options.blank_intervals = [];
options.blank_weight = 0;
options.blank_taper_samples = 512;
options.cir_pre_samples = 8;
options.cir_post_samples = 30;
options.cir_max_path_m = [];
options.max_psdu_bytes = 32;
options.enable_frame_crop = true;
options.verbose = false;
options.show_plots = false;
end

function options = qm35Options(file_name, fs_rx, x410_fc, uwb_fc)
options = baseRadioOptions(file_name, fs_rx, x410_fc, uwb_fc);
options.preamble_repetitions = 128;
options.cir_repetitions = 64;
options.code_index = 9;
options.data_rate = 6.81;
options.sfd_mode = 'auto';
end

function options = dw1000Options(file_name, fs_rx, x410_fc, uwb_fc)
options = baseRadioOptions(file_name, fs_rx, x410_fc, uwb_fc);
options.preamble_repetitions = 256;
options.cir_repetitions = 64;
options.code_index = 10;
options.data_rate = 6.81;
options.sfd_mode = 'auto';
end

function intervals = buildBlankIntervals(results_dw, ic)
intervals = zeros(0, 2);
for k = 1:results_dw.packet_count
    f = results_dw.frames(k);
    if f.sfd_correlation < ic.min_dw_sfd_corr
        continue;
    end
    name = lower(string(f.sfd_name));
    is_dw8 = contains(name, "decawave") || contains(name, "dw-8");
    if ic.require_dw_decawave_sfd && ~is_dw8
        continue;
    end
    a = max(0, f.abs_start_sample - ic.pad_pre_samples);
    b = f.abs_end_sample + ic.pad_post_samples;
    intervals(end+1, :) = [a, b]; %#ok<AGROW>
end
intervals = mergeIntervals(intervals, ic.merge_gap_samples);
end

function out = protectQm35Intervals(blank_intervals, results_qm35, ic)
% Remove / carve blank regions that cover already-found QM35 packets.
if isempty(blank_intervals) || results_qm35.packet_count == 0
    out = blank_intervals;
    return;
end
out = zeros(0, 2);
for i = 1:size(blank_intervals, 1)
    segs = blank_intervals(i, :);
    for k = 1:results_qm35.packet_count
        f = results_qm35.frames(k);
        p0 = max(0, f.abs_start_sample - ic.protect_qm35_pad);
        p1 = f.abs_end_sample + ic.protect_qm35_pad;
        segs = subtractInterval(segs, p0, p1);
        if isempty(segs)
            break;
        end
    end
    if ~isempty(segs)
        out = [out; segs]; %#ok<AGROW>
    end
end
if ~isempty(out)
    out = mergeIntervals(out, ic.merge_gap_samples);
end
end

function segs = subtractInterval(seg, p0, p1)
% Subtract [p0,p1] from one or more [a,b] rows.
if isempty(seg)
    segs = zeros(0, 2);
    return;
end
segs = zeros(0, 2);
for r = 1:size(seg, 1)
    a = seg(r, 1); b = seg(r, 2);
    if p1 < a || p0 > b
        segs(end+1, :) = [a, b]; %#ok<AGROW>
        continue;
    end
    if p0 > a
        segs(end+1, :) = [a, min(b, p0-1)]; %#ok<AGROW>
    end
    if p1 < b
        segs(end+1, :) = [max(a, p1+1), b]; %#ok<AGROW>
    end
end
end

function out = mergeIntervals(intervals, gap)
if isempty(intervals)
    out = zeros(0, 2);
    return;
end
intervals = sortrows(intervals, 1);
out = intervals(1, :);
for k = 2:size(intervals, 1)
    if intervals(k, 1) <= out(end, 2) + gap
        out(end, 2) = max(out(end, 2), intervals(k, 2));
    else
        out(end+1, :) = intervals(k, :); %#ok<AGROW>
    end
end
end

function out = intersectIntervals(intervals, g0, g1)
out = zeros(0, 2);
for k = 1:size(intervals, 1)
    a = max(intervals(k, 1), g0);
    b = min(intervals(k, 2), g1);
    if b > a
        out(end+1, :) = [a, b]; %#ok<AGROW>
    end
end
end

function gaps = findPacketGaps(results, total_samples, min_gap)
if results.packet_count == 0
    gaps = [0, total_samples-1];
    return;
end
starts = sort([results.frames.abs_start_sample]);
ends = sort([results.frames.abs_end_sample]);
% Build occupied union roughly from start-margin to end.
occ = [max(0, starts(:)-2e4), ends(:)+2e4];
occ = mergeIntervals(occ, 1e4);
gaps = zeros(0, 2);
cursor = 0;
for k = 1:size(occ, 1)
    if occ(k, 1) - cursor >= min_gap
        gaps(end+1, :) = [cursor, occ(k, 1)]; %#ok<AGROW>
    end
    cursor = max(cursor, occ(k, 2));
end
if total_samples - cursor >= min_gap
    gaps(end+1, :) = [cursor, total_samples-1];
end
end

function tf = isQm35LikeResult(result)
name = lower(string(result.sfd.name));
is_4z = contains(name, "4z") || contains(name, "802.15.4z");
tf = is_4z && result.phr.secded_pass && result.sfd.correlation >= 0.50;
end

function results = filterQm35Like(results)
if results.packet_count == 0
    return;
end
keep = false(results.packet_count, 1);
for k = 1:results.packet_count
    f = results.frames(k);
    name = lower(string(f.sfd_name));
    is_4z = contains(name, "4z") || contains(name, "802.15.4z");
    keep(k) = is_4z && f.phr_secded_pass && f.sfd_correlation >= 0.50;
end
idx = find(keep);
if isempty(idx)
    results.frames = results.frames([]);
    results.packet_count = 0;
    results.fcs_pass_count = 0;
    return;
end
results.frames = results.frames(idx);
for k = 1:numel(idx)
    results.frames(k).index = k;
    if ~isfield(results.frames(k), 'recovered')
        results.frames(k).recovered = false;
    end
end
results.packet_count = numel(idx);
results.fcs_pass_count = sum([results.frames.fcs_pass]);
end

function abs_end = estimateAbsEnd(offset, result, fs_rx)
fs_work = result.phy_config.SampleRate;
period = result.preamble.samples_per_repetition;
start_work = result.preamble.start_sample;
if ~isempty(result.payload.end_chip) && result.payload.end_chip > 0
    % Rough chip->sample map.
    end_work = start_work + result.payload.end_chip * (period/496);
else
    end_work = start_work + (result.settings.preamble_repetitions + 80) * period;
end
abs_end = offset + ceil(end_work * fs_rx / fs_work);
end

function tf = isNearExisting(base, extra, extra_count, abs_start, tol)
tf = false;
for k = 1:base.packet_count
    if abs(base.frames(k).abs_start_sample - abs_start) <= tol
        tf = true;
        return;
    end
end
for k = 1:extra_count
    if abs(extra(k).abs_start_sample - abs_start) <= tol
        tf = true;
        return;
    end
end
end

function frame = emptyFrameLike(results)
if results.packet_count > 0
    frame = results.frames([]);
else
    frame = struct('index', {}, 'window_offset', {}, 'abs_start_sample', {}, ...
        'abs_end_sample', {}, 'time_start_s', {}, 'time_end_s', {}, ...
        'sfd_name', {}, 'sfd_correlation', {}, 'phr_secded_pass', {}, ...
        'psdu_length_bytes', {}, 'payload_bytes', {}, 'fcs_received', {}, ...
        'fcs_calculated', {}, 'fcs_pass', {}, 'cir', {}, 'recovered', {});
end
end

function frame = packageExtraFrame(index, window_offset, abs_start, abs_end, result, fs_rx)
frame = struct();
frame.index = index;
frame.window_offset = window_offset;
frame.abs_start_sample = abs_start;
frame.abs_end_sample = abs_end;
frame.time_start_s = abs_start/fs_rx;
frame.time_end_s = abs_end/fs_rx;
frame.detected_repetitions = result.preamble.detected_repetitions;
frame.samples_per_repetition = result.preamble.samples_per_repetition;
frame.sample_clock_error_ppm = result.preamble.sample_clock_error_ppm;
frame.carrier_frequency_offset_hz = result.preamble.carrier_frequency_offset_hz;
frame.sfd_name = char(string(result.sfd.name));
frame.sfd_correlation = result.sfd.correlation;
frame.phr_secded_pass = logical(result.phr.secded_pass);
frame.psdu_length_bytes = result.phr.psdu_length_bytes;
if isempty(result.payload.bytes)
    frame.payload_bytes = uint8([]);
else
    frame.payload_bytes = result.payload.bytes(:).';
end
frame.fcs_received = result.payload.fcs_received;
frame.fcs_calculated = result.payload.fcs_calculated;
frame.fcs_pass = logical(result.payload.fcs_pass);
frame.cir = result.cir;
frame.recovered = true;
end

function results = mergeQm35Results(base, extra, fs_rx, total_samples)
results = base;
results.duration_s = total_samples/fs_rx;
if isempty(extra)
    return;
end
% Ensure recovered field on baseline.
for k = 1:results.packet_count
    results.frames(k).recovered = false;
end
all_frames = [results.frames(:); extra(:)];
% Sort by absolute start.
starts = [all_frames.abs_start_sample];
[~, order] = sort(starts);
all_frames = all_frames(order);
% Dedup
keep = true(numel(all_frames), 1);
for k = 2:numel(all_frames)
    if abs(all_frames(k).abs_start_sample - all_frames(k-1).abs_start_sample) <= 8192
        % Prefer FCS pass / higher SFD corr.
        prev = all_frames(k-1);
        cur = all_frames(k);
        take_cur = (cur.fcs_pass && ~prev.fcs_pass) || ...
            (cur.fcs_pass == prev.fcs_pass && cur.sfd_correlation > prev.sfd_correlation);
        if take_cur
            keep(k-1) = false;
        else
            keep(k) = false;
        end
    end
end
all_frames = all_frames(keep);
for k = 1:numel(all_frames)
    all_frames(k).index = k;
end
results.frames = all_frames;
results.packet_count = numel(all_frames);
results.fcs_pass_count = sum([all_frames.fcs_pass]);
if results.packet_count > 0
    results.cir_delay_ns = all_frames(1).cir.delay_ns(:);
    L = numel(results.cir_delay_ns);
    results.cir_values = complex(zeros(L, results.packet_count));
    for k = 1:results.packet_count
        v = all_frames(k).cir.values(:);
        n = min(L, numel(v));
        results.cir_values(1:n, k) = v(1:n);
    end
end
end

function writeSimpleCsv(csv_file, frames)
fid = fopen(csv_file, 'w');
if fid < 0
    return;
end
c = onCleanup(@() fclose(fid));
fprintf(fid, 'index,time_start_ms,time_end_ms,sfd,sfd_corr,psdu,fcs,recovered\n');
for k = 1:numel(frames)
    f = frames(k);
    rec = isfield(f, 'recovered') && f.recovered;
    fprintf(fid, '%d,%.6f,%.6f,"%s",%.4f,%d,%d,%d\n', ...
        k, f.time_start_s*1e3, f.time_end_s*1e3, f.sfd_name, ...
        f.sfd_correlation, f.psdu_length_bytes, f.fcs_pass, rec);
end
clear c;
end

function plotTimeline(results, png_path)
n = results.packet_count;
figure('Name', 'QM35 gap-fill IC timeline', 'Color', 'w', 'Position', [80 80 1000 380]);
hold on;
for k = 1:n
    f = results.frames(k);
    if isfield(f, 'recovered') && f.recovered
        col = [0.2 0.75 0.35];  % recovered
    elseif f.fcs_pass
        col = [0.2 0.55 0.9];
    else
        col = [0.9 0.45 0.2];
    end
    plot([f.time_start_s f.time_end_s]*1e3, [k k], '-', 'Color', col, 'LineWidth', 5);
    plot(f.time_start_s*1e3, k, 'o', 'MarkerFaceColor', col, 'MarkerEdgeColor', 'k');
end
set(gca, 'YDir', 'reverse');
xlabel('Time (ms)'); ylabel('Packet #');
title(sprintf('QM35 packets: baseline + gap-fill (total %d, +%d recovered)', ...
    results.packet_count, results.recovered_count));
grid on; box on;
ylim([0.5 n+0.5]);
if ~isempty(png_path)
    try
        exportgraphics(gcf, png_path, 'Resolution', 140);
    catch
        saveas(gcf, png_path);
    end
end
end
