function preamble = detectRepeatedPreamble(rx, reference, params, seededStart)
%DETECTREPEATEDPREAMBLE 检测并跟踪重复出现的 SYNC 前导符号。
%   PREAMBLE = DETECTREPEATEDPREAMBLE(RX, REFERENCE, PARAMS) 采用与
%   decode_uwb_all 相同的三步思想：低成本能量门控缩小搜索范围、仅对
%   首个 SYNC 提取相关候选、再逐个验证后续 SYNC。确认候选后才对该
%   前导做局部峰跟踪和周期拟合；若自适应路径失败，回退到旧的两级相关。
%
%   See also DECODE_X410_DW1000, VALIDATECAPTURELENGTH.

rx = rx(:);
if nargin < 4
    seededStart = [];
end
symbolLength = reference.samples_per_symbol;
% Match against the shaped SYNC waveform actually present in the received
% signal. The bare spreading code (sampled_code) is the right template only
% for CIR estimation, where the pulse shape must be de-convolved; using it
% here is a mismatched filter that collapses detection SNR.
template = reference.preamble_waveform(:);

% 快速路径：能量门控后，仅扫描候选区域的第一个 SYNC；随后顺序验证
% 少量重复符号。该路径避免构造完整 ROI 的 16 路相关 metric。
if isempty(seededStart) || ~isfinite(seededStart)
    preamble = detectAdaptivePreamble(rx, template, symbolLength, params);
else
    preamble = detectSeededPreamble( ...
        rx, template, symbolLength, seededStart, params);
    if preamble.detected_repetitions < 32
        preamble = detectAdaptivePreamble(rx, template, symbolLength, params);
    end
end

% 兼容性回退：弱信号或异常能量区域下，保留原有全速率相关逻辑。
if preamble.detected_repetitions < 32
    if isfield(params, 'verbose') && params.verbose
        fprintf(['Adaptive preamble detector found only %d peaks; ', ...
            'falling back to legacy full-rate search.\n'], ...
            preamble.detected_repetitions);
    end
    preamble = detectLegacyPreamble(rx, template, symbolLength, params);
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
function preamble = detectSeededPreamble( ...
        rx, template, symbolLength, seededStart, params)
%DETECTSEEDEDPREAMBLE Confirm and track a full-capture detector candidate.
%   SEEDEDSTART is a one-based template start in RX. Only a narrow interval
%   is correlated; the existing full detector remains the fallback path.

maxStart = numel(rx) - symbolLength + 1;
if maxStart < 1
    preamble = emptyPreambleResult(8, 1, numel(rx));
    return;
end
seededStart = min(max(1, round(seededStart)), maxStart);
searchRadius = max(64, ceil(symbolLength/32));
interval = [max(1, seededStart - searchRadius), ...
    min(maxStart, seededStart + searchRadius)];
[starts, scoreEnergy, noiseThreshold] = scanFirstSync( ...
    rx, interval, template, symbolLength);
[peakEnergy, peakIdx] = max(scoreEnergy);
candidateStart = starts(peakIdx);
validation = validateSyncCandidate( ...
    rx, candidateStart, template, symbolLength, noiseThreshold, ...
    max(noiseThreshold, 0.20*peakEnergy), params);
if ~validation.detected
    preamble = emptyPreambleResult(8, 1, numel(rx));
    return;
end
preamble = buildDirectSeededPreamble(rx, template, symbolLength, ...
    candidateStart, sqrt(max(noiseThreshold, 0.20*peakEnergy)), ...
    peakEnergy, interval, params);
if preamble.detected_repetitions >= 32
    preamble.detector = 'seeded_direct_sfd_candidate';
end
end

function preamble = buildDirectSeededPreamble(rx, template, symbolLength, ...
        candidateStart, threshold, peakEnergy, interval, params)
%BUILDDIRECTSEEDEDPREAMBLE Confirm the first SYNC without tracking all of it.
%   Stage 2 already supplied a packet candidate. Correct a candidate that
%   landed on one of the next few repetitions, then describe the remaining
%   preamble on the configured symbol grid. Full-rate NS-SFD correlation
%   refines the start before CFO and CIR estimation.

searchHalfWidth = 8;
firstStart = candidateStart;
for backwardCount = 1:4
    expected = firstStart - symbolLength;
    [bestStart, bestScore] = localBestStart( ...
        rx, expected, searchHalfWidth, template);
    if isempty(bestStart) || bestScore < threshold
        break;
    end
    firstStart = bestStart;
end

availableRepetitions = max(0, floor( ...
    (numel(rx) - firstStart + 1)/symbolLength));
repetitionCount = min(params.preamble_repetitions, availableRepetitions);
starts = firstStart + (0:repetitionCount-1).'*symbolLength;
peaks = starts + symbolLength - 1;

preamble = struct( ...
    'matched', complex(zeros(0, 1)), 'score', zeros(0, 1), ...
    'metric', peakEnergy, 'metric_peak', sqrt(peakEnergy), ...
    'metric_peak_index', 1, ...
    'strongest_end', firstStart + symbolLength - 1, ...
    'threshold', threshold, 'peaks', peaks, ...
    'detected_repetitions', repetitionCount, ...
    'measured_period', double(symbolLength), 'clock_error_ppm', 0, ...
    'start_sample', firstStart, 'search_half_width', searchHalfWidth, ...
    'roi_start', interval(1), 'roi_end', interval(2), ...
    'matched_is_roi', false, 'direct_sfd_timing', true, ...
    'detector', 'seeded_direct_sfd_candidate');
end

% -------------------------------------------------------------------------
function preamble = detectAdaptivePreamble(rx, template, symbolLength, params)
%DETECTADAPTIVEPREAMBLE 单包版的能量门控 + 候选验证检测器。
[rawRegions, guardedRegions] = findAdaptiveEnergyRegions(rx, symbolLength);

for regionIdx = 1:size(rawRegions, 1)
    detection = adaptiveCorrelationCandidate(rx, template, symbolLength, ...
        rawRegions(regionIdx, :), guardedRegions(regionIdx, :), params);
    if ~detection.detected
        continue;
    end

    candidatePreamble = trackCandidatePreamble(rx, template, symbolLength, ...
        detection.candidate_start, sqrt(detection.threshold_energy), params);
    % 单包解码沿用原有“最早包优先”语义；多包保留由 decode_uwb_all 负责。
    if candidatePreamble.detected_repetitions >= 32
        preamble = candidatePreamble;
        return;
    end
end
preamble = emptyPreambleResult(8, 1, numel(rx));
end

function [rawRegions, guardedRegions] = findAdaptiveEnergyRegions(rx, symbolLength)
% 以低成本抽取能量包络定位潜在包区域。这里不做相关运算。
nRx = numel(rx);
stride = 32;
if nRx < 8*symbolLength
    stride = 1;
end
sampleIdx = (1:stride:nRx).';
rxDs = rx(sampleIdx);
smoothLength = max(3, round(4*symbolLength/stride));
energy = movmean(abs(rxDs).^2, smoothLength);

sortedEnergy = sort(energy);
baselineCount = min(numel(sortedEnergy), max(32, floor(0.30*numel(sortedEnergy))));
baseline = sortedEnergy(1:baselineCount);
medianEnergy = median(baseline);
sigmaEnergy = 1.4826*median(abs(baseline - medianEnergy));
high = medianEnergy + 6*max(sigmaEnergy, eps(max(abs(medianEnergy), 1)));
low = medianEnergy + 3*max(sigmaEnergy, eps(max(abs(medianEnergy), 1)));

highMask = energy > high;
lowMask = energy > low;
edges = diff([false; lowMask(:); false]);
runStarts = find(edges == 1);
runEnds = find(edges == -1) - 1;
rawRegions = zeros(0, 2);
minRegionSamples = 2*symbolLength;
for k = 1:numel(runStarts)
    first = runStarts(k);
    last = runEnds(k);
    if ~any(highMask(first:last))
        continue;
    end
    rawFirst = sampleIdx(first);
    rawLast = min(nRx, sampleIdx(last) + stride - 1);
    if rawLast - rawFirst + 1 >= minRegionSamples
        rawRegions(end+1, :) = [rawFirst, rawLast]; %#ok<AGROW>
    end
end

% 能量门控失败时仍允许候选相关扫描全捕获，保证检测器不会静默漏包。
if isempty(rawRegions)
    rawRegions = [1, nRx];
end
rawRegions = mergeIntervals(rawRegions, 4*symbolLength);
guard = 16*symbolLength;
guardedRegions = [max(1, rawRegions(:, 1)-guard), ...
    min(nRx, rawRegions(:, 2)+guard)];
end

function detection = adaptiveCorrelationCandidate(rx, template, symbolLength, rawRegion, guardedRegion, params)
% 先在窄窗口找首 SYNC；失败时只扩展尚未扫描的区域。
nRx = numel(rx);
pre = [5, 15]*symbolLength;
post = [12, 30]*symbolLength;
levels = [ ...
    max(1, rawRegion(1)-pre(1)), min(nRx-symbolLength+1, rawRegion(1)+post(1)); ...
    max(1, rawRegion(1)-pre(2)), min(nRx-symbolLength+1, rawRegion(1)+post(2)); ...
    max(1, guardedRegion(1)), min(nRx-symbolLength+1, guardedRegion(2))];

detection = struct('detected', false, 'candidate_start', 1, ...
    'threshold_energy', Inf, 'repetitions_used', 0);
previous = zeros(0, 2);
for level = 1:size(levels, 1)
    intervals = newSearchIntervals(levels(level, :), previous);
    for intervalIdx = 1:size(intervals, 1)
        interval = intervals(intervalIdx, :);
        [starts, scoreEnergy, threshold] = scanFirstSync( ...
            rx, interval, template, symbolLength);
        [candidates, candidateEnergy] = extractCandidates( ...
            starts, scoreEnergy, threshold, ...
            max(1, round(0.4*symbolLength)));
        % 优先验证最强的少量峰；弱峰会在强峰失败后由更宽搜索区覆盖。
        for candidateIdx = 1:min(8, numel(candidates))
            validation = validateSyncCandidate(rx, candidates(candidateIdx), ...
                template, symbolLength, threshold, ...
                max(threshold, 0.20*candidateEnergy(candidateIdx)), params);
            if validation.detected
                detection = validation;
                return;
            end
        end
    end
    previous = levels(level, :);
end
end

function [starts, scoreEnergy, threshold] = scanFirstSync(rx, interval, template, symbolLength)
% 对搜索区的每个可能起点计算一次归一化 SYNC 相关。
width = interval(2) - interval(1) + 1;
segment = rx(interval(1):interval(2)+symbolLength-1);
matched = uwbdecoder.fftFilter(flipud(conj(template)), segment);
energy = sqrt(movsum(abs(segment).^2, [symbolLength-1, 0])) + eps;
score = abs(matched)./energy;
score = score(symbolLength:symbolLength+width-1);
scoreEnergy = score.^2;
threshold = robustEnergyThreshold(scoreEnergy);
starts = (interval(1):interval(2)).';
end

function [candidates, values] = extractCandidates(starts, energy, threshold, minDistance)
% 使用局部峰而非每个超阈值采样点作为后续验证候选。
level = max(threshold, 0.20*max(energy));
locs = simpleFindPeaks(energy, level, minDistance);
candidates = starts(locs);
values = energy(locs);
if ~isempty(candidates)
    [~, order] = sort(values, 'descend');
    candidates = candidates(order);
    values = values(order);
end
end

function result = validateSyncCandidate(rx, candidateStart, template, symbolLength, ...
        noiseThreshold, perRepetitionThreshold, params)
% 顺序验证后续 SYNC；达到可靠判据即提前停止，无需跟踪完整前导。
maxRepetitions = min(8, params.preamble_repetitions);
minRepetitions = min(3, maxRepetitions);
perRepEnergy = zeros(maxRepetitions, 1);
hitCount = 0;
for repetition = 1:maxRepetitions
    start = candidateStart + (repetition-1)*symbolLength;
    if start < 1 || start + symbolLength - 1 > numel(rx)
        break;
    end
    score = normalizedTemplateScore(rx, start, template);
    perRepEnergy(repetition) = score^2;
    hitCount = hitCount + (perRepEnergy(repetition) > perRepetitionThreshold);
    runningRatio = mean(perRepEnergy(1:repetition))/max(noiseThreshold, eps);
    if repetition >= minRepetitions && hitCount == repetition && runningRatio >= 20
        result = struct('detected', true, 'candidate_start', candidateStart, ...
            'threshold_energy', perRepetitionThreshold, ...
            'repetitions_used', repetition);
        return;
    end
end
result = struct('detected', false, 'candidate_start', candidateStart, ...
    'threshold_energy', perRepetitionThreshold, 'repetitions_used', repetition);
end

function preamble = trackCandidatePreamble(rx, template, symbolLength, ...
        candidateStart, threshold, params, maxBackwardRepetitions)
% 候选确认后才做局部峰跟踪。下游 CFO 至少需要 32 个峰，CIR 默认使用
% 64 个 SYNC，因此不必遍历全部前导字段。
if nargin < 7
    maxBackwardRepetitions = inf;
end
searchHalfWidth = 8;
firstStart = candidateStart;
backwardCount = 0;
if maxBackwardRepetitions > 0
    while backwardCount < maxBackwardRepetitions
        expected = firstStart - symbolLength;
        [bestStart, bestScore] = localBestStart( ...
            rx, expected, searchHalfWidth, template);
        if isempty(bestStart) || bestScore < threshold
            break;
        end
        firstStart = bestStart;
        backwardCount = backwardCount + 1;
    end
end

maxPeaks = min(params.preamble_repetitions, ...
    max(64, params.cir_repetitions));
starts = zeros(maxPeaks, 1);
scores = zeros(maxPeaks, 1);
matches = complex(zeros(maxPeaks, 1));
peakCount = 0;
currentStart = firstStart;
while peakCount < maxPeaks
    [bestStart, bestScore, bestMatch] = localBestStart( ...
        rx, currentStart, searchHalfWidth, template);
    if isempty(bestStart) || bestScore < threshold
        break;
    end
    peakCount = peakCount + 1;
    starts(peakCount) = bestStart;
    scores(peakCount) = bestScore;
    matches(peakCount) = bestMatch;
    currentStart = bestStart + symbolLength;
end
starts = starts(1:peakCount);
scores = scores(1:peakCount);
matches = matches(1:peakCount);
if peakCount < 2
    preamble = emptyPreambleResult(searchHalfWidth, 1, numel(rx));
    preamble.detected_repetitions = peakCount;
    return;
end

periodFit = polyfit((0:peakCount-1).', double(starts), 1);
measuredPeriod = periodFit(1);
startSample = round(periodFit(2));
peaks = starts + symbolLength - 1;
[metricPeak, strongestIdx] = max(scores);
roiStart = max(1, min(peaks) - 2*symbolLength);
roiEnd = min(numel(rx), max(peaks) + 2*symbolLength);
matched = complex(zeros(roiEnd-roiStart+1, 1));
score = zeros(size(matched));
localPeakIdx = peaks - roiStart + 1;
matched(localPeakIdx) = matches;
score(localPeakIdx) = scores;

preamble = struct('matched', matched, 'score', score, ...
    'metric', scores, 'metric_peak', metricPeak, ...
    'metric_peak_index', strongestIdx, ...
    'strongest_end', peaks(strongestIdx), 'threshold', threshold, ...
    'peaks', peaks, 'detected_repetitions', peakCount, ...
    'measured_period', measuredPeriod, ...
    'clock_error_ppm', (measuredPeriod/symbolLength - 1)*1e6, ...
    'start_sample', startSample, 'search_half_width', searchHalfWidth, ...
    'roi_start', roiStart, 'roi_end', roiEnd, 'matched_is_roi', true, ...
    'detector', 'adaptive_energy_candidate');
end

function [bestStart, bestScore, bestMatch] = localBestStart(rx, expectedStart, halfWidth, template)
% 在预期起点附近小范围搜索，吸收每个 SYNC 的整数采样时钟漂移。
starts = (expectedStart-halfWidth):(expectedStart+halfWidth);
valid = starts >= 1 & starts + numel(template) - 1 <= numel(rx);
starts = starts(valid);
if isempty(starts)
    bestStart = []; bestScore = []; bestMatch = [];
    return;
end
segment = rx(starts(1):starts(end)+numel(template)-1);
matches = conv(segment, flipud(conj(template)), 'valid');
windowEnergy = real(conv(abs(segment).^2, ...
    ones(numel(template), 1, 'like', segment), 'valid'));
scores = abs(matches)./(sqrt(max(windowEnergy, 0)) + eps);
[bestScore, idx] = max(scores);
bestStart = starts(idx);
bestMatch = matches(idx);
end

function score = normalizedTemplateScore(rx, start, template)
window = rx(start:start+numel(template)-1);
score = abs(sum(window.*conj(template)))/(sqrt(sum(abs(window).^2)) + eps);
end

function threshold = robustEnergyThreshold(energy)
sortedEnergy = sort(energy);
count = min(numel(sortedEnergy), max(16, floor(0.60*numel(sortedEnergy))));
baseline = sortedEnergy(1:count);
medianEnergy = median(baseline);
sigmaEnergy = 1.4826*median(abs(baseline - medianEnergy));
threshold = medianEnergy + 5*max(sigmaEnergy, eps);
end

function locs = simpleFindPeaks(metric, threshold, minSeparation)
% 不依赖 Signal Toolbox 的局部峰提取，并按峰值强度实施最小间距抑制。
if numel(metric) < 3
    locs = zeros(0, 1);
    return;
end
candidates = find(metric(2:end-1) >= threshold & ...
    metric(2:end-1) >= metric(1:end-2) & ...
    metric(2:end-1) >= metric(3:end)) + 1;
if isempty(candidates)
    locs = zeros(0, 1);
    return;
end
[~, order] = sort(metric(candidates), 'descend');
candidates = candidates(order);
keep = false(size(candidates));
for k = 1:numel(candidates)
    if all(abs(candidates(k) - candidates(keep)) >= minSeparation)
        keep(k) = true;
    end
end
locs = sort(candidates(keep));
end

function intervals = newSearchIntervals(current, previous)
if isempty(previous)
    intervals = current;
    return;
end
intervals = zeros(0, 2);
if current(1) < previous(1)
    intervals(end+1, :) = [current(1), previous(1)-1];
end
if current(2) > previous(2)
    intervals(end+1, :) = [previous(2)+1, current(2)];
end
end

function intervals = mergeIntervals(intervals, gap)
if isempty(intervals), return; end
intervals = sortrows(intervals, [1, 2]);
merged = intervals(1, :);
for k = 2:size(intervals, 1)
    if intervals(k, 1) <= merged(end, 2) + gap + 1
        merged(end, 2) = max(merged(end, 2), intervals(k, 2));
    else
        merged(end+1, :) = intervals(k, :); %#ok<AGROW>
    end
end
intervals = merged;
end

function preamble = detectLegacyPreamble(rx, template, symbolLength, params)
% 原始两级相关检测，仅作为自适应路径失败时的可靠性回退。
nRx = numel(rx);
searchHalfWidth = 8;
accumulationCount = 16;
decimation = 4;
if nRx < 8*symbolLength, decimation = 1; end
[coarseEnd, ~] = coarsePreamblePeak(rx, template, symbolLength, ...
    accumulationCount, decimation);
roiPre = (params.preamble_repetitions + 32)*symbolLength;
roiPost = roiPre;
roiStart = max(1, round(coarseEnd) - roiPre);
roiEnd = min(nRx, round(coarseEnd) + roiPost);
preamble = trackPreambleInRoi(rx, template, symbolLength, ...
    accumulationCount, searchHalfWidth, params, roiStart, roiEnd);
if preamble.detected_repetitions < 32
    preamble = trackPreambleInRoi(rx, template, symbolLength, ...
        accumulationCount, searchHalfWidth, params, 1, nRx);
end
if isstruct(preamble)
    preamble.detector = 'legacy_full_metric';
end
end

function preamble = trackPreambleInRoi(rx, template, symbolLength, ...
        accumulationCount, searchHalfWidth, params, roiStart, roiEnd)
% 在指定 ROI 内完成全采样率匹配、重复 metric 构造和峰值跟踪。
roi = rx(roiStart:roiEnd);
% 匹配滤波输出每个采样点与完整 SYNC 模板的相关幅度。
matchedRoi = uwbdecoder.fftFilter(flipud(conj(template)), roi);
% 用滑动窗口信号能量进行归一化，减小幅度变化和噪声功率的影响。
energy = sqrt(movsum(abs(roi).^2, [symbolLength-1, 0]));
scoreRoi = abs(matchedRoi) ./ (energy + eps);

% 将相隔一个 SYNC 周期的 score 相加，突出连续重复的前导。
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

% 阈值只从最强峰附近估计，避免长时间静默区影响 MAD 噪声底估计。
% 阈值同时受到“局部统计噪声底”和“最强峰固定比例”的约束。
thrLo = max(1, strongestEndLocal - 8*symbolLength);
thrHi = min(numel(scoreRoi), strongestEndLocal + 8*symbolLength);
scoreSample = scoreRoi(thrLo:max(1, round(symbolLength/8)):thrHi);
if numel(scoreSample) < 32
    scoreSample = scoreRoi(1:16:end);
end
scoreMedian = median(scoreSample);
scoreSigma = 1.4826*median(abs(scoreSample - scoreMedian));
threshold = max(scoreMedian + 6*scoreSigma, 0.20*scoreRoi(strongestEndLocal));

% 从最强峰向前按一个 SYNC 周期回溯，寻找最早的连续前导符号。
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

% 从最早峰向后按一个 SYNC 周期跟踪，允许每个峰在 ±8 个采样内微调。
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
    % 少于两个峰无法拟合 SYNC 周期，保留中间量供调试并返回空结果。
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

% 对峰位置做线性拟合：斜率是实际 SYNC 周期，进而得到采样时钟误差。
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
% 构造检测失败或有效峰数量不足时的统一空结果。
preamble = struct('matched', [], 'score', [], 'metric', [], ...
    'metric_peak', 0, 'metric_peak_index', 1, 'strongest_end', 1, ...
    'threshold', 0, 'peaks', zeros(0, 1), 'detected_repetitions', 0, ...
    'measured_period', NaN, 'clock_error_ppm', NaN, 'start_sample', 1, ...
    'search_half_width', searchHalfWidth, 'roi_start', roiStart, ...
    'roi_end', roiEnd, 'matched_is_roi', true);
end

function [coarseEnd, metricPeak] = coarsePreamblePeak(rx, template, ...
        symbolLength, accumulationCount, decimation)
% 低采样率粗搜索：只返回一个用于构造 ROI 的大致峰位置。
templateDs = template(1:decimation:end);
templateDs = templateDs / (norm(templateDs) + eps);
rxDs = rx(1:decimation:end);
symbolDs = max(1, round(symbolLength/decimation));
matched = uwbdecoder.fftFilter(flipud(conj(templateDs)), rxDs);
% 粗搜索同样使用能量归一化和 16 个周期的重复累加。
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
% 将抽取域的峰位置映射回全采样率工作缓冲区。
coarseEnd = (strongestEndDs-1)*decimation + 1;
end
