function corrected = apply_uwb_full_packet_sfo(replica, diagnostics)
%APPLY_UWB_FULL_PACKET_SFO Apply an affine fractional-delay time warp.
%   Positive delay moves the regenerated waveform later. The correction
%   uses the packet-specific intercept and SFO slope returned by
%   estimate_uwb_full_packet_sfo.

if ~diagnostics.applied
    corrected = replica;
    return
end
sampleAxis = (1:numel(replica)).';
zeroBasedAxis = sampleAxis - 1;
delaySamples = diagnostics.delay_intercept_samples + ...
    diagnostics.delay_slope_samples_per_sample * zeroBasedAxis;
interpolator = griddedInterpolant( ...
    sampleAxis, replica(:), 'spline', 'none');
corrected = interpolator(sampleAxis - delaySamples);
corrected(~isfinite(corrected)) = 0;
end
