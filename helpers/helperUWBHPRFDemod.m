function [cw, fieldEnd] = helperUWBHPRFDemod(isPHR, ternarySymbols, fieldStart, cfg, varargin)
%helperUWBHPRFDemod Demodulation as per the HRP-ERDEV scheme
%   [CW, END] = HELPERUWBHPRFDEMOD(false, SYM, START, CFG) demodulates the
%   PHY header (PHR) of an HRP-ERDEV IEEE 802.15.4z signal, which is
%   present in SYM, beginning at the START'th sample.
%
%   [CW, END] = HELPERUWBHPRFDEMOD(true, SYM, START, CFG, PSDULEN)
%   demodulates the payload of an HRP-ERDEV IEEE 802.15.4z signal, which is
%   present in SYM, beginning at the START'th sample. PSDULEN specifies the
%   length of the PSDU in bytes.

%   Copyright 2022 The MathWorks, Inc.
  
  phrLen = 19;
  if cfg.MeanPRFNum < 124.8 || cfg.ConstraintLength == 3
    numPHRSym = phrLen+2;
  else % CL = 7 
    numPHRSym = phrLen+6;
  end
  if isPHR
    numSymbols = numPHRSym;
  else
    PSDULength = varargin{1};
    numSymbols = PSDULength;
  end
  cw = zeros(2, numSymbols); % pre-allocate to prevent auto-grow in FOR loop

  fieldEnd = fieldStart; % init
  
  if cfg.MeanPRFNum > 124.8
    chipsPerSymbol = 16 * (1+isPHR); % double the symbols for PHR
  else
    chipsPerSymbol = 64 * (1+isPHR);
  end
  if cfg.ConstraintLength==7 && isPHR
    chipsPerSymbol = chipsPerSymbol/2;
  end
  % chipsPerSymbol above includes guard bands. ChipsPerSymbol from
  % lrwpanHRPConfig describes only the meaningful content (without guard bands)
  if isPHR
    pnSamplesPerFrame = cfg.ChipsPerSymbol(1);
    pnMaskOffset = 0;
  else
    pnSamplesPerFrame = cfg.ChipsPerSymbol(end);
    pnMaskOffset = numPHRSym*cfg.ChipsPerSymbol(1);
  end
  pn = lrwpan.internal.createScrambler(cfg.CodeIndex, pnSamplesPerFrame, pnMaskOffset);
  symbolMap = lrwpan.internal.hrpHPRFSymbolMap(cfg.MeanPRFNum, cfg.ConstraintLength);
  if ~isPHR && cfg.ConstraintLength==3
    symbolMap = symbolMap(:, 1:(end*(1+isPHR)/2));
  end
    
  symbols = reshape(ternarySymbols(fieldStart:fieldStart+numSymbols*chipsPerSymbol-1), chipsPerSymbol, []);
  if cfg.MeanPRFNum == 124.8
    symbols = symbols(1:2:end, :); % extra guard band between chips for 124.8 MHz
  end
  
  % Demodulate, ChipsPerSymbol bits -> 2-bit codewords
  % 与 BPRF 一致的"先解扩积分 -> 再判决"软判决范式（DW3000 模式）：
  %   - 解扩用乘法(乘 PN 双极性)而非除法，可吃软码片
  %   - 判决用相关度量(点积)而非汉明距离，保留幅度/可靠度信息
  longerPHR = isPHR && (cfg.ConstraintLength==3);

  % symbolMap 为 0/1 unipolar 的候选符号型，转成 ±1 双极性供相关使用
  % (0 -> +1, 1 -> -1)，与解扩后的软码片极性约定一致
  symbolMapBipolar = 1 - 2*symbolMap;

  for sym = 1:numSymbols
    thisSym = symbols(:, sym);

    % remove guard bands:
    thisSym = reshape(thisSym, [], 4*(1+longerPHR));
    thisSym = thisSym(:, 1:2:end);
    thisSym = thisSym(:);

    % ---- 先解扩：乘 PN 双极性，软码片保留幅度(获得处理增益, 平均掉 ISI) ----
    spreadingSeq = pn();
    thisSym = thisSym .* (1-2*spreadingSeq);   % 0->+1,1->-1，乘法解扩

    % ---- 再判决：与所有候选符号型做相关，取相关最大者 ----
    % 解扩后期望码片极性: +1。symbolMapBipolar 各行为候选符号的 ±1 chip 型。
    corrMetric = symbolMapBipolar * thisSym;    % 每个候选的相关积分
    [~, demodIdx] = max(corrMetric);

    % Map table index to binary codeword from Tables 15-10c/d/ef
    msbFirst = false;
    cw(:, sym) = int2bit(demodIdx-1, 2, msbFirst);
  end
  
  fieldEnd = fieldEnd + chipsPerSymbol*numSymbols -1;
end
