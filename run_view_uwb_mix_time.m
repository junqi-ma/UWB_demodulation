%% View time-domain IQ + QM35 CIR at a conflict-aligned window
% Branch: feature/two-packet-cir
%
% Align sample_offset to a DW1000/QM35 collision region, cancel the
% clock-synchronous tone, inspect the cleaned waveform, then run QM35 CIR.
clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% -------------------- File / load window --------------------
file_name = 'F:\UWB基带数据\qm35_dw1000_1.dat';
fs = 737.28e6;          % X410 sample rate (Hz)
ant_num = 1;
channel_index = 1;

% Align this to the conflict region (user-tuned).
sample_offset = 6e6;    % zero-based complex-sample index
sample_num = 10e6;     % window length
plot_num = sample_num;

%% -------------------- Clock-synchronous tone (same as run_decode_*) --------------------
enable_tone_cancel = true;
tone_bin = -169;                 % f/fs = -169/512  -> ~-243.36 MHz
tone_period_samples = 512;
tone_quiet_offset = 400000;      % quiet region for coefficient estimate
tone_quiet_num = 262144;

%% -------------------- QM35 PHY (same as run_decode_*_all / README) --------------------
options = struct();
options.file_name = file_name;
options.sample_offset = sample_offset;
options.sample_num = sample_num;
options.ant_num = ant_num;
options.channel_index = channel_index;
options.fs_rx = fs;
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

options.cir_pre_samples = 8;
options.cir_post_samples = 30;
options.cir_max_path_m = [];
options.max_psdu_bytes = 32;
options.enable_frame_crop = true;
options.verbose = true;
options.show_plots = false;

options.enable_interference_cancellation = enable_tone_cancel;
options.interference_quiet_offset = tone_quiet_offset;
options.interference_quiet_num = tone_quiet_num;
options.interference_tone_bin = tone_bin;
options.interference_period_samples = tone_period_samples;
options.interference_coefficient = [];
options.blank_intervals = [];
options.blank_weight = 0;
options.blank_taper_samples = 256;

%% -------------------- Read raw IQ --------------------
if ~isfile(file_name)
    error('Capture not found: %s', file_name);
end

info = dir(file_name);
bytes_per_complex = ant_num * 4;
total_samples = floor(info.bytes / bytes_per_complex);
if sample_offset < 0 || sample_offset >= total_samples
    error('sample_offset=%d is outside the file (%d samples).', ...
        sample_offset, total_samples);
end
sample_num = min(sample_num, total_samples - sample_offset);
options.sample_num = sample_num;

fprintf('File                         : %s\n', file_name);
fprintf('Total complex samples        : %d (%.3f ms)\n', ...
    total_samples, total_samples/fs*1e3);
fprintf('Conflict window offset/count : %d / %d (%.3f--%.3f ms)\n', ...
    sample_offset, sample_num, ...
    sample_offset/fs*1e3, (sample_offset+sample_num-1)/fs*1e3);

rx_raw = readIqSegment(file_name, sample_offset, sample_num, ...
    ant_num, channel_index);
sample_count = numel(rx_raw);
t = (sample_offset + (0:sample_count-1).') / fs;

fprintf('Loaded samples               : %d\n', sample_count);
fprintf('|IQ| peak / mean (raw)       : %.1f / %.2f ADC\n', ...
    max(abs(rx_raw)), mean(abs(rx_raw)));

%% -------------------- Clock-synchronous tone cancellation --------------------
tone_frequency = tone_bin / tone_period_samples * fs;
tone_coeff = complex(0);
suppression_db = NaN;
rx = rx_raw;

if enable_tone_cancel
    quiet_num = min(tone_quiet_num, max(0, total_samples - tone_quiet_offset));
    if quiet_num < tone_period_samples
        error('Not enough samples for tone estimation at quiet offset %d.', ...
            tone_quiet_offset);
    end
    rx_quiet = readIqSegment(file_name, tone_quiet_offset, quiet_num, ...
        ant_num, channel_index);
    quiet_n = tone_quiet_offset + (0:numel(rx_quiet)-1).';
    quiet_basis = uwbdecoder.synchronousTone( ...
        quiet_n, tone_bin, tone_period_samples);
    tone_coeff = mean(rx_quiet .* conj(quiet_basis));

    rx_n = sample_offset + (0:sample_count-1).';
    rx_basis = uwbdecoder.synchronousTone( ...
        rx_n, tone_bin, tone_period_samples);
    amp_before = abs(mean(rx_raw .* conj(rx_basis)));
    rx = rx_raw - tone_coeff .* rx_basis;
    amp_after = abs(mean(rx .* conj(rx_basis)));
    suppression_db = 20*log10(amp_before / max(amp_after, eps));
    rx = rx - mean(rx);

    % Reuse coefficient in decode_uwb (same absolute phase model).
    options.interference_coefficient = tone_coeff;

    fprintf('\n========== Clock-synchronous tone cancel ==========\n');
    fprintf('Relative tone frequency      : %+.6f MHz\n', tone_frequency/1e6);
    fprintf('Absolute tone frequency      : %.6f MHz\n', ...
        (options.x410_center_frequency + tone_frequency)/1e6);
    fprintf('Coefficient |A| / phase      : %.3f ADC / %.2f deg\n', ...
        abs(tone_coeff), angle(tone_coeff)*180/pi);
    fprintf('Quiet estimate offset/count  : %d / %d\n', ...
        tone_quiet_offset, quiet_num);
    fprintf('Window suppression           : %.2f dB\n', suppression_db);
    fprintf('===================================================\n');
else
    fprintf('Tone cancellation disabled.\n');
    rx = rx - mean(rx);
end

amp = abs(rx);
amp_raw = abs(rx_raw);
power_db = 20*log10(amp + eps);
power_db_raw = 20*log10(amp_raw + eps);

fprintf('|IQ| peak / mean (cleaned)   : %.1f / %.2f ADC\n', ...
    max(amp), mean(amp));

%% -------------------- Figure 1: time domain before / after tone cancel --------------------
n_plot = min(plot_num, sample_count);
idx = 1:n_plot;
t_us = t(idx) * 1e6;
t_ms = t(idx) * 1e3;

figure('Name', 'Conflict window — tone cancel time domain', 'Color', 'w', ...
    'Position', [60 40 1100 820]);

% subplot(4, 1, 1);
% plot(t_us, real(rx_raw(idx)), 'Color', [0.6 0.6 0.9]); hold on;
% plot(t_us, imag(rx_raw(idx)), 'Color', [0.9 0.6 0.6]);
% grid on;
% xlabel('Time (\mus)');
% ylabel('ADC');
% title(sprintf('Raw I/Q  |  offset=%d  N=%d', sample_offset, n_plot));
% legend('I raw', 'Q raw', 'Location', 'best');

subplot(2, 1, 1);
plot(t_us, real(rx(idx)), 'b'); hold on;
plot(t_us, imag(rx(idx)), 'r');
grid on;
xlabel('Time (\mus)');
ylabel('ADC');
if enable_tone_cancel
    title(sprintf('After tone cancel  |  supp=%.1f dB  bin=%d/512', ...
        suppression_db, tone_bin));
else
    title('I/Q (tone cancel off)');
end
legend('I', 'Q', 'Location', 'best');

subplot(2, 1, 2);
plot(t_us, amp_raw(idx), 'Color', [0.65 0.65 0.65]); hold on;
plot(t_us, amp(idx), 'k');
grid on;
xlabel('Time (\mus)');
ylabel('|IQ|');
title('Envelope |IQ| before / after tone cancel');
legend('|raw|', '|cleaned|', 'Location', 'best');

% subplot(3, 1, 3);
% plot(t_ms, power_db_raw(idx), 'Color', [0.7 0.7 0.7]); hold on;
% plot(t_ms, power_db(idx), 'Color', [0.1 0.4 0.8]);
% grid on;
% xlabel('Time (ms)');
% ylabel('Magnitude (dB)');
% title('Envelope dB before / after tone cancel');
% legend('raw', 'cleaned', 'Location', 'best');

sgtitle(sprintf('%s — conflict window + tone cancel', file_name), ...
    'Interpreter', 'none');

%% -------------------- Figure 1b: spectrum around the tone (optional check) --------------------
if enable_tone_cancel
    n_fft = min(262144, sample_count);
    win = hann(n_fft);
    X0 = fftshift(fft((rx_raw(1:n_fft)-mean(rx_raw(1:n_fft))) .* win));
    X1 = fftshift(fft((rx(1:n_fft)-mean(rx(1:n_fft))) .* win));
    f_axis = (-floor(n_fft/2):ceil(n_fft/2)-1).' * fs / n_fft;
    P0 = 20*log10(abs(X0)+eps); P0 = P0 - max(P0);
    P1 = 20*log10(abs(X1)+eps); P1 = P1 - max(P1);

    figure('Name', 'Tone cancel spectrum', 'Color', 'w', ...
        'Position', [80 80 1000 420]);
    plot(f_axis/1e6, P0, 'Color', [0.7 0.7 0.7]); hold on;
    plot(f_axis/1e6, P1, 'b');
    xline(tone_frequency/1e6, 'r--', sprintf('tone %+0.2f MHz', tone_frequency/1e6));
    grid on;
    xlabel('Relative frequency (MHz)');
    ylabel('Normalized PSD (dB)');
    title(sprintf('Spectrum before/after tone cancel (Nfft=%d)', n_fft));
    legend('raw', 'cleaned', 'Location', 'best');
    xlim([-fs/2, fs/2]/1e6);
end

%% -------------------- QM35 CIR estimation on this window --------------------
fprintf('\n========== QM35 CIR estimate (code=9, SYNC=128) ==========\n');
qm35_result = [];
qm35_ok = false;
try
    qm35_result = decode_uwb(options);
    qm35_ok = true;
catch ME
    fprintf('QM35 decode/CIR failed: %s\n', ME.message);
    if ~isempty(ME.stack)
        fprintf('  at %s (line %d)\n', ME.stack(1).name, ME.stack(1).line);
    end
end

if qm35_ok
    abs_start = sample_offset + round( ...
        (qm35_result.preamble.start_sample-1) * fs / ...
        qm35_result.phy_config.SampleRate);
    abs_start = max(0, abs_start);
    t_start_ms = abs_start / fs * 1e3;
    t_start_us = abs_start / fs * 1e6;

    fprintf('Preamble start (abs sample)  : %d (%.3f ms)\n', ...
        abs_start, t_start_ms);
    fprintf('Detected SYNC reps           : %d\n', ...
        qm35_result.preamble.detected_repetitions);
    fprintf('Clock error                  : %.3f ppm\n', ...
        qm35_result.preamble.sample_clock_error_ppm);
    fprintf('CFO                          : %.3f kHz\n', ...
        qm35_result.preamble.carrier_frequency_offset_hz/1e3);
    fprintf('SFD                          : %s  corr=%.4f\n', ...
        qm35_result.sfd.name, qm35_result.sfd.correlation);
    fprintf('CIR length / averages        : %d / %d\n', ...
        numel(qm35_result.cir.values), qm35_result.cir.repetition_count);
    fprintf('PHR / PSDU / FCS             : %d / %d B / %d\n', ...
        qm35_result.phr.secded_pass, qm35_result.phr.psdu_length_bytes, ...
        qm35_result.payload.fcs_pass);

    % Mark preamble start on cleaned time-domain panels.
    figure(1);
    subplot(4, 1, 2);
    xline(t_start_us, 'g--', 'QM35 start', ...
        'LabelVerticalAlignment', 'bottom', 'LineWidth', 1.2);
    subplot(4, 1, 3);
    xline(t_start_us, 'g--', 'LineWidth', 1.2);
    subplot(4, 1, 4);
    xline(t_start_ms, 'g--', 'QM35 start', ...
        'LabelVerticalAlignment', 'bottom', 'LineWidth', 1.2);

    %% -------------------- CIR visualization --------------------
    cir = qm35_result.cir;
    delay_ns = cir.delay_ns(:);
    h = cir.values(:);
    h_mag = abs(h);
    h_mag_n = h_mag / (max(h_mag) + eps);
    h_db = 20*log10(max(h_mag_n, 1e-3));

    figure('Name', 'QM35 CIR at conflict window', 'Color', 'w', ...
        'Position', [100 80 1100 720]);

    subplot(3, 1, 1);
    if isfield(cir, 'individual_values') && ~isempty(cir.individual_values)
        ind = abs(cir.individual_values);
        ind = ind ./ (max(ind, [], 1) + eps);
        h_ind = plot(delay_ns, ind, 'Color', [0.75 0.75 0.75]);
        set(h_ind(2:end), 'HandleVisibility', 'off'); hold on;
        h_avg = plot(delay_ns, h_mag_n, 'r', 'LineWidth', 1.8);
        legend([h_ind(1), h_avg], 'Per-SYNC CIR', 'Coherent average', ...
            'Location', 'best');
    else
        plot(delay_ns, h_mag_n, 'r', 'LineWidth', 1.8);
    end
    xline(0, 'k--', 'Nominal peak');
    grid on;
    xlabel('Relative delay (ns)');
    ylabel('Normalized |CIR|');
    title(sprintf([ ...
        'QM35 code-%d CIR  |  %d reps  |  pre=%d post=%d  |  tone cancel on'], ...
        options.code_index, cir.repetition_count, ...
        cir.pre_samples, cir.post_samples));

    subplot(3, 1, 2);
    plot(delay_ns, h_db, 'b', 'LineWidth', 1.5);
    xline(0, 'k--');
    grid on;
    ylim([-60 2]);
    xlabel('Relative delay (ns)');
    ylabel('|CIR| (dB, peak-normalized)');
    title('CIR magnitude (dB)');

    subplot(3, 1, 3);
    plot(delay_ns, real(h)/(max(abs(h))+eps), 'b', 'LineWidth', 1.2); hold on;
    plot(delay_ns, imag(h)/(max(abs(h))+eps), 'r', 'LineWidth', 1.2);
    xline(0, 'k--');
    grid on;
    xlabel('Relative delay (ns)');
    ylabel('Normalized Re/Im');
    title(sprintf('Complex CIR  |  SFD=%s  corr=%.3f  FCS=%d', ...
        qm35_result.sfd.name, qm35_result.sfd.correlation, ...
        qm35_result.payload.fcs_pass));
    legend('Real', 'Imag', 'Location', 'best');

    sgtitle(sprintf( ...
        'QM35 CIR @ conflict  |  offset=%d  preamble abs=%d (%.3f ms)', ...
        sample_offset, abs_start, t_start_ms), 'Interpreter', 'none');
else
    fprintf(['No QM35 CIR available for this window. ', ...
        'Try shifting sample_offset or increasing sample_num.\n']);
end

%% -------------------- Workspace exports --------------------
assignin('base', 'rx_raw_view', rx_raw);
assignin('base', 'rx_view', rx);
assignin('base', 't_view', t);
assignin('base', 'fs_view', fs);
assignin('base', 'tone_coeff', tone_coeff);
assignin('base', 'tone_suppression_db', suppression_db);
assignin('base', 'sample_offset_view', sample_offset);
assignin('base', 'qm35_result', qm35_result);
assignin('base', 'qm35_cir_ok', qm35_ok);

out_dir = fullfile(project_dir, 'decoded_results', 'qm35_dw1000_1_mixed', 'conflict_view');
if ~isfolder(out_dir)
    mkdir(out_dir);
end
save(fullfile(out_dir, 'conflict_view_tone_cancel.mat'), ...
    'rx_raw', 'rx', 't', 'fs', 'sample_offset', 'sample_num', ...
    'tone_coeff', 'suppression_db', 'enable_tone_cancel', ...
    'qm35_result', 'qm35_ok', 'options', '-v7.3');
figs = findall(0, 'Type', 'figure');
for k = 1:numel(figs)
    try
        exportgraphics(figs(k), fullfile(out_dir, sprintf('fig_%d.png', k)), ...
            'Resolution', 140);
    catch
    end
end
fprintf('Saved outputs under: %s\n', out_dir);

%% ------------------------------------------------------------------------
function rx = readIqSegment(file_name, sample_offset, sample_num, ant_num, channel_index)
fid = fopen(file_name, 'rb');
if fid < 0
    error('Cannot open file: %s', file_name);
end
cleanup_obj = onCleanup(@() fclose(fid));
status = fseek(fid, sample_offset * ant_num * 4, 'bof');
if status ~= 0
    error('Failed to seek to sample offset %d.', sample_offset);
end
raw = fread(fid, [2 * ant_num, sample_num], 'int16=>double');
clear cleanup_obj;
if size(raw, 2) < 1
    error('No samples read at offset %d.', sample_offset);
end
rx = raw(2*channel_index-1, :).' + 1j * raw(2*channel_index, :).';
end
