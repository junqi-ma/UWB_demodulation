function frame = decodePhrAndPayloadPostCmf(pathChips, pathCoefficients, sfd, cfg, maxPsduBytes)
%DECODEPHRANDPAYLOADPOSTCMF Decode BPRF data with de-spread-first CMF.

if nargin < 5 || isempty(maxPsduBytes), maxPsduBytes = 127; end
if cfg.MeanPRFNum > 62.4
    error('decodePhrAndPayloadPostCmf:BPRFOnly', ...
        'The post-despread-CMF experiment currently supports BPRF only.');
end
pathChips = sfd.polarity*pathChips;
phrStart = sfd.end_chip + 1;
[cwPhr, phrEnd] = helperUWBBPRFDemodPostCmf(true, pathChips, phrStart, cfg, pathCoefficients);
[secdedPass, psduLength] = helperUWBPHRDecode(cwPhr, cfg, 3);

bits = []; bytes = uint8([]); payloadStart = []; payloadEnd = [];
fcsPass = false; calculatedFcs = uint16(0); receivedFcs = uint16(0);
if secdedPass && psduLength >= 0 && psduLength <= maxPsduBytes
    cfg.PSDULength = psduLength;
    payloadStart = phrEnd + 1;
    psduBits = cfg.PSDULength*8;
    N = 63; K = 55; blockSize = 330;
    numPayloadSymbols = psduBits + ((N-K)*blockSize/K)*ceil(psduBits/blockSize);
    [cwPayload, payloadEnd] = helperUWBBPRFDemodPostCmf(false, pathChips, ...
        payloadStart, cfg, pathCoefficients, numPayloadSymbols);
    if cfg.ConvolutionalCoding
        cw = [cwPhr cwPayload];
        decoded = helperUWBConvDec(cw(:), cfg.ConstraintLength);
        rsCW = decoded(20:end-2);
    else
        rsCW = cwPayload;
    end
    bits = lrwpan.internal.hrpRS(rsCW, false);
    byteCount = floor(numel(bits)/8);
    bytes = bit2int(reshape(bits(1:8*byteCount), 8, []), 8, false);
    if byteCount >= 2
        calculatedFcs = uwbdecoder.ieee802154CRC16(bytes(1:end-2));
        receivedFcs = uint16(bytes(end-1)) + bitshift(uint16(bytes(end)), 8);
        fcsPass = calculatedFcs == receivedFcs;
    end
end
frame = struct('phr_start', phrStart, 'phr_end', phrEnd, ...
    'coded_phr', cwPhr, 'secded_pass', logical(secdedPass), ...
    'psdu_length', psduLength, 'payload_start', payloadStart, ...
    'payload_end', payloadEnd, 'bits', bits, 'bytes', bytes, ...
    'received_fcs', receivedFcs, 'calculated_fcs', calculatedFcs, ...
    'fcs_pass', logical(fcsPass));
end
