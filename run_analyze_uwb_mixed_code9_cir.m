%% Mixed preamble code-9/code-10 capture: CIR interference analysis.
% Builds a synthetic collocated two-device capture:
%   - wanted  : QM35-style packet, preamble code 9, 128 SYNC reps,
%     3-tap multipath channel, fractional delay, phase, +2.5 kHz CFO;
%   - interferer: DW1000-style SYNC burst, preamble code 10, 256 reps,
%     2-tap channel, asynchronous start overlapping the wanted preamble,
%     own phase, -8 kHz CFO, amplitude swept over an SIR list.
% The receiver always runs the project decoder front end matched to
% preamble code 9 (detectRepeatedPreamble -> cropToFrame ->
% compensateCarrierOffset -> refineTimingWithNsSfd -> estimateCirAndSoftChips)
% and the resulting CIR is scored with analyzeCirInterference.
%
% Reported per SIR:
%   - acquisition: measured symbol period, clock ppm, which signal the
%     preamble detector locked onto (wanted code-9 vs interferer code-10);
%   - CIR energies (raw, unnormalized coherent CIR):
%       first-path power vs code-10 interference leakage, both
%       coherently (peak in the pre-first-path window) and
%       noncoherently (per-repetition residual, median + peak);
%   - full decode pass/fail (PHR SECDED + payload FCS) as a bonus.
%
% Outputs are saved to decoded_results/mixed_code9_cir/.

clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% Configuration
rng_seed = 7;
sir_list_db = [Inf, 20, 10, 5, 0, -5, -10, -20];  % SIR = wanted/interferer
snr_db = 30;                                  % AWGN level (no-interf. baseline)
wanted_cfo_hz = 2.5e3;
interf_cfo_hz = -8e3;
buffer_samples = 1.5e6;                       % work-rate capture length
wanted_start_sample = 300001;                 % code-9 packet start (1-based)
interf_offset_samples = -29333;               % code-10 start rel. wanted start
psdu_length_bytes = 20;
show_plots = true;
output_dir = fullfile(project_dir, 'decoded_results', 'mixed_code9_cir');

% Wanted code-9 channel: first path at delay 0 (fractional part separate),
% reflectors at ~60 ns and ~150 ns (1 sample ~ 1 ns at 998.4 MHz).
wanted_channel = struct( ...
    'delays_samples', [0, 60, 150], ...
    'gains', [1, 0.45*exp(1j*40*pi/180), 0.22*exp(1j*150*pi/180)]);
% Interferer code-10 channel: direct path + one reflector at ~45 ns.
interf_channel = struct( ...
    'delays_samples', [0, 45], ...
    'gains', [1, 0.5*exp(1j*70*pi/180)]);

%% Receiver configuration (QM35 profile, matched to code 9)
overrides = struct( ...
    'code_index', 9, ...
    'data_rate', 6.81, ...
    'preamble_repetitions', 128, ...
    'sfd_mode', 'auto', ...
    'cir_repetitions', 64, ...
    'cir_store_individual_values', true, ...
    'cir_diag_pre_samples', 96, ...
    'cir_diag_post_samples', 200, ...
    'show_plots', false, ...
    'verbose', false);
params = uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), overrides);
reference = uwbdecoder.buildUwbReference(params);
sfd_templates = struct( ...
    'decawave', params.decawave_sfd(:), ...
    'ieee', params.ieee_sfd(:), ...
    'sfd4z_1', params.sfd4z_1(:), ...
    'sfd4z_2', params.sfd4z_2(:), ...
    'sfd4z_3', params.sfd4z_3(:), ...
    'sfd4z_4', params.sfd4z_4(:));

%% Generate the two device signals
% Payload carries a valid 802.15.4 FCS so decode success is meaningful:
% lrwpanWaveformGenerator does not append the FCS itself.
rng(rng_seed, 'twister');
psdu_bytes = randi([0 255], psdu_length_bytes-2, 1);
fcs_bytes = double(typecast(uwbdecoder.ieee802154CRC16( ...
    uint8(psdu_bytes)), 'uint8')).';
psdu_bits = reshape(de2bi([psdu_bytes; fcs_bytes].', 8, ...
    2, 'right-msb').', [], 1);

wanted_base = generatePacket(psdu_bits, 128, 9);
interf_base = generateSyncOnly(256, 10);

wanted = applyChannel(wanted_base, wanted_channel);
interf = applyChannel(interf_base, interf_channel);
wanted = wanted*exp(1j*2*pi*rand);
interf = interf*exp(1j*2*pi*rand);
wanted_frac = 0.37;                        % sub-sample start offsets
interf_frac = 0.81;
wanted = fractionalDelay(wanted, wanted_frac);
interf = fractionalDelay(interf, interf_frac);

% Normalize both to unit average power so 'SIR' is well defined.
wanted = wanted/sqrt(mean(abs(wanted).^2));
interf = interf/sqrt(mean(abs(interf).^2));

noise_power = 10^(-snr_db/10);             % rel. unit wanted power
interf_start_sample = wanted_start_sample + interf_offset_samples;

%% Sweep SIR: build capture, run code-9 receiver, score the CIR
n_cases = numel(sir_list_db);
summary = repmat(emptySummary(), n_cases, 1);
cir_profiles = cell(n_cases, 1);
raw_snippets = cell(n_cases, 1);
raw_window = wanted_start_sample + (-2000:8000).';
for c = 1:n_cases
    sir_db = sir_list_db(c);
    if isinf(sir_db)
        rx_interf = zeros(0, 1);
    else
        rx_interf = interf*10^(-sir_db/20);
    end

    rx = buildMixedCapture(buffer_samples, wanted, wanted_start_sample, ...
        wanted_cfo_hz, rx_interf, interf_start_sample, interf_cfo_hz, ...
        noise_power, reference.fs);
    raw_snippets{c} = rx(raw_window);
    actual_sir_db = Inf;
    if ~isinf(sir_db)
        actual_sir_db = -10*log10(mean(abs(rx_interf).^2));
    end

    try
        case_result = runCase(rx, params, reference, sfd_templates, ...
            wanted_start_sample + wanted_frac, ...
            interf_start_sample + interf_frac);
        case_result.sir_db = sir_db;
        case_result.actual_sir_db = actual_sir_db;
    catch ME
        fprintf('SIR %+5.1f dB: acquisition failed (%s)\n', ...
            sir_db, ME.identifier);
        case_result = emptySummary();
        case_result.sir_db = sir_db;
        case_result.actual_sir_db = actual_sir_db;
        case_result.locked_signal = "none";
        case_result.state = "no_acquisition";
        case_result.decode_status = "n/a";
        cir_profiles{c} = [];
        summary(c) = case_result;
        continue;
    end
    summary(c) = case_result;
    cir_profiles{c} = case_result.cir_profile;
    fprintf(['SIR %+5.1f dB: lock=%s reps=%d(%d-%d) | ', ...
        'FP %6.1f dB, early-coh %6.1f dB, residual %6.1f dB, ', ...
        'occ=%.2f [%s] | decode %s\n'], ...
        sir_db, case_result.locked_signal, ...
        case_result.detected_repetitions, case_result.cir_first_rep, ...
        case_result.cir_last_rep, case_result.first_path_power_db, ...
        case_result.early_coh_peak_db, case_result.early_residual_db, ...
        case_result.interference_occupancy, case_result.state, ...
        case_result.decode_status);
end

%% Report
fprintf('\n=== First path vs code-10 interference in the code-9 CIR ===\n');
fprintf(['%-7s %-7s %-5s %-8s %-12s %-8s %-8s %-10s %-10s ', ...
    '%-7s %-12s %s\n'], 'SIR dB', 'lock', 'reps', 'ppm', 'CIR reps', ...
    'FP dB', 'coh-int', 'FP-coh sup', 'residual', 'occ', 'state', ...
    'decode');
for c = 1:n_cases
    s = summary(c);
    fprintf(['%-7s %-7s %-5d %-+8.1f %-12d %-8.1f %-8.1f %-10.1f ', ...
        '%-10.1f %-7.2f %-12s %s\n'], ...
        sprintf('%+.0f', s.sir_db), s.locked_signal, ...
        s.detected_repetitions, ...
        s.clock_error_ppm, s.cir_first_rep, s.first_path_power_db, ...
        s.early_coh_peak_db, s.first_path_coh_suppression_db, ...
        s.early_residual_db, s.interference_occupancy, s.state, ...
        s.decode_status);
end
fprintf(['\ncoh-int     = coherent code-10 leakage peak in the pre-first-path window\n']);
fprintf(['FP-coh sup  = first path power - coherent interference peak (dB)\n']);
fprintf(['residual    = median noncoherent early-window residual rel. first path (dB)\n']);
fprintf(['reps        = preamble repetitions the detector could track; a value well\n', ...
    '             below 128 means the cross-code interference broke acquisition\n']);

if ~isfolder(output_dir)
    mkdir(output_dir);
end
save(fullfile(output_dir, 'mixed_code9_cir.mat'), 'summary', ...
    'cir_profiles', 'sir_list_db', '-v7.3');
writetable(struct2table(rmfield(summary, 'cir_profile')), ...
    fullfile(output_dir, 'summary.csv'));
fprintf('Saved results to %s\n', output_dir);

%% Figures
if show_plots
    figure('Name', 'Code-9 CIR under code-10 interference', ...
        'Color', 'w', 'Position', [60 60 1200 760]);
    tiledlayout(2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
    colors = lines(n_cases);

    nexttile; hold on;
    for c = 1:n_cases
        p = cir_profiles{c};
        if isempty(p)
            continue;
        end
        plot(p.delay_ns, p.coherent_db, '-', 'Color', colors(c, :), ...
            'LineWidth', 1.1, ...
            'DisplayName', sprintf('SIR %+.0f dB', sir_list_db(c)));
    end
    grid on; xlabel('Delay (ns)'); ylabel('Coherent CIR (dB)');
    title('Coherent CIR (code-9 receiver)');
    legend('-DynamicLegend', 'Location', 'southwest');
    ylim([-60 5]);

    nexttile; hold on;
    for c = 1:n_cases
        p = cir_profiles{c};
        if isempty(p)
            continue;
        end
        plot(p.delay_ns, p.residual_db, '-', 'Color', colors(c, :), ...
            'LineWidth', 1.1, ...
            'DisplayName', sprintf('SIR %+.0f dB', sir_list_db(c)));
    end
    grid on; xlabel('Delay (ns)');
    ylabel('Noncoherent residual (dB)');
    title('Per-repetition residual (interference does not coherently average)');
    legend('-DynamicLegend', 'Location', 'southwest');
    ylim([-75 -5]);

    figure('Name', 'Raw signal before correlation', ...
        'Color', 'w');
    t_us = (raw_window - wanted_start_sample).'/reference.fs*1e6;
    hold on;
    for c = 1:n_cases
        plot(t_us, real(raw_snippets{c}), '-', ...
            'Color', [colors(c, :), 0.85], 'LineWidth', 0.9, ...
            'DisplayName', sprintf('SIR %+.0f dB', sir_list_db(c)));
    end
    grid on;
    xlabel(sprintf('Time relative to wanted start (\\mus)'));
    ylabel('I amplitude (linear)');
    title('Raw captured IQ (before any correlation)');
    legend('-DynamicLegend', 'Location', 'northeast');
    savefig(gcf, fullfile(output_dir, 'raw_signal.fig'));
    exportgraphics(gcf, fullfile(output_dir, 'raw_signal.png'));

    figure('Name', 'Coherent CIR amplitude (linear scale)', ...
        'Color', 'w');
    hold on;
    for c = 1:n_cases
        p = cir_profiles{c};
        if isempty(p)
            continue;
        end
        plot(p.delay_ns, p.coherent_amp, '-', ...
            'Color', colors(c, :), 'LineWidth', 1.1, ...
            'DisplayName', sprintf('SIR %+.0f dB', sir_list_db(c)));
    end
    grid on;
    xlabel('Delay (ns)');
    ylabel('|coherent CIR| (linear)');
    title('Coherent CIR amplitude: first path vs code-10 leakage');
    legend('-DynamicLegend', 'Location', 'northeast');
    savefig(gcf, fullfile(output_dir, 'coherent_cir_amplitude.fig'));
    exportgraphics(gcf, ...
        fullfile(output_dir, 'coherent_cir_amplitude.png'));

    figure('Name', 'First path vs interference summary', ...
        'Color', 'w');
    bar((1:n_cases) - 0.2, [summary.first_path_power_db], 0.38);
    hold on;
    bar(1:n_cases, [summary.early_coh_peak_db], 0.38);
    plot(1:n_cases, [summary.early_residual_db] + ...
        [summary.first_path_power_db], 'k--o', 'LineWidth', 1.2);
    set(gca, 'XTick', 1:n_cases, ...
        'XTickLabel', compose('%+.0f', sir_list_db));
    xlabel('SIR (dB)'); ylabel('Power (dB)');
    legend('first path (coherent)', ...
        'interference peak (coherent, early window)', ...
        'interference residual (noncoherent, early window)', ...
        'Location', 'best');
    title('First-path vs code-10 interference energy in code-9 CIR');
    grid on;
    savefig(gcf, fullfile(output_dir, 'first_path_vs_interference.fig'));
    exportgraphics(gcf, ...
        fullfile(output_dir, 'first_path_vs_interference.png'));
end

%% Local functions
function packet = generatePacket(psdu_bits, preamble_reps, code_index)
%GENERATEPACKET Full HRP packet waveform at the 998.4 MHz work rate.
% 802.15.4a BPRF only supports 16/64/1024/4096 SYNC lengths, so a 64-rep
% packet is generated and its SYNC field is tiled up to preamble_reps.
cfg = lrwpanHRPConfig(Mode='802.15.4a', MeanPRF=62.4, ...
    DataRate=6.81, PreambleDuration=64, ...
    CodeIndex=code_index, SamplesPerPulse=2, PSDULength= ...
    numel(psdu_bits)/8);
tx = lrwpanWaveformGenerator(psdu_bits, cfg);
tx = tx(:);
indices = lrwpanHRPFieldIndices(cfg);
sync = tx(indices.SYNC(1):indices.SYNC(2));
tail = tx(indices.SYNC(2)+1:end);
packet = [repmat(sync, preamble_reps/64, 1); tail];
end

function sync = generateSyncOnly(preamble_reps, code_index)
%GENERATESYNCONLY SYNC-only burst (interferer; data fields irrelevant).
cfg = lrwpanHRPConfig(Mode='802.15.4a', MeanPRF=62.4, ...
    DataRate=6.81, PreambleDuration=64, ...
    CodeIndex=code_index, SamplesPerPulse=2, PSDULength=1);
tx = lrwpanWaveformGenerator(zeros(8, 1), cfg);
indices = lrwpanHRPFieldIndices(cfg);
sync = tx(indices.SYNC(1):indices.SYNC(2));
sync = [repmat(sync(:), preamble_reps/64, 1); zeros(4096, 1)];
end

function y = applyChannel(x, channel)
%APPLYCHANNEL Sparse multipath convolution with fractional-free taps.
y = zeros(numel(x) + channel.delays_samples(end), 1);
for k = 1:numel(channel.gains)
    d = channel.delays_samples(k) + 1;
    y(d:d+numel(x)-1) = y(d:d+numel(x)-1) + channel.gains(k)*x;
end
end

function rx = buildMixedCapture(buffer_samples, wanted, wanted_start, ...
    wanted_cfo, interf, interf_start, interf_cfo, noise_power, fs)
%BUILDMIXEDCAPTURE Place both signals, apply per-signal CFO, add AWGN.
rx = complex(zeros(buffer_samples, 1));
n = (0:buffer_samples-1).';
last = wanted_start + numel(wanted) - 1;
if last > buffer_samples
    error('buildMixedCapture:TooLong', ...
        'Wanted packet exceeds the capture buffer.');
end
rx(wanted_start:last) = wanted.* ...
    exp(1j*2*pi*wanted_cfo*(wanted_start-1:n(last)).'/fs);
if ~isempty(interf)
    last_i = interf_start + numel(interf) - 1;
    if last_i > buffer_samples
        error('buildMixedCapture:TooLong', ...
            'Interferer exceeds the capture buffer.');
    end
    rx(interf_start:last_i) = rx(interf_start:last_i) + interf.* ...
        exp(1j*2*pi*interf_cfo*(interf_start-1:n(last_i)).'/fs);
end
rx = rx + sqrt(noise_power/2)*( ...
    randn(buffer_samples, 1) + 1j*randn(buffer_samples, 1));
end

function out = runCase(rx, params, reference, sfd_templates, ...
    true_wanted_start, true_interf_start)
%RUNCASE Code-9 receiver front end + CIR scoring for one capture.
preamble = uwbdecoder.detectRepeatedPreamble(rx, reference, params, []);
uwbdecoder.validateCaptureLength(rx, preamble, reference, params);
[rx_work, preamble, crop_info] = uwbdecoder.cropToFrame( ...
    rx, preamble, reference, params);
crop_start = crop_info.crop_start;
[rx_work, preamble] = uwbdecoder.compensateCarrierOffset( ...
    rx_work, preamble, reference, params);
preamble = uwbdecoder.refineTimingWithNsSfd( ...
    rx_work, preamble, reference, sfd_templates, params);
[cir, ~] = uwbdecoder.estimateCirAndSoftChips( ...
    rx_work, preamble, reference, params);

detected_start = preamble.start_sample + crop_start - 1;
[lock_name, lock_error_ns] = classifyLock( ...
    detected_start, true_wanted_start, true_interf_start, reference.fs);

% Coherent CIR from the wide diagnostic window (raw, unnormalized).
individual = cir.diag_individual_values;
delay_ns = cir.diag_delay_ns(:);
h_bar = mean(individual, 2);
coherent_power = abs(h_bar).^2;
[fp_power, fp_index] = max(coherent_power);
fp_delay = delay_ns(fp_index);

% Early window = everything before the first path minus a guard; there is
% no wanted energy there, so it isolates code-10 leakage + noise.
guard = 8;
early_last = fp_index - guard;
if early_last >= 1
    early_coherent_peak = max(coherent_power(1:early_last));
else
    early_coherent_peak = NaN;
end

% Project interference detector (per-repetition residual statistics).
diag = uwbdecoder.analyzeCirInterference(cir);

% Full decode attempt (bonus metric: does the packet survive?).
decode_status = "n/a";
try
    result = decode_uwb(params, rx);
    if isfield(result, 'payload') && isfield(result.payload, 'fcs_pass')
        if result.payload.fcs_pass
            decode_status = "ok";
        elseif isfield(result, 'phr') && ~result.phr.secded_pass
            decode_status = "phr_fail";
        else
            decode_status = "fcs_fail";
        end
    end
catch ME
    decode_status = "error:" + string(ME.identifier);
end

out = emptySummary();
out.locked_signal = lock_name;
out.lock_error_ns = lock_error_ns;
out.detected_start_sample = detected_start;
out.measured_period = preamble.measured_period;
out.detected_repetitions = preamble.detected_repetitions;
out.cir_first_rep = cir.first_repetition;
out.cir_last_rep = cir.last_repetition;
out.clock_error_ppm = preamble.clock_error_ppm;
out.first_path_power_db = toDb(fp_power);
out.first_path_delay_ns = fp_delay;
out.early_coh_peak_db = toDb(early_coherent_peak);
out.first_path_coh_suppression_db = toDb(fp_power/max(early_coherent_peak, eps));
out.early_residual_db = diag.early_residual_ratio_db;
out.early_peak_db = diag.early_peak_ratio_db;
out.interference_occupancy = diag.interference_occupancy;
out.state = string(diag.state);
out.sic_recommended = diag.sic_recommended;
out.cfo_estimated_hz = preamble.frequency_offset_hz;
out.sfd_correlation = preamble.sfd_waveform_correlation;
out.decode_status = decode_status;
out.cir_profile = struct('delay_ns', delay_ns, ...
    'coherent_db', toDb(coherent_power), ...
    'coherent_amp', abs(h_bar), ...
    'residual_db', toDb(diag.residual_power), ...
    'first_path_delay_ns', fp_delay);
end

function [lock_name, lock_error_ns] = classifyLock( ...
    detected_start, true_wanted_start, true_interf_start, fs)
%CLASSIFYLOCK Which periodic peak train did the preamble detector find?
err_wanted = abs(detected_start - true_wanted_start);
err_interf = abs(detected_start - true_interf_start);
if err_wanted <= err_interf
    lock_name = "code9";
    lock_error_ns = err_wanted/fs*1e9;
else
    lock_name = "code10";
    lock_error_ns = err_interf/fs*1e9;
end
end

function s = emptySummary()
s = struct('sir_db', NaN, 'actual_sir_db', NaN, 'locked_signal', "", ...
    'lock_error_ns', NaN, 'detected_start_sample', NaN, ...
    'measured_period', NaN, 'detected_repetitions', NaN, ...
    'cir_first_rep', NaN, 'cir_last_rep', NaN, 'clock_error_ppm', NaN, ...
    'first_path_power_db', NaN, 'first_path_delay_ns', NaN, ...
    'early_coh_peak_db', NaN, 'first_path_coh_suppression_db', NaN, ...
    'early_residual_db', NaN, 'early_peak_db', NaN, ...
    'interference_occupancy', NaN, 'state', "", 'sic_recommended', false, ...
    'cfo_estimated_hz', NaN, 'sfd_correlation', NaN, ...
    'decode_status', "", 'cir_profile', []);
end

function y = fractionalDelay(x, d)
%FRACTIONALDELAY Shift x by d samples (|d| < 1) via FFT phase ramp.
n = numel(x);
nfft = 2^nextpow2(n + 2);
X = fft(x, nfft);
ramp = exp(-1j*2*pi*d*(0:nfft-1).'/nfft);
y = ifft(X.*ramp);
y = y(1:n);
end

function db = toDb(value)
db = 10*log10(value + eps);
end
