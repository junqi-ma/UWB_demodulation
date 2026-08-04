function [cw, fieldEnd] = helperUWBBPRFDemodPostCmf(isPHR, pathChips, fieldStart, cfg, pathCoefficients, varargin)
%HELPERUWBBPRFDEMODPOSTCMF BPRF demodulation with PN-first path combining.
%   PATHCHIPS is N-by-P raw complex chip samples for P CIR paths.  Each
%   candidate burst is PN de-spread independently per path, then the P
%   complex metrics are combined with conjugated CIR coefficients.

if isvector(pathChips)
    pathChips = pathChips(:);
end

phrLen = 19;
constraintLength = 3;
numPHRSym = phrLen + constraintLength - 1;
if isPHR
    numSymbols = numPHRSym;
    phrDataRate = localGetCfg(cfg, "PHRDataRate", 0.85);
    if phrDataRate < 2
        chipsPerBurst = 64; chipsPerSymbol = 512;
    else
        chipsPerBurst = 8; chipsPerSymbol = 64;
    end
    pnMaskOffset = 0;
else
    if isempty(varargin)
        error('Payload demodulation requires NUMSYMBOLS.');
    end
    numSymbols = varargin{1};
    chipsPerBurst = 8; chipsPerSymbol = 64;
    phrDataRate = localGetCfg(cfg, "PHRDataRate", 0.85);
    if phrDataRate < 2, phrChipsPerBurst = 64; else, phrChipsPerBurst = 8; end
    pnMaskOffset = numPHRSym*phrChipsPerBurst;
end

cpbFromCfg = localGetCfg(cfg, "ChipsPerBurst", []);
if ~isempty(cpbFromCfg)
    if isPHR, chipsPerBurst = cpbFromCfg(1); else, chipsPerBurst = cpbFromCfg(end); end
    chipsPerSymbol = 8*chipsPerBurst;
end
fieldEnd = fieldStart + chipsPerSymbol*numSymbols - 1;
if fieldStart < 1 || fieldEnd > size(pathChips, 1)
    error('Post-CMF chip matrix is too short: need rows %d:%d.', fieldStart, fieldEnd);
end

quarterLen = chipsPerSymbol/4;
numHopBursts = quarterLen/chipsPerBurst;
if mod(numHopBursts, 1) ~= 0
    error('Invalid BPRF timing.');
end
codeIndex = localGetCfg(cfg, "CodeIndex", []);
if isempty(codeIndex), error('cfg.CodeIndex is required for BPRF descrambling.'); end
pn = lrwpan.internal.createScrambler(codeIndex, chipsPerBurst, pnMaskOffset);

weights = conj(pathCoefficients(:)).';
if numel(weights) ~= size(pathChips, 2)
    error('Path-coefficient count does not match the chip matrix.');
end
symbols = reshape(pathChips(fieldStart:fieldEnd, :), chipsPerSymbol, numSymbols, []);
cw = zeros(2, numSymbols);
hopOffsets = (0:numHopBursts-1)*chipsPerBurst;
for sym = 1:numSymbols
    spreadingSeq = 1 - 2*pn();
    spreadingSeq = spreadingSeq(:);
    metricPos0 = complex(zeros(1, numHopBursts));
    metricPos1 = complex(zeros(1, numHopBursts));
    for h = 1:numHopBursts
        idx0 = hopOffsets(h) + (1:chipsPerBurst);
        idx1 = 2*quarterLen + hopOffsets(h) + (1:chipsPerBurst);
        burst0 = reshape(symbols(idx0, sym, :), chipsPerBurst, []);
        burst1 = reshape(symbols(idx1, sym, :), chipsPerBurst, []);
        metricPos0(h) = sum((spreadingSeq.' * burst0) .* weights);
        metricPos1(h) = sum((spreadingSeq.' * burst1) .* weights);
    end
    [best0, hop0] = max(abs(metricPos0));
    [best1, hop1] = max(abs(metricPos1));
    if best0 >= best1
        cw(1, sym) = 0; bestMetric = metricPos0(hop0);
    else
        cw(1, sym) = 1; bestMetric = metricPos1(hop1);
    end
    cw(2, sym) = real(bestMetric) < 0;
end
end

function val = localGetCfg(cfg, name, defaultVal)
name = char(name);
if isstruct(cfg)
    if isfield(cfg, name), val = cfg.(name); else, val = defaultVal; end
else
    if isprop(cfg, name), val = cfg.(name); else, val = defaultVal; end
end
if isstring(val) || ischar(val)
    val = double(str2double(val));
    if isnan(val), val = defaultVal; end
end
end
