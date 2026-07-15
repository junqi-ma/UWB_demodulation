function [rx, preamble] = compensateCarrierOffset(rx, preamble, reference, params)
%COMPENSATECARRIEROFFSET Estimate CFO and resolve constant complex phase.
usable_peaks = preamble.peaks(1:min(preamble.detected_repetitions, ...
    params.preamble_repetitions));
peak_values = readMatchedAt(preamble, usable_peaks);
fit_count = min(240, length(peak_values));
fit_time = (double(usable_peaks(1:fit_count))-double(usable_peaks(1)))/reference.fs;
fit_phase = unwrap(angle(peak_values(1:fit_count)));
phase_fit = polyfit(fit_time, fit_phase, 1);
frequency_offset = phase_fit(1)/(2*pi);

nn = (0:numel(rx)-1).';
rx = rx(:).*exp(-1j*2*pi*frequency_offset*nn/reference.fs);

phase_repetitions = min(32, preamble.detected_repetitions);
known = repmat(reference.preamble_waveform, phase_repetitions, 1);
first_repetition = max(0, params.preamble_repetitions-phase_repetitions);
phase_start = round(preamble.start_sample+first_repetition*preamble.measured_period);
phase_indices = phase_start+(0:length(known)-1);
if phase_indices(1) < 1 || phase_indices(end) > numel(rx)
    error('Carrier-phase alignment window falls outside the work buffer.');
end
gain = known'*rx(phase_indices);
rx = rx*exp(-1j*angle(gain));
preamble.frequency_offset_hz = frequency_offset;
if isfield(params, 'verbose') && params.verbose
    fprintf('Estimated frequency offset: %.3f kHz.\n', frequency_offset/1e3);
end
end

function values = readMatchedAt(preamble, absolute_peaks)
if isfield(preamble, 'matched_is_roi') && preamble.matched_is_roi
    idx = absolute_peaks-preamble.roi_start+1;
else
    idx = absolute_peaks;
end
if any(idx < 1) || any(idx > numel(preamble.matched))
    error('Preamble peak indices fall outside the matched-filter buffer.');
end
values = preamble.matched(idx);
end
