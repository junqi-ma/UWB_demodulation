%% Find the first QM35 packet in a DW1000+QM35 mixed capture
% Branch: feature/two-packet-cir
%
% The capture (qm35_dw1000_1.dat) contains overlapped / interleaved DW1000 and
% QM35 UWB bursts. This script searches from the file start using the QM35 PHY
% configuration taken from run_decode_x410_dw1000_all / README:
%   preamble_repetitions = 128, code_index = 9, data_rate = 6.81, sfd_mode=auto
%
% DW1000 in this project typically uses code 10 + 256-symbol SYNC, so decoding
% with the QM35 profile preferentially locks onto QM35 frames.
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
% Same RF center assumption as run_decode_* for the DW1000/QM35 family.
options.dw1000_center_frequency = 6489.6e6;

%% -------------------- QM35 PHY (from run_decode / README) --------------------
options.preamble_repetitions = 128;
options.cir_repetitions = 64;
options.code_index = 9;
options.data_rate = 6.81;
options.sfd_mode = 'auto';   % QM35_1.dat typically selects IEEE 802.15.4z SFD #2
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

%% -------------------- Search control --------------------
search = struct();
% Sliding window used for each decode attempt (RX complex samples).
search.window_samples = 1.0e6;
% Advance when decode fails or packet is rejected as non-QM35.
search.step_samples = 0.25e6;
% Only search the beginning of the file for the *first* QM35 packet.
% ~50 ms @ 737.28 MHz ≈ 37e6 samples; raise if needed.
search.max_search_samples = 40e6;
% Prefer FCS pass; if false, accept first PHR-valid QM35-like lock.
search.require_fcs_pass = true;
% SFD name must look like QM35 (4z) when possible. Set false to accept any SFD.
search.require_4z_sfd = false;
% Minimum soft-chip / full-rate SFD correlation to accept a candidate.
search.min_sfd_correlation = 0.50;
% Plot context around the found packet (RX samples before/after start).
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
    % Estimate tone once from the quiet interval, then reuse for every window.
    quiet_opts = options;
    quiet_opts.sample_offset = 0;
    quiet_opts.sample_num = min(base_params.sample_num, total_samples);
    quiet_params = dw1000decoder.mergeOptions( ...
        dw1000decoder.defaultOptions(), quiet_opts);
    % Force a one-shot estimate by reading the quiet segment through the
    % normal reader on a short probe window near file start if needed.
    probe = quiet_params;
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
    % Jump past this detection so we do not re-lock the same non-QM35 burst.
    jump = max(search.step_samples, round(0.15e6));
    offset = offset + jump;
end
search_seconds = toc(t_search);

if ~found
    error(['No QM35 packet found in the first %.3f ms. ', ...
        'Raise search.max_search_samples or relax search gates.'], ...
        search_limit/options.fs_rx*1e3);
end

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
xline(qm35_meta.time_start_s*1e3, 'k--', 'QM35 start', 'LabelVerticalAlignment', 'bottom');
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
    title(sprintf('QM35 CIR  |  SFD=%s  corr=%.3f  FCS=%d', ...
        qm35_result.sfd.name, qm35_result.sfd.correlation, ...
        qm35_result.payload.fcs_pass));
end

sgtitle(sprintf('%s — first QM35 lock', options.file_name), ...
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

% Workspace outputs for follow-on two-packet CIR work.
assignin('base', 'qm35_first_result', qm35_result);
assignin('base', 'qm35_first_meta', qm35_meta);
assignin('base', 'qm35_first_options', options);

out_dir = fullfile(project_dir, 'decoded_results', 'qm35_dw1000_1_first_qm35');
if ~isfolder(out_dir)
    mkdir(out_dir);
end
save(fullfile(out_dir, 'first_qm35_packet.mat'), ...
    'qm35_result', 'qm35_meta', 'options', '-v7.3');
try
    exportgraphics(gcf, fullfile(out_dir, 'first_qm35_waveform.png'), ...
        'Resolution', 140);
catch
    saveas(gcf, fullfile(out_dir, 'first_qm35_waveform.png'));
end
fprintf('Saved: %s\n', out_dir);

%% ------------------------------------------------------------------------
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
