%% Analyze a 64-SYNC CIR under 128-SYNC and payload interference
%
% A target UWB signal contains 64 SYNC symbols. A second, independently
% generated UWB packet contains 128 SYNC symbols and a 127-byte payload.
% The target's complete 64-SYNC interval is overlapped in turn by:
%   1. nothing (clean reference);
%   2. the first 64 symbols of the 128-SYNC interferer;
%   3. an equally long section from the interferer's payload.
%
% The target CIR is estimated exactly from its 64 SYNC repetitions: each
% repetition is correlated with the target spreading code and the complex
% CIR estimates are coherently averaged. All results use the clean peak as
% a common normalization reference.

clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% User-editable parameters
target_code_index = 9;
interferer_code_index = 15;
target_sync_symbols = 64;
interferer_sync_symbols = 128;
interferer_payload_bytes = 127;
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

if target_code_index == interferer_code_index
    error('The target and interferer preamble codes must be different.');
end

cfg_target = makeConfig(target_code_index, target_sync_symbols, ...
    mean_prf_mhz, data_rate_mbps, samples_per_pulse, 1);
% MATLAB's 802.15.4a generator accepts 64 but not 128 for
% PreambleDuration. Generate a standard 64-SYNC/127-byte packet and repeat
% its deterministic SYNC field once to form the requested 128-SYNC field.
interferer_generator_sync_symbols = 64;
cfg_interferer = makeConfig(interferer_code_index, ...
    interferer_generator_sync_symbols, mean_prf_mhz, data_rate_mbps, ...
    samples_per_pulse, interferer_payload_bytes);
idx_target = lrwpanHRPFieldIndices(cfg_target);
idx_interferer = lrwpanHRPFieldIndices(cfg_interferer);

target_packet = lrwpanWaveformGenerator(zeros(8, 1), cfg_target);
rng(payload_rng_seed, 'twister');
interferer_payload_bits = double(randi( ...
    [0 1], 8*interferer_payload_bytes, 1));
interferer_packet = lrwpanWaveformGenerator( ...
    interferer_payload_bits, cfg_interferer);

target_sync = extractField(target_packet, idx_target.SYNC);
interferer_sync_64 = extractField(interferer_packet, idx_interferer.SYNC);
if interferer_sync_symbols ~= 2*interferer_generator_sync_symbols
    error('This 802.15.4a compatibility path expects 128 requested SYNC.');
end
interferer_sync = repmat(interferer_sync_64, 2, 1);
interferer_payload = extractField(interferer_packet, idx_interferer.Payload);
% Assemble the complete requested interferer frame by replacing its
% generator-provided 64-SYNC prefix with the synthesized 128-SYNC field.
interferer_after_sync = interferer_packet(idx_interferer.SYNC(2)+1:end);
complete_interferer_packet = [interferer_sync; interferer_after_sync];
symbol_length = numel(target_sync)/target_sync_symbols;
if symbol_length ~= round(symbol_length)
    error('The target SYNC field has a noninteger symbol length.');
end
symbol_length = round(symbol_length);
overlap_length = numel(target_sync);
if numel(interferer_sync) < overlap_length || ...
        numel(interferer_payload) < overlap_length
    error('The interferer fields are too short for a full 64-SYNC overlap.');
end
sync_interference = interferer_sync(1:overlap_length);
payload_interference = interferer_payload(1:overlap_length);

% Equal RMS power is imposed over the exact interval shared with target
% SYNC. Change interference_to_signal_db to explore near/far behavior.
amplitude_ratio = 10^(interference_to_signal_db/20);
sync_interference = matchRms(sync_interference, target_sync)*amplitude_ratio;
payload_interference = matchRms( ...
    payload_interference, target_sync)*amplitude_ratio;

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
    sampled_code, code_energy);
[cir_sync_overlap, individual_sync] = estimateRepeatedCir( ...
    rx_sync_overlap, target_start, target_sync_symbols, symbol_length, ...
    offsets, sampled_code, code_energy);
[cir_payload_overlap, individual_payload] = estimateRepeatedCir( ...
    rx_payload_overlap, target_start, target_sync_symbols, symbol_length, ...
    offsets, sampled_code, code_energy);
delay_ns = offsets/cfg_target.SampleRate*1e9;

clean_peak = max(abs(cir_clean));
clean_magnitude = abs(cir_clean)/(clean_peak+eps);
sync_magnitude = abs(cir_sync_overlap)/(clean_peak+eps);
payload_magnitude = abs(cir_payload_overlap)/(clean_peak+eps);
sync_error = norm(cir_sync_overlap-cir_clean)/(norm(cir_clean)+eps);
payload_error = norm(cir_payload_overlap-cir_clean)/(norm(cir_clean)+eps);

fprintf('\n========== 64-SYNC CIR overlap comparison ==========\n');
fprintf('Target signal                 : Code %d, %d SYNC\n', ...
    target_code_index, target_sync_symbols);
fprintf('Interferer packet             : Code %d, %d SYNC, %d-byte payload\n', ...
    interferer_code_index, interferer_sync_symbols, ...
    interferer_payload_bytes);
fprintf('Sample rate                   : %.3f MHz\n', cfg_target.SampleRate/1e6);
fprintf('Complete overlap duration     : %.3f us (%d samples)\n', ...
    overlap_length/cfg_target.SampleRate*1e6, overlap_length);
fprintf('Interference-to-signal ratio  : %+.1f dB\n', ...
    interference_to_signal_db);
fprintf('CIR coherent repetitions      : %d\n', target_sync_symbols);
fprintf('128-SYNC interference error   : %.2f %%\n', 100*sync_error);
fprintf('Payload interference error    : %.2f %%\n\n', 100*payload_error);

%% CIR comparison: all panels share the clean-CIR amplitude scale
figure('Color', 'w', 'Name', '64-SYNC CIR overlap comparison', ...
    'Position', [70 80 1400 440]);
tiledlayout(1, 3, 'TileSpacing', 'compact', 'Padding', 'compact');
plotCirPanel(delay_ns, clean_magnitude, 'Clean 64-SYNC CIR', ...
    [0.10 0.45 0.80]);
plotCirPanel(delay_ns, sync_magnitude, ...
    sprintf('64 SYNC overlapped by Code %d SYNC', interferer_code_index), ...
    [0.85 0.30 0.15]);
plotCirPanel(delay_ns, payload_magnitude, ...
    '64 SYNC overlapped by payload', [0.20 0.60 0.35]);
sgtitle(sprintf(['Target Code %d, 64-repetition coherent CIR | ', ...
    'interferer ISR %+.1f dB'], target_code_index, ...
    interference_to_signal_db));

%% Raw-signal overlap over the complete target 64-SYNC interval
raw_indices = target_start + (0:overlap_length-1);
raw_time_us = (0:overlap_length-1)'/cfg_target.SampleRate*1e6;
raw_scale = max(abs([target_component(raw_indices); ...
    sync_component(raw_indices); payload_component(raw_indices)]));

figure('Color', 'w', 'Name', '64-SYNC raw waveform overlap', ...
    'Position', [70 560 1400 440]);
tiledlayout(1, 3, 'TileSpacing', 'compact', 'Padding', 'compact');
plotWaveformPanel(raw_time_us, target_component(raw_indices), ...
    zeros(overlap_length, 1), rx_clean(raw_indices), raw_scale, ...
    'Clean target: 64 SYNC', 'No interference');
plotWaveformPanel(raw_time_us, target_component(raw_indices), ...
    sync_component(raw_indices), rx_sync_overlap(raw_indices), raw_scale, ...
    'Target 64 SYNC + interferer SYNC', '128-SYNC packet: SYNC');
plotWaveformPanel(raw_time_us, target_component(raw_indices), ...
    payload_component(raw_indices), rx_payload_overlap(raw_indices), ...
    raw_scale, 'Target 64 SYNC + interferer payload', ...
    '128-SYNC packet: payload');
sgtitle(sprintf('Complete %.3f us waveform overlap | common amplitude scale', ...
    overlap_length/cfg_target.SampleRate*1e6));

%% Complete target and interferer transmit waveforms, plotted separately
target_time_us = (0:numel(target_packet)-1)'/cfg_target.SampleRate*1e6;
interferer_time_us = (0:numel(complete_interferer_packet)-1)'/ ...
    cfg_interferer.SampleRate*1e6;
interferer_sync_end = numel(interferer_sync);
interferer_sfd_length = idx_interferer.SFD(2)-idx_interferer.SFD(1)+1;
interferer_phr_length = idx_interferer.PHR(2)-idx_interferer.PHR(1)+1;
interferer_sfd_range = interferer_sync_end + [1 interferer_sfd_length];
interferer_phr_range = interferer_sfd_range(2) + [1 interferer_phr_length];
interferer_payload_range = [interferer_phr_range(2)+1, ...
    numel(complete_interferer_packet)];

figure('Color', 'w', 'Name', 'Complete UWB transmit waveforms', ...
    'Position', [90 80 1380 760]);
tiledlayout(2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
nexttile;
plotCompleteWaveform(target_time_us, target_packet, cfg_target.SampleRate, ...
    idx_target.SYNC, idx_target.SFD, idx_target.PHR, idx_target.Payload, ...
    sprintf('Original target UWB signal: Code %d, 64 SYNC', ...
    target_code_index));
nexttile;
plotCompleteWaveform(interferer_time_us, complete_interferer_packet, ...
    cfg_interferer.SampleRate, [1 interferer_sync_end], ...
    interferer_sfd_range, interferer_phr_range, interferer_payload_range, ...
    sprintf('Complete interference UWB signal: Code %d, 128 SYNC, 127 bytes', ...
    interferer_code_index));
sgtitle('Complete time-domain waveforms plotted separately');

cir_interference_result = struct( ...
    'target_configuration', cfg_target, ...
    'interferer_configuration', cfg_interferer, ...
    'interferer_sync_symbols', interferer_sync_symbols, ...
    'interferer_sync_assembly', 'two repeated standard 64-SYNC fields', ...
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

function scaled = matchRms(signal, reference)
scaled = signal(:)*sqrt(sum(abs(reference).^2)/(sum(abs(signal).^2)+eps));
end

function buffer = addAt(buffer, signal, firstIndex)
indices = firstIndex + (0:numel(signal)-1);
if indices(1) < 1 || indices(end) > numel(buffer)
    error('Signal insertion exceeds the simulation buffer.');
end
buffer(indices) = buffer(indices) + signal(:);
end

function [averageCir, individualCir] = estimateRepeatedCir(rx, firstStart, ...
        repetitions, period, offsets, code, codeEnergy)
individualCir = complex(zeros(numel(offsets), repetitions));
for repetition = 0:repetitions-1
    symbol_start = firstStart + repetition*period;
    segment_start = symbol_start + offsets(1);
    segment_length = numel(code) + numel(offsets) - 1;
    segment = rx(segment_start:segment_start+segment_length-1);
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
