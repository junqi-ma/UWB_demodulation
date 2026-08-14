%% Generate a deterministic HRP UWB test sample for GNU Radio.
%
% The generated capture contains:
%   - 5 ms of complex zero samples at the beginning;
%   - an IEEE 802.15.4a HRP waveform with Code Index 9, 64 SYNC symbols,
%     the standard legacy SFD, and a requested 128-byte payload;
%   - GNU Radio complex-float32 and X410-style interleaved int16 files;
%   - a Markdown description of the generated signal.
%
% MATLAB's 802.15.4a HRP PHR encodes at most 127 PSDU bytes. To preserve
% the requested 128-byte test payload, this script generates a standard
% 127-byte frame and appends the final byte as a pulse-level extension. The
% preamble, SFD, PHR, and first 127 payload bytes are standard-compliant; the
% one-byte extension is intentionally marked as non-standard in the output
% description.

clear;
close all;
clc;

project_dir = fileparts(mfilename('fullpath'));
cd(project_dir);
addpath(project_dir);

%% User-editable parameters
fs = 998.4e6;
mean_prf_mhz = 62.4;
data_rate_mbps = 6.81;
code_index = 9;
preamble_symbols = 64;
samples_per_pulse = 2;
requested_payload_bytes = 128;
blank_prefix_s = 5e-3;
payload_rng_seed = 20260807;
peak_amplitude = 0.8;

output_dir = fullfile(project_dir, 'generated_uwb_test');
cf32_name = 'uwb_code9_preamble64_payload128_standard_sfd.cfile';
int16_name = 'uwb_code9_preamble64_payload128_standard_sfd_int16.dat';
metadata_name = 'uwb_code9_preamble64_payload128_standard_sfd_metadata.mat';
description_name = 'UWB_test_signal_description.md';

if abs(fs - 998.4e6) > 1
    error('generate_uwb_gnuradio_sample:SampleRate', ...
        'This test generator is fixed to the 998.4 MHz HRP work grid.');
end
if requested_payload_bytes ~= 128
    error('generate_uwb_gnuradio_sample:PayloadLength', ...
        'This requested test sample is defined for a 128-byte payload.');
end
if blank_prefix_s < 0 || peak_amplitude <= 0
    error('generate_uwb_gnuradio_sample:InvalidParameter', ...
        'blank_prefix_s must be nonnegative and peak_amplitude positive.');
end

if ~exist(output_dir, 'dir')
    mkdir(output_dir);
end

%% Deterministic payload and standard HRP packet
% 802.15.4a/HRP limits PSDULength to 127 bytes. Generate the first 127
% bytes with the standard MATLAB generator, then obtain one additional byte's
% payload pulse symbols from a one-byte reference packet.
standard_psdu_bytes = 127;
extension_bytes = requested_payload_bytes - standard_psdu_bytes;

% Make the standard 127-byte PSDU internally valid: 125 data bytes followed
% by the two-byte IEEE 802.15.4 FCS. The final requested byte remains the
% explicit one-byte pulse-level extension.
rng(payload_rng_seed, 'twister');
standard_data_bytes = uint8(randi([0, 255], standard_psdu_bytes - 2, 1));
fcs_value = ieee802154Crc16(standard_data_bytes);
fcs_bytes = uint8([bitand(fcs_value, uint16(255)); bitshift(fcs_value, -8)]);
extension_payload_bytes = uint8(randi([0, 255], extension_bytes, 1));
payload_bytes = [standard_data_bytes; fcs_bytes; extension_payload_bytes];
payload_bits = bytesToLsbBits(payload_bytes);

cfg = lrwpanHRPConfig(Mode='802.15.4a', MeanPRF=mean_prf_mhz, ...
    DataRate=data_rate_mbps, PreambleDuration=preamble_symbols, ...
    CodeIndex=code_index, SamplesPerPulse=samples_per_pulse, ...
    PSDULength=standard_psdu_bytes);

if abs(cfg.SampleRate - fs) > 1
    error('generate_uwb_gnuradio_sample:ConfigSampleRate', ...
        'MATLAB generated %.3f MHz instead of %.3f MHz.', ...
        cfg.SampleRate/1e6, fs/1e6);
end

[standard_packet_unused, standard_pulse_symbols] = ...
    lrwpanWaveformGenerator(payload_bits(1:standard_psdu_bytes*8), cfg);
field_indices = lrwpanHRPFieldIndices(cfg);

cfg_extension = lrwpanHRPConfig(Mode='802.15.4a', MeanPRF=mean_prf_mhz, ...
    DataRate=data_rate_mbps, PreambleDuration=preamble_symbols, ...
    CodeIndex=code_index, SamplesPerPulse=samples_per_pulse, PSDULength=1);
[~, extension_packet_symbols] = ...
    lrwpanWaveformGenerator(payload_bits(standard_psdu_bytes*8+1:end), ...
    cfg_extension);
extension_field_indices = lrwpanHRPFieldIndices(cfg_extension);

if extension_bytes ~= 1
    error('generate_uwb_gnuradio_sample:InternalPayload', ...
        'The 128-byte extension path must contain exactly one byte.');
end

% The field-index API reports waveform samples. Convert the one-byte
% payload start to the pulse-symbol grid used by the second generator output.
extension_payload_start = ...
    (extension_field_indices.Payload(1) - 1) / samples_per_pulse + 1;
if extension_payload_start ~= round(extension_payload_start)
    error('generate_uwb_gnuradio_sample:PulseGrid', ...
        'The extension payload is not aligned to the pulse grid.');
end
extension_payload_start = round(extension_payload_start);
extension_pulse_symbols = ...
    extension_packet_symbols(extension_payload_start:end);

% Rebuild the standard packet and the one-byte extension through one
% continuous pulse-shaping filter. This avoids a filter-state reset at the
% non-standard extension boundary.
pulse_symbols = [standard_pulse_symbols(:); extension_pulse_symbols(:)];
pulse_impulses = zeros(numel(pulse_symbols)*samples_per_pulse, 1);
pulse_impulses(1:samples_per_pulse:end) = pulse_symbols;
[shape_b, shape_a] = butter(4, 1/samples_per_pulse);
packet = filter(shape_b, shape_a, pulse_impulses);
packet = complex(packet(:), zeros(numel(packet), 1));

standard_packet_samples = numel(standard_packet_unused);
extension_samples = numel(packet) - standard_packet_samples;
if extension_samples <= 0
    error('generate_uwb_gnuradio_sample:EmptyExtension', ...
        'The one-byte payload extension produced no samples.');
end

packet_peak = max(abs(packet));
if packet_peak <= 0 || ~isfinite(packet_peak)
    error('generate_uwb_gnuradio_sample:EmptyWaveform', ...
        'The generated packet has no finite nonzero samples.');
end
packet = packet * (peak_amplitude / packet_peak);

blank_prefix_samples = round(blank_prefix_s * fs);
blank_prefix_s_actual = blank_prefix_samples / fs;
iq = complex(zeros(blank_prefix_samples + numel(packet), 1, 'single'));
iq(blank_prefix_samples+1:end) = single(packet);

%% Write GNU Radio and int16 files
cf32_path = fullfile(output_dir, cf32_name);
int16_path = fullfile(output_dir, int16_name);
metadata_path = fullfile(output_dir, metadata_name);
description_path = fullfile(output_dir, description_name);

writeComplexFloat32(cf32_path, iq);
writeInterleavedInt16(int16_path, iq);

metadata = struct();
metadata.sample_rate_hz = fs;
metadata.mean_prf_mhz = mean_prf_mhz;
metadata.data_rate_mbps = data_rate_mbps;
metadata.code_index = code_index;
metadata.preamble_symbols = preamble_symbols;
metadata.samples_per_pulse = samples_per_pulse;
metadata.sfd = 'IEEE 802.15.4a standard legacy SFD';
metadata.requested_payload_bytes = requested_payload_bytes;
metadata.standard_psdu_bytes = standard_psdu_bytes;
metadata.extension_bytes = extension_bytes;
metadata.payload_bytes = payload_bytes;
metadata.standard_data_bytes = standard_data_bytes;
metadata.fcs_bytes = fcs_bytes;
metadata.fcs_value = fcs_value;
metadata.extension_payload_bytes = extension_payload_bytes;
metadata.payload_rng_seed = payload_rng_seed;
metadata.peak_amplitude = peak_amplitude;
metadata.blank_prefix_seconds = blank_prefix_s_actual;
metadata.blank_prefix_samples = blank_prefix_samples;
metadata.packet_samples = numel(packet);
metadata.total_samples = numel(iq);
metadata.total_duration_seconds = numel(iq) / fs;
metadata.packet_start_sample_one_based = blank_prefix_samples + 1;
metadata.standard_field_indices = field_indices;
metadata.extension_field_indices = extension_field_indices;
metadata.output_complex_float32 = cf32_name;
metadata.output_interleaved_int16 = int16_name;
save(metadata_path, '-struct', 'metadata');

writeDescription(description_path, metadata, cf32_name, int16_name, ...
    metadata_name);

fprintf('\nGenerated UWB GNU Radio test sample\n');
fprintf('Output directory       : %s\n', output_dir);
fprintf('Sample rate            : %.3f MHz\n', fs/1e6);
fprintf('Blank prefix           : %d samples (%.6f ms)\n', ...
    blank_prefix_samples, blank_prefix_s_actual*1e3);
fprintf('Packet samples         : %d\n', numel(packet));
fprintf('Total samples          : %d\n', numel(iq));
fprintf('Complex float32 file   : %s\n', cf32_path);
fprintf('Interleaved int16 file : %s\n', int16_path);
fprintf('Description            : %s\n\n', description_path);

%% Local functions
function bits = bytesToLsbBits(bytes)
bytes = uint8(bytes(:));
bits = zeros(numel(bytes)*8, 1);
for byte_index = 1:numel(bytes)
    bit_range = (byte_index-1)*8 + (1:8);
    bits(bit_range) = bitget(bytes(byte_index), 1:8);
end
bits = double(bits);
end

function crc = ieee802154Crc16(bytes)
bytes = uint8(bytes(:));
crc = uint16(0);
polynomial = uint16(hex2dec('8408'));
for byte_index = 1:numel(bytes)
    crc = bitxor(crc, uint16(bytes(byte_index)));
    for bit_index = 1:8
        if bitand(crc, uint16(1))
            crc = bitxor(bitshift(crc, -1), polynomial);
        else
            crc = bitshift(crc, -1);
        end
    end
end
end

function writeComplexFloat32(filename, signal)
fid = fopen(filename, 'w', 'ieee-le');
if fid < 0
    error('generate_uwb_gnuradio_sample:OpenOutput', ...
        'Cannot open %s for writing.', filename);
end
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>

chunk_samples = 2^20;
for first = 1:chunk_samples:numel(signal)
    last = min(first + chunk_samples - 1, numel(signal));
    x = signal(first:last);
    interleaved = zeros(2*numel(x), 1, 'single');
    interleaved(1:2:end) = real(x);
    interleaved(2:2:end) = imag(x);
    written = fwrite(fid, interleaved, 'single');
    if written ~= numel(interleaved)
        error('generate_uwb_gnuradio_sample:WriteOutput', ...
            'Short write while writing %s.', filename);
    end
end
end

function writeInterleavedInt16(filename, signal)
fid = fopen(filename, 'w', 'ieee-le');
if fid < 0
    error('generate_uwb_gnuradio_sample:OpenOutput', ...
        'Cannot open %s for writing.', filename);
end
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>

signal_peak = max(abs(signal));
scale = 32767 / max(double(signal_peak), eps);
chunk_samples = 2^20;
for first = 1:chunk_samples:numel(signal)
    last = min(first + chunk_samples - 1, numel(signal));
    x = signal(first:last);
    real_part = max(-32768, min(32767, ...
        round(double(real(x)) * scale)));
    imag_part = max(-32768, min(32767, ...
        round(double(imag(x)) * scale)));
    interleaved = zeros(2*numel(x), 1, 'int16');
    interleaved(1:2:end) = int16(real_part);
    interleaved(2:2:end) = int16(imag_part);
    written = fwrite(fid, interleaved, 'int16');
    if written ~= numel(interleaved)
        error('generate_uwb_gnuradio_sample:WriteOutput', ...
            'Short write while writing %s.', filename);
    end
end
end

function writeDescription(filename, metadata, cf32_name, int16_name, ...
    metadata_name)
fid = fopen(filename, 'w', 'n', 'UTF-8');
if fid < 0
    error('generate_uwb_gnuradio_sample:OpenDescription', ...
        'Cannot open %s for writing.', filename);
end
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>

payload_hex = upper(reshape(dec2hex(metadata.payload_bytes, 2).', 1, []));
lines = {
    '# UWB GNU Radio 测试信号说明'
    ''
    '## 文件'
    ''
    sprintf('- %s：GNU Radio Complex Float32，按 I/Q/I/Q 交错排列。', cf32_name)
    sprintf('- %s：小端序交错 int16 I/Q，满幅度缩放到 ±32767。', int16_name)
    sprintf('- %s：MATLAB 元数据。', metadata_name)
    ''
    '## PHY 参数'
    ''
    '- 模式：IEEE 802.15.4a HRP（legacy）'
    sprintf('- 采样率：%.3f MHz', metadata.sample_rate_hz/1e6)
    sprintf('- 平均 PRF：%.1f MHz', metadata.mean_prf_mhz)
    sprintf('- 数据率：%.2f Mbps', metadata.data_rate_mbps)
    sprintf('- Preamble Code Index：%d', metadata.code_index)
    sprintf('- SYNC 前导长度：%d symbols', metadata.preamble_symbols)
    sprintf('- SamplesPerPulse：%d', metadata.samples_per_pulse)
    '- SFD：标准 IEEE 802.15.4a legacy SFD（由 lrwpanWaveformGenerator 内置生成）'
    ''
    '## 时间布局'
    ''
    sprintf('- 前置空白：%d samples = %.6f ms', metadata.blank_prefix_samples, metadata.blank_prefix_seconds*1e3)
    sprintf('- 包起始位置：第 %d 个样本（1-based）', metadata.packet_start_sample_one_based)
    sprintf('- 包波形长度：%d samples = %.6f us', metadata.packet_samples, metadata.packet_samples/metadata.sample_rate_hz*1e6)
    sprintf('- 总长度：%d samples = %.6f ms', metadata.total_samples, metadata.total_duration_seconds*1e3)
    '- 文件开头只有精确的复数零样本；未追加尾部空白。'
    ''
    '## Payload 说明'
    ''
    sprintf('- 请求的测试 payload：%d bytes。', metadata.requested_payload_bytes)
    sprintf('- 标准 IEEE 802.15.4a PHR/PSDU 部分：%d bytes（%d data bytes + 2-byte FCS）。', metadata.standard_psdu_bytes, numel(metadata.standard_data_bytes))
    sprintf('- 额外测试扩展：%d byte，接在标准 PSDU 后的 pulse-level 波形扩展。', metadata.extension_bytes)
    '- 原因：802.15.4a HRP 的 PHR 长度字段和 MATLAB 生成器的 PSDULength 上限为 127 bytes。'
    '- 因此该样本的前导、SFD、PHR、127-byte PSDU 和 FCS 是标准帧；最后 1 byte 是为满足 128-byte 测试长度而添加的非标准尾部。'
    sprintf('- 随机种子：%d（可复现）', metadata.payload_rng_seed)
    sprintf('- FCS：0x%04X（小端字节序：%s）', metadata.fcs_value, upper(reshape(dec2hex(metadata.fcs_bytes, 2).', 1, [])))
    sprintf('- Payload hex：%s', payload_hex)
    ''
    '## GNU Radio 使用'
    ''
    sprintf('1. 使用 File Source 打开 %s。', cf32_name)
    '2. Item type 选择 Complex Float32，采样率设置为 998.4e6。'
    '3. 连接 QT GUI Frequency Sink、Time Sink 或自定义 UWB 解调模块。'
    sprintf('4. 如果使用 %s，请选择交错 Complex Short/int16 I/Q 类型，并注意它已按峰值归一化到 int16 满幅度。', int16_name)
    ''
    '## 重新生成'
    ''
    '- 在 MATLAB 当前目录运行：generate_uwb_gnuradio_sample。'
    '- 修改脚本顶部的采样率、payload、随机种子或输出目录参数后重新运行即可。'
    ''
    '> 注意：5 ms 空白在 998.4 MHz 下对应 4,992,000 个采样点，文件会比较大。'
    };

for line_index = 1:numel(lines)
    fprintf(fid, '%s\n', lines{line_index});
end
end
