function analyze_dump_dw1000_preamble_sic_smoke()
%ANALYZE_DUMP_DW1000_PREAMBLE_SIC_SMOKE 4-window smoke for head-fragment skip.
%   Runs scheduledDumpSicPipeline on packet 24 (Class A), packet 5
%   (Class B), an early full-decode packet (P_early), and packet 47, then
%   hard-asserts the spec E.1 table. Any failed assertion throws so
%   `matlab -batch` exits non-zero.
%
%   Skips cleanly (no error) when the gain1 dump directory or the old SIC
%   manifest is missing, so the script is safe to run without live data.
%
%   See also SCHEDULEDDUMPSICPIPELINE.

projectDir = fileparts(mfilename('fullpath'));
if isempty(projectDir)
    projectDir = pwd;
end
addpath(projectDir);

tag = 'qm35_gain1_scheduled_sc16_dump_20260817';
dumpDir = fullfile('F:\UWB基带数据', tag);
if ~isfolder(dumpDir)
    fprintf('Skipping smoke: dump dir %s not present.\n', dumpDir);
    return;
end
oldManifest = fullfile(projectDir, 'decoded_results', tag, ...
    'sic_dw1000_removed_qm35_preserved', 'pipeline_manifest.mat');
if ~isfile(oldManifest)
    fprintf('Skipping smoke: old manifest %s not present.\n', oldManifest);
    return;
end

% --- P_early: earliest DW packet that passed FCS in the old run ----------
saved = load(oldManifest, 'pipeline');
oldRecords = saved.pipeline.packets;
fcs = arrayfun(@(r) isstruct(r.dw) && isfield(r.dw, 'fcs_pass') && ...
    r.dw.fcs_pass, oldRecords);
selected = oldRecords(fcs);
starts = arrayfun(@(r) double(r.dw.start_sample), selected);
[~, imin] = min(starts);
pEarly = selected(imin).packet_id;
fprintf('P_early packet_id = %d (start=%g)\n', pEarly, starts(imin));

packetIds = [24, 5, pEarly, 47];
cfg = struct();
cfg.dump_dir = dumpDir;
cfg.selection = 'all';
cfg.packet_ids = packetIds;
cfg.max_packets = [];
cfg.overwrite = true;
cfg.make_plots = false;
cfg.output_root = fullfile(projectDir, 'decoded_results', tag, ...
    'sic_dw1000_preamble_smoke');
pipeline = scheduledDumpSicPipeline(cfg);

assertSmoke(pipeline.version == 2, 'pipeline.version must be 2');
records = pipeline.packets;
assertSmoke(numel(records) == numel(packetIds), ...
    'Smoke pipeline did not process every requested packet.');

period = 1016;
assertPkt24(records, period);
assertPkt5(records, period);
assertPEarly(records, pEarly, period);
assertPkt47(records);

writeSmokeTable(records, pipeline.paths.metrics_csv, ...
    fullfile(cfg.output_root, 'smoke_assertions.csv'));
fprintf('\n===== dump preamble-SIC smoke PASSED =====\n');
end

% -------------------------------------------------------------------------
function assertPkt24(records, period)
r = recordFor(records, 24);
assertSmoke(~isempty(r) && r.ok, 'pkt24 did not process.');
assertSmoke(isfinite(r.dw_overlap_start) && ...
    abs(r.dw_overlap_start - 288696) <= 3*period, ...
    sprintf('pkt24 overlap start %g not within 3*%d of 288696', ...
        r.dw_overlap_start, period));
assertSmoke(r.dw_head_start < 2000, ...
    sprintf('pkt24 head start %g not below 2000.', r.dw_head_start));
assertSmoke(ismember(r.dw_search_path, ...
    ["qm35_neighborhood", "suffix_after_head"]), ...
    sprintf('pkt24 search_path %s not neighborhood/suffix.', ...
        char(r.dw_search_path)));
% The preamble-only cancel must be *attempted* at the overlap start. It may
% be rejected by the 0.70 alignment gate (spec Risks: "skip；不降门"), but it
% must never fall back to the head fragment.
assertCancelAttempted(r, 'pkt24');
assertClusterNotWorse(r, 'pkt24');
end

function assertPkt5(records, period)
r = recordFor(records, 5);
assertSmoke(~isempty(r) && r.ok, 'pkt5 did not process.');
assertSmoke(isfinite(r.dw_overlap_start) && ...
    abs(r.dw_overlap_start - 322017) <= 3*period, ...
    sprintf('pkt5 overlap start %g not within 3*%d of 322017.', ...
        r.dw_overlap_start, period));
assertSmoke(r.dw_head_start < 2000, ...
    sprintf('pkt5 head start %g not below 2000.', r.dw_head_start));
assertCancelAttempted(r, 'pkt5');
if isfield(r.dw_cancel, 'start_sample') && ...
        isfinite(r.dw_cancel.start_sample)
    assertSmoke(abs(r.dw_cancel.start_sample - 446) > 100, ...
        'pkt5 was cancelled at the head fragment start 446.');
end
end

function assertCancelAttempted(r, label)
attempted = r.dw_cancel.success || ...
    (~isempty(char(r.dw_cancel.message)));
assertSmoke(attempted, ...
    sprintf('%s: no DW cancellation was attempted.', label));
if r.dw_cancel.success
    assertSmoke(ismember(r.dw_cancel_mode, ["preamble", "full"]), ...
        sprintf('%s cancel_mode %s not preamble/full on success.', ...
            label, char(r.dw_cancel_mode)));
    assertSmoke(r.sic_applied, ...
        sprintf('%s cancel success should set sic_applied.', label));
else
    assertSmoke(r.dw_cancel_mode == "none", ...
        sprintf('%s cancel_mode %s with failed cancel.', ...
            label, char(r.dw_cancel_mode)));
    fprintf('  %s preamble-only cancel rejected by gate: %s\n', ...
        label, char(r.dw_cancel.message));
end
end

function assertPEarly(records, pEarly, period)
r = recordFor(records, pEarly);
assertSmoke(~isempty(r) && r.ok, 'P_early did not process.');
assertSmoke(r.dw_search_class == "full_decode", ...
    sprintf('P_early class %s not full_decode.', char(r.dw_search_class)));
assertSmoke(isnan(r.dw_head_start) || r.dw_head_start > 2000, ...
    'P_early treated as a head fragment.');
assertSmoke(ismember(r.dw_cancel_mode, ["full", "none"]), ...
    sprintf('P_early cancel_mode %s not full/none.', ...
        char(r.dw_cancel_mode)));
assertSmoke(r.sic_applied == (r.dw_cancel_mode == "full"), ...
    'P_early sic_applied does not match cancel_mode.');
end

function assertPkt47(records)
r = recordFor(records, 47);
assertSmoke(~isempty(r) && r.ok, 'pkt47 did not process.');
assertSmoke(r.dw.fcs_pass, 'pkt47 FCS should still pass.');
if r.sic_applied
    assertSmoke(r.dw_cancel_mode == "full", ...
        'pkt47 must not be cancelled via preamble-only.');
else
    assertSmoke(r.dw_cancel_mode == "none", ...
        sprintf('pkt47 cancel_mode %s with sic_applied=false.', ...
            char(r.dw_cancel_mode)));
end
end

function assertClusterNotWorse(r, label)
if ~isstruct(r.qm35_before.interference) || ...
        ~isstruct(r.qm35_after.interference)
    return
end
before = r.qm35_before.interference;
after = r.qm35_after.interference;
if isfield(before, 'cluster_n') && isfield(after, 'cluster_n') && ...
        isfinite(before.cluster_n) && isfinite(after.cluster_n)
    assertSmoke(after.cluster_n <= before.cluster_n + 1, ...
        sprintf('%s QM35 cluster_n rose %g -> %g.', label, ...
            before.cluster_n, after.cluster_n));
end
if isfield(before, 'first_peak_power') && ...
        isfield(after, 'first_peak_power') && ...
        isfinite(before.first_peak_power) && ...
        isfinite(after.first_peak_power)
    assertSmoke(after.first_peak_power >= 0.25*before.first_peak_power, ...
        sprintf('%s main path was punched through by cancellation.', label));
end
end

function writeSmokeTable(records, metricsCsv, assertionsCsv)
packetId = [records.packet_id].';
searchClass = string({records.dw_search_class}).';
searchPath = string({records.dw_search_path}).';
overlapStart = [records.dw_overlap_start].';
headStart = [records.dw_head_start].';
visibleReps = [records.dw_visible_reps].';
cancelMode = string({records.dw_cancel_mode}).';
sicApplied = [records.sic_applied].';
dwFcs = arrayfun(@(r) r.dw.fcs_pass, records);
clusterBefore = arrayfun(@(r) fieldOr(r.qm35_before.interference, ...
    'cluster_n', NaN), records);
clusterAfter = arrayfun(@(r) fieldOr(r.qm35_after.interference, ...
    'cluster_n', NaN), records);
t = table(packetId, searchClass, searchPath, overlapStart, headStart, ...
    visibleReps, cancelMode, sicApplied, dwFcs, clusterBefore, clusterAfter);
ensureDirectory(fileparts(assertionsCsv));
writetable(t, assertionsCsv);
disp(t);
fprintf('Metrics CSV   : %s\n', metricsCsv);
fprintf('Assertions CSV: %s\n', assertionsCsv);
end

% -------------------------------------------------------------------------
function r = recordFor(records, packetId)
idx = find([records.packet_id] == packetId, 1);
if isempty(idx)
    r = [];
else
    r = records(idx);
end
end

function assertSmoke(cond, msg)
if ~cond
    error('analyze_dump_dw1000_preamble_sic_smoke:Assertion', '%s', msg);
end
end

function v = fieldOr(s, name, fallback)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    v = s.(name);
else
    v = fallback;
end
end

function ensureDirectory(directory)
if ~isfolder(directory)
    mkdir(directory);
end
end