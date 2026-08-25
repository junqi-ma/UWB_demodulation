%% Plot the basic UWB SIC principle with a self-contained simulation.
%
% The figure follows the signal flow in the slide:
%   a_k -> s(t) -> y(t) -> h(t) / decoded a_k -> reconstructed y_hat(t)
%
% A second, weaker UWB waveform is mixed into the received signal so that
% the final panel also shows the SIC operation:
%   residual(t) = y(t) - reconstructed_y(t)
%
% The script is intentionally independent of the capture files in this
% repository. It is meant to generate a clean, repeatable illustration for
% a presentation, while keeping the model close to the block diagram.

clearvars;
close all;
clc;
rng(7, 'twister');

%% ------------------------- User configuration -------------------------
cfg.num_symbols = 16;
cfg.symbol_rate = 250e6;       % 250 Mbaud -> Ts = 4 ns
cfg.fs = 40e9;                 % 25 ps sample interval
cfg.interferer_gain = 0.32;    % weaker overlapping UWB component
cfg.noise_rms_ratio = 0.045;   % relative to the dominant received signal
cfg.figure_dpi = 220;
cfg.save_figure = true;

% Use a slide-friendly wide figure. Set to false if you only want the MATLAB
% figure window and do not want files written to decoded_results/.

%% ------------------------- Waveform generation ------------------------
cfg.samples_per_symbol = round(cfg.fs / cfg.symbol_rate);
cfg.dt = 1 / cfg.fs;
cfg.guard_samples = 2 * cfg.samples_per_symbol;
cfg.num_samples = cfg.guard_samples + ...
    cfg.num_symbols * cfg.samples_per_symbol + cfg.guard_samples;
cfg.time_ns = (0:cfg.num_samples - 1) * cfg.dt * 1e9;

% BPSK symbol sequence. A second sequence is used only to make the SIC
% effect visible in the received waveform.
a = [1 -1 1 1 -1 1 -1 -1 1 -1 1 1 1 -1 -1 1];
b = [1 1 -1 1 -1 -1 1 -1 1 1 -1 -1 1 -1 1 -1];

% A normalized Gaussian monocycle is a compact UWB pulse model.
pulse_sigma = 0.32e-9;
pulse_half_width = 1.20e-9;
pulse_time = -pulse_half_width:cfg.dt:pulse_half_width;
pulse = -(pulse_time / pulse_sigma^2) .* ...
    exp(-(pulse_time.^2) / (2 * pulse_sigma^2));
pulse = pulse / max(abs(pulse));
pulse_half_samples = floor(numel(pulse) / 2);

% Dominant component: s(t) = p(t) a_k.
tx = makeUwbPulseTrain(a, pulse, cfg.samples_per_symbol, ...
    cfg.num_samples, cfg.guard_samples);

% Estimated channel and true channel. The small mismatch makes the
% reconstruction realistic without obscuring the principle.
tap_delays = [0 12 34];
tap_values = [1.00 0.45 -0.22];
channel = zeros(1, max(tap_delays) + 1);
channel(tap_delays + 1) = tap_values;

channel_est = zeros(size(channel));
channel_est(tap_delays + 1) = tap_values .* [0.98 1.06 0.88];

% Overlapping weaker component, with a slightly different multipath shape.
interferer_delay = round(0.42 * cfg.samples_per_symbol);
tx_interferer = makeUwbPulseTrain(b, pulse, cfg.samples_per_symbol, ...
    cfg.num_samples, cfg.guard_samples + interferer_delay);
interferer_channel = zeros(1, 44);
interferer_channel([1 19 42]) = [1.00 -0.30 0.16];

rx_dominant = filter(channel, 1, tx);
rx_interferer = cfg.interferer_gain * ...
    filter(interferer_channel, 1, tx_interferer);
noise_rms = cfg.noise_rms_ratio * sqrt(mean(rx_dominant.^2));
noise = noise_rms * randn(size(rx_dominant));
rx_mixed = rx_dominant + rx_interferer + noise;

%% ----------------------- Channel estimation and decoding --------------
% Correlate each symbol interval with the estimated channel-shaped pulse.
% This is a compact matched-filter decoder for the teaching illustration.
estimated_pulse_response = filter(channel_est, 1, pulse);
metric = zeros(1, cfg.num_symbols);
template_energy = sum(estimated_pulse_response.^2);

symbol_centers = cfg.guard_samples + ...
    round((0:cfg.num_symbols - 1) * cfg.samples_per_symbol + ...
    cfg.samples_per_symbol / 2) + 1;

for k = 1:cfg.num_symbols
    pulse_start = symbol_centers(k) - pulse_half_samples;
    pulse_stop = pulse_start + numel(estimated_pulse_response) - 1;
    sample_idx = pulse_start:pulse_stop;

    % The guard interval keeps all matched-filter windows in range.
    metric(k) = sum(rx_mixed(sample_idx) .* estimated_pulse_response) / ...
        template_energy;
end

decoded_symbols = ones(size(metric));
decoded_symbols(metric < 0) = -1;

% Reconstruct the decoded dominant component and subtract it from the
% received mixture: this is the SIC step shown in the last panel.
tx_reconstructed = makeUwbPulseTrain(decoded_symbols, pulse, ...
    cfg.samples_per_symbol, cfg.num_samples, cfg.guard_samples);
reconstructed_rx = filter(channel_est, 1, tx_reconstructed);
sic_residual = rx_mixed - reconstructed_rx;

symbol_errors = nnz(decoded_symbols ~= a);
ber = symbol_errors / cfg.num_symbols;
target_cancellation_db = 10 * log10( ...
    mean(rx_dominant.^2) / ...
    (mean((rx_dominant - reconstructed_rx).^2) + eps));

%% ------------------------------ Plot ----------------------------------
fig = figure('Name', 'UWB SIC principle', ...
    'Color', 'w', 'Position', [50 50 1600 920]);
layout = tiledlayout(fig, 3, 3, ...
    'TileSpacing', 'compact', 'Padding', 'compact');
title(layout, 'UWB SIC principle: estimate, decode, reconstruct, cancel', ...
    'FontSize', 20, 'FontWeight', 'bold');

blue = [0.08 0.35 0.75];
red = [0.86 0.22 0.16];
green = [0.10 0.55 0.32];
purple = [0.45 0.22 0.68];
gray = [0.25 0.28 0.33];

% 1. Symbol sequence a_k
ax1 = nexttile(layout, 1);
stem(ax1, 1:cfg.num_symbols, a, 'filled', ...
    'Color', blue, 'MarkerFaceColor', blue, 'LineWidth', 1.3);
hold(ax1, 'on');
yline(ax1, 0, 'Color', [0.75 0.75 0.75]);
ylim(ax1, [-1.35 1.35]);
xlim(ax1, [0.5 cfg.num_symbols + 0.5]);
grid(ax1, 'on');
title(ax1, 'Symbol sequence  $a_k$', 'Interpreter', 'latex');
xlabel(ax1, 'Symbol index $k$', 'Interpreter', 'latex');
ylabel(ax1, 'BPSK symbol');

% 2. TX signal s(t) = p(t) a_k
ax2 = nexttile(layout, 2);
plot(ax2, cfg.time_ns, tx, 'Color', red, 'LineWidth', 1.0);
decorateTimeAxis(ax2, cfg.time_ns, 'TX signal  $s(t)=p(t)a_k$', ...
    'Amplitude', red);

% 3. RX signal y(t) = desired + interference + noise
ax3 = nexttile(layout, 3);
plot(ax3, cfg.time_ns, rx_mixed, 'Color', gray, 'LineWidth', 0.75);
hold(ax3, 'on');
plot(ax3, cfg.time_ns, rx_dominant, 'Color', blue, 'LineWidth', 0.85);
decorateTimeAxis(ax3, cfg.time_ns, 'RX signal  $y(t)$', ...
    'Amplitude', gray);
legend(ax3, {'Mixed $y(t)$', 'Dominant component'}, ...
    'Interpreter', 'latex', 'Location', 'northeast', 'FontSize', 8);

% 4. Channel response h(t)
ax4 = nexttile(layout, 4);
channel_time_ns = (0:numel(channel) - 1) * cfg.dt * 1e9;
stem(ax4, channel_time_ns, channel, 'filled', ...
    'Color', blue, 'MarkerFaceColor', blue, 'LineWidth', 1.1);
hold(ax4, 'on');
stem(ax4, channel_time_ns, channel_est, 'Color', purple, ...
    'LineStyle', '--', 'Marker', 'o', 'LineWidth', 1.0);
grid(ax4, 'on');
xlim(ax4, [0 max(channel_time_ns) + 0.2]);
title(ax4, 'Channel response  $h(t)$', 'Interpreter', 'latex');
xlabel(ax4, 'Delay (ns)');
ylabel(ax4, 'Tap amplitude');
legend(ax4, {'True $h(t)$', 'Estimated $\hat h(t)$'}, ...
    'Interpreter', 'latex', 'Location', 'northeast', 'FontSize', 8);

% 5. Decoded symbols \hat{a}_k
ax5 = nexttile(layout, 5);
stem(ax5, 1:cfg.num_symbols, a, 'filled', ...
    'Color', [0.65 0.65 0.65], 'MarkerFaceColor', [0.65 0.65 0.65], ...
    'LineWidth', 1.0);
hold(ax5, 'on');
stem(ax5, 1:cfg.num_symbols, decoded_symbols, 'filled', ...
    'Color', green, 'MarkerFaceColor', green, 'LineWidth', 1.3);
bad = decoded_symbols ~= a;
if any(bad)
    scatter(ax5, find(bad), decoded_symbols(bad), 48, red, 'filled');
end
yline(ax5, 0, 'Color', [0.75 0.75 0.75]);
ylim(ax5, [-1.35 1.35]);
xlim(ax5, [0.5 cfg.num_symbols + 0.5]);
grid(ax5, 'on');
title(ax5, sprintf('Decoded symbols  $\\hat a_k$  (BER = %.3f)', ber), ...
    'Interpreter', 'latex');
xlabel(ax5, 'Symbol index $k$', 'Interpreter', 'latex');
ylabel(ax5, 'Decision');
legend(ax5, {'Original $a_k$', 'Decoded $\hat a_k$'}, ...
    'Interpreter', 'latex', 'Location', 'southeast', 'FontSize', 8);

% 6. Reconstructed RX signal \hat{y}(t) = \hat{h}(t) * p(t) \hat{a}_k
ax6 = nexttile(layout, 6);
plot(ax6, cfg.time_ns, rx_dominant, 'Color', blue, 'LineWidth', 0.85);
hold(ax6, 'on');
plot(ax6, cfg.time_ns, reconstructed_rx, '--', ...
    'Color', purple, 'LineWidth', 1.0);
decorateTimeAxis(ax6, cfg.time_ns, ...
    'Reconstructed RX  $\hat y(t)=\hat h(t)*p(t)\hat a_k$', ...
    'Amplitude', purple);
legend(ax6, {'Original dominant RX', 'Reconstructed $\hat y(t)$'}, ...
    'Interpreter', 'latex', 'Location', 'northeast', 'FontSize', 8);

% 7. SIC residual: y(t) - \hat{y}(t)
ax7 = nexttile(layout, [1 3]);
plot(ax7, cfg.time_ns, rx_mixed, 'Color', [0.70 0.70 0.70], ...
    'LineWidth', 0.65);
hold(ax7, 'on');
plot(ax7, cfg.time_ns, reconstructed_rx, '--', ...
    'Color', purple, 'LineWidth', 0.9);
plot(ax7, cfg.time_ns, sic_residual, 'Color', green, 'LineWidth', 0.85);
decorateTimeAxis(ax7, cfg.time_ns, ...
    'SIC output:  $r(t)=y(t)-\hat y(t)$', 'Amplitude', green);
legend(ax7, {'Before cancellation $y(t)$', ...
    'Reconstructed component $\hat y(t)$', 'Residual $r(t)$'}, ...
    'Interpreter', 'latex', 'Location', 'northeast', 'FontSize', 9);
text(ax7, 0.015, 0.90, sprintf('Target cancellation: %.1f dB', ...
    target_cancellation_db), 'Units', 'normalized', ...
    'Color', green, 'FontWeight', 'bold', 'FontSize', 10);

% Common font/line settings for a clean slide export.
set(findall(fig, '-property', 'FontName'), 'FontName', 'Arial');
set(findall(fig, '-property', 'FontSize'), 'FontSize', 10);
set(findall(fig, 'Type', 'axes'), 'LineWidth', 0.8);

%% ------------------------------ Save ----------------------------------
if cfg.save_figure
    this_file = mfilename('fullpath');
    if isempty(this_file)
        project_dir = pwd;
    else
        project_dir = fileparts(this_file);
    end
    output_dir = fullfile(project_dir, 'decoded_results', 'uwb_sic_principle');
    if ~isfolder(output_dir)
        mkdir(output_dir);
    end

    png_file = fullfile(output_dir, 'uwb_sic_principle_story.png');
    fig_file = fullfile(output_dir, 'uwb_sic_principle_story.fig');
    if exist('exportgraphics', 'file') == 2
        exportgraphics(fig, png_file, 'Resolution', cfg.figure_dpi);
    else
        print(fig, png_file, '-dpng', sprintf('-r%d', cfg.figure_dpi));
    end
    savefig(fig, fig_file);
    fprintf('Saved slide figure: %s\n', png_file);
    fprintf('Saved editable MATLAB figure: %s\n', fig_file);
end

fprintf('\nUWB SIC illustration summary\n');
fprintf('Symbols              : %d\n', cfg.num_symbols);
fprintf('Samples/symbol       : %d\n', cfg.samples_per_symbol);
fprintf('Decoded symbol errors: %d / %d\n', symbol_errors, cfg.num_symbols);
fprintf('Target cancellation  : %.2f dB\n', target_cancellation_db);

%% -------------------------- Local functions ---------------------------
function waveform = makeUwbPulseTrain(symbols, pulse, samples_per_symbol, ...
        num_samples, first_symbol_offset)
%makeUwbPulseTrain Place one UWB pulse at the center of each symbol period.

    waveform = zeros(1, num_samples);
    half_pulse = floor(numel(pulse) / 2);
    first_center = first_symbol_offset + ...
        round(samples_per_symbol / 2) + 1;

    for symbol_index = 1:numel(symbols)
        center = first_center + (symbol_index - 1) * samples_per_symbol;
        sample_index = center - half_pulse:center + half_pulse;
        valid = sample_index >= 1 & sample_index <= num_samples;
        waveform(sample_index(valid)) = waveform(sample_index(valid)) + ...
            symbols(symbol_index) * pulse(valid);
    end
end

function decorateTimeAxis(ax, time_ns, plot_title, y_label, plot_color)
%decorateTimeAxis Apply shared formatting to waveform axes.

    grid(ax, 'on');
    xlim(ax, [time_ns(1) time_ns(end)]);
    title(ax, plot_title, 'Interpreter', 'latex');
    xlabel(ax, 'Time (ns)');
    ylabel(ax, y_label);
    ax.GridAlpha = 0.18;
    ax.Color = [0.99 0.99 0.99];
    if nargin >= 5
        ax.YColor = plot_color;
    end
end
