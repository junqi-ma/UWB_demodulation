# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project does

This branch (`gnuradio-scheduled-dump`) analyzes **GNU Radio scheduled-extractor** dumps (`capture.iq` + `capture.jsonl`) from `UwbAutoScheduledExtractorSc16` / `UwbScheduledExtractorSc16`. MATLAB upsamples 65/48 from 737.28 MS/s SC16 to 998.4 MHz, then demodulates QM35 (and optionally DW1000) with the shared HRP UWB PHY stack.

The decode / regenerate / SIC reference implementation is kept. Continuous 1 s `.dat` experiment scripts (grid search, energy-detection plots, PLL notes, `backup/`) stay on `acceleration` and are not on this branch.

## Environment

- **MATLAB R2022b+** with Communications Toolbox (`lrwpanHRPConfig`, `lrwpanWaveformGenerator`, `lrwpan.internal.HRPCodes`, and the `helperUWBBPRFDemod` / `helperUWBPHRDecode` / `helperUWBPayloadDecode` family).
- Working directory is the repo root (`F:\USRP数据解调`). Scripts assume they are run from here (they `cd(fileparts(mfilename('fullpath')))` or `addpath(project_root)`).
- Capture data lives **outside** the repo at `F:\UWB基带数据\` as interleaved int16 I/Q `.dat` files. These are gitignored and not committed.
- Input IQ is assumed **already preprocessed**: resampled to 998.4 MHz, sync single-tone removed, center frequency shifted down 10 MHz. Decoder code does not repeat this.

## Commands (run from repo root)

MATLAB is interpreted — there is no build step. Run scripts via `matlab -batch` (preferred, headless, no GUI) or interactively.

```matlab
% Decode a GNU Radio scheduled SC16 dump (edit dumpDir in the script)
matlab -batch "run_decode_scheduled_sc16_dump"

% Verify the decoder works end-to-end (non-interactive, pass/fail report)
matlab -batch "run_decode_uwb_smoke_test"

% Decode a single packet from a continuous .dat, keep intermediates
matlab -batch "run_decode_uwb"

% CIR interference detector unit test
matlab -batch "runtests('tests/testAnalyzeCirInterference.m')"

% SIC pipeline (continuous mixed .dat reference): QM35 → cancel → DW1000 → cancel
matlab -batch "run_qm35_dw1000_sic_pipeline"
```

`-batch` automatically does `cd` to the script's folder, so paths resolve. If a script errors, `-batch` exits non-zero — useful as a check. There is no linter; `matlab -batch` parse-time errors are the closest equivalent.

## Architecture

### The decode pipeline (core abstraction)

`decode_uwb.m` is the single-packet entry point and the best place to read the full processing chain. It stages work through the `+uwbdecoder/` package in this order:

`readIqRaw` → `selectIqChannel` → `buildUwbReference` → `detectRepeatedPreamble` → `validateCaptureLength` → `cropToFrame` → `compensateCarrierOffset` → `refineTimingWithNsSfd` → `analyzeNsSfdSymbols` → `estimateCirAndSoftChips` → `locateNsSfd` → `decodePhrAndPayload` → `packageResult`

Key design choices to be aware of:
- **`+uwbdecoder/` is a pure-function MATLAB package.** Each stage is stateless and file-independent; batch scripts reuse a single `reference` (via the 4th arg of `decode_uwb`) across packets to avoid rebuilding the PHY waveform.
- **Two-stage preamble detection** (`detectRepeatedPreamble`): coarse 4×-downsampled matched filter for candidate ROI, then full-rate peak tracking with a MAD adaptive threshold (`median + 6σ`, floored at 20% of peak) and `polyfit` over peak positions to get `measured_period` and `clock_error_ppm`.
- **CIR estimation** (`estimateCirAndSoftChips`) uses only the *last* `cir_repetitions` SYNC repetitions (default 64 of 128) and a short local matched-filter window (`cir_pre_samples`/`cir_post_samples`) around the first path — deliberately avoids O(N·L) filtering over the whole capture.
- **Coordinate systems matter.** `cropToFrame` shifts `preamble.*` into cropped-local coordinates; `packageResult` adds back `start_sample_uncropped` and `crop_start_sample`. When comparing timing across stages, confirm which frame you're in.
- **SFD auto-selection** (`refineTimingWithNsSfd`): `sfd_mode='auto'` scores Decawave DW-8, IEEE legacy, and four 4z templates and picks the highest correlation — the chosen name lands in `result.sfd.name`.

### Repository layers

| Layer | Location | Role |
|-------|----------|------|
| Decoder primitives | `+uwbdecoder/` | Pure, reusable stages, including `analyzeCirInterference` |
| Single/batch decode | `decode_uwb.m`, `decode_uwb_all.m` | Orchestrate the package |
| GNU Radio dump I/O + decode | `read_uwb_packet.m`, `decode_scheduled_sc16_dump.m` | Slice SC16 windows, 65/48, call `decode_uwb` |
| Dump experiment drivers | `run_decode_scheduled_sc16_dump.m`, `run_cancel_capture_tone.m` | Concrete dump paths |
| CIR / interference views | `visualize_qm35_cir_interference.m`, `analyze_qm35_early_energy_stats.m` | Per-packet and multi-frame analysis |
| SIC pipeline | `sic_pipeline/` | Multi-stage QM35→DW1000 cancellation |
| Chip helper wrappers | `helpers/` | Communications Toolbox BPRF/HPRF/PHR wrappers |
| Tests | `tests/` | MATLAB `functiontests` |

`sic_pipeline/` deliberately does **not** duplicate decode/cancel logic — it calls the root `run_decode_uwb_all` / `run_cancel_all_uwb_packets` via `run(fullfile(project_root, ...))` and only owns staging, config, and SIC-specific visualization. Don't edit decode behavior inside `sic_pipeline/`.

### Configuration flow

`defaultOptions.m` defines every tunable (sample rate, `preamble_repetitions`, `code_index`, `data_rate`, `sfd_mode`, CIR windows, SFD template arrays). Every `run_*.m` script overrides a subset. `mergeOptions.m` merges and validates. When adding a knob, add it to `defaultOptions` with a safe default rather than hard-coding in a driver.

Chip-specific differences are mostly captured by option values, not code branches:
- **DW1000**: `preamble_repetitions=256`, `code_index=10`, `sfd_mode='decawave'`
- **QM35**: `preamble_repetitions=128`, `code_index=9`, `sfd_mode='auto'`

## Output conventions

- `decoded_results/<capture>_<profile>/` — per-capture batch outputs: `all_frames_cir.mat`, `frame_summary.csv`. Gitignored.
- `regenerated_qm35/` — regenerated waveforms. Gitignored.
- `*.mat`, `*.fig`, `*.dat`, `*.bin`, `*.iq` are all gitignored — never commit data or MATLAB binaries.

## Common gotchas

- **`preamble_repetitions` must match the real SYNC length.** QM35 emits 128; configuring 256 pushes the SFD search ~128 symbols late and breaks decode. First thing to check when SFD correlation is low.
- The receiver turn-on transient bends phase over the first ~24 SYNC peaks — `compensateCarrierOffset` skips them. Don't feed raw early-peak phases into CFO estimates.
- `detectRepeatedPreamble` falls back to a full-capture full-speed search if the ROI yields fewer than 32 peaks — slow on long captures, and usually a sign the coarse detection threshold or `preamble_repetitions` is wrong.
- Output timing fields come in both cropped and uncropped flavors; the `_uncropped` suffix is the one anchored to the original file sample index.
- Communications Toolbox functions raise if the toolbox / a license is missing — `run_decode_uwb_smoke_test` is the quick way to confirm the environment is intact before running longer jobs.
