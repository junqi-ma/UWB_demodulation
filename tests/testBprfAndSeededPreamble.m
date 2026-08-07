function tests = testBprfAndSeededPreamble
%TESTBPRFANDSEEDEDPREAMBLE Verify accelerated decode kernels.
tests = functiontests(localfunctions);
end

function testBprfMexMatchesMatlabKernel(testCase)
projectDirectory = fileparts(fileparts(mfilename('fullpath')));
addpath(projectDirectory, fullfile(projectDirectory, 'helpers'));
rng(11);

numSymbols = 37;
chipsPerBurst = 8;
chipsPerSymbol = 64;
fieldStart = 123;
fieldSamples = complex(randn(chipsPerSymbol*numSymbols, 1, 'single'), ...
    randn(chipsPerSymbol*numSymbols, 1, 'single'));
spreading = 1 - 2*double(rand(chipsPerBurst, numSymbols) > 0.5);
[expectedCw, expectedEnd] = helperUWBBPRFDemodKernel( ...
    fieldSamples, fieldStart, numSymbols, chipsPerBurst, ...
    chipsPerSymbol, spreading);

if exist('helperUWBBPRFDemodKernel_mex', 'file') == 3
    [actualCw, actualEnd] = helperUWBBPRFDemodKernel_mex( ...
        fieldSamples, fieldStart, numSymbols, chipsPerBurst, ...
        chipsPerSymbol, spreading);
    testCase.verifyEqual(actualCw, expectedCw);
    testCase.verifyEqual(actualEnd, expectedEnd);
end
end

function testSeededPreambleTracksKnownStart(testCase)
projectDirectory = fileparts(fileparts(mfilename('fullpath')));
addpath(projectDirectory);
rng(19);

symbolLength = 128;
repetitions = 64;
knownStart = 401;
template = complex(randn(symbolLength, 1), randn(symbolLength, 1));
template = template/norm(template);
rx = 0.002*complex(randn(knownStart + ...
    repetitions*symbolLength + 200, 1), ...
    randn(knownStart + repetitions*symbolLength + 200, 1));
for repetition = 0:repetitions-1
    indices = knownStart + repetition*symbolLength + (0:symbolLength-1);
    rx(indices) = rx(indices) + template;
end

reference = struct('samples_per_symbol', symbolLength, ...
    'preamble_waveform', template);
params = struct('preamble_repetitions', repetitions, ...
    'cir_repetitions', repetitions, 'verbose', false);
preamble = uwbdecoder.detectRepeatedPreamble( ...
    single(rx), reference, params, knownStart + 3);

testCase.verifyEqual(preamble.detector, ...
    'seeded_direct_sfd_candidate');
testCase.verifyTrue(preamble.direct_sfd_timing);
testCase.verifyEqual(preamble.start_sample, knownStart, 'AbsTol', 1);
testCase.verifyEqual(preamble.detected_repetitions, repetitions);
testCase.verifyEqual(preamble.measured_period, symbolLength, 'AbsTol', 1e-9);
end
