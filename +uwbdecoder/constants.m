function c = constants()
%CONSTANTS Physical and HRP protocol constants used across the decoder.
%   C = CONSTANTS() returns a structure whose fields name the magic numbers
%   that appear repeatedly in the decoder (bytes per IQ sample, int16 limits,
%   HRP preamble timing, speed of light). Callers reference C.FIELD instead
%   of inlining the literal, so a value is defined in exactly one place.
%
%   See also DEFAULTOPTIONS, MERGEOPTIONS.

c = struct();
c.BYTES_PER_INT16 = 2;
c.BYTES_PER_IQ_SAMPLE = 4;          % int16 I + int16 Q
c.INT16_MAX = 32767;
c.INT16_MIN = -32768;
c.HRP_CHIPS_PER_SYMBOL = 1016;
c.HRP_CHIP_RATE_HZ = 998.4e6;
c.PREAMBLE_PERIOD_S = 1016/998.4e6; % one SYNC repetition
c.SPEED_OF_LIGHT = 299792458;
end
