%% Validate SYNC-polarity coding for sensing CIR interference suppression.
% Sensing SYNC repetitions keep the same polarity (+1), while the
% communication SYNC repetitions alternate (+1,-1,...).  The receiver
% estimates the sensing CIR exactly in the style of
% +uwbdecoder/estimateCir.m: align repetitions, coherently average the raw
% SYNC windows, then correlate once with reference.sampled_code.
clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% -------------------- User configuration --------------------
rng_seed = 25;
sensing_code_index = 9;
communication_code_index = 10;
sync_repetitions = 64;             % even count required by alternating code
sir_list_db = [20 10 5 0 -5 -10]; % sensing power / communication power
display_sir_db = 0;
snr_db = 35;
% Keep the communication arrival asynchronous but inside the sensing CIR
% window, so its coherent leakage is directly visible and measurable.
communication_offset_samples = 57;
% Cyclic phase offset between the free-running polarity coder and the
% communication SYNC boundary. The coder has period 2*SYNC and alternates
% +1/-1 every SYNC. An offset near 1 SYNC is therefore equivalent to a
% small negative offset plus an irrelevant global polarity inversion.
polarity_timing_offset_sync = [0, 0.1:0.1:0.9];
timing_sweep_sir_db = 0;
display_timing_offset_sync = 0.1:0.1:0.9;
cir_pre_samples = 32;
cir_post_samples = 180;
save_figures = true;
figure_resolution_dpi = 180;
output_dir = fullfile(project_dir, 'decoded_results', ...
    'sync_polarity_cir_simulation');

if mod(sync_repetitions, 2) ~= 0
    error('sync_repetitions must be even for exact +/- pair cancellation.');
end

%% -------------------- Project HRP reference --------------------
options = struct('fs_rx', 998.4e6, 'data_rate', 6.81, ...
    'preamble_repetitions', sync_repetitions, ...
    'cir_repetitions', sync_repetitions, ...
    'code_index', sensing_code_index, ...
    'sfd_mode', '4z2', 'show_plots', false);
params = uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), options);
sensing_reference = uwbdecoder.buildUwbReference(params);
communication_options = options;
communication_options.code_index = communication_code_index;
communication_params = uwbdecoder.mergeOptions( ...
    uwbdecoder.defaultOptions(), communication_options);
communication_reference = uwbdecoder.buildUwbReference(communication_params);
sensing_sync_waveform = sensing_reference.preamble_waveform(:);
communication_sync_waveform = communication_reference.preamble_waveform(:);
samples_per_sync = sensing_reference.samples_per_symbol;

if numel(sensing_sync_waveform) ~= samples_per_sync || ...
        communication_reference.samples_per_symbol ~= samples_per_sync || ...
        communication_reference.fs ~= sensing_reference.fs
    error(['Sensing code %d and communication code %d must share the ', ...
        'same SYNC period and sample rate.'], sensing_code_index, ...
        communication_code_index);
end

sensing_polarity = ones(sync_repetitions, 1);
communication_plain_polarity = ones(sync_repetitions, 1);
communication_alt_polarity = (-1).^(0:sync_repetitions-1).';

% Different multipath channels make the wanted sensing CIR and the
% communication leakage visually distinguishable.
sensing_channel = struct('delays', [0 31 88 143], ...
    'gains', [1, 0.48*exp(1j*35*pi/180), ...
    0.29*exp(1j*112*pi/180), 0.16*exp(-1j*48*pi/180)]);
communication_channel = struct('delays', [0 47 121], ...
    'gains', [1, 0.55*exp(-1j*62*pi/180), ...
    0.24*exp(1j*138*pi/180)]);

sensing_tx = buildSyncBurst(sensing_sync_waveform, sensing_polarity);
communication_plain_tx = buildSyncBurst(communication_sync_waveform, ...
    communication_plain_polarity);
communication_alt_tx = buildSyncBurst(communication_sync_waveform, ...
    communication_alt_polarity);

sensing_rx = applySparseChannel(sensing_tx, sensing_channel);
communication_plain_rx = applySparseChannel(communication_plain_tx, ...
    communication_channel);
communication_alt_rx = applySparseChannel(communication_alt_tx, ...
    communication_channel);

% Normalize the two devices independently so requested SIR is unambiguous.
sensing_rx = sensing_rx / sqrt(mean(abs(sensing_rx).^2) + eps);
communication_plain_rx = communication_plain_rx / ...
    sqrt(mean(abs(communication_plain_rx).^2) + eps);
communication_alt_rx = communication_alt_rx / ...
    sqrt(mean(abs(communication_alt_rx).^2) + eps);

guard = max(cir_pre_samples + 8, communication_offset_samples + 8);
sensing_start = guard + 1;
capture_length = sensing_start - 1 + max([numel(sensing_rx), ...
    communication_offset_samples + numel(communication_plain_rx), ...
    communication_offset_samples + numel(communication_alt_rx)]) + ...
    cir_post_samples + 8;
communication_start = sensing_start + communication_offset_samples;

clean_capture = complex(zeros(capture_length, 1));
clean_capture = addAt(clean_capture, sensing_rx, sensing_start);
clean_cir = estimateKnownSyncCir(clean_capture, sensing_start, ...
    sensing_reference, ...
    sync_repetitions, cir_pre_samples, cir_post_samples);

%% -------------------- SIR sweep --------------------
rng(rng_seed, 'twister');
summary = repmat(struct('sir_db', NaN, 'plain_coherence', NaN, ...
    'alternating_coherence', NaN, 'plain_residual', NaN, ...
    'alternating_residual', NaN, 'interference_suppression_db', NaN), ...
    numel(sir_list_db), 1);
display_case = struct();

signal_power = mean(abs(sensing_rx).^2);
noise_power = signal_power * 10^(-snr_db/10);
common_noise = sqrt(noise_power/2) * ...
    (randn(capture_length, 1) + 1j*randn(capture_length, 1));

for k = 1:numel(sir_list_db)
    sir_db = sir_list_db(k);
    communication_scale = 10^(-sir_db/20);

    plain_capture = clean_capture + common_noise;
    plain_capture = addAt(plain_capture, ...
        communication_scale*communication_plain_rx, communication_start);
    alternating_capture = clean_capture + common_noise;
    alternating_capture = addAt(alternating_capture, ...
        communication_scale*communication_alt_rx, communication_start);

    plain_cir = estimateKnownSyncCir(plain_capture, sensing_start, ...
        sensing_reference, sync_repetitions, ...
        cir_pre_samples, cir_post_samples);
    alternating_cir = estimateKnownSyncCir(alternating_capture, ...
        sensing_start, sensing_reference, sync_repetitions, ...
        cir_pre_samples, cir_post_samples);

    plain_metrics = compareCir(clean_cir.values_raw, plain_cir.values_raw);
    alt_metrics = compareCir(clean_cir.values_raw, ...
        alternating_cir.values_raw);
    suppression_db = 10*log10((plain_metrics.error_energy + eps) / ...
        (alt_metrics.error_energy + eps));

    summary(k).sir_db = sir_db;
    summary(k).plain_coherence = plain_metrics.coherence;
    summary(k).alternating_coherence = alt_metrics.coherence;
    summary(k).plain_residual = plain_metrics.normalized_residual;
    summary(k).alternating_residual = alt_metrics.normalized_residual;
    summary(k).interference_suppression_db = suppression_db;

    fprintf(['SIR %+5.1f dB | coherence plain/alt %.4f / %.4f | ', ...
        'residual %.4f / %.4f | polarity gain %+6.2f dB\n'], ...
        sir_db, plain_metrics.coherence, alt_metrics.coherence, ...
        plain_metrics.normalized_residual, ...
        alt_metrics.normalized_residual, suppression_db);

    if sir_db == display_sir_db
        display_case = struct('plain_capture', plain_capture, ...
            'alternating_capture', alternating_capture, ...
            'plain_cir', plain_cir, 'alternating_cir', alternating_cir, ...
            'plain_metrics', plain_metrics, 'alt_metrics', alt_metrics);
    end
end

if isempty(fieldnames(display_case))
    error('display_sir_db must be one of sir_list_db.');
end

%% -------------------- Polarity cyclic-phase-offset sweep ---------------
% RF arrival timing is fixed. The polarity coder is assumed to be already
% free-running; only its cyclic phase relative to the first communication
% SYNC boundary is changed. This is not a delayed-startup model.
n_timing = numel(polarity_timing_offset_sync);
timing_summary = repmat(struct('offset_sync', NaN, ...
    'offset_samples', NaN, 'self_cancellation_db', NaN, ...
    'cir_coherence', NaN, 'normalized_residual', NaN), n_timing, 1);
communication_scale = 10^(-timing_sweep_sir_db/20);
timing_display_cases = cell(numel(display_timing_offset_sync), 1);

% All-positive Code-10 leakage is the no-polarity-coding reference.
plain_only_capture = complex(zeros(capture_length, 1));
plain_only_capture = addAt(plain_only_capture, communication_plain_rx, ...
    communication_start);
plain_leakage_cir = estimateKnownSyncCir(plain_only_capture, ...
    sensing_start, sensing_reference, sync_repetitions, ...
    cir_pre_samples, cir_post_samples);
plain_leakage_energy = norm(plain_leakage_cir.values_raw)^2;

for k = 1:n_timing
    offset_samples = round(polarity_timing_offset_sync(k) * ...
        samples_per_sync);
    offset_tx = buildTimingOffsetPolarityBurst( ...
        communication_sync_waveform, sync_repetitions, offset_samples);
    offset_rx = applySparseChannel(offset_tx, communication_channel);
    offset_rx = offset_rx / sqrt(mean(abs(offset_rx).^2) + eps);

    communication_only_capture = complex(zeros(capture_length, 1));
    communication_only_capture = addAt(communication_only_capture, ...
        offset_rx, communication_start);
    leakage_cir = estimateKnownSyncCir(communication_only_capture, ...
        sensing_start, sensing_reference, sync_repetitions, ...
        cir_pre_samples, cir_post_samples);
    leakage_energy = norm(leakage_cir.values_raw)^2;

    mixed_capture = clean_capture + common_noise;
    mixed_capture = addAt(mixed_capture, ...
        communication_scale*offset_rx, communication_start);
    mixed_cir = estimateKnownSyncCir(mixed_capture, sensing_start, ...
        sensing_reference, sync_repetitions, ...
        cir_pre_samples, cir_post_samples);
    metrics = compareCir(clean_cir.values_raw, mixed_cir.values_raw);

    timing_summary(k).offset_sync = polarity_timing_offset_sync(k);
    timing_summary(k).offset_samples = offset_samples;
    timing_summary(k).self_cancellation_db = 10*log10( ...
        (plain_leakage_energy + eps)/(leakage_energy + eps));
    timing_summary(k).cir_coherence = metrics.coherence;
    timing_summary(k).normalized_residual = metrics.normalized_residual;

    display_index = find(abs(display_timing_offset_sync - ...
        timing_summary(k).offset_sync) < 1e-12, 1);
    if ~isempty(display_index)
        timing_display_cases{display_index} = struct( ...
            'mixed_capture', mixed_capture, 'mixed_cir', mixed_cir, ...
            'metrics', metrics, ...
            'offset_sync', timing_summary(k).offset_sync, ...
            'offset_samples', offset_samples);
    end

    fprintf(['Timing offset %5.2f SYNC (%6d samples) | self-cancel ', ...
        '%+6.2f dB | coherence %.4f | residual %.4f\n'], ...
        timing_summary(k).offset_sync, offset_samples, ...
        timing_summary(k).self_cancellation_db, metrics.coherence, ...
        metrics.normalized_residual);
end

if any(cellfun(@isempty, timing_display_cases))
    error(['display_timing_offset_sync must be one of ', ...
        'polarity_timing_offset_sync.']);
end

%% -------------------- Figure 1: templates and raw signals --------------------
fig1 = figure('Name', 'SYNC polarity-coded source signals', ...
    'Color', 'w', 'Position', [50 50 1450 850]);
tiledlayout(fig1, 2, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

nexttile;
t_ns = (0:samples_per_sync-1).'/sensing_reference.fs*1e9;
plot(t_ns, real(sensing_sync_waveform), 'LineWidth', 1.0);
hold on;
plot(t_ns, real(communication_sync_waveform), '--', 'LineWidth', 1.0);
grid on;
xlabel('Time in one SYNC (ns)');
ylabel('Amplitude');
legend(sprintf('Sensing code %d', sensing_code_index), ...
    sprintf('Communication code %d', communication_code_index), ...
    'Location', 'best');
title('Project HRP single-SYNC templates');

nexttile;
shown = min(16, sync_repetitions);
stairs(1:shown, sensing_polarity(1:shown), 'o-', 'LineWidth', 1.2);
hold on;
stairs(1:shown, communication_alt_polarity(1:shown), 's-', ...
    'LineWidth', 1.2);
grid on;
ylim([-1.3 1.3]);
yticks([-1 0 1]);
xlabel('SYNC repetition');
ylabel('Polarity');
legend('Sensing: same polarity', 'Communication: alternating polarity', ...
    'Location', 'southwest');
title('Proposed polarity assignment');

plot_samples = min(5*samples_per_sync, numel(sensing_tx));
t_us = (0:plot_samples-1).'/sensing_reference.fs*1e6;
nexttile;
plot(t_us, real(sensing_tx(1:plot_samples)), 'LineWidth', 0.9);
grid on;
xlabel('Time (\mus)');
ylabel('I amplitude');
title('Original sensing SYNC burst (+ + + + ...)');

nexttile;
plot(t_us, real(communication_plain_tx(1:plot_samples)), ...
    'Color', [0.65 0.65 0.65], 'LineWidth', 0.9);
hold on;
plot(t_us, real(communication_alt_tx(1:plot_samples)), ...
    'Color', [0.85 0.22 0.12], 'LineWidth', 0.9);
grid on;
xlabel('Time (\mus)');
ylabel('I amplitude');
legend('Communication baseline', 'Communication alternating polarity', ...
    'Location', 'best');
title('Original communication SYNC burst');

sgtitle('SYNC polarity coding: source templates and generated waveforms');

%% -------------------- Figure 2: CIR comparison --------------------
delay_ns = clean_cir.delay_ns;
clean_aligned = normalizeCir(clean_cir.values_raw);
plain_aligned = alignAndNormalize(clean_cir.values_raw, ...
    display_case.plain_cir.values_raw);
alt_aligned = alignAndNormalize(clean_cir.values_raw, ...
    display_case.alternating_cir.values_raw);
n_display_offsets = numel(display_timing_offset_sync);
timing_aligned = complex(zeros(numel(clean_aligned), n_display_offsets));
for k = 1:n_display_offsets
    timing_aligned(:, k) = alignAndNormalize(clean_cir.values_raw, ...
        timing_display_cases{k}.mixed_cir.values_raw);
end
timing_colors = turbo(n_display_offsets);
scale = max(abs(clean_aligned)) + eps;

fig2 = figure('Name', 'Sensing CIR with SYNC polarity coding', ...
    'Color', 'w', 'Position', [70 70 1450 820]);
tiledlayout(fig2, 2, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

nexttile([1 2]);
plot(delay_ns, abs(clean_aligned)/scale, 'k-', 'LineWidth', 1.8);
hold on;
plot(delay_ns, abs(plain_aligned)/scale, '--', ...
    'Color', [0.82 0.25 0.14], 'LineWidth', 1.2);
plot(delay_ns, abs(alt_aligned)/scale, '-', ...
    'Color', [0.10 0.50 0.82], 'LineWidth', 1.4);
for k = 1:n_display_offsets
    plot(delay_ns, abs(timing_aligned(:, k))/scale, '-.', ...
        'Color', timing_colors(k, :), 'LineWidth', 1.0);
end
grid on;
xlabel('CIR delay (ns)');
ylabel('Normalized |CIR|');
offset_legend = reshape(cellstr(compose( ...
    'Communication +/- offset %.1f SYNC', ...
    display_timing_offset_sync)), 1, []);
cir_legend = [{'Clean sensing CIR', 'Communication all +', ...
    'Communication +/- synchronized'}, offset_legend];
legend(cir_legend, 'Location', 'eastoutside');
title(sprintf('Sensing CIR at SIR %+g dB', display_sir_db));

nexttile;
timing_error_db = 20*log10( ...
    abs(timing_aligned-clean_aligned)/scale + eps);
plain_error_db = 20*log10(abs(plain_aligned-clean_aligned)/scale + eps);
alt_error_db = 20*log10(abs(alt_aligned-clean_aligned)/scale + eps);
plot(delay_ns, plain_error_db, '--', 'Color', [0.82 0.25 0.14], ...
    'LineWidth', 1.1);
hold on;
plot(delay_ns, alt_error_db, '-', 'Color', [0.10 0.50 0.82], ...
    'LineWidth', 1.2);
for k = 1:n_display_offsets
    plot(delay_ns, timing_error_db(:, k), '-.', ...
        'Color', timing_colors(k, :), 'LineWidth', 0.9);
end
grid on;
ylim([-100 5]);
xlabel('CIR delay (ns)');
ylabel('Error relative to peak (dB)');
error_offset_legend = reshape(cellstr(compose( ...
    '+/- offset %.1f SYNC', display_timing_offset_sync)), 1, []);
error_legend = [{'All + interference', '+/- synchronized'}, ...
    error_offset_legend];
legend(error_legend, 'Location', 'eastoutside');
title('CIR error relative to clean target');

nexttile;
raw_count = min(4*samples_per_sync, ...
    numel(display_case.plain_capture)-sensing_start+1);
raw_idx = sensing_start + (0:raw_count-1);
raw_t_us = (0:raw_count-1).'/sensing_reference.fs*1e6;
plot(raw_t_us, real(display_case.plain_capture(raw_idx)), ...
    'Color', [0.82 0.25 0.14 0.72], 'LineWidth', 0.8);
hold on;
plot(raw_t_us, real(display_case.alternating_capture(raw_idx)), ...
    'Color', [0.10 0.50 0.82 0.72], 'LineWidth', 0.8);
grid on;
xlabel('Time from sensing start (\mus)');
ylabel('Mixed I amplitude');
legend('Communication all +', 'Communication +/- synchronized', ...
    'Location', 'best');
title('Raw mixed signal before CIR estimation');

sgtitle(sprintf(['Sensing code %d CIR preservation against ', ...
    'communication code %d | %d coherent SYNC repetitions'], ...
    sensing_code_index, communication_code_index, sync_repetitions));

%% -------------------- Figure 3: SIR sweep metrics --------------------
sir = [summary.sir_db];
fig3 = figure('Name', 'SYNC polarity coding performance', ...
    'Color', 'w', 'Position', [90 90 1450 440]);
tiledlayout(fig3, 1, 3, 'TileSpacing', 'compact', 'Padding', 'compact');

nexttile;
plot(sir, [summary.plain_coherence], 'o--', 'LineWidth', 1.2);
hold on;
plot(sir, [summary.alternating_coherence], 's-', 'LineWidth', 1.4);
grid on;
ylim([0 1.02]);
xlabel('Input SIR (dB)');
ylabel('CIR coherence');
legend('Communication all +', 'Communication +/-', 'Location', 'best');
title('Target CIR shape preservation');

nexttile;
semilogy(sir, [summary.plain_residual], 'o--', 'LineWidth', 1.2);
hold on;
semilogy(sir, [summary.alternating_residual], 's-', 'LineWidth', 1.4);
grid on;
xlabel('Input SIR (dB)');
ylabel('Normalized CIR residual');
legend('Communication all +', 'Communication +/-', 'Location', 'best');
title('CIR estimation error');

nexttile;
plot(sir, [summary.interference_suppression_db], 'd-', ...
    'Color', [0.16 0.60 0.30], 'LineWidth', 1.5, 'MarkerFaceColor', ...
    [0.16 0.60 0.30]);
hold on;
yline(0, 'k:');
grid on;
xlabel('Input SIR (dB)');
ylabel('Error suppression (dB)');
title('Gain from alternating polarity');

sgtitle('SYNC polarity coding performance across interference levels');

%% -------------------- Figure 4: timing offset vs cancellation gain --------------------
fig4 = figure('Name', 'Initial timing offset vs polarity gain', ...
    'Color', 'w', 'Position', [130 130 900 560]);
offset_axis = [timing_summary.offset_sync];
gain_axis = [timing_summary.self_cancellation_db];
plot(offset_axis, gain_axis, 'o-', 'Color', [0.12 0.52 0.30], ...
    'LineWidth', 1.8, 'MarkerSize', 7, ...
    'MarkerFaceColor', [0.12 0.52 0.30]);
grid on;
xlim([min(offset_axis), max(offset_axis)]);
xticks(offset_axis);
xlabel('Initial polarity timing offset (SYNC periods)');
ylabel('Communication self-cancellation gain (dB)');
title(sprintf(['Polarity-coding gain versus initial timing offset ', ...
    '(SIR %+g dB)'], timing_sweep_sir_db));

%% -------------------- Save --------------------
if ~isfolder(output_dir)
    mkdir(output_dir);
end
summary_table = struct2table(summary);
writetable(summary_table, fullfile(output_dir, 'summary.csv'));
timing_summary_table = struct2table(timing_summary);
writetable(timing_summary_table, fullfile(output_dir, ...
    'timing_offset_summary.csv'));
save(fullfile(output_dir, 'sync_polarity_cir_simulation.mat'), ...
    'summary', 'timing_summary', 'clean_cir', 'display_case', ...
    'sensing_reference', ...
    'communication_reference', ...
    'sensing_polarity', 'communication_plain_polarity', ...
    'communication_alt_polarity', 'sensing_channel', ...
    'communication_channel', 'sir_list_db', '-v7.3');

if save_figures
    exportgraphics(fig1, fullfile(output_dir, ...
        '01_sync_polarity_source_waveforms.png'), ...
        'Resolution', figure_resolution_dpi);
    exportgraphics(fig2, fullfile(output_dir, ...
        '02_sensing_cir_comparison.png'), ...
        'Resolution', figure_resolution_dpi);
    exportgraphics(fig3, fullfile(output_dir, ...
        '03_polarity_coding_metrics.png'), ...
        'Resolution', figure_resolution_dpi);
    exportgraphics(fig4, fullfile(output_dir, ...
        '04_timing_offset_cancellation_gain.png'), ...
        'Resolution', figure_resolution_dpi);
end

fprintf('\nResults saved to:\n  %s\n', output_dir);

%% ========================================================================
function burst = buildSyncBurst(syncWaveform, polarity)
syncWaveform = syncWaveform(:);
polarity = polarity(:).';
burst = reshape(syncWaveform * polarity, [], 1);
end

function burst = buildTimingOffsetPolarityBurst(syncWaveform, ...
        repetitionCount, initialOffsetSamples)
% A continuously running alternating-polarity coder with a cyclic phase
% offset relative to the communication SYNC boundaries. Its full period is
% two SYNC intervals. Modulo wrapping ensures that offsets d and 1-d have
% equivalent cancellation strength apart from a global sign inversion.
plainBurst = repmat(syncWaveform(:), repetitionCount, 1);
period = numel(syncWaveform);
sampleIndex = (0:numel(plainBurst)-1).';
phaseSamples = mod(sampleIndex-initialOffsetSamples, 2*period);
polarity = ones(size(sampleIndex));
polarity(phaseSamples >= period) = -1;
burst = plainBurst .* polarity;
end

function output = applySparseChannel(input, channel)
input = input(:);
maxDelay = max(channel.delays);
output = complex(zeros(numel(input) + maxDelay, 1));
for k = 1:numel(channel.delays)
    first = channel.delays(k) + 1;
    output(first:first+numel(input)-1) = ...
        output(first:first+numel(input)-1) + channel.gains(k)*input;
end
end

function output = addAt(output, signal, first)
last = first + numel(signal) - 1;
if first < 1 || last > numel(output)
    error('Signal placement [%d,%d] exceeds capture [1,%d].', ...
        first, last, numel(output));
end
output(first:last) = output(first:last) + signal(:);
end

function cir = estimateKnownSyncCir(rx, startSample, reference, ...
        repetitionCount, preSamples, postSamples)
% Mirrors the aligned-segment/coherent-average/local-CMF implementation in
% +uwbdecoder/estimateCir.m, using known simulation timing.
code = reference.sampled_code(:);
codeMf = flipud(conj(code));
tapOffsets = (-preSamples:postSamples-1).';
tapCount = numel(tapOffsets);
localOffsets = tapOffsets(1) + (0:numel(code)+tapCount-2).';
repetitionStarts = startSample + ...
    (0:repetitionCount-1)*reference.samples_per_symbol;
positions = localOffsets + repetitionStarts;
if any(positions(:) < 1) || any(positions(:) > numel(rx))
    error('CIR aligned window exceeds the synthetic capture.');
end
alignedSegments = rx(positions);
averageSegment = mean(alignedSegments, 2);
valuesRaw = conv(averageSegment, codeMf, 'valid') / ...
    (reference.code_energy + eps);
cir = struct('values_raw', valuesRaw, ...
    'values', valuesRaw/(norm(valuesRaw)+eps), ...
    'delay_ns', tapOffsets/reference.fs*1e9, ...
    'individual_values', [], 'repetition_count', repetitionCount);
end

function metrics = compareCir(referenceCir, estimatedCir)
referenceCir = referenceCir(:);
estimatedCir = estimatedCir(:);
gain = (estimatedCir' * referenceCir) / ...
    (estimatedCir' * estimatedCir + eps);
aligned = estimatedCir * gain;
error = aligned - referenceCir;
metrics = struct( ...
    'coherence', abs(referenceCir' * estimatedCir) / ...
        (norm(referenceCir)*norm(estimatedCir) + eps), ...
    'normalized_residual', norm(error)/(norm(referenceCir)+eps), ...
    'error_energy', norm(error)^2, 'complex_gain', gain, ...
    'aligned_cir', aligned);
end

function output = normalizeCir(input)
output = input(:)/(norm(input(:))+eps);
end

function output = alignAndNormalize(referenceCir, estimatedCir)
metrics = compareCir(referenceCir, estimatedCir);
output = metrics.aligned_cir/(norm(referenceCir)+eps);
end
