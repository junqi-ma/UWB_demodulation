function [cir, chips] = estimateCirAndSoftChips(rx, preamble, reference, params)
%ESTIMATECIRANDSOFTCHIPS Estimate CIR and form front-end-CMF soft chips.
%   CIR estimation is shared with the post-despread-CMF experiment so both
%   branches use exactly the same channel estimate.

cir = uwbdecoder.estimateCir(rx, preamble, reference, params);
values = cir.values;
rx = rx(:);

cirMf = conj(flipud(values));
samplesPerChip = preamble.measured_period/reference.chips_per_symbol;
chipStart = preamble.start_sample + length(values) - cir.pre_samples - 1;
frameSpan = uwbdecoder.estimateFrameSampleSpan(preamble, reference, params);
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
complexChips = interp1(chipAxis, chipFiltered, chipPositions, 'linear', NaN);
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
phaseGain = phaseReference'*complexChips(phaseFirst:phaseLast);
complexChips = complexChips*exp(-1j*angle(phaseGain));
soft = real(complexChips);
soft = soft/(max(abs(soft)) + eps);

chips = struct('complex', complexChips, 'soft', soft, ...
    'samples_per_chip', samplesPerChip, ...
    'chip_start_sample', chipStart, ...
    'chip_end_sample', lastChipSample, ...
    'num_chips', numel(soft));
if isfield(params, 'verbose') && params.verbose
    fprintf(['Estimated %d-sample CIR (pre=%d, post=%d) from ', ...
        'SYNC %d..%d (%d reps); soft chips=%d (budget %d).\n'], ...
        length(values), cir.pre_samples, cir.post_samples, ...
        cir.first_repetition, cir.last_repetition, cir.repetition_count, ...
        numel(soft), frameSpan.n_chips);
end
end

function [sampleAxis, filtered] = localMatchedFilterSegment(rx, filterTaps, posMin, posMax)
filterTaps = filterTaps(:);
rx = rx(:);
tapCount = numel(filterTaps);
absStart = floor(posMin) - tapCount + 1;
absEnd = ceil(posMax);
padLeft = 0;
padRight = 0;
if absStart < 1, padLeft = 1 - absStart; absStart = 1; end
if absEnd > numel(rx), padRight = absEnd - numel(rx); absEnd = numel(rx); end
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
if tapCount <= 128, filtered = filter(filterTaps, 1, segment);
else, filtered = fftfilt(filterTaps, segment); end
sampleAxis = axisStart + (0:numel(filtered)-1).';
filtered = filtered(:);
end
