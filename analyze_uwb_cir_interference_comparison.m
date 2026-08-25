%% Analyze target CIR under synthetic SYNC and payload interference
%
% A target UWB signal contains target_sync_symbols SYNC symbols. N
% independently generated UWB packets contain interferer_sync_symbols SYNC
% symbols and legal 127-byte-or-shorter payloads. MATLAB's generator is used
% only for a legal 64-SYNC base packet; longer synthetic SYNC fields are
% assembled by repeating that base field.
% The target's complete SYNC interval is overlapped in turn by:
%   1. nothing (clean reference);
%   2. the sum of same-length sections from all interferers' repeated SYNC
%      fields;
%   3. the sum of same-length sections from all interferers' payload streams.
%      If the requested overlap is longer than one legal payload, each
%      stream is extended by concatenating independently generated payloads.
%
% The target CIR is estimated exactly from its target_sync_symbols SYNC
% repetitions: each repetition is correlated with the target spreading code
% and the complex CIR estimates are coherently averaged. All results use
% the clean peak as a common normalization reference. The script also reports mean power
% (mean(abs(x).^2)) for both complete packets and their SYNC/SFD/PHR/Payload
% fields, with dB values referenced to the target packet average power.

clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% User-editable parameters
target_code_index = 9;
num_interferers = 3;               % Set N here to simulate N simultaneous interferers.
interferer_code_indices = [15 16 21];      % Scalar repeats; or provide one code per interferer.
target_sync_symbols = 512;
interferer_sync_symbols = 512;
interferer_payload_bytes = 127;
generator_sync_symbols = 64;       % legal base field used by MATLAB generator
enable_sync_polarity_coding = false;
sync_polarity_pattern = [1 -1];      % target sensing SYNC code: +1,-1,...
mean_prf_mhz = 62.4;
data_rate_mbps = 6.81;
samples_per_pulse = 2;
interference_to_signal_db = 0;
payload_rng_seed = 20260819;
cir_pre_samples = 20;
cir_post_samples = 100;

% Fixed target multipath channel; delays are samples at 998.4 MHz.
target_path_delays = [0 8 23];
target_path_gains = [1.00, 0*exp(1j*0.55), 0*exp(-1j*1.10)];

if ~isscalar(num_interferers) || ~isfinite(num_interferers) || ...
        num_interferers < 1 || num_interferers ~= round(num_interferers)
    error('num_interferers must be a positive integer.');
end
interferer_code_indices = expandParameter(interferer_code_indices, ...
    num_interferers, 'interferer_code_indices');
if any(interferer_code_indices == target_code_index)
    error('The target and interferer preamble codes must be different.');
end
interferer_payload_seeds = payload_rng_seed + 1009*(0:num_interferers-1);

validateSyntheticSyncLength(target_sync_symbols, generator_sync_symbols, ...
    'target_sync_symbols');
validateSyntheticSyncLength(interferer_sync_symbols, generator_sync_symbols, ...
    'interferer_sync_symbols');
if interferer_payload_bytes < 1 || interferer_payload_bytes > 127 || ...
        interferer_payload_bytes ~= round(interferer_payload_bytes)
    error('interferer_payload_bytes must be an integer from 1 through 127.');
end

% Keep PreambleDuration=64 in both generator configurations. The requested
% target/interferer lengths are assembled below from these legal base fields.
cfg_target = makeConfig(target_code_index, generator_sync_symbols, ...
    mean_prf_mhz, data_rate_mbps, samples_per_pulse, 1);
idx_target_base = lrwpanHRPFieldIndices(cfg_target);

target_packet_base = lrwpanWaveformGenerator(zeros(8, 1), cfg_target);

% Build the requested target and interferer frames from legal 64-SYNC base
% packets. The returned index structures point into the extended packets.
[target_packet, target_sync, idx_target] = extendSyncField( ...
    target_packet_base, idx_target_base, target_sync_symbols, ...
    generator_sync_symbols);
symbol_length = numel(target_sync)/target_sync_symbols;
if symbol_length ~= round(symbol_length)
    error('The target SYNC field has a noninteger number of samples per symbol.');
end
symbol_length = round(symbol_length);
sync_polarity_sequence = makeSyncPolaritySequence(target_sync_symbols, ...
    sync_polarity_pattern, enable_sync_polarity_coding);
target_sync = applySyncPolarity(target_sync, symbol_length, ...
    sync_polarity_sequence);
% With coding disabled, sync_polarity_sequence is all ones, so this write
% preserves the original target packet exactly.
target_packet(idx_target.SYNC(1):idx_target.SYNC(2)) = target_sync;

interferer_configurations = cell(1, num_interferers);
interferer_base_indices = cell(1, num_interferers);
complete_interferer_packets = cell(1, num_interferers);
interferer_syncs = cell(1, num_interferers);
interferer_payloads = cell(1, num_interferers);
interferer_indices = cell(1, num_interferers);
for interferer_index = 1:num_interferers
    interferer_configurations{interferer_index} = makeConfig( ...
        interferer_code_indices(interferer_index), generator_sync_symbols, ...
        mean_prf_mhz, data_rate_mbps, samples_per_pulse, ...
        interferer_payload_bytes);
    interferer_base_indices{interferer_index} = ...
        lrwpanHRPFieldIndices(interferer_configurations{interferer_index});
    rng(interferer_payload_seeds(interferer_index), 'twister');
    interferer_payload_bits = double(randi( ...
        [0 1], 8*interferer_payload_bytes, 1));
    interferer_packet_base = lrwpanWaveformGenerator( ...
        interferer_payload_bits, interferer_configurations{interferer_index});
    [complete_interferer_packets{interferer_index}, ...
        interferer_syncs{interferer_index}, ...
        interferer_indices{interferer_index}] = extendSyncField( ...
        interferer_packet_base, interferer_base_indices{interferer_index}, ...
        interferer_sync_symbols, generator_sync_symbols);
    interferer_payloads{interferer_index} = extractField( ...
        complete_interferer_packets{interferer_index}, ...
        interferer_indices{interferer_index}.Payload);
end

% Keep the original scalar variables as aliases to the first interferer for
% plotting and backward-compatible result fields. The aggregate waveform is
% used for the simultaneous-interference experiment.
cfg_interferer = interferer_configurations{1};
idx_interferer_base = interferer_base_indices{1};
complete_interferer_packet = sumSignalCells(complete_interferer_packets);
interferer_code_index = interferer_code_indices(1);
interferer_sync = interferer_syncs{1};
idx_interferer = interferer_indices{1};
interferer_payload = interferer_payloads{1};

% The full target overlap may be longer than the legal generated payload.
% Extend only the synthetic payload-interference stream by concatenating
% legal payload chunks; PSDULength remains within MATLAB's 1..127 byte limit.
overlap_length = numel(target_sync);
interferer_sync_for_overlap = cell(1, num_interferers);
payload_for_overlap = cell(1, num_interferers);
for interferer_index = 1:num_interferers
    interferer_sync_for_overlap{interferer_index} = repeatToLength( ...
        interferer_syncs{interferer_index}, overlap_length);
    payload_for_overlap{interferer_index} = buildPayloadStream( ...
        interferer_configurations{interferer_index}, ...
        interferer_base_indices{interferer_index}, ...
        interferer_payloads{interferer_index}, overlap_length, ...
        interferer_payload_seeds(interferer_index));
end

interferer_sync_end = idx_interferer.SYNC(2);
interferer_sfd_range = idx_interferer.SFD;
interferer_phr_range = idx_interferer.PHR;
interferer_payload_range = idx_interferer.Payload;

target_field_signals = {extractField(target_packet, idx_target.SYNC), ...
    extractField(target_packet, idx_target.SFD), ...
    extractField(target_packet, idx_target.PHR), ...
    extractField(target_packet, idx_target.Payload)};
interferer_field_signals = cell(num_interferers, 4);
for interferer_index = 1:num_interferers
    packet = complete_interferer_packets{interferer_index};
    indices = interferer_indices{interferer_index};
    interferer_field_signals(interferer_index, :) = ...
        {extractField(packet, indices.SYNC), ...
        extractField(packet, indices.SFD), ...
        extractField(packet, indices.PHR), ...
        extractField(packet, indices.Payload)};
end
field_names = {'SYNC', 'SFD', 'PHR', 'Payload'};

% Average power is computed over the actual samples in each packet/field.
% The unscaled values describe the generated UWB packets. The two overlap
% values describe the effective interferers after the configured
% interference_to_signal_db scaling used by the CIR experiment.
target_packet_power = averagePower(target_packet);
target_field_power = cellfun(@averagePower, target_field_signals).';
interferer_packet_power = cellfun(@averagePower, ...
    complete_interferer_packets).';
interferer_field_power = cellfun(@averagePower, ...
    interferer_field_signals);

% Equal RMS power is imposed over the exact interval shared with target
% SYNC for each interferer. Thus, interference_to_signal_db is the ISR of
% each individual interferer; the aggregate ISR increases with N unless
% the user reduces this value accordingly.
sync_interference = complex(zeros(overlap_length, 1));
payload_interference = complex(zeros(overlap_length, 1));
individual_sync_overlap = cell(1, num_interferers);
individual_payload_overlap = cell(1, num_interferers);
for interferer_index = 1:num_interferers
    amplitude_ratio = 10^(interference_to_signal_db/20);
    individual_sync_overlap{interferer_index} = matchRms( ...
        interferer_sync_for_overlap{interferer_index}, target_sync) * ...
        amplitude_ratio;
    individual_payload_overlap{interferer_index} = matchRms( ...
        payload_for_overlap{interferer_index}, target_sync) * ...
        amplitude_ratio;
    sync_interference = sync_interference + ...
        individual_sync_overlap{interferer_index};
    payload_interference = payload_interference + ...
        individual_payload_overlap{interferer_index};
end
individual_sync_overlap_power = cellfun(@averagePower, ...
    individual_sync_overlap).';
individual_payload_overlap_power = cellfun(@averagePower, ...
    individual_payload_overlap).';
sync_overlap_power = averagePower(sync_interference);
payload_overlap_power = averagePower(payload_interference);
target_sync_power = averagePower(target_sync);
aggregate_sync_to_target_db = 10*log10(sync_overlap_power / ...
    (target_sync_power + eps));
aggregate_payload_to_target_db = 10*log10(payload_overlap_power / ...
    (target_sync_power + eps));

target_channel = complex(zeros(max(target_path_delays)+1, 1));
target_channel(target_path_delays+1) = target_path_gains;
target_received = conv(target_sync, target_channel);

guard = cir_pre_samples + cir_post_samples + numel(target_channel) + 8;
target_start = guard + 1;
buffer_length = target_start + numel(target_received) + guard;
target_component = addAt(complex(zeros(buffer_length, 1)), ...
    target_received, target_start);
sync_component = addAt(complex(zeros(buffer_length, 1)), ...
    sync_interference, target_start);
payload_component = addAt(complex(zeros(buffer_length, 1)), ...
    payload_interference, target_start);
rx_clean = target_component;
rx_sync_overlap = target_component + sync_component;
rx_payload_overlap = target_component + payload_component;

% Use the same sparse target spreading-code matched filter as the decoder.
target_code = lrwpan.internal.HRPCodes(target_code_index);
spread_code = zeros(numel(target_code)*cfg_target.PreambleSpreadingFactor, 1);
spread_code(1:cfg_target.PreambleSpreadingFactor:end) = target_code(:);
sampled_code = zeros(numel(spread_code)*samples_per_pulse, 1);
sampled_code(1:samples_per_pulse:end) = spread_code;
code_energy = real(sampled_code'*sampled_code);
if numel(sampled_code) ~= symbol_length
    error('Generated SYNC symbol and sampled spreading code lengths differ.');
end

offsets = (-cir_pre_samples:cir_post_samples-1).';
[cir_clean, individual_clean] = estimateRepeatedCir(rx_clean, ...
    target_start, target_sync_symbols, symbol_length, offsets, ...
    sampled_code, code_energy, sync_polarity_sequence);
[cir_sync_overlap, individual_sync] = estimateRepeatedCir( ...
    rx_sync_overlap, target_start, target_sync_symbols, symbol_length, ...
    offsets, sampled_code, code_energy, sync_polarity_sequence);
[cir_payload_overlap, individual_payload] = estimateRepeatedCir( ...
    rx_payload_overlap, target_start, target_sync_symbols, symbol_length, ...
    offsets, sampled_code, code_energy, sync_polarity_sequence);
delay_ns = offsets/cfg_target.SampleRate*1e9;

clean_peak = max(abs(cir_clean));
clean_magnitude = abs(cir_clean)/(clean_peak+eps);
sync_magnitude = abs(cir_sync_overlap)/(clean_peak+eps);
payload_magnitude = abs(cir_payload_overlap)/(clean_peak+eps);
sync_error = norm(cir_sync_overlap-cir_clean)/(norm(cir_clean)+eps);
payload_error = norm(cir_payload_overlap-cir_clean)/(norm(cir_clean)+eps);

fprintf('\n========== %d-SYNC CIR overlap comparison ==========\n', ...
    target_sync_symbols);
fprintf('Target signal                 : Code %d, %d SYNC\n', ...
    target_code_index, target_sync_symbols);
fprintf('Interferer packets            : N=%d, codes [%s], %d SYNC, %d-byte payload\n', ...
    num_interferers, strjoin(string(interferer_code_indices), ' '), ...
    interferer_sync_symbols, interferer_payload_bytes);
fprintf('Sample rate                   : %.3f MHz\n', cfg_target.SampleRate/1e6);
fprintf('Complete overlap duration     : %.3f us (%d samples)\n', ...
    overlap_length/cfg_target.SampleRate*1e6, overlap_length);
fprintf('Interference-to-signal ratio  : %+.1f dB\n', ...
    interference_to_signal_db);
fprintf('Aggregate SYNC ISR             : %+.2f dB\n', ...
    aggregate_sync_to_target_db);
fprintf('Aggregate payload ISR          : %+.2f dB\n', ...
    aggregate_payload_to_target_db);
fprintf('CIR coherent repetitions      : %d\n', target_sync_symbols);
fprintf('SYNC polarity coding          : %s\n', onOff(enable_sync_polarity_coding));
fprintf('SYNC polarity pattern         : [%s]\n', ...
    strjoin(string(sync_polarity_pattern), ' '));
fprintf('SYNC interference error       : %.2f %%\n', 100*sync_error);
fprintf('Payload interference error    : %.2f %%\n\n', 100*payload_error);

%% Average-power comparison for complete packets and individual fields
power_db_reference = target_packet_power + eps;
packet_labels = [{'Target packet'}, arrayfun(@(k) ...
    sprintf('Interferer %d packet', k), 1:num_interferers, ...
    'UniformOutput', false)];
packet_power = [target_packet_power; interferer_packet_power];
packet_power_db = 10*log10(packet_power/power_db_reference);
mean_interferer_field_power = mean(interferer_field_power, 1).';
field_power_db = 10*log10([target_field_power, ...
    mean_interferer_field_power] / power_db_reference);
interferer_field_power_db = 10*log10(interferer_field_power / ...
    power_db_reference);
overlap_power = [sync_overlap_power; payload_overlap_power];
overlap_power_db = 10*log10(overlap_power/power_db_reference);

fprintf('========== UWB average-power comparison ==========%s', newline);
fprintf('Reference                     : target complete packet = %.6g (0 dB)\n', ...
    target_packet_power);
fprintf('%-28s %12s %12s\n', 'Signal', 'mean(|x|^2)', 'relative dB');
for packet_index = 1:numel(packet_power)
    fprintf('%-28s %12.6g %12.3f\n', packet_labels{packet_index}, ...
        packet_power(packet_index), packet_power_db(packet_index));
end
for field_index = 1:numel(field_names)
    fprintf('%-28s %12.6g %12.3f\n', ...
        ['Target ' field_names{field_index}], ...
        target_field_power(field_index), field_power_db(field_index, 1));
    for interferer_index = 1:num_interferers
        fprintf('%-28s %12.6g %12.3f\n', ...
            sprintf('Interferer %d %s', interferer_index, ...
            field_names{field_index}), ...
            interferer_field_power(interferer_index, field_index), ...
            interferer_field_power_db(interferer_index, field_index));
    end
end
fprintf('%-28s %12.6g %12.3f\n', 'Effective interferer SYNC overlap', ...
    sync_overlap_power, overlap_power_db(1));
fprintf('%-28s %12.6g %12.3f\n\n', ...
    'Effective interferer Payload overlap', payload_overlap_power, ...
    overlap_power_db(2));

figure('Color', 'w', 'Name', 'UWB average-power comparison', ...
    'Position', [120 120 1200 500]);
tiledlayout(1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
nexttile;
bar(packet_power_db, 0.55);
grid on;
set(gca, 'XTick', 1:numel(packet_labels), 'XTickLabel', ...
    packet_labels);
yline(0, 'k--', 'Target packet reference');
ylabel('Average power relative to target packet (dB)');
title('Complete-packet average power');
xtickangle(20);

nexttile;
bar(field_power_db, 'grouped');
grid on;
set(gca, 'XTick', 1:numel(field_names), ...
    'XTickLabel', field_names);
yline(0, 'k--', 'Target packet reference');
ylabel('Average power relative to target packet (dB)');
legend('Target field', 'Mean interferer field', 'Location', 'best');
title(sprintf('Field average power (N=%d)', num_interferers));
xtickangle(20);
sgtitle('UWB packet and field average-power comparison');

%% CIR comparison: all panels share the clean-CIR amplitude scale
figure('Color', 'w', 'Name', sprintf('%d-SYNC CIR overlap comparison', ...
    target_sync_symbols), ...
    'Position', [70 80 1400 440]);
tiledlayout(1, 3, 'TileSpacing', 'compact', 'Padding', 'compact');
plotCirPanel(delay_ns, clean_magnitude, ...
    sprintf('Clean %d-SYNC CIR', target_sync_symbols), ...
    [0.10 0.45 0.80]);
plotCirPanel(delay_ns, sync_magnitude, ...
    sprintf('%d SYNC overlapped by %d interferer SYNC signals', ...
    target_sync_symbols, num_interferers), ...
    [0.85 0.30 0.15]);
plotCirPanel(delay_ns, payload_magnitude, ...
    sprintf('%d SYNC overlapped by payload', target_sync_symbols), ...
    [0.20 0.60 0.35]);
sgtitle(sprintf(['Target Code %d, %d-repetition coherent CIR | ', ...
    'interferer ISR %+.1f dB'], target_code_index, ...
    target_sync_symbols, interference_to_signal_db));

%% Raw-signal overlap over the complete target SYNC interval
raw_indices = target_start + (0:overlap_length-1);
raw_time_us = (0:overlap_length-1)'/cfg_target.SampleRate*1e6;
raw_scale = max(abs([target_component(raw_indices); ...
    sync_component(raw_indices); payload_component(raw_indices)]));

figure('Color', 'w', 'Name', sprintf('%d-SYNC raw waveform overlap', ...
    target_sync_symbols), ...
    'Position', [70 560 1400 440]);
tiledlayout(1, 3, 'TileSpacing', 'compact', 'Padding', 'compact');
plotWaveformPanel(raw_time_us, target_component(raw_indices), ...
    zeros(overlap_length, 1), rx_clean(raw_indices), raw_scale, ...
    sprintf('Clean target: %d SYNC', target_sync_symbols), ...
    'No interference');
plotWaveformPanel(raw_time_us, target_component(raw_indices), ...
    sync_component(raw_indices), rx_sync_overlap(raw_indices), raw_scale, ...
    sprintf('Target %d SYNC + %d interferer SYNC signals', ...
    target_sync_symbols, num_interferers), ...
    sprintf('Sum of %d interferers: SYNC', num_interferers));
plotWaveformPanel(raw_time_us, target_component(raw_indices), ...
    payload_component(raw_indices), rx_payload_overlap(raw_indices), ...
    raw_scale, sprintf('Target %d SYNC + %d interferer payloads', ...
    target_sync_symbols, num_interferers), ...
    sprintf('Sum of %d interferers: payload', num_interferers));
sgtitle(sprintf('Complete %.3f us waveform overlap | common amplitude scale', ...
    overlap_length/cfg_target.SampleRate*1e6));

%% Complete target and interferer transmit waveforms, plotted separately
target_time_us = (0:numel(target_packet)-1)'/cfg_target.SampleRate*1e6;
interferer_time_us = (0:numel(complete_interferer_packet)-1)'/ ...
    cfg_interferer.SampleRate*1e6;

figure('Color', 'w', 'Name', 'Complete UWB transmit waveforms', ...
    'Position', [90 80 1380 760]);
tiledlayout(2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
nexttile;
plotCompleteWaveform(target_time_us, target_packet, cfg_target.SampleRate, ...
    idx_target.SYNC, idx_target.SFD, idx_target.PHR, idx_target.Payload, ...
    sprintf('Target UWB signal: Code %d, %d SYNC', ...
    target_code_index, target_sync_symbols));
nexttile;
plotCompleteWaveform(interferer_time_us, complete_interferer_packet, ...
    cfg_interferer.SampleRate, [1 interferer_sync_end], ...
    interferer_sfd_range, interferer_phr_range, interferer_payload_range, ...
    sprintf('Aggregate of %d interference UWB signals: %d SYNC, %d bytes', ...
    num_interferers, interferer_sync_symbols, interferer_payload_bytes));
sgtitle('Complete time-domain waveforms plotted separately');

cir_interference_result = struct( ...
    'target_configuration', cfg_target, ...
    'interferer_configuration', cfg_interferer, ...
    'num_interferers', num_interferers, ...
    'interferer_code_indices', interferer_code_indices, ...
    'interferer_configurations', {interferer_configurations}, ...
    'target_sync_symbols', target_sync_symbols, ...
    'interferer_sync_symbols', interferer_sync_symbols, ...
    'sync_polarity_coding_enabled', enable_sync_polarity_coding, ...
    'sync_polarity_pattern', sync_polarity_pattern, ...
    'sync_polarity_sequence', sync_polarity_sequence, ...
    'target_sync_assembly', sprintf('%d-SYNC base repeated %d times', ...
        generator_sync_symbols, target_sync_symbols/generator_sync_symbols), ...
    'interferer_sync_assembly', sprintf('%d-SYNC base repeated %d times', ...
        generator_sync_symbols, interferer_sync_symbols/generator_sync_symbols), ...
    'interferer_payload_seeds', interferer_payload_seeds, ...
    'interference_to_signal_db', interference_to_signal_db, ...
    'delay_ns', delay_ns, ...
    'clean_cir', cir_clean, ...
    'sync_overlap_cir', cir_sync_overlap, ...
    'payload_overlap_cir', cir_payload_overlap, ...
    'individual_clean_cir', individual_clean, ...
    'individual_sync_overlap_cir', individual_sync, ...
    'individual_payload_overlap_cir', individual_payload, ...
    'sync_overlap_relative_error', sync_error, ...
    'payload_overlap_relative_error', payload_error, ...
    'average_power', struct( ...
        'packet_labels', {packet_labels}, ...
        'packet_power', packet_power, ...
        'packet_power_db_relative_to_target_packet', packet_power_db, ...
        'field_names', {field_names}, ...
        'target_field_power', target_field_power, ...
        'interferer_field_power', interferer_field_power, ...
        'interferer_field_power_db_relative_to_target_packet', ...
        interferer_field_power_db, ...
        'mean_interferer_field_power', mean_interferer_field_power, ...
        'field_power_db_relative_to_target_packet', field_power_db, ...
        'overlap_labels', {{'SYNC overlap', 'Payload overlap'}}, ...
        'overlap_power', overlap_power, ...
        'overlap_power_db_relative_to_target_packet', overlap_power_db, ...
        'individual_sync_overlap_power', individual_sync_overlap_power, ...
        'individual_payload_overlap_power', individual_payload_overlap_power, ...
        'aggregate_sync_to_target_db', aggregate_sync_to_target_db, ...
        'aggregate_payload_to_target_db', aggregate_payload_to_target_db), ...
    'raw_time_us', raw_time_us, ...
    'raw_target_component', target_component(raw_indices), ...
    'raw_sync_component', sync_component(raw_indices), ...
    'raw_payload_component', payload_component(raw_indices), ...
    'raw_sync_overlap', rx_sync_overlap(raw_indices), ...
    'raw_payload_overlap', rx_payload_overlap(raw_indices), ...
    'complete_target_time_us', target_time_us, ...
    'complete_target_packet', target_packet, ...
    'complete_interferer_time_us', interferer_time_us, ...
    'complete_interferer_packet', complete_interferer_packet, ...
    'complete_interferer_packets', {complete_interferer_packets}, ...
    'target_path_delays_samples', target_path_delays, ...
    'target_path_gains', target_path_gains);
assignin('base', 'cir_interference_result', cir_interference_result);

%% Local functions
function cfg = makeConfig(codeIndex, syncSymbols, meanPrf, dataRate, ...
        samplesPerPulse, payloadBytes)
cfg = lrwpanHRPConfig(Mode='802.15.4a', MeanPRF=meanPrf, ...
    DataRate=dataRate, PreambleDuration=syncSymbols, ...
    CodeIndex=codeIndex, SamplesPerPulse=samplesPerPulse, ...
    PSDULength=payloadBytes);
end

function field = extractField(packet, inclusiveIndices)
field = packet(inclusiveIndices(1):inclusiveIndices(2));
field = field(:);
end

function values = expandParameter(value, count, name)
%EXPANDPARAMETER Expand a scalar setting or validate an N-element setting.
if ~isnumeric(value) || isempty(value) || any(~isfinite(value(:)))
    error('%s must contain finite numeric values.', name);
end
if isscalar(value)
    values = repmat(value, 1, count);
elseif numel(value) == count
    values = reshape(value, 1, count);
else
    error('%s must be scalar or contain exactly %d values.', name, count);
end
end

function total = sumSignalCells(signals)
%SUMSIGNALCELLS Sum signals with a common start and zero-pad if needed.
if isempty(signals)
    error('At least one signal is required.');
end
lengths = cellfun(@numel, signals);
total = complex(zeros(max(lengths), 1));
for k = 1:numel(signals)
    signal = signals{k}(:);
    total(1:numel(signal)) = total(1:numel(signal)) + signal;
end
end

function [packet, sync, fieldIndices] = extendSyncField( ...
        basePacket, baseIndices, requestedSyncSymbols, baseSyncSymbols)
%EXTENDSYNCFIELD Repeat a legal base SYNC field and shift later fields.
baseSync = extractField(basePacket, baseIndices.SYNC);
repetitions = requestedSyncSymbols/baseSyncSymbols;
prefix = basePacket(1:baseIndices.SYNC(1)-1);
suffix = basePacket(baseIndices.SYNC(2)+1:end);
sync = repmat(baseSync, repetitions, 1);
packet = [prefix; sync; suffix];

fieldIndices = baseIndices;
fieldIndices.SYNC = [baseIndices.SYNC(1), ...
    baseIndices.SYNC(1) + numel(sync) - 1];
syncLengthShift = numel(sync) - numel(baseSync);
laterFields = {'SFD', 'PHR', 'Payload'};
for k = 1:numel(laterFields)
    name = laterFields{k};
    fieldIndices.(name) = baseIndices.(name) + syncLengthShift;
end
end

function validateSyntheticSyncLength(value, baseValue, name)
if ~isscalar(value) || ~isfinite(value) || value < baseValue || ...
        value ~= round(value) || mod(value, baseValue) ~= 0
    error('%s must be a positive integer multiple of %d for synthetic extension.', ...
        name, baseValue);
end
end

function output = repeatToLength(signal, requestedLength)
%REPEATTOLENGTH Extend a periodic field waveform without changing PHY config.
signal = signal(:);
if isempty(signal) || requestedLength < 1
    error('repeatToLength requires a nonempty signal and positive length.');
end
output = repmat(signal, ceil(requestedLength/numel(signal)), 1);
output = output(1:requestedLength);
end

function output = buildPayloadStream(cfg, baseIndices, firstPayload, ...
        requestedLength, seed)
%BUILDPAYLOADSTREAM Concatenate legal, independently generated payload fields.
output = firstPayload(:);
if numel(output) >= requestedLength
    output = output(1:requestedLength);
    return
end

savedState = rng;
rng(double(seed) + 1, 'twister');
while numel(output) < requestedLength
    bits = double(randi([0 1], 8*cfg.PSDULength, 1));
    packet = lrwpanWaveformGenerator(bits, cfg);
    output = [output; extractField(packet, baseIndices.Payload)]; %#ok<AGROW>
end
rng(savedState);
output = output(1:requestedLength);
end

function scaled = matchRms(signal, reference)
scaled = signal(:)*sqrt(sum(abs(reference).^2)/(sum(abs(signal).^2)+eps));
end

function power = averagePower(signal)
%AVERAGEPOWER Mean complex-sample power, mean(abs(signal).^2).
signal = signal(:);
if isempty(signal)
    power = NaN;
else
    power = mean(abs(signal).^2);
end
end

function sequence = makeSyncPolaritySequence(repetitions, pattern, enabled)
%MAKESYNCPOLARITYSEQUENCE Build the per-SYNC coding/de-rotation sequence.
if ~enabled
    sequence = ones(repetitions, 1);
    return
end

pattern = pattern(:);
if isempty(pattern) || any(~isfinite(pattern)) || ...
        any(abs(abs(pattern) - 1) > 1e-12)
    error('sync_polarity_pattern must contain only +1 and -1 values.');
end
sequence = repmat(pattern, ceil(repetitions/numel(pattern)), 1);
sequence = sequence(1:repetitions);
end

function encoded = applySyncPolarity(sync, samplesPerSymbol, sequence)
%APPLYSYNCPOLARITY Apply one polarity value to every SYNC symbol.
sync = sync(:);
sequence = sequence(:);
if numel(sync) ~= numel(sequence)*samplesPerSymbol
    error('SYNC length does not match the polarity sequence and symbol length.');
end
encoded = sync .* kron(sequence, ones(samplesPerSymbol, 1));
end

function label = onOff(enabled)
if enabled
    label = 'enabled';
else
    label = 'disabled';
end
end

function buffer = addAt(buffer, signal, firstIndex)
indices = firstIndex + (0:numel(signal)-1);
if indices(1) < 1 || indices(end) > numel(buffer)
    error('Signal insertion exceeds the simulation buffer.');
end
buffer(indices) = buffer(indices) + signal(:);
end

function [averageCir, individualCir] = estimateRepeatedCir(rx, firstStart, ...
        repetitions, period, offsets, code, codeEnergy, syncPolarity)
if nargin < 8 || isempty(syncPolarity)
    syncPolarity = ones(repetitions, 1);
end
syncPolarity = syncPolarity(:);
if numel(syncPolarity) ~= repetitions
    error('The SYNC polarity sequence must match the number of repetitions.');
end

individualCir = complex(zeros(numel(offsets), repetitions));
for repetition = 0:repetitions-1
    symbol_start = firstStart + repetition*period;
    segment_start = symbol_start + offsets(1);
    segment_length = numel(code) + numel(offsets) - 1;
    sample_indices = (segment_start:segment_start+segment_length-1).';
    symbol_indices = floor((sample_indices-firstStart)/period) + 1;
    segment_polarity = ones(segment_length, 1);
    inside_sync = symbol_indices >= 1 & symbol_indices <= repetitions;
    segment_polarity(inside_sync) = syncPolarity(symbol_indices(inside_sync));
    % De-rotate each sample before correlation. This also handles the
    % samples around a symbol boundary with their own polarity.
    segment = rx(sample_indices).*segment_polarity;
    individualCir(:, repetition+1) = conv( ...
        segment, flipud(conj(code)), 'valid')/(codeEnergy+eps);
end
averageCir = mean(individualCir, 2);
end

function plotCirPanel(delayNs, magnitude, panelTitle, color)
nexttile;
stem(delayNs, magnitude, 'filled', 'Color', color, 'MarkerSize', 3);
hold on;
xline(0, 'k--', 'Nominal path', 'HandleVisibility', 'off');
grid on;
xlabel('Relative delay (ns)');
ylabel('|CIR| / clean peak');
title(panelTitle);
ylim([0 max(1.1, 1.08*max(magnitude))]);
end

function plotWaveformPanel(timeUs, target, interference, received, ...
        commonScale, panelTitle, interferenceLabel)
nexttile;
plot(timeUs, real(target)/(commonScale+eps), ...
    'Color', [0.10 0.45 0.80], 'LineWidth', 0.55);
hold on;
plot(timeUs, real(interference)/(commonScale+eps), ...
    'Color', [0.85 0.30 0.15], 'LineWidth', 0.55);
plot(timeUs, real(received)/(commonScale+eps), 'k-', 'LineWidth', 0.65);
grid on;
xlabel('Time from target SYNC start (\mus)');
ylabel('Normalized real amplitude');
title(panelTitle);
ylim([-1.1 1.1]);
legend('Target component', interferenceLabel, 'Received sum', ...
    'Location', 'best');
end

function plotCompleteWaveform(timeUs, waveform, fs, syncRange, sfdRange, ...
        phrRange, payloadRange, panelTitle)
waveform = waveform(:);
scale = max(abs(waveform)) + eps;
plot(timeUs, real(waveform)/scale, 'k-', 'LineWidth', 0.45, ...
    'HandleVisibility', 'off');
hold on;
field_ranges = [syncRange; sfdRange; phrRange; payloadRange];
field_names = {'SYNC', 'SFD', 'PHR', 'Payload'};
field_colors = [0.78 0.88 1.00; 1.00 0.86 0.68; ...
    0.86 0.78 1.00; 0.78 0.94 0.82];
yl = [-1.1 1.1];
for field_index = 1:size(field_ranges, 1)
    start_us = (field_ranges(field_index, 1)-1)/fs*1e6;
    end_us = (field_ranges(field_index, 2)-1)/fs*1e6;
    patch([start_us end_us end_us start_us], ...
        [yl(1) yl(1) yl(2) yl(2)], field_colors(field_index, :), ...
        'FaceAlpha', 0.18, 'EdgeColor', 'none', ...
        'DisplayName', field_names{field_index});
end
% Draw the waveform again so sparse UWB pulses remain above field shading.
plot(timeUs, real(waveform)/scale, 'k-', 'LineWidth', 0.45, ...
    'DisplayName', 'Real waveform');
grid on;
xlim([timeUs(1) timeUs(end)]);
ylim(yl);
xlabel('Time from packet start (us)');
ylabel('Normalized real amplitude');
title(panelTitle);
legend('Location', 'eastoutside');
end
