function export_packet_failure_list()
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

status = strings(n, 1);
reason = strings(n, 1);
for i = 1:n
    ri = r(i);
    cls = string(ri.dw_search_class);
    vis = double(ri.dw_visible_reps);
    dwStartUs = double(ri.dw_overlap_start) / 998.4;
    qmStartUs = double(ri.qm35_before.start_sample) / 998.4;
    msgRaw = "";
    if isfield(ri.dw_cancel, 'message') && ~isempty(ri.dw_cancel.message)
        msgRaw = string(ri.dw_cancel.message);
    end
    msg = strtrim(msgRaw);
    align = fieldOrD(ri.dw_cancel, 'alignment_correlation');
    if isnan(align)
        tok = regexp(msg, 'correlation ([0-9.]+)', 'tokens', 'once');
        if ~isempty(tok), align = str2double(tok{1}); end
    end
    supp = fieldOrD(ri.dw_cancel, 'frame_suppression_db');

    % QM35 frame active span: SYNC ~130us plus PSDU tail; use generous 160us
    qmEndUs = qmStartUs + 160;
    tmplFirstUs = dwStartUs + 25;   % alignment template syncs 25..56
    tmplLastUs = dwStartUs + 57;
    tmplHitsQm = tmplFirstUs < qmEndUs && tmplLastUs > qmStartUs;

    if logical(ri.sic_applied)
        if cls == "full_decode"
            status(i) = "OK";
            reason(i) = sprintf('full SIC ok, supp=%.1f dB', supp);
        else
            status(i) = "OK";
            reason(i) = sprintf(['preamble SIC ok (vis=%d/256), ', ...
                'align=%.3f supp=%.1f dB'], vis, align, supp);
        end
        continue
    end
    if ~logical(ri.ok)
        status(i) = "FAIL";
        reason(i) = "pipeline error: " + string(ri.error_message);
    elseif ~logical(fieldOrD(ri.qm35_before, 'fcs_pass', false)) || ...
            ~logical(fieldOrD(ri.qm35_before, 'decode_ok', true))
        status(i) = "FAIL";
        reason(i) = "QM35 decode failed";
    elseif cls == "false_lock_skipped"
        status(i) = "FAIL";
        reason(i) = "DW1000 head fragment only, no overlap candidate (false lock)";
    elseif cls == "full_decode"
        status(i) = "FAIL";
        if tmplHitsQm
            tmplTxt = "hits";
        else
            tmplTxt = "clears";
        end
        reason(i) = sprintf(['FCS passed but cancel rejected: align=%.3f<0.60 ', ...
            '(fit segment %s QM35 burst)'], align, tmplTxt);
    elseif cls == "preamble_only" && vis >= 256
        status(i) = "FAIL";
        reason(i) = sprintf(['full preamble but FCS fail (payload off-window / ', ...
            'QM35 collision); cancel rejected: align=%.3f'], align);
    elseif cls == "preamble_only"
        status(i) = "FAIL";
        if tmplHitsQm
            why = "visible SYNC overlaps QM35 burst -> fit polluted";
        else
            why = "residual interference after weak QM35 cancel";
        end
        reason(i) = sprintf('preamble cut at vis=%d/256; cancel rejected: align=%.3f (%s)', ...
            vis, align, why);
    else
        status(i) = "FAIL";
        reason(i) = "no DW candidate";
    end
end

outDir = fullfile('decoded_results', 'qm35_dw1000_sensing_1', ...
    'sic_dw1000_removed_qm35_preserved', 'validation');
if ~isfolder(outDir), mkdir(outDir); end
csvFile = fullfile(outDir, 'packet_failure_reasons.csv');
fOut = fopen(csvFile, 'w');
fprintf(fOut, 'packet_id,capture_mode,dw_start_us,qm35_start_us,visible_reps,status,reason\n');
fprintf('\n%-5s %-11s %-10s %-6s %-9s %s\n', 'pkt', 'mode', 'dw_us', 'vis', 'status', 'reason');
for i = 1:n
    pid = r(i).packet_id;
    fprintf(fOut, '%d,%s,%.1f,%.1f,%d,%s,"%s"\n', pid, modes(pid + 1), ...
        double(r(i).dw_overlap_start) / 998.4, ...
        double(r(i).qm35_before.start_sample) / 998.4, ...
        r(i).dw_visible_reps, status(i), reason(i));
    fprintf('%-5d %-11s %-10.1f %-6d %-9s %s\n', pid, modes(pid + 1), ...
        double(r(i).dw_overlap_start) / 998.4, r(i).dw_visible_reps, ...
        status(i), reason(i));
end
fclose(fOut);
fprintf('\nCSV written: %s\n', csvFile);
fprintf('summary: OK=%d FAIL=%d\n', nnz(status == "OK"), nnz(status == "FAIL"));
end

function v = fieldOrD(s, name, fallback)
if nargin < 3, fallback = NaN; end
v = fallback;
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    v = double(s.(name));
end
end
