function diagnostics = analyzeNsSfdSymbols(rx, preamble, reference, params)
%ANALYZENSSFDSYMBOLS Evaluate selected SFD timing at symbol resolution.
%   DIAGNOSTICS = ANALYZENSSFDSYMBOLS(RX, PREAMBLE, REFERENCE, PARAMS)
%   tests small preamble-symbol shifts of the selected SFD against a
%   local matched filter around the expected SFD and returns the best
%   shift and its correlation.
%
%   See also REFINETIMINGWITHNSSFD, LOCATENSSFD.

sfdSequence = preamble.selected_sfd_sequence(:);
period = preamble.measured_period;
halfWidth = preamble.search_half_width;
shifts = -2:2;

% Local ROI covering every candidate SFD symbol peak under test.
firstEnd = preamble.start_sample + (params.preamble_repetitions + shifts(1) + 1)* ...
    period - 1;
lastEnd = preamble.start_sample + (params.preamble_repetitions + shifts(end) + ...
    numel(sfdSequence))*period - 1;
roiStart = max(1, floor(firstEnd - halfWidth - reference.samples_per_symbol));
roiEnd = min(numel(rx), ceil(lastEnd + halfWidth + reference.samples_per_symbol));
roi = rx(roiStart:roiEnd);
matchedRoi = uwbdecoder.fftFilter( ...
    flipud(conj(reference.preamble_waveform)), roi);

correlations = zeros(size(shifts));
for shiftIdx = 1:length(shifts)
    values = complex(zeros(length(sfdSequence), 1));
    for symbolIdx = 1:length(sfdSequence)
        expectedEnd = round(preamble.start_sample + (params.preamble_repetitions + ...
            shifts(shiftIdx) + symbolIdx)*period - 1);
        localCenter = expectedEnd - roiStart + 1;
        indices = localCenter-halfWidth:localCenter+halfWidth;
        indices = indices(indices >= 1 & indices <= numel(matchedRoi));
        if isempty(indices)
            values(symbolIdx) = 0;
            continue;
        end
        [~, localPeak] = max(abs(matchedRoi(indices)));
        values(symbolIdx) = matchedRoi(indices(localPeak));
    end
    correlations(shiftIdx) = abs(sfdSequence'*values) / ...
        (norm(sfdSequence)*norm(values) + eps);
end

[bestCorrelation, bestIdx] = max(correlations);
diagnostics = struct('shifts', shifts, 'correlations', correlations, ...
    'best_shift', shifts(bestIdx), 'best_correlation', bestCorrelation, ...
    'sfd_name', preamble.selected_sfd_name, 'sequence', sfdSequence);

if isfield(params, 'verbose') && params.verbose
    fprintf(['Code-level SFD correlation: %.3f, preamble-symbol best ', ...
        '%s-template shift: %d.\n'], bestCorrelation, ...
        preamble.selected_sfd_name, shifts(bestIdx));
    fprintf('Using measured %d + %d boundary: SFD shift = 0.\n', ...
        params.preamble_repetitions, length(sfdSequence));
    fprintf('SFD shift candidates [shift; correlation]:\n');
    disp([shifts; correlations]);
end
end
