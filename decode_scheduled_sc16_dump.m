function results = decode_scheduled_sc16_dump(dumpDir, opts)
%DECODE_SCHEDULED_SC16_DUMP Parse a scheduled-extractor SC16 dump and decode.
%   RESULTS = DECODE_SCHEDULED_SC16_DUMP(DUMPDIR) reads
%       DUMPDIR/capture.iq + DUMPDIR/capture.jsonl
%   written by UwbPacketWriter after UwbAutoScheduledExtractorSc16 /
%   UwbScheduledExtractorSc16, slices each window into head / QM35 body /
%   tail, upsamples 65/48 with the quality_minorder taps, then calls
%   decode_uwb.
%
%   RESULTS = DECODE_SCHEDULED_SC16_DUMP(DUMPDIR, OPTS) accepts:
%     .decode_dw1000   (false) also run a DW1000 decode_uwb on the same
%                      998.4 window (code 10 / 256 SYNC / decawave)
%     .max_slots       ([]) limit scheduled+provisional packets
%     .output_dir      (DUMPDIR) CSV / MAT destination
%     .taps_file       ([]) quality_minorder 65/48 taps; default searches
%                      this repo then ../testdata/resampler_65_48/
%     .show_plots      (false)
%     .cir_interference_options (struct) CIR 干扰检测器选项
%
%   Seed convention:
%     seededStartOne = round(pre * 65/48) + 1
%   so the QM35 search starts at the predicted radar origin inside the PDU.
%
%   See also DECODE_UWB, READ_UWB_PACKET, VISUALIZE_QM35_CIR_INTERFERENCE.

if nargin < 1 || isempty(dumpDir)
    error('decode_scheduled_sc16_dump:Usage', ...
        'usage: results = decode_scheduled_sc16_dump(dumpDir [, opts])');
end
if nargin < 2 || isempty(opts)
    opts = struct();
end
if ~isfield(opts, 'decode_dw1000')
    opts.decode_dw1000 = false;
end
if ~isfield(opts, 'max_slots')
    opts.max_slots = [];
end
if ~isfield(opts, 'output_dir')
    opts.output_dir = dumpDir;
end
if ~isfield(opts, 'taps_file')
    opts.taps_file = [];
end
if ~isfield(opts, 'show_plots')
    opts.show_plots = false;
end
if ~isfield(opts, 'iq_name')
    opts.iq_name = 'capture.iq';
end
if ~isfield(opts, 'cpp_truth_csv')
    opts.cpp_truth_csv = [];
end
if ~isfield(opts, 'cir_interference_options')
    opts.cir_interference_options = struct();
end

thisDir = fileparts(mfilename('fullpath'));
if isfile(fullfile(thisDir, 'decode_uwb.m'))
    addpath(thisDir);
else
    addpath(fullfile(fileparts(thisDir), 'UWB_demodulation'));
end

iqFile = fullfile(dumpDir, opts.iq_name);
jsonlFile = fullfile(dumpDir, 'capture.jsonl');
assert(isfile(iqFile), 'Missing %s', iqFile);
assert(isfile(jsonlFile), 'Missing %s', jsonlFile);

tapsFile = opts.taps_file;
if isempty(tapsFile)
    candidates = {
        fullfile(thisDir, 'testdata', 'resampler_65_48', ...
            'taps_quality_minorder.txt')
        fullfile(fileparts(thisDir), 'testdata', 'resampler_65_48', ...
            'taps_quality_minorder.txt')
        };
    for i = 1:numel(candidates)
        if isfile(candidates{i})
            tapsFile = candidates{i};
            break
        end
    end
end
assert(~isempty(tapsFile) && isfile(tapsFile), ...
    'Cannot find taps_quality_minorder.txt; set opts.taps_file');
fid = fopen(tapsFile, 'rb');
assert(fid >= 0, 'Cannot open taps: %s', tapsFile);
taps = fread(fid, Inf, 'single=>single');
fclose(fid);
assert(~isempty(taps), 'Empty taps: %s', tapsFile);
filterDelay = (numel(taps) - 1) / 2;
interp = 65;
decim = 48;
fs998 = 998.4e6;

metas = readDumpJsonl(jsonlFile);
nAll = numel(metas);
keep = true(1, nAll);
if ~isempty(opts.max_slots)
    scheduled = false(1, nAll);
    for k = 1:nAll
        scheduled(k) = isScheduledMeta(metas(k));
    end
    idx = find(scheduled);
    if numel(idx) > opts.max_slots
        drop = idx((opts.max_slots + 1):end);
        keep(drop) = false;
    end
end
metas = metas(keep);
nPkt = numel(metas);
cppTruthStarts = readCppTruthStarts(opts.cpp_truth_csv, metas);

if ~isfolder(opts.output_dir)
    mkdir(opts.output_dir);
end

qm35Opt = struct();
qm35Opt.fs_rx = fs998;
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
qm35Opt.show_plots = opts.show_plots;
qm35Params = uwbdecoder.mergeOptions(uwbdecoder.defaultOptions(), qm35Opt);
qm35Ref = uwbdecoder.buildUwbReference(qm35Params);
qm35SfdTemplates = buildSfdTemplates(qm35Params);

dwRef = [];
dwOpt = struct();
if opts.decode_dw1000
    dwOpt.fs_rx = fs998;
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
    dwSfdTemplates = buildSfdTemplates(dwParams);
else
    dwParams = struct();
    dwSfdTemplates = struct();
end

fprintf(['Scheduled SC16 dump decode: dir=%s packets=%d/%d ', ...
    'taps=%d dw1000=%d cpp_truth=%d\n'], dumpDir, nPkt, nAll, ...
    numel(taps), opts.decode_dw1000, ~isempty(opts.cpp_truth_csv));

cells = cell(nPkt, 1);
cirInterferenceOptions = opts.cir_interference_options;
doDw = opts.decode_dw1000;
usePar = ~isempty(ver('parallel')) && ~isempty(gcp('nocreate'));
if usePar
    parfor k = 1:nPkt
        cells{k} = decodeOne(iqFile, metas(k), taps, filterDelay, ...
            interp, decim, qm35Params, qm35Ref, qm35SfdTemplates, ...
            dwParams, dwRef, dwSfdTemplates, doDw, ...
            cppTruthStarts(k), cirInterferenceOptions);
    end
else
    for k = 1:nPkt
        cells{k} = decodeOne(iqFile, metas(k), taps, filterDelay, ...
            interp, decim, qm35Params, qm35Ref, qm35SfdTemplates, ...
            dwParams, dwRef, dwSfdTemplates, doDw, ...
            cppTruthStarts(k), cirInterferenceOptions);
        if mod(k, 10) == 0 || k == nPkt
            fprintf('  ... %d/%d\n', k, nPkt);
        end
    end
end

results = vertcat(cells{:});
% Keep the full diagnostic arrays in MAT, but only scalar columns in CSV.
tableResults = rmfield(results, 'qm35_cir_interference');
tableOut = struct2table(tableResults);
csvFile = fullfile(opts.output_dir, 'scheduled_dump_matlab.csv');
writetable(tableOut, csvFile);
save(fullfile(opts.output_dir, 'scheduled_dump_matlab.mat'), ...
    'results', '-v7');

qm35Ok = [results.qm35_decode_ok];
qm35Fcs = [results.qm35_fcs_pass];
fprintf('QM35: decoded=%d/%d  FCS=%d/%d\n', ...
    nnz(qm35Ok), nPkt, nnz(qm35Fcs), nPkt);
if opts.decode_dw1000
    dwOk = [results.dw_decode_ok];
    dwFcs = [results.dw_fcs_pass];
    fprintf('DW1000: decoded=%d/%d  FCS=%d/%d\n', ...
        nnz(dwOk), nPkt, nnz(dwFcs), nPkt);
end
fprintf('Wrote %s\n', csvFile);
end

function metas = readDumpJsonl(jsonlFile)
% Field sets differ between acquisition and scheduled lines; union them.
fid = fopen(jsonlFile, 'r');
assert(fid >= 0, 'Cannot open %s', jsonlFile);
cleanup = onCleanup(@() fclose(fid));
raw = {};
while true
    line = fgetl(fid);
    if ~ischar(line)
        break
    end
    line = strtrim(line);
    if isempty(line)
        continue
    end
    raw{end + 1} = jsondecode(line); %#ok<AGROW>
end
if isempty(raw)
    error('decode_scheduled_sc16_dump:EmptyJsonl', 'no JSONL rows in %s', ...
        jsonlFile);
end
keys = {};
for k = 1:numel(raw)
    keys = union(keys, fieldnames(raw{k}), 'stable');
end
template = cell2struct(repmat({[]}, numel(keys), 1), keys, 1);
metas = repmat(template, numel(raw), 1);
for k = 1:numel(raw)
    f = fieldnames(raw{k});
    for i = 1:numel(f)
        metas(k).(f{i}) = raw{k}.(f{i});
    end
end
end

function tf = isScheduledMeta(meta)
mode = '';
if isfield(meta, 'capture_mode') && ~isempty(meta.capture_mode)
    mode = char(meta.capture_mode);
end
tf = any(strcmp(mode, {'scheduled', 'provisional'}));
end

function [pre, body, post] = geometryOf(meta, n)
pre = fieldOr(meta, 'pre_trigger_samples', []);
if isempty(pre)
    pre = fieldOr(meta, 'pre_guard_samples', 0);
end
body = fieldOr(meta, 'capture_samples', []);
post = fieldOr(meta, 'post_guard_samples', []);
if isempty(body)
    if isempty(post)
        body = max(0, n - pre);
    else
        body = max(0, n - pre - post);
    end
end
pre = max(0, min(n, round(double(pre))));
body = max(0, min(n - pre, round(double(body))));
post = max(0, n - pre - body);
end

function v = fieldOr(s, name, fallback)
if isfield(s, name) && ~isempty(s.(name))
    v = s.(name);
else
    v = fallback;
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

function truthStarts = readCppTruthStarts(csvFile, metas)
n = numel(metas);
truthStarts = NaN(n, 1);
if isempty(csvFile)
    return
end
if ~isfile(csvFile)
    error('decode_scheduled_sc16_dump:MissingCppTruth', ...
        'C++ truth CSV not found: %s', csvFile);
end
t = readtable(csvFile, 'VariableNamingRule', 'preserve');
required = {'packet_id', 'window_start_native', ...
    'predicted_start_native', 'qm35_detected_start'};
if ~all(ismember(required, t.Properties.VariableNames))
    error('decode_scheduled_sc16_dump:InvalidCppTruth', ...
        'C++ truth CSV lacks one or more required columns.');
end
packetIds = double(t.packet_id);
if numel(unique(packetIds)) ~= numel(packetIds)
    error('decode_scheduled_sc16_dump:DuplicateCppTruth', ...
        'C++ truth CSV contains duplicate packet_id values.');
end
for k = 1:n
    packetId = double(fieldOr(metas(k), 'packet_id', -1));
    row = find(packetIds == packetId, 1);
    if isempty(row)
        error('decode_scheduled_sc16_dump:MissingCppTruthPacket', ...
            'No C++ truth row for packet_id %d.', packetId);
    end
    windowStart = double(fieldOr(metas(k), 'window_start_sample', ...
        fieldOr(metas(k), 'start_sample', 0)));
    predicted = double(fieldOr(metas(k), 'predicted_start_sample', ...
        windowStart + fieldOr(metas(k), 'pre_trigger_samples', 0)));
    if double(t.window_start_native(row)) ~= windowStart || ...
            double(t.predicted_start_native(row)) ~= predicted
        error('decode_scheduled_sc16_dump:CppTruthGeometryMismatch', ...
            'C++ truth geometry mismatch for packet_id %d.', packetId);
    end
    truthStarts(k) = double(t.qm35_detected_start(row));
end
end

function out = decodeOne(iqFile, meta, taps, filterDelay, interp, decim, ...
        qm35Params, qm35Ref, qm35SfdTemplates, dwParams, dwRef, ...
        dwSfdTemplates, doDw, cppTruthStartOut, cirInterferenceOptions)
n = double(meta.sample_count);
[pre, body, post] = geometryOf(meta, n);
windowStart = fieldOr(meta, 'window_start_sample', ...
    fieldOr(meta, 'start_sample', 0));
predicted = fieldOr(meta, 'predicted_start_sample', ...
    windowStart + pre);
packetId = fieldOr(meta, 'packet_id', -1);
schedIdx = fieldOr(meta, 'schedule_index', -1);
mode = '';
if isfield(meta, 'capture_mode') && ~isempty(meta.capture_mode)
    mode = string(meta.capture_mode);
end

out = emptyResult(packetId, schedIdx, mode, windowStart, predicted, ...
    pre, body, post, n, interp, decim, filterDelay, cppTruthStartOut);

try
    x737 = readDumpIq(iqFile, meta);
    if numel(x737) ~= n
        error('dump:ShortIq', 'IQ length %d != sample_count %d', ...
            numel(x737), n);
    end
    x998 = upfirdn(x737, taps, interp, decim);
    windowStartOut = round((double(windowStart) * interp + filterDelay) / decim);
    predictedOut = round((double(predicted) * interp + filterDelay) / decim);
    if isfinite(cppTruthStartOut)
        seededStartOne = round(double(cppTruthStartOut) - windowStartOut + 1);
        out.qm35_seed_source = "cpp_truth";
    else
        seededStartOne = round(pre * interp / decim) + 1;
        out.qm35_seed_source = "predicted";
    end
    out.qm35_seed_start_one = seededStartOne;
    if seededStartOne < 1 || seededStartOne > numel(x998)
        error('decode_scheduled_sc16_dump:TruthSeedOutOfBounds', ...
            'packet_id %d seed %d is outside resampled window 1:%d', ...
            packetId, seededStartOne, numel(x998));
    end
    result = decode_uwb(qm35Params, x998, [], qm35Ref, ...
        qm35SfdTemplates, 'single', seededStartOne, true);

    detectedOut = windowStartOut + ...
        double(result.preamble.start_sample_uncropped) - 1;

    out.qm35_decode_ok = true;
    out.qm35_fcs_pass = logical(result.payload.fcs_pass);
    if out.qm35_fcs_pass
        out.qm35_status = "success";
    elseif result.phr.secded_pass
        out.qm35_status = "fcs_or_payload_failed";
    else
        out.qm35_status = "phr_failed";
    end
    out.qm35_predicted_start_out = predictedOut;
    out.qm35_detected_start_out = detectedOut;
    out.qm35_det_minus_pred = detectedOut - predictedOut;
    if isfinite(cppTruthStartOut)
        out.qm35_det_minus_cpp_truth = detectedOut - cppTruthStartOut;
    end
    out.qm35_detected_repetitions = result.preamble.detected_repetitions;
    out.qm35_timing_metric = result.preamble.metric_peak;
    out.qm35_cfo_hz = result.preamble.carrier_frequency_offset_hz;
    out.qm35_sfd_correlation = result.preamble.sfd_waveform_correlation;
    out.qm35_phr_secded_pass = logical(result.phr.secded_pass);
    out.qm35_psdu_length = result.phr.psdu_length_bytes;
    if isempty(result.payload.bytes)
        out.qm35_payload_hex = "";
    else
        out.qm35_payload_hex = string(sprintf('%02X', result.payload.bytes));
    end

    cirInterference = uwbdecoder.analyzeCirInterference( ...
        result.cir, cirInterferenceOptions);
    out.qm35_cir_interference = cirInterference;
    out.qm35_cir_interference_valid = cirInterference.valid;
    out.qm35_first_path_delay_ns = cirInterference.first_path_delay_ns;
    out.qm35_early_tap_count = cirInterference.early_tap_count;
    out.qm35_early_residual_ratio_db = ...
        cirInterference.early_residual_ratio_db;
    out.qm35_early_peak_ratio_db = cirInterference.early_peak_ratio_db;
    out.qm35_interference_occupancy = ...
        cirInterference.interference_occupancy;
    out.qm35_interference_state = cirInterference.state;
    out.qm35_interference_confidence = cirInterference.confidence;
    out.qm35_sic_recommended = cirInterference.sic_recommended;
    out.qm35_detector_version = cirInterference.detector_version;
    out.qm35_classifier = cirInterference.classifier;
    out.qm35_cluster_n = cirInterference.cluster_n;
    out.qm35_cluster_max_peak_db = cirInterference.cluster_max_peak_db;
    out.qm35_cluster_max_run_taps = cirInterference.cluster_max_run_taps;
    out.qm35_first_peak_delay_ns = cirInterference.first_peak_delay_ns;
    out.qm35_first_peak_power = cirInterference.first_peak_power;

    if doDw
        dw = decode_uwb(dwParams, x998, [], dwRef, dwSfdTemplates, ...
            'single', [], true);
        out.dw_decode_ok = true;
        out.dw_fcs_pass = logical(dw.payload.fcs_pass);
        if out.dw_fcs_pass
            out.dw_status = "success";
        elseif dw.phr.secded_pass
            out.dw_status = "fcs_or_payload_failed";
        else
            out.dw_status = "phr_failed";
        end
        out.dw_detected_start_out = windowStartOut + ...
            double(dw.preamble.start_sample_uncropped) - 1;
        out.dw_detected_repetitions = dw.preamble.detected_repetitions;
        out.dw_timing_metric = dw.preamble.metric_peak;
        out.dw_cfo_hz = dw.preamble.carrier_frequency_offset_hz;
        out.dw_sfd_correlation = dw.preamble.sfd_waveform_correlation;
        if isempty(dw.payload.bytes)
            out.dw_payload_hex = "";
        else
            out.dw_payload_hex = string(sprintf('%02X', dw.payload.bytes));
        end
    end
catch err
    out.qm35_status = "decode_error";
    out.error_id = string(err.identifier);
    out.error_message = string(err.message);
end
end

function x = readDumpIq(iqFile, meta)
if isfield(meta, 'file') && ~isempty(meta.file)
    f = fullfile(fileparts(iqFile), char(meta.file));
    offset = 0;
else
    f = iqFile;
    offset = double(meta.file_offset_samples);
end
fid = fopen(f, 'rb', 'ieee-le');
if fid < 0
    error('dump:OpenFailed', 'cannot open %s', f);
end
cleanup = onCleanup(@() fclose(fid));
n = double(meta.sample_count);
status = fseek(fid, offset * 4, 'bof');
if status ~= 0
    error('dump:SeekFailed', 'cannot seek offset %d', offset);
end
raw = fread(fid, 2 * n, 'int16=>single');
if numel(raw) ~= 2 * n
    error('dump:ShortRead', 'short read at offset %d', offset);
end
% SC16 as float(int16), no extra 1/32768. decode_uwb is scale-invariant
% for timing / FCS.
x = complex(raw(1:2:end), raw(2:2:end));
end

function out = emptyResult(packetId, schedIdx, mode, windowStart, ...
        predicted, pre, body, post, n, interp, decim, filterDelay, ...
        cppTruthStartOut)
out = struct( ...
    'packet_id', double(packetId), ...
    'schedule_index', double(schedIdx), ...
    'capture_mode', string(mode), ...
    'window_start_native', double(windowStart), ...
    'predicted_start_native', double(predicted), ...
    'pre_samples', double(pre), ...
    'body_samples', double(body), ...
    'post_samples', double(post), ...
    'sample_count', double(n), ...
    'qm35_status', "decode_error", ...
    'qm35_decode_ok', false, ...
    'qm35_fcs_pass', false, ...
    'qm35_predicted_start_out', ...
        round((double(predicted) * interp + filterDelay) / decim), ...
    'qm35_cpp_truth_start_out', double(cppTruthStartOut), ...
    'qm35_seed_source', "", ...
    'qm35_seed_start_one', NaN, ...
    'qm35_detected_start_out', -1, ...
    'qm35_det_minus_pred', NaN, ...
    'qm35_det_minus_cpp_truth', NaN, ...
    'qm35_detected_repetitions', 0, ...
    'qm35_timing_metric', NaN, ...
    'qm35_cfo_hz', NaN, ...
    'qm35_sfd_correlation', NaN, ...
    'qm35_phr_secded_pass', false, ...
    'qm35_psdu_length', 0, ...
    'qm35_payload_hex', "", ...
    'qm35_cir_interference', struct(), ...
    'qm35_cir_interference_valid', false, ...
    'qm35_first_path_delay_ns', NaN, ...
    'qm35_early_tap_count', 0, ...
    'qm35_early_residual_ratio_db', NaN, ...
    'qm35_early_peak_ratio_db', NaN, ...
    'qm35_interference_occupancy', NaN, ...
    'qm35_interference_state', "invalid", ...
    'qm35_interference_confidence', 0, ...
    'qm35_sic_recommended', false, ...
    'qm35_detector_version', NaN, ...
    'qm35_classifier', "", ...
    'qm35_cluster_n', NaN, ...
    'qm35_cluster_max_peak_db', NaN, ...
    'qm35_cluster_max_run_taps', NaN, ...
    'qm35_first_peak_delay_ns', NaN, ...
    'qm35_first_peak_power', NaN, ...
    'dw_status', "", ...
    'dw_decode_ok', false, ...
    'dw_fcs_pass', false, ...
    'dw_detected_start_out', -1, ...
    'dw_detected_repetitions', 0, ...
    'dw_timing_metric', NaN, ...
    'dw_cfo_hz', NaN, ...
    'dw_sfd_correlation', NaN, ...
    'dw_payload_hex', "", ...
    'error_id', "", ...
    'error_message', "");
end
