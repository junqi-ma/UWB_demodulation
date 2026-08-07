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
if directTiming
    [stablePeaks, stableValues, skipCount] = directCfoAnchors( ...
        rx, preamble, reference, params);
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

if isfield(params, 'verbose') && params.verbose
    fprintf('Estimated frequency offset: %.3f kHz.\n', frequencyOffset/1e3);
end

% -------------------------------------------------------------------------
function [peaks, values, skipCount] = directCfoAnchors( ...
        rx, preamble, reference, params)
%DIRECTCFOANCHORS Correlate a small set of widely spaced known SYNCs.
%   SFD timing has already fixed the preamble origin, so there is no need
%   to perform a local timing search for every repeated symbol.

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
    repetitions*preamble.measured_period);
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
