function [PSDU, payloadEnd] = helperUWBPayloadDecode(ternarySymbols, payloadStart, cwPHR, cfg)
%helperUWBPayloadDecode Payload demodulation and decoding
%   [CW, END] = HELPERUWBPAYLOADDECODE(SYM, START, PHR, CFG) demodulates
%   and decodes the payload of an HRP-ERDEV IEEE 802.15.4z signal, which is
%   present in SYM, beginning at the START'th sample. Convolutional
%   decoding and Reed-Solomon decoding are performed. CWPHR contains the
%   codewords of the PHY header (PHR).

%   Copyright 2022 The MathWorks, Inc.

  phrNotPayload = false;
  
  PSDULength = cfg.PSDULength*8;  % bytes to bits
  if cfg.MeanPRFNum < 124.8 || cfg.ConstraintLength == 3
    % PSDU Length describe the number of uncoded octets. ternarySymbols
    % contain PSDU that may be RS-encoded
    N = 63;
    K = 55;
    blockSize = 330;
    % parity bits are added for any block of 333 bits, even if partially filled
    PSDULength = PSDULength + ((N-K)*blockSize/K) * ceil(PSDULength/blockSize);
  end
  
  % "Modulation symbols" to codewords
  inHPRF = cfg.MeanPRFNum > 62.4;
  if inHPRF
    [cwPayload, payloadEnd] = helperUWBHPRFDemod(phrNotPayload, ternarySymbols, payloadStart, cfg, PSDULength);
    
  else % BPM-BPSK (Burst-position modulation w BPSK)
    % 相关度量式解调：先按 PN 解扩积分，再做位置/极性判决，
    % 因此输入可以是软码片（保留幅度），不要求三值硬判决
    [cwPayload, payloadEnd] = helperUWBBPRFDemod(phrNotPayload, ternarySymbols, payloadStart, cfg, PSDULength);
  end
  
  % Rate 1/2 convolutional coding:
  if cfg.ConvolutionalCoding
    cw = [cwPHR cwPayload];
    decoded = helperUWBConvDec(cw(:), cfg.ConstraintLength);
    
    numPHRSymbols = 19;
    if cfg.MeanPRFNum < 124.8 || cfg.ConstraintLength == 3
      tailToIgnore = 2;
      rsCW = decoded(1+numPHRSymbols: end-tailToIgnore);
    
    else % CL = 7
      % Sec. 15.3.3.3 in 15.4z: "separately appending six zero bits to both the PHR and the PSDU"
      tailToIgnore = 6;
      % tail after payload is ignored during modulation
      rsCW = decoded(1+numPHRSymbols+tailToIgnore: end);
    end
    
  else % No Convolutional Coding
    rsCW = cwPayload;
  end
  
  % Reed Solomon decoding -> PSDU
  if cfg.MeanPRFNum < 124.8 || cfg.ConstraintLength == 3
    encodeNotDecode = false;
    PSDU = lrwpan.internal.hrpRS(rsCW, encodeNotDecode);
  else
    % no RS encoding when HPRF and constraint length = 7
    PSDU = rsCW;
  end
end