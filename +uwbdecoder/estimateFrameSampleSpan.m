function span = estimateFrameSampleSpan(preamble, reference, params)
%ESTIMATEFRAMESAMPLESPAN Soft-chip / crop budget for one UWB frame.
%   SPAN = ESTIMATEFRAMESAMPLESPAN(PREAMBLE, REFERENCE, PARAMS) returns
%   the soft-chip budget and post-samples span for a single frame, sized
%   from the BPRF ternary-chip grid. The formula matches the observed
%   floor (~1.54e5 chips for a 12-byte PSDU on code-10 / 256-SYNC) and
%   scales with max_psdu_bytes without dragging the entire capture into
%   CIR matching.
%
%   See also CROPTOFRAME, ESTIMATECIRANDSOFTCHIPS.

period = preamble.measured_period;
chipsPerSymbol = reference.chips_per_symbol;
samplesPerChip = period / max(chipsPerSymbol, 1);
sfdSymbols = configuredSfdSymbols(params);
maxPsduBytes = configuredMaxPsduBytes(params);

% SHR (SYNC + SFD) on the preamble spreading grid.
nShrChips = (params.preamble_repetitions + sfdSymbols)*chipsPerSymbol;
% PHR + short-payload headroom observed on DW1000 captures (~40 symbol
% equivalents covers PHR and a small PSDU; see 12 B needing ~154e3 chips).
nPhrAndHeadChips = 40*chipsPerSymbol;
% Additional PSDU body beyond 12 bytes (BPRF grid, with margin).
extraBytes = max(0, maxPsduBytes - 12);
nExtraPayloadChips = ceil(extraBytes*1000);
nGuardChips = 8*chipsPerSymbol;

nChips = nShrChips + nPhrAndHeadChips + nExtraPayloadChips + nGuardChips;
% Small overall guard so helper index ranges are never 1-chip short.
nChips = ceil(nChips*1.05);

% Work-rate samples from preamble start through that chip budget.
% chip_start is only a few tens of samples after start_sample.
postSamples = ceil(nChips*samplesPerChip) + round(2*period);

span = struct();
span.sfd_symbols = sfdSymbols;
span.max_psdu_bytes = maxPsduBytes;
span.n_chips = nChips;
span.samples_per_chip = samplesPerChip;
span.post_samples = postSamples;
end

% -------------------------------------------------------------------------
function n = configuredSfdSymbols(params)
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

function n = configuredMaxPsduBytes(params)
if isfield(params, 'max_psdu_bytes') && ~isempty(params.max_psdu_bytes)
    n = params.max_psdu_bytes;
else
    n = 127;
end
end
