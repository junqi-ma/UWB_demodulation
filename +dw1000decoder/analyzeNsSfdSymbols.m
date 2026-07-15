function diagnostics = analyzeNsSfdSymbols(rx, preamble, reference, params)
%ANALYZENSSFDSYMBOLS Evaluate selected SFD timing at symbol resolution.
%   Uses a local matched filter around the expected SFD only.

sfd_sequence = preamble.selected_sfd_sequence(:);
period = preamble.measured_period;
half_width = preamble.search_half_width;
shifts = -2:2;

% Local ROI covering every candidate SFD symbol peak under test.
first_end = preamble.start_sample+(params.preamble_repetitions+shifts(1)+1)* ...
    period-1;
last_end = preamble.start_sample+(params.preamble_repetitions+shifts(end)+ ...
    numel(sfd_sequence))*period-1;
roi_start = max(1, floor(first_end-half_width-reference.samples_per_symbol));
roi_end = min(numel(rx), ceil(last_end+half_width+reference.samples_per_symbol));
roi = rx(roi_start:roi_end);
matched_roi = fftfilt(flipud(conj(reference.preamble_waveform)), roi);

correlations = zeros(size(shifts));
for shift_index = 1:length(shifts)
    values = complex(zeros(length(sfd_sequence), 1));
    for symbol_index = 1:length(sfd_sequence)
        expected_end = round(preamble.start_sample+(params.preamble_repetitions+ ...
            shifts(shift_index)+symbol_index)*period-1);
        local_center = expected_end-roi_start+1;
        indices = local_center-half_width:local_center+half_width;
        indices = indices(indices >= 1 & indices <= numel(matched_roi));
        if isempty(indices)
            values(symbol_index) = 0;
            continue;
        end
        [~, local_peak] = max(abs(matched_roi(indices)));
        values(symbol_index) = matched_roi(indices(local_peak));
    end
    correlations(shift_index) = abs(sfd_sequence'*values)/ ...
        (norm(sfd_sequence)*norm(values)+eps);
end
[best_correlation, best_index] = max(correlations);
diagnostics = struct('shifts', shifts, 'correlations', correlations, ...
    'best_shift', shifts(best_index), 'best_correlation', best_correlation, ...
    'sfd_name', preamble.selected_sfd_name, 'sequence', sfd_sequence);
if isfield(params, 'verbose') && params.verbose
    fprintf(['Code-level SFD correlation: %.3f, preamble-symbol best ', ...
        '%s-template shift: %d.\n'], best_correlation, ...
        preamble.selected_sfd_name, shifts(best_index));
    fprintf('Using measured %d + %d boundary: SFD shift = 0.\n', ...
        params.preamble_repetitions, length(sfd_sequence));
    fprintf('SFD shift candidates [shift; correlation]:\n');
    disp([shifts; correlations]);
end
end
