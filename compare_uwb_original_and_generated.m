function comparison = compare_uwb_original_and_generated( ...
        decode_options, tx, output_png, show_figure, ...
        preprocessed_rx, interference, channel_simulation)
%COMPARE_QM35_ORIGINAL_AND_GENERATED Compare captured and rebuilt QM35 IQ.
%   The capture is already preprocessed on the HRP work grid; only residual
%   carrier correction and timing alignment are applied before comparison.
%   A single complex gain is fitted to expose waveform differences while
%   retaining receiver/channel distortion.

if nargin < 3
    output_png = '';
end
if nargin < 4
    show_figure = true;
end
if nargin < 5
    preprocessed_rx = [];
end
if nargin < 6
    interference = struct();
end
if nargin < 7
    channel_simulation = struct();
end

params = uwbdecoder.mergeOptions( ...
    uwbdecoder.defaultOptions(), decode_options);
addpath(params.helper_path);

if isempty(preprocessed_rx)
    raw = uwbdecoder.readIqRaw(params.file_name, params.sample_offset, ...
        params.sample_num, params.ant_num);
    rx_capture = uwbdecoder.selectIqChannel(raw, params.channel_index);
    interference = struct('enabled', false, 'frequency_hz', NaN, ...
        'coefficient', complex(0), 'suppression_db', NaN, ...
        'source', 'preprocessed input');
else
    rx_capture = preprocessed_rx(:);
end
reference = uwbdecoder.buildUwbReference(params);
if abs(params.fs_rx - reference.fs) > 1
    error('compare_uwb_original_and_generated:SampleRateMismatch', ...
        'Preprocessed input must use the HRP work rate.');
end
rx_work = rx_capture;
preamble = uwbdecoder.detectRepeatedPreamble( ...
    rx_work, reference, params);
uwbdecoder.validateCaptureLength(rx_work, preamble, reference, params);
[rx_corrected, preamble] = uwbdecoder.compensateCarrierOffset( ...
    rx_work, preamble, reference, params);
preamble = uwbdecoder.refineTimingWithNsSfd( ...
    rx_corrected, preamble, reference, params);

generated = tx.waveform_work(:);
[frame_start, timing_correlation] = refineFrameStart( ...
    rx_corrected, generated, preamble.start_sample, ...
    reference.samples_per_symbol);
available = min(numel(generated), numel(rx_corrected)-frame_start+1);
if available < 0.95*numel(generated)
    error('compare_uwb_original_and_generated:ShortCapture', ...
        'Only %d of %d generated samples are present in the capture.', ...
        max(available, 0), numel(generated));
end
generated = generated(1:available);
received = rx_corrected(frame_start:frame_start+available-1);
has_channel_simulation = isstruct(channel_simulation) && ...
    isfield(channel_simulation, 'waveform_work') && ...
    numel(channel_simulation.waveform_work) >= available;
if has_channel_simulation
    generated_after_cir = channel_simulation.waveform_work(1:available);
    generated_after_cir = generated_after_cir(:);
else
    generated_after_cir = generated;
end

complex_gain = (generated'*received)/(generated'*generated+eps);
modeled = complex_gain*generated;
waveform_correlation = abs(generated'*received)/ ...
    (norm(generated)*norm(received)+eps);
nmse = norm(received-modeled)^2/(norm(received)^2+eps);
received_gain_corrected = received/(complex_gain+eps);
cir_complex_gain = (generated_after_cir'*received)/ ...
    (generated_after_cir'*generated_after_cir+eps);
cir_modeled = cir_complex_gain*generated_after_cir;
cir_waveform_correlation = abs(generated_after_cir'*received)/ ...
    (norm(generated_after_cir)*norm(received)+eps);
cir_nmse = norm(received-cir_modeled)^2/(norm(received)^2+eps);
generated_after_cir_plot = cir_modeled/(complex_gain+eps);

comparison = struct();
comparison.capture_file = params.file_name;
comparison.frame_start_work_sample = frame_start;
comparison.sample_rate = reference.fs;
comparison.compared_samples = available;
comparison.timing_correlation = timing_correlation;
comparison.waveform_correlation = waveform_correlation;
comparison.nmse = nmse;
comparison.nmse_db = 10*log10(nmse+eps);
comparison.fitted_complex_gain = complex_gain;
comparison.fitted_gain_db = 20*log10(abs(complex_gain)+eps);
comparison.fitted_phase_deg = rad2deg(angle(complex_gain));
comparison.cir_waveform_correlation = cir_waveform_correlation;
comparison.cir_nmse = cir_nmse;
comparison.cir_nmse_db = 10*log10(cir_nmse+eps);
comparison.cir_fitted_complex_gain = cir_complex_gain;
comparison.cir_fitted_gain_db = 20*log10(abs(cir_complex_gain)+eps);
comparison.cir_fitted_phase_deg = rad2deg(angle(cir_complex_gain));
comparison.input_is_preprocessed = true;
comparison.interference = interference;

if show_figure
    visibility = 'on';
else
    visibility = 'off';
end
fig = figure('Name', 'QM35 original vs regenerated', ...
    'Color', 'w', 'Visible', visibility, 'Position', [80 80 1180 820]);

% Full-frame envelopes, smoothed to expose field-level agreement.
smooth_samples = max(1, round(0.25e-6*reference.fs));
env_rx = movmean(abs(received_gain_corrected), smooth_samples);
env_tx = movmean(abs(generated), smooth_samples);
env_cir = movmean(abs(generated_after_cir_plot), smooth_samples);
env_rx = env_rx/(max(env_rx)+eps);
env_tx = env_tx/(max(env_tx)+eps);
env_cir = env_cir/(max(env_cir)+eps);
plot_step = max(1, ceil(available/6000));
idx = 1:plot_step:available;
t_us = (idx-1)/reference.fs*1e6;

subplot(2, 2, 1);
plot(t_us, env_rx(idx), 'Color', [0.10 0.45 0.85], 'LineWidth', 1.0);
hold on;
plot(t_us, env_tx(idx), '--', 'Color', [0.90 0.30 0.12], ...
    'LineWidth', 1.1);
plot(t_us, env_cir(idx), '-.', 'Color', [0.10 0.65 0.30], ...
    'LineWidth', 1.1);
grid on;
xlabel('Time from frame start (\mus)');
ylabel('Normalized envelope');
title('Full-frame envelope');
legend('Captured (preprocessed + corrected)', ...
    'Regenerated (ideal)', 'Pulse train shaped by estimated CIR', ...
    'Location', 'best');

% Zoom around SFD and the beginning of PHR.
detail_start = max(1, tx.field_indices_work.SFD(1)-2*reference.samples_per_symbol);
detail_end = min(available, tx.field_indices_work.PHR(1)+6000);
detail_idx = detail_start:detail_end;
detail_t_us = (detail_idx-tx.field_indices_work.SFD(1))/reference.fs*1e6;
subplot(2, 2, 2);
plot(detail_t_us, real(received_gain_corrected(detail_idx)), ...
    'Color', [0.10 0.45 0.85]);
hold on;
plot(detail_t_us, real(generated(detail_idx)), '--', ...
    'Color', [0.90 0.30 0.12]);
plot(detail_t_us, real(generated_after_cir_plot(detail_idx)), '-.', ...
    'Color', [0.10 0.65 0.30]);
xline(0, ':k', 'SFD start');
xline((tx.field_indices_work.PHR(1)-tx.field_indices_work.SFD(1))/ ...
    reference.fs*1e6, ':k', 'PHR start');
grid on;
xlabel('Time relative to SFD start (\mus)');
ylabel('In-phase amplitude');
title('SFD / PHR waveform detail');
legend('Captured (preprocessed + gain corrected)', ...
    'Regenerated (ideal)', 'Pulse train shaped by estimated CIR', ...
    'Location', 'best');

% Normalized spectra over the aligned frame.
nfft_limit = min(available, 262144);
nfft = 2^floor(log2(nfft_limit));
spec_rx_signal = received(1:nfft);
spec_tx_signal = generated(1:nfft);
spec_cir_signal = generated_after_cir(1:nfft);
window = 0.5-0.5*cos(2*pi*(0:nfft-1).'/(nfft-1));
spec_rx = fftshift(fft(spec_rx_signal.*window, nfft));
spec_tx = fftshift(fft(spec_tx_signal.*window, nfft));
spec_cir = fftshift(fft(spec_cir_signal.*window, nfft));
spec_rx_db = 20*log10(abs(spec_rx)+eps);
spec_tx_db = 20*log10(abs(spec_tx)+eps);
spec_cir_db = 20*log10(abs(spec_cir)+eps);
spec_rx_db = spec_rx_db-max(spec_rx_db);
spec_tx_db = spec_tx_db-max(spec_tx_db);
spec_cir_db = spec_cir_db-max(spec_cir_db);
freq_mhz = (-nfft/2:nfft/2-1).'*reference.fs/nfft/1e6;
subplot(2, 2, 3);
plot(freq_mhz, spec_rx_db, 'Color', [0.10 0.45 0.85]);
hold on;
plot(freq_mhz, spec_tx_db, '--', 'Color', [0.90 0.30 0.12]);
plot(freq_mhz, spec_cir_db, '-.', 'Color', [0.10 0.65 0.30]);
grid on;
xlabel('Baseband frequency (MHz)');
ylabel('Normalized magnitude (dB)');
ylim([-60 5]);
title('Aligned-frame spectrum');
legend('Captured (preprocessed + corrected)', ...
    'Regenerated (ideal)', 'Pulse train shaped by estimated CIR', ...
    'Location', 'best');

subplot(2, 2, 4);
axis off;
summary_text = sprintf([ ...
    'Capture: %s\n\n', ...
    'Timing correlation:       %.4f\n', ...
    'Whole-frame correlation:  %.4f\n', ...
    'NMSE:                     %.2f dB\n', ...
    'CIR-pulse correlation:    %.4f\n', ...
    'CIR-pulse NMSE:           %.2f dB\n', ...
    'Fitted channel gain:      %.2f dB\n', ...
    'Fitted channel phase:     %.2f deg\n', ...
    'Compared samples:         %d\n', ...
    'Sample rate:              %.2f MHz\n', ...
    'Input preprocessing:      already complete\n\n', ...
    'Note: residual differences include the physical\n', ...
    'channel, receiver filtering, noise, and multipath.'], ...
    params.file_name, timing_correlation, waveform_correlation, ...
    comparison.nmse_db, cir_waveform_correlation, ...
    comparison.cir_nmse_db, comparison.fitted_gain_db, ...
    comparison.fitted_phase_deg, available, reference.fs/1e6);
text(0, 1, summary_text, 'VerticalAlignment', 'top', ...
    'Interpreter', 'none', 'FontName', 'Consolas', 'FontSize', 10.5);

sgtitle('QM35 captured signal vs regenerated signal');
if ~isempty(output_png)
    exportgraphics(fig, output_png, 'Resolution', 160);
end
if ~show_figure
    close(fig);
end
end

function [best_start, best_correlation] = refineFrameStart( ...
        rx, generated, coarse_start, samples_per_symbol)
search_radius = 32;
template_length = min(numel(generated), round(32*samples_per_symbol));
template = generated(1:template_length);
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
