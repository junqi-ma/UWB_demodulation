%% Cancel DW1000 from interfered GNU Radio dump windows and compare CIR.
% Same SIC order as sic_pipeline/run_qm35_dw1000_sic_pipeline.m, but the
% input is a scheduled SC16 dump instead of a continuous 1 s .dat.
%
% The DW1000 search skips window-head fragments (start < 2000) left over
% from a previous packet, then searches the QM35 neighborhood (fallback:
% the suffix) for the overlapping DW packet. Full-decode and preamble-only
% DW cancel both take cfg.min_alignment_correlation (dump default 0.60).
% cancel_uwb_packet_in_iq / cancel_uwb_preamble_in_iq keep their own 0.70
% defaults for other callers. QM35 cancel is unchanged. See
% markdowns/dump窗DW1000_跳过残段与Preamble-only_SIC.md.
clear;
close all;
clc;

thisDir = fileparts(mfilename('fullpath'));
if isempty(thisDir)
    thisDir = pwd;
end
cd(thisDir);
addpath(thisDir);

%% -------------------- User parameters --------------------
dumpDir = 'F:\UWB基带数据\8月20日数据\qm35_sensing_3';
% dumpDir = 'F:\UWB基带数据\qm35_scheduled_sc16_dump';

cfg = struct();
cfg.dump_dir = dumpDir;
cfg.selection = 'interfered';   % 'interfered' | 'sic_recommended' | 'all'
cfg.packet_ids = [];            % nonempty overrides selection
cfg.max_packets = [];           % [] = all selected windows
cfg.overwrite = true;
cfg.make_plots = true;
cfg.use_parallel = true;        % true: process independent packet windows with parfor
cfg.parallel_workers = [];      % []: use/create the default parallel pool
cfg.cir_interference_options = struct( ...
    'occupancy_background_margin_db', 3);
% cfg.dw_head_fragment_max_start = 2000;
% cfg.dw_qm35_search_pre_s = 80e-6;
% cfg.dw_qm35_search_post_s = 40e-6;
% cfg.min_visible_sync_for_preamble_sic = 64;
% cfg.enable_preamble_only_sic = true;  % false: 只消 FCS 过的整包；搜索仍走新包装
cfg.min_alignment_correlation = 0.10;   % dump DW cancel only; 0.70 still the library default

%% -------------------- Run --------------------
pipeline = scheduledDumpSicPipeline(cfg);
assignin('base', 'scheduled_dump_sic_pipeline', pipeline);
