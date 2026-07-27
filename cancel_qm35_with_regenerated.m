function cancellation = cancel_qm35_with_regenerated( ...
        decode_options, channel_signal, tone_cancelled_rx, ...
        output_png, show_figure)
%CANCEL_QM35_WITH_REGENERATED Subtract rebuilt QM35 from captured IQ.
%   Cancellation is evaluated after single-tone removal and center-frequency
%   compensation, but before receiver CFO correction. Both a zero-residual-
%   CFO replica and CFO-aware replicas are tested.

if nargin < 4
    output_png = '';
end
if nargin < 5
    show_figure = true;
end
params = uwbdecoder.mergeOptions( ...
    uwbdecoder.defaultOptions(), decode_options);
reference = uwbdecoder.buildUwbReference(params);

rx_baseband = uwbdecoder.compensateCenterFrequency( ...
    tone_cancelled_rx(:), params);
rx_work = uwbdecoder.resampleCapture( ...
    rx_baseband, params.fs_rx, reference.fs);
preamble = uwbdecoder.detectRepeatedPreamble( ...
    rx_work, reference, params);
uwbdecoder.validateCaptureLength(rx_work, preamble, reference, params);
[rx_corrected, preamble_corrected] = ...
    uwbdecoder.compensateCarrierOffset( ...
    rx_work, preamble, reference, params);
preamble_corrected = uwbdecoder.refineTimingWithNsSfd( ...
    rx_corrected, preamble_corrected, reference, params);

replica = channel_signal.waveform_work(:);
[frame_start, alignment_correlation] = refineFrameStart( ...
    rx_corrected, replica, preamble_corrected.start_sample, ...
    reference.samples_per_symbol);
available = min(numel(replica), numel(rx_work)-frame_start+1);
replica = replica(1:available);
received = rx_work(frame_start:frame_start+available-1);

decoder_cfo_hz = preamble_corrected.frequency_offset_hz;
model_cfo_hz = estimateReplicaCfo(received, replica, ...
    reference.samples_per_symbol, params.preamble_repetitions, reference.fs);

no_cfo = evaluateCancellation(received, replica, 0, reference.fs);
decoder_cfo = evaluateCancellation( ...
    received, replica, decoder_cfo_hz, reference.fs);
model_cfo = evaluateCancellation( ...
    received, replica, model_cfo_hz, reference.fs);
stable_start = min(available, ...
    24*round(reference.samples_per_symbol)+1);
no_cfo.steady_state_suppression_db = stableSuppression( ...
    received, no_cfo.residual, stable_start);
decoder_cfo.steady_state_suppression_db = stableSuppression( ...
    received, decoder_cfo.residual, stable_start);
model_cfo.steady_state_suppression_db = stableSuppression( ...
    received, model_cfo.residual, stable_start);

cancellation = struct();
cancellation.sample_rate = reference.fs;
cancellation.frame_start_work_sample = frame_start;
cancellation.compared_samples = available;
cancellation.alignment_correlation_after_cfo_correction = ...
    alignment_correlation;
cancellation.decoder_cfo_hz = decoder_cfo_hz;
cancellation.replica_fitted_cfo_hz = model_cfo_hz;
cancellation.steady_state_start_sample = stable_start;
cancellation.steady_state_start_symbol = 25;
cancellation.no_cfo = no_cfo;
cancellation.decoder_cfo = decoder_cfo;
cancellation.replica_fitted_cfo = model_cfo;
cancellation.received_before_cancellation = received;

if show_figure
    visibility = 'on';
else
    visibility = 'off';
end
fig = figure('Name', 'QM35 regenerated-signal cancellation', ...
    'Color', 'w', 'Visible', visibility, 'Position', [70 70 1180 820]);

smooth_samples = max(1, round(0.25e-6*reference.fs));
env_received = movmean(abs(received), smooth_samples);
env_no_cfo = movmean(abs(no_cfo.residual), smooth_samples);
env_with_cfo = movmean(abs(model_cfo.residual), smooth_samples);
normalizer = max(env_received)+eps;
plot_step = max(1, ceil(available/6000));
idx = 1:plot_step:available;
t_us = (idx-1)/reference.fs*1e6;

subplot(2, 2, 1);
plot(t_us, env_received(idx)/normalizer, 'Color', [0.15 0.35 0.85]);
hold on;
plot(t_us, env_no_cfo(idx)/normalizer, '--', 'Color', [0.90 0.30 0.12]);
plot(t_us, env_with_cfo(idx)/normalizer, '-.', 'Color', [0.10 0.65 0.30]);
grid on;
xlabel('Time from frame start (\mus)');
ylabel('Envelope / original peak');
title('Original and cancellation residuals');
legend('Before cancellation', 'Residual: replica without CFO', ...
    'Residual: replica with fitted CFO', 'Location', 'best');

[symbol_time_us, symbol_phase, phase_fit] = preamblePhaseTrace( ...
    received, replica, reference.samples_per_symbol, ...
    params.preamble_repetitions, reference.fs);
subplot(2, 2, 2);
plot(symbol_time_us, symbol_phase, '.', 'Color', [0.15 0.35 0.85]);
hold on;
plot(symbol_time_us, phase_fit, 'r-', 'LineWidth', 1.4);
grid on;
xlabel('Preamble time (\mus)');
ylabel('Unwrapped replica/received phase (rad)');
title(sprintf('Residual phase slope: fitted CFO %+.3f kHz', ...
    model_cfo_hz/1e3));
legend('Per-symbol phase', 'Linear fit', 'Location', 'best');

nfft = 2^floor(log2(min(available, 262144)));
window = 0.5-0.5*cos(2*pi*(0:nfft-1).'/(nfft-1));
spec_original = normalizedSpectrum(received(1:nfft), window, nfft);
spec_no_cfo = normalizedSpectrum(no_cfo.residual(1:nfft), window, nfft);
spec_with_cfo = normalizedSpectrum(model_cfo.residual(1:nfft), window, nfft);
spectral_reference = max(spec_original);
spec_original = spec_original-spectral_reference;
spec_no_cfo = spec_no_cfo-spectral_reference;
spec_with_cfo = spec_with_cfo-spectral_reference;
freq_mhz = (-nfft/2:nfft/2-1).'*reference.fs/nfft/1e6;
subplot(2, 2, 3);
plot(freq_mhz, spec_original, 'Color', [0.15 0.35 0.85]);
hold on;
plot(freq_mhz, spec_no_cfo, '--', 'Color', [0.90 0.30 0.12]);
plot(freq_mhz, spec_with_cfo, '-.', 'Color', [0.10 0.65 0.30]);
grid on;
xlabel('Baseband frequency (MHz)');
ylabel('Magnitude relative to original peak (dB)');
ylim([-70 5]);
title('Residual spectra');
legend('Before cancellation', 'No CFO', 'With fitted CFO', ...
    'Location', 'best');

subplot(2, 2, 4);
axis off;
summary_text = sprintf([ ...
    'Decoder CFO estimate:       %+.3f kHz\n', ...
    'Replica-fitted CFO:         %+.3f kHz\n\n', ...
    'No-CFO cancellation:         %.2f dB\n', ...
    'Decoder-CFO cancellation:    %.2f dB\n', ...
    'Fitted-CFO cancellation:     %.2f dB\n\n', ...
    'Fitted-CFO steady state:     %.2f dB\n', ...
    '(steady state excludes first 24 SYNC symbols)\n\n', ...
    'No-CFO correlation:          %.4f\n', ...
    'Decoder-CFO correlation:     %.4f\n', ...
    'Fitted-CFO correlation:      %.4f\n\n', ...
    'Residual power ratios are measured over the full frame.'], ...
    decoder_cfo_hz/1e3, model_cfo_hz/1e3, ...
    no_cfo.suppression_db, decoder_cfo.suppression_db, ...
    model_cfo.suppression_db, model_cfo.steady_state_suppression_db, ...
    no_cfo.correlation, ...
    decoder_cfo.correlation, model_cfo.correlation);
text(0, 1, summary_text, 'VerticalAlignment', 'top', ...
    'Interpreter', 'none', 'FontName', 'Consolas', 'FontSize', 10.5);
sgtitle('Subtracting the CIR-shaped QM35 replica from captured IQ');

if ~isempty(output_png)
    exportgraphics(fig, output_png, 'Resolution', 180);
end
if ~show_figure
    close(fig);
end
end

function suppression_db = stableSuppression(received, residual, first)
idx = first:numel(received);
power_before = mean(abs(received(idx)).^2);
power_after = mean(abs(residual(idx)).^2);
suppression_db = 10*log10(power_before/(power_after+eps));
end

function result = evaluateCancellation(received, replica, cfo_hz, fs)
n = (0:numel(replica)-1).';
replica_with_cfo = replica.*exp(1j*2*pi*cfo_hz*n/fs);
gain = (replica_with_cfo'*received)/(replica_with_cfo'*replica_with_cfo+eps);
modeled = gain*replica_with_cfo;
residual = received-modeled;
power_before = mean(abs(received).^2);
power_after = mean(abs(residual).^2);
result = struct('cfo_hz', cfo_hz, 'complex_gain', gain, ...
    'correlation', abs(replica_with_cfo'*received)/ ...
        (norm(replica_with_cfo)*norm(received)+eps), ...
    'power_before', power_before, 'power_after', power_after, ...
    'suppression_db', 10*log10(power_before/(power_after+eps)), ...
    'modeled_signal', modeled, 'residual', residual);
end

function cfo_hz = estimateReplicaCfo(received, replica, ...
        samples_per_symbol, repetitions, fs)
[time_s, phase] = phaseSamples( ...
    received, replica, samples_per_symbol, repetitions, fs);
stable_start = stablePhaseStart(numel(time_s));
fit = polyfit(time_s(stable_start:end), phase(stable_start:end), 1);
cfo_hz = fit(1)/(2*pi);
end

function [time_us, phase, phase_fit] = preamblePhaseTrace( ...
        received, replica, samples_per_symbol, repetitions, fs)
[time_s, phase] = phaseSamples( ...
    received, replica, samples_per_symbol, repetitions, fs);
stable_start = stablePhaseStart(numel(time_s));
fit = polyfit(time_s(stable_start:end), phase(stable_start:end), 1);
phase_fit = polyval(fit, time_s);
time_us = time_s*1e6;
end

function [time_s, phase] = phaseSamples( ...
        received, replica, samples_per_symbol, repetitions, fs)
samples_per_symbol = round(samples_per_symbol);
repetitions = min(repetitions, ...
    floor(min(numel(received), numel(replica))/samples_per_symbol));
correlations = complex(zeros(repetitions, 1));
for k = 1:repetitions
    idx = (k-1)*samples_per_symbol+(1:samples_per_symbol);
    correlations(k) = replica(idx)'*received(idx);
end
time_s = ((0:repetitions-1).'*samples_per_symbol)/fs;
phase = unwrap(angle(correlations));
end

function start_index = stablePhaseStart(sample_count)
skip_count = min(24, max(0, sample_count-32));
start_index = skip_count+1;
end

function spectrum_db = normalizedSpectrum(signal, window, nfft)
spectrum_db = 20*log10(abs(fftshift(fft(signal.*window, nfft)))+eps);
end

function [best_start, best_correlation] = refineFrameStart( ...
        rx, replica, coarse_start, samples_per_symbol)
search_radius = 32;
template_length = min(numel(replica), round(32*samples_per_symbol));
template = replica(1:template_length);
candidate_starts = round(coarse_start)+(-search_radius:search_radius);
scores = -inf(size(candidate_starts));
for k = 1:numel(candidate_starts)
    first = candidate_starts(k);
    last = first+template_length-1;
    if first < 1 || last > numel(rx)
        continue;
    end
    segment = rx(first:last);
    scores(k) = abs(template'*segment)/(norm(template)*norm(segment)+eps);
end
[best_correlation, index] = max(scores);
best_start = candidate_starts(index);
end
