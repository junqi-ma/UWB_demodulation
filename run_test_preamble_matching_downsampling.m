%% Test UWB packet-start search with different preamble downsampling factors.
% A synthetic IEEE 802.15.4a UWB packet is preceded by an all-zero segment.
% The complete SYNC preamble is matched from the beginning of the capture.
% For every downsampling factor, this script reports:
%   1. the detected packet-start sample and its timing error;
%   2. the median wall-clock search time over several repeated runs.
%
% The received packet retains the transmitter pulse shaping, while the
% matching template is the raw sparse {-1, 0, +1} pulse sequence before
% pulse shaping.  PREAMBLE_DOWNSAMPLING can be edited to test other factors.

clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% Test configuration
fs = 998.4e6;
code_index = 10;
preamble_repetitions = 64;
psdu_length_bytes = 20;
empty_samples = 160000;          % Must be divisible by every factor below.
preamble_downsampling = [1 2 4 8 16 32 64];
benchmark_repetitions = 20;
show_plot = true;
cir_delay_range_ns = [-100 300];

if any(mod(empty_samples, preamble_downsampling) ~= 0)
    error('run_test_preamble_matching_downsampling:GridMisalignment', ...
        ['empty_samples must be divisible by every downsampling factor ', ...
         'so that all tests use the same decimation phase.']);
end

%% Generate one UWB packet and prepend an empty signal
rng(42, 'twister');
psdu_bits = randi([0 1], 8*psdu_length_bytes, 1);
cfg = lrwpanHRPConfig(Mode='802.15.4a', MeanPRF=62.4, ...
    DataRate=6.81, PreambleDuration=preamble_repetitions, ...
    CodeIndex=code_index, SamplesPerPulse=2, ...
    PSDULength=psdu_length_bytes);
[packet, packet_pulse_symbols] = ...
    lrwpanWaveformGenerator(psdu_bits, cfg);
packet = packet(:);

field_indices = lrwpanHRPFieldIndices(cfg);
sync_indices = field_indices.SYNC(1):field_indices.SYNC(2);
sync_sample_count = numel(sync_indices);
if mod(sync_sample_count, cfg.SamplesPerPulse) ~= 0
    error('run_test_preamble_matching_downsampling:InvalidSyncLength', ...
        'SYNC length is not divisible by SamplesPerPulse.');
end
sync_pulse_symbol_count = sync_sample_count/cfg.SamplesPerPulse;
sync_pulse_symbols = packet_pulse_symbols(1:sync_pulse_symbol_count);

% Recreate only the impulse insertion performed before the transmitter's
% pulse-shaping filter.  This is deliberately an unshaped preamble template.
preamble_template = zeros(sync_sample_count, 1);
preamble_template(1:cfg.SamplesPerPulse:end) = sync_pulse_symbols;
capture = [complex(zeros(empty_samples, 1)); packet];
true_start_sample = empty_samples + 1;

fprintf('\n=== UWB preamble-matching downsampling test ===\n');
fprintf('Sample rate             : %.1f MHz\n', fs/1e6);
fprintf('Preamble repetitions    : %d\n', preamble_repetitions);
fprintf('Preamble samples        : %d\n', numel(preamble_template));
fprintf('Matching template       : raw impulses (no pulse shaping)\n');
fprintf('Empty prefix samples    : %d (%.3f us)\n', ...
    empty_samples, empty_samples/fs*1e6);
fprintf('True packet start       : sample %d\n', true_start_sample);
fprintf('Benchmark repetitions   : %d\n\n', benchmark_repetitions);

%% Match from the beginning of the capture at each downsampling factor
n_factor = numel(preamble_downsampling);
detected_sample = zeros(n_factor, 1);
error_samples = zeros(n_factor, 1);
error_ns = zeros(n_factor, 1);
peak_score = zeros(n_factor, 1);
median_time_ms = zeros(n_factor, 1);
minimum_time_ms = zeros(n_factor, 1);
cir_delay_ns = cell(n_factor, 1);
cir_magnitude_db = cell(n_factor, 1);

for k = 1:n_factor
    factor = preamble_downsampling(k);

    % Warm up FFT/memory allocation before collecting timing results.
    localMatchPreamble(capture, preamble_template, factor);

    elapsed = zeros(benchmark_repetitions, 1);
    for trial = 1:benchmark_repetitions
        timer = tic;
        [start_sample, score] = ...
            localMatchPreamble(capture, preamble_template, factor);
        elapsed(trial) = toc(timer);
    end

    detected_sample(k) = start_sample;
    error_samples(k) = start_sample - true_start_sample;
    error_ns(k) = error_samples(k)/fs*1e9;
    peak_score(k) = score;
    median_time_ms(k) = median(elapsed)*1e3;
    minimum_time_ms(k) = min(elapsed)*1e3;

    % Extract the matched-filter CIR once outside the timing loop.
    [~, ~, cir, cir_lag_samples] = ...
        localMatchPreamble(capture, preamble_template, factor, ...
        round(cir_delay_range_ns*1e-9*fs));
    cir_delay_ns{k} = cir_lag_samples/fs*1e9;
    cir_magnitude_db{k} = 20*log10(abs(cir)/(max(abs(cir)) + eps) + eps);
end

speedup = median_time_ms(1)./median_time_ms;
results = table(preamble_downsampling(:), detected_sample, ...
    error_samples, error_ns, peak_score, median_time_ms, ...
    minimum_time_ms, speedup, 'VariableNames', ...
    {'downsampling', 'detected_sample', 'error_samples', 'error_ns', ...
     'peak_score', 'median_time_ms', 'minimum_time_ms', 'speedup'});

disp(results);

%% Visual comparison
if show_plot
    figure('Name', 'UWB preamble downsampling benchmark', 'Color', 'w');

    subplot(2, 1, 1);
    semilogx(preamble_downsampling, median_time_ms, '-o', ...
        'LineWidth', 1.5, 'MarkerFaceColor', [0.20 0.55 0.85]);
    grid on;
    xticks(preamble_downsampling);
    xlabel('Preamble downsampling factor');
    ylabel('Median search time (ms)');
    title('Packet-start search time');

    subplot(2, 1, 2);
    stem(preamble_downsampling, error_ns, 'filled', 'LineWidth', 1.2);
    grid on;
    set(gca, 'XScale', 'log');
    xticks(preamble_downsampling);
    xlabel('Preamble downsampling factor');
    ylabel('Start error (ns)');
    title('Detected packet-start error');

    figure('Name', 'UWB matched preamble CIR', 'Color', 'w');
    hold on;
    for k = 1:n_factor
        plot(cir_delay_ns{k}, cir_magnitude_db{k}, '-o', ...
            'LineWidth', 1.2, 'MarkerSize', 3, ...
            'DisplayName', sprintf('%dx', preamble_downsampling(k)));
    end
    hold off;
    grid on;
    xlim(cir_delay_range_ns);
    ylim([-80 5]);
    xlabel('Delay relative to detected packet start (ns)');
    ylabel('Normalized matched CIR magnitude (dB)');
    title('Full-preamble matched CIR');
    legend('Location', 'best');

    % One SYNC symbol is representative because the preamble consists of
    % repeated symbols.  Showing one symbol makes the retained pulse samples
    % visible even at the larger downsampling factors.
    samples_per_preamble_symbol = ...
        numel(preamble_template)/preamble_repetitions;
    if samples_per_preamble_symbol ~= round(samples_per_preamble_symbol)
        error('run_test_preamble_matching_downsampling:InvalidPreamble', ...
            'The generated preamble is not an integer number of symbols.');
    end
    samples_per_preamble_symbol = round(samples_per_preamble_symbol);
    first_preamble_symbol = ...
        preamble_template(1:samples_per_preamble_symbol);

    figure('Name', 'Downsampled UWB preamble waveforms', 'Color', 'w');
    layout = tiledlayout(ceil(n_factor/2), 2, ...
        'TileSpacing', 'compact', 'Padding', 'compact');
    for k = 1:n_factor
        factor = preamble_downsampling(k);
        sample_indices = 1:factor:samples_per_preamble_symbol;
        time_ns = (sample_indices-1)/fs*1e9;
        waveform_ds = first_preamble_symbol(sample_indices);

        nexttile;
        plot(time_ns, real(waveform_ds), '-o', ...
            'LineWidth', 1, 'MarkerSize', 2, ...
            'Color', [0.15 0.50 0.80]);
        grid on;
        xlim([0, (samples_per_preamble_symbol-1)/fs*1e9]);
        xlabel('Time (ns)');
        ylabel('Amplitude');
        title(sprintf('%dx downsampling, F_s = %.1f MHz', ...
            factor, fs/factor/1e6));
    end
    title(layout, ...
        'Unshaped UWB preamble template after downsampling');
end

%% Local matched-filter implementation
function [startSample, peakScore, cir, cirLagSamples] = ...
        localMatchPreamble(rx, template, factor, cirLagRange)
% Downsample the input and template with identical phase, then perform a
% normalized full-preamble matched filter over the capture from sample one.
if nargin < 4
    cirLagRange = [];
end
rx_ds = rx(1:factor:end);
template_ds = template(1:factor:end);
template_ds = template_ds/(norm(template_ds) + eps);
template_length = numel(template_ds);

if numel(rx_ds) < template_length
    error('run_test_preamble_matching_downsampling:CaptureTooShort', ...
        'The downsampled capture is shorter than the preamble template.');
end

matched = fftfilt(flipud(conj(template_ds)), rx_ds);
window_energy = sqrt(movsum(abs(rx_ds).^2, ...
    [template_length-1, 0]));

% Do not normalize numerical FFT residue in the exactly-zero prefix by
% EPS: doing so can turn round-off into a false high score.  Windows with
% negligible energy are known to contain no packet and receive score zero.
score = zeros(size(window_energy));
minimum_energy = max(window_energy)*1e-8;
active = window_energy > minimum_energy;
score(active) = abs(matched(active))./window_energy(active);

% Only indices containing a complete template are valid matched-filter ends.
valid_ends = template_length:numel(rx_ds);
[peakScore, local_peak] = max(score(valid_ends));
end_ds = valid_ends(local_peak);
start_ds = end_ds - template_length + 1;
startSample = 1 + (start_ds-1)*factor;

cir = complex(zeros(0, 1));
cirLagSamples = zeros(0, 1);
if nargout >= 3
    if isempty(cirLagRange)
        cirLagRange = [-256 256];
    end
    first_lag_ds = floor(cirLagRange(1)/factor);
    last_lag_ds = ceil(cirLagRange(2)/factor);
    requested_lags_ds = (first_lag_ds:last_lag_ds).';
    cir_ends = end_ds + requested_lags_ds;
    inside = cir_ends >= template_length & cir_ends <= numel(rx_ds);
    cir_ends = cir_ends(inside);
    requested_lags_ds = requested_lags_ds(inside);
    cir = matched(cir_ends);
    cirLagSamples = requested_lags_ds*factor;
end
end
