function rx = selectIqChannel(raw, channelIndex)
%SELECTIQCHANNEL Extract one interleaved I/Q channel as a complex column.
%   RX = SELECTIQCHANNEL(RAW, CHANNELINDEX) picks the CHANNELINDEX-th
%   complex channel from RAW, a 2-by-N or (2*antNum)-by-N matrix of
%   interleaved int16 I/Q samples (I1, Q1, I2, Q2, ...). The output is a
%   complex column vector.
%
%   See also READIQRAW.

validateattributes(raw, {'numeric'}, {'2d'}, 'selectIqChannel', 'raw');
validateattributes(channelIndex, {'numeric'}, {'scalar', 'positive', 'integer'}, ...
    'selectIqChannel', 'channelIndex');

iRow = 2*channelIndex - 1;
qRow = 2*channelIndex;
rx = raw(iRow, :) + 1j*raw(qRow, :);
rx = rx(:);
end
