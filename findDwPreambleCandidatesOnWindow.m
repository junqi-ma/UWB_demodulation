function search = findDwPreambleCandidatesOnWindow(rx, profile, qm35Start, opts)
%FINDDWPREAMBLECANDIDATESONWINDOW Dump-SIC search: skip head fragment, find overlap DW.
%   SEARCH = FINDDWPREAMBLECANDIDATESONWINDOW(RX, PROFILE, QM35START)
%   RX is the post-QM35-cancel work-rate window. PROFILE is one
%   refs.dw_profiles(k) (params / reference). QM35START is
%   window.seeded_start_one (one-based). OPTS may be omitted; defaults
%   are filled internally (tests call the 3-arg form).
%
%   Does not modify detectRepeatedPreamble. Head tails are never returned
%   as the overlap candidate.
%
%   See also SCHEDULEDDUMPSICPIPELINE, DETECTREPEATEDPREAMBLE.

if nargin < 4
    opts = struct();
end
opts = fillSearchOpts(opts);

params = profile.params;
ref = profile.reference;
fs = opts.fs;
periodNom = ref.samples_per_symbol;
headFragMax = opts.head_fragment_max_start;
search = emptySearchResult(qm35Start);
rx = rx(:);

try
    earliest = uwbdecoder.detectRepeatedPreamble(rx, ref, params, []);
catch
    search.search_path = "none";
    search.message = "earliest detect failed";
    return
end
period = finitePeriod(earliest.measured_period, periodNom);

if earliest.start_sample >= headFragMax
    search.head_is_fragment = false;
    search.head_start = NaN;
    try
        refined = refineSeeded(rx, ref, params, earliest.start_sample, opts);
        search = acceptOverlap(search, refined, rx, params, "earliest");
    catch
        search.search_path = "none";
        search.message = "earliest refine failed";
    end
    return
end

search.head_is_fragment = true;
search.head_start = double(earliest.start_sample);
search.head_reps = double(earliest.detected_repetitions);
search.head_period = period;

trueHeadEnd = search.head_start + ...
    min(params.preamble_repetitions, ...
        floor((numel(rx) - search.head_start + 1) / period)) * period;

qm35Ok = isfinite(qm35Start) && qm35Start >= 1 && qm35Start <= numel(rx);
if qm35Ok
    lo = max(1, round(double(qm35Start) - opts.qm35_search_pre_s * fs));
    hi = min(numel(rx), round(double(qm35Start) + opts.qm35_search_post_s * fs));
    try
        neigh = detectOnSuffix(rx, ref, params, lo);
        if isValidDetect(neigh, opts) && neigh.start_sample >= lo
            refined = refineSeeded(rx, ref, params, neigh.start_sample, opts);
            if refined.start_sample >= lo
                if refined.start_sample > hi
                    pathName = "late_after_qm35";
                else
                    pathName = "qm35_neighborhood";
                end
                search = acceptOverlap(search, refined, rx, params, pathName);
                return
            end
        end
    catch
        % Neighborhood miss: fall through to the suffix search.
    end
    suffixFrom = max([lo, headFragMax, round(trueHeadEnd)]);
else
    suffixFrom = max(headFragMax, round(trueHeadEnd));
end

suffixFrom = min(max(suffixFrom, headFragMax), numel(rx));
try
    suf = detectOnSuffix(rx, ref, params, suffixFrom);
    if isValidDetect(suf, opts) && suf.start_sample >= suffixFrom
        refined = refineSeeded(rx, ref, params, suf.start_sample, opts);
        search = acceptOverlap(search, refined, rx, params, "suffix_after_head");
        return
    end
catch
end

search.search_path = "none";
search.message = "head fragment skipped; no overlap candidate";
end

% -------------------------------------------------------------------------
function opts = fillSearchOpts(opts)
if nargin < 1 || isempty(opts)
    opts = struct();
end
defaults = struct( ...
    'fs', 998.4e6, ...
    'head_fragment_max_start', 2000, ...
    'qm35_search_pre_s', 80e-6, ...
    'qm35_search_post_s', 40e-6, ...
    'min_detect_reps', 32, ...
    'refine_max_abs_start_err_periods', 50);
names = fieldnames(defaults);
for k = 1:numel(names)
    if ~isfield(opts, names{k}) || isempty(opts.(names{k}))
        opts.(names{k}) = defaults.(names{k});
    end
end
end

function search = emptySearchResult(qm35Start)
search = struct( ...
    'head_start', NaN, ...
    'head_reps', 0, ...
    'head_is_fragment', false, ...
    'head_period', NaN, ...
    'overlap_start', NaN, ...
    'overlap_reps', 0, ...
    'overlap_detected_reps', 0, ...
    'overlap_period', NaN, ...
    'overlap_preamble', struct(), ...
    'search_path', "", ...
    'qm35_start', double(qm35Start), ...
    'message', "");
end

function preamble = detectOnSuffix(rx, ref, params, firstSample)
if firstSample <= 1
    preamble = uwbdecoder.detectRepeatedPreamble(rx, ref, params, []);
    return
end
if firstSample >= numel(rx) - ref.samples_per_symbol
    error('findDwPreambleCandidatesOnWindow:SuffixTooShort', ...
        'Search suffix starts at %d but window is %d.', firstSample, numel(rx));
end
preamble = uwbdecoder.detectRepeatedPreamble( ...
    rx(firstSample:end), ref, params, []);
preamble = shiftPreamble(preamble, firstSample - 1);
end

function preamble = shiftPreamble(preamble, offset)
preamble.start_sample = preamble.start_sample + offset;
if isfield(preamble, 'peaks') && ~isempty(preamble.peaks)
    preamble.peaks = preamble.peaks + offset;
end
if isfield(preamble, 'strongest_end')
    preamble.strongest_end = preamble.strongest_end + offset;
end
if isfield(preamble, 'roi_start')
    preamble.roi_start = preamble.roi_start + offset;
end
if isfield(preamble, 'roi_end')
    preamble.roi_end = preamble.roi_end + offset;
end
end

function ok = isValidDetect(preamble, opts)
ok = isstruct(preamble) && isfield(preamble, 'start_sample') ...
    && isfield(preamble, 'detected_repetitions') ...
    && preamble.detected_repetitions >= opts.min_detect_reps ...
    && isfinite(preamble.start_sample) ...
    && preamble.start_sample >= opts.head_fragment_max_start;
end

function preamble = refineSeeded(rx, ref, params, seed, opts)
preamble = uwbdecoder.detectRepeatedPreamble(rx, ref, params, seed);
period = finitePeriod(preamble.measured_period, ref.samples_per_symbol);
maxErr = opts.refine_max_abs_start_err_periods * period;
fellToHead = preamble.start_sample < opts.head_fragment_max_start;
tooFar = abs(double(preamble.start_sample) - double(seed)) > maxErr;
tooFew = preamble.detected_repetitions < opts.min_detect_reps;
if fellToHead || tooFar || tooFew
    error('findDwPreambleCandidatesOnWindow:RefineFellBack', ...
        ['Seeded refine at %d fell back to start=%d reps=%d ', ...
         '(head fallback or too few peaks).'], ...
        seed, preamble.start_sample, preamble.detected_repetitions);
end
end

function n = visibleReps(preamble, rx, params, periodNom)
period = finitePeriod(preamble.measured_period, periodNom);
n = min(params.preamble_repetitions, ...
    floor((numel(rx) - double(preamble.start_sample) + 1) / period));
n = max(0, n);
end

function search = acceptOverlap(search, refined, rx, params, pathName)
fallback = uwbdecoder.constants().HRP_CHIPS_PER_SYMBOL;
search.overlap_start = double(refined.start_sample);
search.overlap_reps = visibleReps(refined, rx, params, fallback);
search.overlap_detected_reps = double(refined.detected_repetitions);
search.overlap_period = finitePeriod(refined.measured_period, fallback);
search.overlap_preamble = refined;
search.search_path = string(pathName);
search.message = "";
if ~(isfinite(search.overlap_start) && search.overlap_start >= 2000)
    error('findDwPreambleCandidatesOnWindow:AcceptedHead', ...
        'Refusing to accept overlap start %g.', search.overlap_start);
end
end

function p = finitePeriod(measured, fallback)
if isfinite(measured) && measured > 0
    p = double(measured);
else
    p = double(fallback);
end
end
