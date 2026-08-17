%% Compare occupancy detector vs pre-FP cluster criterion on dump SIC.
clear;
close all;
clc;

thisDir = fileparts(mfilename('fullpath'));
if isempty(thisDir)
    thisDir = pwd;
end
cd(thisDir);
addpath(thisDir);

decodeMat = fullfile(thisDir, 'decoded_results', ...
    'qm35_gain1_scheduled_sc16_dump_20260817', 'scheduled_dump_matlab.mat');
sicMat = fullfile(thisDir, 'decoded_results', ...
    'qm35_gain1_scheduled_sc16_dump_20260817', ...
    'sic_dw1000_removed_qm35_preserved', 'pipeline_manifest.mat');

D = load(decodeMat, 'results');
R = D.results;
S = load(sicMat, 'pipeline');
P = S.pipeline.packets;

n = numel(R);
states = strings(n, 1);
sicRec = false(n, 1);
occ = nan(n, 1);
rEarly = nan(n, 1);
for k = 1:n
    states(k) = string(R(k).qm35_interference_state);
    sicRec(k) = logical(R(k).qm35_sic_recommended);
    occ(k) = R(k).qm35_interference_occupancy;
    rEarly(k) = R(k).qm35_early_residual_ratio_db;
end

fprintf('=== old detector on all %d decode packets ===\n', n);
fprintf('clean=%d suspected=%d interfered=%d invalid=%d sic_rec=%d\n', ...
    nnz(states == "clean"), nnz(states == "suspected"), ...
    nnz(states == "interfered"), nnz(states == "invalid"), nnz(sicRec));

clusterN = nan(n, 1);
clusterState = strings(n, 1);
clusterMaxDb = nan(n, 1);
for k = 1:n
    [clusterN(k), clusterState(k), clusterMaxDb(k)] = ...
        clusterScore(R(k).qm35_cir_interference);
end
fprintf('=== cluster criterion (FP-10 ns, run>=3 @ -40 dB, N>=5) ===\n');
fprintf('clean=%d suspected=%d interfered=%d invalid=%d\n', ...
    nnz(clusterState == "clean"), nnz(clusterState == "suspected"), ...
    nnz(clusterState == "interfered"), nnz(clusterState == "invalid"));

fprintf('\nold\\cluster    clean  susp  inter  inv\n');
oldLabels = ["clean", "suspected", "interfered", "invalid"];
newLabels = oldLabels;
for i = 1:numel(oldLabels)
    fprintf('%-12s', oldLabels(i));
    for j = 1:numel(newLabels)
        fprintf('%6d', nnz(states == oldLabels(i) & clusterState == newLabels(j)));
    end
    fprintf('\n');
end

mask = states == "interfered" & clusterState == "clean";
fprintf('\nold-interfered & cluster-clean: %d\n', nnz(mask));
if any(mask)
    fprintf('  ids: %s\n', mat2str([R(mask).packet_id]));
    fprintf('  residual dB median %.1f  [%.1f, %.1f]\n', ...
        median(rEarly(mask), 'omitnan'), min(rEarly(mask)), max(rEarly(mask)));
    fprintf('  occupancy   median %.2f  [%.2f, %.2f]\n', ...
        median(occ(mask), 'omitnan'), min(occ(mask)), max(occ(mask)));
    fprintf('  cluster N   median %.0f  maxPk %.1f dB\n', ...
        median(clusterN(mask), 'omitnan'), max(clusterMaxDb(mask)));
end

mask2 = states == "clean" & clusterState == "interfered";
fprintf('old-clean & cluster-interfered: %d\n', nnz(mask2));
if any(mask2)
    fprintf('  ids: %s\n', mat2str([R(mask2).packet_id]));
    fprintf('  residual median %.1f  occ median %.2f  N median %.0f  maxPk %.1f\n', ...
        median(rEarly(mask2), 'omitnan'), median(occ(mask2), 'omitnan'), ...
        median(clusterN(mask2), 'omitnan'), median(clusterMaxDb(mask2), 'omitnan'));
end

sicA = [P.sic_applied];
dwF = false(numel(P), 1);
qC = false(numel(P), 1);
for k = 1:numel(P)
    dwF(k) = P(k).dw.fcs_pass;
    qC(k) = P(k).qm35_cancel.success;
end
fprintf('\n=== SIC run (%d windows selected by old interfered) ===\n', numel(P));
fprintf('qm35_cancel=%d  dw_fcs=%d  sic_applied=%d\n', nnz(qC), nnz(dwF), nnz(sicA));

fprintf(['\npkt sic oldB->oldA          clusB N   clusA N', ...
    '   rE_b   rE_a  occ_b occ_a dw qC   dC  note\n']);
nFlipOld = 0;
nFlipCluster = 0;
nStayOld = 0;
nStayCluster = 0;
for k = 1:numel(P)
    r = P(k);
    [nB, sB, ~] = clusterScore(r.qm35_before.interference);
    [nA, sA, ~] = clusterScore(r.qm35_after.interference);
    if r.sic_applied && r.qm35_before.interference_state == "interfered" && ...
            r.qm35_after.interference_state ~= "interfered"
        nFlipOld = nFlipOld + 1;
    end
    if r.sic_applied && r.qm35_after.interference_state == "interfered"
        nStayOld = nStayOld + 1;
    end
    if r.sic_applied && sB == "interfered" && sA ~= "interfered"
        nFlipCluster = nFlipCluster + 1;
    end
    if r.sic_applied && sA == "interfered"
        nStayCluster = nStayCluster + 1;
    end
    note = "";
    if r.dw.fcs_pass && ~r.sic_applied
        note = string(r.dw_cancel.message);
    end
    fprintf(['%3d  %d  %-11s->%-11s  %-5s %2.0f   %-5s %2.0f', ...
        '  %6.1f %6.1f  %.2f %.2f  %d %5.1f %5.1f  %s\n'], ...
        r.packet_id, r.sic_applied, r.qm35_before.interference_state, ...
        r.qm35_after.interference_state, sB, nB, sA, nA, ...
        r.cir_metrics.early_residual_before_db, ...
        r.cir_metrics.early_residual_after_db, ...
        r.cir_metrics.occupancy_before, r.cir_metrics.occupancy_after, ...
        r.dw.fcs_pass, r.qm35_cancel.frame_suppression_db, ...
        r.dw_cancel.frame_suppression_db, note);
end
fprintf('\nAmong %d SIC-applied: old flip %d stay-interfered %d; cluster flip %d stay %d\n', ...
    nnz(sicA), nFlipOld, nStayOld, nFlipCluster, nStayCluster);

function [N, state, maxDb] = clusterScore(d)
N = NaN;
state = "invalid";
maxDb = NaN;
if ~isstruct(d) || ~isfield(d, 'individual_values') || ...
        isempty(d.individual_values)
    return
end
H = d.individual_values;
delay = d.delay_ns(:);
fp = NaN;
if isfield(d, 'first_path_delay_ns')
    fp = d.first_path_delay_ns;
end
if ~isfinite(fp)
    return
end
powerBar = abs(mean(H, 2)).^2;
idx = find(delay >= fp);
if isempty(idx)
    idx = (1:numel(powerBar)).';
end
region = powerBar(idx);
isPeak = false(size(region));
if numel(region) == 1
    isPeak = true;
else
    isPeak(1) = region(1) >= region(2);
    isPeak(end) = region(end) >= region(end - 1);
    if numel(region) > 2
        isPeak(2:end-1) = region(2:end-1) >= region(1:end-2) & ...
            region(2:end-1) >= region(3:end);
    end
end
peakLocal = find(isPeak, 1, 'first');
if isempty(peakLocal)
    [~, peakLocal] = max(region);
end
peakPower = region(peakLocal);
early = delay < (fp - 10);
if ~any(early)
    N = 0;
    state = "clean";
    maxDb = -Inf;
    return
end
HeDb = 10 * log10(max(abs(H(early, :)).^2 / (peakPower + eps), eps));
maxDb = max(HeDb(:));
N = 0;
for m = 1:size(HeDb, 2)
    runLen = 0;
    hit = false;
    for t = 1:size(HeDb, 1)
        if HeDb(t, m) > -40
            runLen = runLen + 1;
            if runLen >= 3
                hit = true;
            end
        else
            runLen = 0;
        end
    end
    if hit
        N = N + 1;
    end
end
if N >= 5
    state = "interfered";
elseif N >= 1
    state = "suspected";
else
    state = "clean";
end
end
