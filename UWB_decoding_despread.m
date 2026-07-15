clear; close all; clc;

%% ===================== 基本参数 =====================
c = physconst('LightSpeed');
SNR = -15;
symbolrate = 499.2e6;
fs = 4 * symbolrate;

d1 = 0.0;
tau1 = d1 / c;
amp1 = 1.0;

%% ===================== HRP 配置 =====================
cfg1 = lrwpanHRPConfig( ...
    Mode='HPRF', ...
    MeanPRF=124.8, ...
    DataRate=27.24, ...
    PreambleDuration=256, ...
    STSPacketConfiguration=0, ...
    CodeIndex=25, ...
    PSDULength=127, ...
    PHRDataRate=0.85, ...
    Ranging=true);

%% ===================== 生成发送波形 =====================

psduTx = randi([0, 1], 1016, 1);

tx1 = lrwpanWaveformGenerator(psduTx, cfg1);

ind1 = lrwpanHRPFieldIndices(cfg1);
preamble1 = tx1(1:ind1.SYNC(end)/cfg1.PreambleDuration);

%% ===================== 单条多径信道 =====================

multipath_num = 5;
%base = [0, 2.1e-9, 4.3e-9, 6.05e-9, 8.02e-9, 12e-9];
base = (0:3:multipath_num*3)*1e-9;

mp1.delays = base + 0e-9;

%mp1.gainsdB = [0 -500 -500 -100 -100 -100];
%mp1.gainsdB = [0 -0 -0 -0 -0 -0];
mp1.gainsdB = zeros(size(base));

%% ===================== 通过信道 =====================
fc = 8e9;
ppm = 0;

rx1 = applyUWBChannel(tx1, tau1, mp1, fs, fc, ppm) * amp1;
rx1 = awgn(rx1, SNR, 'measured');
%rx1 = awgn(rx1, SNR, 'measured');

t_ns = (0:length(rx1)-1).' / fs * 1e9;

% ppm=0 时直接使用 rx
rx1 = rx1.*exp(1j*2*pi*fc*ppm*1e-6*t_ns*1e-9);

plot(real(rx1));hold on
%plot(t_ns/1e3,abs(rx1));

%%
coarseFC = comm.CoarseFrequencyCompensator(Modulation='PAM', SampleRate=fs, FrequencyResolution=100);
[rx_fc, freqEst] = coarseFC(rx1);

fprintf('Coarse frequency offset: %.4f Hz\n', freqEst)

[c,s,l] = pca([real(rx_fc),imag(rx_fc)]);

rx_fc = s(:,1) + 1j*s(:,2);

%rx_fc = rx_fc./exp(1j*angle(rx_fc(38)));

plot(real(rx_fc))
%axis equal

%symbolSync = comm.SymbolSynchronizer(Modulation='PAM/PSK/QAM', SamplesPerSymbol=2, TimingErrorDetector='Early-Late (non-data-aided)');
%rx_recover = symbolSync(real(rx_fc));

rx_recover = rx_fc;
%rx_recover = symbolSync(tx1);

%plot(abs(rx1),'--');hold on
%plot(real(rx_fine(1:2:end)));hold on
%plot(real(rx_recover(2:end)),'--');hold on
%axis equal

%%

Tpream = 3; % manual, iterative specification; threshold can increase until only 1 code detected
Tnoise = 0.01; % used for energy detection, toward specification of the Preamble Detector threshold
Tzero = 25/100; % amplitude threshold for zero symbols, as percentage of highest amplitude - should be higher than noise

%cfgRcv = lrwpanHRPConfig(Mode='BPRF', SamplesPerPulse=2); % create an object to keep track of the received-frame properties
cfgRcv = cfg1;
preambleCodesHPRF = 25;
preambleDet = comm.PreambleDetector;
syncFound = false;
codeIdx = preambleCodesHPRF(1)-1;
hprfPreambleDurations = [16, 24, 32, 48, 64, 96, 128, 256];

chunkSize = 2;

while ~syncFound && codeIdx < max(preambleCodesHPRF) % consider all codes until detection
  codeIdx = codeIdx+1;
  for polarity = [1 -1]                               % consider all polarities until detection
    % create SYNC from spread code:
    polarity
    code = lrwpan.internal.HRPCodes(codeIdx);
    spreadingFactorHPRF = cfgRcv.PreambleSpreadingFactor; % spreading factor, L (always 4 for HPRF mode)
    samplesPerPulse = cfgRcv.SamplesPerPulse; % spreading factor, L (always 4 for HPRF mode)
    preamble = zeros(length(code) * spreadingFactorHPRF * samplesPerPulse, 1);
    preamble(1:spreadingFactorHPRF* samplesPerPulse:end) = code;

    preamble = repmat(preamble,chunkSize,1);
  
    release(preambleDet);
    preambleDet.Preamble = preamble;
    meanCorr = mean(abs(filter(flipud(preamble), 1, rx_recover(rx_recover>Tnoise))));

    corrMat = filter(flipud(preamble), 1, polarity*(rx_recover));

    corrMat = corrMat(length(preamble):end);
    %corrMat = corrMat*polarity;
    [~,preamPos] = findpeaks(abs(corrMat),'MinPeakHeight',Tpream*meanCorr);
    durationIdx = find(numel(preamPos)+5 > hprfPreambleDurations, 1, 'last');
    if ~isempty(durationIdx) && corrMat(preamPos(1)) > 0
      %
      plot(real(corrMat));hold on
      plot(preamPos,real(corrMat(preamPos)),'o');
      %figure
      %plot((preamble));hold on
      %plot(real(rx_recover(38:end)));hold on
      %cfgRcv.PreambleDuration = hprfPreambleDurations(durationIdx);
      syncFound = true;
      break; % preamble found, no need to explore other polarity
    end
  end
end
if syncFound
  fprintf('Found SYNC for code #%d.', codeIdx);
  cfgRcv.CodeIndex = codeIdx; % keep track of identified frame characteristics
else
  error('No SYNC field found in the input data.');
end

%%
cirAcc = zeros(1,200);

prLen = length(preamble)/chunkSize;

figure
for i = 1:cfg1.PreambleDuration-chunkSize
    cirAcc = cirAcc + corrMat(prLen*i:prLen*i+200-1).';
    plot(abs(corrMat(prLen*i:prLen*i+200-1).')); hold on
end

figure
plot(abs(cirAcc)/(cfg1.PreambleDuration-chunkSize));hold on
plot(abs(corrMat(prLen*i:prLen*i+200-1).'))

%%

h = cirAcc(1:end);
rx = rx_recover(:).';

%h = conj(h(end:-1:1));
h = conj(h(end:-1:1));
h = h./max(h);

w = conv(rx,h)/2;

w = w(200:end);

plot(real(rx));hold on
plot(real(w));hold on


%%

sfd_data = tx1(ind1.SFD(1):ind1.SFD(2));

corrMat2 = filter(flipud(preamble(1:end/chunkSize)), 1, w);
corrMat3 = filter(flipud(preamble(1:end/chunkSize)), 1, rx_recover);

despread = despreadPayload(tx1, cfg1, 64);

plot(abs(corrMat2)/13);hold on
plot(abs(corrMat3));hold on
%plot(despread);hold on
%plot(tx1);hold on



%% Slice remaining capture with integrate and dump (frame length is unknown for now, it is in the PHR)

rx_new = rx_recover/max(abs(rx_recover)); % normalize amplitude
%rx_downsample = resample(rx_recover,1,4);
%rx_new = rx_recover;

%frameStart = preamPos(1)-length(preamble)+1;
%ternarySymbols = polarity*real(rx_new(frameStart:end));

% 软码片：保留幅度信息，判决推迟到解扩积分之后（DW3000 模式）
% SYNC / SFD / PHR / Payload 全部基于 softChips 做"先解扩后判决"
softChips = polarity*real(w);
softChips = softChips(1:4:end).';
softChips = softChips./max(abs(softChips));

%plot(softChips);hold on

% plot(softChips(1:4:end));hold on
% plot(softChips(2:4:end));hold on
% plot(softChips(3:4:end));hold on
% plot(softChips(4:4:end));hold on

%%

% Detect SFD by correlation (先解扩积分 -> 再判决，DW3000 模式)
% 判决门限：归一化相关系数下限（越接近 1 越像）
sfdCorrThr = 70/100;

preamble_sfd = preamble(1:length(preamble)/chunkSize);
sfdSpreadSeq = preamble_sfd(1:4:end);          % SFD 段每符号的 chip 级扩频序列(±1/0)
sfdSpreadSeq = sfdSpreadSeq(:);
chipsPerSFDSym = length(sfdSpreadSeq);         % 每个 SFD 符号占的 chip 数

sfdStart = 1+length(preamble_sfd)/4*cfgRcv.PreambleDuration;

sfdFound = false;
bestCorr = -inf;
bestSFDNum = -1;
for sfdNum = 0:0 % SFD values from Table 15-7c
  cfgRcv.SFDNumber = sfdNum;
  sfd = lrwpan.internal.getSFD(cfgRcv);
  sfd = sfd(:);
  numSFDSym = length(sfd);                      % SFD 长度随编号变化(最长 64 符号)

  % 按当前候选 SFD 的真实长度动态截取软码片，避免越界
  sfdSpan = chipsPerSFDSym*numSFDSym;
  if sfdStart + sfdSpan - 1 > length(softChips)
    continue;  % 软码片不够长，跳过该候选(更长的 SFD 不可能匹配)
  end
  sfdSoft = softChips(sfdStart : sfdStart + sfdSpan - 1);

  % ---- 先解扩：逐符号用扩频序列相关积分，把 chip 软值压成符号软判决 ----
  softSFDSym = zeros(numSFDSym, 1);
  for k = 1:numSFDSym
    seg = sfdSoft((k-1)*chipsPerSFDSym + (1:chipsPerSFDSym));
    softSFDSym(k) = sum(seg .* sfdSpreadSeq);  % 解扩积分(获得处理增益, 平均掉 ISI)
    plot(seg);hold on
    plot(sfdSpreadSeq);hold on
  end

  % ---- 再判决：符号级软判决序列与期望 SFD 符号型做归一化相关 ----
  % SFD 符号为三值(含 0)，对非零符号做相关；归一化得相关系数
  denom = norm(softSFDSym) * norm(sfd);
  if denom > 0
    sfdCorr = (softSFDSym.' * sfd) / denom;
  else
    sfdCorr = 0;
  end

  figure
  plot(1:numSFDSym, softSFDSym./max(abs(softSFDSym)),'-o');hold on
  plot(1:numSFDSym, sfd,'-x');
  title(sprintf('SFD #%d, corr = %.3f', sfdNum, sfdCorr));

  if sfdCorr > bestCorr
    bestCorr = sfdCorr;
    bestSFDNum = sfdNum;
  end
end

% 判决发生在所有候选积分完成之后：取相关最大且超过门限者
if bestCorr >= sfdCorrThr
  sfdFound = true;
  sfdNum = bestSFDNum;
  cfgRcv.SFDNumber = sfdNum;
  sfd = lrwpan.internal.getSFD(cfgRcv);
end
if sfdFound
  fprintf('Found SFD #%d (corr = %.3f).\n', sfdNum, bestCorr);
else
  warning('No SFD was found after SYNC. (best corr = %.3f)', bestCorr)
end

sfdBER = 1 - bestCorr;   % 兼容后续可能的引用：用 1-相关系数表征匹配残差
sfdEnd = sfdStart + chipsPerSFDSym*length(sfd) - 1;

%%

plot(ind1.SYNC(1):ind1.SYNC(2),tx1(ind1.SYNC(1):ind1.SYNC(2)));hold on
plot(ind1.SFD(1):ind1.SFD(2),tx1(ind1.SFD(1):ind1.SFD(2)));hold on
plot(ind1.PHR(1):ind1.PHR(2),tx1(ind1.PHR(1):ind1.PHR(2)));hold on
plot(ind1.Payload(1):ind1.Payload(2),tx1(ind1.Payload(1):ind1.Payload(2)));hold on

%%
stsAfterSFD = 0;

if ~stsAfterSFD
  phrStart = sfdEnd + 1;
else
  phrStart = sfdEnd + 1 + stsLen;
end

% BPRF 模式：约束长度固定为 3，PHR/payload 用 BPM-BPSK
% helperUWBBPRFDemod 内部对每个候选 burst 做 sum(burst .* PN)，
% 即先解扩积分再做位置/极性判决——输入软码片即可获得抗 ISI 的处理增益
cfgRcv = cfg1;
CL = 3;

isPHR = true;
%[cwPHR, phrEnd] = helperUWBBPRFDemod(isPHR, softChips, phrStart, cfgRcv);
[cwPHR, phrEnd] = helperUWBHPRFDemod(isPHR, softChips, phrStart, cfgRcv);
[secdedPass, PSDULength] = helperUWBPHRDecode(cwPHR, cfgRcv, CL);
if secdedPass
  cfgRcv.PSDULength = PSDULength;
else
  warning('PHR SECDED check failed; continuing with decoded PSDULength anyway.');
end

PSDULength

% phrStart
% ceil((ind1.PHR(1))/4)
% 
% phrEnd
% ceil((ind1.PHR(2))/4)
%%

%cfgRcv.PSDULength = 127;

payloadStart = phrEnd+1;

%payloadStart = 1+ceil((ind1.PHR(2))/4);
% 输入软码片：helperUWBPayloadDecode 的 BPRF 分支已改为相关式解调（先解扩后判决）
[decodedPSDU,payloadEnd] = helperUWBPayloadDecode(softChips, payloadStart, cwPHR, cfgRcv);

[~, ber] = biterr(psduTx, decodedPSDU);

plot(psduTx);hold on
plot(decodedPSDU);hold on
fprintf('Bit error rate: %0.2f\n', ber)

% payloadStart
% ceil((ind1.Payload(1))/4)
% 
% payloadEnd
% ceil((ind1.Payload(2))/4)
%%

function y = applyUWBChannel(x, mainDelay, mp, fs, fc, ppm)
    % x: 基带发送波形
    % mainDelay: 主传播时延（秒）
    % mp.delays: 相对多径时延（秒）
    % mp.gainsdB: 多径增益（dB）
    % fs: 采样率
    % fc: 载波频率
    % ppm: CFO (ppm)

    gains = 10.^(mp.gainsdB/20);
    totalDelays = mainDelay + mp.delays;

    delaySamples = round(totalDelays * fs);
    Lout = length(x) + max(delaySamples) + 10;
    y = complex(zeros(Lout,1));

    % ---------- 多径叠加 ----------
    for k = 1:length(delaySamples)

        tau_k = totalDelays(k);                     
        phase_k = exp(-1j * 2*pi * fc * tau_k);     % 传播相移

        idx = delaySamples(k) + (1:length(x));

        y(idx) = y(idx) + gains(k) * phase_k * x;

    end

    % ---------- CFO ----------
    delta_f = ppm * 1e-6 * fc;      % CFO Hz

    n = (0:Lout-1).';
    cfo_phase = exp(1j * 2*pi * delta_f * n / fs);

    y = y .* cfo_phase;

end


function cir = computeCIR(signal, preamble)
    
    % signal: 接受信号采样（sample）
    % preamble: 本地UWB前导码模板

    corr = filter(flipud(preamble) , 1, signal);

    % plot(abs(corr));hold on

    accumulator = zeros(size(preamble));

    pre_len = length(preamble);

    start_idx = pre_len*2-12;
    
    % 累加CIR提升信噪比
    for i = 1:63
        accumulator = accumulator + corr(start_idx+1+pre_len*(i-1):start_idx+pre_len*i);
    end

    cir = accumulator;
end


function despread = despreadPayload(rxIQ, cfg, sps)
% rxIQ  : 接收基带复信号，列向量，包含完整payload段
% cfg   : lrwpanHRPConfig 配置对象
% sps   : samples per chip（每码片采样点数）
% despread : 解扩后的复信号，维度与rxIQ相同

% 1. 确定payload的PN参数
% PHR部分的符号数（用于计算pnMaskOffset）
phrLen = 19;
if cfg.MeanPRFNum < 124.8 || cfg.ConstraintLength == 3
    numPHRSym = phrLen + 2;
else
    numPHRSym = phrLen + 6;
end

pnSamplesPerFrame = cfg.ChipsPerSymbol(end);   % payload每符号的有效码片数
pnMaskOffset      = numPHRSym * cfg.ChipsPerSymbol(1); % 跳过PHR的PN偏移

% 2. 生成PN序列（码片级别，0/1）
% 总码片数 = IQ总采样点数 / sps
numChips = floor(length(rxIQ) / sps);

pn = lrwpan.internal.createScrambler(cfg.CodeIndex, pnSamplesPerFrame, pnMaskOffset);

pnSeq = zeros(numChips, 1);
chipsGenerated = 0;
while chipsGenerated < numChips
    frame = pn();   % 返回 pnSamplesPerFrame 个码片 (0/1)
    n = min(pnSamplesPerFrame, numChips - chipsGenerated);
    pnSeq(chipsGenerated+1 : chipsGenerated+n) = frame(1:n);
    chipsGenerated = chipsGenerated + n;
end

% 3. 将PN序列转为双极性并上采样到IQ采样率
% 0 -> +1, 1 -> -1
pnBipolar = 1 - 2 * pnSeq;              % (numChips × 1), 实数 ±1

% 上采样：每个码片重复sps次
pnUpsampled = repelem(pnBipolar, sps);  % (numChips*sps × 1)

% 对齐长度（防止末尾差1）
L = min(length(rxIQ), length(pnUpsampled));

% 4. 解扩：复信号逐点乘以实数PN码
% PN码是实数，只旋转相位符号，不影响IQ正交性
despread = rxIQ(1:L) .* pnUpsampled(1:L);

end