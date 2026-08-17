function diagnostics = analyzeCirInterference(cir, options)
%ANALYZECIRINTERFERENCE Detect communication-frame energy in a QM35 CIR.
%   DIAGNOSTICS = ANALYZECIRINTERFERENCE(CIR) scores First-Path-early
%   noncoherent residual power, impulsive residual peaks, and the fraction
%   of SYNC repetitions whose early window is elevated.
%
%   DIAGNOSTICS = ANALYZECIRINTERFERENCE(CIR, OPTIONS) overrides detector
%   fields. Thresholds are provisional until a labeled capture is used to
%   calibrate them; they are not a final SIC policy.
%
%   The detector uses per-repetition CIR only. Coherent-average CIR taps
%   are reconstructed as mean(individual, 2) so the L2-normalized
%   CIR.values used by CMF is never mixed into the variance formula.
%
%   See also ESTIMATECIR, DECODE_SCHEDULED_SC16_DUMP.

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

[firstPathIndex, firstPathReason] = locateFirstPath(powerBar, delayNs, options);
if isempty(firstPathIndex)
    diagnostics.reason = firstPathReason;
    return
end

earlyLast = firstPathIndex - options.guard_samples;
if earlyLast < options.min_early_taps
    diagnostics.first_path_index = firstPathIndex;
    diagnostics.first_path_delay_ns = delayNs(firstPathIndex);
    diagnostics.first_path_power = powerBar(firstPathIndex);
    diagnostics.early_tap_count = max(0, earlyLast);
    diagnostics.reason = "insufficient_early_taps";
    return
end

earlyIndices = (1:earlyLast).';
signalLast = min(numel(hBar), firstPathIndex + options.signal_post_samples);
signalIndices = (firstPathIndex:signalLast).';
earlyResidual = residualPower(earlyIndices);
signalPower = max(powerBar(signalIndices));
peakSignalPower = max(powerBar);

earlyResidualPower = median(earlyResidual);
earlyPeakPower = residualPercentile(earlyResidual, options.peak_percentile);
earlyNoisePower = median(mean(abs(H(earlyIndices, :)).^2, 2));

earlyResidualRatio = earlyResidualPower / (signalPower + eps);
earlyPeakRatio = earlyPeakPower / (signalPower + eps);
earlyResidualRatioPeak = earlyResidualPower / (peakSignalPower + eps);

repetitionEarlyPower = median(abs(H(earlyIndices, :)).^2, 1).';
[occupancy, repetitionThreshold, backgroundNoisePower] = repetitionOccupancy( ...
    repetitionEarlyPower, options, signalPower);

earlyResidualRatioDb = toDb(earlyResidualRatio);
earlyPeakRatioDb = toDb(earlyPeakRatio);
state = classifyState(earlyResidualRatioDb, earlyPeakRatioDb, ...
    occupancy, options);
confidence = stateConfidence(state, earlyResidualRatioDb, ...
    earlyPeakRatioDb, occupancy, options);

diagnostics.valid = true;
diagnostics.reason = "ok";
diagnostics.first_path_index = firstPathIndex;
diagnostics.first_path_delay_ns = delayNs(firstPathIndex);
diagnostics.first_path_power = powerBar(firstPathIndex);
diagnostics.early_tap_count = numel(earlyIndices);
diagnostics.early_noise_power = earlyNoisePower;
diagnostics.early_residual_power = earlyResidualPower;
diagnostics.signal_power = signalPower;
diagnostics.peak_signal_power = peakSignalPower;
diagnostics.early_residual_ratio_db = earlyResidualRatioDb;
diagnostics.early_peak_ratio_db = earlyPeakRatioDb;
diagnostics.early_residual_ratio_peak_db = toDb(earlyResidualRatioPeak);
diagnostics.interference_occupancy = occupancy;
diagnostics.state = state;
diagnostics.interfered = state == "interfered";
diagnostics.sic_recommended = state == "interfered" || state == "suspected";
diagnostics.confidence = confidence;
diagnostics.early_indices = earlyIndices;
diagnostics.signal_indices = signalIndices;
diagnostics.repetition_early_power = repetitionEarlyPower;
diagnostics.repetition_threshold = repetitionThreshold;
diagnostics.background_noise_power = backgroundNoisePower;
diagnostics.coherent_cir = hBar;
end

function options = mergeDetectorOptions(options)
defaults = struct( ...
    'guard_samples', 6, ...
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
end

function diagnostics = emptyDiagnostics(options)
diagnostics = struct( ...
    'valid', false, ...
    'reason', "uninitialized", ...
    'first_path_index', NaN, ...
    'first_path_delay_ns', NaN, ...
    'first_path_power', NaN, ...
    'early_tap_count', 0, ...
    'early_noise_power', NaN, ...
    'early_residual_power', NaN, ...
    'signal_power', NaN, ...
    'peak_signal_power', NaN, ...
    'early_residual_ratio_db', NaN, ...
    'early_peak_ratio_db', NaN, ...
    'early_residual_ratio_peak_db', NaN, ...
    'interference_occupancy', NaN, ...
    'state', "invalid", ...
    'interfered', false, ...
    'sic_recommended', false, ...
    'confidence', 0, ...
    'residual_power', [], ...
    'repetition_early_power', [], ...
    'early_indices', [], ...
    'signal_indices', [], ...
    'repetition_threshold', NaN, ...
    'background_noise_power', NaN, ...
    'delay_ns', [], ...
    'coherent_cir', [], ...
    'individual_values', [], ...
    'cir_source', "", ...
    'options', options);
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
        earlyPower, options, signalPower) %#ok<INUSD>
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

function confidence = stateConfidence(state, residualDb, peakDb, ...
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
