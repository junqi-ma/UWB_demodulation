%% 解析 GNU Radio scheduled SC16 dump，解调 QM35
% 调用 decode_scheduled_sc16_dump：读 capture.iq + capture.jsonl，
% 按窗切开 head / QM35 body / tail，65/48 升到 998.4 MHz，再 decode_uwb
%（code 9 / 64 SYNC / 4z2）。
%
% dump 由 testdata/offline_qm35_auto_lock.py --write-sc16 DIR 生成。
% mixed / 无干扰共用本脚本，只改 dumpDir。
clear;
close all;
clc;

thisDir = fileparts(mfilename('fullpath'));
if isempty(thisDir)
    thisDir = pwd;
end
cd(thisDir);
addpath(thisDir);

%% -------------------- 必填：dump 目录 --------------------
% 目录内必须有 capture.iq 和 capture.jsonl。换场景只改这一行。
dumpDir = 'F:\UWB基带数据\qm35_gain1_scheduled_sc16_dump_20260817';
%dumpDir = 'F:\UWB基带数据\qm35_clean_scheduled_sc16_dump';

dumpDir = char(strtrim(string(dumpDir)));
while ~isempty(dumpDir) && (dumpDir(end) == '/' || dumpDir(end) == '\')
    dumpDir = dumpDir(1:end-1);
end
[~, dumpName] = fileparts(dumpDir);

if ~isfile(fullfile(dumpDir, 'capture.iq')) || ...
        ~isfile(fullfile(dumpDir, 'capture.jsonl'))
    error('run_decode_scheduled_sc16_dump:MissingDump', ...
        ['未找到 %s\\capture.iq / capture.jsonl。\n', ...
         '请把 GNU Radio --write-sc16 的输出目录填到 dumpDir。'], dumpDir);
end

%% -------------------- 选项（由 dump 路径区分输出） --------------------
switch dumpName
    case 'qm35_scheduled_sc16_dump'
        tag = 'scheduled_sc16_dump';
    case 'qm35_clean_scheduled_sc16_dump'
        tag = 'scheduled_sc16_dump_qm35_clean';
    otherwise
        tag = dumpName;
end

opts = struct();
opts.decode_dw1000 = false;     % true 时同一窗再解 DW1000（code 10 / 256）
opts.max_slots = [];            % [] = 全部 scheduled/provisional；调试可改 8
opts.show_plots = false;
opts.iq_name = 'capture.iq';
opts.output_dir = fullfile(thisDir, 'decoded_results', tag);
% occupancy 只作对照；state 由预径簇 N 决定。3 dB 仅让 debug occupancy 与旧 CSV 可比。
opts.cir_interference_options = struct( ...
    'occupancy_background_margin_db', 3);

opts.cpp_truth_csv = fullfile(opts.output_dir, 'scheduled_dump_cpp.csv');
if ~isfile(opts.cpp_truth_csv)
    opts.cpp_truth_csv = fullfile(dumpDir, 'scheduled_dump_cpp.csv');
end
if ~isfile(opts.cpp_truth_csv)
    error('run_decode_scheduled_sc16_dump:MissingCppTruth', ...
        ['C++ truth CSV not found:\n  %s\n  %s'], ...
        fullfile(opts.output_dir, 'scheduled_dump_cpp.csv'), ...
        fullfile(dumpDir, 'scheduled_dump_cpp.csv'));
end

fprintf('dump: %s\n', dumpDir);
fprintf('tag:  %s\n', tag);
fprintf('out:  %s\n', opts.output_dir);

%% -------------------- 解调 --------------------
results = decode_scheduled_sc16_dump(dumpDir, opts);

%% -------------------- 摘要 --------------------
n = numel(results);
fcs = [results.qm35_fcs_pass];
ok = [results.qm35_decode_ok];
fprintf('\n=== QM35 scheduled dump ===\n');
fprintf('dump: %s\n', dumpDir);
fprintf('windows: %d  decode_ok: %d  FCS: %d/%d\n', ...
    n, nnz(ok), nnz(fcs), n);
if isfield(results, 'qm35_interference_state')
    states = [results.qm35_interference_state];
    fprintf(['CIR interference: clean=%d  suspected=%d  ', ...
        'interfered=%d  invalid=%d\n'], ...
        nnz(states == "clean"), nnz(states == "suspected"), ...
        nnz(states == "interfered"), nnz(states == "invalid"));
    fprintf('SIC recommended: %d/%d  (N>=1; default SIC uses N>=5)\n', ...
        nnz([results.qm35_sic_recommended]), n);
    if isfield(results, 'qm35_cluster_n')
        clusterN = [results.qm35_cluster_n];
        fprintf('cluster N>=5: %d/%d  (median N=%.0f)\n', ...
            nnz(clusterN >= 5), n, median(clusterN, 'omitnan'));
    end
end

modes = strings(n, 1);
for k = 1:n
    modes(k) = string(results(k).capture_mode);
end
if any(modes ~= "")
    [u, ~, ic] = unique(modes);
    fprintf('capture_mode:');
    for i = 1:numel(u)
        fprintf(' %s=%d', u(i), nnz(ic == i));
    end
    fprintf('\n');
end

showN = min(n, 24);
fprintf(['\n  id   mode           k     status           FCS   ', ...
    'CIR-int         N   maxPk dB   occ  payload\n']);
for k = 1:showN
    r = results(k);
    hex = char(r.qm35_payload_hex);
    if numel(hex) > 24
        hex = hex(1:24);
    end
    clusterN = NaN;
    maxPk = NaN;
    if isfield(r, 'qm35_cluster_n')
        clusterN = r.qm35_cluster_n;
    end
    if isfield(r, 'qm35_cluster_max_peak_db')
        maxPk = r.qm35_cluster_max_peak_db;
    end
    fprintf(' %3d  %-12s %4.0f  %-16s  %3d  %-12s  %3.0f  %7.1f  %5.2f  %s\n', ...
        r.packet_id, char(r.capture_mode), r.schedule_index, ...
        char(r.qm35_status), r.qm35_fcs_pass, ...
        char(r.qm35_interference_state), clusterN, maxPk, ...
        r.qm35_interference_occupancy, hex);
end
if n > showN
    fprintf('  ... %d more rows in scheduled_dump_matlab.csv\n', n - showN);
end

csvFile = fullfile(opts.output_dir, 'scheduled_dump_matlab.csv');
matFile = fullfile(opts.output_dir, 'scheduled_dump_matlab.mat');
fprintf('\nCSV: %s\nMAT: %s\n', csvFile, matFile);

% 单包诊断改 visualize_qm35_cir_interference 里的 packet_index / dump_dir 后再运行。
