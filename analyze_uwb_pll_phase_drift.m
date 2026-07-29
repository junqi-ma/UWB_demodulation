%% Analyze repeatability of packet-start PLL phase drift after cancellation
% This script uses the signal removed by run_cancel_all_uwb_packets:
%
%   removed model = fitting capture - cancelled capture
%
% For every packet and every preamble SYNC repetition, it estimates the
% complex least-squares ratio between the received signal and the removed
% model. A straight phase line fitted to the stable part of each preamble
% removes packet-dependent initial phase and residual CFO. The remaining
% nonlinear phase is the candidate PLL settling trajectory.
%
% A leave-one-packet-out template test then answers the practical question:
% can a phase trajectory learned from other packets improve cancellation of
% a packet that was not used to build the template?

clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% 1. User configuration
% Each directory must contain cancelled_optimal_complex_metadata.mat and
% cancelled_optimal_complex.dat. Add/remove entries as needed.
result_directories = {
    fullfile(project_dir, 'decoded_results', 'dw1000_new_3')
    fullfile(project_dir, 'decoded_results', 'qm35_new_3')
    };
cancellation_mode = 'optimal_complex';

% Use Inf for all successful packets. A smaller number is useful for a
% quick preview; packets are then selected uniformly over the capture.
max_packets_per_result = Inf;

% Phase is estimated only from model samples above this relative threshold.
% This avoids assigning phase to the nearly empty intervals between pulses.
strong_sample_fraction = 0.15;
minimum_model_amplitude_adc = 3;
minimum_repetition_coherence = 0.20;

% The final part of the preamble defines the stable phase/CFO line. The
% packet-start window is used for repeatability and cancellation tests.
stable_fit_start_fraction = 0.50;
early_repetition_limit = 24;

% Conservative automatic interpretation thresholds.
consistent_resultant_threshold = 0.80;
useful_improvement_threshold_db = 0.50;
useful_packet_fraction_threshold = 0.70;

save_figures = true;
output_root = fullfile(project_dir, 'decoded_results', ...
    'pll_phase_drift_analysis');

%% 2. Analyze each cancellation result
if ~isfolder(output_root)
    mkdir(output_root);
end

summary_cells = cell(numel(result_directories), 1);
summary_count = 0;
for result_index = 1:numel(result_directories)
    result_dir = result_directories{result_index};
    if ~isfolder(result_dir)
        warning('analyze_uwb_pll_phase_drift:ResultDirectoryNotFound', ...
            'Skipping missing result directory: %s', result_dir);
        continue
    end

    fprintf('\n============================================================\n');
    fprintf('PLL phase-drift analysis: %s\n', result_dir);
    fprintf('============================================================\n');

    config = struct();
    config.cancellation_mode = cancellation_mode;
    config.max_packets = max_packets_per_result;
    config.strong_sample_fraction = strong_sample_fraction;
    config.minimum_model_amplitude_adc = minimum_model_amplitude_adc;
    config.minimum_repetition_coherence = ...
        minimum_repetition_coherence;
    config.stable_fit_start_fraction = stable_fit_start_fraction;
    config.early_repetition_limit = early_repetition_limit;
    config.consistent_resultant_threshold = ...
        consistent_resultant_threshold;
    config.useful_improvement_threshold_db = ...
        useful_improvement_threshold_db;
    config.useful_packet_fraction_threshold = ...
        useful_packet_fraction_threshold;

    analysis = analyzeOneResult(result_dir, config);
    summary_count = summary_count + 1;
    summary_cells{summary_count} = analysis.summary;

    result_output_dir = fullfile(output_root, analysis.result_name);
    if ~isfolder(result_output_dir)
        mkdir(result_output_dir);
    end

    packet_table = makePacketTable(analysis);
    repetition_table = makeRepetitionTable(analysis);
    writetable(packet_table, ...
        fullfile(result_output_dir, 'packet_phase_drift.csv'));
    writetable(repetition_table, ...
        fullfile(result_output_dir, 'repetition_phase_template.csv'));
    save(fullfile(result_output_dir, 'pll_phase_drift_analysis.mat'), ...
        'analysis', 'config', '-v7.3');

    fig = plotAnalysis(analysis);
    if save_figures
        exportgraphics(fig, fullfile(result_output_dir, ...
            'pll_phase_drift_analysis.png'), 'Resolution', 180);
    end
    fprintf('Outputs: %s\n', result_output_dir);
end

if summary_count == 0
    error('analyze_uwb_pll_phase_drift:NoResults', ...
        'No valid cancellation result directories were analyzed.');
end

all_summaries = vertcat(summary_cells{1:summary_count});
summary_table = struct2table(all_summaries);
writetable(summary_table, fullfile(output_root, 'summary.csv'));
fprintf('\nCombined summary: %s\n', ...
    fullfile(output_root, 'summary.csv'));

%% ------------------------------------------------------------------------
function analysis = analyzeOneResult(resultDir, config)
metadataFile = fullfile(resultDir, sprintf( ...
    'cancelled_%s_metadata.mat', config.cancellation_mode));
cancelledFileDefault = fullfile(resultDir, sprintf( ...
    'cancelled_%s.dat', config.cancellation_mode));
if ~isfile(metadataFile)
    error('analyze_uwb_pll_phase_drift:MetadataNotFound', ...
        'Cancellation metadata not found: %s', metadataFile);
end

meta = load(metadataFile);
requiredFields = {'reports', 'params', 'fitting_file'};
missingFields = setdiff(requiredFields, fieldnames(meta));
if ~isempty(missingFields)
    error('analyze_uwb_pll_phase_drift:InvalidMetadata', ...
        'Metadata is missing: %s', strjoin(missingFields, ', '));
end

if isfield(meta, 'output_file') && isfile(meta.output_file)
    cancelledFile = meta.output_file;
else
    cancelledFile = cancelledFileDefault;
end
fittingFile = meta.fitting_file;
if ~isfile(fittingFile)
    error('analyze_uwb_pll_phase_drift:FittingCaptureNotFound', ...
        'Fitting capture not found: %s', fittingFile);
end
if ~isfile(cancelledFile)
    error('analyze_uwb_pll_phase_drift:CancelledCaptureNotFound', ...
        'Cancelled capture not found: %s', cancelledFile);
end

fittingInfo = dir(fittingFile);
cancelledInfo = dir(cancelledFile);
if fittingInfo.bytes ~= cancelledInfo.bytes
    error('analyze_uwb_pll_phase_drift:CaptureLengthMismatch', ...
        'Fitting and cancelled captures have different lengths.');
end

reports = meta.reports(:);
successMask = [reports.success].';
reports = reports(successMask);
if isempty(reports)
    error('analyze_uwb_pll_phase_drift:NoSuccessfulPackets', ...
        'Metadata contains no successful cancellation reports.');
end

packetSelection = selectUniformly(numel(reports), config.max_packets);
reports = reports(packetSelection);
params = meta.params;
c = uwbdecoder.constants();
periodSamplesExact = c.PREAMBLE_PERIOD_S * params.fs_rx;
syncCount = params.preamble_repetitions;
stableFirst = max(2, min(syncCount - 1, ...
    ceil(config.stable_fit_start_fraction * syncCount)));
stableIndices = stableFirst:syncCount;
earlyCount = min(config.early_repetition_limit, stableFirst - 1);
earlyIndices = 1:earlyCount;
packetCount = numel(reports);

rawPhase = NaN(packetCount, syncCount);
phaseLine = NaN(packetCount, syncCount);
phaseDrift = NaN(packetCount, syncCount);
coherence = NaN(packetCount, syncCount);
observedEnergy = NaN(packetCount, syncCount);
modelEnergy = NaN(packetCount, syncCount);
crossTerm = complex(NaN(packetCount, syncCount));
strongSampleCount = zeros(packetCount, syncCount);

fprintf('Packets selected       : %d / %d successful\n', ...
    packetCount, sum(successMask));
fprintf('SYNC repetitions       : %d\n', syncCount);
fprintf('Stable fit repetitions : %d..%d\n', stableFirst, syncCount);
fprintf('Early test repetitions : 1..%d\n', earlyCount);

for packetIndex = 1:packetCount
    report = reports(packetIndex);
    preambleSamples = min(report.samples_subtracted, ...
        round(syncCount * periodSamplesExact));
    originalRaw = uwbdecoder.readIqRaw(fittingFile, ...
        report.abs_start_fitted, preambleSamples, params.ant_num);
    cancelledRaw = uwbdecoder.readIqRaw(cancelledFile, ...
        report.abs_start_fitted, preambleSamples, params.ant_num);
    observed = uwbdecoder.selectIqChannel( ...
        originalRaw, params.channel_index);
    cancelled = uwbdecoder.selectIqChannel( ...
        cancelledRaw, params.channel_index);
    model = observed - cancelled;

    for repetition = 1:syncCount
        firstSample = round((repetition - 1) * periodSamplesExact) + 1;
        lastSample = min(preambleSamples, ...
            round(repetition * periodSamplesExact));
        if firstSample > lastSample
            continue
        end
        observedSegment = observed(firstSample:lastSample);
        modelSegment = model(firstSample:lastSample);
        amplitude = abs(modelSegment);
        threshold = max(config.minimum_model_amplitude_adc, ...
            config.strong_sample_fraction * max(amplitude));
        strong = amplitude >= threshold;
        if nnz(strong) < 4
            continue
        end

        x = modelSegment(strong);
        y = observedSegment(strong);
        a = sum(abs(y).^2);
        b = sum(abs(x).^2);
        cross = sum(conj(x) .* y);
        thisCoherence = abs(cross) / sqrt(a * b + eps);
        if thisCoherence < config.minimum_repetition_coherence
            continue
        end

        observedEnergy(packetIndex, repetition) = a;
        modelEnergy(packetIndex, repetition) = b;
        crossTerm(packetIndex, repetition) = cross;
        coherence(packetIndex, repetition) = thisCoherence;
        strongSampleCount(packetIndex, repetition) = nnz(strong);
        rawPhase(packetIndex, repetition) = angle(cross);
    end

    validStable = stableIndices(isfinite( ...
        rawPhase(packetIndex, stableIndices)));
    if numel(validStable) >= 3
        unwrapped = unwrap(rawPhase(packetIndex, :));
        weights = modelEnergy(packetIndex, validStable);
        fittedLine = fitWeightedLine(validStable, ...
            unwrapped(validStable), weights);
        phaseLine(packetIndex, :) = fittedLine;
        phaseDrift(packetIndex, :) = wrapToPiLocal( ...
            unwrapped - fittedLine);
    end

    if mod(packetIndex, 100) == 0 || packetIndex == packetCount
        fprintf('  Processed %d / %d packets\n', ...
            packetIndex, packetCount);
    end
end

validPacket = sum(isfinite(phaseDrift(:, stableIndices)), 2) >= ...
    max(3, ceil(0.8 * numel(stableIndices))) & ...
    sum(isfinite(phaseDrift(:, earlyIndices)), 2) >= ...
    max(3, ceil(0.8 * numel(earlyIndices)));
if nnz(validPacket) < 3
    error('analyze_uwb_pll_phase_drift:TooFewValidPackets', ...
        'Only %d packets have valid phase tracks; at least 3 are required.', ...
        nnz(validPacket));
end

reports = reports(validPacket);
rawPhase = rawPhase(validPacket, :);
phaseLine = phaseLine(validPacket, :);
phaseDrift = phaseDrift(validPacket, :);
coherence = coherence(validPacket, :);
observedEnergy = observedEnergy(validPacket, :);
modelEnergy = modelEnergy(validPacket, :);
crossTerm = crossTerm(validPacket, :);
strongSampleCount = strongSampleCount(validPacket, :);
packetCount = nnz(validPacket);

[templatePhase, resultantLength, circularStd] = ...
    circularColumnStatistics(phaseDrift);
looTemplate = leaveOneOutTemplate(phaseDrift);

currentSuppressionDb = NaN(packetCount, 1);
stableRefitSuppressionDb = NaN(packetCount, 1);
templateSuppressionDb = NaN(packetCount, 1);
templateSimilarity = NaN(packetCount, 1);
earlyPhaseRmsDeg = NaN(packetCount, 1);
for packetIndex = 1:packetCount
    validEarly = earlyIndices( ...
        isfinite(crossTerm(packetIndex, earlyIndices)) & ...
        isfinite(looTemplate(packetIndex, earlyIndices)));
    if isempty(validEarly)
        continue
    end
    a = observedEnergy(packetIndex, validEarly);
    b = modelEnergy(packetIndex, validEarly);
    cross = crossTerm(packetIndex, validEarly);
    currentResidual = sum(a + b - 2 * real(cross));
    stablePhase = phaseLine(packetIndex, validEarly);
    stableResidual = sum(a + b - 2 * real( ...
        exp(-1j * stablePhase) .* cross));
    correctedPhase = stablePhase + ...
        looTemplate(packetIndex, validEarly);
    templateResidual = sum(a + b - 2 * real( ...
        exp(-1j * correctedPhase) .* cross));
    totalObserved = sum(a);

    currentSuppressionDb(packetIndex) = 10 * log10( ...
        totalObserved / max(currentResidual, eps));
    stableRefitSuppressionDb(packetIndex) = 10 * log10( ...
        totalObserved / max(stableResidual, eps));
    templateSuppressionDb(packetIndex) = 10 * log10( ...
        totalObserved / max(templateResidual, eps));
    phaseDifference = wrapToPiLocal( ...
        phaseDrift(packetIndex, validEarly) - ...
        looTemplate(packetIndex, validEarly));
    templateSimilarity(packetIndex) = abs(mean(exp(1j * phaseDifference)));
    earlyPhaseRmsDeg(packetIndex) = sqrt(mean( ...
        phaseDrift(packetIndex, validEarly).^2)) * 180 / pi;
end

improvementDb = templateSuppressionDb - currentSuppressionDb;
improvementOverStableRefitDb = ...
    templateSuppressionDb - stableRefitSuppressionDb;
finiteImprovement = isfinite(improvementDb);
medianResultant = median(resultantLength(earlyIndices), 'omitnan');
minimumResultant = min(resultantLength(earlyIndices), [], 'omitnan');
medianImprovement = median(improvementDb, 'omitnan');
medianTemplateOnlyImprovement = median( ...
    improvementOverStableRefitDb, 'omitnan');
improvedPacketFraction = mean( ...
    improvementDb(finiteImprovement) > 0);
medianEarlyDriftDeg = median( ...
    abs(templatePhase(earlyIndices)), 'omitnan') * 180 / pi;

isConsistent = medianResultant >= ...
    config.consistent_resultant_threshold;
isUseful = isConsistent && ...
    medianImprovement >= config.useful_improvement_threshold_db && ...
    improvedPacketFraction >= config.useful_packet_fraction_threshold;
if isUseful
    decision = "consistent_and_template_is_promising";
elseif isConsistent
    decision = "consistent_but_limited_cancellation_gain";
else
    decision = "not_consistent_enough_for_one_fixed_template";
end

[~, resultName] = fileparts(resultDir);
profileName = inferProfileName(params, resultName);
summary = struct();
summary.result_name = string(resultName);
summary.profile = string(profileName);
summary.packet_count = packetCount;
summary.sync_repetitions = syncCount;
summary.early_repetitions = earlyCount;
summary.stable_fit_first_repetition = stableFirst;
summary.median_early_resultant = medianResultant;
summary.minimum_early_resultant = minimumResultant;
summary.median_early_template_phase_deg = medianEarlyDriftDeg;
summary.median_improvement_db = medianImprovement;
summary.median_improvement_over_stable_refit_db = ...
    medianTemplateOnlyImprovement;
summary.improved_packet_fraction = improvedPacketFraction;
summary.decision = decision;

fprintf('\n--- %s / %s result ---\n', profileName, resultName);
fprintf('Valid packets                  : %d\n', packetCount);
fprintf('Median early resultant [0..1] : %.3f\n', medianResultant);
fprintf('Minimum early resultant       : %.3f\n', minimumResultant);
fprintf('Median |template phase|       : %.2f deg\n', ...
    medianEarlyDriftDeg);
fprintf('Median gain vs current        : %+.3f dB\n', ...
    medianImprovement);
fprintf('Median gain beyond stable fit : %+.3f dB\n', ...
    medianTemplateOnlyImprovement);
fprintf('Packets improved              : %.1f %%\n', ...
    100 * improvedPacketFraction);
fprintf('Decision                      : %s\n', decision);

analysis = struct();
analysis.result_name = resultName;
analysis.profile = profileName;
analysis.result_directory = resultDir;
analysis.metadata_file = metadataFile;
analysis.fitting_file = fittingFile;
analysis.cancelled_file = cancelledFile;
analysis.params = params;
analysis.reports = reports;
analysis.period_samples = periodSamplesExact;
analysis.repetition_time_us = ...
    ((1:syncCount) - 0.5) * periodSamplesExact / params.fs_rx * 1e6;
analysis.stable_indices = stableIndices;
analysis.early_indices = earlyIndices;
analysis.raw_phase_rad = rawPhase;
analysis.phase_line_rad = phaseLine;
analysis.phase_drift_rad = phaseDrift;
analysis.coherence = coherence;
analysis.strong_sample_count = strongSampleCount;
analysis.template_phase_rad = templatePhase;
analysis.resultant_length = resultantLength;
analysis.circular_std_rad = circularStd;
analysis.leave_one_out_template_rad = looTemplate;
analysis.current_suppression_db = currentSuppressionDb;
analysis.stable_refit_suppression_db = stableRefitSuppressionDb;
analysis.template_suppression_db = templateSuppressionDb;
analysis.improvement_db = improvementDb;
analysis.improvement_over_stable_refit_db = ...
    improvementOverStableRefitDb;
analysis.template_similarity = templateSimilarity;
analysis.early_phase_rms_deg = earlyPhaseRmsDeg;
analysis.summary = summary;
end

function selection = selectUniformly(count, maximumCount)
if isinf(maximumCount) || maximumCount >= count
    selection = (1:count).';
else
    validateattributes(maximumCount, {'numeric'}, ...
        {'scalar', 'integer', 'positive'});
    selection = unique(round(linspace(1, count, maximumCount))).';
end
end

function fitted = fitWeightedLine(indices, phase, weights)
x = double(indices(:));
y = double(phase(:));
w = max(double(weights(:)), eps);
xCenter = sum(w .* x) / sum(w);
design = [x - xCenter, ones(size(x))];
weightedDesign = design .* sqrt(w);
weightedPhase = y .* sqrt(w);
coefficients = weightedDesign \ weightedPhase;
allX = (1:max(indices)).';
fitted = (coefficients(1) * (allX - xCenter) + ...
    coefficients(2)).';
end

function wrapped = wrapToPiLocal(phase)
wrapped = mod(phase + pi, 2 * pi) - pi;
end

function [meanPhase, resultant, circularStd] = ...
        circularColumnStatistics(phase)
valid = isfinite(phase);
phasor = zeros(size(phase));
phasor(valid) = exp(1j * phase(valid));
count = sum(valid, 1);
phasorSum = sum(phasor, 1);
meanPhasor = phasorSum ./ max(count, 1);
meanPhase = angle(meanPhasor);
resultant = abs(meanPhasor);
meanPhase(count == 0) = NaN;
resultant(count == 0) = NaN;
circularStd = sqrt(max(0, -2 * log(max(resultant, eps))));
end

function template = leaveOneOutTemplate(phase)
valid = isfinite(phase);
phasor = zeros(size(phase));
phasor(valid) = exp(1j * phase(valid));
columnSum = sum(phasor, 1);
columnCount = sum(valid, 1);
remainingSum = columnSum - phasor;
remainingCount = columnCount - valid;
template = angle(remainingSum);
template(remainingCount < 2) = NaN;
end

function profileName = inferProfileName(params, resultName)
if isfield(params, 'preamble_repetitions') && ...
        params.preamble_repetitions <= 72
    profileName = 'QM35';
elseif contains(lower(resultName), 'qm35')
    profileName = 'QM35';
else
    profileName = 'DW1000';
end
end

function packetTable = makePacketTable(analysis)
packetIndex = [analysis.reports.index].';
packetTable = table(packetIndex, analysis.early_phase_rms_deg, ...
    analysis.template_similarity, analysis.current_suppression_db, ...
    analysis.stable_refit_suppression_db, ...
    analysis.template_suppression_db, analysis.improvement_db, ...
    analysis.improvement_over_stable_refit_db, ...
    'VariableNames', {'packet_index', 'early_phase_rms_deg', ...
    'template_similarity', 'current_early_suppression_db', ...
    'stable_refit_early_suppression_db', ...
    'loo_template_early_suppression_db', ...
    'improvement_vs_current_db', ...
    'improvement_vs_stable_refit_db'});
end

function repetitionTable = makeRepetitionTable(analysis)
repetition = (1:numel(analysis.template_phase_rad)).';
timeUs = analysis.repetition_time_us(:);
templatePhaseDeg = analysis.template_phase_rad(:) * 180 / pi;
resultantLength = analysis.resultant_length(:);
circularStdDeg = analysis.circular_std_rad(:) * 180 / pi;
validPackets = sum(isfinite(analysis.phase_drift_rad), 1).';
repetitionTable = table(repetition, timeUs, templatePhaseDeg, ...
    resultantLength, circularStdDeg, validPackets, ...
    'VariableNames', {'repetition', 'time_us', ...
    'template_phase_deg', 'resultant_length', ...
    'circular_std_deg', 'valid_packets'});
end

function fig = plotAnalysis(analysis)
phaseDeg = analysis.phase_drift_rad * 180 / pi;
templateDeg = analysis.template_phase_rad * 180 / pi;
stdDeg = analysis.circular_std_rad * 180 / pi;
timeUs = analysis.repetition_time_us;
earlyLast = analysis.early_indices(end);
stableFirst = analysis.stable_indices(1);

fig = figure('Name', sprintf('%s PLL phase drift', analysis.profile), ...
    'Color', 'w', 'Position', [40 40 1450 900]);
layout = tiledlayout(fig, 2, 3, 'TileSpacing', 'compact', ...
    'Padding', 'compact');

nexttile(layout, 1);
displayCount = min(200, size(phaseDeg, 1));
displayRows = unique(round(linspace(1, size(phaseDeg, 1), ...
    displayCount)));
plot(timeUs, phaseDeg(displayRows, :).', ...
    'Color', [0.75 0.75 0.75], 'LineWidth', 0.35);
hold on;
plot(timeUs, templateDeg, 'r-', 'LineWidth', 2);
xline(timeUs(earlyLast), 'b--', 'early test end');
xline(timeUs(stableFirst), 'k--', 'stable fit start');
grid on;
xlabel('Time from fitted packet start (\mus)');
ylabel('Phase after constant/CFO removal (deg)');
title(sprintf('Aligned packet tracks (showing %d/%d)', ...
    numel(displayRows), size(phaseDeg, 1)));

nexttile(layout, 2);
imagesc(timeUs, 1:size(phaseDeg, 1), phaseDeg);
axis xy;
colorbar;
clim([-45 45]);
xline(timeUs(earlyLast), 'w--', 'LineWidth', 1.2);
xline(timeUs(stableFirst), 'w--', 'LineWidth', 1.2);
xlabel('Time from fitted packet start (\mus)');
ylabel('Packet');
title('Per-packet nonlinear phase (deg)');

nexttile(layout, 3);
upper = templateDeg + stdDeg;
lower = templateDeg - stdDeg;
fill([timeUs, fliplr(timeUs)], [upper, fliplr(lower)], ...
    [1.00 0.80 0.80], 'EdgeColor', 'none');
hold on;
plot(timeUs, templateDeg, 'r-', 'LineWidth', 2);
yline(0, 'k:');
xline(timeUs(earlyLast), 'b--', 'early test end');
xline(timeUs(stableFirst), 'k--', 'stable fit start');
grid on;
xlabel('Time from fitted packet start (\mus)');
ylabel('Phase (deg)');
title('Circular mean template \pm circular std');

nexttile(layout, 4);
plot(timeUs, analysis.resultant_length, ...
    'Color', [0.10 0.45 0.85], 'LineWidth', 1.5);
hold on;
yline(0.8, 'r--', 'consistency threshold');
xline(timeUs(earlyLast), 'b--', 'early test end');
xline(timeUs(stableFirst), 'k--', 'stable fit start');
ylim([0 1.02]);
grid on;
xlabel('Time from fitted packet start (\mus)');
ylabel('Mean resultant length');
title('Cross-packet phase consistency (1 = identical)');

nexttile(layout, 5);
scatter(analysis.current_suppression_db, ...
    analysis.template_suppression_db, 10, ...
    analysis.template_similarity, 'filled');
hold on;
finiteValues = [analysis.current_suppression_db; ...
    analysis.template_suppression_db];
limits = [min(finiteValues, [], 'omitnan'), ...
    max(finiteValues, [], 'omitnan')];
plot(limits, limits, 'k--');
axis equal;
xlim(limits);
ylim(limits);
grid on;
colorbar;
xlabel('Current early suppression (dB)');
ylabel('Leave-one-out template suppression (dB)');
title('Unseen-packet cancellation test');

nexttile(layout, 6);
histogram(analysis.improvement_db, 40, ...
    'FaceColor', [0.25 0.60 0.35]);
hold on;
xline(0, 'k--');
xline(median(analysis.improvement_db, 'omitnan'), ...
    'r-', 'median', 'LineWidth', 1.5);
grid on;
xlabel('Template improvement vs current (dB)');
ylabel('Packets');
title(sprintf('Median %+.2f dB | %.1f%% improved', ...
    analysis.summary.median_improvement_db, ...
    100 * analysis.summary.improved_packet_fraction));

sgtitle(layout, sprintf('%s / %s | %s', analysis.profile, ...
    analysis.result_name, analysis.summary.decision), ...
    'Interpreter', 'none');
end
