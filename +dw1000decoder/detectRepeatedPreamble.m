function preamble = detectRepeatedPreamble(rx, reference, params)
%DETECTREPEATEDPREAMBLE Detect and track the repeated SYNC symbols.
%   Uses a decimated coarse search, then a full-rate matched filter on an ROI
%   large enough to contain the entire SYNC field. Falls back to a full-rate
%   full-capture search if the ROI pass is unreliable.

rx = rx(:);
n_rx = numel(rx);
symbol_length = reference.samples_per_symbol;
template = reference.preamble_waveform(:);
search_half_width = 8;
accumulation_count = 16;

% --- Stage A: cheap decimated search over the whole capture ---
decimation = 4;
if n_rx < 8*symbol_length
    decimation = 1;
end
[coarse_end, ~] = coarsePreamblePeak(rx, template, symbol_length, ...
    accumulation_count, decimation);

% The coarse peak is typically near the *middle/end* of the repeated SYNC,
% not the first symbol. The ROI must therefore look far enough *backward*
% to include the whole configured preamble, plus a small forward margin.
roi_pre = (params.preamble_repetitions+32)*symbol_length;
roi_post = 48*symbol_length;
roi_start = max(1, round(coarse_end)-roi_pre);
roi_end = min(n_rx, round(coarse_end)+roi_post);

preamble = trackPreambleInRoi(rx, template, symbol_length, ...
    accumulation_count, search_half_width, params, roi_start, roi_end);

% --- Fallback: full-capture full-rate search if ROI tracking was too short ---
if preamble.detected_repetitions < 32
    if isfield(params, 'verbose') && params.verbose
        fprintf(['ROI preamble track found only %d peaks; ', ...
            'falling back to full-rate full-capture search.\n'], ...
            preamble.detected_repetitions);
    end
    preamble = trackPreambleInRoi(rx, template, symbol_length, ...
        accumulation_count, search_half_width, params, 1, n_rx);
end

if isfield(params, 'verbose') && params.verbose
    fprintf('Preamble metric peak: %.3f\n', preamble.metric_peak);
    fprintf('Detected %d repeated preamble symbols.\n', ...
        preamble.detected_repetitions);
    fprintf('Measured preamble period: %.6f samples, clock error: %.3f ppm.\n', ...
        preamble.measured_period, preamble.clock_error_ppm);
    fprintf('Estimated preamble start: work sample %d (ROI %d:%d).\n', ...
        preamble.start_sample, preamble.roi_start, preamble.roi_end);
end
if preamble.detected_repetitions < 32
    error('A reliable repeated preamble was not found. Check receiver settings.');
end
end

function preamble = trackPreambleInRoi(rx, template, symbol_length, ...
        accumulation_count, search_half_width, params, roi_start, roi_end)
roi = rx(roi_start:roi_end);
matched_roi = dw1000decoder.fftfiltCompat(flipud(conj(template)), roi);
energy = sqrt(movsum(abs(roi).^2, [symbol_length-1, 0]));
score_roi = abs(matched_roi)./(energy+eps);

metric_length = length(score_roi)-(accumulation_count-1)*symbol_length;
if metric_length < 1
    preamble = emptyPreambleResult(search_half_width, roi_start, roi_end);
    return;
end
metric = zeros(metric_length, 1, 'like', real(score_roi(1)));
for k = 0:accumulation_count-1
    first = 1+k*symbol_length;
    metric = metric+score_roi(first:first+metric_length-1);
end
[metric_peak, strongest_end_local] = max(metric);

% Threshold: prefer samples near the peak so long quiet regions do not
% drag the MAD-based floor too low or too high.
 thr_lo = max(1, strongest_end_local-8*symbol_length);
 thr_hi = min(numel(score_roi), strongest_end_local+8*symbol_length);
score_sample = score_roi(thr_lo:max(1, round(symbol_length/8)):thr_hi);
if numel(score_sample) < 32
    score_sample = score_roi(1:16:end);
end
score_median = median(score_sample);
score_sigma = 1.4826*median(abs(score_sample-score_median));
threshold = max(score_median+6*score_sigma, 0.20*score_roi(strongest_end_local));

first_end_local = strongest_end_local;
while first_end_local-symbol_length-search_half_width >= 1
    expected = first_end_local-symbol_length;
    indices = expected-search_half_width:expected+search_half_width;
    [previous_score, local_index] = max(score_roi(indices));
    if previous_score < threshold
        break;
    end
    first_end_local = indices(local_index);
end

peaks_local = zeros(params.preamble_repetitions+16, 1);
peak_count = 1;
peaks_local(peak_count) = first_end_local;
current_peak = first_end_local;
while peak_count < length(peaks_local)
    expected = current_peak+symbol_length;
    if expected+search_half_width > length(score_roi)
        break;
    end
    indices = expected-search_half_width:expected+search_half_width;
    [next_score, local_index] = max(score_roi(indices));
    if next_score < threshold
        break;
    end
    current_peak = indices(local_index);
    peak_count = peak_count+1;
    peaks_local(peak_count) = current_peak;
end
peaks_local = peaks_local(1:peak_count);

if peak_count < 2
    preamble = emptyPreambleResult(search_half_width, roi_start, roi_end);
    preamble.matched = matched_roi;
    preamble.score = score_roi;
    preamble.metric = metric;
    preamble.metric_peak = metric_peak;
    preamble.metric_peak_index = strongest_end_local;
    preamble.threshold = threshold;
    preamble.detected_repetitions = peak_count;
    return;
end

period_fit = polyfit((0:peak_count-1).', double(peaks_local), 1);
measured_period = period_fit(1);
clock_error_ppm = (measured_period/symbol_length-1)*1e6;
start_sample_local = round(first_end_local-measured_period+1);

peaks = peaks_local+roi_start-1;
start_sample = start_sample_local+roi_start-1;
strongest_end = strongest_end_local+roi_start-1;

preamble = struct('matched', matched_roi, 'score', score_roi, ...
    'metric', metric, 'metric_peak', metric_peak, ...
    'metric_peak_index', strongest_end_local, ...
    'strongest_end', strongest_end, 'threshold', threshold, ...
    'peaks', peaks, 'detected_repetitions', peak_count, ...
    'measured_period', measured_period, 'clock_error_ppm', clock_error_ppm, ...
    'start_sample', start_sample, 'search_half_width', search_half_width, ...
    'roi_start', roi_start, 'roi_end', roi_end, ...
    'matched_is_roi', true);
end

function preamble = emptyPreambleResult(search_half_width, roi_start, roi_end)
preamble = struct('matched', [], 'score', [], 'metric', [], ...
    'metric_peak', 0, 'metric_peak_index', 1, 'strongest_end', 1, ...
    'threshold', 0, 'peaks', zeros(0, 1), 'detected_repetitions', 0, ...
    'measured_period', NaN, 'clock_error_ppm', NaN, 'start_sample', 1, ...
    'search_half_width', search_half_width, 'roi_start', roi_start, ...
    'roi_end', roi_end, 'matched_is_roi', true);
end

function [coarse_end, metric_peak] = coarsePreamblePeak(rx, template, ...
        symbol_length, accumulation_count, decimation)
template_ds = template(1:decimation:end);
template_ds = template_ds/(norm(template_ds)+eps);
rx_ds = rx(1:decimation:end);
symbol_ds = max(1, round(symbol_length/decimation));
matched = dw1000decoder.fftfiltCompat(flipud(conj(template_ds)), rx_ds);
energy = sqrt(movsum(abs(rx_ds).^2, [symbol_ds-1, 0]));
score = abs(matched)./(energy+eps);
metric_length = length(score)-(accumulation_count-1)*symbol_ds;
if metric_length < 1
    error('Capture is too short for coarse preamble detection.');
end
metric = zeros(metric_length, 1, 'like', real(score(1)));
for k = 0:accumulation_count-1
    first = 1+k*symbol_ds;
    metric = metric+score(first:first+metric_length-1);
end
[metric_peak, strongest_end_ds] = max(metric);
% Map decimated metric index to an approximate full-rate sample index.
coarse_end = (strongest_end_ds-1)*decimation+1;
end
