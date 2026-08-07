function tests = testReadIqRawStrided
%TESTREADIQRAWSTRIDED Verify record-aligned strided capture reads.
tests = functiontests(localfunctions);
end

function testTwoAntennaStride(testCase)
projectDirectory = fileparts(fileparts(mfilename('fullpath')));
addpath(projectDirectory);

recordCount = 20;
antennaCount = 2;
expectedRaw = reshape(1:2*antennaCount*recordCount, ...
    2*antennaCount, recordCount);
fileName = [tempname, '.dat'];
fileGuard = onCleanup(@() deleteIfPresent(fileName));

fid = fopen(fileName, 'wb', 'ieee-le');
testCase.assertGreaterThan(fid, 0);
closeGuard = onCleanup(@() fclose(fid));
written = fwrite(fid, int16(expectedRaw), 'int16');
testCase.verifyEqual(written, numel(expectedRaw));
clear closeGuard;

[actualRaw, sampleIndices] = uwbdecoder.readIqRawStrided( ...
    fileName, 3, 12, antennaCount, 4);
testCase.verifyEqual(sampleIndices, [3; 7; 11]);
testCase.verifyEqual(actualRaw, double(expectedRaw(:, [4, 8, 12])));
clear fileGuard;
end

function testStrideOneMatchesContiguousReader(testCase)
projectDirectory = fileparts(fileparts(mfilename('fullpath')));
addpath(projectDirectory);

expectedRaw = reshape(-30:29, 2, 30);
fileName = [tempname, '.dat'];
fileGuard = onCleanup(@() deleteIfPresent(fileName));

fid = fopen(fileName, 'wb', 'ieee-le');
testCase.assertGreaterThan(fid, 0);
closeGuard = onCleanup(@() fclose(fid));
fwrite(fid, int16(expectedRaw), 'int16');
clear closeGuard;

contiguous = uwbdecoder.readIqRaw(fileName, 5, 10, 1);
[strided, sampleIndices] = uwbdecoder.readIqRawStrided( ...
    fileName, 5, 10, 1, 1);
testCase.verifyEqual(strided, contiguous);
testCase.verifyEqual(sampleIndices, (5:14).');
clear fileGuard;
end

function testSinglePrecisionOutput(testCase)
projectDirectory = fileparts(fileparts(mfilename('fullpath')));
addpath(projectDirectory);

expectedRaw = reshape(-20:19, 2, 20);
fileName = [tempname, '.dat'];
fileGuard = onCleanup(@() deleteIfPresent(fileName));

fid = fopen(fileName, 'wb', 'ieee-le');
testCase.assertGreaterThan(fid, 0);
closeGuard = onCleanup(@() fclose(fid));
fwrite(fid, int16(expectedRaw), 'int16');
clear closeGuard;

[strided, sampleIndices] = uwbdecoder.readIqRawStrided( ...
    fileName, 2, 8, 1, 2, 'single');
contiguous = uwbdecoder.readIqRaw(fileName, 2, 8, 1, 'single');
testCase.verifyClass(strided, 'single');
testCase.verifyClass(contiguous, 'single');
testCase.verifyEqual(strided, single(expectedRaw(:, [3, 5, 7, 9])));
testCase.verifyEqual(contiguous, single(expectedRaw(:, 3:10)));
testCase.verifyEqual(sampleIndices, [2; 4; 6; 8]);
testCase.verifyClass(uwbdecoder.selectIqChannel(strided, 1), 'single');
clear fileGuard;
end

function testFftFilterAcceptsSingleInput(testCase)
rng(7);
filterTaps = complex(randn(73, 1), randn(73, 1));
signal = complex(randn(1000, 1), randn(1000, 1));
expected = fftfilt(filterTaps, signal);
actual = uwbdecoder.fftFilter(single(filterTaps), single(signal));

testCase.verifyClass(actual, 'double');
testCase.verifyEqual(actual, ...
    fftfilt(double(single(filterTaps)), double(single(signal))), ...
    'AbsTol', 1e-12);
testCase.verifyLessThan(norm(actual - expected)/norm(expected), 1e-6);
end

function deleteIfPresent(fileName)
if isfile(fileName)
    delete(fileName);
end
end
