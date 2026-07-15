function preamble = refineTimingWithNsSfd(rx, preamble, reference, params)
%REFINETIMINGWITHNSSFD Select the SFD template and refine frame timing.
switch params.sfd_mode
    case 'decawave'
        candidate_names = {'Decawave DW-8'};
        candidate_sequences = {params.decawave_sfd(:)};
    case 'ieee'
        candidate_names = {'IEEE legacy/BPRF SFD #0'};
        candidate_sequences = {params.ieee_sfd(:)};
    case '4z1'
        candidate_names = {'IEEE 802.15.4z SFD #1'};
        candidate_sequences = {params.sfd4z_1(:)};
    case '4z2'
        candidate_names = {'IEEE 802.15.4z SFD #2'};
        candidate_sequences = {params.sfd4z_2(:)};
    case '4z3'
        candidate_names = {'IEEE 802.15.4z SFD #3'};
        candidate_sequences = {params.sfd4z_3(:)};
    case '4z4'
        candidate_names = {'IEEE 802.15.4z SFD #4'};
        candidate_sequences = {params.sfd4z_4(:)};
    case 'auto'
        candidate_names = {'Decawave DW-8', ...
            'IEEE legacy/BPRF SFD #0', 'IEEE 802.15.4z SFD #2'};
        candidate_sequences = {params.decawave_sfd(:), ...
            params.ieee_sfd(:), params.sfd4z_2(:)};
        % HPRF uses code indices 25--32 and additionally permits SFD
        % numbers 1, 3, and 4. Do not test the short #1 template in BPRF
        % auto mode because a partial #2 match can otherwise select it.
        if params.code_index >= 25 && params.code_index <= 32
            candidate_names = [candidate_names, ...
                {'IEEE 802.15.4z SFD #1', ...
                 'IEEE 802.15.4z SFD #3', ...
                 'IEEE 802.15.4z SFD #4'}];
            candidate_sequences = [candidate_sequences, ...
                {params.sfd4z_1(:), params.sfd4z_3(:), ...
                 params.sfd4z_4(:)}];
        end
end

expected = preamble.start_sample+round( ...
    params.preamble_repetitions*preamble.measured_period);
correlations = zeros(numel(candidate_sequences), 1, 'like', real(rx(1)));
start_samples = zeros(numel(candidate_sequences), 1);
for k = 1:numel(candidate_sequences)
    sfd_reference = kron(candidate_sequences{k}, ...
        reference.preamble_waveform);
    sfd_reference = sfd_reference/(norm(sfd_reference)+eps);
    search_start = max(1, expected-reference.samples_per_symbol);
    search_end = min(length(rx), expected+reference.samples_per_symbol+ ...
        length(sfd_reference)-1);
    search_signal = rx(search_start:search_end);
    matched = dw1000decoder.fftfiltCompat( ...
        flipud(conj(sfd_reference)), search_signal);
    energy = sqrt(movsum(abs(search_signal).^2, ...
        [length(sfd_reference)-1, 0]));
    score = abs(matched)./(energy+eps);
    valid_ends = length(sfd_reference):length(search_signal);
    [correlations(k), local_offset] = max(score(valid_ends));
    start_samples(k) = search_start+valid_ends(local_offset)- ...
        length(sfd_reference);
    if isfield(params, 'verbose') && params.verbose
        fprintf('Full-rate %s correlation: %.3f.\n', ...
            candidate_names{k}, correlations(k));
    end
end
[correlation, selected_index] = max(correlations);
sfd_start = start_samples(selected_index);
if isfield(params, 'verbose') && params.verbose
    fprintf('Selected SFD template: %s.\n', candidate_names{selected_index});
end
if correlation >= 0.10
    preamble.start_sample = sfd_start-round( ...
        params.preamble_repetitions*preamble.measured_period);
    if isfield(params, 'verbose') && params.verbose
        fprintf('SFD-refined preamble start: work sample %d.\n', ...
            preamble.start_sample);
    end
end
preamble.sfd_waveform_correlation = correlation;
preamble.sfd_waveform_candidate_names = candidate_names;
preamble.sfd_waveform_candidate_correlations = correlations;
preamble.selected_sfd_name = candidate_names{selected_index};
preamble.selected_sfd_sequence = candidate_sequences{selected_index};
end
