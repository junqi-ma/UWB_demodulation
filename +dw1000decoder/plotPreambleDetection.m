function plotPreambleDetection(preamble, reference, params)
%PLOTPREAMBLEDETECTION Visualize accumulated and per-symbol correlation.
figure('Name', 'Preamble matching result', 'Color', 'w');
subplot(2, 1, 1);
plot(preamble.metric, 'b'); hold on;
if isfield(preamble, 'metric_peak_index')
    peak_metric_index = preamble.metric_peak_index;
else
    peak_metric_index = preamble.strongest_end;
end
plot(peak_metric_index, preamble.metric_peak, 'ro', 'MarkerFaceColor', 'r');
grid on; xlabel('Sample'); ylabel('16-symbol accumulated metric');
title(sprintf('Code %d preamble matching', params.code_index));
subplot(2, 1, 2);
peak_idx = matchedLocalIndex(preamble, preamble.peaks);
margin = 2*reference.samples_per_symbol;
first = max(1, peak_idx(1)-margin);
last = min(length(preamble.score), peak_idx(end)+margin);
indices = first:last;
if isfield(preamble, 'matched_is_roi') && preamble.matched_is_roi
    abs_axis = preamble.roi_start+indices-1;
else
    abs_axis = indices;
end
plot(abs_axis, preamble.score(indices), 'b'); hold on;
yline(preamble.threshold, 'k--', 'Detection threshold');
plot(preamble.peaks, preamble.score(peak_idx), 'ro', 'MarkerSize', 4);
xline(preamble.peaks(1), 'g--', 'First repetition end');
grid on; xlabel('Sample'); ylabel('Normalized correlation');
title(sprintf('Detected repeated preamble: %d peaks', ...
    preamble.detected_repetitions));
end

function idx = matchedLocalIndex(preamble, absolute_peaks)
if isfield(preamble, 'matched_is_roi') && preamble.matched_is_roi
    idx = absolute_peaks-preamble.roi_start+1;
else
    idx = absolute_peaks;
end
end
