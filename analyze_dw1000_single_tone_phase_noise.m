%% Analyze phase noise of a captured DW1000 single tone
% The input file contains one channel of interleaved int16 samples:
% I0, Q0, I1, Q1, ...
%
% The reported SSB phase noise is
%   L(f) = 10*log10(S_phi(f)/2)  [dBc/Hz],
% where S_phi is the one-sided PSD of the residual phase in rad^2/Hz.
%
% Important: this is a residual measurement. It contains the combined
% phase noise of the DW1000 transmitter, the USRP receiver LO, and the
% sampling clock. Measuring the DW1000 alone requires a cleaner reference
% receiver or a cross-correlation phase-noise measurement.

clear;
clc;
close all;

%% User parameters
file_name = 'F:\UWB基带数据\dw1000_single_tone_1.dat';
sample_rate_hz = 737.28e6;
receiver_center_frequency_hz = 6489.6e6;

sample_offset = 0;               % Zero-based complex-sample offset
analysis_duration_s = inf;       % inf analyzes all samples after the offset
decimation_factor = 64;          % Must be an integer >= 2
maximum_plot_offset_hz = 2e6;    % Stay well inside the decimator passband
welch_segment_length = 2^20;
welch_overlap_fraction = 0.5;
integration_band_hz = [10, 2e6];
report_offset_frequencies_hz = [100, 1e3, 10e3, 100e3, 1e6];
edge_discard_duration_s = 1e-6;

carrier_estimation_samples = 2^22;
input_block_samples = 2^20;      % Must be a multiple of decimation_factor
output_directory = fullfile(pwd, 'phase_noise_results');

%% Validate the input and determine the analysis span
arguments_to_check = [sample_rate_hz, decimation_factor, ...
    carrier_estimation_samples, input_block_samples];
assert(all(isfinite(arguments_to_check) & arguments_to_check > 0), ...
    'Sampling and block parameters must be positive and finite.');
assert(mod(decimation_factor, 1) == 0 && decimation_factor >= 2, ...
    'decimation_factor must be an integer >= 2.');
assert(mod(input_block_samples, decimation_factor) == 0, ...
    'input_block_samples must be a multiple of decimation_factor.');
assert(isfile(file_name), 'Input file does not exist: %s', file_name);

file_info = dir(file_name);
bytes_per_complex_sample = 4;
total_file_samples = floor(file_info.bytes / bytes_per_complex_sample);
available_samples = total_file_samples - sample_offset;
assert(available_samples > carrier_estimation_samples, ...
    'The selected input interval is too short.');

if isinf(analysis_duration_s)
    requested_samples = available_samples;
else
    requested_samples = min(available_samples, ...
        floor(analysis_duration_s * sample_rate_hz));
end
analysis_samples = floor(requested_samples / decimation_factor) * ...
    decimation_factor;
assert(analysis_samples > 0, 'No complete decimation block is available.');

if ~isfolder(output_directory)
    mkdir(output_directory);
end

fprintf('DW1000 single-tone phase-noise analysis\n');
fprintf('  Input file       : %s\n', file_name);
fprintf('  File samples     : %d (%.6f s)\n', total_file_samples, ...
    total_file_samples/sample_rate_hz);
fprintf('  Analyzed samples : %d (%.6f s)\n', analysis_samples, ...
    analysis_samples/sample_rate_hz);

%% Estimate the carrier frequency from the beginning of the selected span
estimate_count = min(carrier_estimation_samples, analysis_samples);
fid = fopen(file_name, 'rb');
assert(fid >= 0, 'Cannot open input file: %s', file_name);
file_cleanup = onCleanup(@() fclose(fid));

seek_status = fseek(fid, sample_offset*bytes_per_complex_sample, 'bof');
assert(seek_status == 0, 'Failed to seek to sample_offset.');
raw_estimate = fread(fid, [2, estimate_count], 'int16=>double');
assert(size(raw_estimate, 2) == estimate_count, ...
    'Could not read the carrier-estimation interval.');
x_estimate = complex(raw_estimate(1, :), raw_estimate(2, :));
clear raw_estimate;

dc_estimate = mean(x_estimate);
x_estimate = x_estimate - dc_estimate;
estimate_window = hann(estimate_count, 'periodic').';
estimate_spectrum = fftshift(fft(x_estimate .* estimate_window));
[~, peak_index] = max(abs(estimate_spectrum));
coarse_frequency_hz = ((peak_index-1) - floor(estimate_count/2)) * ...
    sample_rate_hz / estimate_count;

estimate_indices = 0:estimate_count-1;
coarse_removed = x_estimate .* exp(-1j*2*pi*coarse_frequency_hz * ...
    estimate_indices/sample_rate_hz);
residual_phase = unwrap(angle(coarse_removed));
centered_indices = estimate_indices - mean(estimate_indices);
phase_slope_per_sample = sum(centered_indices .* residual_phase) / ...
    sum(centered_indices.^2);
carrier_frequency_hz = coarse_frequency_hz + ...
    phase_slope_per_sample*sample_rate_hz/(2*pi);
carrier_amplitude_adc = abs(mean(x_estimate .* exp(-1j*2*pi * ...
    carrier_frequency_hz*estimate_indices/sample_rate_hz)));
signal_rms_adc = rms(x_estimate);
clipped_count = nnz(abs(real(x_estimate + dc_estimate)) >= 32767 | ...
    abs(imag(x_estimate + dc_estimate)) >= 32767);

fprintf('  Carrier offset    : %+.9f MHz\n', carrier_frequency_hz/1e6);
fprintf('  RF carrier        : %.9f GHz\n', ...
    (receiver_center_frequency_hz + carrier_frequency_hz)/1e9);
fprintf('  Carrier amplitude : %.3f ADC counts\n', carrier_amplitude_adc);
fprintf('  Signal RMS        : %.3f ADC counts\n', signal_rms_adc);
fprintf('  Clipped samples   : %d in estimation interval\n', clipped_count);

%% Stream, downconvert, and weighted-block decimate
% Each output is a Hann-weighted coherent average of D input samples.
% This integrate-and-dump phase detector avoids loading the 1.47 GB file
% into memory and suppresses far-out noise before downsampling.
seek_status = fseek(fid, sample_offset*bytes_per_complex_sample, 'bof');
assert(seek_status == 0, 'Failed to return to sample_offset.');

decimation_window = hann(decimation_factor, 'periodic');
decimation_window = decimation_window / sum(decimation_window);
output_sample_rate_hz = sample_rate_hz / decimation_factor;
output_count = analysis_samples / decimation_factor;
baseband = complex(zeros(output_count, 1, 'single'));

input_position = 0;
output_position = 0;
next_progress = 10;
while input_position < analysis_samples
    block_count = min(input_block_samples, analysis_samples-input_position);
    raw_block = fread(fid, [2, block_count], 'int16=>single');
    actual_count = size(raw_block, 2);
    assert(actual_count == block_count, ...
        'Unexpected end of file at input sample %d.', input_position);

    x_block = complex(raw_block(1, :), raw_block(2, :));
    clear raw_block;
    absolute_indices = sample_offset + input_position + (0:block_count-1);
    oscillator = single(exp(-1j*2*pi*carrier_frequency_hz/sample_rate_hz .* ...
        absolute_indices));
    mixed_block = x_block .* oscillator;

    block_matrix = reshape(mixed_block, decimation_factor, []);
    decimated_block = sum(block_matrix .* decimation_window, 1);
    block_output_count = numel(decimated_block);
    output_indices = output_position + (1:block_output_count);
    baseband(output_indices) = decimated_block;

    input_position = input_position + block_count;
    output_position = output_position + block_output_count;
    progress_percent = floor(100*input_position/analysis_samples);
    if progress_percent >= next_progress
        fprintf('  Processing        : %3d%%\n', progress_percent);
        next_progress = next_progress + 10;
    end
end

%% Extract residual phase and remove only constant frequency error
baseband = double(baseband);
edge_discard_samples = round(edge_discard_duration_s*output_sample_rate_hz);
assert(2*edge_discard_samples < output_count, ...
    'edge_discard_duration_s removes the complete record.');
baseband = baseband(edge_discard_samples+1:end-edge_discard_samples);
output_count = numel(baseband);
amplitude = abs(baseband);
phase_rad = unwrap(angle(baseband));
time_s = (edge_discard_samples + (0:output_count-1)).' / ...
    output_sample_rate_hz;
centered_time_s = time_s - mean(time_s);
linear_phase_slope = sum(centered_time_s .* phase_rad) / ...
    sum(centered_time_s.^2);
linear_phase_intercept = mean(phase_rad);
phase_residual_rad = phase_rad - ...
    (linear_phase_intercept + linear_phase_slope*centered_time_s);
phase_residual_deg = rad2deg(phase_residual_rad);
refined_carrier_frequency_hz = carrier_frequency_hz + ...
    linear_phase_slope/(2*pi);

fprintf('  Refined offset    : %+.9f MHz\n', ...
    refined_carrier_frequency_hz/1e6);
fprintf('  Mean amplitude    : %.3f ADC counts\n', mean(amplitude));

%% Statistics over the complete decimated phase record
phase_statistics = struct();
phase_statistics.sample_count = output_count;
phase_statistics.sample_rate_hz = output_sample_rate_hz;
phase_statistics.mean_deg = mean(phase_residual_deg);
phase_statistics.median_deg = median(phase_residual_deg);
phase_statistics.standard_deviation_deg = std(phase_residual_deg);
phase_statistics.rms_deg = rms(phase_residual_deg);
phase_statistics.minimum_deg = min(phase_residual_deg);
phase_statistics.maximum_deg = max(phase_residual_deg);
phase_statistics.peak_to_peak_deg = range(phase_residual_deg);
phase_percentiles_deg = prctile(phase_residual_deg, [1, 99]);
phase_statistics.percentile_1_deg = phase_percentiles_deg(1);
phase_statistics.percentile_99_deg = phase_percentiles_deg(2);
phase_statistics.percentile_1_to_99_span_deg = diff(phase_percentiles_deg);
phase_statistics.start_to_end_change_deg = ...
    phase_residual_deg(end) - phase_residual_deg(1);

fprintf('  Full-record phase statistics (linear frequency removed):\n');
fprintf('    Mean / median    : %+.6f / %+.6f deg\n', ...
    phase_statistics.mean_deg, phase_statistics.median_deg);
fprintf('    Standard dev/RMS: %.6f / %.6f deg\n', ...
    phase_statistics.standard_deviation_deg, phase_statistics.rms_deg);
fprintf('    Minimum/maximum : %+.6f / %+.6f deg\n', ...
    phase_statistics.minimum_deg, phase_statistics.maximum_deg);
fprintf('    Peak-to-peak     : %.6f deg\n', ...
    phase_statistics.peak_to_peak_deg);
fprintf('    1%%--99%% interval : %+.6f to %+.6f deg (span %.6f deg)\n', ...
    phase_statistics.percentile_1_deg, ...
    phase_statistics.percentile_99_deg, ...
    phase_statistics.percentile_1_to_99_span_deg);
fprintf('    Start-to-end     : %+.6f deg\n', ...
    phase_statistics.start_to_end_change_deg);

%% Welch phase PSD and SSB phase noise
segment_length = min(welch_segment_length, output_count);
segment_length = 2^floor(log2(segment_length));
overlap_length = floor(welch_overlap_fraction*segment_length);
welch_window = hann(segment_length, 'periodic');
nfft = segment_length;
[phase_psd_rad2_per_hz, offset_frequency_hz] = pwelch( ...
    phase_residual_rad, welch_window, overlap_length, nfft, ...
    output_sample_rate_hz, 'onesided');
ssb_phase_noise_dbc_per_hz = 10*log10( ...
    max(phase_psd_rad2_per_hz/2, realmin));

valid_integration = offset_frequency_hz >= integration_band_hz(1) & ...
    offset_frequency_hz <= integration_band_hz(2);
assert(nnz(valid_integration) >= 2, ...
    'The requested integration band contains too few PSD bins.');
integrated_phase_variance = trapz( ...
    offset_frequency_hz(valid_integration), ...
    phase_psd_rad2_per_hz(valid_integration));
integrated_rms_phase_rad = sqrt(integrated_phase_variance);
integrated_rms_phase_deg = rad2deg(integrated_rms_phase_rad);
rf_carrier_frequency_hz = receiver_center_frequency_hz + ...
    refined_carrier_frequency_hz;
integrated_rms_jitter_s = integrated_rms_phase_rad / ...
    (2*pi*abs(rf_carrier_frequency_hz));

fprintf('  Welch resolution  : %.3f Hz\n', ...
    output_sample_rate_hz/nfft);
fprintf('  Integrated RMS phase (%g Hz--%g Hz): %.6g deg\n', ...
    integration_band_hz(1), integration_band_hz(2), ...
    integrated_rms_phase_deg);
fprintf('  Equivalent jitter : %.6g ps at %.9f GHz\n', ...
    integrated_rms_jitter_s*1e12, rf_carrier_frequency_hz/1e9);

valid_report_offsets = report_offset_frequencies_hz > ...
    offset_frequency_hz(2) & report_offset_frequencies_hz <= ...
    offset_frequency_hz(end);
reported_offsets_hz = report_offset_frequencies_hz(valid_report_offsets);
reported_phase_noise_dbc_per_hz = interp1(offset_frequency_hz(2:end), ...
    ssb_phase_noise_dbc_per_hz(2:end), reported_offsets_hz, ...
    'linear');
fprintf('  Phase-noise points:\n');
for report_index = 1:numel(reported_offsets_hz)
    fprintf('    %9.0f Hz : %8.3f dBc/Hz\n', ...
        reported_offsets_hz(report_index), ...
        reported_phase_noise_dbc_per_hz(report_index));
end

%% Plot diagnostics and phase noise
figure_handle = figure('Color', 'w', ...
    'Name', 'DW1000 single-tone phase noise');
tiledlayout(2, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

nexttile;
waveform_plot_stride = max(1, floor(estimate_count/200000));
waveform_plot_indices = 1:waveform_plot_stride:estimate_count;
plot((waveform_plot_indices-1)/sample_rate_hz*1e3, ...
    real(x_estimate(waveform_plot_indices)), 'LineWidth', 0.7);
grid on;
xlabel('Time (ms)');
ylabel('I (ADC counts)');
title('Captured tone (estimation interval)');

nexttile;
plot(time_s*1e3, amplitude, 'LineWidth', 0.7);
grid on;
xlabel('Time (ms)');
ylabel('Amplitude (ADC counts)');
title('Downconverted amplitude');

nexttile;
maximum_phase_plot_points = 200000;
phase_plot_stride = max(1, ceil(output_count/maximum_phase_plot_points));
phase_plot_indices = 1:phase_plot_stride:output_count;
plot(time_s(phase_plot_indices)*1e3, ...
    phase_residual_deg(phase_plot_indices), 'LineWidth', 0.7);
grid on;
xlabel('Time (ms)');
ylabel('Residual phase (deg)');
title(sprintf('Full-record residual phase (plot stride %d)', ...
    phase_plot_stride));

nexttile;
plot_mask = offset_frequency_hz > 0 & ...
    offset_frequency_hz <= maximum_plot_offset_hz;
semilogx(offset_frequency_hz(plot_mask), ...
    ssb_phase_noise_dbc_per_hz(plot_mask), 'LineWidth', 1);
grid on;
xlabel('Offset frequency (Hz)');
ylabel('L(f) (dBc/Hz)');
title('SSB phase noise');
xlim([max(offset_frequency_hz(2), integration_band_hz(1)), ...
    maximum_plot_offset_hz]);

input_base_name = erase(string(file_info.name), ".dat");
png_file = fullfile(output_directory, ...
    input_base_name + "_phase_noise.png");
mat_file = fullfile(output_directory, ...
    input_base_name + "_phase_noise.mat");
exportgraphics(figure_handle, png_file, 'Resolution', 180);

results = struct();
results.input_file = file_name;
results.sample_rate_hz = sample_rate_hz;
results.sample_offset = sample_offset;
results.analysis_samples = analysis_samples;
results.analysis_duration_s = analysis_samples/sample_rate_hz;
results.receiver_center_frequency_hz = receiver_center_frequency_hz;
results.carrier_offset_hz = refined_carrier_frequency_hz;
results.rf_carrier_frequency_hz = rf_carrier_frequency_hz;
results.carrier_amplitude_adc = carrier_amplitude_adc;
results.output_sample_rate_hz = output_sample_rate_hz;
results.phase_time_s = single(time_s);
results.phase_residual_deg = single(phase_residual_deg);
results.phase_statistics = phase_statistics;
results.offset_frequency_hz = offset_frequency_hz;
results.phase_psd_rad2_per_hz = phase_psd_rad2_per_hz;
results.ssb_phase_noise_dbc_per_hz = ssb_phase_noise_dbc_per_hz;
results.reported_offsets_hz = reported_offsets_hz;
results.reported_phase_noise_dbc_per_hz = ...
    reported_phase_noise_dbc_per_hz;
results.integration_band_hz = integration_band_hz;
results.integrated_rms_phase_rad = integrated_rms_phase_rad;
results.integrated_rms_phase_deg = integrated_rms_phase_deg;
results.integrated_rms_jitter_s = integrated_rms_jitter_s;
save(mat_file, 'results');

fprintf('  Figure saved      : %s\n', png_file);
fprintf('  Results saved     : %s\n', mat_file);
