function [rxCropped, preamble, info] = cropToFrame(rx, preamble, reference, params)
%CROPTOFRAME Keep only the active frame region of the work buffer.
%   [RXCROPPED, PREAMBLE, INFO] = CROPTOFRAME(RX, PREAMBLE, REFERENCE,
%   PARAMS) drops pre-frame samples and trims the tail to the soft-chip
%   budget so ESTIMATECIRANDSOFTCHIPS does not matched-filter a multi-ms
%   capture. PREAMBLE peak/start fields are shifted to the cropped frame.
%
%   See also ESTIMATEFRAMESAMPLESPAN, ESTIMATECIRANDSOFTCHIPS.

rx = rx(:);
period = preamble.measured_period;
startSample = preamble.start_sample;

frameSpan = uwbdecoder.estimateFrameSampleSpan(preamble, reference, params);
preMargin = ceil(3*period);
postSpan = frameSpan.post_samples;

cropStart = max(1, floor(startSample - preMargin));
cropEnd = min(numel(rx), ceil(startSample + postSpan));
if cropEnd <= cropStart
    error('cropToFrame:InvalidCropRegion', ...
        'Failed to form a valid frame crop region.');
end
if cropEnd - startSample + 1 < round(0.5*postSpan)
    % Tail is still short: keep everything remaining after start-margin.
    cropEnd = numel(rx);
end

rxCropped = rx(cropStart:cropEnd);
shift = cropStart - 1;
preamble.start_sample = preamble.start_sample - shift;
preamble.peaks = preamble.peaks - shift;
preamble.strongest_end = preamble.strongest_end - shift;

if isfield(preamble, 'matched_is_roi') && preamble.matched_is_roi
    roiStart = preamble.roi_start;
    matchedIdx = (cropStart:cropEnd) - roiStart + 1;
    valid = matchedIdx >= 1 & matchedIdx <= numel(preamble.matched);
    matchedCrop = complex(zeros(cropEnd - cropStart + 1, 1));
    scoreCrop = zeros(size(matchedCrop));
    matchedCrop(valid) = preamble.matched(matchedIdx(valid));
    scoreCrop(valid) = preamble.score(matchedIdx(valid));
    preamble.matched = matchedCrop;
    preamble.score = scoreCrop;
    preamble.matched_is_roi = false;
elseif isfield(preamble, 'matched') && numel(preamble.matched) == numel(rx)
    preamble.matched = preamble.matched(cropStart:cropEnd);
    if isfield(preamble, 'score') && numel(preamble.score) == numel(rx)
        preamble.score = preamble.score(cropStart:cropEnd);
    end
end

info = struct('crop_start', cropStart, 'crop_end', cropEnd, ...
    'original_length', numel(rx), 'cropped_length', numel(rxCropped), ...
    'post_samples', postSpan, 'n_chips_budget', frameSpan.n_chips);

if isfield(params, 'verbose') && params.verbose
    fprintf(['Cropped work buffer %d:%d (%d -> %d samples, ', ...
        'soft-chip budget %d).\n'], ...
        cropStart, cropEnd, numel(rx), numel(rxCropped), frameSpan.n_chips);
end
end
