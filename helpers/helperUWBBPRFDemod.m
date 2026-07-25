function [cw, fieldEnd] = helperUWBBPRFDemod(isPHR, ternarySymbols, fieldStart, cfg, varargin)
%helperUWBBPRFDemod Demodulate BPRF HRP-UWB PHR/payload BPM-BPSK symbols
%
%   [CW, END] = helperUWBBPRFDemod(true, SYM, START, CFG)
%   demodulates BPRF PHR beginning at START.
%
%   [CW, END] = helperUWBBPRFDemod(false, SYM, START, CFG, NUMSYMBOLS)
%   demodulates BPRF payload-like BPM-BPSK symbols. NUMSYMBOLS here is the
%   number of BPM-BPSK symbols/codewords to demodulate, not necessarily PSDU
%   length in bytes.
%
%   Output CW is 2-by-N:
%       CW(1,:) = g0, BPM position bit
%       CW(2,:) = g1, BPSK polarity bit
%
%   Assumption:
%   SYM is a chip-rate ternary sequence after pulse detection/matched filter,
%   with active chips approximately +1/-1 and inactive chips near 0.

  ternarySymbols = ternarySymbols(:);

  % -------------------------------
  % 1) BPRF basic parameters
  % -------------------------------
  phrLen = 19;
  constraintLength = 3;        % BPRF payload/PHR uses CL=3
  numPHRSym = phrLen + constraintLength - 1;  % 19 + 2 tail symbols = 21

  if isPHR
    numSymbols = numPHRSym;

    % BPRF PHRDataRate can be 0.85 or 6.81 Mbps.
    phrDataRate = localGetCfg(cfg, "PHRDataRate", 0.85);

    if phrDataRate < 2
      chipsPerBurst  = 64;
      chipsPerSymbol = 512;
    else
      chipsPerBurst  = 8;
      chipsPerSymbol = 64;
    end

    pnMaskOffset = 0;

  else
    if isempty(varargin)
      error("For payload demodulation, pass NUMSYMBOLS as the 5th input.");
    end

    numSymbols = varargin{1};

    % BPRF payload rate is fixed at 6.81 Mbps:
    % 8 chips/burst, 64 chips/symbol.
    chipsPerBurst  = 8;
    chipsPerSymbol = 64;

    % Offset the scrambler by the number of active PHR chips.
    phrDataRate = localGetCfg(cfg, "PHRDataRate", 0.85);
    if phrDataRate < 2
      phrChipsPerBurst = 64;
    else
      phrChipsPerBurst = 8;
    end
    pnMaskOffset = numPHRSym * phrChipsPerBurst;
  end

  % If cfg contains MathWorks internal fields, prefer them.
  cpbFromCfg = localGetCfg(cfg, "ChipsPerBurst", []);
  if ~isempty(cpbFromCfg)
    if isPHR
      chipsPerBurst = cpbFromCfg(1);
    else
      chipsPerBurst = cpbFromCfg(end);
    end
    chipsPerSymbol = 8 * chipsPerBurst;  % BPRF 62.4 MHz: active burst is 1/8 symbol
  end

  % -------------------------------
  % 2) Basic consistency checks
  % -------------------------------
  fieldEnd = fieldStart + chipsPerSymbol*numSymbols - 1;

  if fieldStart < 1 || fieldEnd > numel(ternarySymbols)
    error("Input ternarySymbols is too short: need samples %d:%d.", fieldStart, fieldEnd);
  end

  quarterLen = chipsPerSymbol / 4;

  if mod(quarterLen, chipsPerBurst) ~= 0
    error("Invalid BPRF timing: quarterLen/chipsPerBurst is not integer.");
  end

  % For BPRF mean PRF 62.4 MHz, there are 2 candidate bursts per active quarter.
  numHopBursts = quarterLen / chipsPerBurst;

  if numHopBursts ~= 2
    warning("Expected 2 hop bursts per quarter for BPRF 62.4 MHz, got %d.", numHopBursts);
  end

  % -------------------------------
  % 3) Scrambler / spreading sequence
  % -------------------------------
  codeIndex = localGetCfg(cfg, "CodeIndex", []);

  if isempty(codeIndex)
    error("cfg.CodeIndex is required for BPRF descrambling.");
  end

  try
    pn = lrwpan.internal.createScrambler(codeIndex, chipsPerBurst, pnMaskOffset);
  catch ME
    error("Cannot create lrwpan.internal.createScrambler. Original error: %s", ME.message);
  end

  % -------------------------------
  % 4) Reshape into one column per BPM-BPSK symbol
  % -------------------------------
  rx = ternarySymbols(fieldStart:fieldEnd);
  symbols = reshape(rx, chipsPerSymbol, []);

  cw = zeros(2, numSymbols);

  % Candidate burst starts inside quarter 1 and quarter 3.
  % MATLAB indexing is 1-based.
  hopOffsets = (0:numHopBursts-1) * chipsPerBurst;

  q0Base = 0;                % 1st quarter, BPM bit g0 = 0
  q1Base = 2 * quarterLen;   % 3rd quarter, BPM bit g0 = 1

  % -------------------------------
  % 5) BPM-BPSK hard demodulation
  % -------------------------------
  for sym = 1:numSymbols
    thisSym = real(symbols(:, sym));

    % PN sequence for this active burst.
    % 0 -> +1, 1 -> -1.
    spreadingBits = pn();
    spreadingSeq  = 1 - 2*spreadingBits(:);

    metricPos0 = zeros(1, numHopBursts);
    metricPos1 = zeros(1, numHopBursts);

    for h = 1:numHopBursts
      idx0 = q0Base + hopOffsets(h) + (1:chipsPerBurst);
      idx1 = q1Base + hopOffsets(h) + (1:chipsPerBurst);

      burst0 = thisSym(idx0);
      burst1 = thisSym(idx1);

      % Coherent projection onto the expected scrambled burst.
      metricPos0(h) = sum(burst0(:) .* spreadingSeq);
      metricPos1(h) = sum(burst1(:) .* spreadingSeq);
    end

    % Position bit: choose the quarter with larger absolute correlation.
    [best0, hop0] = max(abs(metricPos0));
    [best1, hop1] = max(abs(metricPos1));

    if best0 >= best1
      cw(1, sym) = 0;                 % g0: position bit
      bestMetric = metricPos0(hop0);
    else
      cw(1, sym) = 1;                 % g0: position bit
      bestMetric = metricPos1(hop1);
    end

    % Polarity bit: sign after descrambling.
    % positive -> g1 = 0, negative -> g1 = 1
    cw(2, sym) = bestMetric < 0;
  end
end

function val = localGetCfg(cfg, name, defaultVal)
% Read cfg.name from either object or struct. Return defaultVal if absent.

  name = char(name);

  if isstruct(cfg)
    if isfield(cfg, name)
      val = cfg.(name);
    else
      val = defaultVal;
    end
  else
    if isprop(cfg, name)
      val = cfg.(name);
    else
      val = defaultVal;
    end
  end

  if isstring(val) || ischar(val)
    val = double(str2double(val));
    if isnan(val)
      val = defaultVal;
    end
  end
end