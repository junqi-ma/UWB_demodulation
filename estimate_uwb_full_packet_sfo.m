function diagnostics = estimate_uwb_full_packet_sfo( ...
        observed, model, fs, options)
%ESTIMATE_UWB_FULL_PACKET_SFO Estimate affine delay drift over one packet.
%   DIAGNOSTICS = ESTIMATE_UWB_FULL_PACKET_SFO(OBSERVED, MODEL, FS,
%   OPTIONS) measures a local fractional delay in uniformly spaced packet
%   windows and robustly fits
%
%       delay_samples[n] = intercept + slope * n.
%
%   slope*1e6 is the residual SFO in ppm. Reliability gates prevent a
%   time warp when the delay line is weak, noisy, or implausibly large.

if nargin < 4 || isempty(options)
    options = struct();
end
options = fillOptions(options);
diagnostics = emptyDiagnostics();
sampleCount = min(numel(observed), numel(model));
if sampleCount < 4
    diagnostics.message = 'Packet is too short for SFO estimation.';
    return
end
observed = observed(1:sampleCount);
model = model(1:sampleCount);
windowSamples = max(64, round( ...
    options.window_duration_us * 1e-6 * fs));
overallModelRms = rms(abs(model));
centers = zeros(ceil(sampleCount / windowSamples), 1);
delays = zeros(size(centers));
correlations = zeros(size(centers));
validCount = 0;
for firstSample = 1:windowSamples:sampleCount
    lastSample = min(sampleCount, firstSample + windowSamples - 1);
    if lastSample - firstSample + 1 < 0.5 * windowSamples
        continue
    end
    windowModel = model(firstSample:lastSample);
    if rms(abs(windowModel)) < ...
            options.minimum_relative_model_rms * overallModelRms
        continue
    end
    windowObserved = observed(firstSample:lastSample);
    [delay, correlation] = estimateWindowDelay( ...
        windowObserved, windowModel, options);
    if ~isfinite(delay) || ~isfinite(correlation) || ...
            correlation < options.minimum_window_correlation
        continue
    end
    if abs(delay) >= options.maximum_abs_window_delay_samples - ...
            options.fine_delay_step_samples
        continue
    end
    validCount = validCount + 1;
    centers(validCount) = ((firstSample + lastSample) / 2) - 1;
    delays(validCount) = delay;
    correlations(validCount) = correlation;
end
centers = centers(1:validCount);
delays = delays(1:validCount);
correlations = correlations(1:validCount);
diagnostics.valid_window_count = validCount;
diagnostics.window_center_samples = centers;
diagnostics.window_delay_samples = delays;
diagnostics.window_correlation = correlations;
if validCount < options.minimum_valid_windows
    diagnostics.message = sprintf( ...
        'Only %d valid SFO windows are available.', validCount);
    return
end

weights = correlations .^ 4;
[coefficients, fitted] = weightedAffineFit(centers, delays, weights);
residual = delays - fitted;
residualMedian = median(residual);
robustScale = 1.4826 * median(abs(residual - residualMedian));
inlierThreshold = max(3 * robustScale, ...
    3 * options.fine_delay_step_samples);
inliers = abs(residual - residualMedian) <= inlierThreshold;
if nnz(inliers) >= options.minimum_valid_windows && ~all(inliers)
    centers = centers(inliers);
    delays = delays(inliers);
    correlations = correlations(inliers);
    weights = correlations .^ 4;
    [coefficients, fitted] = weightedAffineFit( ...
        centers, delays, weights);
    residual = delays - fitted;
end

delayIntercept = coefficients(1);
delaySlope = coefficients(2);
sfoPpm = delaySlope * 1e6;
totalDrift = delaySlope * (sampleCount - 1);
fitResidualRms = sqrt(sum(weights .* residual .^ 2) / ...
    (sum(weights) + eps));
weightedMeanDelay = sum(weights .* delays) / (sum(weights) + eps);
totalVariation = sum(weights .* ...
    (delays - weightedMeanDelay) .^ 2);
unexplainedVariation = sum(weights .* residual .^ 2);
explainedFraction = max(0, 1 - unexplainedVariation / ...
    (totalVariation + eps));
isReliable = abs(sfoPpm) <= options.maximum_abs_sfo_ppm && ...
    abs(totalDrift) >= options.minimum_total_drift_samples && ...
    fitResidualRms <= options.maximum_fit_residual_samples && ...
    explainedFraction >= options.minimum_explained_fraction;

diagnostics.applied = isReliable;
diagnostics.sfo_ppm = sfoPpm;
diagnostics.delay_intercept_samples = delayIntercept;
diagnostics.delay_slope_samples_per_sample = delaySlope;
diagnostics.total_drift_samples = totalDrift;
diagnostics.fit_residual_rms_samples = fitResidualRms;
diagnostics.explained_fraction = explainedFraction;
diagnostics.inlier_window_count = numel(delays);
if isReliable
    diagnostics.message = '';
else
    diagnostics.message = sprintf( ...
        ['Rejected SFO: %+.3f ppm, drift %+.4f sample, ', ...
        'fit RMS %.4f, explained %.3f.'], ...
        sfoPpm, totalDrift, fitResidualRms, explainedFraction);
end
end

function [delay, correlation] = estimateWindowDelay( ...
        observed, model, options)
sampleAxis = (1:numel(model)).';
interpolator = griddedInterpolant( ...
    sampleAxis, model(:), 'spline', 'none');
fitIndices = find(abs(model) >= ...
    options.strong_model_fraction * max(abs(model)));
if numel(fitIndices) < options.minimum_strong_samples
    fitIndices = sampleAxis;
end
fitObserved = observed(fitIndices);
maximumDelay = options.maximum_abs_window_delay_samples;
coarseGrid = (-maximumDelay: ...
    options.coarse_delay_step_samples:maximumDelay).';
coarseScore = delayCorrelationGrid( ...
    fitObserved, interpolator, fitIndices, coarseGrid);
[~, bestIndex] = max(coarseScore);
coarseBest = coarseGrid(bestIndex);
fineFirst = max(-maximumDelay, ...
    coarseBest - options.coarse_delay_step_samples);
fineLast = min(maximumDelay, ...
    coarseBest + options.coarse_delay_step_samples);
fineGrid = (fineFirst:options.fine_delay_step_samples:fineLast).';
fineScore = delayCorrelationGrid( ...
    fitObserved, interpolator, fitIndices, fineGrid);
[correlation, bestIndex] = max(fineScore);
delay = fineGrid(bestIndex);
end

function scores = delayCorrelationGrid( ...
        observed, interpolator, fitIndices, delayGrid)
scores = NaN(size(delayGrid));
observedPower = real(observed' * observed);
for k = 1:numel(delayGrid)
    shifted = interpolator(fitIndices - delayGrid(k));
    shifted(~isfinite(shifted)) = 0;
    modelPower = real(shifted' * shifted);
    scores(k) = abs(shifted' * observed) / ...
        sqrt(modelPower * observedPower + eps);
end
end

function [coefficients, fitted] = weightedAffineFit(x, y, weights)
design = [ones(numel(x), 1), x(:)];
weightedDesign = design .* weights(:);
coefficients = (design' * weightedDesign) \ ...
    (weightedDesign' * y(:));
fitted = design * coefficients;
end

function options = fillOptions(options)
defaults = struct( ...
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
    'minimum_explained_fraction', 0.50);
names = fieldnames(defaults);
for k = 1:numel(names)
    if ~isfield(options, names{k}) || isempty(options.(names{k}))
        options.(names{k}) = defaults.(names{k});
    end
end
end

function diagnostics = emptyDiagnostics()
diagnostics = struct( ...
    'applied', false, ...
    'sfo_ppm', NaN, ...
    'delay_intercept_samples', NaN, ...
    'delay_slope_samples_per_sample', NaN, ...
    'total_drift_samples', NaN, ...
    'valid_window_count', 0, ...
    'inlier_window_count', 0, ...
    'fit_residual_rms_samples', NaN, ...
    'explained_fraction', NaN, ...
    'window_center_samples', [], ...
    'window_delay_samples', [], ...
    'window_correlation', [], ...
    'message', '');
end
