function plotSfdDetection(sfd)
%PLOTSFDDETECTION Visualize the local selected-SFD search metric.
%   PLOTSFDDETECTION(SFD) plots the normalized SFD correlation metric
%   over the search window with the detected peak marked.
%
%   See also LOCATENSSFD.

figure('Name', 'DW1000 SFD detection', 'Color', 'w');
indices = (sfd.search_start:sfd.search_end).';
plot(indices, sfd.metric); hold on;
plot(sfd.start_chip, sfd.metric(sfd.local_index), 'ro');
grid on; xlabel('Chip index relative to detected preamble');
ylabel('Normalized SFD correlation');
title(sprintf('%s search after the preamble', sfd.name));
end
