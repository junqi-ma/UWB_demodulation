function frame = decodePhrAndPayload(soft_chips, sfd, cfg)
%DECODEPHRANDPAYLOAD Decode the PHR, PSDU, and reflected frame CRC.
soft_chips = sfd.polarity*soft_chips;
phr_start = sfd.end_chip+1;
[cw_phr, phr_end] = helperUWBBPRFDemod(true, soft_chips, phr_start, cfg);
[secded_pass, psdu_length] = helperUWBPHRDecode(cw_phr, cfg, 3);
fprintf('PHR SECDED pass: %d, decoded PSDU length: %d bytes.\n', ...
    secded_pass, psdu_length);
bits = []; bytes = uint8([]); payload_start = []; payload_end = [];
fcs_pass = false; calculated_fcs = uint16(0); received_fcs = uint16(0);
if secded_pass && psdu_length >= 0 && psdu_length <= 127
    cfg.PSDULength = psdu_length;
    payload_start = phr_end+1;
    [bits, payload_end] = helperUWBPayloadDecode( ...
        soft_chips, payload_start, cw_phr, cfg);
    byte_count = floor(length(bits)/8);
    bytes = bit2int(reshape(bits(1:8*byte_count), 8, []), 8, false);
    fprintf('Decoded %d PSDU bits.\n', length(bits));
    fprintf('First decoded PSDU bytes (hex):\n');
    fprintf('%02X ', bytes(1:min(32, end))); fprintf('\n');
    if byte_count >= 2
        calculated_fcs = dw1000decoder.ieee802154CRC16(bytes(1:end-2));
        received_fcs = uint16(bytes(end-1))+bitshift(uint16(bytes(end)), 8);
        fcs_pass = calculated_fcs == received_fcs;
        fprintf('FCS received: 0x%04X, calculated: 0x%04X, pass: %d.\n', ...
            received_fcs, calculated_fcs, fcs_pass);
    end
else
    warning('Payload decoding skipped because the PHR is invalid.');
end
frame = struct('phr_start', phr_start, 'phr_end', phr_end, ...
    'coded_phr', cw_phr, 'secded_pass', logical(secded_pass), ...
    'psdu_length', psdu_length, 'payload_start', payload_start, ...
    'payload_end', payload_end, 'bits', bits, 'bytes', bytes, ...
    'received_fcs', received_fcs, 'calculated_fcs', calculated_fcs, ...
    'fcs_pass', logical(fcs_pass));
end
