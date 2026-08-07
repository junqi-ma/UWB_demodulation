function filtered = fftFilter(filterTaps, signal)
%FFTFILTER Apply MATLAB's double-only FFT FIR filter to numeric input.
%   FILTERED = FFTFILTER(FILTERTAPS, SIGNAL) promotes only the filter taps
%   and the active signal segment to double before calling FFTFILT. This
%   lets capture and work buffers remain single precision while preserving
%   the established FFTFILT numerical path at the matched-filter boundary.

filtered = fftfilt(double(filterTaps), double(signal));
end
