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
template = unitTemplate(symbolLength);

headStart = 400;
headReps = 40;
laterStart = 288000;
laterReps = 80;
qm35Start = 300000;

rx = noisyWindow(n, symbolLength, headStart, headReps, ...
    laterStart, laterReps, template, 0.002);
search = findDwPreambleCandidatesOnWindow( ...
    rx, makeProfile(symbolLength, template), qm35Start);

testCase.verifyTrue(search.head_is_fragment);
testCase.verifyLessThan(abs(search.head_start - headStart), symbolLength);
testCase.verifyTrue(isfinite(search.overlap_start));
testCase.verifyLessThan( ...
    abs(search.overlap_start - laterStart), 3 * symbolLength);
testCase.verifyGreaterThan(search.overlap_start, 2000);
testCase.verifyEqual(search.search_path, "qm35_neighborhood");
end

function testLongHeadRemainderDoesNotStealLaterPacket(testCase)
rng(19);
symbolLength = 128;
n = 350000;
template = unitTemplate(symbolLength);

headStart = 400;
headReps = 100;
laterStart = 288000;
laterReps = 80;
qm35Start = 240000;

rx = noisyWindow(n, symbolLength, headStart, headReps, ...
    laterStart, laterReps, template, 0.002);
search = findDwPreambleCandidatesOnWindow( ...
    rx, makeProfile(symbolLength, template), qm35Start);

forbiddenCursor = headStart + 64 * symbolLength;
testCase.verifyTrue(isfinite(search.overlap_start));
testCase.verifyLessThan( ...
    abs(search.overlap_start - laterStart), 3 * symbolLength);
testCase.verifyGreaterThan(search.overlap_start, 2000);
testCase.verifyGreaterThan( ...
    abs(search.overlap_start - search.head_start), 10 * symbolLength);
testCase.verifyGreaterThan(abs(search.overlap_start - forbiddenCursor), ...
    2 * symbolLength);
testCase.verifyEqual(search.search_path, "late_after_qm35");
end

function testEarlyStartIsNotHeadFragment(testCase)
rng(11);
symbolLength = 128;
n = 30000;
template = unitTemplate(symbolLength);

earlyStart = 9174;
earlyReps = 80;
qm35Start = NaN;

rx = noisyWindow(n, symbolLength, earlyStart, earlyReps, ...
    [], 0, template, 0.002);
search = findDwPreambleCandidatesOnWindow( ...
    rx, makeProfile(symbolLength, template), qm35Start);

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
template = unitTemplate(symbolLength);

headStart = 969;
headReps = 40;
profile = makeProfile(symbolLength, template);
rx = noisyWindow(n, symbolLength, headStart, headReps, ...
    [], 0, template, 0.002);

search = findDwPreambleCandidatesOnWindow(rx, profile, 300000);
testCase.verifyTrue(search.head_is_fragment);
testCase.verifyFalse(isfinite(search.overlap_start));
testCase.verifyEqual(search.search_path, "none");

searchNan = findDwPreambleCandidatesOnWindow(rx, profile, NaN);
testCase.verifyTrue(searchNan.head_is_fragment);
testCase.verifyFalse(isfinite(searchNan.overlap_start));
testCase.verifyEqual(searchNan.search_path, "none");
end

% -------------------------------------------------------------------------
function template = unitTemplate(symbolLength)
template = complex(randn(symbolLength, 1), randn(symbolLength, 1));
template = template / norm(template);
end

function profile = makeProfile(symbolLength, template)
reference = struct('samples_per_symbol', symbolLength, ...
    'preamble_waveform', template);
params = struct('preamble_repetitions', 256, ...
    'cir_repetitions', 64, 'verbose', false);
profile = struct('name', 'test', 'params', params, ...
    'reference', reference, 'sfd', struct(), 'tx', struct(), ...
    'cancel', struct());
end

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
