%% Analyze alternating-polarity QM35 SYNC coding on measured SC16 dumps.
% Evaluate the 2026-08-24 GNU Radio/OpenCode data set:
%   baseline: clean QM35 scheduled SC16 dump;
%   raw     : continuous pre-RX-decoding stream (coded QM35 + DW1000);
%   decoded : scheduled windows after alternating receiver sign decoding.
%
% The raw stream has no uncoded-QM35 control capture. For each window this
% script reconstructs the counterfactual no-coding mixture:
%   q_coded = c(t).*q_clean
%   dw_raw  = raw - alpha_raw*q_coded
%   control = alpha_post*q_clean + dw_raw
%   model   = alpha_post*q_clean + c(t).*dw_raw
%
% control is the no-alternating-coding counterfactual and decoded is the
% measured post-RX-decoding waveform. Both use the same QM35 CIR estimator.
% The result is coherent/noncoherent early-CIR suppression in dB, normalized
% to the clean QM35 first path. A model residual is reported as a sanity
% check for the reconstruction.
%
% Run:
%   matlab -batch "run('run_analyze_qm35_sync_polarity_dw1000_dump.m')"

clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
if isempty(project_dir)
    project_dir = pwd;
end
cd(project_dir);
addpath(project_dir);

%% Data and analysis configuration
data_root = 'F:\UWB基带数据\qm35_sync_polarity_notched_20260824';
baseline_dump_dir = 'F:\UWB基带数据\qm35_clean_scheduled_sc16_dump';
gain_names = {'gain1', 'gain2', 'gain3'};
gain_power_db = [0, -6, -12];
sync_repetitions = 64;
sync_period_native = 750.276923076923;  % 737.28 MS/s, 1.017628 us
native_fs = 737.28e6;
work_fs = 998.4e6;
interp = 65;
decim = 48;
include_edge_windows = false;  % false = locked scheduled windows only
packet_ids = [];               % [] = all windows selected by this mode
representative_packet_id = 4; % [] = automatic first valid representative
save_figures = true;
figure_resolution_dpi = 140;
early_guard_ns = 10;
minimum_early_taps = 16;

% A bounded smoke mode is useful when validating the script on a new dump.
% It is activated only by an explicit task-specific environment variable;
% normal runs still process all three gains and all scheduled windows.
if strcmp(getenv('UWB_SYNC_POLARITY_SMOKE'), '1')
    gain_names = {'gain1'};
    gain_power_db = 0;
    packet_ids = [3, 49, 98];
    save_figures = false;
end

output_root = fullfile(project_dir, 'decoded_results', ...
    'qm35_sync_polarity_dw1000');
if ~isfolder(output_root)
    mkdir(output_root);
end

%% Build the same QM35 CIR reference used by scheduled-dump decoding.
params = uwbdecoder.defaultOptions();
params.fs_rx = work_fs;
params.data_rate = 6.81;
params.preamble_repetitions = sync_repetitions;
params.code_index = 9;
params.sfd_mode = '4z2';
params.cir_skip_initial_repetitions = 10;
params.cir_repetitions = sync_repetitions - params.cir_skip_initial_repetitions;
params.cir_store_individual_values = true;
params.cir_diag_pre_samples = 64;
params.cir_diag_post_samples = 64;
params.max_psdu_bytes = 127;
params.enable_frame_crop = false;
params.show_plots = false;
params.verbose = false;
params = uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), params);
reference = uwbdecoder.buildUwbReference(params);
taps_file = findResamplerTaps(project_dir);
resampler_taps = loadTaps(taps_file);
filter_delay = (numel(resampler_taps) - 1) / 2;

fprintf('Data root     : %s\n', data_root);
fprintf('Baseline dump : %s\n', baseline_dump_dir);
fprintf('Output root   : %s\n', output_root);
fprintf('SYNC period   : %.6f native samples (%.6f us)\n', ...
    sync_period_native, sync_period_native / native_fs * 1e6);

%% Load common geometry and coding alignment table.
baseline_iq = fullfile(baseline_dump_dir, 'capture.iq');
baseline_jsonl = fullfile(baseline_dump_dir, 'capture.jsonl');
if ~isfile(baseline_iq) || ~isfile(baseline_jsonl)
    error('run_analyze_qm35_sync_polarity_dw1000_dump:BaselineMissing', ...
        'Baseline capture.iq/capture.jsonl not found in %s.', baseline_dump_dir);
end
[~, baseline_meta] = read_uwb_packet(baseline_iq, baseline_jsonl, []);
baseline_meta = baseline_meta(:);
if isempty(baseline_meta)
    error('run_analyze_qm35_sync_polarity_dw1000_dump:EmptyBaseline', ...
        'Baseline JSONL contains no windows.');
end

alignment_csv = fullfile(baseline_dump_dir, 'scheduled_dump_cpp.csv');
if ~isfile(alignment_csv)
    alignment_csv = fullfile(baseline_dump_dir, 'scheduled_dump.csv');
end
alignment_table = table();
if isfile(alignment_csv)
    alignment_table = readtable(alignment_csv, 'VariableNamingRule', 'preserve');
end

if isempty(packet_ids)
    packet_ids = double([baseline_meta.packet_id]);
end
packet_ids = packet_ids(:).';
packet_ids = packet_ids(ismember(packet_ids, double([baseline_meta.packet_id])));
if ~include_edge_windows
    keep = false(size(packet_ids));
    for k = 1:numel(packet_ids)
        meta = findMeta(baseline_meta, packet_ids(k));
        keep(k) = strcmpi(fieldText(meta, 'capture_mode', ''), 'scheduled');
    end
    packet_ids = packet_ids(keep);
end
if isempty(packet_ids)
    error('run_analyze_qm35_sync_polarity_dw1000_dump:NoPackets', ...
        'No packet IDs remain after the selected window-mode filter.');
end
fprintf('Windows selected: %d (edge windows included=%d)\n', ...
    numel(packet_ids), include_edge_windows);

%% Analyze each measured interference-gain data set.
all_summary = table();
aggregate_tables = cell(0, 1);
aggregate_reps = cell(0, 1);
aggregate_heatmaps = cell(0, 1);
aggregate_names = {};
aggregate_db = [];
for g = 1:numel(gain_names)
    gain_name = gain_names{g};
    decoded_dir = fullfile(data_root, ['dump_' gain_name]);
    decoded_iq = fullfile(decoded_dir, 'capture.iq');
    decoded_jsonl = fullfile(decoded_dir, 'capture.jsonl');
    raw_file = fullfile(data_root, ...
        sprintf('qm35_sync_polarity_%s_raw.dat', gain_name));
    if ~isfile(decoded_iq) || ~isfile(decoded_jsonl) || ~isfile(raw_file)
        warning('run_analyze_qm35_sync_polarity_dw1000_dump:MissingGain', ...
            'Skipping %s: decoded dump or raw file is missing.', gain_name);
        continue;
    end

    [~, decoded_meta] = read_uwb_packet(decoded_iq, decoded_jsonl, []);
    decoded_meta = decoded_meta(:);
    validateGeometry(baseline_meta, decoded_meta, packet_ids, gain_name);

    gain_output = fullfile(output_root, gain_name);
    if ~isfolder(gain_output)
        mkdir(gain_output);
    end

    fprintf('\n=== %s (relative DW1000 power %+g dB) ===\n', ...
        gain_name, gain_power_db(g));
    cases = repmat(emptyCase(), numel(packet_ids), 1);
    heatmap = emptyHeatmap(packet_ids);
    representative = struct();

    for p = 1:numel(packet_ids)
        packet_id = packet_ids(p);
        bmeta = findMeta(baseline_meta, packet_id);
        dmeta = findMeta(decoded_meta, packet_id);
        [q_native, qmeta] = read_uwb_packet(baseline_iq, baseline_jsonl, packet_id);
        [d_native, ~] = read_uwb_packet(decoded_iq, decoded_jsonl, packet_id);
        n = min([numel(q_native), numel(d_native), ...
            double(bmeta.sample_count), double(dmeta.sample_count)]);
        q_native = q_native(1:n);
        d_native = d_native(1:n);
        raw_native = readRawSc16(raw_file, ...
            double(bmeta.window_start_sample), n, getIqScale(qmeta));
        if numel(raw_native) ~= n
            warning('run_analyze_qm35_sync_polarity_dw1000_dump:ShortRaw', ...
                'packet %d: raw stream shorter than requested; skipping.', packet_id);
            continue;
        end

        detMinusPredOut = lookupAlignment(alignment_table, packet_id, ...
            'qm35_det_minus_pred');
        code_start_native = round(double(bmeta.predicted_start_sample) + ...
            detMinusPredOut * decim / interp);
        local_sample = (0:n-1).';
        global_sample = double(bmeta.window_start_sample) + local_sample;
        [code, code_mask, ~] = makeAlternatingCode(global_sample, ...
            code_start_native, sync_period_native, sync_repetitions);
        q_coded = q_native .* code;
        fit_mask = code_mask & isfinite(q_native);
        alpha_raw = fitComplexScale(q_coded(fit_mask), raw_native(fit_mask));
        alpha_post = fitComplexScale(q_native(fit_mask), d_native(fit_mask));
        dw_raw = raw_native - alpha_raw * q_coded;
        control_native = alpha_post * q_native + dw_raw;
        model_post_native = alpha_post * q_native + code .* dw_raw;
        model_error_db = 20 * log10(norm(d_native - model_post_native) / ...
            (norm(d_native) + eps) + eps);

        q998 = resampleToWorkRate(q_native, resampler_taps, interp, decim);
        control998 = resampleToWorkRate(control_native, resampler_taps, interp, decim);
        post998 = resampleToWorkRate(d_native, resampler_taps, interp, decim);
        window_start_out = round((double(bmeta.window_start_sample) * ...
            interp + filter_delay) / decim);
        code_start_out = round((code_start_native * interp + filter_delay) / decim);
        seed_one = round(code_start_out - window_start_out + 1);
        preamble = struct('start_sample', seed_one, ...
            'measured_period', double(reference.samples_per_symbol), ...
            'detected_repetitions', sync_repetitions, ...
            'search_half_width', 8);

        try
            clean_cir = uwbdecoder.estimateCir(q998, preamble, reference, params);
            control_cir = uwbdecoder.estimateCir(control998, preamble, reference, params);
            post_cir = uwbdecoder.estimateCir(post998, preamble, reference, params);
            clean_info = buildCleanInfo(clean_cir, early_guard_ns, ...
                minimum_early_taps);
            clean_metric = scoreCir(clean_cir, clean_info);
            control_metric = scoreCir(control_cir, clean_info);
            post_metric = scoreCir(post_cir, clean_info);
            cases(p) = makeCase(packet_id, bmeta, gain_power_db(g), ...
                alpha_raw, alpha_post, model_error_db, nnz(code_mask), ...
                clean_metric, control_metric, post_metric);
            cases(p).ok = true;
            heatmap = storeHeatmapRow(heatmap, p, clean_metric, ...
                control_metric, post_metric);
            if isempty(fieldnames(representative)) && ...
                    (isempty(representative_packet_id) || ...
                    packet_id == representative_packet_id)
                representative = struct('packet_id', packet_id, ...
                    'clean_cir', clean_cir, 'control_cir', control_cir, ...
                    'post_cir', post_cir, 'clean_info', clean_info, ...
                    'model_error_db', model_error_db, 'gain_name', gain_name);
            end
        catch err
            cases(p).packet_id = packet_id;
            cases(p).mode = string(fieldText(bmeta, 'capture_mode', ''));
            cases(p).error_message = string(err.message);
            fprintf('packet %d: CIR failed (%s)\n', packet_id, err.message);
        end

        if mod(p, 10) == 0 || p == numel(packet_ids)
            fprintf('  %d/%d windows\n', p, numel(packet_ids));
        end
    end

    cases_table = casesToTable(cases);
    writetable(cases_table, fullfile(gain_output, 'summary.csv'));
    save(fullfile(gain_output, 'analysis.mat'), 'cases', 'cases_table', ...
        'representative', 'heatmap', 'gain_name', 'gain_power_db', ...
        'sync_period_native', '-v7.3');
    printGainSummary(gain_name, gain_power_db(g), cases_table);

    all_summary = [all_summary; aggregateGainRow(gain_name, ...
        gain_power_db(g), cases_table)]; %#ok<AGROW>
    aggregate_tables{end+1, 1} = cases_table; %#ok<AGROW>
    aggregate_reps{end+1, 1} = representative; %#ok<AGROW>
    aggregate_heatmaps{end+1, 1} = heatmap; %#ok<AGROW>
    aggregate_names{end+1, 1} = gain_name; %#ok<AGROW>
    aggregate_db(end+1, 1) = gain_power_db(g); %#ok<AGROW>

    if save_figures && ~isempty(fieldnames(representative))
        plotRepresentative(representative, gain_output, ...
            gain_power_db(g), figure_resolution_dpi);
    end
    if save_figures
        plotCIRHeatmaps(heatmap, cases_table, gain_output, ...
            gain_name, gain_power_db(g), figure_resolution_dpi);
    end
end

if isempty(all_summary)
    error('run_analyze_qm35_sync_polarity_dw1000_dump:NoResults', ...
        'No gain directory produced a valid result.');
end
writetable(all_summary, fullfile(output_root, 'aggregate_summary.csv'));
save(fullfile(output_root, 'aggregate_analysis.mat'), 'all_summary', ...
    'aggregate_tables', 'aggregate_reps', 'aggregate_heatmaps', ...
    'aggregate_names', ...
    'aggregate_db', 'gain_names', 'gain_power_db', 'sync_period_native', '-v7.3');

if save_figures
    plotAggregate(all_summary, aggregate_tables, aggregate_names, ...
        aggregate_db, output_root, figure_resolution_dpi);
end

fprintf('\n=== Aggregate summary ===\n');
disp(all_summary);
fprintf('Results written to %s\n', output_root);

%% Local functions
function file = findResamplerTaps(projectDir)
candidates = { ...
    fullfile(projectDir, 'testdata', 'resampler_65_48', ...
        'taps_quality_minorder.txt'), ...
    fullfile(fileparts(projectDir), 'testdata', 'resampler_65_48', ...
        'taps_quality_minorder.txt')};
file = '';
for k = 1:numel(candidates)
    if isfile(candidates{k})
        file = candidates{k};
        return;
    end
end
error('run_analyze_qm35_sync_polarity_dw1000_dump:MissingTaps', ...
    'Cannot find taps_quality_minorder.txt.');
end

function taps = loadTaps(file)
fid = fopen(file, 'rb');
if fid < 0
    error('run_analyze_qm35_sync_polarity_dw1000_dump:TapsOpen', ...
        'Cannot open %s.', file);
end
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
taps = fread(fid, Inf, 'single=>single');
if isempty(taps)
    error('run_analyze_qm35_sync_polarity_dw1000_dump:EmptyTaps', ...
        'Empty resampler taps: %s.', file);
end
taps = double(taps(:));
end

function meta = findMeta(metaAll, packetId)
idx = find(double([metaAll.packet_id]) == double(packetId), 1);
if isempty(idx)
    error('run_analyze_qm35_sync_polarity_dw1000_dump:PacketNotFound', ...
        'Packet %d is absent from JSONL.', packetId);
end
meta = metaAll(idx);
end

function validateGeometry(baseMeta, otherMeta, ids, gainName)
for k = 1:numel(ids)
    a = findMeta(baseMeta, ids(k));
    b = findMeta(otherMeta, ids(k));
    fields = {'window_start_sample', 'sample_count', 'file_offset_samples'};
    for j = 1:numel(fields)
        name = fields{j};
        if isfield(a, name) && isfield(b, name) && ...
                double(a.(name)) ~= double(b.(name))
            error('run_analyze_qm35_sync_polarity_dw1000_dump:GeometryMismatch', ...
                '%s packet %d differs in %s.', gainName, ids(k), name);
        end
    end
end
end

function value = lookupAlignment(tbl, packetId, column)
value = 0;
if ~istable(tbl) || ~ismember(column, tbl.Properties.VariableNames) || ...
        ~ismember('packet_id', tbl.Properties.VariableNames)
    return;
end
row = find(double(tbl.packet_id) == double(packetId), 1);
if ~isempty(row) && isfinite(double(tbl.(column)(row)))
    value = double(tbl.(column)(row));
end
end

function [code, mask, rep] = makeAlternatingCode(globalSample, ...
        startSample, period, repetitions)
rep = floor((globalSample - startSample) / period);
mask = rep >= 0 & rep < repetitions;
code = ones(size(globalSample));
code(mask) = 1 - 2 * mod(rep(mask), 2);
end

function x = readRawSc16(file, startSample, n, iqScale)
fid = fopen(file, 'rb', 'ieee-le');
if fid < 0
    error('run_analyze_qm35_sync_polarity_dw1000_dump:RawOpen', ...
        'Cannot open raw stream %s.', file);
end
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
if fseek(fid, double(startSample) * 4, 'bof') ~= 0
    error('run_analyze_qm35_sync_polarity_dw1000_dump:RawSeek', ...
        'Cannot seek raw stream to sample %.0f.', startSample);
end
raw = fread(fid, double(n) * 2, 'int16=>double');
if numel(raw) ~= double(n) * 2
    error('run_analyze_qm35_sync_polarity_dw1000_dump:RawShortRead', ...
        'Short raw read at sample %.0f.', startSample);
end
x = complex(raw(1:2:end), raw(2:2:end)) / iqScale;
x = x(:);
end

function scale = getIqScale(meta)
scale = 1;
if isfield(meta, 'iq_scale') && ~isempty(meta.iq_scale) && ...
        double(meta.iq_scale) ~= 0
    scale = double(meta.iq_scale);
end
end

function alpha = fitComplexScale(reference, observed)
reference = reference(:);
observed = observed(:);
valid = isfinite(reference) & isfinite(observed);
if nnz(valid) < 8 || sum(abs(reference(valid)).^2) < eps
    alpha = 1;
    return;
end
alpha = (reference(valid)' * observed(valid)) / ...
    (reference(valid)' * reference(valid) + eps);
end

function y = resampleToWorkRate(x, taps, up, down)
y = upfirdn(x(:), taps, up, down);
y = y(:);
end

function info = buildCleanInfo(cir, guardNs, minTaps)
[H, delay] = selectIndividual(cir);
if isempty(H) || isempty(delay)
    error('run_analyze_qm35_sync_polarity_dw1000_dump:MissingCIR', ...
        'CIR has no individual repetition values.');
end
hBar = mean(H, 2);
powerBar = abs(hBar).^2;
[peakPower, peakIndex] = max(powerBar);
firstDelay = delay(peakIndex);
try
    d = uwbdecoder.analyzeCirInterference(cir, struct());
    if isfield(d, 'valid') && d.valid && isfinite(d.first_path_delay_ns)
        firstDelay = d.first_path_delay_ns;
    end
catch
end
early = delay < (firstDelay - guardNs);
if nnz(early) < minTaps
    [~, nominalZero] = min(abs(delay));
    last = max(1, nominalZero - 6);
    early = false(size(delay));
    early(1:last) = true;
end
info = struct('delay_ns', delay, 'early_mask', early, ...
    'first_path_delay_ns', firstDelay, 'first_path_power', peakPower);
end

function metric = scoreCir(cir, cleanInfo)
[H, delay] = selectIndividual(cir);
metric = emptyMetric();
if isempty(H) || isempty(delay)
    return;
end
hBar = mean(H, 2);
residualPower = max(0, mean(abs(H).^2, 2) - abs(hBar).^2);
early = mapMask(cleanInfo.delay_ns, cleanInfo.early_mask, delay);
if ~any(early)
    return;
end
coherentPower = max(abs(hBar(early)).^2);
residualMedian = median(residualPower(early), 'omitnan');
noncoherent = median(mean(abs(H(early, :)).^2, 2), 'omitnan');
metric.valid = isfinite(coherentPower) && isfinite(residualMedian);
metric.first_path_power = cleanInfo.first_path_power;
metric.first_path_delay_ns = cleanInfo.first_path_delay_ns;
metric.coherent_early_power = coherentPower;
metric.residual_early_power = residualMedian;
metric.noncoherent_early_power = noncoherent;
metric.coherent_early_db = 10 * log10((coherentPower + eps) / ...
    (cleanInfo.first_path_power + eps));
metric.residual_early_db = 10 * log10((residualMedian + eps) / ...
    (cleanInfo.first_path_power + eps));
metric.noncoherent_early_db = 10 * log10((noncoherent + eps) / ...
    (cleanInfo.first_path_power + eps));
metric.delay_ns = delay;
metric.coherent_cir = hBar;
end

function maskOut = mapMask(referenceDelay, referenceMask, delay)
maskOut = false(size(delay));
for k = 1:numel(delay)
    [distance, idx] = min(abs(referenceDelay - delay(k)));
    if ~isempty(idx) && distance < 1e-6
        maskOut(k) = referenceMask(idx);
    end
end
end

function [H, delay] = selectIndividual(cir)
H = [];
delay = [];
if isfield(cir, 'diag_individual_values') && ...
        ~isempty(cir.diag_individual_values)
    H = double(cir.diag_individual_values);
    if isfield(cir, 'diag_delay_ns')
        delay = double(cir.diag_delay_ns(:));
    end
elseif isfield(cir, 'individual_values') && ...
        ~isempty(cir.individual_values)
    H = double(cir.individual_values);
    if isfield(cir, 'delay_ns')
        delay = double(cir.delay_ns(:));
    end
end
if ~isempty(H) && size(H, 1) ~= numel(delay) && ...
        size(H, 2) == numel(delay)
    H = H.';
end
end

function metric = emptyMetric()
metric = struct('valid', false, 'first_path_power', NaN, ...
    'first_path_delay_ns', NaN, 'coherent_early_power', NaN, ...
    'residual_early_power', NaN, 'noncoherent_early_power', NaN, ...
    'coherent_early_db', NaN, 'residual_early_db', NaN, ...
    'noncoherent_early_db', NaN, 'delay_ns', [], 'coherent_cir', []);
end

function heatmap = emptyHeatmap(packetIds)
heatmap = struct('packet_ids', double(packetIds(:)), ...
    'delay_ns', [], 'clean_db', [], 'control_db', [], 'post_db', []);
end

function heatmap = storeHeatmapRow(heatmap, rowIndex, cleanMetric, ...
        controlMetric, postMetric)
if isempty(heatmap.delay_ns)
    heatmap.delay_ns = cleanMetric.delay_ns(:).';
    nRows = numel(heatmap.packet_ids);
    nCols = numel(heatmap.delay_ns);
    heatmap.clean_db = nan(nRows, nCols);
    heatmap.control_db = nan(nRows, nCols);
    heatmap.post_db = nan(nRows, nCols);
end
heatmap.clean_db(rowIndex, :) = metricHeatmapRow(cleanMetric, ...
    heatmap.delay_ns);
heatmap.control_db(rowIndex, :) = metricHeatmapRow(controlMetric, ...
    heatmap.delay_ns, cleanMetric.first_path_power);
heatmap.post_db(rowIndex, :) = metricHeatmapRow(postMetric, ...
    heatmap.delay_ns, cleanMetric.first_path_power);
end

function row = metricHeatmapRow(metric, targetDelay, normalizationPower)
if nargin < 3 || isempty(normalizationPower) || ~isfinite(normalizationPower)
    normalizationPower = metric.first_path_power;
end
row = nan(1, numel(targetDelay));
if isempty(metric.delay_ns) || isempty(metric.coherent_cir) || ...
        ~isfinite(normalizationPower) || normalizationPower <= 0
    return;
end
source = 20 * log10(abs(metric.coherent_cir(:)) / ...
    sqrt(normalizationPower) + eps);
sourceDelay = metric.delay_ns(:);
valid = isfinite(sourceDelay) & isfinite(source);
if nnz(valid) >= 2
    row = interp1(sourceDelay(valid), source(valid), targetDelay, ...
        'linear', NaN);
end
end

function c = emptyCase()
c = struct('packet_id', NaN, 'mode', "", 'gain_power_db', NaN, ...
    'alpha_raw_abs', NaN, 'alpha_post_abs', NaN, 'model_error_db', NaN, ...
    'coded_samples', NaN, 'clean_coherent_early_db', NaN, ...
    'control_coherent_early_db', NaN, 'post_coherent_early_db', NaN, ...
    'clean_residual_early_db', NaN, 'control_residual_early_db', NaN, ...
    'post_residual_early_db', NaN, 'coherent_suppression_db', NaN, ...
    'residual_suppression_db', NaN, ...
    'post_clean_coherent_delta_db', NaN, ...
    'post_clean_residual_delta_db', NaN, 'ok', false, ...
    'error_message', "");
end

function c = makeCase(packetId, meta, gainDb, alphaRaw, alphaPost, ...
        modelErrorDb, codedSamples, cleanMetric, controlMetric, postMetric)
c = emptyCase();
c.packet_id = double(packetId);
c.mode = string(fieldText(meta, 'capture_mode', ''));
c.gain_power_db = gainDb;
c.alpha_raw_abs = abs(alphaRaw);
c.alpha_post_abs = abs(alphaPost);
c.model_error_db = modelErrorDb;
c.coded_samples = codedSamples;
c.clean_coherent_early_db = cleanMetric.coherent_early_db;
c.control_coherent_early_db = controlMetric.coherent_early_db;
c.post_coherent_early_db = postMetric.coherent_early_db;
c.clean_residual_early_db = cleanMetric.residual_early_db;
c.control_residual_early_db = controlMetric.residual_early_db;
c.post_residual_early_db = postMetric.residual_early_db;
c.coherent_suppression_db = controlMetric.coherent_early_db - ...
    postMetric.coherent_early_db;
c.residual_suppression_db = controlMetric.residual_early_db - ...
    postMetric.residual_early_db;
c.post_clean_coherent_delta_db = postMetric.coherent_early_db - ...
    cleanMetric.coherent_early_db;
c.post_clean_residual_delta_db = postMetric.residual_early_db - ...
    cleanMetric.residual_early_db;
end

function tbl = casesToTable(cases)
tbl = struct2table(cases);
end

function row = aggregateGainRow(gainName, gainDb, tbl)
valid = tbl.ok & isfinite(tbl.coherent_suppression_db);
row = table(string(gainName), gainDb, nnz(valid), ...
    median(tbl.coherent_suppression_db(valid), 'omitnan'), ...
    percentileOrNan(tbl.coherent_suppression_db(valid), 10), ...
    percentileOrNan(tbl.coherent_suppression_db(valid), 90), ...
    median(tbl.residual_suppression_db(valid), 'omitnan'), ...
    percentileOrNan(tbl.residual_suppression_db(valid), 10), ...
    percentileOrNan(tbl.residual_suppression_db(valid), 90), ...
    median(tbl.post_clean_coherent_delta_db(valid), 'omitnan'), ...
    median(tbl.post_clean_residual_delta_db(valid), 'omitnan'), ...
    median(tbl.model_error_db(valid), 'omitnan'), ...
    'VariableNames', {'gain', 'gain_power_db', 'valid_windows', ...
    'coherent_suppression_median_db', 'coherent_suppression_p10_db', ...
    'coherent_suppression_p90_db', 'residual_suppression_median_db', ...
    'residual_suppression_p10_db', 'residual_suppression_p90_db', ...
    'post_clean_coherent_delta_median_db', ...
    'post_clean_residual_delta_median_db', 'model_error_median_db'});
end

function value = percentileOrNan(x, p)
x = x(isfinite(x));
if isempty(x)
    value = NaN;
else
    value = prctile(x, p);
end
end

function printGainSummary(gainName, gainDb, tbl)
valid = tbl.ok & isfinite(tbl.coherent_suppression_db);
fprintf(['%s (%+.0f dB): valid=%d/%d, coherent median/p10=', ...
    '%.2f/%.2f dB, residual median/p10=%.2f/%.2f dB, ', ...
    'model residual median=%.2f dB\n'], gainName, gainDb, nnz(valid), ...
    height(tbl), median(tbl.coherent_suppression_db(valid), 'omitnan'), ...
    percentileOrNan(tbl.coherent_suppression_db(valid), 10), ...
    median(tbl.residual_suppression_db(valid), 'omitnan'), ...
    percentileOrNan(tbl.residual_suppression_db(valid), 10), ...
    median(tbl.model_error_db(valid), 'omitnan'));
end

function plotRepresentative(rep, outputDir, gainDb, dpi)
[hc, dc] = selectIndividual(rep.clean_cir);
[h0, d0] = selectIndividual(rep.control_cir);
[h1, d1] = selectIndividual(rep.post_cir);
if isempty(hc) || isempty(h0) || isempty(h1)
    return;
end
hc = mean(hc, 2);
h0 = mean(h0, 2);
h1 = mean(h1, 2);
fp = max(abs(hc).^2);
fig = figure('Name', sprintf('SYNC polarity representative %s', rep.gain_name), ...
    'Color', 'w', 'Position', [80 80 1250 820]);
tiledlayout(2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
nexttile;
plot(dc, 20*log10(abs(hc) / sqrt(fp) + eps), ...
    'LineWidth', 1.2, 'Color', [0.15 0.45 0.85]);
hold on;
plot(d0, 20*log10(abs(h0) / sqrt(fp) + eps), '--', ...
    'LineWidth', 1.1, 'Color', [0.85 0.33 0.10]);
plot(d1, 20*log10(abs(h1) / sqrt(fp) + eps), '-', ...
    'LineWidth', 1.1, 'Color', [0.20 0.60 0.30]);
grid on; ylim([-75 8]);
xlabel('CIR delay (ns)'); ylabel('|coherent CIR| (dB rel. clean FP)');
legend('clean QM35', 'counterfactual no coding', ...
    'measured after alternating RX coding', 'Location', 'best');
title(sprintf('%s, packet %d, gain %+g dB, model residual %.1f dB', ...
    rep.gain_name, rep.packet_id, gainDb, rep.model_error_db));
nexttile;
early = rep.clean_info.early_mask;
plot(dc(early), 20*log10(abs(h0(early)) / sqrt(fp) + eps), ...
    'Color', [0.85 0.33 0.10], 'LineWidth', 1.1);
hold on;
plot(d1(early), 20*log10(abs(h1(early)) / sqrt(fp) + eps), ...
    'Color', [0.20 0.60 0.30], 'LineWidth', 1.1);
grid on;
xlabel('Early CIR delay (ns)'); ylabel('coherent residual (dB)');
legend('counterfactual no coding', 'after alternating coding', ...
    'Location', 'best');
title('Early window used for interference suppression score');
savefig(fig, fullfile(outputDir, 'representative_cir.fig'));
exportgraphics(fig, fullfile(outputDir, 'representative_cir.png'), ...
    'Resolution', dpi);
end

function plotCIRHeatmaps(heatmap, casesTable, outputDir, gainName, ...
        gainDb, dpi)
if isempty(heatmap.delay_ns) || isempty(heatmap.post_db)
    warning('run_analyze_qm35_sync_polarity_dw1000_dump:NoHeatmap', ...
        'No valid CIR rows for %s.', gainName);
    return;
end
validRows = any(isfinite(heatmap.post_db), 2);
if ~any(validRows)
    return;
end
packetIds = heatmap.packet_ids(validRows);
fig = figure('Name', sprintf('All CIR heatmaps %s', gainName), ...
    'Color', 'w', 'Position', [40 40 1450 1120]);
tiledlayout(4, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
common = [-75, 5];

nexttile;
imagesc(heatmap.delay_ns, packetIds, heatmap.clean_db(validRows, :));
axis xy; caxis(common); colormap(turbo); colorbar;
grid on; ylabel('packet id');
title(sprintf('%s: clean QM35 coherent CIR, all windows', gainName));

nexttile;
imagesc(heatmap.delay_ns, packetIds, heatmap.control_db(validRows, :));
axis xy; caxis(common); colormap(turbo); colorbar;
grid on; ylabel('packet id');
title('Counterfactual no-alternating-coding mixture');

nexttile;
imagesc(heatmap.delay_ns, packetIds, heatmap.post_db(validRows, :));
axis xy; caxis(common); colormap(turbo); colorbar;
grid on; ylabel('packet id');
title('Measured mixture after alternating RX coding');

nexttile;
suppression = nan(numel(packetIds), 1);
if istable(casesTable) && ismember('packet_id', casesTable.Properties.VariableNames)
    [found, loc] = ismember(packetIds, double(casesTable.packet_id));
    if ismember('coherent_suppression_db', casesTable.Properties.VariableNames)
        values = double(casesTable.coherent_suppression_db);
        suppression(found) = values(loc(found));
    end
end
imagesc(1, packetIds, suppression);
axis xy; caxis([-5, 35]); colorbar;
grid on; ylabel('packet id'); xlabel('suppression (dB)');
xlim([0.5, 1.5]);
set(gca, 'XTick', 1, 'XTickLabel', {'coherent'});
title(sprintf('Per-window coherent suppression (dB), gain %+g dB', gainDb));

% Make packet IDs readable for both the 96-row default run and shorter
% smoke runs. The first three panels already share the same delay vector.
for ax = findall(fig, 'Type', 'axes').'
    ytick = packetIds(1:max(1, ceil(numel(packetIds) / 12)):end);
    set(ax, 'YTick', ytick);
end
sgtitle(sprintf('QM35 SYNC alternating-polarity CIR heatmaps — %s', gainName));
savefig(fig, fullfile(outputDir, 'all_cir_heatmaps.fig'));
exportgraphics(fig, fullfile(outputDir, 'all_cir_heatmaps.png'), ...
    'Resolution', dpi);
end

function plotAggregate(summary, caseTables, names, gainDb, outputDir, dpi)
fig = figure('Name', 'QM35 SYNC alternating-polarity aggregate', ...
    'Color', 'w', 'Position', [80 80 1250 820]);
tiledlayout(2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
g = 1:height(summary);
nexttile;
bar(g - 0.18, summary.coherent_suppression_median_db, 0.34, ...
    'FaceColor', [0.20 0.60 0.30]);
hold on;
bar(g + 0.18, summary.residual_suppression_median_db, 0.34, ...
    'FaceColor', [0.15 0.45 0.85]);
grid on; yline(0, 'k-');
set(gca, 'XTick', g, 'XTickLabel', cellstr(summary.gain));
xlabel('DW1000 relative power'); ylabel('suppression (dB)');
legend('coherent early CIR', 'noncoherent early CIR', 'Location', 'best');
title('Median suppression: no-coding control -> measured alternating coding');
nexttile; hold on;
colors = lines(numel(caseTables));
for k = 1:numel(caseTables)
    t = caseTables{k};
    x = sort(t.coherent_suppression_db(t.ok & ...
        isfinite(t.coherent_suppression_db)));
    if isempty(x)
        continue;
    end
    plot(x, (1:numel(x)) / numel(x), 'LineWidth', 1.3, ...
        'Color', colors(k, :), ...
        'DisplayName', sprintf('%s (%+g dB)', names{k}, gainDb(k)));
end
grid on;
xlabel('coherent early-CIR suppression (dB)'); ylabel('empirical CDF');
legend('Location', 'southeast');
title('Per-window coherent suppression distribution');
savefig(fig, fullfile(outputDir, 'aggregate_suppression.fig'));
exportgraphics(fig, fullfile(outputDir, 'aggregate_suppression.png'), ...
    'Resolution', dpi);
end

function text = fieldText(s, name, fallback)
value = fallback;
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    value = s.(name);
end
if isstring(value)
    text = char(value);
elseif ischar(value)
    text = value;
else
    text = char(string(value));
end
text = strtrim(text);
if isempty(text)
    text = fallback;
end
end
