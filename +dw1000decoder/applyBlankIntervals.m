function [rx, info] = applyBlankIntervals(rx, sampleOffset, intervals, ...
        taperSamples, blankWeight)
%APPLYBLANKINTERVALS Soft-blank absolute capture intervals inside a window.
%   [RX, INFO] = APPLYBLANKINTERVALS(RX, SAMPLEOFFSET, INTERVALS,
%   TAPERSAMPLES, BLANKWEIGHT) multiplies the samples in each absolute
%   interval by a weight between BLANKWEIGHT and 1, with a cosine taper at
%   each edge. INTERVALS is N-by-2 in absolute complex-sample indices
%   [start end] (inclusive). BLANKWEIGHT in [0,1]: 0 fully zeros the
%   interferer, 1 leaves it unchanged.
%
%   See also READANDCANCELINTERFERENCE.

rx = rx(:);
n = numel(rx);
info = struct('applied_count', 0, 'samples_touched', 0);
if isempty(intervals) || n < 1
    return;
end

taperSamples = max(0, round(taperSamples));
blankWeight = min(1, max(0, blankWeight));
winStart = sampleOffset;                 % absolute index of rx(1)
winEnd = sampleOffset + n - 1;           % absolute index of rx(end)

mask = ones(n, 1);
for k = 1:size(intervals, 1)
    a = min(intervals(k, 1), intervals(k, 2));
    b = max(intervals(k, 1), intervals(k, 2));
    % Overlap of [a,b] with [winStart, winEnd] in absolute samples.
    o0 = max(a, winStart);
    o1 = min(b, winEnd);
    if o1 < o0
        continue;
    end
    i0 = o0 - winStart + 1;
    i1 = o1 - winStart + 1;
    segLen = i1 - i0 + 1;
    if segLen < 1
        continue;
    end

    w = blankWeight * ones(segLen, 1);
    if taperSamples > 0 && segLen > 2
        tlen = min(taperSamples, floor(segLen/2));
        if tlen >= 1
            ramp = 0.5 - 0.5*cos(pi*(0:tlen-1).'/tlen);  % 0->1
            % Outside interferer weight=1; inside core weight=blankWeight.
            % Edge: blend 1 -> blankWeight.
            w(1:tlen) = 1 - (1 - blankWeight)*ramp;
            w(end-tlen+1:end) = 1 - (1 - blankWeight)*flipud(ramp);
            if segLen > 2*tlen
                w(tlen+1:end-tlen) = blankWeight;
            end
        end
    end
    mask(i0:i1) = min(mask(i0:i1), w);
    info.applied_count = info.applied_count + 1;
    info.samples_touched = info.samples_touched + segLen;
end

rx = rx .* mask;
end
