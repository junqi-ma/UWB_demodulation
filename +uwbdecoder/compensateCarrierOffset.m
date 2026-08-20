function [rx, preamble] = compensateCarrierOffset(rx, preamble, reference, params)
%COMPENSATECARRIEROFFSET Estimate CFO and resolve constant complex phase.
%   [RX, PREAMBLE] = COMPENSATECARRIEROFFSET(RX, PREAMBLE, REFERENCE,
%   PARAMS) estimates the carrier-frequency offset from the stable
%   preamble peaks, derotates RX, and resolves the constant phase by
%   aligning against the known preamble waveform.
%
%   See also DECODE_X410_DW1000.

directTiming = isfield(preamble, 'direct_sfd_timing') && ...
    preamble.direct_sfd_timing;
% After NS-SFD refine, start_sample is on the sampled_code chip grid.
% preamble_waveform is delayed by the pulse-shaping group delay, so a
% correlation at that origin lands in the chip gaps. Seeded detection
% without SFD refine is already waveform-aligned; do not shift it.
shapingDelay = 0;
if directTiming && sfdRefinedToCodeGrid(preamble)
    shapingDelay = pulseShapingDelaySamples(reference);
end
if directTiming
    [stablePeaks, stableValues, skipCount] = directCfoAnchors( ...
        rx, preamble, reference, params, shapingDelay);
else
    usablePeaks = preamble.peaks(1:min(preamble.detected_repetitions, ...
        params.preamble_repetitions));
    peakValues = readMatchedAt(preamble, usablePeaks);
    % The beginning of a file segment can contain a receiver front-end
    % startup transient. Exclude up to the first 24 repetitions, while
    % retaining at least 32 repetitions for the linear fit.
    skipCount = min(24, max(0, length(peakValues) - 32));
    stablePeaks = usablePeaks(skipCount+1:end);
    stableValues = peakValues(skipCount+1:end);
end
fitCount = min(240, length(stableValues));
fitTime = (double(stablePeaks(1:fitCount)) - ...
    double(stablePeaks(1))) / reference.fs;
fitPhase = unwrap(angle(stableValues(1:fitCount)));
phaseFit = polyfit(fitTime, fitPhase, 1);
frequencyOffset = phaseFit(1) / (2*pi);

nn = (0:numel(rx)-1).';
rx = rx(:) .* exp(-1j*2*pi*frequencyOffset*nn/reference.fs);

if directTiming
    phaseRepetitions = min(8, preamble.detected_repetitions);
else
    phaseRepetitions = min(32, preamble.detected_repetitions);
end
known = repmat(reference.preamble_waveform, phaseRepetitions, 1);
firstRepetition = max(0, params.preamble_repetitions - phaseRepetitions);
phaseStart = round(preamble.start_sample + firstRepetition*preamble.measured_period);
phaseStart = phaseStart - shapingDelay;
phaseIndices = phaseStart + (0:length(known)-1);
if phaseIndices(1) < 1 || phaseIndices(end) > numel(rx)
    error('compensateCarrierOffset:PhaseWindowOutOfBounds', ...
        'Carrier-phase alignment window falls outside the work buffer.');
end
gain = known' * rx(phaseIndices);
rx = rx * exp(-1j*angle(gain));
preamble.frequency_offset_hz = frequencyOffset;
preamble.frequency_offset_skipped_repetitions = skipCount;
preamble.frequency_offset_anchor_count = fitCount;
preamble.frequency_offset_shaping_delay_samples = shapingDelay;

if isfield(params, 'verbose') && params.verbose
    fprintf('Estimated frequency offset: %.3f kHz.\n', frequencyOffset/1e3);
end

% -------------------------------------------------------------------------
function [peaks, values, skipCount] = directCfoAnchors( ...
        rx, preamble, reference, params, shapingDelay)
%DIRECTCFOANCHORS Correlate a small set of widely spaced known SYNCs.
%   SFD timing has already fixed the code-grid origin. The shaped SYNC
%   waveform is placed shapingDelay samples earlier so its pulse peaks
%   land on that grid instead of in the chip gaps.

available = min(params.preamble_repetitions, ...
    preamble.detected_repetitions);
skipCount = min(8, max(0, available - 8));
anchorCount = min(16, available - skipCount);
if anchorCount < 2
    error('compensateCarrierOffset:TooFewAnchors', ...
        'At least two preamble repetitions are required for CFO estimation.');
end
repetitions = unique(round(linspace( ...
    skipCount, available - 1, anchorCount))).';
starts = round(preamble.start_sample + ...
    repetitions*preamble.measured_period) - shapingDelay;
sampleOffsets = (0:numel(reference.preamble_waveform)-1).';
indices = sampleOffsets + starts.';
valid = all(indices >= 1 & indices <= numel(rx), 1);
indices = indices(:, valid);
starts = starts(valid);
if numel(starts) < 2
    error('compensateCarrierOffset:AnchorWindowOutOfBounds', ...
        'Too few complete preamble anchors remain inside the work buffer.');
end
segments = rx(indices);
values = sum(segments.*conj(reference.preamble_waveform), 1).';
peaks = starts + reference.samples_per_symbol - 1;
end
end

% -------------------------------------------------------------------------
function values = readMatchedAt(preamble, absolutePeaks)
if isfield(preamble, 'matched_is_roi') && preamble.matched_is_roi
    idx = absolutePeaks - preamble.roi_start + 1;
else
    idx = absolutePeaks;
end
if any(idx < 1) || any(idx > numel(preamble.matched))
    error('compensateCarrierOffset:PeakOutOfBounds', ...
        'Preamble peak indices fall outside the matched-filter buffer.');
end
values = preamble.matched(idx);
end

% -------------------------------------------------------------------------
function tf = sfdRefinedToCodeGrid(preamble)
tf = isfield(preamble, 'sfd_waveform_correlation') && ...
    isfinite(preamble.sfd_waveform_correlation) && ...
    preamble.sfd_waveform_correlation >= 0.10;
end

function delay = pulseShapingDelaySamples(reference)
%PULSESHAPINGDELAYSAMPLES Group delay of preamble_waveform vs sampled_code.
%   First-chip peak of the shaped SYNC relative to the first spreading
%   impulse. This is a property of the PHY reference, not of a capture.

delay = 0;
if ~isstruct(reference) || ~isfield(reference, 'sampled_code') || ...
        ~isfield(reference, 'preamble_waveform')
    return
end
code = reference.sampled_code(:);
wave = reference.preamble_waveform(:);
if isempty(code) || isempty(wave)
    return
end
impulse = find(abs(code) > 0, 1);
if isempty(impulse)
    return
end
nextRel = find(abs(code(impulse+1:end)) > 0, 1);
if isempty(nextRel)
    last = min(numel(wave), impulse + 16);
else
    last = min(numel(wave), impulse + nextRel - 1);
end
if last < impulse
    return
end
segment = abs(wave(impulse:last));
if ~any(segment)
    return
end
[~, rel] = max(segment);
delay = rel - 1;
end
