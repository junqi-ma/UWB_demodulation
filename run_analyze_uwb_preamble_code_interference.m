%% Analyze cross-code interference rejection between UWB preamble codes.
% Two HRP devices that use different preamble codes (CodeIndex) still share
% the same spectrum. This script quantifies how much of code-j interference
% leaks through a receiver matched to code i, using the project reference
% builder (+uwbdecoder/buildUwbReference style waveforms, 998.4 MHz grid):
%
%   Part A - single-symbol cross-correlation leakage (deterministic):
%       The matched-filter peak produced by one unit-energy interferer
%       symbol, maximized over all relative timing offsets. This is the
%       fundamental code-pair suppression and bounds preamble false
%       acquisition, because detectRepeatedPreamble tracks periodic MF
%       peaks regardless of which code produced them.
%
%   Part B - receiver folding simulation (statistical):
%       A full SYNC burst (preamble_repetitions symbols) of code j with a
%       random integer+fractional timing offset, random phase, and random
%       CFO is matched-filtered with code i's template, then folded at
%       code i's symbol period over fold_repetitions repetitions, exactly
%       like CIR estimation (estimateCirAndSoftChips). Reported metrics:
%         - noncoherent leakage: max tap of mean(|y|^2)  (energy detector
%           / peak tracker view, what detectRepeatedPreamble sees)
%         - coherent leakage:    max tap of |mean(y)|^2  (coherent CIR
%           averaging view; cross-period drift and CFO cancel part of it)
%       Both are relative to the unit own-code folded peak (0 dB), i.e.
%       the value is the post-processing SIR for equal symbol energies.
%
% Part C plots the folded CIR profiles for the QM35(code 9) <-> DW1000
% (code 10) pair, the coexistence scenario targeted by the SIC pipeline.
%
% Results are saved to decoded_results/preamble_code_interference/ as a
% .mat, CSV matrices, and figures. No capture files are required.

clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% Configuration
channel_number = 5;                       % UWB channel used to validate codes
code_candidates = [1:6, 9:16, 21:32];     % 4a + 4z preamble code indices
prf_candidates = [62.4, 15.6];            % mean PRF tried per code (first valid wins)
preamble_repetitions = 128;               % interferer SYNC repetitions (QM35 length)
fold_repetitions = 64;                    % receiver folding repetitions (cir default)
trials = 16;                              % random trials per ordered code pair
cfo_max_hz = 25e3;                        % per-trial |CFO| drawn from +-cfo_max_hz
rng_seed = 42;
show_plots = true;
output_dir = fullfile(project_dir, 'decoded_results', ...
    'preamble_code_interference');

%% Build one-symbol references for every code valid on this channel
refs = struct([]);
code_ids = [];
for idx = code_candidates
    ref = buildCodeReference(idx, prf_candidates, channel_number);
    if isempty(ref)
        continue;
    end
    if isempty(code_ids)
        refs = ref;
    else
        refs(end+1) = ref; %#ok<AGROW>
    end
    code_ids(end+1) = idx; %#ok<SAGROW>
end
n_codes = numel(code_ids);
if n_codes < 2
    error('run_analyze_uwb_preamble_code_interference:TooFewCodes', ...
        'Need at least two valid preamble codes to analyze.');
end
fprintf('Built %d valid code references on channel %d: [%s]\n', ...
    n_codes, channel_number, strjoin(string(code_ids), ', '));

fs = refs(1).fs;
if any(arrayfun(@(r) r.fs ~= fs, refs))
    error('run_analyze_uwb_preamble_code_interference:SampleRateMismatch', ...
        'Not all codes share a common sample rate.');
end
for k = 1:n_codes
    refs(k).template = conj(flipud(refs(k).preamble_waveform));
end

%% Part A: single-symbol cross-correlation leakage (worst-case offsets)
% Unit-energy symbols make the own-code MF peak exactly 1 (0 dB), so the
% leakage in dB is directly 20*log10(max cross-correlation magnitude).
leak_single_db = nan(n_codes, n_codes);
for r = 1:n_codes
    for i = 1:n_codes
        leak_single_db(r, i) = 20*log10( ...
            fftXcorrPeak(refs(r).preamble_waveform, refs(i).preamble_waveform) ...
            + eps);
    end
end

%% Part B: full-SYNC folding simulation with random offsets/phases/CFO
rng(rng_seed, 'twister');
% Sanity check: own-code folded peak must be ~1 (0 dB).
check = simulateCodeLeakage(refs(1), refs(1), preamble_repetitions, ...
    fold_repetitions, 0, 0, 0, 0, fs);
fprintf('Own-code folded-peak sanity check: %.2f (noncoh) %.2f (coh) dB\n', ...
    10*log10(check.noncoherent_peak), 10*log10(check.coherent_peak));

leak_noncoh_db = nan(n_codes, n_codes);
leak_noncoh_p95_db = nan(n_codes, n_codes);
leak_coh_db = nan(n_codes, n_codes);
for r = 1:n_codes
    for i = 1:n_codes
        if r == i
            continue;  % own code is the wanted signal: 0 dB by definition
        end
        noncoh = zeros(trials, 1);
        coh = zeros(trials, 1);
        for t = 1:trials
            delta = randi([0, refs(i).samples_per_symbol-1]);
            frac = rand;
            phase = 2*pi*rand;
            cfo_hz = cfo_max_hz*(2*rand - 1);
            sim = simulateCodeLeakage(refs(r), refs(i), ...
                preamble_repetitions, fold_repetitions, delta, frac, ...
                phase, cfo_hz, fs);
            noncoh(t) = sim.noncoherent_peak;
            coh(t) = sim.coherent_peak;
        end
        leak_noncoh_db(r, i) = 10*log10(median(noncoh));
        leak_noncoh_p95_db(r, i) = 10*log10(prctile(noncoh, 95));
        leak_coh_db(r, i) = 10*log10(median(coh));
    end
    fprintf('Fold simulation: wanted code %d done (%d/%d)\n', ...
        code_ids(r), r, n_codes);
end

%% Summary report
fprintf('\n=== Single-symbol cross-correlation leakage, dB (0 dB = own code) ===\n');
fprintf('Rows = wanted/receiver code, columns = interferer code\n');
printDbMatrix(code_ids, leak_single_db);

fprintf('\nWorst-case interferer per wanted code (single-symbol metric):\n');
for r = 1:n_codes
    row = leak_single_db(r, :);
    row(r) = -Inf;  % exclude own code (0 dB by definition)
    [worstDb, k] = max(row);
    fprintf('  want %2d: worst interferer %2d at %6.2f dB', ...
        code_ids(r), code_ids(k), worstDb);
    if code_ids(r) == 9 || code_ids(r) == 10
        other = 9 + (code_ids(r) == 9);
        fprintf('   [%d<-]%2d: %6.2f dB (fold median %6.2f dB)', ...
            code_ids(r), other, leak_single_db(r, code_ids == other), ...
            leak_noncoh_db(r, code_ids == other));
    end
    fprintf('\n');
end

fprintf('\n=== Folded-SYNC leakage, dB (median over %d trials, |CFO|<=%.0f Hz) ===\n', ...
    trials, cfo_max_hz);
printDbMatrix(code_ids, leak_noncoh_db);
fprintf('\nCoherent-folding leakage (median), dB:\n');
printDbMatrix(code_ids, leak_coh_db);

%% Part C: folded CIR profiles for the QM35(9) <-> DW1000(10) pair
rng(rng_seed, 'twister');
profile_pairs = [10, 9; 9, 10];
profiles = cell(size(profile_pairs, 1), 1);
for p = 1:size(profile_pairs, 1)
    want = find(code_ids == profile_pairs(p, 1));
    intf = find(code_ids == profile_pairs(p, 2));
    if isempty(want) || isempty(intf)
        continue;
    end
    delta = randi([0, refs(intf).samples_per_symbol-1]);
    sim = simulateCodeLeakage(refs(want), refs(intf), ...
        preamble_repetitions, fold_repetitions, delta, rand, 2*pi*rand, ...
        cfo_max_hz*(2*rand-1), fs);
    profiles{p} = struct('want_code', code_ids(want), ...
        'intf_code', code_ids(intf), 'noncoherent_db', ...
        10*log10(sim.noncoherent + eps), 'coherent_db', ...
        10*log10(sim.coherent + eps));
end

%% Save results
if ~isfolder(output_dir)
    mkdir(output_dir);
end
results = struct('code_ids', code_ids, 'fs', fs, 'channel', channel_number, ...
    'preamble_repetitions', preamble_repetitions, ...
    'fold_repetitions', fold_repetitions, 'trials', trials, ...
    'cfo_max_hz', cfo_max_hz, ...
    'leak_single_db', leak_single_db, ...
    'leak_noncoh_median_db', leak_noncoh_db, ...
    'leak_noncoh_p95_db', leak_noncoh_p95_db, ...
    'leak_coherent_median_db', leak_coh_db, ...
    'references', {refs});
save(fullfile(output_dir, 'preamble_code_interference.mat'), ...
    'results', '-v7.3');
header = [NaN, code_ids];
writematrix(header, ...
    fullfile(output_dir, 'leakage_single_symbol_db.csv'));
writematrix([code_ids.', leak_single_db], ...
    fullfile(output_dir, 'leakage_single_symbol_db.csv'), ...
    'WriteMode', 'append');
writematrix(header, ...
    fullfile(output_dir, 'leakage_fold_noncoh_median_db.csv'));
writematrix([code_ids.', leak_noncoh_db], ...
    fullfile(output_dir, 'leakage_fold_noncoh_median_db.csv'), ...
    'WriteMode', 'append');
writematrix(header, ...
    fullfile(output_dir, 'leakage_fold_coh_median_db.csv'));
writematrix([code_ids.', leak_coh_db], ...
    fullfile(output_dir, 'leakage_fold_coh_median_db.csv'), ...
    'WriteMode', 'append');
fprintf('\nSaved matrices and .mat to %s\n', output_dir);

%% Figures
if show_plots
    figure('Name', 'Single-symbol cross-correlation leakage (dB)', ...
        'Color', 'w');
    plotLeakageHeatmap(code_ids, leak_single_db, ...
        'Single-symbol cross-correlation leakage (dB, 0 = own code)');

    figure('Name', 'Folded-SYNC noncoherent leakage (dB)', ...
        'Color', 'w');
    plotLeakageHeatmap(code_ids, leak_noncoh_db, ...
        sprintf('Folded-SYNC noncoherent leakage, median of %d trials (dB)', ...
        trials));

    figure('Name', 'QM35/DW1000 folded CIR profiles', 'Color', 'w');
    tiledlayout(2, 1, 'TileSpacing', 'compact');
    for p = 1:numel(profiles)
        if isempty(profiles{p})
            continue;
        end
        nexttile;
        delay_ns = (0:numel(profiles{p}.noncoherent_db)-1).'/fs*1e9;
        areaFill(delay_ns, profiles{p}.noncoherent_db);
        hold on;
        plot(delay_ns, profiles{p}.coherent_db, 'LineWidth', 1.2);
        yline(0, '--', 'own-code peak (0 dB)');
        grid on;
        xlabel('Folded CIR tap (ns)');
        ylabel('Power (dB)');
        title(sprintf('Receiver code %d, interferer code %d-only', ...
            profiles{p}.want_code, profiles{p}.intf_code));
        legend('noncoherent fold', 'coherent fold', 'Location', 'best');
        ylim([-45 3]);
    end
    savefig(gcf, fullfile(output_dir, 'qm35_dw1000_folded_profiles.fig'));
    exportgraphics(gcf, fullfile(output_dir, ...
        'qm35_dw1000_folded_profiles.png'));
end

%% Local functions
function ref = buildCodeReference(code_index, prf_candidates, channel_number)
%BUILDCODEREFERENCE One-symbol HRP reference for a given preamble code.
%   Mirrors +uwbdecoder/buildUwbReference but parameterizes MeanPRF and
%   Channel so length-31 (15.6 PRF) and length-127 (62.4 PRF) codes are
%   both buildable. Returns [] when the code is invalid on this channel.
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
    samplesPerSymbol = indices.SYNC(end)/cfg.PreambleDuration;
    preambleWaveform = tx(1:samplesPerSymbol);
    preambleWaveform = preambleWaveform(:) / ...
        (norm(preambleWaveform) + eps);
    code = lrwpan.internal.HRPCodes(code_index);
    ref = struct('code_index', code_index, 'mean_prf', prf, ...
        'code_length', length(code), 'fs', cfg.SampleRate, ...
        'samples_per_symbol', samplesPerSymbol, ...
        'preamble_waveform', preambleWaveform);
    return;
end
end

function peak = fftXcorrPeak(a, b)
%FFTXCORRPEAK Maximum linear cross-correlation magnitude of a and b.
n = numel(a) + numel(b) - 1;
nfft = 2^nextpow2(n);
c = ifft(fft(a, nfft).*conj(fft(b, nfft)));
peak = max(abs(c(1:n)));
end

function sim = simulateCodeLeakage(ref_rx, ref_intf, n_rep, n_fold, ...
    delta, frac, phase, cfo_hz, fs)
%SIMULATECODELEAKAGE Match-filter a foreign-code SYNC burst and fold it.
%   Places n_rep+2 unit-energy interferer symbols on the interferer symbol
%   grid (integer delta + fractional frac delay, common phase, linear CFO),
%   matched-filters with the wanted template, and folds the output at the
%   wanted symbol period over n_fold repetitions. Peaks are relative to
%   the unit own-code folded peak, i.e. directly in post-processing SIR.
pi_len = numel(ref_rx.preamble_waveform);
pj_len = ref_intf.samples_per_symbol;
w = fractionalDelay(ref_intf.preamble_waveform, frac)*exp(1i*phase);
sig = zeros((n_rep+4)*pj_len + pi_len, 1);
for k = 1:n_rep+2
    first = delta + (k-1)*pj_len + 1;
    sig(first:first+numel(w)-1) = sig(first:first+numel(w)-1) + w;
end
if cfo_hz ~= 0
    n = (0:numel(sig)-1).';
    sig = sig.*exp(1j*2*pi*cfo_hz*n/fs);
end
y = uwbdecoder.fftFilter(ref_rx.template, sig);
base = delta + pi_len;
n_avail = floor((numel(y) - base)/ref_rx.samples_per_symbol);
if n_avail < n_fold
    error('simulateCodeLeakage:TooShort', ...
        'Folded repetition budget too small (%d < %d).', n_avail, n_fold);
end
idx = base + (0:n_avail-1)*ref_rx.samples_per_symbol + ...
    (0:ref_rx.samples_per_symbol-1).';
segments = y(idx);
noncoh = mean(abs(segments).^2, 2);
coh = abs(mean(segments, 2)).^2;
sim = struct('noncoherent_peak', max(noncoh), ...
    'coherent_peak', max(coh), 'noncoherent', noncoh, 'coherent', coh);
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

function printDbMatrix(code_ids, db_matrix)
%PRINTDBMATRIX Print a leakage matrix with 0.1 dB resolution.
fprintf('        %s\n', join(string(code_ids), '  '));
for r = 1:numel(code_ids)
    fprintf('  %2d |', code_ids(r));
    fprintf(' %5.1f', db_matrix(r, :));
    fprintf('\n');
end
end

function plotLeakageHeatmap(code_ids, db_matrix, title_text)
%PLOTLEAKAGEHEATMAP Heatmap of leakage dB with code-index axes.
n = numel(code_ids);
imagesc(db_matrix);
set(gca, 'XTick', 1:n, 'XTickLabel', string(code_ids), ...
    'YTick', 1:n, 'YTickLabel', string(code_ids));
colormap(flipud(parula));
colorbar;
clim([-30 0]);
axis square;
xlabel('Interferer code');
ylabel('Wanted (receiver) code');
title(title_text);
end

function areaFill(x, y)
%AREAFILL Filled step plot for nonnegative-side power profiles.
x = x(:);
y = y(:);
fill([x; flipud(x)], [y; min(y)*ones(numel(y), 1)], ...
    [0.3 0.6 0.85], 'EdgeColor', 'none');
end
