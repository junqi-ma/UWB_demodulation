function analyze_truncated_split()
m = load(fullfile('decoded_results', 'qm35_dw1000_sensing_1', ...
    'sic_dw1000_removed_qm35_preserved', 'pipeline_manifest.mat'));
r = m.pipeline.packets;
fprintf('min_visible_sync_for_preamble_sic = %g\n', ...
    m.pipeline.config.min_visible_sync_for_preamble_sic);

trunc = find([r.dw_visible_reps] < 256 & string({r.dw_search_class}) == "preamble_only");
attempted = 0; gateRejected = 0; skipped = 0;
for k = 1:numel(trunc)
    ri = r(trunc(k));
    msg = strtrim(string(fieldOrD2(ri.dw_cancel, 'message')));
    if strlength(msg) > 0
        attempted = attempted + 1;
        if contains(msg, 'alignment'), gateRejected = gateRejected + 1; end
        fprintf('pkt %3d vis=%3d attempted, msg=%s\n', ri.packet_id, ...
            ri.dw_visible_reps, msg);
    else
        skipped = skipped + 1;
    end
end
fprintf('\ntruncated=%d: cancel attempted=%d (gate-rejected=%d), silently skipped=%d\n', ...
    numel(trunc), attempted, gateRejected, skipped);

% dw_start histogram boundaries vs outcome for ALL packets
qmAt = 325;
fprintf('\noutcome by dw_start band (us):\n');
bands = [0 215; 215 280; 280 338; 338 381; 381 640];
labels = {'<=215 (all fits)', '215-280', '280-338 (QM35 burst zone)', ...
    '338-381 (payload off-window)', '>381 (preamble cut)'};
for b = 1:size(bands, 1)
    idx = find([r.dw_overlap_start] / 998.4 >= bands(b, 1) & ...
        [r.dw_overlap_start] / 998.4 < bands(b, 2));
    if isempty(idx), continue; end
    ok = nnz([r(idx).sic_applied]);
    fprintf('%-32s n=%3d  sic_ok=%3d  sic_fail=%3d\n', labels{b}, ...
        numel(idx), ok, numel(idx) - ok);
end
end

function v = fieldOrD2(s, name)
v = "";
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    v = s.(name);
end
end
