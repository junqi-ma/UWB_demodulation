function tx = generate_qm35_tx_from_decode(decoded, options)
%GENERATE_QM35_TX_FROM_DECODE Rebuild a QM35 frame from decoded PSDU bits.
%   TX = GENERATE_QM35_TX_FROM_DECODE(RESULT) accepts the RESULT returned by
%   decode_x410_dw1000. The decoded PSDU is reused bit-for-bit, including its
%   two FCS bytes, and an IEEE 802.15.4z BPRF/SFD #2 waveform is generated.
%
%   TX.waveform_work is sampled at the HRP rate (998.4 MHz).
%   TX.waveform_x410 is resampled to OPTIONS.fs_tx and frequency shifted so
%   that an X410 tuned to OPTIONS.x410_center_frequency transmits at
%   OPTIONS.qm35_center_frequency.
%
%   The MATLAB BPRF generator only permits a 64-symbol preamble. QM35 uses
%   128 symbols in the capture, so this function generates a standard
%   64-symbol frame and explicitly extends its SYNC field to 128 symbols.

defaults = struct('fs_tx', 737.28e6, ...
    'x410_center_frequency', 6500e6, ...
    'qm35_center_frequency', 6489.6e6, ...
    'preamble_repetitions', 128, 'code_index', 9, ...
    'sfd_number', 2, 'peak_amplitude', 0.8, ...
    'guard_samples', 4096, 'require_fcs_pass', true);
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

[psdu_bits, psdu_bytes, fcs_pass] = extractPsdu(decoded);
if options.require_fcs_pass && ~fcs_pass
    error('generate_qm35_tx_from_decode:FcsFailed', ...
        ['The decoded FCS did not pass. Set require_fcs_pass=false only ', ...
         'when intentionally regenerating a damaged frame.']);
end
if isempty(psdu_bits) || mod(numel(psdu_bits), 8) ~= 0
    error('generate_qm35_tx_from_decode:InvalidPsdu', ...
        'The decoded PSDU must contain a nonempty whole number of bytes.');
end

psdu_length = numel(psdu_bits)/8;
cfg = lrwpanHRPConfig(Mode='BPRF', MeanPRF=62.4, DataRate=6.81, ...
    PHRDataRate=0.85, SamplesPerPulse=2, ...
    STSPacketConfiguration=0, CodeIndex=options.code_index, ...
    PreambleDuration=64, SFDNumber=options.sfd_number, ...
    PSDULength=psdu_length);

[~, standard_pulse_symbols] = ...
    lrwpanWaveformGenerator(double(psdu_bits), cfg);
standard_indices = lrwpanHRPFieldIndices(cfg);
sync_length = standard_indices.SYNC(2)-standard_indices.SYNC(1)+1;
samples_per_sync = sync_length/cfg.PreambleDuration;
if samples_per_sync ~= round(samples_per_sync)
    error('generate_qm35_tx_from_decode:NonintegerSync', ...
        'The generated SYNC length is not an integer number of symbols.');
end
samples_per_sync = round(samples_per_sync);
symbols_per_sync = samples_per_sync/cfg.SamplesPerPulse;
if symbols_per_sync ~= round(symbols_per_sync)
    error('generate_qm35_tx_from_decode:NonintegerPulseGrid', ...
        'SYNC does not contain an integer number of pulse-grid samples.');
end
symbols_per_sync = round(symbols_per_sync);
sync_pulse_symbols = standard_pulse_symbols(1:symbols_per_sync);
standard_sfd_symbol = ...
    (standard_indices.SFD(1)-1)/cfg.SamplesPerPulse+1;

% Keep the generator-produced SFD/PHR/PSDU pulse grid, replacing only SYNC.
% The second generator output is the exact pre-pulse-shaping {-1,0,+1}
% sequence. Shaping it here also keeps the IIR state continuous across the
% custom 128-symbol preamble boundary.
pulse_symbols_work = [repmat(sync_pulse_symbols, ...
    options.preamble_repetitions, 1); ...
    standard_pulse_symbols(standard_sfd_symbol:end)];
pulse_impulses_work = zeros( ...
    numel(pulse_symbols_work)*cfg.SamplesPerPulse, 1);
pulse_impulses_work(1:cfg.SamplesPerPulse:end) = pulse_symbols_work;
[shape_b, shape_a] = butter(4, 1/cfg.SamplesPerPulse);
waveform_work = filter(shape_b, shape_a, pulse_impulses_work);
extra_sync_samples = ...
    (options.preamble_repetitions-cfg.PreambleDuration)*samples_per_sync;
field_indices = standard_indices;
field_indices.SYNC = [1, options.preamble_repetitions*samples_per_sync];
field_indices.SHR = [1, standard_indices.SHR(2)+extra_sync_samples];
field_indices.SFD = standard_indices.SFD+extra_sync_samples;
field_indices.PHR = standard_indices.PHR+extra_sync_samples;
field_indices.Payload = standard_indices.Payload+extra_sync_samples;

[p, q] = rat(options.fs_tx/cfg.SampleRate, 1e-12);
waveform_x410 = resample(waveform_work, p, q);
digital_offset_hz = ...
    options.qm35_center_frequency-options.x410_center_frequency;
n = (0:numel(waveform_x410)-1).';
waveform_x410 = waveform_x410 .* ...
    exp(1j*2*pi*digital_offset_hz*n/options.fs_tx);

peak = max(abs(waveform_x410));
if peak > 0
    waveform_x410 = waveform_x410*(options.peak_amplitude/peak);
end
if options.guard_samples > 0
    guard = complex(zeros(options.guard_samples, 1));
    waveform_x410 = [guard; waveform_x410; guard];
end

tx = struct();
tx.psdu_bits = logical(psdu_bits(:));
tx.psdu_bytes = uint8(psdu_bytes(:));
tx.fcs_pass_at_decode = logical(fcs_pass);
tx.phy_config = cfg;
tx.preamble_repetitions = options.preamble_repetitions;
tx.sfd_number = options.sfd_number;
tx.field_indices_work = field_indices;
tx.pulse_symbols_work = int8(pulse_symbols_work);
tx.pulse_impulses_work = pulse_impulses_work;
tx.pulse_shaping_b = shape_b;
tx.pulse_shaping_a = shape_a;
tx.samples_per_pulse = cfg.SamplesPerPulse;
tx.sample_rate_work = cfg.SampleRate;
tx.sample_rate_tx = options.fs_tx;
tx.digital_offset_hz = digital_offset_hz;
tx.x410_center_frequency = options.x410_center_frequency;
tx.qm35_center_frequency = options.qm35_center_frequency;
tx.waveform_work = waveform_work;
tx.waveform_x410 = waveform_x410;
tx.guard_samples = options.guard_samples;
tx.duration_s = numel(waveform_x410)/options.fs_tx;
end

function validateOptions(options)
positive_scalars = {'fs_tx', 'peak_amplitude'};
for k = 1:numel(positive_scalars)
    value = options.(positive_scalars{k});
    if ~isnumeric(value) || ~isscalar(value) || ~isfinite(value) || value <= 0
        error('generate_qm35_tx_from_decode:InvalidOption', ...
            '%s must be a positive finite scalar.', positive_scalars{k});
    end
end
integer_fields = {'preamble_repetitions', 'code_index', ...
    'sfd_number', 'guard_samples'};
for k = 1:numel(integer_fields)
    value = options.(integer_fields{k});
    if ~isnumeric(value) || ~isscalar(value) || value ~= fix(value)
        error('generate_qm35_tx_from_decode:InvalidOption', ...
            '%s must be an integer scalar.', integer_fields{k});
    end
end
if options.preamble_repetitions <= 0 || options.guard_samples < 0
    error('generate_qm35_tx_from_decode:InvalidOption', ...
        'Preamble repetitions must be positive and guard samples nonnegative.');
end
if ~ismember(options.sfd_number, 0:4)
    error('generate_qm35_tx_from_decode:InvalidOption', ...
        'sfd_number must be in the range 0..4.');
end
end

function [bits, bytes, fcs_pass] = extractPsdu(decoded)
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
fcs_pass = false;
if isfield(payload, 'bits') && ~isempty(payload.bits)
    bits = logical(payload.bits(:));
end
if isfield(payload, 'bytes') && ~isempty(payload.bytes)
    bytes = uint8(payload.bytes(:));
end
if isempty(bits) && ~isempty(bytes)
    byte_grid = repmat(bytes, 1, 8);
    bit_positions = repmat(1:8, numel(bytes), 1);
    bits = reshape(bitget(byte_grid, bit_positions).', [], 1) ~= 0;
end
if isempty(bytes) && ~isempty(bits) && mod(numel(bits), 8) == 0
    bit_matrix = reshape(uint8(bits), 8, []).';
    weights = uint16(2.^(0:7)).';
    bytes = uint8(uint16(bit_matrix)*weights);
end
if isfield(payload, 'fcs_pass')
    fcs_pass = logical(payload.fcs_pass);
end
end
