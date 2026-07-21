clear;
clc;

%% Parameters
file_name = 'F:\UWB基带数据\qm35_1.dat';
ant_num = 1;           % Number of channels
fs = 737.28e6;         % Sample rate (Hz)
sample_num = 0.12e6;   % Samples to read from each channel
sample_offset = 0;     % Starting sample index

%% Read interleaved int16 IQ data
% File order: I1, Q1, I2, Q2, I1, Q1, I2, Q2, ...
fid = fopen(file_name, 'rb');
if fid < 0
    error('Cannot open file: %s', file_name);
end

fseek(fid, sample_offset * ant_num * 4, 'bof');
raw = fread(fid, [2 * ant_num, sample_num], 'int16=>double');
fclose(fid);

% Remove an incomplete sample frame at the end, if present.
sample_count = floor(numel(raw) / (2 * ant_num));
raw = raw(:, 1:sample_count);

%% Convert to complex samples
% Size of comp_data: [ant_num, sample_count]
comp_data = raw(1:2:end, :) + 1j * raw(2:2:end, :);
t = (sample_offset + (0:sample_count-1)) / fs;

clear raw fid;

%% Quick plot
plot_num = min(sample_count, 4000000);
figure;
plot(t(1:plot_num) * 1e6, real(comp_data(:, 1:plot_num)).');hold on
plot(t(1:plot_num) * 1e6, imag(comp_data(:, 1:plot_num)).');
grid on;
xlabel('Time (us)');
ylabel('|IQ|');

%% Spectrum analysis
fft_num = min(sample_count, 262144);
fft_data = comp_data(:, 1:fft_num);

% Hann window reduces spectral leakage.
window = 0.5 - 0.5 * cos(2*pi*(0:fft_num-1)/(fft_num-1));
fft_result = fftshift(fft(fft_data .* window, fft_num, 2), 2);

% Normalize each channel spectrum to 0 dB.
spectrum_db = 20*log10(abs(fft_result) + eps);
spectrum_db = spectrum_db - max(spectrum_db, [], 2);
frequency = (-floor(fft_num/2):ceil(fft_num/2)-1) * fs/fft_num;

figure;
plot(frequency/1e6, spectrum_db.');
grid on;
xlabel('Relative frequency (MHz)');
ylabel('Normalized magnitude (dB)');
title('Frequency spectrum');
xlim([-fs/2, fs/2]/1e6);
