function [cw, fieldEnd] = helperUWBBPRFDemodKernel( ...
    fieldSamples, fieldStart, numSymbols, chipsPerBurst, ...
    chipsPerSymbol, spreadingSequences)
%HELPERUWBBPRFDEMODKERNEL Numeric BPRF BPM-BPSK demodulation kernel.
%   This function intentionally accepts only arrays and scalar dimensions
%   so MATLAB Coder can generate a MEX implementation. FIELDSAMPLES starts
%   at the requested field; FIELDSTART is retained for the public end index.

fieldSamples = fieldSamples(:);
assert(numSymbols <= 2048);
assert(numel(fieldSamples) >= chipsPerSymbol*numSymbols);
assert(size(spreadingSequences, 1) >= chipsPerBurst);
assert(size(spreadingSequences, 2) >= numSymbols);

symbols = reshape(fieldSamples(1:chipsPerSymbol*numSymbols), ...
    chipsPerSymbol, numSymbols);
cw = zeros(2, numSymbols);
quarterLength = chipsPerSymbol/4;
hopCount = quarterLength/chipsPerBurst;
thirdQuarterOffset = 2*quarterLength;

for symbolIndex = 1:numSymbols
  thisSymbol = real(symbols(:, symbolIndex));
  spreading = spreadingSequences(1:chipsPerBurst, symbolIndex);
  bestPosition0 = cast(-inf, 'like', thisSymbol);
  bestPosition1 = cast(-inf, 'like', thisSymbol);
  bestMetric0 = zeros(1, 'like', thisSymbol);
  bestMetric1 = zeros(1, 'like', thisSymbol);

  for hopIndex = 0:hopCount-1
    first0 = hopIndex*chipsPerBurst + 1;
    first1 = thirdQuarterOffset + first0;
    metric0 = sum(thisSymbol(first0:first0+chipsPerBurst-1) .* spreading);
    metric1 = sum(thisSymbol(first1:first1+chipsPerBurst-1) .* spreading);
    if abs(metric0) > bestPosition0
      bestPosition0 = abs(metric0);
      bestMetric0 = metric0;
    end
    if abs(metric1) > bestPosition1
      bestPosition1 = abs(metric1);
      bestMetric1 = metric1;
    end
  end

  if bestPosition0 >= bestPosition1
    bestMetric = bestMetric0;
  else
    cw(1, symbolIndex) = 1;
    bestMetric = bestMetric1;
  end
  cw(2, symbolIndex) = bestMetric < 0;
end

fieldEnd = fieldStart + chipsPerSymbol*numSymbols - 1;
end
