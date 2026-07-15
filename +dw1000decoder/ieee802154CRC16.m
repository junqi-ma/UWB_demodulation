function crc = ieee802154CRC16(bytes)
%IEEE802154CRC16 Calculate reflected IEEE 802.15.4 CRC-16.
crc = uint16(0);
polynomial = uint16(hex2dec('8408'));
bytes = uint8(bytes(:));
for byte_index = 1:length(bytes)
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
