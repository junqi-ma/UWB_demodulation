function diagnostics = plot_uwb_estimated_cir(cir, output_png, show_figure)
%PLOT_QM35_ESTIMATED_CIR Plot averaged and per-repetition QM35 CIR details.

if nargin < 2
    output_png = '';
end
if nargin < 3
    show_figure = true;
end
if ~isstruct(cir) || ~isfield(cir, 'values') || ...
        ~isfield(cir, 'delay_ns')
    error('plot_uwb_estimated_cir:InvalidCir', ...
        'CIR must contain values and delay_ns.');
end

h = cir.values(:);
delay_ns = cir.delay_ns(:);
magnitude = abs(h);
magnitude_normalized = magnitude/(max(magnitude)+eps);
magnitude_db = 20*log10(max(magnitude_normalized, 1e-4));
power = magnitude.^2/(sum(magnitude.^2)+eps);
mean_delay_ns = sum(power.*delay_ns);
rms_delay_ns = sqrt(sum(power.*(delay_ns-mean_delay_ns).^2));
[peak_magnitude, peak_index] = max(magnitude);
peak_delay_ns = delay_ns(peak_index);

diagnostics = struct('peak_index', peak_index, ...
    'peak_delay_ns', peak_delay_ns, 'peak_magnitude', peak_magnitude, ...
    'mean_delay_ns', mean_delay_ns, 'rms_delay_ns', rms_delay_ns, ...
    'tap_count', numel(h), 'repetition_count', cir.repetition_count);

if show_figure
    visibility = 'on';
else
    visibility = 'off';
end
fig = figure('Name', 'QM35 estimated CIR diagnostics', ...
    'Color', 'w', 'Visible', visibility, 'Position', [70 70 1180 820]);

subplot(2, 2, 1);
if isfield(cir, 'individual_values') && ~isempty(cir.individual_values)
    individual = abs(cir.individual_values);
    individual = individual./(max(individual, [], 1)+eps);
    imagesc(delay_ns, 1:size(individual, 2), individual.');
    axis xy;
    colorbar;
    ylabel('Preamble repetition');
    title('Per-repetition normalized CIR magnitude');
else
    text(0.5, 0.5, 'Individual CIR estimates unavailable', ...
        'HorizontalAlignment', 'center');
    axis off;
end
xline(0, 'w--', '0 ns', 'LineWidth', 1.1);
xlabel('Relative delay (ns)');

subplot(2, 2, 2);
stem(delay_ns, magnitude_normalized, 'filled', ...
    'Color', [0.10 0.45 0.85], 'MarkerSize', 4);
hold on;
xline(0, 'k--', 'Nominal zero delay');
plot(peak_delay_ns, 1, 'ro', 'MarkerFaceColor', 'r');
text(peak_delay_ns, 1.04, sprintf('peak %.3f ns', peak_delay_ns), ...
    'HorizontalAlignment', 'center', 'Color', [0.75 0 0]);
grid on;
ylim([0 1.12]);
xlabel('Relative delay (ns)');
ylabel('Normalized magnitude');
title('Coherently averaged CIR');

subplot(2, 2, 3);
plot(delay_ns, real(h), '-o', 'Color', [0.10 0.45 0.85], ...
    'MarkerSize', 3);
hold on;
plot(delay_ns, imag(h), '-s', 'Color', [0.90 0.30 0.12], ...
    'MarkerSize', 3);
xline(0, 'k--');
grid on;
xlabel('Relative delay (ns)');
ylabel('Complex coefficient');
title('Complex CIR coefficients');
legend('Real', 'Imaginary', 'Location', 'best');

subplot(2, 2, 4);
yyaxis left;
stem(delay_ns, magnitude_db, 'filled', 'Color', [0.10 0.45 0.85], ...
    'MarkerSize', 3);
ylabel('Normalized magnitude (dB)');
ylim([-80 5]);
yyaxis right;
phase_deg = rad2deg(angle(h));
valid_phase = magnitude_db >= -30;
plot(delay_ns(valid_phase), phase_deg(valid_phase), 'o-', ...
    'Color', [0.90 0.30 0.12], 'MarkerSize', 4);
ylabel('Phase of taps above -30 dB (deg)');
ylim([-190 190]);
xline(0, 'k--');
grid on;
xlabel('Relative delay (ns)');
title(sprintf('Log magnitude and phase | RMS delay %.3f ns', rms_delay_ns));

sgtitle(sprintf(['QM35 estimated CIR: %d taps, %d coherent repetitions, ', ...
    'strongest tap at %.3f ns'], numel(h), cir.repetition_count, peak_delay_ns));
if ~isempty(output_png)
    exportgraphics(fig, output_png, 'Resolution', 180);
end
if ~show_figure
    close(fig);
end
end
