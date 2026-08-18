function [rxOut, report] = cancel_uwb_preamble_in_iq( ...
        rx, preamble, cir, txOptions, opts)
%CANCEL_UWB_PREAMBLE_IN_IQ Subtract a SYNC-only replica from work-rate IQ.
%   [RXOUT, REPORT] = CANCEL_UWB_PREAMBLE_IN_IQ(RX, PREAMBLE, CIR,
%   TXOPTIONS, OPTS) rebuilds the visible SYNC repetitions (not 256 if 256
%   do not fit), applies the estimated CIR, fits alignment / CFO / complex
%   gain on the visible SYNC span, and subtracts only that span. No PHR /
%   PSDU / FCS is generated, so clipped dump windows whose SFD / PHR fall
%   outside the window can still be cancelled.
%
%   TXOPTIONS needs code_index, visible_reps, fs_tx, phy_mode,
%   peak_amplitude, guard_samples. OPTS defaults come from
%   fillPreambleCancelOptions; min_alignment_correlation stays 0.70.
%
%   The alignment / CFO / fractional-shift local functions are copied from
%   cancel_uwb_packet_in_iq.m so the full-packet 0.70 path stays untouched.
%
%   See also CANCEL_UWB_PACKET_IN_IQ, ESTIMATE_UWB_PREAMBLE_CIR,
%   FIND_DW_PREAMBLE_CANDIDATES_ON_WINDOW.

if nargin < 4 || isempty(txOptions) || ~isfield(txOptions, 'visible_reps')
    error('cancel_uwb_preamble_in_iq:Usage', ...
        'usage: [rx, report] = cancel_uwb_preamble_in_iq(rx, preamble, cir, txOptions, opts)');
end
if nargin < 5 || isempty(opts)
    opts = struct();
end

visible = double(txOptions.visible_reps);
opts = fillPreambleCancelOptions(opts, visible);

if visible < opts.min_visible_sync_for_preamble_sic
    error('cancel_uwb_preamble_in_iq:TooFewSync', ...
        'Visible SYNC repetitions %d is below the %d minimum.', ...
        visible, opts.min_visible_sync_for_preamble_sic);
end

rx = rx(:);
fs = opts.fs_rx;
c = uwbdecoder.constants();
periodRx = c.PREAMBLE_PERIOD_S * fs;

tx = buildSyncOnlyTx(txOptions, visible);
channel = apply_estimated_cir_to_uwb(tx, cir);
replica = channel.waveform_x410(:);

nominalStart = packetStartSample(preamble);
if ~(isfinite(nominalStart) && nominalStart >= 1 && ...
        nominalStart <= numel(rx))
    error('cancel_uwb_preamble_in_iq:BadStart', ...
        'Preamble start %g is outside the IQ window 1:%d.', ...
        nominalStart, numel(rx));
end

[startLocal, integerCorr] = alignReplica( ...
    rx, replica, round(nominalStart), periodRx, ...
    opts.alignment_search_samples, opts.gain_fit_first_sync, ...
    opts.alignment_template_syncs);

need = round(visible * periodRx);
available = min(numel(replica), numel(rx) - startLocal + 1);
if available < round(opts.min_visible_sync_for_preamble_sic * periodRx)
    error('cancel_uwb_preamble_in_iq:ShortWindow', ...
        'Visible SYNC span %d is shorter than %d samples.', ...
        available, round(opts.min_visible_sync_for_preamble_sic * periodRx));
end
replica = replica(1:available);
observed = rx(startLocal:startLocal + available - 1);

initialCfoHz = fitReplicaCfo(observed, replica, periodRx, ...
    opts.cfo_fit_first_sync, opts.cfo_fit_last_sync, fs);
if abs(initialCfoHz) > opts.max_abs_cfo_hz
    error('cancel_uwb_preamble_in_iq:CfoLimit', ...
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
    error('cancel_uwb_preamble_in_iq:CfoLimit', ...
        'Fitted CFO %+.3f kHz exceeds the safety limit.', ...
        fittedCfoHz / 1e3);
end
replicaCfo = replica .* exp(1j * 2 * pi * fittedCfoHz * n / fs);

if alignCorr < opts.min_alignment_correlation
    error('cancel_uwb_preamble_in_iq:Alignment', ...
        'Fractional alignment correlation %.3f is below %.3f.', ...
        alignCorr, opts.min_alignment_correlation);
end

% Complex gain is fitted only over the visible SYNC span; there are no PHR
% or payload fields to model.
gainFirst = round((opts.gain_fit_first_sync - 1) * periodRx) + 1;
gainLast = min(available, round(opts.gain_fit_last_sync * periodRx));
gainIdx = gainFirst:gainLast;
globalGain = (replicaCfo(gainIdx)' * observed(gainIdx)) / ...
    (replicaCfo(gainIdx)' * replicaCfo(gainIdx) + eps);
baseline = globalGain * replicaCfo;

residual = observed - baseline;
suppressionDb = 10 * log10( ...
    mean(abs(observed).^2) / (mean(abs(residual).^2) + eps));
if suppressionDb < opts.min_frame_suppression_db
    error('cancel_uwb_preamble_in_iq:Suppression', ...
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
report.frame_suppression_db = suppressionDb;
report.cir_slow_phase_applied = false;
report.full_packet_sfo_applied = false;
report.cancel_mode = "preamble";
report.visible_reps = visible;
end

function opts = fillPreambleCancelOptions(opts, visible)
defaults = struct( ...
    'fs_rx', 998.4e6, ...
    'alignment_search_samples', 128, ...
    'alignment_template_syncs', 32, ...
    'cfo_fit_first_sync', 25, ...
    'cfo_fit_last_sync', visible, ...
    'gain_fit_first_sync', 25, ...
    'gain_fit_last_sync', visible, ...
    'fractional_alignment_max_samples', 0.75, ...
    'fractional_alignment_coarse_step', 0.10, ...
    'fractional_alignment_fine_step', 0.003, ...
    'fractional_alignment_min_improvement', 5e-4, ...
    'min_alignment_correlation', 0.70, ...
    'min_frame_suppression_db', 0.20, ...
    'max_abs_cfo_hz', 100e3, ...
    'enable_cir_slow_phase', false, ...
    'enable_full_packet_sfo', false, ...
    'min_visible_sync_for_preamble_sic', 64);
names = fieldnames(defaults);
for k = 1:numel(names)
    if ~isfield(opts, names{k}) || isempty(opts.(names{k}))
        opts.(names{k}) = defaults.(names{k});
    end
end
% Force off even when the caller copied dwProfile.cancel (full-packet
% fillCancelOptions defaults these two flags to true).
opts.enable_full_packet_sfo = false;
opts.enable_cir_slow_phase = false;
if opts.cfo_fit_first_sync > visible
    opts.cfo_fit_first_sync = 1;
end
if opts.gain_fit_first_sync > visible
    opts.gain_fit_first_sync = 1;
end
opts.cfo_fit_last_sync = visible;
opts.gain_fit_last_sync = visible;
if opts.alignment_template_syncs > visible
    opts.alignment_template_syncs = visible;
end
end

function tx = buildSyncOnlyTx(txOptions, visible)
cfg = lrwpanHRPConfig(Mode='802.15.4a', MeanPRF=62.4, ...
    DataRate=6.81, SamplesPerPulse=2, ...
    CodeIndex=txOptions.code_index, PreambleDuration=64, ...
    Ranging=true, PSDULength=1);
[~, pulseSymbols] = lrwpanWaveformGenerator(zeros(8, 1), cfg);
indices = lrwpanHRPFieldIndices(cfg);
samplesPerSync = (indices.SYNC(2) - indices.SYNC(1) + 1) / cfg.PreambleDuration;
symbolsPerSync = samplesPerSync / cfg.SamplesPerPulse;
syncPulseSymbols = pulseSymbols(1:round(symbolsPerSync));
pulseSymbolsWork = repmat(syncPulseSymbols, visible, 1);
pulseImpulsesWork = zeros(numel(pulseSymbolsWork) * cfg.SamplesPerPulse, 1);
pulseImpulsesWork(1:cfg.SamplesPerPulse:end) = pulseSymbolsWork;

tx = struct();
tx.pulse_impulses_work = pulseImpulsesWork;
tx.sample_rate_work = cfg.SampleRate;
tx.sample_rate_tx = cfg.SampleRate;
tx.digital_offset_hz = 0;
tx.guard_samples = 0;
tx.preamble_repetitions = visible;
end

function startSample = packetStartSample(preamble)
startSample = NaN;
if isfield(preamble, 'start_sample_uncropped') && ...
        ~isempty(preamble.start_sample_uncropped)
    startSample = double(preamble.start_sample_uncropped);
    return
end
if isfield(preamble, 'start_sample')
    startSample = double(preamble.start_sample);
end
end

% -------------------------------------------------------------------------
% Alignment / CFO / fractional-shift helpers copied from
% cancel_uwb_packet_in_iq.m (L224-L330). Keep the two 0.70 gates in sync.
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