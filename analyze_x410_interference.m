clear;
clc;

%% X410 无 UWB 区间的窄带干扰分析
% 数据格式：交织 int16 IQ，即 I1,Q1,I1,Q1,...
% 本脚本使用已确认不含 UWB 脉冲的区间，估计主单音的精确频率，
% 并分析与采样时钟相关的复制谱线、镜像、直流和功率占比。

%% Parameters
file_name = 'F:\qm35_1.dat';
fs = 737.28e6;                 % Sample rate (Hz)
center_frequency = 6489.6e6;  % X410 RF center frequency (Hz), modify if needed

% For qm35_1.dat, about 0.49--3.09 ms is free of UWB packets.
% The following interval (0.5425--2.5767 ms) lies inside that quiet region.
sample_offset = 400000;
sample_num = 1500000;

fft_num = 2^20;
peak_count = 15;
peak_guard_bins = 5;

%% Read complex IQ samples
fid = fopen(file_name, 'rb');
if fid < 0
    error('Cannot open file: %s', file_name);
end

cleanupObj = onCleanup(@() fclose(fid));
status = fseek(fid, sample_offset * 4, 'bof');
if status ~= 0
    error('Failed to seek to sample offset %d.', sample_offset);
end

raw = fread(fid, [2, sample_num], 'int16=>single');
sample_count = size(raw, 2);
if sample_count < 2
    error('Not enough IQ samples were read.');
end

x = raw(1, :) + 1j * raw(2, :);
clear raw;
n = 0:sample_count-1;

fprintf('Analyzed interval: %.6f--%.6f ms\n', ...
    sample_offset/fs*1e3, (sample_offset + sample_count - 1)/fs*1e3);
fprintf('Samples: %d, sample rate: %.6f MHz\n\n', sample_count, fs/1e6);

%% Coarse FFT estimate
N = min(fft_num, sample_count);
x_fft = x(1:N);
x_fft = x_fft - mean(x_fft);
window = 0.5 - 0.5*cos(2*pi*(0:N-1)/(N-1));
X = fftshift(fft(x_fft .* window, N));
frequency_rel = (-floor(N/2):ceil(N/2)-1) * fs/N;

[~, main_bin] = max(abs(X));
f_coarse = frequency_rel(main_bin);

%% Sub-bin frequency estimate by residual-phase regression
% Mix the coarse FFT estimate to DC, then fit the remaining phase slope.
% This avoids limiting the result to the FFT-bin spacing fs/N.
x_mixed = x .* exp(-1j*2*pi*f_coarse*n/fs);
residual_phase = unwrap(angle(x_mixed));
n_centered = n - mean(n);
phase_slope = sum(n_centered .* (residual_phase - mean(residual_phase))) / ...
              sum(n_centered.^2);
f_tone_rel = f_coarse + phase_slope*fs/(2*pi);
f_tone_abs = center_frequency + f_tone_rel;

%% Tone power, residual power, DC and conjugate image
tone_coefficient = mean(x .* exp(-1j*2*pi*f_tone_rel*n/fs));
tone_amplitude = abs(tone_coefficient);
total_power = mean(abs(x).^2);
tone_power = tone_amplitude^2;
residual_power = max(total_power - tone_power, 0);
tone_power_fraction = tone_power / total_power;
tone_to_residual_db = 10*log10(tone_power/max(residual_power, eps));

dc_amplitude = abs(mean(x));
image_frequency = wrapToNyquist(-f_tone_rel, fs);
image_amplitude = abs(mean(x .* exp(-1j*2*pi*image_frequency*n/fs)));
dc_dbc = 20*log10(max(dc_amplitude, eps)/tone_amplitude);
image_dbc = 20*log10(max(image_amplitude, eps)/tone_amplitude);

fprintf('Dominant tone results\n');
fprintf('  Coarse FFT frequency : %+.6f MHz (bin spacing %.3f Hz)\n', ...
    f_coarse/1e6, fs/N);
fprintf('  Refined relative freq: %+.9f MHz\n', f_tone_rel/1e6);
fprintf('  Absolute frequency   : %.9f GHz\n', f_tone_abs/1e9);
fprintf('  Relation to fs       : f/fs = %.12f (expected near -169/512)\n', ...
    f_tone_rel/fs);
fprintf('  Complex amplitude    : %.3f ADC counts\n', tone_amplitude);
fprintf('  Tone power fraction  : %.3f %%\n', 100*tone_power_fraction);
fprintf('  Tone/residual power  : %.3f dB\n', tone_to_residual_db);
fprintf('  DC component         : %.2f dBc\n', dc_dbc);
fprintf('  Conjugate image      : %.2f dBc at %+.6f MHz relative\n\n', ...
    image_dbc, image_frequency/1e6);

%% Analyze the fs/8 replica comb
% The measured data contains replicas spaced by 92.16 MHz = fs/8.
comb_spacing = fs/8;
comb_index = (-1:6).';
comb_frequency_rel = wrapToNyquist(f_tone_rel + comb_index*comb_spacing, fs);
comb_amplitude = zeros(size(comb_frequency_rel));

for k = 1:numel(comb_frequency_rel)
    c = mean(x .* exp(-1j*2*pi*comb_frequency_rel(k)*n/fs));
    comb_amplitude(k) = abs(c);
end

comb_dbc = 20*log10(max(comb_amplitude, eps)/tone_amplitude);
comb_frequency_abs = center_frequency + comb_frequency_rel;
comb_table = table(comb_index, comb_frequency_rel/1e6, ...
    comb_frequency_abs/1e9, comb_dbc, ...
    'VariableNames', {'CombIndex', 'RelativeFrequency_MHz', ...
    'AbsoluteFrequency_GHz', 'Level_dBc'});

fprintf('Replica comb: spacing = fs/8 = %.6f MHz\n', comb_spacing/1e6);
disp(comb_table);

%% List strongest separated FFT peaks
spectrum_db = 20*log10(abs(X) + eps);
spectrum_db = spectrum_db - max(spectrum_db);
[~, sorted_bins] = sort(spectrum_db, 'descend');
selected_bins = zeros(1, peak_count);
selected_count = 0;

for candidate = sorted_bins
    if selected_count == 0 || ...
            all(abs(candidate - selected_bins(1:selected_count)) > peak_guard_bins)
        selected_count = selected_count + 1;
        selected_bins(selected_count) = candidate;
        if selected_count == peak_count
            break;
        end
    end
end

selected_bins = selected_bins(1:selected_count);
peak_relative_mhz = frequency_rel(selected_bins).'/1e6;
peak_absolute_ghz = (center_frequency + frequency_rel(selected_bins)).'/1e9;
peak_level_dbc = spectrum_db(selected_bins).';
peak_table = table(peak_relative_mhz, peak_absolute_ghz, peak_level_dbc, ...
    'VariableNames', {'RelativeFrequency_MHz', 'AbsoluteFrequency_GHz', ...
    'FFT_Level_dBc'});

fprintf('Strongest separated spectral peaks\n');
disp(peak_table);

%% Plot spectrum using absolute RF frequency
figure('Color', 'w');
plot((center_frequency + frequency_rel)/1e9, spectrum_db, 'LineWidth', 1);
grid on;
xlabel('Absolute RF frequency (GHz)');
ylabel('Normalized magnitude (dB)');
title(sprintf('No-UWB spectrum: dominant tone %.6f GHz', f_tone_abs/1e9));
xlim((center_frequency + [-fs/2, fs/2])/1e9);
ylim([-100, 5]);

hold on;
plot(f_tone_abs/1e9, 0, 'ro', 'MarkerFaceColor', 'r');
text(f_tone_abs/1e9, -5, sprintf('  %.6f GHz', f_tone_abs/1e9), ...
    'Color', 'r', 'VerticalAlignment', 'top');

fprintf(['Interpretation: a stable tone exactly related to fs, together with an ', ...
    'fs/8 replica comb, is consistent with a clock-, NCO-, DDC-, or ', ...
    'interleaving-related deterministic spur.\n']);

%% Local function
function f = wrapToNyquist(f, fs)
    f = mod(f + fs/2, fs) - fs/2;
end
