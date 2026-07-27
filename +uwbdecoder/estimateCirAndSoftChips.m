function [cir, chips] = estimateCirAndSoftChips(rx, preamble, reference, params)
%ESTIMATECIRANDSOFTCHIPS Despread preamble codes, average CIR, slice chips.
%   [CIR, CHIPS] = ESTIMATECIRANDSOFTCHIPS(RX, PREAMBLE, REFERENCE,
%   PARAMS) despreads the preamble codes, coherently averages the CIR
%   over the stable SYNC repetitions, and slices soft chips over a
%   budgeted frame span sized for helperUWBBPRFDemod.
%
%   CIR: one local code-matched filter over the last N SYNC symbols.
%   Soft chips: short CIR template over a budgeted frame span only (not the
%   entire capture).
%
%   See also ESTIMATEFRAMESAMPLESPAN, LOCATENSSFD.

c = uwbdecoder.constants();

code = reference.sampled_code(:);
codeMf = flipud(conj(code));
codeLength = numel(code);
rx = rx(:);

[preSamples, postSamples] = resolveCirWindow(params, preamble, reference);
offsets = (-preSamples:postSamples-1).';
delayNs = offsets / reference.fs * 1e9;

availableRepetitions = min(preamble.detected_repetitions, ...
    params.preamble_repetitions);
if isempty(params.cir_skip_initial_repetitions)
    % Backward-compatible behavior: coherently average the final N SYNCs.
    repetitionCount = min(params.cir_repetitions, availableRepetitions);
    firstRepetition = max(0, availableRepetitions - repetitionCount);
else
    % Explicit stable-region behavior: discard the requested initial SYNCs
    % and average up to cir_repetitions from the remaining preamble.
    firstRepetition = params.cir_skip_initial_repetitions;
    repetitionCount = min(params.cir_repetitions, ...
        availableRepetitions - firstRepetition);
    if repetitionCount < 1
        error('estimateCirAndSoftChips:NoRepetitionsAfterSkip', ...
            ['No detected preamble repetitions remain after skipping ', ...
             'the first %d repetitions.'], firstRepetition);
    end
end
lastRepetition = firstRepetition + repetitionCount - 1;

% --- CIR: local code correlation over the SYNC average window only ---
firstNominalEnd = preamble.start_sample + firstRepetition* ...
    preamble.measured_period + codeLength - 1;
lastNominalEnd = preamble.start_sample + lastRepetition* ...
    preamble.measured_period + codeLength - 1;
filterStart = firstNominalEnd + offsets(1);
filterEnd = lastNominalEnd + offsets(end);
[codeAxis, codeFiltered] = localMatchedFilterSegment(rx, codeMf, ...
    filterStart, filterEnd);

individual = complex(zeros(length(offsets), repetitionCount));
accumulator = complex(zeros(length(offsets), 1));
validCount = 0;
for repetition = firstRepetition:lastRepetition
    repetitionStart = preamble.start_sample + repetition*preamble.measured_period;
    nominalEnd = repetitionStart + codeLength - 1;
    positions = nominalEnd + offsets;
    values = interp1(codeAxis, codeFiltered, positions, 'linear', NaN);
    if any(isnan(values))
        continue;
    end
    validCount = validCount + 1;
    accumulator = accumulator + values(:);
    individual(:, validCount) = values(:) / reference.code_energy;
end
if validCount == 0
    error('estimateCirAndSoftChips:NoValidRepetitions', ...
        'No complete preamble repetitions were available for CIR estimation.');
end
individual = individual(:, 1:validCount);
values = accumulator / (validCount*reference.code_energy + eps);
values = values / (norm(values) + eps);

% --- Soft chips: budgeted span, short CIR FIR ---
cirMf = conj(flipud(values));
samplesPerChip = preamble.measured_period / reference.chips_per_symbol;
chipStart = preamble.start_sample + length(values) - preSamples - 1;
frameSpan = uwbdecoder.estimateFrameSampleSpan(preamble, reference, params);

% End sample for the Nth soft chip (1-based): chip_start + (N-1)*spc.
lastByBudget = chipStart + (frameSpan.n_chips - 1)*samplesPerChip;
lastChipSample = min(numel(rx), ceil(lastByBudget));
if chipStart >= lastChipSample
    error('estimateCirAndSoftChips:ChipStartOutOfBounds', ...
        'chip_start falls outside the work buffer; check timing/crop.');
end

chipPositions = chipStart:samplesPerChip:lastChipSample;
minPreambleChips = params.preamble_repetitions*reference.chips_per_symbol;
if numel(chipPositions) < minPreambleChips
    error('estimateCirAndSoftChips:SoftChipsTooShort', ...
        ['Soft-chip stream shorter than SYNC (%d chips, need >= %d). ', ...
         'Increase sample_num so the capture covers the full frame.'], ...
        numel(chipPositions), minPreambleChips);
end

[chipAxis, chipFiltered] = localMatchedFilterSegment(rx, cirMf, ...
    min(chipPositions), max(chipPositions));
complexChips = interp1(chipAxis, chipFiltered, chipPositions, ...
    'linear', NaN);
if any(isnan(complexChips))
    error('estimateCirAndSoftChips:CirFilterFailed', ...
        'Local CIR matched filter failed over the soft-chip region.');
end
complexChips = complexChips(:);

phaseRepetitions = min(32, params.preamble_repetitions);
phaseFirst = (params.preamble_repetitions - phaseRepetitions)* ...
    reference.chips_per_symbol + 1;
phaseLast = params.preamble_repetitions*reference.chips_per_symbol;
if phaseLast > numel(complexChips) || phaseFirst < 1
    error('estimateCirAndSoftChips:SoftChipsShorterThanPreamble', ...
        ['Soft-chip stream is shorter than the configured preamble; ', ...
         'increase sample_num so the capture covers the full frame.']);
end
phaseReference = repmat(reference.spread_code, phaseRepetitions, 1);
phaseGain = phaseReference' * complexChips(phaseFirst:phaseLast);
complexChips = complexChips * exp(-1j*angle(phaseGain));
soft = real(complexChips);
soft = soft / (max(abs(soft)) + eps);

cir = struct('values', values, 'delay_ns', delayNs, ...
    'individual_values', individual, 'repetition_count', validCount, ...
    'first_repetition', firstRepetition + 1, ...
    'last_repetition', lastRepetition + 1, ...
    'skipped_initial_repetitions', firstRepetition, ...
    'pre_samples', preSamples, 'post_samples', postSamples);
chips = struct('complex', complexChips, 'soft', soft, ...
    'samples_per_chip', samplesPerChip, ...
    'chip_start_sample', chipStart, ...
    'chip_end_sample', lastChipSample, ...
    'num_chips', numel(soft));

if isfield(params, 'verbose') && params.verbose
    fprintf(['Estimated %d-sample CIR (pre=%d, post=%d) from ', ...
        'SYNC %d..%d (%d reps); ', ...
        'soft chips=%d (budget %d).\n'], ...
        length(values), preSamples, postSamples, ...
        cir.first_repetition, cir.last_repetition, validCount, ...
        numel(soft), frameSpan.n_chips);
end
end

% -------------------------------------------------------------------------
function [preSamples, postSamples] = resolveCirWindow(params, preamble, reference)
c = uwbdecoder.constants();

if ~isempty(params.cir_pre_samples)
    preSamples = params.cir_pre_samples;
else
    preSamples = preamble.search_half_width;
end

if ~isempty(params.cir_post_samples)
    postSamples = params.cir_post_samples;
elseif ~isempty(params.cir_max_path_m)
    postSamples = max(1, round(params.cir_max_path_m / c.SPEED_OF_LIGHT * reference.fs));
else
    postSamples = max(1, round(100e-9 * reference.fs));
end

preSamples = max(0, round(preSamples));
postSamples = max(1, round(postSamples));
end

function [sampleAxis, filtered] = localMatchedFilterSegment(rx, filterTaps, ...
        posMin, posMax)
%LOCALMATCHEDFILTERSEGMENT FIR match over [posMin, posMax] only.
filterTaps = filterTaps(:);
rx = rx(:);
tapCount = numel(filterTaps);
absStart = floor(posMin) - tapCount + 1;
absEnd = ceil(posMax);
padLeft = 0;
padRight = 0;
if absStart < 1
    padLeft = 1 - absStart;
    absStart = 1;
end
if absEnd > numel(rx)
    padRight = absEnd - numel(rx);
    absEnd = numel(rx);
end
if absEnd < absStart
    sampleAxis = zeros(0, 1);
    filtered = complex(zeros(0, 1));
    return;
end

segment = rx(absStart:absEnd);
if padLeft > 0 || padRight > 0
    segment = [zeros(padLeft, 1); segment; zeros(padRight, 1)];
end
axisStart = absStart - padLeft;
% Short FIR (CIR template ~ tens of taps): time-domain filter is faster
% than fftfilt on medium-length segments.
if tapCount <= 128
    filtered = filter(filterTaps, 1, segment);
else
    filtered = fftfilt(filterTaps, segment);
end
sampleAxis = axisStart + (0:numel(filtered)-1).';
filtered = filtered(:);
end
