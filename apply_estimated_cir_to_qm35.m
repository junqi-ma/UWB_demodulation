function channel = apply_estimated_cir_to_qm35(tx, cir)
%APPLY_ESTIMATED_CIR_TO_QM35 Replace each UWB shaping pulse with measured CIR.
%   CHANNEL = APPLY_ESTIMATED_CIR_TO_QM35(TX, CIR) filters the unshaped
%   {-1,0,+1} pulse impulse train with the CIR. It does not convolve the
%   already Butterworth-shaped TX waveform with the CIR, avoiding
%   duplicate pulse shaping.
%
%   See also GENERATE_QM35_TX_FROM_DECODE.

if ~isstruct(tx) || ~isfield(tx, 'pulse_impulses_work') || ...
        ~isfield(tx, 'sample_rate_work')
    error('apply_estimated_cir_to_qm35:InvalidTx', ...
        ['TX must contain the unshaped pulse impulse train returned by ', ...
         'generate_qm35_tx_from_decode.']);
end
if ~isstruct(cir) || ~isfield(cir, 'values') || isempty(cir.values)
    error('apply_estimated_cir_to_qm35:InvalidCir', ...
        'CIR must contain a nonempty complex values vector.');
end

x = tx.pulse_impulses_work(:);
h = cir.values(:);
fullWaveform = conv(x, h, 'full');

if isfield(cir, 'pre_samples')
    zeroDelayIdx = round(cir.pre_samples) + 1;
elseif isfield(cir, 'delay_ns')
    [~, zeroDelayIdx] = min(abs(cir.delay_ns));
else
    zeroDelayIdx = 1;
end
first = zeroDelayIdx;
last = first + numel(x) - 1;
alignedWaveform = fullWaveform(first:last);

% Also provide the same sample-rate/frequency format as the X410 waveform.
[p, q] = rat(tx.sample_rate_tx / tx.sample_rate_work, 1e-12);
waveformX410 = resample(alignedWaveform, p, q);
n = (0:numel(waveformX410)-1).';
waveformX410 = waveformX410 .* ...
    exp(1j*2*pi*tx.digital_offset_hz*n / tx.sample_rate_tx);
if tx.guard_samples > 0
    guard = complex(zeros(tx.guard_samples, 1));
    waveformX410 = [guard; waveformX410; guard];
end

channel = struct();
channel.cir_values = h;
channel.cir_delay_ns = cir.delay_ns(:);
channel.zero_delay_index = zeroDelayIdx;
channel.pulse_impulses_work = x;
channel.replaces_shaping_pulse = true;
channel.sample_rate_work = tx.sample_rate_work;
channel.sample_rate_tx = tx.sample_rate_tx;
channel.waveform_full = fullWaveform;
channel.waveform_work = alignedWaveform;
channel.waveform_x410 = waveformX410;
channel.duration_s = numel(waveformX410) / tx.sample_rate_tx;
channel.description = ...
    ['Unshaped QM35 pulse train filtered by the decoded complex CIR; ', ...
     'the CIR replaces the default Butterworth shaping pulse'];
end
