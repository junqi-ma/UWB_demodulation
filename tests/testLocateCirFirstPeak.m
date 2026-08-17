function tests = testLocateCirFirstPeak
%TESTLOCATECIRFIRSTPEAK First local max at/after First Path.
tests = functiontests(localfunctions);
end

function setupOnce(testCase)
projectDirectory = fileparts(fileparts(mfilename('fullpath')));
addpath(projectDirectory);
testCase.TestData.projectDirectory = projectDirectory;
end

function testPlateauReturnsFirstIndex(testCase)
powerBar = [0.01; 0.02; 1; 1; 1; 0.4];
delayNs = (-2:3).';
[peakIdx, peakDelay, peakPower] = uwbdecoder.locateCirFirstPeak( ...
    powerBar, delayNs, 0);
testCase.verifyEqual(peakIdx, 3);
testCase.verifyEqual(peakDelay, 0);
testCase.verifyEqual(peakPower, 1);
end

function testLeftEndpointIsLocalMax(testCase)
powerBar = [1.0; 0.7; 0.4; 0.2];
delayNs = (0:3).';
[peakIdx, peakDelay, peakPower] = uwbdecoder.locateCirFirstPeak( ...
    powerBar, delayNs, 0);
testCase.verifyEqual(peakIdx, 1);
testCase.verifyEqual(peakDelay, 0);
testCase.verifyEqual(peakPower, 1.0);
end

function testEmptySearchFallsBackToFullAxis(testCase)
powerBar = [0.2; 1.0; 0.3; 0.1];
delayNs = (-3:0).';
[peakIdx, peakDelay, peakPower] = uwbdecoder.locateCirFirstPeak( ...
    powerBar, delayNs, 10);
testCase.verifyEqual(peakIdx, 2);
testCase.verifyEqual(peakDelay, -2);
testCase.verifyEqual(peakPower, 1.0);
end

function testFirstLocalMaxIsNotGlobalMax(testCase)
powerBar = [0.05; 0.35; 1.0; 0.4; 0.2; 2.0; 0.5];
delayNs = (-1:5).';
[peakIdx, ~, peakPower] = uwbdecoder.locateCirFirstPeak( ...
    powerBar, delayNs, 0);
testCase.verifyEqual(peakIdx, 3);
testCase.verifyEqual(peakPower, 1.0);
testCase.verifyNotEqual(peakPower, max(powerBar));
end
