function validateCaptureLength(rx, preamble, reference, params)
%VALIDATECAPTURELENGTH Ensure the capture includes the complete SHR.
%   VALIDATECAPTURELENGTH(RX, PREAMBLE, REFERENCE, PARAMS) errors if the
%   resampled work buffer RX is too short to contain the configured
%   preamble repetitions plus the SFD. On error it reports how many
%   additional samples are needed.
%
%   See also DETECTREPEATEDPREAMBLE.

sfdLength = configuredSfdLength(params);
requiredEnd = preamble.start_sample + round( ...
    (params.preamble_repetitions + sfdLength)*preamble.measured_period) - 1;

if requiredEnd > length(rx)
    requiredRxSamples = ceil(requiredEnd*params.fs_rx/reference.fs);
    haveRxSamples = params.sample_num;
    missingWork = requiredEnd - length(rx);
    error('validateCaptureLength:CaptureTooShort', ...
        ['Capture ends before SFD.\n', ...
         '  preamble start (work) : %d\n', ...
         '  required end (work)   : %d (buffer length %d, short by %d)\n', ...
         '  preamble_repetitions  : %d, SFD symbols: %d\n', ...
         '  current sample_num    : %d\n', ...
         '  increase sample_num to at least %d (recommended %d).'], ...
        preamble.start_sample, requiredEnd, length(rx), missingWork, ...
        params.preamble_repetitions, sfdLength, haveRxSamples, ...
        requiredRxSamples, max(requiredRxSamples, ...
        requiredRxSamples + round(0.05e6)));
end
end

% -------------------------------------------------------------------------
function sfdLength = configuredSfdLength(params)
switch params.sfd_mode
    case {'decawave', 'ieee', '4z2'}
        sfdLength = 8;
    case '4z1'
        sfdLength = 4;
    case '4z3'
        sfdLength = 16;
    case '4z4'
        sfdLength = 32;
    case 'auto'
        if params.code_index >= 25 && params.code_index <= 32
            sfdLength = 32;
        else
            sfdLength = 8;
        end
end
end
