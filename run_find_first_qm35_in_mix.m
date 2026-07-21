%% Find the first QM35 packet in a DW1000+QM35 mixed capture
% Branch: feature/two-packet-cir
%
% Searches from file start with the QM35 PHY profile (code 9, SYNC 128).
% After a successful lock, re-runs the pipeline on that window and plots:
%   - preamble matched-filter correlation (before CIR)
%   - spreading-code correlation / per-SYNC slices (before coherent CIR average)
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

%% -------------------- QM35 PHY (from run_decode / README) --------------------
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

options.cir_pre_samples = 8;
options.cir_post_samples = 30;
options.cir_max_path_m = [];
options.max_psdu_bytes = 32;
options.enable_frame_crop = true;
options.verbose = false;
options.show_plots = false;

%% -------------------- Interference cancellation --------------------
options.enable_interference_cancellation = true;
options.interference_quiet_offset = 400000;
options.interference_quiet_num = 262144;
options.interference_tone_bin = -169;
options.interference_period_samples = 512;
options.interference_coefficient = [];
options.blank_intervals = [];
options.blank_weight = 0;
options.blank_taper_samples = 256;

%% -------------------- Search control --------------------
search = struct();
search.window_samples = 1.0e6;
search.step_samples = 0.25e6;
search.max_search_samples = 40e6;
search.require_fcs_pass = true;
search.require_4z_sfd = false;
search.min_sfd_correlation = 0.50;
search.plot_pre_samples = 0.05e6;
search.plot_post_samples = 0.40e6;

%% -------------------- File size / interference once --------------------
info = dir(options.file_name);
if isempty(info)
    error('Capture not found: %s', options.file_name);
end
total_samples = floor(info.bytes/(options.ant_num*4));
search_limit = min(total_samples, search.max_search_samples);

base_params = dw1000decoder.mergeOptions(dw1000decoder.defaultOptions(), options);
if base_params.enable_interference_cancellation && ...
        isempty(base_params.interference_coefficient)
    probe = base_params;
    probe.sample_offset = 0;
    probe.sample_num = min(0.5e6, total_samples);
    [~, interf] = dw1000decoder.readAndCancelInterference(probe);
    if interf.enabled && ~isnan(interf.coefficient)
        options.interference_coefficient = interf.coefficient;
        fprintf('Reusing interference coefficient: |A|=%.3f  ang=%.1f deg\n', ...
            abs(interf.coefficient), angle(interf.coefficient)*180/pi);
    end
end

fprintf('\n========== Search first QM35 packet ==========\n');
fprintf('File                         : %s\n', options.file_name);
fprintf('Total samples                : %d (%.3f ms)\n', ...
    total_samples, total_samples/options.fs_rx*1e3);
fprintf('Search limit                 : %d (%.3f ms)\n', ...
    search_limit, search_limit/options.fs_rx*1e3);
fprintf('QM35 config                  : code=%d  SYNC=%d  rate=%.2f  sfd=%s\n', ...
    options.code_index, options.preamble_repetitions, ...
    options.data_rate, options.sfd_mode);
fprintf('Window / step                : %d / %d\n', ...
    search.window_samples, search.step_samples);
fprintf('================================================\n\n');

%% -------------------- Sliding-window search --------------------
found = false;
attempt = 0;
offset = 0;
qm35_result = [];
qm35_meta = struct();

t_search = tic;
while offset + search.window_samples <= search_limit
    attempt = attempt + 1;
    window_opts = options;
    window_opts.sample_offset = offset;
    window_opts.sample_num = search.window_samples;

    fprintf('---- Attempt %d | offset=%d (%.3f ms, %.1f%%) ----\n', ...
        attempt, offset, offset/options.fs_rx*1e3, ...
        100*offset/max(search_limit, 1));

    try
        result = decode_x410_dw1000(window_opts);
    catch ME
        fprintf('  decode failed: %s\n', ME.message);
        offset = offset + search.step_samples;
        continue;
    end

    abs_start = offset + round( ...
        (result.preamble.start_sample-1) * ...
        options.fs_rx / result.phy_config.SampleRate);
    abs_start = max(0, abs_start);

    is_4z = contains(lower(string(result.sfd.name)), "4z") || ...
        contains(lower(string(result.sfd.name)), "802.15.4z");
    ok_sfd = result.sfd.correlation >= search.min_sfd_correlation;
    ok_phr = logical(result.phr.secded_pass);
    ok_fcs = logical(result.payload.fcs_pass);
    ok_type = (~search.require_4z_sfd) || is_4z;
    ok_fcs_req = (~search.require_fcs_pass) || ok_fcs;

    fprintf(['  start~%d (%.3f ms)  SFD=%s  corr=%.3f  ', ...
        'PHR=%d  PSDU=%d B  FCS=%d\n'], ...
        abs_start, abs_start/options.fs_rx*1e3, result.sfd.name, ...
        result.sfd.correlation, ok_phr, result.phr.psdu_length_bytes, ok_fcs);

    if ok_sfd && ok_phr && ok_type && ok_fcs_req
        found = true;
        qm35_result = result;
        qm35_meta.attempt = attempt;
        qm35_meta.window_offset = offset;
        qm35_meta.abs_start_sample = abs_start;
        qm35_meta.time_start_s = abs_start / options.fs_rx;
        qm35_meta.is_4z_sfd = is_4z;
        fprintf('\n*** First QM35-like packet accepted ***\n');
        break;
    end

    fprintf('  rejected (sfd/phr/type/fcs gate).\n');
    jump = max(search.step_samples, round(0.15e6));
    offset = offset + jump;
end
search_seconds = toc(t_search);

if ~found
    error(['No QM35 packet found in the first %.3f ms. ', ...
        'Raise search.max_search_samples or relax search gates.'], ...
        search_limit/options.fs_rx*1e3);
end

%% -------------------- Re-run window with correlation diagnostics --------------------
% decode_x410_dw1000 does not export intermediate correlations; reprocess the
% accepted window and keep preamble / code-matched outputs before CIR average.
fprintf('\nReprocessing accepted window for correlation plots...\n');
diag_opts = options;
diag_opts.sample_offset = qm35_meta.window_offset;
diag_opts.sample_num = search.window_samples;
diag_opts.verbose = false;
[qm35_result, corr_diag] = decodeQm35WithCorrelationDiag(diag_opts);

% Refresh absolute start from refined diagnostics.
abs_start = qm35_meta.window_offset + round( ...
    (qm35_result.preamble.start_sample-1) * ...
    options.fs_rx / corr_diag.fs_work);
qm35_meta.abs_start_sample = max(0, abs_start);
qm35_meta.time_start_s = qm35_meta.abs_start_sample / options.fs_rx;

%% -------------------- Reload a plot window around the packet --------------------
plot_offset = max(0, qm35_meta.abs_start_sample - search.plot_pre_samples);
plot_num = min(total_samples - plot_offset, ...
    search.plot_pre_samples + search.plot_post_samples);
rx_plot = readIqSegment(options.file_name, plot_offset, plot_num, ...
    options.ant_num, options.channel_index);
t_plot = (plot_offset + (0:numel(rx_plot)-1).') / options.fs_rx;

figure('Name', 'First QM35 packet in mixed capture', 'Color', 'w', ...
    'Position', [60 60 1100 700]);

subplot(3, 1, 1);
plot(t_plot*1e3, real(rx_plot), 'b'); hold on;
plot(t_plot*1e3, imag(rx_plot), 'r');
xline(qm35_meta.time_start_s*1e3, 'k--', 'QM35 start', ...
    'LabelVerticalAlignment', 'bottom');
grid on;
xlabel('Time (ms)');
ylabel('ADC');
title(sprintf('I/Q around first QM35  |  start sample %d (%.3f ms)', ...
    qm35_meta.abs_start_sample, qm35_meta.time_start_s*1e3));
legend('I', 'Q', 'Location', 'best');

subplot(3, 1, 2);
plot(t_plot*1e3, abs(rx_plot), 'k');
xline(qm35_meta.time_start_s*1e3, 'k--');
grid on;
xlabel('Time (ms)');
ylabel('|IQ|');
title('Envelope');

subplot(3, 1, 3);
if ~isempty(qm35_result.cir.values)
    plot(qm35_result.cir.delay_ns, abs(qm35_result.cir.values)/( ...
        max(abs(qm35_result.cir.values))+eps), 'b', 'LineWidth', 1.4);
    grid on;
    xlabel('Relative delay (ns)');
    ylabel('Normalized |CIR|');
    title(sprintf('QM35 CIR (after average)  |  SFD=%s  corr=%.3f  FCS=%d', ...
        qm35_result.sfd.name, qm35_result.sfd.correlation, ...
        qm35_result.payload.fcs_pass));
end

sgtitle(sprintf('%s — first QM35 lock', options.file_name), ...
    'Interpreter', 'none');

%% -------------------- Preamble correlation (before CIR) --------------------
figure('Name', 'QM35 preamble correlation', 'Color', 'w', ...
    'Position', [80 40 1100 720]);

% Map ROI-local score indices to absolute work-rate samples if needed.
score = corr_diag.preamble_score(:);
metric = corr_diag.preamble_metric(:);
peaks = corr_diag.preamble_peaks(:);
start_sample = corr_diag.preamble_start_sample;
thr = corr_diag.preamble_threshold;
roi_start = corr_diag.preamble_roi_start;
fs_work = corr_diag.fs_work;
samples_per_symbol = corr_diag.samples_per_symbol;

score_abs_idx = roi_start + (0:numel(score)-1).';
% Metric is shorter: aligned to score start in trackPreambleInRoi.
metric_abs_idx = roi_start + (0:numel(metric)-1).';

subplot(3, 1, 1);
plot(score_abs_idx, score, 'b'); hold on;
yline(thr, 'k--', 'threshold');
if ~isempty(peaks)
    plot(peaks, score(max(1, min(numel(score), peaks-roi_start+1))), ...
        'ro', 'MarkerSize', 4);
end
xline(start_sample, 'g--', 'preamble start');
grid on;
xlabel('Work-rate sample index (in decode window, cropped coords)');
ylabel('Normalized |matched|');
title(sprintf([ ...
    'Preamble symbol matched-filter score (code %d template)  |  ', ...
    '%d peaks  thr=%.3f'], ...
    options.code_index, numel(peaks), thr));
legend('score', 'threshold', 'peaks', 'Location', 'best');

subplot(3, 1, 2);
plot(metric_abs_idx, metric, 'Color', [0.1 0.5 0.2], 'LineWidth', 1.1); hold on;
[metric_peak, metric_peak_i] = max(metric);
plot(metric_abs_idx(metric_peak_i), metric_peak, 'ro', 'MarkerFaceColor', 'r');
xline(start_sample, 'g--');
grid on;
xlabel('Work-rate sample index');
ylabel('16-symbol accum. metric');
title(sprintf('Preamble accumulated metric  |  peak=%.3f', metric_peak));

subplot(3, 1, 3);
% Zoom around preamble: start to start + a few symbols past SYNC.
zoom0 = max(score_abs_idx(1), start_sample - 2*samples_per_symbol);
zoom1 = min(score_abs_idx(end), start_sample + ...
    (options.preamble_repetitions + 16)*corr_diag.measured_period);
in_zoom = score_abs_idx >= zoom0 & score_abs_idx <= zoom1;
plot(score_abs_idx(in_zoom), score(in_zoom), 'b'); hold on;
yline(thr, 'k--');
pk_zoom = peaks(peaks >= zoom0 & peaks <= zoom1);
if ~isempty(pk_zoom)
    pk_local = pk_zoom - roi_start + 1;
    pk_local = pk_local(pk_local >= 1 & pk_local <= numel(score));
    plot(pk_zoom(1:numel(pk_local)), score(pk_local), 'ro', 'MarkerSize', 4);
end
xline(start_sample, 'g--', 'start');
grid on;
xlabel('Work-rate sample index');
ylabel('score');
title('Preamble score zoom around SYNC');

sgtitle('QM35 preamble correlation (before CIR accumulation)', ...
    'Interpreter', 'none');

%% -------------------- Code correlation (before CIR accumulation) --------------------
figure('Name', 'QM35 code correlation (pre-CIR average)', 'Color', 'w', ...
    'Position', [100 40 1100 760]);

code_axis = corr_diag.code_axis(:);
code_corr = corr_diag.code_corr(:);
delay_ns = corr_diag.delay_ns(:);
individual = corr_diag.individual_raw;   % before coherent average / L2 norm
rep_starts = corr_diag.rep_nominal_ends;

subplot(3, 1, 1);
plot(code_axis, abs(code_corr), 'b'); hold on;
if ~isempty(rep_starts)
    for k = 1:numel(rep_starts)
        xline(rep_starts(k), 'Color', [0.85 0.4 0.1], 'LineStyle', ':', ...
            'HandleVisibility', 'off');
    end
    xline(rep_starts(1), 'Color', [0.85 0.4 0.1], 'LineStyle', ':', ...
        'DisplayName', 'SYNC code-end positions');
end
xline(start_sample, 'g--', 'preamble start');
grid on;
xlabel('Work-rate sample index');
ylabel('|code matched filter|');
title(sprintf([ ...
    'Spreading-code correlation over CIR window  |  code_index=%d  ', ...
    'L=%d taps'], options.code_index, corr_diag.code_length));
legend('Location', 'best');

subplot(3, 1, 2);
if ~isempty(individual)
    ind_mag = abs(individual);
    % Peak-normalize each SYNC slice for shape comparison (pre-average).
    ind_n = ind_mag ./ (max(ind_mag, [], 1) + eps);
    h_ind = plot(delay_ns, ind_n, 'Color', [0.75 0.75 0.75]);
    set(h_ind(2:end), 'HandleVisibility', 'off'); hold on;
    mean_raw = mean(individual, 2);
    mean_n = abs(mean_raw) / (max(abs(mean_raw)) + eps);
    h_mean = plot(delay_ns, mean_n, 'r', 'LineWidth', 1.8);
    xline(0, 'k--', 'nominal peak');
    grid on;
    xlabel('Relative delay (ns)');
    ylabel('Normalized |slice|');
    title(sprintf([ ...
        'Per-SYNC code-correlation slices BEFORE coherent CIR average ', ...
        '(%d reps)'], size(individual, 2)));
    legend([h_ind(1), h_mean], 'Individual SYNC', 'Simple mean (pre-L2)', ...
        'Location', 'best');
else
    text(0.1, 0.5, 'No individual code slices available', 'Units', 'normalized');
    axis off;
end

subplot(3, 1, 3);
if ~isempty(individual)
    % Show unnormalized |individual| energy vs repetition index (pre-average).
    energy = sqrt(sum(abs(individual).^2, 1)).';
    stem(1:numel(energy), energy, 'filled');
    grid on;
    xlabel('SYNC repetition used for CIR (in averaging set)');
    ylabel('Slice L2 energy');
    title('Per-SYNC code-slice energy (before coherent average / L2 normalize)');
end

sgtitle('QM35 spreading-code correlation (before CIR accumulation)', ...
    'Interpreter', 'none');

%% -------------------- Summary --------------------
fprintf('\n========== First QM35 packet summary ==========\n');
fprintf('Search time                  : %.2f s  (%d attempts)\n', ...
    search_seconds, attempt);
fprintf('Window offset                : %d\n', qm35_meta.window_offset);
fprintf('Absolute start sample        : %d\n', qm35_meta.abs_start_sample);
fprintf('Absolute start time          : %.6f ms\n', qm35_meta.time_start_s*1e3);
fprintf('Detected SYNC reps           : %d\n', ...
    qm35_result.preamble.detected_repetitions);
fprintf('Sample-clock error           : %.3f ppm\n', ...
    qm35_result.preamble.sample_clock_error_ppm);
fprintf('CFO                          : %.3f kHz\n', ...
    qm35_result.preamble.carrier_frequency_offset_hz/1e3);
fprintf('SFD                          : %s  corr=%.4f\n', ...
    qm35_result.sfd.name, qm35_result.sfd.correlation);
fprintf('PHR SECDED                   : %d\n', qm35_result.phr.secded_pass);
fprintf('PSDU length                  : %d bytes\n', ...
    qm35_result.phr.psdu_length_bytes);
if ~isempty(qm35_result.payload.bytes)
    fprintf('PSDU bytes                   : ');
    fprintf('%02X ', qm35_result.payload.bytes);
    fprintf('\n');
end
fprintf('FCS                          : rx=0x%04X calc=0x%04X pass=%d\n', ...
    qm35_result.payload.fcs_received, qm35_result.payload.fcs_calculated, ...
    qm35_result.payload.fcs_pass);
fprintf('=================================================\n');

assignin('base', 'qm35_first_result', qm35_result);
assignin('base', 'qm35_first_meta', qm35_meta);
assignin('base', 'qm35_first_options', options);
assignin('base', 'qm35_corr_diag', corr_diag);

out_dir = fullfile(project_dir, 'decoded_results', 'qm35_dw1000_1_first_qm35');
if ~isfolder(out_dir)
    mkdir(out_dir);
end
save(fullfile(out_dir, 'first_qm35_packet.mat'), ...
    'qm35_result', 'qm35_meta', 'options', 'corr_diag', '-v7.3');
figs = findall(0, 'Type', 'figure');
for k = 1:numel(figs)
    try
        exportgraphics(figs(k), fullfile(out_dir, sprintf('fig_%d.png', k)), ...
            'Resolution', 140);
    catch
        try
            saveas(figs(k), fullfile(out_dir, sprintf('fig_%d.png', k)));
        catch
        end
    end
end
fprintf('Saved: %s\n', out_dir);

%% ========================================================================
function [result, diag] = decodeQm35WithCorrelationDiag(options)
%DECODEQM35WITHCORRELATIONDIAG Same pipeline as decode_x410_dw1000, but keeps
%preamble score and pre-average code-correlation slices for plotting.

params = dw1000decoder.mergeOptions(dw1000decoder.defaultOptions(), options);
addpath(params.helper_path);

[rx, interference] = dw1000decoder.readAndCancelInterference(params);
rx = dw1000decoder.compensateCenterFrequency(rx, params);
reference = dw1000decoder.buildDw1000Reference(params);
rx_work = dw1000decoder.resampleCapture(rx, params.fs_rx, reference.fs);

preamble = dw1000decoder.detectRepeatedPreamble(rx_work, reference, params);
dw1000decoder.validateCaptureLength(rx_work, preamble, reference, params);

if params.enable_frame_crop
    [rx_work, preamble] = dw1000decoder.cropToFrame( ...
        rx_work, preamble, reference, params);
end

[rx_work, preamble] = dw1000decoder.compensateCarrierOffset( ...
    rx_work, preamble, reference, params);
preamble = dw1000decoder.refineTimingWithNsSfd( ...
    rx_work, preamble, reference, params);
sfd_symbols = dw1000decoder.analyzeNsSfdSymbols( ...
    rx_work, preamble, reference, params);

% --- Code correlation before CIR accumulation (local MF over CIR region) ---
code = reference.sampled_code(:);
code_mf = flipud(conj(code));
code_length = numel(code);
if ~isempty(params.cir_pre_samples)
    pre_samples = params.cir_pre_samples;
else
    pre_samples = preamble.search_half_width;
end
if ~isempty(params.cir_post_samples)
    post_samples = params.cir_post_samples;
else
    post_samples = max(1, round(100e-9*reference.fs));
end
offsets = (-pre_samples:post_samples-1).';
delay_ns = offsets/reference.fs*1e9;

repetition_count = min(params.cir_repetitions, ...
    min(preamble.detected_repetitions, params.preamble_repetitions));
first_repetition = max(0, params.preamble_repetitions-repetition_count);
last_repetition = first_repetition+repetition_count-1;

first_nominal_end = preamble.start_sample+first_repetition* ...
    preamble.measured_period+code_length-1;
last_nominal_end = preamble.start_sample+last_repetition* ...
    preamble.measured_period+code_length-1;
filter_start = first_nominal_end+offsets(1);
filter_end = last_nominal_end+offsets(end);

% Local matched filter over the CIR support (same as estimateCirAndSoftChips).
tap_count = numel(code_mf);
abs_start = max(1, floor(filter_start)-tap_count+1);
abs_end = min(numel(rx_work), ceil(filter_end));
segment = rx_work(abs_start:abs_end);
filtered = filter(code_mf, 1, segment);
code_axis = abs_start + (0:numel(filtered)-1).';
code_corr = filtered(:);

individual_raw = complex(zeros(length(offsets), repetition_count));
rep_nominal_ends = zeros(repetition_count, 1);
valid_count = 0;
for repetition = first_repetition:last_repetition
    repetition_start = preamble.start_sample+repetition*preamble.measured_period;
    nominal_end = repetition_start+code_length-1;
    positions = nominal_end+offsets;
    values = interp1(code_axis, code_corr, positions, 'linear', NaN);
    if any(isnan(values))
        continue;
    end
    valid_count = valid_count+1;
    individual_raw(:, valid_count) = values(:);
    rep_nominal_ends(valid_count) = nominal_end;
end
individual_raw = individual_raw(:, 1:valid_count);
rep_nominal_ends = rep_nominal_ends(1:valid_count);

% Finish normal CIR / decode path via package functions.
[cir, chips] = dw1000decoder.estimateCirAndSoftChips( ...
    rx_work, preamble, reference, params);
sfd = dw1000decoder.locateNsSfd(chips.soft, reference, params, preamble);
frame = dw1000decoder.decodePhrAndPayload(chips.soft, sfd, reference.cfg);
result = dw1000decoder.packageResult(params, reference, interference, ...
    preamble, sfd_symbols, cir, chips, sfd, frame);

% Preamble score may be ROI-relative.
if isfield(preamble, 'matched_is_roi') && preamble.matched_is_roi
    roi_start = preamble.roi_start;
else
    roi_start = 1;
end

diag = struct();
diag.fs_work = reference.fs;
diag.samples_per_symbol = reference.samples_per_symbol;
diag.measured_period = preamble.measured_period;
diag.preamble_score = preamble.score;
diag.preamble_metric = preamble.metric;
diag.preamble_peaks = preamble.peaks;
diag.preamble_start_sample = preamble.start_sample;
diag.preamble_threshold = preamble.threshold;
diag.preamble_roi_start = roi_start;
diag.code_axis = code_axis;
diag.code_corr = code_corr;
diag.code_length = code_length;
diag.delay_ns = delay_ns;
diag.individual_raw = individual_raw;
diag.rep_nominal_ends = rep_nominal_ends;
diag.pre_samples = pre_samples;
diag.post_samples = post_samples;
end

function rx = readIqSegment(file_name, sample_offset, sample_num, ant_num, channel_index)
fid = fopen(file_name, 'rb');
if fid < 0
    error('Cannot open %s', file_name);
end
cleanup_obj = onCleanup(@() fclose(fid));
fseek(fid, sample_offset*ant_num*4, 'bof');
raw = fread(fid, [2*ant_num, sample_num], 'int16=>double');
clear cleanup_obj;
if size(raw, 2) < 1
    error('Failed to read IQ segment at offset %d.', sample_offset);
end
rx = raw(2*channel_index-1, :).' + 1j*raw(2*channel_index, :).';
end
