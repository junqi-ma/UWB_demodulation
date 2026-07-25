function frame = decodePhrAndPayload(softChips, sfd, cfg, maxPsduBytes)
%DECODEPHRANDPAYLOAD Decode the PHR, PSDU, and reflected frame CRC.
%   FRAME = DECODEPHRANDPAYLOAD(SOFTCHIPS, SFD, CFG) de-interleaves and
%   decodes the PHR, PSDU, and FCS from the signed soft-chip stream.
%   Returns a structure with phr, payload bytes, and fcs_pass fields.
%
%   See also LOCATENSSFD, IEEE802154CRC16.

softChips = sfd.polarity * softChips;
if nargin < 4 || isempty(maxPsduBytes)
    maxPsduBytes = 127;
end
phrStart = sfd.end_chip + 1;
[cwPhr, phrEnd] = helperUWBBPRFDemod(true, softChips, phrStart, cfg);
[secdedPass, psduLength] = helperUWBPHRDecode(cwPhr, cfg, 3);
fprintf('PHR SECDED pass: %d, decoded PSDU length: %d bytes.\n', ...
    secdedPass, psduLength);

bits = []; bytes = uint8([]); payloadStart = []; payloadEnd = [];
fcsPass = false; calculatedFcs = uint16(0); receivedFcs = uint16(0);

if secdedPass && psduLength >= 0 && psduLength <= maxPsduBytes
    cfg.PSDULength = psduLength;
    payloadStart = phrEnd + 1;
    [bits, payloadEnd] = helperUWBPayloadDecode( ...
        softChips, payloadStart, cwPhr, cfg);
    byteCount = floor(length(bits)/8);
    bytes = bit2int(reshape(bits(1:8*byteCount), 8, []), 8, false);
    fprintf('Decoded %d PSDU bits.\n', length(bits));
    fprintf('First decoded PSDU bytes (hex):\n');
    fprintf('%02X ', bytes(1:min(32, end))); fprintf('\n');
    if byteCount >= 2
        calculatedFcs = dw1000decoder.ieee802154CRC16(bytes(1:end-2));
        receivedFcs = uint16(bytes(end-1)) + bitshift(uint16(bytes(end)), 8);
        fcsPass = calculatedFcs == receivedFcs;
        fprintf('FCS received: 0x%04X, calculated: 0x%04X, pass: %d.\n', ...
            receivedFcs, calculatedFcs, fcsPass);
    end
else
    warning('decodePhrAndPayload:InvalidPhr', ...
        ['Payload decoding skipped because the PHR is invalid or the ', ...
        'decoded PSDU length exceeds max_psdu_bytes=%d.'], maxPsduBytes);
end

frame = struct('phr_start', phrStart, 'phr_end', phrEnd, ...
    'coded_phr', cwPhr, 'secded_pass', logical(secdedPass), ...
    'psdu_length', psduLength, 'payload_start', payloadStart, ...
    'payload_end', payloadEnd, 'bits', bits, 'bytes', bytes, ...
    'received_fcs', receivedFcs, 'calculated_fcs', calculatedFcs, ...
    'fcs_pass', logical(fcsPass));
end
