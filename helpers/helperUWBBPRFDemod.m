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

  spreadingSequences = cachedSpreadingSequences( ...
      isPHR, codeIndex, chipsPerBurst, pnMaskOffset, numSymbols);

  % -------------------------------
  % 4) Reshape into one column per BPM-BPSK symbol
  % -------------------------------
  rx = ternarySymbols(fieldStart:fieldEnd);
  if isa(rx, 'single') && exist('helperUWBBPRFDemodKernel_mex', 'file') == 3
    [cw, fieldEnd] = helperUWBBPRFDemodKernel_mex( ...
        rx, fieldStart, numSymbols, chipsPerBurst, chipsPerSymbol, ...
        spreadingSequences);
  else
    [cw, fieldEnd] = helperUWBBPRFDemodKernel( ...
        rx, fieldStart, numSymbols, chipsPerBurst, chipsPerSymbol, ...
        spreadingSequences);
  end
end

function sequences = cachedSpreadingSequences( ...
    isPHR, codeIndex, chipsPerBurst, pnMaskOffset, numSymbols)
% Cache PHR and payload PN matrices independently on each MATLAB worker.
persistent phrKey phrSequences payloadKey payloadSequences

key = double([codeIndex, chipsPerBurst, pnMaskOffset]);
if isPHR
  cacheHit = ~isempty(phrKey) && isequal(phrKey, key) && ...
      size(phrSequences, 2) >= numSymbols;
  if ~cacheHit
    phrKey = key;
    phrSequences = generateSpreadingSequences( ...
        codeIndex, chipsPerBurst, pnMaskOffset, numSymbols);
  end
  sequences = phrSequences(:, 1:numSymbols);
else
  cacheHit = ~isempty(payloadKey) && isequal(payloadKey, key) && ...
      size(payloadSequences, 2) >= numSymbols;
  if ~cacheHit
    payloadKey = key;
    payloadSequences = generateSpreadingSequences( ...
        codeIndex, chipsPerBurst, pnMaskOffset, numSymbols);
  end
  sequences = payloadSequences(:, 1:numSymbols);
end
end

function sequences = generateSpreadingSequences( ...
    codeIndex, chipsPerBurst, pnMaskOffset, numSymbols)
try
  pn = lrwpan.internal.createScrambler( ...
      codeIndex, chipsPerBurst, pnMaskOffset);
catch ME
  error("Cannot create lrwpan.internal.createScrambler. Original error: %s", ...
      ME.message);
end
sequences = zeros(chipsPerBurst, numSymbols);
for sym = 1:numSymbols
  spreadingBits = pn();
  sequences(:, sym) = 1 - 2*double(spreadingBits(:));
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
