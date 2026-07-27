function pipeline = uwbSicPipeline(cfg)
%UWBSICPIPELINE Successively cancel QM35 and DW1000 packets.
%   PIPELINE = UWBSICPIPELINE(CFG) performs:
%     raw -> decode QM35 -> cancel QM35 -> decode DW1000 -> cancel DW1000.

arguments
    cfg struct
end

pipelineDir = fileparts(mfilename('fullpath'));
projectDir = fileparts(pipelineDir);
addpath(projectDir);
addpath(pipelineDir);

cfg = normalizeConfig(cfg, projectDir);
paths = buildPaths(cfg);
ensureDirectory(cfg.output_root);

pipeline = struct();
pipeline.version = 1;
pipeline.status = 'running';
pipeline.started_at = timestampNow();
pipeline.completed_at = '';
pipeline.config = cfg;
pipeline.paths = paths;
pipeline.stages = struct();
saveManifest(paths.manifest_file, pipeline);

fprintf('\n========== UWB SIC pipeline ==========\n');
fprintf('Input : %s\n', cfg.input_file);
fprintf('Output: %s\n', cfg.output_root);

pipeline.stages.qm35_decode = runDecodeStage( ...
    projectDir, cfg.input_file, 'QM35', paths.qm35_decode_dir, ...
    cfg.resume, cfg.overwrite);
saveManifest(paths.manifest_file, pipeline);

toneCoefficient = loadToneCoefficient( ...
    pipeline.stages.qm35_decode.scan_file);
pipeline.stages.qm35_cancel = runCancelStage( ...
    projectDir, cfg.input_file, cfg.input_file, 'QM35', ...
    paths.qm35_decode_dir, paths.qm35_removed_file, toneCoefficient, ...
    cfg, cfg.resume, cfg.overwrite);
saveManifest(paths.manifest_file, pipeline);

pipeline.stages.dw1000_decode = runDecodeStage( ...
    projectDir, paths.qm35_removed_file, 'DW1000', ...
    paths.dw1000_decode_dir, cfg.resume, cfg.overwrite);
saveManifest(paths.manifest_file, pipeline);

pipeline.stages.dw1000_cancel = runCancelStage( ...
    projectDir, paths.qm35_removed_file, cfg.input_file, 'DW1000', ...
    paths.dw1000_decode_dir, paths.qm35_preserved_file, ...
    toneCoefficient, cfg, cfg.resume, cfg.overwrite);

pipeline.status = 'complete';
pipeline.completed_at = timestampNow();
writePipelineSummary(paths.summary_file, pipeline);
saveManifest(paths.manifest_file, pipeline);

if cfg.make_plots
    runPipelineVisualization(pipelineDir, paths.manifest_file);
end

fprintf('\n========== SIC complete ==========\n');
fprintf('QM35 decoded/cancelled   : %d / %d\n', ...
    pipeline.stages.qm35_decode.packet_count, ...
    pipeline.stages.qm35_cancel.cancelled_count);
fprintf('DW1000 decoded/cancelled : %d / %d\n', ...
    pipeline.stages.dw1000_decode.packet_count, ...
    pipeline.stages.dw1000_cancel.cancelled_count);
fprintf('QM35-preserved output    : %s\n', paths.qm35_preserved_file);
fprintf('Manifest                 : %s\n', paths.manifest_file);
end

function cfg = normalizeConfig(cfg, projectDir)
required = {'input_file', 'output_root'};
missing = required(~isfield(cfg, required));
if ~isempty(missing)
    error('uwbSicPipeline:MissingConfig', ...
        'Missing configuration field(s): %s', strjoin(missing, ', '));
end
cfg.input_file = char(string(cfg.input_file));
cfg.output_root = char(string(cfg.output_root));
if ~isfile(cfg.input_file)
    error('uwbSicPipeline:InputNotFound', ...
        'Input capture not found: %s', cfg.input_file);
end
if ~isfield(cfg, 'cancellation_mode') || isempty(cfg.cancellation_mode)
    cfg.cancellation_mode = 'optimal_complex';
end
validModes = {'baseline', 'fixed_scale', 'optimal_real', 'optimal_complex'};
if ~any(strcmpi(cfg.cancellation_mode, validModes))
    error('uwbSicPipeline:InvalidCancellationMode', ...
        'Unsupported cancellation mode: %s', cfg.cancellation_mode);
end
if ~isfield(cfg, 'resume') || isempty(cfg.resume)
    cfg.resume = true;
end
if ~isfield(cfg, 'make_plots') || isempty(cfg.make_plots)
    cfg.make_plots = true;
end
if ~isfield(cfg, 'overwrite') || isempty(cfg.overwrite)
    cfg.overwrite = false;
end
cfg.resume = logical(cfg.resume);
cfg.make_plots = logical(cfg.make_plots);
cfg.overwrite = logical(cfg.overwrite);
cfg.project_directory = projectDir;
end

function paths = buildPaths(cfg)
paths = struct();
paths.manifest_file = fullfile(cfg.output_root, 'pipeline_manifest.mat');
paths.summary_file = fullfile(cfg.output_root, 'pipeline_summary.csv');
paths.qm35_decode_dir = fullfile(cfg.output_root, '01_qm35_decode');
paths.qm35_cancel_dir = fullfile(cfg.output_root, '02_qm35_cancel');
paths.qm35_removed_file = fullfile(paths.qm35_cancel_dir, 'qm35_removed.dat');
paths.dw1000_decode_dir = fullfile(cfg.output_root, '03_dw1000_decode');
paths.dw1000_cancel_dir = fullfile(cfg.output_root, '04_dw1000_cancel');
paths.qm35_preserved_file = fullfile( ...
    paths.dw1000_cancel_dir, 'dw1000_removed_qm35_preserved.dat');
paths.validation_dir = fullfile(cfg.output_root, '05_validation');
end

function stage = runDecodeStage(projectDir, inputFile, profile, ...
        resultDir, resume, overwrite)
matFile = fullfile(resultDir, 'all_frames_cir.mat');
csvFile = fullfile(resultDir, 'frame_summary.csv');
if resume && isfile(matFile) && isfile(csvFile)
    saved = load(matFile, 'results');
    validateDecodeProvenance(saved.results, inputFile, profile);
    results = saved.results;
    reused = true;
    fprintf('\n[%s decode] reusing %s\n', profile, matFile);
else
    assertDecodeWriteAllowed(resultDir, matFile, csvFile, overwrite);
    ensureDirectory(resultDir);
    sic_stage_config = struct( ...
        'input_file', inputFile, ...
        'phy_profile', profile, ...
        'result_directory', resultDir); %#ok<NASGU>
    run(fullfile(projectDir, 'run_decode_uwb_all.m'));
    saved = load(matFile, 'results');
    results = saved.results;
    validateDecodeProvenance(results, inputFile, profile);
    reused = false;
end
stage = struct( ...
    'name', sprintf('%s decode', profile), ...
    'profile', profile, ...
    'input_file', inputFile, ...
    'result_directory', resultDir, ...
    'scan_file', matFile, ...
    'summary_file', csvFile, ...
    'packet_count', results.packet_count, ...
    'fcs_pass_count', results.fcs_pass_count, ...
    'reused', reused, ...
    'completed_at', timestampNow());
end

function stage = runCancelStage(projectDir, fittingFile, outputBaseFile, ...
        profile, resultDir, outputFile, toneCoefficient, cfg, ...
        resume, overwrite)
[outputDir, outputStem] = fileparts(outputFile);
metadataFile = fullfile(outputDir, [outputStem '_metadata.mat']);
summaryFile = fullfile(outputDir, [outputStem '_summary.csv']);
if resume && isfile(outputFile) && isfile(metadataFile) && isfile(summaryFile)
    saved = load(metadataFile, 'success_count', 'reports', ...
        'input_file', 'fitting_file', 'output_base_file', ...
        'output_file', 'params', 'remove_synchronous_tone');
    validateCancellationProvenance(saved, fittingFile, ...
        outputBaseFile, outputFile, profile);
    reports = saved.reports;
    success_count = saved.success_count;
    reused = true;
    fprintf('\n[%s cancel] reusing %s\n', profile, outputFile);
else
    assertCancellationWriteAllowed( ...
        outputFile, metadataFile, summaryFile, overwrite);
    ensureDirectory(outputDir);
    sic_stage_config = struct( ...
        'input_file', fittingFile, ...
        'output_base_file', outputBaseFile, ...
        'phy_profile', profile, ...
        'result_directory', resultDir, ...
        'output_file', outputFile, ...
        'metadata_file', metadataFile, ...
        'summary_file', summaryFile, ...
        'cancellation_mode', cfg.cancellation_mode, ...
        'remove_synchronous_tone', true, ...
        'tone_coefficient', toneCoefficient); %#ok<NASGU>
    run(fullfile(projectDir, 'run_cancel_all_uwb_packets.m'));
    saved = load(metadataFile, 'success_count', 'reports', ...
        'input_file', 'fitting_file', 'output_base_file', ...
        'output_file', 'params', 'remove_synchronous_tone');
    reports = saved.reports;
    success_count = saved.success_count;
    validateCancellationProvenance(saved, fittingFile, ...
        outputBaseFile, outputFile, profile);
    reused = false;
end
suppression = [reports.frame_suppression_db];
suppression = suppression([reports.success] & isfinite(suppression));
stage = struct( ...
    'name', sprintf('%s cancellation', profile), ...
    'profile', profile, ...
    'input_file', fittingFile, ...
    'fitting_file', fittingFile, ...
    'output_base_file', outputBaseFile, ...
    'output_file', outputFile, ...
    'metadata_file', metadataFile, ...
    'summary_file', summaryFile, ...
    'selected_count', numel(reports), ...
    'cancelled_count', success_count, ...
    'skipped_count', numel(reports) - success_count, ...
    'median_packet_suppression_db', safeMedian(suppression), ...
    'mean_packet_suppression_db', safeMean(suppression), ...
    'reused', reused, ...
    'completed_at', timestampNow());
end

function validateDecodeProvenance(results, inputFile, profile)
if ~isfield(results, 'file_name') || ...
        ~samePath(results.file_name, inputFile)
    error('uwbSicPipeline:DecodeInputMismatch', ...
        'Decode result does not belong to input: %s', inputFile);
end
expectedCode = profileCode(profile);
if ~isfield(results, 'params') || ...
        results.params.code_index ~= expectedCode
    error('uwbSicPipeline:DecodeProfileMismatch', ...
        '%s decode result has the wrong preamble code.', profile);
end
end

function validateCancellationProvenance( ...
        saved, fittingFile, outputBaseFile, outputFile, profile)
required = {'fitting_file', 'output_base_file', ...
    'remove_synchronous_tone'};
if ~all(isfield(saved, required))
    error('uwbSicPipeline:OldCancellationMetadata', ...
        ['Cancellation metadata predates the QM35-preserving pipeline. ', ...
        'Rerun this cancellation stage with overwrite=true.']);
end
if ~samePath(saved.fitting_file, fittingFile) || ...
        ~samePath(saved.output_base_file, outputBaseFile) || ...
        ~samePath(saved.output_file, outputFile)
    error('uwbSicPipeline:CancellationInputMismatch', ...
        '%s cancellation metadata has mismatched input/output paths.', profile);
end
if ~saved.remove_synchronous_tone
    error('uwbSicPipeline:ToneNotRemoved', ...
        '%s cancellation output did not remove the synchronous tone.', profile);
end
if saved.params.code_index ~= profileCode(profile)
    error('uwbSicPipeline:CancellationProfileMismatch', ...
        '%s cancellation metadata has the wrong preamble code.', profile);
end
if dir(outputBaseFile).bytes ~= dir(outputFile).bytes
    error('uwbSicPipeline:OutputLengthMismatch', ...
        '%s cancellation changed the capture length.', profile);
end
end

function coefficient = loadToneCoefficient(scanFile)
saved = load(scanFile, 'results');
params = saved.results.params;
if ~isfield(params, 'interference_coefficient') || ...
        isempty(params.interference_coefficient)
    error('uwbSicPipeline:MissingToneCoefficient', ...
        'QM35 decode did not save a synchronous-tone coefficient.');
end
coefficient = params.interference_coefficient(1);
end

function code = profileCode(profile)
switch upper(profile)
    case 'QM35'
        code = 9;
    case 'DW1000'
        code = 10;
    otherwise
        error('uwbSicPipeline:UnknownProfile', ...
            'Unknown PHY profile: %s', profile);
end
end

function assertDecodeWriteAllowed(resultDir, matFile, csvFile, overwrite)
exists = [isfile(matFile), isfile(csvFile)];
if any(exists) && ~overwrite
    error('uwbSicPipeline:PartialDecode', ...
        ['Existing decode products found in %s. Set resume=true to ', ...
        'reuse a complete stage or overwrite=true to replace it.'], resultDir);
end
end

function assertCancellationWriteAllowed( ...
        outputFile, metadataFile, summaryFile, overwrite)
exists = [isfile(outputFile), isfile(metadataFile), isfile(summaryFile)];
if any(exists) && ~overwrite
    error('uwbSicPipeline:PartialCancellation', ...
        ['Existing cancellation products found in %s. Set resume=true ', ...
        'to reuse a complete stage or overwrite=true to replace it.'], ...
        fileparts(outputFile));
end
end

function writePipelineSummary(fileName, pipeline)
names = {'QM35 decode'; 'QM35 cancellation'; ...
    'DW1000 decode'; 'DW1000 cancellation'};
profiles = {'QM35'; 'QM35'; 'DW1000'; 'DW1000'};
inputFiles = {pipeline.stages.qm35_decode.input_file; ...
    pipeline.stages.qm35_cancel.input_file; ...
    pipeline.stages.dw1000_decode.input_file; ...
    pipeline.stages.dw1000_cancel.input_file};
outputFiles = {pipeline.stages.qm35_decode.scan_file; ...
    pipeline.stages.qm35_cancel.output_file; ...
    pipeline.stages.dw1000_decode.scan_file; ...
    pipeline.stages.dw1000_cancel.output_file};
packetCounts = [pipeline.stages.qm35_decode.packet_count; ...
    pipeline.stages.qm35_cancel.cancelled_count; ...
    pipeline.stages.dw1000_decode.packet_count; ...
    pipeline.stages.dw1000_cancel.cancelled_count];
fcsCounts = [pipeline.stages.qm35_decode.fcs_pass_count; NaN; ...
    pipeline.stages.dw1000_decode.fcs_pass_count; NaN];
suppressionDb = [NaN; ...
    pipeline.stages.qm35_cancel.median_packet_suppression_db; NaN; ...
    pipeline.stages.dw1000_cancel.median_packet_suppression_db];
summary = table(names, profiles, inputFiles, outputFiles, packetCounts, ...
    fcsCounts, suppressionDb, 'VariableNames', ...
    {'stage', 'profile', 'input_file', 'output_file', 'packet_count', ...
    'fcs_pass_count', 'median_suppression_db'});
writetable(summary, fileName);
end

function saveManifest(fileName, pipeline)
ensureDirectory(fileparts(fileName));
save(fileName, 'pipeline', '-v7.3');
end

function ensureDirectory(directory)
if ~isfolder(directory)
    mkdir(directory);
end
end

function tf = samePath(a, b)
tf = strcmpi(char(java.io.File(char(a)).getCanonicalPath()), ...
    char(java.io.File(char(b)).getCanonicalPath()));
end

function value = safeMedian(values)
if isempty(values)
    value = NaN;
else
    value = median(values);
end
end

function value = safeMean(values)
if isempty(values)
    value = NaN;
else
    value = mean(values);
end
end

function text = timestampNow()
text = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss Z'));
end

function runPipelineVisualization(pipelineDir, manifestFile)
% Run the standalone visualization script in an isolated workspace.
sic_manifest_file = manifestFile; %#ok<NASGU>
run(fullfile(pipelineDir, 'visualize_UwbSicPipeline.m'));
end
