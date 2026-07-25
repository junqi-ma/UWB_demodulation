function systematicBits = helperUWBConvDec(cw, constraintLength)
%helperUWBConvDec Convolutional decoding as per IEEE 802.15.4a/z
%   SYST = HELPERUWBCONVDEC(CW, CL) convolutionally decodes the input
%   codewords CW, as per the rate-1/2 convolutional coding specified in
%   Sec. 15.3.3.3 of the IEEE 802.15.4 (2020) specification and the IEEE
%   802.15.4z amendment. CL can be either 3 or 7.

%   Copyright 2022 The MathWorks, Inc.

  tbDepth = 5*(constraintLength-1);
  if constraintLength == 3
    % Constraint length 3, as in 15.3.3.3 in 15.4a 
    trellis = poly2trellis(3, [2 5]);
  else
    % Constraint length 7, as in 15.3.3.3 in 15.4z amendment
    trellis = poly2trellis(7, [133 171]);
  end
  if size(cw, 1)/2 < tbDepth % PHR
    cw = [cw; zeros(10, 1)]; 
  end
  systematicBits = vitdec(cw, trellis, tbDepth, 'trunc', 'hard');
end