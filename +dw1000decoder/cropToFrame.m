function [rx_cropped, preamble, info] = cropToFrame(rx, preamble, reference, params)
%CROPTOFRAME Keep only the active frame region of the work buffer.
%   Drops pre-frame samples and trims the tail to the soft-chip budget so
%   estimateCirAndSoftChips does not matched-filter a multi-ms capture.

rx = rx(:);
period = preamble.measured_period;
start_sample = preamble.start_sample;

frame_span = dw1000decoder.estimateFrameSampleSpan(preamble, reference, params);
pre_margin = ceil(3*period);
post_span = frame_span.post_samples;

crop_start = max(1, floor(start_sample-pre_margin));
crop_end = min(numel(rx), ceil(start_sample+post_span));
if crop_end <= crop_start
    error('Failed to form a valid frame crop region.');
end
if crop_end-start_sample+1 < round(0.5*post_span)
    % Tail is still short: keep everything remaining after start-margin.
    crop_end = numel(rx);
end

rx_cropped = rx(crop_start:crop_end);
shift = crop_start-1;
preamble.start_sample = preamble.start_sample-shift;
preamble.peaks = preamble.peaks-shift;
preamble.strongest_end = preamble.strongest_end-shift;

if isfield(preamble, 'matched_is_roi') && preamble.matched_is_roi
    roi_start = preamble.roi_start;
    matched_idx = (crop_start:crop_end)-roi_start+1;
    valid = matched_idx >= 1 & matched_idx <= numel(preamble.matched);
    matched_crop = zeros(crop_end-crop_start+1, 1, 'like', preamble.matched);
    score_crop = zeros(size(matched_crop), 'like', real(preamble.score(1)));
    matched_crop(valid) = preamble.matched(matched_idx(valid));
    score_crop(valid) = preamble.score(matched_idx(valid));
    preamble.matched = matched_crop;
    preamble.score = score_crop;
    preamble.matched_is_roi = false;
elseif isfield(preamble, 'matched') && numel(preamble.matched) == numel(rx)
    preamble.matched = preamble.matched(crop_start:crop_end);
    if isfield(preamble, 'score') && numel(preamble.score) == numel(rx)
        preamble.score = preamble.score(crop_start:crop_end);
    end
end

info = struct('crop_start', crop_start, 'crop_end', crop_end, ...
    'original_length', numel(rx), 'cropped_length', numel(rx_cropped), ...
    'post_samples', post_span, 'n_chips_budget', frame_span.n_chips);
if isfield(params, 'verbose') && params.verbose
    fprintf(['Cropped work buffer %d:%d (%d -> %d samples, ', ...
        'soft-chip budget %d).\n'], ...
        crop_start, crop_end, numel(rx), numel(rx_cropped), frame_span.n_chips);
end
end
