%% Read and plot an X410 capture file.
% Quick-look script: reads interleaved int16 IQ, plots the time-domain
% waveform and the per-channel spectrum.
clear;
clc;

c = dw1000decoder.constants();

%% Parameters
fileName = 'F:\UWB基带数据\qm35_1.dat';
antNum = 1;           % Number of channels
fs = 737.28e6;        % Sample rate (Hz)
sampleNum = 0.12e6;   % Samples to read from each channel
sampleOffset = 0;     % Starting sample index

%% Read interleaved int16 IQ data
% File order: I1, Q1, I2, Q2, I1, Q1, I2, Q2, ...
raw = dw1000decoder.readIqRaw(fileName, sampleOffset, sampleNum, antNum);

% Remove an incomplete sample frame at the end, if present.
sampleCount = floor(numel(raw) / (2*antNum));
raw = raw(:, 1:sampleCount);

%% Convert to complex samples
% Size of compData: [antNum, sampleCount]
compData = raw(1:2:end, :) + 1j*raw(2:2:end, :);
t = (sampleOffset + (0:sampleCount-1)) / fs;

clear raw;

%% Quick plot
plotNum = min(sampleCount, 4000000);
figure;
plot(t(1:plotNum)*1e6, real(compData(:, 1:plotNum)).'); hold on
plot(t(1:plotNum)*1e6, imag(compData(:, 1:plotNum)).');
grid on;
xlabel('Time (us)');
ylabel('|IQ|');

%% Spectrum analysis
fftNum = min(sampleCount, 262144);
fftData = compData(:, 1:fftNum);

% Hann window reduces spectral leakage.
window = 0.5 - 0.5*cos(2*pi*(0:fftNum-1)/(fftNum-1));
fftResult = fftshift(fft(fftData .* window, fftNum, 2), 2);

% Normalize each channel spectrum to 0 dB.
spectrumDb = 20*log10(abs(fftResult) + eps);
spectrumDb = spectrumDb - max(spectrumDb, [], 2);
frequency = (-floor(fftNum/2):ceil(fftNum/2)-1) * fs/fftNum;

figure;
plot(frequency/1e6, spectrumDb.');
grid on;
xlabel('Relative frequency (MHz)');
ylabel('Normalized magnitude (dB)');
title('Frequency spectrum');
xlim([-fs/2, fs/2]/1e6);
