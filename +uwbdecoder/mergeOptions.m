function params = mergeOptions(params, options)
%MERGEOPTIONS Apply and validate user configuration overrides.
%   PARAMS = MERGEOPTIONS(PARAMS, OPTIONS) merges the override structure
%   OPTIONS into the default PARAMS, then validates every field. Unknown
%   fields in OPTIONS error out; out-of-range values error with a
%   descriptive message.
%
%   See also DEFAULTOPTIONS.

if ~isstruct(options) || ~isscalar(options)
    error('mergeOptions:InvalidOptions', ...
        'Options must be a scalar structure.');
end

names = fieldnames(options);
unknown = setdiff(names, fieldnames(params));
if ~isempty(unknown)
    error('mergeOptions:UnknownOption', ...
        'Unknown decoder option: %s', strjoin(unknown, ', '));
end

for k = 1:length(names)
    params.(names{k}) = options.(names{k});
end

if params.channel_index < 1 || params.channel_index > params.ant_num
    error('mergeOptions:InvalidChannelIndex', ...
        'channel_index must be between 1 and ant_num.');
end
if params.sample_offset < 0 || params.sample_num <= 0 || params.fs_rx <= 0
    error('mergeOptions:InvalidSampleParams', ...
        'Sample offset, count, and sample rate are invalid.');
end

validSfdModes = {'decawave', 'ieee', '4z1', '4z2', '4z3', '4z4', 'auto'};
if ~(ischar(params.sfd_mode) || ...
        (isstring(params.sfd_mode) && isscalar(params.sfd_mode)))
    error('mergeOptions:InvalidSfdMode', ...
        'sfd_mode must select a supported SFD template or ''auto''.');
end
params.sfd_mode = lower(char(params.sfd_mode));
if ~ismember(params.sfd_mode, validSfdModes)
    error('mergeOptions:InvalidSfdMode', ...
        ['sfd_mode must be ''decawave'', ''ieee'', ''4z1'', ', ...
         '''4z2'', ''4z3'', ''4z4'', or ''auto''.']);
end

if numel(params.decawave_sfd) ~= 8 || ...
        any(~ismember(params.decawave_sfd(:), [-1, 0, 1]))
    error('mergeOptions:InvalidDecawaveSfd', ...
        'The Decawave DW-8 SFD must contain eight ternary symbols.');
end
if numel(params.ieee_sfd) ~= 8 || ...
        any(~ismember(params.ieee_sfd(:), [-1, 0, 1]))
    error('mergeOptions:InvalidIeeeSfd', ...
        'The IEEE short SFD must contain eight ternary symbols.');
end

sfd4zLengths = [4, 8, 16, 32];
for sfdNumber = 1:4
    fieldName = sprintf('sfd4z_%d', sfdNumber);
    sequence = params.(fieldName);
    if numel(sequence) ~= sfd4zLengths(sfdNumber) || ...
            any(~ismember(sequence(:), [-1, 0, 1]))
        error('mergeOptions:Invalid4zSfd', ...
            'IEEE 802.15.4z SFD #%d must contain %d ternary symbols.', ...
            sfdNumber, sfd4zLengths(sfdNumber));
    end
end

if ~isscalar(params.cir_repetitions) || ...
        params.cir_repetitions < 1 || ...
        params.cir_repetitions ~= fix(params.cir_repetitions)
    error('mergeOptions:InvalidCirRepetitions', ...
        'cir_repetitions must be a positive integer.');
end
if params.cir_repetitions > params.preamble_repetitions
    error('mergeOptions:CirRepetitionsExceedPreamble', ...
        'cir_repetitions cannot exceed preamble_repetitions.');
end

if ~isempty(params.cir_skip_initial_repetitions)
    if ~isscalar(params.cir_skip_initial_repetitions) || ...
            params.cir_skip_initial_repetitions < 0 || ...
            params.cir_skip_initial_repetitions ~= ...
            fix(params.cir_skip_initial_repetitions)
        error('mergeOptions:InvalidCirSkip', ...
            ['cir_skip_initial_repetitions must be empty or a ', ...
             'non-negative integer.']);
    end
    if params.cir_skip_initial_repetitions >= ...
            params.preamble_repetitions
        error('mergeOptions:CirSkipExceedsPreamble', ...
            ['cir_skip_initial_repetitions must leave at least one ', ...
             'preamble repetition for CIR estimation.']);
    end
end

if ~isempty(params.cir_pre_samples)
    if ~isscalar(params.cir_pre_samples) || params.cir_pre_samples < 0 || ...
            params.cir_pre_samples ~= fix(params.cir_pre_samples)
        error('mergeOptions:InvalidCirPreSamples', ...
            'cir_pre_samples must be empty or a non-negative integer.');
    end
end

if ~isempty(params.cir_post_samples)
    if ~isscalar(params.cir_post_samples) || params.cir_post_samples < 1 || ...
            params.cir_post_samples ~= fix(params.cir_post_samples)
        error('mergeOptions:InvalidCirPostSamples', ...
            'cir_post_samples must be empty or a positive integer.');
    end
end

if ~isempty(params.cir_diag_pre_samples)
    if ~isscalar(params.cir_diag_pre_samples) || ...
            params.cir_diag_pre_samples < 0 || ...
            params.cir_diag_pre_samples ~= fix(params.cir_diag_pre_samples)
        error('mergeOptions:InvalidCirDiagPreSamples', ...
            'cir_diag_pre_samples must be empty or a non-negative integer.');
    end
end

if ~isempty(params.cir_diag_post_samples)
    if ~isscalar(params.cir_diag_post_samples) || ...
            params.cir_diag_post_samples < 1 || ...
            params.cir_diag_post_samples ~= fix(params.cir_diag_post_samples)
        error('mergeOptions:InvalidCirDiagPostSamples', ...
            'cir_diag_post_samples must be empty or a positive integer.');
    end
end

if ~isempty(params.cir_max_path_m)
    if ~isscalar(params.cir_max_path_m) || ~isnumeric(params.cir_max_path_m) || ...
            params.cir_max_path_m <= 0
        error('mergeOptions:InvalidCirMaxPath', ...
            'cir_max_path_m must be empty or a positive distance in meters.');
    end
end

if ~isscalar(params.cir_store_individual_values)
    error('mergeOptions:InvalidCirStoreIndividualValues', ...
        'cir_store_individual_values must be a scalar logical value.');
end
if ~isscalar(params.cir_timing)
    error('mergeOptions:InvalidCirTiming', ...
        'cir_timing must be a scalar logical value.');
end

params.show_plots = logical(params.show_plots);
params.enable_frame_crop = logical(params.enable_frame_crop);
params.cir_store_individual_values = ...
    logical(params.cir_store_individual_values);
params.cir_timing = logical(params.cir_timing);
params.verbose = logical(params.verbose);

if ~isempty(params.max_psdu_bytes)
    if ~isscalar(params.max_psdu_bytes) || params.max_psdu_bytes < 0 || ...
            params.max_psdu_bytes > 127 || ...
            params.max_psdu_bytes ~= fix(params.max_psdu_bytes)
        error('mergeOptions:InvalidMaxPsduBytes', ...
            'max_psdu_bytes must be an integer in 0..127.');
    end
end

end
