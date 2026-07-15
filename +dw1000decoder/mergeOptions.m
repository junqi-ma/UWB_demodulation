function params = mergeOptions(params, options)
%MERGEOPTIONS Apply and validate user configuration overrides.
if ~isstruct(options) || ~isscalar(options)
    error('Options must be a scalar structure.');
end
names = fieldnames(options);
unknown = setdiff(names, fieldnames(params));
if ~isempty(unknown)
    error('Unknown decoder option: %s', strjoin(unknown, ', '));
end
for k = 1:length(names)
    params.(names{k}) = options.(names{k});
end
if params.channel_index < 1 || params.channel_index > params.ant_num
    error('channel_index must be between 1 and ant_num.');
end
if params.sample_offset < 0 || params.sample_num <= 0 || params.fs_rx <= 0
    error('Sample offset, count, and sample rate are invalid.');
end
valid_sfd_modes = {'decawave', 'ieee', '4z1', '4z2', '4z3', '4z4', 'auto'};
if ~(ischar(params.sfd_mode) || ...
        (isstring(params.sfd_mode) && isscalar(params.sfd_mode)))
    error('sfd_mode must select a supported SFD template or ''auto''.');
end
params.sfd_mode = lower(char(params.sfd_mode));
if ~ismember(params.sfd_mode, valid_sfd_modes)
    error(['sfd_mode must be ''decawave'', ''ieee'', ''4z1'', ', ...
        '''4z2'', ''4z3'', ''4z4'', or ''auto''.']);
end
if numel(params.decawave_sfd) ~= 8 || ...
        any(~ismember(params.decawave_sfd(:), [-1, 0, 1]))
    error('The Decawave DW-8 SFD must contain eight ternary symbols.');
end
if numel(params.ieee_sfd) ~= 8 || ...
        any(~ismember(params.ieee_sfd(:), [-1, 0, 1]))
    error('The IEEE short SFD must contain eight ternary symbols.');
end
sfd4z_lengths = [4, 8, 16, 32];
for sfd_number = 1:4
    field_name = sprintf('sfd4z_%d', sfd_number);
    sequence = params.(field_name);
    if numel(sequence) ~= sfd4z_lengths(sfd_number) || ...
            any(~ismember(sequence(:), [-1, 0, 1]))
        error('IEEE 802.15.4z SFD #%d must contain %d ternary symbols.', ...
            sfd_number, sfd4z_lengths(sfd_number));
    end
end
if ~isscalar(params.cir_repetitions) || ...
        params.cir_repetitions < 1 || ...
        params.cir_repetitions ~= fix(params.cir_repetitions)
    error('cir_repetitions must be a positive integer.');
end
if params.cir_repetitions > params.preamble_repetitions
    error('cir_repetitions cannot exceed preamble_repetitions.');
end
if ~isempty(params.cir_pre_samples)
    if ~isscalar(params.cir_pre_samples) || params.cir_pre_samples < 0 || ...
            params.cir_pre_samples ~= fix(params.cir_pre_samples)
        error('cir_pre_samples must be empty or a non-negative integer.');
    end
end
if ~isempty(params.cir_post_samples)
    if ~isscalar(params.cir_post_samples) || params.cir_post_samples < 1 || ...
            params.cir_post_samples ~= fix(params.cir_post_samples)
        error('cir_post_samples must be empty or a positive integer.');
    end
end
if ~isempty(params.cir_max_path_m)
    if ~isscalar(params.cir_max_path_m) || ~isnumeric(params.cir_max_path_m) || ...
            params.cir_max_path_m <= 0
        error('cir_max_path_m must be empty or a positive distance in meters.');
    end
end
params.show_plots = logical(params.show_plots);
params.enable_interference_cancellation = ...
    logical(params.enable_interference_cancellation);
params.enable_frame_crop = logical(params.enable_frame_crop);
params.verbose = logical(params.verbose);
if ~isempty(params.max_psdu_bytes)
    if ~isscalar(params.max_psdu_bytes) || params.max_psdu_bytes < 0 || ...
            params.max_psdu_bytes > 127 || ...
            params.max_psdu_bytes ~= fix(params.max_psdu_bytes)
        error('max_psdu_bytes must be an integer in 0..127.');
    end
end
if ~isempty(params.interference_coefficient)
    if ~isscalar(params.interference_coefficient) || ...
            ~isnumeric(params.interference_coefficient)
        error('interference_coefficient must be empty or a scalar complex value.');
    end
    params.interference_coefficient = complex(params.interference_coefficient);
end
end
