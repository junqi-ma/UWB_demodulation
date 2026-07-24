function basis = synchronousTone(n, toneBin, periodSamples)
%SYNCHRONOUSTONE Generate a sample-clock-synchronous complex tone.
%   BASIS = SYNCHRONOUSTONE(N, TONEBIN, PERIODSAMPLES) builds one period
%   of a complex exponential and tiles it over the sample indices N. This
%   is much cheaper than calling exp() on every absolute sample index for
%   long captures.
%
%   TONEBIN is the number of tone cycles per period; PERIODSAMPLES is the
%   integer number of samples in one period.
%
%   See also READANDCANCELINTERFERENCE.

n = n(:);
periodSamples = round(periodSamples);
onePeriod = exp(1j*2*pi*toneBin*(0:periodSamples-1).'/periodSamples);

if isempty(n)
    basis = complex(zeros(0, 1));
    return;
end

% Fast path for contiguous integer ranges (the common decoder case).
if numel(n) > 1 && isequal(n(:), (n(1):n(1)+numel(n)-1).')
    startPhase = mod(n(1), periodSamples);
    idx = mod(startPhase + (0:numel(n)-1).', periodSamples) + 1;
    basis = onePeriod(idx);
    return;
end

basis = onePeriod(mod(n, periodSamples) + 1);
end
