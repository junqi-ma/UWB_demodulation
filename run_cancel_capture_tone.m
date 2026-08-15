%% 对 scheduled SC16 dump 去掉约 6200 MHz 的单音
% 写出 capture_notch.iq，jsonl 不用改。逐窗拟合（拼窗不能整文件一根 CW）。
clear;
close all;
clc;

thisDir = fileparts(mfilename('fullpath'));
if isempty(thisDir)
    thisDir = pwd;
end
cd(thisDir);
addpath(thisDir);

dumpDir = 'F:\UWB基带数据\qm35_scheduled_sc16_dump';

opts = struct();
opts.center_hz = 6489.6e6;
opts.rf_hz = 6200e6;       % 约数；实测峰在 ~6256.640 MHz
opts.search_hz = 80e6;
opts.auto = false;
opts.replace = false;      % true 则备份 capture_raw.iq 并覆盖 capture.iq

report = cancel_capture_tone(dumpDir, opts);
disp(report);
