function [rx, info] = readAndCancelInterference(params)
%READANDCANCELINTERFERENCE Read capture samples and cancel the known tone.
fid = fopen(params.file_name, 'rb');
if fid < 0
    error('Cannot open capture: %s', params.file_name);
end
file_guard = onCleanup(@() fclose(fid));

fseek(fid, params.sample_offset*params.ant_num*4, 'bof');
raw = fread(fid, [2*params.ant_num, params.sample_num], 'int16=>double');
if size(raw, 2) ~= params.sample_num
    error('Could not read the requested capture interval.');
end
rx = dw1000decoder.selectIqChannel(raw, params.channel_index);

tone_frequency = params.interference_tone_bin / ...
    params.interference_period_samples * params.fs_rx;
info = struct('enabled', params.enable_interference_cancellation, ...
    'frequency_hz', tone_frequency, 'coefficient', complex(0), ...
    'suppression_db', NaN);

if params.enable_interference_cancellation
    if ~isempty(params.interference_coefficient)
        coefficient = params.interference_coefficient(1);
        estimated_from_quiet = false;
    else
        status = fseek(fid, ...
            params.interference_quiet_offset*params.ant_num*4, 'bof');
        if status ~= 0
            error('Failed to seek to the interference-estimation interval.');
        end
        quiet_num = params.interference_quiet_num;
        raw_quiet = fread(fid, [2*params.ant_num, quiet_num], 'int16=>double');
        if size(raw_quiet, 2) ~= quiet_num
            error(['Could not read the complete ', ...
                'interference-estimation interval.']);
        end
        rx_quiet = dw1000decoder.selectIqChannel( ...
            raw_quiet, params.channel_index);
        quiet_n = params.interference_quiet_offset+(0:length(rx_quiet)-1).';
        quiet_basis = dw1000decoder.synchronousTone(quiet_n, ...
            params.interference_tone_bin, params.interference_period_samples);
        coefficient = mean(rx_quiet.*conj(quiet_basis));
        estimated_from_quiet = true;
    end

    rx_n = params.sample_offset+(0:length(rx)-1).';
    rx_basis = dw1000decoder.synchronousTone(rx_n, ...
        params.interference_tone_bin, params.interference_period_samples);

    % Optional suppression diagnostic (disabled by default for speed).
    report_suppression = isfield(params, 'verbose') && params.verbose;
    if report_suppression
        amplitude_before = abs(mean(rx.*conj(rx_basis)));
    end
    rx = rx-coefficient.*rx_basis;
    if report_suppression
        amplitude_after = abs(mean(rx.*conj(rx_basis)));
        suppression_db = 20*log10(amplitude_before/max(amplitude_after, eps));
    else
        suppression_db = NaN;
    end
    info.coefficient = coefficient;
    info.suppression_db = suppression_db;

    if report_suppression
        fprintf('Clock-synchronous interference cancellation enabled.\n');
        fprintf('  Relative tone frequency: %+.6f MHz\n', tone_frequency/1e6);
        fprintf('  Absolute tone frequency: %.6f MHz\n', ...
            (params.x410_center_frequency+tone_frequency)/1e6);
        fprintf('  Estimated amplitude     : %.3f ADC counts\n', abs(coefficient));
        fprintf('  Estimated phase         : %.3f degrees\n', angle(coefficient)*180/pi);
        if estimated_from_quiet
            fprintf('  Coefficient source      : quiet-interval estimate\n');
        else
            fprintf('  Coefficient source      : reused precomputed value\n');
        end
        fprintf('  Loaded-segment suppression: %.3f dB\n', suppression_db);
    end
end
rx = rx-mean(rx);
clear file_guard;
end
