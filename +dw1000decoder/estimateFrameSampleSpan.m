function span = estimateFrameSampleSpan(preamble, reference, params)
%ESTIMATEFRAMESAMPLESPAN Soft-chip / crop budget for one UWB frame.
%   Sized from the BPRF ternary-chip grid used by helperUWBBPRFDemod.
%
%   Empirically, a 12-byte PSDU on code-10 / 256-SYNC needs soft-chip indices
%   up to ~1.54e5. The formula below matches that floor and scales with
%   max_psdu_bytes without dragging the entire capture into CIR matching.

period = preamble.measured_period;
chips_per_symbol = reference.chips_per_symbol;
samples_per_chip = period/max(chips_per_symbol, 1);
sfd_symbols = maxSfdSymbols(params);
max_psdu_bytes = maxPsduBytes(params);

% SHR (SYNC + SFD) on the preamble spreading grid.
n_shr_chips = (params.preamble_repetitions+sfd_symbols)*chips_per_symbol;
% PHR + short-payload headroom observed on DW1000 captures (~40 symbol
% equivalents covers PHR and a small PSDU; see 12 B needing ~154e3 chips).
n_phr_and_head_chips = 40*chips_per_symbol;
% Additional PSDU body beyond 12 bytes (BPRF grid, with margin).
extra_bytes = max(0, max_psdu_bytes-12);
n_extra_payload_chips = ceil(extra_bytes*1000);
n_guard_chips = 8*chips_per_symbol;

n_chips = n_shr_chips+n_phr_and_head_chips+n_extra_payload_chips+n_guard_chips;
% Small overall guard so helper index ranges are never 1-chip short.
n_chips = ceil(n_chips*1.05);

% Work-rate samples from preamble start through that chip budget.
% chip_start is only a few tens of samples after start_sample.
post_samples = ceil(n_chips*samples_per_chip)+round(2*period);

span = struct();
span.sfd_symbols = sfd_symbols;
span.max_psdu_bytes = max_psdu_bytes;
span.n_chips = n_chips;
span.samples_per_chip = samples_per_chip;
span.post_samples = post_samples;
end

function n = maxSfdSymbols(params)
switch params.sfd_mode
    case '4z1'
        n = 4;
    case '4z3'
        n = 16;
    case '4z4'
        n = 32;
    case 'auto'
        if params.code_index >= 25 && params.code_index <= 32
            n = 32;
        else
            n = 8;
        end
    otherwise
        n = 8;
end
end

function n = maxPsduBytes(params)
if isfield(params, 'max_psdu_bytes') && ~isempty(params.max_psdu_bytes)
    n = params.max_psdu_bytes;
else
    n = 127;
end
end
