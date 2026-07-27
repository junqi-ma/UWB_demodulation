function results = decode_x410_dw1000_all(options, batch)
%DECODE_X410_DW1000_ALL Decode every packet in an X410 capture file.
%   RESULTS = DECODE_X410_DW1000_ALL(OPTIONS, BATCH) uses three stages:
%   (1) strided energy-envelope scanning over the full .dat, (2) decimated
%   preamble correlation only inside energetic intervals, and (3) full-rate
%   decoding only around the surviving packet candidates.
%
%   OPTIONS uses the same fields as decode_x410_dw1000 / run_decode_*.
%   BATCH controls coarse scan, fine decode, and output paths.
%
%   See also DECODE_X410_DW1000, DW1000DECODER.

if nargin < 1 || isempty(options)
    options = struct();
end
if nargin < 2 || isempty(batch)
    batch = struct();
end

baseParams = dw1000decoder.mergeOptions( ...
    dw1000decoder.defaultOptions(), options);
batch = mergeBatchOptions(batch, baseParams);

if ~isfolder(batch.output_directory)
    mkdir(batch.output_directory);
end

totalSamples = countCaptureSamples(baseParams);
if totalSamples < batch.min_window_samples
    error('decode_x410_dw1000_all:CaptureTooShort', ...
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
reference = dw1000decoder.buildDw1000Reference(baseParams);
addpath(baseParams.helper_path);
coarseTemplate = buildCoarseTemplate(baseParams, reference, batch);

fprintf('\n========== Full-file DW1000 decode (energy+corr+fine) ==========\n');
fprintf('Capture file                 : %s\n', baseParams.file_name);
fprintf('Total complex samples        : %d (%.3f ms @ %.2f MHz)\n', ...
    totalSamples, totalSamples/baseParams.fs_rx*1e3, ...
    baseParams.fs_rx/1e6);
fprintf('Energy chunk/step            : %d / %d\n', ...
    batch.energy_chunk_samples, batch.energy_step_samples);
fprintf('Energy read stride           : %d\n', batch.energy_read_stride);
fprintf('Correlation decimation       : %d\n', ...
    batch.correlation_decimation);
fprintf('Fine decode window           : %d\n', batch.window_samples);
fprintf('==============================================================\n\n');

%% -------------------- Stage 1: strided energy-envelope scan --------------------
ticEnergy = tic;
[energyRegions, energyStats] = findEnergyRegions( ...
    baseParams, batch, totalSamples);
energySeconds = toc(ticEnergy);
fprintf(['Energy scan done in %.1f s | chunks=%d | samples read=%d ', ...
    '(%.2f%%) | regions=%d\n\n'], ...
    energySeconds, energyStats.chunk_count, ...
    energyStats.samples_read, energyStats.read_fraction*100, ...
    size(energyRegions, 1));

%% -------------------- Stage 2: preamble correlation in energy regions --------------------
ticCorrelation = tic;
[candidates, candidateRegions, correlationStats] = refineEnergyRegions( ...
    baseParams, coarseTemplate, batch, energyRegions, totalSamples);
correlationSeconds = toc(ticCorrelation);
coarseSeconds = energySeconds + correlationSeconds;
fprintf(['Correlation refinement done in %.1f s | regions=%d | ', ...
    'raw clusters=%d | selected candidates=%d\n\n'], ...
    correlationSeconds, correlationStats.region_count, ...
    correlationStats.raw_candidate_count, numel(candidates));

%% -------------------- Stage 3: full decode only at candidates --------------------
% Decoding each candidate is independent, so it runs in parfor across
% workers. Duplicate filtering and frame saving are done afterwards because
% they depend on previously accepted frames.
frames = emptyFrameRecord();
packetCount = 0;
attemptCount = 0;
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
    offset = max(0, min(candidate - batch.pre_packet_guard_samples, ...
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
        baseParams.interference_coefficient;

    try
        result = decode_x410_dw1000(windowOptions);
    catch decodeError
        fprintf('  [candidate %d] Decode failed: %s\n', ...
            c, decodeError.message);
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
        fprintf('  Duplicate packet near abs_start=%d; skipping.\n', ...
            absStart);
        continue;
    end

    if batch.require_fcs_pass && ~result.payload.fcs_pass
        fprintf('  Packet rejected: FCS failed at abs_start=%d.\n', ...
            absStart);
        continue;
    end

    packetCount = packetCount + 1;
    frames(packetCount) = packageFrameRecord( ...
        packetCount, candOffsets(c), timing, result, baseParams);

    fprintf(['  Saved packet #%d | abs_start=%d | t=%.3f ms | ', ...
        'SFD=%s | corr=%.3f | FCS=%d\n'], ...
        packetCount, absStart, frames(packetCount).time_start_s*1e3, ...
        frames(packetCount).sfd_name, ...
        frames(packetCount).sfd_correlation, ...
        frames(packetCount).fcs_pass);

    if batch.save_individual_cir
        cirFile = fullfile(batch.output_directory, ...
            sprintf('cir_%03d.mat', packetCount));
        cir = frames(packetCount).cir; %#ok<NASGU>
        meta = frames(packetCount); %#ok<NASGU>
        save(cirFile, 'cir', 'meta', '-v7.3');
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

save(batch.mat_file, 'results', '-v7.3');
writeSummaryCsv(batch.summary_csv, frames);

fprintf('\nSaved %d packet(s) to:\n  %s\n  %s\n', ...
    packetCount, batch.mat_file, batch.summary_csv);
fprintf(['Timing: energy %.1f s | correlation %.1f s | ', ...
    'full decode %.1f s | fine attempts %d\n'], ...
    energySeconds, correlationSeconds, fineSeconds, attemptCount);
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
    'energy_min_region_samples', 3e4, ...
    'energy_region_pre_guard_samples', 5e4, ...
    'energy_region_post_guard_samples', 5e4, ...
    'energy_region_merge_samples', 1e4, ...
    'correlation_decimation', 32, ...
    'correlation_repetitions', 8, ...
    'correlation_chunk_samples', 4e6, ...
    'correlation_overlap_samples', 3e5, ...
    'corr_threshold_sigma', 5, ...
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
    'save_individual_cir', true, ...
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
batch.energy_baseline_fraction = min(1, max(eps, ...
    double(batch.energy_baseline_fraction)));
batch.corr_threshold_sigma = max(0, double(batch.corr_threshold_sigma));
batch.require_fcs_pass = logical(batch.require_fcs_pass);
batch.save_individual_cir = logical(batch.save_individual_cir);

if batch.energy_threshold_sigma_low > batch.energy_threshold_sigma_high
    warning('decode_x410_dw1000_all:EnergyThresholdOrder', ...
        'Clamping the low energy threshold to the high threshold.');
    batch.energy_threshold_sigma_low = ...
        batch.energy_threshold_sigma_high;
end
if batch.energy_step_samples > batch.energy_chunk_samples
    warning('decode_x410_dw1000_all:StepExceedsChunk', ...
        ['energy_step_samples > energy_chunk_samples; ', ...
         'clamping step to chunk size.']);
    batch.energy_step_samples = batch.energy_chunk_samples;
end
if batch.correlation_overlap_samples >= batch.correlation_chunk_samples
    warning('decode_x410_dw1000_all:CorrelationOverlapTooLarge', ...
        'Clamping correlation overlap below the correlation chunk size.');
    batch.correlation_overlap_samples = ...
        max(1, floor(batch.correlation_chunk_samples/4));
end
end

function totalSamples = countCaptureSamples(params)
info = dir(params.file_name);
if isempty(info)
    error('decode_x410_dw1000_all:FileNotFound', ...
        'Cannot find capture file: %s', params.file_name);
end
c = dw1000decoder.constants();
totalSamples = floor(info.bytes / (c.BYTES_PER_IQ_SAMPLE*params.ant_num));
end

function coefficient = estimateInterferenceCoefficient(params, totalSamples)
quietOffset = params.interference_quiet_offset;
quietNum = params.interference_quiet_num;
if quietOffset < 0 || quietOffset >= totalSamples
    error('decode_x410_dw1000_all:QuietOffsetOutOfRange', ...
        'interference_quiet_offset is outside the capture.');
end
quietNum = min(quietNum, totalSamples - quietOffset);
if quietNum < params.interference_period_samples
    error('decode_x410_dw1000_all:NotEnoughQuietSamples', ...
        'Not enough samples available for interference estimation.');
end

rawQuiet = dw1000decoder.readIqRaw(params.file_name, quietOffset, quietNum, params.ant_num);
rxQuiet = dw1000decoder.selectIqChannel(rawQuiet, params.channel_index);
quietN = quietOffset + (0:length(rxQuiet)-1).';
quietBasis = dw1000decoder.synchronousTone(quietN, ...
    params.interference_tone_bin, params.interference_period_samples);
coefficient = mean(rxQuiet .* conj(quietBasis));

fprintf('Precomputed interference coefficient once for full-file scan.\n');
fprintf('  Amplitude: %.3f ADC counts, phase: %.3f deg\n', ...
    abs(coefficient), angle(coefficient)*180/pi);
end

function template = buildCoarseTemplate(params, reference, batch)
%BUILDCOARSETEMPLATE Map one preamble symbol to the coarse decimated grid.
[p, q] = rat(params.fs_rx / reference.fs, 1e-12);
prefRx = resample(reference.preamble_waveform, p, q);
prefRx = prefRx(:);
D = batch.correlation_decimation;
prefDs = prefRx(1:D:end);
prefDs = prefDs / (norm(prefDs) + eps);
template = struct( ...
    'decimation', D, ...
    'preamble_ds', prefDs, ...
    'preamble_rx_length', numel(prefRx));
end

function [regions, stats] = findEnergyRegions(params, batch, totalSamples)
%FINDENERGYREGIONS Locate burst intervals from a truly strided file read.
regions = zeros(0, 2);
chunkCount = 0;
samplesRead = 0;
offset = 0;
estimatedChunks = ceil(totalSamples/batch.energy_step_samples);
chunkOffsets = zeros(estimatedChunks, 1);
thresholdHigh = zeros(estimatedChunks, 1);
thresholdLow = zeros(estimatedChunks, 1);
chunkRegionCount = zeros(estimatedChunks, 1);

fprintf('Stage 1/3: %dx strided energy-envelope scan...\n', ...
    batch.energy_read_stride);
while offset < totalSamples
    chunkSamples = min(batch.energy_chunk_samples, totalSamples - offset);
    chunkCount = chunkCount + 1;
    [raw, sampleIndices] = dw1000decoder.readIqRawStrided( ...
        params.file_name, offset, chunkSamples, params.ant_num, ...
        batch.energy_read_stride);
    rx = dw1000decoder.selectIqChannel(raw, params.channel_index);
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
    high = energyMedian + ...
        batch.energy_threshold_sigma_high*robustSigma;
    low = energyMedian + ...
        batch.energy_threshold_sigma_low*robustSigma;

    localRegions = hysteresisEnergyRegions( ...
        energy, sampleIndices, high, low, ...
        batch.energy_read_stride, batch.energy_min_region_samples, ...
        offset + chunkSamples - 1);
    if ~isempty(localRegions)
        localRegions(:, 1) = max(0, localRegions(:, 1) - ...
            batch.energy_region_pre_guard_samples);
        localRegions(:, 2) = min(totalSamples - 1, ...
            localRegions(:, 2) + batch.energy_region_post_guard_samples);
        regions = [regions; localRegions]; %#ok<AGROW>
    end

    samplesRead = samplesRead + numel(sampleIndices);
    chunkOffsets(chunkCount) = offset;
    thresholdHigh(chunkCount) = high;
    thresholdLow(chunkCount) = low;
    chunkRegionCount(chunkCount) = size(localRegions, 1);

    if mod(chunkCount, 5) == 0 || offset + chunkSamples >= totalSamples
        fprintf(['  energy chunk %d | offset=%d (%.1f%%) | ', ...
            'regions so far=%d\n'], ...
            chunkCount, offset, 100*offset/max(totalSamples, 1), ...
            size(regions, 1));
    end
    if offset + chunkSamples >= totalSamples
        break;
    end
    offset = offset + batch.energy_step_samples;
end

regions = mergeIntervals(regions, batch.energy_region_merge_samples);
stats = struct( ...
    'chunk_count', chunkCount, ...
    'samples_read', samplesRead, ...
    'read_fraction', samplesRead/max(totalSamples, 1), ...
    'read_stride', batch.energy_read_stride, ...
    'chunk_offsets', chunkOffsets(1:chunkCount), ...
    'threshold_high', thresholdHigh(1:chunkCount), ...
    'threshold_low', thresholdLow(1:chunkCount), ...
    'chunk_region_count', chunkRegionCount(1:chunkCount));
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
        params, template, batch, energyRegions, totalSamples)
%REFINEENERGYREGIONS Correlate only the continuous energetic intervals.
candidates = zeros(0, 1);
candidateRegions = zeros(0, 2);
rawCandidateCount = 0;
fallbackCount = 0;
regionCandidateCount = zeros(size(energyRegions, 1), 1);
correlationChunkCount = 0;
step = batch.correlation_chunk_samples - ...
    batch.correlation_overlap_samples;

fprintf('Stage 2/3: preamble correlation inside energy regions...\n');
for regionIdx = 1:size(energyRegions, 1)
    regionFirst = energyRegions(regionIdx, 1);
    regionLast = energyRegions(regionIdx, 2);
    regionCandidates = zeros(0, 1);
    offset = regionFirst;

    while offset <= regionLast
        chunkSamples = min(batch.correlation_chunk_samples, ...
            regionLast - offset + 1);
        correlationChunkCount = correlationChunkCount + 1;
        rx = readProcessedChunkSilent(params, offset, chunkSamples);
        [localCandidates, ~, ~] = ...
            detectCorrelationCandidates(rx, offset, template, batch);
        regionCandidates = [regionCandidates; localCandidates(:)]; %#ok<AGROW>
        if offset + chunkSamples - 1 >= regionLast
            break;
        end
        offset = offset + step;
    end

    regionCandidates = mergeCandidates( ...
        regionCandidates, batch.candidate_merge_samples);
    rawCandidateCount = rawCandidateCount + numel(regionCandidates);
    regionCandidateCount(regionIdx) = numel(regionCandidates);
    targetStart = min(regionLast, regionFirst + ...
        batch.energy_region_pre_guard_samples);
    if isempty(regionCandidates)
        % Energy already supplied the gate. Retain one candidate so a weak
        % or distorted preamble still gets one full-rate decode attempt.
        selectedCandidate = targetStart;
        fallbackCount = fallbackCount + 1;
    else
        % One energy burst normally represents one packet. Choose the
        % correlation cluster nearest the unguarded energy onset so the
        % fine decoder cannot jump to a stronger packet in the next burst.
        [~, selectedIdx] = min(abs(regionCandidates - targetStart));
        selectedCandidate = regionCandidates(selectedIdx);
    end
    candidates(end + 1, 1) = selectedCandidate; %#ok<AGROW>
    candidateRegions(end + 1, :) = [regionFirst, regionLast]; %#ok<AGROW>

    fprintf(['  correlation region %d/%d | %d..%d | ', ...
        'clusters=%d | selected=%d\n'], ...
        regionIdx, size(energyRegions, 1), regionFirst, regionLast, ...
        numel(regionCandidates), selectedCandidate);
end

valid = candidateRegions(:, 1) + batch.min_window_samples <= totalSamples;
candidates = candidates(valid);
candidateRegions = candidateRegions(valid, :);
stats = struct( ...
    'region_count', size(energyRegions, 1), ...
    'correlation_chunk_count', correlationChunkCount, ...
    'raw_candidate_count', rawCandidateCount, ...
    'fallback_candidate_count', fallbackCount, ...
    'region_candidate_count', regionCandidateCount, ...
    'decimation', batch.correlation_decimation);
end

function [candidates, fallbackCandidate, fallbackScore] = ...
        detectCorrelationCandidates(rx, sampleOffset, template, batch)
D = batch.correlation_decimation;
rxDs = rx(1:D:end);
candidates = zeros(0, 1);
fallbackCandidate = sampleOffset;
fallbackScore = -Inf;
templateLength = numel(template.preamble_ds);
if templateLength < 4 || numel(rxDs) <= templateLength
    return;
end

matched = fftfilt(flipud(conj(template.preamble_ds)), rxDs);
energyNorm = sqrt(movsum(abs(rxDs).^2, [templateLength - 1, 0])) + eps;
corrScore = abs(matched)./energyNorm;
repetitionCount = min(batch.correlation_repetitions, ...
    max(1, floor((numel(corrScore) - 1)*D/ ...
    max(template.preamble_rx_length, 1)) + 1));
shifts = round((0:repetitionCount - 1)* ...
    template.preamble_rx_length/D);
validLength = numel(corrScore) - shifts(end);
if validLength < 3
    return;
end

repeatedScore = zeros(validLength, 1);
for r = 1:repetitionCount
    repeatedScore = repeatedScore + ...
        corrScore(1 + shifts(r):validLength + shifts(r));
end
repeatedScore = repeatedScore/repetitionCount;

sortedScore = sort(repeatedScore);
baselineCount = max(16, floor(0.60*numel(sortedScore)));
baselineCount = min(baselineCount, numel(sortedScore));
baseline = sortedScore(1:baselineCount);
corrMedian = median(baseline);
corrSigma = 1.4826*median(abs(baseline - corrMedian));
corrThreshold = corrMedian + ...
    batch.corr_threshold_sigma*max(corrSigma, eps);

[fallbackScore, strongest] = max(repeatedScore);
fallbackCandidate = max(0, sampleOffset + ...
    (double(strongest) - templateLength)*D);

minPeakDistance = max(1, round( ...
    batch.correlation_peak_min_distance_samples/D));
if exist('findpeaks', 'file') == 2
    [~, locs] = findpeaks(repeatedScore, ...
        'MinPeakHeight', corrThreshold, ...
        'MinPeakDistance', minPeakDistance);
else
    locs = simpleFindPeaks( ...
        repeatedScore, corrThreshold, minPeakDistance);
end
if isempty(locs)
    return;
end

clusterGap = max(1, round(batch.correlation_cluster_gap_samples/D));
clusterStarts = [1; find(diff(locs) > clusterGap) + 1];
clusterEnds = [clusterStarts(2:end) - 1; numel(locs)];
for k = 1:numel(clusterStarts)
    members = clusterStarts(k):clusterEnds(k);
    if numel(members) < batch.correlation_min_cluster_peaks
        continue;
    end
    firstPeak = locs(members(1));
    estimatedStart = sampleOffset + ...
        (double(firstPeak) - templateLength)*D;
    candidates(end + 1, 1) = max(0, estimatedStart); %#ok<AGROW>
end
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

function merged = mergeCandidates(candidates, mergeSamples)
if isempty(candidates)
    merged = zeros(0, 1);
    return;
end
candidates = sort(candidates(:));
merged = candidates(1);
for k = 2:numel(candidates)
    if candidates(k) - merged(end) > mergeSamples
        merged(end+1, 1) = candidates(k); %#ok<AGROW>
    end
end
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

function rx = cancelToneAtIndices(rx, sampleIndices, params)
%CANCELTONEATINDICES Remove the cached synchronous tone at sparse indices.
rx = rx(:);
if ~params.enable_interference_cancellation
    return;
end
if isempty(params.interference_coefficient)
    error('decode_x410_dw1000_all:MissingInterferenceCoefficient', ...
        'The energy scanner requires a precomputed interference coefficient.');
end
basis = dw1000decoder.synchronousTone(sampleIndices(:), ...
    params.interference_tone_bin, params.interference_period_samples);
rx = rx - params.interference_coefficient(1).*basis;
end

function rx = readProcessedChunkSilent(params, sampleOffset, sampleNum)
%READPROCESSEDCHUNKSILENT Cheap read + tone cancel + CF shift (no logging).
raw = dw1000decoder.readIqRaw(params.file_name, sampleOffset, sampleNum, params.ant_num);
rx = dw1000decoder.selectIqChannel(raw, params.channel_index);

if params.enable_interference_cancellation
    if isempty(params.interference_coefficient)
        error('decode_x410_dw1000_all:MissingInterferenceCoefficient', ...
            'Silent chunk reader requires a precomputed interference coefficient.');
    end
    coefficient = params.interference_coefficient(1);
    n = sampleOffset + (0:length(rx)-1).';
    basis = dw1000decoder.synchronousTone(n, ...
        params.interference_tone_bin, params.interference_period_samples);
    rx = rx - coefficient .* basis;
end

frequencyShift = params.x410_center_frequency - params.dw1000_center_frequency;
n = sampleOffset + (0:length(rx)-1).';
rx = rx .* exp(1j*2*pi*frequencyShift*n / params.fs_rx);
rx = rx - mean(rx);
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
    warning('decode_x410_dw1000_all:CsvWriteError', ...
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
