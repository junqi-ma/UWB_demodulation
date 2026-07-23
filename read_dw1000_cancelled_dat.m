%% Read and inspect the capture after DW1000 cancellation
clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));

%% -------------------- User configuration --------------------
original_file_name = 'F:\UWB基带数据\DW1000_2.dat';
cancelled_file_name = fullfile(project_dir, 'decoded_results', ...
    'DW1000_2_all_dw1000_cancelled.dat');

fs = 737.28e6;          % Complex sample rate (Hz)
ant_num = 1;            % Number of interleaved antenna channels
channel_index = 1;      % Channel to return and plot
sample_offset = 7778186;      % Zero-based complex-sample offset
sample_num = 1e6;       % Use Inf to read from offset to end of file

%% -------------------- Check file and requested interval --------------------
if ~isfile(original_file_name)
    error('Original capture not found: %s', original_file_name);
end
if ~isfile(cancelled_file_name)
    error('Cancelled capture not found: %s', cancelled_file_name);
end
if channel_index < 1 || channel_index > ant_num
    error('channel_index must be in the range 1..ant_num.');
end

file_info = dir(cancelled_file_name);
original_file_info = dir(original_file_name);
bytes_per_time_sample = 4*ant_num;
if mod(file_info.bytes, bytes_per_time_sample) ~= 0
    error(['File size is not compatible with %d interleaved channel(s). ', ...
        'Check ant_num.'], ant_num);
end
total_samples = file_info.bytes/bytes_per_time_sample;
if mod(original_file_info.bytes, bytes_per_time_sample) ~= 0
    error(['Original file size is not compatible with %d interleaved ', ...
        'channel(s). Check ant_num.'], ant_num);
end
original_total_samples = original_file_info.bytes/bytes_per_time_sample;
if original_total_samples ~= total_samples
    error(['Original and cancelled captures have different lengths ', ...
        '(%d versus %d samples), so they cannot be aligned.'], ...
        original_total_samples, total_samples);
end
if sample_offset < 0 || sample_offset ~= fix(sample_offset) || ...
        sample_offset >= total_samples
    error('sample_offset must be an integer in the range 0..%d.', ...
        total_samples-1);
end
if isinf(sample_num)
    read_count = total_samples-sample_offset;
else
    if sample_num <= 0 || sample_num ~= fix(sample_num)
        error('sample_num must be a positive integer or Inf.');
    end
    read_count = min(sample_num, total_samples-sample_offset);
end

%% -------------------- Read interleaved int16 IQ --------------------
fid = fopen(cancelled_file_name, 'rb', 'ieee-le');
if fid < 0
    error('Cannot open file: %s', cancelled_file_name);
end
file_guard = onCleanup(@() fclose(fid));

status = fseek(fid, sample_offset*bytes_per_time_sample, 'bof');
if status ~= 0
    error('Could not seek to complex sample %d.', sample_offset);
end
raw = fread(fid, [2*ant_num, read_count], 'int16=>double');
if size(raw, 2) ~= read_count
    error('Requested %d samples but read only %d.', ...
        read_count, size(raw, 2));
end

i_row = 2*channel_index-1;
q_row = 2*channel_index;
rx_cancelled = raw(i_row, :).'+1j*raw(q_row, :).';
time_s = (sample_offset+(0:read_count-1).')/fs;
clear raw file_guard;

fid = fopen(original_file_name, 'rb', 'ieee-le');
if fid < 0
    error('Cannot open file: %s', original_file_name);
end
file_guard = onCleanup(@() fclose(fid));
status = fseek(fid, sample_offset*bytes_per_time_sample, 'bof');
if status ~= 0
    error('Could not seek original capture to complex sample %d.', ...
        sample_offset);
end
raw = fread(fid, [2*ant_num, read_count], 'int16=>double');
if size(raw, 2) ~= read_count
    error('Requested %d original samples but read only %d.', ...
        read_count, size(raw, 2));
end
rx_original = raw(i_row, :).'+1j*raw(q_row, :).';
clear raw file_guard;

%% -------------------- Aligned time-domain comparison --------------------
plot_count = min(read_count, 2e5);
plot_time_ms = time_s(1:plot_count)*1e3;
figure('Name', 'Before and after DW1000 cancellation', 'Color', 'w');
subplot(3, 1, 1);
plot(plot_time_ms, real(rx_original(1:plot_count)));
hold on;
plot(plot_time_ms, real(rx_cancelled(1:plot_count)),'--');
grid on;
xlabel('Capture time (ms)');
ylabel('I (ADC counts)');
legend('Before cancellation', 'After cancellation');
title(sprintf('Aligned IQ comparison, channel %d', channel_index));

subplot(3, 1, 2);
plot(plot_time_ms, imag(rx_original(1:plot_count)));
hold on;
plot(plot_time_ms, imag(rx_cancelled(1:plot_count)),'--');
grid on;
xlabel('Capture time (ms)');
ylabel('Q (ADC counts)');
legend('Before cancellation', 'After cancellation');

subplot(3, 1, 3);
plot(plot_time_ms, abs(rx_original(1:plot_count)));
hold on;
plot(plot_time_ms, abs(rx_cancelled(1:plot_count)),'--');
grid on;
xlabel('Capture time (ms)');
ylabel('|IQ| (ADC counts)');
legend('Before cancellation', 'After cancellation');

%% -------------------- Aligned spectrum comparison --------------------
fft_num = min(read_count, 262144);
if fft_num >= 2
    window = 0.5-0.5*cos(2*pi*(0:fft_num-1).'/(fft_num-1));
    original_spectrum = abs(fftshift(fft(rx_original(1:fft_num).*window)));
    cancelled_spectrum = abs(fftshift(fft(rx_cancelled(1:fft_num).*window)));
    spectrum_reference = max(original_spectrum);
    original_spectrum_db = 20*log10(original_spectrum/spectrum_reference+eps);
    cancelled_spectrum_db = ...
        20*log10(cancelled_spectrum/spectrum_reference+eps);
    frequency_hz = (-floor(fft_num/2):ceil(fft_num/2)-1).'*fs/fft_num;

    figure('Name', 'Spectrum before and after DW1000 cancellation', ...
        'Color', 'w');
    plot(frequency_hz/1e6, original_spectrum_db);
    hold on;
    plot(frequency_hz/1e6, cancelled_spectrum_db);
    grid on;
    xlabel('Relative frequency (MHz)');
    ylabel('Magnitude relative to original peak (dB)');
    title(sprintf('Aligned spectrum comparison, channel %d', channel_index));
    legend('Before cancellation', 'After cancellation');
    xlim([-fs/2, fs/2]/1e6);
end

rms_original = sqrt(mean(abs(rx_original).^2));
rms_cancelled = sqrt(mean(abs(rx_cancelled).^2));
rms_change_db = 20*log10((rms_cancelled+eps)/(rms_original+eps));
peak_original = max(abs(rx_original));
peak_cancelled = max(abs(rx_cancelled));
peak_change_db = 20*log10((peak_cancelled+eps)/(peak_original+eps));

fprintf('\n======= Cancellation comparison reader =======\n');
fprintf('Original file         : %s\n', original_file_name);
fprintf('Cancelled file        : %s\n', cancelled_file_name);
fprintf('File samples          : %d (%.6f s)\n', total_samples, ...
    total_samples/fs);
fprintf('Read interval         : %d..%d\n', sample_offset, ...
    sample_offset+read_count-1);
fprintf('Returned samples      : %d\n', numel(rx_cancelled));
fprintf('Selected channel      : %d / %d\n', channel_index, ant_num);
fprintf('Original RMS          : %.3f ADC counts\n', rms_original);
fprintf('Cancelled RMS         : %.3f ADC counts\n', rms_cancelled);
fprintf('RMS change            : %+.3f dB\n', rms_change_db);
fprintf('Peak change           : %+.3f dB\n', peak_change_db);
fprintf('Variables              : rx_original, rx_cancelled, time_s\n');
fprintf('==============================================\n');

assignin('base', 'rx_original', rx_original);
assignin('base', 'rx_cancelled', rx_cancelled);
assignin('base', 'rx_original_time_s', time_s);
assignin('base', 'rx_cancelled_time_s', time_s);
