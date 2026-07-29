clear;
clc;
close all;

%% Visualize X410 tone cancellation without writing a new data file
% Input format: interleaved int16 IQ, I1,Q1,I1,Q1,...
%
% Processing flow:
%   1. Estimate the complex amplitude of the -243.36 MHz tone from a
%      confirmed no-UWB interval.
%   2. Reconstruct the tone with the correct global sample phase.
%   3. Subtract it from a display interval containing a UWB packet.
%   4. Compare time waveforms and spectra before/after cancellation.

%% Parameters
file_name = 'F:\UWB基带数据\dw1000_new_1.dat';
fs = 737.28e6;                 % Sample rate (Hz)
center_frequency = 6489.6e6;  % RF center frequency (Hz), modify if needed

% Confirmed no-UWB interval in qm35_1.dat: approximately 0.49--3.09 ms.
quiet_sample_offset = 400000;  % Zero-based complex-sample index
quiet_sample_num = 1500000;

% The first 400000 samples include both a quiet part and a UWB packet.
display_sample_offset = 0;
display_sample_num = 40000000;

% Measured clock-synchronous tone: f/fs = -169/512.
tone_bin = -169;
tone_period_samples = 512;
f_tone = tone_bin/tone_period_samples * fs;  % -243.36 MHz

fft_num = 262144*5;
tone_zoom_half_width = 5e6;    % Zoom width around the tone (Hz)

%% Read the no-UWB training interval
fid = fopen(file_name, 'rb');
if fid < 0
    error('Cannot open input file: %s', file_name);
end
file_cleanup = onCleanup(@() fclose(fid));

status = fseek(fid, quiet_sample_offset*4, 'bof');
if status ~= 0
    error('Failed to seek to the no-UWB interval.');
end

raw_quiet = fread(fid, [2, quiet_sample_num], 'int16=>double');
quiet_count = size(raw_quiet, 2);
if quiet_count ~= quiet_sample_num
    error('Could not read the complete no-UWB interval.');
end

x_quiet = raw_quiet(1, :) + 1j*raw_quiet(2, :);
clear raw_quiet;

%% Estimate the interference complex amplitude
n_quiet = quiet_sample_offset + (0:quiet_count-1);
quiet_basis = synchronousTone(n_quiet, tone_bin, tone_period_samples);
tone_coefficient = mean(x_quiet .* conj(quiet_basis));

fprintf('Interference estimated from the no-UWB interval\n');
fprintf('  Relative frequency : %+.9f MHz\n', f_tone/1e6);
fprintf('  Absolute frequency : %.9f GHz\n', ...
    (center_frequency + f_tone)/1e9);
fprintf('  Complex coefficient: %.9f %+.9fj\n', ...
    real(tone_coefficient), imag(tone_coefficient));
fprintf('  Amplitude           : %.6f ADC counts\n', ...
    abs(tone_coefficient));
fprintf('  Phase               : %.6f degrees\n\n', ...
    angle(tone_coefficient)*180/pi);

%% Read the interval to visualize
status = fseek(fid, display_sample_offset*4, 'bof');
if status ~= 0
    error('Failed to seek to the display interval.');
end

raw_display = fread(fid, [2, display_sample_num], 'int16=>double');
display_count = size(raw_display, 2);
if display_count < 2
    error('Not enough samples were read for visualization.');
end

x_before = raw_display(1, :) + 1j*raw_display(2, :);
clear raw_display;

%% Reconstruct and subtract the tone in memory
n_display = display_sample_offset + (0:display_count-1);
display_basis = synchronousTone(n_display, tone_bin, tone_period_samples);
interference_estimate = tone_coefficient .* display_basis;
x_after = x_before - interference_estimate;

% Measure the coherent tone remaining in the displayed interval.
tone_before = mean(x_before .* conj(display_basis));
tone_after = mean(x_after .* conj(display_basis));
cancellation_db = 20*log10(abs(tone_before)/max(abs(tone_after), eps));

fprintf('Displayed interval: %.6f--%.6f ms\n', ...
    display_sample_offset/fs*1e3, ...
    (display_sample_offset + display_count - 1)/fs*1e3);
fprintf('Tone amplitude before: %.6f ADC counts\n', abs(tone_before));
fprintf('Tone amplitude after : %.6f ADC counts\n', abs(tone_after));
fprintf('Tone suppression     : %.3f dB\n', cancellation_db);
fprintf('No modified IQ file is written by this script.\n');

%% Calculate spectra with the same window and reference level
N = min([fft_num, display_count]);
window = 0.5 - 0.5*cos(2*pi*(0:N-1)/(N-1));

before_fft = fftshift(fft(x_before(1:N).*window, N));
after_fft = fftshift(fft(x_after(1:N).*window, N));
frequency_rel = (-floor(N/2):ceil(N/2)-1)*fs/N;
frequency_abs = center_frequency + frequency_rel;

reference_level = max(abs(before_fft));
before_db = 20*log10(abs(before_fft)/reference_level + eps);
after_db = 20*log10(abs(after_fft)/reference_level + eps);

%% Visualization
time_us = n_display/fs*1e6;
time_relative_us = (0:display_count-1)/fs*1e6;

figure('Color', 'w', 'Name', 'X410 tone cancellation');
tiledlayout(2, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

% Envelope shows the UWB packet while making the quiet-region baseline clear.
nexttile;
%plot(time_relative_us, abs(x_before), 'LineWidth', 0.8);
plot((x_before(1:end)), 'LineWidth', 0.8);
hold on;
%plot(time_relative_us, abs(x_after), 'LineWidth', 0.8);
plot((x_after(1:end)), 'LineWidth', 0.8);
grid on;
axis equal
xlabel(sprintf('Time from %.6f ms (us)', time_us(1)/1e3));
ylabel('|IQ| (ADC counts)');
title('Time-domain envelope');
legend('Before cancellation', 'After cancellation', 'Location', 'best');

% A short real-part view makes the removed sinusoid directly visible.
nexttile;
short_count = min(3000, display_count);
plot(time_relative_us(1:short_count), real(x_before(1:short_count)), ...
    'LineWidth', 0.8);
hold on;
plot(time_relative_us(1:short_count), real(x_after(1:short_count)), ...
    'LineWidth', 0.8);
grid on;
xlabel('Time (us)');
ylabel('I (ADC counts)');
title('Short waveform detail');
legend('Before cancellation', 'After cancellation', 'Location', 'best');

% Full captured bandwidth using absolute RF frequency.
nexttile;
plot(frequency_abs/1e9, before_db, 'LineWidth', 0.8);
hold on;
plot(frequency_abs/1e9, after_db, 'LineWidth', 0.8);
grid on;
xlabel('Absolute RF frequency (GHz)');
ylabel('Magnitude relative to original peak (dB)');
title('Full-band spectrum');
xlim((center_frequency + [-fs/2, fs/2])/1e9);
ylim([-100, 5]);
legend('Before cancellation', 'After cancellation', 'Location', 'best');

% Zoom around the interference frequency.
nexttile;
tone_absolute_frequency = center_frequency + f_tone;
zoom_mask = abs(frequency_rel - f_tone) <= tone_zoom_half_width;
plot(frequency_abs(zoom_mask)/1e9, before_db(zoom_mask), ...
    'LineWidth', 1);
hold on;
plot(frequency_abs(zoom_mask)/1e9, after_db(zoom_mask), ...
    'LineWidth', 1);
xline(tone_absolute_frequency/1e9, '--k', ...
    sprintf('%.6f GHz', tone_absolute_frequency/1e9));
grid on;
xlabel('Absolute RF frequency (GHz)');
ylabel('Magnitude relative to original peak (dB)');
title(sprintf('Tone detail: suppression %.2f dB', cancellation_db));
ylim([-110, 5]);
legend('Before cancellation', 'After cancellation', 'Location', 'best');

sgtitle('X410 interference cancellation using a no-UWB training interval');

%% Local function
function basis = synchronousTone(n, tone_bin, period_samples)
%SYNCHRONOUSTONE Avoid accumulated phase error over long recordings.
    phase_index = mod(n, period_samples);
    basis = exp(1j*2*pi*tone_bin*phase_index/period_samples);
end
