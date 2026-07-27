function [rx, info] = readAndCancelInterference(params)
%READANDCANCELINTERFERENCE Read capture samples and cancel the known tone.
%   [RX, INFO] = READANDCANCELINTERFERENCE(PARAMS) reads the requested
%   interval from the capture file, extracts the selected I/Q channel,
%   and subtracts the clock-synchronous interference tone when enabled.
%   INFO reports the tone frequency, coefficient, and suppression.
%
%   See also DECODE_X410_DW1000, APPLYBLANKINTERVALS.

c = uwbdecoder.constants();

raw = uwbdecoder.readIqRaw(params.file_name, params.sample_offset, ...
    params.sample_num, params.ant_num);
rx = uwbdecoder.selectIqChannel(raw, params.channel_index);

toneFrequency = params.interference_tone_bin / ...
    params.interference_period_samples * params.fs_rx;
info = struct('enabled', params.enable_interference_cancellation, ...
    'frequency_hz', toneFrequency, 'coefficient', complex(0), ...
    'suppression_db', NaN);

if params.enable_interference_cancellation
    if ~isempty(params.interference_coefficient)
        coefficient = params.interference_coefficient(1);
        estimatedFromQuiet = false;
    else
        quietRaw = uwbdecoder.readIqRaw(params.file_name, ...
            params.interference_quiet_offset, params.interference_quiet_num, ...
            params.ant_num);
        rxQuiet = uwbdecoder.selectIqChannel(quietRaw, params.channel_index);
        quietN = params.interference_quiet_offset + (0:length(rxQuiet)-1).';
        quietBasis = uwbdecoder.synchronousTone(quietN, ...
            params.interference_tone_bin, params.interference_period_samples);
        coefficient = mean(rxQuiet .* conj(quietBasis));
        estimatedFromQuiet = true;
    end

    rxN = params.sample_offset + (0:length(rx)-1).';
    rxBasis = uwbdecoder.synchronousTone(rxN, ...
        params.interference_tone_bin, params.interference_period_samples);

    % Optional suppression diagnostic (disabled by default for speed).
    reportSuppression = isfield(params, 'verbose') && params.verbose;
    if reportSuppression
        amplitudeBefore = abs(mean(rx .* conj(rxBasis)));
    end
    rx = rx - coefficient .* rxBasis;
    if reportSuppression
        amplitudeAfter = abs(mean(rx .* conj(rxBasis)));
        suppressionDb = 20*log10(amplitudeBefore / max(amplitudeAfter, eps));
    else
        suppressionDb = NaN;
    end
    info.coefficient = coefficient;
    info.suppression_db = suppressionDb;

    if reportSuppression
        fprintf('Clock-synchronous interference cancellation enabled.\n');
        fprintf('  Relative tone frequency: %+.6f MHz\n', toneFrequency/1e6);
        fprintf('  Absolute tone frequency: %.6f MHz\n', ...
            (params.x410_center_frequency + toneFrequency)/1e6);
        fprintf('  Estimated amplitude     : %.3f ADC counts\n', abs(coefficient));
        fprintf('  Estimated phase         : %.3f degrees\n', ...
            angle(coefficient)*180/pi);
        if estimatedFromQuiet
            fprintf('  Coefficient source      : quiet-interval estimate\n');
        else
            fprintf('  Coefficient source      : reused precomputed value\n');
        end
        fprintf('  Loaded-segment suppression: %.3f dB\n', suppressionDb);
    end
end

% Optional time-domain blanking of known interferer intervals (e.g. DW1000
% bursts before QM35 decoding in a mixed capture).
if ~isempty(params.blank_intervals)
    [rx, blankInfo] = uwbdecoder.applyBlankIntervals(rx, ...
        params.sample_offset, params.blank_intervals, ...
        params.blank_taper_samples, params.blank_weight);
    info.blank = blankInfo;
    if isfield(params, 'verbose') && params.verbose && blankInfo.applied_count > 0
        fprintf('Blanked %d interferer interval(s), %d samples touched (weight=%.2f).\n', ...
            blankInfo.applied_count, blankInfo.samples_touched, params.blank_weight);
    end
end

rx = rx - mean(rx);
end
