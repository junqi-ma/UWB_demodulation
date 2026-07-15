function z = complexZeros(varargin)
%COMPLEXZEROS Allocate a complex zero array with explicit precision.
%   Z = COMPLEXZEROS(M, N, NUMERIC_TYPE)
%   Z = COMPLEXZEROS([M N], NUMERIC_TYPE)
%   NUMERIC_TYPE is 'single' (default) or 'double'.

if nargin < 1
    error('At least one size argument is required.');
end

if ischar(varargin{end}) || isstring(varargin{end})
    numeric_type = char(varargin{end});
    size_args = varargin(1:end-1);
else
    numeric_type = 'single';
    size_args = varargin;
end

if isempty(size_args)
    error('Size arguments are required.');
end

real_part = zeros(size_args{:}, numeric_type);
z = complex(real_part);
end
