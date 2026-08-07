function mexFile = build_uwb_mex()
%BUILD_UWB_MEX Build the numeric BPRF demodulation MEX kernel.
%   The generated binary is platform-specific and intentionally gitignored.

projectDirectory = fileparts(mfilename('fullpath'));
helperDirectory = fullfile(projectDirectory, 'helpers');
buildDirectory = fullfile(projectDirectory, 'codegen', 'bprf_demod');
originalDirectory = pwd;
directoryGuard = onCleanup(@() cd(originalDirectory));
cd(helperDirectory);

maximumSymbols = 2048;
maximumFieldSamples = 512*maximumSymbols;
fieldSamplesType = coder.typeof(complex(single(0)), ...
    [maximumFieldSamples, 1], [true, false]);
spreadingType = coder.typeof(0, [64, maximumSymbols], [true, true]);
scalarType = 0;

config = coder.config('mex');
config.GenerateReport = false;
codegen('-config', config, 'helperUWBBPRFDemodKernel', '-args', ...
    {fieldSamplesType, scalarType, scalarType, scalarType, scalarType, ...
    spreadingType}, '-o', 'helperUWBBPRFDemodKernel_mex', ...
    '-d', buildDirectory);

mexFile = fullfile(helperDirectory, ...
    ['helperUWBBPRFDemodKernel_mex.' mexext]);
if ~isfile(mexFile)
    error('build_uwb_mex:MissingOutput', ...
        'MATLAB Coder did not create the expected MEX file: %s', mexFile);
end
fprintf('Built %s\n', mexFile);
clear directoryGuard;
end
