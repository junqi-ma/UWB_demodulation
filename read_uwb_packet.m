function [x, meta] = read_uwb_packet(iqFile, jsonlFile, packetId)
%READ_UWB_PACKET Read one UWB packet from a GNU Radio capture.
%   [X, META] = READ_UWB_PACKET('capture.iq', 'capture.jsonl', ID) reads the
%   packet whose packet_id == ID.
%
%   Storage (current gr-uwb Packet Writer):
%     - capture.iq      concatenated SC16 payloads (interleaved int16 I/Q,
%                       little-endian).  Reconstruct:
%                         float = double(int16) / meta.iq_scale
%     - capture.jsonl   one JSON object per packet with at least:
%                       packet_id, sample_count, file_offset_samples,
%                       sample_format ("sc16"), iq_scale
%                       Scheduled dumps also carry window_start_sample,
%                       predicted_start_sample, pre_guard_samples,
%                       capture_samples, post_guard_samples.
%
%   Legacy CF32 files (no sample_format or sample_format=="cf32") are still
%   readable for older captures.
%
%   If ID is omitted (or empty), return all packets' metadata (X = []).
%
%   Example:
%     [x, meta] = read_uwb_packet('capture.iq', 'capture.jsonl', 0);

if nargin < 2
    error('read_uwb_packet:Usage', ...
        'usage: [x, meta] = read_uwb_packet(iq, jsonl [, id])');
end

metaAll = readAllJsonl(jsonlFile);

if nargin < 3 || isempty(packetId)
    x = [];
    meta = metaAll;
    return;
end

idx = find([metaAll.packet_id] == packetId, 1);
if isempty(idx)
    error('read_uwb_packet:NoPacket', ...
        'packet %d not found in %s', packetId, jsonlFile);
end
meta = metaAll(idx);

if isfield(meta, 'file') && ~isempty(meta.file)
    f = fullfile(fileparts(iqFile), meta.file);
    offset = 0;
else
    f = iqFile;
    offset = meta.file_offset_samples;
end

fmt = 'sc16';
if isfield(meta, 'sample_format') && ~isempty(meta.sample_format)
    fmt = lower(char(meta.sample_format));
end

fid = fopen(f, 'rb', 'ieee-le');
if fid < 0
    error('read_uwb_packet:OpenFailed', 'cannot open %s', f);
end

if strcmp(fmt, 'sc16')
    fseek(fid, offset * 4, 'bof');   % 2 x int16 per complex sample
    raw = fread(fid, meta.sample_count * 2, 'int16');
    fclose(fid);
    if numel(raw) < 2 * meta.sample_count
        error('read_uwb_packet:ShortRead', '%s shorter than expected', f);
    end
    scale = 1.0;
    if isfield(meta, 'iq_scale') && meta.iq_scale ~= 0
        scale = double(meta.iq_scale);
    end
    x = (double(raw(1:2:end)) + 1i * double(raw(2:2:end))) / scale;
else
    % Legacy CF32
    fseek(fid, offset * 8, 'bof');
    raw = fread(fid, meta.sample_count * 2, 'float32');
    fclose(fid);
    if numel(raw) < 2 * meta.sample_count
        error('read_uwb_packet:ShortRead', '%s shorter than expected', f);
    end
    x = raw(1:2:end) + 1i * raw(2:2:end);
end
x = x(:);
end

function meta = readAllJsonl(jsonlFile)
fid = fopen(jsonlFile, 'r');
if fid < 0
    error('read_uwb_packet:OpenFailed', 'cannot open %s', jsonlFile);
end
raw = {};
while ~feof(fid)
    line = fgetl(fid);
    if ischar(line) && ~isempty(strtrim(line))
        raw{end + 1} = jsondecode(line); %#ok<AGROW>
    end
end
fclose(fid);

if isempty(raw)
    meta = struct([]);
    return;
end

% Acquisition and scheduled rows do not have identical fields. Build
% their union before forming a struct array so heterogeneous JSONL rows
% remain indexable by packet_id.
keys = {};
for k = 1:numel(raw)
    keys = union(keys, fieldnames(raw{k}), 'stable');
end
template = cell2struct(repmat({[]}, numel(keys), 1), keys, 1);
meta = repmat(template, numel(raw), 1);
for k = 1:numel(raw)
    fields = fieldnames(raw{k});
    for i = 1:numel(fields)
        meta(k).(fields{i}) = raw{k}.(fields{i});
    end
end
end
