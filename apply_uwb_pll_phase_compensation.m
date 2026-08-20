function corrected = apply_uwb_pll_phase_compensation( ...
        replica, periodSamples, compensation)
%APPLY_UWB_PLL_PHASE_COMPENSATION Apply an early-preamble PLL phase curve.
%   Bin boundaries are rounded independently so a noninteger receiver-grid
%   SYNC period cannot accumulate indexing drift. Samples after the
%   configured early repetitions are unchanged.

replica = replica(:);
if ~isstruct(compensation) || ~isfield(compensation, 'enabled') || ...
        ~compensation.enabled
    corrected = replica;
    return
end
samplePhase = zeros(numel(replica), 1);
for repetition = 1:compensation.apply_repetitions
    for bin = 1:compensation.bins_per_repetition
        firstBoundary = (repetition-1) + ...
            (bin-1)/compensation.bins_per_repetition;
        lastBoundary = (repetition-1) + bin/compensation.bins_per_repetition;
        firstSample = round(firstBoundary*periodSamples) + 1;
        lastSample = min(numel(replica), round(lastBoundary*periodSamples));
        if firstSample <= lastSample
            samplePhase(firstSample:lastSample) = ...
                compensation.phase_by_bin_rad(repetition, bin);
        end
    end
end
corrected = replica.*exp(1j*samplePhase);
end
