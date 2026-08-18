function search = findDwPreambleCandidatesOnWindow(rx, profile, qm35Start, opts)
%FINDDWPREAMBLECANDIDATESONWINDOW Dump-SIC search: skip head fragment, find overlap DW.
%   SEARCH = FINDDWPREAMBLECANDIDATESONWINDOW(RX, PROFILE, QM35START, OPTS)
%   RX is the post-QM35-cancel work-rate window. PROFILE is one
%   refs.dw_profiles(k) (params / reference). QM35START is
%   window.seeded_start_one (one-based).
%
%   Searches in this order:
%     1. Unseeded earliest detection. If the absolute start is at or beyond
%        HEAD_FRAGMENT_MAX_START it is a genuine packet (not a head tail).
%     2. Otherwise the head lock is a leftover tail of a previous packet that
%        began before the window. Skip it and search the QM35 neighborhood
%        (x(lo:end), never clipped to x(lo:hi)); if that misses, search the
%        suffix after the head tail.
%   A seeded refine must not fall back to the window-head tail; such a refine
%   is discarded. Does not modify detectRepeatedPreamble. Head tails are never
%   returned as the overlap candidate.
%
%   See also SCHEDULEDDUMPPIPELINE, DETECTREPEATEDPREAMBLE.

opts = fillSearchOptions(opts);

params = profile.params;
ref = profile.reference;
fs = opts.fs;
periodNom = ref.samples_per_symbol;
headFragMax = opts.head_fragment_max_start;

search = emptySearch(qm35Start);

try
    earliest = uwbdecoder.detectRepeatedPreamble(rx, ref, params, []);
catch
    search.search_path = "none";
    search.message = 'no preamble detected on window';
    return
end
period = finitePeriod(earliest.measured_period, periodNom);

if earliest.start_sample >= headFragMax
    search.head_is_fragment = false;
    search.head_start = NaN;
    search.search_path = "earliest";
    if isfinite(double(earliest.start_sample))
        search = acceptOverlap(search, ...
            refineSeeded(rx, ref, params, earliest.start_sample, opts), ...
            "earliest", rx, params);
    end
    return
end

search.head_is_fragment = true;
search.head_start = double(earliest.start_sample);
search.head_reps = double(earliest.detected_repetitions);
search.head_period = period;

% QM35 neighborhood first. Search x(lo:end) so a late overlap packet keeps
% enough SYNC repetitions to cross the detector's 32-peak commit gate; HI
% only decides whether the returned absolute start counts as "in the
% neighborhood" after the fact.
if isfinite(double(qm35Start))
    lo = max(1, round(double(qm35Start) - opts.qm35_search_pre_s * fs));
    hi = min(numel(rx), round(double(qm35Start) + opts.qm35_search_post_s * fs));
    try
        neigh = detectOnSuffix(rx, ref, params, lo, fs);
        if isValidDetect(neigh, opts) && (neigh.start_sample <= hi)
            refined = refineSeeded(rx, ref, params, neigh.start_sample, opts);
            if isValidRefine(refined, neigh.start_sample, opts)
                search = acceptOverlap(search, refined, ...
                    "qm35_neighborhood", rx, params);
                return
            end
        end
    catch
        % treat any neighborhood-search miss as "not found here"
    end
end

try
    tailEnd = earliest.start_sample + earliest.detected_repetitions * period;
    from = max(headFragMax, round(tailEnd));
    from = min(from, numel(rx));
    suf = detectOnSuffix(rx, ref, params, from, fs);
    if isValidDetect(suf, opts)
        refined = refineSeeded(rx, ref, params, suf.start_sample, opts);
        if isValidRefine(refined, suf.start_sample, opts)
            search = acceptOverlap(search, refined, ...
                "suffix_after_head", rx, params);
            return
        end
    end
catch
    % treat any suffix miss as "not found here"
end

search.search_path = "none";
search.message = 'head fragment skipped; no overlap candidate';
end

% -------------------------------------------------------------------------
function opts = fillSearchOptions(opts)
defaults = struct( ...
    'fs', 998.4e6, ...
    'head_fragment_max_start', 2000, ...
    'qm35_search_pre_s', 80e-6, ...
    'qm35_search_post_s', 40e-6, ...
    'min_detect_reps', 32, ...
    'refine_max_abs_start_err_periods', 2);
if nargin < 1 || ~isstruct(opts) || isempty(opts)
    opts = struct();
end
names = fieldnames(defaults);
for k = 1:numel(names)
    if ~isfield(opts, names{k}) || isempty(opts.(names{k}))
        opts.(names{k}) = defaults.(names{k});
    end
end
end

function search = emptySearch(qm35Start)
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

function search = acceptOverlap(search, preamble, path, rx, params)
search.overlap_preamble = preamble;
search.overlap_start = double(preamble.start_sample);
search.overlap_detected_reps = double(preamble.detected_repetitions);
search.overlap_period = finitePeriod(preamble.measured_period, 1016);
search.overlap_reps = visibleReps(preamble, rx, params);
search.search_path = path;
search.message = char(string(path));
end

function preamble = detectOnSuffix(rx, ref, params, firstSample, fs)
if firstSample <= 1
    preamble = uwbdecoder.detectRepeatedPreamble(rx, ref, params, []);
    return
end
if firstSample >= numel(rx) - ref.samples_per_symbol
    error('findDwPreambleCandidatesOnWindow:SuffixTooShort', ...
        'Search suffix starts at %d but window is %d.', ...
        firstSample, numel(rx));
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

function preamble = refineSeeded(rx, ref, params, seed, opts)
preamble = uwbdecoder.detectRepeatedPreamble(rx, ref, params, seed);
period = finitePeriod(preamble.measured_period, ref.samples_per_symbol);
maxErr = opts.refine_max_abs_start_err_periods * period;
if preamble.detected_repetitions < opts.min_detect_reps || ...
        abs(double(preamble.start_sample) - double(seed)) > maxErr
    error('findDwPreambleCandidatesOnWindow:RefineFellBack', ...
        ['Seeded refine at %d fell back to start=%d reps=%d ', ...
         '(likely earliest-head fallback).'], ...
        seed, preamble.start_sample, preamble.detected_repetitions);
end
end

function ok = isValidDetect(preamble, opts)
ok = preamble.detected_repetitions >= opts.min_detect_reps;
end

function ok = isValidRefine(preamble, seed, opts)
period = finitePeriod(preamble.measured_period, 1016);
ok = preamble.detected_repetitions >= opts.min_detect_reps && ...
    abs(double(preamble.start_sample) - double(seed)) <= ...
    opts.refine_max_abs_start_err_periods * period;
end

function n = visibleReps(preamble, rx, params)
period = finitePeriod(preamble.measured_period, 1016);
n = min(params.preamble_repetitions, ...
    floor((numel(rx) - double(preamble.start_sample) + 1) / period));
n = max(0, n);
end

function p = finitePeriod(p, default)
if isempty(p) || ~isfinite(p)
    p = default;
end
end