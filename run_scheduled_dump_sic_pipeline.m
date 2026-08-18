%% Cancel DW1000 from interfered GNU Radio dump windows and compare CIR.
% Same SIC order as sic_pipeline/run_qm35_dw1000_sic_pipeline.m, but the
% input is a scheduled SC16 dump instead of a continuous 1 s .dat.
%
% The DW1000 search skips window-head fragments (start < 2000) left over
% from a previous packet, then searches the QM35 neighborhood (fallback:
% the suffix) for the overlapping DW packet. Full-decode candidates still
% use cancel_uwb_packet_in_iq (min_alignment_correlation stays 0.70, so
% packet 47 remains rejected); FCS-failed or clipped candidates with
% >= min_visible_sync_for_preamble_sic visible SYNCs are cancelled with the
% SYNC-only cancel_uwb_preamble_in_iq. See
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
dumpDir = 'F:\UWB基带数据\qm35_gain1_scheduled_sc16_dump_20260817';
% dumpDir = 'F:\UWB基带数据\qm35_scheduled_sc16_dump';

cfg = struct();
cfg.dump_dir = dumpDir;
cfg.selection = 'interfered';   % 'interfered' | 'sic_recommended' | 'all'
cfg.packet_ids = [];            % nonempty overrides selection
cfg.max_packets = [];           % [] = all selected windows
cfg.overwrite = true;
cfg.make_plots = true;
cfg.cir_interference_options = struct( ...
    'occupancy_background_margin_db', 3);

%% -------------------- Run --------------------
pipeline = scheduledDumpSicPipeline(cfg);
assignin('base', 'scheduled_dump_sic_pipeline', pipeline);
