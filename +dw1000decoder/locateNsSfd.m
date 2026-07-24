function sfd = locateNsSfd(softChips, reference, params, preamble)
%LOCATENSSFD Locate the selected SFD in the soft chip stream.
%   SFD = LOCATENSSFD(SOFTCHIPS, REFERENCE, PARAMS, PREAMBLE) searches
%   a small window around the expected SFD start for the best match of
%   the selected SFD sequence. Returns the chip index, correlation, and
%   polarity.
%
%   See also REFINETIMINGWITHNSSFD, DECODEPHRANDPAYLOAD.

if nargin >= 4 && isfield(preamble, 'selected_sfd_sequence')
    sequence = preamble.selected_sfd_sequence(:);
    sfdName = preamble.selected_sfd_name;
else
    sequence = params.decawave_sfd(:);
    sfdName = 'Decawave DW-8';
end

spread = kron(sequence, reference.spread_code);
expectedStart = 1 + params.preamble_repetitions*reference.chips_per_symbol;
halfWidth = 8;
searchStart = max(1, expectedStart - halfWidth);
searchEnd = min(length(softChips) - length(spread) + 1, expectedStart + halfWidth);
if searchEnd < searchStart
    error('locateNsSfd:CaptureTooShort', ...
        'Capture is too short to contain the expected SFD.');
end

metric = zeros(searchEnd - searchStart + 1, 1);
for k = searchStart:searchEnd
    segment = softChips(k:k+length(spread)-1);
    metric(k - searchStart + 1) = real(spread'*segment) / ...
        (norm(spread)*norm(segment) + eps);
end

[correlation, localIdx] = max(abs(metric));
startChip = searchStart + localIdx - 1;
polarity = sign(metric(localIdx));
if polarity == 0
    polarity = 1;
end

sfd = struct('name', sfdName, 'sequence', sequence, 'spread', spread, ...
    'start_chip', startChip, 'end_chip', startChip + length(spread) - 1, ...
    'correlation', correlation, 'polarity', polarity, ...
    'search_start', searchStart, 'search_end', searchEnd, ...
    'metric', metric, 'local_index', localIdx);

if isfield(params, 'verbose') && params.verbose
    fprintf('%s start: chip %d, normalized correlation: %.3f.\n', ...
        sfdName, startChip, correlation);
end

if correlation < 0.35
    warning('locateNsSfd:WeakMatch', ...
        'Weak %s match. Check configuration and timing.', sfdName);
end
end
