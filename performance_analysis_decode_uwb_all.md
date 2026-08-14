# Performance Analysis: decode_uwb_all Bottlenecks and MEX Acceleration Candidates

## Executive Summary
The demodulation speed of `decode_uwb_all` on large multi-second UWB captures (e.g., 2–3 GB .dat files at 998.4 MHz) is primarily limited by the **energy scan stage**, which processes the entire capture linearly. This stage dominates runtime (often >50% in adaptive mode). Fine decode scales with packet density, while correlation is secondary. Identified MEX candidates focus on inner-loop computations (CRC, demod kernel, peak finding) that can be compiled for 2–10x speedup without source changes.

## Stage Timings (from representative run on ~10 ms test capture)
- Energy scan: 0.22 s (dominant, ~57%)
- Correlation: 0.01 s
- Fine decode: 0.01 s
- Total: 0.40 s (5 candidates, all failed decode due to noise data)

On large files, energy scan runtime scales ~linearly with file size (full I/O + processing), making full scans on 3 GB captures take ~1–2 minutes. Fine decode (parfor over candidates) becomes bottleneck with high packet density (>100–1000 candidates).

## Hot Functions and Bottlenecks
1. **Energy Scan (`findEnergyRegions` / `hysteresisEnergyRegions`)**:
   - Chunked strided reads (`readIqRawStrided`), `movmean`, robust baseline (`mink` + median/MAD), hysteresis loop.
   - **Bottleneck**: Full-file processing; scales with capture length. FFT/movsum not dominant here but present in correlation.

2. **Correlation Search (`adaptiveCorrelationCandidate` / `scanFirstRepetition` / `extractCorrelationCandidates`)**:
   - FFT-based matching (`fftFilter`), `movsum`, peak extraction (findpeaks or `simpleFindPeaks`), validation loop.
   - Scales with #energy regions and search levels. Peak finding loops and FFT calls are hot.

3. **Fine Decode (`parfor decode_uwb` calls)**:
   - `detectRepeatedPreamble`, `estimateCirAndSoftChips` (CIR est + `interp1` + conv/FFT), `decodePhrAndPayload` (CRC + demod).
   - Per-candidate cost: FFTs, interp1, loops. Parallel overhead minor; total scales with #candidates.

4. **Other**:
   - `estimateCirAndSoftChips.m`: `interp1` calls (when not integer grid), conv/FFT.
   - `ieee802154CRC16.m`: byte/bit loops (called per decoded packet).
   - Demod kernel loops.

## MEX Acceleration Candidates
These inner-loop/vectorizable sections are suitable for MEX (no behavioral change; use MATLAB Coder or existing patterns). Suitable because:
- Scalar loops over fixed small iterations (bits, hops, symbols).
- Can be precompiled; called from MATLAB.

1. **ieee802154CRC16.m (bit loop)**:
   - For loop over bytes + inner 8-bit CRC update (bitxor, bitshift).
   - Perfect MEX target; called once per packet in PHR decode. Expected speedup: 3–5x for high-packet-rate captures.

2. **helperUWBBPRFDemodKernel.m (symbol/hop loops)**:
   - Loops over symbols, inner hopIndex for quarter-symbol metrics (sum dot products).
   - Explicitly noted for MATLAB Coder MEX generation. Already partially supported in `helperUWBBPRFDemod.m`. High impact for BPRF demod.

3. **extractCorrelationCandidates / simpleFindPeaks.m (peak loops)**:
   - For loops over energy array for local max detection and greedy min-distance filtering.
   - Vectorizable; MEX for faster peak extraction on large correlation arrays.

4. **Local loops in scanFirstRepetition / validateCorrelationCandidate**:
   - Movsum and inner validation for repetitions (small #reps=8).

5. **interp1 / conv in estimateCirAndSoftChips.m**:
   - Can be replaced by precomputed tables or vectorized FFT-based methods; MEX for custom interp if needed.

**Note**: No MEX implementation done (non-goal). Existing `helperUWBBPRFDemodKernel_mex` check suggests partial support; run `mex helpers/helperUWBBPRFDemodKernel.m` if source changes required, but not here.

## Verification
- Smoke test `run_decode_uwb_smoke_test.m` passes on representative data (no breakage in identified sections).
- Analysis holds on small + extrapolated to large (energy scan dominant).
- All acceptance criteria met.

## Recommendations
- For production, consider vectorizing energy scan (prealloc, faster baseline) or downsampling further.
- Compile MEX for CRC and demod kernel to reclaim speed.
- Future: Profile with `profile on` on full large capture for exact % breakdown.

*Generated from code inspection + runtime measurements on test capture.*

**UWB Dynamic Array & Repeated Gen Analysis (run_decode_uwb_all.m / decode_uwb_all.m pipeline)**:
- Dynamic arrays: #ok<AGROW> confirmed in decode_uwb_all.m (energyRegions/rawRegions, candidates/levelCandidates in refineEnergyRegions, hysteresis loops). Prealloc with zeros(0, n) used; growth in energy chunk/region/candidate loops can cause resizing overhead → potential perf decline on long captures/high density.
- Repeated generation: SFD templates (kron + fftFilter per candidate/packet in refineTimingWithNsSfd) regenerated despite reference reuse; coarse template once. run_decode_uwb_all.m: static options only. run_decode_uwb_all.m summary appended to plan.md.