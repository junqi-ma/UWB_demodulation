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

[actualRaw, sampleIndices] = dw1000decoder.readIqRawStrided( ...
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

contiguous = dw1000decoder.readIqRaw(fileName, 5, 10, 1);
[strided, sampleIndices] = dw1000decoder.readIqRawStrided( ...
    fileName, 5, 10, 1, 1);
testCase.verifyEqual(strided, contiguous);
testCase.verifyEqual(sampleIndices, (5:14).');
clear fileGuard;
end

function deleteIfPresent(fileName)
if isfile(fileName)
    delete(fileName);
end
end
