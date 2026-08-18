function pipeline = scheduledDumpSicPipeline(cfg)
%SCHEDULEDDUMPSICPIPELINE Cancel DW1000 from interfered scheduled-dump windows.
%   PIPELINE = SCHEDULEDDUMPSICPIPELINE(CFG) follows the same order as
%   UWBSICPIPELINE, but operates on GNU Radio detector windows instead of a
%   continuous .dat:
%     resampled window
%       -> decode QM35 (C++ seed)
%       -> cancel QM35
%       -> decode DW1000 on the residual
%       -> cancel DW1000 from the original window (QM35 preserved)
%       -> decode QM35 again and compare CIR
%
%   Reconstruction / fitting reuse CANCEL_UWB_PACKET_IN_IQ, which calls
%   GENERATE_UWB_TX_FROM_DECODE and APPLY_ESTIMATED_CIR_TO_UWB.
%
%   CFG fields:
%     dump_dir          GNU Radio dump directory
%     output_root       result directory
%     selection         'interfered' | 'sic_recommended' | 'all'
%     packet_ids        optional explicit packet_id list
%     max_packets       [] = all selected
%     overwrite         replace existing products
%     make_plots        run CIR comparison figures
%     min_alignment_correlation   DW cancel gate (default 0.60). Does not
%                                 change QM35 cancel or the library 0.70.
%
%   See also UWBSICPIPELINE, RUN_SCHEDULED_DUMP_SIC_PIPELINE,
%   VISUALIZE_SCHEDULED_DUMP_SIC_CIR.

arguments
    cfg struct
end

pipelineTimer = tic;
projectDir = fileparts(mfilename('fullpath'));
addpath(projectDir);

cfg = normalizeDumpSicConfig(cfg, projectDir);
ensureDirectory(cfg.output_root);

pipeline = struct();
pipeline.version = 2;
pipeline.status = 'running';
pipeline.started_at = timestampNow();
pipeline.config = cfg;
pipeline.paths = buildDumpSicPaths(cfg);
pipeline.packets = struct([]);
pipeline.summary = struct();

fprintf('\n========== Scheduled-dump SIC pipeline ==========\n');
fprintf('Dump   : %s\n', cfg.dump_dir);
fprintf('Output : %s\n', cfg.output_root);
fprintf('Select : %s\n', cfg.selection);

refs = buildPhyReferences();
taps = loadResamplerTaps(cfg.taps_file);
packetIds = selectDumpPackets(cfg);
if isempty(packetIds)
    error('scheduledDumpSicPipeline:NoPackets', ...
        'No dump packets matched selection ''%s''.', cfg.selection);
end
fprintf('Windows: %d\n', numel(packetIds));

records = repmat(emptyPacketRecord(), numel(packetIds), 1);
for k = 1:numel(packetIds)
    packetId = packetIds(k);
    fprintf('\n[%d/%d] packet_id %d\n', k, numel(packetIds), packetId);
    records(k) = processOneDumpWindow( ...
        packetId, cfg, refs, taps);
end

pipeline.packets = records;
pipeline.summary = summarizeDumpSic(records);
pipeline.status = 'complete';
pipeline.completed_at = timestampNow();
pipeline.timing = struct('total_elapsed', toc(pipelineTimer));

writeDumpSicTables(pipeline);
save(pipeline.paths.manifest_file, 'pipeline', '-v7.3');

fprintf('\n========== Scheduled-dump SIC complete ==========\n');
fprintf('Processed              : %d\n', pipeline.summary.n_packets);
fprintf('QM35 FCS before/after  : %d / %d\n', ...
    pipeline.summary.qm35_fcs_before, pipeline.summary.qm35_fcs_after);
fprintf('QM35 cancelled         : %d\n', pipeline.summary.qm35_cancelled);
fprintf('DW1000 decoded / FCS   : %d / %d\n', ...
    pipeline.summary.dw_decoded, pipeline.summary.dw_fcs);
fprintf('DW1000 cancelled (SIC) : %d\n', pipeline.summary.dw_cancelled);
fprintf('DW full cancelled      : %d\n', ...
    pipeline.summary.dw_full_cancelled);
fprintf('DW preamble cancelled  : %d\n', ...
    pipeline.summary.dw_preamble_cancelled);
fprintf('DW false-lock skipped  : %d\n', ...
    pipeline.summary.dw_false_lock_skipped);
fprintf('Median CIR coherence   : %.4f\n', ...
    pipeline.summary.median_cir_coherence);
fprintf('Manifest               : %s\n', pipeline.paths.manifest_file);

if cfg.make_plots
    sic_dump_manifest_file = pipeline.paths.manifest_file; %#ok<NASGU>
    sic_dump_managed_visualization = true; %#ok<NASGU>
    run(fullfile(projectDir, 'visualize_scheduled_dump_sic_cir.m'));
end
end

function record = processOneDumpWindow(packetId, cfg, refs, taps)
record = emptyPacketRecord();
record.packet_id = packetId;
try
    window = loadResampledDumpWindow(packetId, cfg, taps);
    record.schedule_index = window.schedule_index;
    record.capture_mode = string(window.capture_mode);
    xOrig = window.x998;

    qm35Before = decode_uwb(refs.qm35.params, xOrig, [], ...
        refs.qm35.reference, refs.qm35.sfd, 'single', ...
        window.seeded_start_one, true);
    record.qm35_before = packDecodedCir(qm35Before, cfg.cir_interference_options);
    fprintf('  QM35 before: FCS=%d  state=%s\n', ...
        record.qm35_before.fcs_pass, record.qm35_before.interference_state);

    xAfterQm35 = xOrig;
    if record.qm35_before.fcs_pass
        try
            [xAfterQm35, qm35Cancel] = cancel_uwb_packet_in_iq( ...
                xOrig, qm35Before, refs.qm35.tx, refs.qm35.cancel);
            record.qm35_cancel = packCancelReport(qm35Cancel);
            fprintf('  QM35 cancel: %.2f dB\n', qm35Cancel.frame_suppression_db);
        catch cancelErr
            record.qm35_cancel.success = false;
            record.qm35_cancel.message = string(cancelErr.message);
            fprintf('  QM35 cancel skipped: %s\n', cancelErr.message);
        end
    end

    [dwDecoded, dwProfile, dwSearch] = decodeDw1000OnWindow( ...
        xAfterQm35, refs.dw_profiles, window.seeded_start_one, cfg);
    record.dw_search_class = classifyDwSearch(dwDecoded, dwSearch, cfg);
    record.dw_overlap_start = dwSearch.overlap_start;
    record.dw_head_start = dwSearch.head_start;
    record.dw_visible_reps = dwSearch.overlap_reps;
    record.dw_cancel_mode = "none";
    record.dw_search_path = string(dwSearch.search_path);

    if ~isempty(dwDecoded)
        record.dw = packDecodedCir(dwDecoded, struct());
        record.dw_profile = string(dwProfile.name);
        startPrint = record.dw.start_sample;
        if isfield(dwDecoded, 'preamble') && ...
                isfield(dwDecoded.preamble, 'start_sample_uncropped')
            startPrint = dwDecoded.preamble.start_sample_uncropped;
        end
        fprintf('  DW1000: profile=%s FCS=%d start=%d class=%s path=%s\n', ...
            dwProfile.name, record.dw.fcs_pass, round(double(startPrint)), ...
            record.dw_search_class, record.dw_search_path);
    elseif isfinite(dwSearch.overlap_start)
        record.dw.decode_ok = true;
        record.dw.fcs_pass = false;
        record.dw.start_sample = dwSearch.overlap_start;
        record.dw.detected_repetitions = dwSearch.overlap_reps;
        record.dw_profile = string(dwProfile.name);
        fprintf('  DW1000: decode failed; overlap=%d vis=%d class=%s path=%s\n', ...
            dwSearch.overlap_start, dwSearch.overlap_reps, ...
            record.dw_search_class, record.dw_search_path);
    else
        fprintf('  DW1000: no overlap candidate (head=%g class=%s)\n', ...
            dwSearch.head_start, record.dw_search_class);
    end

    xPreserved = xOrig;
    fullTried = ~isempty(dwDecoded) && record.dw.fcs_pass;
    if fullTried
        try
            cancelOpts = dwProfile.cancel;
            cancelOpts.min_alignment_correlation = ...
                cfg.min_alignment_correlation;
            [xPreserved, dwCancel] = cancel_uwb_packet_in_iq( ...
                xOrig, dwDecoded, dwProfile.tx, cancelOpts);
            record.dw_cancel = packCancelReport(dwCancel);
            record.sic_applied = logical(record.dw_cancel.success);
            if record.sic_applied
                record.dw_cancel_mode = "full";
            end
            fprintf('  DW1000 cancel full: %.2f dB success=%d\n', ...
                dwCancel.frame_suppression_db, record.sic_applied);
        catch cancelErr
            record.dw_cancel.success = false;
            record.dw_cancel.message = string(cancelErr.message);
            record.sic_applied = false;
            fprintf('  DW1000 full cancel skipped: %s\n', cancelErr.message);
            % 禁止在 FCS pass 时回落到 preamble-only（packet 47）
        end
    elseif cfg.enable_preamble_only_sic && ...
            isfinite(dwSearch.overlap_start) && ...
            dwSearch.overlap_reps >= cfg.min_visible_sync_for_preamble_sic && ...
            isstruct(dwProfile) && isfield(dwProfile, 'params')
        try
            [preambleCir, cirEst] = estimate_uwb_preamble_cir( ...
                xAfterQm35, dwProfile.reference, dwProfile.params, ...
                dwSearch.overlap_start, dwSearch.overlap_preamble);
            txOpt = struct( ...
                'code_index', dwProfile.params.code_index, ...
                'visible_reps', dwSearch.overlap_reps, ...
                'fs_tx', 998.4e6, ...
                'phy_mode', '802.15.4a', ...
                'peak_amplitude', 1, ...
                'guard_samples', 0);
            cancelOpts = dwProfile.cancel;
            cancelOpts.min_visible_sync_for_preamble_sic = ...
                cfg.min_visible_sync_for_preamble_sic;
            cancelOpts.min_alignment_correlation = ...
                cfg.min_alignment_correlation;
            cancelOpts.cfo_fit_last_sync = dwSearch.overlap_reps;
            cancelOpts.gain_fit_last_sync = dwSearch.overlap_reps;
            [xPreserved, dwCancel] = cancel_uwb_preamble_in_iq( ...
                xOrig, preambleCir, cirEst, txOpt, cancelOpts);
            record.dw_cancel = packCancelReport(dwCancel);
            record.sic_applied = logical(record.dw_cancel.success);
            if record.sic_applied
                record.dw_cancel_mode = "preamble";
            end
            fprintf('  DW1000 cancel preamble: %.2f dB vis=%d start=%d success=%d\n', ...
                dwCancel.frame_suppression_db, dwSearch.overlap_reps, ...
                dwSearch.overlap_start, record.sic_applied);
        catch cancelErr
            record.dw_cancel.success = false;
            record.dw_cancel.message = string(cancelErr.message);
            record.sic_applied = false;
            fprintf('  DW1000 preamble cancel skipped: %s\n', cancelErr.message);
        end
    end

    qm35After = decode_uwb(refs.qm35.params, xPreserved, [], ...
        refs.qm35.reference, refs.qm35.sfd, 'single', ...
        window.seeded_start_one, true);
    record.qm35_after = packDecodedCir(qm35After, cfg.cir_interference_options);
    record.cir_metrics = measureCirChange( ...
        record.qm35_before, record.qm35_after);
    fprintf('  QM35 after: FCS=%d  state=%s  coherence=%.4f\n', ...
        record.qm35_after.fcs_pass, record.qm35_after.interference_state, ...
        record.cir_metrics.cir_coherence);
    record.ok = true;
catch err
    record.ok = false;
    record.error_id = string(err.identifier);
    record.error_message = string(err.message);
    fprintf('  ERROR: %s\n', err.message);
end
end

function [decoded, profile, search] = decodeDw1000OnWindow( ...
        x, profiles, qm35Start, cfg)
decoded = [];
profile = struct();
search = emptyDwSearch();
searchOpts = searchOptsFromCfg(cfg);
firstOverlapLocked = false;

for k = 1:numel(profiles)
    try
        candSearch = findDwPreambleCandidatesOnWindow( ...
            x, profiles(k), qm35Start, searchOpts);
    catch
        continue
    end

    if ~firstOverlapLocked && isfinite(candSearch.overlap_start)
        search = candSearch;
        profile = profiles(k);
        firstOverlapLocked = true;
    end
    if ~isfinite(candSearch.overlap_start)
        if ~firstOverlapLocked && candSearch.head_is_fragment
            search.head_start = candSearch.head_start;
            search.head_is_fragment = true;
            search.head_reps = candSearch.head_reps;
        end
        continue
    end

    try
        candidate = decode_uwb(profiles(k).params, x, [], ...
            profiles(k).reference, profiles(k).sfd, 'single', ...
            candSearch.overlap_start, true);
    catch decodeErr
        fprintf('  DW decode at %d failed: %s\n', ...
            candSearch.overlap_start, decodeErr.message);
        continue
    end

    if candidate.payload.fcs_pass
        decoded = candidate;
        profile = profiles(k);
        search = candSearch;
        return
    end
    sameFrozenProfile = firstOverlapLocked && ...
        isfield(profile, 'name') && isfield(profiles(k), 'name') && ...
        strcmp(string(profile.name), string(profiles(k).name));
    if sameFrozenProfile && isempty(decoded)
        decoded = candidate;
    end
end
end

function cls = classifyDwSearch(decoded, search, cfg)
if ~isempty(decoded) && isfield(decoded, 'payload') && decoded.payload.fcs_pass
    cls = "full_decode";
elseif isfinite(search.overlap_start) && ...
        search.overlap_reps >= cfg.min_visible_sync_for_preamble_sic
    cls = "preamble_only";
elseif search.head_is_fragment
    cls = "false_lock_skipped";
else
    cls = "none";
end
end

function search = emptyDwSearch()
search = struct( ...
    'head_start', NaN, ...
    'head_reps', 0, ...
    'head_is_fragment', false, ...
    'head_period', NaN, ...
    'overlap_start', NaN, ...
    'overlap_reps', 0, ...
    'overlap_detected_reps', 0, ...
    'overlap_period', NaN, ...
    'overlap_preamble', struct(), ...
    'search_path', "", ...
    'qm35_start', NaN, ...
    'message', "");
end

function opts = searchOptsFromCfg(cfg)
opts = struct();
opts.fs = 998.4e6;
opts.head_fragment_max_start = cfg.dw_head_fragment_max_start;
opts.qm35_search_pre_s = cfg.dw_qm35_search_pre_s;
opts.qm35_search_post_s = cfg.dw_qm35_search_post_s;
opts.min_detect_reps = 32;
opts.refine_max_abs_start_err_periods = 50;
end

function packed = packDecodedCir(decoded, interferenceOptions)
packed = emptyDecodedPack();
if isempty(decoded)
    return
end
packed.decode_ok = true;
packed.fcs_pass = logical(decoded.payload.fcs_pass);
if isfield(decoded, 'phr')
    packed.phr_secded_pass = logical(decoded.phr.secded_pass);
    packed.psdu_length_bytes = decoded.phr.psdu_length_bytes;
end
if isfield(decoded, 'sfd') && isfield(decoded.sfd, 'name')
    packed.sfd_name = string(decoded.sfd.name);
end
if isfield(decoded.preamble, 'start_sample_uncropped')
    packed.start_sample = double(decoded.preamble.start_sample_uncropped);
else
    packed.start_sample = double(decoded.preamble.start_sample);
end
packed.cfo_hz = decoded.preamble.carrier_frequency_offset_hz;
packed.detected_repetitions = decoded.preamble.detected_repetitions;
if isempty(decoded.payload.bytes)
    packed.payload_hex = "";
else
    packed.payload_hex = string(sprintf('%02X', decoded.payload.bytes));
end
if isfield(decoded, 'cir') && ~isempty(decoded.cir)
    packed.cir = decoded.cir;
    interference = uwbdecoder.analyzeCirInterference( ...
        decoded.cir, interferenceOptions);
    packed.interference = interference;
    packed.interference_state = string(interference.state);
    packed.sic_recommended = logical(interference.sic_recommended);
    packed.early_residual_ratio_db = interference.early_residual_ratio_db;
    packed.early_peak_ratio_db = interference.early_peak_ratio_db;
    packed.interference_occupancy = interference.interference_occupancy;
    packed.first_path_delay_ns = interference.first_path_delay_ns;
end
end

function report = packCancelReport(raw)
report = emptyCancelReport();
fields = fieldnames(report);
for k = 1:numel(fields)
    if isfield(raw, fields{k})
        report.(fields{k}) = raw.(fields{k});
    end
end
if isfield(raw, 'success')
    report.success = logical(raw.success);
else
    report.success = true;
end
end

function metrics = measureCirChange(before, after)
metrics = struct( ...
    'cir_coherence', NaN, ...
    'cir_normalized_residual', NaN, ...
    'before_cir_energy_db', NaN, ...
    'after_cir_energy_db', NaN, ...
    'early_residual_before_db', before.early_residual_ratio_db, ...
    'early_residual_after_db', after.early_residual_ratio_db, ...
    'occupancy_before', before.interference_occupancy, ...
    'occupancy_after', after.interference_occupancy);
if ~isstruct(before.cir) || ~isfield(before.cir, 'values') || ...
        ~isstruct(after.cir) || ~isfield(after.cir, 'values')
    return
end
[b, a] = alignedAverageCir(before.cir, after.cir);
if isempty(b)
    return
end
alpha = (a' * b) / (a' * a + eps);
aAligned = alpha * a;
metrics.cir_coherence = abs(b' * a) / (norm(b) * norm(a) + eps);
metrics.cir_normalized_residual = norm(b - aAligned) / (norm(b) + eps);
metrics.before_cir_energy_db = 10 * log10(mean(abs(b).^2) + eps);
metrics.after_cir_energy_db = 10 * log10(mean(abs(a).^2) + eps);
end

function [beforeValues, afterValues, delay] = alignedAverageCir(beforeCir, afterCir)
delay = beforeCir.delay_ns(:);
beforeValues = beforeCir.values(:);
if numel(afterCir.delay_ns) == numel(delay) && ...
        max(abs(afterCir.delay_ns(:) - delay)) < 1e-9
    afterValues = afterCir.values(:);
else
    afterValues = interp1(afterCir.delay_ns(:), afterCir.values(:), ...
        delay, 'linear', 0);
end
valid = isfinite(beforeValues) & isfinite(afterValues);
beforeValues = beforeValues(valid);
afterValues = afterValues(valid);
delay = delay(valid);
end

function summary = summarizeDumpSic(records)
summary = struct();
summary.n_packets = numel(records);
summary.n_ok = nnz([records.ok]);
summary.qm35_fcs_before = countTrue(records, 'qm35_before', 'fcs_pass');
summary.qm35_fcs_after = countTrue(records, 'qm35_after', 'fcs_pass');
summary.qm35_cancelled = countTrue(records, 'qm35_cancel', 'success');
summary.dw_decoded = countTrue(records, 'dw', 'decode_ok');
summary.dw_fcs = countTrue(records, 'dw', 'fcs_pass');
summary.dw_cancelled = countTrue(records, 'dw_cancel', 'success');
summary.dw_full_cancelled = ...
    nnz(string({records.dw_cancel_mode}) == "full");
summary.dw_preamble_cancelled = ...
    nnz(string({records.dw_cancel_mode}) == "preamble");
summary.dw_false_lock_skipped = ...
    nnz(string({records.dw_search_class}) == "false_lock_skipped");
coherence = nan(numel(records), 1);
for k = 1:numel(records)
    if isfield(records(k).cir_metrics, 'cir_coherence')
        coherence(k) = records(k).cir_metrics.cir_coherence;
    end
end
summary.median_cir_coherence = median(coherence, 'omitnan');
end

function n = countTrue(records, group, fieldName)
n = 0;
for k = 1:numel(records)
    item = records(k).(group);
    if isstruct(item) && isfield(item, fieldName) && item.(fieldName)
        n = n + 1;
    end
end
end

function writeDumpSicTables(pipeline)
records = pipeline.packets;
n = numel(records);
packetId = zeros(n, 1);
ok = false(n, 1);
sicApplied = false(n, 1);
qm35FcsBefore = false(n, 1);
qm35FcsAfter = false(n, 1);
stateBefore = strings(n, 1);
stateAfter = strings(n, 1);
dwFcs = false(n, 1);
dwProfile = strings(n, 1);
qm35CancelDb = nan(n, 1);
dwCancelDb = nan(n, 1);
coherence = nan(n, 1);
residual = nan(n, 1);
earlyBefore = nan(n, 1);
earlyAfter = nan(n, 1);
occBefore = nan(n, 1);
occAfter = nan(n, 1);
errorMessage = strings(n, 1);
dwSearchClass = strings(n, 1);
dwSearchPath = strings(n, 1);
dwOverlapStart = nan(n, 1);
dwHeadStart = nan(n, 1);
dwVisibleReps = zeros(n, 1);
dwCancelMode = strings(n, 1);
for k = 1:n
    r = records(k);
    packetId(k) = r.packet_id;
    ok(k) = r.ok;
    sicApplied(k) = r.sic_applied;
    qm35FcsBefore(k) = r.qm35_before.fcs_pass;
    qm35FcsAfter(k) = r.qm35_after.fcs_pass;
    stateBefore(k) = r.qm35_before.interference_state;
    stateAfter(k) = r.qm35_after.interference_state;
    dwFcs(k) = r.dw.fcs_pass;
    dwProfile(k) = r.dw_profile;
    if r.qm35_cancel.success
        qm35CancelDb(k) = r.qm35_cancel.frame_suppression_db;
    end
    if r.dw_cancel.success
        dwCancelDb(k) = r.dw_cancel.frame_suppression_db;
    end
    coherence(k) = r.cir_metrics.cir_coherence;
    residual(k) = r.cir_metrics.cir_normalized_residual;
    earlyBefore(k) = r.cir_metrics.early_residual_before_db;
    earlyAfter(k) = r.cir_metrics.early_residual_after_db;
    occBefore(k) = r.cir_metrics.occupancy_before;
    occAfter(k) = r.cir_metrics.occupancy_after;
    errorMessage(k) = r.error_message;
    dwSearchClass(k) = r.dw_search_class;
    dwSearchPath(k) = r.dw_search_path;
    dwOverlapStart(k) = r.dw_overlap_start;
    dwHeadStart(k) = r.dw_head_start;
    dwVisibleReps(k) = r.dw_visible_reps;
    dwCancelMode(k) = r.dw_cancel_mode;
end
metrics = table(packetId, ok, sicApplied, qm35FcsBefore, qm35FcsAfter, ...
    stateBefore, stateAfter, dwFcs, dwProfile, qm35CancelDb, dwCancelDb, ...
    coherence, residual, earlyBefore, earlyAfter, occBefore, occAfter, ...
    errorMessage, dwSearchClass, dwSearchPath, dwOverlapStart, ...
    dwHeadStart, dwVisibleReps, dwCancelMode, 'VariableNames', { ...
    'packet_id', 'ok', 'sic_applied', 'qm35_fcs_before', 'qm35_fcs_after', ...
    'state_before', 'state_after', 'dw_fcs_pass', 'dw_profile', ...
    'qm35_cancel_db', 'dw_cancel_db', 'cir_coherence', ...
    'cir_normalized_residual', 'early_residual_before_db', ...
    'early_residual_after_db', 'occupancy_before', 'occupancy_after', ...
    'error_message', 'dw_search_class', 'dw_search_path', ...
    'dw_overlap_start', 'dw_head_start', 'dw_visible_reps', ...
    'dw_cancel_mode'});
writetable(metrics, pipeline.paths.metrics_csv);
save(pipeline.paths.metrics_mat, 'metrics', 'records', '-v7.3');
end

function packetIds = selectDumpPackets(cfg)
if ~isempty(cfg.packet_ids)
    packetIds = cfg.packet_ids(:).';
else
    if isfile(cfg.decode_mat)
        saved = load(cfg.decode_mat, 'results');
        results = saved.results;
        ids = [results.packet_id];
        switch lower(cfg.selection)
            case 'all'
                keep = true(size(ids));
            case 'sic_recommended'
                keep = [results.qm35_sic_recommended];
            otherwise
                states = strings(size(ids));
                for k = 1:numel(results)
                    states(k) = string(results(k).qm35_interference_state);
                end
                keep = states == "interfered";
        end
        packetIds = ids(keep);
    else
        [~, metas] = read_uwb_packet(cfg.iq_file, cfg.jsonl_file);
        packetIds = [metas.packet_id];
        if ~strcmpi(cfg.selection, 'all')
            warning('scheduledDumpSicPipeline:NoDecodeMat', ...
                ['%s not found; processing every dump window. ', ...
                'Run run_decode_scheduled_sc16_dump first to select ', ...
                'only interfered packets.'], cfg.decode_mat);
        end
    end
end
packetIds = unique(double(packetIds), 'stable');
if ~isempty(cfg.max_packets) && numel(packetIds) > cfg.max_packets
    packetIds = packetIds(1:cfg.max_packets);
end
end

function window = loadResampledDumpWindow(packetId, cfg, taps)
[xScaled, meta] = read_uwb_packet(cfg.iq_file, cfg.jsonl_file, packetId);
iqScale = 1;
if isfield(meta, 'iq_scale') && ~isempty(meta.iq_scale)
    iqScale = double(meta.iq_scale);
end
x737 = single(xScaled * iqScale);
interp = 65;
decim = 48;
filterDelay = (numel(taps) - 1) / 2;
x998 = upfirdn(x737, taps, interp, decim);
windowStart = double(fieldOr(meta, 'window_start_sample', ...
    fieldOr(meta, 'start_sample', 0)));
windowStartOut = round((windowStart * interp + filterDelay) / decim);
seededStartOne = NaN;
if isfile(cfg.cpp_truth_csv)
    truth = readtable(cfg.cpp_truth_csv, 'VariableNamingRule', 'preserve');
    row = find(double(truth.packet_id) == double(packetId), 1);
    if ~isempty(row) && ismember('qm35_detected_start', ...
            truth.Properties.VariableNames)
        detectedOut = double(truth.qm35_detected_start(row));
        seededStartOne = round(detectedOut - windowStartOut + 1);
    end
end
if ~(isfinite(seededStartOne) && seededStartOne >= 1 && ...
        seededStartOne <= numel(x998))
    pre = double(fieldOr(meta, 'pre_guard_samples', ...
        fieldOr(meta, 'pre_trigger_samples', 0)));
    seededStartOne = round(pre * interp / decim) + 1;
end
window = struct();
window.x998 = x998;
window.meta = meta;
window.seeded_start_one = seededStartOne;
window.capture_mode = fieldOr(meta, 'capture_mode', 'scheduled');
window.schedule_index = double(fieldOr(meta, 'schedule_index', NaN));
end

function refs = buildPhyReferences()
qm35Opt = struct();
qm35Opt.fs_rx = 998.4e6;
qm35Opt.data_rate = 6.81;
qm35Opt.preamble_repetitions = 64;
qm35Opt.code_index = 9;
qm35Opt.sfd_mode = '4z2';
qm35Opt.cir_skip_initial_repetitions = 10;
qm35Opt.cir_repetitions = 54;
qm35Opt.cir_store_individual_values = true;
qm35Opt.cir_diag_pre_samples = 64;
qm35Opt.cir_diag_post_samples = 64;
qm35Opt.max_psdu_bytes = 127;
qm35Opt.enable_frame_crop = true;
qm35Opt.show_plots = false;
qm35Params = uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), qm35Opt);

refs = struct();
refs.qm35 = struct();
refs.qm35.params = qm35Params;
refs.qm35.reference = uwbdecoder.buildUwbReference(qm35Params);
refs.qm35.sfd = buildSfdTemplates(qm35Params);
refs.qm35.tx = struct( ...
    'fs_tx', 998.4e6, ...
    'phy_mode', 'BPRF', ...
    'ranging', false, ...
    'preamble_repetitions', 64, ...
    'code_index', 9, ...
    'sfd_number', 2, ...
    'sfd_sequence', [], ...
    'peak_amplitude', 1, ...
    'guard_samples', 0, ...
    'require_fcs_pass', true);
refs.qm35.cancel = struct( ...
    'fs_rx', 998.4e6, ...
    'cancellation_mode', 'optimal_complex', ...
    'cfo_fit_last_sync', 64, ...
    'gain_fit_last_sync', 64);

dwSpecs = [
    struct('name', 'dw1000_code10_n256', ...
        'code_index', 10, 'preamble_repetitions', 256, ...
        'cir_repetitions', 64)
    struct('name', 'dw1000_code11_n128', ...
        'code_index', 11, 'preamble_repetitions', 128, ...
        'cir_repetitions', 118)
    ];
refs.dw_profiles = repmat(struct( ...
    'name', '', 'params', struct(), 'reference', [], 'sfd', struct(), ...
    'tx', struct(), 'cancel', struct()), numel(dwSpecs), 1);
for k = 1:numel(dwSpecs)
    dwOpt = struct();
    dwOpt.fs_rx = 998.4e6;
    dwOpt.data_rate = 6.81;
    dwOpt.preamble_repetitions = dwSpecs(k).preamble_repetitions;
    dwOpt.code_index = dwSpecs(k).code_index;
    dwOpt.sfd_mode = 'decawave';
    dwOpt.cir_skip_initial_repetitions = 10;
    dwOpt.cir_repetitions = dwSpecs(k).cir_repetitions;
    dwOpt.cir_store_individual_values = true;
    dwOpt.max_psdu_bytes = 127;
    dwOpt.enable_frame_crop = true;
    dwOpt.show_plots = false;
    dwParams = uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), dwOpt);
    refs.dw_profiles(k).name = dwSpecs(k).name;
    refs.dw_profiles(k).params = dwParams;
    refs.dw_profiles(k).reference = uwbdecoder.buildUwbReference(dwParams);
    refs.dw_profiles(k).sfd = buildSfdTemplates(dwParams);
    refs.dw_profiles(k).tx = struct( ...
        'fs_tx', 998.4e6, ...
        'phy_mode', '802.15.4a', ...
        'ranging', true, ...
        'preamble_repetitions', dwSpecs(k).preamble_repetitions, ...
        'code_index', dwSpecs(k).code_index, ...
        'sfd_number', 0, ...
        'sfd_sequence', [-1; -1; -1; -1; 1; -1; 0; 0], ...
        'peak_amplitude', 1, ...
        'guard_samples', 0, ...
        'require_fcs_pass', true);
    refs.dw_profiles(k).cancel = struct( ...
        'fs_rx', 998.4e6, ...
        'cancellation_mode', 'optimal_complex', ...
        'cfo_fit_last_sync', dwSpecs(k).preamble_repetitions, ...
        'gain_fit_last_sync', dwSpecs(k).preamble_repetitions);
end
end

function templates = buildSfdTemplates(params)
templates = struct( ...
    'decawave', params.decawave_sfd(:), ...
    'ieee', params.ieee_sfd(:), ...
    'sfd4z_1', params.sfd4z_1(:), ...
    'sfd4z_2', params.sfd4z_2(:), ...
    'sfd4z_3', params.sfd4z_3(:), ...
    'sfd4z_4', params.sfd4z_4(:));
end

function taps = loadResamplerTaps(tapsFile)
assert(isfile(tapsFile), 'Missing resampler taps: %s', tapsFile);
fid = fopen(tapsFile, 'rb');
assert(fid >= 0, 'Cannot open taps: %s', tapsFile);
taps = fread(fid, Inf, 'single=>single');
fclose(fid);
assert(~isempty(taps), 'Empty taps: %s', tapsFile);
end

function cfg = normalizeDumpSicConfig(cfg, projectDir)
if ~isfield(cfg, 'dump_dir') || isempty(cfg.dump_dir)
    error('scheduledDumpSicPipeline:MissingDumpDir', ...
        'cfg.dump_dir is required.');
end
cfg.dump_dir = char(strtrim(string(cfg.dump_dir)));
while ~isempty(cfg.dump_dir) && ...
        (cfg.dump_dir(end) == '/' || cfg.dump_dir(end) == '\')
    cfg.dump_dir(end) = [];
end
[~, dumpName] = fileparts(cfg.dump_dir);
switch dumpName
    case 'qm35_scheduled_sc16_dump'
        tag = 'scheduled_sc16_dump';
    case 'qm35_clean_scheduled_sc16_dump'
        tag = 'scheduled_sc16_dump_qm35_clean';
    otherwise
        tag = dumpName;
end
if ~isfield(cfg, 'output_root') || isempty(cfg.output_root)
    cfg.output_root = fullfile(projectDir, 'decoded_results', tag, ...
        'sic_dw1000_removed_qm35_preserved');
end
cfg.output_root = char(cfg.output_root);
cfg.iq_file = fullfile(cfg.dump_dir, 'capture.iq');
cfg.jsonl_file = fullfile(cfg.dump_dir, 'capture.jsonl');
if ~isfile(cfg.iq_file) || ~isfile(cfg.jsonl_file)
    error('scheduledDumpSicPipeline:MissingDump', ...
        'Need capture.iq and capture.jsonl in %s', cfg.dump_dir);
end
if ~isfield(cfg, 'taps_file') || isempty(cfg.taps_file)
    cfg.taps_file = fullfile(projectDir, 'testdata', 'resampler_65_48', ...
        'taps_quality_minorder.txt');
end
if ~isfield(cfg, 'decode_mat') || isempty(cfg.decode_mat)
    cfg.decode_mat = fullfile(projectDir, 'decoded_results', tag, ...
        'scheduled_dump_matlab.mat');
end
if ~isfield(cfg, 'cpp_truth_csv') || isempty(cfg.cpp_truth_csv)
    cfg.cpp_truth_csv = fullfile(projectDir, 'decoded_results', tag, ...
        'scheduled_dump_cpp.csv');
    if ~isfile(cfg.cpp_truth_csv)
        cfg.cpp_truth_csv = fullfile(cfg.dump_dir, 'scheduled_dump_cpp.csv');
    end
end
if ~isfield(cfg, 'selection') || isempty(cfg.selection)
    cfg.selection = 'interfered';
end
if ~isfield(cfg, 'packet_ids')
    cfg.packet_ids = [];
end
if ~isfield(cfg, 'max_packets')
    cfg.max_packets = [];
end
if ~isfield(cfg, 'overwrite') || isempty(cfg.overwrite)
    cfg.overwrite = false;
end
if ~isfield(cfg, 'make_plots') || isempty(cfg.make_plots)
    cfg.make_plots = true;
end
if ~isfield(cfg, 'cir_interference_options') || ...
        isempty(cfg.cir_interference_options)
    cfg.cir_interference_options = struct( ...
        'occupancy_background_margin_db', 3);
end
if ~isfield(cfg, 'dw_head_fragment_max_start') || ...
        isempty(cfg.dw_head_fragment_max_start)
    cfg.dw_head_fragment_max_start = 2000;
end
if ~isfield(cfg, 'dw_qm35_search_pre_s') || ...
        isempty(cfg.dw_qm35_search_pre_s)
    cfg.dw_qm35_search_pre_s = 80e-6;
end
if ~isfield(cfg, 'dw_qm35_search_post_s') || ...
        isempty(cfg.dw_qm35_search_post_s)
    cfg.dw_qm35_search_post_s = 40e-6;
end
if ~isfield(cfg, 'min_visible_sync_for_preamble_sic') || ...
        isempty(cfg.min_visible_sync_for_preamble_sic)
    cfg.min_visible_sync_for_preamble_sic = 64;
end
if ~isfield(cfg, 'enable_preamble_only_sic') || ...
        isempty(cfg.enable_preamble_only_sic)
    cfg.enable_preamble_only_sic = true;
end
if ~isfield(cfg, 'min_alignment_correlation') || ...
        isempty(cfg.min_alignment_correlation)
    cfg.min_alignment_correlation = 0.60;
end
cfg.tag = tag;
cfg.project_directory = projectDir;
end

function paths = buildDumpSicPaths(cfg)
paths = struct();
paths.manifest_file = fullfile(cfg.output_root, 'pipeline_manifest.mat');
paths.metrics_csv = fullfile(cfg.output_root, ...
    'qm35_cir_before_after_dw1000_metrics.csv');
paths.metrics_mat = fullfile(cfg.output_root, ...
    'qm35_cir_before_after_dw1000_metrics.mat');
paths.validation_dir = fullfile(cfg.output_root, 'validation');
end

function record = emptyPacketRecord()
record = struct( ...
    'packet_id', NaN, ...
    'schedule_index', NaN, ...
    'capture_mode', "", ...
    'ok', false, ...
    'sic_applied', false, ...
    'qm35_before', emptyDecodedPack(), ...
    'qm35_after', emptyDecodedPack(), ...
    'qm35_cancel', emptyCancelReport(), ...
    'dw', emptyDecodedPack(), ...
    'dw_profile', "", ...
    'dw_cancel', emptyCancelReport(), ...
    'cir_metrics', struct( ...
        'cir_coherence', NaN, ...
        'cir_normalized_residual', NaN, ...
        'before_cir_energy_db', NaN, ...
        'after_cir_energy_db', NaN, ...
        'early_residual_before_db', NaN, ...
        'early_residual_after_db', NaN, ...
        'occupancy_before', NaN, ...
        'occupancy_after', NaN), ...
    'dw_search_class', "none", ...
    'dw_search_path', "", ...
    'dw_overlap_start', NaN, ...
    'dw_head_start', NaN, ...
    'dw_visible_reps', 0, ...
    'dw_cancel_mode', "none", ...
    'error_id', "", ...
    'error_message', "");
end

function packed = emptyDecodedPack()
packed = struct( ...
    'decode_ok', false, ...
    'fcs_pass', false, ...
    'phr_secded_pass', false, ...
    'psdu_length_bytes', 0, ...
    'sfd_name', "", ...
    'start_sample', NaN, ...
    'cfo_hz', NaN, ...
    'detected_repetitions', 0, ...
    'payload_hex', "", ...
    'cir', struct(), ...
    'interference', struct(), ...
    'interference_state', "invalid", ...
    'sic_recommended', false, ...
    'early_residual_ratio_db', NaN, ...
    'early_peak_ratio_db', NaN, ...
    'interference_occupancy', NaN, ...
    'first_path_delay_ns', NaN);
end

function report = emptyCancelReport()
report = struct( ...
    'success', false, ...
    'message', "", ...
    'start_sample', NaN, ...
    'samples_subtracted', 0, ...
    'alignment_correlation', NaN, ...
    'frame_suppression_db', NaN, ...
    'fitted_cfo_hz', NaN, ...
    'cir_slow_phase_applied', false, ...
    'full_packet_sfo_applied', false);
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

function text = timestampNow()
text = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss Z'));
end
