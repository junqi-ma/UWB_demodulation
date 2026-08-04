function cir = estimateCir(rx, preamble, reference, params)
%ESTIMATECIR Estimate a local CIR from stable SYNC repetitions.
%   CIR = ESTIMATECIR(RX, PREAMBLE, REFERENCE, PARAMS) performs only the
%   preamble spreading-code correlation and coherent CIR averaging shared by
%   the front-end-CMF and post-despread-CMF experiments.

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
    repetitionCount = min(params.cir_repetitions, availableRepetitions);
    firstRepetition = max(0, availableRepetitions - repetitionCount);
else
    firstRepetition = params.cir_skip_initial_repetitions;
    repetitionCount = min(params.cir_repetitions, ...
        availableRepetitions - firstRepetition);
    if repetitionCount < 1
        error('estimateCir:NoRepetitionsAfterSkip', ...
            ['No detected preamble repetitions remain after skipping ', ...
             'the first %d repetitions.'], firstRepetition);
    end
end
lastRepetition = firstRepetition + repetitionCount - 1;

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
    error('estimateCir:NoValidRepetitions', ...
        'No complete preamble repetitions were available for CIR estimation.');
end
individual = individual(:, 1:validCount);
values = accumulator / (validCount*reference.code_energy + eps);
values = values / (norm(values) + eps);

cir = struct('values', values, 'delay_ns', delayNs, ...
    'individual_values', individual, 'repetition_count', validCount, ...
    'first_repetition', firstRepetition + 1, ...
    'last_repetition', lastRepetition + 1, ...
    'skipped_initial_repetitions', firstRepetition, ...
    'pre_samples', preSamples, 'post_samples', postSamples);
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
if tapCount <= 128
    filtered = filter(filterTaps, 1, segment);
else
    filtered = fftfilt(filterTaps, segment);
end
sampleAxis = axisStart + (0:numel(filtered)-1).';
filtered = filtered(:);
end
