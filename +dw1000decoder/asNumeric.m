function x = asNumeric(x, numeric_type)
%ASNUMERIC Cast numeric data to the decoder working precision.
%   X = ASNUMERIC(X, 'single') or ASNUMERIC(X, 'double').
%   Complex values keep their complex nature; only the underlying
%   floating-point class is changed.

if nargin < 2 || isempty(numeric_type)
    numeric_type = 'single';
end
if isstring(numeric_type)
    numeric_type = char(numeric_type);
end
switch lower(numeric_type)
    case 'single'
        x = single(x);
    case 'double'
        x = double(x);
    otherwise
        error('numeric_type must be ''single'' or ''double''.');
end
end
