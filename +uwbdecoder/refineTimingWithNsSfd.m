function preamble = refineTimingWithNsSfd(rx, preamble, reference, sfdTemplates, params)
if nargin < 5 || isempty(sfdTemplates)
    sfdTemplates = struct('decawave', [], 'ieee', [], 'sfd4z_1', [], 'sfd4z_2', [], 'sfd4z_3', [], 'sfd4z_4', []);
end
%REFINETIMINGWITHNSSFD Select the SFD template and refine frame timing.
%   PREAMBLE = REFINETIMINGWITHNSSFD(RX, PREAMBLE, REFERENCE, PARAMS)
%   picks the best-matching SFD template (Decawave, IEEE, or 802.15.4z)
%   and refines the preamble start sample at full rate. Full-rate matching
%   uses the unshaped sampled spreading code at the HRP pulse grid. The
%   selected template name and correlation are stored back into PREAMBLE.
%
%   See also ANALYZENSSFDSYMBOLS, LOCATENSSFD.

switch params.sfd_mode
    case 'decawave'
        candidateNames = {'Decawave DW-8'};
        candidateSequences = {sfdTemplates.decawave};
    case 'ieee'
        candidateNames = {'IEEE legacy/BPRF SFD #0'};
        candidateSequences = {sfdTemplates.ieee};
    case '4z1'
        candidateNames = {'IEEE 802.15.4z SFD #1'};
        candidateSequences = {sfdTemplates.sfd4z_1};
    case '4z2'
        candidateNames = {'IEEE 802.15.4z SFD #2'};
        candidateSequences = {sfdTemplates.sfd4z_2};
    case '4z3'
        candidateNames = {'IEEE 802.15.4z SFD #3'};
        candidateSequences = {sfdTemplates.sfd4z_3};
    case '4z4'
        candidateNames = {'IEEE 802.15.4z SFD #4'};
        candidateSequences = {sfdTemplates.sfd4z_4};
    case 'auto'
        candidateNames = {'Decawave DW-8', ...
            'IEEE legacy/BPRF SFD #0', 'IEEE 802.15.4z SFD #2'};
        candidateSequences = {sfdTemplates.decawave, ...
            sfdTemplates.ieee, sfdTemplates.sfd4z_2};
        % HPRF uses code indices 25--32 and additionally permits SFD
        % numbers 1, 3, and 4. Do not test the short #1 template in BPRF
        % auto mode because a partial #2 match can otherwise select it.
        if params.code_index >= 25 && params.code_index <= 32
            candidateNames = [candidateNames, ...
                {'IEEE 802.15.4z SFD #1', ...
                 'IEEE 802.15.4z SFD #3', ...
                 'IEEE 802.15.4z SFD #4'}];
            candidateSequences = [candidateSequences, ...
                {sfdTemplates.sfd4z_1, sfdTemplates.sfd4z_3, ...
                 sfdTemplates.sfd4z_4}];
        end
end

expected = preamble.start_sample + round( ...
    params.preamble_repetitions * preamble.measured_period);
correlations = zeros(numel(candidateSequences), 1);
startSamples = zeros(numel(candidateSequences), 1);

for k = 1:numel(candidateSequences)
    sfdReference = kron(candidateSequences{k}, reference.sampled_code);
    sfdReference = sfdReference / (norm(sfdReference) + eps);
    searchStart = max(1, expected - reference.samples_per_symbol);
    searchEnd = min(length(rx), expected + reference.samples_per_symbol + ...
        length(sfdReference) - 1);
    searchSignal = rx(searchStart:searchEnd);
    matched = uwbdecoder.fftFilter( ...
        flipud(conj(sfdReference)), searchSignal);
    energy = sqrt(movsum(abs(searchSignal).^2, ...
        [length(sfdReference)-1, 0]));
    score = abs(matched) ./ (energy + eps);
    validEnds = length(sfdReference):length(searchSignal);
    [correlations(k), localOffset] = max(score(validEnds));
    startSamples(k) = searchStart + validEnds(localOffset) - ...
        length(sfdReference);
    if isfield(params, 'verbose') && params.verbose
        fprintf('Full-rate %s correlation: %.3f.\n', ...
            candidateNames{k}, correlations(k));
    end
end

[correlation, selectedIndex] = max(correlations);
sfdStart = startSamples(selectedIndex);
if isfield(params, 'verbose') && params.verbose
    fprintf('Selected SFD template: %s.\n', candidateNames{selectedIndex});
end

if correlation >= 0.10
    refinedStart = sfdStart - round( ...
        params.preamble_repetitions * preamble.measured_period);
    timingShift = refinedStart - preamble.start_sample;
    preamble.start_sample = refinedStart;
    preamble.peaks = preamble.peaks + timingShift;
    preamble.strongest_end = preamble.strongest_end + timingShift;
    if isfield(params, 'verbose') && params.verbose
        fprintf('SFD-refined preamble start: work sample %d.\n', ...
            preamble.start_sample);
    end
end

preamble.sfd_waveform_correlation = correlation;
preamble.sfd_waveform_candidate_names = candidateNames;
preamble.sfd_waveform_candidate_correlations = correlations;
preamble.selected_sfd_name = candidateNames{selectedIndex};
preamble.selected_sfd_sequence = candidateSequences{selectedIndex};
preamble.sfd_start_sample = sfdStart;
end
