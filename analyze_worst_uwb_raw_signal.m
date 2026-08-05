%% Visualize the raw IQ of the worst QM35825 interference segment
% The exported .dat files contain interleaved int16 IQ samples.  This
% script automatically selects rank 01 by default and does not perform
% interference cancellation, filtering, resampling, or normalization.
clear;
close all;
clc;

%% -------------------- Configuration --------------------
data_dir = 'F:\UWB基带数据\qm35_worst10_segments';
rank_to_view = 2;             % 1 is the worst segment
default_fs = 998.4e6;         % used only when metadata is unavailable
default_ant_num = 1;
channel_index = 1;
zoom_duration_us = 40;        % detailed waveform view around QM35 start
max_overview_points = 200000; % display decimation only; data stay unchanged
save_figures = true;
run_dual_decode = true;        % decode QM35825 and DW1000 from the same IQ

%% -------------------- Locate rank file --------------------
if ~isfolder(data_dir)
    error('Data directory not found: %s', data_dir);
end

pattern = sprintf('rank_%02d_*_sample_*.dat', rank_to_view);
files = dir(fullfile(data_dir, pattern));
if isempty(files)
    error('No rank %02d .dat file found in %s.', rank_to_view, data_dir);
end
if numel(files) > 1
    [~, newest] = max([files.datenum]);
    files = files(newest);
end
file_name = fullfile(files.folder, files.name);

meta_pattern = sprintf('rank_%02d_*_metadata.mat', rank_to_view);
meta_files = dir(fullfile(data_dir, meta_pattern));
segment_info = struct();
if ~isempty(meta_files)
    [~, newest] = max([meta_files.datenum]);
    meta_file = fullfile(meta_files(newest).folder, meta_files(newest).name);
    meta = load(meta_file, 'segment_info');
    if isfield(meta, 'segment_info')
        segment_info = meta.segment_info;
    end
else
    meta_file = '';
end

fs = default_fs;
ant_num = default_ant_num;
source_offset = getFieldOr(segment_info, 'source_sample_offset', 0);

%% -------------------- Read untouched int16 IQ --------------------
file_bytes = files.bytes;
bytes_per_complex_sample = 4 * ant_num;
if mod(file_bytes, bytes_per_complex_sample) ~= 0
    error('File size is not an integer number of complex samples: %s', file_name);
end
sample_count = file_bytes / bytes_per_complex_sample;

fid = fopen(file_name, 'rb');
if fid < 0
    error('Cannot open: %s', file_name);
end
cleanup_fid = onCleanup(@() fclose(fid));
raw = fread(fid, [2*ant_num, sample_count], 'int16=>double');
clear cleanup_fid;
if size(raw, 2) ~= sample_count
    error('Short read: expected %d samples, got %d.', sample_count, size(raw, 2));
end
if channel_index < 1 || channel_index > ant_num
    error('channel_index=%d is outside 1..%d.', channel_index, ant_num);
end
rx = complex(raw(2*channel_index-1, :), raw(2*channel_index, :)).';
clear raw;

%% -------------------- Use the preprocessed IQ directly --------------------
% The input already uses the 998.4 MHz complex-baseband grid and has had
% its single-tone and center-frequency preprocessing applied upstream.
rx_clean = rx;

t_ms = (0:sample_count-1).' / fs * 1e3;
duration_ms = sample_count / fs * 1e3;

% Recover the detected QM35 start relative to this exported window.
qm35_start_sample = NaN;
if isfield(segment_info, 'time_start_s') && ...
        isfield(segment_info, 'source_sample_offset')
    qm35_start_sample = round(segment_info.time_start_s * fs) - ...
        segment_info.source_sample_offset;
    if qm35_start_sample < 0 || qm35_start_sample >= sample_count
        qm35_start_sample = NaN;
    end
end

fprintf('\n========== Worst QM35 raw segment ==========\n');
fprintf('Rank                 : %d\n', rank_to_view);
fprintf('File                 : %s\n', file_name);
if ~isempty(meta_file), fprintf('Metadata             : %s\n', meta_file); end
fprintf('Samples              : %d\n', sample_count);
fprintf('Sample rate          : %.3f MHz\n', fs/1e6);
fprintf('Duration             : %.6f ms\n', duration_ms);
fprintf('Source sample offset : %d\n', source_offset);
fprintf('I range              : [%.0f, %.0f] ADC\n', min(real(rx)), max(real(rx)));
fprintf('Q range              : [%.0f, %.0f] ADC\n', min(imag(rx)), max(imag(rx)));
fprintf('|IQ| peak / RMS      : %.2f / %.2f ADC\n', ...
    max(abs(rx)), sqrt(mean(abs(rx).^2)));
fprintf('Input preprocessing  : already complete\n');
if isfinite(qm35_start_sample)
    fprintf('QM35 start in segment: %d (%.6f ms)\n', ...
        qm35_start_sample, qm35_start_sample/fs*1e3);
end
fprintf('=============================================\n\n');

%% -------------------- Overview and waveform detail --------------------
plot_step = max(1, ceil(sample_count / max_overview_points));
overview_idx = (1:plot_step:sample_count).';

% A block-RMS envelope exposes packet/interference changes without altering
% the waveform used in the detailed panels.
envelope_block = max(1, round(0.5e-6 * fs));
envelope_count = floor(sample_count / envelope_block);
trim_count = envelope_count * envelope_block;
envelope_rms = sqrt(mean(reshape(abs(rx(1:trim_count)).^2, ...
    envelope_block, envelope_count), 1));
envelope_clean_rms = sqrt(mean(reshape(abs(rx_clean(1:trim_count)).^2, ...
    envelope_block, envelope_count), 1));
envelope_t_ms = ((0:envelope_count-1) * envelope_block + ...
    (envelope_block-1)/2) / fs * 1e3;

if isfinite(qm35_start_sample)
    zoom_center = qm35_start_sample;
else
    [~, peak_block] = max(envelope_rms);
    zoom_center = round((peak_block-0.5) * envelope_block);
end
zoom_count = max(16, round(zoom_duration_us*1e-6*fs));
zoom_first = max(1, zoom_center - floor(zoom_count/2));
zoom_last = min(sample_count, zoom_first + zoom_count - 1);
zoom_first = max(1, zoom_last - zoom_count + 1);
zoom_idx = (zoom_first:zoom_last).';
zoom_t_us = ((zoom_idx-1) - zoom_center) / fs * 1e6;

fig1 = figure('Name', 'Worst QM35 raw IQ', 'Color', 'w', ...
    'Position', [50 50 1250 850]);

subplot(2,2,1);
plot(t_ms(overview_idx), real(rx_clean(overview_idx)), 'b'); hold on;
plot(t_ms(overview_idx), imag(rx_clean(overview_idx)), 'r');
markQm35Start(qm35_start_sample, fs, 1e3);
grid on; box on;
xlabel('Time in segment (ms)'); ylabel('ADC counts');
legend('I', 'Q', 'QM35 start', 'Location', 'best');
title(sprintf('Preprocessed I/Q (display step = %d)', plot_step));

subplot(2,2,2);
plot(envelope_t_ms, envelope_rms, 'Color', [0.65 0.65 0.65]); hold on;
plot(envelope_t_ms, envelope_clean_rms, 'k', 'LineWidth', 1.1);
markQm35Start(qm35_start_sample, fs, 1e3);
grid on; box on;
xlabel('Time in segment (ms)'); ylabel('RMS |IQ| (ADC)');
legend('Input', 'Input (same grid)', 'QM35 start', 'Location', 'best');
title(sprintf('Input amplitude (%.1f us blocks)', ...
    envelope_block/fs*1e6));

subplot(2,2,3);
plot(zoom_t_us, real(rx_clean(zoom_idx)), 'b'); hold on;
plot(zoom_t_us, imag(rx_clean(zoom_idx)), 'r');
if isfinite(qm35_start_sample), xline(0, 'g--', 'QM35 start'); end
grid on; box on;
xlabel('Time relative to zoom center (us)'); ylabel('ADC counts');
legend('I', 'Q', 'Location', 'best');
title(sprintf('Preprocessed waveform detail (%.1f us)', ...
    numel(zoom_idx)/fs*1e6));

subplot(2,2,4);
plot(zoom_t_us, abs(rx(zoom_idx)), 'Color', [0.7 0.7 0.7]); hold on;
plot(zoom_t_us, abs(rx_clean(zoom_idx)), 'Color', [0.1 0.5 0.2]);
if isfinite(qm35_start_sample), xline(0, 'g--', 'QM35 start'); end
grid on; box on;
xlabel('Time relative to zoom center (us)'); ylabel('|IQ| (ADC)');
legend('Input', 'Input (same grid)', 'QM35 start', 'Location', 'best');
title('Instantaneous magnitude');

sgtitle(sprintf('Worst interference rank %02d | %s', ...
    rank_to_view, files.name), 'Interpreter', 'none');

%% -------------------- Spectrum and time-frequency view --------------------
nfft = 4096;
window = hann(nfft, 'periodic');
noverlap = round(0.75*nfft);
[stft_raw, f_spec, t_spec] = spectrogram(rx, window, noverlap, ...
    nfft, fs, 'centered');
[stft_clean, ~, ~] = spectrogram(rx_clean, window, noverlap, ...
    nfft, fs, 'centered');
reference_peak = max(abs(stft_raw(:)));
stft_clean_db = 20*log10(abs(stft_clean) / reference_peak + eps);
raw_psd_db = 10*log10(mean(abs(stft_raw).^2, 2) + eps);
clean_psd_db = 10*log10(mean(abs(stft_clean).^2, 2) + eps);
psd_reference = max(raw_psd_db);
raw_psd_db = raw_psd_db - psd_reference;
clean_psd_db = clean_psd_db - psd_reference;

fig2 = figure('Name', 'Worst QM35 raw spectrum', 'Color', 'w', ...
    'Position', [80 80 1200 760]);

subplot(2,1,1);
plot(f_spec/1e6, raw_psd_db, 'Color', [0.65 0.65 0.65]); hold on;
plot(f_spec/1e6, clean_psd_db, 'b', 'LineWidth', 1);
grid on; box on;
xlabel('Baseband frequency (MHz)'); ylabel('Relative PSD (dB)');
legend('Input', 'Input (same grid)', 'Location', 'best');
title('Average spectrum of preprocessed input');
xlim([min(f_spec) max(f_spec)]/1e6);

subplot(2,1,2);
imagesc(t_spec*1e3, f_spec/1e6, stft_clean_db);
axis xy; colormap turbo; colorbar; caxis([-60 0]);
xlabel('Time in segment (ms)'); ylabel('Baseband frequency (MHz)');
title('Preprocessed IQ spectrogram (dB relative to input peak)');
if isfinite(qm35_start_sample)
    hold on;
    xline(qm35_start_sample/fs*1e3, 'w--', 'QM35 start', ...
        'LineWidth', 1.2, 'LabelVerticalAlignment', 'bottom');
end

sgtitle(sprintf('Preprocessed input | rank %02d | %.3f MHz', ...
    rank_to_view, fs/1e6));

%% -------------------- Dual-protocol decoding --------------------
% Two independent matched-filter chains operate on the same mixed capture.
% Both decoders operate on the same preprocessed mixed capture.
dual_decode = struct();
if run_dual_decode
    decode_file = file_name;
    decode_input = 'preprocessed IQ';

    common = struct();
    common.file_name = decode_file;
    common.sample_offset = 0;
    common.sample_num = sample_count;
    common.ant_num = 1;
    common.channel_index = 1;
    common.fs_rx = fs;
    common.data_rate = 6.81;
    common.cir_repetitions = 64;
    common.cir_pre_samples = 8;
    common.cir_post_samples = 30;
    common.cir_max_path_m = [];
    common.max_psdu_bytes = 127;
    common.enable_frame_crop = true;
    common.verbose = false;
    common.show_plots = false;

    qm_options = common;
    qm_options.preamble_repetitions = 128;
    qm_options.cir_skip_initial_repetitions = 24;
    qm_options.cir_repetitions = 104;
    qm_options.code_index = 9;
    qm_options.sfd_mode = '4z2';

    dw_options = common;
    dw_options.preamble_repetitions = 256;
    dw_options.code_index = 10;
    dw_options.sfd_mode = 'decawave';

    fprintf('\n========== Dual-protocol decode ==========\n');
    fprintf('Input: %s\n', decode_input);
    [dual_decode.qm35825, dual_decode.qm35825_completed, ...
        dual_decode.qm35825_message] = tryProtocolDecode(qm_options);
    printProtocolResult('QM35825', dual_decode.qm35825, ...
        dual_decode.qm35825_completed, dual_decode.qm35825_message, fs);

    [dual_decode.dw1000, dual_decode.dw1000_completed, ...
        dual_decode.dw1000_message] = tryProtocolDecode(dw_options);
    printProtocolResult('DW1000', dual_decode.dw1000, ...
        dual_decode.dw1000_completed, dual_decode.dw1000_message, fs);
    fprintf('==========================================\n\n');

    dual_decode.input_file = decode_file;
    dual_decode.input_description = decode_input;
    dual_decode.qm35825_options = qm_options;
    dual_decode.dw1000_options = dw_options;

    decode_dir = fullfile(data_dir, 'dual_decode_results');
    if ~isfolder(decode_dir), mkdir(decode_dir); end
    save(fullfile(decode_dir, sprintf('rank_%02d_dual_decode.mat', ...
        rank_to_view)), 'dual_decode', '-v7.3');
    writeDualDecodeSummary(fullfile(decode_dir, sprintf( ...
        'rank_%02d_dual_decode.csv', rank_to_view)), dual_decode, fs);

    fig3 = plotDualDecodeCir(dual_decode, fs, rank_to_view);
    if ~isempty(fig3)
        exportgraphics(fig3, fullfile(decode_dir, sprintf( ...
            'rank_%02d_dual_decode_cir.png', rank_to_view)), ...
            'Resolution', 160);
    end
    fprintf('Dual decode results saved to: %s\n', decode_dir);
end

%% -------------------- Optional figure export --------------------
if save_figures
    figure_dir = fullfile(data_dir, 'raw_signal_figures');
    if ~isfolder(figure_dir), mkdir(figure_dir); end
    base_name = sprintf('rank_%02d', rank_to_view);
    exportgraphics(fig1, fullfile(figure_dir, ...
        [base_name '_raw_time.png']), 'Resolution', 160);
    exportgraphics(fig2, fullfile(figure_dir, ...
        [base_name '_raw_spectrum.png']), 'Resolution', 160);
    fprintf('Figures saved to: %s\n', figure_dir);
end

assignin('base', 'worst_qm35_raw_iq', rx);
assignin('base', 'worst_qm35_clean_iq', rx_clean);
assignin('base', 'worst_qm35_segment_info', segment_info);
assignin('base', 'worst_qm35_dual_decode', dual_decode);

%% ========================================================================
function value = getFieldOr(s, field_name, default_value)
if isstruct(s) && isfield(s, field_name) && ...
        ~isempty(s.(field_name)) && isfinite(s.(field_name))
    value = s.(field_name);
else
    value = default_value;
end
end

function markQm35Start(start_sample, fs, time_scale)
if isfinite(start_sample)
    xline(start_sample/fs*time_scale, 'g--', 'QM35 start', ...
        'LineWidth', 1.1, 'LabelVerticalAlignment', 'bottom');
end
end

function [result, completed, message] = tryProtocolDecode(options)
result = struct();
completed = false;
message = '';
try
    result = decode_uwb(options);
    completed = true;
    message = 'decoder completed';
catch ME
    message = ME.message;
end
end

function printProtocolResult(label, result, completed, message, fs_rx)
if ~completed
    fprintf('%-8s: FAIL - %s\n', label, message);
    return;
end
start_rx = round((result.preamble.start_sample-1) * ...
    fs_rx/result.phy_config.SampleRate);
fprintf(['%-8s: completed | start=%.6f ms | SFD=%s corr=%.3f | ', ...
    'PHR=%d PSDU=%d FCS=%d\n'], label, start_rx/fs_rx*1e3, ...
    char(string(result.sfd.name)), result.sfd.correlation, ...
    result.phr.secded_pass, result.phr.psdu_length_bytes, ...
    result.payload.fcs_pass);
end

function writeDualDecodeSummary(csv_file, dual_decode, fs_rx)
fid = fopen(csv_file, 'w');
if fid < 0
    warning('Cannot create dual-decode CSV: %s', csv_file);
    return;
end
c = onCleanup(@() fclose(fid));
fprintf(fid, ['protocol,completed,start_ms,sfd,sfd_corr,phr_pass,', ...
    'psdu_bytes,fcs_pass,message\n']);
names = {'QM35825', 'DW1000'};
fields = {'qm35825', 'dw1000'};
for k = 1:2
    completed = dual_decode.([fields{k} '_completed']);
    message = strrep(dual_decode.([fields{k} '_message']), '"', '""');
    if completed
        r = dual_decode.(fields{k});
        start_rx = round((r.preamble.start_sample-1) * ...
            fs_rx/r.phy_config.SampleRate);
        fprintf(fid, '%s,1,%.9f,"%s",%.9g,%d,%d,%d,"%s"\n', ...
            names{k}, start_rx/fs_rx*1e3, char(string(r.sfd.name)), ...
            r.sfd.correlation, r.phr.secded_pass, ...
            r.phr.psdu_length_bytes, r.payload.fcs_pass, message);
    else
        fprintf(fid, '%s,0,NaN,"",NaN,0,0,0,"%s"\n', ...
            names{k}, message);
    end
end
clear c;
end

function fig = plotDualDecodeCir(dual_decode, fs_rx, rank_value)
ok_qm = dual_decode.qm35825_completed;
ok_dw = dual_decode.dw1000_completed;
if ~ok_qm && ~ok_dw
    fig = [];
    return;
end
fig = figure('Name', 'QM35825 and DW1000 dual decode', 'Color', 'w', ...
    'Position', [100 100 1150 720]);

subplot(2,1,1); hold on;
labels = {};
if ok_qm
    r = dual_decode.qm35825;
    plot(r.cir.delay_ns, abs(r.cir.values), 'b', 'LineWidth', 1.1);
    labels{end+1} = 'QM35825'; %#ok<AGROW>
end
if ok_dw
    r = dual_decode.dw1000;
    plot(r.cir.delay_ns, abs(r.cir.values), 'r', 'LineWidth', 1.1);
    labels{end+1} = 'DW1000'; %#ok<AGROW>
end
grid on; box on; xlabel('CIR delay (ns)'); ylabel('|CIR|');
legend(labels, 'Location', 'best');
title('Independently decoded CIR from the same mixed IQ');

subplot(2,1,2); hold on;
protocol_labels = {};
corr_values = [];
fcs_values = [];
if ok_qm
    protocol_labels{end+1} = 'QM35825'; %#ok<AGROW>
    corr_values(end+1) = dual_decode.qm35825.sfd.correlation; %#ok<AGROW>
    fcs_values(end+1) = dual_decode.qm35825.payload.fcs_pass; %#ok<AGROW>
end
if ok_dw
    protocol_labels{end+1} = 'DW1000'; %#ok<AGROW>
    corr_values(end+1) = dual_decode.dw1000.sfd.correlation; %#ok<AGROW>
    fcs_values(end+1) = dual_decode.dw1000.payload.fcs_pass; %#ok<AGROW>
end
b = bar(corr_values, 0.55); b.FaceColor = 'flat';
for k = 1:numel(corr_values)
    b.CData(k,:) = [0.2 0.55 0.9];
    text(k, corr_values(k)+0.03, sprintf('FCS=%d', fcs_values(k)), ...
        'HorizontalAlignment', 'center');
end
set(gca, 'XTick', 1:numel(protocol_labels), ...
    'XTickLabel', protocol_labels);
ylim([0 max(1, max(corr_values)+0.15)]);
grid on; box on; ylabel('SFD correlation');
title('Decode quality indicators');
sgtitle(sprintf('Rank %02d dual-protocol decode | fs=%.2f MHz', ...
    rank_value, fs_rx/1e6));
end
