function [preamble, cir, rxOut] = estimate_uwb_preamble_cir( ...
        rx, reference, params, seededStart)
%ESTIMATE_UWB_PREAMBLE_CIR CIR from visible SYNC only (no SHR / PHR check).
%   [PREAMBLE, CIR, RXOUT] = ESTIMATE_UWB_PREAMBLE_CIR(RX, REFERENCE,
%   PARAMS, SEEDEDSTART) seeds preamble detection at SEEDEDSTART, optionally
%   removes the carrier offset, and estimates the CIR from the visible SYNC
%   repetitions only. It stops after estimateCir and never calls
%   validateCaptureLength, cropToFrame, refineTimingWithNsSfd,
%   estimateCirAndSoftChips, or decodePhrAndPayload, so clipped dump windows
%   whose SFD/PHR fall outside the window can still be cancelled.
%
%   The local preamble_repetitions is shrunk to the number of visible SYNC
%   repetitions so compensateCarrierOffset does not open its phase window at
%   the configured 256th repetition.
%
%   See also CANCEL_UWB_PREAMBLE_IN_IQ, FINDDWPREAMBLECANDIDATESONWINDOW.

rx = rx(:);
if ~(isfinite(seededStart) && seededStart >= 1 && seededStart <= numel(rx))
    error('estimate_uwb_preamble_cir:BadSeed', ...
        'Seeded start %g is outside the work window 1:%d.', ...
        seededStart, numel(rx));
end

preamble = uwbdecoder.detectRepeatedPreamble( ...
    rx, reference, params, seededStart);
period = finitePeriod(preamble.measured_period, reference.samples_per_symbol);
if preamble.detected_repetitions < 32 || ...
        abs(double(preamble.start_sample) - double(seededStart)) > 2*period
    error('estimate_uwb_preamble_cir:SeedFallback', ...
        ['Seeded refine at %d fell back to start=%d reps=%d; ', ...
         'do not cancel the window head.'], ...
        seededStart, preamble.start_sample, preamble.detected_repetitions);
end

visible = min(params.preamble_repetitions, ...
    floor((numel(rx) - double(preamble.start_sample) + 1) / period));
visible = max(0, visible);
p = params;
p.preamble_repetitions = visible;

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

function p = finitePeriod(p, default)
if isempty(p) || ~isfinite(p)
    p = default;
end
end