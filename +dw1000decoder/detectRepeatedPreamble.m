function preamble = detectRepeatedPreamble(rx, reference, params)
%DETECTREPEATEDPREAMBLE Detect and track the repeated SYNC symbols.
%   PREAMBLE = DETECTREPEATEDPREAMBLE(RX, REFERENCE, PARAMS) finds the
%   repeated HRP SYNC field in the work buffer RX. It runs a cheap
%   decimated coarse search over the whole capture, then a full-rate
%   matched filter on an ROI large enough to contain the entire SYNC
%   field. Falls back to a full-rate full-capture search if the ROI pass
%   is unreliable.
%
%   See also DECODE_X410_DW1000, VALIDATECAPTURELENGTH.

rx = rx(:);
nRx = numel(rx);
symbolLength = reference.samples_per_symbol;
template = reference.preamble_waveform(:);
searchHalfWidth = 8;
accumulationCount = 16;

% --- Stage A: cheap decimated search over the whole capture ---
decimation = 4;
if nRx < 8*symbolLength
    decimation = 1;
end
[coarseEnd, ~] = coarsePreamblePeak(rx, template, symbolLength, ...
    accumulationCount, decimation);

% The coarse peak may fall anywhere on the repeated-SYNC metric plateau.
% Keep a full configured preamble plus margin on both sides so the ROI still
% covers the entire SYNC field when the coarse maximum occurs near its start.
roiPre = (params.preamble_repetitions + 32)*symbolLength;
roiPost = (params.preamble_repetitions + 32)*symbolLength;
roiStart = max(1, round(coarseEnd) - roiPre);
roiEnd = min(nRx, round(coarseEnd) + roiPost);

preamble = trackPreambleInRoi(rx, template, symbolLength, ...
    accumulationCount, searchHalfWidth, params, roiStart, roiEnd);

% --- Fallback: full-capture full-rate search if ROI tracking was too short ---
if preamble.detected_repetitions < 32
    if isfield(params, 'verbose') && params.verbose
        fprintf(['ROI preamble track found only %d peaks; ', ...
            'falling back to full-rate full-capture search.\n'], ...
            preamble.detected_repetitions);
    end
    preamble = trackPreambleInRoi(rx, template, symbolLength, ...
        accumulationCount, searchHalfWidth, params, 1, nRx);
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
    error('detectRepeatedPreamble:TooFewRepetitions', ...
        'A reliable repeated preamble was not found. Check receiver settings.');
end
end

% -------------------------------------------------------------------------
function preamble = trackPreambleInRoi(rx, template, symbolLength, ...
        accumulationCount, searchHalfWidth, params, roiStart, roiEnd)
roi = rx(roiStart:roiEnd);
matchedRoi = fftfilt(flipud(conj(template)), roi);
energy = sqrt(movsum(abs(roi).^2, [symbolLength-1, 0]));
scoreRoi = abs(matchedRoi) ./ (energy + eps);

metricLength = length(scoreRoi) - (accumulationCount-1)*symbolLength;
if metricLength < 1
    preamble = emptyPreambleResult(searchHalfWidth, roiStart, roiEnd);
    return;
end
metric = zeros(metricLength, 1);
for idx = 0:accumulationCount-1
    first = 1 + idx*symbolLength;
    metric = metric + scoreRoi(first:first+metricLength-1);
end
[metricPeak, strongestEndLocal] = max(metric);

% Threshold: prefer samples near the peak so long quiet regions do not
% drag the MAD-based floor too low or too high.
thrLo = max(1, strongestEndLocal - 8*symbolLength);
thrHi = min(numel(scoreRoi), strongestEndLocal + 8*symbolLength);
scoreSample = scoreRoi(thrLo:max(1, round(symbolLength/8)):thrHi);
if numel(scoreSample) < 32
    scoreSample = scoreRoi(1:16:end);
end
scoreMedian = median(scoreSample);
scoreSigma = 1.4826*median(abs(scoreSample - scoreMedian));
threshold = max(scoreMedian + 6*scoreSigma, 0.20*scoreRoi(strongestEndLocal));

firstEndLocal = strongestEndLocal;
while firstEndLocal - symbolLength - searchHalfWidth >= 1
    expected = firstEndLocal - symbolLength;
    indices = expected-searchHalfWidth:expected+searchHalfWidth;
    [previousScore, localIndex] = max(scoreRoi(indices));
    if previousScore < threshold
        break;
    end
    firstEndLocal = indices(localIndex);
end

peaksLocal = zeros(params.preamble_repetitions + 16, 1);
peakCount = 1;
peaksLocal(peakCount) = firstEndLocal;
currentPeak = firstEndLocal;
while peakCount < length(peaksLocal)
    expected = currentPeak + symbolLength;
    if expected + searchHalfWidth > length(scoreRoi)
        break;
    end
    indices = expected-searchHalfWidth:expected+searchHalfWidth;
    [nextScore, localIndex] = max(scoreRoi(indices));
    if nextScore < threshold
        break;
    end
    currentPeak = indices(localIndex);
    peakCount = peakCount + 1;
    peaksLocal(peakCount) = currentPeak;
end
peaksLocal = peaksLocal(1:peakCount);

if peakCount < 2
    preamble = emptyPreambleResult(searchHalfWidth, roiStart, roiEnd);
    preamble.matched = matchedRoi;
    preamble.score = scoreRoi;
    preamble.metric = metric;
    preamble.metric_peak = metricPeak;
    preamble.metric_peak_index = strongestEndLocal;
    preamble.threshold = threshold;
    preamble.detected_repetitions = peakCount;
    return;
end

periodFit = polyfit((0:peakCount-1).', double(peaksLocal), 1);
measuredPeriod = periodFit(1);
clockErrorPpm = (measuredPeriod/symbolLength - 1)*1e6;
startSampleLocal = round(firstEndLocal - measuredPeriod + 1);

peaks = peaksLocal + roiStart - 1;
startSample = startSampleLocal + roiStart - 1;
strongestEnd = strongestEndLocal + roiStart - 1;

preamble = struct('matched', matchedRoi, 'score', scoreRoi, ...
    'metric', metric, 'metric_peak', metricPeak, ...
    'metric_peak_index', strongestEndLocal, ...
    'strongest_end', strongestEnd, 'threshold', threshold, ...
    'peaks', peaks, 'detected_repetitions', peakCount, ...
    'measured_period', measuredPeriod, 'clock_error_ppm', clockErrorPpm, ...
    'start_sample', startSample, 'search_half_width', searchHalfWidth, ...
    'roi_start', roiStart, 'roi_end', roiEnd, ...
    'matched_is_roi', true);
end

function preamble = emptyPreambleResult(searchHalfWidth, roiStart, roiEnd)
preamble = struct('matched', [], 'score', [], 'metric', [], ...
    'metric_peak', 0, 'metric_peak_index', 1, 'strongest_end', 1, ...
    'threshold', 0, 'peaks', zeros(0, 1), 'detected_repetitions', 0, ...
    'measured_period', NaN, 'clock_error_ppm', NaN, 'start_sample', 1, ...
    'search_half_width', searchHalfWidth, 'roi_start', roiStart, ...
    'roi_end', roiEnd, 'matched_is_roi', true);
end

function [coarseEnd, metricPeak] = coarsePreamblePeak(rx, template, ...
        symbolLength, accumulationCount, decimation)
templateDs = template(1:decimation:end);
templateDs = templateDs / (norm(templateDs) + eps);
rxDs = rx(1:decimation:end);
symbolDs = max(1, round(symbolLength/decimation));
matched = fftfilt(flipud(conj(templateDs)), rxDs);
energy = sqrt(movsum(abs(rxDs).^2, [symbolDs-1, 0]));
score = abs(matched) ./ (energy + eps);
metricLength = length(score) - (accumulationCount-1)*symbolDs;
if metricLength < 1
    error('detectRepeatedPreamble:CaptureTooShort', ...
        'Capture is too short for coarse preamble detection.');
end
metric = zeros(metricLength, 1);
for idx = 0:accumulationCount-1
    first = 1 + idx*symbolDs;
    metric = metric + score(first:first+metricLength-1);
end
[metricPeak, strongestEndDs] = max(metric);
% Map decimated metric index to an approximate full-rate sample index.
coarseEnd = (strongestEndDs-1)*decimation + 1;
end
