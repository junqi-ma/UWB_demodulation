function plotDespreadCir(cir, params)
%PLOTDESPREADCIR Visualize individual and coherently averaged CIRs.
individual_magnitude = abs(cir.individual_values);
individual_magnitude = individual_magnitude./ ...
    (max(individual_magnitude, [], 1)+eps);
magnitude = abs(cir.values)/(max(abs(cir.values))+eps);
magnitude_db = 20*log10(max(magnitude, 1e-3));
figure('Name', 'Spreading-code-despread CIR', 'Color', 'w');
subplot(2, 1, 1);
h_individual = plot(cir.delay_ns, individual_magnitude, ...
    'Color', [0.75 0.75 0.75]);
set(h_individual(2:end), 'HandleVisibility', 'off'); hold on;
h_average = plot(cir.delay_ns, magnitude, 'r', 'LineWidth', 1.8);
xline(0, 'k--', 'Nominal code-correlation peak', 'HandleVisibility', 'off');
grid on; xlabel('Relative delay (ns)'); ylabel('Normalized magnitude');
title(sprintf('Code %d despread CIR: %d repetitions', ...
    params.code_index, cir.repetition_count));
legend([h_individual(1), h_average], 'Individual repetitions', ...
    'Coherent average', 'Location', 'best');
subplot(2, 1, 2);
plot(cir.delay_ns, magnitude_db, 'b', 'LineWidth', 1.5); xline(0, 'k--');
grid on; ylim([-60 2]); xlabel('Relative delay (ns)');
ylabel('Normalized CIR magnitude (dB)');
title('Coherently averaged spreading-code-despread CIR');
end
