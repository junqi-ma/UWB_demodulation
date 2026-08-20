%% Analyze normalized correlation between an HRP UWB preamble and payload
%
% This script answers a detector-oriented question: when one complete SYNC
% symbol is used as the preamble template, how large a false correlation
% peak can occur while the template slides through random payload data?
%
% The simulation uses the same lrwpanHRPConfig/lrwpanWaveformGenerator
% waveform source as the decoder.  Correlation is normalized by both the
% template energy and the energy of each payload window, so its magnitude
% is between zero and one and is independent of waveform amplitude.

clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);

%% User-editable simulation parameters
code_index = 9;
mean_prf_mhz = 62.4;
data_rate_mbps = 6.81;
preamble_symbols = 64;
samples_per_pulse = 2;
payload_bytes = 127;
number_of_frames = 100;
payload_rng_seed = 20260819;

if payload_bytes < 1 || payload_bytes > 127
    error('Payload length must be an integer from 1 through 127 bytes.');
end
if number_of_frames < 1 || number_of_frames ~= round(number_of_frames)
    error('number_of_frames must be a positive integer.');
end

cfg = lrwpanHRPConfig(Mode='802.15.4a', MeanPRF=mean_prf_mhz, ...
    DataRate=data_rate_mbps, PreambleDuration=preamble_symbols, ...
    CodeIndex=code_index, SamplesPerPulse=samples_per_pulse, ...
    PSDULength=payload_bytes);
field_indices = lrwpanHRPFieldIndices(cfg);

% lrwpanHRPFieldIndices returns inclusive [start, end] pairs.
sync_sample_count = field_indices.SYNC(2) - field_indices.SYNC(1) + 1;
samples_per_sync_symbol = sync_sample_count/preamble_symbols;
if samples_per_sync_symbol ~= round(samples_per_sync_symbol)
    error('The SYNC field does not contain an integer number of symbols.');
end
samples_per_sync_symbol = round(samples_per_sync_symbol);

% A zero packet is sufficient to obtain the deterministic SYNC template.
reference_packet = lrwpanWaveformGenerator(zeros(8*payload_bytes, 1), cfg);
preamble_template = reference_packet( ...
    field_indices.SYNC(1):field_indices.SYNC(1)+samples_per_sync_symbol-1);
preamble_template = preamble_template(:);
template_energy = sum(abs(preamble_template).^2);
if template_energy <= 0
    error('The generated preamble template has zero energy.');
end

rng(payload_rng_seed, 'twister');
maximum_correlation = zeros(number_of_frames, 1);
maximum_payload_offset = zeros(number_of_frames, 1);
all_correlation = cell(number_of_frames, 1);
worst_payload_bits = [];
worst_correlation = [];

for frame_index = 1:number_of_frames
    payload_bits = double(randi([0, 1], 8*payload_bytes, 1));
    packet = lrwpanWaveformGenerator(payload_bits, cfg);
    payload = packet(field_indices.Payload(1):field_indices.Payload(2));
    payload = payload(:);

    correlation = slidingNormalizedCorrelation( ...
        payload, preamble_template, template_energy);
    all_correlation{frame_index} = correlation;
    [maximum_correlation(frame_index), maximum_payload_offset(frame_index)] = ...
        max(correlation);

    if frame_index == 1 || maximum_correlation(frame_index) >= ...
            max(maximum_correlation(1:frame_index-1))
        worst_payload_bits = payload_bits;
        worst_correlation = correlation;
    end
end

correlation_samples = vertcat(all_correlation{:});
[overall_maximum, worst_frame_index] = max(maximum_correlation);
percentiles = prctile(maximum_correlation, [50 90 95 99]);

fprintf('\n========== Preamble versus payload correlation ==========\n');
fprintf('Code index                 : %d\n', code_index);
fprintf('Sample rate                : %.3f MHz\n', cfg.SampleRate/1e6);
fprintf('Preamble template          : 1 SYNC symbol (%d samples)\n', ...
    samples_per_sync_symbol);
fprintf('Payload                    : %d bytes per frame\n', payload_bytes);
fprintf('Monte Carlo frames         : %d (seed %d)\n', ...
    number_of_frames, payload_rng_seed);
fprintf('Payload windows evaluated  : %d\n', numel(correlation_samples));
fprintf('Median frame maximum       : %.6f\n', percentiles(1));
fprintf('90/95/99%% frame maximum    : %.6f / %.6f / %.6f\n', ...
    percentiles(2), percentiles(3), percentiles(4));
fprintf('Overall payload maximum    : %.6f (frame %d, offset %d)\n', ...
    overall_maximum, worst_frame_index, ...
    maximum_payload_offset(worst_frame_index)-1);
fprintf('Ideal preamble self-peak   : 1.000000\n\n');

%% Visualization
figure('Color', 'w', 'Name', 'Preamble versus payload correlation');
tiledlayout(2, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

nexttile;
plot((0:numel(worst_correlation)-1)/cfg.SampleRate*1e6, ...
    worst_correlation, 'Color', [0.10 0.45 0.80]);
yline(overall_maximum, 'r--', sprintf('maximum %.4f', overall_maximum));
grid on;
xlabel('Payload template offset (\mus)');
ylabel('Normalized |correlation|');
title(sprintf('Worst frame (%d)', worst_frame_index));
ylim([0, max(0.1, 1.08*overall_maximum)]);

nexttile;
histogram(correlation_samples, 80, 'Normalization', 'probability', ...
    'FaceColor', [0.20 0.60 0.45], 'EdgeColor', 'none');
grid on;
xlabel('Normalized |correlation|');
ylabel('Probability per bin');
title('All payload windows');

nexttile;
plot(1:number_of_frames, maximum_correlation, '.-', ...
    'Color', [0.55 0.25 0.70]);
yline(percentiles(3), 'k--', sprintf('95%% %.4f', percentiles(3)));
grid on;
xlabel('Random payload frame');
ylabel('Maximum correlation');
title('Maximum false peak in each frame');

nexttile;
sorted_maximum = sort(maximum_correlation);
exceedance_probability = (number_of_frames:-1:1)'/number_of_frames;
semilogy(sorted_maximum, exceedance_probability, 'LineWidth', 1.3, ...
    'Color', [0.85 0.35 0.15]);
grid on;
xlabel('Correlation threshold');
ylabel('P(frame maximum \geq threshold)');
title('Empirical false-alarm exceedance');

sgtitle(sprintf(['HRP UWB preamble/payload correlation | code %d | ', ...
    '%d-byte payload | %d frames'], ...
    code_index, payload_bytes, number_of_frames));

simulation_result = struct( ...
    'configuration', cfg, ...
    'rng_seed', payload_rng_seed, ...
    'samples_per_sync_symbol', samples_per_sync_symbol, ...
    'maximum_correlation_per_frame', maximum_correlation, ...
    'maximum_payload_offset_per_frame', maximum_payload_offset-1, ...
    'frame_maximum_percentiles', percentiles, ...
    'overall_maximum', overall_maximum, ...
    'worst_frame_index', worst_frame_index, ...
    'worst_payload_bits', worst_payload_bits, ...
    'worst_frame_correlation', worst_correlation);
assignin('base', 'preamble_payload_correlation_result', simulation_result);

%% Local functions
function score = slidingNormalizedCorrelation(signal, template, templateEnergy)
%SLIDINGNORMALIZEDCORRELATION Normalized complex matched-filter magnitude.
signal = signal(:);
template = template(:);
templateLength = numel(template);
if numel(signal) < templateLength
    error('Payload is shorter than one preamble-symbol template.');
end

numerator = conv(signal, conj(flipud(template)), 'valid');
windowEnergy = conv(abs(signal).^2, ones(templateLength, 1), 'valid');
denominator = sqrt(templateEnergy*windowEnergy);
score = abs(numerator)./max(denominator, eps(class(denominator)));
score(~isfinite(score)) = 0;
end
