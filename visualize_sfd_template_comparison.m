%% Compare full-rate SFD correlation: shaped waveform vs. sampled code
% The two references use the same SFD symbol sequence and search interval:
%   1) kron(SFD, preamble_waveform): transmit pulse-shaped template.
%   2) kron(SFD, sampled_code):     unshaped spreading code on the HRP
%                                    pulse grid.
% The plot is generated after preamble detection, frame cropping, and CFO
% compensation, so the only intentional difference is the SFD template.

clear;
close all;
clc;

%% -------------------- Capture and PHY configuration --------------------
options = struct();
options.file_name = 'F:\UWB基带数据\dw1000_new_processed_1.dat';
options.sample_offset = 0;
options.sample_num = 1.5e6;
options.ant_num = 1;
options.channel_index = 1;
options.fs_rx = 998.4e6;ha
options.preamble_repetitions = 128;
options.cir_repetitions = 64;
options.cir_pre_samples = 8;
options.cir_post_samples = 64;
options.code_index = 11;
options.data_rate = 6.81;
options.show_plots = false;
options.verbose = false;

% Select one known SFD sequence. Change this and the sequence assignment
% below when comparing another SFD type; both templates always use exactly
% this same sequence.
target_sfd_name = 'Decawave DW-8';
options.sfd_mode = 'decawave';

save_figure = false;
output_file = fullfile(pwd, 'decoded_results', ...
    'sfd_template_comparison.png');

params = uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), options);
addpath(params.helper_path);
reference = uwbdecoder.buildUwbReference(params);
if abs(params.fs_rx - reference.fs) > 1
    error('visualize_sfd_template_comparison:SampleRateMismatch', ...
        'Input must use the %.3f MHz HRP work rate.', reference.fs/1e6);
end

switch options.sfd_mode
    case 'decawave'
        sfd_sequence = params.decawave_sfd(:);
    case 'ieee'
        sfd_sequence = params.ieee_sfd(:);
    case '4z1'
        sfd_sequence = params.sfd4z_1(:);
    case '4z2'
        sfd_sequence = params.sfd4z_2(:);
    case '4z3'
        sfd_sequence = params.sfd4z_3(:);
    case '4z4'
        sfd_sequence = params.sfd4z_4(:);
    otherwise
        error('visualize_sfd_template_comparison:ExplicitSfdRequired', ...
            'Set options.sfd_mode to one explicit SFD type, not auto.');
end

%% -------------------- Shared receive preprocessing ---------------------
raw = uwbdecoder.readIqRaw(params.file_name, params.sample_offset, ...
    params.sample_num, params.ant_num);
rx = uwbdecoder.selectIqChannel(raw, params.channel_index);
preamble = uwbdecoder.detectRepeatedPreamble(rx, reference, params);
uwbdecoder.validateCaptureLength(rx, preamble, reference, params);

if params.enable_frame_crop
    [rx, preamble] = uwbdecoder.cropToFrame(rx, preamble, reference, params);
end
[rx, preamble] = uwbdecoder.compensateCarrierOffset( ...
    rx, preamble, reference, params);

expected_start = preamble.start_sample + round( ...
    params.preamble_repetitions*preamble.measured_period);

%% -------------------- Correlate the two SFD templates ------------------
shaped_reference = kron(sfd_sequence, reference.preamble_waveform(:));
code_reference = kron(sfd_sequence, reference.sampled_code(:));

[sample_shaped, corr_shaped] = normalizedSfdCorrelation( ...
    rx, expected_start, reference.samples_per_symbol, shaped_reference);
[sample_code, corr_code] = normalizedSfdCorrelation( ...
    rx, expected_start, reference.samples_per_symbol, code_reference);

[peak_shaped, index_shaped] = max(corr_shaped);
[peak_code, index_code] = max(corr_code);
peak_sample_shaped = sample_shaped(index_shaped);
peak_sample_code = sample_code(index_code);

fprintf('\n========== SFD template correlation comparison ==========\n');
fprintf('SFD sequence                 : %s\n', target_sfd_name);
fprintf('Expected SFD start           : %d work samples\n', expected_start);
fprintf('Shaped waveform peak         : %.12f at %+d samples\n', ...
    peak_shaped, peak_sample_shaped - expected_start);
fprintf('Unshaped sampled-code peak   : %.12f at %+d samples\n', ...
    peak_code, peak_sample_code - expected_start);
fprintf('Code / shaped peak ratio     : %.4f (%.2f%%)\n', ...
    peak_code/max(peak_shaped, eps), 100*peak_code/max(peak_shaped, eps));
fprintf('===========================================================\n');

%% -------------------- Plot normalized correlation waveforms ------------
figure('Color', 'w', 'Name', 'SFD template correlation comparison');
hold on;
plot(sample_shaped - expected_start, corr_shaped, 'LineWidth', 1.3, ...
    'DisplayName', 'Pulse-shaped preamble waveform');
plot(sample_code - expected_start, corr_code, '--', 'LineWidth', 1.3, ...
    'DisplayName', 'Unshaped sampled spreading code');
xline(peak_sample_shaped - expected_start, ':', 'Color', [0 0.45 0.74], ...
    'HandleVisibility', 'off');
xline(peak_sample_code - expected_start, ':', 'Color', [0.85 0.33 0.10], ...
    'HandleVisibility', 'off');
grid on;
xlabel('SFD template start relative to expected start (samples)');
ylabel('Normalized matched-filter magnitude');
title(sprintf('%s: full-rate SFD correlation', target_sfd_name));
legend('Location', 'best');

if save_figure
    output_directory = fileparts(output_file);
    if ~isfolder(output_directory), mkdir(output_directory); end
    exportgraphics(gcf, output_file, 'Resolution', 160);
    fprintf('Saved figure: %s\n', output_file);
end

function [startSamples, score] = normalizedSfdCorrelation( ...
        rx, expectedStart, searchHalfWidth, template)
%NORMALIZEDSFDCORRELATION Match a full-rate SFD template in the decoder ROI.
template = template(:);
template = template/(norm(template) + eps);
searchStart = max(1, expectedStart - searchHalfWidth);
searchEnd = min(numel(rx), expectedStart + searchHalfWidth + ...
    numel(template) - 1);
searchSignal = rx(searchStart:searchEnd);
matched = uwbdecoder.fftFilter(flipud(conj(template)), searchSignal);
energy = sqrt(movsum(abs(searchSignal).^2, [numel(template)-1, 0]));
validEnds = numel(template):numel(searchSignal);
score = abs(matched(validEnds))./(energy(validEnds) + eps);
startSamples = searchStart + validEnds(:) - numel(template);
score = score(:);
end
