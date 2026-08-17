%% QM35 雷达呼吸感知：UWB 通信干扰的链路预算与有效距离分析
% 场景：QM35 以雷达模式测量人体呼吸，附近另有一个 UWB 通信模组（如 DW1000 /
% QM35 数传或 ranging）。雷达回波走双向雷达方程，通信干扰走单向 Friis；
% 雷达接收机用自己的 preamble code 做 CIR 相关后，不同码型的通信能量被压到
% 仓库已测得的 cross-code leakage 水平。
%
% 雷达回波（人体胸壁，距离 R）：
%   P_echo(R) = P_radar_eirp * G_rx * lambda^2 * sigma_resp
%               / ((4*pi)^3 * R^4 * L_radar)
%
% 通信到达功率（干扰源距离 D）：
%   P_comm(D) = P_comm_eirp * G_rx * lambda^2
%               / ((4*pi)^2 * D^2 * L_comm)
%
% 雷达 CIR 相关后的等效干扰（码型抑制之后再做 SIC）：
%   P_code = P_comm(D) * duty_cycle * 10^(L_code_dB/10)
%   P_intf = P_code * 10^(L_sic_dB/10)
%   L_sic_dB = 0 表示不做 SIC；评估时默认再抑制 sic_gain_db = 20 dB
%
% 相关器输出等效噪声（时长 T_obs = cir_repetitions * T_sym）：
%   P_noise = k * T0 * NF / T_obs
%
% 呼吸可检测判据（逐包 CIR 主径相位可用）：
%   SIR(R) = P_echo(R) / (P_intf + P_noise)  >=  SIR_min
%   =>  R_max = (K_radar / (SIR_min * (P_intf + P_noise)))^(1/4)
%
% 码型抑制 L_code 默认取 run_analyze_uwb_preamble_code_interference 对
% radar code 9 测得的折叠泄漏（非相干 / 相干 / 单符号）。SIC 再叠加
% sic_gain_db（先按 20 dB 残差）。不依赖采集文件。
%
% 输出：decoded_results/radar_comm_interference/ 下的图、CSV、.mat

clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% -------------------- 可调参数 --------------------
cfg = struct();

% 几何与信道
cfg.fc_hz = 6.4896e9;                 % Channel 5
cfg.bandwidth_hz = 499.2e6;
cfg.G_rx_dbi = 2;                     % QM35 陶瓷/贴片接收增益
cfg.L_radar_db = 3;                   % 雷达双向实现损耗（失配/馈线/非理想相关）
cfg.L_comm_db = 2;                    % 通信单向实现损耗
cfg.R_near_m = 0.2;                   % 雷达方程近场截止
cfg.R_far_m = 20;                     % 扫描与绘图远界
cfg.R_grid_m = logspace(log10(0.2), log10(20), 401);

% 发射功率：默认双方都顶在 FCC/ETSI 平均 EIRP 上限
%   -41.3 dBm/MHz * 499.2 MHz ≈ -14.3 dBm
cfg.P_radar_eirp_dbm = -14.3;
cfg.P_comm_eirp_dbm = -14.3;

% 人体呼吸：选中的 CIR 径对应的胸壁 RCS（不是全身 RCS）
%   浅呼吸 / 典型胸壁 / 较大胸腔 大约 0.001 / 0.03 / 0.10 m^2
cfg.sigma_resp_m2 = 0.03;

% 雷达观测（与 decode 默认 CIR 折叠一致：跳过 PLL 暂态后的相干次数）
phy = uwbdecoder.constants();
cfg.cir_repetitions = 64;
cfg.T_sym_s = phy.PREAMBLE_PERIOD_S;
cfg.packet_interval_s = 350e-6;       % QM35825 雷达周期，仅作注释/占空比参考
cfg.NF_db = 7;
cfg.T0_k = 290;
cfg.sir_min_db = 6;                   % 主径相位可跟踪的最低 SIR

% 干扰几何与码型
cfg.D_comm_m = 1.0;                   % 默认通信模组距离
cfg.duty_cycle = 1.0;                 % 通信覆盖雷达 CIR 窗的时间比例
cfg.radar_code = 9;                   % QM35
cfg.comm_code = 10;                   % 典型 DW1000 / 另一通信模组
cfg.leakage_metric = "noncoherent";   % "single" | "noncoherent" | "coherent"
cfg.L_sic_db = 0;                     % 主扫描默认不加 SIC，便于对照
cfg.sic_gain_db = 20;                 % 要评估的 SIC 抑制（正数，dB）

% 扫描轴
cfg.D_sweep_m = [0.3, 0.5, 1, 2, 5, 10];
cfg.sigma_sweep_m2 = [0.001, 0.01, 0.03, 0.10];
cfg.P_comm_sweep_dbm = [-20, -14.3, -10, 0, 6];
cfg.duty_sweep = [0.05, 0.2, 0.5, 1.0];
cfg.sic_sweep_db = 0:5:50;            % SIC 抑制幅度扫描（正数）

show_plots = true;
output_dir = fullfile(project_dir, 'decoded_results', ...
    'radar_comm_interference');
if ~isfolder(output_dir)
    mkdir(output_dir);
end

%% -------------------- 码型抑制表 --------------------
codeTable = loadCodeSuppressionTable(project_dir);
cfg.L_code_db = lookupCodeLeakage(codeTable, cfg.radar_code, ...
    cfg.comm_code, cfg.leakage_metric);

%% -------------------- 默认配置下的功率与距离 --------------------
link = evaluateLink(cfg);
cfgSic = cfg;
cfgSic.L_sic_db = -cfg.sic_gain_db;
linkSic = evaluateLink(cfgSic);
R_clean = maxRespirationRange(cfg, 0);
R_intf = maxRespirationRange(cfg, link.P_intf_w);
R_sic = maxRespirationRange(cfgSic, linkSic.P_intf_w);
dR = max(R_clean - R_intf, 0);
dR_sic = max(R_clean - R_sic, 0);

fprintf('=== QM35 雷达呼吸感知 vs UWB 通信干扰 ===\n');
fprintf('信道 %.3f GHz, λ = %.1f mm, G_rx = %.1f dBi\n', ...
    cfg.fc_hz/1e9, link.lambda_m*1e3, cfg.G_rx_dbi);
fprintf('雷达 EIRP %+6.1f dBm, 通信 EIRP %+6.1f dBm\n', ...
    cfg.P_radar_eirp_dbm, cfg.P_comm_eirp_dbm);
fprintf('胸壁 RCS %.3f m^2, CIR 折叠 %d 次 (T_obs = %.1f us)\n', ...
    cfg.sigma_resp_m2, cfg.cir_repetitions, link.T_obs_s*1e6);
fprintf('噪声等效功率 %+6.1f dBm, SIR 门限 %+4.1f dB\n', ...
    link.P_noise_dbm, cfg.sir_min_db);
fprintf('雷达 code %d, 通信 code %d, 抑制 %s = %+.1f dB, 占空比 %.0f%%\n', ...
    cfg.radar_code, cfg.comm_code, cfg.leakage_metric, cfg.L_code_db, ...
    100*cfg.duty_cycle);
fprintf(['通信距离 %.2f m: P_comm = %+6.1f dBm, 码后 P_code = %+6.1f dBm, ', ...
    'SIC %+d dB 后 P_intf = %+6.1f dBm\n'], ...
    cfg.D_comm_m, link.P_comm_dbm, link.P_code_dbm, cfg.sic_gain_db, ...
    linkSic.P_intf_dbm);
fprintf('无干扰有效距离           R0     = %.2f m\n', R_clean);
fprintf('仅码型抑制               R_code = %.2f m   (降低 %.2f m, 剩余 %.0f%%)\n', ...
    R_intf, dR, 100*R_intf/max(R_clean, eps));
fprintf('码型 + SIC %+d dB        R_sic  = %.2f m   (降低 %.2f m, 挽回 %.2f m)\n\n', ...
    cfg.sic_gain_db, R_sic, dR_sic, max(R_sic - R_intf, 0));

printSanityChecks(cfg, link, linkSic);

%% -------------------- 典型场景表 --------------------
scenarios = buildScenarios(cfg, codeTable);
scenarioTable = tabulateScenarios(scenarios);
disp(scenarioTable);
writetable(scenarioTable, fullfile(output_dir, 'typical_scenarios.csv'));

%% -------------------- 扫描：人体距离 / 通信距离 / RCS / 功率 / 码型 --------------------
R = cfg.R_grid_m(:);
P_echo_dbm = pow2dbm(radarEchoPower(cfg, R));
P_noise_dbm = link.P_noise_dbm * ones(size(R));

nD = numel(cfg.D_sweep_m);
sir_vs_R = zeros(numel(R), nD);
sir_vs_R_sic = zeros(numel(R), nD);
Rmax_vs_D = zeros(nD, 1);
Rmax_vs_D_sic = zeros(nD, 1);
P_intf_vs_D_dbm = zeros(nD, 1);
P_intf_vs_D_sic_dbm = zeros(nD, 1);
for k = 1:nD
    ck = cfg;
    ck.D_comm_m = cfg.D_sweep_m(k);
    lk = evaluateLink(ck);
    P_intf_vs_D_dbm(k) = lk.P_intf_dbm;
    sir_vs_R(:, k) = echoSirDb(cfg, R, lk.P_intf_w);
    Rmax_vs_D(k) = maxRespirationRange(ck, lk.P_intf_w);

    ckSicD = ck;
    ckSicD.L_sic_db = -cfg.sic_gain_db;
    lkSicD = evaluateLink(ckSicD);
    P_intf_vs_D_sic_dbm(k) = lkSicD.P_intf_dbm;
    sir_vs_R_sic(:, k) = echoSirDb(ckSicD, R, lkSicD.P_intf_w);
    Rmax_vs_D_sic(k) = maxRespirationRange(ckSicD, lkSicD.P_intf_w);
end

metrics = ["single", "noncoherent", "coherent"];
metricLabel = ["单符号互相关", "非相干折叠", "相干折叠"];
Rmax_vs_D_metric = zeros(nD, numel(metrics));
for m = 1:numel(metrics)
    for k = 1:nD
        ck = cfg;
        ck.D_comm_m = cfg.D_sweep_m(k);
        ck.leakage_metric = metrics(m);
        ck.L_code_db = lookupCodeLeakage(codeTable, ck.radar_code, ...
            ck.comm_code, ck.leakage_metric);
        lk = evaluateLink(ck);
        Rmax_vs_D_metric(k, m) = maxRespirationRange(ck, lk.P_intf_w);
    end
end
Rmax_same_code = zeros(nD, 1);
Rmax_same_code_sic = zeros(nD, 1);
Rmax_coh_sic = zeros(nD, 1);
for k = 1:nD
    ck = cfg;
    ck.D_comm_m = cfg.D_sweep_m(k);
    ck.L_code_db = 0;
    lk = evaluateLink(ck);
    Rmax_same_code(k) = maxRespirationRange(ck, lk.P_intf_w);

    ck.L_sic_db = -cfg.sic_gain_db;
    lk = evaluateLink(ck);
    Rmax_same_code_sic(k) = maxRespirationRange(ck, lk.P_intf_w);

    ck = cfg;
    ck.D_comm_m = cfg.D_sweep_m(k);
    ck.leakage_metric = "coherent";
    ck.L_code_db = lookupCodeLeakage(codeTable, ck.radar_code, ...
        ck.comm_code, ck.leakage_metric);
    ck.L_sic_db = -cfg.sic_gain_db;
    lk = evaluateLink(ck);
    Rmax_coh_sic(k) = maxRespirationRange(ck, lk.P_intf_w);
end

nSic = numel(cfg.sic_sweep_db);
Rmax_vs_sic = zeros(nSic, 3);
sicCodeDb = [0, cfg.L_code_db, lookupCodeLeakage(codeTable, ...
    cfg.radar_code, cfg.comm_code, "coherent")];
for k = 1:nSic
    for m = 1:3
        ck = cfg;
        ck.L_code_db = sicCodeDb(m);
        ck.L_sic_db = -cfg.sic_sweep_db(k);
        lk = evaluateLink(ck);
        Rmax_vs_sic(k, m) = maxRespirationRange(ck, lk.P_intf_w);
    end
end

nS = numel(cfg.sigma_sweep_m2);
Rmax_vs_sigma = zeros(nS, nD);
for iS = 1:nS
    for k = 1:nD
        ck = cfg;
        ck.sigma_resp_m2 = cfg.sigma_sweep_m2(iS);
        ck.D_comm_m = cfg.D_sweep_m(k);
        lk = evaluateLink(ck);
        Rmax_vs_sigma(iS, k) = maxRespirationRange(ck, lk.P_intf_w);
    end
end
Rmax_sigma_clean = zeros(nS, 1);
for iS = 1:nS
    ck = cfg;
    ck.sigma_resp_m2 = cfg.sigma_sweep_m2(iS);
    Rmax_sigma_clean(iS) = maxRespirationRange(ck, 0);
end

nP = numel(cfg.P_comm_sweep_dbm);
Rmax_vs_Pcomm = zeros(nP, 1);
for k = 1:nP
    ck = cfg;
    ck.P_comm_eirp_dbm = cfg.P_comm_sweep_dbm(k);
    lk = evaluateLink(ck);
    Rmax_vs_Pcomm(k) = maxRespirationRange(ck, lk.P_intf_w);
end

nU = numel(cfg.duty_sweep);
Rmax_vs_duty = zeros(nU, 1);
for k = 1:nU
    ck = cfg;
    ck.duty_cycle = cfg.duty_sweep(k);
    lk = evaluateLink(ck);
    Rmax_vs_duty(k) = maxRespirationRange(ck, lk.P_intf_w);
end

% 码型对：雷达 code 9 对其它通信码
commCodes = sort(codeTable.code_ids(codeTable.code_ids ~= cfg.radar_code));
Rmax_vs_code = zeros(numel(commCodes), 3);
for iC = 1:numel(commCodes)
    for m = 1:3
        ck = cfg;
        ck.comm_code = commCodes(iC);
        ck.leakage_metric = metrics(m);
        ck.L_code_db = lookupCodeLeakage(codeTable, ck.radar_code, ...
            ck.comm_code, ck.leakage_metric);
        lk = evaluateLink(ck);
        Rmax_vs_code(iC, m) = maxRespirationRange(ck, lk.P_intf_w);
    end
end

% 热图：通信距离 × 码型抑制 → 有效距离 / 距离下降
D_map = logspace(log10(0.3), log10(10), 80);
L_map = linspace(-45, 0, 70);
Rmax_map = zeros(numel(L_map), numel(D_map));
dR_map = zeros(size(Rmax_map));
for iL = 1:numel(L_map)
    for iD = 1:numel(D_map)
        ck = cfg;
        ck.L_code_db = L_map(iL);
        ck.D_comm_m = D_map(iD);
        lk = evaluateLink(ck);
        Rmax_map(iL, iD) = maxRespirationRange(ck, lk.P_intf_w);
        dR_map(iL, iD) = max(R_clean - Rmax_map(iL, iD), 0);
    end
end

%% -------------------- 图 --------------------
visOpts = {'off', 'on'};
figVis = visOpts{1 + show_plots};

fig1 = figure('Name', '雷达回波与通信干扰功率', 'Color', 'w', ...
    'Visible', figVis, 'Position', [80 80 1100 420]);
tiledlayout(fig1, 1, 2, 'Padding', 'compact', 'TileSpacing', 'compact');
nexttile;
semilogx(R, P_echo_dbm, 'k-', 'LineWidth', 2); hold on;
semilogx(R, P_noise_dbm, 'Color', [0.4 0.4 0.4], 'LineStyle', '--', ...
    'LineWidth', 1.4);
for k = 1:nD
    yline(P_intf_vs_D_dbm(k), '-', ...
        sprintf('D=%.1fm', cfg.D_sweep_m(k)), ...
        'LabelHorizontalAlignment', 'left', 'FontSize', 8);
end
grid on;
xlabel('人体距离 R (m)');
ylabel('功率 (dBm)');
title('胸壁回波 / 噪声 / 码后干扰（实线）与 SIC 后（点划）');
legend({'P_{echo}(R)', 'P_{noise}'}, 'Location', 'southwest');
xlim([cfg.R_near_m, 12]);
for k = 1:nD
    yline(P_intf_vs_D_sic_dbm(k), '-.', ...
        'HandleVisibility', 'off', 'LineWidth', 0.8, ...
        'Color', [0.35 0.35 0.35]);
end

nexttile;
cols = lines(nD);
hold on;
for k = 1:nD
    plot(R, sir_vs_R(:, k), 'Color', cols(k, :), 'LineWidth', 1.6, ...
        'DisplayName', sprintf('D = %.1f m', cfg.D_sweep_m(k)));
    if isfinite(Rmax_vs_D(k)) && Rmax_vs_D(k) > 0
        plot(Rmax_vs_D(k), cfg.sir_min_db, 'o', 'Color', cols(k, :), ...
            'MarkerFaceColor', cols(k, :), 'HandleVisibility', 'off');
    end
end
yline(cfg.sir_min_db, 'k--', 'SIR_{min}', 'LineWidth', 1.2, ...
    'HandleVisibility', 'off');
set(gca, 'XScale', 'log');
grid on;
xlabel('人体距离 R (m)');
ylabel('SIR (dB)');
title(sprintf('呼吸 SIR（code %d\\leftarrow%d, %s %+0.1f dB）', ...
    cfg.radar_code, cfg.comm_code, cfg.leakage_metric, cfg.L_code_db));
legend('Location', 'southwest');
xlim([cfg.R_near_m, 12]);
ylim([-30, 40]);
saveFigure(fig1, output_dir, 'fig1_power_and_sir');

fig2 = figure('Name', '有效感知距离随通信距离/码型', 'Color', 'w', ...
    'Visible', figVis, 'Position', [100 80 1100 420]);
tiledlayout(fig2, 1, 2, 'Padding', 'compact', 'TileSpacing', 'compact');
nexttile;
semilogx(cfg.D_sweep_m, R_clean*ones(nD, 1), 'k--', 'LineWidth', 1.5, ...
    'DisplayName', sprintf('无干扰 R_0 = %.2f m', R_clean));
hold on;
semilogx(cfg.D_sweep_m, Rmax_same_code, '-.', 'LineWidth', 1.6, ...
    'DisplayName', '同码 (0 dB 抑制)');
plot(cfg.D_sweep_m, Rmax_vs_D, '-o', 'LineWidth', 1.8, ...
    'DisplayName', sprintf('非相干码 %+.1f dB', cfg.L_code_db));
plot(cfg.D_sweep_m, Rmax_vs_D_sic, '-s', 'LineWidth', 1.8, ...
    'DisplayName', sprintf('非相干码 + SIC %d dB', cfg.sic_gain_db));
plot(cfg.D_sweep_m, Rmax_coh_sic, '-d', 'LineWidth', 1.6, ...
    'DisplayName', sprintf('相干码 + SIC %d dB', cfg.sic_gain_db));
set(gca, 'XScale', 'log');
grid on;
xlabel('通信干扰距离 D (m)');
ylabel('有效呼吸感知距离 R_{max} (m)');
title('码型抑制之外再做 SIC，能把感知距离挽回多少');
legend('Location', 'northwest');

nexttile;
codeCats = categorical(string(commCodes), string(commCodes), 'Ordinal', true);
bar(codeCats, Rmax_vs_code, 'grouped');
yline(R_clean, 'k--', sprintf('无干扰 %.2f m', R_clean), ...
    'LabelHorizontalAlignment', 'left');
grid on;
xlabel(sprintf('通信 preamble code（雷达 code %d, D = %.1f m）', ...
    cfg.radar_code, cfg.D_comm_m));
ylabel('R_{max} (m)');
title('各通信码型残留干扰对应的感知距离');
legend(metricLabel, 'Location', 'eastoutside');
saveFigure(fig2, output_dir, 'fig2_range_vs_distance_and_code');

fig3 = figure('Name', 'RCS / 通信功率 / 占空比', 'Color', 'w', ...
    'Visible', figVis, 'Position', [120 60 1200 400]);
tiledlayout(fig3, 1, 3, 'Padding', 'compact', 'TileSpacing', 'compact');
nexttile;
plot(cfg.sigma_sweep_m2, Rmax_sigma_clean, 'k--o', 'LineWidth', 1.5, ...
    'DisplayName', '无干扰');
hold on;
pickD = [1, 2, 5];
for k = 1:numel(pickD)
    idx = find(cfg.D_sweep_m == pickD(k), 1);
    if isempty(idx)
        continue;
    end
    plot(cfg.sigma_sweep_m2, Rmax_vs_sigma(:, idx), '-o', ...
        'LineWidth', 1.5, 'DisplayName', sprintf('D = %g m', pickD(k)));
end
set(gca, 'XScale', 'log');
grid on;
xlabel('胸壁 RCS \sigma_{resp} (m^2)');
ylabel('R_{max} (m)');
title('呼吸 RCS 越大，抗干扰距离越远');
legend('Location', 'northwest');

nexttile;
plot(cfg.P_comm_sweep_dbm, Rmax_vs_Pcomm, '-s', 'LineWidth', 1.6);
yline(R_clean, 'k--', sprintf('无干扰 %.2f m', R_clean));
grid on;
xlabel(sprintf('通信 EIRP (dBm), D = %.1f m', cfg.D_comm_m));
ylabel('R_{max} (m)');
title('通信功率（含 ETSI +10 dB / +6 dBm）');

nexttile;
semilogx(cfg.duty_sweep, Rmax_vs_duty, '-d', 'LineWidth', 1.6);
yline(R_clean, 'k--', sprintf('无干扰 %.2f m', R_clean));
grid on;
xlabel('通信占空比（覆盖 CIR 窗的比例）');
ylabel('R_{max} (m)');
title(sprintf('占空比, D = %.1f m', cfg.D_comm_m));
xlim([min(cfg.duty_sweep), 1]);
saveFigure(fig3, output_dir, 'fig3_rcs_power_duty');

fig4 = figure('Name', '典型场景距离对比', 'Color', 'w', ...
    'Visible', figVis, 'Position', [80 40 1100 520]);
cats = categorical(scenarioTable.name, scenarioTable.name, 'Ordinal', true);
b = bar(cats, [scenarioTable.R_clean_m, scenarioTable.R_max_m, ...
    scenarioTable.R_max_sic_m]);
b(1).FaceColor = [0.75 0.75 0.75];
b(2).FaceColor = [0.15 0.45 0.75];
b(3).FaceColor = [0.15 0.62 0.35];
ylabel('有效呼吸感知距离 (m)');
title(sprintf('典型参数：无干扰 / 仅码型 / 码型+SIC %d dB', cfg.sic_gain_db));
legend({'无干扰 R_0', '仅码型 R_{code}', ...
    sprintf('码型+SIC %d dB', cfg.sic_gain_db)}, 'Location', 'northeast');
xtickangle(25);
grid on;
for k = 1:height(scenarioTable)
    if scenarioTable.R_max_sic_m(k) - scenarioTable.R_max_m(k) < 0.05
        continue;
    end
    text(k, scenarioTable.R_max_sic_m(k) + 0.12, ...
        sprintf('+%.2fm', scenarioTable.R_max_sic_m(k) - scenarioTable.R_max_m(k)), ...
        'HorizontalAlignment', 'center', 'FontSize', 8, 'Color', [0.05 0.45 0.20]);
end
saveFigure(fig4, output_dir, 'fig4_scenario_bars');

fig5 = figure('Name', '距离下降热图', 'Color', 'w', ...
    'Visible', figVis, 'Position', [90 30 1100 460]);
tiledlayout(fig5, 1, 2, 'Padding', 'compact', 'TileSpacing', 'compact');
nexttile;
pcolor(D_map, L_map, Rmax_map);
shading interp;
set(gca, 'XScale', 'log');
hold on;
contour(D_map, L_map, Rmax_map, [0.5 1 2 3 4 5], 'k', 'ShowText', 'on');
plot(cfg.D_comm_m, cfg.L_code_db, 'wx', 'MarkerSize', 12, 'LineWidth', 2);
plot(cfg.D_comm_m, cfg.L_code_db - cfg.sic_gain_db, 'w+', ...
    'MarkerSize', 12, 'LineWidth', 2);
cb = colorbar;
cb.Label.String = 'R_{max} (m)';
xlabel('通信距离 D (m)');
ylabel('总抑制 L_{code}+L_{sic} (dB)');
title('有干扰时的有效感知距离（× 仅码，+ 码+SIC）');

nexttile;
pcolor(D_map, L_map, dR_map);
shading interp;
set(gca, 'XScale', 'log');
hold on;
contour(D_map, L_map, dR_map, [0.5 1 2 3 4 5], 'k', 'ShowText', 'on');
plot(cfg.D_comm_m, cfg.L_code_db, 'wx', 'MarkerSize', 12, 'LineWidth', 2);
plot(cfg.D_comm_m, cfg.L_code_db - cfg.sic_gain_db, 'w+', ...
    'MarkerSize', 12, 'LineWidth', 2);
cb = colorbar;
cb.Label.String = '\Delta R = R_0 - R_{max} (m)';
xlabel('通信距离 D (m)');
ylabel('总抑制 L_{code}+L_{sic} (dB)');
title(sprintf('感知距离下降（无干扰 R_0 = %.2f m）', R_clean));
saveFigure(fig5, output_dir, 'fig5_heatmap_range_loss');

fig6 = figure('Name', 'SIC 20 dB 对 SIR 与距离的挽回', 'Color', 'w', ...
    'Visible', figVis, 'Position', [80 20 1100 440]);
tiledlayout(fig6, 1, 2, 'Padding', 'compact', 'TileSpacing', 'compact');
nexttile;
idxD1 = find(cfg.D_sweep_m == cfg.D_comm_m, 1);
if isempty(idxD1)
    idxD1 = 1;
end
plot(R, sir_vs_R(:, idxD1), 'LineWidth', 1.8, ...
    'DisplayName', sprintf('仅码型 %+0.1f dB', cfg.L_code_db));
hold on;
plot(R, sir_vs_R_sic(:, idxD1), 'LineWidth', 1.8, ...
    'DisplayName', sprintf('码型+SIC %d dB', cfg.sic_gain_db));
yline(cfg.sir_min_db, 'k--', 'SIR_{min}', 'HandleVisibility', 'off');
if R_intf > 0
    plot(R_intf, cfg.sir_min_db, 'o', 'MarkerFaceColor', [0.15 0.45 0.75], ...
        'HandleVisibility', 'off');
end
if R_sic > 0
    plot(R_sic, cfg.sir_min_db, 's', 'MarkerFaceColor', [0.15 0.62 0.35], ...
        'HandleVisibility', 'off');
end
set(gca, 'XScale', 'log');
grid on;
xlabel('人体距离 R (m)');
ylabel('SIR (dB)');
title(sprintf('D = %.1f m：SIC %d dB 把 SIR 曲线上移', ...
    cfg.D_comm_m, cfg.sic_gain_db));
legend('Location', 'southwest');
xlim([cfg.R_near_m, 12]);
ylim([-30, 40]);

nexttile;
plot(cfg.sic_sweep_db, Rmax_vs_sic(:, 1), '-.', 'LineWidth', 1.6, ...
    'DisplayName', '同码 + SIC');
hold on;
plot(cfg.sic_sweep_db, Rmax_vs_sic(:, 2), '-s', 'LineWidth', 1.8, ...
    'DisplayName', sprintf('非相干码 %+0.1f dB + SIC', cfg.L_code_db));
plot(cfg.sic_sweep_db, Rmax_vs_sic(:, 3), '-d', 'LineWidth', 1.6, ...
    'DisplayName', '相干码 + SIC');
yline(R_clean, 'k--', sprintf('无干扰 %.2f m', R_clean), ...
    'HandleVisibility', 'off');
xline(cfg.sic_gain_db, ':', sprintf('SIC %d dB', cfg.sic_gain_db), ...
    'LabelVerticalAlignment', 'bottom', 'HandleVisibility', 'off');
grid on;
xlabel('SIC 抑制 (dB)');
ylabel('R_{max} (m)');
title(sprintf('D = %.1f m：还要多少 dB SIC 才能回到 R_0', cfg.D_comm_m));
legend('Location', 'northwest');
xlim([min(cfg.sic_sweep_db), max(cfg.sic_sweep_db)]);
saveFigure(fig6, output_dir, 'fig6_sic_recovery');

%% -------------------- 保存数值 --------------------
sweepD = table(cfg.D_sweep_m(:), Rmax_vs_D(:), Rmax_vs_D_sic(:), ...
    (R_clean - Rmax_vs_D(:)), (R_clean - Rmax_vs_D_sic(:)), ...
    max(Rmax_vs_D_sic(:) - Rmax_vs_D(:), 0), ...
    P_intf_vs_D_dbm(:), P_intf_vs_D_sic_dbm(:), ...
    'VariableNames', {'D_comm_m', 'R_max_code_m', 'R_max_sic_m', ...
    'delta_R_code_m', 'delta_R_sic_m', 'recovered_m', ...
    'P_intf_code_dbm', 'P_intf_sic_dbm'});
writetable(sweepD, fullfile(output_dir, 'range_vs_comm_distance.csv'));

sicSweep = table(cfg.sic_sweep_db(:), Rmax_vs_sic(:, 1), ...
    Rmax_vs_sic(:, 2), Rmax_vs_sic(:, 3), ...
    'VariableNames', {'sic_gain_db', 'Rmax_same_code_m', ...
    'Rmax_noncoherent_m', 'Rmax_coherent_m'});
writetable(sicSweep, fullfile(output_dir, 'range_vs_sic_gain.csv'));

codeTbl = table(commCodes(:), Rmax_vs_code(:, 1), Rmax_vs_code(:, 2), ...
    Rmax_vs_code(:, 3), ...
    'VariableNames', {'comm_code', 'Rmax_single_m', ...
    'Rmax_noncoherent_m', 'Rmax_coherent_m'});
writetable(codeTbl, fullfile(output_dir, 'range_vs_comm_code.csv'));

results = struct('cfg', cfg, 'link', link, 'link_sic', linkSic, ...
    'R_clean_m', R_clean, 'R_intf_m', R_intf, 'R_sic_m', R_sic, ...
    'delta_R_m', dR, 'delta_R_sic_m', dR_sic, ...
    'scenarios', scenarioTable, 'sweep_distance', sweepD, ...
    'sic_sweep', sicSweep, 'range_vs_code', codeTbl, ...
    'code_table', codeTable, 'R_grid_m', R, 'sir_vs_R_db', sir_vs_R, ...
    'sir_vs_R_sic_db', sir_vs_R_sic, 'Rmax_map_m', Rmax_map, ...
    'dR_map_m', dR_map, 'D_map_m', D_map, 'L_map_db', L_map);
save(fullfile(output_dir, 'radar_comm_interference.mat'), 'results', '-v7.3');

fprintf('已保存图和表格到 %s\n', output_dir);
fprintf(['结论（D = %.1f m，非相干码 %+0.1f dB）：仅码型把距离从 %.2f m ', ...
    '降到 %.2f m；再做 SIC %d dB 后回到 %.2f m（挽回 %.2f m）。\n'], ...
    cfg.D_comm_m, cfg.L_code_db, R_clean, R_intf, cfg.sic_gain_db, ...
    R_sic, max(R_sic - R_intf, 0));

%% ========================================================================
function codeTable = loadCodeSuppressionTable(projectDir)
% 优先读已有测量 CSV；读不到则回退到仓库中 code 9 行的固化值。

codeTable = struct();
codeTable.code_ids = [3, 4, 9, 10, 11, 12, 13, 14, 15, 16, 21, 22, 23, 24];
codeTable.single_db = nan(size(codeTable.code_ids));
codeTable.noncoherent_db = nan(size(codeTable.code_ids));
codeTable.coherent_db = nan(size(codeTable.code_ids));
codeTable.source = "embedded";

% 固化的雷达 code 9 行（来自 decoded_results/preamble_code_interference）
% 列顺序与 code_ids 一致。
codeTable.single_db(:) = [-9.28, -12.04, 0, -15.30, -15.30, -14.54, ...
    -13.20, -15.30, -13.85, -12.60, -14.54, -13.20, -11.51, -15.30];
codeTable.noncoherent_db(:) = [-21.24, -22.54, 0, -17.81, -17.80, ...
    -18.07, -14.71, -14.82, -15.35, -13.01, -16.00, -15.23, -10.88, -17.05];
codeTable.coherent_db(:) = [-39.51, -40.13, 0, -38.38, -32.48, -38.95, ...
    -34.89, -33.31, -34.29, -29.78, -31.82, -32.87, -30.83, -36.33];

base = fullfile(projectDir, 'decoded_results', 'preamble_code_interference');
files = { ...
    'leakage_single_symbol_db.csv', 'single_db'; ...
    'leakage_fold_noncoh_median_db.csv', 'noncoherent_db'; ...
    'leakage_fold_coh_median_db.csv', 'coherent_db'};
loadedAny = false;
for k = 1:size(files, 1)
    fpath = fullfile(base, files{k, 1});
    if ~isfile(fpath)
        continue;
    end
    raw = readmatrix(fpath);
    if size(raw, 1) < 2 || size(raw, 2) < 3
        continue;
    end
    header = raw(1, 2:end);
    ids = raw(2:end, 1);
    body = raw(2:end, 2:end);
    row = find(ids == 9, 1);
    if isempty(row)
        continue;
    end
    for iC = 1:numel(codeTable.code_ids)
        col = find(header == codeTable.code_ids(iC), 1);
        if isempty(col)
            continue;
        end
        val = body(row, col);
        if isfinite(val)
            codeTable.(files{k, 2})(iC) = val;
        end
    end
    loadedAny = true;
end
if loadedAny
    codeTable.source = "csv";
end
% 同码按定义是 0 dB 泄漏（完全没有码隔离）
own = codeTable.code_ids == 9;
codeTable.single_db(own) = 0;
codeTable.noncoherent_db(own) = 0;
codeTable.coherent_db(own) = 0;
end

function Ldb = lookupCodeLeakage(codeTable, radarCode, commCode, metric)
if radarCode == commCode
    Ldb = 0;
    return;
end
idx = find(codeTable.code_ids == commCode, 1);
if isempty(idx)
    error('run_analyze_uwb_radar_comm_interference:UnknownCode', ...
        'No leakage entry for communication code %d.', commCode);
end
switch string(metric)
    case "single"
        Ldb = codeTable.single_db(idx);
    case "noncoherent"
        Ldb = codeTable.noncoherent_db(idx);
    case "coherent"
        Ldb = codeTable.coherent_db(idx);
    otherwise
        error('run_analyze_uwb_radar_comm_interference:BadMetric', ...
            'leakage_metric must be single, noncoherent, or coherent.');
end
if ~isfinite(Ldb)
    error('run_analyze_uwb_radar_comm_interference:MissingLeakage', ...
        'Leakage for comm code %d / metric %s is not finite.', ...
        commCode, metric);
end
end

function link = evaluateLink(cfg)
phy = uwbdecoder.constants();
link = struct();
link.lambda_m = phy.SPEED_OF_LIGHT / cfg.fc_hz;
link.T_obs_s = cfg.cir_repetitions * cfg.T_sym_s;
kB = 1.380649e-23;
link.P_noise_w = kB * cfg.T0_k * db2pow(cfg.NF_db) / link.T_obs_s;
link.P_noise_dbm = pow2dbm(link.P_noise_w);
link.P_comm_w = friisPower(cfg, cfg.D_comm_m);
link.P_comm_dbm = pow2dbm(link.P_comm_w);
if ~isfield(cfg, 'L_sic_db') || isempty(cfg.L_sic_db) || ~isfinite(cfg.L_sic_db)
    Lsic = 0;
else
    Lsic = cfg.L_sic_db;
end
link.L_sic_db = Lsic;
link.P_code_w = link.P_comm_w * cfg.duty_cycle * db2pow(cfg.L_code_db);
link.P_code_dbm = pow2dbm(link.P_code_w);
link.P_intf_w = link.P_code_w * db2pow(Lsic);
link.P_intf_dbm = pow2dbm(link.P_intf_w);
link.K_radar = radarRangeConstant(cfg);
end

function K = radarRangeConstant(cfg)
phy = uwbdecoder.constants();
lambda = phy.SPEED_OF_LIGHT / cfg.fc_hz;
P_eirp = dbm2pow(cfg.P_radar_eirp_dbm);
G_rx = db2pow(cfg.G_rx_dbi);
L = db2pow(cfg.L_radar_db);
K = P_eirp * G_rx * lambda^2 * cfg.sigma_resp_m2 / ((4*pi)^3 * L);
end

function P = radarEchoPower(cfg, R)
R = max(R, cfg.R_near_m);
P = radarRangeConstant(cfg) ./ (R.^4);
end

function P = friisPower(cfg, D)
phy = uwbdecoder.constants();
lambda = phy.SPEED_OF_LIGHT / cfg.fc_hz;
P_eirp = dbm2pow(cfg.P_comm_eirp_dbm);
G_rx = db2pow(cfg.G_rx_dbi);
L = db2pow(cfg.L_comm_db);
D = max(D, cfg.R_near_m);
P = P_eirp * G_rx * lambda^2 ./ ((4*pi)^2 * D.^2 * L);
end

function sirDb = echoSirDb(cfg, R, P_intf)
P_echo = radarEchoPower(cfg, R);
link = evaluateLink(cfg);
sirDb = 10*log10(P_echo ./ (P_intf + link.P_noise_w + eps));
end

function Rmax = maxRespirationRange(cfg, P_intf)
link = evaluateLink(cfg);
den = db2pow(cfg.sir_min_db) * (P_intf + link.P_noise_w);
if den <= 0 || ~isfinite(den)
    Rmax = cfg.R_far_m;
    return;
end
Rmax = (link.K_radar / den)^(1/4);
if ~isfinite(Rmax) || Rmax < cfg.R_near_m
    Rmax = 0;
elseif Rmax > cfg.R_far_m
    Rmax = cfg.R_far_m;
end
end

function scenarios = buildScenarios(cfg, codeTable)
% 一组可对照的典型室内参数。每行只改相对默认配置有意义的字段。
% 场景本身按“仅码型”计算，并额外给出叠加 SIC 后的距离。
base = cfg;
base.L_sic_db = 0;
Lnon = lookupCodeLeakage(codeTable, 9, 10, "noncoherent");
Lcoh = lookupCodeLeakage(codeTable, 9, 10, "coherent");
Lsing = lookupCodeLeakage(codeTable, 9, 10, "single");
L23 = lookupCodeLeakage(codeTable, 9, 23, "noncoherent");
sicGain = 20;
if isfield(cfg, 'sic_gain_db') && isfinite(cfg.sic_gain_db)
    sicGain = cfg.sic_gain_db;
end

defs = { ...
    "无干扰",              {}, {0}; ...
    "0.5 m 桌面, 非相干",  {"D_comm_m", "L_code_db"}, {0.5, Lnon}; ...
    "1 m, 非相干 9←10",    {"D_comm_m", "L_code_db"}, {1.0, Lnon}; ...
    "2 m 同室, 非相干",    {"D_comm_m", "L_code_db"}, {2.0, Lnon}; ...
    "5 m 同室, 非相干",    {"D_comm_m", "L_code_db"}, {5.0, Lnon}; ...
    "1 m, 相干 9←10",      {"D_comm_m", "L_code_db"}, {1.0, Lcoh}; ...
    "1 m, 单符号",         {"D_comm_m", "L_code_db"}, {1.0, Lsing}; ...
    "1 m, 同码",           {"D_comm_m", "L_code_db"}, {1.0, 0}; ...
    "1 m, 弱隔离码 23",    {"D_comm_m", "comm_code", "L_code_db"}, {1.0, 23, L23}; ...
    "1 m, 占空比 20%",     {"D_comm_m", "duty_cycle", "L_code_db"}, {1.0, 0.2, Lnon}; ...
    "1 m, 浅呼吸 0.001",   {"D_comm_m", "sigma_resp_m2", "L_code_db"}, {1.0, 0.001, Lnon}; ...
    "1 m, 大 RCS 0.10",    {"D_comm_m", "sigma_resp_m2", "L_code_db"}, {1.0, 0.10, Lnon}; ...
    "2 m, ETSI +6 dBm",    {"D_comm_m", "P_comm_eirp_dbm", "L_code_db"}, {2.0, 6, Lnon}; ...
    "2 m, 通信 -20 dBm",   {"D_comm_m", "P_comm_eirp_dbm", "L_code_db"}, {2.0, -20, Lnon} ...
    };

n = size(defs, 1);
scenarios = struct('name', cell(n, 1), 'cfg', [], 'R_clean_m', [], ...
    'R_max_m', [], 'R_max_sic_m', [], 'delta_R_m', [], 'P_intf_dbm', [], ...
    'P_intf_sic_dbm', [], 'L_code_db', [], 'sic_gain_db', []);
for k = 1:n
    ck = base;
    fields = defs{k, 2};
    vals = defs{k, 3};
    for iF = 1:numel(fields)
        ck.(fields{iF}) = vals{iF};
    end
    ckSic = ck;
    ckSic.L_sic_db = -sicGain;
    if k == 1
        Pint = 0;
        PintSic = 0;
        Lint = -Inf;
        Pint_dbm = -Inf;
        PintSic_dbm = -Inf;
        ck.D_comm_m = NaN;
    else
        lk = evaluateLink(ck);
        lkSic = evaluateLink(ckSic);
        Pint = lk.P_intf_w;
        PintSic = lkSic.P_intf_w;
        Lint = ck.L_code_db;
        Pint_dbm = lk.P_intf_dbm;
        PintSic_dbm = lkSic.P_intf_dbm;
    end
    R0 = maxRespirationRange(ck, 0);
    Rm = maxRespirationRange(ck, Pint);
    RmSic = maxRespirationRange(ckSic, PintSic);
    scenarios(k).name = defs{k, 1};
    scenarios(k).cfg = ck;
    scenarios(k).R_clean_m = R0;
    scenarios(k).R_max_m = Rm;
    scenarios(k).R_max_sic_m = RmSic;
    scenarios(k).delta_R_m = max(R0 - Rm, 0);
    scenarios(k).P_intf_dbm = Pint_dbm;
    scenarios(k).P_intf_sic_dbm = PintSic_dbm;
    scenarios(k).L_code_db = Lint;
    scenarios(k).sic_gain_db = sicGain;
end
end

function T = tabulateScenarios(scenarios)
n = numel(scenarios);
name = strings(n, 1);
D_comm_m = zeros(n, 1);
sigma_m2 = zeros(n, 1);
P_comm_dbm = zeros(n, 1);
duty = zeros(n, 1);
L_code_db = zeros(n, 1);
sic_gain_db = zeros(n, 1);
P_intf_dbm = zeros(n, 1);
P_intf_sic_dbm = zeros(n, 1);
R_clean_m = zeros(n, 1);
R_max_m = zeros(n, 1);
R_max_sic_m = zeros(n, 1);
delta_R_m = zeros(n, 1);
recovered_m = zeros(n, 1);
loss_pct = zeros(n, 1);
for k = 1:n
    s = scenarios(k);
    name(k) = s.name;
    D_comm_m(k) = s.cfg.D_comm_m;
    sigma_m2(k) = s.cfg.sigma_resp_m2;
    P_comm_dbm(k) = s.cfg.P_comm_eirp_dbm;
    duty(k) = s.cfg.duty_cycle;
    L_code_db(k) = s.L_code_db;
    sic_gain_db(k) = s.sic_gain_db;
    P_intf_dbm(k) = s.P_intf_dbm;
    P_intf_sic_dbm(k) = s.P_intf_sic_dbm;
    R_clean_m(k) = s.R_clean_m;
    R_max_m(k) = s.R_max_m;
    R_max_sic_m(k) = s.R_max_sic_m;
    delta_R_m(k) = s.delta_R_m;
    recovered_m(k) = max(s.R_max_sic_m - s.R_max_m, 0);
    loss_pct(k) = 100 * s.delta_R_m / max(s.R_clean_m, eps);
end
T = table(name, D_comm_m, sigma_m2, P_comm_dbm, duty, L_code_db, ...
    sic_gain_db, P_intf_dbm, P_intf_sic_dbm, R_clean_m, R_max_m, ...
    R_max_sic_m, delta_R_m, recovered_m, loss_pct);
end

function printSanityChecks(cfg, link, linkSic)
phy = uwbdecoder.constants();
lambda = phy.SPEED_OF_LIGHT / cfg.fc_hz;
fspl_1m_db = 20*log10(4*pi*1/lambda);
fprintf('自检: 1 m Friis 自由空间损耗 = %.1f dB（6.5 GHz 约 48.7 dB）\n', ...
    fspl_1m_db);
P_echo_1m = pow2dbm(radarEchoPower(cfg, 1));
fprintf('自检: R = 1 m 胸壁回波 = %+6.1f dBm,  1 m 通信到达 = %+6.1f dBm\n', ...
    P_echo_1m, link.P_comm_dbm);
fprintf('自检: 双向/单向差 @1 m ≈ %.1f dB（雷达还乘了 σ/(4πR^2)）\n', ...
    link.P_comm_dbm - P_echo_1m);
fprintf(['抑制预算 @D=%.1f m:  P_comm %+6.1f  → 码 %+5.1f dB 后 %+6.1f', ...
    '  → SIC %+d dB 后 %+6.1f  （噪声 %+6.1f）\n\n'], ...
    cfg.D_comm_m, link.P_comm_dbm, cfg.L_code_db, link.P_code_dbm, ...
    cfg.sic_gain_db, linkSic.P_intf_dbm, link.P_noise_dbm);
end

function y = dbm2pow(dbm)
y = 1e-3 * 10.^(dbm/10);
end

function y = pow2dbm(p)
p = max(p, realmin('double'));
y = 10*log10(p) + 30;
end

function saveFigure(fig, outputDir, stem)
png = fullfile(outputDir, [stem '.png']);
figFile = fullfile(outputDir, [stem '.fig']);
axs = findall(fig, 'Type', 'axes');
for k = 1:numel(axs)
    if isprop(axs(k), 'Toolbar')
        axs(k).Toolbar.Visible = 'off';
    end
end
exportgraphics(fig, png, 'Resolution', 150);
savefig(fig, figFile);
end
