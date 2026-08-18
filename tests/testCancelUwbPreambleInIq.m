function tests = testCancelUwbPreambleInIq
%TESTCANCELUWBPPREAMBLEINIQ SYNC-only cancellation on synthetic work-rate IQ.
%   Needs Communications Toolbox (lrwpanHRPConfig). Never reads
%   F:\UWB基带数据\.
tests = functiontests(localfunctions);
end

function setupOnce(testCase)
projectDirectory = fileparts(fileparts(mfilename('fullpath')));
addpath(projectDirectory);
testCase.TestData.projectDirectory = projectDirectory;
end

function testPreambleOnlyCancelDropsSyncBandPower(testCase)
rng(29);
params = uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), struct( ...
    'code_index', 10, 'preamble_repetitions', 256, ...
    'cir_repetitions', 64, 'cir_skip_initial_repetitions', 10, ...
    'show_plots', false));
ref = uwbdecoder.buildUwbReference(params);

visible = 80;
start = 5000;
noiseStd = 1e-3;
cir = struct('values', [0; 1; 0.3; 0.1], 'pre_samples', 1, ...
    'delay_ns', ((-2:1).')./0.9984);
txWave = buildSyncOnlyWaveform(params, visible, cir);
n = start + numel(txWave) + 200;
rx = noiseStd * complex(randn(n, 1), randn(n, 1));
rx(start:start + numel(txWave) - 1) = ...
    rx(start:start + numel(txWave) - 1) + txWave;

preamble = struct('start_sample', start, ...
    'measured_period', ref.samples_per_symbol, ...
    'detected_repetitions', visible);
cirEst = uwbdecoder.estimateCir(rx, preamble, ref, params);

txOpt = txOptions(visible);
opts = struct();
[rxOut, report] = cancel_uwb_preamble_in_iq( ...
    rx, preamble, cirEst, txOpt, opts);

testCase.verifyGreaterThanOrEqual( ...
    report.alignment_correlation, 0.70);

band = start:start + numel(txWave) - 1;
beforePower = mean(abs(rx(band)).^2);
afterPower = mean(abs(rxOut(band)).^2);
testCase.verifyLessThan(afterPower, 0.25 * beforePower);
testCase.verifyGreaterThan(10 * log10(beforePower / (afterPower + eps)), 6);

% Samples outside the subtracted span are untouched (only the SYNC span
% between 5000 and the aligned start is overwritten).
testCase.verifyLessThan(max(abs(rxOut(1:4000) - rx(1:4000))), 1e-9);
end

function testPreambleOnlyRejectsLowAlignment(testCase)
rng(31);
params = uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), struct( ...
    'code_index', 10, 'preamble_repetitions', 256, ...
    'cir_repetitions', 64, 'cir_skip_initial_repetitions', 10, ...
    'show_plots', false));
ref = uwbdecoder.buildUwbReference(params);

visible = 80;
start = 5000;
offset = 500;   % ~ half a SYNC period: replica no longer aligns
noiseStd = 1e-3;
cir = struct('values', [0; 1; 0.3; 0.1], 'pre_samples', 1, ...
    'delay_ns', ((-2:1).')./0.9984);
txWave = buildSyncOnlyWaveform(params, visible, cir);
n = start + offset + numel(txWave) + 200;
rx = noiseStd * complex(randn(n, 1), randn(n, 1));
rx(start + offset:start + offset + numel(txWave) - 1) = ...
    rx(start + offset:start + offset + numel(txWave) - 1) + txWave;

preamble = struct('start_sample', start, ...
    'measured_period', ref.samples_per_symbol, ...
    'detected_repetitions', visible);
cirEst = uwbdecoder.estimateCir(rx, preamble, ref, params);

txOpt = txOptions(visible);
opts = struct('max_abs_cfo_hz', 1e9);   % isolate the 0.70 alignment gate
testCase.verifyError(@() cancel_uwb_preamble_in_iq( ...
    rx, preamble, cirEst, txOpt, opts), ...
    'cancel_uwb_preamble_in_iq:Alignment');
end

function testTooFewVisibleSyncRejected(testCase)
rng(37);
visible = 32;   % below min_visible_sync_for_preamble_sic = 64
rx = complex(randn(20000, 1), randn(20000, 1));
preamble = struct('start_sample', 5000, ...
    'measured_period', 1016, 'detected_repetitions', 80);
cir = struct('values', [0; 1; 0.3; 0.1], 'pre_samples', 1, ...
    'delay_ns', (0:3).'/0.9984);
txOpt = txOptions(visible);
testCase.verifyError(@() cancel_uwb_preamble_in_iq( ...
    rx, preamble, cir, txOpt, struct()), ...
    'cancel_uwb_preamble_in_iq:TooFewSync');
end

% -------------------------------------------------------------------------
function txWave = buildSyncOnlyWaveform(params, visible, cir)
cfg = lrwpanHRPConfig(Mode='802.15.4a', MeanPRF=62.4, ...
    DataRate=6.81, SamplesPerPulse=2, ...
    CodeIndex=params.code_index, PreambleDuration=64, ...
    Ranging=true, PSDULength=1);
[~, pulseSymbols] = lrwpanWaveformGenerator(zeros(8, 1), cfg);
indices = lrwpanHRPFieldIndices(cfg);
samplesPerSync = (indices.SYNC(2) - indices.SYNC(1) + 1) / cfg.PreambleDuration;
symbolsPerSync = samplesPerSync / cfg.SamplesPerPulse;
syncPulseSymbols = pulseSymbols(1:round(symbolsPerSync));
pulseSymbolsWork = repmat(syncPulseSymbols, visible, 1);
pulseImpulsesWork = zeros(numel(pulseSymbolsWork) * cfg.SamplesPerPulse, 1);
pulseImpulsesWork(1:cfg.SamplesPerPulse:end) = pulseSymbolsWork;
tx = struct();
tx.pulse_impulses_work = pulseImpulsesWork;
tx.sample_rate_work = cfg.SampleRate;
tx.sample_rate_tx = cfg.SampleRate;
tx.digital_offset_hz = 0;
tx.guard_samples = 0;
tx.preamble_repetitions = visible;
channel = apply_estimated_cir_to_uwb(tx, cir);
txWave = channel.waveform_x410(:);
end

function opts = txOptions(visible)
opts = struct( ...
    'code_index', 10, ...
    'visible_reps', visible, ...
    'fs_tx', 998.4e6, ...
    'phy_mode', '802.15.4a', ...
    'peak_amplitude', 1, ...
    'guard_samples', 0);
end