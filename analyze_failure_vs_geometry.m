function analyze_failure_vs_geometry()
m = load(fullfile('decoded_results', 'qm35_dw1000_sensing_1', ...
    'sic_dw1000_removed_qm35_preserved', 'pipeline_manifest.mat'));
r = m.pipeline.packets;
n = numel(r);

cat = strings(n, 1);
for i = 1:n
    ri = r(i);
    cls = string(ri.dw_search_class);
    vis = double(ri.dw_visible_reps);
    sicApplied = logical(ri.sic_applied);
    if cls == "full_decode" && sicApplied
        cat(i) = "OK_full_sic";
    elseif cls == "full_decode"
        cat(i) = "full_SIC_rejected";
    elseif cls == "preamble_only" && vis < 256
        cat(i) = "DW_truncated";
    elseif cls == "preamble_only"
        cat(i) = "FCSfail_full_preamble";
    else
        cat(i) = "false_lock";
    end
end

% geometry: QM35 frame span vs DW preamble span inside the window
qmStart = nan(n, 1);
dwStart = nan(n, 1);
overlapUs = nan(n, 1);   % us of DW preamble overlapping active QM35 frame
for i = 1:n
    qmStart(i) = double(r(i).qm35_before.start_sample) / 998.4;
    dwStart(i) = double(r(i).dw_overlap_start) / 998.4;
end
qmFrameLenUs = 130;      % 128 SYNC x ~1.017us + SFD/data approx
dwPreambleLenUs = 256 * 1017.02 / 1000;
for i = 1:n
    if isnan(dwStart(i)), continue; end
    a = max(dwStart(i), qmStart(i));
    b = min(dwStart(i) + dwPreambleLenUs, qmStart(i) + qmFrameLenUs);
    overlapUs(i) = max(0, b - a);
end

u = unique(cat);
fprintf('%-22s %5s %10s %10s %12s\n', 'category', 'n', 'dw_start', 'QM35', 'DW-in-QM35');
fprintf('%-22s %5s %10s %10s %12s\n', '', '', 'median us', 'median us', 'overlap med us');
for k = 1:numel(u)
    idx = cat == u(k);
    fprintf('%-22s %5d %10.1f %10.1f %12.1f\n', u(k), nnz(idx), ...
        median(dwStart(idx), 'omitnan'), median(qmStart(idx), 'omitnan'), ...
        median(overlapUs(idx), 'omitnan'));
end

% OK vs failed as function of overlap
okMask = cat == "OK_full_sic";
failMask = ~okMask;
edgesOv = -20:20:280;
hOk = histcounts(overlapUs(okMask), edgesOv);
hFail = histcounts(overlapUs(failMask), edgesOv);
fprintf('\n%-18s %6s %6s %6s\n', 'DW-in-QM35 ovlp', 'OK', 'FAIL', 'fail%%');
for e = 1:numel(hOk)
    tot = hOk(e) + hFail(e);
    if tot > 0
        fprintf('%4d-%3d us       %6d %6d %5.0f%%\n', edgesOv(e), edgesOv(e+1), ...
            hOk(e), hFail(e), 100 * hFail(e) / tot);
    end
end

% alignment correlation vs overlap for full-decode packets
fdIdx = find(cat == "OK_full_sic" | cat == "full_SIC_rejected");
al = nan(numel(fdIdx), 1);
ov = nan(numel(fdIdx), 1);
okv = false(numel(fdIdx), 1);
for j = 1:numel(fdIdx)
    ri = r(fdIdx(j));
    al(j) = double(fieldOrD(ri.dw_cancel, 'alignment_correlation'));
    ov(j) = overlapUs(fdIdx(j));
    okv(j) = logical(ri.sic_applied);
end
fprintf('\nfull-decode packets: corr(overlap, alignment) = %.3f\n', ...
    corr(ov, al, 'rows', 'complete'));
fprintf('mean alignment: OK=%.3f  rejected=%.3f\n', ...
    mean(al(okv), 'omitnan'), mean(al(~okv), 'omitnan'));
end

function v = fieldOrD(s, name)
v = NaN;
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    v = double(s.(name));
end
end
