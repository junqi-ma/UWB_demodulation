function [phaseByRepetitionRad, diagnostics] = ...
        estimate_uwb_cir_slow_phase(cir, preambleRepetitions, options)
%ESTIMATE_UWB_CIR_SLOW_PHASE Estimate packet-specific slow phase wander.
%   The estimator projects every repetition CIR onto one fixed dominant
%   path subspace, removes constant phase and linear CFO, and applies a
%   low-degree-of-freedom smoothness prior to the remaining phase. The
%   returned phase is zero outside the repetitions represented by CIR.

if nargin < 3 || isempty(options)
    options = struct();
end
options = fillDefaults(options);

phaseByRepetitionRad = zeros(preambleRepetitions, 1);
diagnostics = emptyDiagnostics();
if ~isstruct(cir) || ~isfield(cir, 'individual_values') || ...
        isempty(cir.individual_values)
    diagnostics.message = 'No individual repetition CIR is available.';
    return
end

individual = double(cir.individual_values);
if size(individual, 2) < options.minimum_repetitions
    diagnostics.message = sprintf( ...
        'Only %d repetition CIRs are available.', size(individual, 2));
    return
end
if isfield(cir, 'first_repetition') && ~isempty(cir.first_repetition)
    firstRepetition = round(double(cir.first_repetition));
else
    firstRepetition = 1;
end
lastRepetition = min(preambleRepetitions, ...
    firstRepetition + size(individual, 2) - 1);
validCount = lastRepetition - firstRepetition + 1;
if validCount < options.minimum_repetitions
    diagnostics.message = 'Too few CIR repetitions fall inside preamble.';
    return
end
individual = individual(:, 1:validCount);

% Select one fixed delay neighborhood for the whole packet. This avoids
% phase jumps caused by choosing a different maximum tap per repetition.
meanMagnitude = mean(abs(individual), 2);
[~, peakTap] = max(meanMagnitude);
firstTap = max(1, peakTap - options.tap_half_width);
lastTap = min(size(individual, 1), peakTap + options.tap_half_width);
pathCir = individual(firstTap:lastTap, :);

% The first left singular vector is the maximum-SNR fixed spatial/delay
% reference. Its arbitrary constant phase is removed by the line fit.
[leftVectors, singularValues, ~] = svd(pathCir, 'econ');
reference = leftVectors(:, 1);
projection = (reference' * pathCir).';
singularPower = diag(singularValues) .^ 2;
subspaceCoherence = singularPower(1) / (sum(singularPower) + eps);

rawPhase = unwrap(angle(projection));
weights = abs(projection) .^ 2;
weights = weights / (median(weights(weights > 0)) + eps);
weights = min(max(weights, options.minimum_weight), ...
    options.maximum_weight);
repetitionAxis = (0:validCount - 1).';

phaseLine = weightedLine(repetitionAxis, rawPhase, weights);
nonlinearPhase = rawPhase - phaseLine;
linearSlopeRadPerRepetition = phaseLine(2) - phaseLine(1);
c = uwbdecoder.constants();
secondStageCfoHz = linearSlopeRadPerRepetition / ...
    (2 * pi * c.PREAMBLE_PERIOD_S);

% Penalized second differences reject repetition-to-repetition noise while
% retaining phase motion on a several-microsecond scale.
secondDifference = diff(eye(validCount), 2);
systemMatrix = diag(weights) + options.smoothing_lambda * ...
    (secondDifference' * secondDifference);
smoothPhase = systemMatrix \ (weights .* nonlinearPhase);

% Ensure that this correction cannot duplicate the complex gain or CFO
% already fitted by the cancellation model.
smoothPhase = smoothPhase - ...
    weightedLine(repetitionAxis, smoothPhase, weights);
maximumCorrectionRad = deg2rad(options.maximum_abs_correction_deg);
smoothPhase = max(-maximumCorrectionRad, ...
    min(maximumCorrectionRad, smoothPhase));

noisePhase = nonlinearPhase - smoothPhase;
nonlinearPower = sum(weights .* nonlinearPhase .^ 2);
unexplainedPower = sum(weights .* noisePhase .^ 2);
explainedFraction = max(0, ...
    1 - unexplainedPower / (nonlinearPower + eps));
correctionRmsDeg = sqrt(sum(weights .* smoothPhase .^ 2) / ...
    sum(weights)) * 180 / pi;
noiseRmsDeg = sqrt(sum(weights .* noisePhase .^ 2) / ...
    sum(weights)) * 180 / pi;

isReliable = isfinite(subspaceCoherence) && ...
    subspaceCoherence >= options.minimum_subspace_coherence && ...
    correctionRmsDeg >= options.minimum_correction_rms_deg && ...
    explainedFraction >= options.minimum_explained_fraction;
isSecondStageCfoReliable = isfinite(subspaceCoherence) && ...
    subspaceCoherence >= options.minimum_subspace_coherence && ...
    isfinite(secondStageCfoHz) && ...
    abs(secondStageCfoHz) <= options.maximum_abs_second_stage_cfo_hz;
if isReliable
    phaseByRepetitionRad(firstRepetition:lastRepetition) = smoothPhase;
    diagnostics.message = '';
else
    diagnostics.message = sprintf( ...
        ['Rejected: coherence %.3f, correction RMS %.3f deg, ', ...
        'explained %.3f.'], subspaceCoherence, correctionRmsDeg, ...
        explainedFraction);
end

diagnostics.applied = isReliable;
diagnostics.second_stage_cfo_applied = isSecondStageCfoReliable;
diagnostics.first_repetition = firstRepetition;
diagnostics.last_repetition = lastRepetition;
diagnostics.repetition_count = validCount;
diagnostics.peak_tap = peakTap;
diagnostics.first_tap = firstTap;
diagnostics.last_tap = lastTap;
diagnostics.subspace_coherence = subspaceCoherence;
diagnostics.raw_nonlinear_rms_deg = sqrt(sum(weights .* ...
    nonlinearPhase .^ 2) / sum(weights)) * 180 / pi;
diagnostics.correction_rms_deg = correctionRmsDeg;
diagnostics.noise_rms_deg = noiseRmsDeg;
diagnostics.maximum_abs_correction_deg = ...
    max(abs(smoothPhase)) * 180 / pi;
diagnostics.explained_fraction = explainedFraction;
diagnostics.linear_phase_slope_rad_per_repetition = ...
    linearSlopeRadPerRepetition;
diagnostics.second_stage_cfo_hz = secondStageCfoHz;
diagnostics.raw_phase_rad = rawPhase;
diagnostics.nonlinear_phase_rad = nonlinearPhase;
diagnostics.smoothed_phase_rad = smoothPhase;
diagnostics.weights = weights;
end

function fitted = weightedLine(x, y, weights)
design = [ones(numel(x), 1), x(:)];
weightedDesign = design .* weights(:);
coefficients = (design' * weightedDesign) \ ...
    (weightedDesign' * y(:));
fitted = design * coefficients;
end

function options = fillDefaults(options)
defaults = struct( ...
    'tap_half_width', 2, ...
    'minimum_repetitions', 20, ...
    'smoothing_lambda', 0.10, ...
    'minimum_weight', 0.20, ...
    'maximum_weight', 5.00, ...
    'minimum_subspace_coherence', 0.85, ...
    'minimum_correction_rms_deg', 0.20, ...
    'minimum_explained_fraction', 0.10, ...
    'maximum_abs_correction_deg', 15.0, ...
    'maximum_abs_second_stage_cfo_hz', 2e3);
names = fieldnames(defaults);
for k = 1:numel(names)
    name = names{k};
    if ~isfield(options, name) || isempty(options.(name))
        options.(name) = defaults.(name);
    end
end
end

function diagnostics = emptyDiagnostics()
diagnostics = struct( ...
    'applied', false, ...
    'second_stage_cfo_applied', false, ...
    'first_repetition', 0, ...
    'last_repetition', 0, ...
    'repetition_count', 0, ...
    'peak_tap', 0, ...
    'first_tap', 0, ...
    'last_tap', 0, ...
    'subspace_coherence', NaN, ...
    'raw_nonlinear_rms_deg', NaN, ...
    'correction_rms_deg', NaN, ...
    'noise_rms_deg', NaN, ...
    'maximum_abs_correction_deg', NaN, ...
    'explained_fraction', NaN, ...
    'linear_phase_slope_rad_per_repetition', NaN, ...
    'second_stage_cfo_hz', NaN, ...
    'raw_phase_rad', [], ...
    'nonlinear_phase_rad', [], ...
    'smoothed_phase_rad', [], ...
    'weights', [], ...
    'message', '');
end
