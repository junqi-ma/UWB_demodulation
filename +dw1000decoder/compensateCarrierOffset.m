function [rx, preamble] = compensateCarrierOffset(rx, preamble, reference, params)
%COMPENSATECARRIEROFFSET Estimate CFO and resolve constant complex phase.
%   [RX, PREAMBLE] = COMPENSATECARRIEROFFSET(RX, PREAMBLE, REFERENCE,
%   PARAMS) estimates the carrier-frequency offset from the stable
%   preamble peaks, derotates RX, and resolves the constant phase by
%   aligning against the known preamble waveform.
%
%   See also DECODE_X410_DW1000.

usablePeaks = preamble.peaks(1:min(preamble.detected_repetitions, ...
    params.preamble_repetitions));
peakValues = readMatchedAt(preamble, usablePeaks);
% The beginning of a file segment contains the receiver/resampler filter
% startup transient. Its curved phase previously looked like a false CFO
% (about -2.2 kHz in QM35_1.dat). Exclude up to the first 24 repetitions,
% while always retaining at least 32 repetitions for the linear fit.
skipCount = min(24, max(0, length(peakValues) - 32));
stablePeaks = usablePeaks(skipCount+1:end);
stableValues = peakValues(skipCount+1:end);
fitCount = min(240, length(stableValues));
fitTime = (double(stablePeaks(1:fitCount)) - ...
    double(stablePeaks(1))) / reference.fs;
fitPhase = unwrap(angle(stableValues(1:fitCount)));
phaseFit = polyfit(fitTime, fitPhase, 1);
frequencyOffset = phaseFit(1) / (2*pi);

nn = (0:numel(rx)-1).';
rx = rx(:) .* exp(-1j*2*pi*frequencyOffset*nn/reference.fs);

phaseRepetitions = min(32, preamble.detected_repetitions);
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

if isfield(params, 'verbose') && params.verbose
    fprintf('Estimated frequency offset: %.3f kHz.\n', frequencyOffset/1e3);
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
