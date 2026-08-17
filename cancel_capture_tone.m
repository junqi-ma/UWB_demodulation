function report = cancel_capture_tone(dumpDir, opts)
%CANCEL_CAPTURE_TONE Notch a CW from a scheduled SC16 dump.
%   REPORT = CANCEL_CAPTURE_TONE(DUMPDIR) reads DUMPDIR/capture.iq +
%   capture.jsonl, subtracts one complex tone in each window, and writes
%   DUMPDIR/capture.iq in place (jsonl unchanged). The un-notched IQ is
%   not kept.
%
%   Windows are not time-contiguous, so the fit is per jsonl window.
%   Default RF hint is 6200 MHz with LO 6489.6 MHz (search ±80 MHz).
%   The mixed 737.28 dump peaks near RF 6256.640 MHz.
%
%   OPTS fields:
%     .fs          (737.28e6)
%     .center_hz   (6489.6e6)
%     .rf_hz       (6200e6)
%     .search_hz   (80e6)
%     .auto        (false)  strongest bin anywhere

if nargin < 1 || isempty(dumpDir)
    error('cancel_capture_tone:Usage', ...
        'usage: report = cancel_capture_tone(dumpDir [, opts])');
end
if nargin < 2 || isempty(opts)
    opts = struct();
end
if ~isfield(opts, 'fs')
    opts.fs = 737.28e6;
end
if ~isfield(opts, 'center_hz')
    opts.center_hz = 6489.6e6;
end
if ~isfield(opts, 'rf_hz')
    opts.rf_hz = 6200e6;
end
if ~isfield(opts, 'search_hz')
    opts.search_hz = 80e6;
end
if ~isfield(opts, 'auto')
    opts.auto = false;
end

iqFile = fullfile(dumpDir, 'capture.iq');
jsonlFile = fullfile(dumpDir, 'capture.jsonl');
outFile = fullfile(dumpDir, 'capture.iq.tmp');
assert(isfile(iqFile) && isfile(jsonlFile), ...
    'need capture.iq and capture.jsonl in %s', dumpDir);

metas = readDumpJsonl(jsonlFile);
probe = [];
for k = 1:numel(metas)
    if double(metas(k).sample_count) >= 10000
        probe = metas(k);
        if isScheduledMeta(metas(k))
            break
        end
    end
end
assert(~isempty(probe), 'no usable window');

x = readWindow(iqFile, probe);
if opts.auto
    fLo = [];
    fHi = [];
else
    fHint = opts.rf_hz - opts.center_hz;
    fLo = fHint - opts.search_hz;
    fHi = fHint + opts.search_hz;
end
f0 = fftPeakHz(x, opts.fs, fLo, fHi);
fHz = refineFreq(x, opts.fs, f0, max(200, opts.fs / numel(x) * 8));

fprintf('dump: %s\n', dumpDir);
fprintf('tone baseband=%.3f Hz  RF=%.6f MHz\n', ...
    fHz, (opts.center_hz + fHz) / 1e6);

outFid = fopen(outFile, 'wb', 'ieee-le');
assert(outFid >= 0, 'cannot write %s', outFile);
cleanup = onCleanup(@() fclose(outFid));
% Pre-size by copying then patching windows keeps unused bytes identical.
inFid = fopen(iqFile, 'rb', 'ieee-le');
assert(inFid >= 0);
chunk = fread(inFid, inf, 'int16=>int16');
fclose(inFid);
fwrite(outFid, chunk, 'int16');

sup = zeros(numel(metas), 1);
binDb = zeros(numel(metas), 1);
for k = 1:numel(metas)
    m = metas(k);
    xw = readWindow(iqFile, m);
    [yw, ~, p0, p1, b0, b1] = fitSubtract(xw, opts.fs, fHz);
    sup(k) = 10 * log10(p0 / max(p1, eps));
    binDb(k) = 20 * log10((b0 + 1e-18) / (b1 + 1e-18));
    off = double(m.file_offset_samples);
    n = double(m.sample_count);
    raw = zeros(2 * n, 1, 'int16');
    raw(1:2:end) = int16(max(min(round(real(yw)), 32767), -32768));
    raw(2:2:end) = int16(max(min(round(imag(yw)), 32767), -32768));
    fseek(outFid, off * 4, 'bof');
    fwrite(outFid, raw, 'int16');
end

fprintf('windows=%d  power_suppression_db mean=%.2f  tone_bin_db mean=%.1f\n', ...
    numel(metas), mean(sup), mean(binDb));
clear cleanup;
movefile(outFile, iqFile, 'f');
leftovers = {'capture_notch.iq', 'capture_raw.iq'};
for i = 1:numel(leftovers)
    p = fullfile(dumpDir, leftovers{i});
    if isfile(p)
        delete(p);
    end
end
fprintf('wrote %s (notched, un-notched IQ discarded)\n', iqFile);

report = struct( ...
    'tone_baseband_hz', fHz, ...
    'tone_rf_hz', opts.center_hz + fHz, ...
    'n_windows', numel(metas), ...
    'power_suppression_db_mean', mean(sup), ...
    'tone_bin_suppression_db_mean', mean(binDb), ...
    'output', string(iqFile));
end

function metas = readDumpJsonl(jsonlFile)
fid = fopen(jsonlFile, 'r');
assert(fid >= 0);
cleanup = onCleanup(@() fclose(fid));
raw = {};
while true
    line = fgetl(fid);
    if ~ischar(line)
        break
    end
    line = strtrim(line);
    if isempty(line)
        continue
    end
    raw{end + 1} = jsondecode(line); %#ok<AGROW>
end
keys = {};
for k = 1:numel(raw)
    keys = union(keys, fieldnames(raw{k}), 'stable');
end
template = cell2struct(repmat({[]}, numel(keys), 1), keys, 1);
metas = repmat(template, numel(raw), 1);
for k = 1:numel(raw)
    f = fieldnames(raw{k});
    for i = 1:numel(f)
        metas(k).(f{i}) = raw{k}.(f{i});
    end
end
end

function tf = isScheduledMeta(meta)
mode = '';
if isfield(meta, 'capture_mode') && ~isempty(meta.capture_mode)
    mode = char(meta.capture_mode);
end
tf = any(strcmp(mode, {'scheduled', 'provisional'}));
end

function x = readWindow(iqFile, meta)
fid = fopen(iqFile, 'rb', 'ieee-le');
assert(fid >= 0);
cleanup = onCleanup(@() fclose(fid));
n = double(meta.sample_count);
off = double(meta.file_offset_samples);
fseek(fid, off * 4, 'bof');
raw = fread(fid, 2 * n, 'int16=>double');
assert(numel(raw) == 2 * n);
x = complex(raw(1:2:end), raw(2:2:end));
end

function [f0, mag0] = fftPeakHz(x, fs, fLo, fHi)
n = numel(x);
nfft = 2 ^ nextpow2(max(n, 4096));
ww = 0.5 - 0.5 * cos(2 * pi * (0:n-1).' / max(n-1, 1));
spec = fftshift(fft(x(:) .* ww, nfft));
freq = (-nfft/2:nfft/2-1).' * (fs / nfft);
mag = abs(spec);
if ~isempty(fLo) || ~isempty(fHi)
    lo = -fs/2;
    hi = fs/2;
    if ~isempty(fLo), lo = fLo; end
    if ~isempty(fHi), hi = fHi; end
    mag(freq < lo | freq > hi) = 0;
end
[mag0, i] = max(mag);
f0 = freq(i);
if i > 1 && i < nfft
    a = mag(i-1); b = mag(i); c = mag(i+1);
    den = a - 2*b + c;
    if den ~= 0
        f0 = f0 + 0.5*(a-c)/den * (freq(2)-freq(1));
    end
end
end

function bestF = refineFreq(x, fs, f0, span)
n = (0:numel(x)-1).';
bestF = f0;
best = 0;
for step = 1:5
    cands = linspace(bestF - span, bestF + span, 21);
    for f = cands
        s = exp(-2j * pi * f * n / fs);
        m = abs(x(:).' * s);
        if m > best
            best = m;
            bestF = f;
        end
    end
    span = span * 0.25;
end
end

function [y, coef, p0, p1, b0, b1] = fitSubtract(x, fs, fHz)
n = (0:numel(x)-1).';
s = exp(2j * pi * fHz * n / fs);
coef = (x(:).' * conj(s)) / numel(x);
y = x(:) - coef * s;
p0 = mean(abs(x(:)).^2);
p1 = mean(abs(y).^2);
b0 = abs(coef);
b1 = abs((y.' * conj(s)) / numel(x));
end
