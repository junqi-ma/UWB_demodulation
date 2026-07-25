function [secdedPass, PSDULength] = helperUWBPHRDecode(cwPHR, cfg, CL)
%helperUWBPHRDecode % PHR decoding (SECDED, frame decoding)
%   [CW, END] = HELPERUWBPHRDECODE(CWPHR, CFG, CL) demodulates and
%   decodes the codewords CWPHR of the PHY header (PHR) of an HRP-ERDEV
%   IEEE 802.15.4z signal. Decoding occurs as per the lrwpanHRPConfig
%   configuration CFG and the constraint length CL.

%   Copyright 2022 The MathWorks, Inc.  

demodPHR = helperUWBConvDec(cwPHR(:), CL);
numPHRBits = 19;
demodPHR = demodPHR(1:numPHRBits);

% SECDED decoding 
% The parity bit XOR formula can construct a binary index address pointing
% to the location of the error in the systematic bits.
% Addressing is constructed after removing powers of two from possible indexes: 
% [b0 b1 b2 b3 b4 b5 b6 b7 b8 b9 b10 b11 b12]
%   3  5  6  7  9 10 11 12 13 14  15  17  18
  
  receivedSystematic = demodPHR(1:13);
  receivedParity = demodPHR(14:end);
  phr = lrwpan.internal.hrpSECDED(receivedSystematic);
  syndromes = xor(receivedParity, phr(14:end));
  
  idx = bit2int(syndromes(2:end), length(syndromes(2:end))); % exclude 14th bit, which is for DED only, not for error addressing
  
  secdedPass = true;
  if idx > 0 % error can be corrected
    powersOf2 = 2.^(0:5);
    addresses = setdiff(1:length(demodPHR), powersOf2);
    errorLocation = find(addresses==idx);
    phr(errorLocation) = ~phr(errorLocation);
      
    if ~syndromes(1) % Double error detection. 2nd error cannot be corrected.
      %warning(message('zigbee:LRWPAN:DED'));
      secdedPass = false;
    end
  end
  
  inHPRF = cfg.MeanPRFNum > 62.4;
  if inHPRF
    if cfg.STSPacketConfiguration == 2 && (cfg.ExtraSTSGapLength > 0 || cfg.ExtraSTSGapIndex > 0) 
      extraGapIdx = bit2int(phr([1 2]), 2);
      PSDULength = bit2int(phr(3:12), 10);
    else
      PSDULength = bit2int(phr(1:12), 12);
    end
    
    ranging = logical(phr(13));
  else
    if cfg.MeanPRFNum == 3.9
      dataRates = [0.11 0.85 1.7 6.81];
    else
      dataRates = [0.11 0.85 6.81 27.24];
    end
    dataRate = dataRates(1+bit2int(phr([1 2]), 2));
    
    PSDULength = bit2int(phr(3:9), 7); %#ok<*NASGU> 
    
    ranging = logical(phr(10));
    
    preambleDurations = [16 64 1024 4096];
    preambleDuration = preambleDurations(1+bit2int(phr([12 13]), 2, false));
  end
end