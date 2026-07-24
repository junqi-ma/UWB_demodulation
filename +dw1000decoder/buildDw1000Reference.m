function reference = buildDw1000Reference(params)
%BUILDDW1000REFERENCE Build waveform and sparse spreading-code references.
%   REFERENCE = BUILDDW1000REFERENCE(PARAMS) constructs the HRP reference
%   structure used throughout the decoder: the preamble waveform, the
%   sparse spreading code, and the sampled code at the HRP pulse grid.
%   Fields include cfg, fs, samples_per_symbol, preamble_waveform,
%   spread_code, sampled_code, chips_per_symbol, and code_energy.
%
%   See also DECODE_X410_DW1000.

cfg = lrwpanHRPConfig(Mode='802.15.4a', MeanPRF=62.4, ...
    DataRate=params.data_rate, PreambleDuration=64, ...
    CodeIndex=params.code_index, SamplesPerPulse=2, PSDULength=1);
tx = lrwpanWaveformGenerator(zeros(8, 1), cfg);
indices = lrwpanHRPFieldIndices(cfg);
samplesPerSymbol = indices.SYNC(end)/cfg.PreambleDuration;
preambleWaveform = tx(1:samplesPerSymbol);
preambleWaveform = preambleWaveform(:) / (norm(preambleWaveform) + eps);
code = lrwpan.internal.HRPCodes(params.code_index);
spreadCode = zeros(length(code)*cfg.PreambleSpreadingFactor, 1);
spreadCode(1:cfg.PreambleSpreadingFactor:end) = code(:);
sampledCode = zeros(length(spreadCode)*cfg.SamplesPerPulse, 1);
sampledCode(1:cfg.SamplesPerPulse:end) = spreadCode;
reference = struct('cfg', cfg, 'fs', cfg.SampleRate, ...
    'samples_per_symbol', samplesPerSymbol, ...
    'preamble_waveform', preambleWaveform, ...
    'spread_code', spreadCode, 'sampled_code', sampledCode, ...
    'chips_per_symbol', length(spreadCode), ...
    'code_energy', real(sampledCode'*sampledCode));
end
