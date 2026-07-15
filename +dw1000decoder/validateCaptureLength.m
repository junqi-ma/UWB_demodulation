function validateCaptureLength(rx, preamble, reference, params)
%VALIDATECAPTURELENGTH Ensure the capture includes the complete SHR.
sfd_length = configuredSfdLength(params);
required_end = preamble.start_sample+round( ...
    (params.preamble_repetitions+sfd_length)*preamble.measured_period)-1;
if required_end > length(rx)
    required_rx_samples = ceil(required_end*params.fs_rx/reference.fs);
    have_rx_samples = params.sample_num;
    missing_work = required_end-length(rx);
    error(['Capture ends before SFD.\n', ...
        '  preamble start (work) : %d\n', ...
        '  required end (work)   : %d (buffer length %d, short by %d)\n', ...
        '  preamble_repetitions  : %d, SFD symbols: %d\n', ...
        '  current sample_num    : %d\n', ...
        '  increase sample_num to at least %d (recommended %d).'], ...
        preamble.start_sample, required_end, length(rx), missing_work, ...
        params.preamble_repetitions, sfd_length, have_rx_samples, ...
        required_rx_samples, max(required_rx_samples, ...
        required_rx_samples+round(0.05e6)));
end
end

function sfd_length = configuredSfdLength(params)
switch params.sfd_mode
    case {'decawave', 'ieee', '4z2'}
        sfd_length = 8;
    case '4z1'
        sfd_length = 4;
    case '4z3'
        sfd_length = 16;
    case '4z4'
        sfd_length = 32;
    case 'auto'
        if params.code_index >= 25 && params.code_index <= 32
            sfd_length = 32;
        else
            sfd_length = 8;
        end
end
end
