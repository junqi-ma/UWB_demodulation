function diagnostics = analyzeCirInterference(cir, options)
%ANALYZECIRINTERFERENCE Detect communication-frame energy in a QM35 CIR.
%   DIAGNOSTICS = ANALYZECIRINTERFERENCE(CIR) scores First-Path-early
%   per-repetition clusters (v2 default) and still computes v1 occupancy /
%   residual on the legacy early window for comparison and rollback.
%
%   DIAGNOSTICS = ANALYZECIRINTERFERENCE(CIR, OPTIONS) overrides detector
%   fields. OPTIONS.classifier is "cluster" (default) or "occupancy".
%   Thresholds were locked on qm35_gain1 scheduled dump (code 9, M=54).
%
%   The detector uses per-repetition CIR only. Coherent-average CIR taps
%   are reconstructed as mean(individual, 2) so the L2-normalized
%   CIR.values used by CMF is never mixed into the variance formula.
%
%   See also LOCATECIRFIRSTPEAK, ESTIMATECIR, DECODE_SCHEDULED_SC16_DUMP.

if nargin < 1 || ~isstruct(cir)
    error('analyzeCirInterference:InvalidCir', ...
        'CIR must be a structure from estimateCir.');
end
if nargin < 2 || isempty(options)
    options = struct();
end
options = mergeDetectorOptions(options);
diagnostics = emptyDiagnostics(options);

[individual, delayNs, source] = selectIndividualCir(cir);
if isempty(individual)
    diagnostics.reason = "missing_individual_cir";
    return
end
if size(individual, 1) ~= numel(delayNs)
    diagnostics.reason = "delay_axis_mismatch";
    return
end

H = double(individual);
hBar = mean(H, 2);
residualPower = max(0, mean(abs(H).^2, 2) - abs(hBar).^2);
powerBar = abs(hBar).^2;

diagnostics.residual_power = residualPower;
diagnostics.delay_ns = delayNs(:);
diagnostics.individual_values = H;
diagnostics.cir_source = source;
diagnostics.coherent_cir = hBar;

[firstPathIndex, firstPathReason] = locateFirstPath(powerBar, delayNs, options);
if isempty(firstPathIndex)
    diagnostics.reason = firstPathReason;
    return
end

firstPathDelayNs = delayNs(firstPathIndex);
[firstPeakIndex, firstPeakDelayNs, firstPeakPower] = ...
    uwbdecoder.locateCirFirstPeak(powerBar, delayNs, firstPathDelayNs);

legacyLast = firstPathIndex - options.guard_samples;
legacyIndices = (1:max(0, legacyLast)).';
nLegacy = numel(legacyIndices);
decisionIndices = find(delayNs(:) < (firstPathDelayNs - options.early_guard_ns));
nDecision = numel(decisionIndices);

diagnostics.first_path_index = firstPathIndex;
diagnostics.first_path_delay_ns = firstPathDelayNs;
diagnostics.first_path_power = powerBar(firstPathIndex);
diagnostics.first_peak_index = firstPeakIndex;
diagnostics.first_peak_delay_ns = firstPeakDelayNs;
diagnostics.first_peak_power = firstPeakPower;
diagnostics.early_indices = decisionIndices;
diagnostics.legacy_early_indices = legacyIndices;
diagnostics.early_tap_count = nDecision;
diagnostics.early_guard_ns = options.early_guard_ns;

useOccupancy = options.classifier == "occupancy";
if useOccupancy
    if nLegacy < options.min_early_taps
        diagnostics.early_tap_count = nLegacy;
        diagnostics.reason = "insufficient_early_taps";
        return
    end
else
    if nDecision < options.min_early_taps
        diagnostics.reason = "insufficient_early_taps";
        return
    end
end

if nLegacy >= options.min_early_taps
    diagnostics = fillLegacyFeatures(diagnostics, H, residualPower, ...
        powerBar, legacyIndices, firstPathIndex, options);
end

if nDecision >= options.min_early_taps && isfinite(firstPeakPower)
    [clusterN, hitMask, maxRun, maxDb, earlyPeakDb] = clusterHits( ...
        H, decisionIndices, powerBar, firstPeakPower, options);
    diagnostics.cluster_n = clusterN;
    diagnostics.cluster_hit_mask = hitMask;
    diagnostics.cluster_max_run_taps = maxRun;
    diagnostics.cluster_max_peak_db = maxDb;
    diagnostics.coherent_early_peak_db = earlyPeakDb;
end

if useOccupancy
    state = classifyState(diagnostics.early_residual_ratio_db, ...
        diagnostics.early_peak_ratio_db, ...
        diagnostics.interference_occupancy, options);
    confidence = occupancyConfidence(state, ...
        diagnostics.early_residual_ratio_db, ...
        diagnostics.early_peak_ratio_db, ...
        diagnostics.interference_occupancy, options);
else
    state = classifyCluster(diagnostics.cluster_n, options);
    confidence = clusterConfidence(state, diagnostics.cluster_n, ...
        diagnostics.cluster_max_run_taps, size(H, 2), options);
end

diagnostics.valid = true;
diagnostics.reason = "ok";
diagnostics.state = state;
diagnostics.interfered = state == "interfered";
diagnostics.sic_recommended = state == "interfered" || state == "suspected";
diagnostics.confidence = confidence;
end

function options = mergeDetectorOptions(options)
defaults = struct( ...
    'classifier', "cluster", ...
    'early_guard_ns', 10, ...
    'hit_run_taps', 3, ...
    'hit_threshold_db', -40, ...
    'cluster_interfered_n', 5, ...
    'cluster_suspected_n', 1, ...
    'guard_samples', 6, ...
    'detector_version', 2, ...
    'min_early_taps', 16, ...
    'first_path_k', 6, ...
    'first_path_consecutive_taps', 2, ...
    'first_path_search_radius', 32, ...
    'first_path_baseline_taps', 16, ...
    'first_path_min_peak_fraction', 1e-2, ...
    'signal_post_samples', 24, ...
    'occupancy_low_fraction', 0.25, ...
    'occupancy_background_margin_db', 5, ...
    'occupancy_threshold', 0.20, ...
    'peak_percentile', 100, ...
    'residual_threshold_db', -25, ...
    'peak_threshold_db', -15);
names = fieldnames(defaults);
for k = 1:numel(names)
    name = names{k};
    if ~isfield(options, name) || isempty(options.(name))
        options.(name) = defaults.(name);
    end
end
if ~(isstring(options.classifier) || ischar(options.classifier))
    error('analyzeCirInterference:UnknownClassifier', ...
        'classifier must be "cluster" or "occupancy".');
end
options.classifier = lower(string(options.classifier));
if options.classifier ~= "cluster" && options.classifier ~= "occupancy"
    error('analyzeCirInterference:UnknownClassifier', ...
        'classifier must be "cluster" or "occupancy", got %s.', ...
        options.classifier);
end
% Caller must not pretend this function is still the v1 detector.
options.detector_version = 2;
end

function diagnostics = emptyDiagnostics(options)
diagnostics = struct( ...
    'valid', false, ...
    'reason', "uninitialized", ...
    'detector_version', options.detector_version, ...
    'classifier', options.classifier, ...
    'first_path_index', NaN, ...
    'first_path_delay_ns', NaN, ...
    'first_path_power', NaN, ...
    'first_peak_index', NaN, ...
    'first_peak_delay_ns', NaN, ...
    'first_peak_power', NaN, ...
    'early_tap_count', 0, ...
    'early_guard_ns', options.early_guard_ns, ...
    'early_noise_power', NaN, ...
    'early_residual_power', NaN, ...
    'signal_power', NaN, ...
    'peak_signal_power', NaN, ...
    'early_residual_ratio_db', NaN, ...
    'early_peak_ratio_db', NaN, ...
    'early_residual_ratio_peak_db', NaN, ...
    'coherent_early_peak_db', NaN, ...
    'interference_occupancy', NaN, ...
    'state', "invalid", ...
    'interfered', false, ...
    'sic_recommended', false, ...
    'confidence', 0, ...
    'cluster_n', NaN, ...
    'cluster_hit_mask', false(1, 0), ...
    'cluster_max_run_taps', NaN, ...
    'cluster_max_peak_db', NaN, ...
    'residual_power', [], ...
    'repetition_early_power', [], ...
    'early_indices', [], ...
    'legacy_early_indices', [], ...
    'signal_indices', [], ...
    'repetition_threshold', NaN, ...
    'background_noise_power', NaN, ...
    'delay_ns', [], ...
    'coherent_cir', [], ...
    'individual_values', [], ...
    'cir_source', "", ...
    'options', options);
end

function diagnostics = fillLegacyFeatures(diagnostics, H, residualPower, ...
        powerBar, legacyIndices, firstPathIndex, options)
hBar = diagnostics.coherent_cir;
signalLast = min(numel(hBar), firstPathIndex + options.signal_post_samples);
signalIndices = (firstPathIndex:signalLast).';
earlyResidual = residualPower(legacyIndices);
signalPower = max(powerBar(signalIndices));
peakSignalPower = max(powerBar);

earlyResidualPower = median(earlyResidual);
earlyPeakPower = residualPercentile(earlyResidual, options.peak_percentile);
earlyNoisePower = median(mean(abs(H(legacyIndices, :)).^2, 2));

earlyResidualRatio = earlyResidualPower / (signalPower + eps);
earlyPeakRatio = earlyPeakPower / (signalPower + eps);
earlyResidualRatioPeak = earlyResidualPower / (peakSignalPower + eps);

repetitionEarlyPower = median(abs(H(legacyIndices, :)).^2, 1).';
[occupancy, repetitionThreshold, backgroundNoisePower] = repetitionOccupancy( ...
    repetitionEarlyPower, options);

diagnostics.early_noise_power = earlyNoisePower;
diagnostics.early_residual_power = earlyResidualPower;
diagnostics.signal_power = signalPower;
diagnostics.peak_signal_power = peakSignalPower;
diagnostics.early_residual_ratio_db = toDb(earlyResidualRatio);
diagnostics.early_peak_ratio_db = toDb(earlyPeakRatio);
diagnostics.early_residual_ratio_peak_db = toDb(earlyResidualRatioPeak);
diagnostics.interference_occupancy = occupancy;
diagnostics.signal_indices = signalIndices;
diagnostics.repetition_early_power = repetitionEarlyPower;
diagnostics.repetition_threshold = repetitionThreshold;
diagnostics.background_noise_power = backgroundNoisePower;
end

function [clusterN, hitMask, maxRun, maxDb, earlyPeakDb] = clusterHits( ...
        H, decisionIndices, powerBar, firstPeakPower, options)
nRep = size(H, 2);
hitMask = false(1, nRep);
clusterN = 0;
maxRun = 0;
maxDb = -Inf;
earlyPeakDb = NaN;
if isempty(decisionIndices) || ~isfinite(firstPeakPower)
    return
end

rho = abs(H(decisionIndices, :)).^2 / (firstPeakPower + eps);
maxDb = toDb(max(rho(:)));
earlyPeakDb = toDb(max(powerBar(decisionIndices)) / (firstPeakPower + eps));
above = rho > 10^(options.hit_threshold_db / 10);
runNeed = max(1, round(options.hit_run_taps));
kernel = ones(runNeed, 1);
for m = 1:nRep
    col = above(:, m);
    runM = longestTrueRun(col);
    if runM > maxRun
        maxRun = runM;
    end
    if numel(col) >= runNeed && any(conv(double(col), kernel, 'valid') >= runNeed)
        hitMask(m) = true;
    end
end
clusterN = nnz(hitMask);
end

function runLen = longestTrueRun(mask)
mask = mask(:);
if isempty(mask) || ~any(mask)
    runLen = 0;
    return
end
padded = [false; mask; false];
edges = diff(padded);
starts = find(edges == 1);
stops = find(edges == -1);
runLen = max(stops - starts);
end

function state = classifyCluster(clusterN, options)
if ~isfinite(clusterN)
    state = "invalid";
elseif clusterN >= options.cluster_interfered_n
    state = "interfered";
elseif clusterN >= options.cluster_suspected_n
    state = "suspected";
else
    state = "clean";
end
end

function confidence = clusterConfidence(state, clusterN, maxRun, nRep, options)
switch state
    case "interfered"
        confidence = saturate(0.55 + 0.45 * (clusterN - options.cluster_interfered_n) / ...
            max(nRep - options.cluster_interfered_n, 1));
    case "suspected"
        confidence = saturate(0.35 + 0.10 * clusterN);
    case "clean"
        if maxRun == 0
            confidence = 0.85;
        else
            confidence = 0.70;
        end
    otherwise
        confidence = 0;
end
end

function [individual, delayNs, source] = selectIndividualCir(cir)
individual = [];
delayNs = [];
source = "";
if isfield(cir, 'diag_individual_values') && ...
        ~isempty(cir.diag_individual_values)
    individual = cir.diag_individual_values;
    if isfield(cir, 'diag_delay_ns')
        delayNs = cir.diag_delay_ns(:);
    end
    source = "diag_individual_values";
    return
end
if isfield(cir, 'individual_values') && ~isempty(cir.individual_values)
    individual = cir.individual_values;
    if isfield(cir, 'delay_ns')
        delayNs = cir.delay_ns(:);
    end
    source = "individual_values";
end
end

function [firstPathIndex, reason] = locateFirstPath(powerBar, delayNs, options)
firstPathIndex = [];
reason = "first_path_not_found";
nTap = numel(powerBar);
if nTap < 3
    return
end

[~, nominalZero] = min(abs(delayNs(:)));
baselineCount = min(options.first_path_baseline_taps, ...
    max(1, nominalZero - options.guard_samples));
if baselineCount < 4
    reason = "first_path_baseline_too_short";
    return
end
baselinePower = powerBar(1:baselineCount);
baselineMed = median(baselinePower);
baselineMad = medianAbsDeviation(baselinePower);
threshold = baselineMed + options.first_path_k * max(baselineMad, eps);
threshold = max(threshold, max(powerBar) * options.first_path_min_peak_fraction);

searchLo = max(1, nominalZero - options.first_path_search_radius);
searchHi = min(nTap, nominalZero + options.first_path_search_radius);
need = max(1, round(options.first_path_consecutive_taps));
runLength = 0;
for idx = searchLo:searchHi
    if powerBar(idx) > threshold
        runLength = runLength + 1;
        if runLength >= need
            firstPathIndex = idx - need + 1;
            reason = "ok";
            return
        end
    else
        runLength = 0;
    end
end
end

function [occupancy, threshold, background] = repetitionOccupancy( ...
        earlyPower, options)
earlyPower = earlyPower(:);
nRep = numel(earlyPower);
if nRep < 1
    occupancy = NaN;
    threshold = NaN;
    background = NaN;
    return
end
sortedPower = sort(earlyPower);
lowCount = max(1, round(options.occupancy_low_fraction * nRep));
lowPower = sortedPower(1:lowCount);
background = median(lowPower);
threshold = max(background, eps) * ...
    10^(options.occupancy_background_margin_db / 10);
occupancy = nnz(earlyPower > threshold) / nRep;
end

function state = classifyState(residualDb, peakDb, occupancy, options)
strongResidual = residualDb > options.residual_threshold_db;
highOccupancy = occupancy > options.occupancy_threshold;
impulsivePeak = peakDb > options.peak_threshold_db;
if highOccupancy
    state = "interfered";
elseif strongResidual || impulsivePeak
    state = "suspected";
else
    state = "clean";
end
end

function confidence = occupancyConfidence(state, residualDb, peakDb, ...
        occupancy, options)
resMargin = (residualDb - options.residual_threshold_db) / 6;
peakMargin = (peakDb - options.peak_threshold_db) / 6;
occMargin = (occupancy - options.occupancy_threshold) / ...
    max(options.occupancy_threshold, eps);
switch state
    case "interfered"
        confidence = saturate(0.55 + 0.45 * mean([ ...
            saturate(resMargin), saturate(occMargin)]));
    case "suspected"
        confidence = saturate(0.35 + 0.35 * max([resMargin, ...
            min(peakMargin, occMargin)]));
    case "clean"
        confidence = saturate(0.75 - 0.45 * max([resMargin, ...
            peakMargin, occMargin]));
    otherwise
        confidence = 0;
end
end

function value = residualPercentile(x, percentile)
x = x(:);
if isempty(x)
    value = NaN;
    return
end
if percentile >= 100
    value = max(x);
    return
end
ranked = sort(x);
index = max(1, min(numel(ranked), ceil(percentile / 100 * numel(ranked))));
value = ranked(index);
end

function y = medianAbsDeviation(x)
x = x(:);
y = median(abs(x - median(x)));
end

function db = toDb(value)
db = 10 * log10(value + eps);
end

function y = saturate(x)
y = min(1, max(0, x));
end
