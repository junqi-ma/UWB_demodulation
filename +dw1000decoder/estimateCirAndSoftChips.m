function [cir, chips] = estimateCirAndSoftChips(rx, preamble, reference, params)
%ESTIMATECIRANDSOFTCHIPS Despread preamble codes, average CIR, and slice chips.
%   CIR: one local code-matched filter over the last N SYNC symbols.
%   Soft chips: short CIR template over a budgeted frame span only (not the
%   entire capture), sized for helperUWBBPRFDemod.

code = reference.sampled_code(:);
code_mf = flipud(conj(code));
code_length = numel(code);
rx = rx(:);

[pre_samples, post_samples] = resolveCirWindow(params, preamble, reference);
offsets = (-pre_samples:post_samples-1).';
delay_ns = offsets/reference.fs*1e9;

repetition_count = min(params.cir_repetitions, ...
    min(preamble.detected_repetitions, params.preamble_repetitions));
first_repetition = max(0, params.preamble_repetitions-repetition_count);
last_repetition = first_repetition+repetition_count-1;

% --- CIR: local code correlation over the SYNC average window only ---
first_nominal_end = preamble.start_sample+first_repetition* ...
    preamble.measured_period+code_length-1;
last_nominal_end = preamble.start_sample+last_repetition* ...
    preamble.measured_period+code_length-1;
filter_start = first_nominal_end+offsets(1);
filter_end = last_nominal_end+offsets(end);
[code_axis, code_filtered] = localMatchedFilterSegment(rx, code_mf, ...
    filter_start, filter_end);

proto = complex(cast(0, 'like', real(rx(1))));
individual = zeros(length(offsets), repetition_count, 'like', proto);
accumulator = zeros(length(offsets), 1, 'like', proto);
valid_count = 0;
for repetition = first_repetition:last_repetition
    repetition_start = preamble.start_sample+repetition*preamble.measured_period;
    nominal_end = repetition_start+code_length-1;
    positions = nominal_end+offsets;
    values = interp1(double(code_axis), double(code_filtered), ...
        double(positions), 'linear', NaN);
    values = cast(values, 'like', proto);
    if any(isnan(double(values)))
        continue;
    end
    valid_count = valid_count+1;
    accumulator = accumulator+values(:);
    individual(:, valid_count) = values(:)/reference.code_energy;
end
if valid_count == 0
    error('No complete preamble repetitions were available for CIR estimation.');
end
individual = individual(:, 1:valid_count);
values = accumulator/(valid_count*reference.code_energy+eps);
values = values/(norm(values)+eps);

% --- Soft chips: budgeted span, short CIR FIR ---
cir_mf = conj(flipud(values));
samples_per_chip = preamble.measured_period/reference.chips_per_symbol;
chip_start = preamble.start_sample+length(values)-pre_samples-1;
frame_span = dw1000decoder.estimateFrameSampleSpan(preamble, reference, params);

% End sample for the Nth soft chip (1-based): chip_start + (N-1)*spc.
last_by_budget = chip_start+(frame_span.n_chips-1)*samples_per_chip;
last_chip_sample = min(numel(rx), ceil(last_by_budget));
if chip_start >= last_chip_sample
    error('chip_start falls outside the work buffer; check timing/crop.');
end

chip_positions = chip_start:samples_per_chip:last_chip_sample;
min_preamble_chips = params.preamble_repetitions*reference.chips_per_symbol;
if numel(chip_positions) < min_preamble_chips
    error(['Soft-chip stream shorter than SYNC (%d chips, need >= %d). ', ...
        'Increase sample_num so the capture covers the full frame.'], ...
        numel(chip_positions), min_preamble_chips);
end

[chip_axis, chip_filtered] = localMatchedFilterSegment(rx, cir_mf, ...
    min(chip_positions), max(chip_positions));
complex_chips = interp1(double(chip_axis), double(chip_filtered), ...
    double(chip_positions), 'linear', NaN);
if any(isnan(complex_chips))
    error('Local CIR matched filter failed over the soft-chip region.');
end
complex_chips = cast(complex_chips(:), 'like', proto);

phase_repetitions = min(32, params.preamble_repetitions);
phase_first = (params.preamble_repetitions-phase_repetitions)* ...
    reference.chips_per_symbol+1;
phase_last = params.preamble_repetitions*reference.chips_per_symbol;
if phase_last > numel(complex_chips) || phase_first < 1
    error(['Soft-chip stream is shorter than the configured preamble; ', ...
        'increase sample_num so the capture covers the full frame.']);
end
phase_reference = repmat(reference.spread_code, phase_repetitions, 1);
phase_gain = phase_reference'*complex_chips(phase_first:phase_last);
complex_chips = complex_chips*exp(-1j*angle(phase_gain));
soft = real(complex_chips);
soft = soft/(max(abs(soft))+eps);

cir = struct('values', values, 'delay_ns', delay_ns, ...
    'individual_values', individual, 'repetition_count', valid_count, ...
    'pre_samples', pre_samples, 'post_samples', post_samples);
chips = struct('complex', complex_chips, 'soft', soft, ...
    'samples_per_chip', samples_per_chip, ...
    'chip_start_sample', chip_start, ...
    'chip_end_sample', last_chip_sample, ...
    'num_chips', numel(soft));
if isfield(params, 'verbose') && params.verbose
    fprintf(['Estimated %d-sample CIR (pre=%d, post=%d) from %d reps; ', ...
        'soft chips=%d (budget %d).\n'], ...
        length(values), pre_samples, post_samples, valid_count, ...
        numel(soft), frame_span.n_chips);
end
end

%% ------------------------------------------------------------------------
function [pre_samples, post_samples] = resolveCirWindow(params, preamble, reference)
if ~isempty(params.cir_pre_samples)
    pre_samples = params.cir_pre_samples;
else
    pre_samples = preamble.search_half_width;
end

if ~isempty(params.cir_post_samples)
    post_samples = params.cir_post_samples;
elseif ~isempty(params.cir_max_path_m)
    c = 299792458;
    post_samples = max(1, round(params.cir_max_path_m/c*reference.fs));
else
    post_samples = max(1, round(100e-9*reference.fs));
end

pre_samples = max(0, round(pre_samples));
post_samples = max(1, round(post_samples));
end

function [sample_axis, filtered] = localMatchedFilterSegment(rx, filter_taps, ...
        pos_min, pos_max)
%LOCALMATCHEDFILTERSEGMENT FIR match over [pos_min, pos_max] only.
filter_taps = filter_taps(:);
rx = rx(:);
tap_count = numel(filter_taps);
abs_start = floor(pos_min)-tap_count+1;
abs_end = ceil(pos_max);
pad_left = 0;
pad_right = 0;
if abs_start < 1
    pad_left = 1-abs_start;
    abs_start = 1;
end
if abs_end > numel(rx)
    pad_right = abs_end-numel(rx);
    abs_end = numel(rx);
end
if abs_end < abs_start
    sample_axis = zeros(0, 1);
    filtered = zeros(0, 1, 'like', complex(cast(0, 'like', real(filter_taps(1)))));
    return;
end

segment = rx(abs_start:abs_end);
if pad_left > 0 || pad_right > 0
    zero_pad = zeros(pad_left, 1, 'like', real(segment(1)));
    zero_pad_r = zeros(pad_right, 1, 'like', real(segment(1)));
    segment = [zero_pad; segment; zero_pad_r];
end
axis_start = abs_start-pad_left;
% Short FIR (CIR template ~ tens of taps): time-domain filter is faster
% than fftfilt on medium-length segments.
if tap_count <= 128
    filtered = filter(filter_taps, 1, segment);
else
    filtered = fftfilt(filter_taps, segment);
end
sample_axis = axis_start+(0:numel(filtered)-1).';
filtered = filtered(:);
end
