function classify_sic_failures()
m = load(fullfile('decoded_results', 'qm35_dw1000_sensing_1', ...
    'sic_dw1000_removed_qm35_preserved', 'pipeline_manifest.mat'));
r = m.pipeline.packets;
n = numel(r);

fid = fopen('F:\UWB基带数据\8月20日数据\qm35_dw1000_sensing_1\capture.jsonl');
modes = strings(3000, 1);
while ~feof(fid)
    line = fgetl(fid);
    if ~ischar(line), break; end
    j = jsondecode(line);
    if j.packet_id < 3000
        modes(j.packet_id + 1) = string(j.capture_mode);
    end
end
fclose(fid);

cat = strings(n, 1);
detail = strings(n, 1);
visAll = nan(n, 1);
for i = 1:n
    ri = r(i);
    cls = fo(ri, 'dw_search_class', "none");
    vis = double(ri.dw_visible_reps);
    visAll(i) = vis;
    fcsDw = logical(fo(ri.dw, 'fcs_pass', false));
    sicApplied = logical(ri.sic_applied);
    dwMsg = strtrim(string(fo(ri.dw_cancel, 'message', "")));
    qmFcs = logical(fo(ri.qm35_before, 'fcs_pass', false));
    qmCancelOk = logical(fo(ri.qm35_cancel, 'success', false));

    if ~ri.ok
        cat(i) = "pipeline_error";
        detail(i) = string(ri.error_message);
    elseif ~qmFcs
        cat(i) = "QM35_decode_fail";
        detail(i) = "QM35 FCS fail";
    elseif ~qmCancelOk
        cat(i) = "QM35_cancel_fail";
        detail(i) = string(ri.qm35_cancel.message);
    elseif cls == "full_decode" && sicApplied
        cat(i) = "OK_full_sic";
        detail(i) = sprintf('supp=%.1f dB', ri.dw_cancel.frame_suppression_db);
    elseif cls == "full_decode"
        cat(i) = "full_decode_SIC_rejected";
        detail(i) = dwMsg;
    elseif cls == "preamble_only"
        if vis < 256
            cat(i) = "DW_truncated";
            detail(i) = sprintf('vis=%d/256 | %s', vis, dwMsg);
        else
            cat(i) = "DW_full_preamble_FCSfail";
            detail(i) = dwMsg;
        end
    elseif cls == "false_lock_skipped"
        cat(i) = "DW_false_lock";
        detail(i) = "head fragment only, no overlap candidate";
    else
        cat(i) = "no_DW_candidate";
        detail(i) = "";
    end
end

u = unique(cat);
fprintf('=== %d packets in manifest ===\n', n);
for k2 = 1:numel(u)
    fprintf('%-28s %3d\n', u(k2), nnz(cat == u(k2)));
end

fprintf('\n--- failure detail per category ---\n');
for k2 = 1:numel(u)
    idx = find(cat == u(k2));
    fprintf('\n[%s] n=%d\n', u(k2), numel(idx));
    for s = idx(1:min(8, numel(idx)))'
        fprintf('  pkt %3d (%s): %s\n', r(s).packet_id, ...
            modes(r(s).packet_id + 1), detail(s));
    end
end

% truncated packets: position of DW start vs window capacity
truncIdx = find(cat == "DW_truncated");
if ~isempty(truncIdx)
    fprintf('\n--- all %d truncated packets ---\n', numel(truncIdx));
    for s = truncIdx'
        fprintf('  pkt %3d: dw_start=%6.1f us, vis=%3d/256, msg=%s\n', ...
            r(s).packet_id, double(r(s).dw_overlap_start) / 998.4, ...
            r(s).dw_visible_reps, detail(s));
    end
end

% rejected-after-full-decode packets
rejIdx = find(cat == "full_decode_SIC_rejected");
if ~isempty(rejIdx)
    fprintf('\n--- all %d full-decode-but-SIC-rejected packets ---\n', numel(rejIdx));
    for s = rejIdx'
        fprintf('  pkt %3d: supp=%.2f dB align=%.3f | %s\n', ...
            r(s).packet_id, fieldD(r(s).dw_cancel, 'frame_suppression_db'), ...
            fieldD(r(s).dw_cancel, 'alignment_correlation'), detail(s));
    end
end

% FCS-fail with full preamble
ffIdx = find(cat == "DW_full_preamble_FCSfail");
if ~isempty(ffIdx)
    fprintf('\n--- all %d full-preamble-but-FCS-fail packets ---\n', numel(ffIdx));
    for s = ffIdx'
        fprintf('  pkt %3d: state_before=%s | %s\n', r(s).packet_id, ...
            string(fo(r(s).qm35_before, 'interference_state', "?")), detail(s));
    end
end
end

function v = fo(s, name, f)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    v = s.(name);
else
    v = f;
end
end

function v = fieldD(s, name)
v = NaN;
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    v = double(s.(name));
end
end
