%% Isolate DW1000 FCS-fail dump windows and check why they failed.
% Reads the existing SIC manifest; does not rerun the 68-window pipeline.
% Optionally re-detects a few representative windows with a later seed.
clear;
close all;
clc;

thisDir = fileparts(mfilename('fullpath'));
if isempty(thisDir)
    thisDir = pwd;
end
cd(thisDir);
addpath(thisDir);

outDir = fullfile(thisDir, 'decoded_results', ...
    'qm35_gain1_scheduled_sc16_dump_20260817', ...
    'sic_dw1000_removed_qm35_preserved');
sicMat = fullfile(outDir, 'pipeline_manifest.mat');
decodeMat = fullfile(thisDir, 'decoded_results', ...
    'qm35_gain1_scheduled_sc16_dump_20260817', 'scheduled_dump_matlab.mat');
dumpDir = 'F:\UWB基带数据\qm35_gain1_scheduled_sc16_dump_20260817';

S = load(sicMat, 'pipeline');
P = S.pipeline.packets;
D = load(decodeMat, 'results');
R = D.results;

fs = 998.4e6;
periodNom = 1016;
shrNeed = (256 + 8) * periodNom;
win998 = round(434995 * 65 / 48);
latestOk = win998 - shrNeed;

id2r = containers.Map('KeyType', 'double', 'ValueType', 'any');
for i = 1:numel(R)
    id2r(R(i).packet_id) = R(i);
end

n = numel(P);
pids = arrayfun(@(p) p.packet_id, P);
dwS = arrayfun(@(p) p.dw.start_sample, P);
pass = arrayfun(@(p) logical(p.dw.fcs_pass), P);
phr = arrayfun(@(p) logical(p.dw.phr_secded_pass), P);
reps = arrayfun(@(p) p.dw.detected_repetitions, P);
cfo = arrayfun(@(p) p.dw.cfo_hz, P);
psdu = arrayfun(@(p) p.dw.psdu_length_bytes, P);
qCancel = arrayfun(@(p) p.qm35_cancel.frame_suppression_db, P);
clusterN = nan(n, 1);
maxPk = nan(n, 1);
winNat = nan(n, 1);
for k = 1:n
    rr = id2r(pids(k));
    winNat(k) = rr.window_start_native;
    clusterN(k) = rr.qm35_cluster_n;
    maxPk(k) = rr.qm35_cluster_max_peak_db;
end
winOut = round(winNat * 65 / 48);
dwAbs = winOut + dwS;

absPass = dwAbs(pass);
dlt = diff(sort(absPass));
T5 = median(dlt(dlt > 5.0e6 & dlt < 5.3e6));
fprintf('Success %d / %d   fail %d   T5=%.4f ms   window=%d  latest SHR start=%d\n', ...
    nnz(pass), n, nnz(~pass), T5 / fs * 1e3, win998, latestOk);

lattice = [];
for i = 1:numel(absPass)
    lattice = [lattice; absPass(i) + (-40:40).' * T5]; %#ok<AGROW>
end
lattice = unique(round(lattice / 200) * 200);
lattice = lattice(lattice > 0);

packet_id = zeros(0, 1);
dw_lock_start = zeros(0, 1);
phr_secded = false(0, 1);
psdu_len = zeros(0, 1);
detected_reps = zeros(0, 1);
cfo_hz = zeros(0, 1);
qm35_cancel_db = zeros(0, 1);
cluster_n = zeros(0, 1);
cluster_max_peak_db = zeros(0, 1);
n_predicted = zeros(0, 1);
later_viable_start = zeros(0, 1);
clipped_start = zeros(0, 1);
truncated_start = zeros(0, 1);
failure_class = strings(0, 1);
note = strings(0, 1);

fprintf('\n=== DW1000 FCS-fail windows ===\n');
fprintf(['pkt  lock   phr psdu reps      cfo   N   later   clip    trunc   class\n']);

for k = find(~pass).'
    w0 = winOut(k);
    predLocal = unique(round(lattice - w0));
    predLocal = predLocal(predLocal > -shrNeed & predLocal < win998);
    viable = predLocal((predLocal >= 2000) & (predLocal <= latestOk));
    clipped = predLocal(predLocal < 1);
    trunc = predLocal((predLocal > latestOk) & (predLocal < win998));

    laterStart = NaN;
    clipStart = NaN;
    truncStart = NaN;
    if ~isempty(viable)
        laterStart = viable(1);
    end
    if ~isempty(clipped)
        [~, ii] = min(abs(clipped));
        clipStart = clipped(ii);
    end
    if ~isempty(trunc)
        truncStart = min(trunc);
    end

    if isfinite(laterStart)
        class = "false_lock_missed_later_dw";
        extra = sprintf('locked %d, later viable DW at %d', dwS(k), laterStart);
    elseif isfinite(clipStart)
        class = "clipped_head_incomplete_sync";
        extra = sprintf('locked %d, previous DW starts %d (before window)', ...
            dwS(k), clipStart);
        if isfinite(truncStart)
            extra = sprintf('%s; later DW at %d has SFD past window', ...
                extra, truncStart);
        end
    else
        class = "no_dw_in_window";
        extra = 'no lattice overlap';
    end

    fprintf('%3d  %5.0f  %3d %4d %4.0f %8.1f %3.0f  %6.0f %7.0f %7.0f   %s\n', ...
        pids(k), dwS(k), phr(k), psdu(k), reps(k), cfo(k), clusterN(k), ...
        laterStart, clipStart, truncStart, class);

    packet_id(end+1, 1) = pids(k); %#ok<AGROW>
    dw_lock_start(end+1, 1) = dwS(k);
    phr_secded(end+1, 1) = phr(k);
    psdu_len(end+1, 1) = psdu(k);
    detected_reps(end+1, 1) = reps(k);
    cfo_hz(end+1, 1) = cfo(k);
    qm35_cancel_db(end+1, 1) = qCancel(k);
    cluster_n(end+1, 1) = clusterN(k);
    cluster_max_peak_db(end+1, 1) = maxPk(k);
    n_predicted(end+1, 1) = numel(predLocal);
    later_viable_start(end+1, 1) = laterStart;
    clipped_start(end+1, 1) = clipStart;
    truncated_start(end+1, 1) = truncStart;
    failure_class(end+1, 1) = class;
    note(end+1, 1) = extra;
end

u = unique(failure_class);
fprintf('\nClass counts:\n');
for i = 1:numel(u)
    fprintf('  %-32s %d\n', u(i), nnz(failure_class == u(i)));
end

T = table(packet_id, dw_lock_start, phr_secded, psdu_len, detected_reps, ...
    cfo_hz, qm35_cancel_db, cluster_n, cluster_max_peak_db, n_predicted, ...
    later_viable_start, clipped_start, truncated_start, failure_class, note);
outCsv = fullfile(outDir, 'dw1000_decode_failures.csv');
writetable(T, outCsv);
fprintf('Wrote %s\n', outCsv);

%% Seeded vs unseeded preamble check on two representative windows
verifyIds = [24, 5];
verifySeeds = [288693, NaN];
tapsFile = fullfile(thisDir, 'testdata', 'resampler_65_48', ...
    'taps_quality_minorder.txt');
if ~isfile(tapsFile)
    fprintf('Skip seed verify: missing taps\n');
    return
end
fid = fopen(tapsFile, 'rb');
taps = fread(fid, Inf, 'single=>single');
fclose(fid);

fprintf('\nBuilding DW1000 code-10 / 256 reference...\n');
dwOpt = struct();
dwOpt.fs_rx = fs;
dwOpt.data_rate = 6.81;
dwOpt.preamble_repetitions = 256;
dwOpt.code_index = 10;
dwOpt.sfd_mode = 'decawave';
dwOpt.cir_skip_initial_repetitions = 10;
dwOpt.cir_repetitions = 64;
dwOpt.max_psdu_bytes = 127;
dwOpt.enable_frame_crop = true;
dwOpt.show_plots = false;
dwParams = uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), dwOpt);
dwRef = uwbdecoder.buildUwbReference(dwParams);
dwSfd = struct( ...
    'decawave', dwParams.decawave_sfd(:), ...
    'ieee', dwParams.ieee_sfd(:), ...
    'sfd4z_1', dwParams.sfd4z_1(:), ...
    'sfd4z_2', dwParams.sfd4z_2(:), ...
    'sfd4z_3', dwParams.sfd4z_3(:), ...
    'sfd4z_4', dwParams.sfd4z_4(:));

iqFile = fullfile(dumpDir, 'capture.iq');
jsonlFile = fullfile(dumpDir, 'capture.jsonl');
interp = 65;
decim = 48;

fprintf('\n=== Seeded re-detect ===\n');
for i = 1:numel(verifyIds)
    pid = verifyIds(i);
    seed = verifySeeds(i);
    fprintf('\n-- packet %d --\n', pid);
    [xScaled, meta] = read_uwb_packet(iqFile, jsonlFile, pid);
    iqScale = 1;
    if isfield(meta, 'iq_scale') && ~isempty(meta.iq_scale)
        iqScale = double(meta.iq_scale);
    end
    x998 = upfirdn(single(xScaled * iqScale), taps, interp, decim);
    fprintf('window samples %d\n', numel(x998));

    preU = uwbdecoder.detectRepeatedPreamble(x998, dwRef, dwParams, []);
    fprintf('unseeded: start=%d  reps=%d  period=%.2f\n', ...
        preU.start_sample, preU.detected_repetitions, preU.measured_period);

    if isfinite(seed)
        preS = uwbdecoder.detectRepeatedPreamble(x998, dwRef, dwParams, seed);
        fprintf('seeded %d: start=%d  reps=%d  period=%.2f\n', ...
            seed, preS.start_sample, preS.detected_repetitions, ...
            preS.measured_period);
        try
            decS = decode_uwb(dwParams, x998, [], dwRef, dwSfd, ...
                'single', seed, true);
            fprintf('seeded decode: FCS=%d PHR=%d psdu=%d hex=%s\n', ...
                decS.payload.fcs_pass, decS.phr.secded_pass, ...
                decS.phr.psdu_length_bytes, ...
                sprintf('%02X', decS.payload.bytes));
        catch err
            fprintf('seeded decode failed: %s\n', err.message);
        end
    end
end
