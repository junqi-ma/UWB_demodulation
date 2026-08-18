function [preamble, cir, rxOut] = estimate_uwb_preamble_cir( ...
        rx, reference, params, seededStart, preparedPreamble)
%ESTIMATE_UWB_PREAMBLE_CIR CIR from visible SYNC only (no SHR / PHR check).
%   [PREAMBLE, CIR, RXOUT] = ESTIMATE_UWB_PREAMBLE_CIR(RX, REFERENCE,
%   PARAMS, SEEDEDSTART) seeds preamble detection at SEEDEDSTART, optionally
%   removes the carrier offset, and estimates the CIR from the visible SYNC
%   repetitions only. It stops after estimateCir and never calls
%   validateCaptureLength, cropToFrame, refineTimingWithNsSfd,
%   estimateCirAndSoftChips, or decodePhrAndPayload, so clipped dump windows
%   whose SFD/PHR fall outside the window can still be cancelled.
%
%   PREPAREDPREAMBLE is optional. If it is a struct with start_sample
%   near SEEDEDSTART, reuse it and skip a second detectRepeatedPreamble.
%
%   See also CANCEL_UWB_PREAMBLE_IN_IQ, FINDDWPREAMBLECANDIDATESONWINDOW.

rx = rx(:);
if ~(isfinite(seededStart) && seededStart >= 1 && seededStart <= numel(rx))
    error('estimate_uwb_preamble_cir:BadSeed', ...
        'Seeded start %g is outside the work window 1:%d.', ...
        seededStart, numel(rx));
end

if nargin >= 5 && preamblePassesGuard(preparedPreamble, seededStart, reference)
    preamble = preparedPreamble;
else
    preamble = uwbdecoder.detectRepeatedPreamble( ...
        rx, reference, params, seededStart);
    if ~preamblePassesGuard(preamble, seededStart, reference)
        error('estimate_uwb_preamble_cir:SeedFallback', ...
            ['Seeded refine at %d fell back to start=%d reps=%d; ', ...
             'do not cancel the window head.'], ...
            seededStart, preamble.start_sample, preamble.detected_repetitions);
    end
end

period = preamble.measured_period;
if ~(isfinite(period) && period > 0)
    period = reference.samples_per_symbol;
end
visible = min(params.preamble_repetitions, ...
    floor((numel(rx) - double(preamble.start_sample) + 1) / period));
visible = max(0, visible);
p = params;
p.preamble_repetitions = min(params.preamble_repetitions, visible);

% The canceller fits its own CFO against the original window, so a failed
% CFO compensation here only degrades the CIR estimate, not the SIC step.
try
    [rxOut, preamble] = uwbdecoder.compensateCarrierOffset( ...
        rx, preamble, reference, p);
catch
    rxOut = rx;
end

cir = uwbdecoder.estimateCir(rxOut, preamble, reference, p);
end

function ok = preamblePassesGuard(preambleCheck, seededStart, reference)
period = reference.samples_per_symbol;
if isstruct(preambleCheck) && isfield(preambleCheck, 'measured_period') && ...
        isfinite(preambleCheck.measured_period) && preambleCheck.measured_period > 0
    period = double(preambleCheck.measured_period);
end
ok = isstruct(preambleCheck) && isfield(preambleCheck, 'start_sample') ...
    && preambleCheck.start_sample >= 2000 ...
    && isfield(preambleCheck, 'detected_repetitions') ...
    && preambleCheck.detected_repetitions >= 32 ...
    && abs(double(preambleCheck.start_sample) - double(seededStart)) <= 50 * period;
end
