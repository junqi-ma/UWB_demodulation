function compensation = load_uwb_pll_phase_compensation( ...
        enabled, templateFile, applyRepetitions, preambleRepetitions)
%LOAD_UWB_PLL_PHASE_COMPENSATION Load a learned UWB PLL phase template.
%   Fine sub-SYNC templates produced by ANALYZE_UWB_PLL_PHASE_DRIFT are
%   preferred. Legacy repetition-level templates remain supported.

compensation = struct( ...
    'enabled', logical(enabled), ...
    'template_file', char(templateFile), ...
    'resolution', "disabled", ...
    'bins_per_repetition', 0, ...
    'apply_repetitions', 0, ...
    'phase_by_repetition_rad', zeros(preambleRepetitions, 1), ...
    'phase_by_bin_rad', zeros(preambleRepetitions, 0), ...
    'first_phase_deg', 0, ...
    'peak_abs_phase_deg', 0);
if ~compensation.enabled
    return
end
if ~isfile(templateFile)
    warning('load_uwb_pll_phase_compensation:TemplateNotFound', ...
        'PLL phase template not found; compensation disabled: %s', ...
        templateFile);
    compensation.enabled = false;
    compensation.resolution = "missing_template";
    return
end
validateattributes(applyRepetitions, {'numeric'}, ...
    {'scalar', 'integer', 'positive'});

template = readtable(templateFile);
names = template.Properties.VariableNames;
isSubsync = all(ismember({'repetition', 'bin_in_repetition', ...
    'applied_template_phase_deg'}, names));
if isSubsync
    repetitions = double(template.repetition);
    bins = double(template.bin_in_repetition);
    phaseDeg = double(template.applied_template_phase_deg);
    valid = isfinite(repetitions) & isfinite(bins) & isfinite(phaseDeg) & ...
        repetitions >= 1 & repetitions <= preambleRepetitions & ...
        repetitions == round(repetitions) & bins >= 1 & bins == round(bins);
    repetitions = repetitions(valid);
    bins = bins(valid);
    phaseDeg = phaseDeg(valid);
    if isempty(repetitions)
        error('load_uwb_pll_phase_compensation:InvalidTemplate', ...
            'The sub-SYNC PLL template contains no valid rows.');
    end
    binsPerRepetition = max(bins);
    applyCount = min([applyRepetitions, preambleRepetitions, ...
        max(repetitions)]);
    phaseByBinDeg = nan(applyCount, binsPerRepetition);
    for row = 1:numel(phaseDeg)
        repetition = repetitions(row);
        bin = bins(row);
        if repetition <= applyCount && bin <= binsPerRepetition
            if isfinite(phaseByBinDeg(repetition, bin))
                error('load_uwb_pll_phase_compensation:DuplicateBin', ...
                    'The sub-SYNC PLL template contains duplicate bins.');
            end
            phaseByBinDeg(repetition, bin) = phaseDeg(row);
        end
    end
    if any(~isfinite(phaseByBinDeg), 'all')
        error('load_uwb_pll_phase_compensation:IncompleteTemplate', ...
            'PLL template must contain bins 1..%d for repetitions 1..%d.', ...
            binsPerRepetition, applyCount);
    end
    compensation.resolution = "subsync";
    compensation.bins_per_repetition = binsPerRepetition;
    compensation.phase_by_bin_rad = zeros( ...
        preambleRepetitions, binsPerRepetition);
    compensation.phase_by_bin_rad(1:applyCount, :) = phaseByBinDeg*pi/180;
    compensation.phase_by_repetition_rad(1:applyCount) = ...
        angle(mean(exp(1j*phaseByBinDeg*pi/180), 2));
    compensation.apply_repetitions = applyCount;
    compensation.first_phase_deg = phaseByBinDeg(1, 1);
    compensation.peak_abs_phase_deg = max(abs(phaseByBinDeg), [], 'all');
    return
end

required = {'repetition', 'template_phase_deg'};
missing = setdiff(required, names);
if ~isempty(missing)
    error('load_uwb_pll_phase_compensation:InvalidTemplate', ...
        'Missing PLL template columns: %s', strjoin(missing, ', '));
end
repetitions = double(template.repetition);
phaseDeg = double(template.template_phase_deg);
valid = isfinite(repetitions) & isfinite(phaseDeg) & repetitions >= 1 & ...
    repetitions <= preambleRepetitions & repetitions == round(repetitions);
repetitions = repetitions(valid);
phaseDeg = phaseDeg(valid);
if isempty(repetitions) || numel(unique(repetitions)) ~= numel(repetitions)
    error('load_uwb_pll_phase_compensation:InvalidTemplate', ...
        'Legacy PLL template repetitions are empty or duplicated.');
end
applyCount = min([applyRepetitions, preambleRepetitions, max(repetitions)]);
requiredRepetitions = (1:applyCount).';
[present, rows] = ismember(requiredRepetitions, repetitions);
if ~all(present)
    error('load_uwb_pll_phase_compensation:IncompleteTemplate', ...
        'PLL template must contain repetitions 1 through %d.', applyCount);
end
compensation.resolution = "repetition";
compensation.bins_per_repetition = 1;
compensation.phase_by_repetition_rad(requiredRepetitions) = ...
    phaseDeg(rows)*pi/180;
compensation.phase_by_bin_rad = compensation.phase_by_repetition_rad;
compensation.apply_repetitions = applyCount;
compensation.first_phase_deg = phaseDeg(rows(1));
compensation.peak_abs_phase_deg = max(abs(phaseDeg(rows)));
end
