function sfd = locateNsSfd(soft_chips, reference, params, preamble)
%LOCATENSSFD Locate the selected SFD in the soft chip stream.
if nargin >= 4 && isfield(preamble, 'selected_sfd_sequence')
    sequence = preamble.selected_sfd_sequence(:);
    sfd_name = preamble.selected_sfd_name;
else
    sequence = params.decawave_sfd(:);
    sfd_name = 'Decawave DW-8';
end
spread = kron(sequence, reference.spread_code);
expected_start = 1+params.preamble_repetitions*reference.chips_per_symbol;
half_width = 8;
search_start = max(1, expected_start-half_width);
search_end = min(length(soft_chips)-length(spread)+1, expected_start+half_width);
if search_end < search_start
    error('Capture is too short to contain the expected SFD.');
end
metric = zeros(search_end-search_start+1, 1, 'like', real(soft_chips(1)));
for k = search_start:search_end
    segment = soft_chips(k:k+length(spread)-1);
    metric(k-search_start+1) = real(spread'*segment)/ ...
        (norm(spread)*norm(segment)+eps);
end
[correlation, local_index] = max(abs(metric));
start_chip = search_start+local_index-1;
polarity = sign(metric(local_index));
if polarity == 0
    polarity = 1;
end
sfd = struct('name', sfd_name, 'sequence', sequence, 'spread', spread, ...
    'start_chip', start_chip, 'end_chip', start_chip+length(spread)-1, ...
    'correlation', correlation, 'polarity', polarity, ...
    'search_start', search_start, 'search_end', search_end, ...
    'metric', metric, 'local_index', local_index);
if isfield(params, 'verbose') && params.verbose
    fprintf('%s start: chip %d, normalized correlation: %.3f.\n', ...
        sfd_name, start_chip, correlation);
end
if correlation < 0.35
    warning('Weak %s match. Check configuration and timing.', sfd_name);
end
end

