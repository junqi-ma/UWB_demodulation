function [rx, info] = applyBlankIntervals(rx, sample_offset, intervals, ...
        taper_samples, blank_weight)
%APPLYBLANKINTERVALS Soft-blank absolute capture intervals inside a window.
%   INTERVALS is N-by-2 absolute complex-sample indices [start end] (0-based
%   start preferred; both ends treated as inclusive absolute indices).
%   BLANK_WEIGHT in [0,1]: 0 fully zeros the interferer, 1 leaves it unchanged.

rx = rx(:);
n = numel(rx);
info = struct('applied_count', 0, 'samples_touched', 0);
if isempty(intervals) || n < 1
    return;
end

taper_samples = max(0, round(taper_samples));
blank_weight = min(1, max(0, blank_weight));
win_start = sample_offset;                 % absolute index of rx(1)
win_end = sample_offset + n - 1;           % absolute index of rx(end)

mask = ones(n, 1);
for k = 1:size(intervals, 1)
    a = min(intervals(k, 1), intervals(k, 2));
    b = max(intervals(k, 1), intervals(k, 2));
    % Overlap of [a,b] with [win_start, win_end] in absolute samples.
    o0 = max(a, win_start);
    o1 = min(b, win_end);
    if o1 < o0
        continue;
    end
    i0 = o0 - win_start + 1;
    i1 = o1 - win_start + 1;
    seg_len = i1 - i0 + 1;
    if seg_len < 1
        continue;
    end

    w = blank_weight * ones(seg_len, 1);
    if taper_samples > 0 && seg_len > 2
        tlen = min(taper_samples, floor(seg_len/2));
        if tlen >= 1
            ramp = 0.5 - 0.5*cos(pi*(0:tlen-1).'/tlen);  % 0->1
            % Outside interferer weight=1; inside core weight=blank_weight.
            % Edge: blend 1 -> blank_weight.
            w(1:tlen) = 1 - (1-blank_weight)*ramp;
            w(end-tlen+1:end) = 1 - (1-blank_weight)*flipud(ramp);
            if seg_len > 2*tlen
                w(tlen+1:end-tlen) = blank_weight;
            end
        end
    end
    mask(i0:i1) = min(mask(i0:i1), w);
    info.applied_count = info.applied_count + 1;
    info.samples_touched = info.samples_touched + seg_len;
end

rx = rx .* mask;
end
