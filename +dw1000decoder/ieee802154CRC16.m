function crc = ieee802154CRC16(bytes)
%IEEE802154CRC16 Compute the reflected IEEE 802.15.4 CRC-16.
%   CRC = IEEE802154CRC16(BYTES) returns the CRC-16 checksum of the
%   uint8 vector BYTES, using the reflected polynomial 0x8408. The result
%   is a uint16 scalar. This is the FCS algorithm used in DW1000 / QM35
%   frames.
%
%   See also DECODEPHRANDPAYLOAD.

bytes = uint8(bytes(:));
crc = uint16(0);
polynomial = uint16(hex2dec('8408'));

for byteIdx = 1:length(bytes)
    crc = bitxor(crc, uint16(bytes(byteIdx)));
    for bitIdx = 1:8
        if bitand(crc, uint16(1))
            crc = bitxor(bitshift(crc, -1), polynomial);
        else
            crc = bitshift(crc, -1);
        end
    end
end
end
