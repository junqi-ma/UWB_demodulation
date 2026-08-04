function [cir, paths] = estimateCirAndPostDespreadPaths(rx, preamble, reference, params)
%ESTIMATECIRANDPOSTDESPREADPATHS Prepare raw chip streams for back-end CMF.
%   The preamble is still code-correlated to estimate CIR.  For the data
%   field, each dominant CIR tap is sampled separately; PN de-spreading and
%   CIR-weighted combining are deliberately deferred to the demodulator.

cir = uwbdecoder.estimateCir(rx, preamble, reference, params);
rx = rx(:);
samplesPerChip = preamble.measured_period / reference.chips_per_symbol;
% The front-end FIR output is indexed after its group delay.  Raw-path
% sampling has no such delay, so its zero-delay chip grid is the preamble
% start itself (not the delayed front-CMF output index).
chipStart = preamble.start_sample;
frameSpan = uwbdecoder.estimateFrameSampleSpan(preamble, reference, params);
chipPositions = chipStart + (0:frameSpan.n_chips-1)'*samplesPerChip;

if chipPositions(end) > numel(rx) || chipPositions(1) < 1
    error('estimateCirAndPostDespreadPaths:ChipGridOutOfBounds', ...
        'The requested post-despread chip grid falls outside the work buffer.');
end

% Keep a small, separated set of dominant paths.  This is the practical
% low-complexity form of a back-end CMF, rather than evaluating every tap.
offsets = (-cir.pre_samples:cir.post_samples-1)';
tapMagnitude = abs(cir.values(:));
[~, order] = sort(tapMagnitude, 'descend');
maxPaths = min(8, numel(order));
minSeparation = max(1, round(samplesPerChip/2));
selected = zeros(0, 1);
for k = 1:numel(order)
    candidate = order(k);
    if isempty(selected) || all(abs(offsets(candidate) - offsets(selected)) >= minSeparation)
        selected(end+1, 1) = candidate; %#ok<AGROW>
        if numel(selected) == maxPaths
            break;
        end
    end
end

pathOffsets = offsets(selected);
pathCoefficients = cir.values(selected);
pathChips = complex(zeros(frameSpan.n_chips, numel(selected)));
sampleAxis = (1:numel(rx))';
for k = 1:numel(selected)
    pathChips(:, k) = interp1(sampleAxis, rx, chipPositions + pathOffsets(k), ...
        'linear', 0);
end

paths = struct('complex_chips', pathChips, ...
    'path_coefficients', pathCoefficients(:), ...
    'path_offsets_samples', pathOffsets(:), ...
    'samples_per_chip', samplesPerChip, ...
    'chip_start_sample', chipStart, ...
    'num_chips', frameSpan.n_chips);

if isfield(params, 'verbose') && params.verbose
    fprintf('Prepared %d raw chip streams for post-despread CMF (%d chips).\n', ...
        numel(selected), frameSpan.n_chips);
end
end
