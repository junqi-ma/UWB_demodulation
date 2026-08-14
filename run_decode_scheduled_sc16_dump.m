%% 解析 GNU Radio scheduled SC16 dump，解调 QM35
% 调用 decode_scheduled_sc16_dump：读 capture.iq + capture.jsonl，
% 按窗切开 head / QM35 body / tail，65/48 升到 998.4 MHz，再 decode_uwb
%（code 9 / 64 SYNC / 4z2）。
%
% dump 目录由 testdata/offline_qm35_auto_lock.py --write-sc16 DIR 生成。
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
% 目录内必须有 capture.iq 和 capture.jsonl。
dumpDir = 'F:\UWB基带数据\qm35_scheduled_sc16_dump';
% dumpDir = 'F:\USRP数据解调\scheduled_sc16_dump';

if ~isfile(fullfile(dumpDir, 'capture.iq')) || ...
        ~isfile(fullfile(dumpDir, 'capture.jsonl'))
    error('run_decode_scheduled_sc16_dump:MissingDump', ...
        ['未找到 %s\\capture.iq / capture.jsonl。\n', ...
         '请把 GNU Radio --write-sc16 的输出目录填到 dumpDir。'], dumpDir);
end

%% -------------------- 选项 --------------------
opts = struct();
opts.decode_dw1000 = false;     % true 时同一窗再解 DW1000（code 10 / 256）
opts.max_slots = [];            % [] = 全部 scheduled/provisional；调试可改 8
opts.show_plots = false;
opts.output_dir = fullfile(thisDir, 'decoded_results', 'scheduled_sc16_dump');

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
fprintf('\n  id   mode           k     status           FCS   peaks      CFO   payload\n');
for k = 1:showN
    r = results(k);
    hex = char(r.qm35_payload_hex);
    if numel(hex) > 24
        hex = hex(1:24);
    end
    fprintf(' %3d  %-12s %4.0f  %-16s  %3d  %5.0f  %8.1f  %s\n', ...
        r.packet_id, char(r.capture_mode), r.schedule_index, ...
        char(r.qm35_status), r.qm35_fcs_pass, ...
        r.qm35_detected_repetitions, r.qm35_cfo_hz, hex);
end
if n > showN
    fprintf('  ... %d more rows in scheduled_dump_matlab.csv\n', n - showN);
end

csvFile = fullfile(opts.output_dir, 'scheduled_dump_matlab.csv');
matFile = fullfile(opts.output_dir, 'scheduled_dump_matlab.mat');
fprintf('\nCSV: %s\nMAT: %s\n', csvFile, matFile);

% 工作区留下 results，便于点开某一帧：
%   r = results(4);
%   [x, meta] = read_uwb_packet(fullfile(dumpDir,'capture.iq'), ...
%       fullfile(dumpDir,'capture.jsonl'), r.packet_id);
