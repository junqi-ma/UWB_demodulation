function tests = testAnalyzeCirInterference
%TESTANALYZECIRINTERFERENCE CIR cluster / occupancy interference detector.
tests = functiontests(localfunctions);
end

function setupOnce(testCase)
projectDirectory = fileparts(fileparts(mfilename('fullpath')));
addpath(projectDirectory);
testCase.TestData.projectDirectory = projectDirectory;
end

function testStableCirResidualNearZero(testCase)
cir = syntheticCir(0);
diagnostics = uwbdecoder.analyzeCirInterference(cir);

testCase.verifyTrue(diagnostics.valid);
testCase.verifyEqual(diagnostics.state, "clean");
testCase.verifyEqual(diagnostics.cluster_n, 0);
testCase.verifyFalse(diagnostics.sic_recommended);
testCase.verifyGreaterThanOrEqual(min(diagnostics.residual_power), 0);
earlyResidual = median(diagnostics.residual_power(diagnostics.early_indices));
testCase.verifyLessThan(earlyResidual, 1e-6);
testCase.verifyLessThan(diagnostics.early_residual_ratio_db, -40);
end

function testIncoherentInterferenceRaisesResidualRatio(testCase)
clean = uwbdecoder.analyzeCirInterference(syntheticCir(0));
interfered = uwbdecoder.analyzeCirInterference(syntheticCir(0.18, 1));

testCase.verifyTrue(interfered.valid);
testCase.verifyGreaterThan(interfered.early_residual_ratio_db, ...
    clean.early_residual_ratio_db + 15);
end

function testPartialCoverageMatchesOccupancy(testCase)
fraction = 0.30;
diagnostics = uwbdecoder.analyzeCirInterference( ...
    syntheticCir(0.22, fraction));

testCase.verifyTrue(diagnostics.valid);
testCase.verifyEqual(diagnostics.interference_occupancy, fraction, ...
    'AbsTol', 0.08);
end

function testRepetitionThresholdIsFiveDbAboveBackground(testCase)
diagnostics = uwbdecoder.analyzeCirInterference(syntheticCir(0));

expectedRatio = 10^(5 / 10);
testCase.verifyEqual(diagnostics.repetition_threshold / ...
    diagnostics.background_noise_power, expectedRatio, 'RelTol', 1e-12);
testCase.verifyEqual(10 * log10(diagnostics.repetition_threshold / ...
    diagnostics.background_noise_power), 5, 'AbsTol', 1e-12);
end

function testNormalizedFeaturesAreScaleInvariant(testCase)
base = syntheticCir(0.16, 0.40);
scaled = base;
scaled.diag_individual_values = 12 * base.diag_individual_values;

a = uwbdecoder.analyzeCirInterference(base);
b = uwbdecoder.analyzeCirInterference(scaled);

testCase.verifyEqual(a.early_residual_ratio_db, b.early_residual_ratio_db, ...
    'AbsTol', 1e-9);
testCase.verifyEqual(a.early_peak_ratio_db, b.early_peak_ratio_db, ...
    'AbsTol', 1e-9);
testCase.verifyEqual(a.interference_occupancy, b.interference_occupancy, ...
    'AbsTol', 1e-12);
end

function testClusterScaleInvariant(testCase)
base = syntheticClusterCir(struct('coverage', 0.40));
scaled = base;
scaled.diag_individual_values = 12 * base.diag_individual_values;

a = uwbdecoder.analyzeCirInterference(base);
b = uwbdecoder.analyzeCirInterference(scaled);

testCase.verifyEqual(a.cluster_n, b.cluster_n);
testCase.verifyEqual(a.state, b.state);
testCase.verifyEqual(a.cluster_max_peak_db, b.cluster_max_peak_db, ...
    'AbsTol', 1e-9);
end

function testFirstPathShiftKeepsDecision(testCase)
baseCir = syntheticClusterCir(struct('coverage', 0.40));
base = uwbdecoder.analyzeCirInterference(baseCir);
shiftedCir = syntheticClusterCir(struct('coverage', 0.40, 'pathShift', 2));
shifted = uwbdecoder.analyzeCirInterference(shiftedCir);

testCase.verifyTrue(base.valid);
testCase.verifyTrue(shifted.valid);
testCase.verifyEqual(shifted.state, base.state);
testCase.verifyEqual(shifted.sic_recommended, base.sic_recommended);
testCase.verifyEqual(shifted.first_path_index, base.first_path_index + 2);
testCase.verifyEqual(shifted.first_peak_index, base.first_peak_index + 2);
end

function testShortEarlyWindowIsInvalid(testCase)
cir = struct();
nTap = 40;
nRep = 24;
delayNs = ((-19:20).') / 0.9984;
h0 = zeros(nTap, 1);
h0(20:22) = [1; 0.8; 0.4];
cir.individual_values = repmat(h0, 1, nRep);
cir.delay_ns = delayNs;

diagnostics = uwbdecoder.analyzeCirInterference(cir);
testCase.verifyFalse(diagnostics.valid);
testCase.verifyEqual(diagnostics.reason, "insufficient_early_taps");
testCase.verifyEqual(diagnostics.state, "invalid");
testCase.verifyFalse(diagnostics.sic_recommended);
testCase.verifyTrue(isnan(diagnostics.cluster_n));
end

function testResidualPowerIsNonnegative(testCase)
cir = syntheticCir(0);
cir.diag_individual_values = repmat(cir.diag_individual_values(:, 1), ...
    1, size(cir.diag_individual_values, 2));
diagnostics = uwbdecoder.analyzeCirInterference(cir);

testCase.verifyTrue(all(diagnostics.residual_power >= 0));
testCase.verifyLessThan(max(diagnostics.residual_power), 1e-18);
end

function testMissingIndividualCirIsInvalid(testCase)
diagnostics = uwbdecoder.analyzeCirInterference(struct('values', 1));
testCase.verifyFalse(diagnostics.valid);
testCase.verifyEqual(diagnostics.reason, "missing_individual_cir");
testCase.verifyTrue(isnan(diagnostics.cluster_n));
end

function testUnknownClassifierErrors(testCase)
testCase.verifyError(@() uwbdecoder.analyzeCirInterference( ...
    syntheticCir(0), struct('classifier', 'residual')), ...
    'analyzeCirInterference:UnknownClassifier');
end

function testFullOccupancyStableInterfererIsInterfered(testCase)
cir = syntheticClusterCir(struct('coverage', 1, 'samePhase', true));
diagnostics = uwbdecoder.analyzeCirInterference(cir);

testCase.verifyTrue(diagnostics.valid);
testCase.verifyLessThan(diagnostics.interference_occupancy, 0.08);
testCase.verifyEqual(diagnostics.cluster_n, size(cir.diag_individual_values, 2));
testCase.verifyEqual(diagnostics.state, "interfered");
testCase.verifyTrue(diagnostics.sic_recommended);
end

function testCleanFirstPeakSidelobesAreClean(testCase)
cir = syntheticCleanSidelobeCir();
diagnostics = uwbdecoder.analyzeCirInterference(cir);

testCase.verifyTrue(diagnostics.valid);
testCase.verifyGreaterThan(diagnostics.first_peak_index, ...
    diagnostics.first_path_index);
testCase.verifyEqual(diagnostics.cluster_n, 0);
testCase.verifyEqual(diagnostics.state, "clean");
end

function testFirstPeakIsNotGlobalMax(testCase)
cir = syntheticClusterCir(struct( ...
    'coverage', 1, ...
    'latePeakAmp', 2.0, ...
    'clusterDb', -18));
diagnostics = uwbdecoder.analyzeCirInterference(cir);

testCase.verifyEqual(diagnostics.first_peak_power, 1.0, 'AbsTol', 1e-12);
testCase.verifyEqual(diagnostics.cluster_max_peak_db, -18, 'AbsTol', 0.3);
testCase.verifyGreaterThan(diagnostics.first_peak_power, 0);
testCase.verifyNotEqual(diagnostics.first_peak_power, 4.0);
end

function testOccupancyRollbackUsesLegacyWindow(testCase)
cir = syntheticClusterCir(struct('coverage', 1, 'samePhase', true));
clustered = uwbdecoder.analyzeCirInterference(cir);
rolled = uwbdecoder.analyzeCirInterference(cir, ...
    struct('classifier', 'occupancy'));

testCase.verifyEqual(clustered.state, "interfered");
testCase.verifyLessThan(rolled.interference_occupancy, 0.08);
testCase.verifyEqual(rolled.interference_occupancy, ...
    clustered.interference_occupancy, 'AbsTol', 1e-12);
testCase.verifyNotEqual(rolled.state, "interfered");
testCase.verifyEqual(rolled.classifier, "occupancy");
end

function testDiagWindowDoesNotChangeCmfCir(testCase)
[rx, preamble, reference, params] = syntheticEstimateCirInput();
cirNarrow = uwbdecoder.estimateCir(rx, preamble, reference, params);

params.cir_diag_pre_samples = 64;
params.cir_diag_post_samples = 64;
cirWide = uwbdecoder.estimateCir(rx, preamble, reference, params);

testCase.verifyEqual(cirWide.values, cirNarrow.values, 'AbsTol', 1e-12);
testCase.verifyEqual(cirWide.delay_ns, cirNarrow.delay_ns, 'AbsTol', 1e-12);
testCase.verifyEqual(cirWide.individual_values, cirNarrow.individual_values, ...
    'AbsTol', 1e-12);
testCase.verifyEqual(cirWide.pre_samples, cirNarrow.pre_samples);
testCase.verifyEqual(cirWide.post_samples, cirNarrow.post_samples);
testCase.verifyTrue(isfield(cirWide, 'diag_individual_values'));
testCase.verifyGreaterThan(numel(cirWide.diag_delay_ns), ...
    numel(cirNarrow.delay_ns));
end

function cir = syntheticCir(interferenceAmp, coverage, pathShift)
if nargin < 1
    interferenceAmp = 0;
end
if nargin < 2
    coverage = 1;
end
if nargin < 3
    pathShift = 0;
end
rng(17);
nTap = 128;
nRep = 40;
delayNs = ((-64:63).') / 0.9984;
h0 = zeros(nTap, 1);
h0(65:67) = [0.35; 1; 0.25];
if pathShift ~= 0
    h0 = circshift(h0, pathShift);
end
H = h0 + 1e-4 * complex(randn(nTap, nRep), randn(nTap, nRep));
if interferenceAmp > 0
    nInt = max(1, round(coverage * nRep));
    cols = (nRep - nInt + 1):nRep;
    H(1:50, cols) = H(1:50, cols) + interferenceAmp * complex( ...
        randn(50, numel(cols)), randn(50, numel(cols)));
end
cir = struct('diag_individual_values', H, 'diag_delay_ns', delayNs);
end

function cir = syntheticClusterCir(args)
if nargin < 1
    args = struct();
end
if ~isfield(args, 'coverage')
    args.coverage = 1;
end
if ~isfield(args, 'pathShift')
    args.pathShift = 0;
end
if ~isfield(args, 'samePhase')
    args.samePhase = true;
end
if ~isfield(args, 'latePeakAmp')
    args.latePeakAmp = 0;
end
if ~isfield(args, 'clusterDb')
    args.clusterDb = -18;
end
if ~isfield(args, 'raiseMedian')
    args.raiseMedian = args.samePhase && args.coverage >= 1;
end
nTap = 128;
nRep = 40;
delayNs = ((-64:63).') / 0.9984;
h0 = zeros(nTap, 1);
h0(65:68) = [0.35; 0.70; 1.0; 0.25];
if args.latePeakAmp > 0
    h0(88) = args.latePeakAmp;
end
if args.pathShift ~= 0
    h0 = circshift(h0, args.pathShift);
end
H = repmat(h0, 1, nRep);
nInt = max(1, round(args.coverage * nRep));
cols = (nRep - nInt + 1):nRep;
clusterAmp = 10^(args.clusterDb / 20);
if args.raiseMedian
    % Stay left of the FP search (nominal zero ± 32) so MAD FP stays
    % on the QM35 mainlobe, but fill enough legacy taps that the
    % per-rep early median rises on every column.
    clusterTaps = (1:32).';
else
    clusterTaps = (40:43).';
end
if args.pathShift ~= 0
    clusterTaps = clusterTaps + args.pathShift;
end
clusterTaps = clusterTaps(clusterTaps >= 1 & clusterTaps <= nTap);
if args.samePhase
    H(clusterTaps, cols) = H(clusterTaps, cols) + clusterAmp;
else
    rng(19);
    H(clusterTaps, cols) = H(clusterTaps, cols) + clusterAmp * complex( ...
        randn(numel(clusterTaps), numel(cols)), ...
        randn(numel(clusterTaps), numel(cols)));
end
cir = struct('diag_individual_values', H, 'diag_delay_ns', delayNs);
end

function cir = syntheticCleanSidelobeCir()
nTap = 128;
nRep = 40;
delayNs = ((-64:63).') / 0.9984;
h0 = zeros(nTap, 1);
h0(65:68) = [0.35; 0.70; 1.0; 0.25];
h0(63:64) = 10^(-28 / 20);
h0(1:55) = 10^(-50 / 20);
H = repmat(h0, 1, nRep);
cir = struct('diag_individual_values', H, 'diag_delay_ns', delayNs);
end

function [rx, preamble, reference, params] = syntheticEstimateCirInput()
rng(23);
code = [1; -1; 1; 1; -1; 1; -1; -1];
reference = struct('sampled_code', code, 'fs', 998.4e6, ...
    'code_energy', sum(abs(code).^2));
preamble = struct('start_sample', 220, 'detected_repetitions', 32, ...
    'measured_period', 32, 'search_half_width', 8);
params = struct('preamble_repetitions', 32, 'cir_repetitions', 16, ...
    'cir_skip_initial_repetitions', 0, 'cir_pre_samples', 8, ...
    'cir_post_samples', 30, 'cir_store_individual_values', true, ...
    'cir_diag_pre_samples', [], 'cir_diag_post_samples', [], ...
    'show_plots', false, 'cir_timing', false);

n = 1400;
rx = 0.01 * complex(randn(n, 1), randn(n, 1));
for repetition = 0:31
    idx = preamble.start_sample + repetition * preamble.measured_period + ...
        (0:numel(code)-1);
    rx(idx) = rx(idx) + code;
end
end
