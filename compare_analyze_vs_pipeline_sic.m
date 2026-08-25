function compare_analyze_vs_pipeline_sic()
% A/B test: rerun the SIC chain for selected packets in two gate modes:
%   ON  = what run_scheduled_dump_sic_pipeline enforces (align>=0.60)
%   OFF = what analyze_scheduled_dump_sic_stages diagnostic uses (no gates)

projectDir = fileparts(mfilename('fullpath'));
addpath(projectDir);

saved = load(fullfile(projectDir, 'decoded_results', ...
    'qm35_dw1000_sensing_1', 'sic_dw1000_removed_qm35_preserved', ...
    'pipeline_manifest.mat'), 'pipeline');
pipeline = saved.pipeline;
cfg = pipeline.config;

testIds = [5 94 39 22 15 3];
refs = buildRefsLocal();

fprintf('%4s | %-22s | %-22s | %-22s\n', 'pkt', 'stored', ...
    'rerun gates ON (=run)', 'rerun gates OFF (=analyze)');
fprintf('%4s | %-22s | %-22s | %-22s\n', '', '', ...
    'align supp_dB applied', 'align supp_dB applied');

for k = 1:numel(testIds)
    pid = testIds(k);
    record = pipeline.packets([pipeline.packets.packet_id] == pid);
    storedStr = sprintf('applied=%d supp=%5.1f', ...
        logical(record.sic_applied), ...
        fieldN(record.dw_cancel, 'frame_suppression_db'));

    [onRep, offRep] = rerunBothModes(record, cfg, refs);
    fprintf('%4d | %-22s | %5.3f %6.2f %7d | %5.3f %6.2f %7d\n', pid, ...
        storedStr, onRep.align, onRep.supp, onRep.applied, ...
        offRep.align, offRep.supp, offRep.applied);
end
end

function [repOn, repOff] = rerunBothModes(record, cfg, refs)
[xScaled, meta] = read_uwb_packet(cfg.iq_file, cfg.jsonl_file, ...
    record.packet_id);
iqScale = 1;
if isfield(meta, 'iq_scale') && ~isempty(meta.iq_scale)
    iqScale = double(meta.iq_scale);
end
xInput = single(xScaled * iqScale);
inputFs = double(fieldOrL(meta, 'sample_rate', 737.28e6));
if abs(inputFs - 998.4e6) <= 998.4e6 * 1e-9
    xOriginal = xInput;
else
    taps = loadTapsLocal(cfg.taps_file);
    xOriginal = upfirdn(xInput, taps, 65, 48);
end

qmStart = seededStartLocal(record, meta, cfg, numel(xOriginal));
qmDecoded = decode_uwb(refs.qm.params, xOriginal, [], refs.qm.reference, ...
    refs.qm.sfd, 'single', qmStart, true);
[xAfterQm35, ~] = cancel_uwb_packet_in_iq(xOriginal, qmDecoded, ...
    refs.qm.tx, refs.qm.cancel);

dw = refs.dw.(string(record.dw_profile));
isPreambleClass = string(record.dw_search_class) == "preamble_only";
vis = double(record.dw_visible_reps);

shared = struct();
if isPreambleClass
    shared = preambleCirRelaxed(xAfterQm35, dw.reference, dw.params, ...
        double(record.dw_overlap_start));
end

optsOn = baseOpts(dw, vis, isPreambleClass);
optsOn.min_alignment_correlation = 0.60;
optsOn.min_frame_suppression_db = 0.20;

optsOff = baseOpts(dw, vis, isPreambleClass);
optsOff.min_alignment_correlation = 0;
optsOff.min_frame_suppression_db = -Inf;

repOn = runCancel(xOriginal, dw, optsOn, isPreambleClass, vis, shared, ...
    record);
repOff = runCancel(xOriginal, dw, optsOff, isPreambleClass, vis, shared, ...
    record);
end

function opts = baseOpts(dw, vis, isPreambleClass)
if isPreambleClass
    opts = struct();
    opts.cfo_fit_last_sync = vis;
    opts.gain_fit_last_sync = vis;
    opts.min_visible_sync_for_preamble_sic = 64;
else
    opts = dw.cancel;
end
end

function rep = runCancel(xOriginal, dw, opts, isPreambleClass, vis, ...
        shared, record)
rep = struct('align', NaN, 'supp', NaN, 'applied', false, ...
    'message', "");
try
    if isPreambleClass
        [~, cancel] = cancel_uwb_preamble_in_iq(xOriginal, ...
            shared.preamble, shared.cir, shared.txOpt, opts);
    else
        dwDecoded = decode_uwb(dw.params, xOriginal, [], ...
            dw.reference, dw.sfd, 'single', ...
            double(record.dw_overlap_start), true);
        assert(dwDecoded.payload.fcs_pass, 'DW FCS fail on rerun');
        [~, cancel] = cancel_uwb_packet_in_iq(xOriginal, dwDecoded, ...
            dw.tx, opts);
    end
    rep.align = double(cancel.alignment_correlation);
    rep.supp = double(cancel.frame_suppression_db);
    rep.applied = logical(cancel.success);
catch err
    rep.message = string(err.message);
    fprintf('   [%d %s] %s\n', record.packet_id, modeName(opts), ...
        err.message);
end
end

function name = modeName(opts)
if isfield(opts, 'min_alignment_correlation') && ...
        opts.min_alignment_correlation > 0
    name = 'ON ';
else
    name = 'OFF';
end
end

function shared = preambleCirRelaxed(rx, reference, params, seed)
% Same steps as estimate_uwb_preamble_cir but without the strict
% start>=2000 / fallback guard, so a rerun cannot abort on head lock.
rx = rx(:);
preamble = uwbdecoder.detectRepeatedPreamble(rx, reference, params, seed);
period = preamble.measured_period;
if ~(isfinite(period) && period > 0)
    period = reference.samples_per_symbol;
end
visible = min(double(params.preamble_repetitions), ...
    floor((numel(rx) - double(preamble.start_sample) + 1) / period));
visible = max(0, visible);
p = params;
p.preamble_repetitions = min(double(params.preamble_repetitions), visible);
try
    [rxOut, preamble] = uwbdecoder.compensateCarrierOffset(rx, ...
        preamble, reference, p);
catch
    rxOut = rx;
end
cir = uwbdecoder.estimateCir(rxOut, preamble, reference, p);
shared = struct('preamble', preamble, 'cir', cir, ...
    'txOpt', struct('code_index', params.code_index, ...
    'visible_reps', visible, 'fs_tx', 998.4e6, ...
    'phy_mode', '802.15.4a', 'peak_amplitude', 1, 'guard_samples', 0));
end

function refs = buildRefsLocal()
projectDir = fileparts(mfilename('fullpath'));
pllRoot = fullfile(projectDir, 'decoded_results', 'pll_phase_drift_analysis');
qmOpt = struct('fs_rx', 998.4e6, 'data_rate', 6.81, ...
    'preamble_repetitions', 64, 'code_index', 9, 'sfd_mode', '4z2', ...
    'cir_skip_initial_repetitions', 10, 'cir_repetitions', 54, ...
    'cir_store_individual_values', true, 'cir_diag_pre_samples', 64, ...
    'cir_diag_post_samples', 64, 'max_psdu_bytes', 127, ...
    'enable_frame_crop', true, 'show_plots', false);
qmParams = uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), qmOpt);
refs.qm = struct('params', qmParams, ...
    'reference', uwbdecoder.buildUwbReference(qmParams), ...
    'sfd', sfdTemplates(qmParams), ...
    'tx', struct('fs_tx', 998.4e6, 'phy_mode', 'BPRF', 'ranging', false, ...
    'preamble_repetitions', 64, 'code_index', 9, 'sfd_number', 2, ...
    'sfd_sequence', [], 'peak_amplitude', 1, 'guard_samples', 0, ...
    'require_fcs_pass', true), ...
    'cancel', struct('fs_rx', 998.4e6, ...
    'cancellation_mode', 'optimal_complex', 'cfo_fit_last_sync', 64, ...
    'gain_fit_last_sync', 64, 'pll_phase_compensation', ...
    load_uwb_pll_phase_compensation(true, fullfile(pllRoot, ...
    'qm35_new_3', 'subsync_phase_template.csv'), 10, 64)));

specs = struct('name', {'dw1000_code10_n256', 'dw1000_code11_n256'}, ...
    'code_index', {10, 11}, 'cir_repetitions', {64, 118});
refs.dw = struct();
for k = 1:numel(specs)
    dwOpt = struct('fs_rx', 998.4e6, 'data_rate', 6.81, ...
        'preamble_repetitions', 256, ...
        'code_index', specs(k).code_index, 'sfd_mode', 'decawave', ...
        'cir_skip_initial_repetitions', 10, ...
        'cir_repetitions', specs(k).cir_repetitions, ...
        'cir_store_individual_values', true, 'max_psdu_bytes', 127, ...
        'enable_frame_crop', true, 'show_plots', false);
    dwParams = uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), dwOpt);
    refs.dw.(specs(k).name) = struct('params', dwParams, ...
        'reference', uwbdecoder.buildUwbReference(dwParams), ...
        'sfd', sfdTemplates(dwParams), ...
        'tx', struct('fs_tx', 998.4e6, 'phy_mode', '802.15.4a', ...
        'ranging', true, 'preamble_repetitions', 256, ...
        'code_index', specs(k).code_index, 'sfd_number', 0, ...
        'sfd_sequence', [-1; -1; -1; -1; 1; -1; 0; 0], ...
        'peak_amplitude', 1, 'guard_samples', 0, ...
        'require_fcs_pass', true), ...
        'cancel', struct('fs_rx', 998.4e6, ...
        'cancellation_mode', 'optimal_complex', ...
        'cfo_fit_last_sync', 256, 'gain_fit_last_sync', 256, ...
        'pll_phase_compensation', load_uwb_pll_phase_compensation(true, ...
        fullfile(pllRoot, 'dw1000_new_3', ...
        'subsync_phase_template.csv'), 10, 256)));
end
end

function templates = sfdTemplates(params)
templates = struct('decawave', params.decawave_sfd(:), ...
    'ieee', params.ieee_sfd(:), 'sfd4z_1', params.sfd4z_1(:), ...
    'sfd4z_2', params.sfd4z_2(:), 'sfd4z_3', params.sfd4z_3(:), ...
    'sfd4z_4', params.sfd4z_4(:));
end

function startSample = seededStartLocal(record, meta, cfg, sigLen)
windowStart = double(fieldOrL(meta, 'window_start_sample', ...
    fieldOrL(meta, 'start_sample', 0)));
startSample = NaN;
if isfile(cfg.cpp_truth_csv)
    truth = readtable(cfg.cpp_truth_csv, 'VariableNamingRule', 'preserve');
    row = find(double(truth.packet_id) == double(record.packet_id), 1);
    if ~isempty(row)
        startSample = round(double(truth.qm35_detected_start(row)) - ...
            windowStart + 1);
    end
end
if ~(isfinite(startSample) && startSample >= 1 && startSample <= sigLen) ...
        && isfield(meta, 'detected_start_sample') && ...
        ~isempty(meta.detected_start_sample)
    startSample = round(double(meta.detected_start_sample) - ...
        windowStart) + 1;
end
if ~(isfinite(startSample) && startSample >= 1 && startSample <= sigLen)
    pre = double(fieldOrL(meta, 'pre_guard_samples', 0));
    startSample = pre + 1;
end
end

function taps = loadTapsLocal(tapsFile)
fid = fopen(tapsFile, 'rb');
taps = fread(fid, Inf, 'single=>single');
fclose(fid);
end

function v = fieldOrL(s, name, f)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    v = s.(name);
else
    v = f;
end
end

function v = fieldN(s, name)
v = NaN;
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    v = double(s.(name));
end
end
