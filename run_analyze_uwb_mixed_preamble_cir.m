%% Analyze the channel estimate for a mixed code-9 + code-10 UWB preamble.
% Combines a wanted code (default 9, "QM35") SYNC burst with an interferer
% code (default 10, "DW1000") SYNC burst on the same 998.4 MHz grid, then
% runs the *real* decoder CIR path (+uwbdecoder/estimateCir) using the
% wanted code's reference. This shows how much of the foreign preamble leaks
% into the code-9 channel estimate, sweepable over the interferer-to-wanted
% energy ratio (dB), a fractional timing offset, phase, and CFO.
%
% The burst is several identical SYNC symbols, and estimateCir folds only
% the interior ones. That restores the Ipatov *periodic* autocorrelation
% (a single pulse-shaped peak for the wanted code). A one-symbol burst
% would instead show aperiodic self-sidelobes at ~-22 dB that look like
% leakage but are not.
%
% Each SIR panel overlays three unnormalized CIRs, all divided by the
% wanted-only first-path peak so the wanted path sits at 0 dB / unity:
%   - wanted-only: residual self-response (should be a single mainlobe)
%   - interferer-only x SIR gain: true cross-code leakage
%   - mixed = wanted + scaled interferer
%
% No capture files are required: the burst is synthesized from lrwpan
% references exactly like run_analyze_uwb_preamble_code_interference.m.
%
% Run:  matlab -batch run_analyze_uwb_mixed_preamble_cir

clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% Configuration
channel_number = 5;                 % UWB channel (validating the PRF choice)
want_code      = 9;                 % wanted / receiver preamble code (Q35)
intf_code      = 15;                % interferer preamble code (DW1000)
prf_candidates = 62.4;              % mean PRF tried per code (first valid wins)
% Need >= 3 symbols so the folded interior symbols have a neighbor on both
% sides and Ipatov periodic autocorrelation applies. First and last symbols
% are synthesized only as wrap-around guards and are not folded.
preamble_repetitions = 8;           % SYNC symbols synthesized (guards + fold)
cir_pre_samples  = 200;             % tap window start = fp-200
cir_post_samples = 201;             % tap window end   = fp+200 (offsets run pre:post-1)
first_peak_window_ns = 5;           % CIR plots: first-peak search half-width (ns)
pulse_guard_ns = 12;                % exclude wanted pulse mainlobe from residual
cir_plot_db = true;                 % CIR figure: true = dB rel. first peak, false = linear
sir_db_sweep    = [-200, 0, 12];     % interferer / wanted energy ratio (dB)
frac_delay      = 0;                % fractional-sample interferer timing offset
phase_deg       = 0;               % interferer carrier phase relative to wanted
cfo_hz          = 13e3;            % interferer carrier offset (relative) [Hz]
rng_seed        = 42;
output_dir = fullfile(project_dir, 'decoded_results', ...
    'mixed_preamble_cir');
if ~isfolder(output_dir)
    mkdir(output_dir);
end

if preamble_repetitions < 3
    error('run_analyze_uwb_mixed_preamble_cir:NeedPeriodicWrap', ...
        ['preamble_repetitions must be >= 3 so interior SYNC symbols ', ...
         'have neighbors and Ipatov periodic autocorrelation applies.']);
end
cir_skip_initial_repetitions = 1;
cir_repetitions = preamble_repetitions - 2;   % drop first and last

%% Build the wanted-code reference via the real decoder builder.
fprintf('Building wanted reference (code %d)...\n', want_code);
wantedParams = uwbdecoder.defaultOptions();
wantedParams.code_index = want_code;
wantedParams.preamble_repetitions = preamble_repetitions;
wantedParams.cir_repetitions = cir_repetitions;
wantedParams.cir_skip_initial_repetitions = cir_skip_initial_repetitions;
wantedParams.cir_pre_samples = cir_pre_samples;
wantedParams.cir_post_samples = cir_post_samples;
wantedParams.cir_store_individual_values = true;   % keep per-SYNC CIRs
wantedParams.show_plots = false;                   % avoid auto plot in builder
reference = uwbdecoder.buildUwbReference(wantedParams);
fs = reference.fs;

% Interferer reference: one symbol is enough; use the local builder from
% the interference-analyzer script (handles 15.6 PRF codes too).
fprintf('Building interferer reference (code %d)...\n', intf_code);
intf = buildCodeReference(intf_code, prf_candidates, channel_number);
if isempty(intf)
    error('run_analyze_uwb_mixed_preamble_cir:BadCode', ...
        'Code %d not realizable on channel %d.', intf_code, channel_number);
end
if intf.fs ~= fs
    error('run_analyze_uwb_mixed_preamble_cir:SampleRateMismatch', ...
        'Wanted and interferer references have different sample rates.');
end

%% Synthesize the mixed SYNC burst once, then scale per SIR.
% Wanted burst: preamble_repetitions symbols of code `want_code`, aligned on
% its own symbol grid (integer sample indices). Interferer burst: the same
% number of symbols, placed at a random whole-sample offset within the CIR
% tap window, plus a fractional-sample delay, common phase, and linear CFO.
rng(rng_seed, 'twister');

want_len = reference.samples_per_symbol;            % = numel(reference.sampled_code)
want_burst = zeros(preamble_repetitions * want_len, 1);
for k = 0:preamble_repetitions - 1
    seg = k * want_len + (1:want_len);
    want_burst(seg) = reference.preamble_waveform;
end

intf_len = intf.samples_per_symbol;
% Keep the interferer inside the CIR tap window around the wanted first
% path, otherwise its cross-code leakage can fall outside the estimate.
intf_grid_offset = randi([0, min(want_len - 1, cir_post_samples)]);
if frac_delay == 0
    w0 = intf.preamble_waveform * exp(1j * deg2rad(phase_deg));
else
    w0 = fractionalDelay(intf.preamble_waveform, frac_delay) * ...
        exp(1j * deg2rad(phase_deg));
end
intf_burst = zeros(preamble_repetitions * intf_len + intf_len, 1);
for k = 0:preamble_repetitions - 1
    first = intf_grid_offset + k * intf_len + 1;
    idx = first:first + numel(w0) - 1;
    intf_burst(idx) = intf_burst(idx) + w0;
end
if cfo_hz ~= 0
    n = (0:numel(intf_burst) - 1).';
    intf_burst = intf_burst .* exp(1j * 2 * pi * cfo_hz * n / fs);
end

% Leading pad covers the first-path pre-window; the extra synthesized
% symbols cover wrap-around so interior folds see a periodic SYNC.
pad_samples = cir_pre_samples;
n_total = pad_samples + preamble_repetitions * want_len + cir_post_samples;
want_burst = [zeros(pad_samples, 1); want_burst];
intf_burst = [zeros(pad_samples, 1); intf_burst];
if numel(want_burst) < n_total
    want_burst(n_total) = 0;
end
if numel(intf_burst) < n_total
    intf_burst(n_total) = 0;
end
want_burst = want_burst(1:n_total);
intf_burst = intf_burst(1:n_total);

% Keep the two pre-sum waveforms (wanted is unit-energy per symbol;
% interferer is already phase/CFO-rotated but NOT yet scaled by SIR).
pre_want = want_burst;
pre_intf = intf_burst;
t_burst_ns = (0:numel(want_burst) - 1).' / fs * 1e9;   % shared sample-time axis

% Preamble struct consumed by estimateCir (field names must match).
preamble = struct('start_sample', 1 + pad_samples, ...
    'measured_period', double(want_len), ...
    'detected_repetitions', preamble_repetitions, ...
    'search_half_width', 8);

%% Run estimateCir: wanted-only, interferer-only, then mixed at each SIR.
fprintf('\n=== estimateCir on mixed wanted=%d + interferer=%d ===\n', ...
    want_code, intf_code);
fprintf(['Repetitions=%d (fold interior %d, skip first %d), ', ...
    'frac delay=%.2f+%d samples, phase=%.1f'], ...
    preamble_repetitions, cir_repetitions, cir_skip_initial_repetitions, ...
    frac_delay, intf_grid_offset, phase_deg);
fprintf('deg, CFO=%.0f Hz\n', cfo_hz);

cirWant = uwbdecoder.estimateCir(want_burst, preamble, reference, wantedParams);
cirIntf = uwbdecoder.estimateCir(intf_burst, preamble, reference, wantedParams);
wantRaw = cirWant.values_raw;
intfRaw = cirIntf.values_raw;
delayNs = cirWant.delay_ns;
wantFp = firstPeakMagnitude(abs(wantRaw), delayNs, first_peak_window_ns);
offPeak = abs(delayNs) > pulse_guard_ns;
wantResidual = max(abs(wantRaw(offPeak)), [], 'omitnan');
intfPeak = max(abs(intfRaw), [], 'omitnan');
intfPeakDelay = delayNs(find(abs(intfRaw) == intfPeak, 1));
fprintf(['Wanted-only residual outside +/-%.0f ns: %.1f dB rel. first path\n', ...
    'Interferer-only peak: %.1f dB rel. wanted first path at %+.1f ns ', ...
    '(unit SIR)\n'], ...
    pulse_guard_ns, 20*log10((wantResidual + eps) / wantFp), ...
    20*log10((intfPeak + eps) / wantFp), intfPeakDelay);

results = struct([]);
for s = 1:numel(sir_db_sweep)
    sir_db = sir_db_sweep(s);
    gain_intf = 10^(sir_db / 20);   % voltage gain relative to unit wanted
    rx = want_burst + gain_intf * intf_burst;
    cir = uwbdecoder.estimateCir(rx, preamble, reference, wantedParams);

    results(s).sir_db = sir_db; %#ok<*SAGROW>
    results(s).gain_intf = gain_intf;
    results(s).cir = cir;
    results(s).rx = rx;                 % pre-correlation mixed signal
    results(s).t_ns = (0:numel(rx)-1).' / fs * 1e9;   % absolute sample time
    results(s).delay_ns = cir.delay_ns;
    results(s).values = cir.values;
    results(s).values_raw = cir.values_raw;
    results(s).want_raw = wantRaw;
    results(s).intf_raw_scaled = gain_intf * intfRaw;
    results(s).has_diag = isfield(cir, 'diag_values') && ~isempty(cir.diag_values);
    if results(s).has_diag
        results(s).diag_delay_ns = cir.diag_delay_ns;
        results(s).diag_values = cir.diag_values;
        results(s).diag_individual = cir.diag_individual_values;
    end

    leakMag = max(abs(results(s).intf_raw_scaled), [], 'omitnan');
    mixedOff = max(abs(cir.values_raw(offPeak)), [], 'omitnan');
    fprintf('\n--- SIR = %+d dB (interferer/wanted) ---\n', sir_db);
    fprintf('  CIR window taps: %d | first-rep=%d last-rep=%d count=%d\n', ...
        numel(cir.values), cir.first_repetition, cir.last_repetition, ...
        cir.repetition_count);
    fprintf('  leakage peak = %.1f dB rel. wanted first path\n', ...
        20*log10((leakMag + eps) / wantFp));
    fprintf('  mixed off-peak = %.1f dB rel. wanted first path\n', ...
        20*log10((mixedOff + eps) / wantFp));
end

%% Figures

% --- Pre-sum waveforms: wanted (code 9) vs interferer (code 10) ---
figure('Name', sprintf('Pre-sum waveforms (wanted code %d vs interferer code %d)', ...
    want_code, intf_code), 'Color', 'w');
subplot(2, 1, 1);
plot(t_burst_ns, real(pre_want), 'Color', [0.30 0.55 0.90], 'LineWidth', 0.6);
hold on;
plot(t_burst_ns, imag(pre_want), ':', 'Color', [0.85 0.33 0.10], 'LineWidth', 0.6);
grid on;
ylabel('Amplitude');
title(sprintf('Wanted signal (code %d), before summation', want_code));
legend({'I (real)', 'Q (imag)'}, 'Location', 'best');

subplot(2, 1, 2);
plot(t_burst_ns, real(pre_intf), 'Color', [0.60 0.30 0.75], 'LineWidth', 0.6);
hold on;
plot(t_burst_ns, imag(pre_intf), ':', 'Color', [0.85 0.33 0.10], 'LineWidth', 0.6);
grid on;
xlabel('Time (ns)');
ylabel('Amplitude');
title(sprintf('Interferer signal (code %d), before summation', intf_code));
legend({'I (real)', 'Q (imag)'}, 'Location', 'best');
savefig(gcf, fullfile(output_dir, sprintf('pre_sum_w%d_i%d.fig', ...
    want_code, intf_code)));
exportgraphics(gcf, fullfile(output_dir, sprintf('pre_sum_w%d_i%d.png', ...
    want_code, intf_code)));

% --- Raw (pre-correlation) mixed signal ---
figure('Name', sprintf('Raw mixed signal (code %d + code %d, pre-correlation)', ...
    want_code, intf_code), 'Color', 'w');
for s = 1:numel(results)
    subplot(numel(results), 1, s);
    rx = results(s).rx;
    t  = results(s).t_ns;
    plot(t, real(rx), 'Color', [0.30 0.55 0.90], 'LineWidth', 0.6);
    hold on;
    plot(t, imag(rx), ':', 'Color', [0.85 0.33 0.10], 'LineWidth', 0.6);
    grid on;
    xlabel('Time (ns)');
    ylabel('Amplitude');
    title(sprintf('Raw mixed signal, SIR = %+d dB', results(s).sir_db));
    if s == 1
        legend({'I (real)', 'Q (imag)'}, 'Location', 'best');
    end
end
savefig(gcf, fullfile(output_dir, sprintf('mixed_raw_signal_w%d_i%d.fig', ...
    want_code, intf_code)));
exportgraphics(gcf, fullfile(output_dir, sprintf('mixed_raw_signal_w%d_i%d.png', ...
    want_code, intf_code)));

% --- CIR: wanted-only vs interferer leakage vs mixed ---
figCir = figure('Name', 'Mixed-preamble CIR (code 9 receiver, code 10 interferer)', ...
    'Color', 'w');
tiledlayout(numel(results), 1, 'TileSpacing', 'compact');

for s = 1:numel(results)
    nexttile;
    sir_db = results(s).sir_db;
    d = results(s).delay_ns;

    % Same wanted-first-path scale on every curve / every SIR panel, so
    % leakage amplitude tracks the configured SIR instead of being
    % renormalized away when the interferer dominates.
    wantMag = abs(results(s).want_raw) / wantFp;
    leakMag = abs(results(s).intf_raw_scaled) / wantFp;
    mixMag  = abs(results(s).values_raw) / wantFp;
    if cir_plot_db
        wantY = 10 * log10(max(wantMag.^2, 1e-8));
        leakY = 10 * log10(max(leakMag.^2, 1e-8));
        mixY  = 10 * log10(max(mixMag.^2, 1e-8));
        yUnit = ' (dB)';
        peakLine = 0;
    else
        wantY = wantMag;
        leakY = leakMag;
        mixY  = mixMag;
        yUnit = '';
        peakLine = 1;
    end
    plot(d, wantY, 'Color', [0.30 0.55 0.90], 'LineWidth', 1.1);
    hold on;
    plot(d, leakY, 'Color', [0.60 0.30 0.75], 'LineWidth', 1.2);
    plot(d, mixY, 'Color', [0.85 0.33 0.10], 'LineWidth', 1.0);
    yline(peakLine, '--', [0.5 0.5 0.5]);
    grid on;
    xlabel('Delay (ns)');
    ylabel(['|CIR|^2 rel. wanted first path', yUnit]);
    title(sprintf('SIR = %+d dB', sir_db));

    if s == 1
        legend({sprintf('wanted-only (code %d)', want_code), ...
            sprintf('interferer-only (code %d) x SIR', intf_code), ...
            'mixed'}, 'Location', 'best');
    end
end
savefig(figCir, fullfile(output_dir, sprintf('mixed_cir_w%d_i%d.fig', ...
    want_code, intf_code)));
exportgraphics(figCir, fullfile(output_dir, sprintf('mixed_cir_w%d_i%d.png', ...
    want_code, intf_code)));

% --- Periodic preamble-code correlation (matches the multi-symbol CIR) ---
figure('Name', sprintf('Preamble code correlation (code %d auto, code %d x %d)', ...
    want_code, want_code, intf_code), 'Color', 'w');
codeA = double(lrwpan.internal.HRPCodes(want_code));
codeB = double(lrwpan.internal.HRPCodes(intf_code));
codeA = codeA(:);
codeB = codeB(:);
nChip = max(numel(codeA), numel(codeB));
energyA = codeA' * codeA;
energyB = codeB' * codeB;
perAuto = fftshift(ifft(abs(fft(codeA, nChip)).^2));
perAuto = perAuto / (energyA + eps);
perCross = fftshift(ifft(fft(codeA, nChip) .* conj(fft(codeB, nChip))));
perCross = perCross / (sqrt(energyA * energyB) + eps);
lagChip = -floor(nChip / 2):(ceil(nChip / 2) - 1);
autoDb = 10 * log10(max(abs(perAuto).^2, 1e-12));
crossDb = 10 * log10(max(abs(perCross).^2, 1e-12));
plot(lagChip, autoDb, 'Color', [0.30 0.55 0.90], 'LineWidth', 1.2);
hold on;
plot(lagChip, crossDb, 'Color', [0.85 0.33 0.10], 'LineWidth', 1.2);
chipsPerSymbol = numel(codeA);
samplesPerChip = reference.samples_per_symbol / chipsPerSymbol;
cirHalfChips = cir_pre_samples / samplesPerChip;
xline(-cirHalfChips, 'k--', 'HandleVisibility', 'off');
xline(cirHalfChips, 'k--', 'HandleVisibility', 'off');
grid on;
xlabel('Chip lag');
ylabel('Periodic correlation power (dB)');
title(sprintf(['Periodic preamble-code correlation (62.4 MHz PRF): ', ...
    'code %d autocorr vs code %d x code %d'], want_code, want_code, intf_code));
legend({sprintf('code %d periodic autocorrelation', want_code), ...
    sprintf('code %d x code %d periodic cross-correlation', want_code, intf_code)}, ...
    'Location', 'south');
savefig(gcf, fullfile(output_dir, sprintf('code_corr_w%d_i%d.fig', ...
    want_code, intf_code)));
exportgraphics(gcf, fullfile(output_dir, sprintf('code_corr_w%d_i%d.png', ...
    want_code, intf_code)));

% --- Time-reversed preamble: correlation with the normal code-9 preamble ---
% IEEE 802.15.4a reversal pairs: flipud(code 9) == code 17 exactly, etc.
codeA = lrwpan.internal.HRPCodes(want_code);
revCodeIdx = [];
for k = 1:32
    try
        ck = lrwpan.internal.HRPCodes(k);
    catch
        continue;
    end
    if isequal(flipud(codeA(:)), ck(:))
        revCodeIdx = k;
        break;
    end
end
revCode = flipud(codeA(:));
rAuto = xcorr(codeA);
rRev = xcorr(codeA(:), revCode);
r0 = rAuto(numel(codeA));
lagsC = -(numel(codeA) - 1):(numel(codeA) - 1);
autoDb = 10 * log10(abs(rAuto).^2 / r0^2 + eps);
revDb = 10 * log10(abs(rRev).^2 / r0^2 + eps);
[revPeakDb, revPeakLagChip] = max(revDb);
revPeakLagChip = lagsC(revPeakLagChip);

wSym = reference.preamble_waveform(:);
L = numel(wSym);
reps = 3;
burst = repmat(wSym, reps, 1);
burstRev = repmat(flipud(wSym), reps, 1);
yN = conv(burst, flipud(conj(wSym)));
yR = conv(burstRev, flipud(conj(wSym)));
lagW = -(L - 1):(numel(burst) - 1);
yNdb = 10 * log10(abs(yN).^2 / (wSym' * wSym)^2 + eps);
yRdb = 10 * log10(abs(yR).^2 / (wSym' * wSym)^2 + eps);
revAt0Db = yRdb(lagW == 0);

fprintf('\nTime-reversal analysis (code %d):\n', want_code);
if ~isempty(revCodeIdx)
    fprintf('  flipud(code %d) == IEEE code %d (exact reversal pair)\n', ...
        want_code, revCodeIdx);
end
fprintf(['  chip-level max corr with reversed code: %+.1f dB power at ', ...
    'chip lag %+d\n'], revPeakDb, revPeakLagChip);
fprintf('  matched filter at lag 0: %+.1f dB (normal peak is 0 dB)\n', revAt0Db);

figure('Name', sprintf('Time-reversed preamble vs normal preamble (code %d)', ...
    want_code), 'Color', 'w');
tiledlayout(2, 1, 'TileSpacing', 'compact');
nexttile;
hold on;
plot(lagsC, autoDb, 'Color', [0.30 0.55 0.90], 'LineWidth', 1.2);
plot(lagsC, revDb, 'Color', [0.85 0.33 0.10], 'LineWidth', 1.2);
yline(-40, 'k:', 'HandleVisibility', 'off');
grid on;
xlabel('Chip lag');
ylabel('Correlation power (dB)');
if ~isempty(revCodeIdx)
    title(sprintf(['Chip level: code %d autocorr vs code %d x reversed ', ...
        'code %d (= IEEE code %d)'], want_code, want_code, want_code, revCodeIdx));
else
    title(sprintf(['Chip level: code %d autocorr vs code %d x reversed ', ...
        'code %d'], want_code, want_code, want_code));
end
legend({sprintf('code %d autocorrelation', want_code), ...
    sprintf('code %d x reversed code %d', want_code, want_code)}, ...
    'Location', 'best');

nexttile;
hold on;
plot(lagW, yNdb, 'Color', [0.30 0.55 0.90], 'LineWidth', 1.0);
plot(lagW, yRdb, 'Color', [0.85 0.33 0.10], 'LineWidth', 1.0);
for k = 0:reps
    xline(k * L, 'k:', 'HandleVisibility', 'off');
end
grid on;
xlim([-L, (reps + 1) * L]);
ylim([-70 5]);
xlabel('Lag (samples; vertical lines = symbol boundaries k*T, T=1016)');
ylabel('Matched-filter output (dB)');
title('Waveform level: 3-symbol preamble through code-9 matched filter');
legend({'normal preamble', 'time-reversed preamble'}, 'Location', 'best');
savefig(gcf, fullfile(output_dir, sprintf('reversed_preamble_w%d.fig', ...
    want_code)));
exportgraphics(gcf, fullfile(output_dir, sprintf('reversed_preamble_w%d.png', ...
    want_code)));

%% Save
save(fullfile(output_dir, sprintf('mixed_cir_w%d_i%d.mat', ...
    want_code, intf_code)), 'results', 'reference', 'intf', 'preamble', ...
    'cirWant', 'cirIntf', 'sir_db_sweep', 'frac_delay', 'phase_deg', 'cfo_hz', ...
    'pre_want', 'pre_intf', 't_burst_ns', 'wantFp', '-v7.3');
fprintf('\nSaved mixed-CIR results and figures to %s\n', output_dir);

%% Local functions (shared with the interference-analyzer script)
function ref = buildCodeReference(code_index, prf_candidates, channel_number)
% One-symbol HRP reference for a given preamble code (mirrors the analyzer).
ref = [];
for prf = prf_candidates
    try
        cfg = lrwpanHRPConfig(Mode='802.15.4a', MeanPRF=prf, ...
            DataRate=6.81, PreambleDuration=64, ...
            CodeIndex=code_index, SamplesPerPulse=2, PSDULength=1, ...
            Channel=channel_number);
        tx = lrwpanWaveformGenerator(zeros(8, 1), cfg);
    catch
        continue;  % code/PRF/channel combination not realizable
    end
    indices = lrwpanHRPFieldIndices(cfg);
    samplesPerSymbol = indices.SYNC(end) / cfg.PreambleDuration;
    preambleWaveform = tx(1:samplesPerSymbol);
    preambleWaveform = preambleWaveform(:) / (norm(preambleWaveform) + eps);
    ref = struct('code_index', code_index, 'mean_prf', prf, ...
        'fs', cfg.SampleRate, 'samples_per_symbol', samplesPerSymbol, ...
        'preamble_waveform', preambleWaveform);
    return;
end
end

function y = fractionalDelay(x, d)
% Fractional shift of x by d samples (|d| < 1) via an FFT phase ramp.
n = numel(x);
nfft = 2^nextpow2(n + 2);
X = fft(x, nfft);
ramp = exp(-1j * 2 * pi * d * (0:nfft - 1).' / nfft);
y = ifft(X .* ramp);
y = y(1:n);
end

function p = firstPeakMagnitude(mag, delayNs, windowNs)
% Magnitude of the first (wanted) path peak: the strongest |CIR| tap within
% +/-windowNs of the nominal arrival (delay 0). Falls back to the global
% peak if the window contains no energy.
mag = mag(:);
delayNs = delayNs(:);
idx = find(abs(delayNs) <= windowNs);
if ~isempty(idx)
    p = max(mag(idx), [], 'omitnan');
else
    p = NaN;
end
if ~isfinite(p) || p <= 0
    p = max(mag, [], 'omitnan');
end
if ~isfinite(p) || p <= 0
    p = eps;
end
end
