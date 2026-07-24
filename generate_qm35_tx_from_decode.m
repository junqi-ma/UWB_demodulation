function tx = generate_qm35_tx_from_decode(decoded, options)
%GENERATE_QM35_TX_FROM_DECODE Rebuild a QM35 frame from decoded PSDU bits.
%   TX = GENERATE_QM35_TX_FROM_DECODE(DECODED) accepts the DECODED result
%   returned by decode_x410_dw1000. The decoded PSDU is reused bit-for-bit,
%   including its two FCS bytes, and an IEEE 802.15.4z BPRF/SFD #2 waveform
%   is generated.
%
%   TX.waveform_work is sampled at the HRP rate (998.4 MHz).
%   TX.waveform_x410 is resampled to OPTIONS.fs_tx and frequency shifted so
%   that an X410 tuned to OPTIONS.x410_center_frequency transmits at
%   OPTIONS.qm35_center_frequency.
%
%   The MATLAB BPRF generator only permits a 64-symbol preamble. QM35 uses
%   128 symbols in the capture, so this function generates a standard
%   64-symbol frame and explicitly extends its SYNC field to 128 symbols.
%
%   See also APPLY_ESTIMATED_CIR_TO_QM35, DECODE_X410_DW1000.

defaults = struct('fs_tx', 737.28e6, ...
    'x410_center_frequency', 6500e6, ...
    'qm35_center_frequency', 6489.6e6, ...
    'phy_mode', 'BPRF', ...
    'ranging', false, ...
    'preamble_repetitions', 128, 'code_index', 9, ...
    'sfd_number', 2, 'peak_amplitude', 0.8, ...
    'sfd_sequence', [], 'guard_samples', 4096, ...
    'require_fcs_pass', true);
if nargin < 2
    options = struct();
end
if ~isstruct(options) || ~isscalar(options)
    error('generate_qm35_tx_from_decode:InvalidOptions', ...
        'OPTIONS must be a scalar structure.');
end
unknown = setdiff(fieldnames(options), fieldnames(defaults));
if ~isempty(unknown)
    error('generate_qm35_tx_from_decode:UnknownOption', ...
        'Unknown option: %s', strjoin(unknown, ', '));
end
names = fieldnames(options);
for k = 1:numel(names)
    defaults.(names{k}) = options.(names{k});
end
options = defaults;
validateOptions(options);

[psduBits, psduBytes, fcsPass] = extractPsdu(decoded);
if options.require_fcs_pass && ~fcsPass
    error('generate_qm35_tx_from_decode:FcsFailed', ...
        ['The decoded FCS did not pass. Set require_fcs_pass=false only ', ...
         'when intentionally regenerating a damaged frame.']);
end
if isempty(psduBits) || mod(numel(psduBits), 8) ~= 0
    error('generate_qm35_tx_from_decode:InvalidPsdu', ...
        'The decoded PSDU must contain a nonempty whole number of bytes.');
end

psduLength = numel(psduBits) / 8;
if strcmpi(options.phy_mode, '802.15.4a')
    cfg = lrwpanHRPConfig(Mode='802.15.4a', MeanPRF=62.4, ...
        DataRate=6.81, SamplesPerPulse=2, ...
        CodeIndex=options.code_index, PreambleDuration=64, ...
        Ranging=options.ranging, PSDULength=psduLength);
else
    cfg = lrwpanHRPConfig(Mode='BPRF', MeanPRF=62.4, DataRate=6.81, ...
        PHRDataRate=0.85, SamplesPerPulse=2, ...
        STSPacketConfiguration=0, CodeIndex=options.code_index, ...
        PreambleDuration=64, SFDNumber=options.sfd_number, ...
        Ranging=options.ranging, PSDULength=psduLength);
end

[~, standardPulseSymbols] = ...
    lrwpanWaveformGenerator(double(psduBits), cfg);
standardIndices = lrwpanHRPFieldIndices(cfg);
syncLength = standardIndices.SYNC(2) - standardIndices.SYNC(1) + 1;
samplesPerSync = syncLength / cfg.PreambleDuration;
if samplesPerSync ~= round(samplesPerSync)
    error('generate_qm35_tx_from_decode:NonintegerSync', ...
        'The generated SYNC length is not an integer number of symbols.');
end
samplesPerSync = round(samplesPerSync);
symbolsPerSync = samplesPerSync / cfg.SamplesPerPulse;
if symbolsPerSync ~= round(symbolsPerSync)
    error('generate_qm35_tx_from_decode:NonintegerPulseGrid', ...
        'SYNC does not contain an integer number of pulse-grid samples.');
end
symbolsPerSync = round(symbolsPerSync);
syncPulseSymbols = standardPulseSymbols(1:symbolsPerSync);
standardSfdSymbol = ...
    (standardIndices.SFD(1) - 1) / cfg.SamplesPerPulse + 1;
standardPhrSymbol = ...
    (standardIndices.PHR(1) - 1) / cfg.SamplesPerPulse + 1;

% Keep the generator-produced SFD/PHR/PSDU pulse grid, replacing only SYNC.
% The second generator output is the exact pre-pulse-shaping {-1,0,+1}
% sequence. Shaping it here also keeps the IIR state continuous across the
% custom 128-symbol preamble boundary.
if isempty(options.sfd_sequence)
    sfdAndBodySymbols = standardPulseSymbols(standardSfdSymbol:end);
    selectedSfdSequence = [];
else
    selectedSfdSequence = options.sfd_sequence(:);
    if any(~ismember(selectedSfdSequence, [-1, 0, 1]))
        error('generate_qm35_tx_from_decode:InvalidSfdSequence', ...
            'sfd_sequence must contain only -1, 0, and +1.');
    end
    preambleCode = lrwpan.internal.HRPCodes(options.code_index);
    spreadCode = zeros( ...
        numel(preambleCode)*cfg.PreambleSpreadingFactor, 1);
    spreadCode(1:cfg.PreambleSpreadingFactor:end) = preambleCode(:);
    customSfdSymbols = kron(selectedSfdSequence, spreadCode);
    standardSfdLength = standardPhrSymbol - standardSfdSymbol;
    if numel(customSfdSymbols) ~= standardSfdLength
        error('generate_qm35_tx_from_decode:SfdLengthMismatch', ...
            ['Custom SFD occupies %d pulse-grid samples; the generated ', ...
             'SFD field occupies %d.'], ...
            numel(customSfdSymbols), standardSfdLength);
    end
    sfdAndBodySymbols = [customSfdSymbols; ...
        standardPulseSymbols(standardPhrSymbol:end)];
end

pulseSymbolsWork = [repmat(syncPulseSymbols, ...
    options.preamble_repetitions, 1); sfdAndBodySymbols];
pulseImpulsesWork = zeros( ...
    numel(pulseSymbolsWork)*cfg.SamplesPerPulse, 1);
pulseImpulsesWork(1:cfg.SamplesPerPulse:end) = pulseSymbolsWork;
[shapeB, shapeA] = butter(4, 1/cfg.SamplesPerPulse);
waveformWork = filter(shapeB, shapeA, pulseImpulsesWork);
extraSyncSamples = ...
    (options.preamble_repetitions - cfg.PreambleDuration)*samplesPerSync;
fieldIndices = standardIndices;
fieldIndices.SYNC = [1, options.preamble_repetitions*samplesPerSync];
fieldIndices.SHR = [1, standardIndices.SHR(2) + extraSyncSamples];
fieldIndices.SFD = standardIndices.SFD + extraSyncSamples;
fieldIndices.PHR = standardIndices.PHR + extraSyncSamples;
fieldIndices.Payload = standardIndices.Payload + extraSyncSamples;

[p, q] = rat(options.fs_tx / cfg.SampleRate, 1e-12);
waveformX410 = resample(waveformWork, p, q);
digitalOffsetHz = ...
    options.qm35_center_frequency - options.x410_center_frequency;
n = (0:numel(waveformX410)-1).';
waveformX410 = waveformX410 .* ...
    exp(1j*2*pi*digitalOffsetHz*n / options.fs_tx);

peak = max(abs(waveformX410));
if peak > 0
    waveformX410 = waveformX410 * (options.peak_amplitude / peak);
end
if options.guard_samples > 0
    guard = complex(zeros(options.guard_samples, 1));
    waveformX410 = [guard; waveformX410; guard];
end

tx = struct();
tx.psdu_bits = logical(psduBits(:));
tx.psdu_bytes = uint8(psduBytes(:));
tx.fcs_pass_at_decode = logical(fcsPass);
tx.phy_config = cfg;
tx.phy_mode = options.phy_mode;
tx.ranging = options.ranging;
tx.preamble_repetitions = options.preamble_repetitions;
tx.sfd_number = options.sfd_number;
tx.sfd_sequence = selectedSfdSequence;
tx.field_indices_work = fieldIndices;
tx.pulse_symbols_work = int8(pulseSymbolsWork);
tx.pulse_impulses_work = pulseImpulsesWork;
tx.pulse_shaping_b = shapeB;
tx.pulse_shaping_a = shapeA;
tx.samples_per_pulse = cfg.SamplesPerPulse;
tx.sample_rate_work = cfg.SampleRate;
tx.sample_rate_tx = options.fs_tx;
tx.digital_offset_hz = digitalOffsetHz;
tx.x410_center_frequency = options.x410_center_frequency;
tx.qm35_center_frequency = options.qm35_center_frequency;
tx.waveform_work = waveformWork;
tx.waveform_x410 = waveformX410;
tx.guard_samples = options.guard_samples;
tx.duration_s = numel(waveformX410) / options.fs_tx;
end

% -------------------------------------------------------------------------
function validateOptions(options)
if ~(ischar(options.phy_mode) || ...
        (isstring(options.phy_mode) && isscalar(options.phy_mode))) || ...
        ~any(strcmpi(string(options.phy_mode), ["BPRF", "802.15.4a"]))
    error('generate_qm35_tx_from_decode:InvalidOption', ...
        'phy_mode must be ''BPRF'' or ''802.15.4a''.')
end
if ~(islogical(options.ranging) && isscalar(options.ranging)) && ...
        ~(isnumeric(options.ranging) && isscalar(options.ranging) && ...
          ismember(options.ranging, [0, 1]))
    error('generate_qm35_tx_from_decode:InvalidOption', ...
        'ranging must be a logical scalar.')
end
positiveScalars = {'fs_tx', 'peak_amplitude'};
for k = 1:numel(positiveScalars)
    value = options.(positiveScalars{k});
    if ~isnumeric(value) || ~isscalar(value) || ~isfinite(value) || value <= 0
        error('generate_qm35_tx_from_decode:InvalidOption', ...
            '%s must be a positive finite scalar.', positiveScalars{k});
    end
end
integerFields = {'preamble_repetitions', 'code_index', ...
    'sfd_number', 'guard_samples'};
for k = 1:numel(integerFields)
    value = options.(integerFields{k});
    if ~isnumeric(value) || ~isscalar(value) || value ~= fix(value)
        error('generate_qm35_tx_from_decode:InvalidOption', ...
            '%s must be an integer scalar.', integerFields{k});
    end
end
if options.preamble_repetitions <= 0 || options.guard_samples < 0
    error('generate_qm35_tx_from_decode:InvalidOption', ...
        'Preamble repetitions must be positive and guard samples nonnegative.')
end
if ~ismember(options.sfd_number, 0:4)
    error('generate_qm35_tx_from_decode:InvalidOption', ...
        'sfd_number must be in the range 0..4.')
end
end

function [bits, bytes, fcsPass] = extractPsdu(decoded)
if isstruct(decoded) && isfield(decoded, 'payload')
    payload = decoded.payload;
else
    payload = decoded;
end
if ~isstruct(payload)
    error('generate_qm35_tx_from_decode:InvalidInput', ...
        'Input must be a decoder result or a payload structure.');
end

bits = [];
bytes = uint8([]);
fcsPass = false;
if isfield(payload, 'bits') && ~isempty(payload.bits)
    bits = logical(payload.bits(:));
end
if isfield(payload, 'bytes') && ~isempty(payload.bytes)
    bytes = uint8(payload.bytes(:));
end
if isempty(bits) && ~isempty(bytes)
    byteGrid = repmat(bytes, 1, 8);
    bitPositions = repmat(1:8, numel(bytes), 1);
    bits = reshape(bitget(byteGrid, bitPositions).', [], 1) ~= 0;
end
if isempty(bytes) && ~isempty(bits) && mod(numel(bits), 8) == 0
    bitMatrix = reshape(uint8(bits), 8, []).';
    weights = uint16(2.^(0:7)).';
    bytes = uint8(uint16(bitMatrix)*weights);
end
if isfield(payload, 'fcs_pass')
    fcsPass = logical(payload.fcs_pass);
end
end
