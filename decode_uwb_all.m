function results = decode_uwb_all(options, batch)
%DECODE_X410_DW1000_ALL Decode every packet in an X410 capture file.
%   RESULTS = DECODE_X410_DW1000_ALL(OPTIONS, BATCH) uses three stages:
%   (1) strided energy-envelope scanning over the full .dat, (2) adaptive
%   full-rate preamble correlation near each energy onset, and (3) full-rate
%   decoding only around the surviving packet candidates.
%
%   OPTIONS uses the same fields as decode_uwb / run_decode_*.
%   BATCH controls coarse scan, fine decode, and output paths.
%
%   See also DECODE_X410_DW1000, DW1000DECODER.

if nargin < 1 || isempty(options)
    options = struct();
end
if nargin < 2 || isempty(batch)
    batch = struct();
end

baseParams = uwbdecoder.mergeOptions( ...
    uwbdecoder.defaultOptions(), options);
batch = mergeBatchOptions(batch, baseParams);

if ~isfolder(batch.output_directory)
    mkdir(batch.output_directory);
end

totalSamples = countCaptureSamples(baseParams);
if totalSamples < batch.min_window_samples
    error('decode_uwb_all:CaptureTooShort', ...
        'Capture has only %d complex samples; need at least %d.', ...
        totalSamples, batch.min_window_samples);
end

% Estimate the interference coefficient once and reuse it everywhere.
if baseParams.enable_interference_cancellation && ...
        isempty(baseParams.interference_coefficient)
    baseParams.interference_coefficient = estimateInterferenceCoefficient( ...
        baseParams, totalSamples);
end

% Build the reference once for refined correlation and sample coordinates.
reference = uwbdecoder.buildUwbReference(baseParams);
addpath(baseParams.helper_path);
coarseTemplate = buildCoarseTemplate(baseParams, reference, batch);

printProgress('Stage 1/3: energy scan', 0, 0);

%% -------------------- Stage 1: strided energy-envelope scan --------------------
ticEnergy = tic;
[energyRegions, energyStats] = findEnergyRegions( ...
    baseParams, batch, totalSamples, @(frac) printProgress('Stage 1/3: energy scan', frac, 0));
energySeconds = toc(ticEnergy);
printProgress('Stage 1/3: energy scan', 1, energySeconds);

%% -------------------- Stage 2: preamble correlation in energy regions --------------------
ticCorrelation = tic;
[candidates, candidateRegions, correlationStats] = refineEnergyRegions( ...
    baseParams, coarseTemplate, batch, energyRegions, ...
    energyStats.raw_regions, totalSamples, ...
    @(frac) printProgress('Stage 2/3: correlation', frac, 0));
correlationSeconds = toc(ticCorrelation);
coarseSeconds = energySeconds + correlationSeconds;
printProgress('Stage 2/3: correlation', 1, correlationSeconds);

%% -------------------- Stage 3: full decode only at candidates --------------------
% Decoding each candidate is independent, so it runs in parfor across
% workers. Duplicate filtering and frame saving are done afterwards because
% they depend on previously accepted frames.
frames = emptyFrameRecord();
packetCount = 0;
ticFine = tic;

% Ensure a parallel pool is open for the fine-decode stage.
if isempty(gcp('nocreate'))
    parpool('local');
end

% Pre-compute per-candidate window offsets so the parfor body is a pure
% function of the candidate index.
numCandidates = numel(candidates);
candOffsets = zeros(numCandidates, 1);
candWindowSamples = zeros(numCandidates, 1);
candValid = false(numCandidates, 1);
for candIdx = 1:numCandidates
    candidate = candidates(candIdx);
    candidateRegion = candidateRegions(candIdx, :);
    offset = max(0, max(candidate - batch.pre_packet_guard_samples, ...
        candidateRegion(1)));
    if offset + batch.min_window_samples > totalSamples
        continue;
    end
    regionWindowSamples = candidateRegion(2) - offset + 1;
    windowSamples = min(batch.window_samples, ...
        max(batch.min_window_samples, regionWindowSamples));
    windowSamples = min(windowSamples, totalSamples - offset);
    candOffsets(candIdx) = offset;
    candWindowSamples(candIdx) = windowSamples;
    candValid(candIdx) = true;
end

attemptCount = nnz(candValid);
interferenceCoefficient = baseParams.interference_coefficient;

% Collect decode results in a cell array; each entry is [] on failure.
decodeCells = cell(numCandidates, 1);
timingCells = cell(numCandidates, 1);

parfor c = 1:numCandidates
    if ~candValid(c)
        continue;
    end
    offset = candOffsets(c);
    windowSamples = candWindowSamples(c);

    windowOptions = options;
    windowOptions.sample_offset = offset;
    windowOptions.sample_num = windowSamples;
    windowOptions.show_plots = false;
    windowOptions.interference_coefficient = ...
        interferenceCoefficient;

    try
        result = decode_uwb(windowOptions, [], [], reference);
    catch decodeError
        continue;
    end

    timing = locateDecodedFrameSamples( ...
        offset, result, baseParams, reference, batch, totalSamples);

    decodeCells{c} = result;
    timingCells{c} = timing;
end

% Sequential post-processing: dedup + frame saving. Iterating in candidate
% order preserves the original first-seen-wins behaviour.
for c = 1:numCandidates
    if isempty(decodeCells{c})
        continue;
    end
    result = decodeCells{c};
    timing = timingCells{c};
    absStart = timing.abs_start_sample;

    if isDuplicatePacket(frames, packetCount, absStart, ...
            batch.start_tolerance_samples)
        continue;
    end

    if batch.require_fcs_pass && ~result.payload.fcs_pass
        continue;
    end

    packetCount = packetCount + 1;
    frames(packetCount) = packageFrameRecord( ...
        packetCount, candOffsets(c), timing, result, baseParams);

    if batch.save_individual_cir
        cirFile = fullfile(batch.output_directory, ...
            sprintf('cir_%03d.mat', packetCount));
        cir = frames(packetCount).cir; %#ok<NASGU>
        meta = frames(packetCount); %#ok<NASGU>
        save(cirFile, 'cir', 'meta', '-v7');
    end
end

fineSeconds = toc(ticFine);

if packetCount == 0
    frames = emptyFrameRecord();
else
    frames = frames(1:packetCount);
end

results = struct();
results.file_name = baseParams.file_name;
results.total_samples = totalSamples;
results.duration_s = totalSamples / baseParams.fs_rx;
results.coarse_seconds = coarseSeconds;
results.energy_seconds = energySeconds;
results.correlation_seconds = correlationSeconds;
results.fine_seconds = fineSeconds;
results.coarse_chunk_count = energyStats.chunk_count;
results.coarse_raw_peak_count = correlationStats.raw_candidate_count;
results.energy_regions = energyRegions;
results.energy_stats = energyStats;
results.correlation_stats = correlationStats;
results.candidate_count = numel(candidates);
results.candidates = candidates(:);
results.candidate_regions = candidateRegions;
results.attempt_count = attemptCount;
results.packet_count = packetCount;
% Keep in lockstep with sic_pipeline/uwbSicPipeline.m
% latestAlgorithmConfig().detection_algorithm_version. Bump both when the
% energy + adaptive full-rate multi-packet detector changes incompatibly.
results.detection_algorithm_version = 3;
results.detection_algorithm = 'adaptive_fullrate_multipacket_v3';
if packetCount == 0
    results.fcs_pass_count = 0;
else
    results.fcs_pass_count = sum([frames.fcs_pass]);
end
results.params = baseParams;
results.batch = batch;
results.frames = frames;
results.sample_index_base = 0;
results.interval_end_inclusive = true;
results.packet_intervals = zeros(0, 2);
results.blank_intervals = zeros(0, 2);
results.precise_interval_mask = false(0, 1);
results.precise_packet_intervals = zeros(0, 2);
results.precise_blank_intervals = zeros(0, 2);
results.cir_delay_ns = [];
results.cir_values = [];

if packetCount > 0
    results.packet_intervals = [ ...
        [frames.abs_start_sample].', [frames.abs_end_sample].'];
    results.blank_intervals = [ ...
        [frames.localization_start_sample].', ...
        [frames.localization_end_sample].'];
    results.precise_interval_mask = ...
        [frames.has_precise_end_sample].';
    results.precise_packet_intervals = results.packet_intervals( ...
        results.precise_interval_mask, :);
    results.precise_blank_intervals = results.blank_intervals( ...
        results.precise_interval_mask, :);
    results.cir_delay_ns = frames(1).cir.delay_ns(:);
    cirLen = numel(results.cir_delay_ns);
    results.cir_values = complex(zeros(cirLen, packetCount));
    for k = 1:packetCount
        values = frames(k).cir.values(:);
        n = min(cirLen, numel(values));
        results.cir_values(1:n, k) = values(1:n);
    end
end

save(batch.mat_file, 'results', '-v7');
writeSummaryCsv(batch.summary_csv, frames);
fineSeconds = toc(ticFine);

printProgress('Stage 3/3: fine decode', 1, fineSeconds);
fprintf('\n');
end

% -------------------------------------------------------------------------
function printProgress(stage, frac, elapsed)
%PRINTPROGRESS Single-line CLI progress bar, overwritten in place.
%   STAGE  : string label, e.g. 'Stage 1/3: energy scan'
%   FRAC   : 0..1 fraction complete (0 = just started, 1 = done)
%   ELAPSED: seconds elapsed for this stage (ignored when frac < 1)
persistent lastFrac lastStage prevLen
if isempty(lastFrac), lastFrac = -1; end
if isempty(lastStage), lastStage = ''; end
if isempty(prevLen), prevLen = 0; end

% Reset state when a new stage begins.
if ~strcmp(stage, lastStage)
    lastFrac = -1;
    lastStage = stage;
    prevLen = 0;
end

barLen = 30;
nRound = max(0, min(barLen, round(frac * barLen)));
bar = [repmat('=', 1, nRound) repmat(' ', 1, barLen - nRound)];

if frac >= 1
    % Clear the previous line (backspace) then print done.
    fprintf(repmat('\b', 1, prevLen));
    msg = sprintf('[%s] [%-*s] done  %.1f s\n', stage, barLen, bar, elapsed);
    fprintf('%s', msg);
    prevLen = 0;
    lastFrac = -1;
else
    % Only refresh when the integer percentage changes (throttle to ~1%).
    pct = floor(frac * 100);
    if pct == lastFrac, return; end
    lastFrac = pct;
    % Clear the previous line (backspace) then print new progress.
    fprintf(repmat('\b', 1, prevLen));
    msg = sprintf('[%s] [%-*s] %3.0f%%', stage, barLen, bar, frac * 100);
    fprintf('%s', msg);
    prevLen = numel(msg);
end
% Force flush so the bar updates in real time even without a newline.
drawnow('limitrate');
end

% -------------------------------------------------------------------------
function batch = mergeBatchOptions(batch, params)
% Accept the former coarse-scan names when an older caller supplies them.
if isfield(batch, 'coarse_chunk_samples') && ...
        ~isfield(batch, 'energy_chunk_samples')
    batch.energy_chunk_samples = batch.coarse_chunk_samples;
end
if isfield(batch, 'coarse_step_samples') && ...
        ~isfield(batch, 'energy_step_samples')
    batch.energy_step_samples = batch.coarse_step_samples;
end
if isfield(batch, 'coarse_decimation') && ...
        ~isfield(batch, 'correlation_decimation')
    batch.correlation_decimation = batch.coarse_decimation;
end
if isfield(batch, 'coarse_correlation_repetitions') && ...
        ~isfield(batch, 'correlation_repetitions')
    batch.correlation_repetitions = ...
        batch.coarse_correlation_repetitions;
end

defaults = struct( ...
    'energy_chunk_samples', 20e6, ...
    'energy_step_samples', 19e6, ...
    'energy_read_stride', 100, ...
    'energy_smooth_rx_samples', 8192, ...
    'energy_baseline_fraction', 0.30, ...
    'energy_threshold_sigma_high', 6, ...
    'energy_threshold_sigma_low', 3, ...
    'energy_threshold_margin_db_high', 6, ...
    'energy_threshold_margin_db_low', 4, ...
    'energy_min_region_samples', 3e4, ...
    'energy_region_pre_guard_samples', 1.5e4, ...
    'energy_region_post_guard_samples', 2.5e4, ...
    'energy_region_merge_samples', 1e4, ...
    'correlation_decimation', 1, ...
    'correlation_repetitions', 8, ...
    'correlation_chunk_samples', 4e6, ...
    'correlation_overlap_samples', 3e5, ...
    'correlation_search_level_1_pre_samples', round(5e-6*params.fs_rx), ...
    'correlation_search_level_1_post_samples', round(12e-6*params.fs_rx), ...
    'correlation_search_level_2_pre_samples', round(15e-6*params.fs_rx), ...
    'correlation_search_level_2_post_samples', round(30e-6*params.fs_rx), ...
    'correlation_expected_offset_samples', round(5.2e-6*params.fs_rx), ...
    'correlation_min_repetitions', 3, ...
    'correlation_baseline_fraction', 0.60, ...
    'corr_threshold_sigma', 5, ...
    'corr_min_threshold_ratio', 20, ...
    'corr_candidate_relative_level', 0.20, ...
    'corr_require_hit_every_repetition', true, ...
    'correlation_multi_packet_search', true, ...
    'correlation_single_region_baseline_fraction', 0.60, ...
    'correlation_long_region_threshold_factor', 1.50, ...
    'correlation_long_region_threshold_margin_samples', ...
        round(20e-6*params.fs_rx), ...
    'correlation_min_packet_separation_fraction', 0.75, ...
    'correlation_packet_exclusion_repetitions', ...
        params.preamble_repetitions, ...
    'correlation_candidate_train_gap_repetitions', 4, ...
    'correlation_tail_chunk_samples', round(100e-6*params.fs_rx), ...
    'correlation_peak_min_distance_samples', 400, ...
    'correlation_cluster_gap_samples', 4000, ...
    'correlation_min_cluster_peaks', 4, ...
    'candidate_merge_samples', 5e4, ...
    'pre_packet_guard_samples', 5e4, ...
    'window_samples', 0.8e6, ...
    'localization_pre_guard_samples', 2048, ...
    'localization_post_guard_samples', 4096, ...
    'start_tolerance_samples', 4096, ...
    'min_window_samples', 0.3e6, ...
    'require_fcs_pass', false, ...
    'save_individual_cir', false, ...
    'output_directory', '', ...
    'mat_file', '', ...
    'summary_csv', '');

names = fieldnames(defaults);
for k = 1:numel(names)
    name = names{k};
    if ~isfield(batch, name) || isempty(batch.(name))
        batch.(name) = defaults.(name);
    end
end

[~, captureStem] = fileparts(params.file_name);
if strlength(string(batch.output_directory)) == 0
    batch.output_directory = fullfile(pwd, 'decoded_results', captureStem);
end
if strlength(string(batch.mat_file)) == 0
    batch.mat_file = fullfile(batch.output_directory, 'all_frames_cir.mat');
end
if strlength(string(batch.summary_csv)) == 0
    batch.summary_csv = fullfile(batch.output_directory, 'frame_summary.csv');
end

integerFields = { ...
    'energy_chunk_samples', 'energy_step_samples', 'energy_read_stride', ...
    'energy_smooth_rx_samples', 'energy_min_region_samples', ...
    'energy_region_pre_guard_samples', ...
    'energy_region_post_guard_samples', ...
    'energy_region_merge_samples', 'correlation_decimation', ...
    'correlation_repetitions', 'correlation_chunk_samples', ...
    'correlation_overlap_samples', ...
    'correlation_search_level_1_pre_samples', ...
    'correlation_search_level_1_post_samples', ...
    'correlation_search_level_2_pre_samples', ...
    'correlation_search_level_2_post_samples', ...
    'correlation_expected_offset_samples', ...
    'correlation_min_repetitions', ...
    'correlation_long_region_threshold_margin_samples', ...
    'correlation_packet_exclusion_repetitions', ...
    'correlation_candidate_train_gap_repetitions', ...
    'correlation_tail_chunk_samples', ...
    'correlation_peak_min_distance_samples', ...
    'correlation_cluster_gap_samples', ...
    'correlation_min_cluster_peaks', 'candidate_merge_samples', ...
    'pre_packet_guard_samples', 'window_samples', ...
    'localization_pre_guard_samples', ...
    'localization_post_guard_samples', 'start_tolerance_samples', ...
    'min_window_samples'};
for k = 1:numel(integerFields)
    name = integerFields{k};
    batch.(name) = max(1, round(batch.(name)));
end
batch.energy_threshold_sigma_high = max(0, ...
    double(batch.energy_threshold_sigma_high));
batch.energy_threshold_sigma_low = max(0, ...
    double(batch.energy_threshold_sigma_low));
batch.energy_threshold_margin_db_high = max(0, ...
    double(batch.energy_threshold_margin_db_high));
batch.energy_threshold_margin_db_low = max(0, ...
    double(batch.energy_threshold_margin_db_low));
batch.energy_baseline_fraction = min(1, max(eps, ...
    double(batch.energy_baseline_fraction)));
batch.corr_threshold_sigma = max(0, double(batch.corr_threshold_sigma));
batch.corr_min_threshold_ratio = max(0, ...
    double(batch.corr_min_threshold_ratio));
batch.correlation_baseline_fraction = min(1, max(eps, ...
    double(batch.correlation_baseline_fraction)));
batch.corr_candidate_relative_level = min(1, max(0, ...
    double(batch.corr_candidate_relative_level)));
batch.corr_require_hit_every_repetition = logical( ...
    batch.corr_require_hit_every_repetition);
batch.correlation_multi_packet_search = logical( ...
    batch.correlation_multi_packet_search);
batch.correlation_single_region_baseline_fraction = min(1, max(eps, ...
    double(batch.correlation_single_region_baseline_fraction)));
batch.correlation_long_region_threshold_factor = max(1, ...
    double(batch.correlation_long_region_threshold_factor));
batch.correlation_min_packet_separation_fraction = max(0, ...
    double(batch.correlation_min_packet_separation_fraction));
batch.require_fcs_pass = logical(batch.require_fcs_pass);
batch.save_individual_cir = logical(batch.save_individual_cir);

if batch.energy_threshold_sigma_low > batch.energy_threshold_sigma_high
    warning('decode_uwb_all:EnergyThresholdOrder', ...
        'Clamping the low energy threshold to the high threshold.');
    batch.energy_threshold_sigma_low = ...
        batch.energy_threshold_sigma_high;
end
if batch.energy_threshold_margin_db_low > ...
        batch.energy_threshold_margin_db_high
    warning('decode_uwb_all:EnergyMarginOrder', ...
        'Clamping the low energy dB margin to the high margin.');
    batch.energy_threshold_margin_db_low = ...
        batch.energy_threshold_margin_db_high;
end
if batch.energy_step_samples > batch.energy_chunk_samples
    warning('decode_uwb_all:StepExceedsChunk', ...
        ['energy_step_samples > energy_chunk_samples; ', ...
         'clamping step to chunk size.']);
    batch.energy_step_samples = batch.energy_chunk_samples;
end
if batch.correlation_overlap_samples >= batch.correlation_chunk_samples
    warning('decode_uwb_all:CorrelationOverlapTooLarge', ...
        'Clamping correlation overlap below the correlation chunk size.');
    batch.correlation_overlap_samples = ...
        max(1, floor(batch.correlation_chunk_samples/4));
end
batch.correlation_min_repetitions = min( ...
    batch.correlation_min_repetitions, batch.correlation_repetitions);
end

function totalSamples = countCaptureSamples(params)
info = dir(params.file_name);
if isempty(info)
    error('decode_uwb_all:FileNotFound', ...
        'Cannot find capture file: %s', params.file_name);
end
c = uwbdecoder.constants();
totalSamples = floor(info.bytes / (c.BYTES_PER_IQ_SAMPLE*params.ant_num));
end

function coefficient = estimateInterferenceCoefficient(params, totalSamples)
quietOffset = params.interference_quiet_offset;
quietNum = params.interference_quiet_num;
if quietOffset < 0 || quietOffset >= totalSamples
    error('decode_uwb_all:QuietOffsetOutOfRange', ...
        'interference_quiet_offset is outside the capture.');
end
quietNum = min(quietNum, totalSamples - quietOffset);
if quietNum < params.interference_period_samples
    error('decode_uwb_all:NotEnoughQuietSamples', ...
        'Not enough samples available for interference estimation.');
end

rawQuiet = uwbdecoder.readIqRaw(params.file_name, quietOffset, quietNum, params.ant_num);
rxQuiet = uwbdecoder.selectIqChannel(rawQuiet, params.channel_index);
quietN = quietOffset + (0:length(rxQuiet)-1).';
quietBasis = uwbdecoder.synchronousTone(quietN, ...
    params.interference_tone_bin, params.interference_period_samples);
coefficient = mean(rxQuiet .* conj(quietBasis));

end

function template = buildCoarseTemplate(params, reference, ~)
%BUILDCOARSETEMPLATE Map one preamble symbol to the full-rate receive grid.
[p, q] = rat(params.fs_rx / reference.fs, 1e-12);
prefRx = resample(reference.preamble_waveform, p, q);
prefRx = prefRx(:);
prefRx = prefRx / (norm(prefRx) + eps);
template = struct( ...
    'decimation', 1, ...
    'preamble', prefRx, ...
    'preamble_rx_length', numel(prefRx));
end

function [regions, stats] = findEnergyRegions(params, batch, totalSamples, progress_cb)
%FINDENERGYREGIONS Locate burst intervals from a truly strided file read.
%   progress_cb(frac) is an optional callback for live progress updates.
rawRegions = zeros(0, 2);
chunkCount = 0;
samplesRead = 0;
offset = 0;
estimatedChunks = ceil(totalSamples/batch.energy_step_samples);
if nargin < 4, progress_cb = []; end
chunkOffsets = zeros(estimatedChunks, 1);
thresholdHigh = zeros(estimatedChunks, 1);
thresholdLow = zeros(estimatedChunks, 1);
chunkRegionCount = zeros(estimatedChunks, 1);

while offset < totalSamples
    chunkSamples = min(batch.energy_chunk_samples, totalSamples - offset);
    chunkCount = chunkCount + 1;
    [raw, sampleIndices] = uwbdecoder.readIqRawStrided( ...
        params.file_name, offset, chunkSamples, params.ant_num, ...
        batch.energy_read_stride);
    rx = uwbdecoder.selectIqChannel(raw, params.channel_index);
    rx = cancelToneAtIndices(rx, sampleIndices, params);
    rx = rx - mean(rx);

    smoothLength = max(3, round( ...
        batch.energy_smooth_rx_samples/batch.energy_read_stride));
    energy = movmean(abs(rx).^2, smoothLength);
    sortedEnergy = sort(energy);
    baselineCount = max(32, floor( ...
        batch.energy_baseline_fraction*numel(sortedEnergy)));
    baselineCount = min(baselineCount, numel(sortedEnergy));
    baselineEnergy = sortedEnergy(1:baselineCount);
    energyMedian = median(baselineEnergy);
    energySigma = 1.4826*median(abs(baselineEnergy - energyMedian));
    robustSigma = max(energySigma, eps(max(abs(energyMedian), 1)));
    adaptiveHigh = energyMedian + ...
        batch.energy_threshold_sigma_high*robustSigma;
    adaptiveLow = energyMedian + ...
        batch.energy_threshold_sigma_low*robustSigma;
    marginHigh = energyMedian* ...
        10^(batch.energy_threshold_margin_db_high/10);
    marginLow = energyMedian* ...
        10^(batch.energy_threshold_margin_db_low/10);
    high = max(adaptiveHigh, marginHigh);
    low = max(adaptiveLow, marginLow);

    localRegions = hysteresisEnergyRegions( ...
        energy, sampleIndices, high, low, ...
        batch.energy_read_stride, batch.energy_min_region_samples, ...
        offset + chunkSamples - 1);
    if ~isempty(localRegions)
        rawRegions = [rawRegions; localRegions]; %#ok<AGROW>
    end

    samplesRead = samplesRead + numel(sampleIndices);
    chunkOffsets(chunkCount) = offset;
    thresholdHigh(chunkCount) = high;
    thresholdLow(chunkCount) = low;
    chunkRegionCount(chunkCount) = size(localRegions, 1);

    if ~isempty(progress_cb)
        progress_cb(min(1, offset / totalSamples));
    end

    if offset + chunkSamples >= totalSamples
        break;
    end
    offset = offset + batch.energy_step_samples;
end

% Merge duplicate raw detections caused by overlapping file chunks before
% adding search guards. Guard overlap must not merge two packet identities:
% adjacent guarded windows are clipped at the midpoint between their raw
% energy cores.
rawRegions = mergeIntervals( ...
    rawRegions, batch.energy_region_merge_samples);
regions = addIndependentGuards(rawRegions, ...
    batch.energy_region_pre_guard_samples, ...
    batch.energy_region_post_guard_samples, totalSamples);
stats = struct( ...
    'chunk_count', chunkCount, ...
    'samples_read', samplesRead, ...
    'read_fraction', samplesRead/max(totalSamples, 1), ...
    'read_stride', batch.energy_read_stride, ...
    'chunk_offsets', chunkOffsets(1:chunkCount), ...
    'threshold_high', thresholdHigh(1:chunkCount), ...
    'threshold_low', thresholdLow(1:chunkCount), ...
    'chunk_region_count', chunkRegionCount(1:chunkCount), ...
    'raw_regions', rawRegions, ...
    'raw_region_count', size(rawRegions, 1), ...
    'raw_coverage', intervalCoverage(rawRegions, totalSamples), ...
    'final_coverage', intervalCoverage(regions, totalSamples));
end

function regions = hysteresisEnergyRegions(energy, sampleIndices, ...
        highThreshold, lowThreshold, stride, minRegionSamples, chunkLast)
%HYSTERESISENERGYREGIONS Keep low-threshold runs containing a high crossing.
highMask = energy > highThreshold;
lowMask = energy > lowThreshold;
edges = diff([false; lowMask(:); false]);
runStarts = find(edges == 1);
runEnds = find(edges == -1) - 1;
regions = zeros(0, 2);
for k = 1:numel(runStarts)
    first = runStarts(k);
    last = runEnds(k);
    if ~any(highMask(first:last))
        continue;
    end
    absFirst = sampleIndices(first);
    absLast = min(chunkLast, sampleIndices(last) + stride - 1);
    if absLast - absFirst + 1 < minRegionSamples
        continue;
    end
    regions(end + 1, :) = [absFirst, absLast]; %#ok<AGROW>
end
end

function [candidates, candidateRegions, stats] = refineEnergyRegions( ...
        params, template, batch, energyRegions, rawEnergyRegions, ...
        totalSamples, progress_cb)
%REFINEENERGYREGIONS Adaptive full-rate, multi-packet preamble search.
% Scan only the first preamble repetition. Candidate delays are then
% validated sequentially at the following repetitions, stopping as soon as
% the accumulated decision passes. A failed narrow search expands twice.
% Suspiciously long energy regions are searched for additional packets.
if nargin < 7, progress_cb = []; end
regionCount = size(energyRegions, 1);
if size(rawEnergyRegions, 1) ~= regionCount
    error('decode_uwb_all:EnergyRegionMismatch', ...
        'Raw and guarded energy-region counts must match.');
end

candidates = zeros(0, 1);
candidateRegions = zeros(0, 2);
candidateRegionIndex = zeros(0, 1);
detectedMask = false(regionCount, 1);
searchLevelUsed = zeros(regionCount, 1);
repetitionsUsed = zeros(regionCount, 1);
candidatesTested = zeros(regionCount, 1);
scannedDelayCount = zeros(regionCount, 1);
regionCandidateCount = zeros(regionCount, 1);
regionPacketCount = zeros(regionCount, 1);
finalThresholdRatios = zeros(regionCount, 1);
scanIntervalCount = zeros(regionCount, 1);
tailSearchUsed = false(regionCount, 1);

rawRegionLengths = rawEnergyRegions(:, 2) - rawEnergyRegions(:, 1) + 1;
if regionCount == 0
    nominalSingleRegionSamples = 0;
    longRegionThresholdSamples = Inf;
else
    sortedRegionLengths = sort(rawRegionLengths);
    baselineRegionCount = max(1, floor( ...
        batch.correlation_single_region_baseline_fraction*regionCount));
    nominalSingleRegionSamples = median( ...
        sortedRegionLengths(1:baselineRegionCount));
    longRegionThresholdSamples = max( ...
        batch.correlation_long_region_threshold_factor* ...
            nominalSingleRegionSamples, ...
        nominalSingleRegionSamples + ...
            batch.correlation_long_region_threshold_margin_samples);
end
packetExclusionSamples = max( ...
    batch.correlation_packet_exclusion_repetitions* ...
        template.preamble_rx_length, ...
    round(batch.correlation_min_packet_separation_fraction* ...
        nominalSingleRegionSamples));
suspiciousLongRegionMask = rawRegionLengths >= ...
    longRegionThresholdSamples;

for regionIdx = 1:regionCount
    [detection, diagnostics] = adaptiveCorrelationCandidate( ...
        params, template.preamble, batch, energyRegions(regionIdx, :), ...
        rawEnergyRegions(regionIdx, 1), totalSamples);
    regionDetections = detection;
    if detection.detected && batch.correlation_multi_packet_search && ...
            suspiciousLongRegionMask(regionIdx)
        [tailDetections, tailDiagnostics] = ...
            searchTailCorrelationCandidates( ...
            params, template.preamble, batch, ...
            rawEnergyRegions(regionIdx, :), detection.candidate, ...
            packetExclusionSamples, totalSamples);
        diagnostics.candidates_tested = diagnostics.candidates_tested + ...
            tailDiagnostics.candidates_tested;
        diagnostics.candidates_extracted = ...
            diagnostics.candidates_extracted + ...
            tailDiagnostics.candidates_extracted;
        diagnostics.scanned_delay_count = ...
            diagnostics.scanned_delay_count + ...
            tailDiagnostics.scanned_delay_count;
        diagnostics.scan_interval_count = ...
            diagnostics.scan_interval_count + ...
            tailDiagnostics.scan_interval_count;
        tailSearchUsed(regionIdx) = tailDiagnostics.search_used;
        if ~isempty(tailDetections)
            regionDetections = [regionDetections; ...
                tailDetections(:)]; %#ok<AGROW>
            [~, order] = sort([regionDetections.candidate]);
            regionDetections = regionDetections(order);
        end
    end

    regionCandidates = [regionDetections.candidate].';
    packetCount = numel(regionCandidates);
    candidates = [candidates; regionCandidates]; %#ok<AGROW>
    candidateRegions = [candidateRegions; ...
        repmat(energyRegions(regionIdx, :), packetCount, 1)]; %#ok<AGROW>
    candidateRegionIndex = [candidateRegionIndex; ...
        repmat(regionIdx, packetCount, 1)]; %#ok<AGROW>
    detectedMask(regionIdx) = detection.detected;
    searchLevelUsed(regionIdx) = detection.level;
    repetitionsUsed(regionIdx) = detection.repetitions_used;
    finalThresholdRatios(regionIdx) = detection.threshold_ratio;
    candidatesTested(regionIdx) = diagnostics.candidates_tested;
    scannedDelayCount(regionIdx) = diagnostics.scanned_delay_count;
    regionCandidateCount(regionIdx) = diagnostics.candidates_extracted;
    regionPacketCount(regionIdx) = packetCount;
    scanIntervalCount(regionIdx) = diagnostics.scan_interval_count;

    if ~isempty(progress_cb)
        progress_cb(regionIdx/max(regionCount, 1));
    end
end

candidateOffsets = max(0, max( ...
    candidates - batch.pre_packet_guard_samples, ...
    candidateRegions(:, 1)));
valid = candidateOffsets + batch.min_window_samples <= totalSamples;
candidates = candidates(valid);
candidateRegions = candidateRegions(valid, :);
candidateRegionIndex = candidateRegionIndex(valid);
stats = struct( ...
    'region_count', regionCount, ...
    'correlation_chunk_count', sum(scanIntervalCount), ...
    'raw_candidate_count', sum(regionCandidateCount), ...
    'fallback_candidate_count', nnz(~detectedMask), ...
    'region_candidate_count', regionCandidateCount, ...
    'region_packet_count', regionPacketCount, ...
    'multi_packet_region_count', nnz(regionPacketCount > 1), ...
    'candidate_region_index', candidateRegionIndex, ...
    'decimation', 1, ...
    'detected_mask', detectedMask, ...
    'search_level_used', searchLevelUsed, ...
    'repetitions_used', repetitionsUsed, ...
    'candidates_tested', candidatesTested, ...
    'scanned_delay_count', scannedDelayCount, ...
    'final_threshold_ratios', finalThresholdRatios, ...
    'scan_interval_count', scanIntervalCount, ...
    'tail_search_used', tailSearchUsed, ...
    'suspicious_long_region_mask', suspiciousLongRegionMask, ...
    'nominal_single_region_samples', nominalSingleRegionSamples, ...
    'long_region_threshold_samples', longRegionThresholdSamples, ...
    'packet_exclusion_samples', packetExclusionSamples);
end

function [detection, diagnostics] = adaptiveCorrelationCandidate( ...
        params, preambleTemplate, batch, guardedRegion, rawStart, ...
        totalSamples)
templateLength = numel(preambleTemplate);
repetitionPeriod = templateLength;
maxDelay = max(0, totalSamples - templateLength);
rawStart = min(max(0, rawStart), maxDelay);

levelBounds = [ ...
    rawStart - batch.correlation_search_level_1_pre_samples, ...
    rawStart + batch.correlation_search_level_1_post_samples; ...
    rawStart - batch.correlation_search_level_2_pre_samples, ...
    rawStart + batch.correlation_search_level_2_post_samples];
levelBounds(:, 1) = max(0, levelBounds(:, 1));
levelBounds(:, 2) = min(maxDelay, levelBounds(:, 2));
levelBounds(3, :) = [ ...
    min(guardedRegion(1), levelBounds(2, 1)), ...
    max(guardedRegion(2), levelBounds(2, 2))];
levelBounds(3, 1) = max(0, levelBounds(3, 1));
levelBounds(3, 2) = min(maxDelay, levelBounds(3, 2));

detection = emptyCorrelationDetection(rawStart);
diagnostics = struct( ...
    'candidates_tested', 0, ...
    'candidates_extracted', 0, ...
    'scanned_delay_count', 0, ...
    'scan_interval_count', 0);
previousBounds = zeros(0, 2);

for level = 1:3
    currentBounds = levelBounds(level, :);
    newIntervals = newCorrelationSearchIntervals( ...
        currentBounds, previousBounds);
    if isempty(newIntervals)
        previousBounds = currentBounds;
        continue;
    end

    bufferStart = currentBounds(1);
    bufferEnd = min(totalSamples - 1, currentBounds(2) + ...
        (batch.correlation_repetitions - 1)*repetitionPeriod + ...
        templateLength - 1);
    rxBuffer = readProcessedBuffer( ...
        params, bufferStart, bufferEnd - bufferStart + 1);

    levelCandidates = zeros(0, 1);
    levelCandidateEnergy = zeros(0, 1);
    levelCandidateThreshold = zeros(0, 1);
    for intervalIdx = 1:size(newIntervals, 1)
        interval = newIntervals(intervalIdx, :);
        [delayPositions, correlationEnergy, threshold] = ...
            scanFirstRepetition(rxBuffer, bufferStart, interval, ...
            preambleTemplate, batch.correlation_baseline_fraction, ...
            batch.corr_threshold_sigma);
        diagnostics.scanned_delay_count = ...
            diagnostics.scanned_delay_count + numel(delayPositions);
        diagnostics.scan_interval_count = ...
            diagnostics.scan_interval_count + 1;
        [candidatePositions, candidateEnergy] = ...
            extractCorrelationCandidates(delayPositions, ...
            correlationEnergy, threshold, ...
            batch.corr_candidate_relative_level, ...
            batch.correlation_peak_min_distance_samples);
        levelCandidates = [levelCandidates; candidatePositions]; %#ok<AGROW>
        levelCandidateEnergy = [ ...
            levelCandidateEnergy; candidateEnergy]; %#ok<AGROW>
        levelCandidateThreshold = [levelCandidateThreshold; ...
            repmat(threshold, numel(candidatePositions), 1)]; %#ok<AGROW>
    end
    diagnostics.candidates_extracted = ...
        diagnostics.candidates_extracted + numel(levelCandidates);

    if ~isempty(levelCandidates)
        expectedCandidate = rawStart + ...
            batch.correlation_expected_offset_samples;
        [~, priority] = sort(abs(levelCandidates - expectedCandidate));
        levelCandidates = levelCandidates(priority);
        levelCandidateEnergy = levelCandidateEnergy(priority);
        levelCandidateThreshold = levelCandidateThreshold(priority);
    end

    for candidateIdx = 1:numel(levelCandidates)
        diagnostics.candidates_tested = ...
            diagnostics.candidates_tested + 1;
        validation = validateCorrelationCandidate( ...
            rxBuffer, bufferStart, levelCandidates(candidateIdx), ...
            levelCandidateEnergy(candidateIdx), ...
            levelCandidateThreshold(candidateIdx), preambleTemplate, ...
            repetitionPeriod, batch.correlation_min_repetitions, ...
            batch.correlation_repetitions, ...
            batch.corr_min_threshold_ratio, ...
            batch.corr_require_hit_every_repetition);
        if validation.detected
            detection = validation;
            detection.candidate = levelCandidates(candidateIdx);
            detection.level = level;
            return;
        end
    end
    previousBounds = currentBounds;
end
end

function [detections, diagnostics] = searchTailCorrelationCandidates( ...
        params, preambleTemplate, batch, rawRegion, primaryCandidate, ...
        packetExclusionSamples, totalSamples)
templateLength = numel(preambleTemplate);
repetitionPeriod = templateLength;
maxDelay = max(0, totalSamples - templateLength);
tailStart = primaryCandidate + packetExclusionSamples;
tailEnd = min(maxDelay, rawRegion(2) + ...
    batch.correlation_search_level_1_post_samples);
diagnostics = struct( ...
    'candidates_tested', 0, ...
    'candidates_extracted', 0, ...
    'scanned_delay_count', 0, ...
    'scan_interval_count', 0, ...
    'search_used', tailStart <= tailEnd);
emptyDetection = emptyCorrelationDetection(0);
validated = emptyDetection([]);

while tailStart <= tailEnd
    chunkEnd = min(tailEnd, ...
        tailStart + batch.correlation_tail_chunk_samples - 1);
    bufferStart = tailStart;
    bufferEnd = min(totalSamples - 1, chunkEnd + ...
        (batch.correlation_repetitions - 1)*repetitionPeriod + ...
        templateLength - 1);
    rxBuffer = readProcessedBuffer( ...
        params, bufferStart, bufferEnd - bufferStart + 1);
    [delayPositions, correlationEnergy, threshold] = ...
        scanFirstRepetition(rxBuffer, bufferStart, ...
        [tailStart, chunkEnd], preambleTemplate, ...
        batch.correlation_baseline_fraction, ...
        batch.corr_threshold_sigma);
    diagnostics.scanned_delay_count = ...
        diagnostics.scanned_delay_count + numel(delayPositions);
    diagnostics.scan_interval_count = ...
        diagnostics.scan_interval_count + 1;
    [candidatePositions, candidateEnergy] = ...
        extractCorrelationCandidates(delayPositions, ...
        correlationEnergy, threshold, ...
        batch.corr_candidate_relative_level, ...
        batch.correlation_peak_min_distance_samples);
    diagnostics.candidates_extracted = ...
        diagnostics.candidates_extracted + numel(candidatePositions);

    for candidateIdx = 1:numel(candidatePositions)
        diagnostics.candidates_tested = ...
            diagnostics.candidates_tested + 1;
        validation = validateCorrelationCandidate( ...
            rxBuffer, bufferStart, candidatePositions(candidateIdx), ...
            candidateEnergy(candidateIdx), threshold, ...
            preambleTemplate, repetitionPeriod, ...
            batch.correlation_min_repetitions, ...
            batch.correlation_repetitions, ...
            batch.corr_min_threshold_ratio, ...
            batch.corr_require_hit_every_repetition);
        if validation.detected
            validation.candidate = candidatePositions(candidateIdx);
            validation.level = 4;
            validated(end + 1, 1) = validation; %#ok<AGROW>
        end
    end
    tailStart = chunkEnd + 1;
end

detections = selectPacketDetections(validated, ...
    packetExclusionSamples, ...
    batch.correlation_candidate_train_gap_repetitions* ...
        repetitionPeriod);
end

function selected = selectPacketDetections( ...
        detections, minimumPacketSpacing, trainGap)
%SELECTPACKETDETECTIONS Group repetition peaks, then suppress packets.
if isempty(detections)
    selected = detections;
    return;
end

[~, timeOrder] = sort([detections.candidate]);
detections = detections(timeOrder);
candidateSamples = [detections.candidate].';
trainStarts = [1; find(diff(candidateSamples) > trainGap) + 1];
trainEnds = [trainStarts(2:end) - 1; numel(detections)];
representatives = detections(trainStarts);
trainScores = zeros(numel(trainStarts), 1);
for trainIdx = 1:numel(trainStarts)
    members = trainStarts(trainIdx):trainEnds(trainIdx);
    memberScores = zeros(numel(members), 1);
    for memberIdx = 1:numel(members)
        memberScores(memberIdx) = mean( ...
            detections(members(memberIdx)).per_rep_energy);
    end
    trainScores(trainIdx) = max(memberScores);
    representatives(trainIdx) = detections(members(1));
end

[~, strengthOrder] = sort(trainScores, 'descend');
keep = false(numel(representatives), 1);
keptCandidates = zeros(0, 1);
for priorityIdx = 1:numel(strengthOrder)
    representativeIdx = strengthOrder(priorityIdx);
    candidate = representatives(representativeIdx).candidate;
    if isempty(keptCandidates) || all(abs( ...
            candidate - keptCandidates) >= minimumPacketSpacing)
        keep(representativeIdx) = true;
        keptCandidates(end + 1, 1) = candidate; %#ok<AGROW>
    end
end
selected = representatives(keep);
if ~isempty(selected)
    [~, timeOrder] = sort([selected.candidate]);
    selected = reshape(selected(timeOrder), [], 1);
end
end

function detection = emptyCorrelationDetection(fallbackCandidate)
detection = struct( ...
    'detected', false, ...
    'candidate', fallbackCandidate, ...
    'level', 3, ...
    'repetitions_used', 0, ...
    'threshold_ratio', 0, ...
    'hit_count', 0, ...
    'per_rep_energy', zeros(0, 1));
end

function intervals = newCorrelationSearchIntervals(current, previous)
if isempty(previous)
    intervals = current;
    return;
end
intervals = zeros(0, 2);
if current(1) < previous(1)
    intervals(end + 1, :) = [current(1), previous(1) - 1]; %#ok<AGROW>
end
if current(2) > previous(2)
    intervals(end + 1, :) = [previous(2) + 1, current(2)]; %#ok<AGROW>
end
end

function rx = readProcessedBuffer(params, sampleOffset, sampleNum)
raw = uwbdecoder.readIqRaw( ...
    params.file_name, sampleOffset, sampleNum, params.ant_num);
rx = uwbdecoder.selectIqChannel(raw, params.channel_index);
sampleIndices = sampleOffset + (0:sampleNum - 1).';
rx = cancelToneAtIndices(rx, sampleIndices, params);
frequencyShift = params.x410_center_frequency - ...
    params.dw1000_center_frequency;
rx = rx .* exp(1j*2*pi*frequencyShift*sampleIndices/params.fs_rx);
rx = rx - mean(rx);
end

function [positions, energy, threshold] = scanFirstRepetition( ...
        rxBuffer, bufferStart, interval, preambleTemplate, ...
        baselineFraction, thresholdSigma)
templateLength = numel(preambleTemplate);
width = interval(2) - interval(1) + 1;
segmentFirst = interval(1) - bufferStart + 1;
segmentLast = segmentFirst + width + templateLength - 2;
segment = rxBuffer(segmentFirst:segmentLast);
matched = fftfilt(flipud(conj(preambleTemplate)), segment);
energyNorm = sqrt(movsum(abs(segment).^2, ...
    [templateLength - 1, 0])) + eps;
score = abs(matched)./energyNorm;
score = score(templateLength:templateLength + width - 1);
energy = score.^2;
threshold = robustCorrelationThreshold( ...
    energy, baselineFraction, thresholdSigma);
positions = (interval(1):interval(2)).';
end

function [positions, values] = extractCorrelationCandidates( ...
        delayPositions, energy, threshold, relativeLevel, minDistance)
level = max(threshold, relativeLevel*max(energy));
% Enforce safe MinPeakDistance (findpeaks errors if > length(energy))
minDistance = max(1, min( ...
    round(minDistance), ...
    floor(length(energy)/2) - 1));
if exist('findpeaks', 'file') == 2
    [values, locations] = findpeaks(energy, ...
        'MinPeakHeight', level, ...
        'MinPeakDistance', minDistance);
else
    locations = simpleFindPeaks(energy, level, minDistance);
    values = energy(locations);
end
positions = delayPositions(locations);
values = values(:);
end

function result = validateCorrelationCandidate( ...
        rxBuffer, bufferStart, candidate, firstEnergy, singleThreshold, ...
        preambleTemplate, repetitionPeriod, minRepetitions, ...
        maxRepetitions, minThresholdRatio, requireAllHits)
templateLength = numel(preambleTemplate);
perRepEnergy = zeros(maxRepetitions, 1);
runningRatio = zeros(maxRepetitions, 1);
perRepEnergy(1) = firstEnergy;
hitCount = double(firstEnergy > singleThreshold);
detected = false;

for repetition = 1:maxRepetitions
    if repetition > 1
        windowFirst = candidate - bufferStart + 1 + ...
            (repetition - 1)*repetitionPeriod;
        windowLast = windowFirst + templateLength - 1;
        if windowFirst < 1 || windowLast > numel(rxBuffer)
            break;
        end
        window = rxBuffer(windowFirst:windowLast);
        score = abs(sum(window.*conj(preambleTemplate))) / ...
            (sqrt(sum(abs(window).^2)) + eps);
        perRepEnergy(repetition) = score.^2;
        hitCount = hitCount + ...
            (perRepEnergy(repetition) > singleThreshold);
    end
    runningRatio(repetition) = ...
        mean(perRepEnergy(1:repetition))/max(singleThreshold, eps);
    enoughHits = hitCount >= minRepetitions;
    if requireAllHits
        enoughHits = hitCount == repetition;
    end
    if repetition >= minRepetitions && ...
            runningRatio(repetition) >= minThresholdRatio && enoughHits
        detected = true;
        break;
    end
end

result = struct( ...
    'detected', detected, ...
    'candidate', 0, ...
    'level', 0, ...
    'repetitions_used', repetition, ...
    'threshold_ratio', runningRatio(repetition), ...
    'hit_count', hitCount, ...
    'per_rep_energy', perRepEnergy(1:repetition));
end

function threshold = robustCorrelationThreshold( ...
        metric, baselineFraction, thresholdSigma)
sortedMetric = sort(metric);
baselineCount = max(16, floor(baselineFraction*numel(sortedMetric)));
baselineCount = min(baselineCount, numel(sortedMetric));
baseline = sortedMetric(1:baselineCount);
baselineMedian = median(baseline);
baselineSigma = 1.4826*median(abs(baseline - baselineMedian));
threshold = baselineMedian + thresholdSigma*max(baselineSigma, eps);
end

function locs = simpleFindPeaks(metric, threshold, minSep)
%SIMPLEFINDPEAKS Minimal peak picker when Signal Toolbox is unavailable.
locs = zeros(0, 1);
n = numel(metric);
if n < 3
    return;
end
candidate = false(n, 1);
for k = 2:n-1
    if metric(k) >= threshold && ...
            metric(k) >= metric(k-1) && metric(k) >= metric(k+1)
        candidate(k) = true;
    end
end
idx = find(candidate);
if isempty(idx)
    return;
end
% Greedy keep of strongest peaks with separation.
[~, order] = sort(metric(idx), 'descend');
idx = idx(order);
keep = false(size(idx));
for k = 1:numel(idx)
    if all(abs(idx(k) - idx(keep)) >= minSep)
        keep(k) = true;
    end
end
locs = sort(idx(keep));
end

function merged = mergeIntervals(intervals, mergeGap)
%MERGEINTERVALS Merge overlapping or nearby inclusive zero-based intervals.
if isempty(intervals)
    merged = zeros(0, 2);
    return;
end
intervals = sortrows(round(intervals), [1, 2]);
merged = intervals(1, :);
for k = 2:size(intervals, 1)
    if intervals(k, 1) <= merged(end, 2) + mergeGap + 1
        merged(end, 2) = max(merged(end, 2), intervals(k, 2));
    else
        merged(end + 1, :) = intervals(k, :); %#ok<AGROW>
    end
end
end

function guarded = addIndependentGuards( ...
        coreRegions, preGuard, postGuard, totalSamples)
%ADDINDEPENDENTGUARDS Expand packet cores without merging packet identity.
% If neighboring search guards overlap, divide the shared gap at the
% midpoint between the two raw energy cores.
if isempty(coreRegions)
    guarded = zeros(0, 2);
    return;
end

guarded = coreRegions;
guarded(:, 1) = max(0, guarded(:, 1) - preGuard);
guarded(:, 2) = min(totalSamples - 1, ...
    guarded(:, 2) + postGuard);

for k = 1:size(coreRegions, 1) - 1
    splitSample = floor((coreRegions(k, 2) + ...
        coreRegions(k + 1, 1))/2);
    guarded(k, 2) = min(guarded(k, 2), splitSample);
    guarded(k + 1, 1) = max( ...
        guarded(k + 1, 1), splitSample + 1);
end
end

function coverage = intervalCoverage(intervals, totalSamples)
if isempty(intervals)
    coverage = 0;
    return;
end
coveredSamples = sum(intervals(:, 2) - intervals(:, 1) + 1);
coverage = coveredSamples/max(totalSamples, 1);
end

function rx = cancelToneAtIndices(rx, sampleIndices, params)
%CANCELTONEATINDICES Remove the cached synchronous tone at sparse indices.
rx = rx(:);
if ~params.enable_interference_cancellation
    return;
end
if isempty(params.interference_coefficient)
    error('decode_uwb_all:MissingInterferenceCoefficient', ...
        'The energy scanner requires a precomputed interference coefficient.');
end
basis = uwbdecoder.synchronousTone(sampleIndices(:), ...
    params.interference_tone_bin, params.interference_period_samples);
rx = rx - params.interference_coefficient(1).*basis;
end

function absSample = absoluteRxSample(sampleOffset, workSample, fsRx, fsWork)
absSample = sampleOffset + round((workSample - 1)*fsRx / fsWork);
absSample = max(0, absSample);
end

function timing = locateDecodedFrameSamples(sampleOffset, result, params, ...
        reference, batch, totalSamples)
%LOCATEDECODEDFRAMESAMPLES Convert decoder coordinates to file coordinates.
% All public absolute indices are zero-based and interval ends are inclusive.
startWork = uncroppedPreambleStart(result);
absStart = absoluteRxSample( ...
    sampleOffset, startWork, params.fs_rx, reference.fs);

phrStart = chipIndexToAbsolute( ...
    sampleOffset, result, result.phr.start_chip, params, reference);
phrEnd = chipIndexToAbsolute( ...
    sampleOffset, result, result.phr.end_chip, params, reference);
payloadStart = chipIndexToAbsolute( ...
    sampleOffset, result, result.payload.start_chip, params, reference);
payloadEnd = chipIndexToAbsolute( ...
    sampleOffset, result, result.payload.end_chip, params, reference);

if isfinite(payloadEnd)
    absEnd = payloadEnd;
    endSource = 'decoded_payload_last_chip';
elseif isfinite(phrEnd)
    absEnd = phrEnd;
    endSource = 'decoded_phr_last_chip';
else
    period = result.preamble.samples_per_repetition;
    sfdSymbols = max(1, numel(result.sfd.sequence));
    endWork = startWork + ...
        (params.preamble_repetitions + sfdSymbols + 64)*period;
    absEnd = absoluteRxSample( ...
        sampleOffset, endWork, params.fs_rx, reference.fs);
    endSource = 'estimated_no_valid_phr';
end
absEnd = min(totalSamples - 1, max(absStart, absEnd));

timing = struct( ...
    'sample_index_base', 0, ...
    'interval_end_inclusive', true, ...
    'abs_start_sample', absStart, ...
    'abs_end_sample', absEnd, ...
    'abs_phr_start_sample', phrStart, ...
    'abs_phr_end_sample', phrEnd, ...
    'abs_payload_start_sample', payloadStart, ...
    'abs_payload_end_sample', payloadEnd, ...
    'end_source', endSource, ...
    'localization_start_sample', max(0, ...
        absStart - batch.localization_pre_guard_samples), ...
    'localization_end_sample', min(totalSamples - 1, ...
        absEnd + batch.localization_post_guard_samples));
end

function absSample = chipIndexToAbsolute( ...
        sampleOffset, result, chipIndex, params, reference)
absSample = NaN;
if isempty(chipIndex) || ~isscalar(chipIndex) || ...
        ~isfinite(chipIndex) || chipIndex < 1
    return;
end
if ~isfield(result, 'soft_chip_timing') || ...
        ~isfield(result.soft_chip_timing, 'first_chip_sample_uncropped')
    return;
end
firstChipWork = result.soft_chip_timing.first_chip_sample_uncropped;
samplesPerChip = result.soft_chip_timing.samples_per_chip;
workSample = firstChipWork + (double(chipIndex) - 1)*samplesPerChip;
absSample = absoluteRxSample( ...
    sampleOffset, workSample, params.fs_rx, reference.fs);
end

function startWork = uncroppedPreambleStart(result)
if isfield(result.preamble, 'start_sample_uncropped') && ...
        ~isempty(result.preamble.start_sample_uncropped)
    startWork = result.preamble.start_sample_uncropped;
else
    % Backward-compatible fallback for results produced without cropping.
    startWork = result.preamble.start_sample;
end
end

function tf = isDuplicatePacket(frames, packetCount, absStart, tolerance)
tf = false;
for k = 1:packetCount
    if abs(frames(k).abs_start_sample - absStart) <= tolerance
        tf = true;
        return;
    end
end
end

function record = emptyFrameRecord()
record = struct( ...
    'index', {}, ...
    'window_offset', {}, ...
    'abs_start_sample', {}, ...
    'abs_end_sample', {}, ...
    'abs_phr_start_sample', {}, ...
    'abs_phr_end_sample', {}, ...
    'abs_payload_start_sample', {}, ...
    'abs_payload_end_sample', {}, ...
    'localization_start_sample', {}, ...
    'localization_end_sample', {}, ...
    'end_sample_source', {}, ...
    'has_precise_end_sample', {}, ...
    'sample_index_base', {}, ...
    'interval_end_inclusive', {}, ...
    'time_start_s', {}, ...
    'time_end_s', {}, ...
    'detected_repetitions', {}, ...
    'samples_per_repetition', {}, ...
    'sample_clock_error_ppm', {}, ...
    'carrier_frequency_offset_hz', {}, ...
    'sfd_name', {}, ...
    'sfd_correlation', {}, ...
    'phr_secded_pass', {}, ...
    'psdu_length_bytes', {}, ...
    'payload_bytes', {}, ...
    'fcs_received', {}, ...
    'fcs_calculated', {}, ...
    'fcs_pass', {}, ...
    'cir', {});
end

function record = packageFrameRecord( ...
        index, windowOffset, timing, result, params)
payloadBytes = result.payload.bytes;
if isempty(payloadBytes)
    payloadBytes = uint8([]);
end

record = struct();
record.index = index;
record.window_offset = windowOffset;
record.abs_start_sample = timing.abs_start_sample;
record.abs_end_sample = timing.abs_end_sample;
record.abs_phr_start_sample = timing.abs_phr_start_sample;
record.abs_phr_end_sample = timing.abs_phr_end_sample;
record.abs_payload_start_sample = timing.abs_payload_start_sample;
record.abs_payload_end_sample = timing.abs_payload_end_sample;
record.localization_start_sample = timing.localization_start_sample;
record.localization_end_sample = timing.localization_end_sample;
record.end_sample_source = timing.end_source;
record.has_precise_end_sample = isfinite(timing.abs_payload_end_sample);
record.sample_index_base = timing.sample_index_base;
record.interval_end_inclusive = timing.interval_end_inclusive;
record.time_start_s = timing.abs_start_sample / params.fs_rx;
record.time_end_s = timing.abs_end_sample / params.fs_rx;
record.detected_repetitions = result.preamble.detected_repetitions;
record.samples_per_repetition = result.preamble.samples_per_repetition;
record.sample_clock_error_ppm = result.preamble.sample_clock_error_ppm;
record.carrier_frequency_offset_hz = ...
    result.preamble.carrier_frequency_offset_hz;
record.sfd_name = char(string(result.sfd.name));
record.sfd_correlation = result.sfd.correlation;
record.phr_secded_pass = logical(result.phr.secded_pass);
record.psdu_length_bytes = result.phr.psdu_length_bytes;
record.payload_bytes = payloadBytes(:).';
record.fcs_received = result.payload.fcs_received;
record.fcs_calculated = result.payload.fcs_calculated;
record.fcs_pass = logical(result.payload.fcs_pass);
record.cir = result.cir;
end

function writeSummaryCsv(csvFile, frames)
fid = fopen(csvFile, 'w');
if fid < 0
    warning('decode_uwb_all:CsvWriteError', ...
        'Could not write summary CSV: %s', csvFile);
    return;
end
fileGuard = onCleanup(@() fclose(fid));

fprintf(fid, ['index,window_offset,abs_start_sample,abs_end_sample,', ...
    'abs_phr_start_sample,abs_phr_end_sample,', ...
    'abs_payload_start_sample,abs_payload_end_sample,', ...
    ['localization_start_sample,localization_end_sample,end_sample_source,', ...
     'has_precise_end_sample,'], ...
    'time_start_ms,time_end_ms,detected_repetitions,', ...
    'sample_clock_error_ppm,cfo_hz,sfd_name,sfd_correlation,', ...
    'phr_secded_pass,psdu_length_bytes,fcs_received,fcs_calculated,', ...
    'fcs_pass,payload_hex\n']);

for k = 1:numel(frames)
    frame = frames(k);
    if isempty(frame.payload_bytes)
        payloadHex = '';
    else
        payloadHex = sprintf('%02X', frame.payload_bytes);
    end
    fprintf(fid, ['%d,%d,%d,%d,%.0f,%.0f,%.0f,%.0f,%d,%d,"%s",%d,', ...
        '%.6f,%.6f,%d,%.6f,%.6f,"%s",%.6f,', ...
        '%d,%d,0x%04X,0x%04X,%d,"%s"\n'], ...
        frame.index, frame.window_offset, frame.abs_start_sample, ...
        frame.abs_end_sample, frame.abs_phr_start_sample, ...
        frame.abs_phr_end_sample, frame.abs_payload_start_sample, ...
        frame.abs_payload_end_sample, frame.localization_start_sample, ...
        frame.localization_end_sample, frame.end_sample_source, ...
        frame.has_precise_end_sample, ...
        frame.time_start_s*1e3, ...
        frame.time_end_s*1e3, frame.detected_repetitions, ...
        frame.sample_clock_error_ppm, frame.carrier_frequency_offset_hz, ...
        frame.sfd_name, frame.sfd_correlation, frame.phr_secded_pass, ...
        frame.psdu_length_bytes, frame.fcs_received, ...
        frame.fcs_calculated, frame.fcs_pass, payloadHex);
end
clear fileGuard;
end
