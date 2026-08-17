function [rxOut, report] = cancel_uwb_packet_in_iq(rx, decoded, txOptions, opts)
%CANCEL_UWB_PACKET_IN_IQ Subtract one regenerated packet from a work-rate IQ.
%   [RXOUT, REPORT] = CANCEL_UWB_PACKET_IN_IQ(RX, DECODED, TXOPTIONS)
%   rebuilds DECODED with GENERATE_UWB_TX_FROM_DECODE and
%   APPLY_ESTIMATED_CIR_TO_UWB, then fits alignment / CFO / complex gain
%   against RX and subtracts the replica.
%
%   This is the in-memory counterpart of run_cancel_all_uwb_packets.m's
%   per-packet patch. It does not read or write .dat files, so scheduled
%   dump windows can reuse the same reconstruction without a capture file.
%
%   See also GENERATE_UWB_TX_FROM_DECODE, APPLY_ESTIMATED_CIR_TO_UWB,
%   RUN_CANCEL_ALL_UWB_PACKETS.

if nargin < 3 || isempty(txOptions)
    error('cancel_uwb_packet_in_iq:Usage', ...
        'usage: [rx, report] = cancel_uwb_packet_in_iq(rx, decoded, txOptions)');
end
if nargin < 4 || isempty(opts)
    opts = struct();
end
opts = fillCancelOptions(opts);

rx = rx(:);
fs = opts.fs_rx;
c = uwbdecoder.constants();
periodRx = c.PREAMBLE_PERIOD_S * fs;

tx = generate_uwb_tx_from_decode(decoded, txOptions);
channel = apply_estimated_cir_to_uwb(tx, decoded.cir);
replica = channel.waveform_x410(:);

nominalStart = packetStartSample(decoded);
if ~(isfinite(nominalStart) && nominalStart >= 1 && ...
        nominalStart <= numel(rx))
    error('cancel_uwb_packet_in_iq:BadStart', ...
        'Decoded packet start %g is outside the IQ window 1:%d.', ...
        nominalStart, numel(rx));
end

[startLocal, integerCorr] = alignReplica( ...
    rx, replica, round(nominalStart), periodRx, ...
    opts.alignment_search_samples, opts.gain_fit_first_sync, ...
    opts.alignment_template_syncs);

available = min(numel(replica), numel(rx) - startLocal + 1);
if available < round(txOptions.preamble_repetitions * periodRx)
    error('cancel_uwb_packet_in_iq:ShortWindow', ...
        'The complete preamble is not available in the IQ window.');
end
replica = replica(1:available);
observed = rx(startLocal:startLocal + available - 1);

initialCfoHz = fitReplicaCfo(observed, replica, periodRx, ...
    opts.cfo_fit_first_sync, opts.cfo_fit_last_sync, fs);
if abs(initialCfoHz) > opts.max_abs_cfo_hz
    error('cancel_uwb_packet_in_iq:CfoLimit', ...
        'Fitted CFO %+.3f kHz exceeds the safety limit.', ...
        initialCfoHz / 1e3);
end
n = (0:available - 1).';
replicaCfo = replica .* exp(1j * 2 * pi * initialCfoHz * n / fs);
[fracDelay, alignCorr] = refineFractionalAlignment( ...
    observed, replicaCfo, periodRx, opts.gain_fit_first_sync, ...
    opts.alignment_template_syncs, opts.fractional_alignment_max_samples, ...
    opts.fractional_alignment_coarse_step, ...
    opts.fractional_alignment_fine_step, ...
    opts.fractional_alignment_min_improvement);
replica = applyFractionalShift(replica, fracDelay);

fittedCfoHz = fitReplicaCfo(observed, replica, periodRx, ...
    opts.cfo_fit_first_sync, opts.cfo_fit_last_sync, fs);
if abs(fittedCfoHz) > opts.max_abs_cfo_hz
    error('cancel_uwb_packet_in_iq:CfoLimit', ...
        'Fitted CFO %+.3f kHz exceeds the safety limit.', ...
        fittedCfoHz / 1e3);
end
replicaCfo = replica .* exp(1j * 2 * pi * fittedCfoHz * n / fs);

cirSlow = emptyCirSlowDiagnostics();
if opts.enable_cir_slow_phase
    [phaseByRep, cirSlow] = estimate_uwb_cir_slow_phase( ...
        decoded.cir, txOptions.preamble_repetitions, ...
        opts.cir_slow_phase_options);
    replicaCfo = applyCirSecondStageCfo(replicaCfo, periodRx, cirSlow);
    replicaCfo = applyRepetitionPhaseCurve(replicaCfo, periodRx, phaseByRep);
end

sfo = estimate_uwb_full_packet_sfo([], [], fs, opts.full_packet_sfo_options);
if opts.enable_full_packet_sfo
    sfo = estimate_uwb_full_packet_sfo( ...
        observed, replicaCfo, fs, opts.full_packet_sfo_options);
end
if sfo.applied
    replicaCfo = apply_uwb_full_packet_sfo(replicaCfo, sfo);
end

if alignCorr < opts.min_alignment_correlation
    error('cancel_uwb_packet_in_iq:Alignment', ...
        'Fractional alignment correlation %.3f is below %.3f.', ...
        alignCorr, opts.min_alignment_correlation);
end

gainFirst = round((opts.gain_fit_first_sync - 1) * periodRx) + 1;
gainLast = min(available, round(opts.gain_fit_last_sync * periodRx));
gainIdx = gainFirst:gainLast;
globalGain = (replicaCfo(gainIdx)' * observed(gainIdx)) / ...
    (replicaCfo(gainIdx)' * replicaCfo(gainIdx) + eps);
baseline = globalGain * replicaCfo;

phrIdx = workFieldToRxIndices(tx.field_indices_work.PHR, ...
    tx.sample_rate_work, fs, available);
payloadIdx = workFieldToRxIndices(tx.field_indices_work.Payload, ...
    tx.sample_rate_work, fs, available);
[model, phrGain, payloadGain] = selectFieldModel( ...
    baseline, observed, phrIdx, payloadIdx, ...
    opts.cancellation_mode, opts.fixed_phr_payload_scale);

residual = observed - model;
suppressionDb = 10 * log10( ...
    mean(abs(observed).^2) / (mean(abs(residual).^2) + eps));
if suppressionDb < opts.min_frame_suppression_db
    error('cancel_uwb_packet_in_iq:Suppression', ...
        'Frame suppression %.3f dB is below %.3f dB.', ...
        suppressionDb, opts.min_frame_suppression_db);
end

rxOut = rx;
rxOut(startLocal:startLocal + available - 1) = residual;

report = struct();
report.success = true;
report.message = '';
report.start_sample = startLocal;
report.samples_subtracted = available;
report.integer_alignment_correlation = integerCorr;
report.alignment_correlation = alignCorr;
report.fractional_delay_samples = fracDelay;
report.fitted_cfo_hz = fittedCfoHz;
report.global_gain = globalGain;
report.phr_gain = phrGain;
report.payload_gain = payloadGain;
report.frame_suppression_db = suppressionDb;
report.cir_slow_phase_applied = cirSlow.applied;
report.cir_second_stage_cfo_applied = cirSlow.second_stage_cfo_applied;
report.full_packet_sfo_applied = sfo.applied;
if isfield(sfo, 'sfo_ppm')
    report.full_packet_sfo_ppm = sfo.sfo_ppm;
else
    report.full_packet_sfo_ppm = NaN;
end
end

function opts = fillCancelOptions(opts)
defaults = struct( ...
    'fs_rx', 998.4e6, ...
    'cancellation_mode', 'optimal_complex', ...
    'fixed_phr_payload_scale', 0.88, ...
    'alignment_search_samples', 128, ...
    'alignment_template_syncs', 32, ...
    'cfo_fit_first_sync', 25, ...
    'cfo_fit_last_sync', [], ...
    'gain_fit_first_sync', 25, ...
    'gain_fit_last_sync', [], ...
    'fractional_alignment_max_samples', 0.75, ...
    'fractional_alignment_coarse_step', 0.10, ...
    'fractional_alignment_fine_step', 0.003, ...
    'fractional_alignment_min_improvement', 5e-4, ...
    'min_alignment_correlation', 0.70, ...
    'min_frame_suppression_db', 0.20, ...
    'max_abs_cfo_hz', 100e3, ...
    'enable_cir_slow_phase', true, ...
    'cir_slow_phase_options', struct( ...
        'tap_half_width', 2, ...
        'smoothing_lambda', 0.10, ...
        'minimum_subspace_coherence', 0.85, ...
        'minimum_correction_rms_deg', 0.20, ...
        'minimum_explained_fraction', 0.10, ...
        'maximum_abs_correction_deg', 15.0, ...
        'maximum_abs_second_stage_cfo_hz', 2e3), ...
    'enable_full_packet_sfo', true, ...
    'full_packet_sfo_options', struct( ...
        'window_duration_us', 8.0, ...
        'maximum_abs_window_delay_samples', 0.50, ...
        'coarse_delay_step_samples', 0.025, ...
        'fine_delay_step_samples', 0.0025, ...
        'minimum_window_correlation', 0.90, ...
        'minimum_valid_windows', 6, ...
        'minimum_relative_model_rms', 0.02, ...
        'strong_model_fraction', 0.10, ...
        'minimum_strong_samples', 64, ...
        'minimum_total_drift_samples', 0.02, ...
        'maximum_abs_sfo_ppm', 20.0, ...
        'maximum_fit_residual_samples', 0.08, ...
        'minimum_explained_fraction', 0.50));
names = fieldnames(defaults);
for k = 1:numel(names)
    if ~isfield(opts, names{k}) || isempty(opts.(names{k}))
        opts.(names{k}) = defaults.(names{k});
    end
end
if isempty(opts.cfo_fit_last_sync)
    opts.cfo_fit_last_sync = 256;
end
if isempty(opts.gain_fit_last_sync)
    opts.gain_fit_last_sync = opts.cfo_fit_last_sync;
end
end

function startSample = packetStartSample(decoded)
startSample = NaN;
if isfield(decoded, 'preamble')
    if isfield(decoded.preamble, 'start_sample_uncropped') && ...
            ~isempty(decoded.preamble.start_sample_uncropped)
        startSample = double(decoded.preamble.start_sample_uncropped);
        return
    end
    if isfield(decoded.preamble, 'start_sample')
        startSample = double(decoded.preamble.start_sample);
    end
end
end

function [bestStart, bestCorrelation] = alignReplica( ...
        received, replica, nominalStart, periodRx, searchRadius, ...
        firstSync, templateSyncs)
templateFirst = round((firstSync - 1) * periodRx) + 1;
templateLast = min(numel(replica), ...
    round((firstSync - 1 + templateSyncs) * periodRx));
template = replica(templateFirst:templateLast);
candidateStarts = nominalStart + (-searchRadius:searchRadius);
scores = -inf(size(candidateStarts));
for k = 1:numel(candidateStarts)
    first = candidateStarts(k) + templateFirst - 1;
    last = first + numel(template) - 1;
    if first < 1 || last > numel(received)
        continue
    end
    segment = received(first:last);
    scores(k) = abs(template' * segment) / ...
        (norm(template) * norm(segment) + eps);
end
[bestCorrelation, idx] = max(scores);
bestStart = candidateStarts(idx);
end

function [bestDelay, bestCorrelation] = refineFractionalAlignment( ...
        received, replica, periodRx, firstSync, templateSyncs, ...
        maxDelay, coarseStep, fineStep, minImprovement)
templateFirst = round((firstSync - 1) * periodRx) + 1;
templateLast = min(numel(replica), ...
    round((firstSync - 1 + templateSyncs) * periodRx));
templateIndices = (templateFirst:templateLast).';
receivedTemplate = received(templateIndices);
padding = ceil(maxDelay) + 3;
segmentFirst = max(1, templateFirst - padding);
segmentLast = min(numel(replica), templateLast + padding);
segmentAxis = (segmentFirst:segmentLast).';
interpolator = griddedInterpolant(segmentAxis, ...
    replica(segmentFirst:segmentLast), 'spline', 'none');
scoreAtDelay = @(delay) fractionalAlignmentScore( ...
    interpolator, templateIndices, receivedTemplate, delay);
zeroCorrelation = scoreAtDelay(0);
coarseDelays = unique([(-maxDelay:coarseStep:maxDelay), 0]);
coarseScores = zeros(size(coarseDelays));
for k = 1:numel(coarseDelays)
    coarseScores(k) = scoreAtDelay(coarseDelays(k));
end
[~, coarseBestIndex] = max(coarseScores);
coarseBestDelay = coarseDelays(coarseBestIndex);
fineFirst = max(-maxDelay, coarseBestDelay - coarseStep);
fineLast = min(maxDelay, coarseBestDelay + coarseStep);
fineDelays = unique([fineFirst:fineStep:fineLast, coarseBestDelay, 0]);
fineScores = zeros(size(fineDelays));
for k = 1:numel(fineDelays)
    fineScores(k) = scoreAtDelay(fineDelays(k));
end
[bestCorrelation, fineBestIndex] = max(fineScores);
bestDelay = fineDelays(fineBestIndex);
if bestCorrelation - zeroCorrelation < minImprovement
    bestDelay = 0;
    bestCorrelation = zeroCorrelation;
end
end

function score = fractionalAlignmentScore( ...
        interpolator, templateIndices, receivedTemplate, delay)
shiftedTemplate = interpolator(templateIndices - delay);
if any(~isfinite(shiftedTemplate))
    score = -inf;
    return
end
score = abs(shiftedTemplate' * receivedTemplate) / ...
    (norm(shiftedTemplate) * norm(receivedTemplate) + eps);
end

function shifted = applyFractionalShift(signal, delay)
if delay == 0
    shifted = signal;
    return
end
sampleAxis = (1:numel(signal)).';
interpolator = griddedInterpolant(sampleAxis, signal(:), 'spline', 'none');
shifted = interpolator(sampleAxis - delay);
shifted(~isfinite(shifted)) = 0;
end

function cfoHz = fitReplicaCfo(received, replica, periodRx, ...
        firstSync, lastSync, fs)
syncCount = min(lastSync, floor(min(numel(received), ...
    numel(replica)) / periodRx));
firstSync = min(firstSync, syncCount);
if syncCount < firstSync
    cfoHz = 0;
    return
end
correlations = complex(zeros(syncCount - firstSync + 1, 1));
times = zeros(size(correlations));
for k = firstSync:syncCount
    first = round((k - 1) * periodRx) + 1;
    last = min(numel(replica), round(k * periodRx));
    idx = first:last;
    q = k - firstSync + 1;
    correlations(q) = replica(idx)' * received(idx);
    times(q) = ((first + last) / 2 - 1) / fs;
end
phase = unwrap(angle(correlations));
lineFit = polyfit(times, phase, 1);
cfoHz = lineFit(1) / (2 * pi);
end

function indices = workFieldToRxIndices(workRange, fsWork, fsRx, available)
first = round((workRange(1) - 1) * fsRx / fsWork) + 1;
last = min(available, round(workRange(2) * fsRx / fsWork));
if first > last || first < 1
    indices = [];
else
    indices = first:last;
end
end

function [model, phrGain, payloadGain] = selectFieldModel( ...
        baseline, received, phrIdx, payloadIdx, mode, fixedScale)
model = baseline;
fields = {phrIdx, payloadIdx};
gains = complex(ones(2, 1));
for k = 1:2
    idx = fields{k};
    if isempty(idx)
        continue
    end
    m = baseline(idx);
    r = received(idx);
    switch lower(mode)
        case 'baseline'
            gains(k) = 1;
        case {'fixed_scale', 'fixed_0p8'}
            gains(k) = fixedScale;
        case 'optimal_real'
            gains(k) = real(m' * r) / (real(m' * m) + eps);
        case 'optimal_complex'
            gains(k) = (m' * r) / (m' * m + eps);
        otherwise
            error('cancel_uwb_packet_in_iq:Mode', ...
                'Unknown cancellation mode: %s', mode);
    end
    model(idx) = gains(k) * m;
end
phrGain = gains(1);
payloadGain = gains(2);
end

function corrected = applyCirSecondStageCfo(replica, periodSamples, diagnostics)
if ~isfield(diagnostics, 'second_stage_cfo_applied') || ...
        ~diagnostics.second_stage_cfo_applied
    corrected = replica;
    return
end
firstSample = round((diagnostics.first_repetition - 1) * periodSamples) + 1;
if firstSample > numel(replica)
    corrected = replica;
    return
end
samplePhase = zeros(numel(replica), 1);
sampleOffsetRepetitions = ((firstSample:numel(replica)).' - ...
    firstSample) / periodSamples;
samplePhase(firstSample:end) = ...
    diagnostics.linear_phase_slope_rad_per_repetition * ...
    sampleOffsetRepetitions;
corrected = replica .* exp(1j * samplePhase);
end

function corrected = applyRepetitionPhaseCurve( ...
        replica, periodSamples, phaseByRepetitionRad)
samplePhase = zeros(numel(replica), 1);
for repetition = 1:numel(phaseByRepetitionRad)
    phase = phaseByRepetitionRad(repetition);
    if phase == 0
        continue
    end
    firstSample = round((repetition - 1) * periodSamples) + 1;
    lastSample = min(numel(replica), round(repetition * periodSamples));
    if firstSample <= lastSample
        samplePhase(firstSample:lastSample) = phase;
    end
end
corrected = replica .* exp(1j * samplePhase);
end

function diagnostics = emptyCirSlowDiagnostics()
diagnostics = struct( ...
    'applied', false, ...
    'second_stage_cfo_applied', false, ...
    'first_repetition', 0, ...
    'last_repetition', 0, ...
    'linear_phase_slope_rad_per_repetition', NaN);
end
