function plotDespreadCir(cir, params)
%PLOTDESPREADCIR Visualize individual and coherently averaged CIRs.
%   PLOTDESPREADCIR(CIR, PARAMS) plots the per-repetition and coherently
%   averaged despread CIR in linear and dB scales.
%
%   See also ESTIMATECIRANDSOFTCHIPS.

individualMagnitude = abs(cir.individual_values);
individualMagnitude = individualMagnitude ./ ...
    (max(individualMagnitude, [], 1) + eps);
magnitude = abs(cir.values) / (max(abs(cir.values)) + eps);
magnitudeDb = 20*log10(max(magnitude, 1e-3));

figure('Name', 'Spreading-code-despread CIR', 'Color', 'w');
subplot(2, 1, 1);
hIndividual = plot(cir.delay_ns, individualMagnitude, ...
    'Color', [0.75 0.75 0.75]);
set(hIndividual(2:end), 'HandleVisibility', 'off'); hold on;
hAverage = plot(cir.delay_ns, magnitude, 'r', 'LineWidth', 1.8);
xline(0, 'k--', 'Nominal code-correlation peak', 'HandleVisibility', 'off');
grid on; xlabel('Relative delay (ns)'); ylabel('Normalized magnitude');
title(sprintf('Code %d despread CIR: %d repetitions', ...
    params.code_index, cir.repetition_count));
legend([hIndividual(1), hAverage], 'Individual repetitions', ...
    'Coherent average', 'Location', 'best');

subplot(2, 1, 2);
plot(cir.delay_ns, magnitudeDb, 'b', 'LineWidth', 1.5); xline(0, 'k--');
grid on; ylim([-60 2]); xlabel('Relative delay (ns)');
ylabel('Normalized CIR magnitude (dB)');
title('Coherently averaged spreading-code-despread CIR');
end
