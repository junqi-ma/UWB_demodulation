%% Visualize the HRP UWB preamble code-9 pattern.
% The preamble contains 256 identical SYNC repetitions. This script shows
% the ternary code itself, its sparse placement in one 1016-chip SYNC, the
% shaped single-SYNC waveform, and the repetition structure.
clear;
close all;
clc;

this_dir = fileparts(mfilename('fullpath'));
if isempty(this_dir)
    this_dir = pwd;
end
addpath(this_dir);

%% -------------------- User parameters --------------------
code_index = 9;
preamble_repetitions = 256;
display_repetitions = 8;
save_figure = true;

%% -------------------- Build the project reference --------------------
options = struct( ...
    'fs_rx', 998.4e6, ...
    'data_rate', 6.81, ...
    'preamble_repetitions', preamble_repetitions, ...
    'code_index', code_index, ...
    'sfd_mode', '4z2', ...
    'show_plots', false);
params = uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), options);
reference = uwbdecoder.buildUwbReference(params);

% HRPCode is the base ternary sequence (its elements may be -1, 0, or +1).
% The spreading factor inserts additional zeros between adjacent elements;
% SamplesPerPulse then maps that chip pattern to the waveform sample grid.
ternary_code = double(lrwpan.internal.HRPCodes(code_index));
ternary_code = ternary_code(:);
spreading_factor = double(reference.cfg.PreambleSpreadingFactor);
samples_per_pulse = double(reference.cfg.SamplesPerPulse);
sync_chip_pattern = double(reference.spread_code(:));
sync_sampled_pattern = double(reference.sampled_code(:));
chips_per_sync = numel(sync_chip_pattern);
samples_per_sync = numel(sync_sampled_pattern);

sync_waveform = reference.preamble_waveform(:);
sync_time_ns = (0:numel(sync_waveform)-1).' / reference.fs * 1e9;
shown_repetitions = min(display_repetitions, preamble_repetitions);
repeated_pattern = repmat(sync_sampled_pattern.', shown_repetitions, 1);

%% -------------------- Plot --------------------
fig = figure('Name', 'HRP UWB preamble code 9 pattern', ...
    'Color', 'w', 'Position', [40 40 1500 900]);
tiledlayout(fig, 2, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

nexttile;
stem(0:numel(ternary_code)-1, ternary_code, 'filled', ...
    'MarkerSize', 4, 'LineWidth', 1.0, 'Color', [0.10 0.42 0.82]);
grid on;
xlim([-1, numel(ternary_code)]);
ylim([-1.25, 1.25]);
yticks([-1 0 1]);
xlabel('Code element index');
ylabel('Ternary value');
title(sprintf('Code %d ternary sequence (%d elements)', ...
    code_index, numel(ternary_code)));

nexttile;
stem(0:chips_per_sync-1, sync_chip_pattern, 'Marker', 'none', ...
    'LineWidth', 0.8, 'Color', [0.82 0.28 0.12]);
grid on;
xlim([0, chips_per_sync-1]);
ylim([-1.25, 1.25]);
yticks([-1 0 1]);
xlabel('Chip index in one SYNC');
ylabel('Chip value');
title(sprintf('One %d-chip SYNC, spreading factor %d', ...
    chips_per_sync, spreading_factor));

nexttile;
plot(sync_time_ns, real(sync_waveform), 'LineWidth', 0.9, ...
    'Color', [0.15 0.45 0.85]);
hold on;
if any(abs(imag(sync_waveform)) > 1e-12)
    plot(sync_time_ns, imag(sync_waveform), '--', 'LineWidth', 0.9, ...
        'Color', [0.85 0.25 0.18]);
    legend('I', 'Q', 'Location', 'northeast');
end
grid on;
xlim([sync_time_ns(1), sync_time_ns(end)]);
xlabel('Time within one SYNC (ns)');
ylabel('Normalized amplitude');
title(sprintf('Pulse-shaped single-SYNC waveform (%d samples)', ...
    numel(sync_waveform)));

nexttile;
imagesc(0:samples_per_sync-1, 1:shown_repetitions, repeated_pattern);
axis xy;
clim([-1 1]);
colormap(fig, [0.15 0.35 0.85; 1 1 1; 0.85 0.20 0.12]);
cb = colorbar;
cb.Ticks = [-1 0 1];
xlabel('Pulse-grid sample index in SYNC');
ylabel('SYNC repetition');
title(sprintf('First %d of %d repeated SYNC patterns', ...
    shown_repetitions, preamble_repetitions));

sgtitle(sprintf(['HRP UWB preamble code %d | %d SYNC repetitions | ', ...
    'ternary code repeated identically in every SYNC'], ...
    code_index, preamble_repetitions));

%% -------------------- Console output and optional save --------------------
fprintf('\n=== HRP UWB preamble code pattern ===\n');
fprintf('Code index             : %d\n', code_index);
fprintf('Preamble repetitions   : %d SYNC\n', preamble_repetitions);
fprintf('Ternary code length    : %d\n', numel(ternary_code));
fprintf('Spreading factor       : %d\n', spreading_factor);
fprintf('Chips per SYNC         : %d\n', chips_per_sync);
fprintf('Samples per pulse      : %d\n', samples_per_pulse);
fprintf('Samples per SYNC       : %d\n', samples_per_sync);
fprintf('Ternary sequence       : ');
fprintf('%+d ', ternary_code);
fprintf('\n');

if save_figure
    output_dir = fullfile(this_dir, 'decoded_results', ...
        'uwb_preamble_code_patterns');
    if ~isfolder(output_dir)
        mkdir(output_dir);
    end
    output_png = fullfile(output_dir, ...
        sprintf('uwb_preamble_code%d_pattern.png', code_index));
    exportgraphics(fig, output_png, 'Resolution', 180);
    fprintf('Figure                  : %s\n', output_png);
end
