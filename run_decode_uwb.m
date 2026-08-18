%% DW1000 X410 capture decoder entry script
% Profiles wall-clock time of every decode stage and prints a breakdown.
clear;
close all;
clc;

%% Input capture
options = struct();
options.file_name = 'D:\bupt\project\UWB基带数据\dw1000_new_processed_1.dat';
options.sample_offset = 0;
% Enough RX samples for a late-aligned 256-SYNC frame; soft chips are still
% limited to a budgeted frame span (not the whole buffer).
options.sample_num = 1.5e6;
options.ant_num = 1;
options.channel_index = 1;

%% X410 and DW1000 radio configuration
options.fs_rx = 737.28e6;
options.x410_center_frequency = 6500e6;
options.dw1000_center_frequency = 6489.6e6;
% QM35_1.dat contains a 128-symbol SYNC field. A value of 256 moves the
% expected SFD boundary 128 symbols into the PHR/payload.
options.preamble_repetitions = 256;
% Number of final preamble repetitions coherently averaged for CIR.
% Set to 256 to use the complete preamble.
options.cir_repetitions = 64;
% CIR multipath window at the HRP work rate (~998.4 MHz):
%   pre=8, post=30 -> 38 samples (~38 ns). Indoor excess path 20 m would be
%   ~67 samples; 30 is a tighter window for strong near multipath.
options.cir_pre_samples = 8;
options.cir_post_samples = 30;
% Optional alternative: set cir_post_samples=[] and e.g. cir_max_path_m=20
% to size the positive delay axis from a maximum excess path length.
options.cir_max_path_m = [];
options.code_index = 10;
options.data_rate = 6.81;

% Automatically test the SFDs allowed by the configured PHY/code family.
options.sfd_mode = 'auto';
% Decawave-defined 8-symbol SFD (DW-8): ----+-00
options.decawave_sfd = [-1; -1; -1; -1; 1; -1; 0; 0];
% IEEE 802.15.4 short SFD: 0+0-+00-
options.ieee_sfd = [0; 1; 0; -1; 1; 0; 0; -1];
% IEEE 802.15.4z SFD #1--#4 (lengths 4, 8, 16, and 32 symbols).
options.sfd4z_1 = [-1; -1; 1; -1];
options.sfd4z_2 = [-1; -1; -1; 1; -1; -1; 1; -1];
options.sfd4z_3 = [-1; -1; -1; -1; -1; 1; 1; -1; ...
    -1; 1; -1; 1; -1; -1; 1; -1];
options.sfd4z_4 = [-1; -1; -1; -1; -1; -1; -1; 1; ...
    -1; -1; 1; -1; -1; 1; -1; 1; -1; 1; -1; -1; ...
    -1; 1; 1; -1; -1; -1; 1; -1; 1; 1; -1; -1];

%% Clock-synchronous interference cancellation
options.enable_interference_cancellation = true;
options.interference_quiet_offset = 400000;
% 256k samples is enough for a stable tone estimate and much cheaper than 1.5e6.
options.interference_quiet_num = 262144;
options.interference_tone_bin = -169;
options.interference_period_samples = 512;

%% Speed / span controls
% Soft chips always run to the end of the work buffer (required by
% helperUWBBPRFDemod). Frame crop only drops samples *before* the packet.
% 12-byte frames need ~1.54e5 soft chips; 32 B leaves margin without a huge FIR.
options.max_psdu_bytes = 32;
options.enable_frame_crop = true;
options.verbose = false;

%% Output control
options.show_plots = false;
% Script-only flag (not a decoder option; do not put in options struct).
show_timing_plot = true;

%% Timing bookkeeping
timing = struct('id', {}, 'name', {}, 'group', {}, 'seconds', {});
total_timer = tic;

%% Step 0: Merge configuration
step_timer = tic;
params = uwbdecoder.mergeOptions( ...
    uwbdecoder.defaultOptions(), options);
addpath(params.helper_path);
timing = appendTiming(timing, 0, 'mergeOptions + addpath', 'setup', ...
    toc(step_timer));

%% Step 1: Read capture and cancel interference
% Variables retained: params, rx_capture, interference
step_timer = tic;
[rx_capture, interference] = ...
    uwbdecoder.readAndCancelInterference(params);
timing = appendTiming(timing, 1, 'readAndCancelInterference', 'io_front', ...
    toc(step_timer));

%% Step 2: Compensate the X410/DW1000 center-frequency difference
% Variable retained: rx_baseband
step_timer = tic;
rx_baseband = uwbdecoder.compensateCenterFrequency( ...
    rx_capture, params);
timing = appendTiming(timing, 2, 'compensateCenterFrequency', 'io_front', ...
    toc(step_timer));

%% Step 3: Build the waveform and sparse spreading-code references
% Variable retained: reference
step_timer = tic;
reference = uwbdecoder.buildUwbReference(params);
timing = appendTiming(timing, 3, 'buildUwbReference', 'setup', ...
    toc(step_timer));

%% Step 4: Resample the capture to the HRP working sample rate
% Variable retained: rx_work
step_timer = tic;
rx_work = uwbdecoder.resampleCapture( ...
    rx_baseband, params.fs_rx, reference.fs);
timing = appendTiming(timing, 4, 'resampleCapture', 'io_front', ...
    toc(step_timer));

%% Step 5: Detect and track the repeated preamble symbols
% Variable retained: preamble_detected
step_timer = tic;
preamble_detected = uwbdecoder.detectRepeatedPreamble( ...
    rx_work, reference, params);
uwbdecoder.validateCaptureLength( ...
    rx_work, preamble_detected, reference, params);
timing = appendTiming(timing, 5, 'detectRepeatedPreamble + validate', ...
    'preamble', toc(step_timer));

%% Step 5b: Crop work buffer to the active frame (major speedup)
step_timer = tic;
if params.enable_frame_crop
    [rx_work, preamble_detected, crop_info] = uwbdecoder.cropToFrame( ...
        rx_work, preamble_detected, reference, params); %#ok<ASGLU>
else
    crop_info = struct('cropped_length', numel(rx_work));
end
timing = appendTiming(timing, 5.2, 'cropToFrame', 'preamble', toc(step_timer));

if params.show_plots
    step_timer = tic;
    uwbdecoder.plotPreambleDetection( ...
        preamble_detected, reference, params);
    timing = appendTiming(timing, 5.1, 'plotPreambleDetection', 'plot', ...
        toc(step_timer));
end

%% Step 6: Estimate and compensate carrier-frequency/phase offset
% Variables retained: rx_corrected, preamble_cfo
step_timer = tic;
[rx_corrected, preamble_cfo] = uwbdecoder.compensateCarrierOffset( ...
    rx_work, preamble_detected, reference, params);
timing = appendTiming(timing, 6, 'compensateCarrierOffset', 'preamble', ...
    toc(step_timer));

%% Step 7: Select the SFD type and refine timing at full rate
% Variable retained: preamble_refined
step_timer = tic;
preamble_refined = uwbdecoder.refineTimingWithNsSfd( ...
    rx_corrected, preamble_cfo, reference, params);
timing = appendTiming(timing, 7, 'refineTimingWithNsSfd', 'sfd', ...
    toc(step_timer));

%% Step 8: Inspect the selected SFD at preamble-symbol resolution
% Variable retained: sfd_symbols
step_timer = tic;
sfd_symbols = uwbdecoder.analyzeNsSfdSymbols( ...
    rx_corrected, preamble_refined, reference, params);
timing = appendTiming(timing, 8, 'analyzeNsSfdSymbols', 'sfd', ...
    toc(step_timer));

%% Step 9: Estimate CIR by spreading-code correlation and form soft chips
% Variables retained: cir, chips
step_timer = tic;
[cir, chips] = uwbdecoder.estimateCirAndSoftChips( ...
    rx_corrected, preamble_refined, reference, params);
timing = appendTiming(timing, 9, 'estimateCirAndSoftChips', 'cir', ...
    toc(step_timer));

if params.show_plots
    step_timer = tic;
    uwbdecoder.plotDespreadCir(cir, params);
    timing = appendTiming(timing, 9.1, 'plotDespreadCir', 'plot', ...
        toc(step_timer));
end

%% Step 10: Locate the selected SFD in the soft-chip stream
% Variable retained: sfd
step_timer = tic;
sfd = uwbdecoder.locateNsSfd( ...
    chips.soft, reference, params, preamble_refined);
timing = appendTiming(timing, 10, 'locateNsSfd', 'decode', toc(step_timer));

if params.show_plots
    step_timer = tic;
    uwbdecoder.plotSfdDetection(sfd);
    timing = appendTiming(timing, 10.1, 'plotSfdDetection', 'plot', ...
        toc(step_timer));
end

%% Step 11: Decode the PHR, PSDU, and frame CRC
% Variable retained: frame
step_timer = tic;
frame = uwbdecoder.decodePhrAndPayload( ...
    chips.soft, sfd, reference.cfg);
timing = appendTiming(timing, 11, 'decodePhrAndPayload', 'decode', ...
    toc(step_timer));

%% Step 12: Package all stage outputs into one optional result structure
step_timer = tic;
result = uwbdecoder.packageResult(params, reference, interference, ...
    preamble_refined, sfd_symbols, cir, chips, sfd, frame);
timing = appendTiming(timing, 12, 'packageResult', 'setup', toc(step_timer));

total_seconds = toc(total_timer);
[timing_table, group_table] = buildTimingTables(timing, total_seconds);
result.timing = timing_table;
result.timing_by_group = group_table;
result.timing_total_seconds = total_seconds;

%% Print a compact decoding summary
fprintf('\n========== DW1000 decoding summary ==========\n');
fprintf('Preamble repetitions detected : %d\n', ...
    result.preamble.detected_repetitions);
fprintf('Measured preamble period      : %.6f samples\n', ...
    result.preamble.samples_per_repetition);
fprintf('Sample-clock error            : %.3f ppm\n', ...
    result.preamble.sample_clock_error_ppm);
fprintf('Carrier-frequency offset      : %.3f kHz\n', ...
    result.preamble.carrier_frequency_offset_hz/1e3);
fprintf('CIR length                    : %d samples\n', ...
    numel(result.cir.values));
fprintf('CIR repetitions averaged      : %d\n', ...
    result.cir.repetition_count);
fprintf('Selected SFD template         : %s\n', result.sfd.name);
fprintf('Selected SFD correlation      : %.4f\n', ...
    result.sfd.correlation);
fprintf('PHR SECDED pass               : %d\n', ...
    result.phr.secded_pass);
fprintf('Decoded PSDU length           : %d bytes\n', ...
    result.phr.psdu_length_bytes);

if ~isempty(result.payload.bytes)
    fprintf('Decoded PSDU bytes            : ');
    fprintf('%02X ', result.payload.bytes);
    fprintf('\n');
end

fprintf('Received FCS                  : 0x%04X\n', ...
    result.payload.fcs_received);
fprintf('Calculated FCS                : 0x%04X\n', ...
    result.payload.fcs_calculated);
fprintf('FCS pass                      : %d\n', ...
    result.payload.fcs_pass);
fprintf('==============================================\n');

%% Print and visualize per-step timing analysis
printTimingReport(timing_table, group_table, total_seconds, params.show_plots);
if show_timing_plot
    plotTimingBreakdown(timing_table, group_table, total_seconds);
end

% Convenience variables in the base workspace.
assignin('base', 'timing_table', timing_table);
assignin('base', 'timing_by_group', group_table);
assignin('base', 'timing_total_seconds', total_seconds);

%% ------------------------------------------------------------------------
function timing = appendTiming(timing, id, name, group, seconds)
timing(end+1).id = id; %#ok<AGROW>
timing(end).name = name;
timing(end).group = group;
timing(end).seconds = seconds;
fprintf('[timing] %04.1f %-36s %8.3f s  (%s)\n', ...
    id, name, seconds, group);
end

function [timing_table, group_table] = buildTimingTables(timing, total_seconds)
ids = [timing.id].';
names = string({timing.name}).';
groups = string({timing.group}).';
seconds = [timing.seconds].';
share_pct = 100*seconds/max(total_seconds, eps);
milliseconds = 1000*seconds;

timing_table = table(ids, names, groups, seconds, milliseconds, share_pct, ...
    'VariableNames', {'id', 'step', 'group', 'seconds', 'milliseconds', 'share_pct'});
timing_table = sortrows(timing_table, 'id', 'ascend');

group_order = ["setup", "io_front", "preamble", "sfd", "cir", "decode", "plot"];
group_seconds = zeros(numel(group_order), 1);
for k = 1:numel(group_order)
    group_seconds(k) = sum(seconds(groups == group_order(k)));
end
group_share = 100*group_seconds/max(total_seconds, eps);
group_table = table(group_order(:), group_seconds, 1000*group_seconds, ...
    group_share, ...
    'VariableNames', {'group', 'seconds', 'milliseconds', 'share_pct'});
end

function printTimingReport(timing_table, group_table, total_seconds, show_plots)
fprintf('\n========== Per-step timing analysis ==========\n');
fprintf('Total wall time                : %.3f s (%.1f ms)\n', ...
    total_seconds, 1000*total_seconds);
if show_plots
    fprintf(['Note: plot* steps include figure rendering ', ...
        '(set show_plots=false for algorithm-only timing).\n']);
end

fprintf('\n--- Steps in pipeline order ---\n');
fprintf('%-5s %-36s %-10s %10s %10s %9s\n', ...
    'ID', 'Step', 'Group', 'Seconds', 'ms', 'Share %');
fprintf('%s\n', repmat('-', 1, 86));
for k = 1:height(timing_table)
    fprintf('%-5.1f %-36s %-10s %10.3f %10.1f %8.1f%%\n', ...
        timing_table.id(k), timing_table.step(k), timing_table.group(k), ...
        timing_table.seconds(k), timing_table.milliseconds(k), ...
        timing_table.share_pct(k));
end
fprintf('%s\n', repmat('-', 1, 86));
fprintf('%-5s %-36s %-10s %10.3f %10.1f %8.1f%%\n', ...
    '', 'TOTAL', '', total_seconds, 1000*total_seconds, 100);

fprintf('\n--- Aggregated by pipeline group ---\n');
fprintf('%-12s %10s %10s %9s\n', 'Group', 'Seconds', 'ms', 'Share %');
fprintf('%s\n', repmat('-', 1, 46));
for k = 1:height(group_table)
    if group_table.seconds(k) <= 0 && group_table.group(k) == "plot"
        continue;
    end
    fprintf('%-12s %10.3f %10.1f %8.1f%%\n', ...
        group_table.group(k), group_table.seconds(k), ...
        group_table.milliseconds(k), group_table.share_pct(k));
end

ranked = sortrows(timing_table, 'seconds', 'descend');
fprintf('\n--- Top steps by runtime ---\n');
top_n = min(5, height(ranked));
for k = 1:top_n
    fprintf('  %d) [%.1f] %-32s %8.3f s (%5.1f%%)\n', ...
        k, ranked.id(k), ranked.step(k), ranked.seconds(k), ranked.share_pct(k));
end

is_plot = timing_table.group == "plot";
core_seconds = sum(timing_table.seconds(~is_plot));
plot_seconds = sum(timing_table.seconds(is_plot));
fprintf('\nCore decode (no plots)         : %.3f s (%.1f%%)\n', ...
    core_seconds, 100*core_seconds/max(total_seconds, eps));
fprintf('Plotting only                  : %.3f s (%.1f%%)\n', ...
    plot_seconds, 100*plot_seconds/max(total_seconds, eps));

% Sum of timed steps may be slightly under total_seconds due to glue code.
accounted = sum(timing_table.seconds);
fprintf('Accounted by timed steps       : %.3f s (%.1f%% of wall time)\n', ...
    accounted, 100*accounted/max(total_seconds, eps));
fprintf('==============================================\n');
end

function plotTimingBreakdown(timing_table, group_table, total_seconds)
figure('Name', 'Decode stage timing', 'Color', 'w', 'Position', [100 100 960 520]);

subplot(1, 2, 1);
barh(timing_table.seconds);
set(gca, 'YTick', 1:height(timing_table), ...
    'YTickLabel', timing_table.step, 'YDir', 'reverse');
xlabel('Seconds');
title(sprintf('Per-step time (total %.3f s)', total_seconds));
grid on;

subplot(1, 2, 2);
active = group_table.seconds > 0 | group_table.group ~= "plot";
groups = group_table(active, :);
bar(groups.seconds);
set(gca, 'XTick', 1:height(groups), 'XTickLabel', groups.group);
xtickangle(30);
ylabel('Seconds');
title('Time by pipeline group');
grid on;

sgtitle('run\_decode\_x410\_dw1000 timing breakdown');
drawnow;
end
