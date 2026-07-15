function rx = selectIqChannel(raw, channel_index)
%SELECTIQCHANNEL Convert one interleaved I/Q channel to a complex column.
rx = raw(2*channel_index-1, :) + 1j*raw(2*channel_index, :);
rx = rx(:);
end
