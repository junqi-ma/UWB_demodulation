function basis = synchronousTone(n, tone_bin, period_samples, numeric_type)
%SYNCHRONOUSTONE Generate a sample-clock-synchronous complex tone.
%   Builds one period and tiles it, which is much cheaper than exp() on
%   every absolute sample index for long captures.
%
%   NUMERIC_TYPE is optional ('single' or 'double', default 'single').

if nargin < 4 || isempty(numeric_type)
    numeric_type = 'single';
end

n = n(:);
period_samples = round(period_samples);
t = dw1000decoder.asNumeric((0:period_samples-1).', numeric_type);
omega = dw1000decoder.asNumeric(2*pi*tone_bin/period_samples, numeric_type);
one_period = exp(1j*omega.*t);

if isempty(n)
    basis = dw1000decoder.complexZeros(0, 1, numeric_type);
    return;
end

% Fast path for contiguous integer ranges (the common decoder case).
if numel(n) > 1 && isequal(n(:), (n(1):n(1)+numel(n)-1).')
    start_phase = mod(n(1), period_samples);
    % Index into one_period for n(1), n(1)+1, ...
    idx = mod(start_phase+(0:numel(n)-1).', period_samples)+1;
    basis = one_period(idx);
    return;
end

basis = one_period(mod(n, period_samples)+1);
end
