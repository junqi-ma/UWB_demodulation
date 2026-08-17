function [peakIdx, peakDelay, peakPower] = locateCirFirstPeak( ...
        powerBar, delayNs, firstPathDelayNs)
%LOCATECIRFIRSTPEAK First local max of coherent CIR power at/after First Path.
%   [PEAKIDX, PEAKDELAY, PEAKPOWER] = LOCATECIRFIRSTPEAK(POWERBAR, DELAYNS,
%   FIRSTPATHDELAYNS) returns the first local maximum of POWERBAR on
%   DELAYNS >= FIRSTPATHDELAYNS. If that set is empty, the full delay
%   axis is searched. POWERBAR is linear power, not complex amplitude.
%
%   A later, taller multipath peak is ignored. If no local maximum exists,
%   the argmax of the search region is returned.
%
%   See also ANALYZECIRINTERFERENCE.

powerBar = double(powerBar(:));
delayNs = double(delayNs(:));
if numel(powerBar) ~= numel(delayNs)
    error('locateCirFirstPeak:DelayAxisMismatch', ...
        'powerBar and delayNs must have the same length.');
end
if isempty(powerBar)
    peakIdx = 1;
    peakDelay = NaN;
    peakPower = NaN;
    return
end

search = true(size(powerBar));
if nargin >= 3 && isfinite(firstPathDelayNs)
    search = delayNs >= firstPathDelayNs;
end
idx = find(search);
if isempty(idx)
    idx = (1:numel(powerBar)).';
end

region = powerBar(idx);
isPeak = false(size(region));
if numel(region) == 1
    isPeak = true;
else
    isPeak(1) = region(1) >= region(2);
    isPeak(end) = region(end) >= region(end - 1);
    if numel(region) > 2
        isPeak(2:end-1) = region(2:end-1) >= region(1:end-2) & ...
            region(2:end-1) >= region(3:end);
    end
end
peakLocal = find(isPeak, 1, 'first');
if isempty(peakLocal)
    [~, peakLocal] = max(region);
end
peakIdx = idx(peakLocal);
peakDelay = delayNs(peakIdx);
peakPower = powerBar(peakIdx);
end
