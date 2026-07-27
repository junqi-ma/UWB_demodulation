%% Read and inspect the capture after DW1000 cancellation.
% Aligned before/after comparison: reads the original and cancelled captures,
% plots time-domain I/Q and the spectrum of the removed component.
clear;
close all;
clc;

c = uwbdecoder.constants();

%% -------------------- User configuration --------------------
originalFileName = 'F:\UWB基带数据\DW1000_2.dat';
cancelledFileName = fullfile(pwd, 'decoded_results', ...
    'DW1000_2_all_dw1000_cancelled.dat');

fs = 737.28e6;          % Complex sample rate (Hz)
antNum = 1;             % Number of interleaved antenna channels
channelIdx = 1;         % Channel to return and plot
sampleOffset = 7778186; % Zero-based complex-sample offset
sampleNum = 1e6;        % Use Inf to read from offset to end of file

%% -------------------- Check file and requested interval --------------------
if ~isfile(originalFileName)
    error('read_uwb_cancelled_dat:FileNotFound', ...
        'Original capture not found: %s', originalFileName);
end
if ~isfile(cancelledFileName)
    error('read_uwb_cancelled_dat:FileNotFound', ...
        'Cancelled capture not found: %s', cancelledFileName);
end
if channelIdx < 1 || channelIdx > antNum
    error('read_uwb_cancelled_dat:InvalidChannel', ...
        'channelIdx must be in the range 1..ant_num.');
end

fileInfo = dir(cancelledFileName);
originalFileInfo = dir(originalFileName);
bytesPerTimeSample = c.BYTES_PER_IQ_SAMPLE*antNum;
if mod(fileInfo.bytes, bytesPerTimeSample) ~= 0
    error('read_uwb_cancelled_dat:InvalidFileSize', ...
        'File size is not compatible with %d interleaved channel(s). Check ant_num.', ...
        antNum);
end
totalSamples = fileInfo.bytes / bytesPerTimeSample;
if mod(originalFileInfo.bytes, bytesPerTimeSample) ~= 0
    error('read_uwb_cancelled_dat:InvalidOriginalFileSize', ...
        'Original file size is not compatible with %d interleaved channel(s). Check ant_num.', ...
        antNum);
end
originalTotalSamples = originalFileInfo.bytes / bytesPerTimeSample;
if originalTotalSamples ~= totalSamples
    error('read_uwb_cancelled_dat:LengthMismatch', ...
        ['Original and cancelled captures have different lengths ', ...
         '(%d versus %d samples), so they cannot be aligned.'], ...
        originalTotalSamples, totalSamples);
end
if sampleOffset < 0 || sampleOffset ~= fix(sampleOffset) || ...
        sampleOffset >= totalSamples
    error('read_uwb_cancelled_dat:InvalidOffset', ...
        'sampleOffset must be an integer in the range 0..%d.', ...
        totalSamples - 1);
end

if isinf(sampleNum)
    readCount = totalSamples - sampleOffset;
else
    if sampleNum <= 0 || sampleNum ~= fix(sampleNum)
        error('read_uwb_cancelled_dat:InvalidSampleNum', ...
            'sampleNum must be a positive integer or Inf.');
    end
    readCount = min(sampleNum, totalSamples - sampleOffset);
end

%% -------------------- Read interleaved int16 IQ --------------------
[~, rxCancelled] = readIqSegment(cancelledFileName, sampleOffset, readCount, ...
    antNum, channelIdx, c);
timeS = (sampleOffset + (0:readCount-1).') / fs;

[~, rxOriginal] = readIqSegment(originalFileName, sampleOffset, readCount, ...
    antNum, channelIdx, c);

%% -------------------- Aligned time-domain comparison --------------------
plotCount = min(readCount, 2e5);
plotTimeMs = timeS(1:plotCount)*1e3;

figure('Name', 'Before and after DW1000 cancellation', 'Color', 'w');
subplot(3, 1, 1);
plot(plotTimeMs, real(rxOriginal(1:plotCount)));
hold on;
plot(plotTimeMs, real(rxCancelled(1:plotCount)), '--');
grid on;
xlabel('Capture time (ms)');
ylabel('I (ADC counts)');
legend('Before cancellation', 'After cancellation');
title(sprintf('Aligned IQ comparison, channel %d', channelIdx));

subplot(3, 1, 2);
plot(plotTimeMs, imag(rxOriginal(1:plotCount)));
hold on;
plot(plotTimeMs, imag(rxCancelled(1:plotCount)), '--');
grid on;
xlabel('Capture time (ms)');
ylabel('Q (ADC counts)');
legend('Before cancellation', 'After cancellation');

subplot(3, 1, 3);
plot(plotTimeMs, abs(rxOriginal(1:plotCount)));
hold on;
plot(plotTimeMs, abs(rxCancelled(1:plotCount)), '--');
grid on;
xlabel('Capture time (ms)');
ylabel('|IQ| (ADC counts)');
legend('Before cancellation', 'After cancellation');

%% -------------------- Aligned spectrum comparison --------------------
fftNum = min(readCount, 262144);
if fftNum >= 2
    window = 0.5 - 0.5*cos(2*pi*(0:fftNum-1).'/(fftNum-1));
    originalSpectrum = abs(fftshift(fft(rxOriginal(1:fftNum).*window)));
    cancelledSpectrum = abs(fftshift(fft(rxCancelled(1:fftNum).*window)));
    spectrumReference = max(originalSpectrum);
    originalSpectrumDb = 20*log10(originalSpectrum / spectrumReference + eps);
    cancelledSpectrumDb = 20*log10(cancelledSpectrum / spectrumReference + eps);
    frequencyHz = (-floor(fftNum/2):ceil(fftNum/2)-1).'*fs / fftNum;

    figure('Name', 'Spectrum before and after DW1000 cancellation', ...
        'Color', 'w');
    plot(frequencyHz/1e6, originalSpectrumDb);
    hold on;
    plot(frequencyHz/1e6, cancelledSpectrumDb);
    grid on;
    xlabel('Relative frequency (MHz)');
    ylabel('Magnitude relative to original peak (dB)');
    title(sprintf('Aligned spectrum comparison, channel %d', channelIdx));
    legend('Before cancellation', 'After cancellation');
    xlim([-fs/2, fs/2]/1e6);
end

rmsOriginal = sqrt(mean(abs(rxOriginal).^2));
rmsCancelled = sqrt(mean(abs(rxCancelled).^2));
rmsChangeDb = 20*log10((rmsCancelled + eps) / (rmsOriginal + eps));
peakOriginal = max(abs(rxOriginal));
peakCancelled = max(abs(rxCancelled));
peakChangeDb = 20*log10((peakCancelled + eps) / (peakOriginal + eps));

fprintf('\n======= Cancellation comparison reader =======\n');
fprintf('Original file         : %s\n', originalFileName);
fprintf('Cancelled file        : %s\n', cancelledFileName);
fprintf('File samples          : %d (%.6f s)\n', totalSamples, ...
    totalSamples / fs);
fprintf('Read interval         : %d..%d\n', sampleOffset, ...
    sampleOffset + readCount - 1);
fprintf('Returned samples      : %d\n', numel(rxCancelled));
fprintf('Selected channel      : %d / %d\n', channelIdx, antNum);
fprintf('Original RMS          : %.3f ADC counts\n', rmsOriginal);
fprintf('Cancelled RMS         : %.3f ADC counts\n', rmsCancelled);
fprintf('RMS change            : %+.3f dB\n', rmsChangeDb);
fprintf('Peak change           : %+.3f dB\n', peakChangeDb);
fprintf('Variables              : rxOriginal, rxCancelled, timeS\n');
fprintf('==============================================\n');

assignin('base', 'rx_original', rxOriginal);
assignin('base', 'rx_cancelled', rxCancelled);
assignin('base', 'rx_original_time_s', timeS);
assignin('base', 'rx_cancelled_time_s', timeS);

% -------------------------------------------------------------------------
function [raw, rx] = readIqSegment(fileName, sampleOffset, sampleNum, ...
        antNum, channelIdx, c)
raw = uwbdecoder.readIqRaw(fileName, sampleOffset, sampleNum, antNum);
rx = uwbdecoder.selectIqChannel(raw, channelIdx);
end
