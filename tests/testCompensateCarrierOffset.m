function tests = testCompensateCarrierOffset
%TESTCOMPENSATECARRIEROFFSET Direct-SFD CFO uses code-grid shaping delay.
tests = functiontests(localfunctions);
end

function setupOnce(testCase)
projectDirectory = fileparts(fileparts(mfilename('fullpath')));
addpath(projectDirectory);
testCase.TestData.projectDirectory = projectDirectory;
end

function testShapingDelayFollowsFirstChipPeak(testCase)
delays = [1, 2, 3];
for k = 1:numel(delays)
    [reference, ~] = syntheticShapedReference(delays(k));
    [rx, preamble, params, trueCfo] = syntheticDirectFrame( ...
        reference, delays(k), -1747);
    [~, preambleOut] = uwbdecoder.compensateCarrierOffset( ...
        rx, preamble, reference, params);
    testCase.verifyEqual( ...
        preambleOut.frequency_offset_shaping_delay_samples, delays(k));
    testCase.verifyEqual(preambleOut.frequency_offset_hz, trueCfo, ...
        'AbsTol', 25);
end
end

function testUnshapedReferenceKeepsZeroDelay(testCase)
[reference, ~] = syntheticShapedReference(0);
[rx, preamble, params, trueCfo] = syntheticDirectFrame( ...
    reference, 0, 2130);
[~, preambleOut] = uwbdecoder.compensateCarrierOffset( ...
    rx, preamble, reference, params);
testCase.verifyEqual(preambleOut.frequency_offset_shaping_delay_samples, 0);
testCase.verifyEqual(preambleOut.frequency_offset_hz, trueCfo, 'AbsTol', 25);
end

function testWaveformAlignedSeedDoesNotApplyShapingDelay(testCase)
delaySamples = 2;
[reference, ~] = syntheticShapedReference(delaySamples);
[rx, preamble, params, trueCfo] = syntheticDirectFrame( ...
    reference, 0, -1747);
preamble = rmfield(preamble, 'sfd_waveform_correlation');
[~, preambleOut] = uwbdecoder.compensateCarrierOffset( ...
    rx, preamble, reference, params);
testCase.verifyEqual(preambleOut.frequency_offset_shaping_delay_samples, 0);
testCase.verifyEqual(preambleOut.frequency_offset_hz, trueCfo, 'AbsTol', 25);
end

function testPhyReferencesShareTheSameShapingDelay(testCase)
codes = [9, 10, 11];
delays = zeros(size(codes));
for k = 1:numel(codes)
    opt = struct('fs_rx', 998.4e6, 'data_rate', 6.81, ...
        'preamble_repetitions', 64, 'code_index', codes(k), ...
        'sfd_mode', 'decawave', 'show_plots', false);
    params = uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), opt);
    reference = uwbdecoder.buildUwbReference(params);
    [rx, preamble, cfoParams, trueCfo] = syntheticDirectFrame( ...
        reference, [], -1800);
    [~, preambleOut] = uwbdecoder.compensateCarrierOffset( ...
        rx, preamble, reference, cfoParams);
    delays(k) = preambleOut.frequency_offset_shaping_delay_samples;
    testCase.verifyGreaterThan(delays(k), 0);
    testCase.verifyEqual(preambleOut.frequency_offset_hz, trueCfo, ...
        'AbsTol', 40);
end
testCase.verifyEqual(delays, delays(1)*ones(size(delays)));
end

function [reference, pulse] = syntheticShapedReference(delaySamples)
symbolLength = 64;
fs = 998.4e6;
code = zeros(symbolLength, 1);
code(1:8:end) = 1;
pulse = [zeros(delaySamples, 1); 1; 0.4; 0.1];
wave = conv(code, pulse);
wave = wave(1:symbolLength);
wave = wave / (norm(wave) + eps);
reference = struct( ...
    'fs', fs, ...
    'samples_per_symbol', symbolLength, ...
    'preamble_waveform', wave, ...
    'sampled_code', code);
end

function [rx, preamble, params, trueCfo] = syntheticDirectFrame( ...
        reference, shapingDelay, trueCfo)
if nargin < 2 || isempty(shapingDelay)
    shapingDelay = firstChipDelay(reference);
end
if nargin < 3 || isempty(trueCfo)
    trueCfo = -1747;
end
repetitions = 64;
symbolLength = reference.samples_per_symbol;
wave = reference.preamble_waveform(:);
origin = 80;
rx = complex(zeros(origin + repetitions*symbolLength + 200, 1));
for repetition = 0:repetitions-1
    idx = origin + repetition*symbolLength + (0:symbolLength-1);
    rx(idx) = rx(idx) + wave;
end
n = (0:numel(rx)-1).';
rx = rx .* exp(1j*2*pi*trueCfo*n/reference.fs);

preamble = struct( ...
    'direct_sfd_timing', true, ...
    'detected_repetitions', repetitions, ...
    'measured_period', double(symbolLength), ...
    'start_sample', origin + shapingDelay, ...
    'sfd_waveform_correlation', 0.9, ...
    'peaks', origin + shapingDelay + (1:repetitions).'*symbolLength - 1);
params = struct('preamble_repetitions', repetitions, 'verbose', false);
end

function delay = firstChipDelay(reference)
code = reference.sampled_code(:);
wave = reference.preamble_waveform(:);
impulse = find(abs(code) > 0, 1);
nextRel = find(abs(code(impulse+1:end)) > 0, 1);
last = min(numel(wave), impulse + nextRel - 1);
[~, rel] = max(abs(wave(impulse:last)));
delay = rel - 1;
end
