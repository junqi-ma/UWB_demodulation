function tests = testFindDwPreambleCandidatesOnWindow
%TESTFINDDWPREAMBLECANDIDATESONWINDOW Dump-SIC head-fragment skip + overlap search.
%   Synthetic only; never reads F:\UWB基带数据\.
tests = functiontests(localfunctions);
end

function setupOnce(testCase)
projectDirectory = fileparts(fileparts(mfilename('fullpath')));
addpath(projectDirectory);
testCase.TestData.projectDirectory = projectDirectory;
end

function testSkipsHeadFragmentAndFindsLaterStart(testCase)
rng(7);
symbolLength = 128;
n = 350000;
template = complex(randn(symbolLength, 1), randn(symbolLength, 1));
template = template / norm(template);
noiseStd = 0.002;

headStart = 400;
headReps = 40;
laterStart = 288000;
laterReps = 256;
qm35Start = 300000;

rx = noisyWindow(n, symbolLength, headStart, headReps, ...
    laterStart, laterReps, template, noiseStd);

reference = struct('samples_per_symbol', symbolLength, ...
    'preamble_waveform', template);
params = struct('preamble_repetitions', 256, ...
    'cir_repetitions', 64, 'verbose', false);
profile = struct('name', 'test', 'params', params, ...
    'reference', reference, 'sfd', struct(), 'tx', struct(), ...
    'cancel', struct());

search = findDwPreambleCandidatesOnWindow(rx, profile, qm35Start, []);

testCase.verifyTrue(search.head_is_fragment);
testCase.verifyLessThan(abs(search.head_start - headStart), symbolLength);
testCase.verifyTrue(isfinite(search.overlap_start));
testCase.verifyLessThan( ...
    abs(search.overlap_start - laterStart), 3 * symbolLength);
testCase.verifyTrue(ismember(search.search_path, ...
    ["qm35_neighborhood", "suffix_after_head"]));
testCase.verifyGreaterThan(search.overlap_start, 2000);
end

function testEarlyStartIsNotHeadFragment(testCase)
rng(11);
symbolLength = 128;
n = 30000;
template = complex(randn(symbolLength, 1), randn(symbolLength, 1));
template = template / norm(template);
noiseStd = 0.002;

earlyStart = 9174;
earlyReps = 80;
qm35Start = NaN;   % no QM35 seed here; not a scheduled window

rx = noisyWindow(n, symbolLength, earlyStart, earlyReps, ...
    [], 0, template, noiseStd);
reference = struct('samples_per_symbol', symbolLength, ...
    'preamble_waveform', template);
params = struct('preamble_repetitions', 256, ...
    'cir_repetitions', 64, 'verbose', false);
profile = struct('name', 'test', 'params', params, ...
    'reference', reference, 'sfd', struct(), 'tx', struct(), ...
    'cancel', struct());

search = findDwPreambleCandidatesOnWindow(rx, profile, qm35Start, []);

testCase.verifyFalse(search.head_is_fragment);
testCase.verifyEqual(search.search_path, "earliest");
testCase.verifyTrue(isfinite(search.overlap_start));
testCase.verifyLessThan(abs(search.overlap_start - earlyStart), ...
    symbolLength);
end

function testHeadLockBelowThresholdIsFragment(testCase)
rng(13);
symbolLength = 128;
n = 350000;
template = complex(randn(symbolLength, 1), randn(symbolLength, 1));
template = template / norm(template);
noiseStd = 0.002;

headStart = 969;
headReps = 40;
qm35Start = 300000;

rx = noisyWindow(n, symbolLength, headStart, headReps, ...
    [], 0, template, noiseStd);
reference = struct('samples_per_symbol', symbolLength, ...
    'preamble_waveform', template);
params = struct('preamble_repetitions', 256, ...
    'cir_repetitions', 64, 'verbose', false);
profile = struct('name', 'test', 'params', params, ...
    'reference', reference, 'sfd', struct(), 'tx', struct(), ...
    'cancel', struct());

search = findDwPreambleCandidatesOnWindow(rx, profile, qm35Start, []);

testCase.verifyTrue(search.head_is_fragment);
testCase.verifyFalse(isfinite(search.overlap_start));
testCase.verifyEqual(search.search_path, "none");
end

% -------------------------------------------------------------------------
function rx = noisyWindow(n, symbolLength, start1, reps1, ...
        start2, reps2, template, noiseStd)
rx = noiseStd * complex(randn(n, 1), randn(n, 1));
if reps1 > 0
    rx = placeSyncs(rx, start1, reps1, symbolLength, template);
end
if reps2 > 0
    rx = placeSyncs(rx, start2, reps2, symbolLength, template);
end
end

function rx = placeSyncs(rx, start, reps, symbolLength, template)
for rep = 0:reps - 1
    idx = start + rep * symbolLength + (0:symbolLength - 1);
    if idx(end) <= numel(rx)
        rx(idx) = rx(idx) + template;
    end
end
end