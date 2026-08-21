%% Generate one IEEE 802.15.4a HRP UWB baseband waveform.
% Outputs:
%   waveform_4a : complex single-precision IQ at 998.4 MHz
%   tx_4a       : detailed transmitter metadata and field indices
%   *.mat       : waveform, payload, configuration, and metadata
%   *.cfile     : GNU Radio interleaved complex-float32 IQ
%   *.dat       : X410-compatible interleaved int16 IQ
clear;
close all;
clc;

this_dir = fileparts(mfilename('fullpath'));
if isempty(this_dir)
    this_dir = pwd;
end
addpath(this_dir);

%% -------------------- User parameters --------------------
sample_rate_hz = 998.4e6;
code_index = 9;
preamble_repetitions = 64;
data_bytes = 125;              % PSDU = data bytes + two-byte FCS
payload_rng_seed = 20260821;
peak_amplitude = 0.8;
guard_samples = 4096;
save_outputs = true;

assert(data_bytes >= 1 && data_bytes <= 125 && data_bytes == fix(data_bytes), ...
    'data_bytes must be an integer from 1 through 125.');
assert(preamble_repetitions >= 1 && ...
    preamble_repetitions == fix(preamble_repetitions), ...
    'preamble_repetitions must be a positive integer.');

%% -------------------- Payload with a valid IEEE 802.15.4 FCS ---------
rng(payload_rng_seed, 'twister');
mac_data_bytes = uint8(randi([0 255], data_bytes, 1));
fcs_value = ieee802154Crc16(mac_data_bytes);
fcs_bytes = uint8([bitand(fcs_value, uint16(255)); ...
    bitshift(fcs_value, -8)]);
psdu_bytes = [mac_data_bytes; fcs_bytes];

% generate_uwb_tx_from_decode accepts the same packed payload structure
% returned by decode_uwb. Marking fcs_pass=true is safe because the FCS was
% calculated immediately above rather than copied from an unknown packet.
decoded_payload = struct();
decoded_payload.payload = struct( ...
    'bytes', psdu_bytes, ...
    'fcs_pass', true);

%% -------------------- IEEE 802.15.4a waveform ------------------------
tx_options = struct( ...
    'fs_tx', sample_rate_hz, ...
    'phy_mode', '802.15.4a', ...
    'ranging', false, ...
    'preamble_repetitions', preamble_repetitions, ...
    'code_index', code_index, ...
    'sfd_number', 0, ...
    'sfd_sequence', [], ...       % standard 802.15.4a legacy SFD
    'peak_amplitude', peak_amplitude, ...
    'guard_samples', guard_samples, ...
    'require_fcs_pass', true);

tx_4a = generate_uwb_tx_from_decode(decoded_payload, tx_options);
waveform_4a = single(tx_4a.waveform_x410(:));

assert(abs(tx_4a.sample_rate_tx - sample_rate_hz) <= 1, ...
    'Generated waveform sample rate does not match the requested rate.');
assert(all(isfinite(waveform_4a)), ...
    'Generated waveform contains non-finite samples.');

% field_indices_work excludes the leading guard added to waveform_x410.
field_indices = tx_4a.field_indices_work;
field_names = {'SYNC', 'SFD', 'PHR', 'Payload'};
for k = 1:numel(field_names)
    name = field_names{k};
    field_indices.(name) = field_indices.(name) + guard_samples;
end

%% -------------------- Preview plot -----------------------------------
time_us = (0:numel(waveform_4a)-1).' / sample_rate_hz * 1e6;
samples_per_sync = diff(tx_4a.field_indices_work.SYNC) + 1;
samples_per_sync = samples_per_sync / preamble_repetitions;
preview_samples = min(numel(waveform_4a), ...
    guard_samples + round(4 * samples_per_sync));

fig = figure('Name', 'IEEE 802.15.4a HRP UWB waveform', ...
    'Color', 'w', 'Position', [50 80 1500 760]);
tiledlayout(fig, 2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

nexttile;
max_plot_points = 150000;
stride = max(1, ceil(numel(waveform_4a) / max_plot_points));
span = 1:stride:numel(waveform_4a);
plot(time_us(span), abs(waveform_4a(span)), ...
    'Color', [0.12 0.43 0.82], 'LineWidth', 0.55);
hold on;
field_colors = [0.15 0.55 0.25; 0.85 0.35 0.10; ...
    0.60 0.25 0.75; 0.15 0.15 0.15];
for k = 1:numel(field_names)
    name = field_names{k};
    start_us = (field_indices.(name)(1)-1) / sample_rate_hz * 1e6;
    xline(start_us, '--', name, 'Color', field_colors(k, :), ...
        'LineWidth', 1.1, 'LabelVerticalAlignment', 'middle');
end
grid on;
xlim([time_us(1), time_us(end)]);
xlabel('Time (us)');
ylabel('|IQ|');
title('Complete packet envelope and field boundaries');

nexttile;
preview = (guard_samples+1):preview_samples;
plot(time_us(preview), real(waveform_4a(preview)), ...
    'Color', [0.15 0.45 0.85], 'LineWidth', 0.65);
hold on;
plot(time_us(preview), imag(waveform_4a(preview)), '--', ...
    'Color', [0.85 0.25 0.18], 'LineWidth', 0.65);
grid on;
xlim([time_us(preview(1)), time_us(preview(end))]);
xlabel('Time (us)');
ylabel('Amplitude');
title('First four SYNC repetitions');
legend('I', 'Q', 'Location', 'northeast');

sgtitle(sprintf(['IEEE 802.15.4a HRP | code %d | %d SYNC | ', ...
    '%d-byte PSDU | %.1f MHz PRF | %.2f Mb/s'], ...
    code_index, preamble_repetitions, numel(psdu_bytes), 62.4, 6.81));

%% -------------------- Save waveform and metadata ---------------------
output_dir = fullfile(this_dir, 'generated_uwb_4a');
base_name = sprintf('uwb_4a_code%d_preamble%d_payload%d', ...
    code_index, preamble_repetitions, numel(psdu_bytes));

metadata = struct();
metadata.protocol = 'IEEE 802.15.4a HRP';
metadata.sample_rate_hz = sample_rate_hz;
metadata.mean_prf_mhz = 62.4;
metadata.data_rate_mbps = 6.81;
metadata.code_index = code_index;
metadata.preamble_repetitions = preamble_repetitions;
metadata.sfd = 'standard IEEE 802.15.4a legacy SFD';
metadata.psdu_bytes = numel(psdu_bytes);
metadata.mac_data_bytes = mac_data_bytes;
metadata.fcs_bytes = fcs_bytes;
metadata.fcs_value = fcs_value;
metadata.payload_rng_seed = payload_rng_seed;
metadata.peak_amplitude = peak_amplitude;
metadata.guard_samples = guard_samples;
metadata.field_indices = field_indices;
metadata.waveform_samples = numel(waveform_4a);
metadata.duration_s = numel(waveform_4a) / sample_rate_hz;

fprintf('\n=== Generated IEEE 802.15.4a HRP waveform ===\n');
fprintf('Code / preamble       : %d / %d SYNC\n', ...
    code_index, preamble_repetitions);
fprintf('PSDU                   : %d bytes (%d data + 2 FCS)\n', ...
    numel(psdu_bytes), data_bytes);
fprintf('FCS                    : 0x%04X\n', fcs_value);
fprintf('Sample rate            : %.3f MHz\n', sample_rate_hz / 1e6);
fprintf('Waveform               : %d samples, %.3f us\n', ...
    numel(waveform_4a), metadata.duration_s * 1e6);

if save_outputs
    if ~isfolder(output_dir)
        mkdir(output_dir);
    end
    mat_file = fullfile(output_dir, base_name + ".mat");
    cf32_file = fullfile(output_dir, base_name + ".cfile");
    int16_file = fullfile(output_dir, base_name + "_int16.dat");
    png_file = fullfile(output_dir, base_name + ".png");

    save(mat_file, 'waveform_4a', 'tx_4a', 'psdu_bytes', 'metadata', '-v7.3');
    writeComplexFloat32(char(cf32_file), waveform_4a);
    int16_scale = write_x410_iq_int16(char(int16_file), waveform_4a);
    metadata.int16_scale = int16_scale;
    exportgraphics(fig, png_file, 'Resolution', 180);

    fprintf('MAT                    : %s\n', mat_file);
    fprintf('GNU Radio CF32         : %s\n', cf32_file);
    fprintf('X410 int16             : %s\n', int16_file);
    fprintf('Preview                : %s\n', png_file);
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
fid = fopen(filename, 'wb', 'ieee-le');
assert(fid >= 0, 'Cannot open output file: %s', filename);
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
interleaved = zeros(2*numel(signal), 1, 'single');
interleaved(1:2:end) = real(signal);
interleaved(2:2:end) = imag(signal);
count = fwrite(fid, interleaved, 'single');
assert(count == numel(interleaved), 'Short write to %s.', filename);
end

