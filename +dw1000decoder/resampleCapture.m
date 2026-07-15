function rx_work = resampleCapture(rx, fs_rx, fs_work)
%RESAMPLECAPTURE Convert X410 samples to the HRP working sample rate.
[p, q] = rat(fs_work/fs_rx, 1e-12);
rx_work = resample(rx, p, q);
end

