function y = fftfiltCompat(b, x, varargin)
%FFTFILTCOMPAT Overlap-add FIR filter that accepts single or double.
%   MathWorks fftfilt validates coefficients/data as double only. Cast to
%   double for the toolbox call, then restore the working precision of x.

want_single = isa(x, 'single') || isa(b, 'single');
if want_single
    y = fftfilt(double(b), double(x), varargin{:});
    y = single(y);
else
    y = fftfilt(b, x, varargin{:});
end
end
