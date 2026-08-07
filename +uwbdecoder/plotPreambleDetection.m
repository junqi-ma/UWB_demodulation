function plotPreambleDetection(preamble, reference, params)
%PLOTPREAMBLEDETECTION Visualize accumulated and per-symbol correlation.
%   PLOTPREAMBLEDETECTION(PREAMBLE, REFERENCE, PARAMS) plots the
%   accumulated multi-symbol metric with its peak, and the per-symbol
%   matched-filter score with detected peaks and the detection threshold.
%
%   See also DETECTREPEATEDPREAMBLE.

figure('Name', 'Preamble matching result', 'Color', 'w');
subplot(2, 1, 1);
plot(preamble.metric, 'b'); hold on;
if isfield(preamble, 'metric_peak_index')
    peakMetricIdx = preamble.metric_peak_index;
else
    peakMetricIdx = preamble.strongest_end;
end
plot(peakMetricIdx, preamble.metric_peak, 'ro', 'MarkerFaceColor', 'r');
grid on; xlabel('Sample'); ylabel('16-symbol accumulated metric');
title(sprintf('Code %d preamble matching', params.code_index));

subplot(2, 1, 2);
if isempty(preamble.score)
    plot(preamble.peaks, zeros(size(preamble.peaks)), 'ro');
    xline(preamble.peaks(1), 'g--', 'First repetition end');
    grid on; xlabel('Sample'); ylabel('Seeded timing grid');
    title(sprintf(['Direct SFD timing candidate: %d configured ', ...
        'preamble repetitions'], preamble.detected_repetitions));
    return;
end
peakIdx = matchedLocalIndex(preamble, preamble.peaks);
margin = 2*reference.samples_per_symbol;
first = max(1, peakIdx(1) - margin);
last = min(length(preamble.score), peakIdx(end) + margin);
indices = first:last;
if isfield(preamble, 'matched_is_roi') && preamble.matched_is_roi
    absAxis = preamble.roi_start + indices - 1;
else
    absAxis = indices;
end
plot(absAxis, preamble.score(indices), 'b'); hold on;
yline(preamble.threshold, 'k--', 'Detection threshold');
plot(preamble.peaks, preamble.score(peakIdx), 'ro', 'MarkerSize', 4);
xline(preamble.peaks(1), 'g--', 'First repetition end');
grid on; xlabel('Sample'); ylabel('Normalized correlation');
title(sprintf('Detected repeated preamble: %d peaks', ...
    preamble.detected_repetitions));
end

% -------------------------------------------------------------------------
function idx = matchedLocalIndex(preamble, absolutePeaks)
if isfield(preamble, 'matched_is_roi') && preamble.matched_is_roi
    idx = absolutePeaks - preamble.roi_start + 1;
else
    idx = absolutePeaks;
end
end
