function rxWork = resampleCapture(rx, fsRx, fsWork)
%RESAMPLECAPTURE Convert X410 samples to the HRP working sample rate.
%   RXWORK = RESAMPLECAPTURE(RX, FSRX, FSWORK) resamples the complex
%   column vector RX from the X410 sample rate FSRX to the HRP working
%   rate FSWORK using a rational resampling factor.
%
%   See also DECODE_X410_DW1000.

[p, q] = rat(fsWork/fsRx, 1e-12);
rxWork = resample(rx, p, q);
end
