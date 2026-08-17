function cir = estimateCir(rx, preamble, reference, params)
%ESTIMATECIR 从稳定的重复 SYNC 符号估计局部 CIR。
%   CIR = ESTIMATECIR(RX, PREAMBLE, REFERENCE, PARAMS) 仅完成前导扩频码
%   相关和 CIR 相干平均；前端 CMF 与“先 de-spread、后 CMF”两条链路共用
%   此处得到的信道估计。

totalTimer = tic;

% --- 1. 窗口与 SYNC 范围准备 ---
stageTimer = tic;
code = reference.sampled_code(:);       % 已知前导扩频码（工作采样率）
codeMf = flipud(conj(code));             % 用于相关的共轭时间反转模板
codeLength = numel(code);
rx = rx(:);

[preSamples, postSamples] = resolveCirWindow(params, preamble, reference);
[preDiag, postDiag] = resolveDiagWindow(params, preSamples, postSamples);
% 相对预期首径位置的 tap 范围：前置保护窗 + 后向多径窗口。
% 诊断窗可以更宽，但 CMF 仍只用中心的 cir_pre/cir_post 抽头。
offsets = (-preDiag:postDiag-1).';
delayNsDiag = offsets / reference.fs * 1e9;
cmfStart = preDiag - preSamples + 1;
cmfEnd = cmfStart + preSamples + postSamples - 1;
delayNs = delayNsDiag(cmfStart:cmfEnd);

% 只使用已检测到、且由配置允许的 SYNC 数量。
availableRepetitions = min(preamble.detected_repetitions, ...
    params.preamble_repetitions);
if isempty(params.cir_skip_initial_repetitions)
    % 默认使用前导末尾的若干 SYNC，避开可能尚未稳定的开始部分。
    repetitionCount = min(params.cir_repetitions, availableRepetitions);
    firstRepetition = max(0, availableRepetitions - repetitionCount);
else
    % 也可显式跳过前若干 SYNC，再从余下部分估计 CIR。
    firstRepetition = params.cir_skip_initial_repetitions;
    repetitionCount = min(params.cir_repetitions, ...
        availableRepetitions - firstRepetition);
    if repetitionCount < 1
        error('estimateCir:NoRepetitionsAfterSkip', ...
            ['No detected preamble repetitions remain after skipping ', ...
             'the first %d repetitions.'], firstRepetition);
    end
end
lastRepetition = firstRepetition + repetitionCount - 1;
setupSeconds = toc(stageTimer);

% --- 2. 对齐并提取各 SYNC 的局部原始窗口 ---
stageTimer = tic;
% 只截取会参与局部 CIR 的原始样点：
% [最早 tap, 最晚 tap + 扩频码长度 - 1]。
% 旧实现会对连续 64 个 SYNC 的全部中间时延做滤波，最后却丢弃绝大多数
% 输出；这里避免计算那些无用的相关 lag。
tapCount = numel(offsets);
localSampleOffsets = offsets(1) + (0:codeLength + tapCount - 2).';
repetitions = firstRepetition:lastRepetition;
repetitionStarts = preamble.start_sample + repetitions*preamble.measured_period;
% 每一列对应一个 SYNC；每一行是该 SYNC 中相同的相对采样位置。
positions = localSampleOffsets + repetitionStarts;

% 多数捕获恰好落在工作采样栅格上，可直接索引。若存在采样钟偏差，
% 则一次性对全部 SYNC 做线性插值，避免在循环中反复调用 interp1。
integerGrid = all(abs(positions(:) - round(positions(:))) < 1e-9) && ...
    all(positions(:) >= 1) && all(positions(:) <= numel(rx));
if integerGrid
    alignedSegments = rx(round(positions));
else
    sampleAxis = (1:numel(rx)).';
    alignedSegments = interp1(sampleAxis, rx, positions, 'linear', NaN);
end
% 舍弃靠近缓冲区边缘、不含完整局部窗口的 SYNC。
valid = all(~isnan(alignedSegments), 1);
alignedSegments = alignedSegments(:, valid);
validCount = size(alignedSegments, 2);
if validCount == 0
    error('estimateCir:NoValidRepetitions', ...
        'No complete preamble repetitions were available for CIR estimation.');
end
alignedSegments = alignedSegments(:, 1:validCount);
alignmentSeconds = toc(stageTimer);

% --- 3. 先相干平均、再进行一次局部相关 ---
stageTimer = tic;
% 此前已经完成 CFO 校正。根据线性性：
%   mean(r_m ⋆ code) = mean(r_m) ⋆ code
% 因而先对对齐后的原始 SYNC 相干平均，再做一次 valid 相关，等价于分别
% 相关后平均，却只计算所需的 tapCount 个 CIR tap。
averageSegment = mean(alignedSegments, 2);
values = conv(averageSegment, codeMf, 'valid') / ...
    (reference.code_energy + eps);
localCorrelationSeconds = toc(stageTimer);

% --- 4. 可选：保留逐 SYNC CIR（仅诊断/绘图） ---
stageTimer = tic;
% 每个 SYNC 的 CIR 仅用于绘图和慢相位诊断，解码本身不需要。默认关闭以
% 保留局部相关的计算节省；开启内置绘图时会自动保留。
storeIndividual = params.cir_store_individual_values || params.show_plots;
if storeIndividual
    individual = complex(zeros(tapCount, validCount));
    for k = 1:validCount
        individual(:, k) = conv(alignedSegments(:, k), codeMf, 'valid') / ...
            (reference.code_energy + eps);
    end
else
    individual = complex(zeros(tapCount, 0));
end
individualSeconds = toc(stageTimer);

% --- 5. 归一化与结果封装 ---
stageTimer = tic;
% 诊断窗可能宽于 CMF 窗。CMF 只使用中心抽头，并只对这一段做 L2 归一化，
% 这样加宽诊断窗不会改变后续 CIR-CMF 的相对路径权重。
valuesDiagRaw = values;
individualDiag = individual;
valuesRaw = valuesDiagRaw(cmfStart:cmfEnd);
if isempty(individualDiag)
    individual = individualDiag;
else
    individual = individualDiag(cmfStart:cmfEnd, :);
end
normalizationNorm = norm(valuesRaw) + eps;
% 归一化只影响幅度标度，不改变后续 CMF 的相对路径权重。
values = valuesRaw / normalizationNorm;
timing = struct('setup_seconds', setupSeconds, ...
    'alignment_seconds', alignmentSeconds, ...
    'local_correlation_seconds', localCorrelationSeconds, ...
    'individual_seconds', individualSeconds, ...
    'package_seconds', toc(stageTimer), ...
    'total_seconds', toc(totalTimer));

cir = struct('values', values, 'delay_ns', delayNs, ...
    'values_raw', valuesRaw, ...
    'normalization_norm', normalizationNorm, ...
    'individual_values', individual, 'repetition_count', validCount, ...
    'first_repetition', firstRepetition + 1, ...
    'last_repetition', lastRepetition + 1, ...
    'skipped_initial_repetitions', firstRepetition, ...
    'pre_samples', preSamples, 'post_samples', postSamples, ...
    'timing', timing);
if preDiag > preSamples || postDiag > postSamples
    cir.diag_values = valuesDiagRaw;
    cir.diag_delay_ns = delayNsDiag;
    cir.diag_individual_values = individualDiag;
    cir.diag_pre_samples = preDiag;
    cir.diag_post_samples = postDiag;
end

if params.cir_timing
    fprintf(['[CIR timing] setup=%6.2f ms, align=%6.2f ms, ', ...
        'local-corr=%6.2f ms, individual=%6.2f ms, package=%6.2f ms, ', ...
        'total=%6.2f ms\n'], ...
        1e3*timing.setup_seconds, 1e3*timing.alignment_seconds, ...
        1e3*timing.local_correlation_seconds, 1e3*timing.individual_seconds, ...
        1e3*timing.package_seconds, 1e3*timing.total_seconds);
end
end

% -------------------------------------------------------------------------
function [preSamples, postSamples] = resolveCirWindow(params, preamble, reference)
% 根据显式 tap 配置、最大路径长度或默认值确定局部 CIR 窗口。
c = uwbdecoder.constants();

if ~isempty(params.cir_pre_samples)
    preSamples = params.cir_pre_samples;
else
    preSamples = preamble.search_half_width;
end

if ~isempty(params.cir_post_samples)
    postSamples = params.cir_post_samples;
elseif ~isempty(params.cir_max_path_m)
    % 将允许的额外路径长度换算为工作采样率下的延迟 tap 数。
    postSamples = max(1, round(params.cir_max_path_m / c.SPEED_OF_LIGHT * reference.fs));
else
    postSamples = max(1, round(100e-9 * reference.fs));
end

preSamples = max(0, round(preSamples));
postSamples = max(1, round(postSamples));
end

function [preDiag, postDiag] = resolveDiagWindow(params, preSamples, postSamples)
% 干扰诊断可以使用更宽的 First Path 前/后窗口，但不能窄于 CMF 窗。
preDiag = preSamples;
postDiag = postSamples;
if isfield(params, 'cir_diag_pre_samples') && ~isempty(params.cir_diag_pre_samples)
    preDiag = max(preSamples, round(params.cir_diag_pre_samples));
end
if isfield(params, 'cir_diag_post_samples') && ~isempty(params.cir_diag_post_samples)
    postDiag = max(postSamples, round(params.cir_diag_post_samples));
end
end
